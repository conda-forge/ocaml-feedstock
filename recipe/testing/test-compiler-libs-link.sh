#!/usr/bin/env bash
# Regression test for native linking against compiler-libs.
# Covers issue #132: a stale prefix-dependent -L marshalled into
# compiler-libs/ocamlcommon.cmxa's lib_ccopts breaks native linking
# against it.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

VERSION="${1:-}"

echo "=== compiler-libs native link test ==="

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
