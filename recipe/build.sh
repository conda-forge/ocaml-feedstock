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

source "${RECIPE_DIR}"/building/common-functions.sh

mkdir -p "${SRC_DIR}"/_logs && export LOG_DIR="${SRC_DIR}"/_logs

# Enable dry-run and other options
export CONFIGURE=(./configure)
export MAKE=(make)

CONFIG_ARGS=(--enable-shared --disable-static PKG_CONFIG=false)

if [[ "1" == "1" ]]; then
  if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
    EXE=""
    SH_EXT="sh"
  else
    EXE=".exe"
    SH_EXT="bat"
  fi

  (
    OCAML_INSTALL_PREFIX="${SRC_DIR}"/_native && mkdir -p "${OCAML_INSTALL_PREFIX}"
    source "${RECIPE_DIR}"/building/build-native.sh
  )

  (
    export OCAML_PREFIX="${SRC_DIR}"/_native
    export OCAMLLIB="${OCAML_PREFIX}"/lib/ocaml

    OCAML_INSTALL_PREFIX="${SRC_DIR}"/_cross && mkdir -p "${OCAML_INSTALL_PREFIX}"
    source "${SRC_DIR}/_native_env.sh"
    source "${RECIPE_DIR}"/building/build-cross-compiler-new.sh
  )
  
  exit 0
else
  source "${RECIPE_DIR}"/building/build-archive.sh
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
