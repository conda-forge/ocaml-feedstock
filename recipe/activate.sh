export OCAMLLIB=$CONDA_PREFIX/lib/ocaml
export OCAML_PREFIX=$CONDA_PREFIX

# We have not found a reliable way to relocate the text+binary file
sed -i "1s#/opt/anaconda1anaconda2anaconda3#${CONDA_PREFIX}#" ${CONDA_PREFIX}/lib/ocaml/runtime-launch-info
