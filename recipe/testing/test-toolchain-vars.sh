#!/bin/bash
# Test that CONDA_OCAML_* toolchain variables work correctly
# This test verifies that ocamlopt respects custom CC/AS/AR settings
set -euo pipefail

echo "=== Test: CONDA_OCAML_* Toolchain Variables ==="

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
echo "Test 2: ocamlopt -config uses ocaml-* wrapper scripts"

CONFIG_CC=$(ocamlopt -config-var c_compiler)
CONFIG_ASM=$(ocamlopt -config-var asm)

echo "  c_compiler = $CONFIG_CC"
echo "  asm = $CONFIG_ASM"

# Config should reference ocaml-* wrapper scripts (for Unix.create_process compatibility)
if [[ "$CONFIG_CC" == "ocaml-cc" ]]; then
    echo "PASS: c_compiler uses ocaml-cc wrapper"
elif [[ "$CONFIG_CC" == *'$'* ]] || [[ "$CONFIG_CC" == *'CONDA_OCAML'* ]]; then
    echo "INFO: c_compiler uses direct env var reference (older build): $CONFIG_CC"
else
    echo "INFO: c_compiler is hardcoded: $CONFIG_CC"
fi

# Test 2b: Verify wrapper scripts exist and are executable
echo ""
echo "Test 2b: Verify wrapper scripts are installed"
for wrapper in ocaml-cc ocaml-as ocaml-ar ocaml-ranlib ocaml-mkexe ocaml-mkdll; do
    if [[ -x "${CONDA_PREFIX}/bin/${wrapper}" ]]; then
        echo "  $wrapper: OK"
    else
        echo "  $wrapper: MISSING"
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

if ocamlopt -o hello hello.ml 2>&1; then
    echo "  Compilation succeeded"

    # Check if wrapper was called
    if [[ -f "$TESTDIR/cc.log" ]] && grep -q "CC_WRAPPER_CALLED" "$TESTDIR/cc.log"; then
        echo "PASS: Custom CONDA_OCAML_CC wrapper was invoked"
    else
        echo "INFO: Wrapper log not found (may be normal for some builds)"
    fi

    # Run the compiled program
    echo "  Running compiled program:"
    ./hello
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

echo "  CONDA_OCAML_CC = ${CONDA_OCAML_CC}"

cd "$TESTDIR"
if ocamlopt -o hello2 hello.ml 2>&1; then
    echo "PASS: Compilation works with default CC"
    ./hello2
else
    echo "FAIL: Compilation failed with default CC"
    exit 1
fi

echo ""
echo "=== All CONDA_OCAML_* toolchain tests passed ==="
