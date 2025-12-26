#!/bin/bash
# Common functions shared across OCaml build scripts
# Source this file with: source "${RECIPE_DIR}/building/common-functions.sh"

# Logging wrapper - captures stdout/stderr to log files for debugging
run_logged() {
  local logname="$1"
  shift
  local logfile="${LOG_DIR}/${logname}.log"

  echo "Running: $*"
  if "$@" >> "${logfile}" 2>&1; then
    return 0
  else
    local rc=$?
    echo "FAILED (exit code ${rc}) - last 50 lines:"
    tail -50 "${logfile}"
    return ${rc}
  fi
}

# Ensure command path is absolute (prevents PATH lookup issues)
_ensure_full_path() {
  local cmd="$1"
  [[ "$cmd" == /* ]] && echo "$cmd" || echo "${BUILD_PREFIX}/bin/${cmd}"
}

# Apply Makefile.cross and platform-specific patches
# Requires: _NEEDS_DL variable to be set
apply_cross_patches() {
  # Apply Makefile.cross and platform-specific patches
  cp "${RECIPE_DIR}"/building/Makefile.cross .
  patch -N -p0 < "${RECIPE_DIR}"/building/tmp_Makefile.patch || true

  # Fix dynlink "inconsistent assumptions" error:
  # Use otherlibrariesopt-cross target which calls dynlink-allopt with proper CAMLOPT/BEST_OCAMLOPT
  sed -i 's/otherlibrariesopt ocamltoolsopt/otherlibrariesopt-cross ocamltoolsopt/g' Makefile.cross
  sed -i 's/\$(MAKE) otherlibrariesopt /\$(MAKE) otherlibrariesopt-cross /g' Makefile.cross

  if [[ "${_NEEDS_DL}" == "1" ]]; then
    sed -i 's/^\(BYTECCLIBS=.*\)$/\1 -ldl/' Makefile.config
  fi
}
