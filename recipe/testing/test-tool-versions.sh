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

# Print FAIL with the observed output and exit 1 unless -version matches
check_version() {
  local tool="$1" out
  echo -n "  ${tool}: "
  out=$("${tool}" -version 2>&1) || true
  if printf '%s\n' "${out}" | grep -q "${VERSION}"; then
    echo "OK"
  else
    echo "FAIL (found: ${out:-<no output>})"
    exit 1
  fi
}

# Print FAIL and exit 1 unless -help succeeds
check_help() {
  local tool="$1"
  echo -n "  ${tool}: "
  if "${tool}" -help > /dev/null 2>&1; then
    echo "OK"
  else
    echo "FAIL (-help exited non-zero)"
    exit 1
  fi
}

# Core tools (always available)
echo "Testing core tools..."
check_version ocamlc
check_version ocamldep
check_version ocamllex
check_version ocamlrun
check_version ocamlyacc

# Interactive tools
echo "Testing interactive tools..."
check_version ocaml
check_version ocamlcp
check_version ocamlmklib
check_version ocamlmktop
check_version ocamloptp
check_version ocamlprof

# Native compiler
echo "Testing native compiler..."
check_version ocamlopt

# Utility tools (check help instead of version for some)
echo "Testing utility tools..."
check_help ocamlobjinfo
check_help ocamlobjinfo.opt
check_help ocamlcmt
check_help ocamlobjinfo.byte

echo "=== All version tests passed ==="
