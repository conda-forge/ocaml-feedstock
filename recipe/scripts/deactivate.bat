@if defined _OOCAML_OCAMLLIB_BACKUP (
    @set "OCAML_OCAMLLIB=%_OCAML_OCAMLLIB_BACKUP%"
    @set "_OCAML_OCAMLLIB_BACKUP="
) else (
    @set "OCAML_OCAMLLIB="
)

@if defined _OCAML_PREFIX_BACKUP (
    @set "OCAML_PREFIX=%_OCAML_PREFIX_BACKUP%"
    @set "_OCAML_PREFIX_BACKUP="
) else (
    @set "OCAML_PREFIX="
)
