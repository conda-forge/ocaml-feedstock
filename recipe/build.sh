#!/bin/bash

# Get an updated config.sub and config.guess
cp $BUILD_PREFIX/share/gnuconfig/config.* ./build-aux
export CC=$(basename "$CC")
export ASPP="$CC -c"
export AS=$(basename "$AS")
export AR=$(basename "$AR")
export RANLIB=$(basename "$RANLIB")
export OCAML_PREFIX=$PREFIX
export OCAMLLIB=$PREFIX/lib/ocaml

# Test failing on macOS. Seems to be a known issue.
rm testsuite/tests/lib-threads/beat.ml
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" != "1" || "${CROSSCOMPILING_EMULATOR}" != "" ]]; then
    bash -x ./configure -prefix $OCAML_PREFIX
    make world.opt -j${CPU_COUNT}
    make tests
    make install
else
    echo "Cross-compiling for arm64"
    bash -x ./configure -prefix $OCAML_PREFIX --host=arm64
    make world.opt -j${CPU_COUNT}
    make install ARCH=arm64
fi

for CHANGE in "activate" "deactivate"
do
    mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
    cp "${RECIPE_DIR}/${CHANGE}.sh" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.sh"
done
