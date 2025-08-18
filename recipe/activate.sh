export OCAMLLIB=$CONDA_PREFIX/lib/ocaml
export OCAML_PREFIX=$CONDA_PREFIX

head -2 ${CONDA_PREFIX}/lib/ocaml/runtime-launch-info
sed -i "1s#/opt/anaconda1anaconda2anaconda3#${CONDA_PREFIX}#" ${CONDA_PREFIX}/lib/ocaml/runtime-launch-info
head -2 ${CONDA_PREFIX}/lib/ocaml/runtime-launch-info
