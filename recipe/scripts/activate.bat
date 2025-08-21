@if defined OCAML_OCAMLLIB (
     @set "_OCAML_OCAMLLIB_BACKUP=%OCAML_OCAMLLIB%"
)
@set "OCAML_OCAMLLIB=%CONDA_PREFIX%\Library\lib\ocaml"

@if defined OCAML_PREFIX (
     @set "_OCAML_PREFIX_BACKUP=%OCAML_PREFIX%"
)
@set "OCAML_PREFIX=%CONDA_PREFIX%\Library"

set "PATH=%CONDA_PREFIX%\Library\lib\ocaml\stublibs;%PATH%"
