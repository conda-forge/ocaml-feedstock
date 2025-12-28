# Setup logging and common functions
LOG_DIR="${SRC_DIR}/build_logs"
mkdir -p "${LOG_DIR}"

source "${RECIPE_DIR}/building/common-functions.sh"

# ============================================================================
# Platform configuration
# ============================================================================
echo "Cross-compiling: ${build_platform} -> ${target_platform}"

case "${target_platform}" in
  osx-arm64)
    _TARGET_ARCH="arm64"
    _PLATFORM_TYPE="macos"
    _NEEDS_DL=0
    _DISABLE_GETENTROPY=0
    ;;
  linux-aarch64)
    _TARGET_ARCH="arm64"
    _PLATFORM_TYPE="linux"
    _NEEDS_DL=1
    _DISABLE_GETENTROPY=1
    ;;
  linux-ppc64le)
    _TARGET_ARCH="power"
    _PLATFORM_TYPE="linux"
    _NEEDS_DL=1
    _DISABLE_GETENTROPY=1
    _MODEL="ppc64le"
    ;;
  *)
    echo "ERROR: Unsupported cross-compilation target: ${target_platform}"
    exit 1
    ;;
esac

# Getentropy configure arg (used in Stage 2 & 3)
_GETENTROPY_ARGS=()
if [[ "${_DISABLE_GETENTROPY}" == "1" ]]; then
  _GETENTROPY_ARGS=(ac_cv_func_getentropy=no)
fi

CONFIG_ARGS=(--enable-shared --disable-static)

# ============================================================================
# Setup cross-compilation toolchain
# ============================================================================
_build_alias="$build_alias"
_host_alias="$host_alias"

source "${RECIPE_DIR}/building/setup-cross-toolchain.sh"
setup_cross_toolchain "${_PLATFORM_TYPE}"

# ============================================================================
# STAGE 3: Cross-compile final binaries for target architecture
# ============================================================================
echo ""
echo "=== Stage 3: Cross-compiling final binaries for ${_host_alias} ==="

# OCAML_INSTALL_PREFIX already set by build.sh (PREFIX for Unix, PREFIX/Library for Windows)

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"
export CROSS_CC="${_CC}"
export CROSS_AR="${_AR}"

# Cross-compiler wrapper is in BUILD_PREFIX (installed from native OCaml package)
_CROSS_OCAMLOPT="${BUILD_PREFIX}/bin/${_host_alias}-ocamlopt"
_CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"

# CRITICAL: BUILD_PREFIX/bin must come first for native tools (ocamlyacc, ocamlrun, etc.)
# that need to run on the BUILD machine during cross-compilation
export PATH="${BUILD_PREFIX}/bin:${PATH}"

# CRITICAL: Export OCAMLLIB to point to cross-compiler's stdlib
# The native ocamlc (used by CAMLC=ocamlc in Makefile.cross) must see the same stdlib
# as the cross-compiler to prevent "inconsistent assumptions" errors.
# The cross-compiler package now includes both bytecode (.cmo) and native (.cmx) files.
# This matches the approach in archives/cross-compile.sh:277
export OCAMLLIB="${BUILD_PREFIX}/lib/ocaml-cross-compilers/${_host_alias}/lib/ocaml"
echo "DEBUG: OCAMLLIB=${OCAMLLIB}"
ls -la "${OCAMLLIB}/"*.cmo 2>/dev/null | head -5 || echo "WARNING: No .cmo files in OCAMLLIB"

# Stage 3 config targets the host platform
_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_host_alias"
  --target="$_host_alias"
  --with-target-bindir="${PREFIX}"/bin
  AR="${_AR}"
  CC="${_CC}"
  RANLIB="${_RANLIB}"
  CFLAGS="${_CFLAGS}"
  LDFLAGS="${_LDFLAGS}"
)
if [[ "${_PLATFORM_TYPE}" == "linux" ]]; then
  _CONFIG_ARGS+=(AS="${_AS}")
fi

# CRITICAL: Configure with PREFIX (target install location), not OCAML_PREFIX (BUILD_PREFIX)
# We want to install cross-compiled binaries to PREFIX, not overwrite BUILD_PREFIX native tools
# PKG_CONFIG=false forces simple "-lzstd" instead of "-L/long/path -lzstd"
PKG_CONFIG=false run_logged "stage3_configure" ./configure -prefix="${PREFIX}" "${CONFIG_ARGS[@]}" "${_CONFIG_ARGS[@]}" ${_GETENTROPY_ARGS[@]+"${_GETENTROPY_ARGS[@]}"}

# Apply Makefile.cross patches
apply_cross_patches

# Patch Makefile.config for cross-compilation (add -ldl if needed)
source "${RECIPE_DIR}/building/patch-config-generated.sh"
patch_makefile_config "${_PLATFORM_TYPE}"

# Define CONDA_OCAML_* variables during build (used by patched config.generated.ml)
export CONDA_OCAML_AS="${_AS}"
export CONDA_OCAML_CC="${_CC}"
export CONDA_OCAML_AR="${_AR}"
export CONDA_OCAML_MKDLL="${_CC} -shared"

# Patch config.generated.ml to use CONDA_OCAML_* env vars (expanded at runtime)
patch_config_generated "utils/config.generated.ml" "${_PLATFORM_TYPE}" "${_MODEL:-}"

# Common cross-compilation make args (shared between crosscompiledopt and crosscompiledruntime)
_CROSS_MAKE_ARGS=(
  ARCH="${_TARGET_ARCH}"
  CAMLOPT="${_CROSS_OCAMLOPT}"
  AS="${_CROSS_AS}"
  ASPP="${_CC} -c"
  CC="${_CC}"
  CROSS_CC="${_CC}"
  CROSS_AR="${_AR}"
  CROSS_MKLIB="${_CROSS_MKLIB}"
)

# Build compiler and libraries
# LIBDIR defines OCAML_STDLIB_DIR in runtime/dynlink.c
_STAGE3_CROSSCOMPILEDOPT_ARGS=(
  "${_CROSS_MAKE_ARGS[@]}"
  SAK_AR="${_BUILD_AR}" SAK_CC="${CC_FOR_BUILD}" SAK_CFLAGS="${_BUILD_CFLAGS}"
  ZSTD_LIBS="-L${PREFIX}/lib -lzstd"
  LIBDIR="${OCAML_INSTALL_PREFIX}/lib/ocaml"
)
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  _STAGE3_CROSSCOMPILEDOPT_ARGS+=(LDFLAGS="${_LDFLAGS}" SAK_LDFLAGS="-fuse-ld=lld")
else
  _STAGE3_CROSSCOMPILEDOPT_ARGS+=(CPPFLAGS="-D_DEFAULT_SOURCE")
fi

run_logged "stage3_crosscompiledopt" make crosscompiledopt "${_STAGE3_CROSSCOMPILEDOPT_ARGS[@]}" OCAMLLIB="${OCAMLLIB}" -j${CPU_COUNT}

# Fix build_config.h paths for target
sed -i "s#${BUILD_PREFIX}/lib/ocaml#${PREFIX}/lib/ocaml#g"  runtime/build_config.h
sed -i "s#${_build_alias}#${_host_alias}#g" runtime/build_config.h

# Build runtime
# LIBDIR must be set explicitly - it defines OCAML_STDLIB_DIR in runtime/dynlink.c
_STAGE3_CROSSCOMPILEDRUNTIME_ARGS=(
  "${_CROSS_MAKE_ARGS[@]}"
  CHECKSTACK_CC="${CC_FOR_BUILD}"
  SAK_AR="${_BUILD_AR}" SAK_CC="${CC_FOR_BUILD}" SAK_CFLAGS="${_BUILD_CFLAGS}"
  ZSTD_LIBS="-L${PREFIX}/lib -lzstd"
  LIBDIR="${OCAML_INSTALL_PREFIX}/lib/ocaml"
)
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  _STAGE3_CROSSCOMPILEDRUNTIME_ARGS+=(LDFLAGS="${_LDFLAGS}" SAK_LDFLAGS="-fuse-ld=lld")
else
  _STAGE3_CROSSCOMPILEDRUNTIME_ARGS+=(
    CPPFLAGS="-D_DEFAULT_SOURCE"
    BYTECCLIBS="-L${PREFIX}/lib -lm -lpthread -ldl -lzstd"
    NATIVECCLIBS="-L${PREFIX}/lib -lm -ldl -lzstd"
    SAK_LINK="${CC_FOR_BUILD} \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)"
  )
fi

run_logged "stage3_crosscompiledruntime" make crosscompiledruntime "${_STAGE3_CROSSCOMPILEDRUNTIME_ARGS[@]}" OCAMLLIB="${OCAMLLIB}" -j${CPU_COUNT}

# Replace stripdebug with a no-op for cross-compilation
# (stripdebug tries to EXECUTE the target binary to strip it, which won't run on build machine)
echo "Replacing stripdebug with no-op version for cross-compilation..."
rm -f tools/stripdebug tools/stripdebug.ml tools/stripdebug.mli tools/stripdebug.cmi tools/stripdebug.cmo
cp "${RECIPE_DIR}/building/stripdebug-noop.ml" tools/stripdebug.ml
ocamlc -o tools/stripdebug tools/stripdebug.ml
rm -f tools/stripdebug.ml tools/stripdebug.cmi tools/stripdebug.cmo

run_logged "stage3_installcross" make installcross

# ============================================================================
# Post-install fixes
# ============================================================================
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  # Fix stublib overlinking
  for lib in "${OCAML_INSTALL_PREFIX}/lib/ocaml/stublibs/"*.so; do
    [[ -f "$lib" ]] || continue
    for dep in $(otool -L "$lib" 2>/dev/null | grep '\./dll' | awk '{print $1}'); do
      install_name_tool -change "$dep" "@loader_path/$(basename $dep)" "$lib"
    done
  done

  # Fix install names for shared libraries
  # 1. Set correct install_name for runtime libraries
  if [[ -f "${OCAML_INSTALL_PREFIX}/lib/ocaml/libasmrun_shared.so" ]]; then
    install_name_tool -id "@rpath/libasmrun_shared.so" "${OCAML_INSTALL_PREFIX}/lib/ocaml/libasmrun_shared.so"
  fi
  if [[ -f "${OCAML_INSTALL_PREFIX}/lib/ocaml/libcamlrun_shared.so" ]]; then
    install_name_tool -id "@rpath/libcamlrun_shared.so" "${OCAML_INSTALL_PREFIX}/lib/ocaml/libcamlrun_shared.so"
  fi

  # 2. Fix references in ALL libraries (runtime libs + stublibs)
  for lib in "${OCAML_INSTALL_PREFIX}/lib/ocaml/"*.so "${OCAML_INSTALL_PREFIX}/lib/ocaml/stublibs/"*.so; do
    [[ -f "$lib" ]] || continue

    # Fix build-time paths to @rpath
    install_name_tool -change "runtime/libasmrun_shared.so" "@rpath/libasmrun_shared.so" "$lib" 2>/dev/null || true
    install_name_tool -change "runtime/libcamlrun_shared.so" "@rpath/libcamlrun_shared.so" "$lib" 2>/dev/null || true

    # Note: Self-references (library linking to itself) are handled via recipe.yaml allowlist

    # Fix relative paths in stublibs (./dllname.so -> @loader_path/dllname.so)
    if [[ "$lib" == *"/stublibs/"* ]]; then
      for dll in dllthreads.so dllunixbyt.so dllunixnat.so dllcamlstrbyt.so dllcamlstrnat.so dllcamlruntime_eventsbyt.so dllcamlruntime_eventsnat.so; do
        install_name_tool -change "./$dll" "@loader_path/$dll" "$lib" 2>/dev/null || true
      done
    fi
  done
fi

# Fix bytecode wrapper shebangs (source function)
source "${RECIPE_DIR}/building/fix-ocamlrun-shebang.sh"
for bin in "${OCAML_INSTALL_PREFIX}"/bin/*; do
  [[ -f "$bin" ]] || continue
  [[ -L "$bin" ]] && continue

  # Check for ocamlrun reference (need 350 bytes for long conda placeholder paths)
  if head -c 350 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
    if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
      fix_ocamlrun_shebang "$bin" 2>/dev/null || true
    fi
    continue
  fi

  # Pure shell scripts: fix exec statements
  if file "$bin" 2>/dev/null | grep -qE "shell script|POSIX shell|text"; then
    sed -i "s#exec '\([^']*\)'#exec \1#" "$bin"
    sed -i "s#exec ${OCAML_INSTALL_PREFIX}/bin#exec \$(dirname \"\$0\")#" "$bin"
  fi
done

echo "Cross-compilation complete for ${_host_alias}"
