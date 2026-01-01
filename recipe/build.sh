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

CONFIG_ARGS=(--enable-shared --disable-static PKG_CONFIG=false)
if [[ "0" == "1" ]]; then
  if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
    EXE=""
    SH_EXT="sh"
  else
    CONFIG_ARGS+=(--with-flexdir="${SRC_DIR}"/flexdll --with-zstd --with-gnu-ld)
    EXE=".exe"
    SH_EXT="bat"
  fi

  (
    OCAML_INSTALL_PREFIX="${SRC_DIR}"/_native && mkdir -p "${OCAML_INSTALL_PREFIX}"
    source "${RECIPE_DIR}"/building/build-native.sh
  )

  (
    OCAML_PREFIX="${SRC_DIR}"/_native
    OCAMLIB="${OCAML_PREFIX}"/lib/ocaml
    
    OCAML_INSTALL_PREFIX="${SRC_DIR}"/_cross && mkdir -p "${OCAML_INSTALL_PREFIX}"
    source "${RECIPE_DIR}"/building/build-cross-compiler-new.sh
  )
  
  exit 0
fi

export OCAML_INSTALL_PREFIX="${PREFIX}"
# Simplify compiler paths to basenames (hardcoded in binaries)
export AR=$(basename "${AR}")
export AS=$(basename "${AS}")
export CC=$(basename "${CC}")
export ASPP="$CC -c"
export RANLIB=$(basename "${RANLIB}")
export LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/Library/lib:${LIBRARY_PATH:-}"

# Define CONDA_OCAML_* variables
export CONDA_OCAML_AR="${AR}"
export CONDA_OCAML_AS="${AS}"
export CONDA_OCAML_CC="${CC}"
export CONDA_OCAML_RANLIB="${RANLIB}"

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
  export CONDA_OCAML_MKEXE="${CC} -fuse-ld=lld -Wl,-headerpad_max_install_names"
  export CONDA_OCAML_MKDLL="${CC} -shared -fuse-ld=lld -Wl,-headerpad_max_install_names -undefined dynamic_lookup"
  EXE=""
  SH_EXT="sh"
elif [[ "${target_platform}" == "linux-"* ]]; then
  export CONDA_OCAML_MKEXE="${CC} -Wl,-E"
  export CONDA_OCAML_MKDLL="${CC} -shared"
  EXE=""
  SH_EXT="sh"
else
  export OCAML_INSTALL_PREFIX="${OCAML_INSTALL_PREFIX}"/Library
  export LDFLAGS="${PREFIX}/Library/lib;${LDFLAGS:-}"
  echo "${LDFLAGS}"
  CONFIG_ARGS+=(
    --with-flexdll
    --with-gnu-ld
    LDFLAGS="${PREFIX}/Library/lib;${LDFLAGS:-}"
  )
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
  ./configure "${CONFIG_ARGS[@]}" LDFLAGS="${LDFLAGS:-}" > "${SRC_DIR}"/_logs/configure.log 2>&1 || { cat "${SRC_DIR}"/_logs/configure.log; exit 1; }
  
  # DEBUG: Show Makefile.build_config (contains BOOTSTRAPPING_FLEXDLL)
  echo "=== DEBUG: Makefile.build_config (CRITICAL - contains BOOTSTRAPPING_FLEXDLL) ==="
  if [[ -f "Makefile.build_config" ]]; then
    cat Makefile*
    cat config.log
  else
    echo "Makefile.build_config NOT FOUND"
  fi
  echo "=== END Makefile.build_config ==="

  # DEBUG: Show Makefile.config BEFORE any patching (matches working build output)
  echo "=== DEBUG: Post-configure Makefile.config (BEFORE patching) ==="
  echo "--- MKEXE/MKDLL/MKMAINDLL settings ---"
  grep -E "^MKEXE|^MKDLL|^MKMAINDLL|^MKEXEDEBUGFLAG" Makefile.config || true
  echo "--- NATIVECCLIBS/BYTECCLIBS settings ---"
  grep -E "^BYTECCLIBS|^NATIVECCLIBS" Makefile.config || true
  echo "--- TOOLCHAIN/FLEXDLL settings ---"
  grep -E "^TOOLCHAIN|^FLEXDLL" Makefile.config || true
  echo "--- CC/AS/AR settings ---"
  grep -E "^CC=|^AS=|^AR=" Makefile.config || true
  echo "=== END DEBUG ==="

  # No-op for unix
  unix_noop_update_toolchain

  # DEBUG: Show Makefile.config AFTER unix_noop_update_toolchain
  echo "=== DEBUG: Post-patching Makefile.config (AFTER unix_noop_update_toolchain) ==="
  echo "--- MKEXE/MKDLL/MKMAINDLL settings ---"
  grep -E "^MKEXE|^MKDLL|^MKMAINDLL|^MKEXEDEBUGFLAG" Makefile.config || true
  echo "--- NATIVECCLIBS/BYTECCLIBS settings ---"
  grep -E "^BYTECCLIBS|^NATIVECCLIBS" Makefile.config || true
  echo "--- TOOLCHAIN/FLEXDLL settings ---"
  grep -E "^TOOLCHAIN|^FLEXDLL" Makefile.config || true
  echo "--- CC/AS/AR settings ---"
  grep -E "^CC=|^AS=|^AR=" Makefile.config || true
  echo "=== END DEBUG ==="

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
    # sed -i 's/^let mkexe = .*/let mkexe = {|%CONDA_OCAML_CC%|}/' "$config_file"
    # sed -i 's/^let mkdll = .*/let mkdll = {|%CONDA_OCAML_MKDLL%|}/' "$config_file"
    # sed -i 's/^let mkmaindll = .*/let mkmaindll = {|%CONDA_OCAML_MKDLL% -maindll|}/' "$config_file"
  fi

  # Remove -L paths and debug-prefix-map from Makefile.config (embedded in ocamlc binary)
  # PREFIX paths can cause truncation issues in binaries - remove them all
  config_file="Makefile.config"
  sed -i 's|-fdebug-prefix-map=[^ ]*||g' "${config_file}"
  sed -i 's|-link\s+-L[^ ]*||g' "${config_file}"  # Remove flexlink's "-link -L..." patterns cleanly
  sed -i 's|-L[^ ]*||g' "${config_file}"        # Remove standalone -L paths from other lines

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
    # Windows: DO NOT override MKEXE - configure sets it correctly with -link -municode
    # (uses wmainCRTStartup entry point, avoids WinMain). The $(addprefix...) is fine
    # when OC_LDFLAGS is empty. We only override MKDLL/MKMAINDLL for flexlink chain.
    echo "=== DEBUG: Windows Makefile.config settings ==="
    grep -E "^MKEXE|^MKDLL|^MKMAINDLL|^OC_LDFLAGS" "${config_file}" || true
    echo "=== END DEBUG ==="
  fi

  # DEBUG: Show config.generated.ml key settings (matches working build output)
  echo "=== DEBUG: config.generated.ml key settings ==="
  grep -E "^let c_compiler|^let mkdll|^let mkexe|^let mkmaindll|^let asm" utils/config.generated.ml || true
  echo "=== END DEBUG ==="

  echo "=== Compiling native compiler ==="
  # V=1 shows actual commands being run (helps debug MKEXE issues)
  if ! make V=1 world.opt -j"${CPU_COUNT}" > "${SRC_DIR}"/_logs/world.log 2>&1; then
    echo "=== BUILD FAILED - Extracting debug info ==="
    echo "--- Last 100 lines of world.log ---"
    tail -100 "${SRC_DIR}"/_logs/world.log
    echo "--- ocamlc.opt.exe link command ---"
    grep -E "ocamlc.opt|ocamlopt.*-o.*ocamlc" "${SRC_DIR}"/_logs/world.log | tail -5 || true
    echo "--- flexlink.opt.exe attempts ---"
    grep -E "flexlink\.opt" "${SRC_DIR}"/_logs/world.log | tail -10 || true
    echo "--- undefined reference errors ---"
    grep -E "undefined reference|undefined symbol" "${SRC_DIR}"/_logs/world.log | head -20 || true
    echo "--- NATIVECCLIBS in link commands ---"
    grep -E "NATIVECCLIBS|lgcc_eh|flexdll_mingw64" "${SRC_DIR}"/_logs/world.log | tail -10 || true
    exit 1
  fi

  # DEBUG: Show flexlink commands from build log (matches working build output)
  echo "=== DEBUG: flexlink commands from build log ==="
  grep -i "flexlink" "${SRC_DIR}"/_logs/world.log | head -30 || true
  echo "=== END DEBUG ==="

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
