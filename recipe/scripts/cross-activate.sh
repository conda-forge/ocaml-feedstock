# shellcheck shell=sh
# Cross-compiler activation for ocaml_$target (installed alongside native ocaml_$build)
#
# Provides functions to swap between native and cross-compiler toolchains:
#   ocaml_use_cross   — switch CONDA_OCAML_* to cross-compiler tools
#   ocaml_use_native  — restore CONDA_OCAML_* to native tools
#
# @TARGET@ and @TARGET_ID@ are replaced at install time by build.sh

_OCAML_CROSS_TARGET="@TARGET@"
_OCAML_CROSS_TARGET_ID="@TARGET_ID@"
_OCAML_CROSS_PREFIX="${CONDA_PREFIX}/lib/ocaml-cross-compilers/@TARGET@"

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
_OCAML_CROSS_CC="@CROSS_CC@"
_OCAML_CROSS_AS="@CROSS_AS@"
_OCAML_CROSS_AR="@CROSS_AR@"
_OCAML_CROSS_LD="@CROSS_LD@"
_OCAML_CROSS_RANLIB="@CROSS_RANLIB@"
_OCAML_CROSS_MKEXE="@CROSS_MKEXE@"
_OCAML_CROSS_MKDLL="@CROSS_MKDLL@"

# Switch to cross-compiler toolchain
ocaml_use_cross() {
  export CONDA_OCAML_CC="${CONDA_OCAML_${_OCAML_CROSS_TARGET_ID}_CC:-${_OCAML_CROSS_CC}}"
  export CONDA_OCAML_AS="${CONDA_OCAML_${_OCAML_CROSS_TARGET_ID}_AS:-${_OCAML_CROSS_AS}}"
  export CONDA_OCAML_AR="${CONDA_OCAML_${_OCAML_CROSS_TARGET_ID}_AR:-${_OCAML_CROSS_AR}}"
  export CONDA_OCAML_LD="${CONDA_OCAML_${_OCAML_CROSS_TARGET_ID}_LD:-${_OCAML_CROSS_LD}}"
  export CONDA_OCAML_RANLIB="${CONDA_OCAML_${_OCAML_CROSS_TARGET_ID}_RANLIB:-${_OCAML_CROSS_RANLIB}}"
  export CONDA_OCAML_MKEXE="${CONDA_OCAML_${_OCAML_CROSS_TARGET_ID}_MKEXE:-${_OCAML_CROSS_MKEXE}}"
  export CONDA_OCAML_MKDLL="${CONDA_OCAML_${_OCAML_CROSS_TARGET_ID}_MKDLL:-${_OCAML_CROSS_MKDLL}}"
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
