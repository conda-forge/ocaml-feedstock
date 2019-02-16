#!/bin/bash
export CC=$(basename "$CC")
export AS=$(basename "$AS")
export OCAML_PREFIX=$PREFIX
export OCAMLLIB=$PREFIX/lib/ocaml

sed -i.bak "s@common_cflags=\"\-O@common_cflags=\"${CFLAGS} \-O@g" configure
sed -i.bak "s@common_cppflags=\"\"@commond_cppflags=\"${CPPFLAGS}\"@g" configure
sed -i.bak "s@ldflags=\"\"@ldflags=\"${LDFLAGS}\"@g" configure

bash -x ./configure -prefix $OCAML_PREFIX -cc $CC -aspp "$CC -c" -as "$AS"
make world.opt -j${CPU_COUNT}
make tests
make install

for CHANGE in "activate" "deactivate"
do
    mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
    cp "${RECIPE_DIR}/${CHANGE}.sh" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.sh"
done
