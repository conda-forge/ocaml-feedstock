@if defined OCAML_PREFIX (
     @set "_OCAML_PREFIX_BACKUP=%OCAML_PREFIX%"
)
@set "OCAML_PREFIX=%CONDA_PREFIX%\Library"

@if defined OCAMLLIB (
     @set "_OCAML_OCAMLLIB_BACKUP=%OCAMLLIB%"
)
@set "OCAMLLIB=%OCAML_PREFIX%\lib\ocaml"

@set "PATH=%OCAMLLIB%\stublibs;%PATH%"

@REM OCaml toolchain configuration
@REM These are used by ocamlopt for assembling and linking native code
@REM Users can override: set CONDA_OCAML_CC=clang && ocamlopt ...
@if not defined CONDA_OCAML_AS @set "CONDA_OCAML_AS=as"
@if not defined CONDA_OCAML_CC @set "CONDA_OCAML_CC=gcc"
@if not defined CONDA_OCAML_AR @set "CONDA_OCAML_AR=ar"
