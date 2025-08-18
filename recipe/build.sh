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

bash -x ./configure \
  --enable-ocamltest \
  --enable-shared \
  --disable-static \
  --mandir=${PREFIX}/share/man \
  --with-target-bindir=/opt/anaconda1anaconda2anaconda3/bin \
  -prefix $OCAML_PREFIX

make world.opt -j${CPU_COUNT}
# make ocamltest -j ${CPU_COUNT}
mkdir -p ${PREFIX}/lib
# Check if cross-compiling - not testing on build architecture
#if [[ -z ${CONDA_BUILD_CROSS_COMPILATION} ]]; then
#  make tests
#fi

# Patch OCaml to generate relocatable bytecode executables
# Replace hardcoded ocamlrun path with env-based lookup
#find . -name "*.ml" -exec grep -l "Config\.bytecomp_c_compiler\|ocamlrun" {} \; | \
#    xargs sed -i 's|output_string oc ("#!" ^ Config\.standard_runtime)|output_string oc "#!/usr/bin/env ocamlrun"|g'

make install

for bin in $PREFIX/bin/*
do
    if file "$bin" | grep -q "script executable"; then
        # echo "$bin"
        # cat "$bin" | head -2
        sed -i "s#exec '\([^']*\)'#exec \1#" "$bin"
        sed -i "s#exec $PREFIX/bin#exec \$(dirname \"\$0\")#" "$bin"
        cat "$bin" | head -2
    fi
done

# # Fix hardcoded paths in OCaml configuration files and binaries
# find $PREFIX -name "*.cmi" -o -name "*.cmo" -o -name "*.cmx" -o -name "*.cma" -o -name "*.cmxa" | \
#     xargs -I {} sh -c 'if file "{}" | grep -q "text"; then sed -i "s|$BUILD_PREFIX|$PREFIX|g" "{}"; fi'

for CHANGE in "activate" "deactivate"
do
    mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
    cp "${RECIPE_DIR}/${CHANGE}.sh" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.sh"
done
