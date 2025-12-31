#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# CRITICAL: Ensure we're using conda bash 5.2+, not system bash
# ==============================================================================
if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  echo "re-exec with conda bash..."
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

mkdir -p "${SRC_DIR}"/_logs

# CONFIG_ARGS=(--enable-shared)
# if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
#   CONFIG_ARGS+=(PKG_CONFIG=false)
#   EXE=""
#   SH_EXT="sh"
# else
#   export PKG_CONFIG_PATH="${OCAML_INSTALL_PREFIX}/lib/pkgconfig;${PREFIX}/lib/pkgconfig;${PKG_CONFIG_PATH:-}"
#   export LIBRARY_PATH="${BUILD_PREFIX}/lib;${PREFIX}/lib;${LIBRARY_PATH:-}"
#   CONFIG_ARGS+=(LDFLAGS="-L${BUILD_PREFIX}/Library/lib -L${BUILD_PREFIX}/lib -L${PREFIX}/Library/lib -L${PREFIX}/lib ${LDFLAGS:-}")
#   EXE=".exe"
#   SH_EXT="bat"
# fi

# (
#   OCAML_INSTALL_PREFIX="${SRC_DIR}"/_native && mkdir -p "${OCAML_INSTALL_PREFIX}"
#   source "${RECIPE_DIR}"/building/build-native.sh
# )

# (
#   OCAML_PREFIX="${SRC_DIR}"/_native
#   OCAMLIB="${OCAML_PREFIX}"/lib/ocaml
#   
#   OCAML_INSTALL_PREFIX="${SRC_DIR}"/_cross && mkdir -p "${OCAML_INSTALL_PREFIX}"
#   source "${RECIPE_DIR}"/building/build-cross-compiler-new.sh
# )

export OCAML_INSTALL_PREFIX="${PREFIX}"
# Simplify compiler paths to basenames (hardcoded in binaries)
export AR=$(basename "${AR}")
export AS=$(basename "${AS}")
export CC=$(basename "${CC}")
export ASPP="$CC -c"
export RANLIB=$(basename "${RANLIB}")

if [[ "${target_platform}" == "osx-"* ]]; then
  # macOS: MUST use LLVM ar/ranlib - GNU ar format incompatible with ld64
  # Use full path to ensure we don't pick up binutils ar from PATH
  _AR=$(find "${BUILD_PREFIX}" "${PREFIX}" -name "llvm-ar*" -type f 2>/dev/null | head -1)
  if [[ -n "${_AR}" ]]; then
    export AR=$(basename ${_AR})
    export RANLIB="${_AR/-ar/-ranlib}"
  else
    echo "WARNING: llvm-ar/llvm-ranlib not found, using GNU AR/RANLIB"
  fi
  # Get just the compiler name from ASPP (e.g., "/path/to/clang -c" → "clang")
  # basename doesn't strip arguments, so we need to extract the first word first
  export AS=$(basename "${ASPP%% *}")
  export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld -Wl,-headerpad_max_install_names"
  export DYLD_LIBRARY_PATH="${PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
fi


# Define CONDA_OCAML_* variables
export CONDA_OCAML_AR="${AR}"
export CONDA_OCAML_AS="${AS}"
export CONDA_OCAML_CC="${CC}"
export CONDA_OCAML_RANLIB="${RANLIB}"
if [[ "${target_platform}" == "linux-"* ]]; then
  export CONDA_OCAML_MKEXE="${CC} -Wl,-E"
  export CONDA_OCAML_MKDLL="${CC} -shared"
elif [[ "${target_platform}" == "osx-"* ]]; then
  export CONDA_OCAML_MKEXE="${CC} -fuse-ld=lld -Wl,-headerpad_max_install_names"
  export CONDA_OCAML_MKDLL="${CC} -shared -fuse-ld=lld -Wl,-headerpad_max_install_names -undefined dynamic_lookup"
else
  # Windows: Use flexlink for FlexDLL support (needed by OCaml runtime)
  # Note: conda-forge MinGW defaults to GUI CRT (crtexewin.o) which expects WinMain
  # We solve this by linking a WinMain shim (see winmain_shim.c below)
  export CONDA_OCAML_MKEXE="flexlink -exe -chain mingw64"
  export CONDA_OCAML_MKDLL="flexlink -chain mingw64"
fi

CONFIG_ARGS=(--enable-shared)

# Platform detection and OCAML_INSTALL_PREFIX setup
if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export LIBRARY_PATH="${PREFIX}/lib:${LIBRARY_PATH:-}"
  # PKG_CONFIG=false forces zstd fallback detection: simple "-lzstd" instead of
  # pkg-config's "-L/long/build/path -lzstd" which causes binary truncation issues
  CONFIG_ARGS+=(PKG_CONFIG=false)
  EXE=""
  SH_EXT="sh"
else
  export OCAML_INSTALL_PREFIX="${OCAML_INSTALL_PREFIX}"/Library
  export PKG_CONFIG_PATH="${OCAML_INSTALL_PREFIX}/lib/pkgconfig;${PREFIX}/lib/pkgconfig;${PKG_CONFIG_PATH:-}"
  export LIBRARY_PATH="${OCAML_INSTALL_PREFIX}/lib;${PREFIX}/lib;${LIBRARY_PATH:-}"
  CONFIG_ARGS+=(LDFLAGS="-L${OCAML_INSTALL_PREFIX}/lib -L${PREFIX}/lib ${LDFLAGS:-}")
  export MINGW_CC=$(find "${BUILD_PREFIX}" -name "x86_64-w64-mingw32-gcc.exe" -type f 2>/dev/null | head -1)
  if [[ -n "${MINGW_CC}" ]]; then
    MINGW_DIR=$(dirname "${MINGW_CC}") && export PATH="${MINGW_DIR}:${PATH}"
  else
    echo "ERROR: non-unix build developped with GCC" && exit 1
  fi
  EXE=".exe"
  SH_EXT="bat"
fi

CONFIG_ARGS+=(
  --mandir="${OCAML_INSTALL_PREFIX}"/share/man
  --with-target-bindir="${OCAML_INSTALL_PREFIX}"/bin
  --with-target-sh="${OCAML_INSTALL_PREFIX}"/bin/bash
  -prefix "${OCAML_INSTALL_PREFIX}"
)

if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
  if [[ -d "${BUILD_PREFIX}"/lib/ocaml-cross-compilers ]]; then
    echo "=== Cross-compiling with cross-compiler ==="
    source "${RECIPE_DIR}/building/cross-compile.sh"
  else
    # Cross-compilation: use unified 3-stage build script
    echo "=== Cross-compiling with unified 3-stage build script ==="
    source "${RECIPE_DIR}/building/3-stage-cross-compile.sh"
  fi
else
  # Load unix no-op non-unix helpers
  source "${RECIPE_DIR}/building/non-unix-utilities.sh"

  # No-op for unix
  unix_noop_build_toolchain

  if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
    CONFIG_ARGS+=(--enable-ocamltest)
  fi

  echo "=== Configuring native compiler ==="
  ./configure "${CONFIG_ARGS[@]}" > "${SRC_DIR}"/_logs/configure.log 2>&1 || { cat "${SRC_DIR}"/config.log; exit 1; }

  # No-op for unix
  unix_noop_update_toolchain

  # Patch config.generated.ml to use CONDA_OCAML_* env vars (expanded at runtime)
  config_file="utils/config.generated.ml"
  if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
    # Use environment variable references - users can customize via CONDA_OCAML_*
    sed -i 's/^let asm = .*/let asm = {|\$CONDA_OCAML_AS|}/' "$config_file"
    sed -i 's/^let c_compiler = .*/let c_compiler = {|\$CONDA_OCAML_CC|}/' "$config_file"
    sed -i 's/^let mkexe = .*/let mkexe = {|\$CONDA_OCAML_CC|}/' "$config_file"
    sed -i 's/^let ar = .*/let ar = {|\$CONDA_OCAML_AR|}/' "$config_file"
    sed -i 's/^let ranlib = .*/let ranlib = {|\$CONDA_OCAML_RANLIB|}/' "$config_file"
    sed -i 's/^let mkdll = .*/let mkdll = {|\$CONDA_OCAML_MKDLL|}/' "$config_file"
    sed -i 's/^let mkmaindll = .*/let mkmaindll = {|\$CONDA_OCAML_MKDLL|}/' "$config_file"

    if [[ "${target_platform}" == "osx-"* ]]; then
      # macOS: clang needs -c flag to assemble without linking
      # Without -c, clang tries to link and fails with "undefined _main"
      sed -i 's/^let asm = .*/let asm = {|\$CONDA_OCAML_CC -c|}/' "$config_file"
      sed -i -E 's/^(let mkdll = .*_MKDLL)(.*)/\1 -undefined dynamic_lookup\2/' "$config_file"
      sed -i -E 's/^(let mkmaindll = .*_MKDLL)(.*)/\1 -undefined dynamic_lookup\2/' "$config_file"
    fi

    # Remove -L paths from bytecomp_c_libraries (embedded in ocamlc binary)
    sed -i 's|-L[^ ]*||g' "$config_file"
  else
    # Windows: Use flexlink with explicit console entry point
    # Problem: conda-forge MinGW defaults to GUI CRT (crtexewin.o) which expects WinMain
    # Solution: Force console entry point via linker flag --entry=mainCRTStartup
    # Both crtexe.o and crtexewin.o define both entry points - only the default differs
    # This preserves FlexDLL support (needed by OCaml runtime for dynamic loading)

    # Use environment variable references - users can customize via CONDA_OCAML_*
    sed -i 's/^let asm = .*/let asm = {|%CONDA_OCAML_AS%|}/' "$config_file"
    sed -i 's/^let c_compiler = .*/let c_compiler = {|%CONDA_OCAML_CC%|}/' "$config_file"
    sed -i 's/^let ar = .*/let ar = {|%CONDA_OCAML_AR%|}/' "$config_file"
    sed -i 's/^let ranlib = .*/let ranlib = {|%CONDA_OCAML_RANLIB%|}/' "$config_file"
    sed -i 's/^let mkexe = .*/let mkexe = {|%CONDA_OCAML_CC%|}/' "$config_file"
    sed -i 's/^let mkdll = .*/let mkdll = {|%CONDA_OCAML_MKDLL%|}/' "$config_file"
    sed -i 's/^let mkmaindll = .*/let mkmaindll = {|%CONDA_OCAML_MKDLL% -maindll|}/' "$config_file"
  fi

  # Remove -L paths and debug-prefix-map from Makefile.config (embedded in ocamlc binary)
  config_file="Makefile.config"
  sed -i 's|-fdebug-prefix-map=[^ ]*||g' "${config_file}"
  sed -i 's|-L[^ ]*||g' "${config_file}"

  if [[ "${target_platform}" == "osx-"* ]]; then
    # macOS: Add -headerpad_max_install_names to ALL linker flags
    # This ensures install_name_tool can relink ALL native binaries (including ocamldoc.opt)
    # Without this, binaries built by ocamlopt (not just MKEXE) may fail during conda relocation
    # Add headerpad to OC_LDFLAGS (used by ocamlopt for native binaries)
    if grep -q "^OC_LDFLAGS=" "${config_file}"; then
      sed -i 's|^OC_LDFLAGS=\(.*\)|OC_LDFLAGS=\1 -Wl,-headerpad_max_install_names|' "${config_file}"
    else
      echo "OC_LDFLAGS=-Wl,-headerpad_max_install_names" >> "${config_file}"
    fi
    # Add headerpad to NATIVECCLINKOPTS (native code C linker options)
    if grep -q "^NATIVECCLINKOPTS=" "${config_file}"; then
      sed -i 's|^NATIVECCLINKOPTS=\(.*\)|NATIVECCLINKOPTS=\1 -Wl,-headerpad_max_install_names|' "${config_file}"
    else
      echo "NATIVECCLINKOPTS=-Wl,-headerpad_max_install_names" >> "${config_file}"
    fi
    echo "=== DEBUG: macOS headerpad settings ==="
    grep -E "^OC_LDFLAGS|^NATIVECCLINKOPTS|^MKEXE" "${config_file}" || true
    echo "=== END DEBUG ==="

  elif [[ "${target_platform}" != "linux-"* ]]; then
    # Windows: Create WinMain shim because conda-forge MinGW defaults to GUI CRT
    # The issue: crtexewin.o's main() calls WinMain(), regardless of entry point
    # Solution: Provide a WinMain that calls main() - link with all executables
    echo "=== Creating WinMain shim for Windows console mode ==="
    cat > "${SRC_DIR}/winmain_shim.c" << 'WINMAIN_EOF'
/* WinMain shim for conda-forge MinGW console applications
 * conda-forge MinGW defaults to GUI CRT (crtexewin.o) which expects WinMain.
 * This shim provides WinMain that calls main() for console applications.
 */
#ifdef _WIN32
#include <windows.h>
#include <stdlib.h>

extern int main(int argc, char **argv);

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow) {
    (void)hInstance; (void)hPrevInstance; (void)lpCmdLine; (void)nCmdShow;
    return main(__argc, __argv);
}
#endif
WINMAIN_EOF

    # Compile the shim
    "${CC}" -c -o "${_SRC_DIR_}/winmain_shim.o" "${_SRC_DIR_}/winmain_shim.c"
    if [[ -f "${_SRC_DIR_}/winmain_shim.o" ]]; then
      echo "Successfully compiled winmain_shim.o"

      # Add to NATIVECCLIBS so it's linked with all native executables
      if grep -q "^NATIVECCLIBS=" "${config_file}"; then
        sed -i "s|^NATIVECCLIBS=\(.*\)|NATIVECCLIBS=\1 ${_SRC_DIR_}/winmain_shim.o|" "${config_file}"
      else
        echo "NATIVECCLIBS=${_SRC_DIR_}/winmain_shim.o" >> "${config_file}"
      fi

      # Also add to BYTECCLIBS for bytecode runtime (ocamlrun.exe)
      if grep -q "^BYTECCLIBS=" "${config_file}"; then
        sed -i "s|^BYTECCLIBS=\(.*\)|BYTECCLIBS=${_SRC_DIR_}/winmain_shim.o \1|" "${config_file}"
      else
        echo "BYTECCLIBS=${_SRC_DIR_}/winmain_shim.o" >> "${config_file}"
      fi
    else
      echo "ERROR: Failed to compile winmain_shim.o"
      exit 1
    fi

    # Keep using flexlink for FlexDLL support
    sed -i 's|^MKEXE=.*|MKEXE=flexlink -exe -chain mingw64|' "${config_file}"
    sed -i 's|^MKDLL=.*|MKDLL=flexlink -chain mingw64|' "${config_file}"
    sed -i 's|^MKMAINDLL=.*|MKMAINDLL=flexlink -maindll -chain mingw64|' "${config_file}"

    echo "=== DEBUG: Makefile.config settings ==="
    grep -E "^MKEXE|^MKDLL|^NATIVECCLIBS|^BYTECCLIBS" "${config_file}" || true
    echo "=== END DEBUG ==="
  fi

  echo "=== Compiling native compiler ==="
  # V=1 shows actual commands being run (helps debug MKEXE issues)
  make V=1 world.opt -j"${CPU_COUNT}" > "${SRC_DIR}"/_logs/world.log 2>&1 || { cat "${SRC_DIR}"/_logs/world.log; exit 1; }

  if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
    echo "=== Running tests ==="
    make ocamltest -j "${CPU_COUNT}" > "${SRC_DIR}"/_logs/ocamltest.log 2>&1 || { cat "${SRC_DIR}"/_logs/ocamltest.log; }
    make tests > "${SRC_DIR}"/_logs/tests.log 2>&1 || { grep -3 'tests failed' "${SRC_DIR}"/_logs/tests.log; }
  fi

  echo "=== Installing native compiler ==="
  make install > "${SRC_DIR}"/_logs/install.log 2>&1 || { cat "${SRC_DIR}"/_logs/install.log; exit 1; }
fi

# ============================================================================
# Cross-compilers
# ============================================================================

source "${RECIPE_DIR}"/building/build-cross-compiler.sh

# ============================================================================
# Post-install fixes (applies to both native and cross-compiled builds)
# ============================================================================

# Fix Makefile.config: replace BUILD_PREFIX paths with PREFIX
if [[ -f "${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config" ]]; then
  sed -i "s#${BUILD_PREFIX}#${PREFIX}#g" "${OCAML_INSTALL_PREFIX}/lib/ocaml/Makefile.config"
fi

# non-Unix: replace symlinks with copies
if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  for bin in "${OCAML_INSTALL_PREFIX}"/bin/*; do
    if [[ -L "$bin" ]]; then
      target=$(readlink "$bin")
      rm "$bin"
      cp "${OCAML_INSTALL_PREFIX}/bin/${target}" "$bin"
    fi
  done
fi

# Fix bytecode wrapper shebangs (source function)
source "${RECIPE_DIR}/building/fix-ocamlrun-shebang.sh"
for bin in "${OCAML_INSTALL_PREFIX}"/bin/* "${OCAML_INSTALL_PREFIX}"/lib/ocaml-cross-compilers/*/bin/*; do
  [[ -f "$bin" ]] || continue
  [[ -L "$bin" ]] && continue

  # Check for ocamlrun reference (need 350 bytes for long conda placeholder paths)
  if head -c 350 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
    if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
      fix_ocamlrun_shebang "$bin" "${SRC_DIR}"/_logs/shebang.log 2>&1 || { cat "${SRC_DIR}"/_logs/shebang.log; exit 1; }
    fi
    continue
  fi

  # Pure shell scripts: fix exec statements
  if file "$bin" 2>/dev/null | grep -qE "shell script|POSIX shell|text"; then
    sed -i "s#exec '\([^']*\)'#exec \1#" "$bin"
    sed -i "s#exec ${OCAML_INSTALL_PREFIX}/bin#exec \$(dirname \"\$0\")#" "$bin"
  fi
done

# Install activation scripts with build-time tool substitution
# Use basenames so scripts work regardless of install location
_BUILD_CC=$(basename "${CC}")
_BUILD_AS=$(basename "${AS}")
_BUILD_AR=$(basename "${AR}")
_BUILD_RANLIB=$(basename "${RANLIB}")

for CHANGE in "activate" "deactivate"; do
  mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
  _SCRIPT="${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
  cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${_SCRIPT}" 2>/dev/null || continue
  # Replace @XX@ placeholders with actual build-time tools
  sed -i "s|@CC@|${_BUILD_CC}|g" "${_SCRIPT}"
  sed -i "s|@AS@|${_BUILD_AS}|g" "${_SCRIPT}"
  sed -i "s|@AR@|${_BUILD_AR}|g" "${_SCRIPT}"
  sed -i "s|@RANLIB@|${_BUILD_RANLIB}|g" "${_SCRIPT}"
done
