#!/usr/bin/env bash
# Shared helpers sourced by the unix test scripts; defines functions only, no side effects.

# Target binaries are foreign-arch on cross builds; run them under qemu when
# the emulator is available, natively otherwise. qemu-user loads ELF images
# only, so a #! file (OCaml bytecode) needs its interpreter resolved here the
# way binfmt_script would, and the interpreter handed to qemu instead.
run_target() {
  if [[ -n "${OCAML_QEMU:-}" ]]; then
    command -v "${OCAML_QEMU}" >/dev/null 2>&1 || { echo "[FAIL] ${OCAML_QEMU} not found on PATH" >&2; return 127; }
    if [[ -z "${QEMU_LD_PREFIX:-}" || ! -d "${QEMU_LD_PREFIX}" ]]; then
      echo "[FAIL] QEMU_LD_PREFIX not set to an existing sysroot by ${OCAML_QEMU} activation" >&2
      return 1
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
          "${OCAML_QEMU}" "$(dirname "$script")/ocamlrun" "$script" "$@"
          return
        fi
        echo "[FAIL] ${script}: native interpreter ${interp} cannot run target binaries under emulation" >&2
        return 126
      fi
      echo "[qemu] shebang ${script} -> ${interp}" >&2
      "${OCAML_QEMU}" "$interp" "$script" "$@"
      return
    fi
    "${OCAML_QEMU}" "$@"
  else
    "$@"
  fi
}

# Under qemu the conda-ocaml-* wrappers are native scripts, which cannot exec
# a target-arch tool themselves. They word-split CONDA_OCAML_* unquoted, so the
# emulator is put in front of each target tool. Call this again after
# re-sourcing an activation script, which can reset the variables.
qemu_wrap_toolchain() {
  [[ -n "${OCAML_QEMU:-}" ]] || return 0
  local _v _name _val _tool _rest _path
  for _v in CC AS LD AR RANLIB MKEXE MKDLL; do
    _name=CONDA_OCAML_${_v}
    _val=${!_name:-}
    [[ -n "${_val}" && "${_val}" != "${OCAML_QEMU} "* ]] || continue
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
    export "${_name}=${OCAML_QEMU} ${_path}${_rest}"
  done
}
