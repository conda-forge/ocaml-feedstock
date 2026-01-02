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
#   NATIVE_ASM     - Assembler with preprocessing (CC -c)
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
source "${RECIPE_DIR}/building/non-unix-utilities.sh"

# ============================================================================
# Validate Environment
# ============================================================================

# Compiler activation should set CONDA_TOOLCHAIN_BUILD
if [[ -z "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
  echo "ERROR: CONDA_TOOLCHAIN_BUILD not set (compiler activation failed?)"
  exit 1
fi

# ============================================================================
# Native Toolchain Setup (NATIVE_*)
# ============================================================================

echo ""
echo "============================================================"
echo "Native OCaml build configuration"
echo "============================================================"
echo "  Platform:      ${target_platform}"
echo "  Install:       ${OCAML_INSTALL_PREFIX}"

# Native toolchain - simplified basenames (hardcoded in binaries)
# These use CONDA_TOOLCHAIN_BUILD which is set by compiler activation
NATIVE_AR=$(find_tool "${CONDA_TOOLCHAIN_BUILD}-ar${EXE}" true)
NATIVE_AS=$(find_tool "${CONDA_TOOLCHAIN_BUILD}-as${EXE}" true)
NATIVE_LD=$(find_tool "${CONDA_TOOLCHAIN_BUILD}-ld${EXE}" true)
NATIVE_RANLIB=$(find_tool "${CONDA_TOOLCHAIN_BUILD}-ranlib${EXE}" true)

NATIVE_CC="${CC_FOR_BUILD}"
NATIVE_ASM=$(basename "${NATIVE_AS}")

# Platform-specific overrides
if [[ "${target_platform}" == "osx"* ]]; then
  # macOS: clang integrated assembler - MUST use LLVM ar/ranlib - GNU ar format incompatible with ld64
  NATIVE_AS="${NATIVE_CC}"
  NATIVE_ASM="$(basename "${NATIVE_CC}") -c"
  
  NATIVE_AR=$(find_tool "llvm-ar" true)
  NATIVE_LD=$(find_tool "ld.lld" true)
  NATIVE_RANLIB=$(find_tool "llvm-ranlib" true)
  
  # Needed for freshly built ocaml to find zstd
  export DYLD_LIBRARY_PATH="${PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
  export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld -Wl,-headerpad_max_install_names"
elif [[ "${target_platform}" != "linux"* ]]; then
  [[ ${OCAML_INSTALL_PREFIX} != *"Library"* ]] && OCAML_INSTALL_PREFIX="${OCAML_INSTALL_PREFIX}"/Library
  echo "  Install:       ${OCAML_INSTALL_PREFIX}  <- Non-unix ..."

  NATIVE_CC=$(find_tool "x86_64-w64-mingw32-gcc" true)
  NATIVE_WINDRES=$(find_tool "x86_64-w64-mingw32-windres" true)
  [[ ! -f "${PREFIX}/Library/bin/windres.exe" ]] && cp "${NATIVE_WINDRES}" "${PREFIX}/Library/bin/windres.exe"

  # Set UTF-8 codepage
  export PYTHONUTF8=1
  # Needed find zstd
  export LDFLAGS="-L${_PREFIX_}/Library/lib ${LDFLAGS:-}"
fi

echo "  NATIVE_AR:     ${NATIVE_AR}"
echo "  NATIVE_AS:     ${NATIVE_AS}"
echo "  NATIVE_ASM:    ${NATIVE_ASM}"
echo "  NATIVE_CC:     ${NATIVE_CC}"
echo "  NATIVE_LD:     ${NATIVE_LD}"
echo "  NATIVE_RANLIB: ${NATIVE_RANLIB}"

# ============================================================================
# CONDA_OCAML_* Variables (Runtime Configuration)
# ============================================================================

# These are embedded in binaries and expanded at runtime
# Users can override via environment variables
export CONDA_OCAML_AR=$(basename "${NATIVE_AR}")
export CONDA_OCAML_CC=$(basename "${NATIVE_CC}")
export CONDA_OCAML_RANLIB=$(basename "${NATIVE_RANLIB}")
# Special case, already a basename
export CONDA_OCAML_AS="${NATIVE_ASM}"

case "${target_platform}" in
  linux*)
    export CONDA_OCAML_MKEXE="${CONDA_OCAML_CC} -Wl,-E"
    export CONDA_OCAML_MKDLL="${CONDA_OCAML_CC} -shared"
    ;;
  osx*)
    export CONDA_OCAML_MKEXE="${CONDA_OCAML_CC} -fuse-ld=lld -Wl,-headerpad_max_install_names"
    export CONDA_OCAML_MKDLL="${CONDA_OCAML_CC} -shared -fuse-ld=lld -Wl,-headerpad_max_install_names -undefined dynamic_lookup"
    ;;
esac

# ============================================================================
# Configure Arguments
# ============================================================================

#  --enable-native-toplevel
CONFIG_ARGS=(
  --enable-frame-pointers
  --enable-installing-source-artifacts
  --enable-installing-bytecode-programs
  --enable-shared
  --disable-static
  --mandir="${OCAML_INSTALL_PREFIX}"/share/man
  PKG_CONFIG=false
  -prefix "${OCAML_INSTALL_PREFIX}"
  
  # This is needed to preset the intall path in binaries and facilitate CONDA reelocation
  --with-target-bindir="${PREFIX}"/bin
)

# Enable ocamltest if running tests
if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
  CONFIG_ARGS+=(--enable-ocamltest)
else
  CONFIG_ARGS+=(--disable-ocamltest)
fi

# Add toolchain to configure args
CONFIG_ARGS+=(
  AR="${NATIVE_AR}"
  AS="${NATIVE_AS}"
  CC="${NATIVE_CC}"
  LD="${NATIVE_LD}"
  RANLIB="${NATIVE_RANLIB}"
)

if [[ "${target_platform}" != "linux"* ]] && [[ "${target_platform}" != "osx"* ]]; then
  CONFIG_ARGS+=(--with-target-bindir="${PREFIX}"/bin)
else
  CONFIG_ARGS+=(
    --with-flexdll
    --with-gnu-ld
    --with-target-bindir="${PREFIX}"/Library/bin
    WINDOWS_UNICODE_MODE=compatible
    WINDRES="${NATIVE_WINDRES}"
  )
fi

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

# ============================================================================
# Patch config.generated.ml and Makefil.config
# ============================================================================

echo "=== [2/4] Patching config for CONDA_OCAML_* variables ==="

config_file="utils/config.generated.ml"
# Remove -L paths from bytecomp_c_libraries (embedded in ocamlc binary)
sed -i 's#-L[^ ]*##g' "$config_file"
if [[ "${target_platform}" == "linux"* ]] || [[ "${target_platform}" == "osx"* ]]; then
  # Unix: Use $CONDA_OCAML_* environment variable references
  sed -i 's/^let asm = .*/let asm = {|\$CONDA_OCAML_AS|}/' "$config_file"
  [[ "${target_platform}" == "osx"* ]] && sed -i 's/^let asm = .*/let asm = {|\$CONDA_OCAML_CC -c|}/' "$config_file"

  sed -i 's/^let ar = .*/let ar = {|\$CONDA_OCAML_AR|}/' "$config_file"
  sed -i 's/^let c_compiler = .*/let c_compiler = {|\$CONDA_OCAML_CC|}/' "$config_file"
  sed -i 's/^let ranlib = .*/let ranlib = {|\$CONDA_OCAML_RANLIB|}/' "$config_file"
  
  sed -i 's/^let mkexe = .*/let mkexe = {|\$CONDA_OCAML_MKEXE|}/' "$config_file"
  sed -i 's/^let mkdll = .*/let mkdll = {|\$CONDA_OCAML_MKDLL|}/' "$config_file"
  sed -i 's/^let mkmaindll = .*/let mkmaindll = {|\$CONDA_OCAML_MKDLL|}/' "$config_file"
else
  # non_unix: Use %CONDA_OCAML_*% environment variable references
  sed -i 's/^let asm = .*/let asm = {|%CONDA_OCAML_ASM%|}/' "$config_file"
  sed -i 's/^let c_compiler = .*/let c_compiler = {|%CONDA_OCAML_CC%|}/' "$config_file"
  sed -i 's/^let ar = .*/let ar = {|%CONDA_OCAML_AR%|}/' "$config_file"
  sed -i 's/^let ranlib = .*/let ranlib = {|%CONDA_OCAML_RANLIB%|}/' "$config_file"
fi

# Clean up Makefile.config - remove embedded paths that cause issues
config_file="Makefile.config"
sed -i  's#-fdebug-prefix-map=[^ ]*##g' "${config_file}"
sed -i  's#-link\s+-L[^ ]*##g' "${config_file}"                             # Remove flexlink's "-link -L..." patterns
sed -i  's#-L[^ ]*##g' "${config_file}"                                     # Remove standalone -L paths
# These would be found in BUILD_PREFIX and fail relocation
sed -Ei 's#^(CC|CPP|ASM|ASPP|STRIP)=/.*/([^/]+)$#\1=\2#' "${config_file}"   # Remove prepended binaries path (could be BUILD_PREFIX non-relocatable)

if [[ "${target_platform}" == "osx"* ]]; then
  # macOS: Add -headerpad_max_install_names to ALL linker flags
  sed -i 's|^OC_LDFLAGS=\(.*\)|OC_LDFLAGS=\1 -Wl,-L${PREFIX}/lib -Wl,-headerpad_max_install_names|' "${config_file}"
  sed -i 's|^NATIVECCLINKOPTS=\(.*\)|NATIVECCLINKOPTS=\1 -Wl,-L${PREFIX}/lib -Wl,-headerpad_max_install_names|' "${config_file}"
elif [[ "${target_platform}" != "linux"* ]]; then
  sed -i 's/^TOOLCHAIN.*/TOOLCHAIN=mingw64/' "$config_file"
  sed -i 's/^FLEXDLL_CHAIN.*/FLEXDLL_CHAIN=mingw64/' "$config_file"
  sed -i 's/$(addprefix -link ,$(OC_LDFLAGS))//g' "$config_file"
  sed -i 's/$(addprefix -link ,$(OC_DLL_LDFLAGS))//g' "$config_file"
fi

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
