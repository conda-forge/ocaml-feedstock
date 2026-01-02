#!/bin/bash
# Common functions shared across OCaml build scripts
# Source this file with: source "${RECIPE_DIR}/building/common-functions.sh"

# Logging wrapper - captures stdout/stderr to log files for debugging
run_logged() {
  local logname="$1"
  shift
  local logfile="${LOG_DIR}/${logname}.log"

  (IFS=' '; echo "Running: $*")
  if "$@" >> "${logfile}" 2>&1; then
    return 0
  else
    local rc=$?
    echo "FAILED (exit code ${rc}):"
    cat "${logfile}"
    return ${rc}
  fi
}

# Apply Makefile.cross and platform-specific patches
# Requires: NEEDS_DL variable to be set (1 = add -ldl)
apply_cross_patches() {
  cp "${RECIPE_DIR}"/building/Makefile.cross .
  patch -N -p0 < "${RECIPE_DIR}"/building/tmp_Makefile.patch || true

  # Fix dynlink "inconsistent assumptions" error:
  # Use otherlibrariesopt-cross target which calls dynlink-allopt with proper CAMLOPT/BEST_OCAMLOPT
  sed -i 's/otherlibrariesopt ocamltoolsopt/otherlibrariesopt-cross ocamltoolsopt/g' Makefile.cross
  sed -i 's/\$(MAKE) otherlibrariesopt /\$(MAKE) otherlibrariesopt-cross /g' Makefile.cross

  if [[ "${NEEDS_DL}" == "1" ]]; then
    sed -i 's/^\(BYTECCLIBS=.*\)$/\1 -ldl/' Makefile.config
  fi
}

# Helper: Find tool with full path (required for macOS to avoid GNU ar)
# Usage: find_tool <tool_name> [required]
# Returns: Full path to tool, or exits if required and not found
find_tool() {
  local tool_name="$1"
  local required="${2:-false}"

  local tool_path
  tool_path=$(find "${BUILD_PREFIX}"/bin "${PREFIX}"/bin -name "${tool_name}"* -type f -perm /111 2>/dev/null | head -1)

  if [[ -n "${tool_path}" ]]; then
    echo "${tool_path}"
  elif [[ "${required}" == "true" ]]; then
    echo "ERROR: ${tool_name} not found - required on macOS (GNU format incompatible with ld64)" >&2
    echo "Searched in: ${BUILD_PREFIX} ${PREFIX}" >&2
    exit 1
  else
    echo ""
  fi
}

# ==============================================================================
# Target Architecture Helpers
# ==============================================================================

# Get target ID from triplet (for CONDA_OCAML_<TARGET_ID>_* variables)
# Usage: get_target_id "aarch64-conda-linux-gnu" → "AARCH64"
get_target_id() {
  local target="$1"
  
  case "${target}" in
    aarch64-conda-linux-gnu) echo "AARCH64" ;;
    powerpc64le-conda-linux-gnu) echo "PPC64LE" ;;
    arm64-apple-darwin*) echo "ARM64" ;;
    x86_64-conda-linux-gnu) echo "X86_64" ;;
    x86_64-apple-darwin*) echo "X86_64" ;;
    *) echo "${target}" | cut -d'-' -f1 | tr '[:lower:]' '[:upper:]' ;;
  esac
}

# Get target architecture for OCaml ARCH variable
# Usage: get_target_arch "aarch64-conda-linux-gnu" → "arm64"
get_target_arch() {
  local target="$1"
  
  case "${target}" in
    aarch64-*|arm64-*) echo "arm64" ;;
    powerpc64le-*) echo "power" ;;
    x86_64-*|*-x86_64-*) echo "amd64" ;;
    *) echo "amd64" ;;  # default
  esac
}

# ==============================================================================
# macOS SDK Sysroot Detection
# ==============================================================================

# Find macOS ARM64 SDK sysroot
# Sets: ARM64_SYSROOT variable
# Usage: setup_macos_sysroot "arm64-apple-darwin20.0.0" [cross_cc]
setup_macos_sysroot() {
  local target="$1"
  local cross_cc="${2:-}"

  ARM64_SYSROOT=""

  # Try SDK search paths
  local try_sysroot
  for try_sysroot in /opt/conda-sdks/*"${ARM64_SDK:-MacOSX11.3}".sdk; do
    [[ -z "${try_sysroot}" ]] && continue
    if [[ -d "${try_sysroot}/usr/include" ]] || [[ -d "${try_sysroot}/System/Library" ]]; then
      ARM64_SYSROOT="${try_sysroot}"
      echo "     Found ARM64 SDK at: ${ARM64_SYSROOT}"
      break
    fi
  done

  # Fallback: query cross-compiler for default sysroot
  if [[ -z "${ARM64_SYSROOT}" ]] && [[ -n "${cross_cc}" ]]; then
    local clang_sysroot
    clang_sysroot=$("${cross_cc}" --print-sysroot 2>/dev/null || true)
    if [[ -n "${clang_sysroot}" ]] && [[ -d "${clang_sysroot}" ]]; then
      ARM64_SYSROOT="${clang_sysroot}"
      echo "     Found ARM64 SDK via clang --print-sysroot: ${ARM64_SYSROOT}"
    fi
  fi

  if [[ -z "${ARM64_SYSROOT}" ]]; then
    echo "     WARNING: No ARM64 SDK found in searched locations"
    echo "     Proceeding without explicit -isysroot (clang will use its default)"
  fi

  export ARM64_SYSROOT
}

# ==============================================================================
# Cross-Toolchain Setup
# ==============================================================================

# Setup cross-toolchain variables for a target
# Sets: CROSS_CC, CROSS_AS, CROSS_AR, CROSS_RANLIB, CROSS_NM, CROSS_STRIP, CROSS_LD
#       CROSS_CFLAGS, CROSS_LDFLAGS, CROSS_ASM, CROSS_MKDLL
# Usage: setup_cross_toolchain "aarch64-conda-linux-gnu"
setup_cross_toolchain() {
  local target="$1"
  
  if [[ "${target}" == "arm64-"* ]]; then
    # macOS: use LLVM tools consistently (GNU tools incompatible with ld64)
    CROSS_AR=$(find_tool "llvm-ar" true)
    CROSS_RANLIB=$(find_tool "llvm-ranlib" true)
    CROSS_NM=$(find_tool "llvm-nm" true)
    CROSS_STRIP=$(find_tool "llvm-strip" true)
    CROSS_LD=$(find_tool "ld.lld" true)

    CROSS_CC=$(find_tool "${target}-clang" true)
    CROSS_AS="${CROSS_CC}"
    CROSS_ASM="$(basename "${CROSS_CC}") -c"

    # Setup sysroot and flags
    setup_macos_sysroot "${target}" "${CROSS_CC}"
    if [[ -n "${ARM64_SYSROOT}" ]]; then
      CROSS_CFLAGS="-ftree-vectorize -fPIC -O3 -pipe -isystem ${BUILD_PREFIX}/include -isysroot ${ARM64_SYSROOT}"
    else
      CROSS_CFLAGS="-ftree-vectorize -fPIC -O3 -pipe -isystem ${BUILD_PREFIX}/include"
    fi
    CROSS_LDFLAGS="-fuse-ld=lld"
    CROSS_MKDLL="${CROSS_CC} -shared -Wl,-headerpad_max_install_names -undefined dynamic_lookup"
  else
    # Linux: use target-prefixed GNU tools
    CROSS_AR=$(find_tool "${target}-ar" true)
    CROSS_AS=$(find_tool "${target}-as" true)
    CROSS_CC=$(find_tool "${target}-gcc" true)
    CROSS_RANLIB=$(find_tool "${target}-ranlib" true)
    CROSS_NM=$(find_tool "${target}-nm" true)
    CROSS_STRIP=$(find_tool "${target}-strip" true)
    CROSS_LD=$(find_tool "${target}-ld" true)

    CROSS_ASM=$(basename "${CROSS_AS}")
    CROSS_CFLAGS="-ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe -isystem ${BUILD_PREFIX}/include"
    CROSS_LDFLAGS=""
    CROSS_MKDLL="${CROSS_CC} -shared"
  fi

  # Export all
  export CROSS_AR CROSS_AS CROSS_CC CROSS_RANLIB CROSS_NM CROSS_STRIP CROSS_LD
  export CROSS_CFLAGS CROSS_LDFLAGS CROSS_ASM CROSS_MKDLL
}

# ==============================================================================
# CONDA_OCAML_* Variable Helpers
# ==============================================================================

# Get CONDA_OCAML_* environment string for cross-compilation
# Returns a string suitable for prefixing make commands in a subshell
# Usage: $(get_cross_env_string) make crossopt ...
get_cross_env_string() {
  echo "CONDA_OCAML_CC='${CROSS_CC}' CONDA_OCAML_AS='${CROSS_AS}' CONDA_OCAML_AR='${CROSS_AR}' CONDA_OCAML_RANLIB='${CROSS_RANLIB}' CONDA_OCAML_MKDLL='${CROSS_MKDLL}'"
}

# Get CONDA_OCAML_* export commands for cross-compilation
# Returns export commands - use in subshell: ( eval "$(get_cross_env_exports)"; make ... )
get_cross_env_exports() {
  cat << EOF
export CONDA_OCAML_CC='${CROSS_CC}'
export CONDA_OCAML_AS='${CROSS_AS}'
export CONDA_OCAML_AR='${CROSS_AR}'
export CONDA_OCAML_RANLIB='${CROSS_RANLIB}'
export CONDA_OCAML_MKDLL='${CROSS_MKDLL}'
EOF
}

# Get default tool basenames for wrapper scripts
# Usage: get_cross_tool_defaults "aarch64-conda-linux-gnu"
# Sets: DEFAULT_CC, DEFAULT_AS, DEFAULT_AR, DEFAULT_RANLIB, DEFAULT_MKDLL
get_cross_tool_defaults() {
  local target="$1"

  DEFAULT_CC=$(basename "${CROSS_CC}")
  DEFAULT_AS=$(basename "${CROSS_AS}")
  DEFAULT_AR=$(basename "${CROSS_AR}")
  DEFAULT_RANLIB=$(basename "${CROSS_RANLIB}")

  if [[ "${target}" == "arm64-"* ]]; then
    DEFAULT_MKDLL="${DEFAULT_CC} -shared -undefined dynamic_lookup"
  else
    DEFAULT_MKDLL="${DEFAULT_CC} -shared"
  fi
}

# ==============================================================================
# Config Patching
# ==============================================================================

# Patch config.generated.ml to use CONDA_OCAML_* environment variables
# Usage: patch_config_generated_ml "utils/config.generated.ml" "aarch64-conda-linux-gnu" "/path/to/cross/lib/ocaml"
patch_config_generated_ml() {
  local config_file="$1"
  local target="$2"
  local cross_libdir="$3"
  
  local model
  model=$(get_target_model "${target}")

  if [[ "${target}" == "arm64-"* ]]; then
    sed -i 's#^let asm = .*#let asm = {|$CONDA_OCAML_CC -c|}#' "$config_file"
    sed -i 's#^let mkdll = .*#let mkdll = {|$CONDA_OCAML_MKDLL -fuse-ld=lld -Wl,-headerpad_max_install_names -undefined dynamic_lookup|}#' "$config_file"
    sed -i 's#^let mkexe = .*#let mkexe = {|$CONDA_OCAML_CC -fuse-ld=lld -Wl,-headerpad_max_install_names|}#' "$config_file"
  else
    sed -i 's#^let asm = .*#let asm = {|$CONDA_OCAML_AS|}#' "$config_file"
    sed -i 's#^let mkdll = .*#let mkdll = {|$CONDA_OCAML_MKDLL|}#' "$config_file"
    sed -i 's#^let mkexe = .*#let mkexe = {|$CONDA_OCAML_CC -Wl,-E|}#' "$config_file"
  fi

  sed -i 's#^let c_compiler = .*#let c_compiler = {|$CONDA_OCAML_CC|}#' "$config_file"
  sed -i 's#^let ar = .*#let ar = {|$CONDA_OCAML_AR|}#' "$config_file"
  sed -i 's#^let ranlib = .*#let ranlib = {|$CONDA_OCAML_RANLIB|}#' "$config_file"
  sed -i "s#^let standard_library_default = .*#let standard_library_default = {|${cross_libdir}|}#" "$config_file"

  # PowerPC model override
  [[ -n "${model}" ]] && sed -i "s#^let model = .*#let model = {|${model}|}#" "$config_file"
}

# ==============================================================================
# Wrapper Script Generation
# ==============================================================================

# Generate wrapper script for cross-compiler tool
# Requires: CROSS_* variables set (call setup_cross_toolchain first)
# Usage: generate_cross_wrapper "ocamlopt" "/path/to/install" "aarch64-conda-linux-gnu"
generate_cross_wrapper() {
  local tool="$1"
  local install_prefix="$2"
  local target="$3"
  local install_cross_prefix="$4"

  local target_id
  target_id=$(get_target_id "${target}")

  # Get default tool basenames (sets DEFAULT_CC, DEFAULT_AS, etc.)
  get_cross_tool_defaults "${target}"

  mkdir -p "${install_prefix}/bin"
  local wrapper_path="${install_prefix}/bin/${target}-${tool}"

  cat > "${wrapper_path}" << WRAPPER
#!/bin/sh
prefix="\$(cd "\$(dirname "\$0")/.." && pwd)"
export OCAMLLIB="\${prefix}/lib/ocaml-cross-compilers/${target}/lib/ocaml"
# Set CONDA_OCAML_* for cross-compilation (user can override via CONDA_OCAML_${target_id}_*)
export CONDA_OCAML_CC="\${CONDA_OCAML_${target_id}_CC:-${DEFAULT_CC}}"
export CONDA_OCAML_AS="\${CONDA_OCAML_${target_id}_AS:-${DEFAULT_AS}}"
export CONDA_OCAML_AR="\${CONDA_OCAML_${target_id}_AR:-${DEFAULT_AR}}"
export CONDA_OCAML_RANLIB="\${CONDA_OCAML_${target_id}_RANLIB:-${DEFAULT_RANLIB}}"
export CONDA_OCAML_MKDLL="\${CONDA_OCAML_${target_id}_MKDLL:-${DEFAULT_MKDLL}}"
exec "\${prefix}/lib/ocaml-cross-compilers/${target}/bin/${tool}.opt" "\$@"
WRAPPER
  chmod +x "${wrapper_path}"

  echo "     Created wrapper: ${wrapper_path}"
}
