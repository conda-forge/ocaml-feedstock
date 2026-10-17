# shellcheck shell=sh

export _OCAML_OCAMLLIB_CONDA_BACKUP="${OCAMLLIB:-}"
export _OCAML_OCAML_PREFIX_CONDA_BACKUP="${OCAML_PREFIX:-}"

export OCAML_PREFIX="${CONDA_PREFIX}"
export OCAMLLIB="${OCAML_PREFIX}"/lib/ocaml

# During a conda build the host prefix libraries go first on OCAMLPATH
if [ "${CONDA_BUILD:-}" = "1" ] && [ -n "${PREFIX:-}" ] && [ "${PREFIX}" != "${CONDA_PREFIX:-}" ]; then
  case ":${OCAMLPATH:-}:" in
    *":${PREFIX}/lib/ocaml:"*) ;;
    *)
      export _OCAML_OCAMLPATH_CONDA_BACKUP="${OCAMLPATH:-}"
      # Distinguish unset from set-but-empty for the restore
      if [ -z "${OCAMLPATH+x}" ]; then
        export _OCAML_OCAMLPATH_CONDA_WAS_UNSET=1
      else
        unset _OCAML_OCAMLPATH_CONDA_WAS_UNSET
      fi
      export OCAMLPATH="${PREFIX}/lib/ocaml${OCAMLPATH:+:${OCAMLPATH}}"
      ;;
  esac
fi

# OCaml toolchain configuration
# These are used by ocamlopt for assembling and linking native code
# @CC@, @AS@, etc. are replaced at build time with actual tools used
# Users can override: CONDA_OCAML_CC=clang ocamlopt ...
export CONDA_OCAML_AR="${CONDA_OCAML_AR:-@AR@}"
export CONDA_OCAML_AS="${CONDA_OCAML_AS:-@AS@}"
export CONDA_OCAML_CC="${CONDA_OCAML_CC:-@CC@}"
export CONDA_OCAML_LD="${CONDA_OCAML_LD:-@LD@}"
export CONDA_OCAML_RANLIB="${CONDA_OCAML_RANLIB:-@RANLIB@}"
export CONDA_OCAML_MKEXE="${CONDA_OCAML_MKEXE:-@MKEXE@}"
export CONDA_OCAML_MKDLL="${CONDA_OCAML_MKDLL:-@MKDLL@}"

# macOS: DYLD_FALLBACK_LIBRARY_PATH for build-time executables to find libzstd
if [ "$(uname)" = "Darwin" ]; then
  export _OCAML_DYLD_FALLBACK_LIBRARY_PATH_BACKUP="${DYLD_FALLBACK_LIBRARY_PATH:-}"
  export DYLD_FALLBACK_LIBRARY_PATH="${CONDA_PREFIX}/lib${DYLD_FALLBACK_LIBRARY_PATH:+:${DYLD_FALLBACK_LIBRARY_PATH}}"
fi
