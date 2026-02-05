#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# OCaml Build Script - GCC Pattern Multi-Output
# ==============================================================================
#
# BUILD MODE DETECTION (gcc-style):
#
# Package name indicates TARGET platform (e.g., ocaml_linux-aarch64)
# Build behavior depends on BUILD platform:
#
# MODE="native":
#   CROSS_TARGET_PLATFORM == target_platform (e.g., ocaml_linux-64 on linux-64)
#   → Build native OCaml compiler
#
# MODE="cross-compiler":
#   CROSS_TARGET_PLATFORM != target_platform (e.g., ocaml_linux-aarch64 on linux-64)
#   → Build cross-compiler (native binaries producing target code)
#
# MODE="cross-target":
#   CROSS_TARGET_PLATFORM == target_platform AND CONDA_BUILD_CROSS_COMPILATION == 1
#   (e.g., ocaml_linux-aarch64 built ON linux-aarch64 via cross-compilation)
#   → Build using cross-compiler from BUILD_PREFIX
#
# Environment variables from recipe.yaml:
#   CROSS_TARGET_PLATFORM:  Target platform this package produces code for
#   TARGET_TRIPLET: Cross-compiler triplet for this target
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
# CROSS_TARGET_PLATFORM and TARGET_TRIPLET are set by recipe.yaml env section

echo ""
echo "============================================================"
echo "OCaml Build Script - Mode Detection"
echo "============================================================"
echo "  CROSS_TARGET_PLATFORM:      ${CROSS_TARGET_PLATFORM:-<not set>}"
echo "  TARGET_TRIPLET:     ${TARGET_TRIPLET:-<not set>}"
echo "  target_platform: ${target_platform}"
echo "  build_platform:  ${build_platform:-target_platform}"
echo "  CONDA_BUILD_CROSS_COMPILATION: ${CONDA_BUILD_CROSS_COMPILATION:-0}"
echo "============================================================"

# Validate required environment variables
if [[ -z "${CROSS_TARGET_PLATFORM:-}" ]]; then
  echo "ERROR: CROSS_TARGET_PLATFORM not set. This should be set by recipe.yaml"
  exit 1
fi
if [[ -z "${TARGET_TRIPLET:-}" ]]; then
  echo "ERROR: TARGET_TRIPLET not set. This should be set by recipe.yaml"
  exit 1
fi

# Determine build mode
if [[ "${CROSS_TARGET_PLATFORM}" != "${target_platform}" ]]; then
  # Building cross-compiler (e.g., ocaml_linux-aarch64 on linux-64)
  BUILD_MODE="cross-compiler"
  echo ""
  echo ">>> BUILD MODE: cross-compiler"
  echo ">>> Building ${CROSS_TARGET_PLATFORM} cross-compiler on ${target_platform}"
  echo ""
elif [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
  # Building cross-compiled native (e.g., ocaml_linux-aarch64 ON linux-aarch64)
  BUILD_MODE="cross-target"
  echo ""
  echo ">>> BUILD MODE: cross-target"
  echo ">>> Cross-compiling ${CROSS_TARGET_PLATFORM} native compiler from ${build_platform:-target_platform}"
  echo ""
else
  # Building native (e.g., ocaml_linux-64 on linux-64)
  BUILD_MODE="native"
  echo ""
  echo ">>> BUILD MODE: native"
  echo ">>> Building native ${CROSS_TARGET_PLATFORM} compiler"
  echo ""
fi

# ==============================================================================
# MODE: native
# Build native OCaml compiler
# ==============================================================================
if [[ "${BUILD_MODE}" == "native" ]]; then
  OCAML_NATIVE_INSTALL_PREFIX="${SRC_DIR}"/_native_compiler
  (
    OCAML_INSTALL_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    source "${RECIPE_DIR}"/building/build-native.sh
  )

  # Transfer to PREFIX
  echo ""
  echo "=== Transferring native build to PREFIX ==="
  OCAML_INSTALL_PREFIX="${PREFIX}"

  if is_unix; then
    tar -C "${OCAML_NATIVE_INSTALL_PREFIX}" -cf - . | tar -C "${OCAML_INSTALL_PREFIX}" -xf -
    makefile_config="${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config"
    sed -i "s#${OCAML_NATIVE_INSTALL_PREFIX}#${OCAML_INSTALL_PREFIX}#g" "${makefile_config}"
    cat > "${OCAML_INSTALL_PREFIX}/lib/ocaml/ld.conf" << EOF
${OCAML_INSTALL_PREFIX}/lib/ocaml/stublibs
${OCAML_INSTALL_PREFIX}/lib/ocaml
EOF
  else
    # Windows: cp -rL dereferences symlinks
    cp -rL "${OCAML_NATIVE_INSTALL_PREFIX}/"* "${OCAML_INSTALL_PREFIX}/"
    makefile_config="${OCAML_INSTALL_PREFIX}/Library/lib/ocaml/Makefile.config"
    WIN_OCAMLLIB=$(echo "${OCAML_INSTALL_PREFIX}/Library/lib/ocaml" | sed 's#^/\([a-zA-Z]\)/#\1:/#')
    cat > "${OCAML_INSTALL_PREFIX}/Library/lib/ocaml/ld.conf" << EOF
${WIN_OCAMLLIB}/stublibs
${WIN_OCAMLLIB}
EOF
  fi

  sed -i "s#/.*build_env/bin/##g" "${makefile_config}"
  sed -i 's#$(CC)#$(CONDA_OCAML_CC)#g' "${makefile_config}"

fi

# ==============================================================================
# MODE: cross-compiler
# Build cross-compiler (native binaries producing target code)
# ==============================================================================
if [[ "${BUILD_MODE}" == "cross-compiler" ]]; then
  # Stage 1: Build native OCaml (needed to build cross-compiler)
  OCAML_NATIVE_INSTALL_PREFIX="${SRC_DIR}"/_native_compiler
  (
    OCAML_INSTALL_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    source "${RECIPE_DIR}"/building/build-native.sh
  )

  # Stage 2: Build cross-compiler for CROSS_TARGET_PLATFORM
  OCAML_XCROSS_INSTALL_PREFIX="${SRC_DIR}"/_xcross_compiler
  (
    export OCAML_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}"
    export OCAMLLIB="${OCAML_PREFIX}"/lib/ocaml
    # Tell cross-compiler builder which target to build
    export CROSS_TARGET_PLATFORM="${CROSS_TARGET_PLATFORM}"
    export TARGET_TRIPLET="${TARGET_TRIPLET}"

    OCAML_INSTALL_PREFIX="${OCAML_XCROSS_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
    source "${SRC_DIR}/_native_compiler_env.sh"
    source "${RECIPE_DIR}"/building/build-cross-compiler.sh
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
  CROSS_TARGET="${TARGET_TRIPLET}"

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
    echo "Falling back to full 3-stage build"
  fi

  # Fallback: Full 3-stage build
  if [[ ${FAST_CROSS_PATH_SUCCESS} -eq 0 ]]; then
    echo ""
    echo "=== Full 3-stage cross-target build ==="

    # Stage 1: Build native OCaml (on build platform)
    OCAML_NATIVE_INSTALL_PREFIX="${SRC_DIR}"/_native_compiler
    (
      OCAML_INSTALL_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
      source "${RECIPE_DIR}"/building/build-native.sh
    )

    # Stage 2: Build cross-compiler
    OCAML_XCROSS_INSTALL_PREFIX="${SRC_DIR}"/_xcross_compiler
    (
      export OCAML_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}"
      export OCAMLLIB="${OCAML_PREFIX}"/lib/ocaml
      export CROSS_TARGET_PLATFORM="${CROSS_TARGET_PLATFORM}"
      export TARGET_TRIPLET="${TARGET_TRIPLET}"

      OCAML_INSTALL_PREFIX="${OCAML_XCROSS_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
      source "${SRC_DIR}/_native_compiler_env.sh"
      source "${RECIPE_DIR}"/building/build-cross-compiler.sh
    )

    # Stage 3: Cross-compile target binaries
    OCAML_TARGET_INSTALL_PREFIX="${SRC_DIR}"/_target_compiler
    (
      export OCAML_PREFIX="${OCAML_NATIVE_INSTALL_PREFIX}"
      export CROSS_COMPILER_PREFIX="${OCAML_XCROSS_INSTALL_PREFIX}"

      OCAML_INSTALL_PREFIX="${OCAML_TARGET_INSTALL_PREFIX}" && mkdir -p "${OCAML_INSTALL_PREFIX}"
      source "${SRC_DIR}/_native_compiler_env.sh"
      source "${SRC_DIR}/_xcross_compiler_${CROSS_TARGET_PLATFORM}_env.sh"
      source "${RECIPE_DIR}"/building/build-cross-target.sh
    )
  fi

  # Transfer to PREFIX
  echo ""
  echo "=== Transferring cross-target build to PREFIX ==="
  OCAML_INSTALL_PREFIX="${PREFIX}"

  tar -C "${OCAML_TARGET_INSTALL_PREFIX}" -cf - . | tar -C "${OCAML_INSTALL_PREFIX}" -xf -
  makefile_config="${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config"
  sed -i "s#${OCAML_TARGET_INSTALL_PREFIX}#${OCAML_INSTALL_PREFIX}#g" "${makefile_config}"
  sed -i "s#/.*build_env/bin/##g" "${makefile_config}"
  sed -i 's#$(CC)#$(CONDA_OCAML_CC)#g' "${makefile_config}"
  cat > "${OCAML_INSTALL_PREFIX}/lib/ocaml/ld.conf" << EOF
${OCAML_INSTALL_PREFIX}/lib/ocaml/stublibs
${OCAML_INSTALL_PREFIX}/lib/ocaml
EOF
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

  # Fix bytecode wrapper shebangs (source function)
  source "${RECIPE_DIR}/building/fix-ocamlrun-shebang.sh"
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
    # The package runs on CROSS_TARGET_PLATFORM, so it needs that platform's tools
    if [[ "${BUILD_MODE}" == "cross-target" ]]; then
      echo "  (Using TARGET toolchain: ${TARGET_TRIPLET}-*)"
      export CONDA_OCAML_AR="${TARGET_TRIPLET}-ar"
      export CONDA_OCAML_AS="${TARGET_TRIPLET}-as"
      export CONDA_OCAML_CC="${TARGET_TRIPLET}-gcc"
      export CONDA_OCAML_LD="${TARGET_TRIPLET}-ld"
      export CONDA_OCAML_RANLIB="${TARGET_TRIPLET}-ranlib"
      export CONDA_OCAML_MKEXE="${TARGET_TRIPLET}-gcc"
      export CONDA_OCAML_MKDLL="${TARGET_TRIPLET}-gcc -shared"
      export CONDA_OCAML_WINDRES="${TARGET_TRIPLET}-windres"
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
  source "${RECIPE_DIR}/building/fix-ocamlrun-shebang.sh"
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
