#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# OCaml Build Script - GCC Pattern Multi-Output (Unified)
# ==============================================================================
#
# BUILD MODE DETECTION (gcc-style):
#
# Package name indicates TARGET platform (e.g., ocaml_linux-aarch64)
# Build behavior depends on BUILD platform:
#
# MODE="native":
#   OCAML_TARGET_PLATFORM == target_platform (e.g., ocaml_linux-64 on linux-64)
#   → Build native OCaml compiler
#
# MODE="cross-compiler":
#   OCAML_TARGET_PLATFORM != target_platform (e.g., ocaml_linux-aarch64 on linux-64)
#   → Build cross-compiler (native binaries producing target code)
#
# MODE="cross-target":
#   OCAML_TARGET_PLATFORM == target_platform AND CONDA_BUILD_CROSS_COMPILATION == 1
#   (e.g., ocaml_linux-aarch64 built ON linux-aarch64 via cross-compilation)
#   → Build using cross-compiler from BUILD_PREFIX
#
# Environment variables from recipe.yaml:
#   OCAML_TARGET_PLATFORM:  Target platform this package produces code for
#   OCAML_TARGET_TRIPLET: Cross-compiler triplet for this target
#
# Build functions are defined inline below (consolidated from building/_build_*_function.sh):
#   build_native()           - Native OCaml compiler build
#   build_cross_compiler()   - Cross-compiler build (native binaries for target code)
#   build_cross_target()     - Cross-compiled native build using cross-compiler from BUILD_PREFIX
#
# ==============================================================================

# ==============================================================================
# CRITICAL: Ensure we're using conda bash 5.2+, not system bash
# ==============================================================================
if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  echo "re-exec with conda bash..."
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

source "${RECIPE_DIR}"/building/common-functions.sh
source "${RECIPE_DIR}"/building/fix-ocamlrun-shebang.sh

# ============================================================================
# Early CFLAGS/LDFLAGS Sanitization
# ============================================================================
# conda-build cross-compilation can produce CFLAGS with mixed-arch flags:
#   -march=nocona -mtune=haswell (x86) ... -march=armv8-a (arm)
# This causes errors like "unknown architecture 'nocona'" on aarch64 compilers.
# Sanitize at the very start to clean ALL uses of CFLAGS throughout the build.
if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
  _target_arch=$(get_arch_for_sanitization "${target_platform}")
  echo ""
  echo "=== Sanitizing CFLAGS/LDFLAGS for ${_target_arch} ==="
  echo "Before: CFLAGS contains $(echo "${CFLAGS:-}" | grep -oE '\-march=[^ ]+' | head -3 | tr '\n' ' ')"
  sanitize_and_export_cross_flags "${_target_arch}"
  echo "After:  CFLAGS contains $(echo "${CFLAGS:-}" | grep -oE '\-march=[^ ]+' | head -3 | tr '\n' ' ')"
fi

# Platform detection (must be after sourcing common-functions.sh for is_unix)
if is_unix; then
  EXE=""
  SH_EXT="sh"
else
  EXE=".exe"
  SH_EXT="bat"
fi

mkdir -p "${SRC_DIR}"/_logs && export LOG_DIR="${SRC_DIR}"/_logs

# Enable dry-run and other options
CONFIGURE=(./configure)
MAKE=(make)

CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --enable-installing-source-artifacts
  --enable-installing-bytecode-programs
  PKG_CONFIG=false
)

# ==============================================================================
# Fix xlocale.h compatibility (removed in glibc 2.26, merged into locale.h)
# ==============================================================================
if [[ "$(uname)" == "Linux" ]] && grep -q 'xlocale\.h' runtime/floats.c 2>/dev/null; then
  echo "Patching runtime/floats.c: xlocale.h -> locale.h (glibc 2.26+ compat)"
  sed -i 's/#include <xlocale\.h>/#include <locale.h>/g' runtime/floats.c
fi

# ==============================================================================
# BUILD MODE DETECTION
# ==============================================================================
# OCAML_TARGET_PLATFORM and OCAML_TARGET_TRIPLET are set by recipe.yaml env section

echo ""
echo "============================================================"
echo "OCaml Build Script - Mode Detection"
echo "============================================================"
echo "  OCAML_TARGET_PLATFORM:         ${OCAML_TARGET_PLATFORM:-<not set>}"
echo "  OCAML_TARGET_TRIPLET:          ${OCAML_TARGET_TRIPLET:-<not set>}"
echo "  target_platform:               ${target_platform}"
echo "  build_platform:                ${build_platform:-${target_platform}}"
echo "  CONDA_BUILD_CROSS_COMPILATION: ${CONDA_BUILD_CROSS_COMPILATION:-0}"
echo "============================================================"

# Validate required environment variables
if [[ -z "${OCAML_TARGET_PLATFORM:-}" ]]; then
  echo "ERROR: OCAML_TARGET_PLATFORM not set. This should be set by recipe.yaml"
  exit 1
fi
if [[ -z "${OCAML_TARGET_TRIPLET:-}" ]]; then
  echo "ERROR: OCAML_TARGET_TRIPLET not set. This should be set by recipe.yaml"
  exit 1
fi

# Determine build mode
if [[ "${OCAML_TARGET_PLATFORM}" != "${target_platform}" ]]; then
  # Building cross-compiler (e.g., ocaml_linux-aarch64 on linux-64)
  BUILD_MODE="cross-compiler"
  echo ""
  echo ">>> BUILD MODE: cross-compiler"
  echo ">>> Building ${OCAML_TARGET_PLATFORM} cross-compiler on ${target_platform}"
  echo ""
elif [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
  # Building cross-compiled native (e.g., ocaml_linux-aarch64 ON linux-aarch64)
  BUILD_MODE="cross-target"
  echo ""
  echo ">>> BUILD MODE: cross-target"
  echo ">>> Cross-compiling ${OCAML_TARGET_PLATFORM} native compiler from ${build_platform:-${target_platform}}"
  echo ""
else
  # Building native (e.g., ocaml_linux-64 on linux-64)
  BUILD_MODE="native"
  echo ""
  echo ">>> BUILD MODE: native"
  echo ">>> Building native ${OCAML_TARGET_PLATFORM} compiler"
  echo ""
fi

# ==============================================================================
# Build Cache Status
# ==============================================================================
# Enable caching with OCAML_USE_CACHE=1 in environment or recipe
# Cache location: ${RECIPE_DIR}/.build_cache/
if cache_enabled; then
  echo "============================================================"
  echo "Build Cache: ENABLED"
  echo "============================================================"
  cache_status
  echo "============================================================"
  echo ""
else
  echo "  Build cache: disabled (set OCAML_USE_CACHE=1 to enable)"
  echo ""
fi

# ==============================================================================
# SHARED HELPERS
# ==============================================================================

# Export CONDA_OCAML_* cross-compilation env and add cross-tools to PATH.
# Used by both crossopt and installcross subshells in build_cross_compiler().
# NOTE: CONDA_OCAML_MKEXE gets the NATIVE linker here, not the cross one.
# It used to be left unset for that purpose, but "not setting" it stopped
# meaning "unset": an activated build dep (ocaml_osx-arm64) exports its own
# baked CONDA_OCAML_MKEXE, so declining to set it inherited that value - on
# osx a "<triplet>-gcc" that does not exist, which killed crossopt. Setting
# it explicitly overrides the inherited value; the :- keeps it safe under
# set -u, and an empty value still lets the wrapper fall back to the native
# linker, which is the original intent either way.
_setup_crossopt_env() {
  export CONDA_OCAML_AS="${CROSS_ASM}"
  export CONDA_OCAML_CC="${CROSS_CC}"
  export CONDA_OCAML_AR="${CROSS_AR}"
  export CONDA_OCAML_RANLIB="${CROSS_RANLIB}"
  export CONDA_OCAML_MKDLL="${CROSS_MKDLL}"
  export CONDA_OCAML_MKEXE="${NATIVE_MKEXE:-}"
  PATH="${OCAML_PREFIX}/bin:${PATH}"
  hash -r
}

# Generate _native_compiler_env.sh with basenames for portability.
# Called from build_native() and cache restore path.
generate_native_env_file() {
  cat > "${SRC_DIR}/_native_compiler_env.sh" << EOF
# Generated by generate_native_env_file() - uses basenames for portability
export NATIVE_AR="${NATIVE_AR##*/}"
export NATIVE_AS="${NATIVE_AS##*/}"
export NATIVE_ASM="${NATIVE_ASM##*/}"
export NATIVE_CC="${NATIVE_CC##*/}"
export NATIVE_CFLAGS="${NATIVE_CFLAGS}"
export NATIVE_LD="${NATIVE_LD##*/}"
export NATIVE_LDFLAGS="${NATIVE_LDFLAGS}"
export NATIVE_RANLIB="${NATIVE_RANLIB##*/}"
export NATIVE_STRIP="${NATIVE_STRIP##*/}"

# CONDA_OCAML_* for runtime - basenames
# NOTE: MKEXE/MKDLL contain flags with paths (e.g. -Wl,-rpath,@executable_path/../lib)
# so ##*/ would strip to just "lib". setup_toolchain already uses basename for the command.
export CONDA_OCAML_AR="${CONDA_OCAML_AR##*/}"
export CONDA_OCAML_AS="${CONDA_OCAML_AS##*/}"
export CONDA_OCAML_CC="${CONDA_OCAML_CC##*/}"
export CONDA_OCAML_LD="${CONDA_OCAML_LD##*/}"
export CONDA_OCAML_RANLIB="${CONDA_OCAML_RANLIB##*/}"
export CONDA_OCAML_MKEXE="${CONDA_OCAML_MKEXE}"
export CONDA_OCAML_MKDLL="${CONDA_OCAML_MKDLL}"
EOF
}

# Generate _xcross_compiler_<target>_env.sh with basenames for portability.
# Called from build_cross_compiler() and cache restore path.
# Usage: generate_xcross_env_file <target_name>
generate_xcross_env_file() {
  local target_name="$1"
  cat > "${SRC_DIR}/_xcross_compiler_${target_name}_env.sh" << EOF
# Generated by generate_xcross_env_file() - uses basenames for portability
export CROSS_AR="${CROSS_AR##*/}"
export CROSS_AS="${CROSS_AS##*/}"
export CROSS_ASM="${CROSS_ASM}"
export CROSS_CC="${CROSS_CC##*/}"
export CROSS_CFLAGS="${CROSS_CFLAGS}"
export CROSS_LD="${CROSS_LD##*/}"
export CROSS_LDFLAGS="${CROSS_LDFLAGS}"
export CROSS_RANLIB="${CROSS_RANLIB##*/}"
export CROSS_MKDLL="${CROSS_MKDLL}"
export CROSS_MKEXE="${CROSS_MKEXE}"
export CROSS_STRIP="${CROSS_STRIP##*/}"
export CROSS_NM="${CROSS_NM##*/}"
EOF
}

# Append -DARCH_BIG_ENDIAN=1 to a CFLAGS string when the cross target is
# big-endian, otherwise echo the string unchanged. Idempotent - calling it twice
# does not duplicate the flag. See the call sites in build_cross_compiler() and
# build_cross_target() for why the define cannot simply be patched into
# runtime/caml/m.h.
# Usage: CROSS_CFLAGS="$(add_big_endian_define "${CROSS_PLATFORM}" "${CROSS_CFLAGS:-}")"
add_big_endian_define() {
  local _platform="$1" _flags="${2:-}"
  case "${_platform}" in
    linux-s390x) ;;
    *) printf '%s' "${_flags}"; return 0 ;;
  esac
  if [[ "${_flags}" == *-DARCH_BIG_ENDIAN=1* ]]; then
    printf '%s' "${_flags}"
  else
    printf '%s' "${_flags% } -DARCH_BIG_ENDIAN=1"
  fi
}

# ==============================================================================
# BUILD FUNCTIONS
# ==============================================================================

# ==============================================================================
# build_native() - Build native OCaml compiler
# (formerly building/build-native.sh)
# ==============================================================================

build_native() {
  local -a CONFIG_ARGS=("${CONFIG_ARGS[@]}")

  # ============================================================================
  # Validate Environment
  # ============================================================================

  : "${OCAML_INSTALL_PREFIX:=${PREFIX}}"

  # Compiler activation should set CONDA_TOOLCHAIN_BUILD
  if [[ -z "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
    if [[ "${OCAML_TARGET_TRIPLET}" == *"-pc-"* ]]; then
      CONDA_TOOLCHAIN_BUILD="no-pc-toolchain"
    else
      echo "ERROR: CONDA_TOOLCHAIN_BUILD not set (compiler activation failed?)"
      exit 1
    fi
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
  setup_toolchain "NATIVE" "${CONDA_TOOLCHAIN_BUILD}"
  setup_cflags_ldflags "NATIVE" "${build_platform:-${target_platform}}" "${target_platform}"

  # Platform-specific overrides
  if [[ "${target_platform}" == "osx"* ]]; then
    # macOS: Use DYLD_FALLBACK_LIBRARY_PATH so OCaml can find libzstd at runtime
    # IMPORTANT: Use FALLBACK, not DYLD_LIBRARY_PATH - FALLBACK doesn't override system libs
    # Cross-compilation: BUILD_PREFIX has x86_64 libs for native compiler
    # Native build: PREFIX has x86_64 libs (same arch)
    # Note: fix-macos-install-names.sh unsets DYLD_* before running system tools
    setup_dyld_fallback
  elif [[ "${target_platform}" != "linux"* ]]; then
    [[ ${OCAML_INSTALL_PREFIX} != *"Library"* ]] && OCAML_INSTALL_PREFIX="${OCAML_INSTALL_PREFIX}"/Library
    echo "  Install:       ${OCAML_INSTALL_PREFIX}  <- Non-unix ..."

    if [[ "${OCAML_TARGET_TRIPLET}" != *"-pc-"* ]]; then
      NATIVE_WINDRES=$(find_tool "${CONDA_TOOLCHAIN_BUILD}-windres" true)
      [[ ! -f "${PREFIX}/Library/bin/windres.exe" ]] && cp "${NATIVE_WINDRES}" "${BUILD_PREFIX}/Library/bin/windres.exe"
    else
      NATIVE_WINDRES="rc.exe"
    fi

    # Set UTF-8 codepage
    export PYTHONUTF8=1
    # Needed to find zstd
    if [[ "${OCAML_TARGET_TRIPLET}" == *"-pc-"* ]]; then
      export NATIVE_LDFLAGS="/LIBPATH:${PREFIX}/Library/lib ${NATIVE_LDFLAGS:-}"
    else
      export NATIVE_LDFLAGS="-L${PREFIX}/Library/lib ${NATIVE_LDFLAGS:-}"
    fi
  fi

  print_toolchain_info NATIVE

  # ============================================================================
  # CONDA_OCAML_* Variables (Runtime Configuration)
  # ============================================================================

  # These are embedded in binaries and expanded at runtime
  # Users can override via environment variables
  export CONDA_OCAML_AR=$(basename "${NATIVE_AR}")
  export CONDA_OCAML_CC=$(basename "${NATIVE_CC}")
  export CONDA_OCAML_LD=$(basename "${NATIVE_LD}")
  export CONDA_OCAML_RANLIB=$(basename "${NATIVE_RANLIB:-echo}")
  # Special case, already a basename
  export CONDA_OCAML_AS="${NATIVE_ASM}"
  export CONDA_OCAML_MKEXE="${NATIVE_MKEXE}"
  export CONDA_OCAML_MKDLL="${NATIVE_MKDLL}"
  # non-unix-specific: windres for resource compilation
  export CONDA_OCAML_WINDRES="${NATIVE_WINDRES:-windres}"

  # ============================================================================
  # Export variables for downstream scripts
  # ============================================================================
  # Use basenames for tools so the env file is portable across builds
  generate_native_env_file

  # ============================================================================
  # Configure Arguments
  # ============================================================================

  #  --enable-native-toplevel
  CONFIG_ARGS+=(
    -prefix "${OCAML_INSTALL_PREFIX}"
    --mandir="${OCAML_INSTALL_PREFIX}"/share/man
  )

  # Enable ocamltest if running tests
  if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
    CONFIG_ARGS+=(--enable-ocamltest)
  else
    CONFIG_ARGS+=(--disable-ocamltest)
  fi

  # Add toolchain to configure args
  # NOTE: OCaml 5.4.0+ requires CFLAGS/LDFLAGS as environment variables, not configure args.
  # Passing them as args causes make to misparse flags like -O2 as filenames.
  # non-unix: pass BARE TOOL NAMES to configure, not absolute paths.
  # find_tool() returns an absolute path, and on Windows BUILD_PREFIX carries
  # backslashes. When make hands that string to /bin/sh the backslashes are eaten
  # as escapes, producing e.g.
  #   D:bldbldrattler-build_ocaml_win-64_...build_env/Library/bin/x86_64-w64-mingw32-ar.exe
  # -> "No such file or directory", make[1] Makefile:1412 libcamlrun_non_shared.a
  #    Error 127, make Makefile:852 world.opt Error 2.
  # Basenames resolve via PATH instead, so no path conversion (cygpath) is needed.
  # generate_native_env_file() already basenames these, but only inside the heredoc
  # it writes to _native_compiler_env.sh - the LIVE shell vars keep the full path.
  # GUARDED to non-unix only: unix lanes pass absolute paths today and work.
  if ! is_unix; then
    NATIVE_AR="${NATIVE_AR##*/}"
    NATIVE_AS="${NATIVE_AS##*/}"
    NATIVE_LD="${NATIVE_LD##*/}"
    NATIVE_RANLIB="${NATIVE_RANLIB##*/}"
    # CC/STRIP mangle the same way (e.g. Makefile:494 utils/domainstate.mli
    # Error 127, with .../x86_64-w64-mingw32-gcc.exe not found) - same
    # mechanism as AR above, so they get the same basename treatment.
    NATIVE_CC="${NATIVE_CC##*/}"
    NATIVE_STRIP="${NATIVE_STRIP##*/}"
    export NATIVE_AR NATIVE_AS NATIVE_LD NATIVE_RANLIB NATIVE_CC NATIVE_STRIP
    echo "  non-unix: using bare tool names AR=${NATIVE_AR} AS=${NATIVE_AS} LD=${NATIVE_LD} RANLIB=${NATIVE_RANLIB} CC=${NATIVE_CC} STRIP=${NATIVE_STRIP}"
  fi
  export CC="${NATIVE_CC}"
  export STRIP="${NATIVE_STRIP}"

  if [[ "${OCAML_TARGET_TRIPLET}" == *"-pc-"* ]]; then
    # MSVC: Let configure detect correct flags - don't inject GCC-style flags
    # cl.exe uses /O2, /LIBPATH: etc. - incompatible with GCC -O2, -L
    export CFLAGS=""
    export LDFLAGS="${NATIVE_LDFLAGS}"
    # Don't pass AS — configure's default for MSVC includes critical flags:
    #   "ml64 -nologo -Cp -c -Fo" (the trailing -Fo is concatenated with output path)
    CONFIG_ARGS+=(
      AR="${NATIVE_AR}"
      LD="${NATIVE_LD}"
    )
  else
    export CFLAGS="${NATIVE_CFLAGS}"
    export LDFLAGS="${NATIVE_LDFLAGS}"
    CONFIG_ARGS+=(
      AR="${NATIVE_AR}"
      AS="${NATIVE_AS}"
      LD="${NATIVE_LD}"
      RANLIB="${NATIVE_RANLIB}"
      host_alias="${build_alias:-${host_alias:-${CONDA_TOOLCHAIN_BUILD}}}"
    )
  fi

  if is_unix; then
    CONFIG_ARGS+=(
      --enable-frame-pointers
    )
  else
    CONFIG_ARGS+=(
      --with-flexdll
      WINDRES="${NATIVE_WINDRES}"
      windows_UNICODE_MODE=compatible
    )
    if [[ "${OCAML_TARGET_TRIPLET}" == *"-pc-"* ]]; then
      # MSVC: --build=cygwin (MSYS2 build env), --host=windows (MSVC target)
      # This is how OCaml detects MSVC mode and uses /Fe: instead of -o
      CONFIG_ARGS+=(
        --build=x86_64-pc-cygwin
        --host="${OCAML_TARGET_TRIPLET}"
      )
    fi
  fi

  # ============================================================================
  # Install conda-ocaml-* wrapper scripts BEFORE build (needed during compilation)
  # ============================================================================

  if is_unix; then
    echo "  Installing conda-ocaml-* wrapper scripts to BUILD_PREFIX..."
    install_conda_ocaml_wrappers "${BUILD_PREFIX}/bin"
    # Debug: verify wrappers installed and environment set
    echo "  Wrapper scripts installed:"
    ls -la "${BUILD_PREFIX}/bin/conda-ocaml-"* 2>/dev/null || echo "    (none found!)"
    echo "  CONDA_OCAML_* environment:"
    echo "    CONDA_OCAML_AS=${CONDA_OCAML_AS:-<unset>}"
    echo "    CONDA_OCAML_CC=${CONDA_OCAML_CC:-<unset>}"
    echo "    CONDA_OCAML_AR=${CONDA_OCAML_AR:-<unset>}"
    echo "    CONDA_OCAML_RANLIB=${CONDA_OCAML_RANLIB:-<unset>}"
    echo "    CONDA_OCAML_MKEXE=${CONDA_OCAML_MKEXE:-<unset>}"
    echo "    CONDA_OCAML_MKDLL=${CONDA_OCAML_MKDLL:-<unset>}"
    echo "  PATH includes BUILD_PREFIX/bin: $(echo "$PATH" | grep -q "${BUILD_PREFIX}/bin" && echo "yes" || echo "NO!")"
  else
    # Non-unix: Build wrapper .exe files BEFORE configuring
    # These need to exist when config.generated.ml references them
    CC="${NATIVE_CC}" "${RECIPE_DIR}/building/build-wrappers.sh" "${BUILD_PREFIX}/Library/bin"
  fi

  # ============================================================================
  # Configure
  # ============================================================================

  # Set TARGET environment variables for configure
  # These tell OCaml where binaries/libraries will be at RUNTIME on the target system
  # conda-forge will relocate paths containing ${PREFIX}, but NOT paths with _native
  export TARGET_BINDIR="${PREFIX}/bin"
  export TARGET_LIBDIR="${PREFIX}/lib/ocaml"

  echo ""
  echo "  [1/4] Configuring native compiler"
  run_logged "configure" "${CONFIGURE[@]}" "${CONFIG_ARGS[@]}" -prefix="${OCAML_INSTALL_PREFIX}" || { cat config.log; exit 1; }

  # ============================================================================
  # Patch Makefile for OCaml 5.4.0 bug: CHECKSTACK_CC undefined
  # ============================================================================
  patch_checkstack_cc

  # ============================================================================
  # MSYS2 compatibility patches for MSVC toolchain
  # ============================================================================
  # MSYS2 causes two issues with MSVC tools in Makefile variables:
  # 1. Path conversion: /link flag → filesystem path of link.exe (breaks cl.exe)
  # 2. Name shadowing: bare "link" → MSYS2 coreutils link (hard link utility)
  if [[ "${OCAML_TARGET_TRIPLET}" == *"-pc-"* ]]; then
    # MSYS2 path conversion: /link is converted to the filesystem path of link.exe
    # (e.g., %BUILD_PREFIX%/Library/link), breaking cl.exe's /link flag that tells
    # it to pass remaining args to the linker. Using -link avoids this — cl.exe
    # accepts both / and - as option prefixes, but MSYS2 only converts /-prefixed args.
    echo "  Applying MSYS2 workarounds for MSVC toolchain..."
    # MSYS2 auto-converts /flag args to Windows paths when spawning non-MSYS2 binaries.
    # MSVC tools use /nologo, /link, /out: etc. which get mangled. Disable globally.
    export MSYS2_ARG_CONV_EXCL='*'
    # MSYS2's /usr/bin/link.exe (coreutils hard link) shadows MSVC's link.exe in PATH.
    # flexlink and OCaml's build system call bare "link" expecting MSVC's linker.
    # Hide MSYS2's link to prevent the collision.
    if [[ -f /usr/bin/link.exe ]]; then
      echo "  Hiding MSYS2 /usr/bin/link.exe (coreutils) to avoid shadowing MSVC link.exe"
      mv /usr/bin/link.exe /usr/bin/link.msys2.exe
    fi
    # MKLIB: configure uses "link -lib" which is MSVC syntax for "lib.exe".
    # Even with MSYS2 link hidden, use lib.exe directly for clarity.
    sed -i 's|^MKLIB=link -lib |MKLIB=lib.exe |' Makefile.config
  fi

  # ============================================================================
  # Patch config.generated.ml and Makefile.config
  # ============================================================================

  echo "  [2/4] Patching config for ocaml-* wrapper scripts"

  local config_file="utils/config.generated.ml"

  # Debug: Check native_compiler exists before patching
  echo "    config.generated.ml native_compiler: $(grep 'native_compiler' "$config_file" | head -1 || echo '(not found)')"

  # NOTE: Do NOT remove -L paths here - they're needed for the build.
  # The -L removal for the *_c_libraries values happens further down, still
  # BEFORE world.opt: world.opt compiles those values into the Config module,
  # so any edit made after it has no effect on `ocamlopt -config-var`.

  if is_unix; then
    # Unix: Use conda-ocaml-* wrapper scripts that expand CONDA_OCAML_* environment variables
    # This allows tools like Dune to invoke the compiler via Unix.create_process
    # (which doesn't expand shell variables) while still honoring runtime overrides
    patch_config_generated_ml_native
  elif [[ "${OCAML_TARGET_TRIPLET}" == *"-pc-"* ]]; then
    # MSVC: Don't override config.generated.ml — configure's defaults include
    # required flags (e.g., asm = "ml64 -nologo -Cp -c -Fo" where -Fo is
    # concatenated with the output path). The conda-ocaml wrapper mechanism
    # doesn't work for MSVC (no .exe wrappers built, flags can't be injected).
    echo "    Skipping config.generated.ml patching for MSVC (using configure defaults)"
  else
    # MinGW: Use conda-ocaml-*.exe wrapper executables
    # These read CONDA_OCAML_* environment variables at runtime.
    # Unlike Unix shell scripts, non-unix needs actual .exe wrappers because:
    # - CreateProcess doesn't expand %VAR% (only cmd.exe does)
    # - .bat files don't work as direct executables from CreateProcess
    sed -i 's/^let asm = .*/let asm = {|conda-ocaml-as.exe|}/' "$config_file"
    sed -i 's/^let c_compiler = .*/let c_compiler = {|conda-ocaml-cc.exe|}/' "$config_file"
    sed -i 's/^let ar = .*/let ar = {|conda-ocaml-ar.exe|}/' "$config_file"
    sed -i 's/^let ranlib = .*/let ranlib = {|conda-ocaml-ranlib.exe|}/' "$config_file"
    # NOTE: Do NOT override mkexe/mkdll/mkmaindll on non-unix!
    # These use flexlink which has complex behavior that shouldn't be wrapped.
    # Let OCaml+flexlink handle linking directly.
  fi

  # Clean up Makefile.config - remove embedded paths that cause issues
  patch_makefile_config_post_configure

  if [[ "${target_platform}" == "osx"* ]]; then
    # For cross-compilation, use BUILD_PREFIX (has x86_64 libs for native compiler)
    # For native build (osx-64), use PREFIX (same arch, normal behavior)
    if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
      _LIB_PREFIX="${BUILD_PREFIX}"
    else
      _LIB_PREFIX="${PREFIX}"
    fi

    local config_file="Makefile.config"

    # OC_LDFLAGS may not exist - append or create
    if grep -q '^OC_LDFLAGS=' "${config_file}"; then
      sed -i "s|^OC_LDFLAGS=\(.*\)|OC_LDFLAGS=\1 -Wl,-L${_LIB_PREFIX}/lib -Wl,-headerpad_max_install_names|" "${config_file}"
    else
      echo "OC_LDFLAGS=-Wl,-L${_LIB_PREFIX}/lib -Wl,-headerpad_max_install_names" >> "${config_file}"
    fi

    # These should exist - append to them
    sed -i "s|^NATIVECCLINKOPTS=\(.*\)|NATIVECCLINKOPTS=\1 -Wl,-L${_LIB_PREFIX}/lib -Wl,-headerpad_max_install_names|" "${config_file}"
    sed -i "s|^NATIVECCLIBS=\(.*\)|NATIVECCLIBS=\1 -L${_LIB_PREFIX}/lib -lzstd|" "${config_file}"
    # Fix BYTECCLIBS for -output-complete-exe (links libcamlrun.a which contains zstd.o)
    # Use @loader_path for relocatable rpath (survives conda relocation)
    # Note: Don't use -L${PREFIX}/lib here - conda-ocaml-mkexe wrapper adds it at runtime
    sed -i "s|^BYTECCLIBS=\(.*\)|BYTECCLIBS=\1 -Wl,-rpath,@loader_path/../lib -lzstd|" "${config_file}"
  elif [[ "${target_platform}" != "linux"* ]] && [[ "${OCAML_TARGET_TRIPLET}" != *"-pc-"* ]]; then
    local config_file="Makefile.config"

    # non-unix: Fix flexlink toolchain detection
    sed -i 's/^TOOLCHAIN.*/TOOLCHAIN=mingw64/' "$config_file"
    sed -i 's/^FLEXDLL_CHAIN.*/FLEXDLL_CHAIN=mingw64/' "$config_file"

    # Fix $(addprefix -link ,$(OC_LDFLAGS)) generating garbage when empty
    # Use $(if $(strip ...)) to guard against empty/whitespace-only values
    # NOTE: All $() must be escaped or bash interprets them as command substitution
    sed -i 's/\$(addprefix -link ,\$(OC_LDFLAGS))/\$(if \$(strip \$(OC_LDFLAGS)),\$(addprefix -link ,\$(OC_LDFLAGS)),)/g' "$config_file"
    sed -i 's/\$(addprefix -link ,\$(OC_DLL_LDFLAGS))/\$(if \$(strip \$(OC_DLL_LDFLAGS)),\$(addprefix -link ,\$(OC_DLL_LDFLAGS)),)/g' "$config_file"

    # Remove trailing "-link " garbage from MKEXE/MKDLL lines
    # Configure generates "... $(addprefix...) -link " but when OC_LDFLAGS is empty,
    # this trailing "-link" causes "flexlink ... -link -o output" which passes -o to linker!
    sed -i 's/^\(MK[A-Z]*=.*\)[[:space:]]*-link[[:space:]]*$/\1/' "$config_file"
  fi

  # Strip build-time -L paths from config.generated.ml (macOS)
  #
  # utils/config.generated.ml holds the *_c_libraries values that configure
  # produced. world.opt compiles these INTO the Config module, so
  # `ocamlc/ocamlopt -config-var bytecomp_c_libraries` reads THIS file, not
  # Makefile.config. Cleaning Makefile.config cannot affect it (refuted twice).
  #
  # This MUST run BEFORE world.opt. Editing config.generated.ml afterwards has no
  # effect. The strip also removes the legitimate relocatable -L${PREFIX}/lib; on
  # macOS conda-ocaml-mkexe re-supplies it at runtime, which is why this is
  # guarded to osx only.
  if [[ "${target_platform}" == "osx"* ]]; then
    local _cfg_ml="utils/config.generated.ml"
    echo "  - Stripping build-time -L paths from ${_cfg_ml}..."
    local _cvar
    for _cvar in bytecomp_c_libraries native_c_libraries compression_c_libraries; do
      if grep -q "^let ${_cvar} = " "${_cfg_ml}" 2>/dev/null; then
        sed -i -E "/^let ${_cvar} = /s#-L[^ |]+ *##g" "${_cfg_ml}"
      fi
    done
    echo "  [diag] post-strip config.generated.ml C-library vars:"
    grep -E '^let (bytecomp|native|compression)_c_libraries = ' "${_cfg_ml}" \
      | sed 's/^/    /' || echo "    [diag] (no matching vars)"
  fi

  # ============================================================================
  # Build
  # ============================================================================

  echo "  [3/4] Compiling native compiler"
  run_logged "world" "${MAKE[@]}" world.opt -j"${CPU_COUNT}"

  # ============================================================================
  # Tests (Optional)
  # ============================================================================

  if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
    echo "  - Running tests"
    run_logged "ocamltest" "${MAKE[@]}"  ocamltest -j "${CPU_COUNT}"
    run_logged "test" "${MAKE[@]}"  tests -j "${CPU_COUNT}"
  fi

  # ============================================================================
  # Install
  # ============================================================================

  echo "  [4/4] Installing native compiler"

  # Install (INSTALLING=1 and VPATH= help prevent stale file issues if Makefile.cross is included)
  run_logged "install" "${MAKE[@]}" install INSTALLING=1 VPATH=

  # Clean hardcoded -L paths from installed Makefile.config
  # During build we added -L${BUILD_PREFIX}/lib or -L${PREFIX}/lib to find zstd
  # But these absolute paths won't exist at runtime - clean them out
  echo "  - Cleaning hardcoded -L paths from installed Makefile.config..."
  local installed_config="${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config"
  clean_makefile_config "${installed_config}" "${PREFIX}"

  # NOTE: runtime-launch-info cleanup deferred to post-transfer (after transfer_to_prefix)
  # Cleaning here would corrupt the file if this build is used as an intermediate stage

  # Verify rpath for macOS binaries
  # OCaml embeds @rpath/libzstd.1.dylib - rpath should be set via BYTECCLIBS during build
  # This verifies the rpath is present and adds it only if missing
  if [[ "${target_platform}" == "osx"* ]]; then
    echo "  - Verifying rpath for macOS binaries..."
    verify_macos_rpath "${OCAML_INSTALL_PREFIX}/bin" "@loader_path/../lib"

    # Fix install_names to silence rattler-build overlinking warnings
    # Only needed for packaged output, not for temporary build tools (cross-compilation)
    # See fix-macos-install-names.sh for details
    if [[ "${OCAML_INSTALL_PREFIX}" == "${PREFIX}" ]]; then
      bash "${RECIPE_DIR}/building/fix-macos-install-names.sh" "${OCAML_INSTALL_PREFIX}/lib/ocaml"
    else
      echo "  - Skipping install_name fixes (build tool, not packaged)"
    fi
  fi

  # Install conda-ocaml-* wrappers (expand CONDA_OCAML_* env vars for tools like Dune)
  if is_unix; then
    echo "  - Installing conda-ocaml-* wrapper scripts..."
    install_conda_ocaml_wrappers "${OCAML_INSTALL_PREFIX}/bin"
    # NOTE: macOS ocamlmklib wrapper is created in build.sh AFTER cross-compiler builds
    # (the native ocamlmklib is used during cross-compiler build and must remain unwrapped)
  else
    # non-unix: Build and install wrapper .exe files
    # These are small C programs that read CONDA_OCAML_* env vars at runtime
    CC="${NATIVE_CC}" "${RECIPE_DIR}/building/build-wrappers.sh" "${OCAML_INSTALL_PREFIX}/bin"
  fi

  # Clean up for potential cross-compiler builds
  # Distclean uses xargs which fails on Windows if environment is too large (32KB limit).
  # Run with minimal environment — cleanup only needs PATH and basic shell vars.
  run_logged "distclean" env -i PATH="$PATH" SYSTEMROOT="${SYSTEMROOT:-}" "${MAKE[@]}" distclean || true

  echo ""
  echo "============================================================"
  echo "Native OCaml installed successfully"
  echo "============================================================"
  echo "  Location: ${OCAML_INSTALL_PREFIX}"
  echo "  Version:  $(${OCAML_INSTALL_PREFIX}/bin/ocamlopt -version 2>/dev/null || echo 'N/A')"
}

# ==============================================================================
# build_cross_compiler() - Build cross-compiler (native binaries for target code)
# (formerly building/build-cross-compiler.sh)
# ==============================================================================

build_cross_compiler() {
  local -a CONFIG_ARGS=("${CONFIG_ARGS[@]}")

  # Sanitize CFLAGS unconditionally: cross-compilers fail on x86-specific flags
  # (see top-level Early CFLAGS/LDFLAGS Sanitization block for full rationale)
  sanitize_and_export_cross_flags "aarch64"

  if [[ "${target_platform}" != "linux"* ]] && [[ "${target_platform}" != "osx"* ]]; then
    echo "No cross-compiler recipe for ${target_platform} ... yet"
    return 0
  fi

  # ============================================================================
  # Configuration
  # ============================================================================

  # OCAML_PREFIX = where native OCaml is installed (source for native tools)
  # OCAML_INSTALL_PREFIX = where cross-compilers will be installed (destination)
  : "${OCAML_PREFIX:=${PREFIX}}"
  : "${OCAML_INSTALL_PREFIX:=${PREFIX}}"
  # Where the cross-compiler will FINALLY live, baked into config.ml's
  # standard_library_default and into the cross Makefile.config. For the
  # ocaml_<target> cross-compiler output this is ${PREFIX} (the staged tree is
  # transferred there after this function returns). For an in-lane cross-target
  # build the tree is consumed in place and never transferred, so the caller
  # overrides this with the staging prefix.
  : "${OCAML_CROSS_FINAL_PREFIX:=${PREFIX}}"

  # macOS: Use DYLD_FALLBACK_LIBRARY_PATH so native compiler can find libzstd at runtime
  # IMPORTANT: Use FALLBACK, not DYLD_LIBRARY_PATH - FALLBACK doesn't override system libs
  # The native compiler (x86_64) needs BUILD_PREFIX libs, not PREFIX (which has target arch libs)
  # Cross-compilation: PREFIX=ARM64, BUILD_PREFIX=x86_64
  # Native build: PREFIX=x86_64, BUILD_PREFIX=x86_64 (same)
  # Note: fix-macos-install-names.sh unsets DYLD_* before running system tools to avoid iconv issues
  setup_dyld_fallback

  # Define cross targets based on build platform or explicit env vars
  declare -a CROSS_TARGETS

  # Check if OCAML_TARGET_TRIPLET is explicitly set (gcc pattern: build one target per output)
  if [[ -n "${OCAML_TARGET_TRIPLET:-}" ]]; then
    echo "  Using explicit OCAML_TARGET_TRIPLET: ${OCAML_TARGET_TRIPLET}"
    CROSS_TARGETS=("${OCAML_TARGET_TRIPLET}")
  fi

  # ============================================================================
  # Build loop
  # ============================================================================

  echo ""
  echo "============================================================"
  echo "Cross-compiler build configuration"
  echo "============================================================"
  echo "  Native OCaml (source):    ${OCAML_PREFIX}"
  echo "  Cross install (dest):     ${OCAML_INSTALL_PREFIX}"
  echo "  Native ocamlopt:          ${OCAML_PREFIX}/bin/ocamlopt"

  # CRITICAL: Add native OCaml to PATH so configure can find ocamlc
  # Configure checks "if the installed OCaml compiler can build the cross compiler"
  PATH="${OCAML_PREFIX}/bin:${PATH}"
  hash -r
  echo "  PATH updated to include: ${OCAML_PREFIX}/bin"

  for target in "${CROSS_TARGETS[@]}"; do
    echo ""
    echo "  ------------------------------------------------------------"
    echo "  Building cross-compiler for ${target}"
    echo "  ------------------------------------------------------------"

    # Get target properties using common functions
    CROSS_ARCH=$(get_target_arch "${target}")
    CROSS_PLATFORM=$(get_target_platform "${target}")

    # Handle PowerPC model override
    CROSS_MODEL=""
    [[ "${target}" == "powerpc64le-"* ]] && CROSS_MODEL="ppc64le"

    # Setup macOS ARM64 SDK (must be done before setup_cflags_ldflags)
    if [[ "${target}" == "arm64-apple-darwin"* ]]; then
      echo "  Setting up macOS ARM64 SDK for cross-compilation..."
      setup_macos_sysroot "${target}"
      # CRITICAL: Override BOTH SDKROOT and CONDA_BUILD_SYSROOT
      # conda-forge sets CONDA_BUILD_SYSROOT=/opt/conda-sdks/MacOSX10.13.sdk for x86_64
      # The cross-compiler clang respects CONDA_BUILD_SYSROOT for library lookup
      # Without overriding it, lld finds the wrong SDK even with -syslibroot flags
      export SDKROOT="${ARM64_SYSROOT}"
      export CONDA_BUILD_SYSROOT="${ARM64_SYSROOT}"
      echo "  SDKROOT exported: ${SDKROOT}"
      echo "  CONDA_BUILD_SYSROOT exported: ${CONDA_BUILD_SYSROOT}"
    fi

    # Setup cross-toolchain (sets CROSS_CC, CROSS_AS, CROSS_AR, etc.)
    setup_toolchain "CROSS" "${target}"
    setup_cflags_ldflags "CROSS" "${build_platform}" "${CROSS_PLATFORM}"

    # MUST come after setup_cflags_ldflags above: that helper OVERWRITES
    # CROSS_CFLAGS with "export ${name}_CFLAGS=..." (see
    # recipe/building/common-functions.sh:359-429), so an injection placed any
    # earlier in this loop is silently discarded.
    #
    # Big-endian cross targets: the cross-configure below must run
    # --host="${build_alias}" (x86_64) because THIS tree produces a cross-compiler
    # BINARY that has to run on the build machine. autoconf therefore emits a
    # runtime/caml/m.h with ARCH_BIG_ENDIAN left #undef'd, and that single header
    # is shared by TWO different compiles in this tree: the host-side SAK build
    # (Makefile.cross:189-193, CC=$(SAK_CC), x86_64) and the TARGET runtime
    # (RUNTIME_VARS, CC=cross). Patching m.h would corrupt the host-side compile,
    # so inject the define through the CROSS-only CFLAGS, which never reach
    # SAK_CFLAGS. Symptom when missing: Tag_val reads byte [-8] instead of [-1],
    # misclassifies String_tag, and every natively-compiled target binary SIGSEGVs
    # at si_addr=NULL. m.h.in ships "#undef ARCH_BIG_ENDIAN", so on a
    # little-endian-configured tree this -D is the only definition; if a tree is
    # already configured correctly the -D is an identical redefinition (legal C).
    CROSS_CFLAGS="$(add_big_endian_define "${CROSS_PLATFORM}" "${CROSS_CFLAGS:-}")"

    # Platform-specific settings for cross-compiler
    # NEEDS_DL: glibc 2.17 requires explicit -ldl for dlopen/dlclose/dlsym
    # This is used by apply_cross_patches() to add -ldl to Makefile.config
    # CROSS_PLATFORM is "linux-aarch64", "linux-ppc64le", "osx-arm64", etc.
    NEEDS_DL=0
    case "${CROSS_PLATFORM}" in
      linux-*)
        NEEDS_DL=1
        ;;
    esac
    export NEEDS_DL

    # Export CONDA_OCAML_<TARGET_ID>_* variables
    TARGET_ID=$(get_target_id "${target}")

    echo "  Target:        ${target}"
    echo "  Target ID:     ${TARGET_ID}"
    echo "  Arch:          ${CROSS_ARCH}"
    echo "  Platform:      ${CROSS_PLATFORM}"
    print_toolchain_info CROSS

    # ========================================================================
    # Generate standalone toolchain wrappers EARLY (needed during crossopt build)
    # ========================================================================
    # These must exist BEFORE crossopt because config.generated.ml references them.
    # Install in both BUILD_PREFIX/bin (for build-time access) and OCAML_INSTALL_PREFIX/bin (for package)
    echo "  Installing ${target}-ocaml-* toolchain wrappers (build-time)..."

    # Create toolchain wrappers using CROSS_* basenames as defaults
    # Use basenames so wrappers are relocatable (resolve via PATH when package is installed elsewhere)
    # Format: tool_name:ENV_SUFFIX:default_value
    _cross_cc_base=$(basename "${CROSS_CC}")
    _cross_ar_base=$(basename "${CROSS_AR}")
    _cross_ld_base=$(basename "${CROSS_LD}")
    _cross_ranlib_base=$(basename "${CROSS_RANLIB}")
    # ASM/MKEXE/MKDLL may contain flags — basename the command, keep the flags
    _cross_asm_base="${CROSS_ASM}"  # already a basename (set by setup_toolchain)
    _cross_mkexe_base="${CROSS_MKEXE//${CROSS_CC}/${_cross_cc_base}}"
    _cross_mkdll_base="${CROSS_MKDLL//${CROSS_CC}/${_cross_cc_base}}"
    for tool_pair in "cc:CC:${_cross_cc_base}" "as:AS:${_cross_asm_base}" "ar:AR:${_cross_ar_base}" \
                     "ld:LD:${_cross_ld_base}" "ranlib:RANLIB:${_cross_ranlib_base}" \
                     "mkexe:MKEXE:${_cross_mkexe_base}" "mkdll:MKDLL:${_cross_mkdll_base}"; do
      tool_name="${tool_pair%%:*}"
      rest="${tool_pair#*:}"
      env_suffix="${rest%%:*}"
      default_tool="${rest#*:}"

      # Create in BUILD_PREFIX/bin for build-time PATH access
      wrapper_path="${BUILD_PREFIX}/bin/${target}-ocaml-${tool_name}"
      cat > "${wrapper_path}" << TOOLWRAPPER
#!/usr/bin/env bash
# OCaml cross-compiler toolchain wrapper for ${target}
# Reads CONDA_OCAML_${TARGET_ID}_${env_suffix} or uses default cross-tool
exec \${CONDA_OCAML_${TARGET_ID}_${env_suffix}:-${default_tool}} "\$@"
TOOLWRAPPER
      chmod +x "${wrapper_path}"
    done
    echo "    Created in BUILD_PREFIX: ${target}-ocaml-{cc,as,ar,ld,ranlib,mkexe,mkdll}"

    # Use OCAML_TARGET_PLATFORM if set (gcc pattern), otherwise CROSS_PLATFORM
    _ENV_TARGET="${OCAML_TARGET_PLATFORM:-${CROSS_PLATFORM}}"
    generate_xcross_env_file "${_ENV_TARGET}"

    # Installation prefix for this cross-compiler
    OCAML_CROSS_PREFIX="${OCAML_INSTALL_PREFIX}/lib/ocaml-cross-compilers/${target}"
    OCAML_CROSS_LIBDIR="${OCAML_CROSS_PREFIX}/lib/ocaml"
    mkdir -p "${OCAML_CROSS_PREFIX}/bin" "${OCAML_CROSS_LIBDIR}"

    # ========================================================================
    # Install target-arch zstd for shared library linking
    # ========================================================================
    # The bytecode runtime shared library (libcamlrun_shared.so) needs to link
    # against target-arch zstd. Create a conda env with target-platform zstd.
    TARGET_ZSTD_ENV="zstd_${CROSS_PLATFORM}"
    echo "  Installing target-arch zstd for ${CROSS_PLATFORM}..."
    conda create -n "${TARGET_ZSTD_ENV}" --platform "${CROSS_PLATFORM}" -y zstd --quiet 2>&1 | grep -v "^INFO:" || true
    # Get env path from conda info (envs are in $CONDA_PREFIX/envs/ or default location)
    CONDA_ENVS_DIR=$(conda info --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['envs_dirs'][0])")
    TARGET_ZSTD_LIB="${CONDA_ENVS_DIR}/${TARGET_ZSTD_ENV}/lib"
    # conda create above is best-effort (|| true): some targets have no zstd on
    # conda-forge at all (PackagesNotFoundInChannelsError). Probe the
    # actual outcome rather than assuming success - emitting -lzstd for a library
    # that was never installed fails the libcamlrun_shared.so link.
    # libzstd.dylib: conda's macOS zstd ships ONLY the .dylib, so a .so/.a-only
    # probe is blind on every osx-* target and always reports "not available".
    if [[ -f "${TARGET_ZSTD_LIB}/libzstd.so" || -f "${TARGET_ZSTD_LIB}/libzstd.a" || -f "${TARGET_ZSTD_LIB}/libzstd.dylib" ]]; then
      TARGET_ZSTD_AVAILABLE=1
      TARGET_ZSTD_LIBS="-L${TARGET_ZSTD_LIB} -lzstd"
    else
      TARGET_ZSTD_AVAILABLE=0
      TARGET_ZSTD_LIBS=""
      echo "  [zstd-probe] no target-arch zstd for ${CROSS_PLATFORM}; building without zstd"
    fi
    export TARGET_ZSTD_AVAILABLE
    echo "  TARGET_ZSTD_LIBS: ${TARGET_ZSTD_LIBS}"

    # ========================================================================
    # Clean and configure
    # ========================================================================

    echo "  [1/7] Cleaning previous build..."
    run_logged "pre-cross-distclean" "${MAKE[@]}" distclean > /dev/null 2>&1 || true

    echo "  [2/7] Configuring for ${target}..."
    # PKG_CONFIG=false forces simple "-lzstd" instead of "-L/long/path -lzstd"
    # Do NOT pass CC here - configure needs BUILD compiler
    # ac_cv_func_getentropy=no: conda-forge uses glibc 2.17 sysroot which lacks getentropy
    # CRITICAL: Override CFLAGS/LDFLAGS - conda-build sets them for TARGET (ppc64le)
    # but configure needs BUILD flags (x86_64) to compile the cross-compiler binary
    # NOTE: OCaml 5.4.0+ requires CFLAGS/LDFLAGS as env vars, not configure args.
    export CC="${NATIVE_CC}"
    export CFLAGS="${NATIVE_CFLAGS}"
    export LDFLAGS="${NATIVE_LDFLAGS}"
    export STRIP="${NATIVE_STRIP}"

    # Per-target configure args (frame pointers not supported on PPC)
    declare -a TARGET_CONFIG_ARGS=()
    case "${CROSS_ARCH}" in
      arm64|amd64)
        TARGET_CONFIG_ARGS+=(--enable-frame-pointers)
        ;;
    esac

    # No target-arch zstd for this platform (see [zstd-probe] above). Without this,
    # configure bakes -lzstd into Makefile.config's BYTECCLIBS and the crossopt link
    # of runtime/libcamlrun_shared.so fails with "cannot find -lzstd" - emptying
    # TARGET_ZSTD_LIBS alone is not enough, the token also comes from BYTECCLIBS.
    if [[ "${TARGET_ZSTD_AVAILABLE:-1}" == "0" ]]; then
      TARGET_CONFIG_ARGS+=(--without-zstd)
    fi

    run_logged "cross-configure" ${CONFIGURE[@]} \
      -prefix="${OCAML_CROSS_PREFIX}" \
      --mandir="${OCAML_CROSS_PREFIX}"/share/man \
      --host="${build_alias}" \
      --target="${target}" \
      "${CONFIG_ARGS[@]}" \
      "${TARGET_CONFIG_ARGS[@]}" \
      AR="${CROSS_AR}" \
      AS="${NATIVE_AS}" \
      LD="${NATIVE_LD}" \
      NM="${CROSS_NM}" \
      RANLIB="${CROSS_RANLIB}" \
      STRIP="${CROSS_STRIP}" \
      ac_cv_func_getentropy=no \
      ${CROSS_MODEL:+MODEL=${CROSS_MODEL}}

    # CRITICAL: Unset CC/CFLAGS/LDFLAGS after configure completes
    # OCaml 5.4.0 configure requires these as env vars, but leaving them set
    # can cause crossopt to pick up NATIVE values from environment instead of
    # the CROSS values passed as make arguments. This leads to arch inconsistencies
    # between stdlib and otherlibs (unix), causing "inconsistent assumptions" errors.
    unset CC CFLAGS LDFLAGS

    # ========================================================================
    # Patch Makefile for OCaml 5.4.0 bug: CHECKSTACK_CC undefined
    # ========================================================================
    patch_checkstack_cc

    # ========================================================================
    # Patch config.generated.ml
    # ========================================================================

    echo "  [3/7] Patching config.generated.ml..."
    config_file="utils/config.generated.ml"

    # Use ${target}-ocaml-* standalone wrapper scripts (not conda-ocaml-* from native)
    # This makes cross-compiler fully standalone without runtime dependency on native ocaml
    sed -i \
      -e "s#^let asm = .*#let asm = {|${target}-ocaml-as|}#" \
      -e "s#^let ar = .*#let ar = {|${target}-ocaml-ar|}#" \
      -e "s#^let c_compiler = .*#let c_compiler = {|${target}-ocaml-cc|}#" \
      -e "s#^let ranlib = .*#let ranlib = {|${target}-ocaml-ranlib|}#" \
      -e "s#^let mkexe = .*#let mkexe = {|${target}-ocaml-mkexe|}#" \
      -e "s#^let mkdll = .*#let mkdll = {|${target}-ocaml-mkdll|}#" \
      -e "s#^let mkmaindll = .*#let mkmaindll = {|${target}-ocaml-mkdll|}#" \
      "$config_file"
    # CRITICAL: Use the actual PREFIX path that conda will install to
    # OCAML_CROSS_LIBDIR may point to work/_xcross_compiler/... during build
    # We need to use ${PREFIX} (the conda prefix) which will be correct after install
    # Conda/rattler-build will relocate these paths during packaging
    FINAL_STDLIB_PATH="${OCAML_CROSS_FINAL_PREFIX}/lib/ocaml-cross-compilers/${target}/lib/ocaml"
    sed -i "s#^let standard_library_default = .*#let standard_library_default = {|${FINAL_STDLIB_PATH}|}#" "$config_file"

    # CRITICAL: Patch architecture - this is baked into the binary!
    # CROSS_ARCH is set by get_target_arch() - values: arm64, power, amd64
    sed -i "s#^let architecture = .*#let architecture = {|${CROSS_ARCH}|}#" "$config_file"

    # Patch model for PowerPC
    [[ -n "${CROSS_MODEL}" ]] && sed -i "s#^let model = .*#let model = {|${CROSS_MODEL}|}#" "$config_file"

    # Patch native_pack_linker to use cross-linker via wrapper
    sed -i "s#^let native_pack_linker = .*#let native_pack_linker = {|${target}-ocaml-ld -r -o |}#" "$config_file"

    # CRITICAL: Patch native_c_libraries to include -ldl for Linux targets
    # glibc 2.17 requires explicit -ldl for dlopen/dlclose/dlsym/dlerror
    # This value is BAKED INTO the compiler binary, not read from Makefile.config!
    if [[ "${NEEDS_DL}" == "1" ]]; then
      # Add -ldl to native_c_libraries if not already present
      if ! grep -q '"-ldl"' "$config_file"; then
        sed -i 's#^let native_c_libraries = {|\(.*\)|}#let native_c_libraries = {|\1 -ldl|}#' "$config_file"
        echo "    Patched native_c_libraries: added -ldl"
      fi
      # Also patch bytecomp_c_libraries for bytecode
      if ! grep -q 'bytecomp_c_libraries.*-ldl' "$config_file"; then
        sed -i 's#^let bytecomp_c_libraries = {|\(.*\)|}#let bytecomp_c_libraries = {|\1 -ldl|}#' "$config_file"
        echo "    Patched bytecomp_c_libraries: added -ldl"
      fi
    fi

    echo "    Patched architecture=${CROSS_ARCH}"
    [[ -n "${CROSS_MODEL}" ]] && echo "    Patched model=${CROSS_MODEL}"
    echo "    Patched native_pack_linker=${target}-ocaml-ld -r -o"

    # Apply Makefile.cross patches (includes otherlibrariesopt → otherlibrariesopt-cross fix)
    apply_cross_patches

    # ========================================================================
    # Pre-build bytecode runtime with NATIVE tools
    # ========================================================================
    # runtime-all builds BOTH bytecode (libcamlrun*, ocamlrun*) and native (libasmrun*).
    # Bytecode runs on BUILD machine → NATIVE tools; Native is for TARGET → CROSS tools.
    #
    # Strategy (prevents Stdlib__Sys consistency errors - see HISTORY.md):
    # 1. Build runtime-all with NATIVE tools (ARCH=amd64) - stable .cmi files
    # 2. Clean only native runtime files (libasmrun*, amd64.o, *.nd.o)
    # 3. crossopt rebuilds native parts for TARGET (bytecode unchanged)

    echo "  [4/7] Pre-building bytecode runtime and stdlib with native tools..."
    run_logged "runtime-all" "${MAKE[@]}" runtime-all \
      ARCH=amd64 \
      CC="${NATIVE_CC}" \
      CFLAGS="${NATIVE_CFLAGS}" \
      LD="${NATIVE_LD}" \
      LDFLAGS="${NATIVE_LDFLAGS}" \
      SAK_CC="${NATIVE_CC}" \
      SAK_CFLAGS="${NATIVE_CFLAGS}" \
      SAK_LDFLAGS="${NATIVE_LDFLAGS}" \
      ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd" \
      -j"${CPU_COUNT}"

    # NOTE: stdlib pre-build removed - was causing inconsistent assumptions
    # Let crossopt handle stdlib build entirely with consistent variables

    # Clean native runtime files so crossopt's runtimeopt rebuilds them for TARGET arch
    # - libasmrun*.a: native runtime static libraries (TARGET arch needed)
    # - libasmrun_shared.so: native runtime shared library
    # - amd64*.o: x86_64 assembly objects (crossopt needs arm64*.o or power*.o)
    # - *.nd.o, *.ni.o, *.npic.o: native code object files (need CROSS CC)
    # NOTE: libcamlrun*.a (bytecode runtime) is cleaned and rebuilt for TARGET
    # in Makefile.cross AFTER runtimeopt, since crossopt's runtime-all rebuilds
    # it with BUILD tools (it's linked into -output-complete-exe TARGET binaries).
    echo "     Cleaning native runtime files for crossopt rebuild..."
    rm -f runtime/libasmrun*.a runtime/libasmrun_shared.so
    rm -f runtime/amd64*.o runtime/*.nd.o runtime/*.ni.o runtime/*.npic.o
    rm -f runtime/libcomprmarsh.a  # Also needs CROSS tools

    # CRITICAL: Clean ALL stdlib files so crossopt rebuilds everything consistently
    # The working branch (mnt/v5.4.0_1-clean) does this - it works because crossopt
    # then builds stdlib from scratch with consistent CRCs throughout
    echo "     Cleaning stdlib compiled files for crossopt rebuild..."
    rm -f stdlib/*.cmi stdlib/*.cmo stdlib/*.cma
    rm -f stdlib/*.cmx stdlib/*.cmxa stdlib/*.o stdlib/*.a


    # ========================================================================
    # Build cross-compiler
    # ========================================================================

    # Shared cross-toolchain args for crossopt and installcross
    # OCaml's runtime/%.o: runtime/%.S rule expands $(ASPP) $(OC_ASPPFLAGS) only;
    # ASPPFLAGS is never referenced, so arch-specific assembler flags must ride on ASPP.
    CROSS_TOOLCHAIN_ARGS=(
      ARCH="${CROSS_ARCH}"
      AR="${CROSS_AR}"
      AS="${CROSS_AS}"
      ASPP="${CROSS_CC} -c ${CROSS_ASPPFLAGS:-}"
      CC="${CROSS_CC}"
      CFLAGS="${CROSS_CFLAGS}"
      CROSS_AR="${CROSS_AR}"
      CROSS_CC="${CROSS_CC}"
      CROSS_MKEXE="${CROSS_MKEXE}"
      CROSS_MKDLL="${CROSS_MKDLL}"
      LD="${CROSS_LD}"
      LDFLAGS="${CROSS_LDFLAGS}"
      NM="${CROSS_NM}"
      RANLIB="${CROSS_RANLIB}"
      STRIP="${CROSS_STRIP}"
    )

    # libtool bug: with --host=x86_64 --target=s390x, _LT_SYS_DYNAMIC_LINKER keys its
    # -m emulation off $target and probes with the x86_64 linker, so the shared-lib
    # check fails. That ONE false negative sets SUPPORTS_SHARED_LIBRARIES=false plus
    # MKDLL/MKMAINDLL sentinels. s390x does support shared libraries; repair all three.
    #   - SUPPORTS_SHARED_LIBRARIES gates Makefile:1291-1297, which populates
    #     runtime_{BYTECODE,NATIVE}_SHARED_LIBRARIES. Left false, libcamlrun_shared.so
    #     and libasmrun_shared.so are never built or installed and the package content
    #     test fails - patching MKDLL alone fixes the command but not the missing target.
    #   - MKDLL/MKMAINDLL are the actual link commands for those targets.
    #   - MKDLL/MKMAINDLL must reference the UNEXPANDED make variable $(CC), not a
    #     hardcoded compiler path. Makefile.cross has TWO different shared-lib builds
    #     that use DIFFERENT compilers by design: line 189-193 (crossopt) builds the
    #     cross-compiler's OWN runtime with CC=$(SAK_CC) (the HOST x86_64 compiler),
    #     while line 223 builds the TARGET-arch shared runtime via RUNTIME_VARS, which
    #     sets CC to the cross compiler. A hardcoded ${CROSS_CC} path in MKDLL breaks
    #     whichever invocation it does not match (host build got fed s390x objects to
    #     the s390x linker's ld: "Relocations in generic ELF (EM: 62)"/"wrong format").
    #     Letting MKDLL=$(CC) -shared instead makes it inherit whatever CC each
    #     sub-make invocation set, exactly like the generated Makefile.config already
    #     does for MKEXE=$(CC) $(OC_LDFLAGS) $(LDFLAGS) (also unexpanded $(CC)).
    if [[ "${CROSS_PLATFORM}" == "linux-s390x" ]]; then
      if grep -q '^SUPPORTS_SHARED_LIBRARIES=false' "Makefile.config"; then
        sed -i "s|^SUPPORTS_SHARED_LIBRARIES=false|SUPPORTS_SHARED_LIBRARIES=true|" "Makefile.config"
        echo "[s390x-sharedlib-fix] SUPPORTS_SHARED_LIBRARIES -> true (libtool probe false negative)"
      fi
      if grep -q '^MKDLL=shared-libs-not-available' "Makefile.config"; then
        sed -i 's|^MKDLL=shared-libs-not-available|MKDLL=$(CC) -shared|' "Makefile.config"
        echo '[s390x-sharedlib-fix] MKDLL -> $(CC) -shared'
      fi
      if grep -q '^MKMAINDLL=shared-libs-not-available' "Makefile.config"; then
        sed -i 's|^MKMAINDLL=shared-libs-not-available|MKMAINDLL=$(CC) -shared|' "Makefile.config"
        echo '[s390x-sharedlib-fix] MKMAINDLL -> $(CC) -shared'
      fi
    fi

    echo "  [5/7] Building and installing cross-compiler..."

    # QEMU_LD_PREFIX: crossopt emulates TARGET binaries on the build machine
    # (the unix.cmi step execs a cross ocamlc under qemu-user). Without this,
    # qemu searches the HOST /lib and dies with
    #   qemu-<arch>-static: Could not open '/lib/ld64.so.1'
    # Same idiom the tests: blocks already use - see recipe.yaml's
    # `export QEMU_LD_PREFIX="${PREFIX}${{ sysroot }}"`. Here the target sysroot
    # comes from the sysroot_<target> build dep, which lands under BUILD_PREFIX.
    # Exported here (outside the crossopt subshell below) so it stays set for
    # the POST-INSTALL check_unix_crc call after the subshell closes.
    if [[ "${CROSS_PLATFORM}" != "${build_platform:-}" && -n "${OCAML_TARGET_TRIPLET:-}" ]]; then
      _qemu_sysroot="${BUILD_PREFIX}/${OCAML_TARGET_TRIPLET}/sysroot"
      if [[ -d "${_qemu_sysroot}" ]]; then
        export QEMU_LD_PREFIX="${_qemu_sysroot}"
        echo "  [qemu] QEMU_LD_PREFIX=${QEMU_LD_PREFIX}"
      else
        echo "  [qemu] WARNING: expected target sysroot not found at ${_qemu_sysroot}; leaving QEMU_LD_PREFIX unset"
      fi
    fi

    (
      # Export CONDA_OCAML_* for cross-compilation and add cross-tools to PATH
      _setup_crossopt_env

      # Native compiler stdlib location (for copying fresh .cmi files in crossopt)
      NATIVE_STDLIB="${OCAML_PREFIX}/lib/ocaml"

      # No target-arch zstd for this platform (see [zstd-probe] above, and the
      # matching --without-zstd guard a few lines up). The in-tree build was
      # configured --without-zstd, so Makefile.config already has an EMPTY
      # ZSTD_LIBS; passing the BUILD_PREFIX (x86_64 host) libzstd here on the
      # command line overrides that and reintroduces -lzstd onto the target
      # cross-linker's command line, which then fails with
      # "skipping incompatible .../libzstd.so ... cannot find -lzstd".
      if [[ "${TARGET_ZSTD_AVAILABLE:-1}" == "0" ]]; then
        CROSSOPT_ZSTD_LIBS=""
      else
        CROSSOPT_ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd"
      fi

      # --- Build crossopt ---
      CROSSOPT_ARGS=(
        "${CROSS_TOOLCHAIN_ARGS[@]}"
        CAMLOPT=ocamlopt
        CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"
        LIBDIR="${OCAML_CROSS_LIBDIR}"
        ZSTD_LIBS="${CROSSOPT_ZSTD_LIBS}"
        TARGET_ZSTD_LIBS="${TARGET_ZSTD_LIBS}"

        SAK_AR="${NATIVE_AR}"
        SAK_CC="${NATIVE_CC}"
        SAK_CFLAGS="${NATIVE_CFLAGS}"
        SAK_LDFLAGS="${NATIVE_LDFLAGS}"

        NATIVE_AS="${NATIVE_AS}"
        NATIVE_ASM="${NATIVE_ASM}"
        NATIVE_CC="${NATIVE_CC}"
        NATIVE_STDLIB="${NATIVE_STDLIB}"
      )

      # linux-s390x ONLY: force the stdlib .cmi compiler to the in-tree ocamlc.
      # The bare `ocamlc` in Makefile.cross's CROSS_OVERRIDES resolves via PATH
      # to $BUILD_PREFIX/bin/ocamlc, which is zstd-enabled and emits .cmi with
      # the COMPRESSED marshal magic 0x8495A6BD that the zstd-less s390x
      # runtime cannot read. No other target is affected - the knob defaults 0.
      if [[ "${CROSS_PLATFORM}" == "linux-s390x" ]]; then
        CROSSOPT_ARGS+=( STDLIB_CMI_PIN_INTREE=1 )
        echo "  linux-s390x: pinning stdlib CAMLC to in-tree ocamlc (STDLIB_CMI_PIN_INTREE=1)"
      fi

      run_logged "crossopt" "${MAKE[@]}" crossopt "${CROSSOPT_ARGS[@]}" -j"${CPU_COUNT}"

      # --- Install crossopt ---
      echo "  [6/7] Installing cross-compiler via 'make installcross'..."

      # Clean LIBDIR before install to ensure fresh installation
      echo "    Cleaning LIBDIR before install..."
      rm -rf "${OCAML_CROSS_LIBDIR}"

      # PRE-INSTALL: Verify Implementation CRCs match before installing
      _pre_unix="${SRC_DIR}/otherlibs/unix/unix.cmxa"
      _pre_threads="${SRC_DIR}/otherlibs/systhreads/threads.cmxa"
      _ocamlobjinfo_build="${SRC_DIR}/tools/ocamlobjinfo.opt"

      if [[ -f "$_pre_unix" ]] && [[ -f "$_pre_threads" ]] && [[ -f "$_ocamlobjinfo_build" ]]; then
        check_unix_crc "${_ocamlobjinfo_build}" "${_pre_unix}" "${_pre_threads}" "PRE-INSTALL"
      else
        echo "    ERROR: Missing a CRC file:"
        ls -l "$_pre_unix" "$_pre_threads" "$_ocamlobjinfo_build"
      fi

      INSTALL_ARGS=(
        "${CROSS_TOOLCHAIN_ARGS[@]}"
        PREFIX="${OCAML_CROSS_PREFIX}"
      )

      run_logged "installcross" "${MAKE[@]}" installcross "${INSTALL_ARGS[@]}"
    )

    # Verify rpath for macOS cross-compiler binaries
    # OCaml embeds @rpath/libzstd.1.dylib - rpath should be set via BYTECCLIBS during build
    # Cross-compiler binaries are in ${PREFIX}/lib/ocaml-cross-compilers/${target}/bin/
    # libzstd is in ${PREFIX}/lib/, so relative path is ../../../../lib
    if [[ "${target_platform}" == "osx"* ]]; then
      echo "  Verifying rpath for macOS cross-compiler binaries..."
      verify_macos_rpath "${OCAML_CROSS_PREFIX}/bin" "@loader_path/../../../../lib"

      # Fix install_names to silence rattler-build overlinking warnings
      # See fix-macos-install-names.sh for details
      bash "${RECIPE_DIR}/building/fix-macos-install-names.sh" "${OCAML_CROSS_LIBDIR}"
    fi

    # Post-install fixes for cross-compiler package

    # ld.conf - point to native OCaml's stublibs (same arch as cross-compiler binary)
    # Cross-compiler binary runs on BUILD machine, needs BUILD-arch stublibs
    cat > "${OCAML_CROSS_LIBDIR}/ld.conf" << EOF
${OCAML_PREFIX}/lib/ocaml/stublibs
${OCAML_PREFIX}/lib/ocaml
EOF

    # Remove unnecessary binaries to reduce package size
    # Cross-compiler only needs: ocamlopt, ocamlc, ocamldep, ocamllex, ocamlyacc, ocamlmklib
    echo "  Cleaning up unnecessary binaries..."
    (
      cd "${OCAML_CROSS_PREFIX}/bin"

      # Remove bytecode versions (keep only .opt)
      rm -f ocamlc.byte ocamldep.byte ocamllex.byte ocamlobjinfo.byte ocamlopt.byte

      # Remove toplevel and REPL (not needed for cross-compilation)
      rm -f ocaml

      # Remove bytecode interpreters (cross-compiler produces native code)
      rm -f ocamlrun ocamlrund ocamlruni

      # Remove profiling tools
      rm -f ocamlcp ocamloptp ocamlprof

      # Remove other unnecessary tools
      rm -f ocamlcmt ocamlmktop

      # Optionally remove ocamlobjinfo (only for debugging)
      # rm -f ocamlobjinfo ocamlobjinfo.opt
    )

    # Remove man pages (not needed in cross-compiler package)
    rm -rf "${OCAML_CROSS_PREFIX}/man" 2>&1 || true

    # Patch Makefile.config for cross-compilation
    # The installed Makefile.config has BUILD machine settings, we need TARGET settings
    # Also clean up build-time paths that would cause test failures and runtime issues
    echo "  Patching Makefile.config for target ${target}..."
    makefile_config="${OCAML_CROSS_LIBDIR}/Makefile.config"
    if [[ -f "${makefile_config}" ]]; then
      # Architecture
      sed -i "s|^ARCH=.*|ARCH=${CROSS_ARCH}|" "${makefile_config}"

      # TOOLPREF - CRITICAL: Must be TARGET triplet, not BUILD triplet!
      # opam uses this to find the correct cross-toolchain
      sed -i "s|^TOOLPREF=.*|TOOLPREF=${target}-|" "${makefile_config}"

      # Model (for PowerPC)
      if [[ -n "${CROSS_MODEL}" ]]; then
        sed -i "s|^MODEL=.*|MODEL=${CROSS_MODEL}|" "${makefile_config}"
      fi

      # Toolchain - use standalone ${target}-ocaml-* wrappers (not conda-ocaml-* from native)
      sed -i "s|^CC=.*|CC=${target}-ocaml-cc|" "${makefile_config}"
      sed -i "s|^AS=.*|AS=${target}-ocaml-as|" "${makefile_config}"
      sed -i "s|^ASM=.*|ASM=${target}-ocaml-as|" "${makefile_config}"
      sed -i "s|^ASPP=.*|ASPP=${target}-ocaml-cc -c|" "${makefile_config}"
      sed -i "s|^AR=.*|AR=${target}-ocaml-ar|" "${makefile_config}"
      sed -i "s|^RANLIB=.*|RANLIB=${target}-ocaml-ranlib|" "${makefile_config}"

      # CPP - strip build-time path, keep binary name and flags (-E -P)
      # Pattern: CPP=/long/path/to/clang -E -P -> CPP=clang -E -P
      # The ( .*)? is optional to handle CPP without flags
      sed -Ei 's#^(CPP)=/.*/([^/ ]+)( .*)?$#\1=\2\3#' "${makefile_config}"

      # Linker commands - use standalone ${target}-ocaml-* wrappers
      sed -i "s|^NATIVE_PACK_LINKER=.*|NATIVE_PACK_LINKER=${target}-ocaml-ld -r -o|" "${makefile_config}"
      sed -i "s|^MKEXE=.*|MKEXE=${target}-ocaml-mkexe|" "${makefile_config}"
      sed -i "s|^MKDLL=.*|MKDLL=${target}-ocaml-mkdll|" "${makefile_config}"
      sed -i "s|^MKMAINDLL=.*|MKMAINDLL=${target}-ocaml-mkdll|" "${makefile_config}"

      # Standard library path - use actual ${PREFIX} which conda will relocate
      # The OCAML_CROSS_LIBDIR variable contains build-time work directory path
      # We need to use the FINAL installed path: ${PREFIX}/lib/ocaml-cross-compilers/${target}/lib/ocaml
      FINAL_CROSS_LIBDIR="${OCAML_CROSS_FINAL_PREFIX}/lib/ocaml-cross-compilers/${target}/lib/ocaml"
      FINAL_CROSS_PREFIX="${OCAML_CROSS_FINAL_PREFIX}/lib/ocaml-cross-compilers/${target}"
      sed -i "s|^prefix=.*|prefix=${FINAL_CROSS_PREFIX}|" "${makefile_config}"
      sed -i "s|^LIBDIR=.*|LIBDIR=${FINAL_CROSS_LIBDIR}|" "${makefile_config}"
      sed -i "s|^STUBLIBDIR=.*|STUBLIBDIR=${FINAL_CROSS_LIBDIR}/stublibs|" "${makefile_config}"

      # Remove -Wl,-rpath paths that point to build directories
      sed -i 's|-Wl,-rpath,[^ ]*rattler-build[^ ]* ||g' "${makefile_config}"
      sed -i 's|-Wl,-rpath-link,[^ ]*rattler-build[^ ]* ||g' "${makefile_config}"

      # Clean LDFLAGS - remove build-time paths from LDFLAGS and LDFLAGS?= lines
      # These patterns catch conda-bld, rattler-build, build_env paths
      sed -i 's|-L[^ ]*miniforge[^ ]* ||g' "${makefile_config}"
      sed -i 's|-L[^ ]*miniconda[^ ]* ||g' "${makefile_config}"

      # Use clean_makefile_config for common build-time path cleanup
      clean_makefile_config "${makefile_config}" "${PREFIX}"

      echo "    Patched ARCH=${CROSS_ARCH}"
      [[ -n "${CROSS_MODEL}" ]] && echo "    Patched MODEL=${CROSS_MODEL}"
      echo "    Patched toolchain to use ${target}-ocaml-* standalone wrappers"
      echo "    Cleaned build-time paths from prefix/LIBDIR/STUBLIBDIR"
      echo "    Removed CONFIGURE_ARGS (contained build-time paths)"
    else
      echo "    WARNING: Makefile.config not found at ${makefile_config}"
    fi

    # NOTE: runtime-launch-info cleanup deferred to post-transfer
    # Cleaning here would corrupt the file before Stage 3 can use it

    # Remove unnecessary library files to reduce package size
    echo "  Cleaning up unnecessary library files..."
    (
      cd "${OCAML_CROSS_LIBDIR}"

      # Remove source files (not needed for compilation)
      find . -name "*.ml" -type f -delete 2>&1 || true
      find . -name "*.mli" -type f -delete 2>&1 || true

      # Remove typed trees (only for IDE tooling, not compilation)
      find . -name "*.cmt" -type f -delete 2>&1 || true
      find . -name "*.cmti" -type f -delete 2>&1 || true

      find . -name "*.annot" -type f -delete 2>&1 || true

      # Note: Keep .cma/.cmo - dune bootstrap may need bytecode libraries
      # Note: Keep .cmx/.cmxa/.a/.cmi/.o - required for native compilation
    )

    echo "  Installed via make installcross to: ${OCAML_CROSS_PREFIX}"

    # ========================================================================
    # Verify runtime library architecture
    # ========================================================================
    echo "  Verifying libasmrun.a architecture (expected: ${CROSS_ARCH})..."
    if [[ -f "${OCAML_CROSS_LIBDIR}/libasmrun.a" ]]; then
      _tmpdir=$(mktemp -d)
      (cd "$_tmpdir" && ar x "${OCAML_CROSS_LIBDIR}/libasmrun.a" 2>&1)
      _obj=$(ls "$_tmpdir"/*.o 2>&1 | head -1)
      if [[ -n "$_obj" ]]; then
        if [[ "${target_platform}" == "osx"* ]]; then
          _arch_info=$(lipo -info "$_obj" 2>&1 || file "$_obj")
        else
          _arch_info=$(readelf -h "$_obj" 2>&1 | grep -i "Machine:" || file "$_obj")
        fi
        echo "    libasmrun.a object: $_arch_info"
        # Check architecture matches target (use | not \| with grep -E)
        case "${CROSS_ARCH}" in
          arm64) _expected="arm64|ARM64|AArch64|aarch64" ;;
          aarch64) _expected="AArch64|aarch64|arm64|ARM64" ;;
          power) _expected="PowerPC|ppc64" ;;
          riscv) _expected="RISC-V|RISCV|riscv" ;;
          amd64) _expected="x86-64|x86_64|X86-64|amd64" ;;
          s390x) _expected="S/390|s390|IBM S/390" ;;
          *) _expected="${CROSS_ARCH}" ;;
        esac
        if ! echo "$_arch_info" | grep -qiE "$_expected"; then
          echo "    ✗ ERROR: libasmrun.a has WRONG architecture!"
          echo "    Expected: ${CROSS_ARCH}, Got: $_arch_info"
          rm -rf "$_tmpdir"
          exit 1
        fi
        echo "    ✓ Architecture verified: ${CROSS_ARCH}"
      fi
      rm -rf "$_tmpdir"
    else
      echo "    WARNING: libasmrun.a not found at ${OCAML_CROSS_LIBDIR}/libasmrun.a"
    fi

    # ========================================================================
    # [7/7] Copy toolchain wrappers and generate OCaml compiler wrappers
    # ========================================================================
    # These were created earlier (before crossopt) for build-time use.
    # Now copy to OCAML_INSTALL_PREFIX/bin for the final package.

    echo "  [7/7] Installing wrappers to package..."
    echo "    Copying ${target}-ocaml-* toolchain wrappers..."
    mkdir -p "${OCAML_INSTALL_PREFIX}/bin"

    for tool_name in cc as ar ld ranlib mkexe mkdll; do
      src="${BUILD_PREFIX}/bin/${target}-ocaml-${tool_name}"
      dst="${OCAML_INSTALL_PREFIX}/bin/${target}-ocaml-${tool_name}"
      if [[ -f "${src}" ]]; then
        cp "${src}" "${dst}"
        chmod +x "${dst}"
      else
        echo "    WARNING: ${src} not found"
      fi
    done
    echo "    Copied: ${target}-ocaml-{cc,as,ar,ld,ranlib,mkexe,mkdll}"

    # ========================================================================
    # Generate OCaml compiler wrapper scripts
    # FAIL-FAST: Verify CRC consistency between unix.cmxa and threads.cmxa
    # ========================================================================
    check_unix_crc \
      "${SRC_DIR}/tools/ocamlobjinfo.opt" \
      "${OCAML_CROSS_LIBDIR}/unix/unix.cmxa" \
      "${OCAML_CROSS_LIBDIR}/threads/threads.cmxa" \
      "POST-INSTALL ${target}"

    # ========================================================================
    # Generate wrapper scripts
    # ========================================================================

    for tool in ocamlopt ocamlc ocamldep ocamlobjinfo ocamllex ocamlyacc ocamlmklib; do
      generate_cross_wrapper "${tool}" "${OCAML_INSTALL_PREFIX}" "${target}" "${OCAML_CROSS_PREFIX}"
      (cd "${OCAML_INSTALL_PREFIX}"/bin && ln -s "${target}-${tool}.opt" "${target}-${tool}")
    done

    echo "  Installed: ${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt"
    echo "  Libs:      ${OCAML_CROSS_LIBDIR}/"

    # ========================================================================
    # Basic smoke test
    # ========================================================================

    echo "  Basic smoke test..."
    CROSS_OCAMLOPT="${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt"

    if "${CROSS_OCAMLOPT}" -version | grep -q "${PKG_VERSION}"; then
      echo "    ✓ Version check passed"
    else
      echo "    ✗ ERROR: Version mismatch"
      exit 1
    fi

    ${RECIPE_DIR}/testing/test-cross-compiler-consistency.sh "${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt"

    echo "  Done: ${target} (comprehensive tests run in post-install)"
  done

  echo ""
  echo "============================================================"
  echo "All cross-compilers built successfully"
  echo "============================================================"
}

# ==============================================================================
# build_cross_target() - Build cross-compiled native compiler using BUILD_PREFIX cross-compiler
# (formerly building/build-cross-target.sh)
# ==============================================================================

build_cross_target() {
  local -a CONFIG_ARGS=("${CONFIG_ARGS[@]}")

  # Sanitize mixed-arch CFLAGS early (see top-level block for rationale)
  if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
    _target_arch=$(get_arch_for_sanitization "${target_platform}")
    echo "  Sanitizing CFLAGS/LDFLAGS for ${_target_arch} cross-compilation..."
    sanitize_and_export_cross_flags "${_target_arch}"
  fi

  # Only run for cross-compilation targets
  if [[ "${build_platform}" == "${target_platform}" ]] || [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
    echo "Not a cross-compilation target, skipping"
    return 0
  fi

  # ============================================================================
  # Configuration
  # ============================================================================

  : "${OCAML_PREFIX:=${BUILD_PREFIX}}"
  : "${CROSS_COMPILER_PREFIX:=${BUILD_PREFIX}}"
  : "${OCAML_INSTALL_PREFIX:=${PREFIX}}"

  # ============================================================================
  # Platform Detection & Toolchain Setup (using common-functions.sh)
  # ============================================================================

  CROSS_ARCH=$(get_target_arch "${host_alias}")
  CROSS_PLATFORM=$(get_target_platform "${host_alias}")

  # Platform-specific settings
  NEEDS_DL=0
  CROSS_MODEL=""
  case "${target_platform}" in
    linux-*)
      NEEDS_DL=1
      [[ "${target_platform}" == "linux-ppc64le" ]] && CROSS_MODEL="ppc64le"
      ;;
    osx-*)
      ;;
    *)
      echo "ERROR: Unsupported cross-compilation target: ${target_platform}"
      exit 1
      ;;
  esac

  if [[ -z ${CROSS_CC:-} ]]; then
    # This is for the case of compatible previous conda-forge OCAML - otherwise, 3-stage sets these correctly
    setup_toolchain "CROSS" "${host_alias}"
    setup_cflags_ldflags "CROSS" "${build_platform}" "${target_platform}"
  fi

  # Same big-endian injection as build_cross_compiler(), applied after
  # setup_cflags_ldflags may have (re)populated CROSS_CFLAGS. Tree 2 is configured
  # --host="${host_alias}" so its own m.h is already correct; the helper is
  # idempotent and the -D is an identical redefinition there. It matters because
  # crosscompiledopt/crosscompiledruntime reuse tree 1's ocamlopt as CAMLOPT, so
  # the target runtime objects must agree with tree 1 on endianness.
  CROSS_CFLAGS="$(add_big_endian_define "${CROSS_PLATFORM}" "${CROSS_CFLAGS:-}")"

  # CRITICAL: Export CFLAGS/LDFLAGS to environment with clean CROSS values
  # Make inherits environment variables, and sub-makes may pick up polluted
  # environment values. By exporting CROSS_CFLAGS as CFLAGS, we ensure consistency.
  export CFLAGS="${CROSS_CFLAGS}"
  export LDFLAGS="${CROSS_LDFLAGS}"

  if [[ -z ${NATIVE_CC:-} ]]; then
    # This is for the case of compatible previous conda-forge OCAML - otherwise, 3-stage sets these correctly
    setup_toolchain "NATIVE" "${build_alias}"
    setup_cflags_ldflags "NATIVE" "${build_platform}" "${target_platform}"
  fi

  # Ensure CROSS_ASM/NATIVE_ASM are set (fallback for fast path or when setup_toolchain skipped)
  if [[ -z "${CROSS_ASM:-}" ]]; then
    if [[ "${target_platform}" == "osx-"* ]]; then
      CROSS_ASM="$(basename "${CROSS_CC}") -c"
    else
      CROSS_ASM="$(basename "${CROSS_AS}")"
    fi
    export CROSS_ASM
  fi

  if [[ -z "${NATIVE_ASM:-}" ]]; then
    if [[ "${build_platform}" == "osx-"* ]]; then
      NATIVE_ASM="$(basename "${NATIVE_CC}") -c"
    else
      NATIVE_ASM="$(basename "${NATIVE_AS}")"
    fi
    export NATIVE_ASM
  fi

  # macOS: Use DYLD_FALLBACK_LIBRARY_PATH so cross-compiler finds libzstd at runtime
  # (Stage 3 runs cross-compiler binaries from Stage 2)
  # IMPORTANT: Use FALLBACK, not DYLD_LIBRARY_PATH - FALLBACK doesn't override system libs
  setup_dyld_fallback

  echo ""
  echo "============================================================"
  echo "Cross-target build configuration (Stage 3)"
  echo "============================================================"
  echo "  Target platform:      ${target_platform}"
  echo "  Target triplet:       ${host_alias}"
  echo "  Target arch:          ${CROSS_ARCH}"
  echo "  Platform type:        ${target_platform%%-*}"
  echo "  Native OCaml:         ${OCAML_PREFIX}"
  echo "  Cross-compiler:       ${CROSS_COMPILER_PREFIX}"
  echo "  Install prefix:       ${OCAML_INSTALL_PREFIX}"
  print_toolchain_info NATIVE
  print_toolchain_info CROSS

  # ============================================================================
  # Export variables for downstream scripts
  # ============================================================================
  cat > "${SRC_DIR}/_target_compiler_${target_platform}_env.sh" << EOF
# CONDA_OCAML_* for runtime
export CONDA_OCAML_AR="${CROSS_AR}"
export CONDA_OCAML_AS="${CROSS_ASM}"
export CONDA_OCAML_CC="${CROSS_CC}"
export CONDA_OCAML_RANLIB="${CROSS_RANLIB}"
export CONDA_OCAML_MKEXE="${CROSS_MKEXE:-}"
export CONDA_OCAML_MKDLL="${CROSS_MKDLL:-}"
EOF

  # ============================================================================
  # Cross-compiler paths
  # ============================================================================

  CROSS_OCAMLOPT="${CROSS_COMPILER_PREFIX}/bin/${host_alias}-ocamlopt"
  CROSS_OCAMLMKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"

  # Verify cross-compiler exists
  if [[ ! -x "${CROSS_OCAMLOPT}" ]]; then
    echo "ERROR: Cross-compiler not found: ${CROSS_OCAMLOPT}"
    exit 1
  fi

  # OCAMLLIB must point to cross-compiler's stdlib
  export OCAMLLIB="${CROSS_COMPILER_PREFIX}/lib/ocaml-cross-compilers/${host_alias}/lib/ocaml"

  echo "  Cross ocamlopt:       ${CROSS_OCAMLOPT}"
  echo "  OCAMLLIB:             ${OCAMLLIB}"

  # Verify stdlib exists
  if [[ ! -f "${OCAMLLIB}/stdlib.cma" ]]; then
    echo "ERROR: Cross-compiler stdlib not found at ${OCAMLLIB}"
    exit 1
  fi

  # PATH: native tools first, then cross tools
  export PATH="${OCAML_PREFIX}/bin:${BUILD_PREFIX}/bin:${PATH}"
  hash -r

  # ============================================================================
  # Configure
  # ============================================================================

  echo ""
  echo "  [1/5] Configuring for ${host_alias} ==="

  # NOTE: OCaml 5.4.0+ requires CFLAGS/LDFLAGS as env vars, not configure args.
  export CC="${CROSS_CC}"
  export CFLAGS="${CROSS_CFLAGS}"
  export LDFLAGS="${CROSS_LDFLAGS}"

  CONFIG_ARGS+=(
    -prefix="${OCAML_INSTALL_PREFIX}"
    -mandir="${OCAML_INSTALL_PREFIX}"/share/man
    --build="${build_alias}"
    --host="${host_alias}"
    --target="${host_alias}"
    AR="${CROSS_AR}"
    AS="${CROSS_AS}"
    LD="${CROSS_LD}"
    RANLIB="${CROSS_RANLIB}"
  )

  if [[ "${target_platform}" == "linux-"* ]]; then
    CONFIG_ARGS+=(ac_cv_func_getentropy=no)
  fi

  # TARGET_ZSTD_AVAILABLE is exported by the [zstd-probe] in build_cross_compiler()
  # (~line 907), but that runs in a SEPARATE subshell from build_cross_target() (see
  # the two independent `( ... )` invocations around line 1985/1998) - exports do not
  # cross subshell boundaries. Recompute the same outcome-based probe locally; the
  # conda env itself persists on disk from the in-lane cross-compiler build above, so
  # this finds the real result rather than re-running conda create.
  if [[ -z "${TARGET_ZSTD_AVAILABLE:-}" ]]; then
    _TARGET_ZSTD_ENV="zstd_${CROSS_PLATFORM}"
    _TARGET_ZSTD_ENVS_DIR=$(conda info --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['envs_dirs'][0])")
    _TARGET_ZSTD_LIB="${_TARGET_ZSTD_ENVS_DIR}/${_TARGET_ZSTD_ENV}/lib"
    # libzstd.dylib: see the matching [zstd-probe] note above - macOS ships only .dylib.
    if [[ -f "${_TARGET_ZSTD_LIB}/libzstd.so" || -f "${_TARGET_ZSTD_LIB}/libzstd.a" || -f "${_TARGET_ZSTD_LIB}/libzstd.dylib" ]]; then
      TARGET_ZSTD_AVAILABLE=1
    else
      TARGET_ZSTD_AVAILABLE=0
    fi
  fi

  # No target-arch zstd for this platform (see [zstd-probe]); configure OCaml
  # without it rather than letting it emit -lzstd for a library that is absent.
  if [[ "${TARGET_ZSTD_AVAILABLE:-1}" == "0" ]]; then
    CONFIG_ARGS+=(--without-zstd)
  fi

  # zstd has no build for some targets; the [zstd-probe] sets
  # TARGET_ZSTD_AVAILABLE=0 there and configure got --without-zstd above. The
  # NATIVECCLIBS/BYTECCLIBS assignments below (crosscompiledopt at [3/5] and
  # crosscompiledruntime at [4/5]) are passed ON THE MAKE COMMAND LINE, which
  # OUTRANKS Makefile.config - a hardcoded -lzstd there puts the flag back and
  # the otherlibs link fails with "cannot find -lzstd". Computed once here
  # since both steps below use it.
  _zstd_lib=""
  if [[ "${TARGET_ZSTD_AVAILABLE:-1}" != "0" ]]; then
    _zstd_lib=" -lzstd"
  fi

  # Install conda-ocaml-* wrapper scripts to BUILD_PREFIX (needed during build)
  echo "    Installing conda-ocaml-* wrapper scripts to BUILD_PREFIX..."
  install_conda_ocaml_wrappers "${BUILD_PREFIX}/bin"

  # Set TARGET environment variables for configure
  # These tell OCaml where binaries/libraries will be at RUNTIME on the target system
  # conda-forge will relocate paths containing ${PREFIX}, but NOT paths with _native
  export TARGET_BINDIR="${PREFIX}/bin"
  export TARGET_LIBDIR="${PREFIX}/lib/ocaml"

  run_logged "stage3_configure" "${CONFIGURE[@]}" "${CONFIG_ARGS[@]}"

  # ============================================================================
  # Patch Makefile for OCaml 5.4.0 bug: CHECKSTACK_CC undefined
  # ============================================================================
  patch_checkstack_cc

  # ============================================================================
  # Patch configuration
  # ============================================================================

  echo "  [2/5] Patching configuration ==="

  # Patch config.generated.ml to use conda-ocaml-* wrapper scripts
  # Wrappers expand CONDA_OCAML_* env vars at runtime, compatible with Unix.create_process
  patch_config_generated_ml_native

  # PowerPC model
  local config_file="utils/config.generated.ml"
  [[ -n "${CROSS_MODEL}" ]] && sed -i "s#^let model = .*#let model = {|${CROSS_MODEL}|}#" "$config_file"

  # Strip build-time -L paths from config.generated.ml (macOS)
  #
  # stage3_configure (above) regenerates utils/config.generated.ml with a
  # build-time -L baked into bytecomp_c_libraries/native_c_libraries, and
  # patch_config_generated_ml_native only rewrites tool names - it does not
  # strip -L. crosscompiledopt below bakes whatever is in this file into the
  # cross ocamlopt's Config module, so this must run after both of those and
  # before crosscompiledopt. Guarded to osx only: it also removes the
  # legitimate relocatable -L${PREFIX}/lib, which macOS conda-ocaml-mkexe
  # re-supplies at runtime, but Linux cross-target lanes (aarch64/ppc64le/
  # riscv64) do NOT and would fail with "cannot find -lzstd" if unguarded.
  # Intentionally duplicates the build_native block at ~601-613.
  if [[ "${target_platform}" == "osx"* ]]; then
    local _cfg_ml="utils/config.generated.ml"
    echo "  - Stripping build-time -L paths from ${_cfg_ml}..."
    local _cvar
    for _cvar in bytecomp_c_libraries native_c_libraries compression_c_libraries; do
      if grep -q "^let ${_cvar} = " "${_cfg_ml}" 2>/dev/null; then
        sed -i -E "/^let ${_cvar} = /s#-L[^ |]+ *##g" "${_cfg_ml}"
      fi
    done
    echo "  [diag] post-strip config.generated.ml C-library vars:"
    grep -E '^let (bytecomp|native|compression)_c_libraries = ' "${_cfg_ml}" \
      | sed 's/^/    /' || echo "    [diag] (no matching vars)"
  fi

  # Apply Makefile.cross patches
  apply_cross_patches

  # Shared args for crosscompiledopt and crosscompiledruntime
  CROSS_TARGET_COMMON_ARGS=(
    ARCH="${CROSS_ARCH}"
    CAMLOPT="${CROSS_OCAMLOPT}"
    AS="${CROSS_AS}"
    ASPP="${CROSS_CC} -c ${CROSS_ASPPFLAGS:-}"
    CC="${CROSS_CC}"
    CROSS_CC="${CROSS_CC}"
    CROSS_AR="${CROSS_AR}"
    CROSS_MKLIB="${CROSS_OCAMLMKLIB}"
    # Guarded like NATIVECCLIBS/BYTECCLIBS below: a make command-line assignment
    # OUTRANKS Makefile.config, so a hardcoded -lzstd here reaches the stage-3
    # ocamlc.opt link (Makefile:556) even though configure got --without-zstd.
    ZSTD_LIBS="-L${PREFIX}/lib${_zstd_lib}"
    LIBDIR="${OCAML_INSTALL_PREFIX}/lib/ocaml"
    OCAMLLIB="${OCAMLLIB}"
    CONDA_OCAML_AS="${CROSS_ASM}"
    CONDA_OCAML_CC="${CROSS_CC}"
    CONDA_OCAML_MKEXE="${CROSS_MKEXE:-}"
    CONDA_OCAML_MKDLL="${CROSS_MKDLL:-}"
    SAK_AR="${NATIVE_AR}"
    SAK_CC="${NATIVE_CC}"
    SAK_CFLAGS="${NATIVE_CFLAGS}"
  )

  # riscv64 only: the cross-compiler package in BUILD_PREFIX ships
  # <triplet>-ocaml-mkexe, whose built-in default is
  #   x86_64-conda-linux-gnu-zig cc -target riscv64-linux-gnu -Wl,-E -ldl
  # i.e. zig (hence ld.lld) carrying no LDFLAGS at all. lld then defaults to
  # --no-allow-shlib-undefined, and the ocamlc.opt/ocamlopt.opt link fails on
  # pthread_create/pthread_join@GLIBC_2.34 referenced by the target libzstd.so.
  # Only riscv64 conda packages carry those versioned refs, which is exactly why
  # conda-forge enables --allow-shlib-undefined for riscv64 and no other linux
  # arch. That wrapper reads CONDA_OCAML_RISCV64_MKEXE (same name pattern this
  # recipe builds at recipe/scripts/cross-activate.sh:44), NOT CONDA_OCAML_MKEXE.
  # Point it at the cross gcc with the full CROSS_LDFLAGS set so the flag
  # actually reaches the link, and so a gcc lane stops linking via lld.
  if [[ "${CROSS_ARCH}" == "riscv" ]]; then
    # mkexe is a command PREFIX ($MKEXE -o out <objects> <cclibs>), so a bare -lm would land
    # before the objects and CROSS_LDFLAGS' -Wl,--as-needed would drop it. --no-as-needed forces
    # a DT_NEEDED on libm.so regardless of position. The cross ocamlopt's own native_c_libraries
    # omits -lm (baked into its Config module, not readable from Makefile.config).
    export CONDA_OCAML_RISCV64_MKEXE="${CROSS_CC} ${CROSS_LDFLAGS} -Wl,-E -ldl -Wl,--no-as-needed -lm -Wl,--as-needed"
    echo "  CONDA_OCAML_RISCV64_MKEXE=${CONDA_OCAML_RISCV64_MKEXE}"
  fi

  # ============================================================================
  # Build crosscompiledopt
  # ============================================================================

  echo "  [3/5] Building crosscompiledopt ==="

  (
    CROSSCOMPILEDOPT_ARGS=(
      "${CROSS_TARGET_COMMON_ARGS[@]}"
      LDFLAGS="${CROSS_LDFLAGS}"
      SAK_LDFLAGS="${NATIVE_LDFLAGS}"
    )

    if [[ "${target_platform}" == "linux-"* ]]; then
      CROSSCOMPILEDOPT_ARGS+=(
        CPPFLAGS="-D_DEFAULT_SOURCE"
        NATIVECCLIBS="-L${PREFIX}/lib -lm -ldl${_zstd_lib}"
        BYTECCLIBS="-L${PREFIX}/lib -lm -lpthread -ldl${_zstd_lib}"
      )
    fi

    # Override STRIP to a no-op for cross-compile builds.
    # The crosscompiledopt step builds tmpheader.exe as a cross-arch ELF (e.g.
    # riscv64-linux-gnu); the host x86_64 GNU strip cannot parse it and fails with
    # 'Unable to recognise the format'. tmpheader.exe is a build-time tool only,
    # not shipped, so stripping is unnecessary.
    CROSSCOMPILEDOPT_ARGS+=(STRIP=:)

    # linux-s390x ONLY: force the stdlib .cmi compiler to the in-tree ocamlc,
    # same fix as the crossopt leg (see STDLIB_CMI_PIN_INTREE note above) - the
    # bare `ocamlc` in Makefile.cross's CROSS_OVERRIDES resolves via PATH to
    # $BUILD_PREFIX/bin/ocamlc, which is zstd-enabled and emits .cmi carrying
    # the COMPRESSED marshal magic that the zstd-less s390x runtime cannot
    # read. This stage-3 leg produces the packaged ocaml-compiler output, so
    # it must be pinned too. V=1 (verbose make output) is guarded in the same
    # block so it stays a no-op on the other eight targets.
    if [[ "${CROSS_PLATFORM}" == "linux-s390x" ]]; then
      CROSSCOMPILEDOPT_ARGS+=( STDLIB_CMI_PIN_INTREE=1 V=1 )
      echo "  linux-s390x: pinning stdlib CAMLC to in-tree ocamlc for crosscompiledopt"
    fi

    # QEMU_LD_PREFIX: same rationale as the crossopt leg above.
    if [[ "${CROSS_PLATFORM}" != "${build_platform:-}" && -n "${OCAML_TARGET_TRIPLET:-}" ]]; then
      _qemu_sysroot="${BUILD_PREFIX}/${OCAML_TARGET_TRIPLET}/sysroot"
      if [[ -d "${_qemu_sysroot}" ]]; then
        export QEMU_LD_PREFIX="${_qemu_sysroot}"
        echo "  [qemu] QEMU_LD_PREFIX=${QEMU_LD_PREFIX}"
      else
        echo "  [qemu] WARNING: expected target sysroot not found at ${_qemu_sysroot}; leaving QEMU_LD_PREFIX unset"
      fi
    fi

    run_logged "crosscompiledopt" "${MAKE[@]}" crosscompiledopt "${CROSSCOMPILEDOPT_ARGS[@]}" -j"${CPU_COUNT}"
  )

  # ============================================================================
  # Build crosscompiledruntime
  # ============================================================================

  echo "  [4/5] Building crosscompiledruntime ==="

  # Fix build_config.h paths for target
  sed -i "s#${BUILD_PREFIX}/lib/ocaml#${OCAML_INSTALL_PREFIX}/lib/ocaml#g" runtime/build_config.h
  sed -i "s#${build_alias}#${host_alias}#g" runtime/build_config.h

  (
    CROSSCOMPILEDRUNTIME_ARGS=(
      "${CROSS_TARGET_COMMON_ARGS[@]}"
      CHECKSTACK_CC="${NATIVE_CC}"
    )

    if [[ "${target_platform}" == "osx-"* ]]; then
      CROSSCOMPILEDRUNTIME_ARGS+=(
        LDFLAGS="${CROSS_LDFLAGS}"
        SAK_LDFLAGS="${NATIVE_LDFLAGS}"
      )
    else
      CROSSCOMPILEDRUNTIME_ARGS+=(
        CPPFLAGS="-D_DEFAULT_SOURCE"
        BYTECCLIBS="-L${PREFIX}/lib -lm -lpthread -ldl${_zstd_lib}"
        NATIVECCLIBS="-L${PREFIX}/lib -lm -ldl${_zstd_lib}"
        SAK_LINK="${NATIVE_CC} \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)"
      )
    fi

    # linux-s390x ONLY: verbose make output (V=1) for crosscompiledruntime,
    # guarded so it stays a no-op on the other eight targets.
    if [[ "${CROSS_PLATFORM}" == "linux-s390x" ]]; then
      CROSSCOMPILEDRUNTIME_ARGS+=( V=1 )
    fi

    run_logged "crosscompiledruntime" "${MAKE[@]}" crosscompiledruntime "${CROSSCOMPILEDRUNTIME_ARGS[@]}" -j"${CPU_COUNT}"
  )

  # ============================================================================
  # Install
  # ============================================================================

  echo "  [5/5] Installing ==="

  # Replace stripdebug with no-op (can't execute target binaries on build machine)
  rm -f tools/stripdebug tools/stripdebug.ml tools/stripdebug.mli tools/stripdebug.cmi tools/stripdebug.cmo
  cat > tools/stripdebug.ml << 'STRIPDEBUG'
let () =
  let src = Sys.argv.(1) in
  let dst = Sys.argv.(2) in
  let ic = open_in_bin src in
  let len = in_channel_length ic in
  let buf = Bytes.create len in
  really_input ic buf 0 len;
  close_in ic;
  let oc = open_out_bin dst in
  output oc buf 0 len;
  close_out oc
STRIPDEBUG
  "${OCAML_PREFIX}/bin/ocamlc" -o tools/stripdebug tools/stripdebug.ml
  rm -f tools/stripdebug.ml tools/stripdebug.cmi tools/stripdebug.cmo

  run_logged "installcross" "${MAKE[@]}" installcross

  # ============================================================================
  # Post-install fixes
  # ============================================================================

  # Clean hardcoded -L paths from installed Makefile.config
  echo "    Cleaning hardcoded paths from Makefile.config..."
  local installed_config="${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config"
  clean_makefile_config "${installed_config}" "${PREFIX}"

  # NOTE: runtime-launch-info cleanup deferred to post-transfer
  # Cleaning here would corrupt the file if this is an intermediate build stage

  if [[ "${target_platform}" == "osx-"* ]]; then
    echo "    Fixing macOS install names..."
    bash "${RECIPE_DIR}/building/fix-macos-install-names.sh" "${OCAML_INSTALL_PREFIX}/lib/ocaml"
  fi

  # Install conda-ocaml-* wrapper scripts (expand CONDA_OCAML_* env vars for tools like Dune)
  echo "    Installing conda-ocaml-* wrapper scripts..."
  install_conda_ocaml_wrappers "${OCAML_INSTALL_PREFIX}/bin"

  # Clean up for potential cross-compiler builds
  run_logged "distclean" "${MAKE[@]}"  distclean

  echo ""
  echo "============================================================"
  echo "Cross-target build complete"
  echo "============================================================"
  echo "  Target:    ${host_alias}"
  echo "  Installed: ${OCAML_INSTALL_PREFIX}"
}

# ==============================================================================
# MODE: native
# Build native OCaml compiler
# ==============================================================================
if [[ "${BUILD_MODE}" == "native" ]]; then
  OCAML_NATIVE_INSTALL_PREFIX="${SRC_DIR}"/_native_compiler

  # Try to restore from cache
  if cache_native_exists; then
    echo ""
    echo "=== Restoring native OCaml from cache ==="
    cache_native_restore "${OCAML_NATIVE_INSTALL_PREFIX}"
  else
    echo ""
    echo "=== Building native OCaml ==="
    (
      OCAML_INSTALL_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
      build_native
    )
    # Save to cache after successful build
    cache_native_save "${OCAML_NATIVE_INSTALL_PREFIX}"
  fi

  # Transfer to PREFIX
  OCAML_INSTALL_PREFIX="${PREFIX}"

  if is_unix; then
    transfer_to_prefix "${OCAML_NATIVE_INSTALL_PREFIX}" "${OCAML_INSTALL_PREFIX}"
  else
    # Windows: cp -rL dereferences symlinks
    cp -rL "${OCAML_NATIVE_INSTALL_PREFIX}/"* "${OCAML_INSTALL_PREFIX}/"
    makefile_config="${OCAML_INSTALL_PREFIX}/Library/lib/ocaml/Makefile.config"
    WIN_OCAMLLIB=$(echo "${OCAML_INSTALL_PREFIX}/Library/lib/ocaml" | sed 's#^/\([a-zA-Z]\)/#\1:/#')
    cat > "${OCAML_INSTALL_PREFIX}/Library/lib/ocaml/ld.conf" << EOF
${WIN_OCAMLLIB}/stublibs
${WIN_OCAMLLIB}
EOF
    sed -i "s#/.*build_env/bin/##g" "${makefile_config}"
    sed -i 's#$(CC)#$(CONDA_OCAML_CC)#g' "${makefile_config}"
  fi

  # CRITICAL: Clean build-time paths from FINAL installed Makefile.config
  # This must happen AFTER transfer_to_prefix because that's when the file reaches ${PREFIX}
  echo "  Cleaning build-time paths from final Makefile.config..."
  if is_unix; then
    clean_makefile_config "${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config" "${OCAML_INSTALL_PREFIX}"
  else
    clean_makefile_config "${OCAML_INSTALL_PREFIX}/Library/lib/ocaml/Makefile.config" "${OCAML_INSTALL_PREFIX}"
  fi

  # Clean build-time paths from runtime-launch-info (after transfer to PREFIX)
  echo "  Cleaning build-time paths from final runtime-launch-info..."
  if is_unix; then
    clean_runtime_launch_info "${OCAML_INSTALL_PREFIX}/lib/ocaml/runtime-launch-info" "${OCAML_INSTALL_PREFIX}"
  fi

fi

# toplevel/byte/*.cmi are deleted by GNU make as chained-implicit-rule intermediates
# (upstream Makefile:400-402 pattern rule, never .PRECIOUS/.SECONDARY), but `make install`
# (upstream Makefile:2717-2719) globs them. Makefile.cross restores them from the toplevel/
# root copies just before install. Exported (not passed as a make arg) because there are two
# installcross call sites and one of them takes no arguments. Deliberately a dedicated flag
# rather than reusing STDLIB_CMI_PIN_INTREE, which would also flip the CAMLC/CAMLOPT pins
# across the entire install phase.
# Guarded on OCAML_TARGET_PLATFORM, not target_platform: on the host-cross lane
# (linux_64_cross_target_platform_linux-s390x) target_platform is linux-64 and only
# OCAML_TARGET_PLATFORM is linux-s390x, so target_platform would miss that lane entirely.
# OCAML_TARGET_PLATFORM is set by the recipe.yaml env section and hard-validated at
# build.sh:167-170, so it is guaranteed present here.
if [[ "${OCAML_TARGET_PLATFORM}" == "linux-s390x" ]]; then
  export OCAML_TOPLEVEL_BYTE_CMI_RESTORE=1
fi

# ==============================================================================
# MODE: cross-compiler
# Build cross-compiler (native binaries producing target code)
# ==============================================================================
if [[ "${BUILD_MODE}" == "cross-compiler" ]]; then
  # Native OCaml is available in BUILD_PREFIX (from ocaml_$build_platform dependency)

  # Setup native toolchain variables needed by build_cross_compiler (NATIVE_CC, SAK_*, etc.)
  setup_toolchain "NATIVE" "${CONDA_TOOLCHAIN_BUILD}"
  setup_cflags_ldflags "NATIVE" "${build_platform:-${target_platform}}" "${target_platform}"

  OCAML_XCROSS_INSTALL_PREFIX="${SRC_DIR}"/_xcross_compiler
  (
    export OCAML_PREFIX="${BUILD_PREFIX}"
    export OCAMLLIB="${OCAML_PREFIX}/lib/ocaml"
    OCAML_INSTALL_PREFIX="${OCAML_XCROSS_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    build_cross_compiler
  )

  # Transfer cross-compiler files to PREFIX
  echo ""
  echo "=== Transferring cross-compiler to PREFIX ==="
  OCAML_INSTALL_PREFIX="${PREFIX}"

  # Only copy cross-compiler specific files
  tar -C "${OCAML_XCROSS_INSTALL_PREFIX}" -cf - . | tar -C "${OCAML_INSTALL_PREFIX}" -xf -

  # Fix cross-compiler Makefile.config and ld.conf
  for cross_dir in "${OCAML_INSTALL_PREFIX}"/lib/ocaml-cross-compilers/*/; do
    [[ -d "$cross_dir" ]] || continue
    triplet=$(basename "$cross_dir")
    echo "  Fixing paths for ${triplet}..."

    # Replace staging paths with install paths in Makefile.config
    makefile_config="${cross_dir}/lib/ocaml/Makefile.config"
    if [[ -f "$makefile_config" ]]; then
      sed -i "s#${OCAML_XCROSS_INSTALL_PREFIX}#${OCAML_INSTALL_PREFIX}#g" "$makefile_config"
      sed -i "s#/.*build_env/bin/##g" "$makefile_config"
      sed -i 's#$(CC)#$(CONDA_OCAML_CC)#g' "$makefile_config"
      echo "    Fixed: lib/ocaml-cross-compilers/${triplet}/lib/ocaml/Makefile.config"
    fi

    # Fix ld.conf
    ldconf="${cross_dir}/lib/ocaml/ld.conf"
    if [[ -f "$ldconf" ]]; then
      cat > "$ldconf" << EOF
${cross_dir}lib/ocaml/stublibs
${cross_dir}lib/ocaml
EOF
      echo "    Fixed: lib/ocaml-cross-compilers/${triplet}/lib/ocaml/ld.conf"
    fi

    # Fix runtime-launch-info (binary file - use binary-safe cleanup)
    runtime_info="${cross_dir}/lib/ocaml/runtime-launch-info"
    if [[ -f "$runtime_info" ]]; then
      clean_runtime_launch_info "$runtime_info" "${OCAML_INSTALL_PREFIX}"
    fi
  done
fi

# ==============================================================================
# MODE: cross-target
# Build using cross-compiler from BUILD_PREFIX (cross-compiled native)
# ==============================================================================
if [[ "${BUILD_MODE}" == "cross-target" ]]; then
  CROSS_TARGET="${OCAML_TARGET_TRIPLET}"

  # The ocaml_${target_platform} cross-compiler package is deliberately NOT a
  # build dependency of this output (see recipe.yaml, is_cross_target branch):
  # for a new architecture it may not exist on conda-forge yet, and the lane
  # that produces it (is_cross_compiler, on the designated cross_build_platform)
  # is a separate CI job whose artifacts this job cannot see.
  #
  # Build the cross-compiler in-lane instead, unconditionally rather than
  # only-when-missing, so the identical code path runs locally and in CI, and
  # the cross-compiler is guaranteed to match this exact source tree and version.
  OCAML_XCROSS_INSTALL_PREFIX="${SRC_DIR}"/_xcross_compiler
  CROSS_COMPILER_DIR="${OCAML_XCROSS_INSTALL_PREFIX}/lib/ocaml-cross-compilers/${CROSS_TARGET}"

  echo ""
  echo "=== Cross-target build: building cross-compiler in-lane ==="
  echo "  Cross-compiler: ${CROSS_COMPILER_DIR}"

  (
    # setup_toolchain/setup_cflags_ldflags are required by build_cross_compiler
    # (NATIVE_CC, SAK_*, NATIVE_CFLAGS/LDFLAGS). Kept INSIDE this subshell so the
    # NATIVE_* exports cannot leak into build_cross_target below.
    setup_toolchain "NATIVE" "${CONDA_TOOLCHAIN_BUILD}"
    setup_cflags_ldflags "NATIVE" "${build_platform:-${target_platform}}" "${target_platform}"
    export OCAML_PREFIX="${BUILD_PREFIX}"
    export OCAML_CROSS_FINAL_PREFIX="${OCAML_XCROSS_INSTALL_PREFIX}"
    export OCAMLLIB="${OCAML_PREFIX}/lib/ocaml"
    OCAML_INSTALL_PREFIX="${OCAML_XCROSS_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    build_cross_compiler
  )

  if [[ ! -f "${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma" ]]; then
    echo "ERROR: in-lane cross-compiler build produced no ${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma"
    exit 1
  fi

  OCAML_TARGET_INSTALL_PREFIX="${SRC_DIR}"/_target_compiler
  (
    export OCAML_PREFIX="${BUILD_PREFIX}"
    export CROSS_COMPILER_PREFIX="${OCAML_XCROSS_INSTALL_PREFIX}"
    OCAML_INSTALL_PREFIX="${OCAML_TARGET_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    build_cross_target
  )

  # Transfer to PREFIX
  OCAML_INSTALL_PREFIX="${PREFIX}"
  transfer_to_prefix "${OCAML_TARGET_INSTALL_PREFIX}" "${OCAML_INSTALL_PREFIX}"

  # CRITICAL: Clean build-time paths from FINAL installed Makefile.config
  echo "  Cleaning build-time paths from final Makefile.config..."
  clean_makefile_config "${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config" "${OCAML_INSTALL_PREFIX}"

  # CRITICAL: Clean build-time paths from runtime-launch-info
  # The cross-target build copies runtime-launch-info from the cross-compiler's stdlib,
  # which has BINDIR pointing to the cross-compiler's staging directory.
  # Replace line 2 with the correct target BINDIR ($PREFIX/bin).
  echo "  Cleaning build-time paths from final runtime-launch-info..."
  clean_runtime_launch_info "${OCAML_INSTALL_PREFIX}/lib/ocaml/runtime-launch-info" "${OCAML_INSTALL_PREFIX}"
fi

# ==============================================================================
# Common post-processing (native and cross-target modes only)
# ==============================================================================
if [[ "${BUILD_MODE}" == "native" ]] || [[ "${BUILD_MODE}" == "cross-target" ]]; then
  OCAML_INSTALL_PREFIX="${PREFIX}"

  # non-Unix: replace symlinks with copies
  if ! is_unix; then
    for bin in "${OCAML_INSTALL_PREFIX}"/bin/*; do
      if [[ -L "$bin" ]]; then
        target=$(readlink "$bin")
        rm "$bin"
        cp "${OCAML_INSTALL_PREFIX}/bin/${target}" "$bin"
      fi
    done
  fi

  # Fix bytecode wrapper shebangs
  for bin in "${OCAML_INSTALL_PREFIX}"/bin/*; do
    [[ -f "$bin" ]] || continue
    [[ -L "$bin" ]] && continue

    # Check for ocamlrun reference (need 350 bytes for long conda placeholder paths)
    if head -c 350 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
      if is_unix; then
        fix_ocamlrun_shebang "$bin" "${SRC_DIR}"/_logs/shebang.log 2>&1 || { cat "${SRC_DIR}"/_logs/shebang.log; exit 1; }
      fi
      continue
    fi

    # Pure shell scripts: fix exec statements
    if file "$bin" 2>/dev/null | grep -qE "shell script|POSIX shell|text"; then
      sed -i "s#exec '\([^']*\)'#exec \1#" "$bin"
      sed -i "s#exec ${OCAML_INSTALL_PREFIX}/bin#exec \$(dirname \"\$0\")#" "$bin"
    fi
  done

  # ==============================================================================
  # Install activation scripts with build-time tool substitution
  # ==============================================================================
  echo ""
  echo "=== Installing activation scripts ==="

  (
    # Source native compiler env if available (not present in Stage 3 fast path)
    if [[ -f "${SRC_DIR}/_native_compiler_env.sh" ]]; then
      source "${SRC_DIR}/_native_compiler_env.sh"
    fi

    # Cross-target mode: override with TARGET platform toolchain
    # The package runs on OCAML_TARGET_PLATFORM, so it needs that platform's tools
    if [[ "${BUILD_MODE}" == "cross-target" ]]; then
      echo "  (Using TARGET toolchain: ${OCAML_TARGET_TRIPLET}-*)"
      # macOS has no -gcc driver; common-functions.sh selects -clang for *-apple-*
      # and only linux/mingw use -gcc. Mirror that here.
      _drv="gcc"
      _mkexe_flags=""
      _mkdll_flags="-shared"
      case "${OCAML_TARGET_TRIPLET}" in
        *-apple-*)
          _drv="clang"
          # Mirror common-functions.sh setup_toolchain()'s *-apple-* branch (MKEXE/MKDLL
          # composition) so the flags baked into the SHIPPED activation script match what
          # a native build would use. -isysroot is deliberately excluded: it is a BUILD-
          # machine absolute SDK path and would be a relocation hazard once baked in.
          _vmin="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-10.13}"
          _mkexe_flags="${_vmin} -Wl,-headerpad_max_install_names -Wl,-rpath,@executable_path/../lib"
          _mkdll_flags="${_vmin} -shared -Wl,-headerpad_max_install_names -undefined dynamic_lookup"
          ;;
      esac
      export CONDA_OCAML_AR="${OCAML_TARGET_TRIPLET}-ar"
      export CONDA_OCAML_AS="${OCAML_TARGET_TRIPLET}-as"
      export CONDA_OCAML_CC="${OCAML_TARGET_TRIPLET}-${_drv}"
      export CONDA_OCAML_LD="${OCAML_TARGET_TRIPLET}-ld"
      export CONDA_OCAML_RANLIB="${OCAML_TARGET_TRIPLET}-ranlib"
      export CONDA_OCAML_MKEXE="${OCAML_TARGET_TRIPLET}-${_drv}${_mkexe_flags:+ ${_mkexe_flags}}"
      export CONDA_OCAML_MKDLL="${OCAML_TARGET_TRIPLET}-${_drv} ${_mkdll_flags}"
      export CONDA_OCAML_WINDRES="${OCAML_TARGET_TRIPLET}-windres"
    elif [[ -z "${CONDA_OCAML_AR:-}" ]]; then
      # Stage 3 fast path (native mode): use triplet-prefixed names from BUILD_PREFIX
      # These MUST be triplet-prefixed (not generic cc/ar) because in cross-compilation
      # scenarios, generic 'cc' points to the TARGET compiler, but conda-ocaml-cc in
      # ocaml_osx-64 (BUILD_PREFIX) needs the BUILD PLATFORM compiler.
      # ocaml_$platform declares a run dep on the platform-specific C compiler package
      # to ensure these binaries are available.
      echo "  (Using BUILD_PREFIX defaults - native mode)"
      export CONDA_OCAML_AR=$(basename "${AR:-ar}")
      export CONDA_OCAML_AS=$(basename "${AS:-as}")
      export CONDA_OCAML_CC=$(basename "${CC:-cc}")
      export CONDA_OCAML_LD=$(basename "${LD:-ld}")
      export CONDA_OCAML_RANLIB=$(basename "${RANLIB:-ranlib}")
      # macOS needs rpath for downstream binaries to find libzstd
      if [[ "${target_platform}" == osx-* ]]; then
        export CONDA_OCAML_MKEXE="${CC:-cc} -Wl,-rpath,@executable_path/../lib"
      else
        export CONDA_OCAML_MKEXE="${CC:-cc}"
      fi
      # macOS needs -undefined dynamic_lookup to defer symbol resolution to runtime
      if [[ "${target_platform}" == osx-* ]]; then
        export CONDA_OCAML_MKDLL="${CC:-cc} -shared -undefined dynamic_lookup"
      else
        export CONDA_OCAML_MKDLL="${CC:-cc} -shared"
      fi
      export CONDA_OCAML_WINDRES="${WINDRES:-windres}"
    fi

    # Helper: convert "fullpath/cmd flags" to "cmd flags" (basename first word only)
    _basename_cmd() {
      local cmd="$1"
      local first="${cmd%% *}"
      local rest="${cmd#* }"
      if [[ "$rest" == "$cmd" ]]; then
        basename "$first"
      else
        echo "$(basename "$first") $rest"
      fi
    }

    for CHANGE in "activate" "deactivate"; do
      mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
      # Use fixed name "ocaml" for consistency with 5.3.0 (not PKG_NAME which varies by output)
      _SCRIPT="${PREFIX}/etc/conda/${CHANGE}.d/ocaml_${CHANGE}.${SH_EXT}"
      cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${_SCRIPT}" 2>/dev/null || continue
      # Replace @XX@ placeholders with runtime-safe basenames (not full build paths)
      sed -i "s|@AR@|$(basename "${CONDA_OCAML_AR}")|g" "${_SCRIPT}"
      sed -i "s|@AS@|$(basename "${CONDA_OCAML_AS}")|g" "${_SCRIPT}"
      sed -i "s|@CC@|$(basename "${CONDA_OCAML_CC}")|g" "${_SCRIPT}"
      sed -i "s|@LD@|$(basename "${CONDA_OCAML_LD}")|g" "${_SCRIPT}"
      sed -i "s|@RANLIB@|$(basename "${CONDA_OCAML_RANLIB}")|g" "${_SCRIPT}"
      sed -i "s|@MKEXE@|$(_basename_cmd "${CONDA_OCAML_MKEXE}")|g" "${_SCRIPT}"
      sed -i "s|@MKDLL@|$(_basename_cmd "${CONDA_OCAML_MKDLL}")|g" "${_SCRIPT}"
      sed -i "s|@WINDRES@|$(basename "${CONDA_OCAML_WINDRES:-windres}")|g" "${_SCRIPT}"
    done
  )
fi

# ==============================================================================
# Cross-compiler post-processing
# ==============================================================================
if [[ "${BUILD_MODE}" == "cross-compiler" ]]; then
  OCAML_INSTALL_PREFIX="${PREFIX}"

  # Fix bytecode wrapper shebangs for cross-compiler binaries
  for bin in "${OCAML_INSTALL_PREFIX}"/lib/ocaml-cross-compilers/*/bin/*; do
    [[ -f "$bin" ]] || continue
    [[ -L "$bin" ]] && continue

    if head -c 350 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
      if is_unix; then
        fix_ocamlrun_shebang "$bin" "${SRC_DIR}"/_logs/shebang.log 2>&1 || { cat "${SRC_DIR}"/_logs/shebang.log; exit 1; }
      fi
    fi
  done

  # Install cross-compiler activation scripts with swap functions
  # These provide ocaml_use_cross / ocaml_use_native for downstream build scripts
  _CROSS_TARGET="${OCAML_TARGET_TRIPLET}"
  _CROSS_TARGET_ID=$(get_target_id "${_CROSS_TARGET}")

  # Extract cross-compiler tool defaults from the generated wrapper scripts.
  # The wrappers (generated by generate_cross_wrapper) contain lines like:
  #   export CONDA_OCAML_CC="${CONDA_OCAML_AARCH64_CC:-aarch64-conda-linux-gnu-gcc}"
  # We extract the default value (after :-) from any wrapper.
  _CROSS_WRAPPER=$(ls "${PREFIX}"/bin/${_CROSS_TARGET}-ocamlopt.opt 2>/dev/null | head -1)
  if [[ -z "${_CROSS_WRAPPER}" ]]; then
    echo "ERROR: No cross-compiler wrapper found for ${_CROSS_TARGET}"
    exit 1
  fi
  # Extract default value after :- from wrapper lines like:
  #   export CONDA_OCAML_CC="${CONDA_OCAML_AARCH64_CC:-aarch64-conda-linux-gnu-gcc}"
  # Strip ${LDFLAGS} from MKEXE/MKDLL — those are build-time only, not for activation.
  _extract_default() {
    grep "CONDA_OCAML_$1=" "${_CROSS_WRAPPER}" | sed 's/.*:-//' | sed 's/\"\s*$//' | sed 's/}$//' | sed 's/\${LDFLAGS}//g' | xargs
  }
  _CROSS_CC=$(_extract_default "CC")
  _CROSS_AS=$(_extract_default "AS")
  _CROSS_AR=$(_extract_default "AR")
  _CROSS_LD=$(_extract_default "LD")
  _CROSS_RANLIB=$(_extract_default "RANLIB")
  _CROSS_MKEXE=$(_extract_default "MKEXE")
  _CROSS_MKDLL=$(_extract_default "MKDLL")

  for CHANGE in "activate" "deactivate"; do
    mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
    _SCRIPT="${PREFIX}/etc/conda/${CHANGE}.d/ocaml_cross_${CHANGE}.sh"
    cp "${RECIPE_DIR}/scripts/cross-${CHANGE}.sh" "${_SCRIPT}"

    if [[ "${CHANGE}" == "activate" ]]; then
      sed -i "s|@TARGET@|${_CROSS_TARGET}|g" "${_SCRIPT}"
      sed -i "s|@TARGET_ID@|${_CROSS_TARGET_ID}|g" "${_SCRIPT}"
      sed -i "s|@CROSS_CC@|${_CROSS_CC}|g" "${_SCRIPT}"
      sed -i "s|@CROSS_AS@|${_CROSS_AS}|g" "${_SCRIPT}"
      sed -i "s|@CROSS_AR@|${_CROSS_AR}|g" "${_SCRIPT}"
      sed -i "s|@CROSS_LD@|${_CROSS_LD}|g" "${_SCRIPT}"
      sed -i "s|@CROSS_RANLIB@|${_CROSS_RANLIB}|g" "${_SCRIPT}"
      sed -i "s|@CROSS_MKEXE@|${_CROSS_MKEXE}|g" "${_SCRIPT}"
      sed -i "s|@CROSS_MKDLL@|${_CROSS_MKDLL}|g" "${_SCRIPT}"
    fi
  done
  echo "  Installed cross-compiler activation scripts (ocaml_use_cross/ocaml_use_native)"
fi

echo ""
echo "============================================================"
echo "Build complete: ${PKG_NAME} (${BUILD_MODE} mode)"
echo "============================================================"

# ==============================================================================
# macOS ocamlmklib wrapper: REMOVED
# ==============================================================================
# Previously replaced bin/ocamlmklib (bytecode) with a shell wrapper adding
# -ldopt "-Wl,-undefined,dynamic_lookup". This is REDUNDANT because:
# 1. config.generated.ml is patched to use conda-ocaml-mkdll as MKDLL
# 2. CONDA_OCAML_MKDLL already includes -undefined dynamic_lookup on macOS
# 3. The wrapper broke dependency-based builds (build_number > 0) because
#    ocamlrun can't read a shell script as bytecode
# If downstream packages need -undefined dynamic_lookup, it should come through
# CONDA_OCAML_MKDLL (set by activate.sh), not by wrapping the bytecode binary.
