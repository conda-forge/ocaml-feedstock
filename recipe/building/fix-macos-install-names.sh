#!/bin/bash
# fix-macos-install-names.sh - Give packaged OCaml Mach-O libraries @rpath names
#
# The runtime libraries (lib*run*.so) and stublibs (stublibs/dll*.so) are real
# files named after the runtime id; the plain names (libasmrun_shared.so,
# libcamlrun_shared.so, stublibs/dllX.so) are symlinks to them. OCaml links
# them with ids and load commands such as "runtime/libcamlrun_shared.so",
# "./dllX.so" or "@rpath/<plain name>", which rattler-build reports as
# overlinking. For every real file this:
#   - sets the id to @rpath/<own real basename>
#   - rewrites each load command naming an in-package library to
#     @rpath/<real basename of its target>, resolving plain names through
#     their symlinks
#   - adds the LC_RPATH entries (@loader_path, plus the sibling directory of
#     any dependency in the other directory) those @rpath names need
# Running it twice changes nothing the second time.
#
# Usage: fix-macos-install-names.sh <ocaml_lib_dir>
#   ocaml_lib_dir: Path to lib/ocaml directory (e.g., $PREFIX/lib/ocaml)
#
# Example:
#   fix-macos-install-names.sh "${PREFIX}/lib/ocaml"
#   fix-macos-install-names.sh "${PREFIX}/lib/ocaml-cross-compilers/arm64-apple-darwin20.0.0/lib/ocaml"

set -euo pipefail

# Conda's DYLD_* settings make the macOS system tools (install_name_tool,
# otool, codesign) load the wrong libiconv and crash.
unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH 2>/dev/null || true

OCAML_LIB="${1:?Usage: fix-macos-install-names.sh <ocaml_lib_dir>}"

if [[ ! -d "${OCAML_LIB}" ]]; then
  echo "ERROR: Directory not found: ${OCAML_LIB}"
  exit 1
fi

# Print the path of the real file behind <name> in the libdir or its stublibs,
# following symlinks; print nothing if <name> is not an in-package library.
resolve_in_package() {
  local name="$1" dir path target
  for dir in "${OCAML_LIB}" "${OCAML_LIB}/stublibs"; do
    path="${dir}/${name}"
    if [[ ! -e "${path}" ]]; then
      continue
    fi
    while [[ -L "${path}" ]]; do
      target=$(readlink "${path}")
      if [[ "${target}" == /* ]]; then
        path="${target}"
      else
        path="$(dirname "${path}")/${target}"
      fi
    done
    if [[ -f "${path}" ]]; then
      echo "${path}"
      return 0
    fi
  done
  return 0
}

# LC_RPATH path that reaches <target_dir> from a file in <lib_dir>.
rpath_between() {
  local lib_dir="$1" target_dir="$2"
  if [[ "${target_dir}" == "${lib_dir}" ]]; then
    echo "@loader_path"
  elif [[ "${lib_dir}" == "${OCAML_LIB}/stublibs" ]]; then
    echo "@loader_path/.."
  else
    echo "@loader_path/stublibs"
  fi
}

fix_one() {
  local lib="$1" real lib_dir rel id dep target_path new rp existing
  local rpaths=" @loader_path "
  real=$(basename "${lib}")
  lib_dir=$(dirname "${lib}")
  rel="${lib#"${OCAML_LIB}"/}"

  id=$(otool -D "${lib}" | sed -n '2p')
  if [[ "${id}" != "@rpath/${real}" ]]; then
    echo "    ${rel}: id ${id:-<none>} -> @rpath/${real}"
    install_name_tool -id "@rpath/${real}" "${lib}"
  fi

  while IFS= read -r dep; do
    case "${dep}" in
      runtime/*|./*|@rpath/*) ;;
      *) continue ;;
    esac
    target_path=$(resolve_in_package "$(basename "${dep}")")
    if [[ -z "${target_path}" ]]; then
      if [[ "${dep}" == @rpath/* ]]; then
        continue
      fi
      echo "ERROR: ${lib}: load command ${dep} names no library in ${OCAML_LIB}" >&2
      exit 1
    fi
    new="@rpath/$(basename "${target_path}")"
    if [[ "${dep}" != "${new}" ]]; then
      echo "    ${rel}: ${dep} -> ${new}"
      install_name_tool -change "${dep}" "${new}" "${lib}"
    fi
    rp=$(rpath_between "${lib_dir}" "$(dirname "${target_path}")")
    case "${rpaths}" in
      *" ${rp} "*) ;;
      *) rpaths="${rpaths}${rp} " ;;
    esac
  done < <(otool -L "${lib}" | tail -n +2 | awk '{print $1}')

  # An rpath already present is left alone.
  existing=$(otool -l "${lib}" | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}')
  for rp in ${rpaths}; do
    if ! grep -qxF -- "${rp}" <<< "${existing}"; then
      echo "    ${rel}: adding LC_RPATH ${rp}"
      install_name_tool -add_rpath "${rp}" "${lib}"
    fi
  done

  # install_name_tool invalidates the signature; arm64 refuses unsigned code.
  codesign -f -s - "${lib}" 2>/dev/null || true
}

echo "  Fixing install_names in ${OCAML_LIB}..."
for lib in "${OCAML_LIB}"/lib*run*.so "${OCAML_LIB}"/stublibs/dll*.so; do
  if [[ -f "${lib}" && ! -L "${lib}" ]]; then
    fix_one "${lib}"
  fi
done
echo "  Install names fixed."
