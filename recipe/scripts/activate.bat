@if defined OCAML_PREFIX (
     @set "_OCAML_PREFIX_BACKUP=%OCAML_PREFIX%"
)
@set "OCAML_PREFIX=%CONDA_PREFIX%\Library"

@if defined OCAMLLIB (
     @set "_OCAML_OCAMLLIB_BACKUP=%OCAMLLIB%"
)
@set "OCAMLLIB=%OCAML_PREFIX%\lib\ocaml"

set "PATH=%OCAMLLIB%\stublibs;%PATH%"
