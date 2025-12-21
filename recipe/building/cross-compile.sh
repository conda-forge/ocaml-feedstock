#!/usr/bin/env bash
set -eu

# Unified cross-compilation script for OCaml feedstock
# Supports: osx-arm64, linux-aarch64, linux-ppc64le
#
# 3-Stage Cross-Compilation:
#   Stage 1: Build native x86_64 compiler (runs on BUILD, produces BUILD code)
#   Stage 2: Build cross-compiler (runs on BUILD, produces TARGET code)
#   Stage 3: Cross-compile final binaries (runs on TARGET, produces TARGET binaries)

# ============================================================================
# Utility functions
# ============================================================================
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
_OCAML_PREFIX="${OCAML_PREFIX}"

# TARGET cross-compiler (for building target code)
_CC="${CC}"
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
  # macOS: MUST use -fuse-ld=lld for ld64/LLVM ar compatibility
  # MUST include -L${BUILD_PREFIX}/lib -lzstd to find x86_64 zstd (not arm64 from $PREFIX)
  _BUILD_CFLAGS="-march=core2 -mtune=haswell -mssse3 -I${BUILD_PREFIX}/include"
  _BUILD_LDFLAGS="-fuse-ld=lld -L${BUILD_PREFIX}/lib -lzstd -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
  _CROSS_AS="${_CC}"  # macOS: clang integrated assembler for cross
else
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
# STAGE 2: Build cross-compiler (runs on x86_64, emits target code)
# ============================================================================
source "${RECIPE_DIR}/building/build-cross-compiler.sh"
run_logged "distclean" make distclean

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

export PATH="${BUILD_PREFIX}/bin:${OCAML_PREFIX}/bin:${_PATH}"
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

run_logged "stage3_configure" ./configure -prefix="${OCAML_PREFIX}" "${CONFIG_ARGS[@]}" "${_CONFIG_ARGS[@]}" ${_GETENTROPY_ARGS[@]+"${_GETENTROPY_ARGS[@]}"}

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
_STAGE3_CROSSCOMPILEDOPT_ARGS=(
  "${_CROSS_MAKE_ARGS[@]}"
  ZSTD_LIBS="-L${PREFIX}/lib -lzstd"
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
_STAGE3_CROSSCOMPILEDRUNTIME_ARGS=(
  "${_CROSS_MAKE_ARGS[@]}"
  CHECKSTACK_CC="${CC_FOR_BUILD}"
  SAK_CC="${CC_FOR_BUILD}" SAK_CFLAGS="${_BUILD_CFLAGS}"
  ZSTD_LIBS="-L${PREFIX}/lib -lzstd"
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

run_logged "stage3_crosscompiledruntime" make crosscompiledruntime "${_STAGE3_CROSSCOMPILEDRUNTIME_ARGS[@]}" -j${CPU_COUNT}
run_logged "stage3_installcross" make installcross

# ============================================================================
# Post-install fixes
# ============================================================================
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  # Fix stublib overlinking
  for lib in "${OCAML_PREFIX}/lib/ocaml/stublibs/"*.so; do
    [[ -f "$lib" ]] || continue
    for dep in $(otool -L "$lib" 2>/dev/null | grep '\./dll' | awk '{print $1}'); do
      install_name_tool -change "$dep" "@loader_path/$(basename $dep)" "$lib"
    done
  done

  # Fix install names for shared libraries
  if [[ -f "${OCAML_PREFIX}/lib/ocaml/libasmrun_shared.so" ]]; then
    install_name_tool -id "@rpath/libasmrun_shared.so" "${OCAML_PREFIX}/lib/ocaml/libasmrun_shared.so"
  fi
  if [[ -f "${OCAML_PREFIX}/lib/ocaml/libcamlrun_shared.so" ]]; then
    install_name_tool -id "@rpath/libcamlrun_shared.so" "${OCAML_PREFIX}/lib/ocaml/libcamlrun_shared.so"
  fi

  for lib in "${OCAML_PREFIX}/lib/ocaml/"*.so "${OCAML_PREFIX}/lib/ocaml/stublibs/"*.so; do
    [[ -f "$lib" ]] || continue
    install_name_tool -change "runtime/libasmrun_shared.so" "@rpath/libasmrun_shared.so" "$lib" 2>/dev/null || true
    install_name_tool -change "runtime/libcamlrun_shared.so" "@rpath/libcamlrun_shared.so" "$lib" 2>/dev/null || true
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
      fix_ocamlrun_shebang "$bin" 2>/dev/null || true
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
