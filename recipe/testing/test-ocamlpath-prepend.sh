#!/usr/bin/env bash
# Test the OCAMLPATH prepend done by the installed activation during a conda
# build: PREFIX/lib/ocaml goes first, deactivation restores unset, empty and
# non-empty values exactly, and a second activation does not duplicate.

set -euo pipefail

ACTIVATE="${CONDA_PREFIX}/etc/conda/activate.d/ocaml_activate.sh"
DEACTIVATE="${CONDA_PREFIX}/etc/conda/deactivate.d/ocaml_deactivate.sh"

echo "=== OCAMLPATH Prepend Tests ==="

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
HOST="${WORK}/host"
mkdir -p "${HOST}/lib/ocaml"
LIB="${HOST}/lib/ocaml"

fail() {
  echo "FAIL ($1)"
  exit 1
}

# Source activation as a conda build would: PREFIX differs from CONDA_PREFIX
activate() {
  export CONDA_BUILD=1
  export PREFIX="${HOST}"
  # shellcheck disable=SC1090
  source "${ACTIVATE}"
}

deactivate() {
  # shellcheck disable=SC1090
  source "${DEACTIVATE}"
}

# Each case runs in a subshell so the activation state never leaks
echo -n "  OCAMLPATH unset: "
(
  unset OCAMLPATH
  activate
  case "${OCAMLPATH:-}" in
    "${LIB}"*) ;;
    *) fail "after activate: '${OCAMLPATH:-}'" ;;
  esac
  deactivate
  [[ -z "${OCAMLPATH+x}" ]] || fail "still set after deactivate: '${OCAMLPATH}'"
)
echo "OK"

echo -n "  OCAMLPATH empty: "
(
  export OCAMLPATH=""
  activate
  [[ "${OCAMLPATH}" = "${LIB}" ]] || fail "after activate: '${OCAMLPATH}'"
  deactivate
  [[ "${OCAMLPATH+x}" = "x" ]] || fail "unset after deactivate"
  [[ -z "${OCAMLPATH}" ]] || fail "not empty after deactivate: '${OCAMLPATH}'"
)
echo "OK"

echo -n "  OCAMLPATH=/x: "
(
  export OCAMLPATH="/x"
  activate
  [[ "${OCAMLPATH}" = "${LIB}:/x" ]] || fail "after activate: '${OCAMLPATH}'"
  deactivate
  [[ "${OCAMLPATH:-}" = "/x" ]] || fail "after deactivate: '${OCAMLPATH:-}'"
)
echo "OK"

echo -n "  double activate: "
(
  export OCAMLPATH="/x"
  activate
  activate
  [[ "${OCAMLPATH}" = "${LIB}:/x" ]] || fail "duplicated: '${OCAMLPATH}'"
  deactivate
  [[ "${OCAMLPATH:-}" = "/x" ]] || fail "after deactivate: '${OCAMLPATH:-}'"
)
echo "OK"

echo "=== All OCAMLPATH prepend tests passed ==="
