#!/usr/bin/env bash
# Test cross-compiler CRC consistency
# Verifies unix.cmxa and threads.cmxa have compatible Implementation CRCs

set -euo pipefail

CROSS_COMPILER="${1:-aarch64-conda-linux-gnu-ocamlopt}"

echo "Testing cross-compiler consistency: ${CROSS_COMPILER}"

# Test 1: stdlib + unix (basic consistency)
cat > /tmp/test_consistency.ml << 'EOF'
let () =
  Printf.printf "OCaml version: %s\n" Sys.ocaml_version;
  let stats = Unix.stat "." in
  Printf.printf "inode: %d\n" stats.Unix.st_ino
EOF

echo "  Test 1: stdlib + unix.cmxa..."
if ${CROSS_COMPILER} -I +unix -o /tmp/test_consistency.exe unix.cmxa /tmp/test_consistency.ml 2>&1; then
  echo "    ✓ Passed"
else
  echo "    ✗ FAILED: stdlib.cmxa and unix.cmxa are incompatible"
  rm -f /tmp/test_consistency.ml /tmp/test_consistency.exe
  exit 1
fi

# Test 2: unix + threads (the bug we fixed - Implementation CRC mismatch)
cat > /tmp/test_threads.ml << 'EOF'
let () =
  let _ = Thread.create (fun () -> Unix.sleep 0) () in
  print_endline "threads test"
EOF

echo "  Test 2: unix.cmxa + threads.cmxa..."
if ${CROSS_COMPILER} -I +unix -I +threads -o /tmp/test_threads.exe unix.cmxa threads.cmxa /tmp/test_threads.ml 2>&1; then
  echo "    ✓ Passed"
else
  echo "    ✗ FAILED: unix.cmxa + threads.cmxa compilation failed (likely CRC mismatch or missing modules)"
  rm -f /tmp/test_consistency.ml /tmp/test_consistency.exe /tmp/test_threads.ml /tmp/test_threads.exe
  exit 1
fi

rm -f /tmp/test_consistency.ml /tmp/test_consistency.exe /tmp/test_threads.ml /tmp/test_threads.exe
echo "  ✓ Cross-compiler is consistent"
exit 0
