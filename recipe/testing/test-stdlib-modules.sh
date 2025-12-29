#!/usr/bin/env bash
# Test OCaml 5.x stdlib modules and multicore features
# Exercises Domains (multicore), Unix, Str, and threads

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

echo "=== OCaml 5.x Stdlib Module Tests ==="

# 1. Test Domains (multicore) - OCaml 5.x feature
echo "=== Testing Domains (multicore) ==="
cat > test_domains.ml << 'EOF'
let () =
  let d = Domain.spawn (fun () ->
    print_endline "Hello from spawned domain"
  ) in
  Domain.join d;
  print_endline "Domain test passed"
EOF

echo -n "  bytecode: "
if ocamlc -o test_domains test_domains.ml 2>/dev/null && ./test_domains | grep -q "Domain test passed"; then
  echo "OK"
else
  echo "FAILED"
  exit 1
fi

echo -n "  native: "
if ocamlopt -o test_domains test_domains.ml 2>/dev/null && ./test_domains | grep -q "Domain test passed"; then
  echo "OK"
else
  echo "FAILED"
  exit 1
fi
rm -f test_domains test_domains.ml test_domains.cmi test_domains.cmo test_domains.cmx test_domains.o

# 2. Test Unix module
echo "=== Testing Unix module ==="
cat > test_unix.ml << 'EOF'
let () =
  let pid = Unix.getpid () in
  Printf.printf "PID: %d\n" pid;
  print_endline "Unix module test passed"
EOF

echo -n "  bytecode: "
if ocamlc -I +unix unix.cma -o test_unix test_unix.ml 2>/dev/null && ./test_unix | grep -q "Unix module test passed"; then
  echo "OK"
else
  echo "FAILED"
  exit 1
fi

echo -n "  native: "
if ocamlopt -I +unix unix.cmxa -o test_unix test_unix.ml 2>/dev/null && ./test_unix | grep -q "Unix module test passed"; then
  echo "OK"
else
  echo "FAILED"
  exit 1
fi
rm -f test_unix test_unix.ml test_unix.cmi test_unix.cmo test_unix.cmx test_unix.o

# 3. Test Str module (requires str library)
echo "=== Testing Str module ==="
cat > test_str.ml << 'EOF'
let () =
  let re = Str.regexp "hello" in
  let result = Str.string_match re "hello world" 0 in
  if result then
    print_endline "Str module test passed"
  else
    print_endline "Str module test FAILED"
EOF

echo -n "  bytecode: "
if ocamlc -I +str str.cma -o test_str test_str.ml 2>/dev/null && ./test_str | grep -q "Str module test passed"; then
  echo "OK"
else
  echo "FAILED"
  exit 1
fi

echo -n "  native: "
if ocamlopt -I +str str.cmxa -o test_str test_str.ml 2>/dev/null && ./test_str | grep -q "Str module test passed"; then
  echo "OK"
else
  echo "FAILED"
  exit 1
fi
rm -f test_str test_str.ml test_str.cmi test_str.cmo test_str.cmx test_str.o

# NOTE: Threads test moved to separate recipe entry for visibility

# 4. Test dynlink module (native)
echo "=== Testing dynlink module ==="
echo -n "  dynlink available: "
if ocamlobjinfo "${PREFIX}/lib/ocaml/dynlink/dynlink.cmxa" >/dev/null 2>&1; then
  echo "OK"
else
  echo "SKIPPED (dynlink not available)"
fi

echo "=== All stdlib module tests passed ==="
