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
# Fix 2026-04-26b: empty MINGW64ARM default_libs in flexdll patch (chain search_path init too early);
# explicitly add -luser32/-lkernel32/-ladvapi32/-lshell32 to BYTECCLIBS for arm64 Windows link.

echo ""
echo "============================================================"
echo "OCaml Build Script - Mode Detection"
echo "  BUILD_SCRIPT_VERSION: 2026-04-29d (gcc-bat-trace-wildcard-and-surface-logs)"
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
# NOTE: CONDA_OCAML_MKEXE intentionally NOT set - use native linker.
_setup_crossopt_env() {
  # On Windows, conda-ocaml-*.exe wrappers are native PE binaries.
  # _spawnvp can't resolve MSYS2 POSIX paths (/d/bld/...).
  # Convert executable paths to Windows mixed format (D:/bld/...) via cygpath -m.
  if ! is_unix && command -v cygpath &>/dev/null; then
    _to_win() {
      local _full="$1" _exe _args
      _exe="${_full%% *}"
      if [[ "${_full}" == *" "* ]]; then
        _args="${_full#* }"
        echo "$(cygpath -m "${_exe}") ${_args}"
      else
        cygpath -m "${_exe}"
      fi
    }
    export CONDA_OCAML_AS="$(_to_win "${CROSS_AS}")"
    export CONDA_OCAML_CC="$(_to_win "${CROSS_CC}")"
    export CONDA_OCAML_AR="$(_to_win "${CROSS_AR}")"
    export CONDA_OCAML_RANLIB="$(_to_win "${CROSS_RANLIB}")"
    export CONDA_OCAML_MKDLL="$(_to_win "${CROSS_MKDLL}")"
  else
    export CONDA_OCAML_AS="${CROSS_AS}"
    export CONDA_OCAML_CC="${CROSS_CC}"
    export CONDA_OCAML_AR="${CROSS_AR}"
    export CONDA_OCAML_RANLIB="${CROSS_RANLIB}"
    export CONDA_OCAML_MKDLL="${CROSS_MKDLL}"
  fi
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
      export NATIVE_LDFLAGS="/LIBPATH:${_PREFIX_}/Library/lib ${NATIVE_LDFLAGS:-}"
    else
      export NATIVE_LDFLAGS="-L${_PREFIX_}/Library/lib ${NATIVE_LDFLAGS:-}"
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
  # The -L path removal for bytecomp_c_libraries happens AFTER world.opt build
  # but BEFORE install, to avoid non-relocatable paths in installed binaries.

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
    # TOOLCHAIN=mingw64 always (build-platform toolchain, controls RC=windres vs rc.exe)
    sed -i 's/^TOOLCHAIN.*/TOOLCHAIN=mingw64/' "$config_file"
    # FLEXDLL_CHAIN varies: mingw64arm for win-arm64 cross, mingw64 otherwise
    if [[ "${OCAML_TARGET_TRIPLET}" == "aarch64-w64-mingw32"* ]]; then
      sed -i 's/^FLEXDLL_CHAIN.*/FLEXDLL_CHAIN=mingw64arm/' "$config_file"
    else
      sed -i 's/^FLEXDLL_CHAIN.*/FLEXDLL_CHAIN=mingw64/' "$config_file"
    fi

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

  if [[ "${target_platform}" != "linux"* ]] && [[ "${target_platform}" != "osx"* ]] && [[ "${target_platform}" != "win"* ]]; then
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
  # On Windows, binaries are in Library/bin, not bin
  if is_unix; then
    PATH="${OCAML_PREFIX}/bin:${PATH}"
  else
    PATH="${OCAML_PREFIX}/Library/bin:${OCAML_PREFIX}/bin:${PATH}"
  fi
  hash -r
  echo "  PATH updated to include OCaml tools"

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
    setup_cflags_ldflags "CROSS" "${build_platform:-${target_platform}}" "${CROSS_PLATFORM}"

    # Normalize Windows backslashes in CROSS_* path vars (same reason as NATIVE_* above)
    if ! is_unix; then
      for _var in CROSS_CC CROSS_AR CROSS_AS CROSS_ASM CROSS_LD CROSS_NM \
                  CROSS_RANLIB CROSS_STRIP CROSS_MKDLL CROSS_MKEXE; do
        if [[ -n "${!_var:-}" ]]; then
          export "${_var}=${!_var//\\//}"
        fi
      done
    fi

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

      # Create in BUILD_PREFIX bin dir for build-time PATH access
      if is_unix; then
        wrapper_path="${BUILD_PREFIX}/bin/${target}-ocaml-${tool_name}"
      else
        wrapper_path="${BUILD_PREFIX}/Library/bin/${target}-ocaml-${tool_name}"
      fi
      cat > "${wrapper_path}" << TOOLWRAPPER
#!/usr/bin/env bash
# OCaml cross-compiler toolchain wrapper for ${target}
# Reads CONDA_OCAML_${TARGET_ID}_${env_suffix} or uses default cross-tool
exec \${CONDA_OCAML_${TARGET_ID}_${env_suffix}:-${default_tool}} "\$@"
TOOLWRAPPER
      chmod +x "${wrapper_path}"
    done
    echo "    Created in BUILD_PREFIX: ${target}-ocaml-{cc,as,ar,ld,ranlib,mkexe,mkdll}"

    # Create ${target}-gcc.bat wrapper for flexlink's -chain mingw64arm.
    # flexdll's version.ml hardcodes "aarch64-w64-mingw32-gcc" as the compiler.
    # Must be a .bat file — flexlink calls the compiler via CreateProcess/cmd.exe,
    # not via bash, so a bash shim is invisible to it.
    if ! is_unix; then
      # Extract zig exe path from CROSS_CC (e.g. "/path/zig.exe cc -target foo")
      _zig_exe_path="${CROSS_CC%% *}"  # everything before first space
      # Convert to Windows path format for the bat file
      _zig_exe_win=$(cygpath -w "${_zig_exe_path}" 2>/dev/null || echo "${_zig_exe_path//\//\\}")
      # Extract target triple from CROSS_CC (e.g. "...zig.exe cc -target aarch64-windows-gnu")
      _zig_target_triple=""
      if [[ "${CROSS_CC}" == *"-target "* ]]; then
        _zig_target_triple="${CROSS_CC##*-target }"   # "aarch64-windows-gnu [maybe more]"
        _zig_target_triple="${_zig_target_triple%% *}" # "aarch64-windows-gnu"
      fi
      _flexlink_gcc_bat="${BUILD_PREFIX}/Library/bin/${target}-gcc.bat"
      # crt2.o intercept: flexlink's -chain mingw64arm queries `gcc -print-file-name=crt2.o`
      # which ignores positional args / FLEXLINKFLAGS. Intercept it in the shim.
      _crt2_win="${_crt2_dst:-CRT2_DST_UNSET}"
      if [[ "${_crt2_win}" != "CRT2_DST_UNSET" ]]; then
        _crt2_win=$(cygpath -w "${_crt2_dst}" 2>/dev/null || echo "${_crt2_dst//\//\\\\}")
      fi
      echo "    DEBUG _crt2_dst at gcc.bat creation: '${_crt2_dst:-UNSET}' → win='${_crt2_win}'"
      cat > "${_flexlink_gcc_bat}" << GCCBAT
@echo off
echo [%DATE% %TIME%] gcc.bat called with: [%*] >> "%TEMP%\gcc-bat-trace.log"
echo "%*" | findstr /C:"-print-file-name=crt2.o" >nul 2>&1
if not errorlevel 1 (
  echo ${_crt2_win}
  exit /b 0
)
"${_zig_exe_win}" cc -target ${_zig_target_triple} %*
GCCBAT
      echo "    Created flexlink shim: ${target}-gcc.bat → intercepts -print-file-name=crt2.o → '${_crt2_win}', otherwise zig cc -target ${_zig_target_triple}"
    fi

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
    CONDA_ENVS_DIR=$(conda info --json 2>/dev/null | python -c "import sys,json; print(json.load(sys.stdin)['envs_dirs'][0])")
    TARGET_ZSTD_LIB="${CONDA_ENVS_DIR}/${TARGET_ZSTD_ENV}/lib"
    TARGET_ZSTD_LIBS="-L${TARGET_ZSTD_LIB} -lzstd"
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
    export TARGET_BINDIR="${OCAML_CROSS_PREFIX}/bin"
    export TARGET_LIBDIR="${OCAML_CROSS_LIBDIR}"

    # Per-target configure args (frame pointers not supported on PPC or Windows)
    declare -a TARGET_CONFIG_ARGS=()
    if is_unix; then
      case "${CROSS_ARCH}" in
        arm64|amd64)
          TARGET_CONFIG_ARGS+=(--enable-frame-pointers)
          ;;
      esac
    fi

    run_logged "cross-configure" ${CONFIGURE[@]} \
      -prefix="${OCAML_CROSS_PREFIX}" \
      --mandir="${OCAML_CROSS_PREFIX}"/share/man \
      --host="${build_alias:-${CONDA_TOOLCHAIN_BUILD}}" \
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
      ${CROSS_MODEL:+MODEL=${CROSS_MODEL}} \
    || { echo "  === config.log ==="; cat config.log; exit 1; }

    # CRITICAL: Unset CC/CFLAGS/LDFLAGS after configure completes
    # OCaml 5.4.0 configure requires these as env vars, but leaving them set
    # can cause crossopt to pick up NATIVE values from environment instead of
    # the CROSS values passed as make arguments. This leads to arch inconsistencies
    # between stdlib and otherlibs (unix), causing "inconsistent assumptions" errors.
    unset CC CFLAGS LDFLAGS

    # ========================================================================
    # Fix clang/zig __builtin_setjmp SEH conflict on Windows (OCaml#XXXX)
    # ========================================================================
    # OCaml configure sets HAS_BUILTIN_SETJMP based on __builtin_setjmp presence.
    # clang defines __GNUC__ so it takes the __builtin_setjmp path, but on
    # Windows, clang/LLVM generates SEH unwind tables. __builtin_longjmp
    # traversing these tables corrupts the SEH chain → bytecode interpreter crash.
    #
    # caml_jmp_buf is void*[5] (40 bytes) when HAS_BUILTIN_SETJMP is set.
    # Windows jmp_buf is 128 bytes (MSVC) or 64 bytes (MinGW) — simple cast
    # would cause stack corruption. Must disable at the typedef level so OCaml
    # uses the full platform-sized jmp_buf and standard setjmp/longjmp.
    if ! is_unix; then
      _config_h="runtime/caml/config.h"
      echo "  DEBUG-SETJMP: NATIVE_CC=${NATIVE_CC}"
      echo "  DEBUG-SETJMP: config.h exists: $([[ -f ${_config_h} ]] && echo YES || echo NO)"
      echo "  DEBUG-SETJMP: pwd=$(pwd)"
      if [[ -f "${_config_h}" ]]; then
        echo "  DEBUG-SETJMP: HAS_BUILTIN_SETJMP line: $(grep 'HAS_BUILTIN_SETJMP' ${_config_h} || echo '<not found>')"
      fi
      if [[ "${NATIVE_CC}" == *zig* || "${NATIVE_CC}" == *clang* ]]; then
        if [[ -f "${_config_h}" ]] && grep -q 'define HAS_BUILTIN_SETJMP' "${_config_h}"; then
          echo "  Patching ${_config_h}: disabling HAS_BUILTIN_SETJMP (clang SEH conflict)"
          sed -i 's/#define HAS_BUILTIN_SETJMP/\/* disabled: clang\/zig __builtin_longjmp corrupts SEH chain on Windows *\//' \
            "${_config_h}"
        else
          echo "  DEBUG-SETJMP: HAS_BUILTIN_SETJMP not found or already absent — no patch needed"
        fi
      fi
    fi

    # DEBUG: show SAK_BUILD and subsystem flags (remove after fixing WinMain issue)
    echo "  DEBUG: NATIVE_LDFLAGS=${NATIVE_LDFLAGS}"
    echo "  DEBUG: LDFLAGS_FOR_BUILD=${LDFLAGS_FOR_BUILD:-<unset>}"
    if [[ -f Makefile.build_config ]]; then
      echo "  DEBUG: SAK_BUILD from Makefile.build_config:"
      grep '^SAK_BUILD=' Makefile.build_config || echo "  DEBUG: SAK_BUILD not found"
      echo "  DEBUG: SAK= from Makefile.build_config:"
      grep '^SAK=' Makefile.build_config || echo "  DEBUG: SAK not found"
    fi
    if [[ -f Makefile.config ]]; then
      echo "  DEBUG: MKEXE from Makefile.config:"
      grep '^MKEXE=' Makefile.config || true
      echo "  DEBUG: OUTPUTEXE from Makefile.config:"
      grep '^OUTPUTEXE=' Makefile.config || true
    fi
    echo "  DEBUG: GCC default subsystem:"
    "${NATIVE_CC}" -dumpspecs 2>/dev/null | grep -A2 'mconsole\|mwindows\|subsystem' || echo "  DEBUG: no specs found"

    # ========================================================================
    # Patch Makefile for OCaml 5.4.0 bug: CHECKSTACK_CC undefined
    # ========================================================================
    patch_checkstack_cc

    # ========================================================================
    # Fix zig-feedstock synchronization.def LIBRARY name
    # ========================================================================
    # Zig _19 adds synchronization.def with "LIBRARY synchronization.dll" but
    # synchronization.dll doesn't exist — the real DLL is an API set:
    # api-ms-win-core-synch-l1-2-0.dll (resolved by Windows API Set Schema).
    # Binaries linked against the wrong name crash at runtime (exit 127).
    # Patch the .def to use the correct API set DLL name.
    # TODO: Remove once zig-feedstock ships the corrected .def.
    if ! is_unix; then
      _sync_def=$(find "${BUILD_PREFIX}" -name "synchronization.def" 2>/dev/null | head -1)
      if [[ -n "${_sync_def}" ]]; then
        if grep -q 'LIBRARY synchronization' "${_sync_def}"; then
          echo "  Patching ${_sync_def}: LIBRARY synchronization.dll → api-ms-win-core-synch-l1-2-0.dll"
          sed -i 's/LIBRARY synchronization.*/LIBRARY api-ms-win-core-synch-l1-2-0.dll/' "${_sync_def}"
        fi
      fi
    fi

    # ========================================================================
    # Strip GCC-specific linker flags from BYTECCLIBS (zig is not GCC)
    # ========================================================================
    # OCaml's configure detects MinGW and adds GCC-specific libraries:
    #   -l:libpthread.a  — colon syntax (exact filename search) is a GNU ld
    #                       extension that triggers zig's "reached unreachable code"
    #   -lgcc_eh          — GCC exception handling; zig doesn't ship this
    # Zig provides its own threading (Windows native threads) and unwinding,
    # so these are both unnecessary and crash-inducing.
    if ! is_unix && [[ -f Makefile.config ]]; then
      if grep -qE '\-l:libpthread\.a|\-lgcc_eh' Makefile.config; then
        echo "  Patching Makefile.config: replacing GCC-specific -l:libpthread.a with -lpthread, removing -lgcc_eh"
        sed -i 's/ -l:libpthread\.a/ -lpthread/g; s/ -lgcc_eh//g' Makefile.config
      fi
      # Save BYTECCLIBS before arm64-specific injections so step [4/7] can use
      # the native-only value for ocamlruns.exe (MKEXE_VIA_CC = direct CC).
      # The full BYTECCLIBS (with arm64 -L paths) is needed by ocamlrun.exe
      # (MKEXE = flexlink -chain mingw64arm) but the arm64 libs conflict with
      # the native x86_64 link used for ocamlruns.exe.
      _native_bytecclibs=$(sed -n 's/^BYTECCLIBS=//p' Makefile.config)
      echo "  Saved native BYTECCLIBS (pre arm64 injection): ${_native_bytecclibs}"

      # zig _21+ provides ARM64 import libs in lib/zig/libc/mingw/lib-common/:
      #   libkernel32.a, libws2_32.a, libole32.a, libadvapi32.a, libuser32.a,
      #   libshell32.a, libmsvcrt.a, libucrtbase.a, libuuid.a, crt2.o, dllcrt2.o
      # Also provides stubs: _fpreset_arm64.o (auto-injected), ___chkstk_ms.o,
      #   __intrinsic_setjmpex.o.
      # We only need to generate OCaml-specific libs not provided by zig.
      _zig_exe="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-zig.exe"
      _zig_mingw="${BUILD_PREFIX}/Library/lib/zig/libc/mingw"

      # zig _21+ installs ARM64 import libs (ws2_32, ole32, uuid, kernel32, etc.)
      # and stubs (_fpreset_arm64.o, ___chkstk_ms.o) in a fixed location under BUILD_PREFIX.
      # Use the known install path directly - -print-file-name is unreliable on Windows
      # (returns the literal name when the target lib search path isn't in the native search).
      _zig_arm64_lib_dir="${_zig_mingw}/lib-common"
      _zig_arm64_lib_dir_s=""
      if [[ -d "${_zig_arm64_lib_dir}" && -f "${_zig_arm64_lib_dir}/libkernel32.a" ]]; then
        _zig_arm64_lib_dir_s=$(cygpath -ms "${_zig_arm64_lib_dir}" 2>/dev/null || \
                               cygpath -m  "${_zig_arm64_lib_dir}" 2>/dev/null || \
                               echo "${_zig_arm64_lib_dir}")
        echo "  zig lib-common dir: ${_zig_arm64_lib_dir_s}"
      else
        echo "  WARNING: zig arm64 lib-common not found at ${_zig_arm64_lib_dir}; flexlink may fail to resolve imports"
        _zig_arm64_lib_dir=""
      fi

      # OCaml-specific libs not provided by zig — generate into a separate dir
      _arm64_lib_dir="${BUILD_PREFIX}/Library/lib/ocaml-arm64-imports"
      mkdir -p "${_arm64_lib_dir}"

      # libcrt_helpers.a — stubs for symbols zig enables in flexdll_mingw64arm.obj
      # but does NOT expose as flexlink-resolvable archive entries:
      #   __stack_chk_*  — stack protector (zig injects these into flexdll objects)
      #   __ubsan_*      — UBSan handlers (zig _21 compiles flexdll with UBSan;
      #                    BRANCH26 relocations → flexlink "Unsupported relocation kind 0003"
      #                    unless a LOCAL definition is provided in an archive)
      # Note: _fpreset / __chkstk / __intrinsic_setjmpex are now provided by zig _21
      # via auto-injection and lib-common — no longer needed here.
      _crt_helpers="${_arm64_lib_dir}/libcrt_helpers.a"
      cat > "${_arm64_lib_dir}/_crt_helpers.c" << 'CRTHELPERS'
__attribute__((weak)) unsigned long __stack_chk_guard = 0;
__attribute__((weak)) void __stack_chk_fail(void) { while(1); }
typedef struct { const char *f; unsigned l, c; } SourceLocation;
typedef struct { SourceLocation l; const void *t; unsigned a; unsigned char p; } TypeMismatchData;
typedef struct { SourceLocation l; const void *t; } OverflowData;
typedef struct { SourceLocation l; } UnreachableData;
typedef struct { SourceLocation l; } NonnullArgData;
typedef struct { SourceLocation l; const void *t; } PointerOverflowData;
__attribute__((weak)) void __ubsan_handle_type_mismatch_v1(TypeMismatchData *d, unsigned long p) { (void)d; (void)p; }
__attribute__((weak)) void __ubsan_handle_add_overflow(OverflowData *d, unsigned long l, unsigned long r) { (void)d; (void)l; (void)r; }
__attribute__((weak)) void __ubsan_handle_sub_overflow(OverflowData *d, unsigned long l, unsigned long r) { (void)d; (void)l; (void)r; }
__attribute__((weak)) void __ubsan_handle_divrem_overflow(OverflowData *d, unsigned long l, unsigned long r) { (void)d; (void)l; (void)r; }
__attribute__((weak)) void __ubsan_handle_pointer_overflow(PointerOverflowData *d, unsigned long b, unsigned long r) { (void)d; (void)b; (void)r; }
__attribute__((weak)) void __ubsan_handle_nonnull_arg(NonnullArgData *d) { (void)d; }
__attribute__((weak)) void __ubsan_handle_builtin_unreachable(UnreachableData *d) { (void)d; while(1); }
/* _tls_index: needed because flexlink links .obj files directly without CRT
   startup objects (crt2.o), so the TLS index variable is otherwise undefined. */
int _tls_index = 0;
/* __chkstk / ___chkstk_ms / _chkstk: stack probe intrinsic.
   zig _21+ provides this via lib-common; zig 0.15.2 does not. */
__attribute__((weak)) void __chkstk(void) { }
__attribute__((weak)) void ___chkstk_ms(void) { }
__attribute__((weak)) void _chkstk(void) { }
CRTHELPERS
      # Fix 2026-04-26d: libcrt_helpers.a was being built as x86_64 COFF; must use
      # -target aarch64-windows-gnu for arm64 cross-build (build 1511828 nm reported
      # "file format not recognized" because the object was x86_64, not aarch64 COFF).
      # Fix 2026-04-26e: deep format diagnostics for libcrt_helpers.o and lib-common archives - blocker A persists despite fix-26d, need to identify zig cc output format vs flexlink expectations
      "${_zig_exe}" cc -target aarch64-windows-gnu -c \
        "${_arm64_lib_dir}/_crt_helpers.c" \
        -o "${_arm64_lib_dir}/_crt_helpers.o" 2>&1 \
        || { echo "FAILED step 1: zig cc _crt_helpers.c" >&2; }
      "${_zig_exe}" ar rcs "${_crt_helpers}" \
        "${_arm64_lib_dir}/_crt_helpers.o" 2>&1 \
        || { echo "FAILED step 2: zig ar libcrt_helpers.a" >&2; }
      echo "  Created libcrt_helpers.a (stack_chk + ubsan + chkstk stubs for flexdll)"
      echo "--- magic bytes (od) _crt_helpers.o ---"
      od -A x -t x1z -N 8 "${_arm64_lib_dir}/_crt_helpers.o" 2>&1 || true
      echo "--- zig ar t libcrt_helpers.a ---"
      "${_zig_exe}" ar t "${_arm64_lib_dir}/libcrt_helpers.a" 2>&1 | head -30 || true
      rm -f "${_arm64_lib_dir}/_crt_helpers.c" "${_arm64_lib_dir}/_crt_helpers.o"

      # winpthread — OCaml runtime uses pthread_mutex/cond/condattr functions.
      # The GCC-specific -l:libpthread.a was replaced with -lpthread.
      # Build from zig's winpthread sources; if not found, create import stub.
      _pthread_lib="${_arm64_lib_dir}/libpthread.a"
      if [[ ! -f "${_pthread_lib}" ]]; then
        _wp_src="${_zig_mingw}/libsrc"
        _wp_objs=()
        for _wp_c in "${_wp_src}"/winpthread/*.c; do
          [[ -f "${_wp_c}" ]] || continue
          _wp_obj="${_arm64_lib_dir}/$(basename "${_wp_c%.c}").o"
          "${_zig_exe}" cc -target aarch64-windows-gnu -c "${_wp_c}" \
            -I"${_zig_mingw}/include" -o "${_wp_obj}" 2>/dev/null && \
            _wp_objs+=("${_wp_obj}") || true
        done
        if [[ ${#_wp_objs[@]} -gt 0 ]]; then
          "${_zig_exe}" ar rcs "${_pthread_lib}" "${_wp_objs[@]}" 2>/dev/null && \
            echo "  Created libpthread.a (${#_wp_objs[@]} objects)" || \
            echo "  WARNING: libpthread.a creation failed"
          rm -f "${_wp_objs[@]}"
        else
          echo "  No winpthread sources, creating comprehensive stub libpthread.a"
          cat > "${_arm64_lib_dir}/pthread.def" << 'PTHREADDEF'
LIBRARY "libwinpthread-1.dll"
EXPORTS
  pthread_cancel
  pthread_detach
  pthread_equal
  pthread_exit
  pthread_mutex_init
  pthread_mutex_lock
  pthread_mutex_unlock
  pthread_mutex_destroy
  pthread_mutex_trylock
  pthread_mutexattr_init
  pthread_mutexattr_destroy
  pthread_mutexattr_settype
  pthread_cond_init
  pthread_cond_destroy
  pthread_cond_signal
  pthread_cond_broadcast
  pthread_cond_wait
  pthread_cond_timedwait
  pthread_condattr_init
  pthread_condattr_destroy
  pthread_condattr_setclock
  pthread_create
  pthread_join
  pthread_self
  pthread_key_create
  pthread_key_delete
  pthread_getspecific
  pthread_setspecific
PTHREADDEF
          "${_zig_exe}" dlltool -m arm64 -D "libwinpthread-1.dll" \
            -d "${_arm64_lib_dir}/pthread.def" -l "${_pthread_lib}" 2>/dev/null && \
            echo "  Created libpthread.a (import stub)" || true
        fi
      fi

      # version.dll — OCaml win32.c uses version info APIs (not in zig lib-common)
      _version_lib="${_arm64_lib_dir}/libversion.a"
      if [[ ! -f "${_version_lib}" ]]; then
        cat > "${_arm64_lib_dir}/version.def" << 'VERSIONDEF'
LIBRARY "version.dll"
EXPORTS
  GetFileVersionInfoSizeW
  GetFileVersionInfoW
  VerQueryValueW
VERSIONDEF
        "${_zig_exe}" dlltool -m arm64 -D "version.dll" \
          -d "${_arm64_lib_dir}/version.def" -l "${_version_lib}" 2>/dev/null && \
          echo "  Created libversion.a" || true
      fi

      # api-ms-win-core-synch-l1-2-0.dll — OCaml platform.c WaitOnAddress (not in zig lib-common)
      _sync_lib="${_arm64_lib_dir}/libsynchronization.a"
      if [[ ! -f "${_sync_lib}" ]]; then
        cat > "${_arm64_lib_dir}/synchronization.def" << 'SYNCDEF'
LIBRARY "api-ms-win-core-synch-l1-2-0.dll"
EXPORTS
  WaitOnAddress
  WakeByAddressAll
  WakeByAddressSingle
SYNCDEF
        "${_zig_exe}" dlltool -m arm64 -D "api-ms-win-core-synch-l1-2-0.dll" \
          -d "${_arm64_lib_dir}/synchronization.def" -l "${_sync_lib}" 2>/dev/null && \
          echo "  Created libsynchronization.a" || true
      fi

      # shlwapi.dll — OCaml/flexdll path utilities (not in zig lib-common)
      _shlwapi_lib="${_arm64_lib_dir}/libshlwapi.a"
      if [[ ! -f "${_shlwapi_lib}" ]]; then
        cat > "${_arm64_lib_dir}/shlwapi.def" << 'SHLWAPIDEF'
LIBRARY "shlwapi.dll"
EXPORTS
  PathIsPrefixW
  PathCombineW
SHLWAPIDEF
        "${_zig_exe}" dlltool -m arm64 -D "shlwapi.dll" \
          -d "${_arm64_lib_dir}/shlwapi.def" -l "${_shlwapi_lib}" 2>/dev/null && \
          echo "  Created libshlwapi.a" || true
      fi

      # msvcrt.dll - CRT (legacy) ARM64 import stub for zig 0.15.2 (lib-common is x86-64)
      _msvcrt_lib="${_arm64_lib_dir}/libmsvcrt.a"
      cat > "${_arm64_lib_dir}/msvcrt.def" << 'MSVCRTDEF'
LIBRARY "msvcrt.dll"
EXPORTS
fprintf
printf
sprintf
snprintf
vfprintf
vprintf
vsprintf
vsnprintf
fflush
fopen
fclose
fread
fwrite
fseek
ftell
feof
ferror
rewind
fgetc
fputs
fgets
puts
malloc
free
realloc
calloc
memcpy
memmove
memset
memcmp
strlen
strcpy
strcat
strcmp
strncmp
strncpy
exit
abort
_exit
atexit
signal
swscanf
longjmp
setjmp
MSVCRTDEF
      "${_zig_exe}" dlltool -m arm64 -D "msvcrt.dll" \
        -d "${_arm64_lib_dir}/msvcrt.def" -l "${_msvcrt_lib}" 2>&1 || true
      [[ -f "${_msvcrt_lib}" ]] && echo "  Created libmsvcrt.a (ARM64 import stub)" || echo "  WARNING: libmsvcrt.a NOT created"

      # ucrtbase.dll - modern CRT (ARM64 routes printf/fprintf here, not msvcrt)
      _ucrtbase_lib="${_arm64_lib_dir}/libucrtbase.a"
      cat > "${_arm64_lib_dir}/ucrtbase.def" << 'UCRTBASEDEF'
LIBRARY "ucrtbase.dll"
EXPORTS
fprintf
printf
sprintf
snprintf
vfprintf
vprintf
vsprintf
vsnprintf
fflush
fopen
fclose
fread
fwrite
fseek
ftell
feof
ferror
rewind
fgetc
fputs
fgets
puts
malloc
free
realloc
calloc
memcpy
memmove
memset
memcmp
strlen
strcpy
strcat
strcmp
strncmp
strncpy
exit
abort
_exit
atexit
signal
swscanf
longjmp
setjmp
UCRTBASEDEF
      "${_zig_exe}" dlltool -m arm64 -D "ucrtbase.dll" \
        -d "${_arm64_lib_dir}/ucrtbase.def" -l "${_ucrtbase_lib}" 2>&1 || true
      [[ -f "${_ucrtbase_lib}" ]] && echo "  Created libucrtbase.a (ARM64 import stub)" || echo "  WARNING: libucrtbase.a NOT created"

      # ws2_32.dll - Winsock ARM64 import stub
      _ws2_lib="${_arm64_lib_dir}/libws2_32.a"
      cat > "${_arm64_lib_dir}/ws2_32.def" << 'WS2DEF'
LIBRARY "ws2_32.dll"
EXPORTS
WSAStartup
WSACleanup
WSAGetLastError
WSASetLastError
WSASocketW
socket
bind
connect
listen
accept
send
recv
sendto
recvfrom
closesocket
shutdown
gethostbyname
gethostname
getpeername
getsockname
setsockopt
getsockopt
select
ioctlsocket
htons
htonl
ntohs
ntohl
inet_addr
inet_ntoa
freeaddrinfo
getaddrinfo
WS2DEF
      "${_zig_exe}" dlltool -m arm64 -D "ws2_32.dll" \
        -d "${_arm64_lib_dir}/ws2_32.def" -l "${_ws2_lib}" 2>&1 || true
      [[ -f "${_ws2_lib}" ]] && echo "  Created libws2_32.a (ARM64 import stub)" || echo "  WARNING: libws2_32.a NOT created"

      echo "  OCaml-specific arm64 libs generated:"
      ls "${_arm64_lib_dir}/"*.a 2>/dev/null | xargs -n1 basename | sort || echo "  (none)"

      # Add both zig's lib-common (standard Windows libs) and OCaml-specific dir to BYTECCLIBS
      _arm64_lib_dir_win=$(cygpath -ms "${_arm64_lib_dir}" 2>/dev/null || \
                           cygpath -m "${_arm64_lib_dir}" 2>/dev/null || \
                           echo "${_arm64_lib_dir}")
      if [[ -n "${_zig_arm64_lib_dir_s}" ]]; then
        sed -i "s|^BYTECCLIBS=\(.*\)|BYTECCLIBS=-L${_arm64_lib_dir_win} -L${_zig_arm64_lib_dir_s} -lcrt_helpers -lmsvcrt -lws2_32 -lucrtbase -luser32 -lkernel32 -ladvapi32 -lshell32 \1|" Makefile.config
        echo "  BYTECCLIBS updated: zig lib-common + OCaml-specific arm64 dirs + crt_helpers + ucrtbase + win32 import libs"
      else
        sed -i "s|^BYTECCLIBS=\(.*\)|BYTECCLIBS=-L${_arm64_lib_dir_win} -lcrt_helpers -lmsvcrt -lws2_32 -lucrtbase -luser32 -lkernel32 -ladvapi32 -lshell32 \1|" Makefile.config
        echo "  BYTECCLIBS updated: OCaml-specific arm64 dir only + crt_helpers + ucrtbase + win32 import libs"
      fi
    fi

    # Fix sak.exe WinMain: zig cc -target windows-gnu may default to GUI subsystem.
    # Strategy 1: probe for a console subsystem linker flag (for correct PE header).
    # Strategy 2: always add WinMain stub delegating to main() as ultimate fallback.
    # This is belt-and-suspenders: Strategy 2 guarantees correctness even if no flag works.
    if ! is_unix; then
      # --- Strategy 1: probe for working console subsystem flag ---
      # Compile a minimal probe binary with each candidate flag, then inspect the
      # PE Optional Header subsystem field (offset pe+92, value 3 = console).
      _sak_probe_ran=false
      _sak_found_flag=""
      if [[ -n "${NATIVE_CC}" ]] && [[ -f runtime/sak.c ]]; then
        _sak_probe_ran=true
        _probe_dir=$(mktemp -d "/tmp/sak_probe_XXXXXX")
        printf 'int main(void) { return 0; }\n' > "${_probe_dir}/probe.c"
        _probe_py='
import struct, sys
try:
    data = open(sys.argv[1], "rb").read(512)
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    sub = struct.unpack_from("<H", data, pe + 92)[0]
    sys.exit(0 if sub == 3 else 1)
except Exception:
    sys.exit(1)
'
        for _flag in "" "-mconsole" "-Xlinker /subsystem:console" \
                        "-Wl,/subsystem:console" "-Wl,--subsystem,console"; do
          _probe_exe="${_probe_dir}/probe_${RANDOM}.exe"
          # eval to allow word-splitting of empty/spaced flags
          if eval "${NATIVE_CC} ${_flag} -o '${_probe_exe}' '${_probe_dir}/probe.c'" 2>/dev/null \
              && python3 -c "${_probe_py}" "${_probe_exe}" 2>/dev/null; then
            _sak_found_flag="${_flag}"
            echo "  SAK console probe: '${_flag:-<default>}' → PE subsystem=console (3) ✓"
            break
          else
            echo "  SAK console probe: '${_flag:-<default>}' → compile failed or GUI subsystem"
          fi
          rm -f "${_probe_exe}"
        done
        rm -rf "${_probe_dir}"
        if [[ -z "${_sak_found_flag}" ]]; then
          echo "  SAK console probe: all flags failed, relying on WinMain stub only"
        fi
      fi
      # Export so Makefile.cross SAK_SUBSYSTEM_FLAG ?= picks it up.
      # Only export if probe ran — otherwise let Makefile.cross use its ?= default.
      if ${_sak_probe_ran}; then
        export SAK_SUBSYSTEM_FLAG="${_sak_found_flag}"
        echo "  SAK_SUBSYSTEM_FLAG exported as: '${SAK_SUBSYSTEM_FLAG:-<empty, WinMain stub only>}'"
      fi

      # --- Strategy 2: WinMain stub as ultimate fallback ---
      # Appended to sak.c so it compiles on all Windows builds.
      # When console subsystem is correctly set, WinMain is present but never called.
      # When GUI subsystem sneaks in, WinMain delegates to main().
      # CRITICAL: Only use KERNEL32.DLL APIs — CommandLineToArgvW requires SHELL32.DLL
      # which may not be loadable in MSYS2 environments, causing sak.exe to fail with
      # exit code 127 (PE loader can't satisfy DLL imports before main() even starts).
      if [[ -f runtime/sak.c ]]; then
        cat >> runtime/sak.c <<'SAK_WINMAIN_STUB'

/* sak.exe WinMain fallback for zig cc -target windows-gnu GUI subsystem default.
   Uses only KERNEL32.DLL APIs — SHELL32.DLL (CommandLineToArgvW) is NOT available
   in all environments (e.g., MSYS2 on CI) and its mere import causes PE loader
   failure (exit 127) even when WinMain is never called (console subsystem). */
#ifdef _WIN32

/* When SAK_NEEDS_MAIN_WRAPPER is set (MSVC target), sak.c defines wmain (via
   caml/misc.h main_os macro) not main. Provide a main→wmain shim that
   uses GetCommandLineW (KERNEL32) to get wide args — __argc/__wargv globals
   are not reliably populated by zig's CRT startup. */
#ifdef SAK_NEEDS_MAIN_WRAPPER
#include <wchar.h>
int wmain(int argc, wchar_t **argv);
wchar_t * __stdcall GetCommandLineW(void);
int __stdcall MultiByteToWideChar(unsigned cp, unsigned long flags,
    const char *mb, int mblen, wchar_t *wc, int wclen);
int main(int argc, char **argv) {
  /* Convert narrow argv to wide argv using MultiByteToWideChar (KERNEL32).
     sak.exe needs at most 3 args: program, command, path. */
  wchar_t *wargv_buf[5] = {0};
  wchar_t wbuf[4][1024];
  int i, wc = (argc > 4) ? 4 : argc;
  for (i = 0; i < wc; i++) {
    int n = MultiByteToWideChar(65001/*CP_UTF8*/, 0, argv[i], -1, wbuf[i], 1024);
    if (n <= 0) n = MultiByteToWideChar(0/*CP_ACP*/, 0, argv[i], -1, wbuf[i], 1024);
    wargv_buf[i] = wbuf[i];
  }
  return wmain(wc, wargv_buf);
}
#else
int main(int argc, char **argv);
#endif

/* KERNEL32-only API declarations */
char * __stdcall GetCommandLineA(void);
void * __stdcall LocalAlloc(unsigned uFlags, unsigned long sz);
int WinMain(void *h0, void *h1, char *c, int n) {
  /* Simple command-line parsing using GetCommandLineA (KERNEL32 only).
     sak.exe only needs 2 args: command-name and a path string.
     For robustness, parse the first 3 tokens from the command line. */
  char *cmd = GetCommandLineA();
  if (!cmd || !*cmd) return main(0, (char*[]){(char*)"sak", 0});
  /* Skip argv[0] (may be quoted) */
  char *p = cmd;
  if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; }
  else { while (*p && *p != ' ' && *p != '\t') p++; }
  while (*p == ' ' || *p == '\t') p++;
  /* Collect up to 3 remaining args (sak needs at most: command path) */
  char *args[5] = {(char*)"sak", 0, 0, 0, 0};
  int argc2 = 1;
  while (*p && argc2 < 4) {
    if (*p == '\'') { p++; args[argc2++] = p; while (*p && *p != '\'') p++; if (*p) *p++ = 0; }
    else if (*p == '"') { p++; args[argc2++] = p; while (*p && *p != '"') p++; if (*p) *p++ = 0; }
    else { args[argc2++] = p; while (*p && *p != ' ' && *p != '\t') p++; if (*p) *p++ = 0; }
    while (*p == ' ' || *p == '\t') p++;
  }
  return main(argc2, args);
}
#endif
SAK_WINMAIN_STUB
        echo "  Appended WinMain stub to runtime/sak.c"
      fi
    fi

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
    FINAL_STDLIB_PATH="${PREFIX}/lib/ocaml-cross-compilers/${target}/lib/ocaml"
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

    # SAK_BUILD override is handled via append to Makefile.build_config (above).
    # Do NOT pass SAK_BUILD on the make command line — it would clobber the file-level
    # override that includes -Wl,--subsystem,console.

    # Ensure boot/ has native OCaml tools — flexdll build needs them for flexlink.exe.
    # Ensure boot/ has ocamlrun + ocamlc — flexdll build needs them to compile flexlink.exe.
    # For cross-compilation, use the installed native OCaml from BUILD_PREFIX.
    mkdir -p boot
    if [[ ! -f boot/ocamlrun.exe ]]; then
      local _ocaml_bin="${BUILD_PREFIX}/Library/bin"
      [[ -f "${_ocaml_bin}/ocamlrun.exe" ]] || _ocaml_bin="${BUILD_PREFIX}/bin"
      for _tool in ocamlrun ocamlc ocamllex; do
        if [[ -f "${_ocaml_bin}/${_tool}.exe" ]]; then
          cp "${_ocaml_bin}/${_tool}.exe" "boot/${_tool}.exe"
        elif [[ -f "${_ocaml_bin}/${_tool}" ]]; then
          cp "${_ocaml_bin}/${_tool}" "boot/${_tool}.exe"
        fi
      done
      # flexdll build uses boot/ocamlc with '-nostdlib -I ../stdlib' (relative to flexdll/).
      # '../stdlib' = source tree stdlib/ which is empty before build. Copy .cmi files from
      # the installed native OCaml so flexlink.exe can compile.
      local _ocaml_lib="${BUILD_PREFIX}/lib/ocaml"
      [[ -d "${_ocaml_lib}" ]] || _ocaml_lib="${BUILD_PREFIX}/Library/lib/ocaml"
      if [[ -d "${_ocaml_lib}" ]]; then
        mkdir -p stdlib
        cp "${_ocaml_lib}"/*.cmi stdlib/ 2>/dev/null || true
        cp "${_ocaml_lib}"/stdlib.cma stdlib/ 2>/dev/null || true
        cp "${_ocaml_lib}"/std_exit.cmo stdlib/ 2>/dev/null || true
        # boot/ocamlc needs runtime-launch-info to link bytecode executables (flexlink.exe)
        cp "${_ocaml_lib}"/runtime-launch-info stdlib/ 2>/dev/null || true
        echo "  Copied stdlib .cmi files and runtime-launch-info from ${_ocaml_lib}"
      fi
      echo "  Copied native boot tools from ${_ocaml_bin}"
    fi

    # ========================================================================
    # DEBUG: Diagnose sak.exe + OCAML_STDLIB_DIR chain BEFORE make runs
    # The Makefile generates build_config.h via:
    #   C_LITERAL = $(shell $(SAK) $(ENCODE_C_LITERAL) '$(1)')
    #   #define OCAML_STDLIB_DIR $(call C_LITERAL,$(TARGET_LIBDIR))
    # If sak.exe fails silently, $(shell ...) returns empty → build fails with
    #   "expected expression" at runtime/dynlink.c:91
    # ========================================================================
    echo "  DEBUG-STDLIB-DIR: === sak.exe + OCAML_STDLIB_DIR diagnostic ==="
    if [[ -f Makefile.build_config ]]; then
      echo "  DEBUG-STDLIB-DIR: TARGET_LIBDIR from Makefile.build_config:"
      grep '^TARGET_LIBDIR=' Makefile.build_config || echo "  DEBUG-STDLIB-DIR: TARGET_LIBDIR NOT FOUND in Makefile.build_config!"
      echo "  DEBUG-STDLIB-DIR: ENCODE_C_LITERAL from Makefile.build_config:"
      grep '^ENCODE_C_LITERAL=' Makefile.build_config || echo "  DEBUG-STDLIB-DIR: ENCODE_C_LITERAL NOT FOUND!"
      echo "  DEBUG-STDLIB-DIR: SAK_BUILD from Makefile.build_config:"
      grep '^SAK_BUILD=' Makefile.build_config || echo "  DEBUG-STDLIB-DIR: SAK_BUILD NOT FOUND!"
      echo "  DEBUG-STDLIB-DIR: CC_FOR_BUILD from Makefile.build_config:"
      grep '^CC_FOR_BUILD=' Makefile.build_config || echo "  DEBUG-STDLIB-DIR: CC_FOR_BUILD NOT FOUND!"
    else
      echo "  DEBUG-STDLIB-DIR: Makefile.build_config DOES NOT EXIST!"
    fi

    # Pre-build sak.exe manually and test it produces valid C_LITERAL output
    local _sak_cc="${SAK_CC_MSVC:-${NATIVE_CC}}"
    echo "  DEBUG-STDLIB-DIR: Pre-building sak.exe with SAK_CC: ${_sak_cc}"
    local _sak_src="runtime/sak.c"
    local _sak_exe="runtime/sak.exe"
    if [[ -f "${_sak_src}" ]]; then
      # Build sak.exe with SAK compiler (msvc target on Windows for MSYS2 compat)
      local _sak_build_cmd="${_sak_cc} ${SAK_SUBSYSTEM_FLAG:-} -o ${_sak_exe} ${_sak_src}"
      echo "  DEBUG-STDLIB-DIR: sak build cmd: ${_sak_build_cmd}"
      if eval "${_sak_build_cmd}" 2>&1; then
        echo "  DEBUG-STDLIB-DIR: sak.exe built successfully"
        # Check binary: file type, size, PE architecture
        echo "  DEBUG-STDLIB-DIR: sak.exe size: $(wc -c < "${_sak_exe}") bytes"
        file "${_sak_exe}" 2>/dev/null | sed 's/^/  DEBUG-STDLIB-DIR: file: /' || true
        # Check PE subsystem (3=console, 2=GUI) and DLL imports
        python3 -c "
import struct, sys
try:
    data = open(sys.argv[1], 'rb').read()
    pe = struct.unpack_from('<I', data, 0x3C)[0]
    machine = struct.unpack_from('<H', data, pe + 4)[0]
    sub = struct.unpack_from('<H', data, pe + 92)[0]
    machines = {0x14c: 'x86', 0x8664: 'x86_64', 0xAA64: 'aarch64'}
    subs = {2: 'GUI', 3: 'CONSOLE'}
    print(f'  DEBUG-STDLIB-DIR: PE machine={machines.get(machine, hex(machine))} subsystem={subs.get(sub, sub)}')
    # Extract DLL imports from PE import table
    num_sections = struct.unpack_from('<H', data, pe + 6)[0]
    opt_size = struct.unpack_from('<H', data, pe + 20)[0]
    sections_offset = pe + 24 + opt_size
    # Import table RVA is at PE optional header offset 104 (PE32+) or 96 (PE32)
    import_rva = struct.unpack_from('<I', data, pe + 24 + 120)[0] if machine == 0x8664 else struct.unpack_from('<I', data, pe + 24 + 104)[0]
    if import_rva:
        # Find section containing import RVA
        for i in range(num_sections):
            s = sections_offset + i * 40
            vaddr = struct.unpack_from('<I', data, s + 12)[0]
            vsize = struct.unpack_from('<I', data, s + 8)[0]
            raw = struct.unpack_from('<I', data, s + 20)[0]
            if vaddr <= import_rva < vaddr + vsize:
                dlls = []
                off = raw + (import_rva - vaddr)
                while True:
                    name_rva = struct.unpack_from('<I', data, off + 12)[0]
                    if name_rva == 0: break
                    name_off = raw + (name_rva - vaddr)
                    end = data.index(0, name_off)
                    dlls.append(data[name_off:end].decode('ascii', errors='replace'))
                    off += 20
                print(f'  DEBUG-STDLIB-DIR: DLL imports: {\" \".join(dlls)}')
                break
except Exception as e:
    print(f'  DEBUG-STDLIB-DIR: PE parse error: {e}')
" "${_sak_exe}" 2>&1 || true
        # Check DLL deps via objdump if available
        objdump -p "${_sak_exe}" 2>/dev/null | grep "DLL Name" | sed 's/^/  DEBUG-STDLIB-DIR: /' || true

        # ================================================================
        # Probe all approaches to make zig-compiled binaries run in MSYS2
        # Problem: zig cc -target x86_64-windows-gnu links api-ms-win-crt-*.dll
        # which MSYS2 bash can't find (not in DLL search path)
        # ================================================================
        echo "  DEBUG-STDLIB-DIR: === ZIG RUNTIME PROBE ==="
        local _probe_src="/tmp/zig_probe.c"
        printf '#include <stdio.h>\nint main(void) { printf("OK"); return 0; }\n' > "${_probe_src}"
        local _zig_base="${NATIVE_CC%% *}"  # extract zig exe path (before ' cc -target ...')

        # Approach 1: current target (x86_64-windows-gnu) — baseline (expected: fail 127)
        echo "  DEBUG-STDLIB-DIR: [probe1] x86_64-windows-gnu (baseline)..."
        local _p="/tmp/probe1.exe"
        if ${NATIVE_CC} -o "${_p}" "${_probe_src}" 2>&1; then
          _out=$("${_p}" 2>&1) && _rc=$? || _rc=$?
          echo "  DEBUG-STDLIB-DIR: [probe1] rc=${_rc} out='${_out}'"
          objdump -p "${_p}" 2>/dev/null | grep "DLL Name" | sed 's/^/  DEBUG-STDLIB-DIR: [probe1] /' || true
        else
          echo "  DEBUG-STDLIB-DIR: [probe1] BUILD FAILED"
        fi
        rm -f "${_p}"

        # Approach 2: -static (statically link CRT)
        echo "  DEBUG-STDLIB-DIR: [probe2] x86_64-windows-gnu -static..."
        _p="/tmp/probe2.exe"
        if ${NATIVE_CC} -static -o "${_p}" "${_probe_src}" 2>&1; then
          _out=$("${_p}" 2>&1) && _rc=$? || _rc=$?
          echo "  DEBUG-STDLIB-DIR: [probe2] rc=${_rc} out='${_out}'"
          objdump -p "${_p}" 2>/dev/null | grep "DLL Name" | sed 's/^/  DEBUG-STDLIB-DIR: [probe2] /' || true
        else
          echo "  DEBUG-STDLIB-DIR: [probe2] BUILD FAILED"
        fi
        rm -f "${_p}"

        # Approach 3: -target x86_64-windows-msvc (MSVC CRT — msvcrt.dll)
        echo "  DEBUG-STDLIB-DIR: [probe3] x86_64-windows-msvc..."
        _p="/tmp/probe3.exe"
        if "${_zig_base}" cc -target x86_64-windows-msvc -o "${_p}" "${_probe_src}" 2>&1; then
          _out=$("${_p}" 2>&1) && _rc=$? || _rc=$?
          echo "  DEBUG-STDLIB-DIR: [probe3] rc=${_rc} out='${_out}'"
          objdump -p "${_p}" 2>/dev/null | grep "DLL Name" | sed 's/^/  DEBUG-STDLIB-DIR: [probe3] /' || true
        else
          echo "  DEBUG-STDLIB-DIR: [probe3] BUILD FAILED"
        fi
        rm -f "${_p}"

        # Approach 4: add C:\Windows\System32 to PATH then run baseline binary
        echo "  DEBUG-STDLIB-DIR: [probe4] windows-gnu + System32 in PATH..."
        _p="/tmp/probe4.exe"
        if ${NATIVE_CC} -o "${_p}" "${_probe_src}" 2>&1; then
          _out=$(PATH="/c/Windows/System32:${PATH}" "${_p}" 2>&1) && _rc=$? || _rc=$?
          echo "  DEBUG-STDLIB-DIR: [probe4] rc=${_rc} out='${_out}'"
        else
          echo "  DEBUG-STDLIB-DIR: [probe4] BUILD FAILED"
        fi
        rm -f "${_p}"

        # Approach 5: add C:\Windows\System32 to PATH via Windows-style path
        echo "  DEBUG-STDLIB-DIR: [probe5] windows-gnu + C:\\Windows\\System32 in PATH..."
        _p="/tmp/probe5.exe"
        if ${NATIVE_CC} -o "${_p}" "${_probe_src}" 2>&1; then
          _out=$(PATH="C:\\Windows\\System32:${PATH}" "${_p}" 2>&1) && _rc=$? || _rc=$?
          echo "  DEBUG-STDLIB-DIR: [probe5] rc=${_rc} out='${_out}'"
        else
          echo "  DEBUG-STDLIB-DIR: [probe5] BUILD FAILED"
        fi
        rm -f "${_p}"

        # Show current PATH for context
        echo "  DEBUG-STDLIB-DIR: Current PATH (first 5 entries):"
        echo "${PATH}" | tr ':' '\n' | head -5 | sed 's/^/  DEBUG-STDLIB-DIR:   /'

        rm -f "${_probe_src}"
        echo "  DEBUG-STDLIB-DIR: === END ZIG RUNTIME PROBE ==="
        # Test: does sak.exe run at all? Capture BOTH stdout and stderr separately
        echo "  DEBUG-STDLIB-DIR: Testing sak.exe (no args)..."
        local _sak_stdout _sak_stderr _sak_rc
        _sak_stdout=$("${_sak_exe}" 2>/tmp/sak_stderr.txt) && _sak_rc=$? || _sak_rc=$?
        _sak_stderr=$(cat /tmp/sak_stderr.txt 2>/dev/null)
        echo "  DEBUG-STDLIB-DIR: sak.exe exit code: ${_sak_rc}"
        [[ -n "${_sak_stdout}" ]] && echo "  DEBUG-STDLIB-DIR: sak.exe stdout: '${_sak_stdout}'"
        [[ -n "${_sak_stderr}" ]] && echo "  DEBUG-STDLIB-DIR: sak.exe stderr: '${_sak_stderr}'"
        # Test: encode-C-utf16-literal with a sample path
        local _test_libdir
        _test_libdir=$(grep '^TARGET_LIBDIR=' Makefile.build_config 2>/dev/null | cut -d= -f2-)
        if [[ -n "${_test_libdir}" ]]; then
          echo "  DEBUG-STDLIB-DIR: Testing sak encode-C-utf16-literal '${_test_libdir}'"
          local _sak_output
          _sak_output=$("${_sak_exe}" encode-C-utf16-literal "${_test_libdir}" 2>/tmp/sak_stderr.txt) && _sak_rc=$? || _sak_rc=$?
          _sak_stderr=$(cat /tmp/sak_stderr.txt 2>/dev/null)
          echo "  DEBUG-STDLIB-DIR: sak output (rc=${_sak_rc}): '${_sak_output}'"
          [[ -n "${_sak_stderr}" ]] && echo "  DEBUG-STDLIB-DIR: sak stderr: '${_sak_stderr}'"
          if [[ -z "${_sak_output}" ]]; then
            echo "  DEBUG-STDLIB-DIR: *** SAK OUTPUT IS EMPTY - THIS WILL CAUSE OCAML_STDLIB_DIR FAILURE ***"
            echo "  DEBUG-STDLIB-DIR: Trying encode-C-utf8-literal instead..."
            _sak_output=$("${_sak_exe}" encode-C-utf8-literal "${_test_libdir}" 2>/tmp/sak_stderr.txt) && _sak_rc=$? || _sak_rc=$?
            _sak_stderr=$(cat /tmp/sak_stderr.txt 2>/dev/null)
            echo "  DEBUG-STDLIB-DIR: sak utf8 output (rc=${_sak_rc}): '${_sak_output}'"
            [[ -n "${_sak_stderr}" ]] && echo "  DEBUG-STDLIB-DIR: sak utf8 stderr: '${_sak_stderr}'"
          fi
          # Also test with Make's $(shell) invocation pattern (single-quoted path)
          echo "  DEBUG-STDLIB-DIR: Testing via sh -c (simulating Make shell)..."
          _sak_output=$(sh -c "'${_sak_exe}' encode-C-utf16-literal '${_test_libdir}'" 2>/tmp/sak_stderr.txt) && _sak_rc=$? || _sak_rc=$?
          _sak_stderr=$(cat /tmp/sak_stderr.txt 2>/dev/null)
          echo "  DEBUG-STDLIB-DIR: sh -c output (rc=${_sak_rc}): '${_sak_output}'"
          [[ -n "${_sak_stderr}" ]] && echo "  DEBUG-STDLIB-DIR: sh -c stderr: '${_sak_stderr}'"
        else
          echo "  DEBUG-STDLIB-DIR: Could not extract TARGET_LIBDIR to test sak"
        fi
      else
        echo "  DEBUG-STDLIB-DIR: *** sak.exe BUILD FAILED ***"
      fi
    else
      echo "  DEBUG-STDLIB-DIR: ${_sak_src} not found!"
    fi
    echo "  DEBUG-STDLIB-DIR: === end diagnostic ==="

    echo "  [4/7] Pre-building bytecode runtime and stdlib with native tools..."
    # Save the pre-built boot/ocamlrun.exe from BUILD_PREFIX before make
    # overwrites it with the zig-compiled ocamlruns.exe. The zig-compiled
    # bytecode interpreter segfaults when running flexlink bytecode — the
    # pre-built one (from the native OCaml package) works correctly.
    if ! is_unix && [[ -f boot/ocamlrun.exe ]]; then
      cp boot/ocamlrun.exe boot/ocamlrun.exe.prebuilt
      echo "  Saved pre-built boot/ocamlrun.exe (zig runtime segfaults on bytecode)"
    fi
    # Split runtime-all into two phases for win-arm64 cross-compilation:
    # Phase A: build ocamlruns.exe with native BYTECCLIBS (no arm64 -L paths).
    #   MKEXE_VIA_CC uses $(CC) directly — the arm64 import libs in BYTECCLIBS
    #   cause "machine type arm64 conflicts with x64" when linking with native CC.
    # Phase B: build everything else (ocamlrun.exe, ocamlrund.exe, sak.exe, etc.)
    #   using Makefile.config's BYTECCLIBS which includes arm64 -L paths for
    #   flexlink -chain mingw64arm. Make skips ocamlruns.exe (already up-to-date).
    if ! is_unix && [[ -n "${_native_bytecclibs:-}" ]]; then
      echo "  [4/7a] Building ocamlruns.exe with native BYTECCLIBS (no arm64 libs)..."
      run_logged "runtime-ocamlruns" "${MAKE[@]}" runtime/ocamlruns.exe \
        V=1 \
        ARCH=amd64 \
        CC="${NATIVE_CC}" \
        CFLAGS="${NATIVE_CFLAGS}" \
        LD="${NATIVE_LD}" \
        LDFLAGS="${NATIVE_LDFLAGS}" \
        BYTECCLIBS="${_native_bytecclibs}" \
        ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd" \
        -j"${CPU_COUNT}"
      echo "  [4/7b] Building arm64 runtime targets (cross CC + flexlink arm64 BYTECCLIBS)..."
      # Phase B for win-arm64: rebuild everything with cross CC (arm64 zig).
      # Phase A built ocamlruns.exe as x64 — save it, let phase B rebuild all
      # objects as arm64 (including ocamlruns.exe), then restore the x64 copy.
      # This avoids the shared-object problem: prims.obj, libcamlrun_non_shared.lib
      # are used by both ocamlruns and ocamlrun, but can't be both x64 and arm64.
      # Save x64 ocamlruns.exe + boot/ocamlrun.exe, then clean shared objects.
      # Phase B builds only ocamlrun.exe and ocamlrund.exe (flexlink arm64 targets).
      # We do NOT build runtime-all because it includes ocamlruns.exe which uses
      # MKEXE_VIA_CC (hardcoded x64 in Makefile.build_config) but reads BYTECCLIBS
      # from Makefile.config (which now has arm64 -L path) → architecture conflict.
      # Build patched flexlink.exe — Phase A only builds ocamlruns.exe.
      # flexlink is normally built during crossopt (step 5) but step 4b needs it.
      echo "  Building patched flexlink.exe from flexdll/ source..."
      local _native_stdlib
      if [[ -d "${BUILD_PREFIX}/Library/lib/ocaml" ]]; then
        _native_stdlib="${BUILD_PREFIX}/Library/lib/ocaml"
      else
        _native_stdlib="${BUILD_PREFIX}/lib/ocaml"
      fi
      # Build flexdll support objects (C files: all chains including arm64).
      # Skip native flexlink.exe target — bootstrap ocamlopt uses lld-link directly
      # (no MKEXE) but conda ships no static OCaml native runtime .lib (only
      # camlrun.dll via flexlink), creating a bootstrap circularity.
      # Build flexlink.exe as bytecode with ocamlc to break the circularity.
      CONDA_OCAML_AS="${NATIVE_ASM}" CONDA_OCAML_CC="${NATIVE_CC}" \
      OCAMLLIB="${_native_stdlib}" \
        "${MAKE[@]}" -C flexdll \
          NATDYNLINK=false \
          CC="${CROSS_CC}" \
          build_mingw64arm \
          V=1
      echo "  Built flexdll arm64 support objects: $(ls flexdll/*.obj 2>/dev/null | tr '\n' ' ')"
      # Build flexlink.exe bytecode using bootstrap ocamlc.
      # Bytecode runs via ocamlrun.exe (from $BUILD_PREFIX in PATH).
      local _ocamlc_exe="${BUILD_PREFIX}/Library/bin/ocamlc.exe"
      [[ -f "${_ocamlc_exe}" ]] || _ocamlc_exe="${BUILD_PREFIX}/bin/ocamlc.exe"
      echo "  Building flexlink.exe (bytecode) with ${_ocamlc_exe}..."
      # Write version.ml with zig arm64 cross-compiler before compiling
      local _zig_exe_fla="${CROSS_CC%% *}"
      local _zig_exe_fla_win
      _zig_exe_fla_win=$(cygpath -m "${_zig_exe_fla}" 2>/dev/null || echo "${_zig_exe_fla}")
      local _zig_cross_cc_fla="${_zig_exe_fla_win} cc -target aarch64-windows-gnu"
      cat > flexdll/version.ml <<VERSIONML_BYTE
let version = "0.44"
let mingw_prefix = "i686-w64-mingw32-"
let mingw64_prefix = "x86_64-w64-mingw32-"
let mingw64arm_prefix = "aarch64-w64-mingw32-"
let msvc = "cl"
let msvc64 = "cl"
let cygwin64 = "x86_64-pc-cygwin-gcc"
let mingw = "i686-w64-mingw32-gcc"
let mingw64 = "x86_64-w64-mingw32-gcc"
let mingw64arm = "${_zig_cross_cc_fla}"
let gnat = "gcc"
VERSIONML_BYTE
      # Compat.ml is generated from Compat.ml.in by the flexdll Makefile (sed strip).
      # build_mingw64arm only builds .obj files — generate Compat.ml manually.
      # Upstream drops all ^4XX:-prefixed shims for OCaml >= 4.08; bootstrap is 5.x,
      # so all prefixed lines reference removed symbols (Pervasives, String.create).
      if [[ -f flexdll/Compat.ml.in ]] && [[ ! -f flexdll/Compat.ml ]]; then
        sed -E -e '/^[0-9]+:/d' flexdll/Compat.ml.in > flexdll/Compat.ml
        echo "  Generated flexdll/Compat.ml from Compat.ml.in (all OCaml<4.08 shims dropped for 5.x bootstrap)"
      fi
      (
        cd "${SRC_DIR}/flexdll"
        OCAMLLIB="${_native_stdlib}" \
          "${_ocamlc_exe}" \
            -o flexlink.exe \
            version.ml Compat.ml coff.ml cmdline.ml create_dll.ml reloc.ml
      )
      echo "  Built flexlink.exe: $(ls -la flexdll/flexlink.exe 2>/dev/null || echo 'NOT FOUND')"
      cp runtime/ocamlruns.exe runtime/ocamlruns.exe.x64
      cp boot/ocamlrun.exe boot/ocamlrun.exe.x64
      # Save Phase A flexlink (has mingw64arm support from our patch)
      if [[ -f flexdll/flexlink.exe ]]; then
        cp flexdll/flexlink.exe flexdll/flexlink.exe.x64
      elif [[ -f byte/bin/flexlink.exe ]]; then
        cp byte/bin/flexlink.exe flexdll/flexlink.exe.x64
      fi
      echo "  Saved x64 ocamlruns.exe, cleaning shared objects for arm64 rebuild..."
      # Prevent Make from rebuilding ocamlruns.exe during Phase B:
      # deleting .b.obj files invalidates libcamlrun_non_shared.lib prereqs,
      # causing Make to rebuild the .lib then re-link ocamlruns.exe with
      # arm64 BYTECCLIBS against x64 MKEXE_VIA_CC → arch conflict.
      touch -t 209901010000 runtime/ocamlruns.exe
      rm -f runtime/*.b.obj runtime/*.bd.obj runtime/*.bpic.obj runtime/prims.obj
      rm -f runtime/libcamlrun.lib runtime/libcamlrund.lib
      rm -f runtime/ocamlrun.exe runtime/ocamlrund.exe
      # Build only the flexlink-linked targets (arm64) — NOT ocamlruns.exe.
      # Override CC to CROSS_CC so .b.obj/.bd.obj files are compiled for arm64
      # (Makefile.config CC targets x64; zig just needs a different -target flag).
      # Write flexdll/version.ml with zig cross-compiler baked in.
      # version.ml is a GENERATED file (flexdll Makefile target) — distclean
      # removes it, and Phase A doesn't trigger flexdll rebuild to regenerate.
      # Flexlink bakes version.ml into bytecode — no PATH lookup needed.
      # Use cygpath -m (mixed/forward slashes) to avoid OCaml illegal-backslash
      # errors — forward slashes are valid in both OCaml strings and Windows APIs.
      _zig_exe="${CROSS_CC%% *}"  # strip "cc -target ..."
      _zig_exe_win=$(cygpath -m "${_zig_exe}" 2>/dev/null || echo "${_zig_exe}")
      _zig_cross_cc="${_zig_exe_win} cc -target aarch64-windows-gnu"
      echo "  Writing flexdll/version.ml: mingw64arm = ${_zig_cross_cc}"
      cat > flexdll/version.ml <<VERSIONML
let version = "0.44"
let mingw_prefix = "i686-w64-mingw32-"
let mingw64_prefix = "x86_64-w64-mingw32-"
let mingw64arm_prefix = "aarch64-w64-mingw32-"
let msvc = "cl"
let msvc64 = "cl"
let cygwin64 = "x86_64-pc-cygwin-gcc"
let mingw = "i686-w64-mingw32-gcc"
let mingw64 = "x86_64-w64-mingw32-gcc"
let mingw64arm = "${_zig_cross_cc}"
let gnat = "gcc"
VERSIONML
      # Force flexdll/flexlink.exe rebuild (native arm64 stub) with patched version.ml.
      rm -f flexdll/flexlink.exe
      # Protect byte/bin/flexlink.exe from Makefile reconstruction.
      # flexlink.byte.exe doesn't exist yet (created in step 5/7 crossopt).
      # The Makefile recipe does rm/cp/cat that would create a broken double-PE.
      # Use Phase A flexlink (patched with mingw64arm chain support)
      # and future-touch to prevent make from overwriting it.
      mkdir -p byte/bin
      # Use Phase A flexlink (patched with mingw64arm chain support)
      if [[ -f flexdll/flexlink.exe.x64 ]]; then
        cp flexdll/flexlink.exe.x64 byte/bin/flexlink.exe
      elif [[ -f flexdll/flexlink.exe ]]; then
        cp flexdll/flexlink.exe byte/bin/flexlink.exe
      else
        echo "  ERROR: No patched flexlink.exe found!"
        echo "  flexdll/flexlink.exe: $(ls -la flexdll/flexlink.exe 2>/dev/null || echo missing)"
        echo "  flexdll/flexlink.exe.x64: $(ls -la flexdll/flexlink.exe.x64 2>/dev/null || echo missing)"
        exit 1
      fi
      touch -t 209901010000 byte/bin/flexlink.exe
      touch -t 209901010000 boot/ocamlrun.exe
      # === V3 fix 2026-04-25j: bypass libcamlrun.lib archive (S3 confirmed size-driven flexlink stack overflow) ===
      # V2 S3 (halved libcamlrun.lib) confirmed: flexlink "Stack overflow" is SIZE-DRIVEN, not an ARM64 reloc bug.
      # Root cause: flexlink's internal recursion stack overflows when processing 59 .b.obj files inside
      # libcamlrun.lib (~2.57MB) during mingw64arm relocation processing.
      # Fix: bypass the .lib archive entirely — build the .b.obj/.bd.obj files via make, then invoke flexlink
      # directly with all .b.obj files expanded on the command line (no archive indirection).
      # This avoids the recursive archive-expansion codepath in flexlink that causes the overflow.

      # Step 0: build crt2.o and dllcrt2.o from zig's bundled mingw-w64 CRT sources.
      # flexlink -chain mingw64arm prepends crt2.o (EXE) and dllcrt2.o (DLL) to default_libs;
      # real MinGW ships these pre-built but zig only ships the .c sources.
      # MUST run before the make invocation below — OCaml's runtime Makefile calls
      # flexlink -chain mingw64arm which expects crt2.o to already exist.
      echo "===== [V3] Building crt2.o and dllcrt2.o from zig mingw sources ====="
      _zig_mingw_crt="${_zig_mingw}/crt"
      _crt2_src="${_zig_mingw_crt}/crtexe.c"      # Compiles to crt2.o (mingw-w64 EXE entry point)
      _dllcrt2_src="${_zig_mingw_crt}/crtdll.c"   # Compiles to dllcrt2.o (mingw-w64 DLL entry point)
      if [[ -f "${_crt2_src}" && -f "${_dllcrt2_src}" ]]; then
        "${_zig_exe}" cc -target aarch64-windows-gnu -c \
          -D_CRTBLD \
          -I "${BUILD_PREFIX}/Library/lib/zig/libc/mingw/include" \
          -I "${BUILD_PREFIX}/Library/lib/zig/libc/mingw/def-include" \
          "${_crt2_src}" -o "${_arm64_lib_dir}/crt2.o" 2>&1 \
          || { echo "FAILED: zig cc crtexe.c" >&2; }
        "${_zig_exe}" cc -target aarch64-windows-gnu -c \
          -D_CRTBLD \
          -I "${BUILD_PREFIX}/Library/lib/zig/libc/mingw/include" \
          -I "${BUILD_PREFIX}/Library/lib/zig/libc/mingw/def-include" \
          "${_dllcrt2_src}" -o "${_arm64_lib_dir}/dllcrt2.o" 2>&1 \
          || { echo "FAILED: zig cc crtdll.c" >&2; }
        ls -la "${_arm64_lib_dir}/"crt*.o 2>&1 || true
        # Inject absolute crt2.o path into FLEXLINKFLAGS so flexlink -chain mingw64arm
        # finds it directly without calling aarch64-w64-mingw32-gcc -print-file-name=crt2.o
        # (that bat wrapper fails in conda env).  flexlink accepts .o/.obj file paths as
        # positional args; FLEXLINKFLAGS is read from the environment by flexlink on every
        # invocation — both from Makefile-driven calls and direct build.sh calls.
        _crt2_dst_win=$(cygpath -m "${_arm64_lib_dir}/crt2.o" 2>/dev/null || echo "${_arm64_lib_dir}/crt2.o")
        export FLEXLINKFLAGS="${FLEXLINKFLAGS:+${FLEXLINKFLAGS} }${_crt2_dst_win}"
        echo "FLEXLINKFLAGS (with crt2 paths): ${FLEXLINKFLAGS}"

        # === gcc.bat regeneration with crt2.o intercept ===
        # Original gcc.bat at line 849 was created before _crt2_dst_win existed.
        # Now overwrite with intercept-enabled version so flexlink's
        # `gcc -print-file-name=crt2.o` query returns the absolute path.
        _flexlink_gcc_bat_v2="${BUILD_PREFIX}/Library/bin/${target}-gcc.bat"
        _zig_exe_win_bat=$(cygpath -w "${_zig_exe}" 2>/dev/null || echo "${_zig_exe//\//\\}")
        _zig_triple_bat="${CROSS_CC##*-target }"
        _zig_triple_bat="${_zig_triple_bat%% *}"
        echo "    DEBUG regen gcc.bat: target=${target} _crt2_dst_win='${_crt2_dst_win}'"
        cat > "${_flexlink_gcc_bat_v2}" << GCCBAT_V2
@echo off
echo [%DATE% %TIME%] gcc.bat called with: [%*] >> "%TEMP%\gcc-bat-trace.log"
echo "%*" | findstr /C:"-print-file-name=crt2.o" >nul 2>&1
if not errorlevel 1 (
  echo ${_crt2_dst_win}
  exit /b 0
)
"${_zig_exe_win_bat}" cc -target ${_zig_triple_bat} %*
GCCBAT_V2
        echo "    Regenerated flexlink shim (v2): ${target}-gcc.bat -> intercepts -print-file-name=crt2.o -> '${_crt2_dst_win}'"

        # Batch empty-archive stubs: zig provides no libmingw32/libgcc/libgcc_eh/libmoldname;
        # CRT startup is handled by zig cc driver + crt2.o built above. flexdll's mingw_libs
        # adds these unconditionally for the mingw64arm chain; satisfy each search with an
        # empty archive so no symbols are pulled in.
        echo "  Creating empty mingw lib stubs (zig provides CRT inline; satisfy flexdll default_libs)"
        _empty_obj="${_arm64_lib_dir}/_empty_mingw_stub.obj"
        echo "" | "${_zig_exe}" cc -target aarch64-windows-gnu -x c -c -o "${_empty_obj}" - 2>/dev/null \
            || { echo "FAILED: empty obj for mingw lib stubs" >&2; }

        for _stub_name in mingw32 gcc gcc_eh moldname mingwex; do
            _stub_dst="${_arm64_lib_dir}/lib${_stub_name}.a"
            _zig_existing="${BUILD_PREFIX}/Library/lib/zig/libc/mingw/lib-common/lib${_stub_name}.a"
            if [[ -f "${_stub_dst}" ]]; then
                echo "  lib${_stub_name}.a already in _arm64_lib_dir — skip stub"
                continue
            fi
            if [[ -f "${_zig_existing}" ]]; then
                echo "  lib${_stub_name}.a present in zig lib-common — skip stub"
                continue
            fi
            "${_zig_exe}" ar rcs "${_stub_dst}" "${_empty_obj}" \
                || { echo "FAILED: zig ar lib${_stub_name}.a stub" >&2; }
            echo "  created stub: $(ls -l "${_stub_dst}" 2>&1)"
        done
      else
        echo "WARNING: zig mingw CRT sources not found at ${_zig_mingw_crt}"
        ls -la "${_zig_mingw_crt}/" 2>&1 || true
      fi

      # Step 1: build all .b.obj and .bd.obj files (but not the link step — make will try to link and fail
      # with the .lib; we catch the error and proceed if the objs exist).
      echo "  ===== [V3] Building runtime .b.obj/.bd.obj files via make ====="
      # Fix-27b: flexlink is OCaml bytecode; large libcamlrun.lib (59 .b.obj members) overflows
      # the OCaml interpreter stack. Set BOTH s= (initial stack chunk) and l= (max stack limit)
      # to 256 MiB. Fix-27a tried l= alone but overflow persisted; flexlink may need a larger
      # initial allocation, not just a higher ceiling. NOTE: this is the OCaml bytecode interpreter
      # stack, NOT the output PE stack (which flexlink controls via its own -stack flag).
      export OCAMLRUNPARAM="${OCAMLRUNPARAM:+${OCAMLRUNPARAM},}s=268435456,l=268435456"
      echo "  Fix-27b: OCAMLRUNPARAM=${OCAMLRUNPARAM}"
      run_logged "runtime-arm64-v3-compile" "${MAKE[@]}" \
        runtime/ocamlrun.exe runtime/ocamlrund.exe \
        V=1 \
        CC="${CROSS_CC}" \
        SAK_CC="${SAK_CC_GNU:-${NATIVE_CC}}" \
        SAK_CFLAGS="${NATIVE_CFLAGS}" \
        SAK_LDFLAGS="${NATIVE_LDFLAGS}" \
        ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd" \
        -j"${CPU_COUNT}" || true  # may fail at link step; that is expected

      # Verify .b.obj files exist before proceeding
      local _bobj_count _bdobj_count
      _bobj_count=$(ls runtime/*.b.obj 2>/dev/null | wc -l)
      _bdobj_count=$(ls runtime/*.bd.obj 2>/dev/null | wc -l)
      echo "  [V3] .b.obj count: ${_bobj_count}, .bd.obj count: ${_bdobj_count}"
      if [[ "${_bobj_count}" -lt 10 ]]; then
        echo "  [V3] ERROR: too few .b.obj files (${_bobj_count}); compilation likely failed"
        ls -la runtime/*.b.obj 2>/dev/null || echo "  (none found)"
        exit 1
      fi

      # Step 2: extract BYTECCLIBS from Makefile.config for the flexlink invocation.
      # The Makefile link rule for ocamlrun.exe passes $(BYTECCLIBS) which contains
      # the arm64-injected -L and -l flags (zig lib-common, crt_helpers, ucrtbase, ws2_32, etc).
      # These were written to Makefile.config by the arm64 BYTECCLIBS injection step above.
      local _bytecclibs
      _bytecclibs=$(grep -E '^BYTECCLIBS=' Makefile.config 2>/dev/null | head -1 | sed 's/^BYTECCLIBS=//')
      echo "  [V3] BYTECCLIBS from Makefile.config: ${_bytecclibs}"

      # V3 fix 2026-04-25k: use source-built patched flexlink (mingw64arm chain support).
      # conda-installed stock FlexDLL 0.44 (on PATH) lacks mingw64arm; it errors with
      # "wrong argument 'mingw64arm'". The patched flexlink built in Phase A lives at
      # ${SRC_DIR}/flexdll/flexlink.exe (cwd=${SRC_DIR} here, so relative path works too,
      # but we use the absolute form to be explicit and safe regardless of subshell shifts).
      local _patched_flexlink="${SRC_DIR}/flexdll/flexlink.exe"
      if [[ ! -f "${_patched_flexlink}" ]]; then
        echo "  [V3] ERROR: patched flexlink not found at ${_patched_flexlink}"
        echo "  flexdll/ contents: $(ls flexdll/flexlink*.exe 2>/dev/null || echo '(none)')"
        exit 1
      fi
      echo "  [V3] Using patched flexlink: ${_patched_flexlink}"

      # Fix 2026-04-26c-diag: dump lib-common .a contents to verify __imp_ vs undecorated symbol presence; informs next architectural fix
      echo "=== DIAG START 2026-04-26c-diag ==="

      echo "=== DIAG 2026-04-26c: lib-common .a files ==="
      ls -lah "${BUILD_PREFIX}/Library/lib/zig/libc/mingw/lib-common/"*.a 2>&1 | head -30 || true

      local _diag_lib_common="${BUILD_PREFIX}/Library/lib/zig/libc/mingw/lib-common"
      for _diag_lib in libucrtbase.a libuser32.a libkernel32.a libws2_32.a; do
        local _diag_path="${_diag_lib_common}/${_diag_lib}"
        echo "--- DIAG: ${_diag_lib} members ---"
        ar t "${_diag_path}" 2>&1 | head -20 || true
        echo "--- DIAG: ${_diag_lib} defined symbols (first 50) ---"
        nm --defined-only "${_diag_path}" 2>&1 | head -50 || true
        echo "--- DIAG: ${_diag_lib} key symbol grep ---"
        nm "${_diag_path}" 2>&1 | grep -E ' (T|U|D) (fprintf|printf|__imp_fprintf|WSAStartup|CloseHandle|__ubsan_handle_pointer_overflow)$' | head -10 || true
      done

      local _diag_crt_helpers="${BUILD_PREFIX}/Library/lib/ocaml-arm64-imports/libcrt_helpers.a"
      echo "--- DIAG: libcrt_helpers.a UBSan content ---"
      nm "${_diag_crt_helpers}" 2>&1 | grep -E '__ubsan' | head -20 || true
      echo "--- DIAG: libcrt_helpers.a all defined symbols ---"
      nm --defined-only "${_diag_crt_helpers}" 2>&1 | head -30 || true

      echo "--- DIAG: sample runtime .b.obj undefined symbols ---"
      local _diag_bobj
      _diag_bobj=$(ls runtime/*.b.obj 2>/dev/null | head -1 || true)
      if [[ -n "${_diag_bobj}" ]]; then
        echo "  (using ${_diag_bobj})"
        nm "${_diag_bobj}" 2>&1 | grep -E '^\s+U ' | head -20 || true
      else
        echo "  (no .b.obj found)"
      fi

      echo "--- DIAG 2026-04-26g: libkernel32.a arch verification ---"
      _lc_dir="${BUILD_PREFIX}/Library/lib/zig/libc/mingw/lib-common"
      echo "--- ls ${BUILD_PREFIX}/Library/lib/zig/libc/mingw/ (look for arch-specific dirs) ---"
      ls -la "${BUILD_PREFIX}/Library/lib/zig/libc/mingw/" 2>&1 | head -30 || true
      echo "--- zig ar t libkernel32.a (member names hint at arch) ---"
      "${_zig_exe}" ar t "${_lc_dir}/libkernel32.a" 2>&1 | head -10 || true
      echo "--- magic bytes of first archive member (od) libkernel32.a ---"
      od -A x -t x1z -N 16 "${_lc_dir}/libkernel32.a" 2>&1 || true

      echo "=== DIAG END 2026-04-26c-diag ==="

      # Diagnostic: capture flexlink alias resolution chain on win-arm64 to investigate
      # any remaining stack overflow or symbol resolution issues. Honored by OCaml
      # Makefile-driven invocations AND build.sh direct flexlink calls.
      # Append -explain to FLEXLINKFLAGS (crt2 paths already injected above in Step 0).
      export FLEXLINKFLAGS="${FLEXLINKFLAGS:+${FLEXLINKFLAGS} }-explain"
      echo "FLEXLINKFLAGS=${FLEXLINKFLAGS}"

      # Step 4: invoke flexlink directly for ocamlrun.exe, expanding all .b.obj files inline.
      echo "  ===== [V3] Direct flexlink for ocamlrun.exe (bypassing libcamlrun.lib) ====="

      # === PRE-DIAGNOSTIC DUMP: collect everything we need to understand direct-flexlink behavior ===
      echo "===================================================="
      echo "  DIAG DUMP — direct-flexlink environment for crt2.o investigation"
      echo "===================================================="
      echo "DIAG: target=${target}"
      echo "DIAG: _patched_flexlink='${_patched_flexlink}'"
      echo "DIAG: file _patched_flexlink:"
      file "${_patched_flexlink}" 2>&1 || echo "  (file command unavailable)"
      echo "DIAG: ls -la _patched_flexlink:"
      ls -la "${_patched_flexlink}" 2>&1 || true
      echo "DIAG: _crt2_dst_win (raw) = '${_crt2_dst_win}'"
      echo "DIAG: hex dump of _crt2_dst_win:"
      echo -n "${_crt2_dst_win}" | od -c | head -5 || true
      echo "DIAG: _arm64_lib_dir = '${_arm64_lib_dir}'"
      echo "DIAG: ls _arm64_lib_dir/crt2.o:"
      ls -la "${_arm64_lib_dir}/crt2.o" 2>&1 || true
      echo "DIAG: which cygpath:"
      which cygpath 2>&1 || echo "  cygpath NOT FOUND on PATH"
      echo "DIAG: cygpath -m crt2:"
      cygpath -m "${_arm64_lib_dir}/crt2.o" 2>&1 || echo "  (cygpath -m unavailable)"
      echo "DIAG: cygpath -w crt2:"
      cygpath -w "${_arm64_lib_dir}/crt2.o" 2>&1 || echo "  (cygpath -w unavailable)"
      echo "DIAG: pwd -W:"
      pwd -W 2>&1 || echo "  (pwd -W unavailable)"
      echo "DIAG: PATH (head):"
      echo "${PATH}" | tr ':' '\n' | head -15 || true
      echo "DIAG: which ${target}-gcc.bat:"
      ls -la "${BUILD_PREFIX}/Library/bin/${target}-gcc.bat" 2>&1 || true
      echo "DIAG: cat ${target}-gcc.bat:"
      cat "${BUILD_PREFIX}/Library/bin/${target}-gcc.bat" 2>&1 || true
      echo "DIAG: invoke gcc.bat with -print-file-name=crt2.o directly:"
      "${BUILD_PREFIX}/Library/bin/${target}-gcc.bat" -print-file-name=crt2.o 2>&1 || echo "  (gcc.bat invocation failed)"
      echo "DIAG: FLEXLINKFLAGS='${FLEXLINKFLAGS}'"
      echo "===================================================="

      echo ""
      echo "=== FLEXLINK CHAIN INTROSPECTION ==="
      echo "DIAG: flexlink -help (first 50 lines):"
      "${_patched_flexlink}" -help 2>&1 | head -50 || true
      echo ""
      echo "DIAG: flexlink -chain (no value, see if it lists chains):"
      "${_patched_flexlink}" -chain 2>&1 | head -10 || true
      echo ""
      echo "DIAG: strings flexlink.exe | grep -i 'mingw\\|crt2' | head -30:"
      strings "${_patched_flexlink}" 2>/dev/null | grep -i 'mingw\|crt2' | head -30 || echo "  (strings unavailable)"

      # Compute alternative path representations
      _crt2_posix="${_arm64_lib_dir}/crt2.o"
      _crt2_winsl=$(cygpath -w "${_crt2_posix}" 2>/dev/null || echo "${_crt2_posix}")
      _crt2_mixed=$(cygpath -m "${_crt2_posix}" 2>/dev/null || echo "${_crt2_posix}")
      echo "DIAG: _crt2_posix='${_crt2_posix}'"
      echo "DIAG: _crt2_winsl (cygpath -w)='${_crt2_winsl}'"
      echo "DIAG: _crt2_mixed (cygpath -m)='${_crt2_mixed}'"

      # Also place crt2.o where gcc -print-file-name might natively find it (fallback chain)
      _zig_lib_common="${BUILD_PREFIX}/Library/lib/zig/libc/mingw/lib-common"
      if [[ -d "${_zig_lib_common}" ]]; then
        cp -L "${_crt2_posix}" "${_zig_lib_common}/crt2.o" 2>&1 \
          && echo "DIAG: copied crt2.o to ${_zig_lib_common}/crt2.o" \
          || echo "DIAG: copy to ${_zig_lib_common} failed (read-only or absent)"
      fi

      # === TRIAL 1: ORIGINAL — positional arg + FLEXLINKFLAGS, forward-slash path ===
      echo ""
      echo "=== TRIAL 1: positional + FLEXLINKFLAGS, forward-slash (cygpath -m) path ==="
      _T1_OUT="runtime/ocamlrun-trial1.exe"
      # shellcheck disable=SC2086
      run_logged "trial1-original" \
        "${_patched_flexlink}" -exe -chain mingw64arm -explain -stack 33554432 -link -municode \
          -o "${_T1_OUT}" \
          "${_crt2_mixed}" \
          runtime/prims.obj \
          runtime/*.b.obj \
          ${_bytecclibs} \
        && echo "  TRIAL 1 SUCCESS" || echo "  TRIAL 1 FAILED"

      # === TRIAL 2: NO POSITIONAL ARG — FLEXLINKFLAGS only ===
      echo ""
      echo "=== TRIAL 2: FLEXLINKFLAGS only, no positional crt2.o ==="
      _T2_OUT="runtime/ocamlrun-trial2.exe"
      # shellcheck disable=SC2086
      run_logged "trial2-no-positional" \
        "${_patched_flexlink}" -exe -chain mingw64arm -explain -stack 33554432 -link -municode \
          -o "${_T2_OUT}" \
          runtime/prims.obj \
          runtime/*.b.obj \
          ${_bytecclibs} \
        && echo "  TRIAL 2 SUCCESS" || echo "  TRIAL 2 FAILED"

      # === TRIAL 3: BACKSLASH PATH — cygpath -w form ===
      echo ""
      echo "=== TRIAL 3: positional with cygpath -w (backslash) path ==="
      _T3_OUT="runtime/ocamlrun-trial3.exe"
      # shellcheck disable=SC2086
      run_logged "trial3-backslash" \
        "${_patched_flexlink}" -exe -chain mingw64arm -explain -stack 33554432 -link -municode \
          -o "${_T3_OUT}" \
          "${_crt2_winsl}" \
          runtime/prims.obj \
          runtime/*.b.obj \
          ${_bytecclibs} \
        && echo "  TRIAL 3 SUCCESS" || echo "  TRIAL 3 FAILED"

      # === TRIAL 4: CHAIN-FREE — no -chain, see if crt2.o lookup is chain-related ===
      echo ""
      echo "=== TRIAL 4: no -chain flag, see what flexlink does without chain resolution ==="
      _T4_OUT="runtime/ocamlrun-trial4.exe"
      # shellcheck disable=SC2086
      run_logged "trial4-no-chain" \
        "${_patched_flexlink}" -exe -explain -stack 33554432 -link -municode \
          -o "${_T4_OUT}" \
          "${_crt2_mixed}" \
          runtime/prims.obj \
          runtime/*.b.obj \
          ${_bytecclibs} \
        && echo "  TRIAL 4 SUCCESS" || echo "  TRIAL 4 FAILED"

      # === TRIAL 5: ENV-OVERRIDE — set FLEXDIR to point at a dir containing crt2.o ===
      echo ""
      echo "=== TRIAL 5: FLEXDIR override + positional, basename-only ==="
      _T5_OUT="runtime/ocamlrun-trial5.exe"
      _FLEXDIR_BACKUP="${FLEXDIR:-}"
      export FLEXDIR="${_arm64_lib_dir}"
      # shellcheck disable=SC2086
      run_logged "trial5-flexdir" \
        "${_patched_flexlink}" -exe -chain mingw64arm -explain -stack 33554432 -link -municode \
          -o "${_T5_OUT}" \
          "${_crt2_mixed}" \
          runtime/prims.obj \
          runtime/*.b.obj \
          ${_bytecclibs} \
        && echo "  TRIAL 5 SUCCESS" || echo "  TRIAL 5 FAILED"
      export FLEXDIR="${_FLEXDIR_BACKUP}"

      # === Pick the first successful trial output as runtime/ocamlrun.exe ===
      echo ""
      echo "=== Trial outcome summary ==="
      for trial_n in 1 2 3 4 5; do
        trial_out="runtime/ocamlrun-trial${trial_n}.exe"
        if [[ -f "${trial_out}" ]]; then
          echo "  Trial ${trial_n}: PRODUCED ${trial_out} ($(stat -c '%s' "${trial_out}" 2>/dev/null || echo '?') bytes)"
          if [[ ! -f "runtime/ocamlrun.exe" ]]; then
            cp "${trial_out}" "runtime/ocamlrun.exe"
            echo "  -> adopted as runtime/ocamlrun.exe (from trial ${trial_n})"
          fi
        else
          echo "  Trial ${trial_n}: NO OUTPUT"
        fi
      done

      # === SURFACE PER-TRIAL FLEXLINK LOGS ===
      echo ""
      echo "=== Surfacing per-trial flexlink -explain logs ==="
      for trial_log in runtime-arm64-v3-link-trial*.log; do
        if [[ -f "${trial_log}" ]]; then
          echo "--- BEGIN ${trial_log} ---"
          cat "${trial_log}" || true
          echo "--- END ${trial_log} ---"
        fi
      done

      # === SURFACE GCC.BAT TRACE LOG ===
      echo ""
      echo "=== gcc.bat invocation trace ==="
      _gcc_bat_trace_unix=$(cygpath -u "%TEMP%/gcc-bat-trace.log" 2>/dev/null || echo "/tmp/gcc-bat-trace.log")
      if [[ -f "${_gcc_bat_trace_unix}" ]]; then
        cat "${_gcc_bat_trace_unix}" || true
      else
        # Try common temp locations
        for trace_path in "${TEMP}/gcc-bat-trace.log" "${TMP}/gcc-bat-trace.log" "/tmp/gcc-bat-trace.log" "${SRC_DIR}/gcc-bat-trace.log"; do
          if [[ -f "${trace_path}" ]]; then
            echo "Found trace at: ${trace_path}"
            cat "${trace_path}" || true
            break
          fi
        done
      fi

      if [[ ! -f "runtime/ocamlrun.exe" ]]; then
        echo "ERROR: All 5 trials failed to produce runtime/ocamlrun.exe"
        exit 1
      fi

      # Step 5: invoke flexlink directly for ocamlrund.exe, expanding all .bd.obj files inline.
      echo "  ===== [V3] Direct flexlink for ocamlrund.exe (bypassing libcamlrund.lib) ====="
      # shellcheck disable=SC2086
      run_logged "runtime-arm64-v3-link-ocamlrund" \
        "${_patched_flexlink}" -exe -chain mingw64arm -explain -stack 33554432 -link -municode -link -g \
          -o runtime/ocamlrund.exe \
          "${_crt2_dst_win}" \
          runtime/prims.obj \
          runtime/*.bd.obj \
          ${_bytecclibs}

      # Verify both executables were produced
      if [[ ! -f runtime/ocamlrun.exe ]] || [[ ! -f runtime/ocamlrund.exe ]]; then
        echo "  [V3] ERROR: link step failed"
        ls -la runtime/ocamlrun*.exe 2>/dev/null || echo "  (no ocamlrun*.exe found)"
        exit 1
      fi
      echo "  [V3] SUCCESS: ocamlrun.exe and ocamlrund.exe produced via direct .obj linking"
      # Restore x64 ocamlruns.exe + boot/ocamlrun.exe for bytecode tools
      echo "  Restoring x64 ocamlruns.exe and boot/ocamlrun.exe..."
      cp runtime/ocamlruns.exe.x64 runtime/ocamlruns.exe
      cp boot/ocamlrun.exe.x64 boot/ocamlrun.exe
    else
      # Non-cross or unix: use native CC for everything
      run_logged "runtime-all" "${MAKE[@]}" runtime-all \
        V=1 \
        ARCH=amd64 \
        CC="${NATIVE_CC}" \
        CFLAGS="${NATIVE_CFLAGS}" \
        LD="${NATIVE_LD}" \
        LDFLAGS="${NATIVE_LDFLAGS}" \
        SAK_CC="${SAK_CC_GNU:-${NATIVE_CC}}" \
        SAK_CFLAGS="${NATIVE_CFLAGS}" \
        SAK_LDFLAGS="${NATIVE_LDFLAGS}" \
        \
        ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd" \
        -j"${CPU_COUNT}"
    fi

    # Restore the pre-built boot/ocamlrun.exe.
    # The zig-compiled ocamlrun.exe works for static C operations (sak.exe)
    # but segfaults when interpreting OCaml bytecode. The pre-built ocamlrun.exe
    # from the native OCaml package handles bytecode correctly. crossopt invokes
    # bytecode tools (ocamlopt.byte, etc.) so it needs the working interpreter.
    # NOTE: byte/bin/flexlink.exe is built natively by cross-flexdll inside
    # crossopt — no post-crossopt fixup is needed.
    if ! is_unix && [[ -f boot/ocamlrun.exe.prebuilt ]]; then
      echo "  Restoring pre-built boot/ocamlrun.exe over zig-compiled version"
      cp boot/ocamlrun.exe.prebuilt boot/ocamlrun.exe
    fi

    # DEBUG: Show generated build_config.h AFTER make
    if [[ -f runtime/build_config.h ]]; then
      echo "  DEBUG-STDLIB-DIR: runtime/build_config.h contents:"
      cat runtime/build_config.h
    else
      echo "  DEBUG-STDLIB-DIR: runtime/build_config.h WAS NOT GENERATED!"
    fi

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
    CROSS_TOOLCHAIN_ARGS=(
      ARCH="${CROSS_ARCH}"
      AR="${CROSS_AR}"
      AS="${CROSS_AS}"
      ASPP="${CROSS_CC} -c"
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

    echo "  [5/7] Building and installing cross-compiler..."

    (
      # Export CONDA_OCAML_* for cross-compilation and add cross-tools to PATH
      _setup_crossopt_env

      # Native compiler stdlib location (for copying fresh .cmi files in crossopt)
      # On Windows, conda packages install under Library/ (not directly in PREFIX)
      if is_unix; then
        NATIVE_STDLIB="${OCAML_PREFIX}/lib/ocaml"
      else
        NATIVE_STDLIB="${OCAML_PREFIX}/Library/lib/ocaml"
      fi
      # Fix OCAMLLIB: activate.sh sets ${PREFIX}/lib/ocaml (missing Library/ on
      # Windows).  cross-flexdll calls ocamlopt which needs OCAMLLIB to find Stdlib.
      export OCAMLLIB="${NATIVE_STDLIB}"

      # Compiler drivers (zig, clang) need -c for assembly-only mode.
      # Without -c, zig cc tries to link .s files instead of just assembling.
      if [[ "${NATIVE_ASM}" == *zig* ]] && [[ "${NATIVE_ASM}" != *" -c"* ]]; then
        NATIVE_ASM="${NATIVE_ASM} -c"
        export NATIVE_ASM
      fi

      # --- Build crossopt ---
      CROSSOPT_ARGS=(
        "${CROSS_TOOLCHAIN_ARGS[@]}"
        CAMLOPT=ocamlopt
        CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"
        LIBDIR="${OCAML_CROSS_LIBDIR}"
        ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd"
        TARGET_ZSTD_LIBS="${TARGET_ZSTD_LIBS}"

        SAK_AR="${NATIVE_AR}"
        SAK_CC="${SAK_CC_GNU:-${NATIVE_CC}}"
        SAK_CFLAGS="${NATIVE_CFLAGS}"
        SAK_LDFLAGS="${NATIVE_LDFLAGS}"
        SAK_BYTECCLIBS="${_native_bytecclibs}"

        # ALL executables in cross-compilation run on the BUILD machine (x64).
        # MKEXE must include -Wl,--subsystem,console to force console subsystem.
        # Without it, zig's lld selects the GUI CRT (crtexewin.obj) which expects
        # WinMain() — but ocamlrun uses wmain() (via main_os macro in caml/misc.h).
        MKEXE="${SAK_CC_GNU:-${NATIVE_CC}} -Wl,--subsystem,console"

        # cygpath -m for NATIVE_AS/CC: Makefile.cross passes these to
        # CONDA_OCAML_AS/CC overrides for native-tool steps. The conda-ocaml
        # wrappers (.exe) need Windows paths, not MSYS2 POSIX paths.
        NATIVE_AS="$( ! is_unix && command -v cygpath &>/dev/null && _to_win "${NATIVE_AS}" || echo "${NATIVE_AS}" )"
        NATIVE_ASM="${NATIVE_ASM}"
        NATIVE_CC="$( ! is_unix && command -v cygpath &>/dev/null && _to_win "${NATIVE_CC}" || echo "${NATIVE_CC}" )"
        NATIVE_STDLIB="${NATIVE_STDLIB}"
      )

      # MKEXE override is now handled inside Makefile.cross crossopt recipe
      # (sed on Makefile.config, restored at end of crossopt target)
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
      FINAL_CROSS_LIBDIR="${PREFIX}/lib/ocaml-cross-compilers/${target}/lib/ocaml"
      FINAL_CROSS_PREFIX="${PREFIX}/lib/ocaml-cross-compilers/${target}"
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
export CONDA_OCAML_AS="${CROSS_AS}"
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

  # Apply Makefile.cross patches
  apply_cross_patches

  # Shared args for crosscompiledopt and crosscompiledruntime
  CROSS_TARGET_COMMON_ARGS=(
    ARCH="${CROSS_ARCH}"
    CAMLOPT="${CROSS_OCAMLOPT}"
    AS="${CROSS_AS}"
    ASPP="${CROSS_CC} -c"
    CC="${CROSS_CC}"
    CROSS_CC="${CROSS_CC}"
    CROSS_AR="${CROSS_AR}"
    CROSS_MKLIB="${CROSS_OCAMLMKLIB}"
    ZSTD_LIBS="-L${PREFIX}/lib -lzstd"
    LIBDIR="${OCAML_INSTALL_PREFIX}/lib/ocaml"
    OCAMLLIB="${OCAMLLIB}"
    CONDA_OCAML_AS="${CROSS_AS}"
    CONDA_OCAML_CC="${CROSS_CC}"
    CONDA_OCAML_MKEXE="${CROSS_MKEXE:-}"
    CONDA_OCAML_MKDLL="${CROSS_MKDLL:-}"
    SAK_AR="${NATIVE_AR}"
    SAK_CC="${SAK_CC_GNU:-${NATIVE_CC}}"
    SAK_CFLAGS="${NATIVE_CFLAGS}"
  )

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
        NATIVECCLIBS="-L${PREFIX}/lib -lm -ldl -lzstd"
        BYTECCLIBS="-L${PREFIX}/lib -lm -lpthread -ldl -lzstd"
      )
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
        BYTECCLIBS="-L${PREFIX}/lib -lm -lpthread -ldl -lzstd"
        NATIVECCLIBS="-L${PREFIX}/lib -lm -ldl -lzstd"
        SAK_LINK="${NATIVE_CC} \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)"
      )
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

# ==============================================================================
# MODE: cross-compiler
# Build cross-compiler (native binaries producing target code)
# ==============================================================================
if [[ "${BUILD_MODE}" == "cross-compiler" ]]; then
  # Native OCaml is available in BUILD_PREFIX (from ocaml_$build_platform dependency)

  # Detect build platform toolchain
  # Compiler activation should set CONDA_TOOLCHAIN_BUILD
  if [[ -z "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
    if ! is_unix; then
      # On Windows, use the mingw triplet for native toolchain detection
      # setup_toolchain's *-mingw32 case will find gcc or fall back to zig
      CONDA_TOOLCHAIN_BUILD="x86_64-w64-mingw32"
    else
      echo "ERROR: CONDA_TOOLCHAIN_BUILD not set (compiler activation failed?)"
      exit 1
    fi
  fi

  # Debug: dump conda-build env vars available on this platform
  if ! is_unix; then
    echo "=== DEBUG: Windows cross-compiler environment ==="
    echo "  --- conda-build vars ---"
    echo "  build_platform=${build_platform:-<unset>}"
    echo "  target_platform=${target_platform:-<unset>}"
    echo "  build_alias=${build_alias:-<unset>}"
    echo "  host_alias=${host_alias:-<unset>}"
    echo "  BUILD_PREFIX=${BUILD_PREFIX:-<unset>}"
    echo "  PREFIX=${PREFIX:-<unset>}"
    echo "  SRC_DIR=${SRC_DIR:-<unset>}"
    echo "  CONDA_BUILD_CROSS_COMPILATION=${CONDA_BUILD_CROSS_COMPILATION:-<unset>}"
    echo "  CC=${CC:-<unset>}"
    echo "  AR=${AR:-<unset>}"
    echo "  AS=${AS:-<unset>}"
    echo "  LD=${LD:-<unset>}"
    echo "  NM=${NM:-<unset>}"
    echo "  RANLIB=${RANLIB:-<unset>}"
    echo "  STRIP=${STRIP:-<unset>}"
    echo "  CFLAGS=${CFLAGS:-<unset>}"
    echo "  LDFLAGS=${LDFLAGS:-<unset>}"
    echo "  --- zig vars ---"
    env | grep -iE "^ZIG|^CONDA_ZIG" | sort | sed 's/^/  /' || true
    echo "  --- all CONDA_ vars ---"
    env | grep -i "^CONDA_" | sort | sed 's/^/  /' || true
    echo "=== END DEBUG ==="
  fi

  # Setup native toolchain variables needed by build_cross_compiler (NATIVE_CC, SAK_*, etc.)
  setup_toolchain "NATIVE" "${CONDA_TOOLCHAIN_BUILD}"
  if is_unix; then
    setup_cflags_ldflags "NATIVE" "${build_platform:-${target_platform}}" "${target_platform}"
  else
    # NATIVE_CC stays as gcc (build-host compiler from setup_toolchain).
    # sak.exe WinMain fix: SAK_BUILD sed in build_cross_compiler() bypasses flexlink.
    export NATIVE_CFLAGS="${NATIVE_CFLAGS:-}"
    export NATIVE_LDFLAGS="${NATIVE_LDFLAGS:-}"
    export CROSS_CFLAGS="${CROSS_CFLAGS:-}"
    export CROSS_LDFLAGS="${CROSS_LDFLAGS:-}"

    # CRITICAL: Normalize Windows backslashes to forward slashes in NATIVE_* path vars.
    # On Windows, setup_toolchain may produce paths like D:\bld\...\zig.exe which bash
    # interprets as escape sequences (D:bldbld...) causing "command not found".
    # This also breaks Make's $(shell ...) calls (e.g. sak.exe for OCAML_STDLIB_DIR).
    for _var in NATIVE_CC NATIVE_AR NATIVE_AS NATIVE_ASM NATIVE_LD NATIVE_NM \
                NATIVE_RANLIB NATIVE_STRIP NATIVE_MKDLL NATIVE_MKEXE; do
      if [[ -n "${!_var:-}" ]]; then
        export "${_var}=${!_var//\\//}"
      fi
    done

    # CRITICAL: Create SAK_CC using -target x86_64-windows-msvc for tools that must
    # run on the build machine during cross-compilation (sak.exe → build_config.h).
    # zig cc -target x86_64-windows-gnu links api-ms-win-crt-*.dll UCRT shims which
    # are not in MSYS2's DLL search path → exit 127 for any zig-gnu binary.
    # The msvc target links only KERNEL32.dll + ntdll.dll → works in MSYS2.
    _zig_exe="${NATIVE_CC%% *}"  # extract zig exe path (before ' cc -target ...')
    # sak.c uses wmain (via main_os macro from caml/misc.h when CAML_INTERNALS + _WIN32).
    # MSVC linker expects main() by default. Zig rejects /entry:wmainCRTStartup.
    # Solution: compile with -DSAK_NEEDS_MAIN_WRAPPER — we prepend a main→wmain shim.
    # Create a wrapper script so SAK_CC_MSVC is a single-token path.
    # Multi-word CC= values get word-split by make (it interprets -target as
    # its own flags: -t -a -r -g -e -t). Wrapper scripts are the established
    # pattern in this build for zig toolchain invocations.
    # Use cygpath on Windows to get a POSIX path - raw $SRC_DIR has Windows
    # backslashes that get eaten during bash expansion (D:\bld\... → D:bld...).
    if command -v cygpath &>/dev/null; then
      _sak_cc_msvc_wrapper="$(cygpath -u "${SRC_DIR}")/sak-cc-msvc"
    else
      _sak_cc_msvc_wrapper="${SRC_DIR}/sak-cc-msvc"
    fi
    cat > "${_sak_cc_msvc_wrapper}" <<'SAKEOF'
#!/bin/bash
exec "@@ZIG_EXE@@" cc -target x86_64-windows-msvc -DSAK_NEEDS_MAIN_WRAPPER "$@"
SAKEOF
    sed -i "s|@@ZIG_EXE@@|${_zig_exe}|g" "${_sak_cc_msvc_wrapper}"
    chmod +x "${_sak_cc_msvc_wrapper}"
    export SAK_CC_MSVC="${_sak_cc_msvc_wrapper}"
    echo "  SAK_CC_MSVC: ${SAK_CC_MSVC} (wrapper for: ${_zig_exe} cc -target x86_64-windows-msvc)"

    # Also create a GNU-target wrapper for SAK_CC used in runtime-all compilation.
    # NATIVE_CC is also multi-word (zig.exe cc -target x86_64-windows-gnu) and
    # gets word-split by make the same way. Runtime needs GNU target for pthread.h.
    if command -v cygpath &>/dev/null; then
      _sak_cc_gnu_wrapper="$(cygpath -u "${SRC_DIR}")/sak-cc-gnu"
    else
      _sak_cc_gnu_wrapper="${SRC_DIR}/sak-cc-gnu"
    fi
    cat > "${_sak_cc_gnu_wrapper}" <<'GNUEOF'
#!/bin/bash
exec "@@ZIG_EXE@@" cc -target x86_64-windows-gnu "$@"
GNUEOF
    sed -i "s|@@ZIG_EXE@@|${_zig_exe}|g" "${_sak_cc_gnu_wrapper}"
    chmod +x "${_sak_cc_gnu_wrapper}"
    export SAK_CC_GNU="${_sak_cc_gnu_wrapper}"
    echo "  SAK_CC_GNU: ${SAK_CC_GNU} (wrapper for: ${_zig_exe} cc -target x86_64-windows-gnu)"
  fi

  # Debug: dump conda-build env vars available on this platform
  if ! is_unix; then
    echo "=== DEBUG: Windows cross-compiler environment POST NATICE toolchain ==="
    echo "  --- all NATIVE_ vars ---"
    env | grep -i "^NATIVE_" | sort | sed 's/^/  /' || true
    echo "=== END DEBUG ==="
  fi

  # Rebuild conda-ocaml-* wrappers in BUILD_PREFIX. The native ocaml dependency's
  # pre-built wrappers may lack multi-word tokenization (e.g., "zig.exe cc -target ...").
  # build_native() rebuilds them, but cross-compiler mode skips build_native().
  if ! is_unix; then
    echo "  Rebuilding conda-ocaml-* wrappers in BUILD_PREFIX (multi-word toolchain support)..."
    CC="${NATIVE_CC}" "${RECIPE_DIR}/building/build-wrappers.sh" "${BUILD_PREFIX}/Library/bin"
  fi

  OCAML_XCROSS_INSTALL_PREFIX="${SRC_DIR}"/_xcross_compiler
  (
    export OCAML_PREFIX="${BUILD_PREFIX}"
    export OCAMLLIB="${OCAML_PREFIX}/lib/ocaml"

    # Debug: check flexlink availability and runtime library state
    echo "=== DEBUG: cross-compiler pre-flight ==="
    echo "  OCAMLLIB=${OCAMLLIB}"
    echo "  flexlink in PATH: $(command -v flexlink 2>/dev/null || echo 'NOT FOUND')"
    echo "  flexlink.exe in PATH: $(command -v flexlink.exe 2>/dev/null || echo 'NOT FOUND')"
    ls -la "${OCAMLLIB}"/libasmrun* 2>/dev/null || echo "  No libasmrun* in OCAMLLIB"
    ls -la "${OCAMLLIB}"/*.lib 2>/dev/null | head -5 || echo "  No .lib files in OCAMLLIB"
    echo "  ocamlopt -version: $(ocamlopt -version 2>/dev/null || echo 'NOT FOUND')"
    echo "  ocamlopt -config (MKEXE): $(ocamlopt -config 2>/dev/null | grep -i mkexe || echo 'NOT FOUND')"
    echo "  PATH entries with Library/bin:"
    echo "$PATH" | tr ':' '\n' | grep -i "library/bin" | head -5 || echo "    (none)"
    echo "=== END DEBUG ==="

    OCAML_INSTALL_PREFIX="${OCAML_XCROSS_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    build_cross_compiler
  )

  # Verify cross-compiler produced output before transferring
  if [[ ! -d "${OCAML_XCROSS_INSTALL_PREFIX}/lib/ocaml-cross-compilers" ]]; then
    echo "WARNING: No cross-compiler output produced for ${OCAML_TARGET_TRIPLET}"
    echo "  This platform combination may not be supported yet."
    echo "  Creating empty package (metapackage only)."
  else
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
  fi  # end of: cross-compiler produced output
fi

# ==============================================================================
# MODE: cross-target
# Build using cross-compiler from BUILD_PREFIX (cross-compiled native)
# ==============================================================================
if [[ "${BUILD_MODE}" == "cross-target" ]]; then
  # Cross-compiler is available in BUILD_PREFIX (from ocaml_$target_platform dependency)
  CROSS_TARGET="${OCAML_TARGET_TRIPLET}"
  CROSS_COMPILER_DIR="${BUILD_PREFIX}/lib/ocaml-cross-compilers/${CROSS_TARGET}"

  echo ""
  echo "=== Cross-target build: Using cross-compiler from BUILD_PREFIX ==="
  echo "  Cross-compiler: ${CROSS_COMPILER_DIR}"

  if [[ ! -f "${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma" ]]; then
    echo "ERROR: Cross-compiler not found at ${CROSS_COMPILER_DIR}"
    echo "The ocaml_${target_platform} package must be installed as a build dependency"
    exit 1
  fi

  OCAML_TARGET_INSTALL_PREFIX="${SRC_DIR}"/_target_compiler
  (
    export OCAML_PREFIX="${BUILD_PREFIX}"
    export CROSS_COMPILER_PREFIX="${BUILD_PREFIX}"
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
      export CONDA_OCAML_AR="${OCAML_TARGET_TRIPLET}-ar"
      export CONDA_OCAML_AS="${OCAML_TARGET_TRIPLET}-as"
      export CONDA_OCAML_CC="${OCAML_TARGET_TRIPLET}-gcc"
      export CONDA_OCAML_LD="${OCAML_TARGET_TRIPLET}-ld"
      export CONDA_OCAML_RANLIB="${OCAML_TARGET_TRIPLET}-ranlib"
      export CONDA_OCAML_MKEXE="${OCAML_TARGET_TRIPLET}-gcc"
      export CONDA_OCAML_MKDLL="${OCAML_TARGET_TRIPLET}-gcc -shared"
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
