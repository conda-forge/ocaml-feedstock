export _OCAML_OCAMLLIB_CONDA_BACKUP=${OCAMLLIB:-}
export _OCAML_OCAML_PREFIX_CONDA_BACKUP=${OCAML_PREFIX:-}

export OCAMLLIB=$CONDA_PREFIX/lib/ocaml
export OCAML_PREFIX=$CONDA_PREFIX

sed -i "2s#/opt/ocaml1ocaml2ocaml3#${CONDA_PREFIX}#" ${CONDA_PREFIX}/lib/ocaml/runtime-launch-info
