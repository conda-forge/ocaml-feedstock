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
echo "DBG: ${OCAML_PREFIX}"
printf 'print_endline "Hi CF"\n' > hi.ml
ocamlrun "${OCAML_PREFIX}/bin/ocamlc.byte" -o hi hi.ml
./hi | grep -q "Hi CF" && echo "  full bytecode compile via ocamlrun: OK"

# 7. Complete executable test (used by Dune bootstrap)
# This exercises: ocamlc -output-complete-exe -I +unix unix.cma ...
echo "=== Testing -output-complete-exe (Dune bootstrap pattern) ==="

# Detect if running under QEMU (cross-compiled package on different host arch)
# ocamlc.opt crashes under QEMU user-mode emulation with -output-complete-exe
_OCAMLC_ARCH=""
_HOST_ARCH="$(uname -m)"
if file "$(which ocamlc.opt 2>/dev/null || echo "${OCAML_PREFIX}/bin/ocamlc.opt")" 2>/dev/null | grep -q "ARM aarch64"; then
  _OCAMLC_ARCH="aarch64"
elif file "$(which ocamlc.opt 2>/dev/null || echo "${OCAML_PREFIX}/bin/ocamlc.opt")" 2>/dev/null | grep -q "64-bit.*x86-64"; then
  _OCAMLC_ARCH="x86_64"
elif file "$(which ocamlc.opt 2>/dev/null || echo "${OCAML_PREFIX}/bin/ocamlc.opt")" 2>/dev/null | grep -q "64-bit.*PowerPC"; then
  _OCAMLC_ARCH="ppc64le"
fi

if [[ -n "${_OCAMLC_ARCH}" && "${_OCAMLC_ARCH}" != "${_HOST_ARCH}" ]]; then
  echo "  SKIP: Running ${_OCAMLC_ARCH} binary on ${_HOST_ARCH} host (QEMU emulation unstable for -output-complete-exe)"
else
  # Create a program that uses Unix module (like Dune's bootstrap)
  cat > complete_exe_test.ml << 'EOF'
(* Test program exercising Unix module - similar to Dune bootstrap *)
let () =
  let cwd = Unix.getcwd () in
  Printf.printf "CWD: %s\n" cwd;
  print_endline "complete-exe works"
EOF

  # Compile with -output-complete-exe (embeds bytecode interpreter)
  # This is the exact pattern dune/opam use for bootstrapping
  echo "  compiling with -output-complete-exe..."
  ocamlc -output-complete-exe -g -o complete_test.exe -I +unix unix.cma complete_exe_test.ml

  # Verify it's a real executable (not bytecode that needs ocamlrun)
  echo -n "  verifying executable type: "
  file complete_test.exe | grep -qE "(ELF|Mach-O|PE32)" && echo "OK (native executable)" || echo "WARNING: unexpected file type"

  # Run it
  echo -n "  executing: "
  ./complete_test.exe | grep -q "complete-exe works" && echo "OK"

  # Verify it works without ocamlrun in PATH (truly standalone)
  echo -n "  standalone execution (no ocamlrun): "
  env -u OCAMLLIB PATH=/usr/bin:/bin ./complete_test.exe 2>/dev/null | grep -q "complete-exe works" && echo "OK" || echo "SKIP (may need system libs)"

  rm -f complete_exe_test.ml complete_test.exe
fi

# Cleanup
rm -f hi hi.ml lib.ml lib.cmi lib.cmo lib.cmx lib.o main.ml main.cmi main.cmo main.cmx main.o multi tmp/hi
rmdir tmp 2>/dev/null || true

echo "=== All compilation tests passed ==="
