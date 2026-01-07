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

# Check binary doesn't contain build-time paths
echo "Checking ocamlc.opt binary for build-time paths..."
if strings "${PREFIX}/bin/ocamlc.opt" | grep -q "rattler-build_"; then
  echo "ERROR: ocamlc.opt contains build-time paths"
  strings "${PREFIX}/bin/ocamlc.opt" | grep "rattler-build_" | head -5
  exit 1
fi
echo "  ocamlc.opt binary: clean"

echo "=== All environment/path tests passed ==="
