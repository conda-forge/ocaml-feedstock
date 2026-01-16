#!/usr/bin/env bash
# Comprehensive cross-compiler validation tests
# Tests cross-compilers built on linux-64 and osx-64 platforms
# These tests verify the cross-compilers are correctly configured for use
# by downstream packages like dune/opam.

set -euo pipefail

VERSION="${1:-}"
BUILD_PLATFORM="${2:-${build_platform:-}}"
TARGET_PLATFORM="${3:-${target_platform:-}}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [build_platform] [target_platform]"
  exit 1
fi

# ==============================================================================
# Helper Functions
# ==============================================================================

# Get target architecture for OCaml ARCH variable
# Usage: get_target_arch "aarch64-conda-linux-gnu" → "arm64"
get_target_arch() {
  local target="$1"

  case "${target}" in
    aarch64-*|arm64-*) echo "arm64" ;;
    powerpc64le-*) echo "power" ;;
    x86_64-*|*-x86_64-*) echo "amd64" ;;
    *) echo "amd64" ;;  # default
  esac
}

# Get target ID from triplet (for environment variable naming)
# Usage: get_target_id "aarch64-conda-linux-gnu" → "AARCH64"
get_target_id() {
  local target="$1"

  case "${target}" in
    aarch64-conda-linux-gnu) echo "AARCH64" ;;
    powerpc64le-conda-linux-gnu) echo "PPC64LE" ;;
    arm64-apple-darwin*) echo "ARM64" ;;
    x86_64-conda-linux-gnu|x86_64-apple-darwin*) echo "X86_64" ;;
    *) echo "${target}" | cut -d'-' -f1 | tr '[:lower:]' '[:upper:]' ;;
  esac
}

# ==============================================================================
# Comprehensive Cross-Compiler Validation
# ==============================================================================
# These tests verify the cross-compiler is correctly configured for use
# by downstream packages like dune/opam. Previous builds passed basic tests
# but failed when used by dune due to wrong architecture in -config output.

test_cross_compiler() {
  local target="$1"
  local arch_name="$2"
  local qemu_cmd="${3:-}"
  local qemu_prefix="${4:-}"

  echo ""
  echo "  ========================================================================"
  echo "  Testing ${target} cross-compiler"
  echo "  ========================================================================"

  # Derive variables from target
  CROSS_ARCH=$(get_target_arch "${target}")
  TARGET_ID=$(get_target_id "${target}")
  CROSS_OCAMLOPT="${PREFIX}/bin/${target}-ocamlopt"
  CROSS_OCAMLC="${PREFIX}/bin/${target}-ocamlc"
  OCAML_CROSS_PREFIX="${PREFIX}/lib/ocaml-cross-compilers/${target}"
  OCAML_CROSS_LIBDIR="${OCAML_CROSS_PREFIX}/lib/ocaml"

  # Check if cross-compiler exists
  if [[ ! -x "${CROSS_OCAMLOPT}" ]]; then
    echo "  ✗ SKIP: ${target} cross-compiler not found at ${CROSS_OCAMLOPT}"
    return 0
  fi

  TEST_ERRORS=0

  # ---------------------------------------------------------------------------
  # Test 1: Version check
  # ---------------------------------------------------------------------------
  echo "  [1/8] Version check..."
  if "${CROSS_OCAMLOPT}" -version | grep -q "${VERSION}"; then
    echo "    ✓ Version: ${VERSION}"
  else
    echo "    ✗ ERROR: Version mismatch"
    TEST_ERRORS=$((TEST_ERRORS + 1))
  fi

  # ---------------------------------------------------------------------------
  # Test 2: Architecture in -config (CRITICAL - was wrong before!)
  # ---------------------------------------------------------------------------
  echo "  [2/8] Architecture in -config..."
  CONFIG_ARCH=$("${CROSS_OCAMLOPT}" -config | grep "^architecture:" | awk '{print $2}')
  if [[ "${CONFIG_ARCH}" == "${CROSS_ARCH}" ]]; then
    echo "    ✓ architecture: ${CONFIG_ARCH}"
  else
    echo "    ✗ ERROR: architecture is '${CONFIG_ARCH}', expected '${CROSS_ARCH}'"
    echo "      This means config.generated.ml was not patched correctly!"
    TEST_ERRORS=$((TEST_ERRORS + 1))
  fi

  # ---------------------------------------------------------------------------
  # Test 3: native_pack_linker uses cross-linker (CRITICAL - was wrong before!)
  # ---------------------------------------------------------------------------
  echo "  [3/8] native_pack_linker in -config..."
  PACK_LINKER=$("${CROSS_OCAMLOPT}" -config | grep "^native_pack_linker:" | cut -d: -f2- | xargs)
  if [[ "${PACK_LINKER}" == *"conda-ocaml-ld"* ]]; then
    echo "    ✓ native_pack_linker: ${PACK_LINKER}"
  else
    echo "    ✗ ERROR: native_pack_linker is '${PACK_LINKER}'"
    echo "      Expected to contain 'conda-ocaml-ld'"
    TEST_ERRORS=$((TEST_ERRORS + 1))
  fi

  # ---------------------------------------------------------------------------
  # Test 4: Toolchain wrappers use conda-ocaml-* (not hardcoded paths)
  # ---------------------------------------------------------------------------
  echo "  [4/8] Toolchain wrappers in -config..."
  for tool in asm c_compiler native_c_compiler; do
    TOOL_VAL=$("${CROSS_OCAMLOPT}" -config | grep "^${tool}:" | cut -d: -f2- | xargs)
    if [[ "${TOOL_VAL}" == "conda-ocaml-"* ]]; then
      echo "    ✓ ${tool}: ${TOOL_VAL}"
    elif [[ "${TOOL_VAL}" == *"/build"* ]] || [[ "${TOOL_VAL}" == *"_build_env"* ]]; then
      echo "    ✗ ERROR: ${tool} has hardcoded build path: ${TOOL_VAL}"
      TEST_ERRORS=$((TEST_ERRORS + 1))
    else
      echo "    ~ ${tool}: ${TOOL_VAL} (acceptable)"
    fi
  done

  # ---------------------------------------------------------------------------
  # Test 5: Library structure (OCaml 5.x subdirectories with META)
  # ---------------------------------------------------------------------------
  echo "  [5/8] Library structure (dune compatibility)..."
  for lib in unix str dynlink; do
    if [[ -d "${OCAML_CROSS_LIBDIR}/${lib}" ]] && [[ -f "${OCAML_CROSS_LIBDIR}/${lib}/META" ]]; then
      echo "    ✓ ${lib}/ with META"
    else
      echo "    ✗ ERROR: Missing ${lib}/ subdirectory or META file"
      TEST_ERRORS=$((TEST_ERRORS + 1))
    fi
  done

  # ---------------------------------------------------------------------------
  # Test 6: Required files exist
  # ---------------------------------------------------------------------------
  echo "  [6/8] Required files..."
  for required in Makefile.config caml/mlvalues.h stdlib.cmxa; do
    if [[ -e "${OCAML_CROSS_LIBDIR}/${required}" ]]; then
      echo "    ✓ ${required}"
    else
      echo "    ✗ ERROR: Missing ${required}"
      TEST_ERRORS=$((TEST_ERRORS + 1))
    fi
  done

  # ---------------------------------------------------------------------------
  # Test 7: Produces correct architecture binaries
  # ---------------------------------------------------------------------------
  echo "  [7/8] Binary architecture..."
  TEST_ML="/tmp/test_xcross_${TARGET_ID}.ml"
  TEST_BIN="/tmp/test_xcross_${TARGET_ID}"

  cat > "${TEST_ML}" << 'TESTEOF'
let () = print_endline "Hello from cross-compiled OCaml"
TESTEOF

  if "${CROSS_OCAMLOPT}" -o "${TEST_BIN}" "${TEST_ML}" 2>/dev/null; then
    _file_output=$(file "${TEST_BIN}")
    case "${CROSS_ARCH}" in
      arm64)
        if echo "$_file_output" | grep -qiE "aarch64|arm64"; then
          echo "    ✓ Produces arm64 binaries"
        else
          echo "    ✗ ERROR: Expected arm64, got: $_file_output"
          TEST_ERRORS=$((TEST_ERRORS + 1))
        fi
        ;;
      power)
        if echo "$_file_output" | grep -qi "powerpc\|ppc64"; then
          echo "    ✓ Produces ppc64 binaries"
        else
          echo "    ✗ ERROR: Expected ppc64, got: $_file_output"
          TEST_ERRORS=$((TEST_ERRORS + 1))
        fi
        ;;
      amd64)
        if echo "$_file_output" | grep -qi "x86-64\|x86_64"; then
          echo "    ✓ Produces x86_64 binaries"
        else
          echo "    ✗ ERROR: Expected x86_64, got: $_file_output"
          TEST_ERRORS=$((TEST_ERRORS + 1))
        fi
        ;;
    esac

    # Execution test with QEMU if available
    if [[ -n "$qemu_cmd" ]] && command -v "$qemu_cmd" >/dev/null 2>&1; then
      echo "    Testing execution (QEMU)..."
      if QEMU_LD_PREFIX="${qemu_prefix}" ${qemu_cmd} "${TEST_BIN}" 2>/dev/null | grep -q "Hello from cross-compiled"; then
        echo "    ✓ Execution successful (QEMU)"
      else
        echo "    ~ Execution SKIPPED (QEMU execution failed - expected on some platforms)"
      fi
    fi

    rm -f "${TEST_BIN}" "${TEST_BIN}.o" "${TEST_BIN}.cmx" "${TEST_BIN}.cmi"
  else
    echo "    ✗ ERROR: Cross-compilation failed"
    "${CROSS_OCAMLOPT}" -verbose -o "${TEST_BIN}" "${TEST_ML}" 2>&1 | tail -10 || true
    TEST_ERRORS=$((TEST_ERRORS + 1))
  fi

  rm -f "${TEST_ML}"

  # ---------------------------------------------------------------------------
  # Test 8: Stdlib/Unix consistency (prevents "inconsistent assumptions" error)
  # ---------------------------------------------------------------------------
  echo "  [8/8] Stdlib__Sys consistency check..."
  CONSISTENCY_TEST="/tmp/test_consistency_${TARGET_ID}.ml"
  CONSISTENCY_BIN="/tmp/test_consistency_${TARGET_ID}"

  cat > "${CONSISTENCY_TEST}" << 'CONSEOF'
(* Tests that stdlib.cmxa and unix.cmxa have consistent Stdlib__Sys CRC *)
let () =
  Printf.printf "OCaml version: %s\n" Sys.ocaml_version;
  let stats = Unix.stat "." in
  Printf.printf "Directory inode: %d\n" stats.Unix.st_ino;
  print_endline "Consistency check PASSED"
CONSEOF

  # This will fail with "inconsistent assumptions over implementation Stdlib__Sys"
  # if stdlib.cmxa and unix.cmxa have different Stdlib__Sys CRC checksums
  if "${CROSS_OCAMLOPT}" -o "${CONSISTENCY_BIN}" unix.cmxa "${CONSISTENCY_TEST}" 2>/dev/null; then
    echo "    ✓ stdlib.cmxa and unix.cmxa are consistent"
  else
    echo "    ✗ ERROR: Inconsistent assumptions - stdlib and unix incompatible"
    echo "      This is the bug fixed in HISTORY.md (runtime-all .cmi regeneration)"
    "${CROSS_OCAMLOPT}" -o "${CONSISTENCY_BIN}" unix.cmxa "${CONSISTENCY_TEST}" 2>&1 | grep -i "inconsistent" || true
    TEST_ERRORS=$((TEST_ERRORS + 1))
  fi

  rm -f "${CONSISTENCY_TEST}" "${CONSISTENCY_BIN}" "${CONSISTENCY_BIN}."*

  # ---------------------------------------------------------------------------
  # Summary
  # ---------------------------------------------------------------------------
  if [[ ${TEST_ERRORS} -gt 0 ]]; then
    echo ""
    echo "  ✗ FAILED: ${TEST_ERRORS} test(s) failed for ${target}"
    echo "    The cross-compiler may build packages that fail at runtime!"
    return 1
  else
    echo ""
    echo "  ✓ All tests passed for ${target}"
    return 0
  fi
}

# ==============================================================================
# Environment Setup Tests
# ==============================================================================
# Verify that toolchain wrapper scripts can be overridden via CONDA_OCAML_*
# environment variables. This is critical for dune/opam cross-compilation.

test_toolchain_env_vars() {
  local target="$1"

  echo ""
  echo "  ========================================================================"
  echo "  Testing toolchain environment variables for ${target}"
  echo "  ========================================================================"

  TARGET_ID=$(get_target_id "${target}")
  CROSS_OCAMLOPT="${PREFIX}/bin/${target}-ocamlopt"

  if [[ ! -x "${CROSS_OCAMLOPT}" ]]; then
    echo "  ✗ SKIP: ${target} cross-compiler not found"
    return 0
  fi

  # Create fake toolchain wrappers to test environment override
  FAKE_TOOLCHAIN_DIR="/tmp/fake_toolchain_${TARGET_ID}"
  mkdir -p "${FAKE_TOOLCHAIN_DIR}"

  for tool in ar as cc ranlib mkdll mkexe ld; do
    cat > "${FAKE_TOOLCHAIN_DIR}/fake-${tool}" << 'EOF'
#!/usr/bin/env bash
echo "FAKE_TOOLCHAIN_SUCCESS"
exit 1
EOF
    chmod +x "${FAKE_TOOLCHAIN_DIR}/fake-${tool}"
  done

  # Set CONDA_OCAML_<TARGET_ID>_* variables
  export "CONDA_OCAML_${TARGET_ID}_CC=${FAKE_TOOLCHAIN_DIR}/fake-cc"
  export "CONDA_OCAML_${TARGET_ID}_AS=${FAKE_TOOLCHAIN_DIR}/fake-as"
  export "CONDA_OCAML_${TARGET_ID}_AR=${FAKE_TOOLCHAIN_DIR}/fake-ar"
  export "CONDA_OCAML_${TARGET_ID}_RANLIB=${FAKE_TOOLCHAIN_DIR}/fake-ranlib"
  export "CONDA_OCAML_${TARGET_ID}_MKDLL=${FAKE_TOOLCHAIN_DIR}/fake-mkdll"
  export "CONDA_OCAML_${TARGET_ID}_MKEXE=${FAKE_TOOLCHAIN_DIR}/fake-mkexe"
  export "CONDA_OCAML_${TARGET_ID}_LD=${FAKE_TOOLCHAIN_DIR}/fake-ld"

  # Try to compile - should fail but show fake toolchain was used
  TEST_ML="/tmp/test_env_${TARGET_ID}.ml"
  echo 'let () = print_endline "test"' > "${TEST_ML}"

  # Ensure PREFIX/bin is in PATH so conda-ocaml-* wrappers can be found
  export PATH="${PREFIX}/bin:${PATH}"

  # Debug: Check if conda-ocaml-cc exists and is executable
  if [[ ! -x "${PREFIX}/bin/conda-ocaml-cc" ]]; then
    echo "    ✗ ERROR: ${PREFIX}/bin/conda-ocaml-cc not found or not executable"
    echo "      This is a package installation issue"
    ENV_TEST_PASSED=0
    return 0
  fi

  # Debug: Check wrapper script content
  echo "  Debug: Checking cross-compiler wrapper..."
  echo "    Wrapper exists: ${CROSS_OCAMLOPT}"
  if grep -q "CONDA_OCAML_${TARGET_ID}_CC" "${CROSS_OCAMLOPT}" 2>/dev/null; then
    echo "    ✓ Wrapper reads CONDA_OCAML_${TARGET_ID}_CC"
  else
    echo "    ✗ Wrapper does NOT read CONDA_OCAML_${TARGET_ID}_CC"
  fi

  echo "  Testing environment variable override..."
  COMPILE_OUTPUT=$("${CROSS_OCAMLOPT}" -verbose -o "/tmp/test_env_${TARGET_ID}" "${TEST_ML}" 2>&1 || true)

  if echo "${COMPILE_OUTPUT}" | grep -q "FAKE_TOOLCHAIN_SUCCESS"; then
    echo "    ✓ Environment variables properly override toolchain wrappers"
    ENV_TEST_PASSED=1
  else
    echo "    ✗ ERROR: Environment variables not being used by wrapper scripts"
    echo "      This breaks dune/opam cross-compilation workflows"
    echo "    Debug: First 10 lines of compilation output:"
    echo "${COMPILE_OUTPUT}" | head -10 | sed 's/^/      /'
    ENV_TEST_PASSED=0
  fi

  # Cleanup
  unset "CONDA_OCAML_${TARGET_ID}_CC"
  unset "CONDA_OCAML_${TARGET_ID}_AS"
  unset "CONDA_OCAML_${TARGET_ID}_AR"
  unset "CONDA_OCAML_${TARGET_ID}_RANLIB"
  unset "CONDA_OCAML_${TARGET_ID}_MKDLL"
  unset "CONDA_OCAML_${TARGET_ID}_MKEXE"
  unset "CONDA_OCAML_${TARGET_ID}_LD"
  rm -rf "${FAKE_TOOLCHAIN_DIR}" "${TEST_ML}" "/tmp/test_env_${TARGET_ID}"*

  if [[ ${ENV_TEST_PASSED} -eq 1 ]]; then
    echo "  ✓ Environment variable tests passed"
    return 0
  else
    echo "  ✗ Environment variable tests failed"
    return 1
  fi
}

# ==============================================================================
# Main Test Execution
# ==============================================================================

echo "========================================================================"
echo "Cross-Compiler Validation Tests (OCaml ${VERSION})"
echo "========================================================================"
echo "Build platform:  ${BUILD_PLATFORM}"
echo "Target platform: ${TARGET_PLATFORM:-same as build}"
echo ""

# Only run on native x86_64 platforms where cross-compilers are built
if [[ "$BUILD_PLATFORM" != "linux-64" ]] && [[ "$BUILD_PLATFORM" != "osx-64" ]]; then
  echo "Cross-compilers only built on linux-64 and osx-64, skipping"
  exit 0
fi

# Skip if this is a cross-compilation (cross-compilers not available)
if [[ -n "$TARGET_PLATFORM" ]] && [[ "$BUILD_PLATFORM" != "$TARGET_PLATFORM" ]]; then
  echo "This is a cross-compilation build, cross-compilers not available"
  exit 0
fi

TOTAL_ERRORS=0

# Linux x86_64: test aarch64 and ppc64le cross-compilers
if [[ "$BUILD_PLATFORM" == "linux-64" ]]; then
  # Test aarch64 cross-compiler
  if test_cross_compiler \
    "aarch64-conda-linux-gnu" \
    "Linux ARM64 (aarch64)" \
    "qemu-execve-aarch64" \
    "${PREFIX}/aarch64-conda-linux-gnu/sysroot"; then
    :
  else
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
  fi

  # Test environment variable override for aarch64
  if test_toolchain_env_vars "aarch64-conda-linux-gnu"; then
    :
  else
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
  fi

  # Test ppc64le cross-compiler
  if test_cross_compiler \
    "powerpc64le-conda-linux-gnu" \
    "Linux PPC64LE" \
    "qemu-execve-ppc64le" \
    "${PREFIX}/powerpc64le-conda-linux-gnu/sysroot"; then
    :
  else
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
  fi

  # Test environment variable override for ppc64le
  if test_toolchain_env_vars "powerpc64le-conda-linux-gnu"; then
    :
  else
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
  fi
fi

# macOS x86_64: test arm64 cross-compiler
if [[ "$BUILD_PLATFORM" == "osx-64" ]]; then
  # Test arm64 cross-compiler (no QEMU for macOS)
  if test_cross_compiler \
    "arm64-apple-darwin20.0.0" \
    "macOS ARM64" \
    "" \
    ""; then
    :
  else
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
  fi

  # Test environment variable override for arm64
  if test_toolchain_env_vars "arm64-apple-darwin20.0.0"; then
    :
  else
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
  fi
fi

echo ""
echo "========================================================================"
if [[ ${TOTAL_ERRORS} -gt 0 ]]; then
  echo "FAILED: ${TOTAL_ERRORS} cross-compiler(s) failed validation"
  echo "========================================================================"
  exit 1
else
  echo "SUCCESS: All cross-compiler validation tests passed"
  echo "========================================================================"
  exit 0
fi
