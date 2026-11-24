#!/usr/bin/env bash
# Cross-target package: its compiler-libs must agree with the cross compiler's.
# Downstream cross builds (ppxlib) compile against the target compiler-libs and
# link the cross package's ocamlcommon.cmxa. Compile and link only; no target
# binary is executed.
# Usage: test-cross-target-compiler-libs.sh <target-triplet>
# PREFIX is the target install; CONDA_PREFIX is the build env holding the cross compiler.

set -euo pipefail

TRIPLET="${1:?usage: $0 <target-triplet>}"
TARGET_CL="${PREFIX}/lib/ocaml/compiler-libs"
CROSS_CL="${CONDA_PREFIX}/lib/ocaml-cross-compilers/${TRIPLET}/lib/ocaml/compiler-libs"

echo "=== cross-target compiler-libs consistency test ==="
CROSS_OCAMLOPT=""
for c in "${CONDA_PREFIX}/lib/ocaml-cross-compilers/${TRIPLET}/shims/ocamlopt.opt" \
  "${CONDA_PREFIX}/bin/${TRIPLET}-ocamlopt.opt" \
  "${CONDA_PREFIX}/bin/${TRIPLET}-ocamlopt"; do
  if [[ -e "${c}" ]]; then
    CROSS_OCAMLOPT="${c}"
    break
  fi
done
if [[ -z "${CROSS_OCAMLOPT}" ]]; then
  echo "[FAIL] missing cross ocamlopt"
  exit 1
fi
echo "  cross ocamlopt: ${CROSS_OCAMLOPT}"
for p in "${CROSS_CL}/ocamlcommon.cmxa" "${TARGET_CL}/parse.cmx"; do
  if [[ ! -e "${p}" ]]; then
    echo "[FAIL] missing: ${p}"
    exit 1
  fi
done

# The cross ocamlopt links through the conda-ocaml wrappers.
if [[ -z "${CONDA_OCAML_CC:-}" ]]; then
  if command -v "${TRIPLET}-gcc" > /dev/null 2>&1; then
    export CONDA_OCAML_CC="${TRIPLET}-gcc"
  else
    export CONDA_OCAML_CC="${TRIPLET}-clang"
  fi
fi
export CONDA_OCAML_MKEXE="${CONDA_OCAML_MKEXE:-${CONDA_OCAML_CC}}"
export CONDA_OCAML_MKDLL="${CONDA_OCAML_MKDLL:-${CONDA_OCAML_CC} -shared}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}"

printf 'let f lb = Parse.implementation lb\n' > m.ml
printf 'let () = ignore M.f\n' > main.ml

fail() {
  echo "[FAIL] target and cross compiler-libs disagree"
  cat out.txt
  exit 1
}

"${CROSS_OCAMLOPT}" -I "${TARGET_CL}" -c m.ml > out.txt 2>&1 || fail
"${CROSS_OCAMLOPT}" -I "${CROSS_CL}" "${CROSS_CL}/ocamlcommon.cmxa" m.cmx main.ml -o main > out.txt 2>&1 || fail

echo "=== cross-target compiler-libs consistency test passed ==="
