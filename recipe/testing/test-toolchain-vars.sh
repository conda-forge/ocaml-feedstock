#!/bin/bash
# Test that CONDA_OCAML_* toolchain variables work correctly
# This test verifies that ocamlopt respects custom CC/AS/AR settings
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
    if [[ -f "${1:-}" && "$(head -c 2 "${1:-}" 2>/dev/null)" == '#!' ]]; then
      local script="$1"
      shift
      local interp
      interp=$(head -n 1 "$script" | sed -e 's/^#![[:space:]]*//' -e 's/[[:space:]].*//')
      if [[ -z "$interp" ]]; then
        echo "[FAIL] could not parse interpreter from shebang of ${script}" >&2
        return 1
      fi
      "${QEMU_EXECVE}" "$interp" "$script" "$@"
      return
    fi
    "${QEMU_EXECVE}" "$@"
  else
    "$@"
  fi
}

echo "=== Test: CONDA_OCAML_* Toolchain Variables ==="

ERRORS=0

# Test 1: Verify activation script sets defaults
echo ""
echo "Test 1: Activation script sets default CONDA_OCAML_* values"

# Source activation script (may already be sourced)
if [[ -f "${CONDA_PREFIX}/etc/conda/activate.d/ocaml_activate.sh" ]]; then
    source "${CONDA_PREFIX}/etc/conda/activate.d/ocaml_activate.sh"
fi

# Check that variables are set
for var in CONDA_OCAML_CC CONDA_OCAML_AS CONDA_OCAML_AR CONDA_OCAML_MKDLL; do
    if [[ -z "${!var:-}" ]]; then
        echo "FAIL: $var is not set after activation"
        exit 1
    fi
    echo "  $var = ${!var}"
done
echo "PASS: All CONDA_OCAML_* variables are set"

# Test 2: Verify ocamlopt -config shows wrapper script references
echo ""
echo "Test 2: ocamlopt -config uses conda-ocaml-* wrapper scripts"

CONFIG_CC=$(ocamlopt -config-var c_compiler)
CONFIG_ASM=$(ocamlopt -config-var asm)

echo "  c_compiler = $CONFIG_CC"
echo "  asm = $CONFIG_ASM"

# Config should reference conda-ocaml-* wrapper scripts (for Unix.create_process compatibility)
if [[ "$CONFIG_CC" == "conda-ocaml-cc" ]]; then
    echo "PASS: c_compiler uses conda-ocaml-cc wrapper"
else
    echo "FAIL: c_compiler expected 'conda-ocaml-cc', got: $CONFIG_CC"
    ERRORS=$((ERRORS + 1))
fi

# Test 2b: Verify wrapper scripts exist and are executable
echo ""
echo "Test 2b: Verify wrapper scripts are installed"
for wrapper in conda-ocaml-cc conda-ocaml-as conda-ocaml-ar conda-ocaml-ranlib conda-ocaml-mkexe conda-ocaml-mkdll; do
    if [[ -x "${CONDA_PREFIX}/bin/${wrapper}" ]]; then
        echo "  $wrapper: OK"
    else
        echo "  $wrapper: MISSING"
        ERRORS=$((ERRORS + 1))
    fi
done

# Test 3: Custom CC is respected in compilation
echo ""
echo "Test 3: Custom CONDA_OCAML_CC is used during compilation"

TESTDIR=$(mktemp -d)
trap "rm -rf '$TESTDIR'" EXIT

cat > "$TESTDIR/hello.ml" << 'EOF'
let () = print_endline "Hello from OCaml"
EOF

# ocamlopt only reaches Config.c_compiler when there is C to compile; a
# stub-free .ml is handled by asm and mkexe alone. This gives the custom
# CC something to do so the check below can assert.
cat > "$TESTDIR/stub.c" << 'EOF'
int conda_ocaml_cc_probe(void) { return 0; }
EOF

# Create a wrapper script that logs its invocation
REAL_CC="${CONDA_OCAML_CC}"
cat > "$TESTDIR/cc-wrapper" << EOF
#!/bin/bash
echo "CC_WRAPPER_CALLED" >> "$TESTDIR/cc.log"
exec $REAL_CC "\$@"
EOF
chmod +x "$TESTDIR/cc-wrapper"

# Set custom CC and reactivate
export CONDA_OCAML_CC="$TESTDIR/cc-wrapper"
if [[ -f "${CONDA_PREFIX}/etc/conda/activate.d/ocaml_activate.sh" ]]; then
    source "${CONDA_PREFIX}/etc/conda/activate.d/ocaml_activate.sh"
fi

# Clear log and compile
> "$TESTDIR/cc.log"
cd "$TESTDIR"

if ocamlopt -o hello stub.c hello.ml 2>&1; then
    echo "  Compilation succeeded"

    # Check if wrapper was called
    if [[ -f "$TESTDIR/cc.log" ]] && grep -q "CC_WRAPPER_CALLED" "$TESTDIR/cc.log"; then
        echo "PASS: Custom CONDA_OCAML_CC wrapper was invoked"
    else
        echo "FAIL: custom CONDA_OCAML_CC was not invoked while compiling stub.c"
        echo "  CONDA_OCAML_CC = ${CONDA_OCAML_CC:-<not set>}"
        echo "  c_compiler     = $CONFIG_CC"
        if [[ -f "$TESTDIR/cc.log" ]]; then
            echo "  cc.log contents:"
            cat "$TESTDIR/cc.log"
        else
            echo "  cc.log absent"
        fi
        ERRORS=$((ERRORS + 1))
    fi

    # Run the compiled program
    echo "  Running compiled program:"
    run_target ./hello
else
    echo "FAIL: Compilation failed with custom CC"
    exit 1
fi

# Test 4: Restore default and verify it still works
echo ""
echo "Test 4: Default CC works after unsetting custom value"

unset CONDA_OCAML_CC
if [[ -f "${CONDA_PREFIX}/etc/conda/activate.d/ocaml_activate.sh" ]]; then
    source "${CONDA_PREFIX}/etc/conda/activate.d/ocaml_activate.sh"
fi

echo "  CONDA_OCAML_CC = ${CONDA_OCAML_CC:-<not set>}"

cd "$TESTDIR"
if ocamlopt -o hello2 hello.ml 2>&1; then
    echo "PASS: Compilation works with default CC"
    run_target ./hello2
else
    echo "FAIL: Compilation failed with default CC"
    exit 1
fi

if [[ $ERRORS -gt 0 ]]; then
  echo "=== FAILED: ${ERRORS} toolchain wrapper check(s) failed ==="
  exit 1
fi

echo ""
echo "=== All CONDA_OCAML_* toolchain tests passed ==="
