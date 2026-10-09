#!/usr/bin/env bash
# cross-ocamlmklib - wrapper that uses CROSS_CC/CROSS_AR instead of hardcoded Config values
#
# ocamlmklib has Config.mkdll and Config.ar baked in from compile time (BUILD tools).
# For cross-compilation, we need to use the TARGET cross-compiler instead.
#
# This wrapper handles two cases:
# 1. C-only builds (.o files): Uses CROSS_CC/CROSS_AR directly
# 2. Mixed builds (.cmo/.cmx + .o files): Builds C libs with cross tools, then calls
#    real ocamlmklib for OCaml parts (which uses -ocamlc/-ocamlopt flags correctly)
#
# Environment variables (must be set by caller):
#   CROSS_CC  - Target C compiler (e.g., aarch64-...-gcc)
#   CROSS_AR  - Target archiver (e.g., aarch64-...-ar)

set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# CRITICAL: Ensure we're using conda bash 5.2+, not system bash
# ==============================================================================
if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  echo "re-exec with conda bash..."
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

# macOS needs -undefined dynamic_lookup to defer OCaml runtime symbol resolution to runtime
# Without this, the linker fails with "Undefined symbols for architecture arm64: _caml_alloc_small..."
if [[ "$(uname)" == "Darwin" ]]; then
  MACOS_LINK_FLAGS=(-undefined dynamic_lookup)
else
  MACOS_LINK_FLAGS=()
fi

# Build shared (.so) and static (.a) C libraries using cross-tools.
# Usage: _build_c_libs <output_name>
# Requires: CROSS_CC, CROSS_AR, c_objs[], ld_opts[], c_libs[], MACOS_LINK_FLAGS[], verbose
_build_c_libs() {
  local _name="$1"
  local dll_name="dll${_name}.so"
  local lib_name="lib${_name}.a"

  local cmd=("${CROSS_CC}" -shared ${MACOS_LINK_FLAGS[@]+"${MACOS_LINK_FLAGS[@]}"} -o "$dll_name" "${c_objs[@]}" ${ld_opts[@]+"${ld_opts[@]}"} ${c_libs[@]+"${c_libs[@]}"})
  [[ -n "$verbose" ]] && echo "+ ${cmd[*]}"
  "${cmd[@]}"

  rm -f "$lib_name"
  cmd=("${CROSS_AR}" rcs "$lib_name" "${c_objs[@]}")
  [[ -n "$verbose" ]] && echo "+ ${cmd[*]}"
  "${cmd[@]}"
}

# Parse arguments
output=""
output_c=""
c_objs=()
ocaml_objs=()
ld_opts=()
c_libs=()
verbose=""
ocamlc_cmd=""
ocamlopt_cmd=""
other_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -oc)
      output_c="$2"
      other_args+=("$1" "$2")
      shift 2
      ;;
    -o)
      output="$2"
      other_args+=("$1" "$2")
      shift 2
      ;;
    -ocamlc)
      ocamlc_cmd="$2"
      other_args+=("$1" "$2")
      shift 2
      ;;
    -ocamlopt)
      ocamlopt_cmd="$2"
      other_args+=("$1" "$2")
      shift 2
      ;;
    -v|-verbose)
      verbose=1
      other_args+=("$1")
      shift
      ;;
    -l*)
      c_libs+=("$1")
      other_args+=("$1")
      shift
      ;;
    -L*)
      ld_opts+=("$1")
      other_args+=("$1")
      shift
      ;;
    -cclib|-ccopt|-ocamlcflags|-ocamloptflags|-ldopt|-I)
      other_args+=("$1" "$2")
      shift 2
      ;;
    -*)
      other_args+=("$1")
      shift
      ;;
    *.o|*.a)
      c_objs+=("$1")
      other_args+=("$1")
      shift
      ;;
    *.cmo|*.cma|*.cmx|*.ml|*.mli)
      ocaml_objs+=("$1")
      other_args+=("$1")
      shift
      ;;
    *)
      other_args+=("$1")
      shift
      ;;
  esac
done

# If we have OCaml files, we need the native ocamlmklib for the OCaml archive creation
# But we still need to intercept C stub library creation
if [[ ${#ocaml_objs[@]} -gt 0 ]]; then
  # For mixed builds, we build the C stub libs ourselves, then delegate to native ocamlmklib
  # BUT ocamlmklib expects to find the C libs in the directory to link into the .cma/.cmxa

  if [[ ${#c_objs[@]} -gt 0 ]]; then
    if [[ -z "${CROSS_CC:-}" ]]; then
      echo "[cross-ocamlmklib] ERROR: CROSS_CC not set" >&2
      exit 1
    fi

    if [[ -z "${CROSS_AR:-}" ]]; then
      echo "[cross-ocamlmklib] ERROR: CROSS_AR not set" >&2
      exit 1
    fi

    _output_c="${output_c:-$output}"
    if [[ -z "$_output_c" ]]; then
      echo "[cross-ocamlmklib] ERROR: No -oc or -o output name specified" >&2
      exit 1
    fi

    _build_c_libs "${_output_c}"
  fi

  # Now call native ocamlmklib for OCaml archive creation
  # Remove C object files from args since we already handled them
  # Use "ocamlrun ocamlmklib" because cached ocamlmklib has stale shebang path

  # Run ocamlmklib via ocamlrun to avoid stale shebang
  # Use an array to avoid IFS issues (IFS=$'\n\t' at top removes space as separator)
  native_mklib_cmd=()
  native_mklib_path=$(command -v ocamlmklib 2>/dev/null || true)
  ocamlrun_path=$(command -v ocamlrun 2>/dev/null || true)
  if [[ -n "$native_mklib_path" ]] && [[ -n "$ocamlrun_path" ]]; then
    # Use absolute paths to avoid PATH issues in sub-directories
    native_mklib_cmd=("$ocamlrun_path" "$native_mklib_path")
  elif [[ -n "$native_mklib_path" ]]; then
    # Fallback: run ocamlmklib directly (may have stale shebang)
    native_mklib_cmd=("$native_mklib_path")
  fi

  # Build new args without C objects
  native_args=()
  i=0
  while [[ $i -lt ${#other_args[@]} ]]; do
    arg="${other_args[$i]}"
    case "$arg" in
      *.o|*.a)
        # Skip C objects, they're already built
        ;;
      *)
        native_args+=("$arg")
        ;;
    esac
    ((i++)) || true
  done

  exec "${native_mklib_cmd[@]}" "${native_args[@]}"
else
  # C-only build - handle entirely ourselves
  # Use -oc if provided, otherwise fall back to -o (like real ocamlmklib)
  _output_c="${output_c:-$output}"
  if [[ -z "$_output_c" ]]; then
    echo "[cross-ocamlmklib] ERROR: No -oc or -o output name specified" >&2
    exit 1
  fi

  if [[ ${#c_objs[@]} -eq 0 ]]; then
    echo "[cross-ocamlmklib] ERROR: No .o files specified" >&2
    exit 1
  fi

  if [[ -z "${CROSS_CC:-}" ]]; then
    echo "[cross-ocamlmklib] ERROR: CROSS_CC not set" >&2
    exit 1
  fi

  if [[ -z "${CROSS_AR:-}" ]]; then
    echo "[cross-ocamlmklib] ERROR: CROSS_AR not set" >&2
    exit 1
  fi

  _build_c_libs "${_output_c}"
fi
