#!/usr/bin/env bash
# Test that OCaml's primitive table compilation uses correct architecture
# This catches cross-compilation bugs where intermediate .o files have wrong arch

set -euo pipefail

echo "Testing that primitive table compilation uses correct architecture..."

# Create a test that forces primitive table generation
# NOTE: custom_prim intentionally doesn't exist - we only care about architecture
cat > /tmp/test_prims.ml << 'EOF'
external custom_prim : unit -> unit = "custom_prim"
let () =
  try custom_prim () with _ -> print_endline "OK"
EOF

# Capture output silently - we expect "undefined symbol: custom_prim" failure
# We only care if there's an architecture mismatch error
OUTPUT=$(ocamlc -output-complete-exe /tmp/test_prims.ml -o /tmp/test_prims.exe 2>&1 || true)

if [[ "$(uname)" == "Darwin" ]]; then
  # On macOS, check for architecture mismatch (e.g., x86_64 .o on arm64 build)
  if echo "${OUTPUT}" | grep -q "incompatible with target architecture"; then
    echo "ERROR: Architecture mismatch in primitive table compilation"
    echo "${OUTPUT}"
    exit 1
  fi
fi

echo "Primitives architecture test passed"
