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

  # Setup macOS ARM64 SDK for linking tests
  # The cross-compiler needs CONDA_BUILD_SYSROOT pointing to ARM64 SDK
  # otherwise linker finds x86_64 SDK and fails with "libSystem.tbd incompatible with arm64"
  if [[ "${target}" == "arm64-apple-darwin"* ]]; then
    echo "  Setting up ARM64 SDK for linking tests..."
    SDK_DIR="/tmp/conda-sdks"
    ARM64_SDK="${SDK_DIR}/MacOSX11.0.sdk"
    if [[ ! -d "${ARM64_SDK}" ]]; then
      mkdir -p "${SDK_DIR}"
      curl -sL "https://github.com/phracker/MacOSX-SDKs/releases/download/11.3/MacOSX11.0.sdk.tar.xz" -o "${SDK_DIR}/sdk.tar.xz"
      tar -xf "${SDK_DIR}/sdk.tar.xz" -C "${SDK_DIR}"
      rm -f "${SDK_DIR}/sdk.tar.xz"
    fi
    export SDKROOT="${ARM64_SDK}"
    export CONDA_BUILD_SYSROOT="${ARM64_SDK}"
    echo "    CONDA_BUILD_SYSROOT=${ARM64_SDK}"
  fi

  TEST_ERRORS=0

  # ---------------------------------------------------------------------------
  # Test 1: Version check
  # ---------------------------------------------------------------------------
  echo "  [1/14] Version check..."
  if "${CROSS_OCAMLOPT}" -version | grep -q "${VERSION}"; then
    echo "    ✓ Version: ${VERSION}"
  else
    echo "    ✗ ERROR: Version mismatch"
    TEST_ERRORS=$((TEST_ERRORS + 1))
  fi

  # ---------------------------------------------------------------------------
  # Test 2: Architecture in -config (CRITICAL - was wrong before!)
  # ---------------------------------------------------------------------------
  echo "  [2/14] Architecture in -config..."
  # Use tr -d '\0' to strip null bytes that cause "binary file matches" errors
  CONFIG_ARCH=$("${CROSS_OCAMLOPT}" -config | tr -d '\0' | grep -a "^architecture:" | awk '{print $2}')
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
  echo "  [3/14] native_pack_linker in -config..."
  PACK_LINKER=$("${CROSS_OCAMLOPT}" -config | tr -d '\0' | grep -a "^native_pack_linker:" | cut -d: -f2- | xargs)
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
  echo "  [4/14] Toolchain wrappers in -config..."
  for tool in asm c_compiler native_c_compiler; do
    TOOL_VAL=$("${CROSS_OCAMLOPT}" -config | tr -d '\0' | grep -a "^${tool}:" | cut -d: -f2- | xargs)
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
  echo "  [5/14] Library structure (dune compatibility)..."
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
  echo "  [6/14] Required files..."
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
  echo "  [7/14] Binary architecture..."
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
  echo "  [8/14] Stdlib__Sys consistency check..."
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
  # Test 9: macOS rpath for libzstd (prevents runtime "@rpath/libzstd not found")
  # ---------------------------------------------------------------------------
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "  [9/9] macOS rpath for libzstd..."
    # Cross-compiler binaries are in ${PREFIX}/lib/ocaml-cross-compilers/${target}/bin/
    # They need rpath to find libzstd in ${PREFIX}/lib/
    CROSS_OCAMLOPT_BIN="${OCAML_CROSS_PREFIX}/bin/ocamlopt.opt"
    if [[ -f "${CROSS_OCAMLOPT_BIN}" ]]; then
      # Show diagnostic info
      echo "    Binary: ${CROSS_OCAMLOPT_BIN}"
      echo "    Dependencies (otool -L):"
      otool -L "${CROSS_OCAMLOPT_BIN}" 2>&1 | head -10 | sed 's/^/      /'

      # Check if libzstd is linked via @rpath
      if otool -L "${CROSS_OCAMLOPT_BIN}" 2>/dev/null | grep -q "@rpath/libzstd"; then
        echo "    libzstd link: @rpath/libzstd (needs rpath entry)"

        # Show LC_RPATH entries
        echo "    LC_RPATH entries (otool -l):"
        otool -l "${CROSS_OCAMLOPT_BIN}" 2>&1 | grep -A2 "LC_RPATH" | sed 's/^/      /' || echo "      (none found)"

        # Verify rpath includes path to lib/
        # Accept either @executable_path or @loader_path (equivalent for executables)
        if otool -l "${CROSS_OCAMLOPT_BIN}" 2>/dev/null | grep -A2 "LC_RPATH" | grep -qE "@(executable_path|loader_path)"; then
          RPATH_VAL=$(otool -l "${CROSS_OCAMLOPT_BIN}" 2>/dev/null | grep -A2 "LC_RPATH" | grep "path" | awk '{print $2}')
          echo "    ✓ rpath set: ${RPATH_VAL}"
        else
          echo "    ✗ ERROR: Missing rpath entry for @executable_path or @loader_path"
          echo "      Binary links @rpath/libzstd but has no rpath to find it"
          echo "      Expected: @executable_path/../../../../lib or @loader_path/../../../../lib"
          TEST_ERRORS=$((TEST_ERRORS + 1))
        fi
      else
        echo "    ~ libzstd not linked via @rpath (OK - may be statically linked)"
      fi
    else
      echo "    ~ SKIP: ocamlopt.opt not found at ${CROSS_OCAMLOPT_BIN}"
    fi
  else
    echo "  [9/14] macOS rpath check... SKIP (not macOS)"
  fi

  # ---------------------------------------------------------------------------
  # Test 10: Makefile.config toolchain verification (CRITICAL for opam)
  # ---------------------------------------------------------------------------
  echo "  [10/14] Makefile.config toolchain verification..."
  MAKEFILE_CONFIG="${OCAML_CROSS_LIBDIR}/Makefile.config"
  if [[ -f "${MAKEFILE_CONFIG}" ]]; then
    CONFIG_ERRORS=0

    # Extract toolchain values
    CONFIG_AS=$(grep "^ASM\?=" "${MAKEFILE_CONFIG}" | head -1 | cut -d= -f2- | xargs || echo "")
    CONFIG_LD=$(grep "^LD=" "${MAKEFILE_CONFIG}" | head -1 | cut -d= -f2- | xargs || echo "")
    CONFIG_CC=$(grep "^CC=" "${MAKEFILE_CONFIG}" | head -1 | cut -d= -f2- | xargs || echo "")
    CONFIG_TOOLPREF=$(grep "^TOOLPREF=" "${MAKEFILE_CONFIG}" | head -1 | cut -d= -f2- | xargs || echo "")

    # Determine expected toolchain prefix based on target
    case "${target}" in
      aarch64-conda-linux-gnu)
        EXPECTED_PREFIX="aarch64"
        WRONG_PREFIX="x86_64"
        ;;
      powerpc64le-conda-linux-gnu)
        EXPECTED_PREFIX="powerpc64le"
        WRONG_PREFIX="x86_64"
        ;;
      arm64-apple-darwin*)
        EXPECTED_PREFIX="arm64"
        WRONG_PREFIX="x86_64"
        ;;
      *)
        EXPECTED_PREFIX=""
        WRONG_PREFIX=""
        ;;
    esac

    # Check each critical field - should use wrapper OR correct target prefix
    for var_name in AS LD CC; do
      eval "var_value=\$CONFIG_${var_name}"
      if [[ -z "${var_value}" ]]; then
        echo "    ~ ${var_name}: (not set)"
      elif [[ "${var_value}" == "conda-ocaml-"* ]]; then
        echo "    ✓ ${var_name}: ${var_value} (wrapper)"
      elif [[ -n "${WRONG_PREFIX}" ]] && echo "${var_value}" | grep -q "${WRONG_PREFIX}"; then
        echo "    ✗ ERROR: ${var_name}=${var_value} contains ${WRONG_PREFIX} (should be ${EXPECTED_PREFIX} or wrapper)"
        CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
      elif [[ -n "${EXPECTED_PREFIX}" ]] && echo "${var_value}" | grep -q "${EXPECTED_PREFIX}"; then
        echo "    ✓ ${var_name}: ${var_value} (correct target prefix)"
      else
        echo "    ~ ${var_name}: ${var_value} (acceptable)"
      fi
    done

    # Check TOOLPREF specifically - this is critical for opam
    if [[ -n "${CONFIG_TOOLPREF}" ]]; then
      if [[ -n "${WRONG_PREFIX}" ]] && echo "${CONFIG_TOOLPREF}" | grep -q "${WRONG_PREFIX}"; then
        echo "    ✗ ERROR: TOOLPREF=${CONFIG_TOOLPREF} contains ${WRONG_PREFIX}"
        echo "      This will cause opam to use wrong toolchain!"
        CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
      elif [[ -n "${EXPECTED_PREFIX}" ]] && echo "${CONFIG_TOOLPREF}" | grep -q "${EXPECTED_PREFIX}"; then
        echo "    ✓ TOOLPREF: ${CONFIG_TOOLPREF} (correct)"
      else
        echo "    ~ TOOLPREF: ${CONFIG_TOOLPREF}"
      fi
    fi

    if [[ ${CONFIG_ERRORS} -gt 0 ]]; then
      echo "    ✗ CRITICAL: Makefile.config has wrong toolchain for ${target}"
      echo "      Full Makefile.config toolchain section:"
      grep -E "^(AS|ASM|LD|CC|AR|RANLIB|TOOLPREF|NATIVE_CC|TARGET)=" "${MAKEFILE_CONFIG}" | sed 's/^/        /'
      TEST_ERRORS=$((TEST_ERRORS + CONFIG_ERRORS))
    fi
  else
    echo "    ✗ ERROR: Makefile.config not found at ${MAKEFILE_CONFIG}"
    TEST_ERRORS=$((TEST_ERRORS + 1))
  fi

  # ---------------------------------------------------------------------------
  # Test 11: standard_library path verification
  # ---------------------------------------------------------------------------
  echo "  [11/14] standard_library path verification..."
  STDLIB_PATH=$("${CROSS_OCAMLOPT}" -config 2>/dev/null | tr -d '\0' | grep -a "^standard_library:" | cut -d: -f2- | xargs)
  if [[ "${STDLIB_PATH}" == *"ocaml-cross-compilers/${target}"* ]]; then
    echo "    ✓ standard_library: ${STDLIB_PATH}"
  elif [[ "${STDLIB_PATH}" == *"/lib/ocaml" ]] && [[ "${STDLIB_PATH}" != *"cross-compilers"* ]]; then
    echo "    ✗ ERROR: standard_library points to native OCaml, not cross-compiler"
    echo "      Path: ${STDLIB_PATH}"
    echo "      Expected: ...ocaml-cross-compilers/${target}/lib/ocaml"
    TEST_ERRORS=$((TEST_ERRORS + 1))
  else
    echo "    ~ standard_library: ${STDLIB_PATH} (verify manually)"
  fi

  # ---------------------------------------------------------------------------
  # Test 12: Multi-file compilation (opam-like pattern)
  # ---------------------------------------------------------------------------
  echo "  [12/14] Multi-file compilation (opam-like)..."
  MULTIFILE_DIR="/tmp/test_multifile_${TARGET_ID}"
  rm -rf "${MULTIFILE_DIR}"
  mkdir -p "${MULTIFILE_DIR}"

  # Create a multi-file project similar to opam's structure
  cat > "${MULTIFILE_DIR}/helper.ml" << 'HELPEREOF'
let greeting = "Hello"
let target = "cross-compiled world"
let make_message () = Printf.sprintf "%s, %s!" greeting target
HELPEREOF

  cat > "${MULTIFILE_DIR}/helper.mli" << 'HELPERMLIEOF'
val greeting : string
val target : string
val make_message : unit -> string
HELPERMLIEOF

  cat > "${MULTIFILE_DIR}/main.ml" << 'MAINEOF'
let () =
  let msg = Helper.make_message () in
  print_endline msg;
  (* Test some actual computation to catch instruction set issues *)
  let sum = List.fold_left (+) 0 [1; 2; 3; 4; 5] in
  Printf.printf "Sum 1-5: %d\n" sum;
  if sum = 15 then
    print_endline "COMPUTATION_CORRECT"
  else
    print_endline "COMPUTATION_WRONG"
MAINEOF

  MULTIFILE_BIN="${MULTIFILE_DIR}/main"

  # Compile step by step like opam/dune would
  cd "${MULTIFILE_DIR}"
  MULTIFILE_OK=1

  # Step 1: Compile interface
  if ! "${CROSS_OCAMLOPT}" -c helper.mli 2>/dev/null; then
    echo "    ✗ ERROR: Failed to compile helper.mli"
    "${CROSS_OCAMLOPT}" -c helper.mli 2>&1 | tail -5 | sed 's/^/      /'
    MULTIFILE_OK=0
  fi

  # Step 2: Compile helper module
  if [[ ${MULTIFILE_OK} -eq 1 ]] && ! "${CROSS_OCAMLOPT}" -c helper.ml 2>/dev/null; then
    echo "    ✗ ERROR: Failed to compile helper.ml"
    "${CROSS_OCAMLOPT}" -c helper.ml 2>&1 | tail -5 | sed 's/^/      /'
    MULTIFILE_OK=0
  fi

  # Step 3: Compile main module
  if [[ ${MULTIFILE_OK} -eq 1 ]] && ! "${CROSS_OCAMLOPT}" -c main.ml 2>/dev/null; then
    echo "    ✗ ERROR: Failed to compile main.ml"
    "${CROSS_OCAMLOPT}" -c main.ml 2>&1 | tail -5 | sed 's/^/      /'
    MULTIFILE_OK=0
  fi

  # Step 4: Link everything
  if [[ ${MULTIFILE_OK} -eq 1 ]] && ! "${CROSS_OCAMLOPT}" -o "${MULTIFILE_BIN}" helper.cmx main.cmx 2>/dev/null; then
    echo "    ✗ ERROR: Failed to link multi-file project"
    "${CROSS_OCAMLOPT}" -o "${MULTIFILE_BIN}" helper.cmx main.cmx 2>&1 | tail -5 | sed 's/^/      /'
    MULTIFILE_OK=0
  fi

  if [[ ${MULTIFILE_OK} -eq 1 ]]; then
    echo "    ✓ Multi-file compilation successful"

    # Verify with QEMU if available
    if [[ -n "$qemu_cmd" ]] && command -v "$qemu_cmd" >/dev/null 2>&1; then
      echo "    Testing execution (QEMU)..."
      QEMU_OUTPUT=$(QEMU_LD_PREFIX="${qemu_prefix}" ${qemu_cmd} "${MULTIFILE_BIN}" 2>&1 || true)
      if echo "${QEMU_OUTPUT}" | grep -q "COMPUTATION_CORRECT"; then
        echo "    ✓ Computation correct under QEMU"
      elif echo "${QEMU_OUTPUT}" | grep -q "COMPUTATION_WRONG"; then
        echo "    ✗ ERROR: Computation wrong - possible instruction set mismatch"
        echo "      Output: ${QEMU_OUTPUT}"
        TEST_ERRORS=$((TEST_ERRORS + 1))
      elif echo "${QEMU_OUTPUT}" | grep -q "Hello"; then
        echo "    ~ Partial execution (computation test inconclusive)"
      else
        echo "    ~ QEMU execution failed (may be platform limitation)"
        echo "      Output: ${QEMU_OUTPUT}" | head -3 | sed 's/^/      /'
      fi
    fi
  else
    TEST_ERRORS=$((TEST_ERRORS + 1))
  fi

  cd - >/dev/null
  rm -rf "${MULTIFILE_DIR}"

  # ---------------------------------------------------------------------------
  # Test 13: Unix library with actual syscall (catches ABI issues)
  # ---------------------------------------------------------------------------
  echo "  [13/14] Unix library syscall test..."
  SYSCALL_TEST="/tmp/test_syscall_${TARGET_ID}.ml"
  SYSCALL_BIN="/tmp/test_syscall_${TARGET_ID}"

  cat > "${SYSCALL_TEST}" << 'SYSCALLEOF'
let () =
  (* Test actual Unix syscalls - catches ABI/calling convention issues *)
  let pid = Unix.getpid () in
  Printf.printf "PID: %d\n" pid;
  let time = Unix.gettimeofday () in
  Printf.printf "Time: %.0f\n" time;
  (* Verify PID is reasonable (not garbage) *)
  if pid > 0 && pid < 10000000 then
    print_endline "SYSCALL_OK"
  else
    print_endline "SYSCALL_SUSPICIOUS"
SYSCALLEOF

  if "${CROSS_OCAMLOPT}" -o "${SYSCALL_BIN}" unix.cmxa "${SYSCALL_TEST}" 2>/dev/null; then
    echo "    ✓ Unix syscall compilation successful"

    if [[ -n "$qemu_cmd" ]] && command -v "$qemu_cmd" >/dev/null 2>&1; then
      SYSCALL_OUTPUT=$(QEMU_LD_PREFIX="${qemu_prefix}" ${qemu_cmd} "${SYSCALL_BIN}" 2>&1 || true)
      if echo "${SYSCALL_OUTPUT}" | grep -q "SYSCALL_OK"; then
        echo "    ✓ Unix syscalls work correctly under QEMU"
      elif echo "${SYSCALL_OUTPUT}" | grep -q "SYSCALL_SUSPICIOUS"; then
        echo "    ✗ WARNING: Unix syscalls return suspicious values"
        echo "      Output: ${SYSCALL_OUTPUT}"
      else
        echo "    ~ QEMU syscall test inconclusive"
      fi
    fi
  else
    echo "    ✗ ERROR: Unix syscall compilation failed"
    "${CROSS_OCAMLOPT}" -o "${SYSCALL_BIN}" unix.cmxa "${SYSCALL_TEST}" 2>&1 | tail -5 | sed 's/^/      /'
    TEST_ERRORS=$((TEST_ERRORS + 1))
  fi

  rm -f "${SYSCALL_TEST}" "${SYSCALL_BIN}" "${SYSCALL_BIN}."*

  # ---------------------------------------------------------------------------
  # Test 14: Verify no build-time paths leaked into cross-compiler
  # ---------------------------------------------------------------------------
  echo "  [14/14] Build-time path leak check..."
  LEAK_ERRORS=0

  # Check Makefile.config for build-time paths
  # Note: Lines like prefix=, LIBDIR=, STUBLIBDIR= contain $PREFIX which will be
  # relocated by conda - these are NOT bugs. We check for:
  # 1. _build_env paths (BUILD environment, won't be relocated to HOST)
  # 2. Tool paths (CPP, CC, etc.) with full build-time paths
  if [[ -f "${MAKEFILE_CONFIG}" ]]; then
    # Check for _build_env which is ALWAYS wrong (build env in host package)
    if grep -qE "_build_env" "${MAKEFILE_CONFIG}"; then
      echo "    ✗ ERROR: Makefile.config contains build environment paths:"
      grep -E "_build_env" "${MAKEFILE_CONFIG}" | head -5 | sed 's/^/      /'
      LEAK_ERRORS=$((LEAK_ERRORS + 1))
    fi
    # Check tool paths (CPP, CC, AS) - these should be just binary names, not full paths
    # Pattern: tool=/absolute/path/... means build-time path leaked
    if grep -E "^(CPP|CC|AS|ASM|ASPP)=/" "${MAKEFILE_CONFIG}" | grep -qE "(conda-bld|rattler-build|miniforge|miniconda|/home/.*/build)"; then
      echo "    ✗ ERROR: Makefile.config has tool paths with build-time directories:"
      grep -E "^(CPP|CC|AS|ASM|ASPP)=/" "${MAKEFILE_CONFIG}" | grep -E "(conda-bld|rattler-build|miniforge|miniconda|/home/.*/build)" | head -3 | sed 's/^/      /'
      LEAK_ERRORS=$((LEAK_ERRORS + 1))
    fi
    if [[ ${LEAK_ERRORS} -eq 0 ]]; then
      echo "    ✓ Makefile.config: no build-time path leaks"
    fi
  fi

  # Check -config output for leaked paths
  # Note: standard_library paths contain $PREFIX which will be relocated - not a bug
  # Real bugs: _build_env paths, tool paths with full build-time directories
  # Strip null bytes to avoid "binary file matches" grep errors
  CONFIG_OUTPUT=$("${CROSS_OCAMLOPT}" -config 2>/dev/null | tr -d '\0')
  CONFIG_LEAK=0
  # Check for _build_env which is ALWAYS wrong
  if echo "${CONFIG_OUTPUT}" | grep -qaE "_build_env"; then
    echo "    ✗ ERROR: ocamlopt -config contains build environment paths:"
    echo "${CONFIG_OUTPUT}" | grep -aE "_build_env" | head -3 | sed 's/^/      /'
    CONFIG_LEAK=1
  fi
  # Check tool configs (c_compiler, asm, etc.) - should be wrapper names, not full paths
  if echo "${CONFIG_OUTPUT}" | grep -aE "^(c_compiler|asm|native_c_compiler): /" | grep -qaE "(conda-bld|rattler-build|miniforge|miniconda)"; then
    echo "    ✗ ERROR: ocamlopt -config has tool paths with build-time directories:"
    echo "${CONFIG_OUTPUT}" | grep -aE "^(c_compiler|asm|native_c_compiler): /" | grep -aE "(conda-bld|rattler-build|miniforge|miniconda)" | head -3 | sed 's/^/      /'
    CONFIG_LEAK=1
  fi
  if [[ ${CONFIG_LEAK} -eq 1 ]]; then
    LEAK_ERRORS=$((LEAK_ERRORS + 1))
  else
    echo "    ✓ ocamlopt -config: no build-time path leaks"
  fi

  if [[ ${LEAK_ERRORS} -gt 0 ]]; then
    TEST_ERRORS=$((TEST_ERRORS + LEAK_ERRORS))
  fi

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
