#!/usr/bin/env bash
# Test OCaml package integrity: environment paths, resource files, and compiler config
# Verifies no build-time paths leaked into installed package
#
# Usage:
#   test-package-integrity.sh                    # Native build (can execute binaries)
#   test-package-integrity.sh cross-target       # Cross-target build (executes under OCAML_QEMU when set)
#   test-package-integrity.sh cross <target>     # Cross-compiler build

set -euo pipefail

MODE="${1:-native}"
TARGET="${2:-}"

echo "=== OCaml Package Integrity Tests (mode: ${MODE}) ==="

# binutils_impl provides triplet-prefixed tools only. PATH can also hold a
# target-arch copy, so use the first prefixed one that runs on this host.
build_tool() {
  local dir cand
  local IFS=:
  for dir in ${PATH}; do
    for cand in "${dir}"/*-"$1"; do
      if [[ -x "${cand}" ]] && "${cand}" --version >/dev/null 2>&1; then
        echo "${cand}"
        return 0
      fi
    done
  done
  echo "$1"
}
STRINGS=$(build_tool strings)
echo "Using strings: ${STRINGS}"

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
    echo "ERROR: ${label} not found at ${file} (expected unconditionally)"
    exit 1
  fi

  if grep -E "${staging_pattern}" "${file}" | grep -qv "${PREFIX}"; then
    echo "ERROR: ${label} contains build-time paths:"
    grep -E "${staging_pattern}" "${file}" | grep -v "${PREFIX}" | head -5
    exit 1
  fi
  echo "  ${label}: clean"
}

# ============================================================================
# HELPER: Check ocamlmklib runs the compilers shipped next to it
# Usage: check_ocamlmklib_compiler <ocamlc> <ocamlmklib> <expected-ocamlc-path>
#
# ocamlmklib -v prints "+ <cmd>" before running each command; the first word
# of the first such line is the compiler it resolved.
# ============================================================================
check_ocamlmklib_compiler() {
  local ocamlc_cmd="$1"
  local mklib_cmd="$2"
  local expected="$3"
  local tmpdir out first_line compiler

  tmpdir=$(mktemp -d)
  echo "let x = 1" > "${tmpdir}/a.ml"
  if ! (cd "${tmpdir}" && "${ocamlc_cmd}" -c a.ml); then
    echo "ERROR: ${ocamlc_cmd} -c failed in ${tmpdir}"
    rm -rf "${tmpdir}"
    exit 1
  fi
  if ! out=$(cd "${tmpdir}" && "${mklib_cmd}" -v -o a a.cmo 2>&1); then
    echo "ERROR: ${mklib_cmd} failed:"
    echo "${out}" | head -10
    rm -rf "${tmpdir}"
    exit 1
  fi
  rm -rf "${tmpdir}"

  first_line=$(echo "${out}" | grep -m1 '^+ ' || true)
  compiler="${first_line#+ }"
  compiler="${compiler%% *}"
  if ! [[ -n "${compiler}" && "${compiler}" -ef "${expected}" ]]; then
    echo "ERROR: ${mklib_cmd} resolved compiler '${compiler}', expected '${expected}'"
    exit 1
  fi
  echo "  ${mklib_cmd} compiler: ${compiler}"
}

# ============================================================================
# HELPER: ocamlmklib must not record -L$PREFIX/lib in .cma/.cmxa
# conda-forge/ocaml-feedstock#191
# ============================================================================
check_ocamlmklib_archive_flags() {
  local tmpdir archive info extra
  echo "Checking ocamlmklib archive link flags (#191)..."
  tmpdir=$(mktemp -d)
  cat > "${tmpdir}/stub.c" <<'EOF'
#include <caml/mlvalues.h>
value ml191_id(value v){return v;}
EOF
  echo 'external id : int -> int = "ml191_id"' > "${tmpdir}/m191.ml"
  if ! (cd "${tmpdir}" && ocamlc -c m191.ml \
        && { ! command -v ocamlopt >/dev/null 2>&1 || ocamlopt -c m191.ml; } \
        && CONDA_BUILD=1 PREFIX="${PREFIX}" ocamlmklib -o m191 stub.c m191.cmo \
             $(command -v ocamlopt >/dev/null 2>&1 && echo m191.cmx) -L"${PREFIX}/lib"); then
    echo "ERROR: building m191 with ocamlmklib failed"
    rm -rf "${tmpdir}"
    exit 1
  fi

  for archive in m191.cma m191.cmxa; do
    if [[ ! -f "${tmpdir}/${archive}" ]]; then
      if [[ "${archive}" == m191.cmxa ]] && ! command -v ocamlopt >/dev/null 2>&1; then
        continue
      fi
      echo "ERROR: ocamlmklib did not produce ${archive}"
      rm -rf "${tmpdir}"
      exit 1
    fi
    info=$(cd "${tmpdir}" && ocamlobjinfo "${archive}")
    extra=$(echo "${info}" | grep -E '^Extra C (object files|options)' || true)
    echo "  ${archive}:"
    echo "${extra}" | sed 's/^/    /'
    if echo "${extra}" | grep -qF -e "-L${PREFIX}/lib"; then
      echo "ERROR: ${archive} records -L${PREFIX}/lib"
      rm -rf "${tmpdir}"
      exit 1
    fi
    if ! echo "${extra}" | grep -qF -e "-lm191"; then
      echo "ERROR: ${archive} does not record -lm191"
      rm -rf "${tmpdir}"
      exit 1
    fi
    echo "  [PASS] ${archive}: no -L${PREFIX}/lib, -lm191 recorded"
  done

  if command -v ocamlopt >/dev/null 2>&1; then
    if ! (cd "${tmpdir}" && ocamlopt -shared -linkall -I . m191.cmxa -o m191.cmxs); then
      echo "ERROR: ocamlopt -shared of m191.cmxa failed"
      rm -rf "${tmpdir}"
      exit 1
    fi
    echo "  [PASS] ocamlopt -shared m191.cmxa -> m191.cmxs"
  fi
  rm -rf "${tmpdir}"
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
    if "${STRINGS}" "${OCAMLOPT_BIN}" | grep -q "rattler-build_"; then
      echo "ERROR: ocamlopt.opt contains build-time paths"
      "${STRINGS}" "${OCAMLOPT_BIN}" | grep "rattler-build_" | head -5
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

  # --- Bytecode launchers ---
  # The cross tree's bytecode tools run on its own BUILD-arch ocamlrun, so the
  # package works without a native ocaml installed.
  echo "Checking cross bytecode launchers..."
  CROSS_OCAMLRUN="${CROSS_PREFIX}/bin/ocamlrun"
  if [[ ! -x "${CROSS_OCAMLRUN}" ]]; then
    echo "ERROR: ${CROSS_OCAMLRUN} not found or not executable"
    exit 1
  fi
  if ! "${CROSS_OCAMLRUN}" -version; then
    echo "ERROR: ${CROSS_OCAMLRUN} does not run on this host"
    exit 1
  fi
  if "${STRINGS}" "${CROSS_OCAMLRUN}" | grep -q "rattler-build_"; then
    echo "ERROR: ocamlrun contains build-time paths"
    "${STRINGS}" "${CROSS_OCAMLRUN}" | grep "rattler-build_" | head -5
    exit 1
  fi
  for launcher in "${CROSS_PREFIX}/bin/ocamlmklib" "${CROSS_LIBDIR}/expunge"; do
    # C locale: line 2 may be bytecode, which BSD tr rejects as UTF-8
    launch_line=$(sed -n '2p' "${launcher}" | LC_ALL=C tr -d '\0')
    if [[ "${launch_line}" == "r='"* ]]; then
      # OCaml 5.5 sh launcher: r=<runtime name>, c=<bindir>/"$r", search fallback
      launch_r="${launch_line#r=\'}"
      launch_r="${launch_r%%\'*}"
      launch_c=$(sed -n '3p' "${launcher}" | LC_ALL=C tr -d '\0')
      launch_dir="${launch_c#c=}"
      launch_dir="${launch_dir%/\"\$r\"}"
      echo "  ${launcher##*/} launcher:"
      head -n 12 "${launcher}" | LC_ALL=C tr -d '\0' | sed 's/^/    | /'
      candidate=""
      how=""
      if [[ -f "${launch_dir}/${launch_r}" ]]; then
        candidate="${launch_dir}/${launch_r}"
        how="baked bindir"
      elif [[ -x "$(dirname "${launcher}")/${launch_r}" ]]; then
        candidate="$(dirname "${launcher}")/${launch_r}"
        how="next to launcher"
      else
        candidate=$(command -v "${launch_r}" || true)
        how="PATH"
      fi
      if [[ -z "${candidate}" || ! -x "${candidate}" ]] \
          || ! "${candidate}" -version 2>&1 | grep -q "The OCaml runtime"; then
        echo "ERROR: ${launcher} runtime '${launch_r}' does not resolve to a runnable ocamlrun"
        echo "  baked bindir: '${launch_dir}', candidate: '${candidate}' (${how})"
        exit 1
      fi
      if [[ "${launcher}" == */ocamlmklib ]] && ! "${launcher}" -version; then
        echo "ERROR: ${launcher} -version failed"
        exit 1
      fi
      echo "  ${launcher##*/}: runtime ${candidate} (${how})"
      continue
    fi
    if [[ "${launch_line}" != 'exec "$(dirname "$0")/'*'ocamlrun" "$0" "$@"' ]]; then
      echo "ERROR: ${launcher} does not launch the cross tree's ocamlrun: ${launch_line}"
      exit 1
    fi
    echo "  ${launcher##*/}: ${launch_line}"
  done

  # --- ocamlmklib compiler resolution ---
  # conda-forge/ocaml-feedstock#188: ocamlmklib must use the compilers next to it, not Config.bindir
  echo "Checking ${TARGET}-ocamlmklib compiler resolution..."
  check_ocamlmklib_compiler "${PREFIX}/bin/${TARGET}-ocamlc" "${PREFIX}/bin/${TARGET}-ocamlmklib" \
    "${CROSS_PREFIX}/bin/ocamlc"

# ============================================================================
# NATIVE / CROSS-TARGET mode
# ============================================================================
else
  MAKEFILE_CONFIG="${PREFIX}/lib/ocaml/Makefile.config"
  OCAMLOPT_BIN="${PREFIX}/bin/ocamlopt.opt"

  # Cross-target binaries run under the emulator when one is available
  OCAML_RUN=(ocamlc.opt)
  CAN_EXECUTE=true
  if [[ "${MODE}" == "cross-target" ]]; then
    if [[ -n "${OCAML_QEMU:-}" ]]; then
      OCAML_RUN=("${OCAML_QEMU}" "${PREFIX}/bin/ocamlc.opt")
      echo "Cross-target build: running ocamlc.opt under ${OCAML_QEMU}"
    else
      CAN_EXECUTE=false
      echo "Cross-target build: skipping execution-based tests (OCAML_QEMU not set)"
    fi
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

  # Absolute -L paths in Makefile.config must stay under PREFIX; a stray one
  # means the -L${PREFIX} strip guard was skipped, leaking build-sandbox paths.
  if [[ -f "${MAKEFILE_CONFIG}" ]]; then
    L_ERR=0
    for ltok in $(grep -oE -- '-L/[^ ]+' "${MAKEFILE_CONFIG}" 2>/dev/null || true); do
      lpath="${ltok#-L}"
      if [[ "${lpath}" != "${PREFIX}"* ]]; then
        echo "ERROR: Makefile.config -L path outside PREFIX: ${ltok}"
        L_ERR=1
      fi
    done
    if [[ "${L_ERR}" -eq 1 ]]; then
      exit 1
    fi
    echo "  Makefile.config: -L paths clean"
  fi

  # --- -config-var checks ---
  if [[ "${CAN_EXECUTE}" == "true" ]]; then
    echo "Checking ocamlc.opt -config-var values..."

    STDLIB_PATH=$("${OCAML_RUN[@]}" -config-var standard_library)
    echo "  standard_library=${STDLIB_PATH}"
    if echo "${STDLIB_PATH}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
      echo "ERROR: standard_library contains build-time staging path"
      exit 1
    fi
    echo "  standard_library: clean"

    CC_PATH=$("${OCAML_RUN[@]}" -config-var bytecomp_c_compiler 2>/dev/null || echo "N/A")
    echo "  bytecomp_c_compiler=${CC_PATH}"

    CC_PATH=$("${OCAML_RUN[@]}" -config-var native_c_compiler 2>/dev/null || echo "N/A")
    echo "  native_c_compiler=${CC_PATH}"

    CC_PATH=$("${OCAML_RUN[@]}" -config-var c_compiler)
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

    ASM_PATH=$("${OCAML_RUN[@]}" -config-var asm)
    echo "  asm=${ASM_PATH}"
    if echo "${ASM_PATH}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
      echo "ERROR: asm contains build-time staging path: ${ASM_PATH}"
      exit 1
    fi
    echo "  asm: clean"

    BYTECCLIBS=$("${OCAML_RUN[@]}" -config-var bytecomp_c_libraries 2>/dev/null || echo "N/A")
    echo "  bytecomp_c_libraries=${BYTECCLIBS}"
    if [[ "${BYTECCLIBS}" != "N/A" ]] && echo "${BYTECCLIBS}" | grep -qE -- "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
      echo "ERROR: bytecomp_c_libraries contains build-time -L path: ${BYTECCLIBS}"
      exit 1
    fi
    echo "  bytecomp_c_libraries: clean"

    ZSTDLIBS=$("${OCAML_RUN[@]}" -config-var compression_c_libraries 2>/dev/null || echo "N/A")
    echo "  compression_c_libraries=${ZSTDLIBS}"
    if [[ "${ZSTDLIBS}" != "N/A" ]] && echo "${ZSTDLIBS}" | grep -qE -- "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
      echo "ERROR: compression_c_libraries contains build-time -L path: ${ZSTDLIBS}"
      exit 1
    fi
    echo "  compression_c_libraries: clean (or not present in this version)"

    NATIVECCLIBS=$("${OCAML_RUN[@]}" -config-var native_c_libraries 2>/dev/null || echo "N/A")
    echo "  native_c_libraries=${NATIVECCLIBS}"
    if [[ "${NATIVECCLIBS}" != "N/A" ]] && echo "${NATIVECCLIBS}" | grep -qE -- "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
      echo "ERROR: native_c_libraries contains build-time -L path: ${NATIVECCLIBS}"
      exit 1
    fi
    echo "  native_c_libraries: clean"

    # bindir and standard_library_default are baked into the binary; they must
    # name the install prefix so conda relocates them.
    for var in bindir standard_library_default; do
      VAR_VALUE=$("${OCAML_RUN[@]}" -config-var "${var}" 2>/dev/null || echo "N/A")
      if echo "${VAR_VALUE}" | grep -qE "_h_env|_build_env|/work/|_native_compiler|_xcross_compiler|_target_compiler"; then
        echo "ERROR: ${var} contains build-time staging path: ${VAR_VALUE}"
        exit 1
      fi
    done

    # conda-forge/ocaml-feedstock#188: ocamlmklib must use the compilers next to it, not Config.bindir
    # Native only: under OCAML_QEMU the compilers ocamlmklib spawns cannot run.
    if [[ "${MODE}" != "native" ]]; then
      echo "  ocamlmklib compiler resolution: skipped in ${MODE} mode"
    else
      case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
          echo "  ocamlmklib compiler resolution: skipped on Windows (uses PATH by design)"
          ;;
        *)
          echo "Checking ocamlmklib compiler resolution..."
          check_ocamlmklib_compiler ocamlc ocamlmklib "${PREFIX}/bin/ocamlc"
          check_ocamlmklib_archive_flags
          ;;
      esac
    fi
  else
    echo "Skipping -config-var checks (cannot execute cross-target binaries)"
  fi

  # --- Binary strings check ---
  echo "Checking ocamlc.opt binary for build-time paths..."
  OCAMLC_BIN="${PREFIX}/bin/ocamlc.opt"
  if [[ -f "${OCAMLC_BIN}" ]]; then
    if "${STRINGS}" "${OCAMLC_BIN}" | grep -q "rattler-build_"; then
      echo "ERROR: ocamlc.opt contains build-time paths"
      "${STRINGS}" "${OCAMLC_BIN}" | grep "rattler-build_" | head -5
      exit 1
    fi
    echo "  ocamlc.opt binary: clean"
  else
    echo "  WARNING: ocamlc.opt not found"
  fi

  # --- Config is opaque to other compiler-libs units ---
  # Config bakes per-build paths; units importing its implementation with a CRC
  # would change CRC on every rebuild. ocamlobjinfo prints an all-dash CRC for
  # an opaque import. Cross-target ocamlobjinfo runs under the emulator; .cmx
  # metadata is architecture-independent.
  OBJINFO_RUN=("${PREFIX}/bin/ocamlobjinfo")
  if [[ "${MODE}" == "cross-target" ]]; then
    OBJINFO_RUN=("${OCAML_QEMU:-}" "${PREFIX}/bin/ocamlobjinfo.opt")
  fi
  if [[ "${CAN_EXECUTE}" != "true" ]]; then
    echo "Skipping Config opacity check (cannot execute cross-target binaries)"
  else
    echo "Checking Config is imported without an implementation CRC..."
    for unit in clflags location; do
      cmx="${PREFIX}/lib/ocaml/compiler-libs/${unit}.cmx"
      if [[ ! -f "${cmx}" ]]; then
        echo "ERROR: ${cmx} not found"
        exit 1
      fi
      config_crc=$("${OBJINFO_RUN[@]}" "${cmx}" \
        | awk '/^Implementations imported:/ {f=1; next} /^[^[:space:]]/ {f=0} f && $2 == "Config" {print $1}')
      if [[ -z "${config_crc}" ]]; then
        # clflags uses Config; location does not import its implementation
        if [[ "${unit}" == "clflags" ]]; then
          echo "ERROR: clflags.cmx does not list Config under implementations imported"
          exit 1
        fi
        echo "  ${unit}.cmx: does not import Config"
        continue
      fi
      if [[ "${config_crc}" != "${config_crc//[^-]/}" ]]; then
        echo "ERROR: ${unit}.cmx imports Config implementation with CRC ${config_crc}"
        exit 1
      fi
      echo "  ${unit}.cmx: Config imported without CRC"
    done
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

# --- Staging prefixes in shipped files (all modes) ---
# Paths compiled into binaries and libraries are invisible to -config-var when
# the binary cannot run here, so scan the bytes of every shipped file.
echo "Scanning shipped files for build-time staging prefixes..."
if [[ "${MODE}" == "cross" ]]; then
  SCAN_PATHS=("${PREFIX}/bin/${TARGET}-"* "${PREFIX}/lib/ocaml-cross-compilers/${TARGET}")
else
  SCAN_PATHS=("${PREFIX}/bin/oc"* "${PREFIX}/lib/ocaml")
fi
STAGING_RE='/_(native|xcross|target)_compiler'
# .cmt/.cmti record the build command line and load path; they never name a
# runtime path, so they are skipped.
STAGING_HITS=$(grep -rlaE --exclude='*.cmt' --exclude='*.cmti' "${STAGING_RE}" "${SCAN_PATHS[@]}" 2>/dev/null || true)
if [[ -n "${STAGING_HITS}" ]]; then
  echo "ERROR: shipped files contain build-time staging prefixes:"
  while IFS= read -r hit; do
    echo "  ${hit}: $(grep -aoE "[^[:space:][:cntrl:]]*${STAGING_RE}[^[:space:][:cntrl:]]*" "${hit}" | head -1)"
  done <<< "${STAGING_HITS}"
  exit 1
fi
echo "  staging prefixes: none in ${#SCAN_PATHS[@]} scanned paths"

echo "=== All package integrity tests passed ==="
