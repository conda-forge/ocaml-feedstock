#!/usr/bin/env bash
# Test environment variables and resource file paths
# Verifies no build-time paths leaked into installed package

set -euo pipefail

echo "=== OCAML config Tests ==="

# Check config vars don't contain build-time paths
echo "Checking ocamlc.opt -config-var values..."

STDLIB_PATH=$(ocamlc.opt -config-var standard_library)
echo "  standard_library=${STDLIB_PATH}"

CC_PATH=$(ocamlc.opt -config-var bytecomp_c_compiler)
echo "  bytecomp_c_compiler=${CC_PATH}"

CC_PATH=$(ocamlc.opt -config-var native_c_compiler)
echo "  native_c_compiler=${CC_PATH}"

CC_PATH=$(ocamlc.opt -config-var c_compiler)
echo "  c_compiler=${CC_PATH}"

# Should be basename OR contain $PREFIX, never rattler-build_ from another job
if echo "$CC_PATH" | grep -q "rattler-build_"; then
  echo "ERROR: c_compiler contains build-time path: $CC_PATH"
  exit 1
fi

# If absolute path, must be under PREFIX
if [[ "$CC_PATH" == /* ]] && [[ "$CC_PATH" != "${PREFIX}"* ]]; then
  echo "ERROR: c_compiler absolute path not under PREFIX: $CC_PATH"
  exit 1
fi
echo "  c_compiler: clean"

ASM_PATH=$(ocamlc.opt -config-var asm)
echo "  asm=${ASM_PATH}"
if echo "$ASM_PATH" | grep -q "rattler-build_"; then
  echo "ERROR: asm contains build-time path: $ASM_PATH"
  exit 1
fi
echo "  asm: clean"

# Check library paths don't contain -L flags with absolute paths
BYTECCLIBS=$(ocamlc.opt -config-var bytecomp_c_libraries)
echo "  bytecomp_c_libraries=${BYTECCLIBS}"
if echo "$BYTECCLIBS" | grep -qE "^-L|[[:space:]]-L"; then
  echo "ERROR: bytecomp_c_libraries contains -L path: $BYTECCLIBS"
  exit 1
fi
echo "  bytecomp_c_libraries: clean"

# compression_c_libraries may not exist in all OCaml versions
ZSTDLIBS=$(ocamlc.opt -config-var compression_c_libraries 2>/dev/null || echo "N/A")
echo "  compression_c_libraries=${ZSTDLIBS}"
if [[ "$ZSTDLIBS" != "N/A" ]] && echo "$ZSTDLIBS" | grep -qE "^-L|[[:space:]]-L"; then
  echo "ERROR: compression_c_libraries contains -L path: $ZSTDLIBS"
  exit 1
fi
echo "  compression_c_libraries: clean (or not present in this version)"

# Check native_c_libraries for -L paths
NATIVECCLIBS=$(ocamlc.opt -config-var native_c_libraries 2>/dev/null || echo "N/A")
echo "  native_c_libraries=${NATIVECCLIBS}"
if [[ "$NATIVECCLIBS" != "N/A" ]] && echo "$NATIVECCLIBS" | grep -qE "^-L|[[:space:]]-L"; then
  # Allow -L if it's a relative path or system path, but not build paths
  if echo "$NATIVECCLIBS" | grep -qE "-L[^ ]*(conda-bld|rattler-build|build_env)"; then
    echo "ERROR: native_c_libraries contains build-time -L path: $NATIVECCLIBS"
    exit 1
  fi
fi
echo "  native_c_libraries: clean"

# Check Makefile.config for hardcoded build paths
MAKEFILE_CONFIG="${PREFIX}/lib/ocaml/Makefile.config"
if [[ -f "${MAKEFILE_CONFIG}" ]]; then
  echo "Checking Makefile.config for build-time paths..."
  if grep -qE "\-L[^ ]*(conda-bld|rattler-build|build_env)" "${MAKEFILE_CONFIG}"; then
    echo "ERROR: Makefile.config contains build-time -L paths:"
    grep -E "\-L[^ ]*(conda-bld|rattler-build|build_env)" "${MAKEFILE_CONFIG}" || true
    exit 1
  fi
  echo "  Makefile.config: clean"
fi

# Check rpath on macOS (prevents "@rpath/libzstd.1.dylib not found" at runtime)
if [[ "$(uname)" == "Darwin" ]]; then
  echo "Checking macOS rpath for libzstd..."
  OCAMLOPT_BIN="${PREFIX}/bin/ocamlopt.opt"
  if [[ -f "${OCAMLOPT_BIN}" ]]; then
    # Show diagnostic info
    echo "  Binary: ${OCAMLOPT_BIN}"
    echo "  Dependencies (otool -L):"
    otool -L "${OCAMLOPT_BIN}" 2>&1 | head -10 | sed 's/^/    /'

    # Check if libzstd is linked via @rpath
    if otool -L "${OCAMLOPT_BIN}" 2>/dev/null | grep -q "@rpath/libzstd"; then
      echo "  libzstd link: @rpath/libzstd (needs rpath entry)"

      # Show LC_RPATH entries
      echo "  LC_RPATH entries (otool -l):"
      otool -l "${OCAMLOPT_BIN}" 2>&1 | grep -A2 "LC_RPATH" | sed 's/^/    /' || echo "    (none found)"

      # Verify rpath includes path to lib/
      # Accept either @executable_path or @loader_path (equivalent for executables)
      if otool -l "${OCAMLOPT_BIN}" 2>/dev/null | grep -A2 "LC_RPATH" | grep -qE "@(executable_path|loader_path)"; then
        RPATH_VAL=$(otool -l "${OCAMLOPT_BIN}" 2>/dev/null | grep -A2 "LC_RPATH" | grep "path" | awk '{print $2}')
        echo "  rpath: ${RPATH_VAL} (OK)"
      else
        echo "ERROR: Missing rpath entry for @executable_path or @loader_path"
        echo "  Binary links @rpath/libzstd but has no rpath to find it"
        echo "  Expected: @executable_path/../lib or @loader_path/../lib"
        exit 1
      fi
    else
      echo "  libzstd not linked via @rpath (OK - may be statically linked)"
    fi
  else
    echo "  SKIP: ocamlopt.opt not found"
  fi
fi

echo "=== OCAML config tests passed ==="
