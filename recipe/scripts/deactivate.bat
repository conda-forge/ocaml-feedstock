@if defined _OCAML_OCAMLLIB_BACKUP (
    @set "OCAMLLIB=%_OCAML_OCAMLLIB_BACKUP%"
    @set "_OCAML_OCAMLLIB_BACKUP="
) else (
    @set "OCAMLLIB="
)

@if defined _OCAML_PREFIX_BACKUP (
    @set "OCAML_PREFIX=%_OCAML_PREFIX_BACKUP%"
    @set "_OCAML_PREFIX_BACKUP="
) else (
    @set "OCAML_PREFIX="
)

@REM Clean up OCaml library path
@set "CAML_LD_LIBRARY_PATH="

@REM Clean up OCaml toolchain variables
@set "CONDA_OCAML_AS="
@set "CONDA_OCAML_CC="
@set "CONDA_OCAML_AR="
@set "CONDA_OCAML_LD="
@set "CONDA_OCAML_RANLIB="
@set "CONDA_OCAML_MKEXE="
@set "CONDA_OCAML_MKDLL="
@set "CONDA_OCAML_WINDRES="
