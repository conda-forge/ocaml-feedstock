#!/usr/bin/env bash
# Run a command; a foreign-arch ELF runs only under the literal qemu-execve-<arch>
# named by OCAML_QEMU, never directly. QEMU_LD_PREFIX is set for that one command only.
# Usage: bash run-target.sh <binary> [args...]
# Env: OCAML_QEMU (qemu-execve-<arch>), OCAML_QEMU_SYSROOT (target sysroot).
set -euo pipefail

# Prints "<EI_DATA> <e_machine>" for an ELF file; fails for anything else.
elf_machine() {
  local f="$1" magic data b0 b1
  [[ -f "$f" && -r "$f" ]] || return 1
  magic=$(od -An -tx1 -N4 "$f" | tr -d ' \n')
  [[ "$magic" == "7f454c46" ]] || return 1
  data=$(od -An -tu1 -j5 -N1 "$f" | tr -d ' \n')
  read -r b0 b1 < <(od -An -tu1 -j18 -N2 "$f")
  if [[ "$data" == "2" ]]; then
    echo "$data $((b0 * 256 + b1))"
  else
    echo "$data $((b1 * 256 + b0))"
  fi
}

[[ $# -ge 1 ]] || { echo "usage: run-target.sh <binary> [args...]" >&2; exit 2; }
bin="$1"
[[ "$bin" == */* ]] || bin=$(command -v "$bin" 2>/dev/null || true)

target=$(elf_machine "$bin" 2>/dev/null) || exec "$@"
# qemu-execve does not search PATH, so hand it the resolved path.
shift
set -- "$bin" "$@"
build=$(elf_machine "${BASH}" 2>/dev/null) || exec "$@"
[[ "${target#* }" != "${build#* }" ]] || exec "$@"

if [[ -z "${OCAML_QEMU:-}" ]]; then
  echo "run-target.sh: ${bin} is a foreign ELF (e_machine ${target#* }) but OCAML_QEMU is empty" >&2
  exit 126
fi
if ! command -v "${OCAML_QEMU}" >/dev/null 2>&1; then
  echo "run-target.sh: ${OCAML_QEMU} not found on PATH" >&2
  exit 127
fi

if [[ -n "${OCAML_QEMU_SYSROOT:-}" && -d "${OCAML_QEMU_SYSROOT}" ]]; then
  QEMU_LD_PREFIX="${OCAML_QEMU_SYSROOT}" exec "${OCAML_QEMU}" "$@"
fi
exec "${OCAML_QEMU}" "$@"
