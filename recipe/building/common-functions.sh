# Common functions shared across OCaml build scripts
# Source this file with: source "${RECIPE_DIR}/building/common-functions.sh"

# =============================================================================
# CRITICAL: macOS DYLD_LIBRARY_PATH cleanup
# =============================================================================
# conda's libiconv can override /usr/lib/libiconv.2.dylib but lacks symbols
# (_iconv_close, _iconv_open, _iconv) that system tools depend on.
# This causes segfaults when running sed, make, or any tool that loads libcups.
# Unsetting DYLD_LIBRARY_PATH at the start prevents this - scripts should use
# DYLD_FALLBACK_LIBRARY_PATH instead (searched AFTER system paths).
if [[ "$(uname 2>/dev/null)" == "Darwin" ]]; then
  unset DYLD_LIBRARY_PATH 2>/dev/null || true
fi

# Nagging unix test
is_unix() {
  [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]
}

is_build_unix() {
  [[ "${build_platform:-${target_platform}}" == "linux-"* || "${build_platform:-${target_platform}}" == "osx-"* ]]
}

# Logging wrapper - captures stdout/stderr to log files for debugging
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
    tail -100 "${logfile}" | sed "s/^/${indent} /"
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

  if [[ "${NEEDS_DL:-0}" == "1" ]]; then
    # glibc 2.17 requires explicit -ldl for dlopen/dlclose/dlsym
    # Patch both BYTECCLIBS (bytecode runtime) and NATIVECCLIBS (native runtime)
    sed -i 's/^\(BYTECCLIBS=.*\)$/\1 -ldl/' Makefile.config
    sed -i 's/^\(NATIVECCLIBS=.*\)$/\1 -ldl/' Makefile.config
  fi
}

# Helper: Find tool with full path (required for macOS to avoid GNU ar)
# Usage: find_tool <tool_name> [required]
# Returns: Full path to tool, or exits if required and not found
find_tool() {
  local tool_name="$1"
  local required="${2:-false}"

  local tool_path
  if is_build_unix; then
    tool_path=$(find \
                  "${BUILD_PREFIX}"/bin \
                  "${PREFIX}"/bin \
                  \( -name "${tool_name}" -o -name "${tool_name}-[0-9]*" \) \
                  \( -type f -o -type l \) \
                  -perm /111 \
                  2>/dev/null | head -1)
  else
    tool_path=$(find \
                  "${_BUILD_PREFIX_}"/Library/bin \
                  "${_PREFIX_}"/Library/bin \
                  "${_BUILD_PREFIX_}"/bin \
                  "${_PREFIX_}"/bin \
                  \( -name "${tool_name}" -o -name "${tool_name}.exe" \) \
                  \( -type f -o -type l \) \
                  -perm /111 2>/dev/null | head -1)
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

decompress_xz() {
  local input="$1"
  local output_dir="$2"

  python -c "
import lzma, tarfile
with lzma.open('${input}') as xz:
    with tarfile.open(fileobj=xz) as tar:
        tar.extractall('${output_dir}')
"
}

# Find macOS ARM64 SDK sysroot
# Sets: ARM64_SYSROOT variable
# Usage: setup_macos_sysroot "arm64-apple-darwin20.0.0" [cross_cc]
setup_macos_sysroot() {
  ARM64_SYSROOT=""
  local SDK_DIR="/opt/conda-sdks"

  # Check existing
  for sdk in "${SDK_DIR}"/MacOSX11.[0-9]+.sdk; do
    [[ -d "${sdk}" ]] && ARM64_SYSROOT="${sdk}" && break
  done

  # Download if missing
  if [[ -z "${ARM64_SYSROOT}" ]]; then
    SDK_DIR="${SRC_DIR}/conda-sdks" && mkdir -p "${SDK_DIR}" 2>/dev/null
  
    echo "     Downloading MacOSX11.sdk..."
    local url="https://github.com/phracker/MacOSX-SDKs/releases/download/11.3/MacOSX11.0.sdk.tar.xz"
    curl -L --output "${SDK_DIR}"/MacOSX11.0.sdk.tar.xz "${url}"
    echo "d3feee3ef9c6016b526e1901013f264467bb927865a03422a9cb925991cc9783  ${SDK_DIR}/MacOSX11.0.sdk.tar.xz" | shasum -a 256 -c

    echo "     Extracting MacOSX11.0.sdk..."
    python3 << PYEOF
import lzma
import tarfile
import os

tarball = "${SDK_DIR}/MacOSX11.0.sdk.tar.xz"
outdir = "${SDK_DIR}"

with lzma.open(tarball, 'rb') as f:
    with tarfile.open(fileobj=f, mode='r:') as tar:
        tar.extractall(path=outdir, filter='data')

print(f"Extracted to {outdir}")
PYEOF

    if [[ $? -ne 0 ]]; then
      echo "ERROR: Extraction failed"
      return 1
    fi

    ARM64_SYSROOT="${SDK_DIR}/MacOSX11.0.sdk"
  fi

  echo "     Using ARM64 SDK: ${ARM64_SYSROOT}"
  export ARM64_SYSROOT
}

# ==============================================================================
# CFLAGS and LDFLAGS Sanitization (Portable - can be used in other recipes)
# ==============================================================================

# Sanitize compiler flags for cross-compilation
# Removes duplicates and architecture-inappropriate flags
# Usage: sanitize_cross_cflags "aarch64" "${CFLAGS}"
# Usage: sanitize_cross_ldflags "${LDFLAGS}"
#
# Problem: conda-build cross-compilation sometimes produces CFLAGS like:
#   -march=nocona -mtune=haswell ... -march=armv8-a -mtune=cortex-a72 ...
# This causes errors when the cross-compiler sees incompatible arch flags.
#
# This function:
#   1. Removes x86-specific flags when targeting ARM/PPC
#   2. Removes ARM-specific flags when targeting x86
#   3. Removes duplicate flags while preserving order
#   4. Keeps the LAST occurrence of conflicting flags (target-specific)

# Architecture-specific flags to filter
_X86_ARCH_FLAGS="-march=nocona|-march=core2|-march=haswell|-march=skylake|-march=x86-64"
_X86_TUNE_FLAGS="-mtune=nocona|-mtune=core2|-mtune=haswell|-mtune=skylake|-mtune=generic"
_X86_FEATURE_FLAGS="-mssse3|-msse4|-msse4.1|-msse4.2|-mavx|-mavx2|-mfma"

_ARM_ARCH_FLAGS="-march=armv8-a|-march=armv8.1-a|-march=armv8.2-a|-march=native"
_ARM_TUNE_FLAGS="-mtune=cortex-a53|-mtune=cortex-a72|-mtune=neoverse-n1|-mtune=native"

_PPC_ARCH_FLAGS="-mcpu=power8|-mcpu=power9|-mcpu=power10"
_PPC_TUNE_FLAGS="-mtune=power8|-mtune=power9|-mtune=power10"

sanitize_cross_cflags() {
  local target_arch="$1"
  shift
  local flags="$*"

  # Determine which architecture flags to remove based on target
  local remove_pattern=""
  case "${target_arch}" in
    aarch64|arm64|armv8*)
      # Targeting ARM: remove x86 and PPC flags
      remove_pattern="${_X86_ARCH_FLAGS}|${_X86_TUNE_FLAGS}|${_X86_FEATURE_FLAGS}|${_PPC_ARCH_FLAGS}|${_PPC_TUNE_FLAGS}"
      ;;
    powerpc64le|ppc64le|power*)
      # Targeting PPC: remove x86 and ARM flags
      remove_pattern="${_X86_ARCH_FLAGS}|${_X86_TUNE_FLAGS}|${_X86_FEATURE_FLAGS}|${_ARM_ARCH_FLAGS}|${_ARM_TUNE_FLAGS}"
      ;;
    x86_64|amd64|i686)
      # Targeting x86: remove ARM and PPC flags
      remove_pattern="${_ARM_ARCH_FLAGS}|${_ARM_TUNE_FLAGS}|${_PPC_ARCH_FLAGS}|${_PPC_TUNE_FLAGS}"
      ;;
    *)
      # Unknown target: remove all architecture-specific flags to be safe
      remove_pattern="${_X86_ARCH_FLAGS}|${_X86_TUNE_FLAGS}|${_X86_FEATURE_FLAGS}|${_ARM_ARCH_FLAGS}|${_ARM_TUNE_FLAGS}|${_PPC_ARCH_FLAGS}|${_PPC_TUNE_FLAGS}"
      ;;
  esac

  # Process flags: remove inappropriate arch flags and deduplicate
  local result=""
  local seen=""

  for flag in ${flags}; do
    # Skip if this flag matches the remove pattern
    # Use printf instead of echo to handle flags starting with '-' safely
    if printf '%s\n' "${flag}" | grep -qE "^(${remove_pattern})$"; then
      continue
    fi

    # Skip duplicates (keep first occurrence for most flags)
    if printf ' %s ' "${seen}" | grep -qF " ${flag} "; then
      continue
    fi

    seen="${seen} ${flag}"
    result="${result:+${result} }${flag}"
  done

  echo "${result}"
}

sanitize_cross_ldflags() {
  local flags="$*"

  # LDFLAGS typically don't have arch-specific flags, but may have duplicates
  # Process flags: deduplicate while preserving order
  local result=""
  local seen=""

  for flag in ${flags}; do
    # Skip duplicates
    if echo " ${seen} " | grep -qF " ${flag} "; then
      continue
    fi

    seen="${seen} ${flag}"
    result="${result:+${result} }${flag}"
  done

  echo "${result}"
}

# Convenience function: sanitize both CFLAGS and LDFLAGS and export them
# Usage: sanitize_and_export_cross_flags "aarch64"
# Modifies: CFLAGS, LDFLAGS environment variables
sanitize_and_export_cross_flags() {
  local target_arch="$1"

  if [[ -n "${CFLAGS:-}" ]]; then
    CFLAGS=$(sanitize_cross_cflags "${target_arch}" "${CFLAGS}")
    export CFLAGS
  fi

  if [[ -n "${LDFLAGS:-}" ]]; then
    LDFLAGS=$(sanitize_cross_ldflags "${LDFLAGS}")
    export LDFLAGS
  fi
}

# Get target architecture from conda target triplet or platform
# Usage: get_arch_from_triplet "aarch64-conda-linux-gnu" → "aarch64"
# Usage: get_arch_from_platform "linux-aarch64" → "aarch64"
get_arch_for_sanitization() {
  local input="$1"

  case "${input}" in
    aarch64-*|linux-aarch64|osx-arm64|arm64-*)
      echo "aarch64"
      ;;
    powerpc64le-*|linux-ppc64le|ppc64le-*)
      echo "powerpc64le"
      ;;
    x86_64-*|linux-64|osx-64)
      echo "x86_64"
      ;;
    *)
      # Extract first component as fallback
      echo "${input%%-*}"
      ;;
  esac
}

# ==============================================================================
# CFLAGS and LDFLAGS Setup
# ==============================================================================

# Get native CFLAGS/LDFLAGS for the current platform
# Sets: NATIVE_CFLAGS, NATIVE_LDFLAGS
# Usage: setup_native_flags
setup_cflags_ldflags() {
  local name="${1}"
  local native="${2:-${build_platform:-NOTSET}}"
  local target="${3:-${target_platform}}"

  [[ "${native}" != "linux-"* ]] && [[ "${native}" != "osx-"* ]] && native="nonunix-${native#*-}"
  [[ "${target}" != "linux-"* ]] && [[ "${target}" != "osx-"* ]] && target="nonunix-${target#*-}"
  
  case "${name}_${native}_${target}" in
    NATIVE_osx-64_osx-64|NATIVE_linux-64_linux-64|NATIVE_nonunix-64_nonunix-64)
      # Native build: use environment CFLAGS (set by conda-build for this platform)
      export "${name}_CFLAGS=${CFLAGS:-}"
      export "${name}_LDFLAGS=${LDFLAGS:-}"
      ;;
    CROSS_linux-64_linux-aarch64|CROSS_linux-64_linux-ppc64le)
      # Cross-compiling FOR Linux aarch64/ppc64le
      # ALWAYS use clean generic flags - conda-build's CFLAGS is often corrupted with
      # mixed build/target flags that cause -march=nocona on aarch64 cross-compiler
      export "${name}_CFLAGS=-ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -isystem ${PREFIX}/include"
      export "${name}_LDFLAGS=-Wl,-O2 -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -L${PREFIX}/lib"
      ;;
    CROSS_osx-64_osx-arm64)
      # Cross-compiling FOR macOS ARM64 (on osx-64)
      # ALWAYS use clean generic flags - conda-build's CFLAGS is often corrupted
      # CRITICAL: Both CFLAGS and LDFLAGS need -isysroot for the ARM64 SDK!
      setup_macos_sysroot
      export "${name}_CFLAGS=-ftree-vectorize -fPIC -O2 -pipe -isystem ${PREFIX}/include${ARM64_SYSROOT:+ -isysroot ${ARM64_SYSROOT}}"
      export "${name}_LDFLAGS=-fuse-ld=lld -L${PREFIX}/lib -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs${ARM64_SYSROOT:+ -isysroot ${ARM64_SYSROOT}}"
      ;;
    NATIVE_osx-64_osx-arm64)
      # Native OCaml build during cross-platform CI (runs on x86_64 BUILD machine)
      # MUST include -L${BUILD_PREFIX}/lib for zstd - PREFIX has ARM64 libs!
      # CRITICAL: Also strip -L$PREFIX from global LDFLAGS (conda-build sets it with ARM64 paths)
      export LDFLAGS="-L${BUILD_PREFIX}/lib ${LDFLAGS//-L${PREFIX}\/lib/}"
      export "${name}_CFLAGS=-march=core2 -mtune=haswell -mssse3 -ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -isystem ${BUILD_PREFIX}/include"
      export "${name}_LDFLAGS=-fuse-ld=lld -L${BUILD_PREFIX}/lib -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
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
       _CC=$(find_tool "${target}-clang" true)
       _LD=$(find_tool "ld.lld" true)
       _NM=$(find_tool "llvm-nm" true)
       _RANLIB=$(find_tool "llvm-ranlib" true)
       _STRIP=$(find_tool "llvm-strip" true)

       _AS="${_CC}"
       _ASM="$(basename "${_CC}") -c"

       # Use version-min flag to match SDK version (default 10.13 for conda-forge)
       local _VERSION_MIN="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-10.13}"
       _MKDLL="$(basename "${_CC}") ${_VERSION_MIN} -shared -Wl,-headerpad_max_install_names -undefined dynamic_lookup"
       # Add rpath so downstream binaries can find libzstd in ${CONDA_PREFIX}/lib
       _MKEXE="$(basename "${_CC}") ${_VERSION_MIN} -fuse-ld=lld -Wl,-headerpad_max_install_names -Wl,-rpath,@executable_path/../lib"
       # Include -isysroot in MKDLL/MKEXE when cross-compiling for ARM64
       # OCaml's Makefile uses $(MKEXE) directly without $(LDFLAGS)
       # NOTE: CONDA_BUILD_SYSROOT must be exported to ARM64 SDK path
       # (in build-cross-compiler.sh) for the cross-compiler to use correct SDK
       if [[ -n "${ARM64_SYSROOT:-}" ]]; then
         _MKDLL="${_MKDLL} -isysroot ${ARM64_SYSROOT}"
         _MKEXE="${_MKEXE} -isysroot ${ARM64_SYSROOT}"
       fi
      ;;
    *-linux-*)
       _AR=$(find_tool "${target}-ar" true)
       _AS=$(find_tool "${target}-as" true)
       _CC=$(find_tool "${target}-gcc" true)
       _LD=$(find_tool "${target}-ld" true)
       _NM=$(find_tool "${target}-nm" true)
       _RANLIB=$(find_tool "${target}-ranlib" true)
       _STRIP=$(find_tool "${target}-strip" true)

       _ASM=$(basename "${_AS}")
  
       _MKDLL="$(basename "${_CC}") -shared"
       # -Wl,-E exports symbols for dlopen (required by ocamlnat)
       # -ldl required on glibc 2.17 (conda-forge sysroot) for dlopen/dlclose/dlsym
       _MKEXE="$(basename "${_CC}") -Wl,-E -ldl"
      ;;
    *-mingw32)
       _AR=$(find_tool "${target}-ar" true)
       _AS=$(find_tool "${target}-as" true)
       _CC=$(find_tool "${target}-gcc" true)
       _LD=$(find_tool "${target}-ld" true)
       _NM=$(find_tool "${target}-nm" true)
       _RANLIB=$(find_tool "${target}-ranlib" true)
       _STRIP=$(find_tool "${target}-strip" true)

       _ASM=$(basename "${_AS}")
  
       _MKDLL="$(basename "${_CC}")"
       _MKEXE="$(basename "${_CC}")"
      ;;
    *-pc-*)
       # MSVC tools come from Visual Studio environment (PATH), not conda packages
       # Verify cl.exe is available (VS environment must be activated)
       if ! command -v cl.exe &>/dev/null; then
         echo "ERROR: cl.exe not found in PATH. Visual Studio environment not activated?"
         echo "  Ensure VS Developer Command Prompt or vcvarsall.bat was run before build."
         exit 1
       fi
       _AR="lib.exe"
       _AS="ml64.exe"
       _CC="cl.exe"
       _LD="link.exe"
       _NM=""
       _RANLIB=""
       _STRIP=""

       _ASM="ml64.exe"

       # MSVC linking is handled by flexlink
       _MKDLL=""
       _MKEXE=""
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

# Get default tool basenames for wrapper scripts
# Usage: get_cross_tool_defaults "aarch64-conda-linux-gnu"
# Sets: DEFAULT_CC, DEFAULT_AS, DEFAULT_AR, DEFAULT_LD, DEFAULT_RANLIB, DEFAULT_MKDLL, DEFAULT_MKEXE
get_cross_tool_defaults() {
  local target="$1"

  DEFAULT_CC=$(basename "${CROSS_CC}")
  # CRITICAL: Use CROSS_ASM (not CROSS_AS) - on macOS, ASM includes "-c" flag
  # Without -c, clang tries to link instead of just assembling
  DEFAULT_AS="${CROSS_ASM}"
  DEFAULT_AR=$(basename "${CROSS_AR}")
  DEFAULT_LD=$(basename "${CROSS_LD}")
  DEFAULT_RANLIB=$(basename "${CROSS_RANLIB}")

  if [[ "${target}" == "arm64-"* ]]; then
    # macOS: use lld linker and headerpad for install_name_tool compatibility
    # Add rpath so downstream binaries can find libzstd in ${CONDA_PREFIX}/lib
    DEFAULT_MKDLL="${DEFAULT_CC} -shared -undefined dynamic_lookup \${LDFLAGS}"
    DEFAULT_MKEXE="${DEFAULT_CC} -fuse-ld=lld -Wl,-headerpad_max_install_names -Wl,-rpath,@executable_path/../lib \${LDFLAGS}"
  else
    # Linux: -Wl,-E exports symbols for dlopen (required by ocamlnat)
    DEFAULT_MKDLL="${DEFAULT_CC} -shared \${LDFLAGS}"
    DEFAULT_MKEXE="${DEFAULT_CC} \${LDFLAGS} -Wl,-E -ldl"
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
  local wrapper_path="${install_prefix}/bin/${target}-${tool}.opt"

  cat > "${wrapper_path}" << WRAPPER
#!/bin/sh
prefix="\$(cd "\$(dirname "\$0")/.." && pwd)"
export OCAMLLIB="\${prefix}/lib/ocaml-cross-compilers/${target}/lib/ocaml"
# Set CONDA_OCAML_* for cross-compilation (user can override via CONDA_OCAML_${target_id}_*)
export CONDA_OCAML_CC="\${CONDA_OCAML_${target_id}_CC:-${DEFAULT_CC}}"
export CONDA_OCAML_AS="\${CONDA_OCAML_${target_id}_AS:-${DEFAULT_AS}}"
export CONDA_OCAML_AR="\${CONDA_OCAML_${target_id}_AR:-${DEFAULT_AR}}"
export CONDA_OCAML_LD="\${CONDA_OCAML_${target_id}_LD:-${DEFAULT_LD}}"
export CONDA_OCAML_RANLIB="\${CONDA_OCAML_${target_id}_RANLIB:-${DEFAULT_RANLIB}}"
export CONDA_OCAML_MKDLL="\${CONDA_OCAML_${target_id}_MKDLL:-${DEFAULT_MKDLL}}"
export CONDA_OCAML_MKEXE="\${CONDA_OCAML_${target_id}_MKEXE:-${DEFAULT_MKEXE}}"
WRAPPER

  # macOS targets need -ldopt for ocamlmklib to add -undefined dynamic_lookup
  # This allows _caml_* symbols to remain unresolved until runtime
  if [[ "${tool}" == "ocamlmklib" ]] && [[ "${target}" == arm64-apple-darwin* ]]; then
    cat >> "${wrapper_path}" << WRAPPER
exec "\${prefix}/lib/ocaml-cross-compilers/${target}/bin/${tool}.opt" -ldopt "-Wl,-undefined,dynamic_lookup" "\$@"
WRAPPER
  else
    cat >> "${wrapper_path}" << WRAPPER
exec "\${prefix}/lib/ocaml-cross-compilers/${target}/bin/${tool}.opt" "\$@"
WRAPPER
  fi
  chmod +x "${wrapper_path}"

  echo "     Created wrapper: ${wrapper_path}"
}

# ==============================================================================
# Post-Install Path Cleaning
# ==============================================================================

# Clean build-time -L paths and absolute paths from an installed Makefile.config
# Usage: clean_makefile_config <config_file> <prefix>
# Parameters:
#   config_file - path to the installed Makefile.config
#   prefix      - conda PREFIX to substitute for build-time absolute paths
clean_makefile_config() {
  local config_file="$1"
  local prefix="$2"

  [[ -f "${config_file}" ]] || return 0

  # Remove -L paths containing build directories (conda-bld, rattler-build, build_env)
  sed -i 's|-L[^ ]*conda-bld[^ ]* ||g' "${config_file}"
  sed -i 's|-L[^ ]*rattler-build[^ ]* ||g' "${config_file}"
  sed -i 's|-L[^ ]*build_env[^ ]* ||g' "${config_file}"
  sed -i 's|-L[^ ]*_build_env[^ ]* ||g' "${config_file}"
  # Remove any remaining absolute -L paths (will find libs via standard paths at runtime)
  sed -i 's|-L/[^ ]*/lib ||g' "${config_file}"
  # Clean -Wl,-L paths too
  sed -i 's|-Wl,-L[^ ]* ||g' "${config_file}"

  # CRITICAL: Remove CONFIGURE_ARGS - it contains build-time paths like /home/*/feedstock_root/*
  sed -i '/^CONFIGURE_ARGS=/d' "${config_file}"
  echo "CONFIGURE_ARGS=# Removed - contained build-time paths" >> "${config_file}"

  # Clean any remaining build-time paths (various patterns used by CI systems)
  # Strategy: Match paths anywhere on line (start, middle, end) using better regex patterns

  # 1. Absolute paths starting with /home/ (comprehensive patterns)
  sed -i "s|/home/[^/]*/feedstock_root[^[:space:]]*|${prefix}|g" "${config_file}"
  sed -i "s|/home/[^/]*/feedstock[^[:space:]]*|${prefix}|g" "${config_file}"
  sed -i "s|/home/[^/]*/build_artifacts[^[:space:]]*|${prefix}|g" "${config_file}"
  sed -i "s|/home/conda/feedstock_root[^[:space:]]*|${prefix}|g" "${config_file}"

  # 2. Any path containing rattler-build (handles paths at any position, including end of line)
  sed -i "s|[^[:space:]]*rattler-build[^[:space:]]*|${prefix}|g" "${config_file}"

  # 3. Any path containing conda-bld
  sed -i "s|[^[:space:]]*conda-bld[^[:space:]]*|${prefix}|g" "${config_file}"

  # 4. Any path containing build_artifacts
  sed -i "s|[^[:space:]]*build_artifacts[^[:space:]]*|${prefix}|g" "${config_file}"

  # 5. Placeholder paths (common in conda builds with long prefixes)
  sed -i "s|[^[:space:]]*placehold[^[:space:]]*|${prefix}|g" "${config_file}"

  # 6. Host/build env paths
  sed -i "s|[^[:space:]]*host_env[^[:space:]]*|${prefix}|g" "${config_file}"
  sed -i "s|[^[:space:]]*build_env[^[:space:]]*|${prefix}|g" "${config_file}"
  sed -i "s|[^[:space:]]*_build_env[^[:space:]]*|${prefix}|g" "${config_file}"

  # 7. Remove -isystem and -I paths with build-time directories
  sed -i 's|-isystem [^[:space:]]*rattler-build[^[:space:]]*||g' "${config_file}"
  sed -i 's|-isystem [^[:space:]]*conda-bld[^[:space:]]*||g' "${config_file}"
  sed -i 's|-isystem [^[:space:]]*build_env[^[:space:]]*||g' "${config_file}"
  sed -i 's|-isystem [^[:space:]]*placehold[^[:space:]]*||g' "${config_file}"
  sed -i 's|-isystem [^[:space:]]*host_env[^[:space:]]*||g' "${config_file}"
  sed -i 's|-I[^[:space:]]*rattler-build[^[:space:]]*||g' "${config_file}"
  sed -i 's|-I[^[:space:]]*conda-bld[^[:space:]]*||g' "${config_file}"
  sed -i 's|-I[^[:space:]]*build_env[^[:space:]]*||g' "${config_file}"
  sed -i 's|-I[^[:space:]]*placehold[^[:space:]]*||g' "${config_file}"
  sed -i 's|-I[^[:space:]]*host_env[^[:space:]]*||g' "${config_file}"

  # 8. Remove -L paths with build-time directories
  sed -i 's|-L[^[:space:]]*rattler-build[^[:space:]]*||g' "${config_file}"
  sed -i 's|-L[^[:space:]]*conda-bld[^[:space:]]*||g' "${config_file}"
  sed -i 's|-L[^[:space:]]*build_env[^[:space:]]*||g' "${config_file}"
  sed -i 's|-L[^[:space:]]*placehold[^[:space:]]*||g' "${config_file}"
  sed -i 's|-L[^[:space:]]*host_env[^[:space:]]*||g' "${config_file}"

  # 9. Delete lines that are ONLY ${prefix} (orphaned after path replacement)
  sed -i '/^'"${prefix//\//\\/}"'$/d' "${config_file}"

  # 10. Delete lines that start with build-time paths (standalone path lines)
  sed -i '\|^/[^[:space:]]*rattler-build|d' "${config_file}"
  sed -i '\|^/[^[:space:]]*conda-bld|d' "${config_file}"
  sed -i '\|^/[^[:space:]]*placehold|d' "${config_file}"
  sed -i '\|^/[^[:space:]]*host_env|d' "${config_file}"
  sed -i '\|^/[^[:space:]]*build_env|d' "${config_file}"
  sed -i '\|^/home/[^/]*/feedstock|d' "${config_file}"

  # 10a. FINAL CLEANUP: Use grep to remove any remaining lines with build markers
  # This catches edge cases where sed patterns don't match (e.g., unusual path formats)
  local temp_file="${config_file}.final_clean"
  if grep -qE "rattler-build|conda-bld|/home/[^/]+/feedstock|host_env_placehold|build_env_placehold" "${config_file}" 2>/dev/null; then
    grep -vE "rattler-build|conda-bld|/home/[^/]+/feedstock|host_env_placehold|build_env_placehold" "${config_file}" > "${temp_file}" 2>/dev/null
    if [[ -s "${temp_file}" ]]; then
      mv "${temp_file}" "${config_file}"
    else
      rm -f "${temp_file}"
    fi
  fi

  # 11. Clean up multiple consecutive spaces created by removals
  sed -i 's|  *| |g' "${config_file}"

  # NUCLEAR CLEANUP: Delete ANY line containing build directory markers
  # These paths cannot be fixed by substitution because ${PREFIX} IS the build path during build
  # Lines with build-time paths won't work at runtime anyway - delete them entirely
  # Using sed -i for deletion (always succeeds, unlike grep -v which exits 1 on no match)

  # First try to salvage lines by removing just the path portions inline
  sed -i 's|[^[:space:]]*/bld/rattler-build_[^[:space:]]*||g' "${config_file}"
  sed -i 's|[^[:space:]]*/output/bld/[^[:space:]]*||g' "${config_file}"
  sed -i 's|[^[:space:]]*host_env_placehold[^[:space:]]*||g' "${config_file}"
  sed -i 's|[^[:space:]]*build_env_placehold[^[:space:]]*||g' "${config_file}"

  # Delete entire lines that STILL contain build markers (using sed -i for reliability)
  sed -i '/\/bld\/rattler-build_/d' "${config_file}"
  sed -i '/\/output\/bld\//d' "${config_file}"
  sed -i '/host_env_placehold/d' "${config_file}"
  sed -i '/build_env_placehold/d' "${config_file}"

  # Final cleanup: remove empty lines and fix whitespace
  sed -i '/^[[:space:]]*$/d' "${config_file}"
  sed -i 's|  *| |g' "${config_file}"
}

# Clean build-time paths from an installed runtime-launch-info file
# Usage: clean_runtime_launch_info <runtime_launch_info_file> <prefix>
# Parameters:
#   runtime_launch_info_file - path to the runtime-launch-info file
#   prefix                   - conda PREFIX to substitute for build-time paths
clean_runtime_launch_info() {
  local runtime_launch_info="$1"
  local prefix="$2"

  [[ -f "${runtime_launch_info}" ]] || return 0

  # runtime-launch-info is generated by OCaml's configure.ac:
  #   printf '%s\n%s\000\n' "$launch_method" "$bindir" > runtime.info
  # then stdlib/Makefile appends the compiled stub (header.c):
  #   cat runtime.info tmpheader.exe > runtime-launch-info
  #
  # Format:
  #   Line 1: launch method ("sh" or "exe") + \n
  #   Line 2: BINDIR path + \000 + \n    ← null-terminated! This is intentional.
  #   Rest:   compiled stub binary (header.exe)
  #
  # BINDIR is used by ocamlc at LINK TIME to construct #!/BINDIR/ocamlrun shebangs
  # for every bytecode executable. A wrong BINDIR = broken bytecode programs.
  #
  # We use Python for binary-safe manipulation: replace BINDIR in line 2,
  # preserve the null terminator and binary portion byte-for-byte.

  local new_bindir="${prefix}/bin"

  python3 -c "
import sys
path, new_bindir = sys.argv[1], sys.argv[2].encode()

with open(path, 'rb') as f:
    data = f.read()

# Find first and second newlines
first_nl = data.index(b'\n')
second_nl = data.index(b'\n', first_nl + 1)

line1 = data[:first_nl]
old_line2 = data[first_nl+1:second_nl]  # includes the \x00 terminator
binary = data[second_nl+1:]

# Check if line 2 contains build-time paths
markers = [b'_h_env', b'_build_env', b'/work/', b'_native_compiler',
           b'_xcross_compiler', b'_target_compiler', b'rattler-build',
           b'conda-bld', b'feedstock']
if not any(m in old_line2 for m in markers):
    print(f'  runtime-launch-info: BINDIR is clean ({old_line2.rstrip(chr(0).encode()).decode()})')
    sys.exit(0)

# New line 2: BINDIR + null terminator (matching OCaml's configure.ac format)
new_line2 = new_bindir + b'\x00'

print(f'  runtime-launch-info: fixing BINDIR')
print(f'    old: {old_line2.rstrip(chr(0).encode()).decode()}')
print(f'    new: {new_bindir.decode()}')

with open(path, 'wb') as f:
    f.write(line1 + b'\n' + new_line2 + b'\n' + binary)
" "${runtime_launch_info}" "${new_bindir}"
}

# ==============================================================================
# Makefile.config Patches
# ==============================================================================

# Patch Makefile.config to add CHECKSTACK_CC if missing (OCaml 5.4.0 bug)
# OCaml 5.4.0 uses CHECKSTACK_CC but doesn't define it - causes build failure:
#   "make[2]: O2: No such file or directory" (flags executed as commands)
# Usage: patch_checkstack_cc
# Operates on Makefile.config in the current directory
patch_checkstack_cc() {
  if ! grep -q "^CHECKSTACK_CC" Makefile.config; then
    echo "  Patching Makefile.config: adding CHECKSTACK_CC = \$(CC)"
    echo 'CHECKSTACK_CC = $(CC)' >> Makefile.config
  fi
}

# Clean embedded binary paths and -L flags from Makefile.config after configure
# Removes non-relocatable build-time tool paths baked in by configure.
# Usage: patch_makefile_config_post_configure
# Operates on Makefile.config in the current directory
patch_makefile_config_post_configure() {
  local config_file="Makefile.config"

  sed -i  's#-fdebug-prefix-map=[^ ]*##g' "${config_file}"
  sed -i  's#-link\s+-L[^ ]*##g' "${config_file}"                             # Remove flexlink's "-link -L..." patterns
  sed -i  's#-L[^ ]*##g' "${config_file}"                                     # Remove standalone -L paths
  # These would be found in BUILD_PREFIX and fail relocation
  # Remove prepended binaries path (could be BUILD_PREFIX non-relocatable)
  # Simple commands: CC, AS, ASM, ASPP, STRIP (line ends with binary name)
  sed -Ei 's#^(CC|AS|ASM|ASPP|STRIP)=/.*/([^/]+)$#\1=\2#' "${config_file}"
  # CPP has flags after binary (e.g., "/path/to/clang -E -P" -> "clang -E -P")
  # The ( .*)? is optional to handle CPP without flags
  sed -Ei 's#^(CPP)=/.*/([^/ ]+)( .*)?$#\1=\2\3#' "${config_file}"
}

# ==============================================================================
# Wrapper Script Installation
# ==============================================================================

# Install conda-ocaml-{cc,as,ar,ld,ranlib,mkexe,mkdll} wrapper scripts
# Usage: install_conda_ocaml_wrappers <dest_bin_dir>
# Parameters:
#   dest_bin_dir - destination bin directory (e.g., ${BUILD_PREFIX}/bin or ${PREFIX}/bin)
install_conda_ocaml_wrappers() {
  local dest_bin_dir="$1"

  for wrapper in conda-ocaml-cc conda-ocaml-as conda-ocaml-ar conda-ocaml-ld conda-ocaml-ranlib conda-ocaml-mkexe conda-ocaml-mkdll; do
    install -m 755 "${RECIPE_DIR}/scripts/${wrapper}" "${dest_bin_dir}/${wrapper}"
  done
}

# ==============================================================================
# macOS Runtime Library Path
# ==============================================================================

# Set up DYLD_FALLBACK_LIBRARY_PATH for macOS so OCaml can find libzstd at runtime
# IMPORTANT: Uses FALLBACK (not DYLD_LIBRARY_PATH) - FALLBACK doesn't override system libs
# For cross-compilation: BUILD_PREFIX has x86_64 libs for native compiler
# For native build: PREFIX has same-arch libs
# Usage: setup_dyld_fallback
# Uses globals: target_platform, CONDA_BUILD_CROSS_COMPILATION, BUILD_PREFIX, PREFIX,
#               DYLD_FALLBACK_LIBRARY_PATH
setup_dyld_fallback() {
  if [[ "${target_platform}" == "osx"* ]]; then
    if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
      export DYLD_FALLBACK_LIBRARY_PATH="${BUILD_PREFIX}/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
    else
      export DYLD_FALLBACK_LIBRARY_PATH="${PREFIX}/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
    fi
    echo "  Set DYLD_FALLBACK_LIBRARY_PATH for libzstd"
  fi
}

# ==============================================================================
# macOS rpath Verification
# ==============================================================================

# Verify and fix rpath for macOS binaries that use @rpath/libzstd
# Usage: verify_macos_rpath <binary_dir> <rpath_value>
# Parameters:
#   binary_dir  - directory containing *.opt binaries to check
#   rpath_value - rpath to add if missing (e.g. "@loader_path/../lib" or
#                 "@loader_path/../../../../lib")
verify_macos_rpath() {
  local binary_dir="$1"
  local rpath_value="$2"

  for binary in "${binary_dir}"/*.opt; do
    if [[ -f "${binary}" ]]; then
      # Check if libzstd is linked via @rpath
      if otool -L "${binary}" 2>/dev/null | grep -q "@rpath/libzstd"; then
        # Check if rpath already exists (either @executable_path or @loader_path)
        if otool -l "${binary}" 2>/dev/null | grep -A2 "LC_RPATH" | grep -qE "@(executable_path|loader_path)"; then
          RPATH=$(otool -l "${binary}" 2>/dev/null | grep -A2 "LC_RPATH" | grep "path" | head -1 | awk '{print $2}')
          echo "    $(basename ${binary}): rpath OK (${RPATH})"
        else
          # No rpath set - add one
          echo "    $(basename ${binary}): adding ${rpath_value} rpath"
          if install_name_tool -add_rpath "${rpath_value}" "${binary}" 2>&1; then
            codesign -f -s - "${binary}" 2>/dev/null || true
          else
            echo "    WARNING: install_name_tool failed for $(basename ${binary})"
          fi
        fi
      fi
    fi
  done
}

# ==============================================================================
# config.generated.ml Patching
# ==============================================================================

# Patch utils/config.generated.ml to use conda-ocaml-* wrapper scripts (native/target builds)
# Wrappers expand CONDA_OCAML_* env vars at runtime, compatible with Unix.create_process
# (which doesn't expand shell variables).
# Usage: patch_config_generated_ml_native
# Operates on utils/config.generated.ml in the current directory
patch_config_generated_ml_native() {
  local config_file="utils/config.generated.ml"

  sed -i 's/^let asm = .*/let asm = {|conda-ocaml-as|}/' "$config_file"
  sed -i 's/^let ar = .*/let ar = {|conda-ocaml-ar|}/' "$config_file"
  sed -i 's/^let c_compiler = .*/let c_compiler = {|conda-ocaml-cc|}/' "$config_file"
  sed -i 's/^let ranlib = .*/let ranlib = {|conda-ocaml-ranlib|}/' "$config_file"
  sed -i 's/^let mkexe = .*/let mkexe = {|conda-ocaml-mkexe|}/' "$config_file"
  sed -i 's/^let mkdll = .*/let mkdll = {|conda-ocaml-mkdll|}/' "$config_file"
  sed -i 's/^let mkmaindll = .*/let mkmaindll = {|conda-ocaml-mkdll|}/' "$config_file"
}

# ==============================================================================
# Prefix Transfer
# ==============================================================================

# Transfer a built OCaml tree from one directory to another and fix embedded paths
# Usage: transfer_to_prefix <src_dir> <dest_dir>
# Parameters:
#   src_dir  - source directory (e.g. a staging build tree)
#   dest_dir - destination directory (e.g. ${PREFIX})
# Actions:
#   1. Copies the full tree via tar pipe
#   2. Rewrites all src_dir references in Makefile.config to dest_dir
#   3. Strips prepended build_env bin paths from tool entries in Makefile.config
#   4. Replaces bare $(CC) with $(CONDA_OCAML_CC) in Makefile.config
#   5. Writes a fresh ld.conf pointing at dest_dir/lib/ocaml
transfer_to_prefix() {
  local src_dir="$1"
  local dest_dir="$2"

  echo "=== Transferring ${src_dir} to ${dest_dir} ==="
  tar -C "${src_dir}" -cf - . | tar -C "${dest_dir}" -xf -

  local config_file="${dest_dir}/lib/ocaml/Makefile.config"
  sed -i "s#${src_dir}#${dest_dir}#g" "${config_file}"
  sed -i "s#/.*build_env/bin/##g" "${config_file}"
  sed -i 's#$(CC)#$(CONDA_OCAML_CC)#g' "${config_file}"

  printf '%s\n%s\n' "${dest_dir}/lib/ocaml/stublibs" "${dest_dir}/lib/ocaml" \
    > "${dest_dir}/lib/ocaml/ld.conf"
}

# ==============================================================================
# Toolchain Diagnostics
# ==============================================================================

# Print all toolchain variables for a given prefix (NATIVE or CROSS)
# Usage: print_toolchain_info <prefix>
# Parameters:
#   prefix - variable name prefix, e.g. "NATIVE" or "CROSS"
# Prints: AR, AS, ASM, CC, CFLAGS, LD, LDFLAGS, RANLIB values via indirect reference
print_toolchain_info() {
  local prefix="$1"

  for var in AR AS ASM CC CFLAGS LD LDFLAGS RANLIB; do
    local varname="${prefix}_${var}"
    echo "  ${varname}=${!varname}"
  done
}

# ==============================================================================
# Unix CRC Consistency Check
# ==============================================================================

# Verify that unix.cmxa and threads.cmxa share the same CRC for the unix module
# Usage: check_unix_crc <ocamlobjinfo_path> <unix_cmxa> <threads_cmxa> <label>
# Parameters:
#   ocamlobjinfo_path - full path to the ocamlobjinfo binary
#   unix_cmxa         - path to unix.cmxa (or unix.cma)
#   threads_cmxa      - path to threads.cmxa (or threads.cma)
#   label             - descriptive label printed in pass/fail messages
# Exits non-zero if the CRCs do not match.
check_unix_crc() {
  local ocamlobjinfo_path="$1"
  local unix_cmxa="$2"
  local threads_cmxa="$3"
  local label="$4"

  # Extract Unix implementation CRC from unix.cmxa
  local unix_crc
  unix_crc=$("${ocamlobjinfo_path}" "${unix_cmxa}" 2>&1 \
    | grep -A1 "^Name: Unix$" | grep "CRC of implementation" | awk '{print $NF}')

  # Extract what threads.cmxa expects from Unix (implementation CRC)
  # Must scope to "Implementations imported" section to avoid matching interface CRCs
  local threads_crc
  threads_crc=$("${ocamlobjinfo_path}" "${threads_cmxa}" 2>&1 \
    | sed -n '/^Implementations imported:/,/^[A-Z]/p' \
    | grep -E "^\s+[a-f0-9]+\s+Unix$" | awk '{print $1}' | head -1)

  if [[ "${unix_crc}" == "${threads_crc}" && -n "${unix_crc}" ]]; then
    echo "    [PASS] ${label}: unix CRC match (${unix_crc})"
  else
    echo "    [FAIL] ${label}: unix CRC mismatch"
    echo "           unix.cmxa    CRC: ${unix_crc:-<empty>}"
    echo "           threads.cmxa expects: ${threads_crc:-<empty>}"
    exit 1
  fi
}

# ==============================================================================
# Progressive Build Cache
# ==============================================================================
# Caches successful build INSTALLED ARTIFACTS to speed up iterative debugging.
# Enable with OCAML_USE_CACHE=1 in recipe or environment.
# Cache location: ${RECIPE_DIR}/.build_cache/
#
# Cache structure (ONLY installed artifacts, NOT source trees):
#   .build_cache/
#     native_${PKG_VERSION}_${build_platform}/     - Native compiler install dir
#     xcross_${PKG_VERSION}_${target_platform}/    - Cross-compiler install dir
#
# Usage:
#   if cache_native_exists; then
#     cache_native_restore  # Restore installed compiler
#     # Skip build_native entirely
#   else
#     build_native
#     cache_native_save
#   fi
# ==============================================================================

# Check if caching is enabled
cache_enabled() {
  [[ "${OCAML_USE_CACHE:-0}" == "1" ]]
}

# Get cache root directory
cache_root() {
  echo "${RECIPE_DIR}/.build_cache"
}

# Get a short hash of build scripts to detect source changes that invalidate cache
# (e.g., configure.ac format changes, patch updates, Makefile rule changes)
_cache_source_hash() {
  local hash_input="${PKG_VERSION}"
  # Include build script and patches in hash — any change invalidates cache
  for f in "${RECIPE_DIR}/build.sh" "${RECIPE_DIR}/building/common-functions.sh"; do
    [[ -f "$f" ]] && hash_input+="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)"
  done
  echo "${hash_input}" | md5sum | cut -c1-8
}

# Get cache key for native compiler install
cache_key_native() {
  echo "native_${PKG_VERSION}_${build_platform:-linux-64}_$(_cache_source_hash)"
}

# Get cache key for cross-compiler
cache_key_xcross() {
  local target="${1:-${OCAML_TARGET_PLATFORM:-${cross_target_platform}}}"
  echo "xcross_${PKG_VERSION}_${target}_$(_cache_source_hash)"
}

# Check if native compiler cache exists
cache_native_exists() {
  cache_enabled || return 1
  local cache_dir
  cache_dir="$(cache_root)/$(cache_key_native)"
  [[ -d "${cache_dir}" ]] && [[ -f "${cache_dir}/bin/ocamlopt" ]]
}

# Check if cross-compiler cache exists
cache_xcross_exists() {
  cache_enabled || return 1
  local target="${1:-${OCAML_TARGET_PLATFORM:-${cross_target_platform}}}"
  local cache_dir
  cache_dir="$(cache_root)/$(cache_key_xcross "${target}")"
  [[ -d "${cache_dir}" ]] && [[ -d "${cache_dir}/lib/ocaml-cross-compilers" ]]
}

# Save native compiler install directory to cache
# Only caches OCaml artifacts, NOT env files (they contain build-specific paths)
cache_native_save() {
  cache_enabled || return 0
  local src_dir="${1:-${OCAML_NATIVE_INSTALL_PREFIX:-${SRC_DIR}/_native_compiler}}"
  local cache_dir
  cache_dir="$(cache_root)/$(cache_key_native)"

  echo "  [CACHE] Saving native compiler to cache..."
  echo "          Source: ${src_dir}"
  echo "          Cache:  ${cache_dir}"

  mkdir -p "$(cache_root)"
  rm -rf "${cache_dir}"
  cp -a "${src_dir}" "${cache_dir}"

  echo "  [CACHE] Native compiler cached successfully"
}

# Save cross-compiler install directory to cache
# Only caches OCaml artifacts, NOT env files (they contain build-specific paths)
cache_xcross_save() {
  cache_enabled || return 0
  local src_dir="${1:-${OCAML_XCROSS_INSTALL_PREFIX:-${SRC_DIR}/_xcross_compiler}}"
  local target="${2:-${OCAML_TARGET_PLATFORM:-${cross_target_platform}}}"
  local cache_dir
  cache_dir="$(cache_root)/$(cache_key_xcross "${target}")"

  echo "  [CACHE] Saving cross-compiler (${target}) to cache..."
  echo "          Source: ${src_dir}"
  echo "          Cache:  ${cache_dir}"

  mkdir -p "$(cache_root)"
  rm -rf "${cache_dir}"
  cp -a "${src_dir}" "${cache_dir}"

  echo "  [CACHE] Cross-compiler (${target}) cached successfully"
}

# Restore native compiler from cache
# Only restores OCaml artifacts - env files are generated fresh by caller
cache_native_restore() {
  cache_enabled || return 1
  local dst_dir="${1:-${OCAML_NATIVE_INSTALL_PREFIX:-${SRC_DIR}/_native_compiler}}"
  local cache_dir
  cache_dir="$(cache_root)/$(cache_key_native)"

  if ! cache_native_exists; then
    echo "  [CACHE] No native compiler cache found"
    return 1
  fi

  echo "  [CACHE] Restoring native compiler from cache..."
  echo "          Cache:  ${cache_dir}"
  echo "          Target: ${dst_dir}"

  mkdir -p "$(dirname "${dst_dir}")"
  rm -rf "${dst_dir}"
  cp -a "${cache_dir}" "${dst_dir}"

  # Set OCAMLLIB to override baked-in stdlib path
  # This allows cached compiler to find stdlib at current build location
  local current_stdlib_path="${dst_dir}/lib/ocaml"
  export OCAMLLIB="${current_stdlib_path}"
  export CAML_LD_LIBRARY_PATH="${current_stdlib_path}/stublibs"
  echo "  [CACHE] Set OCAMLLIB=${OCAMLLIB} to override cached compiler's baked-in path"

  # CRITICAL: Clean stale .cmi files from source tree that have old stdlib CRCs
  # When using cached native compiler for cross-compilation, the source tree may have
  # .cmi files from a previous build that were compiled against the OLD stdlib.
  # These must be removed so the cross-compiler build generates fresh .cmi files
  # with CRCs matching the NEW stdlib that will be built.
  # This prevents "inconsistent assumptions over interface Stdlib" errors.
  echo "  [CACHE] Cleaning stale .cmi files from source tree..."
  rm -f "${SRC_DIR}"/utils/*.cmi "${SRC_DIR}"/parsing/*.cmi "${SRC_DIR}"/lambda/*.cmi 2>/dev/null || true
  rm -f "${SRC_DIR}"/bytecomp/*.cmi "${SRC_DIR}"/file_formats/*.cmi "${SRC_DIR}"/typing/*.cmi 2>/dev/null || true
  rm -f "${SRC_DIR}"/driver/*.cmi "${SRC_DIR}"/toplevel/*.cmi "${SRC_DIR}"/asmcomp/*.cmi 2>/dev/null || true
  rm -f "${SRC_DIR}"/middle_end/*.cmi "${SRC_DIR}"/middle_end/**/*.cmi 2>/dev/null || true
  rm -f "${SRC_DIR}"/stdlib/*.cmi "${SRC_DIR}"/stdlib/*.cmo "${SRC_DIR}"/stdlib/*.cma 2>/dev/null || true
  rm -f "${SRC_DIR}"/stdlib/*.cmx "${SRC_DIR}"/stdlib/*.cmxa "${SRC_DIR}"/stdlib/*.o "${SRC_DIR}"/stdlib/*.a 2>/dev/null || true
  rm -f "${SRC_DIR}"/otherlibs/unix/*.cmi "${SRC_DIR}"/otherlibs/str/*.cmi 2>/dev/null || true
  rm -f "${SRC_DIR}"/otherlibs/dynlink/*.cmi "${SRC_DIR}"/otherlibs/dynlink/native/*.cmi 2>/dev/null || true
  rm -f "${SRC_DIR}"/otherlibs/systhreads/*.cmi "${SRC_DIR}"/otherlibs/runtime_events/*.cmi 2>/dev/null || true

  echo "  [CACHE] Native compiler restored successfully"
  return 0
}

# Restore cross-compiler from cache
# Only restores OCaml artifacts - env files are generated fresh by caller
cache_xcross_restore() {
  cache_enabled || return 1
  local dst_dir="${1:-${OCAML_XCROSS_INSTALL_PREFIX:-${SRC_DIR}/_xcross_compiler}}"
  local target="${2:-${OCAML_TARGET_PLATFORM:-${cross_target_platform}}}"
  local cache_dir
  cache_dir="$(cache_root)/$(cache_key_xcross "${target}")"

  if ! cache_xcross_exists "${target}"; then
    echo "  [CACHE] No cross-compiler cache found for ${target}"
    return 1
  fi

  echo "  [CACHE] Restoring cross-compiler (${target}) from cache..."
  echo "          Cache:  ${cache_dir}"
  echo "          Target: ${dst_dir}"

  mkdir -p "$(dirname "${dst_dir}")"
  rm -rf "${dst_dir}"
  cp -a "${cache_dir}" "${dst_dir}"

  # Set OCAMLLIB to override baked-in stdlib path
  # This allows cached compiler to find stdlib at current build location
  local current_stdlib_path="${dst_dir}/lib/ocaml"
  export OCAMLLIB="${current_stdlib_path}"
  export CAML_LD_LIBRARY_PATH="${current_stdlib_path}/stublibs"
  echo "  [CACHE] Set OCAMLLIB=${OCAMLLIB} to override cached compiler's baked-in path"

  echo "  [CACHE] Cross-compiler (${target}) restored successfully"
  return 0
}

# Show cache status
cache_status() {
  local cache_root_dir
  cache_root_dir="$(cache_root)"

  echo "=== Build Cache Status ==="
  echo "  Enabled: ${OCAML_USE_CACHE:-0}"
  echo "  Location: ${cache_root_dir}"

  if [[ -d "${cache_root_dir}" ]]; then
    echo "  Cached stages:"
    for entry in "${cache_root_dir}"/*/; do
      [[ -d "${entry}" ]] || continue
      local name
      name=$(basename "${entry}")
      local size
      size=$(du -sh "${entry}" 2>/dev/null | cut -f1)
      echo "    - ${name} (${size})"
    done
  else
    echo "  No cache directory exists"
  fi
}

# Clear all caches
cache_clear() {
  local cache_root_dir
  cache_root_dir="$(cache_root)"

  if [[ -d "${cache_root_dir}" ]]; then
    echo "  [CACHE] Clearing all caches..."
    rm -rf "${cache_root_dir}"
    echo "  [CACHE] Cache cleared"
  else
    echo "  [CACHE] No cache to clear"
  fi
}
