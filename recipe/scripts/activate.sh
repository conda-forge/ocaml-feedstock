# shellcheck shell=sh

# This function takes no arguments
# It tries to determine the name of this file in a programatic way.
_get_sourced_filename() {
    # shellcheck disable=SC3054,SC2296 # non-POSIX array access and bad '(' are guarded
    if [ -n "${BASH_SOURCE+x}" ] && [ -n "${BASH_SOURCE[0]}" ]; then
        # shellcheck disable=SC3054 # non-POSIX array access is guarded
        basename "${BASH_SOURCE[0]}"
    elif [ -n "$ZSH_NAME" ] && [ -n "${(%):-%x}" ]; then
        # in zsh use prompt-style expansion to introspect the same information
        # see http://stackoverflow.com/questions/9901210/bash-source0-equivalent-in-zsh
        # shellcheck disable=SC2296  # bad '(' is guarded
        basename "${(%):-%x}"
    else
        echo "UNKNOWN FILE"
    fi
}

export _OCAML_OCAMLLIB_CONDA_BACKUP="${OCAMLLIB:-}"
export _OCAML_OCAML_PREFIX_CONDA_BACKUP="${OCAML_PREFIX:-}"

if [ "${CONDA_BUILD:-0}" = "1" ]; then
  if [ -f /tmp/old-env-$$.txt ]; then
    rm -f /tmp/old-env-$$.txt || true
  fi
  env > /tmp/old-env-$$.txt
fi

export OCAML_PREFIX="${CONDA_PREFIX}"
export OCAMLLIB="${OCAML_PREFIX}"/lib/ocaml

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

if [ $? -ne 0 ]; then
  echo "ERROR: $(_get_sourced_filename) failed, see above for details"
#exit 1
else
  if [ "${CONDA_BUILD:-0}" = "1" ]; then
    if [ -f /tmp/new-env-$$.txt ]; then
      rm -f /tmp/new-env-$$.txt || true
    fi
    env > /tmp/new-env-$$.txt

    echo "INFO: $(_get_sourced_filename) made the following environmental changes:"
    diff -U 0 -rN /tmp/old-env-$$.txt /tmp/new-env-$$.txt | tail -n +4 | grep "^-.*\|^+.*" | grep -v "CONDA_BACKUP_" | sort
    rm -f /tmp/old-env-$$.txt /tmp/new-env-$$.txt || true
  fi
fi
