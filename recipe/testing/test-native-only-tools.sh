#!/usr/bin/env bash
# Test tools only available on native builds (not cross-compiled)
# ocamldoc, ocamldebug are not built during cross-compilation

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

echo "=== Native-only Tool Tests (expecting ${VERSION}) ==="

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

check_version ocamldoc
check_version ocamldoc.opt
check_version ocamldebug

echo "=== All native-only tool tests passed ==="
