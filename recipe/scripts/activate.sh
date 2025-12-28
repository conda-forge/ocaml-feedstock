export _OCAML_OCAMLLIB_CONDA_BACKUP="${OCAMLLIB:-}"
export _OCAML_OCAML_PREFIX_CONDA_BACKUP="${OCAML_PREFIX:-}"

export OCAML_PREFIX="${CONDA_PREFIX}"
export OCAMLLIB="${OCAML_PREFIX}"/lib/ocaml

# OCaml toolchain configuration
# These are used by ocamlopt for assembling and linking native code
# Users can override: CONDA_OCAML_CC=clang ocamlopt ...
export CONDA_OCAML_AS="${CONDA_OCAML_AS:-${AS:-as}}"
export CONDA_OCAML_CC="${CONDA_OCAML_CC:-${CC:-cc}}"
export CONDA_OCAML_AR="${CONDA_OCAML_AR:-${AR:-ar}}"
