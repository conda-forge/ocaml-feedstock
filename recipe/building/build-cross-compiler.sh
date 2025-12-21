#!/usr/bin/env bash
set -eu

# Unified cross-compilation script for OCaml feedstock
# Supports: osx-arm64, linux-aarch64, linux-ppc64le
#
#   Stage 2: Build cross-compiler (runs on BUILD, produces TARGET code)

echo ""
echo "=== Stage 2: Building cross-compiler (x86_64 -> ${_host_alias}) ==="
_PATH="${PATH}"
export PATH="${BUILD_PREFIX}/bin:${_PATH}"
export OCAMLLIB=${BUILD_PREFIX}/lib/ocaml
export OCAML_PREFIX=${SRC_DIR}/_cross

if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  export PKG_CONFIG_PATH="${BUILD_PREFIX}/lib/pkgconfig:${BUILD_PREFIX}/share/pkgconfig"
  export DYLD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
fi

_STAGE1_CFLAGS="${_BUILD_CFLAGS}"

if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  # macOS: use simple flags matching proven build-arm64.sh
  _STAGE1_LDFLAGS="${_BUILD_LDFLAGS}"
else
  # Linux: add rpath for finding libraries at runtime
  _STAGE1_LDFLAGS="${_BUILD_LDFLAGS} -Wl,-rpath,${OCAML_PREFIX}/lib -Wl,-rpath,${BUILD_PREFIX}/lib -Wl,-rpath-link,${OCAML_PREFIX}/lib"
fi

_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_build_alias"
  AR="$_build_alias-ar"
  AS="$_build_alias-as"
  ASPP="${CC_FOR_BUILD} -c"
  CC="${CC_FOR_BUILD}"
  LD="$_build_alias-ld"
  NM="$_build_alias-nm"
  RANLIB="$_build_alias-ranlib"
  STRIP="$_build_alias-strip"
  CFLAGS="${_STAGE1_CFLAGS}" LDFLAGS="${_STAGE1_LDFLAGS}"
)

if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  _CONFIG_ARGS+=(CPP="$_build_alias-clang-cpp" LIPO="$_build_alias-lipo" NMEDIT="$_build_alias-nmedit" OTOOL="$_build_alias-otool")
fi

run_logged "stage2_configure" ./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}" \
  --target="$_host_alias" \
  ${_GETENTROPY_ARGS[@]+"${_GETENTROPY_ARGS[@]}"} || { cat config.log; exit 1; }

# Patch utils/config.generated.ml for cross-compilation (hardcoded paths for cross-compiler)
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  _TARGET_ASM="${_CC} -c"
  _MKDLL="${_CC} -shared -undefined dynamic_lookup -L."
  _MKEXE="${_CC} ${_LDFLAGS}"
else
  _TARGET_ASM="${_AS}"
  _MKDLL="${_CC} -shared -L."
  _MKEXE="${_CC} -Wl,-E ${_LDFLAGS}"
fi

config_file="utils/config.generated.ml"
sed -i "s#^let asm = .*#let asm = {|${_TARGET_ASM}|}#" "$config_file"
sed -i "s#^let mkdll = .*#let mkdll = {|${_MKDLL}|}#" "$config_file"
sed -i "s#^let mkmaindll = .*#let mkmaindll = {|${_MKDLL}|}#" "$config_file"
sed -i "s#^let c_compiler = .*#let c_compiler = {|${_CC}|}#" "$config_file"
sed -i "s#^let mkexe = .*#let mkexe = {|${_MKEXE}|}#" "$config_file"
if [[ "${_NEEDS_DL}" == "1" ]]; then
  sed -i 's#^let native_c_libraries = {|\(.*\)|}#let native_c_libraries = {|\1 -ldl|}#' "$config_file"
fi
if [[ -n "${_MODEL:-}" ]]; then
  sed -i "s#^let model = .*#let model = {|${_MODEL}|}#" "$config_file"
fi

apply_cross_patches

# Setup cross-ocamlmklib wrapper
chmod +x "${RECIPE_DIR}"/building/cross-ocamlmklib.sh
export CROSS_CC="${_CC}"
export CROSS_AR="${_AR}"
_CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"

# Build cross-compiler
_STAGE2_CROSSOPT_ARGS=(
  ARCH="${_TARGET_ARCH}"
  AS="${_CROSS_AS}"
  ASPP="${_CC} -c"
  CC="${_CC}"
  CROSS_CC="${_CC}"
  CROSS_AR="${_AR}"
  CROSS_MKLIB="${_CROSS_MKLIB}"
  CAMLOPT=ocamlopt
  CFLAGS="${_CFLAGS}"
  SAK_CC="${CC_FOR_BUILD}"
  SAK_CFLAGS="${_BUILD_CFLAGS}"
  ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd"
)
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  _STAGE2_CROSSOPT_ARGS+=(SAK_LDFLAGS="-fuse-ld=lld")
else
  _STAGE2_CROSSOPT_ARGS+=(CPPFLAGS="-D_DEFAULT_SOURCE" SAK_LINK="${CC_FOR_BUILD} \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)")
fi

run_logged "stage2_crossopt" make crossopt "${_STAGE2_CROSSOPT_ARGS[@]}" -j${CPU_COUNT}
run_logged "stage2_installcross" make installcross
