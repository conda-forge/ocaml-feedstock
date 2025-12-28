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

echo -n "  ocamldoc: " && ocamldoc -version | grep -q "${VERSION}" && echo "OK"
echo -n "  ocamldoc.opt: " && ocamldoc.opt -version | grep -q "${VERSION}" && echo "OK"
echo -n "  ocamldebug: " && ocamldebug -version | grep -q "${VERSION}" && echo "OK"

echo "=== All native-only tool tests passed ==="
