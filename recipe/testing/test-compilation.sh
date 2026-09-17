#!/usr/bin/env bash
# Test OCaml compilation capabilities
# Exercises bytecode, native, and multi-file compilation

set -euo pipefail

# Target binaries are foreign-arch on cross builds; run them under qemu when
# the emulator is available, natively otherwise. qemu-user loads ELF images
# only, so a #! file (OCaml bytecode) needs its interpreter resolved here the
# way binfmt_script would, and the interpreter handed to qemu instead.
run_target() {
  if [[ -n "${QEMU_EXECVE:-}" ]]; then
    if [[ -n "${QEMU_LD_PREFIX:-}" && ! -d "${QEMU_LD_PREFIX}" ]]; then
      echo "[WARN] QEMU_LD_PREFIX does not exist: ${QEMU_LD_PREFIX}" >&2
      echo "[WARN] qemu will fall back to /lib and may fail confusingly" >&2
    fi
    # A bare command name is resolved here so both qemu and the #! check below
    # get a real path.
    if [[ -n "${1:-}" && "$1" != */* ]]; then
      local resolved
      resolved=$(type -P -- "$1" || true)
      if [[ -n "$resolved" ]]; then
        shift
        set -- "$resolved" "$@"
      fi
    fi
    if [[ -f "${1:-}" && "$(head -c 2 "${1:-}" 2>/dev/null)" == '#!' ]]; then
      local script="$1"
      shift
      local interp
      interp=$(head -n 1 "$script" | sed -e 's/^#![[:space:]]*//' -e 's/[[:space:]].*//')
      if [[ -z "$interp" ]]; then
        echo "[FAIL] could not parse interpreter from shebang of ${script}" >&2
        return 1
      fi
      # #!/usr/bin/env <prog> is resolved through PATH, as env itself would.
      if [[ "${interp}" == */env ]]; then
        local envprog
        envprog=$(head -n 1 "$script" | sed -e 's/^#![[:space:]]*[^[:space:]]*[[:space:]]*//' -e 's/[[:space:]].*//')
        if [[ -n "${envprog}" ]]; then
          interp=$(type -P -- "${envprog}" || echo "${interp}")
        fi
      fi
      if [[ "${interp}" != "${PREFIX:-/nonexistent}/"* ]]; then
        # A native interpreter cannot start target binaries. OCaml's sh
        # launcher header only re-execs this file under the ocamlrun next to
        # it, so that step is done here under the emulator instead.
        local line2
        line2=$(sed -n '2p' "$script")
        if [[ "${line2}" == exec*ocamlrun* ]]; then
          echo "[qemu] sh launcher ${script} -> $(dirname "$script")/ocamlrun" >&2
          "${QEMU_EXECVE}" "$(dirname "$script")/ocamlrun" "$script" "$@"
          return
        fi
        echo "[FAIL] ${script}: native interpreter ${interp} cannot run target binaries under emulation" >&2
        return 126
      fi
      echo "[qemu] shebang ${script} -> ${interp}" >&2
      "${QEMU_EXECVE}" "$interp" "$script" "$@"
      return
    fi
    "${QEMU_EXECVE}" "$@"
  else
    "$@"
  fi
}

# Under qemu the conda-ocaml-* wrappers are native scripts, which cannot exec
# a ppc64le tool themselves. They word-split CONDA_OCAML_* unquoted, so the
# emulator is put in front of each target tool. grep and file are ppc64le
# test requirements too, so they are routed through run_target. Call this
# again after re-sourcing an activation script, which can reset the variables.
qemu_wrap_toolchain() {
  [[ -n "${QEMU_EXECVE:-}" ]] || return 0
  local _v _name _val _tool _rest _path _t _p
  for _v in CC AS LD AR RANLIB MKEXE MKDLL; do
    _name=CONDA_OCAML_${_v}
    _val=${!_name:-}
    [[ -n "${_val}" && "${_val}" != "${QEMU_EXECVE} "* ]] || continue
    _tool=${_val%% *}
    _rest=
    [[ "${_val}" == *" "* ]] && _rest=" ${_val#* }"
    _path=$(type -P -- "${_tool}" || true)
    if [[ -z "${_path}" ]]; then
      echo "[WARN] ${_name}: ${_tool} not found on PATH, left unprefixed" >&2
      continue
    fi
    # Only target tools under $PREFIX need the emulator; a native script such
    # as a test's logging wrapper is left as it is.
    [[ "${_path}" == "${PREFIX:-/nonexistent}/"* ]] || continue
    export "${_name}=${QEMU_EXECVE} ${_path}${_rest}"
  done
  for _t in grep file; do
    _p=$(type -P -- "${_t}" || true)
    if [[ -n "${_p}" && "${_p}" == "${PREFIX:-/nonexistent}/"* ]]; then
      eval "${_t}() { run_target \"${_p}\" \"\$@\"; }"
    fi
  done
}
qemu_wrap_toolchain

# Run a command, capture its output, and require that output to contain a
# pattern. Capturing first stops grep -q from SIGPIPE-ing a live producer
# under pipefail, which is what made the REPL check fail while the string
# it wanted was in fact printed.
assert_contains() {
  local label="$1" pattern="$2"
  shift 2
  local rc=0 out
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "$pattern"; then
    echo "  ${label}: OK"
    return 0
  fi
  echo "  [FAIL] ${label}"
  echo "  command: $*"
  echo "  exit status: $rc"
  echo "  expected output to contain: ${pattern}"
  echo "  ----- output start -----"
  printf '%s\n' "$out"
  echo "  ----- output end -----"
  exit 1
}

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
run_target ocamlc -o hi hi.ml

# Verify direct bytecode execution (shebang must work)
if ! run_target ./hi | grep -q "Hello World"; then
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
mkdir -p tmp
cp hi tmp
export -f run_target
assert_contains "bytecode portability" "Hello World" bash -c 'cd tmp && run_target ./hi'
rm -f ./hi

# Test bytecode compiler via ocamlrun
assert_contains "ocamlc.byte via ocamlrun" "${VERSION}" run_target ocamlrun "${OCAML_PREFIX}/bin/ocamlc.byte" -version

# 2. Native compilation + execution
echo "=== Testing native compilation ==="
run_target ocamlopt -o hi hi.ml
assert_contains "native execution" "Hello World" run_target ./hi
rm -f ./hi

# 3. REPL test (ocaml toplevel)
echo "=== Testing REPL ==="
repl_rc=0
repl_out="$(echo 'print_endline "REPL works";;' | run_target ocaml 2>&1)" || repl_rc=$?
if [ "$repl_rc" -eq 0 ] && printf '%s' "$repl_out" | grep -q "REPL works"; then
  echo "  REPL: OK"
else
  echo "  [FAIL] REPL did not print expected output"
  echo "  ocaml exit status: $repl_rc"
  echo "  ocaml binary path: $(command -v ocaml || true)"
  echo "  ----- REPL output start -----"
  printf '%s\n' "$repl_out"
  echo "  ----- REPL output end -----"
  exit 1
fi

# 4. ocamldep actually parsing files
echo "=== Testing ocamldep ==="
run_target ocamldep hi.ml > /dev/null
echo "  ocamldep parsing: OK"

# 5. Multi-file compilation (exercises module system)
echo "=== Testing multi-file compilation ==="
printf 'let greet () = print_endline "From Lib"\n' > lib.ml
printf 'let () = Lib.greet ()\n' > main.ml
run_target ocamlc -c lib.ml
run_target ocamlc -c main.ml
run_target ocamlc -o multi lib.cmo main.cmo
assert_contains "multi-file bytecode" "From Lib" run_target ./multi

run_target ocamlopt -c lib.ml
run_target ocamlopt -c main.ml
run_target ocamlopt -o multi lib.cmx main.cmx
assert_contains "multi-file native" "From Lib" run_target ./multi

# 6. Bytecode compiler via ocamlrun (full compile)
echo "=== Testing bytecode compiler via ocamlrun ==="
printf 'print_endline "Hi CF"\n' > hi.ml
run_target ocamlrun "${OCAML_PREFIX}/bin/ocamlc.byte" -o hi hi.ml
assert_contains "full bytecode compile via ocamlrun" "Hi CF" run_target ./hi

# 7. Complete executable test (used by Dune bootstrap)
# This exercises: ocamlc -output-complete-exe -I +unix unix.cma ...
echo "=== Testing -output-complete-exe (Dune bootstrap pattern) ==="

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
run_target ocamlc -output-complete-exe -g -o complete_test.exe -I +unix unix.cma complete_exe_test.ml

# Verify it's a real executable (not bytecode that needs ocamlrun)
echo -n "  verifying executable type: "
if file complete_test.exe | grep -qE "(ELF|Mach-O|PE32)"; then
  echo "OK (native executable)"
else
  echo "FAIL: unexpected file type"
  exit 1
fi

# Run it
assert_contains "executing" "complete-exe works" run_target ./complete_test.exe

# Verify it works without ocamlrun in PATH (truly standalone)
if [[ -n "${QEMU_EXECVE:-}" ]]; then
  assert_contains "standalone execution (no ocamlrun)" "complete-exe works" \
    env -u OCAMLLIB PATH=/usr/bin:/bin "${QEMU_EXECVE}" ./complete_test.exe
else
  assert_contains "standalone execution (no ocamlrun)" "complete-exe works" \
    env -u OCAMLLIB PATH=/usr/bin:/bin ./complete_test.exe
fi

rm -f complete_exe_test.ml complete_test.exe

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
if run_target ocamlc -custom -g -o custom_test -I +unix unix.cma custom_test.ml 2>custom_link_err.txt; then
  echo " OK"
  echo -n "  executing: "
  run_target ./custom_test | grep -q "custom-link works" && echo "OK" || { echo "FAIL"; exit 1; }
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

echo -n "  creating shared library with ocamlmklib..."
if run_target ocamlmklib -o stub_test stub_test.o 2>mklib_err.txt; then
  echo " OK"
  # Verify files were created
  if ! ls dllstub_test.so libstub_test.a >/dev/null 2>&1; then
    echo "  [FAIL] ocamlmklib did not produce both dllstub_test.so and libstub_test.a"
    ls -l
    exit 1
  fi
  echo "  shared+static libs created: OK"
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
