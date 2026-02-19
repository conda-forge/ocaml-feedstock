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
source "${RECIPE_DIR}/building/fix-ocamlrun-shebang.sh"

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
echo "  OCAML_TARGET_TRIPLET:                ${OCAML_TARGET_TRIPLET:-<not set>}"
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
  cat > "${SRC_DIR}/_native_compiler_env.sh" << EOF
# Generated by build_native() - do not edit
export NATIVE_AR="${NATIVE_AR}"
export NATIVE_AS="${NATIVE_AS}"
export NATIVE_ASM="${NATIVE_ASM}"
export NATIVE_CC="${NATIVE_CC}"
export NATIVE_CFLAGS="${NATIVE_CFLAGS}"
export NATIVE_LD="${NATIVE_LD}"
export NATIVE_LDFLAGS="${NATIVE_LDFLAGS}"
export NATIVE_RANLIB="${NATIVE_RANLIB}"
export NATIVE_STRIP="${NATIVE_STRIP}"
export NATIVE_INSTALL_PREFIX="${OCAML_INSTALL_PREFIX}"

# CONDA_OCAML_* for runtime
export CONDA_OCAML_AR="${CONDA_OCAML_AR}"
export CONDA_OCAML_AS="${CONDA_OCAML_AS}"
export CONDA_OCAML_CC="${CONDA_OCAML_CC}"
export CONDA_OCAML_LD="${CONDA_OCAML_LD}"
export CONDA_OCAML_RANLIB="${CONDA_OCAML_RANLIB}"
export CONDA_OCAML_MKEXE="${CONDA_OCAML_MKEXE:-}"
export CONDA_OCAML_MKDLL="${CONDA_OCAML_MKDLL:-}"
EOF

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
      --with-target-bindir="${PREFIX}"/bin
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

  # ============================================================================
  # Build
  # ============================================================================

  echo "  [3/4] Compiling native compiler"
  run_logged "world" "${MAKE[@]}" world.opt -j"${CPU_COUNT}" || { cat "${LOG_DIR}/world.log"; exit 1; }

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

  # Clean build-time paths from runtime-launch-info
  # This file contains paths used during compilation - sanitize any build-time leaks
  echo "  - Cleaning build-time paths from runtime-launch-info..."
  local runtime_launch_info="${OCAML_INSTALL_PREFIX}/lib/ocaml/runtime-launch-info"
  clean_runtime_launch_info "${runtime_launch_info}" "${PREFIX}"

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

  # macOS: Use DYLD_FALLBACK_LIBRARY_PATH so native compiler can find libzstd at runtime
  # IMPORTANT: Use FALLBACK, not DYLD_LIBRARY_PATH - FALLBACK doesn't override system libs
  # The native compiler (x86_64) needs BUILD_PREFIX libs, not PREFIX (which has target arch libs)
  # Cross-compilation: PREFIX=ARM64, BUILD_PREFIX=x86_64
  # Native build: PREFIX=x86_64, BUILD_PREFIX=x86_64 (same)
  # Note: fix-macos-install-names.sh unsets DYLD_* before running system tools to avoid iconv issues
  setup_dyld_fallback

  # Define cross targets based on build platform or explicit env vars
  CONFIG_ARGS+=(--with-target-bindir="${PREFIX}"/bin)
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

    # Create toolchain wrappers using CROSS_* variables as defaults
    # Format: tool_name:ENV_SUFFIX:default_value
    for tool_pair in "cc:CC:${CROSS_CC}" "as:AS:${CROSS_ASM}" "ar:AR:${CROSS_AR}" \
                     "ld:LD:${CROSS_LD}" "ranlib:RANLIB:${CROSS_RANLIB}" \
                     "mkexe:MKEXE:${CROSS_MKEXE}" "mkdll:MKDLL:${CROSS_MKDLL}"; do
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
    cat > "${SRC_DIR}/_xcross_compiler_${_ENV_TARGET}_env.sh" << EOF
# Generated by build-cross-compiler.sh - do not edit
export "CROSS_AR=${CROSS_AR}"
export "CROSS_AS=${CROSS_AS}"
export "CROSS_ASM=${CROSS_ASM}"
export "CROSS_CC=${CROSS_CC}"
export "CROSS_CFLAGS=${CROSS_CFLAGS}"
export "CROSS_LD=${CROSS_LD}"
export "CROSS_LDFLAGS=${CROSS_LDFLAGS}"
export "CROSS_RANLIB=${CROSS_RANLIB}"
export "CROSS_MKDLL=${CROSS_MKDLL}"
export "CROSS_MKEXE=${CROSS_MKEXE}"

# CONDA_OCAML_* for runtime (use CROSS_* not CONDA_OCAML_* which may be native)
export "CONDA_OCAML_${TARGET_ID}_AR=${CROSS_AR}"
export "CONDA_OCAML_${TARGET_ID}_AS=${CROSS_ASM}"
export "CONDA_OCAML_${TARGET_ID}_CC=${CROSS_CC}"
export "CONDA_OCAML_${TARGET_ID}_RANLIB=${CROSS_RANLIB}"
export "CONDA_OCAML_${TARGET_ID}_MKDLL=${CROSS_MKDLL}"
export "CONDA_OCAML_${TARGET_ID}_MKEXE=${CROSS_MKEXE}"
EOF

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

    # Per-target configure args (frame pointers not supported on PPC)
    declare -a TARGET_CONFIG_ARGS=()
    case "${CROSS_ARCH}" in
      arm64|amd64)
        TARGET_CONFIG_ARGS+=(--enable-frame-pointers)
        ;;
    esac

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
      -j"${CPU_COUNT}" || { cat "${LOG_DIR}"/runtime-all.log; exit 1; }

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

    # CRITICAL: Clean stdlib .cmi files - they contain arch-specific metadata
    # The .cmi files from runtime-all were built with ARCH=amd64, but crossopt
    # needs ARCH=arm64. Must force complete rebuild for consistency.
    # This prevents "inconsistent assumptions over implementation Stdlib__Sys" errors
    # between stdlib.cmxa and unix.cmxa (different CRC checksums).
    echo "     Cleaning stdlib compiled files to prevent arch inconsistencies..."
    rm -f stdlib/*.cmi stdlib/*.cmo stdlib/*.cma
    rm -f stdlib/*.cmx stdlib/*.cmxa stdlib/*.o stdlib/*.a

    # ========================================================================
    # Build cross-compiler
    # ========================================================================

    echo "  [5/7] Building cross-compiler (crossopt)..."

    (
      # Export CONDA_OCAML_* for cross-compilation (conda-ocaml-* wrappers expand these)
      # - Use CROSS_ASM (includes "-c" for macOS clang) not CROSS_AS
      # - MKEXE stays NATIVE (links x86_64 cross-compiler binary)
      # - OCAMLLIB will be set by Makefile.cross based on LIBDIR
      export CONDA_OCAML_AS="${CROSS_ASM}"
      export CONDA_OCAML_CC="${CROSS_CC}"
      export CONDA_OCAML_AR="${CROSS_AR}"
      export CONDA_OCAML_RANLIB="${CROSS_RANLIB}"
      export CONDA_OCAML_MKDLL="${CROSS_MKDLL}"

      # Ensure cross-tools are findable in PATH
      PATH="${OCAML_PREFIX}/bin:${PATH}"
      hash -r

      # Native compiler stdlib location (for copying fresh .cmi files in crossopt)
      NATIVE_STDLIB="${OCAML_PREFIX}/lib/ocaml"

      # Build arguments
      CROSSOPT_ARGS=(
        ARCH="${CROSS_ARCH}"
        AR="${CROSS_AR}"
        AS="${CROSS_AS}"
        ASPP="${CROSS_CC} -c"
        CAMLOPT=ocamlopt
        CC="${CROSS_CC}"
        CFLAGS="${CROSS_CFLAGS}"
        CROSS_AR="${CROSS_AR}"
        CROSS_CC="${CROSS_CC}"
        CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"
        CROSS_MKEXE="${CROSS_MKEXE}"
        CROSS_MKDLL="${CROSS_MKDLL}"
        LD="${CROSS_LD}"
        LDFLAGS="${CROSS_LDFLAGS}"
        LIBDIR="${OCAML_CROSS_LIBDIR}"
        NM="${CROSS_NM}"
        RANLIB="${CROSS_RANLIB}"
        STRIP="${CROSS_STRIP}"
        ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd"
        TARGET_ZSTD_LIBS="${TARGET_ZSTD_LIBS}"

        SAK_AR="${NATIVE_AR}"
        SAK_CC="${NATIVE_CC}"
        SAK_CFLAGS="${NATIVE_CFLAGS}"
        SAK_LDFLAGS="${NATIVE_LDFLAGS}"

        # NATIVE tools for building BUILD-platform binaries (profiling.cmx, ocamlopt.opt)
        NATIVE_AS="${NATIVE_AS}"
        NATIVE_ASM="${NATIVE_ASM}"  # Includes "-c" for macOS clang
        NATIVE_CC="${NATIVE_CC}"

        # Native compiler stdlib location (for copying fresh .cmi files)
        NATIVE_STDLIB="${NATIVE_STDLIB}"
      )

      run_logged "crossopt" "${MAKE[@]}" crossopt "${CROSSOPT_ARGS[@]}" -j"${CPU_COUNT}" || { cat "${LOG_DIR}"/crossopt.log; exit 1; }
    )

    # ========================================================================
    # Install cross-compiler
    # ========================================================================

    echo "  [6/7] Installing cross-compiler via 'make installcross'..."

    (
      # Use same environment as crossopt
      export CONDA_OCAML_AS="${CROSS_ASM}"
      export CONDA_OCAML_CC="${CROSS_CC}"
      export CONDA_OCAML_AR="${CROSS_AR}"
      export CONDA_OCAML_RANLIB="${CROSS_RANLIB}"
      export CONDA_OCAML_MKDLL="${CROSS_MKDLL}"
      # CONDA_OCAML_MKEXE intentionally NOT set - use native linker

      PATH="${OCAML_PREFIX}/bin:${PATH}"
      hash -r

      INSTALL_ARGS=(
        PREFIX="${OCAML_CROSS_PREFIX}"
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

      # Clean LIBDIR before install to ensure fresh installation
      # This prevents mixing of files from crossopt build with make install
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

    # Clean build-time paths from runtime-launch-info
    echo "  Cleaning build-time paths from runtime-launch-info..."
    clean_runtime_launch_info "${OCAML_CROSS_LIBDIR}/runtime-launch-info" "${PREFIX}"

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

  CONFIG_ARGS+=(--with-target-bindir="${PREFIX}"/bin)
  CROSS_ARCH=$(get_target_arch "${host_alias}")
  CROSS_PLATFORM=$(get_target_platform "${host_alias}")

  # Platform-specific settings
  NEEDS_DL=0
  DISABLE_GETENTROPY=0
  CROSS_MODEL=""
  case "${target_platform}" in
    linux-*)
      PLATFORM_TYPE="linux"
      NEEDS_DL=1
      DISABLE_GETENTROPY=1
      [[ "${target_platform}" == "linux-ppc64le" ]] && CROSS_MODEL="ppc64le"
      ;;
    osx-*)
      PLATFORM_TYPE="macos"
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
  echo "  Platform type:        ${PLATFORM_TYPE}"
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

  if [[ "${DISABLE_GETENTROPY}" == "1" ]]; then
    CONFIG_ARGS+=(ac_cv_func_getentropy=no)
  fi

  # Install conda-ocaml-* wrapper scripts to BUILD_PREFIX (needed during build)
  echo "    Installing conda-ocaml-* wrapper scripts to BUILD_PREFIX..."
  install_conda_ocaml_wrappers "${BUILD_PREFIX}/bin"

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

  # ============================================================================
  # Build crosscompiledopt
  # ============================================================================

  echo "  [3/5] Building crosscompiledopt ==="

  (

    CROSSCOMPILEDOPT_ARGS=(
      ARCH="${CROSS_ARCH}"
      CAMLOPT="${CROSS_OCAMLOPT}"
      CROSS_CC="${CROSS_CC}"
      CROSS_AR="${CROSS_AR}"
      CROSS_MKLIB="${CROSS_OCAMLMKLIB}"
      ZSTD_LIBS="-L${PREFIX}/lib -lzstd"
      LIBDIR="${OCAML_INSTALL_PREFIX}/lib/ocaml"
      OCAMLLIB="${OCAMLLIB}"
      LDFLAGS="${CROSS_LDFLAGS}"

      CONDA_OCAML_AS="${CROSS_ASM}"
      CONDA_OCAML_CC="${CROSS_CC}"
      CONDA_OCAML_MKEXE="${CROSS_MKEXE:-}"
      CONDA_OCAML_MKDLL="${CROSS_MKDLL:-}"

      AS="${CROSS_AS}"
      ASPP="${CROSS_CC} -c"
      CC="${CROSS_CC}"

      SAK_AR="${NATIVE_AR}"
      SAK_CC="${NATIVE_CC}"
      SAK_CFLAGS="${NATIVE_CFLAGS}"
      SAK_LDFLAGS="${NATIVE_LDFLAGS}"
    )

    if [[ "${PLATFORM_TYPE}" == "linux" ]]; then
      CROSSCOMPILEDOPT_ARGS+=(
        CPPFLAGS="-D_DEFAULT_SOURCE"
        # glibc 2.17 (conda-forge sysroot) requires -ldl for dlopen/dlclose/dlsym
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
      ARCH="${CROSS_ARCH}"
      CAMLOPT="${CROSS_OCAMLOPT}"
      AS="${CROSS_AS}"
      ASPP="${CROSS_CC} -c"
      CC="${CROSS_CC}"
      CROSS_CC="${CROSS_CC}"
      CROSS_AR="${CROSS_AR}"
      CROSS_MKLIB="${CROSS_OCAMLMKLIB}"
      CHECKSTACK_CC="${NATIVE_CC}"
      SAK_AR="${NATIVE_AR}"
      SAK_CC="${NATIVE_CC}"
      SAK_CFLAGS="${NATIVE_CFLAGS}"
      ZSTD_LIBS="-L${PREFIX}/lib -lzstd"
      LIBDIR="${OCAML_INSTALL_PREFIX}/lib/ocaml"
      OCAMLLIB="${OCAMLLIB}"
      CONDA_OCAML_AS="${CROSS_ASM}"
      CONDA_OCAML_CC="${CROSS_CC}"
      CONDA_OCAML_MKEXE="${CROSS_MKEXE:-}"
      CONDA_OCAML_MKDLL="${CROSS_MKDLL:-}"
    )

    if [[ "${PLATFORM_TYPE}" == "macos" ]]; then
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

  # Clean build-time paths from runtime-launch-info
  echo "    Cleaning build-time paths from runtime-launch-info..."
  local runtime_launch_info="${OCAML_INSTALL_PREFIX}/lib/ocaml/runtime-launch-info"
  clean_runtime_launch_info "${runtime_launch_info}" "${PREFIX}"

  if [[ "${PLATFORM_TYPE}" == "macos" ]]; then
    echo "    Fixing macOS install names..."

    # Fix stublib overlinking
    for lib in "${OCAML_INSTALL_PREFIX}/lib/ocaml/stublibs/"*.so; do
      [[ -f "$lib" ]] || continue
      for dep in $(otool -L "$lib" 2>/dev/null | grep '\./dll' | awk '{print $1}'); do
        install_name_tool -change "$dep" "@loader_path/$(basename $dep)" "$lib"
      done
    done

    # Set correct install_name for runtime libraries
    for rtlib in libasmrun_shared.so libcamlrun_shared.so; do
      [[ -f "${OCAML_INSTALL_PREFIX}/lib/ocaml/${rtlib}" ]] && \
        install_name_tool -id "@rpath/${rtlib}" "${OCAML_INSTALL_PREFIX}/lib/ocaml/${rtlib}"
    done

    # Fix references in all libraries
    for lib in "${OCAML_INSTALL_PREFIX}/lib/ocaml/"*.so "${OCAML_INSTALL_PREFIX}/lib/ocaml/stublibs/"*.so; do
      [[ -f "$lib" ]] || continue
      install_name_tool -change "runtime/libasmrun_shared.so" "@rpath/libasmrun_shared.so" "$lib" 2>/dev/null || true
      install_name_tool -change "runtime/libcamlrun_shared.so" "@rpath/libcamlrun_shared.so" "$lib" 2>/dev/null || true
    done
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
# build_stages_1_and_2() - Build native OCaml (Stage 1) + cross-compiler (Stage 2)
# Sets OCAML_NATIVE_INSTALL_PREFIX and OCAML_XCROSS_INSTALL_PREFIX in caller scope.
# ==============================================================================
build_stages_1_and_2() {
  # Stage 1: Build native OCaml (needed to bootstrap the cross-compiler)
  OCAML_NATIVE_INSTALL_PREFIX="${SRC_DIR}"/_native_compiler
  (
    OCAML_INSTALL_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    build_native
  )

  # Stage 2: Build cross-compiler for OCAML_TARGET_PLATFORM
  OCAML_XCROSS_INSTALL_PREFIX="${SRC_DIR}"/_xcross_compiler
  (
    export OCAML_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}"
    export OCAMLLIB="${OCAML_PREFIX}"/lib/ocaml

    OCAML_INSTALL_PREFIX="${OCAML_XCROSS_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    source "${SRC_DIR}/_native_compiler_env.sh"
    build_cross_compiler
  )
}

# ==============================================================================
# MODE: native
# Build native OCaml compiler
# ==============================================================================
if [[ "${BUILD_MODE}" == "native" ]]; then
  OCAML_NATIVE_INSTALL_PREFIX="${SRC_DIR}"/_native_compiler
  (
    OCAML_INSTALL_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    build_native
  )

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

fi

# ==============================================================================
# MODE: cross-compiler
# Build cross-compiler (native binaries producing target code)
# ==============================================================================
if [[ "${BUILD_MODE}" == "cross-compiler" ]]; then
  build_stages_1_and_2

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
  done
fi

# ==============================================================================
# MODE: cross-target
# Build using cross-compiler from BUILD_PREFIX (cross-compiled native)
# ==============================================================================
if [[ "${BUILD_MODE}" == "cross-target" ]]; then
  # Determine cross-compiler triplet for this target
  CROSS_TARGET="${OCAML_TARGET_TRIPLET}"

  echo ""
  echo "=== Cross-target build: Using cross-compiler from BUILD_PREFIX ==="
  echo "Looking for cross-compiler: ${CROSS_TARGET}"

  FAST_CROSS_PATH_SUCCESS=0

  # Check if cross-compiler exists (from ocaml build dependency)
  CROSS_COMPILER_DIR="${BUILD_PREFIX}/lib/ocaml-cross-compilers/${CROSS_TARGET}"
  if [[ -d "${CROSS_COMPILER_DIR}" ]]; then
    echo "Found cross-compiler: ${CROSS_COMPILER_DIR}"

    # Verify it has required files
    if [[ -f "${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma" ]]; then
      echo "Cross-compiler stdlib found, attempting Stage 3..."

      # Try Stage 3 - may fail if API changed between versions
      OCAML_TARGET_INSTALL_PREFIX="${SRC_DIR}"/_target_compiler
      set +e
      (
        set -e
        export OCAML_PREFIX="${BUILD_PREFIX}"
        export CROSS_COMPILER_PREFIX="${BUILD_PREFIX}"
        OCAML_INSTALL_PREFIX="${OCAML_TARGET_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
        build_cross_target
      )
      STAGE3_RC=$?
      set -e

      if [[ ${STAGE3_RC} -eq 0 ]]; then
        echo ""
        echo "============================================================"
        echo "Stage 3 cross-compilation succeeded!"
        echo "============================================================"
        FAST_CROSS_PATH_SUCCESS=1
      else
        echo ""
        echo "============================================================"
        echo "Stage 3 failed (exit code ${STAGE3_RC})"
        echo "This usually means API changed between OCaml versions"
        echo "Falling back to full 3-stage build..."
        echo "============================================================"

        # Clean up any partial build artifacts
        make distclean >/dev/null 2>&1 || true
        for var in $(compgen -v | grep -E '^(CONDA_OCAML_|NATIVE_|CROSS_|OCAML_|OCAMLLIB)'); do
          unset "$var"
        done
      fi
    else
      echo "Cross-compiler stdlib not found at ${CROSS_COMPILER_DIR}/lib/ocaml/"
      echo "Cannot use fast path"
    fi
  else
    echo "No cross-compiler found in BUILD_PREFIX"
    echo "Falling back to full 3-stage build"
  fi

  # Fallback: Full 3-stage build
  if [[ ${FAST_CROSS_PATH_SUCCESS} -eq 0 ]]; then
    echo ""
    echo "=== Full 3-stage cross-target build ==="

    build_stages_1_and_2

    # Stage 3: Cross-compile target binaries
    OCAML_TARGET_INSTALL_PREFIX="${SRC_DIR}"/_target_compiler
    (
      export OCAML_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}"
      export CROSS_COMPILER_PREFIX="${OCAML_XCROSS_INSTALL_PREFIX}"

      OCAML_INSTALL_PREFIX="${OCAML_TARGET_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
      source "${SRC_DIR}/_native_compiler_env.sh"
      source "${SRC_DIR}/_xcross_compiler_${OCAML_TARGET_PLATFORM}_env.sh"
      build_cross_target
    )
  fi

  # Transfer to PREFIX
  OCAML_INSTALL_PREFIX="${PREFIX}"
  transfer_to_prefix "${OCAML_TARGET_INSTALL_PREFIX}" "${OCAML_INSTALL_PREFIX}"
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
      # Stage 3 fast path (native mode): use defaults from BUILD_PREFIX toolchain
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
fi

echo ""
echo "============================================================"
echo "Build complete: ${PKG_NAME} (${BUILD_MODE} mode)"
echo "============================================================"

# ==============================================================================
# macOS: Create ocamlmklib wrapper (MUST be after all builds complete)
# ==============================================================================
# This wrapper adds -ldopt "-Wl,-undefined,dynamic_lookup" so downstream packages
# (opam, dune) can build stub libraries without their own workarounds.
# NOTE: This runs AFTER cross-compiler builds because the native ocamlmklib
# is used during cross-compilation and must remain unwrapped until now.
if [[ "${target_platform}" == osx-* ]]; then
  echo ""
  echo "=== Creating macOS ocamlmklib wrapper ==="
  real_ocamlmklib="${PREFIX}/bin/ocamlmklib"
  if [[ -f "${real_ocamlmklib}" ]] && [[ ! -f "${real_ocamlmklib}.real" ]]; then
    mv "${real_ocamlmklib}" "${real_ocamlmklib}.real"
    cat > "${real_ocamlmklib}" << 'WRAPPER_EOF'
#!/bin/bash
# Wrapper to add -undefined dynamic_lookup for macOS shared lib creation
# This allows _caml_* symbols to remain unresolved until runtime
exec "${0}.real" -ldopt "-Wl,-undefined,dynamic_lookup" "$@"
WRAPPER_EOF
    chmod +x "${real_ocamlmklib}"
    echo "  Created wrapper: ocamlmklib -> ocamlmklib.real"
  else
    echo "  Skipped: ocamlmklib wrapper already exists or ocamlmklib not found"
  fi
fi
