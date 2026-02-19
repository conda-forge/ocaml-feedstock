#!/usr/bin/env bash
# Test OCaml compiler configuration
# Verifies no build-time paths leaked into installed package
#
# Usage:
#   test-config.sh                    # Native build (can execute binaries)
#   test-config.sh cross <target>     # Cross-compiler build
#   test-config.sh cross-target       # Cross-target build (can't execute binaries)

set -euo pipefail

MODE="${1:-native}"
TARGET="${2:-}"

echo "=== OCAML config Tests (mode: ${MODE}) ==="

# Determine which compiler to test and if we can execute binaries
CAN_EXECUTE=true
if [[ "${MODE}" == "cross" ]]; then
  if [[ -z "${TARGET}" ]]; then
    echo "ERROR: Cross-compiler mode requires target argument"
    echo "Usage: test-config.sh cross <target-triplet>"
    exit 1
  fi
  OCAML_CMD="${PREFIX}/bin/${TARGET}-ocamlopt"
  MAKEFILE_CONFIG="${PREFIX}/lib/ocaml-cross-compilers/${TARGET}/lib/ocaml/Makefile.config"
  OCAMLOPT_BIN="${PREFIX}/lib/ocaml-cross-compilers/${TARGET}/bin/ocamlopt.opt"
  echo "Testing cross-compiler: ${TARGET}"
elif [[ "${MODE}" == "cross-target" ]]; then
  # Cross-target build: binaries are for target platform, can't execute on build host
  OCAML_CMD="ocamlc.opt"
  MAKEFILE_CONFIG="${PREFIX}/lib/ocaml/Makefile.config"
  OCAMLOPT_BIN="${PREFIX}/bin/ocamlopt.opt"
  CAN_EXECUTE=false
  echo "Cross-target build: skipping execution-based tests (no QEMU)"
else
  OCAML_CMD="ocamlc.opt"
  MAKEFILE_CONFIG="${PREFIX}/lib/ocaml/Makefile.config"
  OCAMLOPT_BIN="${PREFIX}/bin/ocamlopt.opt"
fi

# Check config vars don't contain build-time paths
# (requires executing the compiler - skip for cross-target builds)
if [[ "${CAN_EXECUTE}" == "true" ]]; then
  echo "Checking ${OCAML_CMD} -config-var values..."

  STDLIB_PATH=$("${OCAML_CMD}" -config-var standard_library)
  echo "  standard_library=${STDLIB_PATH}"
  # Check for staging-specific paths (test env PREFIX may be under rattler-build_xxx/)
  if echo "${STDLIB_PATH}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
    echo "ERROR: standard_library contains build-time staging path"
    exit 1
  fi
  echo "  standard_library: clean"

  CC_PATH=$("${OCAML_CMD}" -config-var bytecomp_c_compiler 2>/dev/null || echo "N/A")
  echo "  bytecomp_c_compiler=${CC_PATH}"

  CC_PATH=$("${OCAML_CMD}" -config-var native_c_compiler 2>/dev/null || echo "N/A")
  echo "  native_c_compiler=${CC_PATH}"

  CC_PATH=$("${OCAML_CMD}" -config-var c_compiler)
  echo "  c_compiler=${CC_PATH}"

  # Should be basename OR under $PREFIX, check for staging-specific paths
  if echo "$CC_PATH" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
    echo "ERROR: c_compiler contains build-time staging path: $CC_PATH"
    exit 1
  fi

  # If absolute path, must be under PREFIX (skip for cross-compiler wrappers)
  if [[ "${MODE}" != "cross" ]] && [[ "$CC_PATH" == /* ]] && [[ "$CC_PATH" != "${PREFIX}"* ]]; then
    echo "ERROR: c_compiler absolute path not under PREFIX: $CC_PATH"
    exit 1
  fi
  echo "  c_compiler: clean"

  ASM_PATH=$("${OCAML_CMD}" -config-var asm)
  echo "  asm=${ASM_PATH}"
  # Check for staging-specific paths (test env PREFIX may be under rattler-build_xxx/)
  if echo "$ASM_PATH" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
    echo "ERROR: asm contains build-time staging path: $ASM_PATH"
    exit 1
  fi
  echo "  asm: clean"

  # Check library paths don't contain -L flags with build-time paths
  BYTECCLIBS=$("${OCAML_CMD}" -config-var bytecomp_c_libraries 2>/dev/null || echo "N/A")
  echo "  bytecomp_c_libraries=${BYTECCLIBS}"
  if [[ "$BYTECCLIBS" != "N/A" ]] && echo "$BYTECCLIBS" | grep -qE "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
    echo "ERROR: bytecomp_c_libraries contains build-time -L path: $BYTECCLIBS"
    exit 1
  fi
  echo "  bytecomp_c_libraries: clean"

  # compression_c_libraries may not exist in all OCaml versions
  ZSTDLIBS=$("${OCAML_CMD}" -config-var compression_c_libraries 2>/dev/null || echo "N/A")
  echo "  compression_c_libraries=${ZSTDLIBS}"
  if [[ "$ZSTDLIBS" != "N/A" ]] && echo "$ZSTDLIBS" | grep -qE "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
    echo "ERROR: compression_c_libraries contains build-time -L path: $ZSTDLIBS"
    exit 1
  fi
  echo "  compression_c_libraries: clean (or not present in this version)"

  # Check native_c_libraries for -L paths
  NATIVECCLIBS=$("${OCAML_CMD}" -config-var native_c_libraries 2>/dev/null || echo "N/A")
  echo "  native_c_libraries=${NATIVECCLIBS}"
  if [[ "$NATIVECCLIBS" != "N/A" ]] && echo "$NATIVECCLIBS" | grep -qE "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
    echo "ERROR: native_c_libraries contains build-time -L path: $NATIVECCLIBS"
    exit 1
  fi
  echo "  native_c_libraries: clean"
else
  echo "Skipping -config-var checks (cannot execute cross-target binaries)"
fi

# Check Makefile.config for hardcoded build paths
if [[ -f "${MAKEFILE_CONFIG}" ]]; then
  echo "Checking Makefile.config for build-time paths..."
  BUILD_PATH_PATTERN="(conda-bld|rattler-build|build_env|build_artifacts|/home/.*/feedstock)"
  # Filter out lines containing current PREFIX (test environment path is acceptable)
  if grep -E "${BUILD_PATH_PATTERN}" "${MAKEFILE_CONFIG}" | grep -qv "${PREFIX}"; then
    echo "ERROR: Makefile.config contains build-time paths:"
    grep -E "${BUILD_PATH_PATTERN}" "${MAKEFILE_CONFIG}" | grep -v "${PREFIX}" | head -5
    exit 1
  fi
  echo "  Makefile.config: clean"
else
  echo "  WARNING: Makefile.config not found at ${MAKEFILE_CONFIG}"
fi

# Check rpath on macOS (prevents "@rpath/libzstd.1.dylib not found" at runtime)
if [[ "$(uname)" == "Darwin" ]] && [[ -f "${OCAMLOPT_BIN}" ]]; then
  echo "Checking macOS rpath for libzstd..."
  echo "  Binary: ${OCAMLOPT_BIN}"
  echo "  Dependencies (otool -L):"
  otool -L "${OCAMLOPT_BIN}" 2>&1 | head -10 | sed 's/^/    /'

  # Check if libzstd is linked via @rpath
  if otool -L "${OCAMLOPT_BIN}" 2>/dev/null | grep -q "@rpath/libzstd"; then
    echo "  libzstd link: @rpath/libzstd (needs rpath entry)"

    # Show LC_RPATH entries
    echo "  LC_RPATH entries (otool -l):"
    otool -l "${OCAMLOPT_BIN}" 2>&1 | grep -A2 "LC_RPATH" | sed 's/^/    /' || echo "    (none found)"

    # Verify rpath includes path to lib/
    # Accept either @executable_path or @loader_path (equivalent for executables)
    if otool -l "${OCAMLOPT_BIN}" 2>/dev/null | grep -A2 "LC_RPATH" | grep -qE "@(executable_path|loader_path)"; then
      RPATH_VAL=$(otool -l "${OCAMLOPT_BIN}" 2>/dev/null | grep -A2 "LC_RPATH" | grep "path" | awk '{print $2}')
      echo "  rpath: ${RPATH_VAL} (OK)"
    else
      echo "ERROR: Missing rpath entry for @executable_path or @loader_path"
      echo "  Binary links @rpath/libzstd but has no rpath to find it"
      echo "  Expected: @executable_path/../lib or @loader_path/../lib"
      exit 1
    fi
  else
    echo "  libzstd not linked via @rpath (OK - may be statically linked)"
  fi
fi

echo "=== OCAML config tests passed ==="
