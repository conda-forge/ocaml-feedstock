#!/usr/bin/env bash
# Test OCaml package integrity: environment paths, resource files, and compiler config
# Verifies no build-time paths leaked into installed package
#
# Usage:
#   test-package-integrity.sh                    # Native build (can execute binaries)
#   test-package-integrity.sh cross-target       # Cross-target build (can't execute binaries)
#   test-package-integrity.sh cross <target>     # Cross-compiler build

set -euo pipefail

MODE="${1:-native}"
TARGET="${2:-}"

echo "=== OCaml Package Integrity Tests (mode: ${MODE}) ==="

# ============================================================================
# HELPER: Check a file for staging/build-time paths
# Usage: check_no_staging_paths <file> <label>
#
# Both scripts share the same pattern for Makefile.config:
#   - Flag any line matching rattler-build_|conda-bld|build_artifacts|/home/.*/feedstock
#   - UNLESS that line also contains the test-env $PREFIX (which is acceptable)
# ============================================================================
check_no_staging_paths() {
  local file="$1"
  local label="$2"
  local staging_pattern="rattler-build_|conda-bld|build_artifacts|/home/.*/feedstock"

  if [[ ! -f "${file}" ]]; then
    echo "  WARNING: ${label} not found at ${file}"
    return 0
  fi

  if grep -E "${staging_pattern}" "${file}" | grep -qv "${PREFIX}"; then
    echo "ERROR: ${label} contains build-time paths:"
    grep -E "${staging_pattern}" "${file}" | grep -v "${PREFIX}" | head -5
    exit 1
  fi
  echo "  ${label}: clean"
}

# ============================================================================
# CROSS-COMPILER mode
# ============================================================================
if [[ "${MODE}" == "cross" ]]; then
  if [[ -z "${TARGET}" ]]; then
    echo "ERROR: Cross-compiler mode requires target argument"
    echo "Usage: test-package-integrity.sh cross <target-triplet>"
    exit 1
  fi

  CROSS_PREFIX="${PREFIX}/lib/ocaml-cross-compilers/${TARGET}"
  CROSS_LIBDIR="${CROSS_PREFIX}/lib/ocaml"
  CROSS_OCAMLOPT="${PREFIX}/bin/${TARGET}-ocamlopt"
  MAKEFILE_CONFIG="${CROSS_LIBDIR}/Makefile.config"
  OCAMLOPT_BIN="${CROSS_PREFIX}/bin/ocamlopt.opt"

  echo "Testing cross-compiler for ${TARGET}"
  echo "  CROSS_PREFIX: ${CROSS_PREFIX}"
  echo "  CROSS_LIBDIR: ${CROSS_LIBDIR}"

  # --- Cross-compiler wrapper ---
  echo "Checking cross-compiler wrapper..."
  if [[ ! -x "${CROSS_OCAMLOPT}" ]]; then
    echo "ERROR: Cross-compiler wrapper not found or not executable: ${CROSS_OCAMLOPT}"
    exit 1
  fi
  echo "  ${TARGET}-ocamlopt: exists and executable"

  # --- -config-var checks ---
  echo "Checking ${CROSS_OCAMLOPT} -config-var values..."

  STDLIB_PATH=$("${CROSS_OCAMLOPT}" -config-var standard_library)
  echo "  standard_library=${STDLIB_PATH}"
  if [[ "${STDLIB_PATH}" != *"ocaml-cross-compilers/${TARGET}"* ]]; then
    echo "ERROR: standard_library should be under ocaml-cross-compilers/${TARGET}"
    exit 1
  fi
  if echo "${STDLIB_PATH}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
    echo "ERROR: standard_library contains build-time staging path"
    exit 1
  fi
  echo "  standard_library: clean"

  CC_PATH=$("${CROSS_OCAMLOPT}" -config-var bytecomp_c_compiler 2>/dev/null || echo "N/A")
  echo "  bytecomp_c_compiler=${CC_PATH}"

  CC_PATH=$("${CROSS_OCAMLOPT}" -config-var native_c_compiler 2>/dev/null || echo "N/A")
  echo "  native_c_compiler=${CC_PATH}"

  CC_PATH=$("${CROSS_OCAMLOPT}" -config-var c_compiler)
  echo "  c_compiler=${CC_PATH}"
  if echo "${CC_PATH}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
    echo "ERROR: c_compiler contains build-time staging path: ${CC_PATH}"
    exit 1
  fi
  echo "  c_compiler: clean"

  ASM_PATH=$("${CROSS_OCAMLOPT}" -config-var asm)
  echo "  asm=${ASM_PATH}"
  if echo "${ASM_PATH}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
    echo "ERROR: asm contains build-time staging path: ${ASM_PATH}"
    exit 1
  fi
  echo "  asm: clean"

  BYTECCLIBS=$("${CROSS_OCAMLOPT}" -config-var bytecomp_c_libraries 2>/dev/null || echo "N/A")
  echo "  bytecomp_c_libraries=${BYTECCLIBS}"
  if [[ "${BYTECCLIBS}" != "N/A" ]] && echo "${BYTECCLIBS}" | grep -qE -- "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
    echo "ERROR: bytecomp_c_libraries contains build-time -L path: ${BYTECCLIBS}"
    exit 1
  fi
  echo "  bytecomp_c_libraries: clean"

  ZSTDLIBS=$("${CROSS_OCAMLOPT}" -config-var compression_c_libraries 2>/dev/null || echo "N/A")
  echo "  compression_c_libraries=${ZSTDLIBS}"
  if [[ "${ZSTDLIBS}" != "N/A" ]] && echo "${ZSTDLIBS}" | grep -qE -- "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
    echo "ERROR: compression_c_libraries contains build-time -L path: ${ZSTDLIBS}"
    exit 1
  fi
  echo "  compression_c_libraries: clean (or not present in this version)"

  NATIVECCLIBS=$("${CROSS_OCAMLOPT}" -config-var native_c_libraries 2>/dev/null || echo "N/A")
  echo "  native_c_libraries=${NATIVECCLIBS}"
  if [[ "${NATIVECCLIBS}" != "N/A" ]] && echo "${NATIVECCLIBS}" | grep -qE -- "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
    echo "ERROR: native_c_libraries contains build-time -L path: ${NATIVECCLIBS}"
    exit 1
  fi
  echo "  native_c_libraries: clean"

  # --- Makefile.config ---
  echo "Checking Makefile.config..."
  check_no_staging_paths "${MAKEFILE_CONFIG}" "Makefile.config"

  # --- ld.conf ---
  echo "Checking ld.conf..."
  LD_CONF="${CROSS_LIBDIR}/ld.conf"
  if [[ -f "${LD_CONF}" ]]; then
    if grep -E "rattler-build_|conda-bld|build_artifacts" "${LD_CONF}" | grep -qv "${PREFIX}"; then
      echo "ERROR: ld.conf contains build-time paths"
      exit 1
    fi
    echo "  ld.conf: clean"
  else
    echo "  WARNING: ld.conf not found"
  fi

  # --- Binary strings check ---
  echo "Checking ${OCAMLOPT_BIN} for build-time paths..."
  if [[ -f "${OCAMLOPT_BIN}" ]]; then
    if strings "${OCAMLOPT_BIN}" | grep -q "rattler-build_"; then
      echo "ERROR: ocamlopt.opt contains build-time paths"
      strings "${OCAMLOPT_BIN}" | grep "rattler-build_" | head -5
      exit 1
    fi
    echo "  ocamlopt.opt binary: clean"
  else
    echo "  WARNING: ocamlopt.opt not found at ${OCAMLOPT_BIN}"
  fi

  # --- Toolchain wrappers ---
  echo "Checking toolchain wrappers..."
  for tool in cc as ar ld ranlib mkexe mkdll; do
    wrapper="${PREFIX}/bin/${TARGET}-ocaml-${tool}"
    if [[ ! -x "${wrapper}" ]]; then
      echo "ERROR: Toolchain wrapper not found: ${wrapper}"
      exit 1
    fi
  done
  echo "  ${TARGET}-ocaml-{cc,as,ar,ld,ranlib,mkexe,mkdll}: all present"

# ============================================================================
# NATIVE / CROSS-TARGET mode
# ============================================================================
else
  MAKEFILE_CONFIG="${PREFIX}/lib/ocaml/Makefile.config"
  OCAMLOPT_BIN="${PREFIX}/bin/ocamlopt.opt"

  # For cross-target builds binaries are for the target platform; skip execution-based tests
  CAN_EXECUTE=true
  if [[ "${MODE}" == "cross-target" ]]; then
    CAN_EXECUTE=false
    echo "Cross-target build: skipping execution-based tests (no QEMU)"
  fi

  # --- OCAMLLIB env var ---
  echo "Checking OCAMLLIB..."
  if [[ -n "${OCAMLLIB:-}" ]]; then
    echo "  OCAMLLIB: ${OCAMLLIB}"
    if echo "${OCAMLLIB}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
      echo "ERROR: OCAMLLIB contains build-time staging path"
      exit 1
    fi
  else
    echo "  OCAMLLIB: not set (will use default)"
  fi

  # --- runtime-launch-info BINDIR check ---
  echo "Checking runtime-launch-info..."
  RUNTIME_INFO="${PREFIX}/lib/ocaml/runtime-launch-info"
  if [[ -f "${RUNTIME_INFO}" ]]; then
    # runtime-launch-info is a BINARY file: line1="sh", line2=LIBDIR path, line3+=ocamlrun binary
    # Only check line 2 (the text path) - the binary portion may contain build-time strings
    # that are handled by conda's binary relocation separately
    RUNTIME_PATH=$(head -2 "${RUNTIME_INFO}" | tail -1)
    echo "  runtime-launch-info line 2: ${RUNTIME_PATH}"
    if echo "${RUNTIME_PATH}" | grep -q "${PREFIX}"; then
      echo "  runtime-launch-info: contains PREFIX"
    fi
    # BINDIR (line 2) is used by ocamlc at LINK TIME to construct the shebang path
    # (#!/BINDIR/ocamlrun) baked into every bytecode executable. A wrong BINDIR means
    # every bytecode program produced by this ocamlc will fail to launch.
    if echo "${RUNTIME_PATH}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
      echo "ERROR: runtime-launch-info BINDIR contains build-time staging paths"
      echo "  This will cause bytecode executables to embed a wrong #!/.../ocamlrun shebang"
      exit 1
    fi
    echo "  runtime-launch-info: clean"
  else
    echo "  runtime-launch-info: not found (may be OK for some versions)"
  fi

  # --- ld.conf ---
  echo "Checking ld.conf..."
  LD_CONF="${PREFIX}/lib/ocaml/ld.conf"
  if [[ -f "${LD_CONF}" ]]; then
    if head -2 "${LD_CONF}" | grep -q "${PREFIX}"; then
      echo "  ld.conf: contains PREFIX"
    fi
    if grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler" "${LD_CONF}"; then
      echo "ERROR: ld.conf contains build-time staging paths"
      exit 1
    fi
    echo "  ld.conf: clean"
  else
    echo "  WARNING: ld.conf not found"
  fi

  # --- Makefile.config ---
  echo "Checking Makefile.config..."
  check_no_staging_paths "${MAKEFILE_CONFIG}" "Makefile.config"

  # --- -config-var checks (skip for cross-target) ---
  if [[ "${CAN_EXECUTE}" == "true" ]]; then
    OCAML_CMD="ocamlc.opt"
    echo "Checking ${OCAML_CMD} -config-var values..."

    STDLIB_PATH=$("${OCAML_CMD}" -config-var standard_library)
    echo "  standard_library=${STDLIB_PATH}"
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
    if echo "${CC_PATH}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
      echo "ERROR: c_compiler contains build-time staging path: ${CC_PATH}"
      exit 1
    fi
    if [[ "${CC_PATH}" == /* ]] && [[ "${CC_PATH}" != "${PREFIX}"* ]]; then
      echo "ERROR: c_compiler absolute path not under PREFIX: ${CC_PATH}"
      exit 1
    fi
    echo "  c_compiler: clean"

    ASM_PATH=$("${OCAML_CMD}" -config-var asm)
    echo "  asm=${ASM_PATH}"
    if echo "${ASM_PATH}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
      echo "ERROR: asm contains build-time staging path: ${ASM_PATH}"
      exit 1
    fi
    echo "  asm: clean"

    BYTECCLIBS=$("${OCAML_CMD}" -config-var bytecomp_c_libraries 2>/dev/null || echo "N/A")
    echo "  bytecomp_c_libraries=${BYTECCLIBS}"
    if [[ "${BYTECCLIBS}" != "N/A" ]] && echo "${BYTECCLIBS}" | grep -qE -- "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
      echo "ERROR: bytecomp_c_libraries contains build-time -L path: ${BYTECCLIBS}"
      exit 1
    fi
    echo "  bytecomp_c_libraries: clean"

    ZSTDLIBS=$("${OCAML_CMD}" -config-var compression_c_libraries 2>/dev/null || echo "N/A")
    echo "  compression_c_libraries=${ZSTDLIBS}"
    if [[ "${ZSTDLIBS}" != "N/A" ]] && echo "${ZSTDLIBS}" | grep -qE -- "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
      echo "ERROR: compression_c_libraries contains build-time -L path: ${ZSTDLIBS}"
      exit 1
    fi
    echo "  compression_c_libraries: clean (or not present in this version)"

    NATIVECCLIBS=$("${OCAML_CMD}" -config-var native_c_libraries 2>/dev/null || echo "N/A")
    echo "  native_c_libraries=${NATIVECCLIBS}"
    if [[ "${NATIVECCLIBS}" != "N/A" ]] && echo "${NATIVECCLIBS}" | grep -qE -- "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
      echo "ERROR: native_c_libraries contains build-time -L path: ${NATIVECCLIBS}"
      exit 1
    fi
    echo "  native_c_libraries: clean"
  else
    echo "Skipping -config-var checks (cannot execute cross-target binaries)"
  fi

  # --- Binary strings check ---
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

  # --- macOS rpath check (native/cross-compiler only, not cross-target) ---
  if [[ "$(uname)" == "Darwin" ]] && [[ -f "${OCAMLOPT_BIN}" ]] && [[ "${MODE}" != "cross-target" ]]; then
    echo "Checking macOS rpath for libzstd..."
    echo "  Binary: ${OCAMLOPT_BIN}"
    echo "  Dependencies (otool -L):"
    otool -L "${OCAMLOPT_BIN}" 2>&1 | head -10 | sed 's/^/    /'

    if otool -L "${OCAMLOPT_BIN}" 2>/dev/null | grep -q "@rpath/libzstd"; then
      echo "  libzstd link: @rpath/libzstd (needs rpath entry)"

      echo "  LC_RPATH entries (otool -l):"
      otool -l "${OCAMLOPT_BIN}" 2>&1 | grep -A2 "LC_RPATH" | sed 's/^/    /' || echo "    (none found)"

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
fi

echo "=== All package integrity tests passed ==="
