#!/usr/bin/env bash
# Regression test for native linking against compiler-libs.
# Covers issue #132: a stale prefix-dependent -L marshalled into
# compiler-libs/ocamlcommon.cmxa's lib_ccopts breaks native linking
# against it.

set -euo pipefail

VERSION="${1:-}"

# Target binaries are foreign-arch on cross builds; run them under qemu when
# the emulator is available, natively otherwise. qemu-user loads ELF images
# only, so a #! file (OCaml bytecode) needs its interpreter resolved here the
# way binfmt_script would, and the interpreter handed to qemu instead.
run_target() {
  if [[ -n "${QEMU_EXECVE:-}" ]]; then
    if [[ -n "${QEMU_LD_PREFIX:-}" && ! -d "${QEMU_LD_PREFIX}" ]]; then
      echo "[WARN] QEMU_LD_PREFIX does not exist: ${QEMU_LD_PREFIX}" >&2
      echo "[WARN] qemu will fall back to /lib and may fail confusingly" >&2
    fi
    # A bare command name is resolved here so both qemu and the #! check below
    # get a real path.
    if [[ -n "${1:-}" && "$1" != */* ]]; then
      local resolved
      resolved=$(type -P -- "$1" || true)
      if [[ -n "$resolved" ]]; then
        shift
        set -- "$resolved" "$@"
      fi
    fi
    if [[ -f "${1:-}" && "$(head -c 2 "${1:-}" 2>/dev/null)" == '#!' ]]; then
      local script="$1"
      shift
      local interp
      interp=$(head -n 1 "$script" | sed -e 's/^#![[:space:]]*//' -e 's/[[:space:]].*//')
      if [[ -z "$interp" ]]; then
        echo "[FAIL] could not parse interpreter from shebang of ${script}" >&2
        return 1
      fi
      # #!/usr/bin/env <prog> is resolved through PATH, as env itself would.
      if [[ "${interp}" == */env ]]; then
        local envprog
        envprog=$(head -n 1 "$script" | sed -e 's/^#![[:space:]]*[^[:space:]]*[[:space:]]*//' -e 's/[[:space:]].*//')
        if [[ -n "${envprog}" ]]; then
          interp=$(type -P -- "${envprog}" || echo "${interp}")
        fi
      fi
      if [[ "${interp}" != "${PREFIX:-/nonexistent}/"* ]]; then
        # A native interpreter cannot start target binaries. OCaml's sh
        # launcher header only re-execs this file under the ocamlrun next to
        # it, so that step is done here under the emulator instead.
        local line2
        line2=$(sed -n '2p' "$script")
        if [[ "${line2}" == exec*ocamlrun* ]]; then
          echo "[qemu] sh launcher ${script} -> $(dirname "$script")/ocamlrun" >&2
          "${QEMU_EXECVE}" "$(dirname "$script")/ocamlrun" "$script" "$@"
          return
        fi
        echo "[FAIL] ${script}: native interpreter ${interp} cannot run target binaries under emulation" >&2
        return 126
      fi
      echo "[qemu] shebang ${script} -> ${interp}" >&2
      "${QEMU_EXECVE}" "$interp" "$script" "$@"
      return
    fi
    "${QEMU_EXECVE}" "$@"
  else
    "$@"
  fi
}

echo "=== compiler-libs native link test ==="

# Under qemu the conda-ocaml-* wrappers are native scripts, which cannot exec
# a target-arch tool themselves. They word-split CONDA_OCAML_* unquoted, so the
# emulator is put in front of each target tool. Call this again after
# re-sourcing an activation script, which can reset the variables.
qemu_wrap_toolchain() {
  [[ -n "${QEMU_EXECVE:-}" ]] || return 0
  local _v _name _val _tool _rest _path
  for _v in CC AS LD AR RANLIB MKEXE MKDLL; do
    _name=CONDA_OCAML_${_v}
    _val=${!_name:-}
    [[ -n "${_val}" && "${_val}" != "${QEMU_EXECVE} "* ]] || continue
    _tool=${_val%% *}
    _rest=
    [[ "${_val}" == *" "* ]] && _rest=" ${_val#* }"
    _path=$(type -P -- "${_tool}" || true)
    if [[ -z "${_path}" ]]; then
      echo "[WARN] ${_name}: ${_tool} not found on PATH, left unprefixed" >&2
      continue
    fi
    # Only target tools under $PREFIX need the emulator; a native script such
    # as a test's logging wrapper is left as it is.
    [[ "${_path}" == "${PREFIX:-/nonexistent}/"* ]] || continue
    export "${_name}=${QEMU_EXECVE} ${_path}${_rest}"
  done
}

# Same fallback convention as test-compilation.sh's cc_cmd="${CONDA_OCAML_CC:-cc}".
# ocamlopt drives external linking through the conda-ocaml-mkexe wrapper, which
# needs these set or the link fails earlier with a missing -gcc driver error,
# unrelated to the issue this test covers.
export CONDA_OCAML_CC="${CONDA_OCAML_CC:-cc}"
export CONDA_OCAML_MKEXE="${CONDA_OCAML_MKEXE:-${CONDA_OCAML_CC}}"
export CONDA_OCAML_MKDLL="${CONDA_OCAML_MKDLL:-${CONDA_OCAML_CC} -shared}"
qemu_wrap_toolchain

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT
cd "${TMPDIR_TEST}"

printf 'let () = print_string Config.version\n' > t.ml

echo "=== Testing native link against compiler-libs ==="
if run_target ocamlopt -I +compiler-libs ocamlcommon.cmxa t.ml -o t > link_out.txt 2>&1; then
  echo "  link: OK"
else
  echo "  [FAIL] native link against compiler-libs failed"
  echo "  ocamlopt output:"
  cat link_out.txt
  exit 1
fi

# Diagnostic only: show the Extra C options recorded in ocamlcommon.cmxa,
# where the stale -L is recorded. Does not affect PASS/FAIL.
if command -v ocamlobjinfo >/dev/null 2>&1; then
  CMXA_PATH="$(run_target ocamlopt -where)/compiler-libs/ocamlcommon.cmxa"
  echo "  Extra C options for ocamlcommon.cmxa (diagnostic):"
  run_target ocamlobjinfo "${CMXA_PATH}" 2>/dev/null | grep "Extra C options" || echo "    (not found)"
fi

# Bonus check: run the produced executable if this platform can run it.
# Cross-targets under emulation may not run it; only the link is required.
if [[ -x ./t ]]; then
  if run_target ./t > run_out.txt 2>&1; then
    ACTUAL_VERSION="$(cat run_out.txt)"
    echo "  execution: OK (${ACTUAL_VERSION})"
    if [[ -n "${VERSION}" && "${ACTUAL_VERSION}" != "${VERSION}" ]]; then
      echo "  [FAIL] version mismatch: expected ${VERSION}, got ${ACTUAL_VERSION}"
      exit 1
    fi
  else
    echo "  execution: SKIP (binary could not run on this host)"
  fi
fi

echo "=== compiler-libs native link test passed ==="
