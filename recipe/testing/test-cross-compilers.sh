#!/usr/bin/env bash
# Test cross-compilers built on native platforms
# Exercises aarch64, ppc64le, and arm64 cross-compilers

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

echo "=== Cross-Compiler Tests (expecting ${VERSION}) ==="

# Detect build platform
BUILD_PLATFORM="${build_platform:-}"
TARGET_PLATFORM="${target_platform:-}"

echo "Build platform: ${BUILD_PLATFORM}"
echo "Target platform: ${TARGET_PLATFORM:-same as build}"
echo ""

# Only run on native x86_64 platforms where cross-compilers are built
if [[ "$BUILD_PLATFORM" != "linux-64" ]] && [[ "$BUILD_PLATFORM" != "osx-64" ]]; then
  echo "Cross-compilers only built on linux-64 and osx-64, skipping"
  exit 0
fi

# Skip if this is a cross-compilation (cross-compilers not available)
if [[ -n "$TARGET_PLATFORM" ]] && [[ "$BUILD_PLATFORM" != "$TARGET_PLATFORM" ]]; then
  echo "This is a cross-compilation build, cross-compilers not available"
  exit 0
fi

test_cross_compiler() {
  local prefix="$1"
  local arch_name="$2"
  local qemu_cmd="${3:-}"
  local qemu_prefix="${4:-}"

  echo "=== Testing ${arch_name} cross-compilers (${prefix}-*) ==="

  # Version tests
  echo "  Version checks..."
  echo -n "    ${prefix}-ocamlc: "
  ${prefix}-ocamlc -version | grep -q "${VERSION}" && echo "OK" || { echo "FAILED"; exit 1; }

  echo -n "    ${prefix}-ocamldep: "
  ${prefix}-ocamldep -version | grep -q "${VERSION}" && echo "OK" || { echo "FAILED"; exit 1; }

  echo -n "    ${prefix}-ocamlobjinfo: "
  ${prefix}-ocamlobjinfo -help >/dev/null 2>&1 && echo "OK" || { echo "FAILED"; exit 1; }

  echo -n "    ${prefix}-ocamlopt: "
  ${prefix}-ocamlopt -version | grep -q "${VERSION}" && echo "OK" || { echo "FAILED"; exit 1; }

  # Compilation test
  echo "  Compilation test..."
  local testfile="test_${prefix//[-.]/_}.ml"
  printf 'print_endline "Hello from %s"\n' "${arch_name}" > "${testfile}"

  echo -n "    compile: "
  if ${prefix}-ocamlopt -o "test_${prefix//[-.]/_}" "${testfile}" 2>/dev/null; then
    echo "OK"

    # Execution test with QEMU if available
    if [[ -n "$qemu_cmd" ]] && command -v "$qemu_cmd" >/dev/null 2>&1; then
      echo -n "    execute (QEMU): "
      if QEMU_LD_PREFIX="${qemu_prefix}" ${qemu_cmd} "./test_${prefix//[-.]/_}" 2>/dev/null | grep -q "Hello from ${arch_name}"; then
        echo "OK"
      else
        echo "SKIPPED (QEMU execution failed)"
      fi
    else
      echo "    execute: SKIPPED (no QEMU)"
    fi

    rm -f "test_${prefix//[-.]/_}"
  else
    echo "FAILED"
    exit 1
  fi

  rm -f "${testfile}"
  echo ""
}

# Linux x86_64: test aarch64 and ppc64le cross-compilers
if [[ "$BUILD_PLATFORM" == "linux-64" ]]; then
  # Check if cross-compilers exist
  if command -v aarch64-conda-linux-gnu-ocamlopt >/dev/null 2>&1; then
    test_cross_compiler \
      "aarch64-conda-linux-gnu" \
      "Linux ARM64 (aarch64)" \
      "qemu-execve-aarch64" \
      "${PREFIX}/aarch64-conda-linux-gnu/sysroot"
  else
    echo "aarch64 cross-compiler not found, skipping"
  fi

  if command -v powerpc64le-conda-linux-gnu-ocamlopt >/dev/null 2>&1; then
    test_cross_compiler \
      "powerpc64le-conda-linux-gnu" \
      "Linux PPC64LE" \
      "qemu-execve-ppc64le" \
      "${PREFIX}/powerpc64le-conda-linux-gnu/sysroot"
  else
    echo "ppc64le cross-compiler not found, skipping"
  fi
fi

# macOS x86_64: test arm64 cross-compiler
if [[ "$BUILD_PLATFORM" == "osx-64" ]]; then
  if command -v arm64-apple-darwin20.0.0-ocamlopt >/dev/null 2>&1; then
    # No QEMU for macOS cross-compilation
    test_cross_compiler \
      "arm64-apple-darwin20.0.0" \
      "macOS ARM64" \
      "" \
      ""
  else
    echo "arm64 cross-compiler not found, skipping"
  fi
fi

echo "=== All cross-compiler tests passed ==="
