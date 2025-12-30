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

export OCAML_INSTALL_PREFIX="${PREFIX}"
# Simplify compiler paths to basenames (hardcoded in binaries)
export AR=$(basename "${AR}")
export AS=$(basename "${AS}")
export CC=$(basename "${CC}")
export ASPP="$CC -c"
export RANLIB=$(basename "${RANLIB}")

if [[ "${target_platform}" == "osx-"* ]]; then
  # macOS: MUST use LLVM ar/ranlib - GNU ar format incompatible with ld64
  # Use full path to ensure we don't pick up binutils ar from PATH
  _AR=$(find "${BUILD_PREFIX}" "${PREFIX}" -name "llvm-ar" -type f 2>/dev/null | head -1)
  if [[ -n "${_AR}" ]]; then
    export AR=$(basename ${_AR})
    export RANLIB="${_AR/-as/-ranlib}"
  else
    echo "ERROR: Install llvm-ar/llvm-ranlib" && exit 1
  fi
  export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld"
  export DYLD_LIBRARY_PATH="${PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
fi


# Define CONDA_OCAML_* variables
export CONDA_OCAML_AR="${AR}"
export CONDA_OCAML_AS="${AS}"
export CONDA_OCAML_CC="${CC}"
export CONDA_OCAML_RANLIB="${RANLIB}"
export CONDA_OCAML_MKEXE="${CC}"
export CONDA_OCAML_MKDLL="${CC} -shared"

CONFIG_ARGS=(--enable-shared)

# Platform detection and OCAML_INSTALL_PREFIX setup
if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export LIBRARY_PATH="${PREFIX}/lib:${LIBRARY_PATH:-}"
  # PKG_CONFIG=false forces zstd fallback detection: simple "-lzstd" instead of
  # pkg-config's "-L/long/build/path -lzstd" which causes binary truncation issues
  CONFIG_ARGS+=(PKG_CONFIG=false)
  SH_EXT="sh"
else
  export OCAML_INSTALL_PREFIX="${OCAML_INSTALL_PREFIX}"/Library
  export PKG_CONFIG_PATH="${OCAML_INSTALL_PREFIX}/lib/pkgconfig;${PREFIX}/lib/pkgconfig;${PKG_CONFIG_PATH:-}"
  export LIBRARY_PATH="${OCAML_INSTALL_PREFIX}/lib;${PREFIX}/lib;${LIBRARY_PATH:-}"
  CONFIG_ARGS+=(LDFLAGS="-L${OCAML_INSTALL_PREFIX}/lib -L${PREFIX}/lib ${LDFLAGS:-}")
  export MINGW_CC=$(find "${BUILD_PREFIX}" -name "x86_64-w64-mingw32-gcc.exe" -type f 2>/dev/null | head -1)
  if [[ -n "${MINGW_CC}" ]]; then
    MINGW_DIR=$(dirname "${MINGW_CC}") && export PATH="${MINGW_DIR}:${PATH}"
  else
    echo "ERROR: non-unix build developped with GCC" && exit 1
  fi
  SH_EXT="bat"
fi

CONFIG_ARGS+=(
  --mandir="${OCAML_INSTALL_PREFIX}"/share/man
  --with-target-bindir="${OCAML_INSTALL_PREFIX}"/bin
  --with-target-sh="${OCAML_INSTALL_PREFIX}"/bin/bash
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

  if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
    CONFIG_ARGS+=(--enable-ocamltest)
  fi

  echo "=== Configuring native compiler ==="
  ./configure "${CONFIG_ARGS[@]}" > "${SRC_DIR}"/_logs/configure.log 2>&1 || { cat "${SRC_DIR}"/config.log; exit 1; }
  cat "${SRC_DIR}"/_logs/configure.log

  # No-op for unix
  unix_noop_update_toolchain

  # Patch config.generated.ml to use CONDA_OCAML_* env vars (expanded at runtime)
  config_file="utils/config.generated.ml"
  if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
    # Use environment variable references - users can customize via CONDA_OCAML_*
    sed -i 's/^let asm = .*/let asm = {|\$CONDA_OCAML_AS|}/' "$config_file"
    sed -i 's/^let c_compiler = .*/let c_compiler = {|\$CONDA_OCAML_CC|}/' "$config_file"
    sed -i 's/^let mkexe = .*/let mkexe = {|\$CONDA_OCAML_CC|}/' "$config_file"
    sed -i 's/^let ar = .*/let ar = {|\$CONDA_OCAML_AR|}/' "$config_file"
    sed -i 's/^let ranlib = .*/let ranlib = {|\$CONDA_OCAML_RANLIB|}/' "$config_file"
    sed -i 's/^let mkdll = .*/let mkdll = {|\$CONDA_OCAML_MKDLL|}/' "$config_file"
    sed -i 's/^let mkmaindll = .*/let mkmaindll = {|\$CONDA_OCAML_MKDLL|}/' "$config_file"

    if [[ "${target_platform}" == "osx-"* ]]; then
      sed -i 's/^(let mk(?:main)?dll = .*_MKDLL)(.*)/\1 -undefined dynamic_lookup\2/' "$config_file"
    fi

    # Remove -L paths from bytecomp_c_libraries (embedded in ocamlc binary)
    sed -i 's|-L[^ ]*||g' "$config_file"
  fi

  # Remove -L paths from Makefile.config (embedded in ocamlc binary)
  config_file="Makefile.config"
  sed -i 's|-fdebug-prefix-map=[^ ]*||g' "${config_file}"
  sed -i 's|-L[^ ]*||g' "${config_file}"

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
_BUILD_CC=$(basename "${CC}")
_BUILD_AS=$(basename "${AS}")
_BUILD_AR=$(basename "${AR}")
_BUILD_RANLIB=$(basename "${RANLIB}")

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
