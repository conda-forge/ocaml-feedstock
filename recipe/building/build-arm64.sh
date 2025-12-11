#!/usr/bin/env bash
set -eu

_build_alias="$build_alias"
_host_alias="$host_alias"
_OCAML_PREFIX="${OCAML_PREFIX}"

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
  ASPP="${CC_FOR_BUILD} -c"
  CC="${CC_FOR_BUILD}"
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
./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}" \
  "${_TARGET[@]}"

make world.opt -j${CPU_COUNT}
make install

# Save for cross-compiled runtime
cp runtime/build_config.h "${SRC_DIR}"

make distclean


# --- Build cross-compiler
_PATH="${PATH}"
export PATH="${OCAML_PREFIX}/bin:${_PATH}"
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# Set environment for cross-compiler installation
export OCAML_PREFIX=${SRC_DIR}/_cross

_TARGET=(
  --target="$_host_alias"
)
./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}" \
  "${_TARGET[@]}"

# patch for cross: This is changing in 5.4.0
cp "${RECIPE_DIR}"/building/Makefile.cross .
patch -p0 < ${RECIPE_DIR}/building/tmp_Makefile.patch
make crossopt -j${CPU_COUNT}
make installcross
make distclean


# --- Cross-compile
export PATH="${OCAML_PREFIX}/bin:${_PATH}"
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# Reset to final install path
export OCAML_PREFIX="${_OCAML_PREFIX}"

_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_host_alias"
  --target="$_host_alias"
  --with-target-bindir="${PREFIX}"/bin
)
./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}"

make crosscompiledopt CAMLOPT=ocamlopt -j${CPU_COUNT}

perl -pe 's#\$SRC_DIR/_native/lib/ocaml#\$PREFIX/lib/ocaml#g' "${SRC_DIR}"/build_config.h > runtime/build_config.h
perl -i -pe "s#${_build_alias}#${_host_alias}#g" runtime/build_config.h

echo ".";echo ".";echo ".";echo ".";
cat runtime/build_config.h
echo ".";echo ".";echo ".";echo ".";

make crosscompiledruntime \
  CAMLOPT=ocamlopt \
  CHECKSTACK_CC="${CC_FOR_BUILD}" \
  SAK_CC="${CC_FOR_BUILD}" \
  SAK_LINK="${CC_FOR_BUILD} \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)" \
  -j${CPU_COUNT}
make installcross
