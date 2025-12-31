# compiler activation should set CONDA_TOOLCHAIN_BUILD
if [[ -z "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
  echo "ERROR: CONDA_TOOLCHAIN_BUILD not set" && return 1
fi

# Simplify compiler paths to basenames (hardcoded in binaries)
_AR="${CONDA_TOOLCHAIN_BUILD}"-ar"${EXE}"
_AS="${CONDA_TOOLCHAIN_BUILD}"-as"${EXE}"
_CC=$(basename "${CC_FOR_BUILD}")
_ASPP="$CC -c"
_RANLIB="${CONDA_TOOLCHAIN_BUILD}"-ranlib"${EXE}"

if [[ "${target_platform}" == "osx-"* ]]; then
  _AS="${_CC}"
  export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld -Wl,-headerpad_max_install_names"
  export DYLD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
fi

CONFIG_ARGS+=(
  AR="${_AR}"
  AS="${_AS}"
  CC="${_CC}"
  RANLIB="${_RANLIB}"
  MKEXE="${_CC}"
  MKDLL="${_CC} -shared"
)

# Define CONDA_OCAML_* variables
export CONDA_OCAML_AR="${_AR}"
export CONDA_OCAML_AS="${_AS}"
export CONDA_OCAML_CC="${_CC}"
export CONDA_OCAML_RANLIB="${_RANLIB}"
if [[ "${target_platform}" == "linux-"* ]]; then
  export CONDA_OCAML_MKEXE="${_CC} -Wl,-E"
  export CONDA_OCAML_MKDLL="${_CC} -shared"
elif [[ "${target_platform}" == "osx-"* ]]; then
  export CONDA_OCAML_MKEXE="${_CC} -fuse-ld=lld -Wl,-headerpad_max_install_names"
  export CONDA_OCAML_MKDLL="${_CC} -shared -fuse-ld=lld -Wl,-headerpad_max_install_names -undefined dynamic_lookup"
else
  # Windows: Use flexlink for FlexDLL support (needed by OCaml runtime)
  # We override MKEXE to include -link -municode (wmainCRTStartup entry point,
  # avoids WinMain) but remove $(addprefix...) that causes LDFLAGS garbage.
  export CONDA_OCAML_MKEXE="flexlink -exe -chain mingw64"
  export CONDA_OCAML_MKDLL="flexlink -chain mingw64"
fi

CONFIG_ARGS=(--enable-shared)

# Load unix no-op non-unix helpers
source "${RECIPE_DIR}/building/non-unix-utilities.sh"

# No-op for unix
unix_noop_build_toolchain

if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
  CONFIG_ARGS+=(--enable-ocamltest)
fi

echo "=== Configuring native compiler ==="
./configure "${CONFIG_ARGS[@]}" -prefix="${OCAML_INSTALL_PREFIX}" > "${SRC_DIR}"/_logs/configure.log 2>&1 || { cat "${SRC_DIR}"/config.log; exit 1; }

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
    sed -i 's/^(let mk(?:main)?dll = .*_MKDLL)(.*)/\1 -undefined dynamic_lookup\2/' "$config_file"
  fi
else
  # Use environment variable references - users can customize via CONDA_OCAML_*
  sed -i 's/^let asm = .*/let asm = {|%CONDA_OCAML_AS%|}/' "$config_file"
  sed -i 's/^let c_compiler = .*/let c_compiler = {|%CONDA_OCAML_CC%|}/' "$config_file"
  sed -i 's/^let ar = .*/let ar = {|%CONDA_OCAML_AR%|}/' "$config_file"
  sed -i 's/^let ranlib = .*/let ranlib = {|%CONDA_OCAML_RANLIB%|}/' "$config_file"
  sed -i 's/^let mkexe = .*/let mkexe = {|%CONDA_OCAML_CC%|}/' "$config_file"
  sed -i 's/^let mkdll = .*/let mkdll = {|%CONDA_OCAML_MKDLL%|}/' "$config_file"
  sed -i 's/^let mkmaindll = .*/let mkmaindll = {|%CONDA_OCAML_MKDLL% -maindll|}/' "$config_file"
fi
# Remove -L paths from bytecomp_c_libraries (embedded in ocamlc binary)
sed -i 's|-L[^ ]*||g' "$config_file"

# Remove -L paths from Makefile.config (embedded in ocamlc binary)
config_file="Makefile.config"
sed -i 's|-fdebug-prefix-map=[^ ]*||g' "${config_file}"
sed -i 's|-L[^ ]*||g' "${config_file}"

echo "=== Compiling native compiler ==="
make world.opt -j"${CPU_COUNT}" > "${SRC_DIR}"/_logs/world.log 2>&1 || { cat "${SRC_DIR}"/_logs/world.log; exit 1; }

if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
  echo "=== Running tests ==="
  make ocamltest -j "${CPU_COUNT}" > "${SRC_DIR}"/_logs/ocamltest.log 2>&1 || { cat "${SRC_DIR}"/_logs/ocamltest.log; }
  make tests > "${SRC_DIR}"/_logs/tests.log 2>&1 || { grep -3 'tests failed' "${SRC_DIR}"/_logs/tests.log; }
fi

echo "=== Installing native compiler ==="
make install > "${SRC_DIR}"/_logs/install.log 2>&1 || { cat "${SRC_DIR}"/_logs/install.log; exit 1; }

cp runtime/build_config.h "${SRC_DIR}"
make distclean
