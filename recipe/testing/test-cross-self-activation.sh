#!/usr/bin/env bash
# Test that the cross-compiler activates itself in a cross-compiling env:
# plain ocamlopt must resolve to the cross compiler and emit target objects.
# Usage: test-cross-self-activation.sh <target_triplet>
set -euo pipefail

TARGET="$1"
# The package under test is installed in PREFIX; the test run activates the
# build env, so CONDA_PREFIX may name that unrelated env.
export CONDA_PREFIX="${PREFIX:-${CONDA_PREFIX}}"
ACTIVATE="${CONDA_PREFIX}/etc/conda/activate.d/ocaml_cross_activate.sh"
DEACTIVATE="${CONDA_PREFIX}/etc/conda/deactivate.d/ocaml_cross_deactivate.sh"
CROSS="${CONDA_PREFIX}/lib/ocaml-cross-compilers/${TARGET}"
SHIMS="${CROSS}/shims"
CROSS_LIB="${CROSS}/lib/ocaml"

case "${TARGET}" in
  aarch64-*|arm64-*) EXPECTED_ARCH="arm64";  FILE_RE="aarch64|arm64" ;;
  powerpc64le-*)     EXPECTED_ARCH="power";  FILE_RE="powerpc|ppc64" ;;
  riscv64-*)         EXPECTED_ARCH="riscv";  FILE_RE="risc-v" ;;
  s390x-*)           EXPECTED_ARCH="s390x";  FILE_RE="S/390|s390" ;;
  x86_64-*)          EXPECTED_ARCH="amd64";  FILE_RE="x86-64|x86_64" ;;
  *) echo "[FAIL] Unrecognised target ${TARGET}"; exit 1 ;;
esac

echo "=== Cross-Compiler Self-Activation Tests (${TARGET}) ==="
ERRORS=0

# Count PATH entries equal to the launcher dir
shims_on_path() {
  local _n=0 _entry
  local IFS=:
  for _entry in ${PATH}; do
    [[ "${_entry}" == "${SHIMS}" ]] && _n=$((_n + 1))
  done
  echo "${_n}"
}

# Count OCAMLPATH entries equal to the cross library dir
cross_lib_on_ocamlpath() {
  local _n=0 _entry
  local IFS=:
  for _entry in ${OCAMLPATH:-}; do
    [[ "${_entry}" == "${CROSS_LIB}" ]] && _n=$((_n + 1))
  done
  echo "${_n}"
}

if [[ "${OCAML_CROSS_MODE:-}" == "cross" ]]; then
  echo "env started self-activated (OCAML_CROSS_MODE=${OCAML_CROSS_MODE}," \
    "CONDA_BUILD_CROSS_COMPILATION=${CONDA_BUILD_CROSS_COMPILATION:-<unset>}," \
    "build_platform=${build_platform:-<unset>}, target_platform=${target_platform:-<unset>});" \
    "deactivating to take the baseline"
  # shellcheck disable=SC1090
  source "${DEACTIVATE}"
fi

ORIG_OCAMLPATH_SET="${OCAMLPATH+x}"
ORIG_OCAMLPATH="${OCAMLPATH:-}"

echo "Test 1: activation switches to cross mode"
export CONDA_BUILD_CROSS_COMPILATION=1
# shellcheck disable=SC1090
source "${ACTIVATE}"
if [[ "${OCAML_CROSS_MODE:-}" == "cross" ]]; then
  echo "  PASS: OCAML_CROSS_MODE=cross"
else
  echo "  FAIL: OCAML_CROSS_MODE='${OCAML_CROSS_MODE:-<unset>}' (expected 'cross')"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 2: second activation keeps one PATH entry"
# shellcheck disable=SC1090
source "${ACTIVATE}"
if [[ "$(shims_on_path)" == "1" ]]; then
  echo "  PASS: ${SHIMS} on PATH once"
else
  echo "  FAIL: ${SHIMS} on PATH $(shims_on_path) times (expected 1)"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 3: plain ocamlopt resolves to the launcher dir"
_ocamlopt=$(command -v ocamlopt || true)
if [[ "${_ocamlopt}" == "${SHIMS}/ocamlopt" ]]; then
  echo "  PASS: ocamlopt -> ${_ocamlopt}"
else
  echo "  FAIL: ocamlopt -> '${_ocamlopt:-<not found>}' (expected ${SHIMS}/ocamlopt)"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 4: ocamlopt -config reports the target architecture"
_arch=$(ocamlopt -config 2>/dev/null | sed -n 's/^architecture: //p' || true)
if [[ "${_arch}" == "${EXPECTED_ARCH}" ]]; then
  echo "  PASS: architecture=${_arch}"
else
  echo "  FAIL: architecture='${_arch}' (expected ${EXPECTED_ARCH})"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 5: ocamlopt -c emits a target object"
WORK=$(mktemp -d)
echo 'let x = 42' > "${WORK}/self_act.ml"
if (cd "${WORK}" && ocamlopt -c self_act.ml); then
  _file_output=$(file "${WORK}/self_act.o")
  if echo "${_file_output}" | grep -qiE "${FILE_RE}"; then
    echo "  PASS: ${_file_output}"
  else
    echo "  FAIL: expected ${EXPECTED_ARCH} object, got: ${_file_output}"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "  FAIL: ocamlopt -c failed"
  ERRORS=$((ERRORS + 1))
fi
rm -rf "${WORK}"

echo "Test 6: the ocaml launcher runs the cross toplevel without a native ocaml"
if [[ -x "${SHIMS}/ocaml" ]]; then
  WORK=$(mktemp -d)
  echo 'let () = print_string "shim-ok"' > "${WORK}/shim_ok.ml"
  _out=$(cd "${WORK}" && PATH="${SHIMS}:/usr/bin:/bin" "${SHIMS}/ocaml" shim_ok.ml 2>&1 || true)
  if [[ "${_out}" == "shim-ok" ]]; then
    echo "  PASS: ${SHIMS}/ocaml ran a script"
  else
    echo "  FAIL: ${SHIMS}/ocaml printed '${_out}' (expected 'shim-ok')"
    ERRORS=$((ERRORS + 1))
  fi
  # #load of unix.cma loads the unix stubs into the toplevel's ocamlrun
  cat > "${WORK}/top_unix.ml" << 'EOF'
#directory "+unix";;
#load "unix.cma";;
print_string (if Sys.file_exists (Unix.getcwd ()) then "toplevel-unix-ok" else "bad");;
EOF
  _out=$(cd "${WORK}" && env -u CAML_LD_LIBRARY_PATH PATH="${SHIMS}:/usr/bin:/bin" "${SHIMS}/ocaml" top_unix.ml 2>&1; echo " exit=$?")
  if [[ "${_out}" == "toplevel-unix-ok exit=0" ]]; then
    echo "  PASS: ${SHIMS}/ocaml loaded unix.cma"
  else
    echo "  FAIL: ${SHIMS}/ocaml with unix.cma printed '${_out}' (expected 'toplevel-unix-ok exit=0')"
    ERRORS=$((ERRORS + 1))
  fi
  rm -rf "${WORK}"
else
  echo "  FAIL: ${SHIMS}/ocaml missing or not executable"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 6b: the lexer/parser generator launchers run from the shims dir"
for _g in ocamllex ocamlyacc; do
  _found=$(PATH="${SHIMS}:/usr/bin:/bin" command -v "${_g}" || true)
  if [[ "${_found}" == "${SHIMS}/${_g}" ]] && PATH="${SHIMS}:/usr/bin:/bin" "${_g}" -version >/dev/null 2>&1; then
    echo "  PASS: ${_g} -version via ${_found}"
  else
    echo "  FAIL: ${_g} -> '${_found:-<not found>}' or -version failed"
    ERRORS=$((ERRORS + 1))
  fi
done

echo "Test 7: the cross library is first on OCAMLPATH"
if [[ "${OCAMLPATH:-}" == "${CROSS_LIB}" || "${OCAMLPATH:-}" == "${CROSS_LIB}:"* ]] && \
   [[ "$(cross_lib_on_ocamlpath)" == "1" ]]; then
  echo "  PASS: OCAMLPATH=${OCAMLPATH}"
else
  echo "  FAIL: OCAMLPATH='${OCAMLPATH:-<unset>}' (expected ${CROSS_LIB} first, once)"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 8: ocaml_use_native drops the cross library, ocaml_use_cross restores it once"
ocaml_use_native
_native_n=$(cross_lib_on_ocamlpath)
ocaml_use_cross
ocaml_use_cross
if [[ "${_native_n}" == "0" && "$(cross_lib_on_ocamlpath)" == "1" ]] && \
   [[ "${OCAMLPATH:-}" == "${CROSS_LIB}" || "${OCAMLPATH:-}" == "${CROSS_LIB}:"* ]]; then
  echo "  PASS: native=0 entries, cross=1 entry first"
else
  echo "  FAIL: native=${_native_n} entries, cross OCAMLPATH='${OCAMLPATH:-<unset>}'"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 9: ocaml_use_cross moves the launcher dir back to the front"
WORK=$(mktemp -d)
printf '#!/bin/sh\nexit 0\n' > "${WORK}/ocamlopt"
chmod +x "${WORK}/ocamlopt"
export PATH="${WORK}:${PATH}"
_warn=$(ocaml_cross_check 2>&1 >/dev/null)
ocaml_use_cross
_first="${PATH%%:*}"
_after=$(ocaml_cross_check 2>&1 >/dev/null)
if [[ -n "${_warn}" && -z "${_after}" && "${_first}" == "${SHIMS}" && "$(shims_on_path)" == "1" ]]; then
  echo "  PASS: warned while shadowed, ${SHIMS} first and once after ocaml_use_cross"
else
  echo "  FAIL: warn='${_warn}' after='${_after}' first='${_first}' count=$(shims_on_path)"
  ERRORS=$((ERRORS + 1))
fi
_p=":${PATH}:"
_p="${_p//":${WORK}:"/:}"
_p="${_p#:}"
export PATH="${_p%:}"
rm -rf "${WORK}"

echo "Test 10: a Unix bytecode program runs on the cross tree's ocamlrun"
WORK=$(mktemp -d)
echo 'let () = ignore (Unix.getpid ()); print_string "unix-ok"' > "${WORK}/t.ml"
_out=$(cd "${WORK}" && PATH="${SHIMS}:/usr/bin:/bin" \
  ocamlc -I +unix unix.cma t.ml -o t.byte 2>&1 && \
  PATH="${SHIMS}:/usr/bin:/bin" "${CROSS}/bin/ocamlrun" t.byte 2>&1 || true)
if [[ "${_out}" == "unix-ok" ]]; then
  echo "  PASS: ${CROSS}/bin/ocamlrun loaded the unix stubs"
else
  echo "  FAIL: printed '${_out}' (expected 'unix-ok')"
  ls "${CROSS_LIB}/stublibs" 2>&1 | sed 's/^/    /'
  ERRORS=$((ERRORS + 1))
fi
rm -rf "${WORK}"

echo "Test 10b: every bare-name tool has a launcher in the shims dir"
for _t in ocamlc ocamlc.opt ocamlopt ocamlopt.opt ocamldep ocamldep.opt ocamlmklib \
          ocamlobjinfo ocaml ocamllex ocamlyacc ocamlrun; do
  if [[ -x "${SHIMS}/${_t}" ]]; then
    echo "  PASS: shims/${_t}"
  else
    echo "  FAIL: shims/${_t} missing or not executable"
    ERRORS=$((ERRORS + 1))
  fi
done

echo "Test 10c: ocamlrun from PATH runs bytecode the cross ocamlc linked"
WORK=$(mktemp -d)
echo 'let () = ignore (Unix.getpid ()); print_string "unix-ok"' > "${WORK}/t.ml"
_out=$(cd "${WORK}" && PATH="${SHIMS}:/usr/bin:/bin" \
  ocamlc -I +unix unix.cma t.ml -o t.byte 2>&1 && \
  env -u OCAMLLIB -u CAML_LD_LIBRARY_PATH PATH="${SHIMS}:/usr/bin:/bin" ocamlrun t.byte 2>&1 || true)
if [[ "${_out}" == "unix-ok" ]]; then
  echo "  PASS: bare ocamlrun ran t.byte"
else
  echo "  FAIL: printed '${_out}' (expected 'unix-ok')"
  ERRORS=$((ERRORS + 1))
fi
rm -rf "${WORK}"

echo "Test 10d: ocaml_cross_check passes"
if _out=$(ocaml_cross_check 2>&1); then
  echo "  PASS: ${_out%%$'\n'*}"
else
  echo "  FAIL: ocaml_cross_check failed: ${_out}"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 10e: in a conda build the cross mkexe links and runs against PREFIX/lib"
_mkexe=$(CONDA_BUILD=1 PREFIX=/fake/host bash -c 'ocaml_use_cross; echo "${CONDA_OCAML_MKEXE}"' 2>&1 | tail -n 1)
if [[ "${_mkexe}" == *" -L/fake/host/lib"* && "${_mkexe}" == *"-Wl,-rpath,/fake/host/lib"* ]]; then
  echo "  PASS: ${_mkexe}"
else
  echo "  FAIL: CONDA_OCAML_MKEXE='${_mkexe}'"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 10f: the scoped mkexe/mkdll the wrappers read get the same flags, once, and are restored"
_sx="CONDA_OCAML_${_OCAML_CROSS_TARGET_ID}_MKEXE"
_sd="CONDA_OCAML_${_OCAML_CROSS_TARGET_ID}_MKDLL"
_scoped=$(CONDA_BUILD=1 PREFIX=/fake/host bash -c '
  unset '"${_sx} ${_sd}"'
  ocaml_use_cross; ocaml_use_cross
  echo "${'"${_sx}"'}"
  echo "${'"${_sd}"'}"
  ocaml_use_native
  echo "${'"${_sx}"'+set}${'"${_sd}"'+set}"
  export '"${_sx}"'=prior-exe '"${_sd}"'=prior-dll
  ocaml_use_cross; ocaml_use_cross
  ocaml_use_native
  echo "${'"${_sx}"'}|${'"${_sd}"'}"
' 2>&1 | tail -n 4)
{ read -r _s_exe; read -r _s_dll; read -r _s_unset; read -r _s_prior; } <<< "${_scoped}"
_dup_exe="${_s_exe#* -L/fake/host/lib}"
_dup_dll="${_s_dll#* -L/fake/host/lib}"
if [[ "${_s_exe}" == *" -L/fake/host/lib"* && "${_s_exe}" == *"-Wl,-rpath,/fake/host/lib"* && \
      "${_dup_exe}" != *"-L/fake/host/lib"* && \
      "${_s_dll}" == *" -L/fake/host/lib"* && "${_dup_dll}" != *"-L/fake/host/lib"* && \
      -z "${_s_unset}" && "${_s_prior}" == "prior-exe|prior-dll" ]]; then
  echo "  PASS: scoped ${_sx} and ${_sd} carry -L once; unset/prior state restored"
else
  echo "  FAIL: exe='${_s_exe}' dll='${_s_dll}' after-native-unset='${_s_unset}' prior='${_s_prior}'"
  ERRORS=$((ERRORS + 1))
fi

echo "Test 11: deactivation removes the launcher dir and restores OCAMLPATH"
# shellcheck disable=SC1090
source "${DEACTIVATE}"
if [[ "$(shims_on_path)" == "0" && -z "${OCAML_CROSS_MODE:-}" ]]; then
  echo "  PASS: PATH and OCAML_CROSS_MODE restored"
else
  echo "  FAIL: PATH has ${SHIMS} $(shims_on_path) times, OCAML_CROSS_MODE='${OCAML_CROSS_MODE:-}'"
  ERRORS=$((ERRORS + 1))
fi
if [[ "${OCAMLPATH+x}" == "${ORIG_OCAMLPATH_SET}" && "${OCAMLPATH:-}" == "${ORIG_OCAMLPATH}" ]]; then
  echo "  PASS: OCAMLPATH restored to '${OCAMLPATH-<unset>}'"
else
  echo "  FAIL: OCAMLPATH='${OCAMLPATH-<unset>}' (expected '${ORIG_OCAMLPATH}', set='${ORIG_OCAMLPATH_SET}')"
  ERRORS=$((ERRORS + 1))
fi

if [[ $ERRORS -gt 0 ]]; then
  echo "=== FAILED: ${ERRORS} self-activation test(s) failed ==="
  exit 1
fi

echo "=== All self-activation tests passed ==="
