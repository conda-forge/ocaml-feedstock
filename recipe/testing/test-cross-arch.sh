#!/usr/bin/env bash
# Test cross-compiled binaries have correct architecture
# Verifies binaries match target platform (not build platform)

set -euo pipefail

echo "=== Cross-Compiled Binary Architecture Tests ==="

# Get target platform from positional argument (passed by recipe.yaml)
TARGET_PLATFORM="${1:-}"
if [[ -z "$TARGET_PLATFORM" ]]; then
  echo "ERROR: target_platform not passed to script"
  echo "Usage: $0 <target_platform>"
  exit 1
fi

echo "Target platform: ${TARGET_PLATFORM}"

# Define expected architecture string based on platform
case "${TARGET_PLATFORM}" in
  linux-aarch64)
    ARCH_CHECK="AArch64"
    CHECK_CMD="readelf -h"
    SHARED_EXT="so"
    ;;
  linux-ppc64le)
    ARCH_CHECK="PowerPC64"
    CHECK_CMD="readelf -h"
    SHARED_EXT="so"
    ;;
  osx-arm64)
    ARCH_CHECK="ARM64"
    CHECK_CMD="otool -hv"
    SHARED_EXT="so"
    ;;
  *)
    echo "Not a cross-compilation target (${TARGET_PLATFORM}), skipping"
    exit 0
    ;;
esac

echo "Expected architecture: ${ARCH_CHECK}"
echo ""

check_binary() {
  local binary="$1"
  local name="$2"

  if [[ ! -f "$binary" ]]; then
    echo "ERROR: ${name} not found at ${binary}"
    exit 1
  fi

  echo -n "  ${name}: "
  if ${CHECK_CMD} "$binary" 2>/dev/null | grep -iq "${ARCH_CHECK}"; then
    echo "OK (${ARCH_CHECK})"
  else
    echo "FAILED"
    echo "    Expected: ${ARCH_CHECK}"
    echo "    Got:"
    ${CHECK_CMD} "$binary" 2>/dev/null | head -5
    exit 1
  fi
}

echo "Checking native compiler binaries..."
check_binary "${PREFIX}/bin/ocamlc.opt" "ocamlc.opt"
check_binary "${PREFIX}/bin/ocamlopt.opt" "ocamlopt.opt"
check_binary "${PREFIX}/bin/ocamllex.opt" "ocamllex.opt"
check_binary "${PREFIX}/bin/ocamldep.opt" "ocamldep.opt"
check_binary "${PREFIX}/bin/ocamlobjinfo.opt" "ocamlobjinfo.opt"

echo ""
echo "Checking runtime binaries..."
check_binary "${PREFIX}/bin/ocamlrun" "ocamlrun"

echo ""
echo "Checking shared libraries..."
check_binary "${PREFIX}/lib/ocaml/libasmrun_shared.${SHARED_EXT}" "libasmrun_shared.${SHARED_EXT}"

# Check stublibs if they exist
if ls "${PREFIX}/lib/ocaml/stublibs/"*.${SHARED_EXT} >/dev/null 2>&1; then
  echo ""
  echo "Checking stublibs..."
  for stublib in "${PREFIX}/lib/ocaml/stublibs/"*.${SHARED_EXT}; do
    stubname=$(basename "$stublib")
    check_binary "$stublib" "stublibs/${stubname}"
  done
fi

echo ""
echo "=== All cross-compiled binaries have correct architecture (${ARCH_CHECK}) ==="
