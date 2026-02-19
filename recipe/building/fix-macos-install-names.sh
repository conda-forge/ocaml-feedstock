#!/bin/bash
# fix-macos-install-names.sh - Fix install_names for macOS shared libraries
#
# OCaml builds .so files with relative paths like "./dllunixbyt.so" or
# "runtime/libcamlrun_shared.so" which cause rattler-build overlinking warnings.
# This script fixes install_names to use @rpath for proper relocation.
#
# Usage: fix-macos-install-names.sh <ocaml_lib_dir>
#   ocaml_lib_dir: Path to lib/ocaml directory (e.g., $PREFIX/lib/ocaml)
#
# Example:
#   fix-macos-install-names.sh "${PREFIX}/lib/ocaml"
#   fix-macos-install-names.sh "${PREFIX}/lib/ocaml-cross-compilers/arm64-apple-darwin20.0.0/lib/ocaml"

set -euo pipefail

# CRITICAL: Unset DYLD_* variables before running macOS system tools
# Conda sets these to find its libraries, but this causes macOS tools
# (install_name_tool, otool, codesign) to load wrong libiconv, causing segfaults.
# The tools work fine with system libraries when these are unset.
unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH 2>/dev/null || true

OCAML_LIB="${1:?Usage: fix-macos-install-names.sh <ocaml_lib_dir>}"

# CRITICAL: macOS system tools (install_name_tool, otool, codesign) can crash
# when conda's libiconv overrides /usr/lib/libiconv.2.dylib but lacks symbols.
# Run these tools with clean DYLD paths to avoid the conflict.
unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH 2>/dev/null || true

if [[ ! -d "${OCAML_LIB}" ]]; then
  echo "ERROR: Directory not found: ${OCAML_LIB}"
  exit 1
fi

echo "  Fixing install_names in ${OCAML_LIB}..."

# Fix runtime libraries first (others may depend on them)
for lib in "${OCAML_LIB}"/lib{camlrun,asmrun}_shared.so; do
  if [[ -f "${lib}" ]]; then
    libname=$(basename "${lib}")
    echo "    ${libname}: setting install_name to @rpath/${libname}"
    install_name_tool -id "@rpath/${libname}" "${lib}" 2>/dev/null || true
  fi
done

# Fix stublibs
if [[ -d "${OCAML_LIB}/stublibs" ]]; then
  for lib in "${OCAML_LIB}"/stublibs/dll*.so; do
    if [[ -f "${lib}" ]]; then
      libname=$(basename "${lib}")
      echo "    stublibs/${libname}: setting install_name to @rpath/${libname}"
      install_name_tool -id "@rpath/${libname}" "${lib}" 2>/dev/null || true

      # Fix references to runtime libraries within stublibs
      for dep in "runtime/libcamlrun_shared.so" "runtime/libasmrun_shared.so" \
                 "./libcamlrun_shared.so" "./libasmrun_shared.so"; do
        depname=$(basename "${dep}")
        if otool -L "${lib}" 2>/dev/null | grep -q "${dep}"; then
          install_name_tool -change "${dep}" "@rpath/${depname}" "${lib}" 2>/dev/null || true
        fi
      done

      # Fix references to sibling stublibs (./dllXXX.so)
      for sibling in "${OCAML_LIB}"/stublibs/dll*.so; do
        sibname=$(basename "${sibling}")
        if otool -L "${lib}" 2>/dev/null | grep -q "./${sibname}"; then
          install_name_tool -change "./${sibname}" "@rpath/${sibname}" "${lib}" 2>/dev/null || true
        fi
      done
    fi
  done
fi

# Re-sign all modified libraries (required on macOS arm64)
echo "  Re-signing modified libraries..."
for lib in "${OCAML_LIB}"/lib*.so "${OCAML_LIB}"/stublibs/dll*.so; do
  if [[ -f "${lib}" ]]; then
    codesign -f -s - "${lib}" 2>/dev/null || true
  fi
done

echo "  Install names fixed."
