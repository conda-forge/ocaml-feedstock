#!/usr/bin/env bash
# Test OCaml tool versions
# Verifies all tools report correct version

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

echo "=== OCaml Tool Version Tests (expecting ${VERSION}) ==="

# Core tools (always available)
echo "Testing core tools..."
echo -n "  ocamlc: " && ocamlc -version | grep -q "${VERSION}" && echo "OK"
echo -n "  ocamldep: " && ocamldep -version | grep -q "${VERSION}" && echo "OK"
echo -n "  ocamllex: " && ocamllex -version | grep -q "${VERSION}" && echo "OK"
echo -n "  ocamlrun: " && ocamlrun -version | grep -q "${VERSION}" && echo "OK"
echo -n "  ocamlyacc: " && ocamlyacc -version | grep -q "${VERSION}" && echo "OK"

# Interactive tools
echo "Testing interactive tools..."
echo -n "  ocaml: " && ocaml -version | grep -q "${VERSION}" && echo "OK"
echo -n "  ocamlcp: " && ocamlcp -version | grep -q "${VERSION}" && echo "OK"
echo -n "  ocamlmklib: " && ocamlmklib -version | grep -q "${VERSION}" && echo "OK"
echo -n "  ocamlmktop: " && ocamlmktop -version | grep -q "${VERSION}" && echo "OK"
echo -n "  ocamloptp: " && ocamloptp -version | grep -q "${VERSION}" && echo "OK"
echo -n "  ocamlprof: " && ocamlprof -version | grep -q "${VERSION}" && echo "OK"

# Native compiler
echo "Testing native compiler..."
echo -n "  ocamlopt: " && ocamlopt -version | grep -q "${VERSION}" && echo "OK"

# Utility tools (check help instead of version for some)
echo "Testing utility tools..."
echo -n "  ocamlobjinfo: " && ocamlobjinfo -help > /dev/null 2>&1 && echo "OK"
echo -n "  ocamlobjinfo.opt: " && ocamlobjinfo.opt -help > /dev/null 2>&1 && echo "OK"
echo -n "  ocamlcmt: " && ocamlcmt -help > /dev/null 2>&1 && echo "OK"
echo -n "  ocamlobjinfo.byte: " && ocamlobjinfo.byte -help > /dev/null 2>&1 && echo "OK"

echo "=== All version tests passed ==="
