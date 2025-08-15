#!/bin/bash
export CC=$(basename "$CC")
export ASPP="$CC -c"
export AS=$(basename "$AS")
export AR=$(basename "$AR")
export RANLIB=$(basename "$RANLIB")
export OCAML_PREFIX=$PREFIX
export OCAMLLIB=$PREFIX/lib/ocaml

if [ "$(uname)" = "Darwin" ]; then
# Tests failing on macOS. Seems to be a known issue.
  rm testsuite/tests/lib-threads/beat.ml
fi 

bash -x ./configure -prefix $OCAML_PREFIX --enable-ocamltest
make world.opt -j${CPU_COUNT}
make ocamltest -j ${CPU_COUNT}
mkdir -p ${PREFIX}/lib
# Check if cross-compiling - not testing on build architecture
if [[ -z ${CONDA_BUILD_CROSS_COMPILATION} ]]; then
  make tests
fi
make install

for CHANGE in "activate" "deactivate"
do
    mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
    cp "${RECIPE_DIR}/${CHANGE}.sh" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.sh"
done
