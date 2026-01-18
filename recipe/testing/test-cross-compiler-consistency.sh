#!/usr/bin/env bash
# Test environment variables and resource file paths
# Verifies no build-time paths leaked into installed package

set -euo pipefail

CROSS_COMPILER="${1:-aarch64-conda-linux-gnu-ocamlopt}"

echo "Testing cross-compiler consistency: ${CROSS_COMPILER}"

# Create a simple test program that uses both stdlib and unix
cat > /tmp/test_consistency.ml << 'EOF'
(* This program uses both stdlib (Sys module) and unix library *)
let () =
  (* Use Stdlib__Sys via Sys module *)
  Printf.printf "OCaml version: %s\n" Sys.ocaml_version;
  Printf.printf "Architecture: %s\n" Sys.os_type;

  (* Use Unix module - this forces linking unix.cmxa with stdlib.cmxa *)
  let stats = Unix.stat "." in
  Printf.printf "Current directory inode: %d\n" stats.Unix.st_ino;

  print_endline "Cross-compiler consistency test PASSED"
EOF

# Try to compile with the cross-compiler
# This will fail with "inconsistent assumptions" if stdlib and unix are incompatible
echo "Compiling test program..."
if ${CROSS_COMPILER} -o /tmp/test_consistency.exe unix.cmxa /tmp/test_consistency.ml; then
  echo "✓ Compilation succeeded - no inconsistent assumptions"
  echo "✓ Cross-compiler is consistent"
  rm -f /tmp/test_consistency.ml /tmp/test_consistency.exe
  exit 0
else
  echo "✗ Compilation FAILED - cross-compiler has inconsistent assumptions"
  echo "✗ stdlib.cmxa and unix.cmxa are incompatible"
  rm -f /tmp/test_consistency.ml
  exit 1
fi
