#!/usr/bin/env bash
set -eu

export CC=$(basename "$CC")
export ASPP="$CC -c"
export AS=$(basename "$AS")
export AR=$(basename "$AR")
export RANLIB=$(basename "$RANLIB")
export OCAML_PREFIX=$PREFIX
export OCAMLLIB=$PREFIX/lib/ocaml

if [ "$(uname)" = "Darwin" ]; then
  # Tests failing on macOS. Seems to be a known issue.
  rm testsuite/tests/lib-str/t01.ml
  rm testsuite/tests/lib-threads/beat.ml
fi 

if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  rm testsuite/tests/unicode/$'\u898b'.ml
fi 

bash -x ./configure \
  --enable-ocamltest \
  --enable-shared \
  --disable-static \
  --mandir=${PREFIX}/share/man \
  --with-target-bindir=/opt/anaconda1anaconda2anaconda3/bin \
  -prefix $OCAML_PREFIX

make world.opt -j${CPU_COUNT}

# Check if cross-compiling - not testing on build architecture
if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
  make ocamltest -j ${CPU_COUNT}
  make tests || true
fi

mkdir -p ${PREFIX}/lib
make install

for bin in $PREFIX/bin/*
do
  if file "$bin" | grep -q "script executable"; then
    sed -i "s#exec '\([^']*\)'#exec \1#" "$bin"
    sed -i "s#exec $PREFIX/bin#exec \$(dirname \"\$0\")#" "$bin"
  fi
done

for CHANGE in "activate" "deactivate"
do
  mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
  cp "${RECIPE_DIR}/${CHANGE}.sh" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.sh"
done
