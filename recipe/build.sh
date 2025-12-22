#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

mkdir -p "${PREFIX}"/lib "${SRC_DIR}"/_logs

# Platform detection and OCAML_PREFIX setup
if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export OCAML_PREFIX="${PREFIX}"
  SH_EXT="sh"
else
  export OCAML_PREFIX="${PREFIX}"/Library
  SH_EXT="bat"
fi

export OCAMLLIB="${OCAML_PREFIX}/lib/ocaml"

CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir="${OCAML_PREFIX}"/share/man
  --with-target-bindir="${PREFIX}"/bin
  -prefix "${OCAML_PREFIX}"
)

if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
  # Cross-compilation: use unified 3-stage build script
  source "${RECIPE_DIR}/building/cross-compile.sh"
else
  # Load unix no-op non-unix helpers
  source "${RECIPE_DIR}/building/non-unix-utilities.sh"

  # No-op for unix
  unix_noop_build_toolchain

  # Simplify compiler paths to basenames (hardcoded in binaries)
  export CC=$(basename "${CC}")
  export ASPP="$CC -c"
  export AS=$(basename "${AS:-as}")
  export AR=$(basename "${AR:-ar}")
  export RANLIB=$(basename "${RANLIB:-ranlib}")

  # Platform-specific linker flags
  if [[ "${target_platform}" == "osx-"* ]]; then
    export LIBRARY_PATH="${PREFIX}/lib:${LIBRARY_PATH:-}"
    export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld -Wl,-headerpad_max_install_names"
    export DYLD_LIBRARY_PATH="${PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
  elif [[ "${target_platform}" == "linux-"* ]]; then
    export LIBRARY_PATH="${PREFIX}/lib:${LIBRARY_PATH:-}"
    export LDFLAGS="${LDFLAGS:-} -L${PREFIX}/lib"
  fi

  export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH:-}"

  if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
    CONFIG_ARGS+=(--enable-ocamltest)
  fi

  ./configure "${CONFIG_ARGS[@]}" LDFLAGS="${LDFLAGS:-}" > "${SRC_DIR}"/_logs/configure.log 2>&1 || { cat "${SRC_DIR}"/_logs/configure.log; exit 1; }

  # No-op for unix
  unix_noop_update_toolchain

  # Patch config.generated.ml with compiler paths for build
  config_file="utils/config.generated.ml"
  if [[ -f "$config_file" ]]; then
    if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
      if [[ "${target_platform}" == "osx-"* ]]; then
        _BUILD_MKEXE="${CC} -fuse-ld=lld -Wl,-headerpad_max_install_names"
        _BUILD_MKDLL="${CC} -fuse-ld=lld -Wl,-headerpad_max_install_names -shared -undefined dynamic_lookup"
      else
        # Linux: -Wl,-E exports symbols for ocamlnat (native toplevel)
        _BUILD_MKEXE="${CC} -Wl,-E"
        _BUILD_MKDLL="${CC} -shared"
      fi

      # These must be basename variables as they get embedded in binaries
      sed -i "s/^let asm = .*/let asm = {|${AS}|}/" "$config_file"
      sed -i "s/^let c_compiler = .*/let c_compiler = {|${CC}|}/" "$config_file"
      sed -i "s/^let mkexe = .*/let mkexe = {|${_BUILD_MKEXE}|}/" "$config_file"
      sed -i "s/^let mkdll = .*/let mkdll = {|${_BUILD_MKDLL}|}/" "$config_file"
      sed -i "s/^let mkmaindll = .*/let mkmaindll = {|${_BUILD_MKDLL}|}/" "$config_file"
    fi
  fi

  make world.opt -j"${CPU_COUNT}" > "${SRC_DIR}"/_logs/world.log 2>&1 || { cat "${SRC_DIR}"/_logs/world.log; exit 1; }

  if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
    make ocamltest -j "${CPU_COUNT}" > "${SRC_DIR}"/_logs/ocamltest.log 2>&1 || { cat "${SRC_DIR}"/_logs/ocamltest.log; }
    make tests > "${SRC_DIR}"/_logs/tests.log 2>&1 || { grep -3 'tests failed' "${SRC_DIR}"/_logs/tests.log; }
  fi

  make install > "${SRC_DIR}"/_logs/install.log 2>&1 || { cat "${SRC_DIR}"/_logs/install.log; exit 1; }
fi

# ============================================================================
# Post-install fixes (applies to both native and cross-compiled builds)
# ============================================================================

# Fix Makefile.config: replace BUILD_PREFIX paths with PREFIX
if [[ -f "${OCAML_PREFIX}/lib/ocaml/Makefile.config" ]]; then
  sed -i 's|-fdebug-prefix-map=[^ ]*||g' "${OCAML_PREFIX}/lib/ocaml/Makefile.config"
  sed -i "s#${BUILD_PREFIX}#${PREFIX}#g" "${OCAML_PREFIX}/lib/ocaml/Makefile.config"
fi

# non-Unix: replace symlinks with copies
if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  for bin in "${OCAML_PREFIX}"/bin/*; do
    if [[ -L "$bin" ]]; then
      target=$(readlink "$bin")
      rm "$bin"
      cp "${OCAML_PREFIX}/bin/${target}" "$bin"
    fi
  done
fi

# Fix bytecode wrapper shebangs (source function)
source "${RECIPE_DIR}/building/fix-ocamlrun-shebang.sh"
for bin in "${OCAML_PREFIX}"/bin/*; do
  [[ -f "$bin" ]] || continue
  [[ -L "$bin" ]] && continue

  # Check for ocamlrun reference (need 350 bytes for long conda placeholder paths)
  if head -c 350 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
    if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
      fix_ocamlrun_shebang "$bin" 2>/dev/null || true
    fi
    continue
  fi

  # Pure shell scripts: fix exec statements
  if file "$bin" 2>/dev/null | grep -qE "shell script|POSIX shell|text"; then
    sed -i "s#exec '\([^']*\)'#exec \1#" "$bin"
    sed -i "s#exec ${OCAML_PREFIX}/bin#exec \$(dirname \"\$0\")#" "$bin"
  fi
done

# Install activation scripts
for CHANGE in "activate" "deactivate"; do
  mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
  cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
done
