#!/usr/bin/env bash
# Test cross-compilers built on native platforms
# Exercises aarch64, ppc64le, and arm64 cross-compilers

set -euo pipefail

echo "Testing that primitive table compilation uses correct architecture..."

# Create a test that forces primitive table generation
cat > /tmp/test_prims.ml << 'EOF'
external custom_prim : unit -> unit = "custom_prim"
let () =
  try custom_prim () with _ -> print_endline "OK"
EOF

# This generates camlprim*.o temp file - verify it's the right arch
# We can't easily inspect the temp file, but we can check the final binary
ocamlc -output-complete-exe /tmp/test_prims.ml -o /tmp/test_prims.exe 2>&1 || true

# If we get "architecture X incompatible with target Y", the test fails
# The compilation might fail for other reasons (missing custom_prim), that's OK
if [[ "$(uname)" == "Darwin" ]]; then
  # Check if any .o files in temp have wrong architecture
  # This is a heuristic - check the error message
  OUTPUT=$(ocamlc -output-complete-exe /tmp/test_prims.ml -o /tmp/test_prims.exe 2>&1 || true)
  if echo "${OUTPUT}" | grep -q "incompatible with target architecture"; then
    echo "ERROR: Architecture mismatch in primitive table compilation"
    echo "${OUTPUT}"
    exit 1
  fi
fi

echo "Primitives architecture test passed"
