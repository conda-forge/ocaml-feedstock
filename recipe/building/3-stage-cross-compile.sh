LOG_DIR="${SRC_DIR}/build_logs"
mkdir -p "${LOG_DIR}"

run_logged() {
  local logname="$1"
  shift
  local logfile="${LOG_DIR}/${logname}.log"

  echo "Running: $*"
  if "$@" >> "${logfile}" 2>&1; then
    return 0
  else
    local rc=$?
    echo "FAILED (exit code ${rc}) - last 50 lines:"
    tail -50 "${logfile}"
    return ${rc}
  fi
}

_ensure_full_path() {
  local cmd="$1"
  [[ "$cmd" == /* ]] && echo "$cmd" || echo "${BUILD_PREFIX}/bin/${cmd}"
}

apply_cross_patches() {
  # Apply Makefile.cross and platform-specific patches
  cp "${RECIPE_DIR}"/building/Makefile.cross .
  patch -N -p0 < "${RECIPE_DIR}"/building/tmp_Makefile.patch || true
  if [[ "${_NEEDS_DL}" == "1" ]]; then
    perl -i -pe 's/^(BYTECCLIBS=.*)$/$1 -ldl/' Makefile.config
  fi
}

# ============================================================================
# Platform configuration
# ============================================================================
echo "Cross-compiling: ${build_platform} -> ${target_platform}"

# Ensure CC_FOR_BUILD is set (conda-forge should set this for cross-compilation)
if [[ -z "${CC_FOR_BUILD:-}" ]]; then
  CC_FOR_BUILD="${BUILD_PREFIX}/bin/${build_alias}-cc"
  # macOS may not have -cc symlink, try -clang
  if [[ ! -x "${CC_FOR_BUILD}" ]]; then
    CC_FOR_BUILD="${BUILD_PREFIX}/bin/${build_alias}-clang"
  fi
  echo "WARNING: CC_FOR_BUILD not set, using: ${CC_FOR_BUILD}"
fi

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
# Save original environment & resolve cross-compiler paths
# ============================================================================
_build_alias="$build_alias"
_host_alias="$host_alias"
_OCAML_PREFIX="${OCAML_INSTALL_PREFIX}"

# TARGET cross-compiler (for building target code)
# macOS clang cross-compilers may not have -cc symlink, only -clang
_CC="${CC}"
if [[ ! -x "${_CC}" ]] && [[ "${_CC}" == *"-cc" ]]; then
  _CC_FALLBACK="${_CC%-cc}-clang"
  if [[ -x "${_CC_FALLBACK}" ]]; then
    echo "NOTE: ${_CC} not found, using ${_CC_FALLBACK}"
    _CC="${_CC_FALLBACK}"
  fi
fi
_AR="${AR}"
_RANLIB="${_AR%-ar}-ranlib"
_CFLAGS="${CFLAGS:-}"
_LDFLAGS="${LDFLAGS:-}"
if [[ "${_PLATFORM_TYPE}" == "linux" ]]; then
  _AS="${AS}"
fi

# Platform-specific LDFLAGS for target
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  _LDFLAGS="-fuse-ld=lld -Wl,-headerpad_max_install_names ${_LDFLAGS}"
fi

# ============================================================================
# BUILD platform toolchain (for Stage 1 native build and cross-compiler runtime)
# ============================================================================
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  # macOS: MUST use LLVM tools (GNU ar format incompatible with ld64)
  # MUST include -L${BUILD_PREFIX}/lib -lzstd to find x86_64 zstd (not arm64 from $PREFIX)
  _BUILD_AR="${BUILD_PREFIX}/bin/llvm-ar"
  _BUILD_RANLIB="${BUILD_PREFIX}/bin/llvm-ranlib"
  _BUILD_NM="${BUILD_PREFIX}/bin/llvm-nm"
  _BUILD_CFLAGS="-march=core2 -mtune=haswell -mssse3 -I${BUILD_PREFIX}/include"
  _BUILD_LDFLAGS="-fuse-ld=lld -L${BUILD_PREFIX}/lib -lzstd -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
  _CROSS_AS="${_CC}"  # macOS: clang integrated assembler for cross
else
  _BUILD_AR="${BUILD_PREFIX}/bin/${_build_alias}-ar"
  _BUILD_RANLIB="${BUILD_PREFIX}/bin/${_build_alias}-ranlib"
  _BUILD_NM="${BUILD_PREFIX}/bin/${_build_alias}-nm"
  _BUILD_CFLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -I${BUILD_PREFIX}/include"
  _BUILD_LDFLAGS="-L${BUILD_PREFIX}/lib -lzstd -Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections"
  _CROSS_AS="${_AS}"  # Linux: binutils assembler for cross
fi

# ============================================================================
# Clear cross-compilation environment for Stage 1
# ============================================================================
unset build_alias host_alias HOST TARGET_ARCH
# CRITICAL: Unset CFLAGS/LDFLAGS - conda-build sets these with -L$PREFIX/lib
# which causes the linker to find arm64 libraries instead of x86_64
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
fi

# ============================================================================
# STAGE 1: Build native x86_64 compiler
# ============================================================================
echo ""
echo "=== Stage 1: Building native x86_64 OCaml compiler ==="
export OCAML_PREFIX=${SRC_DIR}/_native && mkdir -p ${SRC_DIR}/_native
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# CRITICAL: Override PKG_CONFIG_PATH to find x86_64 zstd in BUILD_PREFIX
# Without this, pkg-config might find target-arch zstd from $PREFIX causing linker errors
export PKG_CONFIG_PATH="${BUILD_PREFIX}/lib/pkgconfig:${BUILD_PREFIX}/share/pkgconfig"
export LIBRARY_PATH="${BUILD_PREFIX}/lib:${LIBRARY_PATH:-}"

if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  export DYLD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
else
  export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
fi

# Common configure args (used in all stages)
CONFIG_ARGS=(--enable-shared --disable-static --mandir=${OCAML_PREFIX}/share/man)

# Stage 1 uses BUILD toolchain
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  # macOS: use simple flags matching proven build-arm64.sh
  _STAGE1_LDFLAGS="${_BUILD_LDFLAGS}"
else
  # Linux: add rpath for finding libraries at runtime
  _STAGE1_LDFLAGS="${_BUILD_LDFLAGS} -Wl,-rpath,${OCAML_PREFIX}/lib -Wl,-rpath,${BUILD_PREFIX}/lib -Wl,-rpath-link,${OCAML_PREFIX}/lib"
fi

# Stage 1 configure args - use only build-specific flags, not target CFLAGS
_STAGE1_CFLAGS="${_BUILD_CFLAGS}"

_CONFIG_ARGS=(
  --build="$_build_alias" --host="$_build_alias"
  AR="${_BUILD_AR}" AS="$_build_alias-as" ASPP="${CC_FOR_BUILD} -c"
  CC="${CC_FOR_BUILD}" RANLIB="${_BUILD_RANLIB}" STRIP="$_build_alias-strip"
  CFLAGS="${_STAGE1_CFLAGS}" LDFLAGS="${_STAGE1_LDFLAGS}"
)
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  _CONFIG_ARGS+=(CPP="$_build_alias-clang-cpp" LD="$_build_alias-ld" LIPO="$_build_alias-lipo" NM="${_BUILD_NM}" NMEDIT="$_build_alias-nmedit" OTOOL="$_build_alias-otool")
else
  _CONFIG_ARGS+=(LD="$_build_alias-ld" NM="${_BUILD_NM}")
fi

# PKG_CONFIG=false forces simple "-lzstd" instead of "-L/long/path -lzstd"
PKG_CONFIG=false run_logged "stage1_configure" ./configure -prefix="${OCAML_PREFIX}" "${CONFIG_ARGS[@]}" "${_CONFIG_ARGS[@]}" --target="$_build_alias"
run_logged "stage1_world" make world.opt -j${CPU_COUNT}
run_logged "stage1_install" make install

cp runtime/build_config.h "${SRC_DIR}"
run_logged "stage1_distclean" make distclean

# ============================================================================
# STAGE 2: Build cross-compiler (runs on x86_64, emits target code)
# ============================================================================
echo ""
echo "=== Stage 2: Building cross-compiler (x86_64 -> ${_host_alias}) ==="
_PATH="${PATH}"
export PATH="${SRC_DIR}/_native/bin:${_PATH}"
export OCAMLLIB=${SRC_DIR}/_native/lib/ocaml
export OCAML_PREFIX=${SRC_DIR}/_cross

PKG_CONFIG=false run_logged "stage2_configure" ./configure -prefix="${OCAML_PREFIX}" "${CONFIG_ARGS[@]}" "${_CONFIG_ARGS[@]}" --target="$_host_alias" ${_GETENTROPY_ARGS[@]+"${_GETENTROPY_ARGS[@]}"}

# Patch utils/config.generated.ml for cross-compilation (hardcoded paths for cross-compiler)
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  export _TARGET_ASM="${_CC} -c"
  export _MKDLL="${_CC} -shared -undefined dynamic_lookup -L."
  export _MKEXE="${_CC} ${_LDFLAGS}"
else
  export _TARGET_ASM="${_AS}"
  export _MKDLL="${_CC} -shared -L."
  export _MKEXE="${_CC} -Wl,-E ${_LDFLAGS}"
fi
export _CC_TARGET="${_CC}"

perl -i -pe 's/^let asm = .*/let asm = {|$ENV{_TARGET_ASM}|}/' utils/config.generated.ml
perl -i -pe 's/^let mkdll = .*/let mkdll = {|$ENV{_MKDLL}|}/' utils/config.generated.ml
perl -i -pe 's/^let mkmaindll = .*/let mkmaindll = {|$ENV{_MKDLL}|}/' utils/config.generated.ml
perl -i -pe 's/^let c_compiler = .*/let c_compiler = {|$ENV{_CC_TARGET}|}/' utils/config.generated.ml
perl -i -pe 's/^let mkexe = .*/let mkexe = {|$ENV{_MKEXE}|}/' utils/config.generated.ml
if [[ "${_NEEDS_DL}" == "1" ]]; then
  perl -i -pe 's/^let native_c_libraries = \{\|(.*)\|\}/let native_c_libraries = {|$1 -ldl|}/' utils/config.generated.ml
fi
if [[ -n "${_MODEL:-}" ]]; then
  perl -i -pe "s/^let model = .*/let model = {|${_MODEL}|}/" utils/config.generated.ml
fi

apply_cross_patches

# Setup cross-ocamlmklib wrapper
chmod +x "${RECIPE_DIR}"/building/cross-ocamlmklib.sh
export CROSS_CC="${_CC}"
export CROSS_AR="${_AR}"
_CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"

# Build cross-compiler
_STAGE2_CROSSOPT_ARGS=(
  ARCH="${_TARGET_ARCH}" AS="${_CROSS_AS}" ASPP="${_CC} -c"
  CC="${_CC}" CROSS_CC="${_CC}" CROSS_AR="${_AR}" CROSS_MKLIB="${_CROSS_MKLIB}"
  CAMLOPT=ocamlopt CFLAGS="${_CFLAGS}"
  SAK_AR="${_BUILD_AR}" SAK_CC="${CC_FOR_BUILD}" SAK_CFLAGS="${_BUILD_CFLAGS}"
  ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd"
)
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  _STAGE2_CROSSOPT_ARGS+=(SAK_LDFLAGS="-fuse-ld=lld")
else
  _STAGE2_CROSSOPT_ARGS+=(CPPFLAGS="-D_DEFAULT_SOURCE" SAK_LINK="${CC_FOR_BUILD} \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)")
fi

run_logged "stage2_crossopt" make crossopt "${_STAGE2_CROSSOPT_ARGS[@]}" -j${CPU_COUNT}
run_logged "stage2_installcross" make installcross
run_logged "stage2_distclean" make distclean

# ============================================================================
# STAGE 3: Cross-compile final binaries for target architecture
# ============================================================================
echo ""
echo "=== Stage 3: Cross-compiling final binaries for ${_host_alias} ==="

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"
export CROSS_CC="${_CC}"
export CROSS_AR="${_AR}"

# Save cross-compiler path BEFORE changing OCAML_PREFIX
_CROSS_OCAMLOPT="${OCAML_PREFIX}/bin/ocamlopt"

# CRITICAL: _native/bin MUST come before _cross/bin (OCAML_PREFIX)
# - _native/bin has build-arch ocamlyacc, ocamlrun, ocamllex that run on BUILD machine
# - _cross/bin has cross-compiled ocamlyacc that was built for TARGET (won't run on BUILD)
# CROSS_OVERRIDES sets OCAMLYACC=ocamlyacc, which looks up PATH - must find native version
export PATH="${BUILD_PREFIX}/bin:${SRC_DIR}/_native/bin:${OCAML_PREFIX}/bin:${_PATH}"
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml
export OCAML_PREFIX="${_OCAML_PREFIX}"

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

PKG_CONFIG=false run_logged "stage3_configure" ./configure -prefix="${OCAML_PREFIX}" "${CONFIG_ARGS[@]}" "${_CONFIG_ARGS[@]}" ${_GETENTROPY_ARGS[@]+"${_GETENTROPY_ARGS[@]}"}

# Patch config.generated.ml for RUNTIME paths (uses $CC/$AS env vars for relocatable binaries)
config_file="utils/config.generated.ml"
if [[ "${_PLATFORM_TYPE}" == "linux" ]]; then
  sed -i 's/^let ar = .*/let ar = {|\$AR|}/' "$config_file"
fi

apply_cross_patches
if [[ "${_NEEDS_DL}" == "1" ]]; then
  sed -i 's/^\(NATIVECCLIBS=.*\)$/\1 -ldl/' Makefile.config
fi

sed -i 's/^let asm = .*/let asm = {|\$AS|}/' "$config_file"
sed -i 's/^let c_compiler = .*/let c_compiler = {|\$CC|}/' "$config_file"

if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  sed -i 's/^let mkdll = .*/let mkdll = {|\$CC -shared -undefined dynamic_lookup|}/' "$config_file"
  sed -i 's/^let mkmaindll = .*/let mkmaindll = {|\$CC -shared -undefined dynamic_lookup|}/' "$config_file"
  sed -i 's/^let mkexe = .*/let mkexe = {|\$CC|}/' "$config_file"
else
  sed -i 's/^let mkdll = .*/let mkdll = {|\$CC -shared|}/' "$config_file"
  sed -i 's/^let mkmaindll = .*/let mkmaindll = {|\$CC -shared|}/' "$config_file"
  sed -i 's/^let mkexe = .*/let mkexe = {|\$CC|}/' "$config_file"
  sed -i 's/^let native_c_libraries = {|\(.*\)|}/let native_c_libraries = {|\1 -ldl|}/' "$config_file"
fi
if [[ -n "${_MODEL:-}" ]]; then
  sed -i "s/^let model = .*/let model = {|${_MODEL}|}/" "$config_file"
fi

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
  LIBDIR="${OCAML_PREFIX}/lib/ocaml"
)
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  _STAGE3_CROSSCOMPILEDOPT_ARGS+=(LDFLAGS="${_LDFLAGS}" SAK_LDFLAGS="-fuse-ld=lld")
else
  _STAGE3_CROSSCOMPILEDOPT_ARGS+=(CPPFLAGS="-D_DEFAULT_SOURCE")
fi

run_logged "stage3_crosscompiledopt" make crosscompiledopt "${_STAGE3_CROSSCOMPILEDOPT_ARGS[@]}" -j${CPU_COUNT}

# Fix build_config.h paths for target
#sed "s#${BUILD_PREFIX}/lib/ocaml#${PREFIX}/lib/ocaml#g" "${SRC_DIR}"/build_config.h > runtime/build_config.h
sed -i "s#${BUILD_PREFIX}/lib/ocaml#${PREFIX}/lib/ocaml#g"  runtime/build_config.h
sed -i "s#${_build_alias}#${_host_alias}#g" runtime/build_config.h

# Build runtime
# LIBDIR must be set explicitly - it defines OCAML_STDLIB_DIR in runtime/dynlink.c
_STAGE3_CROSSCOMPILEDRUNTIME_ARGS=(
  "${_CROSS_MAKE_ARGS[@]}"
  CHECKSTACK_CC="${CC_FOR_BUILD}"
  SAK_AR="${_BUILD_AR}" SAK_CC="${CC_FOR_BUILD}" SAK_CFLAGS="${_BUILD_CFLAGS}"
  ZSTD_LIBS="-L${PREFIX}/lib -lzstd"
  LIBDIR="${OCAML_PREFIX}/lib/ocaml"
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

make crosscompiledruntime "${_STAGE3_CROSSCOMPILEDRUNTIME_ARGS[@]}" -j${CPU_COUNT}
make installcross

# ============================================================================
# Post-install fixes
# ============================================================================
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  # Fix install names for shared libraries
  # 1. Set correct install_name for runtime libraries
  if [[ -f "${OCAML_PREFIX}/lib/ocaml/libasmrun_shared.so" ]]; then
    install_name_tool -id "@rpath/libasmrun_shared.so" "${OCAML_PREFIX}/lib/ocaml/libasmrun_shared.so"
  fi
  if [[ -f "${OCAML_PREFIX}/lib/ocaml/libcamlrun_shared.so" ]]; then
    install_name_tool -id "@rpath/libcamlrun_shared.so" "${OCAML_PREFIX}/lib/ocaml/libcamlrun_shared.so"
  fi

  # 2. Fix references in ALL libraries (runtime libs + stublibs)
  for lib in "${OCAML_PREFIX}/lib/ocaml/"*.so "${OCAML_PREFIX}/lib/ocaml/stublibs/"*.so; do
    [[ -f "$lib" ]] || continue

    # Fix build-time paths to @rpath
    install_name_tool -change "runtime/libasmrun_shared.so" "@rpath/libasmrun_shared.so" "$lib" 2>/dev/null || true
    install_name_tool -change "runtime/libcamlrun_shared.so" "@rpath/libcamlrun_shared.so" "$lib" 2>/dev/null || true

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
for bin in "${OCAML_PREFIX}"/bin/*; do
  [[ -f "$bin" ]] || continue
  [[ -L "$bin" ]] && continue

  # Check for ocamlrun reference (need 350 bytes for long conda placeholder paths)
  if head -c 350 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
    if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
      fix_ocamlrun_shebang "$bin" 2>/dev/null
    fi
    continue
  fi

  # Pure shell scripts: fix exec statements
  if file "$bin" 2>/dev/null | grep -qE "shell script|POSIX shell|text"; then
    sed -i "s#exec '\([^']*\)'#exec \1#" "$bin"
    sed -i "s#exec ${OCAML_PREFIX}/bin#exec \$(dirname \"\$0\")#" "$bin"
  fi
done

echo "Cross-compilation complete for ${_host_alias}"
