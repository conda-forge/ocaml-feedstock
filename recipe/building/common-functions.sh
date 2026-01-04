# Common functions shared across OCaml build scripts
# Source this file with: source "${RECIPE_DIR}/building/common-functions.sh"

# Logging wrapper - captures stdout/stderr to log files for debugging
run_logged_() {
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

run_logged() {
  local logname="$1"
  shift
  local logfile="${LOG_DIR}/${logname}.log"
  local indent="    "

  local cmd="$1"
  shift
  
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    echo "${indent}$ $cmd $*"
  else
    # Show command name + count of args
    local nargs=$#
    # Extract just the key names from KEY=value args
    local keys=""
    for arg in "$@"; do
      [[ "$arg" == *"="* ]] && keys+=" ${arg%%=*}"
      [[ "$arg" != *"="* ]] && keys+=" ${arg}"
    done
    echo "${indent}$ ${cmd##*/} [${nargs} args:${keys:- ...}]"
  fi

  if "$cmd" "$@" >> "${logfile}" 2>&1; then
    return 0
  else
    local rc=$?
    echo "${indent} FAILED (${rc}) - see ${logfile##*/}"
    tail -15 "${logfile}" | sed "s/^/${indent} /"
    return ${rc}
  fi
}

# Apply Makefile.cross and platform-specific patches
# Requires: NEEDS_DL variable to be set (1 = add -ldl)
apply_cross_patches() {
  cp "${RECIPE_DIR}"/building/Makefile.cross .
  patch -N -p0 < "${RECIPE_DIR}"/building/tmp_Makefile.patch > /dev/null 2>&1 || true

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
  if [[ "${build_platform:-${target_platform}}" == "linux-"* ]] || [[ "${build_platform:-${target_platform}}" == "osx-"* ]]; then
    tool_path=$(find \
                  "${BUILD_PREFIX}"/bin \
                  "${PREFIX}"/bin \
                  \( -name "${tool_name}" -o -name "${tool_name}-[0-9]*" \) \
                  -type f -perm /111 2>/dev/null | head -1)
  else
    tool_path=$(find \
                  "${_BUILD_PREFIX_}"/Library/bin \
                  "${_PREFIX_}"/Library/bin \
                  "${_BUILD_PREFIX_}"/bin \
                  "${_PREFIX_}"/bin \
                  \( -name "${tool_name}" -o -name "${tool_name}.exe" \) \
                  -type f -perm /111 2>/dev/null | head -1)
  fi

  if [[ -n "${tool_path}" ]]; then
    echo "${tool_path}"
  elif [[ "${required}" == "true" ]]; then
    echo "ERROR: ${tool_name} not found" >&2
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
    x86_64-conda-linux-gnu|x86_64-apple-darwin*) echo "X86_64" ;;
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

# Get target architecture for OCaml ARCH variable
# Usage: get_target_arch "aarch64-conda-linux-gnu" → "arm64"
get_target_platform() {
  local target="$1"
  
  case "${target}" in
    aarch64-*) echo "linux-aarch64" ;;
    arm64-*) echo "osx-arm64" ;;
    powerpc64le-*) echo "linux-ppc64le" ;;
    x86_64-conda-linux-gnu) echo "linux-64" ;;
    x86_64-apple-darwin*) echo "osx-64" ;;
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
  
  export ARM64_SYSROOT
}

# ==============================================================================
# CFLAGS and LDFLAGS
# ==============================================================================

# Get native CFLAGS/LDFLAGS for the current platform
# Sets: NATIVE_CFLAGS, NATIVE_LDFLAGS
# Usage: setup_native_flags
setup_cflags_ldflags() {
  local name="${1}"
  local native="${2:-${build_platform:-NOTSET}}"
  local target="${3:-${target_platform}}"

  [[ "${native}" != "linux-"* ]] && [[ "${native}" != "osx-"* ]] && native="nonunix${native#*-}"
  [[ "${target}" != "linux-"* ]] && [[ "${target}" != "osx-"* ]] && target="nonunix${target#*-}"
  
  case "${name}_${native}_${target}" in
    NATIVE_osx-64_osx-64|NATIVE_linux-64_linux-64|NATIVE_nonunix-64_nonunix-64)
      # Native build: use environment CFLAGS (set by conda-build for this platform)
      export "${name}_CFLAGS=${CFLAGS}"
      export "${name}_LDFLAGS=${LDFLAGS}"
      ;;
    CROSS_linux-64_linux-aarch64|CROSS_linux-64_linux-ppc64le|CROSS_osx-64_osx-arm64)
      # Cross-compiling FOR aarch64/ppc64le
      if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
        # Cross-platform CI: conda sets proper target CFLAGS
        export "${name}_CFLAGS=${CFLAGS}"
        export "${name}_LDFLAGS=${LDFLAGS}"
      elif [[ "${target}" == "arm-64" ]]; then
        # Native build creating cross-compilers: use generic ARM64 flags
        setup_macos_sysroot
        export "${name}_CFLAGS=-ftree-vectorize -fPIC -O2 -pipe -isystem ${PREFIX}/include${ARM64_SYSROOT:+ -isysroot ${ARM64_SYSROOT}}"
        export "${name}_LDFLAGS=-fuse-ld=lld -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
      else
        # Native build creating cross-compilers: use generic flags (no x86_64 -march/-mtune)
        export "${name}_CFLAGS=-ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -isystem ${PREFIX}/include"
        export "${name}_LDFLAGS=-Wl,-O2 -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -L${PREFIX}/lib"
      fi
      ;;
    NATIVE_osx-64_osx-arm64)
      # Native OCaml build during cross-platform CI (runs on x86_64 BUILD machine)
      export "${name}_CFLAGS=-march=core2 -mtune=haswell -mssse3 -ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -isystem ${BUILD_PREFIX}/include"
      export "${name}_LDFLAGS=-fuse-ld=lld -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
      ;;
    NATIVE_linux-64_linux-aarch64|NATIVE_linux-64_linux-ppc64le)
      # Native OCaml build during cross-platform CI (runs on x86_64 BUILD machine)
      export "${name}_CFLAGS=-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -isystem ${BUILD_PREFIX}/include"
      export "${name}_LDFLAGS=-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections -Wl,-rpath,${BUILD_PREFIX}/lib -Wl,-rpath-link,${BUILD_PREFIX}/lib -L${BUILD_PREFIX}/lib"
      ;;
    CROSS_linux-64_linux-64|CROSS_osx-64_osx-64|CROSS_nonunix-*|*)
      echo "ERROR: setup_cflags_ldflags used with incorrect arguments"
      echo "   name:            ${name}"
      echo "   native platform: ${native}"
      echo "   target platform: ${target}"
      exit 1
      ;;
  esac
}

# ==============================================================================
# Build-Toolchain Setup
# ==============================================================================

# Setup BUILD-toolchain variables for a target
# Sets: BUILD_CC, BUILD_AS, BUILD_AR, BUILD_RANLIB, BUILD_NM, BUILD_STRIP, BUILD_LD
#       BUILD_CFLAGS, BUILD_LDFLAGS, BUILD_ASM, BUILD_MKDLL, BUILD_MKEXE
# Usage: setup_native_toolchain "aarch64-conda-linux-gnu"
setup_toolchain() {
  local name="${1}"
  local target="${2}"

  case "${target}" in
    *-apple-*)
       # macOS: use LLVM tools consistently (GNU tools incompatible with ld64)
       _AR=$(find_tool "llvm-ar" true)
       _RANLIB=$(find_tool "llvm-ranlib" true)
       _NM=$(find_tool "llvm-nm" true)
       _STRIP=$(find_tool "llvm-strip" true)
       _LD=$(find_tool "ld.lld" true)

       _CC=$(find_tool "${target}-clang" true)
       _AS="${_CC}"
       _ASM="$(basename "${_CC}") -c"

       _MKDLL="${_CC} -shared -Wl,-headerpad_max_install_names -undefined dynamic_lookup"
       _MKEXE="${_CC} -fuse-ld=lld -Wl,-headerpad_max_install_names"
      ;;
    *-linux-*)
       _AR=$(find_tool "${target}-ar" true)
       _AS=$(find_tool "${target}-as" true)
       _CC=$(find_tool "${target}-gcc" true)
       _RANLIB=$(find_tool "${target}-ranlib" true)
       _NM=$(find_tool "${target}-nm" true)
       _STRIP=$(find_tool "${target}-strip" true)
       _LD=$(find_tool "${target}-ld" true)

       _ASM=$(basename "${_AS}")
       _MKDLL="${_CC} -shared"
       # -Wl,-E exports symbols for dlopen (required by ocamlnat)
       _MKEXE="${_CC} -Wl,-E"
      ;;
    *)
      echo "ERROR: setup_toolchain used with unsupported target: ${target}"
      exit 1
      ;;
  esac

  # Export all
  export "${name}_AR=${_AR}" "${name}_AS=${_AS}" "${name}_CC=${_CC}" "${name}_RANLIB=${_RANLIB}"
  export "${name}_NM=${_NM}" "${name}_STRIP=${_STRIP}" "${name}_LD=${_LD}"
  export "${name}_ASM=${_ASM}" "${name}_MKDLL=${_MKDLL}" "${name}_MKEXE=${_MKEXE}"
}

# ==============================================================================
# CONDA_OCAML_* Variable Helpers
# ==============================================================================

# Get CONDA_OCAML_* environment string for cross-compilation
# Returns a string suitable for prefixing make commands in a subshell
# Usage: $(get_cross_env_string) make crossopt ...
get_cross_env_string() {
  echo "CONDA_OCAML_CC='${CROSS_CC}' CONDA_OCAML_AS='${CROSS_AS}' CONDA_OCAML_AR='${CROSS_AR}' CONDA_OCAML_RANLIB='${CROSS_RANLIB}' CONDA_OCAML_MKDLL='${CROSS_MKDLL}' CONDA_OCAML_MKEXE='${CROSS_MKEXE}'"
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
export CONDA_OCAML_MKEXE='${CROSS_MKEXE}'
EOF
}

# Get default tool basenames for wrapper scripts
# Usage: get_cross_tool_defaults "aarch64-conda-linux-gnu"
# Sets: DEFAULT_CC, DEFAULT_AS, DEFAULT_AR, DEFAULT_RANLIB, DEFAULT_MKDLL, DEFAULT_MKEXE
get_cross_tool_defaults() {
  local target="$1"

  DEFAULT_CC=$(basename "${CROSS_CC}")
  DEFAULT_AS=$(basename "${CROSS_AS}")
  DEFAULT_AR=$(basename "${CROSS_AR}")
  DEFAULT_RANLIB=$(basename "${CROSS_RANLIB}")

  if [[ "${target}" == "arm64-"* ]]; then
    # macOS: use lld linker and headerpad for install_name_tool compatibility
    DEFAULT_MKDLL="${DEFAULT_CC} -shared -undefined dynamic_lookup"
    DEFAULT_MKEXE="${DEFAULT_CC} -fuse-ld=lld -Wl,-headerpad_max_install_names"
  else
    # Linux: -Wl,-E exports symbols for dlopen (required by ocamlnat)
    DEFAULT_MKDLL="${DEFAULT_CC} -shared"
    DEFAULT_MKEXE="${DEFAULT_CC} -Wl,-E -ldl"
  fi
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
export CONDA_OCAML_MKEXE="\${CONDA_OCAML_${target_id}_MKEXE:-${DEFAULT_MKEXE}}"
exec "\${prefix}/lib/ocaml-cross-compilers/${target}/bin/${tool}.opt" "\$@"
WRAPPER
  chmod +x "${wrapper_path}"

  echo "     Created wrapper: ${wrapper_path}"
}
