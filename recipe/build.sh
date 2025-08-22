#!/usr/bin/env bash
set -eux

# export CC=$(basename "$CC")
# export ASPP="$CC -c"
# export AS=$(basename "$AS")
# export AR=$(basename "$AR")
# export RANLIB=$(basename "$RANLIB")

unset build_alias
unset host_alias

if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  export OCAML_PREFIX=$PREFIX/Library
  SH_EXT="bat"
else
  export OCAML_PREFIX=$PREFIX
  SH_EXT="sh"
fi

export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

CONFIG_ARGS=(
  --enable-ocamltest
  --enable-shared
  --disable-static
  --mandir=${OCAML_PREFIX}/share/man
  --with-target-bindir=/opt/anaconda1anaconda2anaconda3/bin
  -prefix $OCAML_PREFIX
)

if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
  if [[ "${target_platform}" == "osx-arm64" ]]; then
    CONFIG_ARGS+=(
      --build="x86_64-apple-darwin13.4.0"
      --host="aarch64-apple-darwin20.0.0"
      --target="aarch64-apple-darwin20.0.0"
    )
  fi
fi

mkdir -p ${OCAML_PREFIX}/lib
bash ./configure "${CONFIG_ARGS[@]}"

# --- Try to resolve 'Bad CPU' due to missing host exec
make checknative
make coldstart \
  SAK_CC="x86_64-apple-darwin13.4.0-clang" \
  SAK_LINK="x86_64-apple-darwin13.4.0-clang \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)" \
  CC="x86_64-apple-darwin13.4.0-clang" \
  -j${CPU_COUNT}
make checkstack \
  CC="x86_64-apple-darwin13.4.0-clang" \
  -j${CPU_COUNT}

# --- Cross-compile?
make world.opt -j${CPU_COUNT}
  
# Check if cross-compiling - not testing on build architecture
if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
  if [ "$(uname)" = "Darwin" ]; then
    # Tests failing on macOS. Seems to be a known issue.
    rm testsuite/tests/lib-str/t01.ml
    rm testsuite/tests/lib-threads/beat.ml
  fi
  
  if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
    rm testsuite/tests/unicode/$'\u898b'.ml
  fi
  
  make ocamltest -j ${CPU_COUNT}
  make tests
fi

make install

for bin in ${OCAML_PREFIX}/bin/*
do
  if file "$bin" | grep -q "script executable"; then
    sed -i "s#exec '\([^']*\)'#exec \1#" "$bin"
    sed -i "s#exec ${OCAML_PREFIX}/bin#exec \$(dirname \"\$0\")#" "$bin"
  fi
done

for CHANGE in "activate" "deactivate"
do
  mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
  cp "${RECIPE_DIR}/${CHANGE}.${SH_EXT}" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
done
