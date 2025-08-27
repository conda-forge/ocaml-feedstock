#!/usr/bin/env bash
set -eu

source run-and-log.sh
_log_index=0

_build_alias="$build_alias"
_host_alias="$host_alias"

unset build_alias
unset host_alias
unset HOST TARGET_ARCH

export OCAML_PREFIX=${SRC_DIR}/_native && mkdir -p ${SRC_DIR}/_native
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir=${OCAML_PREFIX}/share/man
)


# --- x86_64 compiler
_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_build_alias"
  AR="$_build_alias-ar"
  AS="$_build_alias-as"
  ASPP="$_build_alias-clang -c"
  CC="$_build_alias-clang"
  CPP="$_build_alias-clang-cpp"
  LD="$_build_alias-ld"
  LIPO="$_build_alias-lipo"
  NM="$_build_alias-nm"
  NMEDIT="$_build_alias-nmedit"
  OTOOL="$_build_alias-otool"
  RANLIB="$_build_alias-ranlib"
  STRIP="$_build_alias-strip"
  CFLAGS="-march=core2 -mtune=haswell -mssse3 ${CFLAGS}"
  LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
)

_TARGET=(
  --target="$_build_alias"
)
run_and_log "configure-x86_64" ./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}" \
  "${_TARGET[@]}"

run_and_log "world-x86_64" make world.opt -j${CPU_COUNT}
run_and_log "install-x86_64" make install

# Save for cross-compiled runtime
cp runtime/build_config.h "${SRC_DIR}"

run_and_log "distclean-x86_64" make distclean


# --- Build cross-compiler
_PATH="${PATH}"
export PATH="${OCAML_PREFIX}/bin:${_PATH}"
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# Set environment for cross-compiler installation
export OCAML_PREFIX=${SRC_DIR}/_cross

_TARGET=(
  --target="$_host_alias"
)
run_and_log "configure-x86_64->arm64" ./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}" \
  "${_TARGET[@]}"

# patch for cross: This is changing in 5.4.0
cp "${RECIPE_DIR}"/Makefile.cross .
patch -p0 < ${RECIPE_DIR}/tmp_Makefile.patch
run_and_log "make-x86_64->arm64" make crossopt -j${CPU_COUNT}
run_and_log "install-x86_64->arm64" make installcross
run_and_log "distclean-x86_64->arm64" make distclean


# --- Cross-compile
export PATH="${OCAML_PREFIX}/bin:${_PATH}"
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# Reset to final install path
export OCAML_PREFIX=$PREFIX

_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_host_alias"
  --target="$_host_alias"
  --with-target-bindir=/opt/anaconda1anaconda2anaconda3/bin
)
run_and_log "configure-arm64" ./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}"

run_and_log "make-arm64" make crosscompiledopt CAMLOPT=ocamlopt -j${CPU_COUNT}

sed 's#$SRC_DIR/_native/lib/ocaml#$PREFIX/lib/ocaml#' "${SRC_DIR}"/build_config.h > runtime/build_config.h
sed -i "s#$_build_alias#$_host_alias#" runtime/build_config.h

echo ".";echo ".";echo ".";echo ".";
cat runtime/build_config.h
echo ".";echo ".";echo ".";echo ".";

run_and_log "make-runtime-arm64" make crosscompiledruntime \
  CAMLOPT=ocamlopt \
  CHECKSTACK_CC="$_build_alias-clang" \
  SAK_CC="$_build_alias-clang" \
  SAK_LINK="$_build_alias-clang \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)" \
  -j${CPU_COUNT}
run_and_log "install-arm64" make installcross

for binary in ${PREFIX}/bin/*; do
  file "$binary"
done
