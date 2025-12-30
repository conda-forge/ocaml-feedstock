#!/usr/bin/env bash
# Test environment variables and resource file paths
# Verifies no build-time paths leaked into installed package

set -euo pipefail

echo "=== OCAML config Tests ==="

# Check config vars don't contain build-time paths
echo "Checking ocamlc.opt -config-var values..."

STDLIB_PATH=$(ocamlc.opt -config-var standard_library)
echo "  standard_library=${STDLIB_PATH}"

CC_PATH=$(ocamlc.opt -config-var c_compiler)
echo "  c_compiler=${CC_PATH}"

# Should be basename OR contain $PREFIX, never rattler-build_ from another job
if echo "$CC_PATH" | grep -q "rattler-build_"; then
  echo "ERROR: c_compiler contains build-time path: $CC_PATH"
  exit 1
fi

# If absolute path, must be under PREFIX
if [[ "$CC_PATH" == /* ]] && [[ "$CC_PATH" != "${PREFIX}"* ]]; then
  echo "ERROR: c_compiler absolute path not under PREFIX: $CC_PATH"
  exit 1
fi
echo "  c_compiler: clean"

ASM_PATH=$(ocamlc.opt -config-var asm)
echo "  asm=${ASM_PATH}"
if echo "$ASM_PATH" | grep -q "rattler-build_"; then
  echo "ERROR: asm contains build-time path: $ASM_PATH"
  exit 1
fi
echo "  asm: clean"

# Check library paths don't contain -L flags with absolute paths
BYTECCLIBS=$(ocamlc.opt -config-var bytecomp_c_libraries)
echo "  bytecomp_c_libraries=${BYTECCLIBS}"
if echo "$BYTECCLIBS" | grep -qE "^-L|[[:space:]]-L"; then
  echo "ERROR: bytecomp_c_libraries contains -L path: $BYTECCLIBS"
  exit 1
fi
echo "  bytecomp_c_libraries: clean"

# compression_c_libraries may not exist in all OCaml versions
ZSTDLIBS=$(ocamlc.opt -config-var compression_c_libraries 2>/dev/null || echo "N/A")
echo "  compression_c_libraries=${ZSTDLIBS}"
if [[ "$ZSTDLIBS" != "N/A" ]] && echo "$ZSTDLIBS" | grep -qE "^-L|[[:space:]]-L"; then
  echo "ERROR: compression_c_libraries contains -L path: $ZSTDLIBS"
  exit 1
fi
echo "  compression_c_libraries: clean (or not present in this version)"

echo "=== OCAML config tests passed ==="
