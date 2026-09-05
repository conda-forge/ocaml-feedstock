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
    echo "${indent}$ ${cmd##*/} ($# args)"
  fi

  if "$cmd" "$@" >> "${logfile}" 2>&1; then
    return 0
  else
    local rc=$?
    echo "${indent} FAILED (${rc}) - see ${logfile##*/}"
    echo "${indent} --- W15: error-signature lines in ${logfile##*/} (|| true guards: grep no-match must NOT abort run_logged under set -euo pipefail) ---"
    # W40 2026-07-30: added '\[W[0-9]' alternative so bracketed W-tag diagnostic
    # markers (e.g. [W37-DIAG], [W38], [W39]) surface here even when they precede
    # the tail -300 window below (crossopt.log can run well past 300 lines before
    # the actual failure; these unconditional echo diagnostics from Makefile.cross
    # were being written but never appeared in CI-visible failure context).
    grep -n -iE 'error:|error [0-9]|\*\*\*|undefined|unresolved|lld-link|flexlink|STATUS_|Exception|cannot find|fatal error|no such file|\[W[0-9]' "${logfile}" 2>/dev/null | head -80 | sed "s/^/${indent} /" || true
    # W7PP 2026-08-09: W40 added the '\[W[0-9]' alternative to the grep above so W-tag markers
    # would surface, but it shares that grep's `head -80` budget with error:|lld-link|flexlink|
    # undefined|unresolved -- patterns which occur constantly in crossopt.log (40000+ lines on
    # the win-arm64 lane). The budget is exhausted by early error-signature matches long before
    # the [W42]/[W7HH] cache-priming diagnostics are reached, so in practice W40 never surfaced
    # them. Round 50 (build 1565075 log 60) showed the last surviving [Wxx] line was
    # Makefile.cross:894 -- the line immediately BEFORE the W42 if-block -- which looked like
    # the block had not executed. It had not been proven either way; the output was simply
    # never printed. Give the W-tag markers a DEDICATED pass with their own budget so they
    # never compete with error-signature matches again.
    # Failure-branch only: this code runs solely after a command has already failed, so it
    # cannot affect any passing lane.
    echo "${indent} --- W7PP: ALL [Wxx]-tagged diagnostics in ${logfile##*/} (dedicated pass) ---"
    grep -n -E '\[W[0-9A-Z]' "${logfile}" 2>/dev/null | head -300 | sed "s/^/${indent} /" || true
    echo "${indent} --- W15: last 300 lines ---"
    tail -300 "${logfile}" 2>/dev/null | sed "s/^/${indent} /" || true
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
                  "${BUILD_PREFIX}"/Library/bin \
                  "${PREFIX}"/Library/bin \
                  "${BUILD_PREFIX}"/bin \
                  "${PREFIX}"/bin \
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
    return 1
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
    riscv64-conda-linux-gnu) echo "RISCV64" ;;
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
    riscv64-*) echo "riscv" ;;
    x86_64-*|*-x86_64-*) echo "amd64" ;;
    *) echo "amd64" ;;  # default
  esac
}

# Get target platform from triplet
# Usage: get_target_platform "aarch64-conda-linux-gnu" → "linux-aarch64"
get_target_platform() {
  local target="$1"
  
  case "${target}" in
    aarch64-*mingw32|aarch64-*windows*) echo "win-arm64" ;;
    x86_64-*mingw32|x86_64-*windows*) echo "win-64" ;;
    aarch64-*) echo "linux-aarch64" ;;
    arm64-*) echo "osx-arm64" ;;
    powerpc64le-*) echo "linux-ppc64le" ;;
    riscv64-*) echo "linux-riscv64" ;;
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
    riscv64-*|linux-riscv64)
      echo "riscv64"
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
    CROSS_nonunix-64_nonunix-arm64|CROSS_nonunix-arm64_nonunix-arm64|CROSS_nonunix-64_nonunix-64)
      # W3QQ: cross non-unix uses zig (handles arm64 target AND win-64 intermediate
      # cross-compiler built during win-arm64 cross-compile job)
      export "${name}_CFLAGS="
      export "${name}_LDFLAGS="
      ;;
    NATIVE_osx-64_osx-64|NATIVE_osx-arm64_osx-arm64|NATIVE_linux-64_linux-64|NATIVE_linux-aarch64_linux-aarch64|NATIVE_nonunix-64_nonunix-64)
      # Native build: use environment CFLAGS (set by conda-build for this platform)
      export "${name}_CFLAGS=${CFLAGS:-}"
      export "${name}_LDFLAGS=${LDFLAGS:-}"
      ;;
    CROSS_linux-64_linux-aarch64|CROSS_linux-64_linux-ppc64le|CROSS_linux-aarch64_linux-ppc64le|CROSS_linux-aarch64_linux-64)
      # Cross-compiling FOR Linux aarch64/ppc64le
      # ALWAYS use clean generic flags - conda-build's CFLAGS is often corrupted with
      # mixed build/target flags that cause -march=nocona on aarch64 cross-compiler
      export "${name}_CFLAGS=-ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -isystem ${PREFIX}/include"
      export "${name}_LDFLAGS=-Wl,-O2 -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -L${PREFIX}/lib"
      ;;
    CROSS_linux-64_linux-riscv64|CROSS_linux-aarch64_linux-riscv64)
      # Cross-compiling FOR Linux riscv64. Same clean generic CFLAGS as
      # aarch64/ppc64le, but riscv64 needs conda-forge's own linker policy:
      # activate-gcc_linux-riscv64.sh enables -Wl,--allow-shlib-undefined and
      # omits --disable-new-dtags/--gc-sections, unlike linux-64. Without
      # --allow-shlib-undefined the link of ocamlc.opt/ocamlopt.opt fails on
      # pthread_create@GLIBC_2.34 / pthread_join@GLIBC_2.34 (referenced by libzstd.so).
      export "${name}_CFLAGS=-ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -isystem ${PREFIX}/include"
      export "${name}_LDFLAGS=-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--allow-shlib-undefined -Wl,-rpath,${PREFIX}/lib -Wl,-rpath-link,${PREFIX}/lib -L${PREFIX}/lib"
      ;;
    CROSS_osx-64_osx-arm64)
      # Cross-compiling FOR macOS ARM64 (on osx-64)
      # ALWAYS use clean generic flags - conda-build's CFLAGS is often corrupted
      # CRITICAL: Both CFLAGS and LDFLAGS need -isysroot for the ARM64 SDK!
      setup_macos_sysroot
      export "${name}_CFLAGS=-ftree-vectorize -fPIC -O2 -pipe -isystem ${PREFIX}/include${ARM64_SYSROOT:+ -isysroot ${ARM64_SYSROOT}}"
      export "${name}_LDFLAGS=-fuse-ld=lld -L${PREFIX}/lib -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs${ARM64_SYSROOT:+ -isysroot ${ARM64_SYSROOT}}"
      ;;
    CROSS_osx-arm64_osx-64)
      # No setup_macos_sysroot here: that helper only provisions an ARM64 SDK (MacOSX11.0),
      # needed because Intel runners carry MacOSX10.13 which cannot target arm64. The
      # reverse direction needs no workaround - an arm64 runner's SDK is 11.0+ and can
      # target x86_64 - so use the sysroot conda-forge activation already supplies.
      export "${name}_CFLAGS=-ftree-vectorize -fPIC -O2 -pipe -isystem ${PREFIX}/include"
      export "${name}_LDFLAGS=-fuse-ld=lld -L${PREFIX}/lib -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
      ;;
    NATIVE_osx-64_osx-arm64)
      # Native OCaml build during cross-platform CI (runs on x86_64 BUILD machine)
      # MUST include -L${BUILD_PREFIX}/lib for zstd - PREFIX has ARM64 libs!
      # CRITICAL: Also strip -L$PREFIX from global LDFLAGS (conda-build sets it with ARM64 paths)
      export LDFLAGS="-L${BUILD_PREFIX}/lib ${LDFLAGS//-L${PREFIX}\/lib/}"
      export "${name}_CFLAGS=-march=core2 -mtune=haswell -mssse3 -ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -isystem ${BUILD_PREFIX}/include"
      export "${name}_LDFLAGS=-fuse-ld=lld -L${BUILD_PREFIX}/lib -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
      ;;
    NATIVE_osx-arm64_osx-64)
      export LDFLAGS="-L${BUILD_PREFIX}/lib ${LDFLAGS//-L${PREFIX}\/lib/}"
      export "${name}_CFLAGS=-ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -isystem ${BUILD_PREFIX}/include"
      export "${name}_LDFLAGS=-fuse-ld=lld -L${BUILD_PREFIX}/lib -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
      ;;
    NATIVE_linux-64_linux-aarch64|NATIVE_linux-64_linux-ppc64le|NATIVE_linux-64_linux-riscv64)
      # Native OCaml build during cross-platform CI (runs on x86_64 BUILD machine)
      export "${name}_CFLAGS=-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -isystem ${BUILD_PREFIX}/include"
      export "${name}_LDFLAGS=-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections -Wl,-rpath,${BUILD_PREFIX}/lib -Wl,-rpath-link,${BUILD_PREFIX}/lib -L${BUILD_PREFIX}/lib"
      ;;
    CROSS_osx-64_osx-64)
      # "Double-cross" variant osx_arm64_cross_target_platform_osx-64: the BUILD
      # host is osx-64 and target_platform is osx-arm64, but THIS cross-compiler
      # emits osx-64 code, so build == cross target. That is legitimate; the
      # catch-all below used to reject it outright (exit 1).
      # Do NOT reuse the ambient CFLAGS/LDFLAGS the way the NATIVE_*_* arm does:
      # conda-build sets them for target_platform=osx-arm64, so -L${PREFIX}/lib
      # holds ARM64 libs. Use BUILD_PREFIX x86_64 flags instead, mirroring the
      # NATIVE_osx-64_osx-arm64 arm above, which exists for the same hazard.
      export "${name}_CFLAGS=-march=core2 -mtune=haswell -mssse3 -ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -isystem ${BUILD_PREFIX}/include"
      export "${name}_LDFLAGS=-fuse-ld=lld -L${BUILD_PREFIX}/lib -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
      ;;
    CROSS_osx-arm64_osx-arm64)
      export "${name}_CFLAGS=-ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -isystem ${BUILD_PREFIX}/include"
      export "${name}_LDFLAGS=-fuse-ld=lld -L${BUILD_PREFIX}/lib -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
      ;;
    CROSS_linux-64_linux-64|CROSS_nonunix-*|*)
      echo "ERROR: setup_cflags_ldflags used with incorrect arguments"
      echo "   name:            ${name}"
      echo "   native platform: ${native}"
      echo "   target platform: ${target}"
      exit 1
      ;;
  esac

  # Strip GCC-specific linker flags that zig's lld rejects.
  # -Wl,-rpath-link is a GNU ld / binutils extension; zig's lld does not support it.
  # Run unconditionally when ZIG is in use; -Wl,-rpath and -L on the same path
  # already cover both link-time discovery and runtime lookup.
  if [[ -n "${ZIG:-}" ]]; then
    local _ldflags_var="${name}_LDFLAGS"
    if [[ -n "${!_ldflags_var:-}" ]]; then
      printf -v "${_ldflags_var}" '%s' \
        "$(echo "${!_ldflags_var}" | sed -E 's/[[:space:]]*-Wl,-rpath-link,[^[:space:]]+//g')"
      export "${_ldflags_var}"
    fi
  fi
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
       # NOTE: Do NOT include -fuse-ld=lld here. The installed OCaml package should use
       # Apple's default ld64 which properly handles weak SDK symbols (e.g., __darwin_check_fd_set_overflow).
       # lld is stricter and rejects weak imports, breaking downstream packages (ocamlfind, ocamlbuild).
       _MKEXE="$(basename "${_CC}") ${_VERSION_MIN} -Wl,-headerpad_max_install_names -Wl,-rpath,@executable_path/../lib"
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
       # GCC in conda prefix first, then zig as fallback
       # find_tool only searches BUILD_PREFIX/PREFIX (not system PATH)
       # v05_03CD: guard ZIG for non-zig variants (win_64-gcc, win_64-vs2022)
       if [[ -n "${ZIG:-}" ]] || command -v "${ZIG:-}" >/dev/null 2>&1; then
         echo "  Using Zig cross-compilation for ${target} (native zig + -target)"
         local _native_zig
         case "${target}" in
             x86_64-w64-mingw32*)   _zig_target="x86_64-windows-gnu" ;;
             aarch64-w64-mingw32*)  _zig_target="aarch64-windows-gnu" ;;
             x86_64-apple-darwin*)  _zig_target="x86_64-macos-none" ;;
             arm64-apple-darwin*)   _zig_target="aarch64-macos-none" ;;
             *-conda-linux-gnu*)    _zig_target="${1%%-conda-linux-gnu*}-linux-gnu" ;;
             *)                     _zig_target="${target}" ;;  # pass through as-is
         esac
         # W3VV: For NATIVE toolchain in CROSS-COMPILE mode only, prefer the build-host-arch
         # zig binary. ZIG would point at the cross-target arch zig in cross-compile mode,
         # but a NATIVE_CC binary must EXECUTE on the build machine. Path is normalized
         # backslash-to-forward-slash for make/sh compatibility on Windows.
         # Restricted to (build_platform != target_platform) so the win-64 native variant
         # (which was passing pre-W3UU) keeps its original ZIG selection.
         _native_zig="${ZIG//\\//}"
         if [[ "${1}" == "NATIVE" ]] && [[ "${build_platform:-}" != "${target_platform:-}" ]]; then
             case "${build_platform:-${target_platform}}" in
                 win-64)    _w3vv_host_zig="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe" ;;
                 win-arm64) _w3vv_host_zig="${BUILD_PREFIX}/Library/bin/aarch64-w64-mingw32-zig.exe" ;;
                 *)         _w3vv_host_zig="" ;;
             esac
             if [[ -n "${_w3vv_host_zig:-}" ]] && [[ -x "${_w3vv_host_zig}" ]]; then
                 _native_zig="${_w3vv_host_zig//\\//}"
                 echo "  [W3VV] NATIVE cross-compile: using build-host zig: ${_native_zig}"
             fi
             unset _w3vv_host_zig
             # W4AB: also override _zig_target to match build host arch
             # (W3VV picked the right binary; without this, target stays as host triplet
             #  and produces wrong-arch PE that cannot run on build host)
             case "${build_platform:-${target_platform}}" in
                 win-64)     _zig_target="x86_64-windows-gnu" ;;
                 win-arm64)  _zig_target="aarch64-windows-gnu" ;;
                 linux-64)   _zig_target="x86_64-linux-gnu" ;;
                 linux-aarch64) _zig_target="aarch64-linux-gnu" ;;
                 osx-64)     _zig_target="x86_64-macos" ;;
                 osx-arm64)  _zig_target="aarch64-macos" ;;
             esac
             echo "[W4AC] NATIVE cross-compile detected: _native_zig=${_native_zig} _zig_target=${_zig_target} build_platform=${build_platform}"
         fi
         _CC="${_native_zig} cc -target ${_zig_target}"
         _AS="${_native_zig} cc -target ${_zig_target}"
         _AR="${ZIG_AR:+${ZIG_AR//\\//}}"
         _AR="${_AR:-${_native_zig} ar}"
         _LD="${_native_zig} cc -target ${_zig_target}"
         _NM="${_native_zig} nm"
         # Derive ranlib from ar path: zig-ar.bat → zig-ranlib.bat, zig-ar → zig-ranlib
         if [[ -n "${ZIG_AR:-}" ]]; then
           _RANLIB="${ZIG_AR//\\//}"
           _RANLIB="${_RANLIB/zig-ar/zig-ranlib}"
         else
           _RANLIB="${_native_zig} ranlib"
         fi
         _STRIP="echo strip-skipped"
         unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS 2>/dev/null || true
       elif find_tool "${target}-gcc" false >/dev/null 2>&1; then
         _AR=$(find_tool "${target}-ar" true)
         _AS=$(find_tool "${target}-as" true)
         _CC=$(find_tool "${target}-gcc" true)
         _LD=$(find_tool "${target}-ld" true)
         _NM=$(find_tool "${target}-nm" true)
         _RANLIB=$(find_tool "${target}-ranlib" true)
         _STRIP=$(find_tool "${target}-strip" true)
       elif find_tool "${target}-zig" false >/dev/null 2>&1 || command -v "${target}-zig" >/dev/null 2>&1; then
         # Target-specific zig wrapper (injects -target automatically)
         echo "  Using Zig toolchain for ${target} (triplet-prefixed)"
         local _zig
         _zig=$(find_tool "${target}-zig" false 2>/dev/null || command -v "${target}-zig")
         _CC="${_zig} cc"
         _AS="${_zig} cc"
         _AR="${ZIG_AR:+${ZIG_AR//\\//}}"
         _AR="${_AR:-${_zig} ar}"
         _LD="${_zig} cc"
         _NM="${_zig} nm"
         if [[ -n "${ZIG_AR:-}" ]]; then
           _RANLIB="${ZIG_AR//\\//}"
           _RANLIB="${_RANLIB/zig-ar/zig-ranlib}"
         else
           _RANLIB="${_zig} ranlib"
         fi
         _STRIP="echo strip-skipped"
         unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS 2>/dev/null || true
       else
         echo "ERROR: No mingw toolchain found for ${target}"
         echo "  Searched for: ${target}-gcc (find_tool), ${target}-zig (find_tool + PATH)"
         exit 1
       fi

       _ASM=$(basename "${_AS:-${_CC}}")

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
  export "${name}_AR=${_AR}" "${name}_AS=${_AS}" "${name}_RANLIB=${_RANLIB}"
  # W7EE: on the win-arm64 bootstrap-native path, bootstrap-fallback-native.sh forces
  # target_platform=build_platform, which skips the W3VV host-zig override above (guard
  # requires build_platform != target_platform). setup_toolchain then recomputes _CC from
  # the still-arm64-targeted ZIG and would clobber the correct x86_64 host NATIVE_CC that
  # build.sh's _w3ff_ensure_host_native_cc already exported before this call. Preserve it
  # instead of overwriting, but ONLY when role=NATIVE, build host is win-64, and the current
  # NATIVE_CC already matches the exact x86_64-host zig invocation _w3ff sets. Every other
  # path (role != NATIVE, non-win-64 build host, NATIVE_CC not pre-set to this exact form,
  # gcc/vs variants) falls through to the original unconditional export unchanged.
  #
  # W7FF REGRESSION FIX: the W7EE guard above was under-restrictive and also fired on the
  # PLAIN win-64 TARGET job (build_platform==target_platform==win-64, role=NATIVE), where
  # NATIVE_CC legitimately matches the x86_64-host substring. Skipping the export there kept
  # _w3ff's raw-${BUILD_PREFIX} NATIVE_CC (native Windows backslashes, NOT normalized) instead
  # of the backslash-normalized _CC computed at line 568, so /bin/sh -c ate the backslashes
  # in make recipes (C:\bld\... -> C:bld...zig.exe: No such file or directory), breaking
  # world.opt. The true intent is "do not clobber the x86_64 host CC with an ARM64 _CC", so
  # gate additionally on _CC NOT already being x86_64: on the plain win-64 job _CC targets
  # x86_64-windows-gnu (condition false -> normal export, regression fixed); on the win-arm64
  # bootstrap-native path _CC targets aarch64-windows-gnu (condition true -> preserve x86_64
  # host CC, W7EE behaviour retained). Most-restrictive guard per shared-helper-scope rule.
  if [[ "${1}" == "NATIVE" && "${build_platform:-}" == "win-64" && "${NATIVE_CC:-}" == *"x86_64-w64-mingw32-zig.exe cc -target x86_64-windows-gnu"* && "${_CC}" != *"x86_64-windows-gnu"* ]]; then
      echo "[W7EE/W7FF] setup_toolchain: preserving host-x86_64 NATIVE_CC set by _w3ff (${NATIVE_CC}); NOT clobbering with ${_CC} (arm64 on the win-arm64 bootstrap-native path)"
  else
      export "${name}_CC=${_CC}"
  fi
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
    DEFAULT_MKEXE="${DEFAULT_CC} -Wl,-headerpad_max_install_names -Wl,-rpath,@executable_path/../lib \${LDFLAGS}"
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

  # Build-time path markers to clean (conda-bld, rattler-build, placeholders, env dirs)
  local markers=(
    "rattler-build" "conda-bld" "build_artifacts" "placehold"
    "host_env" "build_env" "_build_env" "feedstock"
  )

  # Remove -L and -Wl,-L paths containing build directories
  sed -i 's|-L/[^ ]*/lib ||g' "${config_file}"
  sed -i 's|-Wl,-L[^ ]* ||g' "${config_file}"
  for marker in "${markers[@]}"; do
    sed -i "s|-L[^ ]*${marker}[^ ]* ||g" "${config_file}"
  done

  # CRITICAL: Remove CONFIGURE_ARGS - it contains build-time paths
  sed -i '/^CONFIGURE_ARGS=/d' "${config_file}"
  echo "CONFIGURE_ARGS=# Removed - contained build-time paths" >> "${config_file}"

  # Replace absolute /home/ paths with prefix
  sed -i "s|/home/[^/]*/feedstock_root[^[:space:]]*|${prefix}|g" "${config_file}"
  sed -i "s|/home/[^/]*/feedstock[^[:space:]]*|${prefix}|g" "${config_file}"
  sed -i "s|/home/[^/]*/build_artifacts[^[:space:]]*|${prefix}|g" "${config_file}"
  sed -i "s|/home/conda/feedstock_root[^[:space:]]*|${prefix}|g" "${config_file}"

  # For each marker: replace standalone paths, strip -isystem/-I/-L references,
  # delete standalone lines starting with the marker
  for marker in "${markers[@]}"; do
    sed -i "s|[^[:space:]]*${marker}[^[:space:]]*|${prefix}|g" "${config_file}"
    sed -i "s|-isystem [^[:space:]]*${marker}[^[:space:]]*||g" "${config_file}"
    sed -i "s|-I[^[:space:]]*${marker}[^[:space:]]*||g" "${config_file}"
    sed -i "s|-L[^[:space:]]*${marker}[^[:space:]]*||g" "${config_file}"
    sed -i "\\|^/[^[:space:]]*${marker}|d" "${config_file}"
  done

  # Delete orphaned lines that are only the prefix
  sed -i '/^'"${prefix//\//\\/}"'$/d' "${config_file}"
  sed -i '\|^/home/[^/]*/feedstock|d' "${config_file}"

  # Final grep-based cleanup for any remaining build markers
  local temp_file="${config_file}.final_clean"
  local grep_pattern="rattler-build|conda-bld|/home/[^/]+/feedstock|host_env_placehold|build_env_placehold"
  if grep -qE "${grep_pattern}" "${config_file}" 2>/dev/null; then
    grep -vE "${grep_pattern}" "${config_file}" > "${temp_file}" 2>/dev/null
    if [[ -s "${temp_file}" ]]; then
      mv "${temp_file}" "${config_file}"
    else
      rm -f "${temp_file}"
    fi
  fi

  # OCaml 5.4+: Strip $(LDFLAGS) from MKEXE/MKDLL/MKMAINDLL.
  # OCaml 5.4 added $(LDFLAGS) to these variables, which leaks conda-forge platform
  # flags (-fuse-ld=lld on macOS, MSVC /nologo on Windows) into downstream builds.
  # OCaml's own flags are in $(OC_LDFLAGS) which is sufficient.
  sed -i 's| \$(LDFLAGS)||g' "${config_file}"

  # Clean up whitespace: collapse multiple spaces, remove empty lines
  sed -i 's|  *| |g' "${config_file}"
  sed -i '/^[[:space:]]*$/d' "${config_file}"
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

  # v05_03BN: use python3 with fallback to python (Windows conda envs only have 'python')
  local _bn_py="${PYTHON:-}"
  if [[ -z "$_bn_py" ]] || ! command -v "$_bn_py" >/dev/null 2>&1; then
    if command -v python3 >/dev/null 2>&1; then _bn_py=python3
    elif command -v python >/dev/null 2>&1; then _bn_py=python
    else echo "ERROR: no python interpreter found" >&2; return 1; fi
  fi
  "$_bn_py" -c "
import sys
path, new_bindir = sys.argv[1], sys.argv[2].encode()

with open(path, 'rb') as f:
    data = f.read()

# v05_03BO: tolerate empty / malformed files (e.g. win-arm64 stub with
# SKIP_TMPHEADER_BUILD=true means runtime-launch-info has no real format).
if len(data) == 0:
    print(f'  runtime-launch-info: empty file, skipping cleanup')
    sys.exit(0)

# Find first and second newlines
try:
    first_nl = data.index(b'\n')
    second_nl = data.index(b'\n', first_nl + 1)
except ValueError:
    print(f'  runtime-launch-info: missing expected newline structure (size={len(data)} bytes), skipping')
    sys.exit(0)

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
  # Strip ONLY build-sandbox -L paths (conda-bld/rattler-build/build_env).
  # A relocatable -L${PREFIX}/lib MUST SURVIVE: lib/ocaml/Makefile.config is
  # declared prefix_detection force_file_type: text (recipe.yaml), so conda
  # rewrites the prefix at install time. Stripping every -L unconditionally
  # breaks the test-time relink on native Linux lanes (cannot find -lzstd).
  # macOS is unaffected because conda-ocaml-mkexe re-supplies -L at runtime,
  # but build.sh leaves CONDA_OCAML_MKEXE unset on Linux.
  sed -Ei 's#-L[^ ]*(conda-bld|rattler-build|build_env)[^ ]*##g' "${config_file}"
  # These would be found in BUILD_PREFIX and fail relocation
  # Remove prepended binaries path (could be BUILD_PREFIX non-relocatable)
  # Simple commands: CC, AS, ASM, ASPP, STRIP (line ends with binary name)
  sed -Ei 's#^(CC|AS|ASM|ASPP|STRIP)=/.*/([^/]+)$#\1=\2#' "${config_file}"
  # CPP has flags after binary (e.g., "/path/to/clang -E -P" -> "clang -E -P")
  # The ( .*)? is optional to handle CPP without flags
  sed -Ei 's#^(CPP)=/.*/([^/ ]+)( .*)?$#\1=\2\3#' "${config_file}"

  # Strip GCC-specific linker flags that crash zig's lld (all build modes):
  #   -l:libpthread.a  — colon syntax (exact filename) is GNU ld extension that
  #                      triggers zig's "reached unreachable code" panic
  #   -lgcc_eh         — GCC exception handling library; zig doesn't ship this
  #   -lgcc            — GCC runtime; zig uses compiler_rt internally
  #   -lmingwex        — MinGW extended C lib; zig's libc covers it
  #   -lmingw32        — MinGW core lib; zig's libc covers it
  # All are unnecessary with zig: Windows native threads replace pthreads,
  # and zig provides its own unwinding. This guard is safe on all platforms
  # because none of these flags appear in non-zig (GCC/clang) Makefile.config outputs.
  # ORDER: strip -lgcc_eh before bare -lgcc so "_eh" is not left orphaned.
  if ! is_unix && [[ -f "${config_file}" ]]; then
    if grep -qE '\-l:libpthread\.a|\-lgcc_eh|\-lgcc|\-lmingwex|\-lmingw32' "${config_file}"; then
      echo "[zig-unreachable-workaround] stripping -l:libpthread.a, -lgcc_eh, -lgcc, -lmingwex, -lmingw32 from Makefile.config"
      echo "=== DIAG: BYTECCLIBS pre-strip ==="
      grep '^BYTECCLIBS=' "${config_file}" || echo "(no BYTECCLIBS line)"
      echo "=== DIAG: NATIVECCLIBS pre-strip ==="
      grep '^NATIVECCLIBS=' "${config_file}" || echo "(no NATIVECCLIBS line)"
      # [W7VV] round 59: finish what W7UU started. W7UU (round 58) deleted -l:libpthread.a
      # only from utils/config.generated.ml; build 1565826 log 60 then showed BYTECCLIBS
      # pre-strip `-l:libpthread.a` -> post-strip `-lpthread` (lines 1079-1098), i.e. THIS
      # rewrite kept manufacturing the bare flag, and the cross-flexdll HOST self-link died
      # on `lld-link: error: pthread_cancel was replaced` at log:10100. Guard verified on the
      # same build: [W7UU] fired only in the win-arm64 native log (host_platform=win-arm64,
      # log:962) and never in the green win-64 log (host_platform=win-64, log:988), so this
      # guard cannot leak into a green lane (feedback_shared_helper_scope).
      echo "  [W7VV-DIAG] observed host_platform='${host_platform:-<unset>}' target_platform='${target_platform:-<unset>}' build_platform='${build_platform:-<unset>}'"
      if [[ "${host_platform:-}" == "win-arm64" ]]; then
        _w7vv_pthread_sed='s/ -l:libpthread\.a//g'
        echo "  [W7VV] win-arm64 NATIVE: DELETING -l:libpthread.a from ${config_file} (zig auto-links its own winpthreads)"
      else
        _w7vv_pthread_sed='s/ -l:libpthread\.a/ -lpthread/g'
      fi
      sed -i \
        -e "${_w7vv_pthread_sed}" \
        -e 's/ -lgcc_eh\([[:space:]]\|$\)/\1/g;
            s/ -lgcc\([[:space:]]\|$\)/\1/g;
            s/ -lmingwex\([[:space:]]\|$\)/\1/g;
            s/ -lmingw32\([[:space:]]\|$\)/\1/g' \
        "${config_file}"
      echo "=== DIAG: BYTECCLIBS post-strip ==="
      grep '^BYTECCLIBS=' "${config_file}" || echo "(no BYTECCLIBS line)"
      echo "=== DIAG: NATIVECCLIBS post-strip ==="
      grep '^NATIVECCLIBS=' "${config_file}" || echo "(no NATIVECCLIBS line)"
    fi
  fi

  # Strip the same GCC-specific flags from config.status (autoconf re-run script).
  # config.status stores S["PTHREAD_LIBS"] and S["cclibs"] values that autoconf
  # re-injects into Makefile.config / config.generated.ml whenever make detects
  # stale configure/config.status timestamps.  Without this strip, a timestamp
  # re-run silently undoes every Makefile.config strip we applied above.
  # The S["..."]= lines use shell-quoted double-quoted values, so the boundary
  # class [[:space:]"] covers both whitespace between flags and the closing ".
  # ORDER: whole-line empties FIRST (S["PTHREAD_LIBS"], S["link_gcc_eh"],
  # S["LIBS"]) so the space-prefixed patterns below never see those values.
  # Then -lgcc_eh before bare -lgcc so the "_eh" suffix is not left orphaned.
  #
  # S["PTHREAD_LIBS"] fix: the existing pattern ' -l:libpthread.a' required a
  # leading space, but in S["PTHREAD_LIBS"] the value starts directly after '"'
  # (no leading space), so '-l:libpthread.a' survived.  Zig bundles pthread
  # support via its libc, so the safe fix is to empty the variable entirely.
  #
  # Makefile.config PTHREAD_LIBS direct-patch (defense-in-depth): even after
  # config.status is stripped, some make rules re-read Makefile.config entries
  # that were written before configure finished.  Ensure the Makefile.config
  # PTHREAD_LIBS line is also normalized.
  # is_unix guard added while porting: PR97's block was unconditional and would
  # force PTHREAD_LIBS on every native/cross Linux and osx build.
  if ! is_unix; then
    if [[ -f Makefile.config ]]; then
      if [[ "${host_platform:-}" == "win-arm64" ]]; then
        # [W7VV] round 59: empty it rather than forcing -lpthread. The comment above already
        # says zig bundles pthread support via its libc, so forcing the flag back in re-created
        # the very reference the strip above removes.
        sed -i 's|^PTHREAD_LIBS=.*|PTHREAD_LIBS=|' Makefile.config || true
        echo "  [W7VV] win-arm64 NATIVE: PTHREAD_LIBS emptied (was forced to -lpthread)"
      else
        sed -i 's|^PTHREAD_LIBS=.*|PTHREAD_LIBS=-lpthread|' Makefile.config || true
      fi
    fi
  fi

  # W5S 2026-07-14: on Windows, MSYS2 arg-conversion leaves AR/RANLIB/LD/PARTIALLD as
  # BACKSLASH paths in Makefile.config (MSYS2_ARG_CONV_EXCL is only set on the -pc- branch).
  # /bin/sh then eats the backslashes at MKLIB time (Makefile:1412), mangling the ar path
  # to a non-existent one (win-64 gcc MKLIB Error 127). NATIVE_AR itself is forward-slash;
  # only the Makefile.config copy is corrupted. Normalize backslashes to forward slashes for
  # these tool vars (no-op on unix, where these lines never contain backslashes). RANLIB is
  # included because OCaml's MKLIB rule is `$(AR) rc ... && $(RANLIB) ...` (same rule).
  if ! is_unix; then
    if [[ -f Makefile.config ]]; then
      sed -Ei '/^(AR|RANLIB|LD|PARTIALLD)=/ s#\\#/#g' Makefile.config || true
    fi
  fi

  # is_unix guard added while porting: PR97's config.status strip block was
  # unconditional and would force these substitutions on every native/cross
  # Linux and osx build.
  if ! is_unix; then
    if [[ -f config.status ]]; then
      echo "=== DIAG: config.status S[\"PTHREAD_LIBS\"] / S[\"cclibs\"] / S[\"LIBS\"] / S[\"link_gcc_eh\"] pre-strip ==="
      grep -E '^S\["(PTHREAD_LIBS|cclibs|LIBS|link_gcc_eh)"\]=' config.status || echo "(no matching lines)"
      # [W7VV] round 59: same delete-vs-rewrite choice as the Makefile.config block above.
      if [[ "${host_platform:-}" == "win-arm64" ]]; then
        _w7vv_cfgstatus_sed='/^S\[".*"\]=/s/ -l:libpthread\.a//g'
      else
        _w7vv_cfgstatus_sed='/^S\[".*"\]=/s/ -l:libpthread\.a/ -lpthread/g'
      fi
      sed -i \
        -e 's|^S\["PTHREAD_LIBS"\]=".*"$|S["PTHREAD_LIBS"]=""|' \
        -e 's|^S\["link_gcc_eh"\]=".*"$|S["link_gcc_eh"]=""|' \
        -e '/^S\["LIBS"\]=.*\(-lgcc\|-l:libpthread\.a\)/s|^S\["LIBS"\]=".*"$|S["LIBS"]=""|' \
        -e "${_w7vv_cfgstatus_sed}" \
        -e '/^S\[".*"\]=/s/ -lgcc_eh\([[:space:]"]\|$\)/\1/g' \
        -e '/^S\[".*"\]=/s/ -lgcc\([[:space:]"]\|$\)/\1/g' \
        -e '/^S\[".*"\]=/s/ -lmingwex\([[:space:]"]\|$\)/\1/g' \
        -e '/^S\[".*"\]=/s/ -lmingw32\([[:space:]"]\|$\)/\1/g' \
        config.status
      echo "=== DIAG: config.status S[\"PTHREAD_LIBS\"] / S[\"cclibs\"] / S[\"LIBS\"] / S[\"link_gcc_eh\"] post-strip ==="
      grep -E '^S\["(PTHREAD_LIBS|cclibs|LIBS|link_gcc_eh)"\]=' config.status || echo "(no matching lines)"
    fi
  fi
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

  # conda-ocaml-common is a SOURCED shared library, not an executable tool:
  # installed at 644 (not 755) into the same dir the wrappers land in, so
  # each wrapper's `. "$(dirname "$0")/conda-ocaml-common"` resolves at
  # runtime (wrappers are exec'd from PATH by ocamlopt/dune/flexlink in the
  # installed prefix, not sourced by the build).
  install -m 644 "${RECIPE_DIR}/scripts/conda-ocaml-common" "${dest_bin_dir}/conda-ocaml-common"

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
      # Unconditional prepend, matching pre-PR103W behaviour exactly. Runs
      # FIRST (before the TARGET_ZSTD_LIB block below) because each export
      # here PREPENDS: whichever export runs LAST ends up FIRST in the
      # resulting search order. A duplicate ${BUILD_PREFIX}/lib entry may
      # appear after the second call in build_cross_compiler() -- that is
      # harmless (dyld just searches the same directory twice) and is
      # strictly safer than de-duplicating here, which would reorder entries
      # and change dyld search order on the currently-GREEN osx lanes if
      # DYLD_FALLBACK_LIBRARY_PATH already contains this dir at a later
      # position. Do not "helpfully" dedupe it.
      export DYLD_FALLBACK_LIBRARY_PATH="${BUILD_PREFIX}/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
      # PR103W (2026-09-08): the in-tree x86_64 ocamlc.opt/ocamlopt.opt that
      # crossopt runs link libzstd via @rpath, and the only x86_64-arch
      # libzstd on osx-64 cross lanes lives in TARGET_ZSTD_LIB (build.sh
      # ~line 5926), not BUILD_PREFIX/lib. Prepend it LAST (after
      # BUILD_PREFIX/lib above) so it ends up FIRST in the search order and
      # resolves before BUILD_PREFIX/lib's host-arch libzstd -- the whole
      # point of this fix is that the x86_64 cross binary must find the
      # TARGET-arch libzstd before dyld ever has a chance to reject the
      # host-arch dylib on architecture mismatch. Guard is osx-cross-only and
      # directory-existence checked: PR103U regressed six GREEN linux cross
      # lanes by gating on "TARGET_ZSTD_LIBS non-empty" alone (true on linux
      # cross lanes too); this guard is additionally scoped inside the osx
      # branch so it cannot fire on linux lanes regardless of TARGET_ZSTD_LIB
      # contents there.
      if [[ -n "${TARGET_ZSTD_LIB:-}" && -d "${TARGET_ZSTD_LIB:-}" ]]; then
        # PR103W follow-up (2026-09-08): setup_dyld_fallback is now called
        # twice in build_cross_compiler() -- once at ~5702 (before
        # TARGET_ZSTD_LIB is assigned, so this branch is skipped) and again
        # after the zstd block (~5943, once TARGET_ZSTD_LIB is known). Only
        # this entry needs de-duplication (colon-delimited containment check,
        # so a substring of a longer path cannot false-match) to make the
        # second call idempotent for it; ${BUILD_PREFIX}/lib above is left
        # unconditional, see comment there.
        case ":${DYLD_FALLBACK_LIBRARY_PATH:-}:" in
          *":${TARGET_ZSTD_LIB}:"*) ;;  # already present - skip to avoid duplicate
          *) export DYLD_FALLBACK_LIBRARY_PATH="${TARGET_ZSTD_LIB}:${DYLD_FALLBACK_LIBRARY_PATH:-}" ;;
        esac
      fi
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
  # v05_03BK: convert Windows paths via cygpath when running under MSYS2;
  # tar interprets backslashes/colons as remote-host syntax otherwise.
  local _bk_src="${src_dir}" _bk_dst="${dest_dir}"
  if command -v cygpath >/dev/null 2>&1; then
    _bk_src="$(cygpath -u "${src_dir}")"
    _bk_dst="$(cygpath -u "${dest_dir}")"
  fi
  mkdir -p "${_bk_dst}"
  # v05_03BM/BU: --dereference only on Windows (MSYS2 tar can't recreate symlinks).
  # Unix builds keep symlinks - preserving original/correct packaging behavior.
  local _bu_tar_extra=""
  if command -v cygpath >/dev/null 2>&1; then
    _bu_tar_extra="--dereference"
  fi
  tar -C "${_bk_src}" ${_bu_tar_extra} -cf - . | tar -C "${_bk_dst}" -xf -

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

  # ocamlobjinfo is a TARGET binary on cross lanes, so it only runs under
  # emulation. Prefer an explicit qemu-execve (OCAML_QEMU, from recipe.yaml's
  # ${{ qemu }}) over binfmt_misc, which dispatches to the image's REGISTERED
  # interpreter. QEMU_LD_PREFIX must be exported outside any subshell for this
  # to resolve dynamic loaders correctly. OCAML_QEMU is empty on native lanes,
  # where the prefix disappears entirely.
  local -a _runner=()
  if [[ -n "${OCAML_QEMU:-}" ]] && command -v "${OCAML_QEMU}" >/dev/null 2>&1; then
    _runner=("${OCAML_QEMU}")
  fi

  # Capture stdout+stderr TOGETHER into a variable, then filter the variable -
  # do NOT fold `2>&1` into a pipeline feeding grep. The old form did, which sent
  # the emulator's own error text into grep where it was silently discarded,
  # producing an empty CRC with no diagnostic. The `|| true` guards also matter:
  # under `set -e` a no-match grep aborted the script before the [FAIL] block
  # below could print anything at all.
  local unix_out threads_out
  unix_out=$({ "${_runner[@]}" "${ocamlobjinfo_path}" "${unix_cmxa}"; } 2>&1) || true
  threads_out=$({ "${_runner[@]}" "${ocamlobjinfo_path}" "${threads_cmxa}"; } 2>&1) || true

  # Extract Unix implementation CRC from unix.cmxa
  local unix_crc
  unix_crc=$(printf '%s\n' "${unix_out}" \
    | grep -A1 "^Name: Unix$" | grep "CRC of implementation" | awk '{print $NF}') || true

  # Extract what threads.cmxa expects from Unix (implementation CRC)
  # Must scope to "Implementations imported" section to avoid matching interface CRCs
  local threads_crc
  threads_crc=$(printf '%s\n' "${threads_out}" \
    | sed -n '/^Implementations imported:/,/^[A-Z]/p' \
    | grep -E "^\s+[a-f0-9]+\s+Unix$" | awk '{print $1}' | head -1) || true

  if [[ "${unix_crc}" == "${threads_crc}" && -n "${unix_crc}" ]]; then
    echo "    [PASS] ${label}: unix CRC match (${unix_crc})"
  else
    echo "    [FAIL] ${label}: unix CRC mismatch"
    echo "           unix.cmxa    CRC: ${unix_crc:-<empty>}"
    echo "           threads.cmxa expects: ${threads_crc:-<empty>}"
    echo "           runner: ${_runner[*]:-<none, direct exec>}"
    echo "           --- ocamlobjinfo output on unix.cmxa (first 5 lines) ---"
    printf '%s\n' "${unix_out}" | head -5 | sed 's/^/           /'
    exit 1
  fi
}

# Build cache functions (extracted for clarity)
source "${RECIPE_DIR}/building/build-cache.sh"
