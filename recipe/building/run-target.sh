#!/usr/bin/env bash
# Run a command, wrapping it in qemu-user only when its ELF machine differs
# from the build machine's. QEMU_LD_PREFIX is set for that one command only.
# Usage: bash run-target.sh <binary> [args...]
# Env: OCAML_QEMU (interpreter), OCAML_QEMU_SYSROOT (target sysroot).
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

qemu=""
if [[ -n "${OCAML_QEMU:-}" ]]; then
  qemu=$(command -v "${OCAML_QEMU}" 2>/dev/null || true)
fi
if [[ -z "$qemu" ]]; then
  case "${target#* }" in
    22) arch=s390x ;;
    21) arch=ppc64le ;;
    183) arch=aarch64 ;;
    243) arch=riscv64 ;;
    62) arch=x86_64 ;;
    *) arch="" ;;
  esac
  if [[ -n "$arch" ]]; then
    qemu=$(command -v "qemu-execve-${arch}" 2>/dev/null || true)
  fi
fi
[[ -n "$qemu" ]] || exec "$@"

if [[ -n "${OCAML_QEMU_SYSROOT:-}" && -d "${OCAML_QEMU_SYSROOT}" ]]; then
  QEMU_LD_PREFIX="${OCAML_QEMU_SYSROOT}" exec "$qemu" "$@"
fi
exec "$qemu" "$@"
