#!/bin/bash
# ============================================================================
# NATIVE OCAML BUILD SCRIPT
# Builds native OCaml compiler for the current target platform
#
# Variables:
#   OCAML_INSTALL_PREFIX - Where native OCaml will be installed (destination)
#
# Toolchain Variables (NATIVE_*):
#   NATIVE_CC      - C compiler for native code
#   NATIVE_AS      - Assembler for native code
#   NATIVE_AR      - Archive tool
#   NATIVE_RANLIB  - Archive index tool
#   NATIVE_ASPP    - Assembler with preprocessing (CC -c)
#
# CONDA_OCAML_* Variables (embedded in binaries for runtime use):
#   CONDA_OCAML_CC      - Runtime C compiler
#   CONDA_OCAML_AS      - Runtime assembler
#   CONDA_OCAML_AR      - Runtime archive tool
#   CONDA_OCAML_RANLIB  - Runtime ranlib
#   CONDA_OCAML_MKEXE   - Runtime executable linker command
#   CONDA_OCAML_MKDLL   - Runtime shared library linker command
# ============================================================================

set -euo pipefail

# Source common functions
source "${RECIPE_DIR}/building/common-functions.sh"

# ============================================================================
# Platform Detection
# ============================================================================

# Determine platform type
case "${target_platform}" in
  linux-*)  _PLATFORM_TYPE="linux" ;;
  osx-*)    _PLATFORM_TYPE="macos" ;;
  win-*)    _PLATFORM_TYPE="windows" ;;
  *)        _PLATFORM_TYPE="unknown" ;;
esac

# Determine if dlopen needs -ldl (glibc <2.34)
_NEEDS_DL=0
[[ "${_PLATFORM_TYPE}" == "linux" ]] && _NEEDS_DL=1

# ============================================================================
# Validate Environment
# ============================================================================

# Compiler activation should set CONDA_TOOLCHAIN_BUILD
if [[ -z "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
  echo "ERROR: CONDA_TOOLCHAIN_BUILD not set (compiler activation failed?)"
  exit 1
fi

# Where to install native OCaml
: "${OCAML_INSTALL_PREFIX:=${PREFIX}}"

# ============================================================================
# Native Toolchain Setup (NATIVE_*)
# ============================================================================

echo ""
echo "============================================================"
echo "Native OCaml build configuration"
echo "============================================================"
echo "  Platform:      ${target_platform} (${_PLATFORM_TYPE})"
echo "  Install:       ${OCAML_INSTALL_PREFIX}"

# Native toolchain - simplified basenames (hardcoded in binaries)
# These use CONDA_TOOLCHAIN_BUILD which is set by compiler activation
NATIVE_AR="${CONDA_TOOLCHAIN_BUILD}-ar${EXE}"
NATIVE_AS="${CONDA_TOOLCHAIN_BUILD}-as${EXE}"
NATIVE_CC=$(basename "${CC_FOR_BUILD}")
NATIVE_RANLIB="${CONDA_TOOLCHAIN_BUILD}-ranlib${EXE}"
NATIVE_ASPP="${NATIVE_CC} -c"

# Platform-specific overrides
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  # macOS: clang integrated assembler
  NATIVE_AS="${NATIVE_CC}"
  export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld -Wl,-headerpad_max_install_names"
  export DYLD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
fi

echo "  NATIVE_CC:     ${NATIVE_CC}"
echo "  NATIVE_AS:     ${NATIVE_AS}"
echo "  NATIVE_AR:     ${NATIVE_AR}"
echo "  NATIVE_RANLIB: ${NATIVE_RANLIB}"

# ============================================================================
# CONDA_OCAML_* Variables (Runtime Configuration)
# ============================================================================

# These are embedded in binaries and expanded at runtime
# Users can override via environment variables
export CONDA_OCAML_AR="${NATIVE_AR}"
export CONDA_OCAML_AS="${NATIVE_AS}"
export CONDA_OCAML_CC="${NATIVE_CC}"
export CONDA_OCAML_RANLIB="${NATIVE_RANLIB}"

case "${_PLATFORM_TYPE}" in
  linux)
    export CONDA_OCAML_MKEXE="${NATIVE_CC} -Wl,-E"
    export CONDA_OCAML_MKDLL="${NATIVE_CC} -shared"
    ;;
  macos)
    export CONDA_OCAML_MKEXE="${NATIVE_CC} -fuse-ld=lld -Wl,-headerpad_max_install_names"
    export CONDA_OCAML_MKDLL="${NATIVE_CC} -shared -fuse-ld=lld -Wl,-headerpad_max_install_names -undefined dynamic_lookup"
    ;;
    ;;
esac

# ============================================================================
# Configure Arguments
# ============================================================================

CONFIG_ARGS=(--enable-shared)

# Load platform-specific utilities
source "${RECIPE_DIR}/building/non-unix-utilities.sh"

# No-op for unix, builds flexdll on Windows
unix_noop_build_toolchain

# Enable ocamltest if running tests
if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
  CONFIG_ARGS+=(--enable-ocamltest)
fi

# Add toolchain to configure args
CONFIG_ARGS+=(
  AR="${NATIVE_AR}"
  AS="${NATIVE_AS}"
  CC="${NATIVE_CC}"
  RANLIB="${NATIVE_RANLIB}"
)

# ============================================================================
# Configure
# ============================================================================

echo ""
echo "=== [1/4] Configuring native compiler ==="
./configure "${CONFIG_ARGS[@]}" -prefix="${OCAML_INSTALL_PREFIX}" \
  > "${SRC_DIR}/_logs/configure.log" 2>&1 || {
    cat "${SRC_DIR}/config.log"
    exit 1
  }

# No-op for unix, patches Makefile.config on Windows
unix_noop_update_toolchain

# ============================================================================
# Patch config.generated.ml
# ============================================================================

echo "=== [2/4] Patching config for CONDA_OCAML_* variables ==="

config_file="utils/config.generated.ml"

if [[ "${_PLATFORM_TYPE}" == "linux" ]] || [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  # Unix: Use $CONDA_OCAML_* environment variable references
  sed -i 's/^let asm = .*/let asm = {|\$CONDA_OCAML_AS|}/' "$config_file"
  sed -i 's/^let c_compiler = .*/let c_compiler = {|\$CONDA_OCAML_CC|}/' "$config_file"
  sed -i 's/^let mkexe = .*/let mkexe = {|\$CONDA_OCAML_MKEXE|}/' "$config_file"
  sed -i 's/^let ar = .*/let ar = {|\$CONDA_OCAML_AR|}/' "$config_file"
  sed -i 's/^let ranlib = .*/let ranlib = {|\$CONDA_OCAML_RANLIB|}/' "$config_file"
  sed -i 's/^let mkdll = .*/let mkdll = {|\$CONDA_OCAML_MKDLL|}/' "$config_file"
  sed -i 's/^let mkmaindll = .*/let mkmaindll = {|\$CONDA_OCAML_MKDLL|}/' "$config_file"

  if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
    sed -i 's/^(let mk(?:main)?dll = .*_MKDLL)(.*)/\1 -undefined dynamic_lookup\2/' "$config_file"
  fi
else
  # Windows: Use %CONDA_OCAML_*% environment variable references
  sed -i 's/^let asm = .*/let asm = {|%CONDA_OCAML_AS%|}/' "$config_file"
  sed -i 's/^let c_compiler = .*/let c_compiler = {|%CONDA_OCAML_CC%|}/' "$config_file"
  sed -i 's/^let ar = .*/let ar = {|%CONDA_OCAML_AR%|}/' "$config_file"
  sed -i 's/^let ranlib = .*/let ranlib = {|%CONDA_OCAML_RANLIB%|}/' "$config_file"
fi

# Remove -L paths from bytecomp_c_libraries (embedded in ocamlc binary)
sed -i 's|-L[^ ]*||g' "$config_file"

# Clean up Makefile.config - remove embedded paths that cause issues
config_file="Makefile.config"
sed -i 's|-fdebug-prefix-map=[^ ]*||g' "${config_file}"
sed -i 's|-link\s+-L[^ ]*||g' "${config_file}"  # Remove flexlink's "-link -L..." patterns
sed -i 's|-L[^ ]*||g' "${config_file}"          # Remove standalone -L paths

# ============================================================================
# Build
# ============================================================================

echo "=== [3/4] Compiling native compiler ==="
make world.opt -j"${CPU_COUNT}" \
  > "${SRC_DIR}/_logs/world.log" 2>&1 || {
    echo "Build failed - last 100 lines of log:"
    tail -100 "${SRC_DIR}/_logs/world.log"
    exit 1
  }

# ============================================================================
# Tests (Optional)
# ============================================================================

if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
  echo "=== Running tests ==="
  make ocamltest -j "${CPU_COUNT}" \
    > "${SRC_DIR}/_logs/ocamltest.log" 2>&1 || {
      echo "ocamltest build failed:"
      cat "${SRC_DIR}/_logs/ocamltest.log"
    }
  make tests \
    > "${SRC_DIR}/_logs/tests.log" 2>&1 || {
      echo "Some tests failed:"
      grep -3 'tests failed' "${SRC_DIR}/_logs/tests.log" || true
    }
fi

# ============================================================================
# Install
# ============================================================================

echo "=== [4/4] Installing native compiler ==="
make install \
  > "${SRC_DIR}/_logs/install.log" 2>&1 || {
    cat "${SRC_DIR}/_logs/install.log"
    exit 1
  }

# Save build config for cross-compiler builds
cp runtime/build_config.h "${SRC_DIR}"

# Clean up for potential cross-compiler builds
make distclean

echo ""
echo "============================================================"
echo "Native OCaml installed successfully"
echo "============================================================"
echo "  Location: ${OCAML_INSTALL_PREFIX}"
echo "  Version:  $(${OCAML_INSTALL_PREFIX}/bin/ocamlopt -version 2>/dev/null || echo 'N/A')"
