export _OCAML_OCAMLLIB_CONDA_BACKUP="${OCAMLLIB:-}"
export _OCAML_OCAML_PREFIX_CONDA_BACKUP="${OCAML_PREFIX:-}"

export OCAML_PREFIX="${CONDA_PREFIX}"
export OCAMLLIB="${OCAML_PREFIX}"/lib/ocaml

# OCaml toolchain configuration
# These are used by ocamlopt for assembling and linking native code
# @CC@, @AS@, etc. are replaced at build time with actual tools used
# Users can override: CONDA_OCAML_CC=clang ocamlopt ...
export CONDA_OCAML_AS="${CONDA_OCAML_AS:-${AS:-@AS@}}"
export CONDA_OCAML_CC="${CONDA_OCAML_CC:-${CC:-@CC@}}"
export CONDA_OCAML_AR="${CONDA_OCAML_AR:-${AR:-@AR@}}"
export CONDA_OCAML_RANLIB="${CONDA_OCAML_RANLIB:-${RANLIB:-@RANLIB@}}"
export CONDA_OCAML_MKDLL="${CONDA_OCAML_MKDLL:-${CONDA_OCAML_CC} -shared}"
