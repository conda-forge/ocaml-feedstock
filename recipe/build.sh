#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# OCaml Build Script
# ==============================================================================
#
# BUILD FLOW:
#
# Native platforms (linux-64, osx-64):
#   Build native OCaml (build-native.sh)
#   OR
#   Build cross-compilers (build-cross-compiler.sh)
#
# Cross platforms (linux-aarch64, linux-ppc64le, osx-arm64):
#   Fast path: Stage 3 only (requires cross-compiler from channel)
#     - Use ocaml + cross-compiler from BUILD_PREFIX (build dependencies)
#     - Run build-cross-target.sh
#
#   Fallback: Full 3-stage using same scripts as native build
#     1. Build native OCaml (build-native.sh)
#     2. Build cross-compiler (build-cross-compiler.sh)
#     3. Build target (build-cross-target.sh)
#
# ==============================================================================

# ==============================================================================
# Ensure we're using conda bash 5.2+, not system bash
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

  # This is needed to preset the install path in binaries and facilitate CONDA relocation
  --with-target-bindir="${PREFIX}"/bin

  PKG_CONFIG=false
)


if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
  # ==============================================================================
  # NATIVE COMPILER
  # ==============================================================================
  if [[ ${PKG_NAME} == "ocaml_${target_platform}" ]]; then
    (
      OCAML_INSTALL_PREFIX="${SRC_DIR}"/_native_compiler && mkdir -p "${OCAML_INSTALL_PREFIX}"
      source "${RECIPE_DIR}"/building/build-native.sh
      if is_unix; then
        tar -C "${SRC_DIR}/_native_compiler" -cf - . | tar -C "${PREFIX}" -xf -
      else
        cp -r "${SRC_DIR}/_native_compiler/"* "${PREFIX}/"
      fi
    )

  # ==============================================================================
  # CROSS-COMPILER
  # ==============================================================================
  elif [[ ${PKG_NAME} == "ocaml-cross-compiler_"* ]]; then
    (
      export OCAML_PREFIX="${BUILD_PREFIX}"
      export OCAMLLIB="${OCAML_PREFIX}"/lib/ocaml

      if [[ -d "${OCAMLLIB}" ]]; then
        OCAML_INSTALL_PREFIX="${SRC_DIR}"/_xcross_compiler && mkdir -p "${OCAML_INSTALL_PREFIX}"
        OCAML_CROSS_PLATFORM=$(echo ${PKG_NAME} | sed 's/ocaml-cross-compiler_//' )
        source "${RECIPE_DIR}"/building/build-cross-compiler.sh

        tar -C "${SRC_DIR}/_xcross_compiler" -cf - . | tar -C "${PREFIX}" -xf -
      else
        echo "Ocaml native compiler required, install in build requirements"
        exit 1
      fi
    )
  else
    echo "${PKG_NAME} is not supported, (ocaml-cross-compiler_${build_platform})"
    exit 1
  fi
else
  # ==============================================================================
  # CROSS-PLATFORM COMPILER
  # ==============================================================================
  FAST_CROSS_PATH_SUCCESS=0
 
  # ---------------------------------------------------------------------------
  # Fast path: Try to use existing cross-compiler from channel
  # ---------------------------------------------------------------------------

  # Check if cross-compiler exists (from ocaml build dependency)
  CROSS_COMPILER_DIR="${BUILD_PREFIX}/lib/ocaml-cross-compilers/${CONDA_TOOLCHAIN_HOST}"
  if [[ -d "${CROSS_COMPILER_DIR}" ]]; then
    # Verify it has required files
    if [[ -f "${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma" ]]; then
      # Try Stage 3 - may fail if API changed between versions
      set +e
      (
        set -e
        export OCAML_PREFIX="${BUILD_PREFIX}"
        export CROSS_COMPILER_PREFIX="${BUILD_PREFIX}"
        OCAML_INSTALL_PREFIX="${SRC_DIR}"/_target_compiler
        source "${RECIPE_DIR}"/building/build-cross-target.sh
      )
      STAGE3_RC=$?
      set -e

      if [[ ${STAGE3_RC} -eq 0 ]]; then
        FAST_CROSS_PATH_SUCCESS=1
      else
        # Clean up any partial build artifacts
        make distclean >/dev/null 2>&1 || true
        for var in $(compgen -v | grep -E '^(CONDA_OCAML_|NATIVE_|CROSS_|OCAML_|OCAMLLIB)'); do
          unset "$var"
        done
      fi
    else
      echo "Cross-compiler stdlib not found at ${CROSS_COMPILER_DIR}/lib/ocaml/"
    fi
  else
    echo "No cross-compiler found in BUILD_PREFIX"
  fi
  
  # ==============================================================================
  # Full 3-stage cross-compiled target
  # ==============================================================================
  if [[ ${FAST_CROSS_PATH_SUCCESS} -eq 0 ]]; then
    # Stage 1: Build native OCaml
    (
      OCAML_INSTALL_PREFIX="${SRC_DIR}"/_native_compiler && mkdir -p "${OCAML_INSTALL_PREFIX}"
      source "${RECIPE_DIR}"/building/build-native.sh
    )

    # Stage 2: Build cross-compilers (using native OCaml)
    (
      export OCAML_PREFIX="${SRC_DIR}"/_native_compiler
      export OCAMLLIB="${OCAML_PREFIX}"/lib/ocaml

      OCAML_INSTALL_PREFIX="${SRC_DIR}"/_xcross_compiler && mkdir -p "${OCAML_INSTALL_PREFIX}"
      source "${SRC_DIR}/_native_compiler_env.sh"
      source "${RECIPE_DIR}"/building/build-cross-compiler.sh
    )
 
    (
      export OCAML_PREFIX="${SRC_DIR}"/_native_compiler
      export CROSS_COMPILER_PREFIX="${SRC_DIR}"/_xcross_compiler
      OCAML_INSTALL_PREFIX="${SRC_DIR}"/_target_compiler
      source "${SRC_DIR}/_native_compiler_env.sh"
      source "${SRC_DIR}/_xcross_compiler_${target_platform}_env.sh"
      source "${RECIPE_DIR}"/building/build-cross-target.sh
    )
  fi
  
  tar -C "${SRC_DIR}/_target_compiler" -cf - . | tar -C "${PREFIX}" -xf -
fi

# ==============================================================================
# Post-Install
# ==============================================================================

OCAML_INSTALL_PREFIX="${PREFIX}"

# Native OCaml ld.conf
if [[ -f "${OCAML_INSTALL_PREFIX}/lib/ocaml/ld.conf" ]]; then
  cat > "${OCAML_INSTALL_PREFIX}/lib/ocaml/ld.conf" << EOF
${OCAML_INSTALL_PREFIX}/lib/ocaml/stublibs
${OCAML_INSTALL_PREFIX}/lib/ocaml
EOF
fi

# Cross-compiler ld.conf files
for ldconf in "${OCAML_INSTALL_PREFIX}"/lib/ocaml-cross-compilers/*/lib/ocaml/ld.conf; do
  [[ -f "$ldconf" ]] || continue
  cross_dir=$(dirname $(dirname $(dirname "$ldconf")))
  cat > "$ldconf" << EOF
${cross_dir}/lib/ocaml/stublibs
${cross_dir}/lib/ocaml
EOF
  echo "  Fixed: ${ldconf#${OCAML_INSTALL_PREFIX}/}"
done

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

# Fix bytecode wrapper shebangs (source function)
source "${RECIPE_DIR}/building/fix-ocamlrun-shebang.sh"
for bin in "${OCAML_INSTALL_PREFIX}"/bin/* "${OCAML_INSTALL_PREFIX}"/lib/ocaml-cross-compilers/*/bin/*; do
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

if [[ ${PKG_NAME} != "ocaml-cross-compiler_"* ]]; then
  (
    # Set OCAML_PREFIX for env script (uses ${OCAML_PREFIX}/bin for PATH)
    export OCAML_PREFIX="${PREFIX}"

    if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
      source "${SRC_DIR}/_native_compiler_env.sh"
    else
      source "${SRC_DIR}/_target_compiler_${target_platform}_env.sh"
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
      
      # PKG_NAME now includes the platform
      pkg_name=$(echo "${PKG_NAME}" | sed "s#_${target_platform}##")
      _SCRIPT="${PREFIX}/etc/conda/${CHANGE}.d/${pkg_name}_${CHANGE}.${SH_EXT}"
      
      cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${_SCRIPT}" 2>/dev/null || continue
      # Replace @XX@ placeholders with runtime-safe basenames (not full build paths)
      sed -i "s|@AR@|$(basename "${CONDA_OCAML_AR}")|g" "${_SCRIPT}"
      sed -i "s|@AS@|$(basename "${CONDA_OCAML_AS}")|g" "${_SCRIPT}"
      sed -i "s|@CC@|$(basename "${CONDA_OCAML_CC}")|g" "${_SCRIPT}"
      sed -i "s|@RANLIB@|$(basename "${CONDA_OCAML_RANLIB}")|g" "${_SCRIPT}"
      sed -i "s|@MKEXE@|$(_basename_cmd "${CONDA_OCAML_MKEXE}")|g" "${_SCRIPT}"
      sed -i "s|@MKDLL@|$(_basename_cmd "${CONDA_OCAML_MKDLL}")|g" "${_SCRIPT}"
    done
  )
fi

echo ""
echo "============================================================"
echo "Native platform build complete: ${target_platform}"
echo "============================================================"
