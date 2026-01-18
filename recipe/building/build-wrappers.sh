#!/usr/bin/env bash
# Build conda-ocaml-* wrapper executables for Windows
#
# These wrappers read CONDA_OCAML_* environment variables at runtime,
# allowing the OCaml compiler to work with different toolchains without
# hardcoding paths.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SRC="${SCRIPT_DIR}/conda-ocaml-wrapper.c"
INSTALL_DIR="${1:-${PREFIX}/Library/bin}"

# Ensure we have a C compiler
CC="${CC:-gcc}"

echo "Building conda-ocaml-* wrappers for Windows..."
echo "  Source: ${WRAPPER_SRC}"
echo "  Install: ${INSTALL_DIR}"
echo "  Compiler: ${CC}"

mkdir -p "${INSTALL_DIR}"

# Define wrappers: TOOL_NAME -> DEFAULT_TOOL
# These match the Unix conda-ocaml-* scripts
# NOTE: Do NOT include MKEXE/MKDLL - flexlink handles linking on Windows
declare -A WRAPPERS=(
    ["CC"]="gcc.exe"
    ["AS"]="as.exe"
    ["AR"]="ar.exe"
    ["LD"]="ld.exe"
    ["RANLIB"]="ranlib.exe"
    ["WINDRES"]="windres.exe"
)

for tool_name in "${!WRAPPERS[@]}"; do
    default_tool="${WRAPPERS[$tool_name]}"
    wrapper_name="conda-ocaml-${tool_name,,}.exe"  # lowercase

    echo "  Building ${wrapper_name} (default: ${default_tool})..."

    "${CC}" -O2 -o "${INSTALL_DIR}/${wrapper_name}" "${WRAPPER_SRC}" \
        -DTOOL_NAME="${tool_name}" \
        -DDEFAULT_TOOL="\"${default_tool}\""
done

echo "Done building wrappers."
ls -la "${INSTALL_DIR}"/conda-ocaml-*.exe 2>/dev/null || true
