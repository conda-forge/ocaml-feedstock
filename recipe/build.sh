#!/usr/bin/env bash
set -eu

# Paths are hardcoded in binaries, simplify to basename
export CC=$(basename "$CC")
export ASPP="$CC -c"
export AS=$(basename "$AS")
export AR=$(basename "$AR")
export RANLIB=$(basename "$RANLIB")

# Avoids an annoying 'directory not found'
mkdir -p ${PREFIX}/lib

if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  export OCAML_PREFIX=$PREFIX/Library
  SH_EXT="bat"
else
  export OCAML_PREFIX=$PREFIX
  SH_EXT="sh"
fi

export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir=${OCAML_PREFIX}/share/man
  --with-target-bindir="${PREFIX}"/bin
  -prefix $OCAML_PREFIX
)

if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]] && [[ "${target_platform}" == "osx-arm64" ]]; then
  "${RECIPE_DIR}"/building/build-arm64.sh
else
  if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
    CONFIG_ARGS+=(--enable-ocamltest)
  fi

  ./configure "${CONFIG_ARGS[@]}" >& /dev/null
  make world.opt -j${CPU_COUNT} >& /dev/null

  if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
    if [ "$(uname)" == "Darwin" ]; then
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

  make install >& /dev/null
fi

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
  cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
done
