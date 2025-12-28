#!/usr/bin/env bash
# Test environment variables and resource file paths
# Verifies no build-time paths leaked into installed package

set -euo pipefail

echo "=== Environment and Resource File Tests ==="

# Check OCAMLLIB is set
echo "${OCAMLLIB:-'UNSET'}" | grep -q ocaml && echo "OCAMLLIB set: ${OCAMLLIB}"

# Check resource files contain PREFIX (not build paths)
echo "Checking runtime-launch-info..."
head -2 "${PREFIX}/lib/ocaml/runtime-launch-info" | grep -q "${PREFIX}" && echo "  runtime-launch-info: clean"

echo "Checking ld.conf..."
head -2 "${PREFIX}/lib/ocaml/ld.conf" | grep -q "${PREFIX}" && echo "  ld.conf: clean"

echo "Checking Makefile.config..."
grep -q "${PREFIX}" "${PREFIX}/lib/ocaml/Makefile.config" && echo "  Makefile.config: clean"

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

# Check binary doesn't contain build-time paths
echo "Checking ocamlc.opt binary for build-time paths..."
if strings "${PREFIX}/bin/ocamlc.opt" | grep -q "rattler-build_"; then
  echo "ERROR: ocamlc.opt contains build-time paths"
  strings "${PREFIX}/bin/ocamlc.opt" | grep "rattler-build_" | head -5
  exit 1
fi
echo "  ocamlc.opt binary: clean"

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

echo "=== All environment/path tests passed ==="
