#!/usr/bin/env bash
# Test environment variables and resource file paths
# Verifies no build-time paths leaked into installed package
#
# Usage:
#   test-env-paths.sh                    # Native or cross-target build
#   test-env-paths.sh cross <target>     # Cross-compiler build

set -euo pipefail

MODE="${1:-native}"
TARGET="${2:-}"

echo "=== Environment and Resource File Tests (mode: ${MODE}) ==="

if [[ "${MODE}" == "cross" ]]; then
  # ============================================================================
  # CROSS-COMPILER mode
  # ============================================================================
  if [[ -z "${TARGET}" ]]; then
    echo "ERROR: Cross-compiler mode requires target argument"
    echo "Usage: test-env-paths.sh cross <target-triplet>"
    exit 1
  fi

  CROSS_PREFIX="${PREFIX}/lib/ocaml-cross-compilers/${TARGET}"
  CROSS_LIBDIR="${CROSS_PREFIX}/lib/ocaml"
  CROSS_OCAMLOPT="${PREFIX}/bin/${TARGET}-ocamlopt"

  echo "Testing cross-compiler for ${TARGET}"
  echo "  CROSS_PREFIX: ${CROSS_PREFIX}"
  echo "  CROSS_LIBDIR: ${CROSS_LIBDIR}"

  # Check cross-compiler wrapper exists
  echo "Checking cross-compiler wrapper..."
  if [[ ! -x "${CROSS_OCAMLOPT}" ]]; then
    echo "ERROR: Cross-compiler wrapper not found or not executable: ${CROSS_OCAMLOPT}"
    exit 1
  fi
  echo "  ${TARGET}-ocamlopt: exists and executable"

  # Check standard_library path in cross-compiler config
  echo "Checking ${TARGET}-ocamlopt -config-var standard_library..."
  STDLIB_PATH=$("${CROSS_OCAMLOPT}" -config-var standard_library)
  echo "  standard_library: ${STDLIB_PATH}"
  if [[ "${STDLIB_PATH}" != *"ocaml-cross-compilers/${TARGET}"* ]]; then
    echo "ERROR: standard_library should be under ocaml-cross-compilers/${TARGET}"
    exit 1
  fi
  # Check for staging/build environment paths (not just any rattler-build directory)
  # The test env PREFIX may be under rattler-build_xxx/, so check for staging-specific patterns
  if echo "${STDLIB_PATH}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
    echo "ERROR: standard_library contains build-time staging path"
    exit 1
  fi
  echo "  standard_library: clean"

  # Check Makefile.config in cross-compiler dir
  MAKEFILE_CONFIG="${CROSS_LIBDIR}/Makefile.config"
  echo "Checking ${MAKEFILE_CONFIG}..."
  if [[ -f "${MAKEFILE_CONFIG}" ]]; then
    # Filter out lines containing current PREFIX (test environment path is acceptable)
    if grep -E "rattler-build_|conda-bld|build_artifacts|/home/.*/feedstock" "${MAKEFILE_CONFIG}" | grep -qv "${PREFIX}"; then
      echo "ERROR: Makefile.config contains build-time paths:"
      grep -E "rattler-build_|conda-bld|build_artifacts|/home/.*/feedstock" "${MAKEFILE_CONFIG}" | grep -v "${PREFIX}" | head -5
      exit 1
    fi
    echo "  Makefile.config: clean"
  else
    echo "  WARNING: Makefile.config not found"
  fi

  # Check ld.conf in cross-compiler dir
  LD_CONF="${CROSS_LIBDIR}/ld.conf"
  echo "Checking ${LD_CONF}..."
  if [[ -f "${LD_CONF}" ]]; then
    # Filter out lines containing current PREFIX (test environment path is acceptable)
    if grep -E "rattler-build_|conda-bld|build_artifacts" "${LD_CONF}" | grep -qv "${PREFIX}"; then
      echo "ERROR: ld.conf contains build-time paths"
      exit 1
    fi
    echo "  ld.conf: clean"
  else
    echo "  WARNING: ld.conf not found"
  fi

  # Check cross-compiler binary for build-time paths
  CROSS_BIN="${CROSS_PREFIX}/bin/ocamlopt.opt"
  echo "Checking ${CROSS_BIN} for build-time paths..."
  if [[ -f "${CROSS_BIN}" ]]; then
    if strings "${CROSS_BIN}" | grep -q "rattler-build_"; then
      echo "ERROR: ocamlopt.opt contains build-time paths"
      strings "${CROSS_BIN}" | grep "rattler-build_" | head -5
      exit 1
    fi
    echo "  ocamlopt.opt binary: clean"
  else
    echo "  WARNING: ocamlopt.opt not found at ${CROSS_BIN}"
  fi

  # Check toolchain wrappers exist
  echo "Checking toolchain wrappers..."
  for tool in cc as ar ld ranlib mkexe mkdll; do
    wrapper="${PREFIX}/bin/${TARGET}-ocaml-${tool}"
    if [[ ! -x "${wrapper}" ]]; then
      echo "ERROR: Toolchain wrapper not found: ${wrapper}"
      exit 1
    fi
  done
  echo "  ${TARGET}-ocaml-{cc,as,ar,ld,ranlib,mkexe,mkdll}: all present"

else
  # ============================================================================
  # NATIVE / CROSS-TARGET mode
  # ============================================================================

  # Check OCAMLLIB is set
  echo "Checking OCAMLLIB..."
  if [[ -n "${OCAMLLIB:-}" ]]; then
    echo "  OCAMLLIB: ${OCAMLLIB}"
    # Check for staging/build environment paths (not just any rattler-build directory)
    # The test env may be under rattler-build_xxx/, but _h_env/_build_env/work/ are staging paths
    if echo "${OCAMLLIB}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
      echo "ERROR: OCAMLLIB contains build-time staging path"
      exit 1
    fi
  else
    echo "  OCAMLLIB: not set (will use default)"
  fi

  # Check resource files contain PREFIX (not build paths)
  echo "Checking runtime-launch-info..."
  RUNTIME_INFO="${PREFIX}/lib/ocaml/runtime-launch-info"
  if [[ -f "${RUNTIME_INFO}" ]]; then
    if head -2 "${RUNTIME_INFO}" | grep -q "${PREFIX}"; then
      echo "  runtime-launch-info: contains PREFIX"
    fi
    # Check for staging-specific paths (filter out test env PREFIX which may contain rattler-build)
    if grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler" "${RUNTIME_INFO}"; then
      echo "ERROR: runtime-launch-info contains build-time staging paths"
      exit 1
    fi
    echo "  runtime-launch-info: clean"
  else
    echo "  runtime-launch-info: not found (may be OK for some versions)"
  fi

  echo "Checking ld.conf..."
  LD_CONF="${PREFIX}/lib/ocaml/ld.conf"
  if [[ -f "${LD_CONF}" ]]; then
    if head -2 "${LD_CONF}" | grep -q "${PREFIX}"; then
      echo "  ld.conf: contains PREFIX"
    fi
    # Check for staging-specific paths (filter out test env PREFIX which may contain rattler-build)
    if grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler" "${LD_CONF}"; then
      echo "ERROR: ld.conf contains build-time staging paths"
      exit 1
    fi
    echo "  ld.conf: clean"
  else
    echo "  WARNING: ld.conf not found"
  fi

  echo "Checking Makefile.config..."
  MAKEFILE_CONFIG="${PREFIX}/lib/ocaml/Makefile.config"
  if [[ -f "${MAKEFILE_CONFIG}" ]]; then
    if grep -q "${PREFIX}" "${MAKEFILE_CONFIG}"; then
      echo "  Makefile.config: contains PREFIX"
    fi
    # Filter out lines containing current PREFIX (test environment path is acceptable)
    if grep -E "rattler-build_|conda-bld|build_artifacts|/home/.*/feedstock" "${MAKEFILE_CONFIG}" | grep -qv "${PREFIX}"; then
      echo "ERROR: Makefile.config contains build-time paths:"
      grep -E "rattler-build_|conda-bld|build_artifacts|/home/.*/feedstock" "${MAKEFILE_CONFIG}" | grep -v "${PREFIX}" | head -5
      exit 1
    fi
    echo "  Makefile.config: clean"
  else
    echo "  WARNING: Makefile.config not found"
  fi

  # Check binary doesn't contain build-time paths
  echo "Checking ocamlc.opt binary for build-time paths..."
  OCAMLC_BIN="${PREFIX}/bin/ocamlc.opt"
  if [[ -f "${OCAMLC_BIN}" ]]; then
    if strings "${OCAMLC_BIN}" | grep -q "rattler-build_"; then
      echo "ERROR: ocamlc.opt contains build-time paths"
      strings "${OCAMLC_BIN}" | grep "rattler-build_" | head -5
      exit 1
    fi
    echo "  ocamlc.opt binary: clean"
  else
    echo "  WARNING: ocamlc.opt not found"
  fi
fi

echo "=== All environment/path tests passed ==="
