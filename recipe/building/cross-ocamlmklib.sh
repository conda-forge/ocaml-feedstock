#!/bin/bash
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
#   CROSS_OCAMLMKLIB_NATIVE - Path to native ocamlmklib (optional, defaults to PATH search)
#   CROSS_OCAMLMKLIB_DEBUG - Set to 1 for verbose output

set -eu

debug() {
  if [[ "${CROSS_OCAMLMKLIB_DEBUG:-}" == "1" ]]; then
    echo "[cross-ocamlmklib] $*" >&2
  fi
}

debug "Args: $*"
debug "CROSS_CC=${CROSS_CC:-unset}"
debug "CROSS_AR=${CROSS_AR:-unset}"

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
      debug "WARNING: Unknown argument: $1"
      other_args+=("$1")
      shift
      ;;
  esac
done

debug "C objects: ${c_objs[*]:-none}"
debug "OCaml objects: ${ocaml_objs[*]:-none}"

# If we have OCaml files, we need the native ocamlmklib for the OCaml archive creation
# But we still need to intercept C stub library creation
if [[ ${#ocaml_objs[@]} -gt 0 ]]; then
  debug "Mixed build detected - OCaml + C files"

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

    # Build shared library with cross-compiler
    dll_name="dll${_output_c}.so"
    debug "Building shared library: $dll_name"
    cmd=("${CROSS_CC}" -shared -o "$dll_name" "${c_objs[@]}" "${ld_opts[@]}" "${c_libs[@]}")
    if [[ -n "$verbose" ]]; then
      echo "+ ${cmd[*]}"
    fi
    "${cmd[@]}"

    # Build static library with cross-archiver
    lib_name="lib${_output_c}.a"
    debug "Building static library: $lib_name"
    rm -f "$lib_name"
    cmd=("${CROSS_AR}" rcs "$lib_name" "${c_objs[@]}")
    if [[ -n "$verbose" ]]; then
      echo "+ ${cmd[*]}"
    fi
    "${cmd[@]}"

    debug "Built C libs: $dll_name, $lib_name"
  fi

  # Now call native ocamlmklib for OCaml archive creation
  # Remove C object files from args since we already handled them
  # Use "ocamlrun ocamlmklib" because cached ocamlmklib has stale shebang path
  native_mklib="${CROSS_OCAMLMKLIB_NATIVE:-ocamlmklib}"

  # If native_mklib is just "ocamlmklib", run it via ocamlrun to avoid stale shebang
  if [[ "$native_mklib" == "ocamlmklib" ]]; then
    native_mklib_path=$(command -v ocamlmklib 2>/dev/null || true)
    if [[ -n "$native_mklib_path" ]]; then
      native_mklib="ocamlrun $native_mklib_path"
    fi
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

  debug "Delegating to native ocamlmklib: $native_mklib ${native_args[*]}"
  # shellcheck disable=SC2086
  exec $native_mklib "${native_args[@]}"
else
  # C-only build - handle entirely ourselves
  debug "C-only build detected"

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

  # Build shared library: dll<name>.so
  dll_name="dll${_output_c}.so"
  debug "Building shared library: $dll_name"
  cmd=("${CROSS_CC}" -shared -o "$dll_name" "${c_objs[@]}" "${ld_opts[@]}" "${c_libs[@]}")
  if [[ -n "$verbose" ]]; then
    echo "+ ${cmd[*]}"
  fi
  "${cmd[@]}"

  # Build static library: lib<name>.a
  lib_name="lib${_output_c}.a"
  debug "Building static library: $lib_name"
  rm -f "$lib_name"
  cmd=("${CROSS_AR}" rcs "$lib_name" "${c_objs[@]}")
  if [[ -n "$verbose" ]]; then
    echo "+ ${cmd[*]}"
  fi
  "${cmd[@]}"

  debug "Done: created $dll_name and $lib_name"
fi
