#!/usr/bin/env bash
# Test that the cross-compiler activates itself in a cross-compiling env:
# plain ocamlopt must resolve to the cross compiler and emit target objects.
# Usage: test-cross-self-activation.sh <target_triplet>
set -euo pipefail

TARGET="$1"
# The package under test is installed in PREFIX; the test run activates the
# build env, so CONDA_PREFIX may name that unrelated env.
export CONDA_PREFIX="${PREFIX:-${CONDA_PREFIX}}"
ACTIVATE="${CONDA_PREFIX}/etc/conda/activate.d/ocaml_cross_activate.sh"
DEACTIVATE="${CONDA_PREFIX}/etc/conda/deactivate.d/ocaml_cross_deactivate.sh"
SHIMS="${CONDA_PREFIX}/lib/ocaml-cross-compilers/${TARGET}/shims"

case "${TARGET}" in
  aarch64-*|arm64-*) EXPECTED_ARCH="arm64";  FILE_RE="aarch64|arm64" ;;
  powerpc64le-*)     EXPECTED_ARCH="power";  FILE_RE="powerpc|ppc64" ;;
  riscv64-*)         EXPECTED_ARCH="riscv";  FILE_RE="risc-v" ;;
  s390x-*)           EXPECTED_ARCH="s390x";  FILE_RE="S/390|s390" ;;
  x86_64-*)          EXPECTED_ARCH="amd64";  FILE_RE="x86-64|x86_64" ;;
  *) echo "[FAIL] Unrecognised target ${TARGET}"; exit 1 ;;
esac

echo "=== Cross-Compiler Self-Activation Tests (${TARGET}) ==="
ERRORS=0

# Count PATH entries equal to the launcher dir
shims_on_path() {
  local _n=0 _entry
  local IFS=:
  for _entry in ${PATH}; do
    [[ "${_entry}" == "${SHIMS}" ]] && _n=$((_n + 1))
  done
  echo "${_n}"
}

echo "Test 1: activation switches to cross mode"
export CONDA_BUILD_CROSS_COMPILATION=1
# shellcheck disable=SC1090
source "${ACTIVATE}"
if [[ "${OCAML_CROSS_MODE:-}" == "cross" ]]; then
  echo "  PASS: OCAML_CROSS_MODE=cross"
else
  echo "  FAIL: OCAML_CROSS_MODE='${OCAML_CROSS_MODE:-<unset>}' (expected 'cross')"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 2: second activation keeps one PATH entry"
# shellcheck disable=SC1090
source "${ACTIVATE}"
if [[ "$(shims_on_path)" == "1" ]]; then
  echo "  PASS: ${SHIMS} on PATH once"
else
  echo "  FAIL: ${SHIMS} on PATH $(shims_on_path) times (expected 1)"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 3: plain ocamlopt resolves to the launcher dir"
_ocamlopt=$(command -v ocamlopt || true)
if [[ "${_ocamlopt}" == "${SHIMS}/ocamlopt" ]]; then
  echo "  PASS: ocamlopt -> ${_ocamlopt}"
else
  echo "  FAIL: ocamlopt -> '${_ocamlopt:-<not found>}' (expected ${SHIMS}/ocamlopt)"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 4: ocamlopt -config reports the target architecture"
_arch=$(ocamlopt -config 2>/dev/null | sed -n 's/^architecture: //p' || true)
if [[ "${_arch}" == "${EXPECTED_ARCH}" ]]; then
  echo "  PASS: architecture=${_arch}"
else
  echo "  FAIL: architecture='${_arch}' (expected ${EXPECTED_ARCH})"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 5: ocamlopt -c emits a target object"
WORK=$(mktemp -d)
echo 'let x = 42' > "${WORK}/self_act.ml"
if (cd "${WORK}" && ocamlopt -c self_act.ml); then
  _file_output=$(file "${WORK}/self_act.o")
  if echo "${_file_output}" | grep -qiE "${FILE_RE}"; then
    echo "  PASS: ${_file_output}"
  else
    echo "  FAIL: expected ${EXPECTED_ARCH} object, got: ${_file_output}"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "  FAIL: ocamlopt -c failed"
  ERRORS=$((ERRORS + 1))
fi
rm -rf "${WORK}"

echo "Test 6: the ocaml launcher runs the cross toplevel without a native ocaml"
if [[ -x "${SHIMS}/ocaml" ]]; then
  WORK=$(mktemp -d)
  echo 'let () = print_string "shim-ok"' > "${WORK}/shim_ok.ml"
  _out=$(cd "${WORK}" && PATH="${SHIMS}:/usr/bin:/bin" "${SHIMS}/ocaml" shim_ok.ml 2>&1 || true)
  if [[ "${_out}" == "shim-ok" ]]; then
    echo "  PASS: ${SHIMS}/ocaml ran a script"
  else
    echo "  FAIL: ${SHIMS}/ocaml printed '${_out}' (expected 'shim-ok')"
    ERRORS=$((ERRORS + 1))
  fi
  rm -rf "${WORK}"
else
  echo "  FAIL: ${SHIMS}/ocaml missing or not executable"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 7: deactivation removes the launcher dir"
# shellcheck disable=SC1090
source "${DEACTIVATE}"
if [[ "$(shims_on_path)" == "0" && -z "${OCAML_CROSS_MODE:-}" ]]; then
  echo "  PASS: PATH and OCAML_CROSS_MODE restored"
else
  echo "  FAIL: PATH has ${SHIMS} $(shims_on_path) times, OCAML_CROSS_MODE='${OCAML_CROSS_MODE:-}'"
  ERRORS=$((ERRORS + 1))
fi

if [[ $ERRORS -gt 0 ]]; then
  echo "=== FAILED: ${ERRORS} self-activation test(s) failed ==="
  exit 1
fi

echo "=== All self-activation tests passed ==="
