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

# Archives no longer record -L${PREFIX}/lib (#191), so in a conda build the
# native links find the host prefix libraries through mkexe/mkdll instead.
# Only in a native (non-cross) conda build: on a cross build PREFIX holds
# target libraries that a native link must not search
if [ "${CONDA_BUILD:-}" = "1" ] && [ -n "${PREFIX:-}" ] && [ "${PREFIX}" != "${CONDA_PREFIX:-}" ] \
   && [ "${CONDA_BUILD_CROSS_COMPILATION:-}" != "1" ] \
   && { [ -z "${build_platform:-}" ] || [ -z "${target_platform:-}" ] || [ "${build_platform}" = "${target_platform}" ]; }; then
  case "${CONDA_OCAML_MKEXE}" in
    *" -L${PREFIX}/lib"*) ;;
    *) export CONDA_OCAML_MKEXE="${CONDA_OCAML_MKEXE} -L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib" ;;
  esac
  case "${CONDA_OCAML_MKDLL}" in
    *" -L${PREFIX}/lib"*) ;;
    *) export CONDA_OCAML_MKDLL="${CONDA_OCAML_MKDLL} -L${PREFIX}/lib" ;;
  esac
fi

# macOS: DYLD_FALLBACK_LIBRARY_PATH for build-time executables to find libzstd
if [ "$(uname)" = "Darwin" ]; then
  export _OCAML_DYLD_FALLBACK_LIBRARY_PATH_BACKUP="${DYLD_FALLBACK_LIBRARY_PATH:-}"
  export DYLD_FALLBACK_LIBRARY_PATH="${CONDA_PREFIX}/lib${DYLD_FALLBACK_LIBRARY_PATH:+:${DYLD_FALLBACK_LIBRARY_PATH}}"
fi
