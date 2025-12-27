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

# ==============================================================================
# CROSS-COMPILATION ROUTING
# ==============================================================================
# When build_platform != target_platform, we need cross-compilation.
# Two strategies available:
#   1. Stage 3 only: Use pre-built cross-compiler (fast, ~10 min)
#   2. 3-stage bootstrap: Build everything from scratch (slow, ~40 min)
#
# conda-forge CI runs all platforms in parallel, so cross-compiler from
# another platform won't be available on first build. We check the channel
# and fall back to 3-stage bootstrap if not found.
# ==============================================================================
if [[ "${build_platform:-0}" != "0" ]] && [[ "${build_platform:-}" != "${target_platform}" ]]; then
  echo "=== Cross-compilation detected: ${build_platform:-} -> ${target_platform} ==="

  _CROSS_PKG="ocaml-cross-compiler_${target_platform}"
  _CROSS_VERSION="${PKG_VERSION}"
  _CROSS_COMPILER_DIR="${BUILD_PREFIX}/ocaml-cross-compilers/${host_alias:-}"
  _USE_STAGE3=0

  # Check if cross-compiler is available on conda-forge channel
  echo "Checking for ${_CROSS_PKG}==${_CROSS_VERSION} on conda-forge..."
  if mamba search -c conda-forge "${_CROSS_PKG}==${_CROSS_VERSION}" --json 2>/dev/null | grep -q '"version"'; then
    echo "Found ${_CROSS_PKG} on conda-forge, attempting install..."
    if mamba install -p "${BUILD_PREFIX}" -c conda-forge "${_CROSS_PKG}==${_CROSS_VERSION}" --yes --quiet 2>/dev/null; then
      if [[ -d "${_CROSS_COMPILER_DIR}" ]] && [[ -x "${BUILD_PREFIX}/bin/${host_alias:-}-ocamlopt" ]]; then
        echo "Cross-compiler installed successfully"
        _USE_STAGE3=1
      fi
    fi
  fi

  if [[ "${_USE_STAGE3}" == "1" ]]; then
    echo "Using Stage 3 only (fast path, ~10 min)"
    source "${RECIPE_DIR}/building/cross-compile.sh"
  else
    echo "Cross-compiler not available on channel"
    echo "Using 3-stage bootstrap (self-sufficient path, ~40 min)"
    source "${RECIPE_DIR}/building/3-stage-cross-compile.sh"
  fi

  # Cross-compilation scripts handle everything including post-install
  # Install activation scripts and exit
  for CHANGE in "activate" "deactivate"; do
    mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
    cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}" 2>/dev/null || true
  done
  exit 0
fi

# ==============================================================================
# NATIVE BUILD (build_platform == target_platform)
# ==============================================================================
echo "=== Native build for ${target_platform} ==="

CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir="${OCAML_INSTALL_PREFIX}"/share/man
  --with-target-bindir="${PREFIX}"/bin
  -prefix "${OCAML_INSTALL_PREFIX}"
)

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
  export LDFLAGS="${LDFLAGS:-}"
fi

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH:-}"

if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
  CONFIG_ARGS+=(--enable-ocamltest)
fi

echo "=== Configuring native compiler ==="
./configure "${CONFIG_ARGS[@]}" > "${SRC_DIR}"/_logs/configure.log 2>&1 || { cat "${SRC_DIR}"/_logs/configure.log; exit 1; }

# No-op for unix
unix_noop_update_toolchain

# Patch config.generated.ml with compiler paths for build
config_file="utils/config.generated.ml"
if [[ -f "${config_file}" ]]; then
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
    sed -i "s/^let asm = .*/let asm = {|${AS}|}/" "${config_file}"
    sed -i "s/^let c_compiler = .*/let c_compiler = {|${CC}|}/" "${config_file}"
    sed -i "s/^let mkexe = .*/let mkexe = {|${_BUILD_MKEXE}|}/" "${config_file}"
    sed -i "s/^let mkdll = .*/let mkdll = {|${_BUILD_MKDLL}|}/" "${config_file}"
    sed -i "s/^let mkmaindll = .*/let mkmaindll = {|${_BUILD_MKDLL}|}/" "${config_file}"
    
    # Remove build locations that are backed into binaries - Generates 'Invalid argument' during opam
    sed -i 's#-L[^ ]*##g' "${config_file}"
  fi
fi

# Fix Makefile.config: replace BUILD_PREFIX paths with PREFIX
config_file="Makefile.config"
if [[ -f "${config_file}" ]]; then
  sed -i 's|-fdebug-prefix-map=[^ ]*||g' "${config_file}"
  sed -i "s#-L[^ ]*##g" "${config_file}"
fi

echo "=== Compiling native compiler ==="
make world.opt -j"${CPU_COUNT}" > "${SRC_DIR}"/_logs/world.log 2>&1 || { cat "${SRC_DIR}"/_logs/world.log; exit 1; }

if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
  echo "=== Building tests for ${target_platform} ==="
  make ocamltest -j "${CPU_COUNT}" > "${SRC_DIR}"/_logs/ocamltest.log 2>&1 || { cat "${SRC_DIR}"/_logs/ocamltest.log; }
  make tests > "${SRC_DIR}"/_logs/tests.log 2>&1 || { grep -3 'tests failed' "${SRC_DIR}"/_logs/tests.log; }
fi

echo "=== Installing native compiler ==="
make install > "${SRC_DIR}"/_logs/install.log 2>&1 || { cat "${SRC_DIR}"/_logs/install.log; exit 1; }

# ============================================================================
# Post-install fixes (applies to both native and cross-compiled builds)
# ============================================================================

# Fix Makefile.config: replace BUILD_PREFIX paths with PREFIX
config_file="${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config"
if [[ -f "${config_file}" ]]; then
  sed -i "s#${BUILD_PREFIX}#${PREFIX}#g" "${config_file}"
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
for bin in "${OCAML_INSTALL_PREFIX}"/bin/* "${OCAML_INSTALL_PREFIX}"/ocaml-cross-compilers/*/bin/*; do
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

# Install activation scripts
for CHANGE in "activate" "deactivate"; do
  mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
  cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}" 2>/dev/null
done
