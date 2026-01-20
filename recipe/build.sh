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
      OCAML_TARGET_INSTALL_PREFIX="${SRC_DIR}"/_target_compiler
      set +e
      (
        set -e
        export OCAML_PREFIX="${BUILD_PREFIX}"
        export CROSS_COMPILER_PREFIX="${BUILD_PREFIX}"
        OCAML_INSTALL_PREFIX="${OCAML_TARGET_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
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
    echo "To enable fast path, add to recipe build dependencies:"
    echo "  - ocaml >=5.3"
  fi
fi

# ==============================================================================
# Native, cross-compiler & Full 3-stage cross-compiled target
# ==============================================================================
if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]] || [[ ${FAST_CROSS_PATH_SUCCESS} -eq 0 ]]; then
  # Stage 1: Build native OCaml
  OCAML_NATIVE_INSTALL_PREFIX="${SRC_DIR}"/_native_compiler
  (
    OCAML_INSTALL_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    source "${RECIPE_DIR}"/building/build-native.sh
  )

  # Stage 2: Build cross-compilers (using native OCaml)
  OCAML_XCROSS_INSTALL_PREFIX="${SRC_DIR}"/_xcross_compiler
  (
    export OCAML_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}"
    export OCAMLLIB="${OCAML_PREFIX}"/lib/ocaml

    OCAML_INSTALL_PREFIX="${OCAML_XCROSS_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    source "${SRC_DIR}/_native_compiler_env.sh"
    source "${RECIPE_DIR}"/building/build-cross-compiler.sh
  )
  
  if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
    # Stage 3: Cross-compile target binaries
    OCAML_TARGET_INSTALL_PREFIX="${SRC_DIR}"/_target_compiler
    (
      export OCAML_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}"
      export CROSS_COMPILER_PREFIX="${OCAML_XCROSS_INSTALL_PREFIX}"

      OCAML_INSTALL_PREFIX="${OCAML_TARGET_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
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

# Windows: Use cp -r instead of tar to avoid path escaping issues
# The tar command on Windows has issues with paths containing backslashes
if is_unix; then
  makefile_config="${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config"
  
  if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
    tar -C "${OCAML_TARGET_INSTALL_PREFIX}" -cf - . | tar -C "${OCAML_INSTALL_PREFIX}" -xf -
    sed -i "s#${OCAML_TARGET_INSTALL_PREFIX}#${OCAML_INSTALL_PREFIX}#g" "${makefile_config}"
  else
    tar -C "${OCAML_NATIVE_INSTALL_PREFIX}" -cf - . | tar -C "${OCAML_INSTALL_PREFIX}" -xf -
    tar -C "${OCAML_XCROSS_INSTALL_PREFIX}" -cf - . | tar -C "${OCAML_INSTALL_PREFIX}" -xf -
    sed -i "s#${OCAML_NATIVE_INSTALL_PREFIX}#${OCAML_INSTALL_PREFIX}#g" "${makefile_config}"
  fi
  cat > "${OCAML_INSTALL_PREFIX}/lib/ocaml/ld.conf" << EOF
${OCAML_INSTALL_PREFIX}/lib/ocaml/stublibs
${OCAML_INSTALL_PREFIX}/lib/ocaml
EOF
else
  # Windows: cp -r is more reliable than tar with Windows paths
  cp -r "${OCAML_NATIVE_INSTALL_PREFIX}/"* "${OCAML_INSTALL_PREFIX}/"
  makefile_config="${OCAML_INSTALL_PREFIX}/Library/lib/ocaml/Makefile.config"
  # Windows ld.conf - OCaml looks here for stublibs (DLLs)
  # Convert Unix-style paths (/c/path) to Windows-style (C:/path) for OCaml
  WIN_OCAMLLIB=$(echo "${OCAML_INSTALL_PREFIX}/Library/lib/ocaml" | sed 's#^/\([a-zA-Z]\)/#\1:/#')
  cat > "${OCAML_INSTALL_PREFIX}/Library/lib/ocaml/ld.conf" << EOF
${WIN_OCAMLLIB}/stublibs
${WIN_OCAMLLIB}
EOF
fi

sed -i "s#/.*build_env/bin/##g" "${makefile_config}"
sed -i 's#$(CC)#$(CONDA_OCAML_CC)#g' "${makefile_config}"

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

# Use basenames so scripts work regardless of install location
# CRITICAL: Always use NATIVE tools for activation scripts, even during cross-compilation
# The native ocamlc/ocamlopt binaries run on BUILD platform and need BUILD platform tools
# Cross-compilers have their own tool configuration baked in (config.generated.ml)
(
  # Source native compiler env if available (not present in Stage 3 fast path)
  if [[ -f "${SRC_DIR}/_native_compiler_env.sh" ]]; then
    source "${SRC_DIR}/_native_compiler_env.sh"
  else
    # Stage 3 fast path: use defaults from BUILD_PREFIX toolchain
    echo "  (Using BUILD_PREFIX defaults - Stage 3 fast path)"
    export CONDA_OCAML_AR=$(basename "${AR:-ar}")
    export CONDA_OCAML_AS=$(basename "${AS:-as}")
    export CONDA_OCAML_CC=$(basename "${CC:-cc}")
    export CONDA_OCAML_LD=$(basename "${LD:-ld}")
    export CONDA_OCAML_RANLIB=$(basename "${RANLIB:-ranlib}")
    export CONDA_OCAML_MKEXE="${CC:-cc}"
    export CONDA_OCAML_MKDLL="${CC:-cc} -shared"
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
    _SCRIPT="${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
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

echo ""
echo "============================================================"
echo "Native platform build complete: ${target_platform}"
echo "============================================================"
