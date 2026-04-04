#!/usr/bin/env bash
# Test cross-compiler activation scripts (ocaml_use_cross / ocaml_use_native)
# Validates that cross-activate.sh installs correctly and swap functions work.
set -euo pipefail

echo "=== Cross-Compiler Activation Tests ==="
ERRORS=0

# Test 1: Cross activation script exists and was sourced
echo "Test 1: Cross activation script sourced"
if [[ -z "${OCAML_CROSS_TARGET:-}" ]]; then
  echo "  FAIL: OCAML_CROSS_TARGET not set — cross-activate.sh not sourced"
  ERRORS=$((ERRORS + 1))
else
  echo "  PASS: OCAML_CROSS_TARGET=${OCAML_CROSS_TARGET}"
fi

# Test 2: OCAML_CROSS_MODE starts as "native"
echo "Test 2: Initial mode is native"
if [[ "${OCAML_CROSS_MODE:-}" != "native" ]]; then
  echo "  FAIL: OCAML_CROSS_MODE='${OCAML_CROSS_MODE:-<unset>}' (expected 'native')"
  ERRORS=$((ERRORS + 1))
else
  echo "  PASS: OCAML_CROSS_MODE=native"
fi

# Test 3: ocaml_use_cross function exists
echo "Test 3: ocaml_use_cross function defined"
if ! type ocaml_use_cross >/dev/null 2>&1; then
  echo "  FAIL: ocaml_use_cross function not defined"
  ERRORS=$((ERRORS + 1))
else
  echo "  PASS: ocaml_use_cross defined"
fi

# Test 4: ocaml_use_native function exists
echo "Test 4: ocaml_use_native function defined"
if ! type ocaml_use_native >/dev/null 2>&1; then
  echo "  FAIL: ocaml_use_native function not defined"
  ERRORS=$((ERRORS + 1))
else
  echo "  PASS: ocaml_use_native defined"
fi

# Test 5: Native values are backed up
echo "Test 5: Native values backed up"
if [[ -z "${_OCAML_NATIVE_CC:-}" ]]; then
  echo "  FAIL: _OCAML_NATIVE_CC not set (native backup missing)"
  ERRORS=$((ERRORS + 1))
else
  echo "  PASS: _OCAML_NATIVE_CC=${_OCAML_NATIVE_CC}"
fi

# Test 6: Swap to cross mode and verify
echo "Test 6: ocaml_use_cross swaps environment"
NATIVE_CC="${CONDA_OCAML_CC:-}"
ocaml_use_cross
if [[ "${OCAML_CROSS_MODE}" != "cross" ]]; then
  echo "  FAIL: OCAML_CROSS_MODE='${OCAML_CROSS_MODE}' after ocaml_use_cross (expected 'cross')"
  ERRORS=$((ERRORS + 1))
else
  echo "  PASS: OCAML_CROSS_MODE=cross"
fi
# CONDA_OCAML_CC should have changed (unless native and cross happen to use same compiler)
echo "  CONDA_OCAML_CC=${CONDA_OCAML_CC:-<unset>} (was ${NATIVE_CC})"

# Test 7: OCAMLLIB points to cross-compiler path
echo "Test 7: OCAMLLIB points to cross-compiler"
if [[ "${OCAMLLIB:-}" == *"ocaml-cross-compilers"* ]]; then
  echo "  PASS: OCAMLLIB=${OCAMLLIB}"
else
  echo "  FAIL: OCAMLLIB='${OCAMLLIB:-<unset>}' (expected path containing 'ocaml-cross-compilers')"
  ERRORS=$((ERRORS + 1))
fi

# Test 8: Swap back to native and verify
echo "Test 8: ocaml_use_native restores environment"
ocaml_use_native
if [[ "${OCAML_CROSS_MODE}" != "native" ]]; then
  echo "  FAIL: OCAML_CROSS_MODE='${OCAML_CROSS_MODE}' after ocaml_use_native (expected 'native')"
  ERRORS=$((ERRORS + 1))
else
  echo "  PASS: OCAML_CROSS_MODE=native"
fi

# Test 9: CONDA_OCAML_CC restored to original
echo "Test 9: CONDA_OCAML_CC restored"
if [[ "${CONDA_OCAML_CC:-}" == "${NATIVE_CC}" ]]; then
  echo "  PASS: CONDA_OCAML_CC=${CONDA_OCAML_CC} (restored)"
else
  echo "  FAIL: CONDA_OCAML_CC='${CONDA_OCAML_CC:-<unset>}' (expected '${NATIVE_CC}')"
  ERRORS=$((ERRORS + 1))
fi

if [[ $ERRORS -gt 0 ]]; then
  echo "=== FAILED: ${ERRORS} cross-activation test(s) failed ==="
  exit 1
fi

echo "=== All cross-activation tests passed ==="
