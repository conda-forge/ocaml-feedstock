#!/usr/bin/env bash
# Test OCaml threads module
# Separate from stdlib-modules for cross-compilation visibility

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

echo "=== Testing threads module ==="

# Detect cross-compilation
BUILD_PLATFORM="${build_platform:-}"
TARGET_PLATFORM="${target_platform:-}"
IS_CROSS_COMPILED="false"
if [[ -n "$BUILD_PLATFORM" ]] && [[ -n "$TARGET_PLATFORM" ]] && [[ "$BUILD_PLATFORM" != "$TARGET_PLATFORM" ]]; then
  IS_CROSS_COMPILED="true"
  echo "Cross-compiled build detected: ${BUILD_PLATFORM} -> ${TARGET_PLATFORM}"
fi

cat > test_threads.ml << 'EOF'
let () =
  let t = Thread.create (fun () ->
    print_endline "Hello from thread"
  ) () in
  Thread.join t;
  print_endline "Threads module test passed"
EOF

echo -n "  bytecode: "
# threads.cma depends on unix.cma on Linux
if ocamlc -I +unix unix.cma -I +threads threads.cma -o test_threads test_threads.ml 2>/dev/null && ./test_threads | grep -q "Threads module test passed"; then
  echo "OK"
else
  echo "FAILED"
  exit 1
fi

echo -n "  native: "
# QEMU user-mode emulation can't reliably run threaded native code
if [[ "$IS_CROSS_COMPILED" == "true" ]]; then
  echo "SKIPPED (cross-compiled: QEMU can't run threaded native code)"
elif ocamlopt -I +unix unix.cmxa -I +threads threads.cmxa -o test_threads test_threads.ml 2>/dev/null && ./test_threads | grep -q "Threads module test passed"; then
  echo "OK"
else
  echo "FAILED"
  exit 1
fi

rm -f test_threads test_threads.ml test_threads.cmi test_threads.cmo test_threads.cmx test_threads.o

echo "=== Threads test passed ==="
