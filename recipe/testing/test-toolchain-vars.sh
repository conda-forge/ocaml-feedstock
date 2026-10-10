#!/bin/bash
# Test that CONDA_OCAML_* toolchain variables work correctly
# This test verifies that ocamlopt respects custom CC/AS/AR settings
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

qemu_wrap_toolchain

echo "=== Test: CONDA_OCAML_* Toolchain Variables ==="

ERRORS=0

# Test 1: Verify activation script sets defaults
echo ""
echo "Test 1: Environment activation sets default CONDA_OCAML_* values"

# Check that variables are set
for var in CONDA_OCAML_CC CONDA_OCAML_AS CONDA_OCAML_AR CONDA_OCAML_MKDLL; do
    if [[ -z "${!var:-}" ]]; then
        echo "FAIL: $var is not set by environment activation"
        exit 1
    fi
    echo "  $var = ${!var}"
done
echo "PASS: All CONDA_OCAML_* variables are set"

# Test 2: Verify ocamlopt -config shows wrapper script references
echo ""
echo "Test 2: ocamlopt -config uses conda-ocaml-* wrapper scripts"

CONFIG_CC=$(run_target ocamlopt -config-var c_compiler)
CONFIG_ASM=$(run_target ocamlopt -config-var asm)

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
    if [[ -x "${PREFIX}/bin/${wrapper}" ]]; then
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

# conda-ocaml-cc reads CONDA_OCAML_CC when it runs
export CONDA_OCAML_CC="$TESTDIR/cc-wrapper"

# Clear log and compile
> "$TESTDIR/cc.log"
cd "$TESTDIR"

if run_target ocamlopt -o hello stub.c hello.ml 2>&1; then
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
echo "Test 4: Default CC works after restoring it"

export CONDA_OCAML_CC="${REAL_CC}"

echo "  CONDA_OCAML_CC = ${CONDA_OCAML_CC:-<not set>}"

cd "$TESTDIR"
if run_target ocamlopt -o hello2 hello.ml 2>&1; then
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
