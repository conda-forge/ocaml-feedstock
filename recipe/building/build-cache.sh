#!/usr/bin/env bash
# build-cache.sh — Progressive build cache functions for OCaml feedstock builds.
#
# Caches successful build INSTALLED ARTIFACTS to speed up iterative debugging.
# Enable with OCAML_USE_CACHE=1 in recipe or environment.
# Cache location: ${RECIPE_DIR}/.build_cache/
#
# Sourced by common-functions.sh.

# ==============================================================================
# Progressive Build Cache
# ==============================================================================
# Caches successful build INSTALLED ARTIFACTS to speed up iterative debugging.
# Enable with OCAML_USE_CACHE=1 in recipe or environment.
# Cache location: ${RECIPE_DIR}/.build_cache/
#
# Cache structure (ONLY installed artifacts, NOT source trees):
#   .build_cache/
#     native_${PKG_VERSION}_${build_platform}/     - Native compiler install dir
#     xcross_${PKG_VERSION}_${target_platform}/    - Cross-compiler install dir
#
# Usage:
#   if cache_native_exists; then
#     cache_native_restore  # Restore installed compiler
#     # Skip build_native entirely
#   else
#     build_native
#     cache_native_save
#   fi
# ==============================================================================

# Check if caching is enabled
cache_enabled() {
  [[ "${OCAML_USE_CACHE:-0}" == "1" ]]
}

# Get cache root directory
cache_root() {
  echo "${RECIPE_DIR}/.build_cache"
}

# Get a short hash of build scripts to detect source changes that invalidate cache
# (e.g., configure.ac format changes, patch updates, Makefile rule changes)
_cache_source_hash() {
  local hash_input="${PKG_VERSION}"
  # Include build script and patches in hash — any change invalidates cache
  for f in "${RECIPE_DIR}/build.sh" "${RECIPE_DIR}/building/common-functions.sh"; do
    [[ -f "$f" ]] && hash_input+="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)"
  done
  echo "${hash_input}" | md5sum | cut -c1-8
}

# Get cache key for native compiler install
cache_key_native() {
  echo "native_${PKG_VERSION}_${build_platform:-linux-64}_$(_cache_source_hash)"
}

# Get cache key for cross-compiler
cache_key_xcross() {
  local target="${1:-${OCAML_TARGET_PLATFORM:-${cross_target_platform}}}"
  echo "xcross_${PKG_VERSION}_${target}_$(_cache_source_hash)"
}

# Check if native compiler cache exists
cache_native_exists() {
  cache_enabled || return 1
  local cache_dir
  cache_dir="$(cache_root)/$(cache_key_native)"
  [[ -d "${cache_dir}" ]] && [[ -f "${cache_dir}/bin/ocamlopt" ]]
}

# Check if cross-compiler cache exists
cache_xcross_exists() {
  cache_enabled || return 1
  local target="${1:-${OCAML_TARGET_PLATFORM:-${cross_target_platform}}}"
  local cache_dir
  cache_dir="$(cache_root)/$(cache_key_xcross "${target}")"
  [[ -d "${cache_dir}" ]] && [[ -d "${cache_dir}/lib/ocaml-cross-compilers" ]]
}

# Save native compiler install directory to cache
# Only caches OCaml artifacts, NOT env files (they contain build-specific paths)
cache_native_save() {
  cache_enabled || return 0
  local src_dir="${1:-${OCAML_NATIVE_INSTALL_PREFIX:-${SRC_DIR}/_native_compiler}}"
  local cache_dir
  cache_dir="$(cache_root)/$(cache_key_native)"

  echo "  [CACHE] Saving native compiler to cache..."
  echo "          Source: ${src_dir}"
  echo "          Cache:  ${cache_dir}"

  mkdir -p "$(cache_root)"
  rm -rf "${cache_dir}"
  cp -a "${src_dir}" "${cache_dir}"

  echo "  [CACHE] Native compiler cached successfully"
}

# Save cross-compiler install directory to cache
# Only caches OCaml artifacts, NOT env files (they contain build-specific paths)
cache_xcross_save() {
  cache_enabled || return 0
  local src_dir="${1:-${OCAML_XCROSS_INSTALL_PREFIX:-${SRC_DIR}/_xcross_compiler}}"
  local target="${2:-${OCAML_TARGET_PLATFORM:-${cross_target_platform}}}"
  local cache_dir
  cache_dir="$(cache_root)/$(cache_key_xcross "${target}")"

  echo "  [CACHE] Saving cross-compiler (${target}) to cache..."
  echo "          Source: ${src_dir}"
  echo "          Cache:  ${cache_dir}"

  mkdir -p "$(cache_root)"
  rm -rf "${cache_dir}"
  cp -a "${src_dir}" "${cache_dir}"

  echo "  [CACHE] Cross-compiler (${target}) cached successfully"
}

# Restore native compiler from cache
# Only restores OCaml artifacts - env files are generated fresh by caller
cache_native_restore() {
  cache_enabled || return 1
  local dst_dir="${1:-${OCAML_NATIVE_INSTALL_PREFIX:-${SRC_DIR}/_native_compiler}}"
  local cache_dir
  cache_dir="$(cache_root)/$(cache_key_native)"

  if ! cache_native_exists; then
    echo "  [CACHE] No native compiler cache found"
    return 1
  fi

  echo "  [CACHE] Restoring native compiler from cache..."
  echo "          Cache:  ${cache_dir}"
  echo "          Target: ${dst_dir}"

  mkdir -p "$(dirname "${dst_dir}")"
  rm -rf "${dst_dir}"
  cp -a "${cache_dir}" "${dst_dir}"

  # Set OCAMLLIB to override baked-in stdlib path
  # This allows cached compiler to find stdlib at current build location
  local current_stdlib_path="${dst_dir}/lib/ocaml"
  export OCAMLLIB="${current_stdlib_path}"
  export CAML_LD_LIBRARY_PATH="${current_stdlib_path}/stublibs"
  echo "  [CACHE] Set OCAMLLIB=${OCAMLLIB} to override cached compiler's baked-in path"

  # CRITICAL: Clean stale .cmi files from source tree that have old stdlib CRCs
  # When using cached native compiler for cross-compilation, the source tree may have
  # .cmi files from a previous build that were compiled against the OLD stdlib.
  # These must be removed so the cross-compiler build generates fresh .cmi files
  # with CRCs matching the NEW stdlib that will be built.
  # This prevents "inconsistent assumptions over interface Stdlib" errors.
  echo "  [CACHE] Cleaning stale .cmi files from source tree..."
  rm -f "${SRC_DIR}"/utils/*.cmi "${SRC_DIR}"/parsing/*.cmi "${SRC_DIR}"/lambda/*.cmi 2>/dev/null || true
  rm -f "${SRC_DIR}"/bytecomp/*.cmi "${SRC_DIR}"/file_formats/*.cmi "${SRC_DIR}"/typing/*.cmi 2>/dev/null || true
  rm -f "${SRC_DIR}"/driver/*.cmi "${SRC_DIR}"/toplevel/*.cmi "${SRC_DIR}"/asmcomp/*.cmi 2>/dev/null || true
  rm -f "${SRC_DIR}"/middle_end/*.cmi "${SRC_DIR}"/middle_end/**/*.cmi 2>/dev/null || true
  rm -f "${SRC_DIR}"/stdlib/*.cmi "${SRC_DIR}"/stdlib/*.cmo "${SRC_DIR}"/stdlib/*.cma 2>/dev/null || true
  rm -f "${SRC_DIR}"/stdlib/*.cmx "${SRC_DIR}"/stdlib/*.cmxa "${SRC_DIR}"/stdlib/*.o "${SRC_DIR}"/stdlib/*.a 2>/dev/null || true
  rm -f "${SRC_DIR}"/otherlibs/unix/*.cmi "${SRC_DIR}"/otherlibs/str/*.cmi 2>/dev/null || true
  rm -f "${SRC_DIR}"/otherlibs/dynlink/*.cmi "${SRC_DIR}"/otherlibs/dynlink/native/*.cmi 2>/dev/null || true
  rm -f "${SRC_DIR}"/otherlibs/systhreads/*.cmi "${SRC_DIR}"/otherlibs/runtime_events/*.cmi 2>/dev/null || true

  echo "  [CACHE] Native compiler restored successfully"
  return 0
}

# Restore cross-compiler from cache
# Only restores OCaml artifacts - env files are generated fresh by caller
cache_xcross_restore() {
  cache_enabled || return 1
  local dst_dir="${1:-${OCAML_XCROSS_INSTALL_PREFIX:-${SRC_DIR}/_xcross_compiler}}"
  local target="${2:-${OCAML_TARGET_PLATFORM:-${cross_target_platform}}}"
  local cache_dir
  cache_dir="$(cache_root)/$(cache_key_xcross "${target}")"

  if ! cache_xcross_exists "${target}"; then
    echo "  [CACHE] No cross-compiler cache found for ${target}"
    return 1
  fi

  echo "  [CACHE] Restoring cross-compiler (${target}) from cache..."
  echo "          Cache:  ${cache_dir}"
  echo "          Target: ${dst_dir}"

  mkdir -p "$(dirname "${dst_dir}")"
  rm -rf "${dst_dir}"
  cp -a "${cache_dir}" "${dst_dir}"

  # Set OCAMLLIB to override baked-in stdlib path
  # This allows cached compiler to find stdlib at current build location
  local current_stdlib_path="${dst_dir}/lib/ocaml"
  export OCAMLLIB="${current_stdlib_path}"
  export CAML_LD_LIBRARY_PATH="${current_stdlib_path}/stublibs"
  echo "  [CACHE] Set OCAMLLIB=${OCAMLLIB} to override cached compiler's baked-in path"

  echo "  [CACHE] Cross-compiler (${target}) restored successfully"
  return 0
}

# Show cache status
cache_status() {
  local cache_root_dir
  cache_root_dir="$(cache_root)"

  echo "=== Build Cache Status ==="
  echo "  Enabled: ${OCAML_USE_CACHE:-0}"
  echo "  Location: ${cache_root_dir}"

  if [[ -d "${cache_root_dir}" ]]; then
    echo "  Cached stages:"
    for entry in "${cache_root_dir}"/*/; do
      [[ -d "${entry}" ]] || continue
      local name
      name=$(basename "${entry}")
      local size
      size=$(du -sh "${entry}" 2>/dev/null | cut -f1)
      echo "    - ${name} (${size})"
    done
  else
    echo "  No cache directory exists"
  fi
}
