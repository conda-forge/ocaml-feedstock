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
#   1. Build native OCaml (build-native.sh)
#   2. Build cross-compilers (build-cross-compiler-new.sh)
#   → Package includes: native OCaml + cross-compilers
#
# Cross platforms (linux-aarch64, linux-ppc64le, osx-arm64):
#   Fast path: Stage 3 only (requires cross-compiler from channel)
#     - Use ocaml + cross-compiler from BUILD_PREFIX (build dependencies)
#     - Run build-cross-target-new.sh
#
#   Fallback: Full 3-stage using same scripts as native build
#     1. Build native OCaml (build-native.sh)
#     2. Build cross-compiler (build-cross-compiler-new.sh)
#     3. Build target (build-cross-target-new.sh)
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

# Platform detection
if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  EXE=""
  SH_EXT="sh"
else
  EXE=".exe"
  SH_EXT="bat"
fi


FAST_CROSS_PATH_SUCCESS=0
  
# ==============================================================================
# CROSS-PLATFORM BUILD
# ==============================================================================
if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
  echo ""
  echo "============================================================"
  echo "Cross-platform build: ${build_platform} -> ${target_platform}"
  echo "============================================================"

  # Determine cross-compiler target triplet
  case "${target_platform}" in
    linux-aarch64)  CROSS_TARGET="aarch64-conda-linux-gnu" ;;
    linux-ppc64le)  CROSS_TARGET="powerpc64le-conda-linux-gnu" ;;
    osx-arm64)      CROSS_TARGET="arm64-apple-darwin20.0.0" ;;
    *)
      echo "ERROR: Unsupported cross-compilation target: ${target_platform}"
      exit 1
      ;;
  esac

  # ---------------------------------------------------------------------------
  # Fast path: Try to use existing cross-compiler from channel
  # ---------------------------------------------------------------------------

  echo ""
  echo "=== Attempting fast cross-compilation path ==="
  echo "Looking for cross-compiler in BUILD_PREFIX..."

  # Check if cross-compiler exists (from ocaml build dependency)
  CROSS_COMPILER_DIR="${BUILD_PREFIX}/lib/ocaml-cross-compilers/${CROSS_TARGET}"
  if [[ -d "${CROSS_COMPILER_DIR}" ]]; then
    echo "Found cross-compiler: ${CROSS_COMPILER_DIR}"

    # Verify it has required files
    if [[ -f "${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma" ]]; then
      echo "Cross-compiler stdlib found, attempting Stage 3..."

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
        for var in $(compgen -v | grep -E '^(CONDA_OCAML_|NATIVE_|CROSS_)'); do
          unset "$var"
        done
      fi
    else
      echo "Cross-compiler stdlib not found at ${CROSS_COMPILER_DIR}/lib/ocaml/"
      echo "Cannot use fast path"
    fi
  else
    echo "No cross-compiler found in BUILD_PREFIX"
    echo "To enable fast path, add to recipe build dependencies:"
    echo "  - ocaml >=5.3"
  fi
fi

# ==============================================================================
# Native, cross-compiler & Full 3-stage cross-compiled target
# ==============================================================================
if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]] || [[ ${FAST_CROSS_PATH_SUCCESS} -eq 0 ]]; then
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
  
  if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
    (
      export OCAML_PREFIX="${SRC_DIR}"/_native_compiler
      export CROSS_COMPILER_PREFIX="${SRC_DIR}"/_xcross_compiler
      OCAML_INSTALL_PREFIX="${SRC_DIR}"/_target_compiler
      source "${SRC_DIR}/_native_compiler_env.sh"
      source "${SRC_DIR}/_xcross_compiler_${target_platform}_env.sh"
      source "${RECIPE_DIR}"/building/build-cross-target.sh
    )
  fi
fi

# ==============================================================================
# Transfer builds to PREFIX
# ==============================================================================
echo ""
echo "=== Transferring builds to PREFIX ==="

OCAML_INSTALL_PREFIX="${PREFIX}"

if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
  tar -C "${SRC_DIR}/_target_compiler" -cf - . | tar -C "${OCAML_INSTALL_PREFIX}" -xf -
else
  tar -C "${SRC_DIR}/_native_compiler" -cf - . | tar -C "${OCAML_INSTALL_PREFIX}" -xf -
  tar -C "${SRC_DIR}/_xcross_compiler" -cf - . | tar -C "${OCAML_INSTALL_PREFIX}" -xf -
fi

# ==============================================================================
# Fix ld.conf - update paths from build-time to install-time
# ==============================================================================
echo "=== Fixing ld.conf paths ==="

# Native OCaml ld.conf
if [[ -f "${OCAML_INSTALL_PREFIX}/lib/ocaml/ld.conf" ]]; then
  cat > "${OCAML_INSTALL_PREFIX}/lib/ocaml/ld.conf" << EOF
${OCAML_INSTALL_PREFIX}/lib/ocaml/stublibs
${OCAML_INSTALL_PREFIX}/lib/ocaml
EOF
  echo "  Fixed: lib/ocaml/ld.conf"
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

# ==============================================================================
# Install activation scripts with build-time tool substitution
# ==============================================================================
echo ""
echo "=== Installing activation scripts ==="

# Use basenames so scripts work regardless of install location
(
  if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
    source "${SRC_DIR}/_native_compiler_env.sh"
  else
    source "${SRC_DIR}/_target_compiler_${target_platform}_env.sh"
  fi
  
  for CHANGE in "activate" "deactivate"; do
    mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
    _SCRIPT="${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
    cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${_SCRIPT}" 2>/dev/null || continue
    # Replace @XX@ placeholders with actual build-time tools
    sed -i "s|@AR@|${CONDA_OCAML_AR}|g" "${_SCRIPT}"
    sed -i "s|@AS@|${CONDA_OCAML_AS}|g" "${_SCRIPT}"
    sed -i "s|@CC@|${CONDA_OCAML_CC}|g" "${_SCRIPT}"
    sed -i "s|@RANLIB@|${CONDA_OCAML_RANLIB}|g" "${_SCRIPT}"
    sed -i "s|@MKEXE@|${CONDA_OCAML_MKEXE}|g" "${_SCRIPT}"
    sed -i "s|@MKDLL@|${CONDA_OCAML_MKDLL}|g" "${_SCRIPT}"
  done
)

echo ""
echo "============================================================"
echo "Native platform build complete: ${target_platform}"
echo "============================================================"
