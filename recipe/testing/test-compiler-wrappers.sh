#!/usr/bin/env bash
# Test that conda-ocaml-cc/mkexe/mkdll wrappers resolve to real compilers
# This test runs on ocaml_$platform (NOT ocaml-compiler) with NO extra C compiler
# test dep — it validates that the run dep on compiler("c") provides the
# triplet-prefixed binary that activate.sh bakes into CONDA_OCAML_CC.
#
# This catches: missing C compiler run dep, broken activation, wrong triplet name

set -euo pipefail

MODE="${1:-native}"
echo "=== OCaml Compiler Wrapper Tests (mode: ${MODE}) ==="

if [[ "${MODE}" == "cross-target" ]]; then
  echo "  Cross-target: skipping execution-based wrapper tests (no QEMU)"
  echo "  Verifying CONDA_OCAML_CC is set..."
  if [[ -z "${CONDA_OCAML_CC:-}" ]]; then
    echo "  FAIL: CONDA_OCAML_CC is not set after activation"
    exit 1
  fi
  echo "  CONDA_OCAML_CC=${CONDA_OCAML_CC} (set but cannot verify execution)"
  echo "=== Wrapper tests passed (cross-target, limited) ==="
  exit 0
fi

ERRORS=0

# Test 1: CONDA_OCAML_CC is set and resolves to a real binary
echo "Test 1: CONDA_OCAML_CC resolves to a real compiler"
if [[ -z "${CONDA_OCAML_CC:-}" ]]; then
  echo "  FAIL: CONDA_OCAML_CC is not set"
  ERRORS=$((ERRORS + 1))
else
  echo "  CONDA_OCAML_CC=${CONDA_OCAML_CC}"
  if command -v ${CONDA_OCAML_CC} >/dev/null 2>&1; then
    echo "  PASS: '${CONDA_OCAML_CC}' found in PATH"
  else
    echo "  FAIL: '${CONDA_OCAML_CC}' not found in PATH"
    echo "  PATH=${PATH}"
    ERRORS=$((ERRORS + 1))
  fi
fi

# Test 2: conda-ocaml-cc wrapper can compile a C file
echo "Test 2: conda-ocaml-cc compiles a C file"
cat > /tmp/wrapper_test.c << 'EOF'
#include <stdio.h>
int main() { printf("wrapper-ok\n"); return 0; }
EOF

if conda-ocaml-cc -o /tmp/wrapper_test /tmp/wrapper_test.c 2>/tmp/wrapper_cc_err.txt; then
  if /tmp/wrapper_test | grep -q "wrapper-ok"; then
    echo "  PASS: conda-ocaml-cc compiled and ran successfully"
  else
    echo "  FAIL: compiled but output wrong"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "  FAIL: conda-ocaml-cc compilation failed"
  cat /tmp/wrapper_cc_err.txt | head -10
  ERRORS=$((ERRORS + 1))
fi
rm -f /tmp/wrapper_test /tmp/wrapper_test.c /tmp/wrapper_cc_err.txt

# Test 3: conda-ocaml-mkexe wrapper works (used by ocamlc -custom)
echo "Test 3: conda-ocaml-mkexe links an executable"
cat > /tmp/mkexe_test.c << 'EOF'
int main() { return 0; }
EOF

if conda-ocaml-cc -c -o /tmp/mkexe_test.o /tmp/mkexe_test.c 2>/dev/null; then
  if conda-ocaml-mkexe -o /tmp/mkexe_test /tmp/mkexe_test.o 2>/tmp/mkexe_err.txt; then
    echo "  PASS: conda-ocaml-mkexe linked successfully"
  else
    echo "  FAIL: conda-ocaml-mkexe linking failed"
    cat /tmp/mkexe_err.txt | head -10
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "  FAIL: could not compile test object"
  ERRORS=$((ERRORS + 1))
fi
rm -f /tmp/mkexe_test /tmp/mkexe_test.o /tmp/mkexe_test.c /tmp/mkexe_err.txt

if [[ $ERRORS -gt 0 ]]; then
  echo "=== FAILED: ${ERRORS} wrapper test(s) failed ==="
  exit 1
fi

echo "=== All wrapper tests passed ==="
