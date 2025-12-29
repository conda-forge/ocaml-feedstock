#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

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

mkdir -p "${PREFIX}"/lib "${SRC_DIR}"/_logs

# Platform detection and OCAML_INSTALL_PREFIX setup
if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export OCAML_INSTALL_PREFIX="${PREFIX}"
  SH_EXT="sh"
else
  export OCAML_INSTALL_PREFIX="${PREFIX}"/Library
  SH_EXT="bat"
fi

CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir="${OCAML_INSTALL_PREFIX}"/share/man
  --with-target-bindir="${PREFIX}"/bin
  -prefix "${OCAML_INSTALL_PREFIX}"
)

if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
  if [[ -d "${BUILD_PREFIX}"/lib/ocaml-cross-compilers ]]; then
    echo "=== Cross-compiling with cross-compiler ==="
    source "${RECIPE_DIR}/building/cross-compile.sh"
  else
    # Cross-compilation: use unified 3-stage build script
    echo "=== Cross-compiling with unified 3-stage build script ==="
    source "${RECIPE_DIR}/building/3-stage-cross-compile.sh"
  fi
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

  # Platform-specific linker flags (Unix only - Windows uses different mechanism)
  if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
    export LIBRARY_PATH="${PREFIX}/lib:${LIBRARY_PATH:-}"
  fi
  if [[ "${target_platform}" == "osx-"* ]]; then
    export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld -Wl,-headerpad_max_install_names"
    export DYLD_LIBRARY_PATH="${PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
  fi

  if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
    CONFIG_ARGS+=(--enable-ocamltest)
  fi

  echo "=== Configuring native compiler ==="
  # PKG_CONFIG=false forces zstd fallback detection: simple "-lzstd" instead of
  # pkg-config's "-L/long/build/path -lzstd" which causes binary truncation issues
  PKG_CONFIG=false ./configure "${CONFIG_ARGS[@]}" > "${SRC_DIR}"/_logs/configure.log 2>&1 || { cat "${SRC_DIR}"/_logs/configure.log; exit 1; }

  # No-op for unix
  unix_noop_update_toolchain

  # Define CONDA_OCAML_* variables during build (used by patched config.generated.ml)
  export CONDA_OCAML_AS="${AS}"
  export CONDA_OCAML_CC="${CC}"
  export CONDA_OCAML_AR="${AR:-ar}"
  export CONDA_OCAML_RANLIB="${RANLIB:-ranlib}"
  export CONDA_OCAML_MKDLL="${CC} -shared"

  # Patch config.generated.ml to use CONDA_OCAML_* env vars (expanded at runtime)
  config_file="utils/config.generated.ml"
  if [[ -f "$config_file" ]]; then
    if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
      # Use environment variable references - users can customize via CONDA_OCAML_*
      sed -i 's/^let asm = .*/let asm = {|\$CONDA_OCAML_AS|}/' "$config_file"
      sed -i 's/^let c_compiler = .*/let c_compiler = {|\$CONDA_OCAML_CC|}/' "$config_file"
      sed -i 's/^let mkexe = .*/let mkexe = {|\$CONDA_OCAML_CC|}/' "$config_file"

      if [[ "${target_platform}" == "osx-"* ]]; then
        sed -i 's/^let mkdll = .*/let mkdll = {|\$CONDA_OCAML_MKDLL -undefined dynamic_lookup|}/' "$config_file"
        sed -i 's/^let mkmaindll = .*/let mkmaindll = {|\$CONDA_OCAML_MKDLL -undefined dynamic_lookup|}/' "$config_file"
        sed -i 's/^let ar = .*/let ar = {|\$CONDA_OCAML_AR|}/' "$config_file"
        sed -i 's/^let ranlib = .*/let ranlib = {|\$CONDA_OCAML_RANLIB|}/' "$config_file"
      else
        # Linux
        sed -i 's/^let mkdll = .*/let mkdll = {|\$CONDA_OCAML_MKDLL|}/' "$config_file"
        sed -i 's/^let mkmaindll = .*/let mkmaindll = {|\$CONDA_OCAML_MKDLL|}/' "$config_file"
        sed -i 's/^let ar = .*/let ar = {|\$CONDA_OCAML_AR|}/' "$config_file"
        sed -i 's/^let ranlib = .*/let ranlib = {|\$CONDA_OCAML_RANLIB|}/' "$config_file"
      fi

      # Remove -L paths from bytecomp_c_libraries (embedded in ocamlc binary)
      sed -i 's|-L[^ ]*||g' "$config_file"
    fi
  fi

  # Remove -L paths from Makefile.config (embedded in ocamlc binary)
  config_file="Makefile.config"
  if [[ -f "${config_file}" ]]; then
    sed -i 's|-fdebug-prefix-map=[^ ]*||g' "${config_file}"
    sed -i 's|-L[^ ]*||g' "${config_file}"
  fi

  echo "=== Compiling native compiler ==="
  make world.opt -j"${CPU_COUNT}" > "${SRC_DIR}"/_logs/world.log 2>&1 || { cat "${SRC_DIR}"/_logs/world.log; exit 1; }

  if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
    echo "=== Running tests ==="
    make ocamltest -j "${CPU_COUNT}" > "${SRC_DIR}"/_logs/ocamltest.log 2>&1 || { cat "${SRC_DIR}"/_logs/ocamltest.log; }
    make tests > "${SRC_DIR}"/_logs/tests.log 2>&1 || { grep -3 'tests failed' "${SRC_DIR}"/_logs/tests.log; }
  fi

  echo "=== Installing native compiler ==="
  make install > "${SRC_DIR}"/_logs/install.log 2>&1 || { cat "${SRC_DIR}"/_logs/install.log; exit 1; }
fi

# ============================================================================
# Cross-compilers
# ============================================================================

source "${RECIPE_DIR}"/building/build-cross-compiler.sh

# ============================================================================
# Post-install fixes (applies to both native and cross-compiled builds)
# ============================================================================

# Fix Makefile.config: replace BUILD_PREFIX paths with PREFIX
if [[ -f "${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config" ]]; then
  sed -i "s#${BUILD_PREFIX}#${PREFIX}#g" "${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config"
fi

# non-Unix: replace symlinks with copies
if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  for bin in "${OCAML_INSTALL_PREFIX}"/bin/*; do
    if [[ -L "$bin" ]]; then
      target=$(readlink "$bin")
      rm "$bin"
      cp "${OCAML_INSTALL_PREFIX}/bin/${target}" "$bin"
    fi
  done
fi

# Fix bytecode wrapper shebangs (source function)
source "${RECIPE_DIR}/building/fix-ocamlrun-shebang.sh"
for bin in "${OCAML_INSTALL_PREFIX}"/bin/* "${OCAML_INSTALL_PREFIX}"/lib/ocaml-cross-compilers/*/bin/*; do
  [[ -f "$bin" ]] || continue
  [[ -L "$bin" ]] && continue

  # Check for ocamlrun reference (need 350 bytes for long conda placeholder paths)
  if head -c 350 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
    if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
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
# Use basenames so scripts work regardless of install location
_BUILD_CC=$(basename "${CC:-cc}")
_BUILD_AS=$(basename "${AS:-as}")
_BUILD_AR=$(basename "${AR:-ar}")
_BUILD_RANLIB=$(basename "${RANLIB:-ranlib}")

for CHANGE in "activate" "deactivate"; do
  mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
  _SCRIPT="${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
  cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${_SCRIPT}" 2>/dev/null || continue
  # Replace @XX@ placeholders with actual build-time tools
  sed -i "s|@CC@|${_BUILD_CC}|g" "${_SCRIPT}"
  sed -i "s|@AS@|${_BUILD_AS}|g" "${_SCRIPT}"
  sed -i "s|@AR@|${_BUILD_AR}|g" "${_SCRIPT}"
  sed -i "s|@RANLIB@|${_BUILD_RANLIB}|g" "${_SCRIPT}"
done
