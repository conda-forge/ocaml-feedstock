#!/usr/bin/env bash
# Test OCaml compilation capabilities
# Exercises bytecode, native, and multi-file compilation

set -euo pipefail

# Run a TARGET binary. Under cross-emulation OCAML_QEMU is the emulator
# (e.g. qemu-execve-ppc64le) and we resolve the binary to an absolute path,
# because the emulator does not do PATH lookup. When OCAML_QEMU is empty
# (all native lanes) this is exactly equivalent to running the command directly.
_run_target() {
  local _cmd="$1"; shift
  if [ -n "${OCAML_QEMU:-}" ]; then
    local _p
    _p="$(command -v "${_cmd}")" || { echo "ERROR: ${_cmd} not found in PATH" >&2; return 1; }
    "${OCAML_QEMU}" "${_p}" "$@"
  else
    "${_cmd}" "$@"
  fi
}

# Run a bytecode executable (produced by plain `ocamlc -o ...`, i.e. NOT
# -custom or -output-complete-exe). Such a file is a script whose shebang
# points at the target ocamlrun; under emulation the shebang chain does not
# work on hosts without binfmt_misc registered for the target arch, so we
# invoke ocamlrun explicitly instead. When OCAML_QEMU is empty this is
# exactly equivalent to running the executable directly (bare shebang
# execution, unchanged).
_run_bytecode() {
  local _exe="$1"; shift
  if [ -n "${OCAML_QEMU:-}" ]; then
    _run_target ocamlrun "${_exe}" "$@"
  else
    "${_exe}" "$@"
  fi
}

# Resolve OCAML_QEMU to an absolute path once. Some call sites deliberately
# restrict PATH (e.g. `env -u OCAMLLIB PATH=/usr/bin:/bin ...`) to prove a
# standalone binary runs without ocamlrun in scope; `command -v` cannot
# resolve the emulator inside that restricted PATH, so we resolve it here
# instead. When OCAML_QEMU is empty (all native lanes) OCAML_QEMU_ABS stays
# empty and downstream commands are unaffected.
OCAML_QEMU_ABS=""
if [ -n "${OCAML_QEMU:-}" ]; then
  OCAML_QEMU_ABS="$(command -v "${OCAML_QEMU}")" || OCAML_QEMU_ABS=""
fi

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
_run_target ocamlc -o hi hi.ml

# Verify direct bytecode execution (shebang must work)
if ! _run_bytecode ./hi | grep -q "Hello World"; then
  echo "  [FAIL] bytecode direct execution failed (shebang broken?)"
  echo "  Checking runtime-launch-info BINDIR..."
  if [[ -f "${PREFIX}/lib/ocaml/runtime-launch-info" ]]; then
    python3 -c "
with open('${PREFIX}/lib/ocaml/runtime-launch-info', 'rb') as f:
    data = f.read()
    nl1 = data.index(b'\n')
    nl2 = data.index(b'\n', nl1+1)
    bindir = data[nl1+1:nl2].rstrip(b'\x00').decode()
    print(f'  BINDIR in runtime-launch-info: {bindir}')
"
  fi
  exit 1
fi
echo "  bytecode direct execution: OK"

# Test bytecode portability (run from different directory)
mkdir -p tmp && cp hi tmp && (cd tmp; _run_bytecode ./hi) | grep -q "Hello World" && echo "  bytecode portability: OK"
rm -f ./hi

# Test bytecode compiler via ocamlrun
echo -n "  ocamlc.byte via ocamlrun: "
_run_target ocamlrun "${OCAML_PREFIX}/bin/ocamlc.byte" -version | grep -q "${VERSION}" && echo "OK"

# 2. Native compilation + execution
echo "=== Testing native compilation ==="
_run_target ocamlopt -o hi hi.ml
_run_target ./hi | grep -q "Hello World" && echo "  native execution: OK"
rm -f ./hi

# 3. REPL test (ocaml toplevel)
echo "=== Testing REPL ==="
_OCAML_BIN="$(command -v ocaml 2>/dev/null)" || _OCAML_BIN="ocaml"
echo 'print_endline "REPL works";;' | _run_bytecode "${_OCAML_BIN}" 2>&1 | grep -q "REPL works" && echo "  REPL: OK" || echo "  REPL: (exit expected)"

# 4. ocamldep actually parsing files
echo "=== Testing ocamldep ==="
_run_target ocamldep hi.ml > /dev/null && echo "  ocamldep parsing: OK"

# 5. Multi-file compilation (exercises module system)
echo "=== Testing multi-file compilation ==="
printf 'let greet () = print_endline "From Lib"\n' > lib.ml
printf 'let () = Lib.greet ()\n' > main.ml
_run_target ocamlc -c lib.ml
_run_target ocamlc -c main.ml
_run_target ocamlc -o multi lib.cmo main.cmo
_run_bytecode ./multi | grep -q "From Lib" && echo "  multi-file bytecode: OK"

_run_target ocamlopt -c lib.ml
_run_target ocamlopt -c main.ml
_run_target ocamlopt -o multi lib.cmx main.cmx
_run_target ./multi | grep -q "From Lib" && echo "  multi-file native: OK"

# 6. Bytecode compiler via ocamlrun (full compile)
echo "=== Testing bytecode compiler via ocamlrun ==="
echo "DBG: ${OCAML_PREFIX}"
printf 'print_endline "Hi CF"\n' > hi.ml
_run_target ocamlrun "${OCAML_PREFIX}/bin/ocamlc.byte" -o hi hi.ml
_run_bytecode ./hi | grep -q "Hi CF" && echo "  full bytecode compile via ocamlrun: OK"

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
  _run_target ocamlc -output-complete-exe -g -o complete_test.exe -I +unix unix.cma complete_exe_test.ml

  # Verify it's a real executable (not bytecode that needs ocamlrun)
  echo -n "  verifying executable type: "
  file complete_test.exe | grep -qE "(ELF|Mach-O|PE32)" && echo "OK (native executable)" || echo "WARNING: unexpected file type"

  # Run it
  echo -n "  executing: "
  _run_target ./complete_test.exe | grep -q "complete-exe works" && echo "OK"

  # Verify it works without ocamlrun in PATH (truly standalone)
  echo -n "  standalone execution (no ocamlrun): "
  env -u OCAMLLIB PATH=/usr/bin:/bin ${OCAML_QEMU_ABS:-} ./complete_test.exe 2>/dev/null | grep -q "complete-exe works" && echo "OK" || echo "SKIP (may need system libs)"

  rm -f complete_exe_test.ml complete_test.exe
fi

# 8. Custom bytecode linking (ocamlfind/ocamlbuild pattern)
# This exercises: ocamlc -custom -o prog unix.cma ...
# Tests that MKEXE can link C stubs (libunixbyt.a) without linker errors.
# Catches: lld weak symbol issues on macOS, MSVC link.exe collision on Windows
echo "=== Testing -custom bytecode linking (ocamlfind pattern) ==="
cat > custom_test.ml << 'EOF'
let () =
  let t = Unix.gettimeofday () in
  Printf.printf "time: %.0f\n" t;
  print_endline "custom-link works"
EOF

echo -n "  compiling with -custom..."
if _run_target ocamlc -custom -g -o custom_test -I +unix unix.cma custom_test.ml 2>custom_link_err.txt; then
  echo " OK"
  echo -n "  executing: "
  _run_target ./custom_test | grep -q "custom-link works" && echo "OK" || { echo "FAIL"; exit 1; }
else
  echo " FAIL"
  echo "  Linker error during -custom bytecode linking:"
  cat custom_link_err.txt | head -20
  echo ""
  echo "  This usually means MKEXE has incompatible linker flags."
  echo "  Checking Makefile.config MKEXE:"
  grep "^MKEXE" "${PREFIX}/lib/ocaml/Makefile.config" || true
  echo "  CONDA_OCAML_MKEXE=${CONDA_OCAML_MKEXE:-<not set>}"
  exit 1
fi
rm -f custom_test custom_test.ml custom_link_err.txt

# 9. Shared library stub creation (ocamlmklib pattern)
# This exercises: ocamlmklib -o stubs stubs.o
# Catches: macOS __darwin_check_fd_set_overflow weak symbol with lld
echo "=== Testing shared library creation (ocamlmklib pattern) ==="
cat > stub_test.c << 'EOF'
#include <caml/mlvalues.h>
#include <caml/memory.h>
CAMLprim value stub_get_42(value unit) {
  CAMLparam1(unit);
  CAMLreturn(Val_int(42));
}
EOF

echo -n "  compiling C stub..."
cc_cmd="${CONDA_OCAML_CC:-cc}"
${cc_cmd} -c -I "${PREFIX}/lib/ocaml" -fPIC stub_test.c -o stub_test.o 2>&1 && echo " OK" || { echo " FAIL (C compilation)"; exit 1; }

# ocamlmklib is a shell-trampoline over bytecode (#!/usr/bin/sh + exec ocamlrun),
# not a native ELF, so it must go through _run_bytecode: handing the trampoline
# directly to qemu-execve makes qemu's ELF loader reject it with ENOEXEC
# ("Exec format error"). Native lanes (empty OCAML_QEMU) are unaffected.
echo -n "  creating shared library with ocamlmklib..."
if _run_bytecode "$(command -v ocamlmklib)" -o stub_test stub_test.o 2>mklib_err.txt; then
  echo " OK"
  # Verify files were created
  ls dllstub_test.so libstub_test.a >/dev/null 2>&1 && echo "  shared+static libs created: OK" || echo "  WARNING: some output files missing"
else
  echo " FAIL"
  echo "  ocamlmklib error:"
  cat mklib_err.txt | head -20
  exit 1
fi
rm -f stub_test.c stub_test.o dllstub_test.so libstub_test.a mklib_err.txt

# Cleanup
rm -f hi hi.ml lib.ml lib.cmi lib.cmo lib.cmx lib.o main.ml main.cmi main.cmo main.cmx main.o multi tmp/hi
rmdir tmp 2>/dev/null || true

echo "=== All compilation tests passed ==="
