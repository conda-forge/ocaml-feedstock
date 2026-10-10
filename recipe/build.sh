#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# OCaml build script, gcc-style multi-output.
#
# The package name indicates the TARGET platform (e.g. ocaml_linux-aarch64);
# the build mode depends on the BUILD platform:
#   native:         OCAML_TARGET_PLATFORM == target_platform
#                   -> build the native compiler
#   cross-compiler: OCAML_TARGET_PLATFORM != target_platform
#                   -> build a cross-compiler (native binaries producing target code)
#   cross-target:   OCAML_TARGET_PLATFORM == target_platform and CONDA_BUILD_CROSS_COMPILATION == 1
#                   -> cross-compile the target compiler using the cross-compiler in BUILD_PREFIX
#
# From recipe.yaml: OCAML_TARGET_PLATFORM (platform the package produces code for),
# OCAML_TARGET_TRIPLET (cross-compiler triplet for that target).

# Re-exec under conda bash 5.2+ instead of the system bash.
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

# conda-build cross-compilation can produce CFLAGS mixing x86 and arm flags
# (-march=nocona ... -march=armv8-a), which aarch64 compilers reject
# ("unknown architecture 'nocona'"). Sanitize before anything uses them.
if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
  _target_arch=$(get_arch_for_sanitization "${target_platform}")
  echo ""
  echo "=== Sanitizing CFLAGS/LDFLAGS for ${_target_arch} ==="
  sanitize_and_export_cross_flags "${_target_arch}"
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

CONFIGURE=(./configure)
MAKE=(make)

# Upstream marshals the non -l part of ZSTD_LIBS into
# compilerlibs/ocamlcommon.cmxa as -ccopt, where relocation NUL-pads the
# prefix-dependent -L it leaves in lib_ccopts (issue #132). Keep only the
# -l flags; ZSTD_LIBS itself stays intact for linking.
COMPRESSED_MARSHALING_OVERRIDE='COMPRESSED_MARSHALING_FLAGS=-cclib -lcomprmarsh $(patsubst %, -cclib %, $(filter -l%,$(ZSTD_LIBS)))'

CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --enable-installing-source-artifacts
  --enable-installing-bytecode-programs
  PKG_CONFIG=false
)

# zstd (marshal compression) is optional, gated by OCAML_HAS_ZSTD (recipe.yaml
# has_zstd; off only for linux-s390x, which has no zstd package). Each build_*
# function copies CONFIG_ARGS, so this reaches every ./configure call.
if [[ "${OCAML_HAS_ZSTD:-1}" == "0" ]]; then
  CONFIG_ARGS+=(--without-zstd)
fi

# xlocale.h was removed in glibc 2.26 (merged into locale.h)
if [[ "$(uname)" == "Linux" ]] && grep -q 'xlocale\.h' runtime/floats.c 2>/dev/null; then
  echo "Patching runtime/floats.c: xlocale.h -> locale.h (glibc 2.26+ compat)"
  sed -i 's/#include <xlocale\.h>/#include <locale.h>/g' runtime/floats.c
fi

# --- build mode detection ---
# OCAML_TARGET_PLATFORM and OCAML_TARGET_TRIPLET come from recipe.yaml's env section.

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

# --- shared helpers ---

# Export CONDA_OCAML_* cross-compilation env and add cross-tools to PATH.
# Used by the crossopt and installcross subshells in build_cross_compiler().
# CONDA_OCAML_MKEXE gets the NATIVE linker: the bytecode tools built in this
# leg (e.g. ocamlc.opt) run on this host. It is exported explicitly because an
# activated build dependency can export its own baked value, which an unset
# var would inherit.
_setup_crossopt_env() {
  export CONDA_OCAML_AS="${CROSS_ASM}"
  export CONDA_OCAML_CC="${CROSS_CC}"
  export CONDA_OCAML_AR="${CROSS_AR}"
  export CONDA_OCAML_RANLIB="${CROSS_RANLIB}"
  export CONDA_OCAML_MKDLL="${CROSS_MKDLL}"
  export CONDA_OCAML_MKEXE="${NATIVE_MKEXE:-}"
  # The cross ocamlopt archives via the shipped <triplet>-ocaml-ar wrapper, which
  # execs ${CONDA_OCAML_<ID>_AR:-<tool name baked at its build time>}. When
  # conda-forge's LLVM pin moves, the baked default (e.g. llvm-ar-19) no longer
  # exists ("exec: llvm-ar-19: not found"), so override it. The wrapper reads the
  # target-specific CONDA_OCAML_<TARGET_ID>_AR, not the generic CONDA_OCAML_AR
  # (see scripts/cross-activate.sh).
  if [[ -n "${TARGET_ID:-}" ]]; then
    export "CONDA_OCAML_${TARGET_ID}_AR=${CROSS_AR##*/}"
    export "CONDA_OCAML_${TARGET_ID}_RANLIB=${CROSS_RANLIB##*/}"
  fi
  PATH="${OCAML_PREFIX}/bin:${PATH}"
  hash -r
}

# Generate _native_compiler_env.sh with basenames for portability.
# Called from build_native(); sourced by the activation-script step when present.
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
# MKEXE/MKDLL contain flags with paths (e.g. -Wl,-rpath,@executable_path/../lib),
# so ##*/ would strip to just "lib"; setup_toolchain already basenames the command.
export CONDA_OCAML_AR="${CONDA_OCAML_AR##*/}"
export CONDA_OCAML_AS="${CONDA_OCAML_AS##*/}"
export CONDA_OCAML_CC="${CONDA_OCAML_CC##*/}"
export CONDA_OCAML_LD="${CONDA_OCAML_LD##*/}"
export CONDA_OCAML_RANLIB="${CONDA_OCAML_RANLIB##*/}"
export CONDA_OCAML_MKEXE="${CONDA_OCAML_MKEXE}"
export CONDA_OCAML_MKDLL="${CONDA_OCAML_MKDLL}"
EOF
}

# Append -DARCH_BIG_ENDIAN=1 to a CFLAGS string when the cross target is
# big-endian (linux-s390x), otherwise echo the string unchanged. Idempotent -
# calling it twice does not duplicate the flag.
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

# Define ARCH_BIG_ENDIAN in an INSTALLED caml/m.h for a big-endian target.
# The build only passes it in CFLAGS, but downstream C stubs read the
# installed header, and without it Tag_val/Is_string use the little-endian
# header layout. Idempotent; fails if the header form is not recognised.
fix_installed_big_endian_header() {
  local _platform="$1" _mh="$2"
  case "${_platform}" in
    linux-s390x) ;;
    *) return 0 ;;
  esac
  [[ -f "${_mh}" ]] || { echo "ERROR: ${_mh} not found"; return 1; }
  grep -q '^#define ARCH_BIG_ENDIAN' "${_mh}" && return 0
  sed -i -e 's|^/\* #undef ARCH_BIG_ENDIAN \*/$|#define ARCH_BIG_ENDIAN 1|' -e 's|^#undef ARCH_BIG_ENDIAN$|#define ARCH_BIG_ENDIAN 1|' "${_mh}"
  grep -q '^#define ARCH_BIG_ENDIAN' "${_mh}" || { echo "ERROR: could not define ARCH_BIG_ENDIAN in ${_mh}"; return 1; }
}

# --- build_native(): native OCaml compiler ---

build_native() {
  local -a CONFIG_ARGS=("${CONFIG_ARGS[@]}")

  : "${OCAML_INSTALL_PREFIX:=${PREFIX}}"

  # Compiler activation should set CONDA_TOOLCHAIN_BUILD
  if [[ -z "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
    if [[ "${OCAML_TARGET_TRIPLET}" == *"-pc-"* ]]; then
      CONDA_TOOLCHAIN_BUILD="no-pc-toolchain"
    elif [[ "${target_platform}" == "win-arm64" ]]; then
      # zig's activation does not export it and the lane is native, so build == target
      CONDA_TOOLCHAIN_BUILD="${OCAML_TARGET_TRIPLET}"
    else
      echo "ERROR: CONDA_TOOLCHAIN_BUILD not set (compiler activation failed?)"
      exit 1
    fi
  fi

  echo ""
  echo "============================================================"
  echo "Native OCaml build configuration"
  echo "============================================================"
  echo "  Platform:      ${target_platform}"
  echo "  Install:       ${OCAML_INSTALL_PREFIX}"

  # Native toolchain as basenames (they get hardcoded in binaries)
  setup_toolchain "NATIVE" "${CONDA_TOOLCHAIN_BUILD}"
  setup_cflags_ldflags "NATIVE" "${build_platform:-${target_platform}}" "${target_platform}"

  # Platform-specific overrides
  if [[ "${target_platform}" == "osx"* ]]; then
    # DYLD_FALLBACK_LIBRARY_PATH (not DYLD_LIBRARY_PATH, which would override
    # system libs) lets OCaml find libzstd at runtime;
    # fix-macos-install-names.sh unsets DYLD_* before running system tools.
    setup_dyld_fallback
  elif [[ "${target_platform}" != "linux"* ]]; then
    [[ ${OCAML_INSTALL_PREFIX} != *"Library"* ]] && OCAML_INSTALL_PREFIX="${OCAML_INSTALL_PREFIX}"/Library
    echo "  Install:       ${OCAML_INSTALL_PREFIX}  <- Non-unix ..."

    if [[ "${OCAML_TARGET_TRIPLET}" != *"-pc-"* ]]; then
      NATIVE_WINDRES=$(find_tool "${CONDA_TOOLCHAIN_BUILD}-windres" false)
      # zig spells its wrappers <triplet>-zig-<tool> and exports no var for windres
      [[ -z "${NATIVE_WINDRES}" ]] && NATIVE_WINDRES=$(find_tool "${CONDA_TOOLCHAIN_BUILD}-zig-windres" true)
      [[ ! -f "${PREFIX}/Library/bin/windres.exe" ]] && cp "${NATIVE_WINDRES}" "${BUILD_PREFIX}/Library/bin/windres.exe"
    else
      NATIVE_WINDRES="rc.exe"
    fi

    export PYTHONUTF8=1
    # find zstd
    if [[ "${OCAML_TARGET_TRIPLET}" == *"-pc-"* ]]; then
      export NATIVE_LDFLAGS="/LIBPATH:${PREFIX}/Library/lib ${NATIVE_LDFLAGS:-}"
    else
      export NATIVE_LDFLAGS="-L${PREFIX}/Library/lib ${NATIVE_LDFLAGS:-}"
    fi
  fi

  print_toolchain_info NATIVE

  # Expanded at runtime by the wrappers; users can override via the environment.
  export CONDA_OCAML_AR=$(basename "${NATIVE_AR}")
  export CONDA_OCAML_CC=$(basename "${NATIVE_CC}")
  export CONDA_OCAML_LD=$(basename "${NATIVE_LD}")
  export CONDA_OCAML_RANLIB=$(basename "${NATIVE_RANLIB:-echo}")
  # already a basename
  export CONDA_OCAML_AS="${NATIVE_ASM}"
  export CONDA_OCAML_MKEXE="${NATIVE_MKEXE}"
  export CONDA_OCAML_MKDLL="${NATIVE_MKDLL}"
  # non-unix: windres for resource compilation
  export CONDA_OCAML_WINDRES="${NATIVE_WINDRES:-windres}"

  generate_native_env_file

  CONFIG_ARGS+=(
    -prefix "${OCAML_INSTALL_PREFIX}"
    --mandir="${OCAML_INSTALL_PREFIX}"/share/man
  )

  CONFIG_ARGS+=(--disable-ocamltest)

  # CFLAGS/LDFLAGS go in as environment variables, not configure args: as args
  # make misparses flags like -O2 as filenames.
  # non-unix: pass bare tool names to configure, not absolute paths. On Windows
  # BUILD_PREFIX carries backslashes that /bin/sh eats as escapes (error 127,
  # "No such file or directory"); basenames resolve via PATH instead. The live
  # vars keep the full path (generate_native_env_file only basenames its output),
  # and unix lanes work with absolute paths, hence the guard.
  if ! is_unix; then
    NATIVE_AR="${NATIVE_AR##*/}"
    NATIVE_AS="${NATIVE_AS##*/}"
    NATIVE_LD="${NATIVE_LD##*/}"
    NATIVE_RANLIB="${NATIVE_RANLIB##*/}"
    # CC/STRIP are mangled the same way (error 127 on .../x86_64-w64-mingw32-gcc.exe)
    NATIVE_CC="${NATIVE_CC##*/}"
    NATIVE_STRIP="${NATIVE_STRIP##*/}"
    export NATIVE_AR NATIVE_AS NATIVE_LD NATIVE_RANLIB NATIVE_CC NATIVE_STRIP
    echo "  non-unix: using bare tool names AR=${NATIVE_AR} AS=${NATIVE_AS} LD=${NATIVE_LD} RANLIB=${NATIVE_RANLIB} CC=${NATIVE_CC} STRIP=${NATIVE_STRIP}"
  fi
  export CC="${NATIVE_CC}"
  export STRIP="${NATIVE_STRIP}"

  if [[ "${OCAML_TARGET_TRIPLET}" == *"-pc-"* ]]; then
    # MSVC: let configure detect the flags (cl.exe uses /O2, /LIBPATH:, not GCC-style).
    export CFLAGS=""
    export LDFLAGS="${NATIVE_LDFLAGS}"
    # Don't pass AS: configure's MSVC default "ml64 -nologo -Cp -c -Fo" needs the
    # trailing -Fo, which is concatenated with the output path.
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
      # --build=cygwin (MSYS2 build env) with an MSVC --host is how OCaml detects
      # MSVC mode and uses /Fe: instead of -o.
      CONFIG_ARGS+=(
        --build=x86_64-pc-cygwin
        --host="${OCAML_TARGET_TRIPLET}"
      )
    fi
    if [[ "${target_platform}" == "win-arm64" ]]; then
      # OCaml has no arm64 Windows native-code backend, so this target is bytecode-only.
      # ocamldoc man-page generation deadlocks under the freshly built runtime, and the
      # package already treats ocamldoc as native-only, so disable it here too.
      CONFIG_ARGS+=(--disable-native-compiler --disable-ocamldoc)
      # configure puts the UNICODE defines only in the internal runtime flags; bake them
      # into ocamlc_cppflags/ocamlopt_cppflags so user C stubs see TCHAR APIs as wide.
      CONFIG_ARGS+=(
        "COMPILER_BYTECODE_CPPFLAGS=-DUNICODE -D_UNICODE"
        "COMPILER_NATIVE_CPPFLAGS=-DUNICODE -D_UNICODE"
      )
    fi
  fi

  # conda-ocaml-* wrappers must exist before the build.
  if is_unix; then
    echo "  Installing conda-ocaml-* wrapper scripts to BUILD_PREFIX..."
    install_conda_ocaml_wrappers "${BUILD_PREFIX}/bin"
  else
    # non-unix: the wrapper .exe files must exist before configure, since
    # config.generated.ml references them
    CC="${NATIVE_CC}" "${RECIPE_DIR}/building/build-wrappers.sh" "${BUILD_PREFIX}/Library/bin"
  fi

  # TARGET_BINDIR/LIBDIR tell OCaml where binaries and libraries live at runtime
  # on the target; conda-forge relocates paths containing ${PREFIX}, not _native ones.
  export TARGET_BINDIR="${PREFIX}/bin"
  export TARGET_LIBDIR="${PREFIX}/lib/ocaml"

  echo ""
  echo "  [1/4] Configuring native compiler"
  run_logged "configure" "${CONFIGURE[@]}" "${CONFIG_ARGS[@]}" -prefix="${OCAML_INSTALL_PREFIX}" || { tail -n 100 config.log; exit 1; }

  # OCaml 5.4.0 leaves CHECKSTACK_CC undefined in the Makefile
  patch_checkstack_cc

  # MSYS2 breaks MSVC tools in Makefile variables in two ways: it converts the
  # /link flag to the filesystem path of link.exe (breaking cl.exe), and bare
  # "link" resolves to MSYS2's coreutils hard-link utility.
  if [[ "${OCAML_TARGET_TRIPLET}" == *"-pc-"* ]]; then
    echo "  Applying MSYS2 workarounds for MSVC toolchain..."
    # MSYS2 converts /flag args to Windows paths when spawning non-MSYS2
    # binaries, mangling /nologo, /link, /out:, etc.
    export MSYS2_ARG_CONV_EXCL='*'
    # MSYS2's /usr/bin/link.exe shadows MSVC's link.exe, which flexlink and
    # OCaml's build call by the bare name "link".
    if [[ -f /usr/bin/link.exe ]]; then
      echo "  Hiding MSYS2 /usr/bin/link.exe (coreutils) to avoid shadowing MSVC link.exe"
      mv /usr/bin/link.exe /usr/bin/link.msys2.exe
    fi
    # configure's MKLIB "link -lib" is MSVC syntax for lib.exe; call lib.exe directly.
    sed -i 's|^MKLIB=link -lib |MKLIB=lib.exe |' Makefile.config
  fi

  echo "  [2/4] Patching config for ocaml-* wrapper scripts"

  local config_file="utils/config.generated.ml"

  if is_unix; then
    # conda-ocaml-* wrappers expand CONDA_OCAML_* at runtime, so tools like Dune
    # (Unix.create_process does not expand shell variables) still honor overrides.
    patch_config_generated_ml_native

    # -config-var reads these from the Config module compiled from
    # config.generated.ml, not Makefile.config, so strip build-time -L here;
    # after world.opt the value is compiled in.
    if [[ "${target_platform}" == "osx"* ]]; then
      local _cfg_ml="utils/config.generated.ml"
      if [[ -f "${_cfg_ml}" ]]; then
        local _cvar
        for _cvar in bytecomp_c_libraries native_c_libraries compression_c_libraries; do
          if grep -q "^let ${_cvar} = " "${_cfg_ml}"; then
            sed -i -E "/^let ${_cvar} = /s#-L[^ \"]+ *##g" "${_cfg_ml}"
          else
            echo "  [config-sanitize] WARNING: ${_cvar} not matched in ${_cfg_ml}"
          fi
        done
      else
        echo "  [config-sanitize] WARNING: ${_cfg_ml} not found"
      fi
    fi
  elif [[ "${OCAML_TARGET_TRIPLET}" == *"-pc-"* ]]; then
    # MSVC: keep configure's defaults, which carry required flags (asm = "ml64
    # -nologo -Cp -c -Fo"); the wrapper mechanism cannot inject flags there.
    echo "    Skipping config.generated.ml patching for MSVC (using configure defaults)"
  else
    # MinGW: needs real conda-ocaml-*.exe wrappers reading CONDA_OCAML_* at
    # runtime; CreateProcess does not expand %VAR% and cannot run .bat files.
    sed -i 's/^let asm = .*/let asm = {|conda-ocaml-as.exe|}/' "$config_file"
    sed -i 's/^let c_compiler = .*/let c_compiler = {|conda-ocaml-cc.exe|}/' "$config_file"
    sed -i 's/^let ar = .*/let ar = {|conda-ocaml-ar.exe|}/' "$config_file"
    sed -i 's/^let ranlib = .*/let ranlib = {|conda-ocaml-ranlib.exe|}/' "$config_file"
    # mkexe/mkdll/mkmaindll stay unwrapped on non-unix: flexlink does the linking.
  fi

  # remove embedded paths from Makefile.config
  patch_makefile_config_post_configure

  if [[ "${target_platform}" == "osx"* ]]; then
    # Cross builds use BUILD_PREFIX (x86_64 libs for the native compiler);
    # native osx-64 uses PREFIX (same arch).
    if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
      _LIB_PREFIX="${BUILD_PREFIX}"
    else
      _LIB_PREFIX="${PREFIX}"
    fi

    local config_file="Makefile.config"

    # OC_LDFLAGS may not exist: append or create
    if grep -q '^OC_LDFLAGS=' "${config_file}"; then
      sed -i "s|^OC_LDFLAGS=\(.*\)|OC_LDFLAGS=\1 -Wl,-L${_LIB_PREFIX}/lib -Wl,-headerpad_max_install_names|" "${config_file}"
    else
      echo "OC_LDFLAGS=-Wl,-L${_LIB_PREFIX}/lib -Wl,-headerpad_max_install_names" >> "${config_file}"
    fi

    sed -i "s|^NATIVECCLINKOPTS=\(.*\)|NATIVECCLINKOPTS=\1 -Wl,-L${_LIB_PREFIX}/lib -Wl,-headerpad_max_install_names|" "${config_file}"
    if [[ "${OCAML_HAS_ZSTD:-1}" == "1" ]]; then
      sed -i "s|^NATIVECCLIBS=\(.*\)|NATIVECCLIBS=\1 -L${_LIB_PREFIX}/lib -lzstd|" "${config_file}"
      # BYTECCLIBS for -output-complete-exe (libcamlrun.a contains zstd.o); a
      # @loader_path rpath survives conda relocation, and the conda-ocaml-mkexe
      # wrapper adds -L${PREFIX}/lib at runtime.
      sed -i "s|^BYTECCLIBS=\(.*\)|BYTECCLIBS=\1 -Wl,-rpath,@loader_path/../lib -lzstd|" "${config_file}"
    fi
  elif [[ "${target_platform}" != "linux"* ]] && [[ "${OCAML_TARGET_TRIPLET}" != *"-pc-"* ]]; then
    local config_file="Makefile.config"

    # non-unix: fix flexlink toolchain detection; the chain follows the target architecture
    local flexdll_chain=mingw64
    [[ "${target_platform}" == "win-arm64" ]] && flexdll_chain=mingw64arm
    sed -i "s/^TOOLCHAIN.*/TOOLCHAIN=${flexdll_chain}/" "$config_file"
    sed -i "s/^FLEXDLL_CHAIN.*/FLEXDLL_CHAIN=${flexdll_chain}/" "$config_file"

    # $(addprefix -link ,$(OC_LDFLAGS)) generates garbage when empty; guard it
    # with $(if $(strip ...)). The $() are escaped to avoid command substitution.
    sed -i 's/\$(addprefix -link ,\$(OC_LDFLAGS))/\$(if \$(strip \$(OC_LDFLAGS)),\$(addprefix -link ,\$(OC_LDFLAGS)),)/g' "$config_file"
    sed -i 's/\$(addprefix -link ,\$(OC_DLL_LDFLAGS))/\$(if \$(strip \$(OC_DLL_LDFLAGS)),\$(addprefix -link ,\$(OC_DLL_LDFLAGS)),)/g' "$config_file"

    # With empty OC_LDFLAGS a trailing "-link" in MKEXE/MKDLL yields
    # "flexlink ... -link -o output", passing -o to the linker; strip it.
    sed -i 's/^\(MK[A-Z]*=.*\)[[:space:]]*-link[[:space:]]*$/\1/' "$config_file"
  fi

  if [[ "${target_platform}" == "win-arm64" ]]; then
    if [[ ! -f "Makefile.config" ]]; then
      echo "  [FIX] ERROR: Makefile.config not found, cannot rewrite library tokens"
    else
      echo "  [FIX] replacing -lsynchronization with -lapi-ms-win-core-synch-l1-2-0 (arm64 has no synchronization.dll) in Makefile.config and config.generated.ml"
      sed -i -e "s/-lsynchronization/-lapi-ms-win-core-synch-l1-2-0/g" "Makefile.config"
      # Config.bytecomp_c_libraries/native_c_libraries are compiled in, keep them equal to Makefile.config
      sed -i -E "/^let (bytecomp|native)_c_libraries/s/-lsynchronization/-lapi-ms-win-core-synch-l1-2-0/g" "utils/config.generated.ml"
    fi
  fi

  # win-arm64: flexlink resolves "-lfoo" only against explicit -L flags on this
  # MINGW64ARM chain, and zig ships no on-disk mingw import libraries (zig cc
  # synthesizes them). BYTECCLIBS/NATIVECCLIBS keep the plain -lfoo tokens because
  # ocamlruns.exe is linked by zig cc directly from them and panics on
  # flexlink-only passthrough options. So build real import libraries from zig's
  # bundled mingw .def files with dlltool and point flexlink at them via -L.
  if [[ "${target_platform}" == "win-arm64" ]]; then
    _imports_search_line=$("${NATIVE_CC}" -print-search-dirs 2>&1 | grep '^libraries:' 2>/dev/null) || true
    _imports_dirlist="${_imports_search_line#libraries:}"
    _imports_dirlist="${_imports_dirlist# }"
    _imports_dirlist="${_imports_dirlist#=}"

    _imports_dirs=()
    IFS=';' read -r -a _imports_raw_dirs <<< "${_imports_dirlist}" || true
    for _imports_raw_dir in "${_imports_raw_dirs[@]+"${_imports_raw_dirs[@]}"}"; do
      _imports_norm_dir="${_imports_raw_dir//\\//}"
      [[ -n "${_imports_norm_dir}" ]] && _imports_dirs+=("${_imports_norm_dir}")
    done

    # def-include sits alongside the enumerated dirs, so probe each dir's
    # sibling too (without duplicates).
    _imports_extra_dirs=()
    for _imports_dir in "${_imports_dirs[@]+"${_imports_dirs[@]}"}"; do
      _imports_candidate="$(dirname "${_imports_dir}")/def-include"
      _imports_seen=0
      for _imports_seen_dir in "${_imports_dirs[@]+"${_imports_dirs[@]}"}" "${_imports_extra_dirs[@]+"${_imports_extra_dirs[@]}"}"; do
        [[ "${_imports_seen_dir}" == "${_imports_candidate}" ]] && _imports_seen=1 && break
      done
      [[ "${_imports_seen}" -eq 0 ]] && _imports_extra_dirs+=("${_imports_candidate}")
    done
    _imports_dirs+=("${_imports_extra_dirs[@]+"${_imports_extra_dirs[@]}"}")

    _imports_dlltool=""
    _imports_dlltool_style=""
    if command -v dlltool >/dev/null 2>&1; then
      _imports_dlltool="$(command -v dlltool)"
      _imports_dlltool_style="binutils"
    elif command -v llvm-dlltool >/dev/null 2>&1; then
      _imports_dlltool="$(command -v llvm-dlltool)"
      _imports_dlltool_style="llvm"
    fi

    _imports_ar=""
    if command -v llvm-ar >/dev/null 2>&1; then
      _imports_ar="$(command -v llvm-ar)"
    elif command -v ar >/dev/null 2>&1; then
      _imports_ar="$(command -v ar)"
    fi

    _imports_nm=""
    if command -v llvm-nm >/dev/null 2>&1; then
      _imports_nm="$(command -v llvm-nm)"
    elif command -v nm >/dev/null 2>&1; then
      _imports_nm="$(command -v nm)"
    fi

    _imports_definc_dir=""
    for _imports_dir in "${_imports_dirs[@]+"${_imports_dirs[@]}"}"; do
      if [[ "$(basename "${_imports_dir}")" == "def-include" && -d "${_imports_dir}" ]]; then
        _imports_definc_dir="${_imports_dir}"
        break
      fi
    done

    _imports_zig_root=""
    if [[ "${#_imports_dirs[@]}" -gt 0 ]]; then
      _imports_zig_root="$(dirname "${_imports_dirs[0]}")"
    fi

    # zig ships parallel mingw dirs, lib-common and libarm64, each with its own
    # copy of every archive. lib-common archives lack the expected symbols on
    # this target, so search libarm64 first and verify every copied archive below.
    _imports_ordered_search_dirs=()
    for _imports_dir in "${_imports_dirs[@]+"${_imports_dirs[@]}"}"; do
      [[ -d "${_imports_dir}" && "${_imports_dir}" == */libarm64 ]] && _imports_ordered_search_dirs+=("${_imports_dir}")
    done
    for _imports_dir in "${_imports_dirs[@]+"${_imports_dirs[@]}"}"; do
      [[ -d "${_imports_dir}" && "${_imports_dir}" == */lib-common ]] && _imports_ordered_search_dirs+=("${_imports_dir}")
    done
    for _imports_dir in "${_imports_dirs[@]+"${_imports_dirs[@]}"}"; do
      if [[ -d "${_imports_dir}" && "${_imports_dir}" != */libarm64 && "${_imports_dir}" != */lib-common ]]; then
        _imports_ordered_search_dirs+=("${_imports_dir}")
      fi
    done

    _imports_stage_dir="${BUILD_PREFIX}/Library/lib/ocaml-arm64-imports"
    _imports_tmp_dir="${_imports_stage_dir}/.tmp"
    _imports_stub_libs=()
    mkdir -p "${_imports_stage_dir}" "${_imports_tmp_dir}" || true
    for _imports_lib in kernel32 ucrtbase ucrt msvcrt user32 advapi32 shell32 ole32 ws2_32 uuid version shlwapi api-ms-win-core-synch-l1-2-0 winpthread pthread gcc_eh wsock32 mingwex api-ms-win-crt-runtime-l1-1-0 api-ms-win-crt-math-l1-1-0; do
      _imports_basenames=("${_imports_lib}.def" "lib${_imports_lib}.def")
      _imports_basenames_in=("${_imports_lib}.def.in" "lib${_imports_lib}.def.in")
      if [[ "${_imports_lib}" == "pthread" || "${_imports_lib}" == "winpthread" ]]; then
        _imports_basenames+=("libwinpthread-1.def" "winpthread.def")
        _imports_basenames_in+=("libwinpthread-1.def.in" "winpthread.def.in")
      fi

      _imports_out="${_imports_stage_dir}/lib${_imports_lib}.a"
      _imports_mechanism=""

      # Priority 1: a prebuilt archive from the zig lib tree beats a generated
      # one (more likely to satisfy flexlink's symbol resolver). Search libarm64
      # before lib-common, then the whole tree as a last resort.
      if [[ -n "${_imports_zig_root}" && -d "${_imports_zig_root}" ]]; then
        _imports_found_archive=""
        set +e
        for _imports_search_dir in "${_imports_ordered_search_dirs[@]+"${_imports_ordered_search_dirs[@]}"}"; do
          _imports_hit=$(find "${_imports_search_dir}" -type f \( -iname "lib${_imports_lib}.a" -o -iname "${_imports_lib}.lib" \) 2>/dev/null | head -1)
          if [[ -n "${_imports_hit}" ]]; then
            _imports_found_archive="${_imports_hit}"
            break
          fi
        done
        if [[ -z "${_imports_found_archive}" ]]; then
          _imports_found_archive=$(find "${_imports_zig_root}" -type f \( -iname "lib${_imports_lib}.a" -o -iname "${_imports_lib}.lib" \) 2>/dev/null | head -1)
        fi
        set -e
        if [[ -n "${_imports_found_archive}" ]]; then
          cp "${_imports_found_archive}" "${_imports_out}" 2>/dev/null || true
          if [[ -f "${_imports_out}" ]]; then
            _imports_mechanism="copied"

            _imports_expected_sym=""
            case "${_imports_lib}" in
              # arm64 ws2_32 import lib does not carry WSAStartup; wsock32 supplies that.
              ws2_32) _imports_expected_sym="WSASocketW" ;;
              kernel32) _imports_expected_sym="CreateFileW" ;;
              user32) _imports_expected_sym="MessageBoxW" ;;
              advapi32) _imports_expected_sym="RegOpenKeyExW" ;;
              shell32) _imports_expected_sym="SHGetKnownFolderPath" ;;
              ole32) _imports_expected_sym="CoCreateInstance" ;;
              shlwapi) _imports_expected_sym="PathFileExistsW" ;;
              version) _imports_expected_sym="GetFileVersionInfoW" ;;
              api-ms-win-core-synch-l1-2-0) _imports_expected_sym="WaitOnAddress" ;;
              winpthread) _imports_expected_sym="pthread_mutex_lock" ;;
              ucrtbase) _imports_expected_sym="malloc" ;;
              ucrt) _imports_expected_sym="malloc" ;;
              msvcrt) _imports_expected_sym="memcpy" ;;
              uuid) _imports_expected_sym="IID_IUnknown" ;;
              wsock32) _imports_expected_sym="WSAStartup" ;;
              # printf is what the yacc link needs from mingwex and shows the
              # archive carries the printf family.
              mingwex) _imports_expected_sym="printf" ;;
              api-ms-win-crt-runtime-l1-1-0) _imports_expected_sym="atexit" ;;
              api-ms-win-crt-math-l1-1-0) _imports_expected_sym="__isnan" ;;
            esac
            if [[ -n "${_imports_nm}" && -n "${_imports_expected_sym}" ]]; then
              set +e
              # import libs carry a bare thunk symbol and an __imp_ data symbol;
              # accept either.
              _imports_verify_hit=$("${_imports_nm}" --defined-only "${_imports_out}" 2>/dev/null | grep -E " (__imp_)?${_imports_expected_sym}\$" 2>/dev/null | head -1)
              set -e
              if [[ -z "${_imports_verify_hit}" ]]; then
                rm -f "${_imports_out}" 2>/dev/null || true
                _imports_mechanism=""
              fi
            fi
          fi
        fi
      fi

      # Priority 2/3: generate from a .def or preprocessed .def.in when no
      # real archive was found.
      if [[ -z "${_imports_mechanism}" ]]; then
        _imports_def=""
        _imports_def_mechanism=""
        for _imports_basename in "${_imports_basenames[@]}"; do
          for _imports_dir in "${_imports_ordered_search_dirs[@]+"${_imports_ordered_search_dirs[@]}"}"; do
            if [[ -f "${_imports_dir}/${_imports_basename}" ]]; then
              _imports_def="${_imports_dir}/${_imports_basename}"
              _imports_def_mechanism="def"
              break 2
            fi
          done
        done

        # mingw ships several import libs only as .def.in templates that need
        # the C preprocessor; same libarm64-first order as above.
        if [[ -z "${_imports_def}" ]]; then
          _imports_def_in=""
          for _imports_basename in "${_imports_basenames_in[@]}"; do
            for _imports_dir in "${_imports_ordered_search_dirs[@]+"${_imports_ordered_search_dirs[@]}"}"; do
              if [[ -f "${_imports_dir}/${_imports_basename}" ]]; then
                _imports_def_in="${_imports_dir}/${_imports_basename}"
                break 2
              fi
            done
          done
          if [[ -n "${_imports_def_in}" ]]; then
            _imports_pp_out="${_imports_tmp_dir}/${_imports_lib}.def"
            set +e
            "${NATIVE_CC}" -E -x c -P -I "${_imports_definc_dir:-$(dirname "${_imports_def_in}")}" "${_imports_def_in}" -o "${_imports_pp_out}" >/dev/null 2>&1
            _imports_pp_rc=$?
            set -e
            if [[ "${_imports_pp_rc}" -eq 0 && -f "${_imports_pp_out}" ]]; then
              _imports_def="${_imports_pp_out}"
              _imports_def_mechanism="def.in"
            fi
          fi
        fi

        if [[ -n "${_imports_def}" && -n "${_imports_dlltool}" ]]; then
          # arm64 windows has no stdcall @N decoration, but these .def files use
          # i386 spelling (WSASocketW@24). Strip a trailing @<digits> so the
          # archive defines the undecorated name flexlink asks for; DATA/alias
          # lines do not end in @N and are untouched.
          _imports_def_sanitized="${_imports_tmp_dir}/${_imports_lib}.undecorated.def"
          sed 's/@[0-9][0-9]*[[:space:]]*$//' "${_imports_def}" > "${_imports_def_sanitized}" 2>/dev/null || cp "${_imports_def}" "${_imports_def_sanitized}"
          set +e
          if [[ "${_imports_dlltool_style}" == "llvm" ]]; then
            "${_imports_dlltool}" -m arm64 -d "${_imports_def_sanitized}" -l "${_imports_out}" -D "${_imports_lib}.dll" >/dev/null 2>&1
          else
            "${_imports_dlltool}" --machine arm64 --def "${_imports_def_sanitized}" --output-lib "${_imports_out}" --dllname "${_imports_lib}.dll" >/dev/null 2>&1
          fi
          set -e
          if [[ -f "${_imports_out}" ]]; then
            _imports_mechanism="${_imports_def_mechanism}"
          fi
        fi
      fi

      # Priority 4: uuid is libsrc/uuid.c in mingw (GUID constants), not a DLL import.
      if [[ -z "${_imports_mechanism}" && "${_imports_lib}" == "uuid" && -n "${_imports_zig_root}" && -d "${_imports_zig_root}" && -n "${_imports_ar}" ]]; then
        _imports_uuid_src=""
        set +e
        _imports_uuid_src=$(find "${_imports_zig_root}" -type f -iname "uuid.c" 2>/dev/null | head -1)
        set -e
        if [[ -n "${_imports_uuid_src}" ]]; then
          _imports_uuid_obj="${_imports_tmp_dir}/uuid.o"
          set +e
          "${NATIVE_CC}" -c "${_imports_uuid_src}" -o "${_imports_uuid_obj}" >/dev/null 2>&1
          _imports_cc_rc=$?
          set -e
          if [[ "${_imports_cc_rc}" -eq 0 && -f "${_imports_uuid_obj}" ]]; then
            set +e
            "${_imports_ar}" rcs "${_imports_out}" "${_imports_uuid_obj}" >/dev/null 2>&1
            set -e
            if [[ -f "${_imports_out}" ]]; then
              _imports_mechanism="compiled"
            fi
          fi
        fi
      fi

      # Priority 5: an empty stub archive so flexlink can resolve the token.
      # zig-cc supplies its own runtime and pthread support at the real link;
      # if that is wrong, the real link fails with undefined symbols.
      if [[ -z "${_imports_mechanism}" ]]; then
        if [[ -n "${_imports_ar}" ]]; then
          set +e
          "${_imports_ar}" rcs "${_imports_out}" >/dev/null 2>&1
          set -e
          if [[ -f "${_imports_out}" ]]; then
            _imports_mechanism="stub"
            _imports_stub_libs+=("${_imports_lib}")
          fi
        fi
      fi

    done

    # mingw's plain libpthread.a is a small forwarding stub with no bodies; if
    # that landed in staging, replace it with libwinpthread.a.
    _imports_winpthread_out="${_imports_stage_dir}/libwinpthread.a"
    _imports_pthread_out="${_imports_stage_dir}/libpthread.a"
    _imports_mingwex_out="${_imports_stage_dir}/libmingwex.a"
    if [[ -f "${_imports_winpthread_out}" ]]; then
      _imports_pthread_size=0
      if [[ -f "${_imports_pthread_out}" ]]; then
        _imports_pthread_size=$(wc -c < "${_imports_pthread_out}" 2>/dev/null) || true
      fi
      if [[ "${_imports_pthread_size:-0}" -lt 8192 ]]; then
        cp "${_imports_winpthread_out}" "${_imports_pthread_out}" 2>/dev/null || true
      fi
    fi

    # Strip the mingw CRT startup shims and the fpreset member from the staged
    # pthread and mingwex archives: crt[u]exe[win].obj define wmain and call
    # wWinMain (not provided here), and fpreset_arm64.obj duplicates fpreset and
    # _fpreset from ucrtbase, so each would collide at link time.
    if [[ -n "${_imports_ar}" ]]; then
      for _imports_crt_archive in "${_imports_winpthread_out}" "${_imports_pthread_out}" "${_imports_mingwex_out}"; do
        [[ -f "${_imports_crt_archive}" ]] || continue
        _imports_crt_shims=$("${_imports_ar}" t "${_imports_crt_archive}" 2>/dev/null | grep -E '(^|[\\/])(crtexewin|ucrtexewin|crtexe|ucrtexe|fpreset_arm64)\.obj$') || true
        if [[ -n "${_imports_crt_shims}" ]]; then
          while IFS= read -r _imports_crt_shim; do
            [[ -z "${_imports_crt_shim}" ]] && continue
            "${_imports_ar}" d "${_imports_crt_archive}" "${_imports_crt_shim}" 2>/dev/null || true
          done <<< "${_imports_crt_shims}"
        fi
      done
    fi

    # zig's own compiler-rt/builtins carries __chkstk, the stack protector and
    # the ubsan handlers, which a plain mingw import lib lacks; search the whole
    # zig lib tree.
    _imports_builtins_found=""
    if [[ -n "${_imports_zig_root}" && -d "${_imports_zig_root}" ]]; then
      set +e
      for _imports_builtins_pattern in "libclang_rt.builtins-aarch64*.a" "libclang_rt.builtins*.a" "libcompiler_rt*.a" "libbuiltins*.a"; do
        _imports_builtins_found=$(find "${_imports_zig_root}" -type f -iname "${_imports_builtins_pattern}" 2>/dev/null | head -1)
        [[ -n "${_imports_builtins_found}" ]] && break
      done
      set -e
    fi
    _imports_builtins_libflag=""
    if [[ -n "${_imports_builtins_found}" ]]; then
      _imports_builtins_base="$(basename "${_imports_builtins_found}")"
      _imports_builtins_out="${_imports_stage_dir}/${_imports_builtins_base}"
      cp "${_imports_builtins_found}" "${_imports_builtins_out}" 2>/dev/null || true
      if [[ -f "${_imports_builtins_out}" ]]; then
        _imports_builtins_libflag="${_imports_builtins_base#lib}"
        _imports_builtins_libflag="${_imports_builtins_libflag%.a}"
      fi
    fi

    # zig's arm64 mingw runtime lacks the __isnan family and the pthread
    # spinlock entry points that libwinpthread's members (rwlock.obj,
    # thread.obj, cond.obj) call; supply them from a small compiled archive.
    _imports_compat_src="${_imports_tmp_dir}/conda_arm64_compat.c"
    _imports_compat_obj="${_imports_tmp_dir}/conda_arm64_compat.o"
    _imports_compat_out="${_imports_stage_dir}/libconda_arm64_compat.a"
    cat > "${_imports_compat_src}" << 'C_EOF'
/* zig's arm64 mingw runtime ships neither the __isnan family nor the
   pthread spinlock entry points that libwinpthread's own members call. */

typedef void *pthread_spinlock_t;

int __isnan(double x);
int __isnanf(float x);
int __isnanl(long double x);
int pthread_spin_lock(pthread_spinlock_t *lock);
int pthread_spin_unlock(pthread_spinlock_t *lock);
int pthread_spin_destroy(pthread_spinlock_t *lock);

/* the mingw member that defines fpreset is stripped out of the pthread
   archives to avoid a duplicate definition, and ucrtbase exports only the
   undecorated name, so the underscored alias libpthread.a still calls is
   forwarded here. */
void fpreset(void);
void _fpreset(void) { fpreset(); }

int __isnan(double x) { return x != x; }
int __isnanf(float x) { return x != x; }
int __isnanl(long double x) { return x != x; }

/* winpthreads convention: -1 (PTHREAD_SPINLOCK_INITIALIZER) is unlocked and 0 is locked. */
int pthread_spin_lock(pthread_spinlock_t *lock)
{
  volatile __UINTPTR_TYPE__ *p = (volatile __UINTPTR_TYPE__ *)lock;
  while (__atomic_exchange_n(p, (__UINTPTR_TYPE__)0, __ATOMIC_ACQUIRE) == 0) {
    while (__atomic_load_n(p, __ATOMIC_RELAXED) == 0) { }
  }
  return 0;
}

int pthread_spin_unlock(pthread_spinlock_t *lock)
{
  __atomic_store_n((volatile __UINTPTR_TYPE__ *)lock,
                   (__UINTPTR_TYPE__)-1, __ATOMIC_RELEASE);
  return 0;
}

int pthread_spin_destroy(pthread_spinlock_t *lock)
{
  (void)lock;
  return 0;
}
C_EOF
    # __chkstk with compiler-rt semantics: flexlink resolves symbols only from
    # the archives it is given. A separate archive member, so it is pulled only
    # when __chkstk is undefined.
    _imports_chkstk_src="${_imports_tmp_dir}/conda_arm64_chkstk.c"
    _imports_chkstk_obj="${_imports_tmp_dir}/conda_arm64_chkstk.o"
    cat > "${_imports_chkstk_src}" << 'C_EOF'
/* compiler-rt semantics: x15 = allocation size / 16; probe each 4096-byte
   page below sp without moving sp; clobbers only x16 and x17. */
__asm__(".text\n.balign 4\n.globl __chkstk\n__chkstk:\n  lsl x16, x15, #4\n  mov x17, sp\n1:\n  sub x17, x17, #4096\n  subs x16, x16, #4096\n  ldr xzr, [x17]\n  b.gt 1b\n  ret\n");
C_EOF
    if [[ -n "${_imports_ar}" ]]; then
      set +e
      "${NATIVE_CC}" -c -fno-sanitize=undefined -fno-stack-protector -mno-stack-arg-probe "${_imports_compat_src}" -o "${_imports_compat_obj}" >/dev/null 2>&1
      _imports_compat_cc_rc=$?
      "${NATIVE_CC}" -c -fno-sanitize=undefined -fno-stack-protector -mno-stack-arg-probe "${_imports_chkstk_src}" -o "${_imports_chkstk_obj}" >/dev/null 2>&1
      _imports_chkstk_cc_rc=$?
      set -e
      if [[ "${_imports_compat_cc_rc}" -eq 0 && -f "${_imports_compat_obj}" && "${_imports_chkstk_cc_rc}" -eq 0 && -f "${_imports_chkstk_obj}" ]]; then
        set +e
        "${_imports_ar}" rcs "${_imports_compat_out}" "${_imports_compat_obj}" "${_imports_chkstk_obj}" >/dev/null 2>&1
        set -e
      fi
    fi

    _imports_extra_libflags=""
    # ucrtbase is the C runtime zig's arm64 mingw target links against; msvcrt
    # is the legacy alternative and the two are never linked together, so
    # exactly one stays in the -l list (ucrtbase; msvcrt is excluded below).
    for _imports_deflib in kernel32 ucrtbase msvcrt ucrt user32 advapi32 shell32 ole32 shlwapi version api-ms-win-core-synch-l1-2-0 uuid ws2_32 winpthread wsock32 mingwex api-ms-win-crt-runtime-l1-1-0 api-ms-win-crt-math-l1-1-0; do
      _imports_deflib_is_stub=0
      for _imports_stub_check in "${_imports_stub_libs[@]+"${_imports_stub_libs[@]}"}"; do
        if [[ "${_imports_stub_check}" == "${_imports_deflib}" ]]; then
          _imports_deflib_is_stub=1
          break
        fi
      done
      [[ "${_imports_deflib_is_stub}" -eq 1 ]] && continue
      # OCaml MKEXE already passes -lpthread, and staged libpthread.a is a
      # byte-identical copy of libwinpthread.a
      [[ "${_imports_deflib}" == "winpthread" ]] && continue
      [[ "${_imports_deflib}" == "msvcrt" ]] && continue
      if [[ -f "${_imports_stage_dir}/lib${_imports_deflib}.a" ]]; then
        _imports_extra_libflags="${_imports_extra_libflags:+${_imports_extra_libflags} }-l${_imports_deflib}"
      fi
    done
    if [[ -n "${_imports_builtins_libflag}" ]]; then
      _imports_extra_libflags="${_imports_extra_libflags:+${_imports_extra_libflags} }-l${_imports_builtins_libflag}"
    fi
    if [[ -f "${_imports_stage_dir}/libconda_arm64_compat.a" ]]; then
      _imports_extra_libflags="${_imports_extra_libflags:+${_imports_extra_libflags} }-lconda_arm64_compat"
    fi

    if [[ -n "${_imports_extra_libflags}" ]]; then
      export FLEXLINKFLAGS="${FLEXLINKFLAGS:+${FLEXLINKFLAGS} }-L${_imports_stage_dir}${_imports_extra_libflags:+ ${_imports_extra_libflags}}"
      echo "  [FIX] FLEXLINKFLAGS now: ${FLEXLINKFLAGS}"
      # Install step ships these archives and activate.bat reuses the -l list.
      printf '%s\n' "${_imports_extra_libflags}" > "${SRC_DIR}/_win_arm64_flexlink_libs.txt"
    fi
  fi

  # win-arm64: zig ships no compiler_rt archive to satisfy __ubsan_handle_* and
  # __stack_chk_fail/__stack_chk_guard at link time, so disable UB sanitizing
  # and the stack protector. Large-frame stack probing stays on because
  # libconda_arm64_compat.a provides __chkstk for flexlink links.
  if [[ "${target_platform}" == "win-arm64" ]]; then
    if [[ -f "Makefile.config" ]]; then
      sed -i -E 's/^(CFLAGS=.*)$/\1 -fno-sanitize=undefined -fno-stack-protector/' "Makefile.config"
      sed -i -E 's/^(OC_CFLAGS=.*)$/\1 -fno-sanitize=undefined -fno-stack-protector/' "Makefile.config"
    else
      echo "  [FIX] ERROR: Makefile.config not found, cannot append -fno-sanitize=undefined -fno-stack-protector"
    fi
  fi

  # win-arm64: zig resolves the GNU form -l:libpthread.a (baked into
  # Makefile.config by configure) only against explicit -L directories, never
  # its builtin mingw sysroot, so the first bytecode link fails. Replace it with
  # whichever of -lpthread / -lwinpthread links; if neither does, warn and leave
  # Makefile.config unchanged.
  if [[ "${target_platform}" == "win-arm64" ]]; then
    if [[ -f "Makefile.config" ]]; then
      IFS=' ' read -r -a _pthread_cflags <<< "${NATIVE_CFLAGS:-}"
      IFS=' ' read -r -a _pthread_ldflags <<< "${NATIVE_LDFLAGS:-}"
      _pthread_src="${LOG_DIR}/pthread_link_test.c"
      printf 'int main(void) { return 0; }\n' > "${_pthread_src}" || true
      _pthread_replacement=""
      for _pthread_candidate in -lpthread -lwinpthread; do
        _pthread_log="${LOG_DIR}/pthread_link_test${_pthread_candidate}.log"
        set +e
        "${NATIVE_CC}" "${_pthread_cflags[@]+"${_pthread_cflags[@]}"}" "${_pthread_src}" "${_pthread_candidate}" -o "${LOG_DIR}/pthread_link_test.exe" "${_pthread_ldflags[@]+"${_pthread_ldflags[@]}"}" > "${_pthread_log}" 2>&1
        _pthread_rc=$?
        set -e
        if [[ ${_pthread_rc} -eq 0 ]]; then
          _pthread_replacement="${_pthread_candidate}"
          break
        fi
      done
      if [[ -z "${_pthread_replacement}" ]]; then
        echo "  [FIX] WARNING: neither -lpthread nor -lwinpthread linked cleanly; leaving -l:libpthread.a in Makefile.config unchanged"
      else
        echo "  [FIX] replacing -l:libpthread.a with ${_pthread_replacement} in Makefile.config and config.generated.ml"
        sed -i "s/-l:libpthread\.a/${_pthread_replacement}/g" "Makefile.config"
        sed -i -E "/^let (bytecomp|native)_c_libraries/s/-l:libpthread\.a/${_pthread_replacement}/g" "utils/config.generated.ml"
      fi
    else
      echo "  [FIX] ERROR: Makefile.config not found, cannot replace -l:libpthread.a"
    fi
  fi

  # The build-time -L to the host prefix must not be compiled into the installed compiler.
  if [[ "${target_platform}" == "win-arm64" ]]; then
    _cfg_ml="utils/config.generated.ml"
    _cfg_link_vars=(mkexe mkdll mkmaindll bytecomp_c_libraries native_c_libraries compression_c_libraries)
    for _cvar in "${_cfg_link_vars[@]}"; do
      # flexlink passes "-link <opt>" to the C linker; drop the pair, or a dangling -link swallows the next argument
      sed -i -E "/^let ${_cvar} = /s#(-link +)?-L[^ |\"]+ *##g" "${_cfg_ml}"
    done
  fi

  if [[ "${target_platform}" == "win-arm64" ]]; then
    # configured with --disable-native-compiler, so world.opt has nothing to build
    echo "  [3/4] Compiling bytecode compiler"
    # This lane hangs rather than failing, and run_logged surfaces output only
    # once make returns; bound the call with timeout so a hang is diagnosable.
    _world_timeout="${OCAML_WORLD_TIMEOUT_S:-1500}"
    _world_start=$(date +%s)
    if run_logged "world" timeout --preserve-status -k 120 "${_world_timeout}s" "${MAKE[@]}" world "${COMPRESSED_MARSHALING_OVERRIDE}" -j"${CPU_COUNT}"; then
      :
    else
      _world_rc=$?
      _world_elapsed=$(( $(date +%s) - _world_start ))
      if (( _world_elapsed >= _world_timeout - 5 )); then
        echo "  [DIAG world] make world TIMED OUT after ${_world_timeout}s"
      else
        echo "  [DIAG world] make world failed with status ${_world_rc}"
      fi
      return ${_world_rc}
    fi
  else
    echo "  [3/4] Compiling native compiler"
    run_logged "world" "${MAKE[@]}" world.opt "${COMPRESSED_MARSHALING_OVERRIDE}" -j"${CPU_COUNT}"
  fi

  echo "  [4/4] Installing native compiler"

  # INSTALLING=1 and VPATH= avoid stale-file issues if Makefile.cross is included
  run_logged "install" "${MAKE[@]}" install INSTALLING=1 VPATH=

  # Ship the flexlink import libraries so ocamlc -custom / -output-complete-exe
  # can resolve -lws2_32 etc. outside the build environment
  if [[ "${target_platform}" == "win-arm64" && -f "${SRC_DIR}/_win_arm64_flexlink_libs.txt" ]]; then
    _flexdll_dest="${OCAML_INSTALL_PREFIX}/lib/ocaml/flexdll"
    mkdir -p "${_flexdll_dest}"
    IFS=' ' read -r -a _flexlink_libs <<< "$(cat "${SRC_DIR}/_win_arm64_flexlink_libs.txt")"
    for _flexlink_lib in "${_flexlink_libs[@]}"; do
      cp "${_imports_stage_dir}/lib${_flexlink_lib#-l}.a" "${_flexdll_dest}/"
    done
    # flexlink resolves c_libraries from this directory at -custom /
    # -output-complete-exe link time
    _cl_cfg="${SRC_DIR}/utils/config.generated.ml"
    _cl_line=""
    if [[ -f "${_cl_cfg}" ]]; then
      _cl_line="$(sed -n -E 's/^let (bytecomp|native)_c_libraries = \{\|(.*)\|\}.*/\2/p' "${_cl_cfg}" || true)"
    else
      echo "  WARNING: ${_cl_cfg} not found, c_libraries not shipped"
    fi
    [[ -n "${_cl_line}" ]] || echo "  WARNING: no c_libraries found in ${_cl_cfg}"
    _cl_shipped=""
    # The script runs with IFS=$'\n\t', so split the space-separated list explicitly
    IFS=' ' read -r -a _cl_toks <<< "$(printf '%s' "${_cl_line}" | tr '\n' ' ')"
    for _cl_tok in ${_cl_toks[@]+"${_cl_toks[@]}"}; do
      [[ "${_cl_tok}" == -l?* && "${_cl_tok}" != -l:* ]] || continue
      _cl_name="${_cl_tok#-l}"
      [[ -f "${_flexdll_dest}/lib${_cl_name}.a" ]] && continue
      if [[ -f "${_imports_stage_dir}/lib${_cl_name}.a" ]]; then
        cp "${_imports_stage_dir}/lib${_cl_name}.a" "${_flexdll_dest}/"
        _cl_shipped="${_cl_shipped} lib${_cl_name}.a"
      else
        echo "  WARNING: ${_imports_stage_dir}/lib${_cl_name}.a not found, not shipped"
      fi
    done
    echo "  - Shipped c_libraries archives to ${_flexdll_dest}:${_cl_shipped:- none}"
  fi

  # The build added -L${BUILD_PREFIX}/lib / -L${PREFIX}/lib to find zstd; those
  # absolute paths won't exist at runtime.
  echo "  - Cleaning hardcoded -L paths from installed Makefile.config..."
  local installed_config="${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config"
  clean_makefile_config "${installed_config}" "${PREFIX}"

  # runtime-launch-info is cleaned after transfer_to_prefix; cleaning here would
  # corrupt it when this build is an intermediate stage.

  # OCaml embeds @rpath/libzstd.1.dylib; BYTECCLIBS should already set the rpath,
  # so only add it if missing.
  if [[ "${target_platform}" == "osx"* ]]; then
    echo "  - Verifying rpath for macOS binaries..."
    verify_macos_rpath "${OCAML_INSTALL_PREFIX}/bin" "@loader_path/../lib"

    # Fix install_names to silence rattler-build overlinking warnings; only
    # packaged output needs it, not temporary build tools.
    if [[ "${OCAML_INSTALL_PREFIX}" == "${PREFIX}" ]]; then
      bash "${RECIPE_DIR}/building/fix-macos-install-names.sh" "${OCAML_INSTALL_PREFIX}/lib/ocaml"
    else
      echo "  - Skipping install_name fixes (build tool, not packaged)"
    fi
  fi

  # conda-ocaml-* wrappers expand CONDA_OCAML_* for tools like Dune
  if is_unix; then
    echo "  - Installing conda-ocaml-* wrapper scripts..."
    install_conda_ocaml_wrappers "${OCAML_INSTALL_PREFIX}/bin"
  else
    # non-unix: small C programs reading CONDA_OCAML_* at runtime
    CC="${NATIVE_CC}" "${RECIPE_DIR}/building/build-wrappers.sh" "${OCAML_INSTALL_PREFIX}/bin"
  fi

  # Clean up for later cross-compiler builds. distclean uses xargs, which fails
  # on Windows when the environment exceeds 32KB, so run with a minimal one.
  run_logged "distclean" env -i PATH="$PATH" SYSTEMROOT="${SYSTEMROOT:-}" "${MAKE[@]}" distclean || true

  echo ""
  echo "============================================================"
  echo "Native OCaml installed successfully"
  echo "============================================================"
  echo "  Location: ${OCAML_INSTALL_PREFIX}"
  echo "  Version:  $(${OCAML_INSTALL_PREFIX}/bin/ocamlopt -version 2>/dev/null || echo 'N/A')"
}

# --- build_cross_compiler(): native binaries producing target code ---

build_cross_compiler() {
  local -a CONFIG_ARGS=("${CONFIG_ARGS[@]}")

  # Sanitize CFLAGS unconditionally: cross-compilers fail on x86-specific flags
  # (see the top-level sanitization block).
  sanitize_and_export_cross_flags "$(get_arch_for_sanitization "${OCAML_TARGET_TRIPLET:-${target_platform}}")"

  if [[ "${target_platform}" != "linux"* ]] && [[ "${target_platform}" != "osx"* ]]; then
    echo "No cross-compiler recipe for ${target_platform} ... yet"
    return 0
  fi

  # OCAML_PREFIX = where native OCaml is installed (source for native tools)
  # OCAML_INSTALL_PREFIX = where cross-compilers will be installed (destination)
  : "${OCAML_PREFIX:=${PREFIX}}"
  : "${OCAML_INSTALL_PREFIX:=${PREFIX}}"
  # Where the cross-compiler finally lives; baked into config.ml's
  # standard_library_default and the cross Makefile.config. ${PREFIX} when the
  # staged tree is transferred there; a caller consuming the tree in place can
  # point it at the staging prefix.
  : "${OCAML_CROSS_FINAL_PREFIX:=${PREFIX}}"

  # DYLD_FALLBACK_LIBRARY_PATH (not DYLD_LIBRARY_PATH, which would override
  # system libs) lets the x86_64 native compiler find libzstd in BUILD_PREFIX
  # rather than the target-arch PREFIX; fix-macos-install-names.sh unsets DYLD_*
  # before running system tools to avoid iconv issues.
  setup_dyld_fallback

  echo "  Using explicit OCAML_TARGET_TRIPLET: ${OCAML_TARGET_TRIPLET}"

  echo ""
  echo "============================================================"
  echo "Cross-compiler build configuration"
  echo "============================================================"
  echo "  Native OCaml (source):    ${OCAML_PREFIX}"
  echo "  Cross install (dest):     ${OCAML_INSTALL_PREFIX}"
  echo "  Native ocamlopt:          ${OCAML_PREFIX}/bin/ocamlopt"

  # configure checks that the installed OCaml compiler can build the cross
  # compiler, so native OCaml must be on PATH.
  PATH="${OCAML_PREFIX}/bin:${PATH}"
  hash -r
  echo "  PATH updated to include: ${OCAML_PREFIX}/bin"

  target="${OCAML_TARGET_TRIPLET}"
    echo ""
    echo "  ------------------------------------------------------------"
    echo "  Building cross-compiler for ${target}"
    echo "  ------------------------------------------------------------"

    CROSS_ARCH=$(get_target_arch "${target}")
    CROSS_PLATFORM=$(get_target_platform "${target}")

    # PowerPC model override
    CROSS_MODEL=""
    [[ "${target}" == "powerpc64le-"* ]] && CROSS_MODEL="ppc64le"

    # The macOS ARM64 SDK must be set up before setup_cflags_ldflags
    if [[ "${target}" == "arm64-apple-darwin"* ]]; then
      echo "  Setting up macOS ARM64 SDK for cross-compilation..."
      setup_macos_sysroot "${target}"
      # Override both: conda-forge points CONDA_BUILD_SYSROOT at the x86_64 SDK,
      # and the cross-compiler clang uses it for library lookup, so lld finds
      # the wrong SDK even with -syslibroot flags.
      export SDKROOT="${ARM64_SYSROOT}"
      export CONDA_BUILD_SYSROOT="${ARM64_SYSROOT}"
      echo "  SDKROOT exported: ${SDKROOT}"
      echo "  CONDA_BUILD_SYSROOT exported: ${CONDA_BUILD_SYSROOT}"
    fi

    # sets CROSS_CC, CROSS_AS, CROSS_AR, etc.
    setup_toolchain "CROSS" "${target}"
    setup_cflags_ldflags "CROSS" "${build_platform}" "${CROSS_PLATFORM}"

    # linux-s390x is big-endian, but m.h.in ships with ARCH_BIG_ENDIAN #undef'd
    # because configure runs --host= for the x86_64 build machine, not the
    # target. Without the define, Tag_val reads the wrong byte and every
    # natively-compiled target binary SIGSEGVs at si_addr=NULL. Injected via
    # CROSS_CFLAGS rather than patching m.h, which the host-side SAK build
    # shares and must keep little-endian.
    CROSS_CFLAGS="$(add_big_endian_define "${CROSS_PLATFORM}" "${CROSS_CFLAGS:-}")"

    # NEEDS_DL: glibc 2.17 requires explicit -ldl for dlopen/dlclose/dlsym;
    # apply_cross_patches() uses it to add -ldl to Makefile.config.
    NEEDS_DL=0
    case "${CROSS_PLATFORM}" in
      linux-*)
        NEEDS_DL=1
        ;;
    esac
    export NEEDS_DL

    TARGET_ID=$(get_target_id "${target}")

    echo "  Target:        ${target}"
    echo "  Target ID:     ${TARGET_ID}"
    echo "  Arch:          ${CROSS_ARCH}"
    echo "  Platform:      ${CROSS_PLATFORM}"
    print_toolchain_info CROSS

    # Standalone toolchain wrappers must exist before crossopt because
    # config.generated.ml references them. Created in BUILD_PREFIX/bin for
    # build-time use and copied to OCAML_INSTALL_PREFIX/bin later.
    echo "  Installing ${target}-ocaml-* toolchain wrappers (build-time)..."

    # CROSS_* basenames are the defaults so wrappers are relocatable (resolved via PATH).
    # Pair format: tool_name:ENV_SUFFIX:default_value
    _cross_cc_base=$(basename "${CROSS_CC}")
    _cross_ar_base=$(basename "${CROSS_AR}")
    _cross_ld_base=$(basename "${CROSS_LD}")
    _cross_ranlib_base=$(basename "${CROSS_RANLIB}")
    # ASM/MKEXE/MKDLL may contain flags - basename the command, keep the flags
    _cross_asm_base="${CROSS_ASM}"  # already a basename
    _cross_mkexe_base="${CROSS_MKEXE//${CROSS_CC}/${_cross_cc_base}}"
    _cross_mkdll_base="${CROSS_MKDLL//${CROSS_CC}/${_cross_cc_base}}"
    for tool_pair in "cc:CC:${_cross_cc_base}" "as:AS:${_cross_asm_base}" "ar:AR:${_cross_ar_base}" \
                     "ld:LD:${_cross_ld_base}" "ranlib:RANLIB:${_cross_ranlib_base}" \
                     "mkexe:MKEXE:${_cross_mkexe_base}" "mkdll:MKDLL:${_cross_mkdll_base}"; do
      tool_name="${tool_pair%%:*}"
      rest="${tool_pair#*:}"
      env_suffix="${rest%%:*}"
      default_tool="${rest#*:}"

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

    OCAML_CROSS_PREFIX="${OCAML_INSTALL_PREFIX}/lib/ocaml-cross-compilers/${target}"
    OCAML_CROSS_LIBDIR="${OCAML_CROSS_PREFIX}/lib/ocaml"
    mkdir -p "${OCAML_CROSS_PREFIX}/bin" "${OCAML_CROSS_LIBDIR}"

    # libcamlrun_shared.so links against target-arch zstd, so create a conda env
    # with target-platform zstd. Skipped when OCAML_HAS_ZSTD=0 (TARGET_ZSTD_LIBS
    # stays empty).
    if [[ "${OCAML_HAS_ZSTD:-1}" == "1" ]]; then
      TARGET_ZSTD_ENV="zstd_${CROSS_PLATFORM}"
      echo "  Installing target-arch zstd for ${CROSS_PLATFORM}..."
      conda create -n "${TARGET_ZSTD_ENV}" --platform "${CROSS_PLATFORM}" -y zstd --quiet 2>&1 | grep -v "^INFO:" || true
      CONDA_ENVS_DIR=$(conda info --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['envs_dirs'][0])")
      TARGET_ZSTD_LIB="${CONDA_ENVS_DIR}/${TARGET_ZSTD_ENV}/lib"
      TARGET_ZSTD_LIBS="-L${TARGET_ZSTD_LIB} -lzstd"
      echo "  TARGET_ZSTD_LIBS: ${TARGET_ZSTD_LIBS}"
    else
      TARGET_ZSTD_LIBS=""
      echo "  Skipping target-arch zstd install (has_zstd is off)"
    fi

    echo "  [1/7] Cleaning previous build..."
    run_logged "pre-cross-distclean" "${MAKE[@]}" distclean > /dev/null 2>&1 || true

    echo "  [2/7] Configuring for ${target}..."
    # PKG_CONFIG=false forces a plain "-lzstd" instead of "-L/long/path -lzstd".
    # CC is not passed as an arg: configure needs the BUILD compiler.
    # ac_cv_func_getentropy=no: the glibc 2.17 sysroot lacks getentropy.
    # CFLAGS/LDFLAGS are overridden because conda-build sets them for the TARGET
    # but configure needs BUILD flags to compile the cross-compiler binary; they
    # are env vars since OCaml 5.4.0 rejects them as configure args.
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

    # Leaving these set lets crossopt pick up NATIVE values from the environment
    # instead of the CROSS values passed as make arguments, giving arch
    # mismatches between stdlib and otherlibs ("inconsistent assumptions").
    unset CC CFLAGS LDFLAGS

    # OCaml 5.4.0 leaves CHECKSTACK_CC undefined in the Makefile
    patch_checkstack_cc

    echo "  [3/7] Patching config.generated.ml..."
    config_file="utils/config.generated.ml"

    # Standalone ${target}-ocaml-* wrappers (not conda-ocaml-* from native) keep
    # the cross-compiler free of any runtime dependency on native ocaml.
    sed -i \
      -e "s#^let asm = .*#let asm = {|${target}-ocaml-as|}#" \
      -e "s#^let ar = .*#let ar = {|${target}-ocaml-ar|}#" \
      -e "s#^let c_compiler = .*#let c_compiler = {|${target}-ocaml-cc|}#" \
      -e "s#^let ranlib = .*#let ranlib = {|${target}-ocaml-ranlib|}#" \
      -e "s#^let mkexe = .*#let mkexe = {|${target}-ocaml-mkexe|}#" \
      -e "s#^let mkdll = .*#let mkdll = {|${target}-ocaml-mkdll|}#" \
      -e "s#^let mkmaindll = .*#let mkmaindll = {|${target}-ocaml-mkdll|}#" \
      "$config_file"
    # Use the final install path, not OCAML_CROSS_LIBDIR (a work/_xcross_compiler
    # path during the build); rattler-build relocates it when packaging.
    FINAL_STDLIB_PATH="${OCAML_CROSS_FINAL_PREFIX}/lib/ocaml-cross-compilers/${target}/lib/ocaml"
    sed -i "s#^let standard_library_default = .*#let standard_library_default = {|${FINAL_STDLIB_PATH}|}#" "$config_file"

    # architecture is baked into the binary (arm64, power, amd64)
    sed -i "s#^let architecture = .*#let architecture = {|${CROSS_ARCH}|}#" "$config_file"

    [[ -n "${CROSS_MODEL}" ]] && sed -i "s#^let model = .*#let model = {|${CROSS_MODEL}|}#" "$config_file"

    # native_pack_linker goes through the cross-linker wrapper
    sed -i "s#^let native_pack_linker = .*#let native_pack_linker = {|${target}-ocaml-ld -r -o |}#" "$config_file"

    # glibc 2.17 needs an explicit -ldl; the value is baked into the compiler
    # binary, not read from Makefile.config.
    if [[ "${NEEDS_DL}" == "1" ]]; then
      if ! grep -q '"-ldl"' "$config_file"; then
        sed -i 's#^let native_c_libraries = {|\(.*\)|}#let native_c_libraries = {|\1 -ldl|}#' "$config_file"
        echo "    Patched native_c_libraries: added -ldl"
      fi
      if ! grep -q 'bytecomp_c_libraries.*-ldl' "$config_file"; then
        sed -i 's#^let bytecomp_c_libraries = {|\(.*\)|}#let bytecomp_c_libraries = {|\1 -ldl|}#' "$config_file"
        echo "    Patched bytecomp_c_libraries: added -ldl"
      fi
    fi

    echo "    Patched architecture=${CROSS_ARCH}"
    [[ -n "${CROSS_MODEL}" ]] && echo "    Patched model=${CROSS_MODEL}"
    echo "    Patched native_pack_linker=${target}-ocaml-ld -r -o"

    apply_cross_patches

    # Pre-build the bytecode runtime with NATIVE tools. runtime-all builds both
    # bytecode (libcamlrun*, ocamlrun*; runs on BUILD, so NATIVE tools) and native
    # (libasmrun*; for TARGET, so CROSS tools). To avoid Stdlib__Sys consistency
    # errors: build runtime-all with NATIVE tools (ARCH=amd64), clean only the
    # native runtime files, and let crossopt rebuild those for TARGET.

    # BUILD-arch zstd link flags; empty when has_zstd is off so no -lzstd
    # token reaches the native (BUILD-machine) link lines below.
    _BUILD_ZSTD_LIBS=""
    [[ "${OCAML_HAS_ZSTD:-1}" == "1" ]] && _BUILD_ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd"

    # BUILD-arch zstd for Makefile.cross's decompress-only stub, which lets the
    # BUILD-arch compilers of a zstd-free target read compressed .cmi/.cmx.
    # Set regardless of OCAML_HAS_ZSTD; passed only with STDLIB_CMI_PIN_INTREE=1.
    _BUILD_ZSTD_STUB_CFLAGS="-I${BUILD_PREFIX}/include"
    _BUILD_ZSTD_STUB_LIBS="-L${BUILD_PREFIX}/lib -lzstd"

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
      ZSTD_LIBS="${_BUILD_ZSTD_LIBS}" \
      -j"${CPU_COUNT}"

    # stdlib must not be pre-built here (inconsistent assumptions); crossopt builds
    # it entirely with consistent variables.

    # Clean native runtime files so crossopt's runtimeopt rebuilds them for TARGET arch
    # - libasmrun*.a: native runtime static libraries (TARGET arch needed)
    # - libasmrun_shared.so: native runtime shared library
    # - amd64*.o: x86_64 assembly objects (crossopt needs arm64*.o or power*.o)
    # - *.nd.o, *.ni.o, *.npic.o: native code object files (need CROSS CC)
    # libcamlrun*.a (bytecode runtime) is cleaned and rebuilt for TARGET in
    # Makefile.cross after runtimeopt, since crossopt's runtime-all rebuilds it
    # with BUILD tools and it is linked into -output-complete-exe TARGET binaries.
    echo "     Cleaning native runtime files for crossopt rebuild..."
    rm -f runtime/libasmrun*.a runtime/libasmrun_shared.so
    rm -f runtime/amd64*.o runtime/*.nd.o runtime/*.ni.o runtime/*.npic.o
    rm -f runtime/libcomprmarsh.a  # also needs CROSS tools

    # Clean all stdlib files so crossopt builds stdlib from scratch with
    # consistent CRCs throughout.
    echo "     Cleaning stdlib compiled files for crossopt rebuild..."
    rm -f stdlib/*.cmi stdlib/*.cmo stdlib/*.cma
    rm -f stdlib/*.cmx stdlib/*.cmxa stdlib/*.o stdlib/*.a

    # Shared cross-toolchain args for crossopt and installcross.
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

    # libtool bug: with --host=x86_64 --target=s390x, _LT_SYS_DYNAMIC_LINKER keys
    # its -m emulation off $target but probes with the x86_64 linker, so the
    # shared-lib check reports a false negative. s390x does support shared
    # libraries; repair the three Makefile.config sentinels.
    # SUPPORTS_SHARED_LIBRARIES gates building libcamlrun_shared.so and
    # libasmrun_shared.so at all. MKDLL/MKMAINDLL use the unexpanded $(CC)
    # -shared because Makefile.cross builds shared libraries with two compilers
    # (host x86_64 for the cross-compiler's runtime, cross for the target runtime)
    # and a hardcoded path would break one of them.
    if [[ "${CROSS_PLATFORM}" == "linux-s390x" ]]; then
      if grep -q '^SUPPORTS_SHARED_LIBRARIES=false' "Makefile.config"; then
        sed -i "s|^SUPPORTS_SHARED_LIBRARIES=false|SUPPORTS_SHARED_LIBRARIES=true|" "Makefile.config"
        echo "  [s390x-sharedlib-fix] SUPPORTS_SHARED_LIBRARIES -> true (libtool probe false negative)"
      fi
      if grep -q '^MKDLL=shared-libs-not-available' "Makefile.config"; then
        sed -i 's|^MKDLL=shared-libs-not-available|MKDLL=$(CC) -shared|' "Makefile.config"
        echo '  [s390x-sharedlib-fix] MKDLL -> $(CC) -shared'
      fi
      if grep -q '^MKMAINDLL=shared-libs-not-available' "Makefile.config"; then
        sed -i 's|^MKMAINDLL=shared-libs-not-available|MKMAINDLL=$(CC) -shared|' "Makefile.config"
        echo '  [s390x-sharedlib-fix] MKMAINDLL -> $(CC) -shared'
      fi
    fi

    echo "  [5/7] Building and installing cross-compiler..."

    # crossopt execs a target-arch ocamlc on the build machine (the
    # otherlibs/unix .cmi step), needing qemu-user when the arch differs.
    # run-target.sh wraps only such binaries and sets QEMU_LD_PREFIX (from
    # OCAML_QEMU_SYSROOT) so qemu finds the target's loader. Exported outside
    # the subshell below so the post-install check_unix_crc still sees it.
    if [[ "${CROSS_PLATFORM}" != "${build_platform:-}" && -n "${OCAML_TARGET_TRIPLET:-}" ]]; then
      _qemu_sysroot="${BUILD_PREFIX}/${OCAML_TARGET_TRIPLET}/sysroot"
      if [[ -d "${_qemu_sysroot}" ]]; then
        export OCAML_QEMU_SYSROOT="${_qemu_sysroot}"
        echo "  [qemu] OCAML_QEMU_SYSROOT=${OCAML_QEMU_SYSROOT}"
      else
        echo "  [qemu] target sysroot not found at ${_qemu_sysroot}; leaving OCAML_QEMU_SYSROOT unset"
      fi
    fi

    (
      _setup_crossopt_env

      NATIVE_STDLIB="${OCAML_PREFIX}/lib/ocaml"

      # --- Build crossopt ---
      CROSSOPT_ARGS=(
        "${CROSS_TOOLCHAIN_ARGS[@]}"
        CAMLOPT=ocamlopt
        V=1
        "RUN_TARGET=bash ${RECIPE_DIR}/building/run-target.sh"
        CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"
        LIBDIR="${OCAML_CROSS_LIBDIR}"
        ZSTD_LIBS="${_BUILD_ZSTD_LIBS}"
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

      # A --without-zstd runtime cannot decompress compressed marshal payloads.
      # The bare CAMLC=ocamlc in Makefile.cross's CROSS_OVERRIDES resolves via
      # PATH to a zstd-enabled ocamlc, which writes stdlib and compilerlibs .cmi
      # files with the compressed marshal magic 0x8495A6BD; the zstd-free runtime
      # rejects them ("Corrupted compiled interface").
      # STDLIB_CMI_PIN_INTREE=1 redirects those writes to the in-tree ocamlc,
      # which is built --without-zstd. Gated on the target having no zstd, the
      # actual condition requiring the pin, not on a platform name.
      if [[ "${OCAML_HAS_ZSTD:-1}" == "0" ]]; then
        CROSSOPT_ARGS+=(
          STDLIB_CMI_PIN_INTREE=1
          NOZSTD_STUB_ZSTD_CFLAGS="${_BUILD_ZSTD_STUB_CFLAGS}"
          NOZSTD_STUB_ZSTD_LIBS="${_BUILD_ZSTD_STUB_LIBS}"
        )
        echo "  zstd-free target: pinning stdlib CAMLC to in-tree ocamlc (STDLIB_CMI_PIN_INTREE=1)"
      fi

      # Serialized: Makefile.cross deletes utils/*.cmi and middle_end/*.cmi mid-build,
      # which races with parallel compile jobs and corrupts what a concurrent ocamlc reads
      run_logged "crossopt" "${MAKE[@]}" crossopt "${CROSSOPT_ARGS[@]}" "${COMPRESSED_MARSHALING_OVERRIDE}" -j1

      # --- Install crossopt ---
      echo "  [6/7] Installing cross-compiler via 'make installcross'..."

      # Start from an empty LIBDIR for a fresh install
      echo "    Cleaning LIBDIR before install..."
      rm -rf "${OCAML_CROSS_LIBDIR}"

      # Verify implementation CRCs match before installing
      _pre_unix="${SRC_DIR}/otherlibs/unix/unix.cmxa"
      _pre_threads="${SRC_DIR}/otherlibs/systhreads/threads.cmxa"
      _ocamlobjinfo_build="${SRC_DIR}/tools/ocamlobjinfo.opt"

      if [[ -f "$_pre_unix" ]] && [[ -f "$_pre_threads" ]] && [[ -f "$_ocamlobjinfo_build" ]]; then
        check_unix_crc "${_ocamlobjinfo_build}" "${_pre_unix}" "${_pre_threads}" "PRE-INSTALL"
      else
        echo "    ERROR: Missing a CRC file: ${_pre_unix} ${_pre_threads} ${_ocamlobjinfo_build}"
        exit 1
      fi

      INSTALL_ARGS=(
        "${CROSS_TOOLCHAIN_ARGS[@]}"
        PREFIX="${OCAML_CROSS_PREFIX}"
      )

      run_logged "installcross" "${MAKE[@]}" installcross "${INSTALL_ARGS[@]}"
    )

    fix_installed_big_endian_header "${CROSS_PLATFORM}" "${OCAML_CROSS_LIBDIR}/caml/m.h" || exit 1

    # OCaml embeds @rpath/libzstd.1.dylib; BYTECCLIBS should already set the
    # rpath. Binaries are in ${PREFIX}/lib/ocaml-cross-compilers/${target}/bin/
    # and libzstd in ${PREFIX}/lib/, hence ../../../../lib.
    if [[ "${target_platform}" == "osx"* ]]; then
      echo "  Verifying rpath for macOS cross-compiler binaries..."
      verify_macos_rpath "${OCAML_CROSS_PREFIX}/bin" "@loader_path/../../../../lib"

      # silence rattler-build overlinking warnings
      bash "${RECIPE_DIR}/building/fix-macos-install-names.sh" "${OCAML_CROSS_LIBDIR}"
    fi

    # ld.conf points to native OCaml's stublibs: the cross-compiler binary runs
    # on the BUILD machine and needs BUILD-arch stublibs.
    cat > "${OCAML_CROSS_LIBDIR}/ld.conf" << EOF
${OCAML_PREFIX}/lib/ocaml/stublibs
${OCAML_PREFIX}/lib/ocaml
EOF

    # Drop binaries the cross-compiler does not need (it needs ocamlopt, ocamlc,
    # ocamldep, ocamllex, ocamlyacc, ocamlmklib).
    echo "  Cleaning up unnecessary binaries..."
    (
      cd "${OCAML_CROSS_PREFIX}/bin"

      # bytecode versions (keep only .opt)
      rm -f ocamlc.byte ocamldep.byte ocamllex.byte ocamlobjinfo.byte ocamlopt.byte

      # toplevel and REPL
      rm -f ocaml

      # bytecode interpreters (the cross-compiler produces native code)
      rm -f ocamlrun ocamlrund ocamlruni

      # profiling tools
      rm -f ocamlcp ocamloptp ocamlprof

      rm -f ocamlcmt ocamlmktop
    )

    rm -rf "${OCAML_CROSS_PREFIX}/man" 2>&1 || true

    # The installed Makefile.config has BUILD machine settings; switch to TARGET
    # settings and drop build-time paths that break tests and runtime.
    echo "  Patching Makefile.config for target ${target}..."
    makefile_config="${OCAML_CROSS_LIBDIR}/Makefile.config"
    if [[ -f "${makefile_config}" ]]; then
      sed -i "s|^ARCH=.*|ARCH=${CROSS_ARCH}|" "${makefile_config}"

      # TOOLPREF must be the TARGET triplet: opam uses it to find the cross-toolchain
      sed -i "s|^TOOLPREF=.*|TOOLPREF=${target}-|" "${makefile_config}"

      if [[ -n "${CROSS_MODEL}" ]]; then
        sed -i "s|^MODEL=.*|MODEL=${CROSS_MODEL}|" "${makefile_config}"
      fi

      # standalone ${target}-ocaml-* wrappers, not conda-ocaml-* from native
      sed -i "s|^CC=.*|CC=${target}-ocaml-cc|" "${makefile_config}"
      sed -i "s|^AS=.*|AS=${target}-ocaml-as|" "${makefile_config}"
      sed -i "s|^ASM=.*|ASM=${target}-ocaml-as|" "${makefile_config}"
      sed -i "s|^ASPP=.*|ASPP=${target}-ocaml-cc -c|" "${makefile_config}"
      sed -i "s|^AR=.*|AR=${target}-ocaml-ar|" "${makefile_config}"
      sed -i "s|^RANLIB=.*|RANLIB=${target}-ocaml-ranlib|" "${makefile_config}"

      # CPP: strip the build-time path, keep binary name and flags
      # (CPP=/long/path/to/clang -E -P -> CPP=clang -E -P); flags are optional
      sed -Ei 's#^(CPP)=/.*/([^/ ]+)( .*)?$#\1=\2\3#' "${makefile_config}"

      # linker commands
      sed -i "s|^NATIVE_PACK_LINKER=.*|NATIVE_PACK_LINKER=${target}-ocaml-ld -r -o|" "${makefile_config}"
      sed -i "s|^MKEXE=.*|MKEXE=${target}-ocaml-mkexe|" "${makefile_config}"
      sed -i "s|^MKDLL=.*|MKDLL=${target}-ocaml-mkdll|" "${makefile_config}"
      sed -i "s|^MKMAINDLL=.*|MKMAINDLL=${target}-ocaml-mkdll|" "${makefile_config}"

      # Use the final installed path (conda relocates ${PREFIX}); OCAML_CROSS_LIBDIR
      # is a build-time work directory.
      FINAL_CROSS_LIBDIR="${OCAML_CROSS_FINAL_PREFIX}/lib/ocaml-cross-compilers/${target}/lib/ocaml"
      FINAL_CROSS_PREFIX="${OCAML_CROSS_FINAL_PREFIX}/lib/ocaml-cross-compilers/${target}"
      sed -i "s|^prefix=.*|prefix=${FINAL_CROSS_PREFIX}|" "${makefile_config}"
      sed -i "s|^LIBDIR=.*|LIBDIR=${FINAL_CROSS_LIBDIR}|" "${makefile_config}"
      sed -i "s|^STUBLIBDIR=.*|STUBLIBDIR=${FINAL_CROSS_LIBDIR}/stublibs|" "${makefile_config}"

      # drop -Wl,-rpath paths pointing at build directories
      sed -i 's|-Wl,-rpath,[^ ]*rattler-build[^ ]* ||g' "${makefile_config}"
      sed -i 's|-Wl,-rpath-link,[^ ]*rattler-build[^ ]* ||g' "${makefile_config}"

      # remove build-time -L paths from LDFLAGS lines
      sed -i 's|-L[^ ]*miniforge[^ ]* ||g' "${makefile_config}"
      sed -i 's|-L[^ ]*miniconda[^ ]* ||g' "${makefile_config}"

      clean_makefile_config "${makefile_config}" "${PREFIX}"

      echo "    Patched ARCH=${CROSS_ARCH}"
      [[ -n "${CROSS_MODEL}" ]] && echo "    Patched MODEL=${CROSS_MODEL}"
      echo "    Patched toolchain to use ${target}-ocaml-* standalone wrappers"
      echo "    Cleaned build-time paths from prefix/LIBDIR/STUBLIBDIR"
    else
      echo "    WARNING: Makefile.config not found at ${makefile_config}"
    fi

    # runtime-launch-info is cleaned after the transfer; cleaning here would
    # corrupt it before the cross-target stage can use it.

    echo "  Cleaning up unnecessary library files..."
    (
      cd "${OCAML_CROSS_LIBDIR}"

      # sources are not needed for compilation
      find . -name "*.ml" -type f -delete 2>&1 || true
      find . -name "*.mli" -type f -delete 2>&1 || true

      # typed trees are only for IDE tooling
      find . -name "*.cmt" -type f -delete 2>&1 || true
      find . -name "*.cmti" -type f -delete 2>&1 || true

      find . -name "*.annot" -type f -delete 2>&1 || true

      # Keep .cma/.cmo (dune bootstrap may need bytecode libraries) and
      # .cmx/.cmxa/.a/.cmi/.o (required for native compilation).
    )

    echo "  Installed via make installcross to: ${OCAML_CROSS_PREFIX}"

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
        # grep -E alternation uses | (not \|)
        case "${CROSS_ARCH}" in
          arm64) _expected="arm64|ARM64|AArch64|aarch64" ;;
          aarch64) _expected="AArch64|aarch64|arm64|ARM64" ;;
          power) _expected="PowerPC|ppc64" ;;
          riscv) _expected="RISC-V|RISCV|riscv" ;;
          s390x) _expected="IBM S/390|S/390|s390" ;;
          amd64) _expected="x86_64|amd64" ;;
          *) _expected="${CROSS_ARCH}" ;;
        esac
        if ! echo "$_arch_info" | grep -qiE "$_expected"; then
          echo "    [FAIL] ERROR: libasmrun.a has WRONG architecture!"
          echo "    Expected: ${CROSS_ARCH}, Got: $_arch_info"
          rm -rf "$_tmpdir"
          exit 1
        fi
      fi
      rm -rf "$_tmpdir"
    else
      echo "    WARNING: libasmrun.a not found at ${OCAML_CROSS_LIBDIR}/libasmrun.a"
    fi

    # Copy the toolchain wrappers created before crossopt into
    # OCAML_INSTALL_PREFIX/bin for the final package.
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

    # Fail fast on CRC inconsistency between unix.cmxa and threads.cmxa
    check_unix_crc \
      "${SRC_DIR}/tools/ocamlobjinfo.opt" \
      "${OCAML_CROSS_LIBDIR}/unix/unix.cmxa" \
      "${OCAML_CROSS_LIBDIR}/threads/threads.cmxa" \
      "POST-INSTALL ${target}"

    for tool in ocamlopt ocamlc ocamldep ocamlobjinfo ocamllex ocamlyacc ocamlmklib; do
      generate_cross_wrapper "${tool}" "${OCAML_INSTALL_PREFIX}" "${target}" "${OCAML_CROSS_PREFIX}"
      (cd "${OCAML_INSTALL_PREFIX}"/bin && ln -s "${target}-${tool}.opt" "${target}-${tool}")
    done

    echo "  Installed: ${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt"
    echo "  Libs:      ${OCAML_CROSS_LIBDIR}/"

    echo "  Basic smoke test..."
    CROSS_OCAMLOPT="${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt"

    if "${CROSS_OCAMLOPT}" -version | grep -q "${PKG_VERSION}"; then
      echo "    [OK] Version check passed"
    else
      echo "    [FAIL] ERROR: Version mismatch"
      exit 1
    fi

    ${RECIPE_DIR}/testing/test-cross-compiler-consistency.sh "${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt"

    echo "  Done: ${target} (comprehensive tests run in post-install)"

  echo ""
  echo "============================================================"
  echo "Cross-compiler for ${target} built successfully"
  echo "============================================================"
}

# --- build_cross_target(): native compiler cross-compiled with the BUILD_PREFIX cross-compiler ---

build_cross_target() {
  local -a CONFIG_ARGS=("${CONFIG_ARGS[@]}")

  # Sanitize mixed-arch CFLAGS early (see the top-level block)
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

  : "${OCAML_PREFIX:=${BUILD_PREFIX}}"
  : "${CROSS_COMPILER_PREFIX:=${BUILD_PREFIX}}"
  : "${OCAML_INSTALL_PREFIX:=${PREFIX}}"

  CROSS_ARCH=$(get_target_arch "${host_alias}")
  CROSS_PLATFORM=$(get_target_platform "${host_alias}")

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
    # only unset when the toolchain was not set up by an earlier stage
    setup_toolchain "CROSS" "${host_alias}"
    setup_cflags_ldflags "CROSS" "${build_platform}" "${target_platform}"
  fi

  # Sub-makes inherit the environment and may pick up polluted values, so export
  # the clean CROSS values as CFLAGS/LDFLAGS.
  export CFLAGS="${CROSS_CFLAGS}"
  export LDFLAGS="${CROSS_LDFLAGS}"

  if [[ -z ${NATIVE_CC:-} ]]; then
    # only unset when the toolchain was not set up by an earlier stage
    setup_toolchain "NATIVE" "${build_alias}"
    setup_cflags_ldflags "NATIVE" "${build_platform}" "${target_platform}"
  fi

  # DYLD_FALLBACK_LIBRARY_PATH (not DYLD_LIBRARY_PATH, which would override
  # system libs) lets the cross-compiler binaries find libzstd at runtime.
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

  cat > "${SRC_DIR}/_target_compiler_${target_platform}_env.sh" << EOF
# CONDA_OCAML_* for runtime
export CONDA_OCAML_AR="${CROSS_AR}"
export CONDA_OCAML_AS="${CROSS_ASM}"
export CONDA_OCAML_CC="${CROSS_CC}"
export CONDA_OCAML_RANLIB="${CROSS_RANLIB}"
export CONDA_OCAML_MKEXE="${CROSS_MKEXE:-}"
export CONDA_OCAML_MKDLL="${CROSS_MKDLL:-}"
EOF

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

  echo ""
  echo "  [1/5] Configuring for ${host_alias} ==="

  # CFLAGS/LDFLAGS are env vars since OCaml 5.4.0 rejects them as configure args
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

  # conda-ocaml-* wrappers are needed during the build
  echo "    Installing conda-ocaml-* wrapper scripts to BUILD_PREFIX..."
  install_conda_ocaml_wrappers "${BUILD_PREFIX}/bin"

  # TARGET_BINDIR/LIBDIR tell OCaml where binaries and libraries live at runtime
  # on the target; conda-forge relocates paths containing ${PREFIX}, not _native ones.
  export TARGET_BINDIR="${PREFIX}/bin"
  export TARGET_LIBDIR="${PREFIX}/lib/ocaml"

  run_logged "stage3_configure" "${CONFIGURE[@]}" "${CONFIG_ARGS[@]}"

  # OCaml 5.4.0 leaves CHECKSTACK_CC undefined in the Makefile
  patch_checkstack_cc

  echo "  [2/5] Patching configuration ==="

  # conda-ocaml-* wrappers expand CONDA_OCAML_* at runtime and work with
  # Unix.create_process
  patch_config_generated_ml_native

  # PowerPC model
  local config_file="utils/config.generated.ml"
  [[ -n "${CROSS_MODEL}" ]] && sed -i "s#^let model = .*#let model = {|${CROSS_MODEL}|}#" "$config_file"

  # Apply Makefile.cross patches
  apply_cross_patches

  # zstd link suffix for target-arch libs; empty when has_zstd is off so no
  # -lzstd token reaches any of the target link lines below.
  _zstd_lib=""
  [[ "${OCAML_HAS_ZSTD:-1}" == "1" ]] && _zstd_lib=" -lzstd"

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

  # Same stale-wrapper override as _setup_crossopt_env(). TARGET_ID is only set
  # in build_cross_compiler(), so derive it here. Without it crosscompiledopt
  # fails linking compilerlibs/ocamlcommon.cmxa with "<triplet>-ocaml-ar: line 4:
  # exec: llvm-ar-19: not found".
  local _tgt_id _mkexe_val
  _tgt_id=$(get_target_id "${OCAML_TARGET_TRIPLET}")
  export "CONDA_OCAML_${_tgt_id}_AR=${CROSS_AR##*/}"
  export "CONDA_OCAML_${_tgt_id}_RANLIB=${CROSS_RANLIB##*/}"
  # Same trap for the shipped <triplet>-ocaml-mkexe / -mkdll wrappers, which exec
  #   ${CONDA_OCAML_<ID>_MKEXE:-<full command line baked at its build time>}
  # The baked default carries that build's -isysroot, pointing into a rattler-build
  # work dir that no longer exists; the linker then reports "no such sysroot
  # directory" and cannot find -lpthread (on macOS only a stub inside the SDK).
  # Not basenamed with ##*/: these are full command lines and it would strip the
  # -isysroot path. This is the target-ID-scoped variable read only by that
  # wrapper, separate from the unscoped CONDA_OCAML_MKEXE that
  # _setup_crossopt_env() sets, so the override is needed regardless.
  if [[ -n "${CROSS_MKEXE:-}" ]]; then
    _mkexe_val="${CROSS_MKEXE}"
    # gcc ignores LIBRARY_PATH when configured as a cross compiler, so linux
    # targets need the search path on the link driver's command line. Set on the
    # exported override, not CROSS_MKEXE: the wrapper bakes CROSS_MKEXE as its
    # default, and a prefix baked into a shipped artifact is fatal.
    if [[ "${target_platform}" == "linux-"* ]]; then
      _mkexe_val="${_mkexe_val} -L${PREFIX}/lib"
    fi
    export "CONDA_OCAML_${_tgt_id}_MKEXE=${_mkexe_val}"
  fi
  if [[ -n "${CROSS_MKDLL:-}" ]]; then
    export "CONDA_OCAML_${_tgt_id}_MKDLL=${CROSS_MKDLL}"
  fi
  # riscv64: the shipped per-triplet ocaml-mkexe wrapper invokes the linker
  # without LDFLAGS, defaulting to --no-allow-shlib-undefined, which rejects
  # target libzstd.so's pthread_create/pthread_join@GLIBC_2.34 references.
  if [[ "${CROSS_ARCH}" == "riscv" ]]; then
    export "CONDA_OCAML_${_tgt_id}_MKEXE=${CROSS_CC} ${CROSS_LDFLAGS} -Wl,-E -ldl -Wl,--no-as-needed -lm -Wl,--as-needed"
  fi

  echo "  [3/5] Building crosscompiledopt ==="

  # As in the crossopt leg: this step execs a target-arch binary on the build
  # machine, needing qemu-user pointed at the target sysroot when the arch
  # differs; run-target.sh reads OCAML_QEMU_SYSROOT.
  if [[ "${CROSS_PLATFORM}" != "${build_platform:-}" && -n "${OCAML_TARGET_TRIPLET:-}" ]]; then
    _qemu_sysroot="${BUILD_PREFIX}/${OCAML_TARGET_TRIPLET}/sysroot"
    if [[ -d "${_qemu_sysroot}" ]]; then
      export OCAML_QEMU_SYSROOT="${_qemu_sysroot}"
      echo "  [qemu] OCAML_QEMU_SYSROOT=${OCAML_QEMU_SYSROOT}"
    else
      echo "  [qemu] target sysroot not found at ${_qemu_sysroot}; leaving OCAML_QEMU_SYSROOT unset"
    fi
  fi

  (
    CROSSCOMPILEDOPT_ARGS=(
      "${CROSS_TARGET_COMMON_ARGS[@]}"
      "RUN_TARGET=bash ${RECIPE_DIR}/building/run-target.sh"
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

    # Same zstd-free condition as the crossopt leg: this stage packages the
    # target binaries, so otherlibrariesopt and ocamltoolsopt must also write
    # stdlib .cmi files with the in-tree ocamlc, not the zstd-enabled PATH one.
    if [[ "${OCAML_HAS_ZSTD:-1}" == "0" ]]; then
      CROSSCOMPILEDOPT_ARGS+=( STDLIB_CMI_PIN_INTREE=1 )
      echo "  zstd-free target: pinning stdlib CAMLC to in-tree ocamlc (STDLIB_CMI_PIN_INTREE=1)"
    fi

    # ocamlopt links compilerlibs from flags recorded in the .cmxa, which carries
    # no -L, so give the cross gcc a search path it consults directly. Scoped to
    # this make, not exported build-wide.
    run_logged "crosscompiledopt" env LIBRARY_PATH="${PREFIX}/lib${LIBRARY_PATH:+:${LIBRARY_PATH}}" "${MAKE[@]}" crosscompiledopt "${CROSSCOMPILEDOPT_ARGS[@]}" "${COMPRESSED_MARSHALING_OVERRIDE}" -j"${CPU_COUNT}"
  )

  echo "  [4/5] Building crosscompiledruntime ==="

  # point build_config.h at the target
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

    run_logged "crosscompiledruntime" "${MAKE[@]}" crosscompiledruntime "${CROSSCOMPILEDRUNTIME_ARGS[@]}" -j"${CPU_COUNT}"
  )

  echo "  [5/5] Installing ==="

  # stripdebug becomes a no-op copy: target binaries can't run on the build machine
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

  fix_installed_big_endian_header "${CROSS_PLATFORM}" "${OCAML_INSTALL_PREFIX}/lib/ocaml/caml/m.h" || exit 1

  echo "    Cleaning hardcoded paths from Makefile.config..."
  local installed_config="${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config"
  clean_makefile_config "${installed_config}" "${PREFIX}"

  # runtime-launch-info is cleaned after the transfer; cleaning here would
  # corrupt it when this is an intermediate stage.

  if [[ "${target_platform}" == "osx-"* ]]; then
    echo "    Fixing macOS install names..."
    bash "${RECIPE_DIR}/building/fix-macos-install-names.sh" "${OCAML_INSTALL_PREFIX}/lib/ocaml"
  fi

  # conda-ocaml-* wrappers expand CONDA_OCAML_* for tools like Dune
  echo "    Installing conda-ocaml-* wrapper scripts..."
  install_conda_ocaml_wrappers "${OCAML_INSTALL_PREFIX}/bin"

  # Clean up for later cross-compiler builds
  run_logged "distclean" "${MAKE[@]}"  distclean

  echo ""
  echo "============================================================"
  echo "Cross-target build complete"
  echo "============================================================"
  echo "  Target:    ${host_alias}"
  echo "  Installed: ${OCAML_INSTALL_PREFIX}"
}

# --- mode: native ---
if [[ "${BUILD_MODE}" == "native" ]]; then
  OCAML_NATIVE_INSTALL_PREFIX="${SRC_DIR}"/_native_compiler

  echo ""
  echo "=== Building native OCaml ==="
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

  # Clean build-time paths from the final Makefile.config; this must follow
  # transfer_to_prefix, which is when the file reaches ${PREFIX}.
  echo "  Cleaning build-time paths from final Makefile.config..."
  if is_unix; then
    clean_makefile_config "${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config" "${OCAML_INSTALL_PREFIX}"
  else
    clean_makefile_config "${OCAML_INSTALL_PREFIX}/Library/lib/ocaml/Makefile.config" "${OCAML_INSTALL_PREFIX}"
  fi

  # runtime-launch-info is cleaned after the transfer to PREFIX
  echo "  Cleaning build-time paths from final runtime-launch-info..."
  if is_unix; then
    clean_runtime_launch_info "${OCAML_INSTALL_PREFIX}/lib/ocaml/runtime-launch-info" "${OCAML_INSTALL_PREFIX}"
  fi

fi

# GNU make deletes toplevel/byte/*.cmi as chained-implicit-rule intermediates
# (upstream pattern rule, never .PRECIOUS/.SECONDARY), but `make install` globs
# them; Makefile.cross restores them from the toplevel/ copies just before
# install. Exported rather than passed as a make arg because one of the two
# installcross call sites takes no arguments. A dedicated flag, since reusing
# STDLIB_CMI_PIN_INTREE would also flip the CAMLC/CAMLOPT pins for the whole
# install phase. Guarded on OCAML_TARGET_PLATFORM: on a cross lane
# target_platform is the BUILD host and would miss the s390x cross lane.
if [[ "${OCAML_TARGET_PLATFORM}" == "linux-s390x" ]]; then
  export OCAML_TOPLEVEL_BYTE_CMI_RESTORE=1
fi

# --- mode: cross-compiler ---
if [[ "${BUILD_MODE}" == "cross-compiler" ]]; then
  # Native OCaml comes from BUILD_PREFIX (the ocaml_$build_platform dependency).

  # build_cross_compiler needs the NATIVE_* variables (NATIVE_CC, SAK_*, etc.)
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

    # staging paths -> install paths in Makefile.config
    makefile_config="${cross_dir}/lib/ocaml/Makefile.config"
    if [[ -f "$makefile_config" ]]; then
      sed -i "s#${OCAML_XCROSS_INSTALL_PREFIX}#${OCAML_INSTALL_PREFIX}#g" "$makefile_config"
      sed -i "s#/.*build_env/bin/##g" "$makefile_config"
      sed -i 's#$(CC)#$(CONDA_OCAML_CC)#g' "$makefile_config"
      echo "    Fixed: lib/ocaml-cross-compilers/${triplet}/lib/ocaml/Makefile.config"
    fi

    ldconf="${cross_dir}/lib/ocaml/ld.conf"
    if [[ -f "$ldconf" ]]; then
      cat > "$ldconf" << EOF
${cross_dir}lib/ocaml/stublibs
${cross_dir}lib/ocaml
EOF
      echo "    Fixed: lib/ocaml-cross-compilers/${triplet}/lib/ocaml/ld.conf"
    fi

    # runtime-launch-info is binary: use the binary-safe cleanup
    runtime_info="${cross_dir}/lib/ocaml/runtime-launch-info"
    if [[ -f "$runtime_info" ]]; then
      clean_runtime_launch_info "$runtime_info" "${OCAML_INSTALL_PREFIX}"
    fi
  done
fi

# --- mode: cross-target ---
if [[ "${BUILD_MODE}" == "cross-target" ]]; then
  CROSS_TARGET="${OCAML_TARGET_TRIPLET}"

  if [[ "${OCAML_BOOTSTRAP_IN_LANE:-0}" == "1" ]]; then
    # This target has no published ocaml_<target> cross-compiler to depend on
    # (see recipe.yaml, bootstrap_in_lane), so build one here. The tree is
    # consumed in place and never transferred to ${PREFIX}, which is why
    # OCAML_CROSS_FINAL_PREFIX points at the staging prefix.
    OCAML_XCROSS_INSTALL_PREFIX="${SRC_DIR}"/_xcross_compiler
    CROSS_COMPILER_SOURCE="${OCAML_XCROSS_INSTALL_PREFIX}"
    CROSS_COMPILER_DIR="${OCAML_XCROSS_INSTALL_PREFIX}/lib/ocaml-cross-compilers/${CROSS_TARGET}"

    echo ""
    echo "=== Cross-target build: building cross-compiler in-lane ==="
    echo "  Cross-compiler: ${CROSS_COMPILER_DIR}"

    (
      # These provide the NATIVE_CC, SAK_* and NATIVE_CFLAGS/LDFLAGS that
      # build_cross_compiler needs; kept in this subshell so the NATIVE_* exports
      # cannot leak into build_cross_target.
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
  else
    # The cross-compiler comes from BUILD_PREFIX (the ocaml_$target_platform dependency)
    CROSS_COMPILER_SOURCE="${BUILD_PREFIX}"
    CROSS_COMPILER_DIR="${BUILD_PREFIX}/lib/ocaml-cross-compilers/${CROSS_TARGET}"

    echo ""
    echo "=== Cross-target build: Using cross-compiler from BUILD_PREFIX ==="
    echo "  Cross-compiler: ${CROSS_COMPILER_DIR}"

    if [[ ! -f "${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma" ]]; then
      echo "ERROR: Cross-compiler not found at ${CROSS_COMPILER_DIR}"
      echo "The ocaml_${target_platform} package must be installed as a build dependency"
      exit 1
    fi
  fi

  OCAML_TARGET_INSTALL_PREFIX="${SRC_DIR}"/_target_compiler
  (
    export OCAML_PREFIX="${BUILD_PREFIX}"
    export CROSS_COMPILER_PREFIX="${CROSS_COMPILER_SOURCE}"
    OCAML_INSTALL_PREFIX="${OCAML_TARGET_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    build_cross_target
  )

  # Transfer to PREFIX
  OCAML_INSTALL_PREFIX="${PREFIX}"
  transfer_to_prefix "${OCAML_TARGET_INSTALL_PREFIX}" "${OCAML_INSTALL_PREFIX}"

  echo "  Cleaning build-time paths from final Makefile.config..."
  clean_makefile_config "${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config" "${OCAML_INSTALL_PREFIX}"

  # This build copies runtime-launch-info from the cross-compiler's stdlib, whose
  # BINDIR points at the cross-compiler's staging directory; line 2 is replaced
  # with the target BINDIR ($PREFIX/bin).
  echo "  Cleaning build-time paths from final runtime-launch-info..."
  clean_runtime_launch_info "${OCAML_INSTALL_PREFIX}/lib/ocaml/runtime-launch-info" "${OCAML_INSTALL_PREFIX}"
fi

# --- post-processing: native and cross-target modes ---
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

    # 350 bytes are needed to see an ocamlrun reference behind long conda placeholder paths
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

  # Install activation scripts with build-time tool substitution
  echo ""
  echo "=== Installing activation scripts ==="

  (
    # absent when the native stage did not run in this build
    if [[ -f "${SRC_DIR}/_native_compiler_env.sh" ]]; then
      source "${SRC_DIR}/_native_compiler_env.sh"
    fi

    # cross-target: the package runs on OCAML_TARGET_PLATFORM, so use that platform's tools
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
      # native mode without the native stage: use triplet-prefixed names from
      # BUILD_PREFIX. Generic cc/ar would point at the TARGET compiler in
      # cross-compilation, but conda-ocaml-cc in ocaml_osx-64 (BUILD_PREFIX) needs
      # the BUILD PLATFORM compiler. ocaml_$platform has a run dep on the
      # platform-specific C compiler package so these binaries are available.
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
      # fixed name "ocaml", not PKG_NAME, which varies by output
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
      # win-arm64 only: flexlink import dir and -l list; blank on every other lane
      _flexlink_extra=""
      if [[ "${target_platform}" == "win-arm64" && -f "${SRC_DIR}/_win_arm64_flexlink_libs.txt" ]]; then
        _flexlink_extra="-L%CONDA_PREFIX%/Library/lib/ocaml/flexdll $(cat "${SRC_DIR}/_win_arm64_flexlink_libs.txt")"
      fi
      sed -i "s|@FLEXLINK_EXTRA@|${_flexlink_extra}|g" "${_SCRIPT}"
    done
  )
fi

# --- post-processing: cross-compiler mode ---
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

  # Activation scripts provide ocaml_use_cross / ocaml_use_native for downstream builds
  _CROSS_TARGET="${OCAML_TARGET_TRIPLET}"
  _CROSS_TARGET_ID=$(get_target_id "${_CROSS_TARGET}")

  # Take the tool defaults (after :-) from the wrappers generate_cross_wrapper
  # writes, which contain lines like
  #   export CONDA_OCAML_CC="${CONDA_OCAML_AARCH64_CC:-aarch64-conda-linux-gnu-gcc}"
  _CROSS_WRAPPER=$(ls "${PREFIX}"/bin/${_CROSS_TARGET}-ocamlopt.opt 2>/dev/null | head -1)
  if [[ -z "${_CROSS_WRAPPER}" ]]; then
    echo "ERROR: No cross-compiler wrapper found for ${_CROSS_TARGET}"
    exit 1
  fi
  # Strip ${LDFLAGS} from MKEXE/MKDLL - those are build-time only, not for activation.
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
