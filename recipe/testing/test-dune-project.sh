#!/bin/bash
# Test dune project build for ocaml-devel metapackage
# Verifies that the full development toolchain works together
set -euo pipefail

echo "=== Test: Dune Project Build ==="
echo

# Create temporary project directory
TESTDIR=$(mktemp -d)
trap "rm -rf $TESTDIR" EXIT

cd "$TESTDIR"

# Create a minimal dune project
echo "Creating test dune project..."

cat > dune-project << 'EOF'
(lang dune 3.0)
(name hello_dune)
EOF

cat > dune << 'EOF'
(executable
 (name hello)
 (public_name hello_dune))
EOF

cat > hello.ml << 'EOF'
let () =
  print_endline "Hello from dune-built OCaml!";
  Printf.printf "OCaml version: %s\n" Sys.ocaml_version
EOF

echo "Project structure:"
ls -la

echo
echo "Building with dune..."
dune build

echo
echo "Running built executable..."
dune exec ./hello.exe

echo
echo "Testing dune clean..."
dune clean

echo
echo "=== Dune project build test PASSED ==="
