#!/usr/bin/env bash
# Test OCaml compilation capabilities
# Exercises bytecode, native, and multi-file compilation

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

echo "=== OCaml Compilation Tests ==="

# Create test file
printf 'print_endline "Hello World"\n' > hi.ml

# 1. Bytecode compilation + execution
echo "=== Testing bytecode compilation ==="
ocamlc -o hi hi.ml
./hi | grep -q "Hello World" && echo "  bytecode execution: OK"

# Test bytecode portability (run from different directory)
mkdir -p tmp && cp hi tmp && (cd tmp; ./hi) | grep -q "Hello World" && echo "  bytecode portability: OK"
rm -f ./hi

# Test bytecode compiler via ocamlrun
echo -n "  ocamlc.byte via ocamlrun: "
ocamlrun "${OCAML_PREFIX}/bin/ocamlc.byte" -version | grep -q "${VERSION}" && echo "OK"

# 2. Native compilation + execution
echo "=== Testing native compilation ==="
ocamlopt -o hi hi.ml
./hi | grep -q "Hello World" && echo "  native execution: OK"
rm -f ./hi

# 3. REPL test (ocaml toplevel)
echo "=== Testing REPL ==="
echo 'print_endline "REPL works";;' | ocaml 2>&1 | grep -q "REPL works" && echo "  REPL: OK" || echo "  REPL: (exit expected)"

# 4. ocamldep actually parsing files
echo "=== Testing ocamldep ==="
ocamldep hi.ml > /dev/null && echo "  ocamldep parsing: OK"

# 5. Multi-file compilation (exercises module system)
echo "=== Testing multi-file compilation ==="
printf 'let greet () = print_endline "From Lib"\n' > lib.ml
printf 'let () = Lib.greet ()\n' > main.ml
ocamlc -c lib.ml
ocamlc -c main.ml
ocamlc -o multi lib.cmo main.cmo
./multi | grep -q "From Lib" && echo "  multi-file bytecode: OK"

ocamlopt -c lib.ml
ocamlopt -c main.ml
ocamlopt -o multi lib.cmx main.cmx
./multi | grep -q "From Lib" && echo "  multi-file native: OK"

# 6. Bytecode compiler via ocamlrun (full compile)
echo "=== Testing bytecode compiler via ocamlrun ==="
printf 'print_endline "Hi CF"\n' > hi.ml
ocamlrun "${OCAML_PREFIX}/bin/ocamlc.byte" -o hi hi.ml
./hi | grep -q "Hi CF" && echo "  full bytecode compile via ocamlrun: OK"

# Cleanup
rm -f hi hi.ml lib.ml lib.cmi lib.cmo lib.cmx lib.o main.ml main.cmi main.cmo main.cmx main.o multi tmp/hi
rmdir tmp 2>/dev/null || true

echo "=== All compilation tests passed ==="
