# shellcheck shell=sh
# Cross-compiler activation for ocaml_$target (installed alongside native ocaml_$build)
#
# Provides functions to swap between native and cross-compiler toolchains:
#   ocaml_use_cross   — switch CONDA_OCAML_* to cross-compiler tools
#   ocaml_use_native  — restore CONDA_OCAML_* to native tools
#
# @TARGET@ and @TARGET_ID@ are replaced at install time by build.sh

export _OCAML_CROSS_TARGET="@TARGET@"
export _OCAML_CROSS_TARGET_ID="@TARGET_ID@"
export _OCAML_CROSS_PREFIX="${CONDA_PREFIX}/lib/ocaml-cross-compilers/@TARGET@"

# Backup native values on first activation
export _OCAML_NATIVE_CC="${CONDA_OCAML_CC:-}"
export _OCAML_NATIVE_AS="${CONDA_OCAML_AS:-}"
export _OCAML_NATIVE_AR="${CONDA_OCAML_AR:-}"
export _OCAML_NATIVE_LD="${CONDA_OCAML_LD:-}"
export _OCAML_NATIVE_RANLIB="${CONDA_OCAML_RANLIB:-}"
export _OCAML_NATIVE_MKEXE="${CONDA_OCAML_MKEXE:-}"
export _OCAML_NATIVE_MKDLL="${CONDA_OCAML_MKDLL:-}"
export _OCAML_NATIVE_OCAMLLIB="${OCAMLLIB:-}"
export _OCAML_NATIVE_OCAML_PREFIX="${OCAML_PREFIX:-}"

# Cross-compiler defaults (replaced at install time)
export _OCAML_CROSS_CC="@CROSS_CC@"
export _OCAML_CROSS_AS="@CROSS_AS@"
export _OCAML_CROSS_AR="@CROSS_AR@"
export _OCAML_CROSS_LD="@CROSS_LD@"
export _OCAML_CROSS_RANLIB="@CROSS_RANLIB@"
export _OCAML_CROSS_MKEXE="@CROSS_MKEXE@"
export _OCAML_CROSS_MKDLL="@CROSS_MKDLL@"

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
  export OCAML_CROSS_MODE="cross"
}

# Restore native toolchain
ocaml_use_native() {
  export CONDA_OCAML_CC="${_OCAML_NATIVE_CC}"
  export CONDA_OCAML_AS="${_OCAML_NATIVE_AS}"
  export CONDA_OCAML_AR="${_OCAML_NATIVE_AR}"
  export CONDA_OCAML_LD="${_OCAML_NATIVE_LD}"
  export CONDA_OCAML_RANLIB="${_OCAML_NATIVE_RANLIB}"
  export CONDA_OCAML_MKEXE="${_OCAML_NATIVE_MKEXE}"
  export CONDA_OCAML_MKDLL="${_OCAML_NATIVE_MKDLL}"
  export OCAMLLIB="${_OCAML_NATIVE_OCAMLLIB}"
  export OCAML_PREFIX="${_OCAML_NATIVE_OCAML_PREFIX}"
  export OCAML_CROSS_MODE="native"
}

# Export functions so they're available in subshells and test scripts
export -f ocaml_use_cross
export -f ocaml_use_native

# Export cross-compiler info for downstream scripts
export OCAML_CROSS_TARGET="${_OCAML_CROSS_TARGET}"
export OCAML_CROSS_PREFIX="${_OCAML_CROSS_PREFIX}"
export OCAML_CROSS_MODE="native"

if [ "${CONDA_BUILD:-0}" = "1" ]; then
  echo "INFO: ocaml_cross_activate.sh loaded:"
  echo "  OCAML_CROSS_TARGET=${OCAML_CROSS_TARGET}"
  echo "  OCAML_CROSS_PREFIX=${OCAML_CROSS_PREFIX}"
  echo "  OCAML_CROSS_MODE=${OCAML_CROSS_MODE} (use ocaml_use_cross/ocaml_use_native to swap)"
fi
