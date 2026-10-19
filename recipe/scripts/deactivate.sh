unset OCAMLLIB
unset OCAML_PREFIX
unset CONDA_OCAML_AS
unset CONDA_OCAML_CC
unset CONDA_OCAML_AR
unset CONDA_OCAML_LD
unset CONDA_OCAML_RANLIB
unset CONDA_OCAML_MKDLL
unset CONDA_OCAML_MKEXE

if [[ -n "${_OCAML_OCAMLLIB_CONDA_BACKUP:-}" ]]; then
    export OCAMLLIB="${_OCAML_OCAMLLIB_CONDA_BACKUP}"
    unset _OCAML_OCAMLLIB_CONDA_BACKUP
fi
if [[ -n "${_OCAML_OCAML_PREFIX_CONDA_BACKUP:-}" ]]; then
    export OCAML_PREFIX="${_OCAML_OCAML_PREFIX_CONDA_BACKUP}"
    unset _OCAML_OCAML_PREFIX_CONDA_BACKUP
fi

if [[ -n "${_OCAML_OCAMLPATH_CONDA_BACKUP+x}" ]]; then
    if [[ "${_OCAML_OCAMLPATH_CONDA_WAS_UNSET:-}" = "1" ]]; then
        unset OCAMLPATH
    else
        export OCAMLPATH="${_OCAML_OCAMLPATH_CONDA_BACKUP}"
    fi
    unset _OCAML_OCAMLPATH_CONDA_BACKUP _OCAML_OCAMLPATH_CONDA_WAS_UNSET
fi

# Drop the no-op switches, but not the real ones a cross package defined
if [[ "${_OCAML_NOOP_SWITCHES:-}" == "1" ]]; then
    unset -f ocaml_use_native ocaml_use_cross 2>/dev/null || true
    unset _OCAML_NOOP_SWITCHES
fi

# macOS: Restore DYLD_FALLBACK_LIBRARY_PATH
if [[ -n "${_OCAML_DYLD_FALLBACK_LIBRARY_PATH_BACKUP+x}" ]]; then
    if [[ -n "${_OCAML_DYLD_FALLBACK_LIBRARY_PATH_BACKUP}" ]]; then
        export DYLD_FALLBACK_LIBRARY_PATH="${_OCAML_DYLD_FALLBACK_LIBRARY_PATH_BACKUP}"
    else
        unset DYLD_FALLBACK_LIBRARY_PATH
    fi
    unset _OCAML_DYLD_FALLBACK_LIBRARY_PATH_BACKUP
fi
