@if defined OCAML_PREFIX (
     @set "_OCAML_PREFIX_BACKUP=%OCAML_PREFIX%"
)
@set "OCAML_PREFIX=%CONDA_PREFIX%\Library"

@if defined OCAMLLIB (
     @set "_OCAML_OCAMLLIB_BACKUP=%OCAMLLIB%"
)
@set "OCAMLLIB=%OCAML_PREFIX%\lib\ocaml"

@set "PATH=%OCAMLLIB%\stublibs;%PATH%"
@set "CAML_LD_LIBRARY_PATH=%OCAMLLIB%\stublibs"

@REM OCaml toolchain configuration
@REM These are used by ocamlopt for assembling and linking native code
@REM @CC@, @AS@, etc. are replaced at build time with actual tools used
@REM Users can override: set CONDA_OCAML_CC=cl && set CONDA_OCAML_MKDLL=cl /LD && ocamlopt ...

@REM Use CONDA_OCAML_* if set, else use system AS/CC/AR, else use build-time defaults
@if not defined CONDA_OCAML_AS (
    @if defined AS (@set "CONDA_OCAML_AS=%AS%") else (@set "CONDA_OCAML_AS=@AS@")
)
@if not defined CONDA_OCAML_CC (
    @if defined CC (@set "CONDA_OCAML_CC=%CC%") else (@set "CONDA_OCAML_CC=@CC@")
)
@if not defined CONDA_OCAML_AR (
    @if defined AR (@set "CONDA_OCAML_AR=%AR%") else (@set "CONDA_OCAML_AR=@AR@")
)
@if not defined CONDA_OCAML_RANLIB (
    @if defined RANLIB (@set "CONDA_OCAML_RANLIB=%RANLIB%") else (@set "CONDA_OCAML_RANLIB=@RANLIB@")
)
@if not defined CONDA_OCAML_LD (
    @if defined LD (@set "CONDA_OCAML_LD=%LD%") else (@set "CONDA_OCAML_LD=@LD@")
)
@if not defined CONDA_OCAML_MKEXE (
    @set "CONDA_OCAML_MKEXE=@MKEXE@"
)
@if not defined CONDA_OCAML_MKDLL (
    @set "CONDA_OCAML_MKDLL=@MKDLL@"
)
@if not defined CONDA_OCAML_WINDRES (
    @if defined WINDRES (@set "CONDA_OCAML_WINDRES=%WINDRES%") else (@set "CONDA_OCAML_WINDRES=@WINDRES@")
)
