#!/usr/bin/env bash
# Build conda-ocaml-* wrapper executables for non-unix
#
# These wrappers read CONDA_OCAML_* environment variables at runtime,
# allowing the OCaml compiler to work with different toolchains without
# hardcoding paths.
#
# Supports both MinGW (gcc) and MSVC (cl) toolchains based on TARGET_TRIPLET.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SRC="${SCRIPT_DIR}/non-unix-conda-ocaml-wrapper.c"
INSTALL_DIR="${1:-${PREFIX}/Library/bin}"

# Detect toolchain from triplet: -w64-mingw32 = MinGW, -pc-windows = MSVC
TRIPLET="${TARGET_TRIPLET:-x86_64-w64-mingw32}"

echo "Building conda-ocaml-* wrappers for non-unix..."
echo "  Source: ${WRAPPER_SRC}"
echo "  Install: ${INSTALL_DIR}"
echo "  Triplet: ${TRIPLET}"

mkdir -p "${INSTALL_DIR}"

# Define wrappers based on toolchain detected from triplet
# NOTE: Do NOT include MKEXE/MKDLL - flexlink handles linking on non-unix
declare -A WRAPPERS

if [[ "${TRIPLET}" == *"-w64-mingw32"* ]]; then
    echo "  Detected MinGW (GCC) toolchain from triplet..."
    CC="${CC:-gcc}"
    WRAPPERS=(
        ["CC"]="gcc.exe"
        ["AS"]="as.exe"
        ["AR"]="ar.exe"
        ["LD"]="ld.exe"
        ["RANLIB"]="ranlib.exe"
        ["WINDRES"]="windres.exe"
    )
elif [[ "${TRIPLET}" == *"-pc-"* ]]; then
    echo "  Detected MSVC (Visual Studio) toolchain from triplet..."
    echo "  MSVC tools come from Visual Studio - creating batch script wrappers instead..."

    # For MSVC, create simple .bat wrappers that call the MSVC tools directly
    # These tools are expected to be in PATH from VS activation
    declare -A MSVC_TOOLS=(
        ["cc"]="cl.exe"
        ["as"]="ml64.exe"
        ["ar"]="lib.exe"
        ["ld"]="link.exe"
        ["ranlib"]="echo"
        ["windres"]="rc.exe"
    )

    for tool_name in "${!MSVC_TOOLS[@]}"; do
        msvc_tool="${MSVC_TOOLS[$tool_name]}"
        wrapper_name="conda-ocaml-${tool_name}.bat"
        echo "    Creating ${wrapper_name} -> ${msvc_tool}..."

        if [[ "${msvc_tool}" == "echo" ]]; then
            # No-op for ranlib
            cat > "${INSTALL_DIR}/${wrapper_name}" << 'EOF'
@echo off
REM No-op ranlib for MSVC - lib.exe handles indexing automatically
exit /b 0
EOF
        else
            cat > "${INSTALL_DIR}/${wrapper_name}" << EOF
@echo off
${msvc_tool} %*
EOF
        fi
    done

    echo "Done creating MSVC batch wrappers."
    ls -la "${INSTALL_DIR}"/conda-ocaml-*.bat 2>/dev/null || true
    exit 0
else
    echo "ERROR: Unknown triplet '${TRIPLET}'. Expected '*-w64-mingw32' or '*-pc-*'."
    exit 1
fi

echo "  Compiler: ${CC}"

for tool_name in "${!WRAPPERS[@]}"; do
    default_tool="${WRAPPERS[$tool_name]}"
    wrapper_name="conda-ocaml-${tool_name,,}.exe"  # lowercase

    echo "  Building ${wrapper_name} (default: ${default_tool})..."

    # Handle special case: RANLIB with no-op for MSVC
    if [[ "${default_tool}" == "echo" ]]; then
        # Create a simple batch script instead of compiled wrapper
        cat > "${INSTALL_DIR}/${wrapper_name%.exe}.bat" << 'EOF'
@echo off
REM No-op ranlib for MSVC - lib.exe handles indexing automatically
exit /b 0
EOF
        echo "    (created no-op batch script)"
        continue
    fi

    # Compile with appropriate flags for gcc vs cl
    if [[ "${CC}" == "cl" || "${CC}" == "cl.exe" ]]; then
        # MSVC cl.exe syntax
        "${CC}" /O2 /Fe:"${INSTALL_DIR}/${wrapper_name}" "${WRAPPER_SRC}" \
            /DTOOL_NAME="${tool_name}" \
            /DDEFAULT_TOOL="\"${default_tool}\""
    else
        # GCC/MinGW syntax
        "${CC}" -O2 -o "${INSTALL_DIR}/${wrapper_name}" "${WRAPPER_SRC}" \
            -DTOOL_NAME="${tool_name}" \
            -DDEFAULT_TOOL="\"${default_tool}\""
    fi
done

echo "Done building wrappers."
ls -la "${INSTALL_DIR}"/conda-ocaml-*.exe 2>/dev/null || true
ls -la "${INSTALL_DIR}"/conda-ocaml-*.bat 2>/dev/null || true
