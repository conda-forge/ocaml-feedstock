# shellcheck shell=sh
# Cross-compiler activation for ocaml_$target (standalone, or alongside native ocaml_$build)
#
# Provides functions to swap between native and cross-compiler toolchains:
#   ocaml_use_cross   - switch CONDA_OCAML_* to cross-compiler tools and put
#                       the bare-name launchers (ocamlc, ocamlopt, ...) on PATH
#   ocaml_use_native  - restore CONDA_OCAML_* to native tools and drop them
#
# The env switches to cross mode on its own when it cross-compiles
# (CONDA_BUILD_CROSS_COMPILATION=1, or build_platform != target_platform).
# OCAML_CROSS_AUTO=0 turns that off.
#
# @TARGET@ and @TARGET_ID@ are replaced at install time by build.sh

export _OCAML_CROSS_TARGET="@TARGET@"
export _OCAML_CROSS_TARGET_ID="@TARGET_ID@"
export _OCAML_CROSS_PREFIX="${CONDA_PREFIX}/lib/ocaml-cross-compilers/@TARGET@"
export _OCAML_CROSS_SHIMS="${_OCAML_CROSS_PREFIX}/shims"

# Backup native values, unless a previous activation already switched to cross
if [ "${OCAML_CROSS_MODE:-}" != "cross" ]; then
  export _OCAML_NATIVE_CC="${CONDA_OCAML_CC:-}"
  export _OCAML_NATIVE_AS="${CONDA_OCAML_AS:-}"
  export _OCAML_NATIVE_AR="${CONDA_OCAML_AR:-}"
  export _OCAML_NATIVE_LD="${CONDA_OCAML_LD:-}"
  export _OCAML_NATIVE_RANLIB="${CONDA_OCAML_RANLIB:-}"
  export _OCAML_NATIVE_MKEXE="${CONDA_OCAML_MKEXE:-}"
  export _OCAML_NATIVE_MKDLL="${CONDA_OCAML_MKDLL:-}"
  export _OCAML_NATIVE_OCAMLLIB="${OCAMLLIB:-}"
  export _OCAML_NATIVE_OCAML_PREFIX="${OCAML_PREFIX:-}"
  export OCAML_CROSS_MODE="native"
fi

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

# Cross-compiler defaults (replaced at install time)
export _OCAML_CROSS_CC="@CROSS_CC@"
export _OCAML_CROSS_AS="@CROSS_AS@"
export _OCAML_CROSS_AR="@CROSS_AR@"
export _OCAML_CROSS_LD="@CROSS_LD@"
export _OCAML_CROSS_RANLIB="@CROSS_RANLIB@"
export _OCAML_CROSS_MKEXE="@CROSS_MKEXE@"
export _OCAML_CROSS_MKDLL="@CROSS_MKDLL@"

# Remove every copy of the bare-name launcher dir from PATH
_ocaml_cross_path_drop() {
  local _p=":${PATH:-}:"
  while [[ "${_p}" == *":${_OCAML_CROSS_SHIMS}:"* ]]; do
    _p="${_p//":${_OCAML_CROSS_SHIMS}:"/:}"
  done
  _p="${_p#:}"
  export PATH="${_p%:}"
}

# Switch to cross-compiler toolchain
# Uses indirect expansion (${!var}) since bash doesn't support nested ${VAR_${OTHER}}
ocaml_use_cross() {
  local _id="${_OCAML_CROSS_TARGET_ID}"
  local _var
  _var="CONDA_OCAML_${_id}_CC";    export CONDA_OCAML_CC="${!_var:-${_OCAML_CROSS_CC}}"
  _var="CONDA_OCAML_${_id}_AS";    export CONDA_OCAML_AS="${!_var:-${_OCAML_CROSS_AS}}"
  _var="CONDA_OCAML_${_id}_AR";    export CONDA_OCAML_AR="${!_var:-${_OCAML_CROSS_AR}}"
  _var="CONDA_OCAML_${_id}_LD";    export CONDA_OCAML_LD="${!_var:-${_OCAML_CROSS_LD}}"
  _var="CONDA_OCAML_${_id}_RANLIB"; export CONDA_OCAML_RANLIB="${!_var:-${_OCAML_CROSS_RANLIB}}"
  _var="CONDA_OCAML_${_id}_MKEXE"; export CONDA_OCAML_MKEXE="${!_var:-${_OCAML_CROSS_MKEXE}}"
  _var="CONDA_OCAML_${_id}_MKDLL"; export CONDA_OCAML_MKDLL="${!_var:-${_OCAML_CROSS_MKDLL}}"
  export OCAMLLIB="${_OCAML_CROSS_PREFIX}/lib/ocaml"
  export OCAML_PREFIX="${_OCAML_CROSS_PREFIX}"
  _ocaml_cross_path_drop
  export PATH="${_OCAML_CROSS_SHIMS}${PATH:+:${PATH}}"
  export OCAML_CROSS_MODE="cross"
}

# Restore native toolchain; a variable that was unset before is unset again
ocaml_use_native() {
  local _name _backup
  for _name in CC AS AR LD RANLIB MKEXE MKDLL; do
    _backup="_OCAML_NATIVE_${_name}"
    if [[ -n "${!_backup:-}" ]]; then
      export "CONDA_OCAML_${_name}=${!_backup}"
    else
      unset "CONDA_OCAML_${_name}"
    fi
  done
  if [[ -n "${_OCAML_NATIVE_OCAMLLIB:-}" ]]; then
    export OCAMLLIB="${_OCAML_NATIVE_OCAMLLIB}"
  else
    unset OCAMLLIB
  fi
  if [[ -n "${_OCAML_NATIVE_OCAML_PREFIX:-}" ]]; then
    export OCAML_PREFIX="${_OCAML_NATIVE_OCAML_PREFIX}"
  else
    unset OCAML_PREFIX
  fi
  _ocaml_cross_path_drop
  export OCAML_CROSS_MODE="native"
}

# Export functions so they're available in subshells and test scripts
export -f _ocaml_cross_path_drop
export -f ocaml_use_cross
export -f ocaml_use_native

# Export cross-compiler info for downstream scripts
export OCAML_CROSS_TARGET="${_OCAML_CROSS_TARGET}"
export OCAML_CROSS_PREFIX="${_OCAML_CROSS_PREFIX}"

# Self-activate in a cross-compiling env; re-sourcing in cross mode refreshes it
if [ "${OCAML_CROSS_MODE}" = "cross" ]; then
  ocaml_use_cross
elif [ "${OCAML_CROSS_AUTO:-1}" != "0" ]; then
  if [ "${CONDA_BUILD_CROSS_COMPILATION:-0}" = "1" ] || \
     { [ -n "${build_platform:-}" ] && [ -n "${target_platform:-}" ] && [ "${build_platform}" != "${target_platform}" ]; }; then
    ocaml_use_cross
  fi
fi
