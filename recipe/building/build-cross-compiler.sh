#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ============================================================================
# CROSS-COMPILERS (only on linux-64 and osx-64)
# ============================================================================
if [[ "${target_platform}" == "linux-64" ]] || [[ "${target_platform}" == "osx-64" ]]; then

  # Define cross targets based on build platform
  declare -A CROSS_TARGETS
  if [[ "${build_platform}" == "linux-64" ]]; then
    CROSS_TARGETS=(
      ["aarch64-conda-linux-gnu"]="arm64:linux"
      ["powerpc64le-conda-linux-gnu"]="power:linux:ppc64le"
    )
  elif [[ "${build_platform}" == "osx-64" ]]; then
    CROSS_TARGETS=(
      ["arm64-apple-darwin20.0.0"]="arm64:macos"
    )
  fi

  for target in "${!CROSS_TARGETS[@]}"; do
    IFS=':' read -r _ARCH _PLATFORM _MODEL <<< "${CROSS_TARGETS[$target]}"

    echo "=== Building cross-compiler for ${target} ==="

    CROSS_PREFIX="${PREFIX}/ocaml-cross-compilers/${target}"
    mkdir -p "${CROSS_PREFIX}/bin" "${CROSS_PREFIX}/lib/ocaml"

    # Get cross-toolchain
    _CC="${BUILD_PREFIX}/bin/${target}-cc"
    _AR="${BUILD_PREFIX}/bin/${target}-ar"
    _AS="${BUILD_PREFIX}/bin/${target}-as"

    # Configure for cross target (reuses native build artifacts)
    ./configure -prefix="${CROSS_PREFIX}" \
      --target="${target}" \
      "${CONFIG_ARGS[@]}" \
      ${_MODEL:+ac_cv_func_getentropy=no}

    # Patch config.generated.ml for cross output
    config_file="utils/config.generated.ml"
    if [[ "${_PLATFORM}" == "macos" ]]; then
      sed -i "s#^let asm = .*#let asm = {|${_CC} -c|}#" "$config_file"
      sed -i "s#^let mkdll = .*#let mkdll = {|${_CC} -shared -undefined dynamic_lookup|}#" "$config_file"
    else
      sed -i "s#^let asm = .*#let asm = {|${_AS}|}#" "$config_file"
      sed -i "s#^let mkdll = .*#let mkdll = {|${_CC} -shared|}#" "$config_file"
    fi
    sed -i "s#^let c_compiler = .*#let c_compiler = {|${_CC}|}#" "$config_file"
    [[ -n "${_MODEL}" ]] && sed -i "s#^let model = .*#let model = {|${_MODEL}|}#" "$config_file"

    # Apply cross patches
    cp "${RECIPE_DIR}"/building/Makefile.cross .
    patch -N -p0 < "${RECIPE_DIR}"/building/tmp_Makefile.patch || true

    # Build cross-compiler
    make crossopt \
      ARCH="${_ARCH}" \
      AS="${_AS}" \
      ASPP="${_CC} -c" \
      CC="${_CC}" \
      CROSS_CC="${_CC}" \
      CROSS_AR="${_AR}" \
      SAK_CC="${CC}" \
      SAK_CFLAGS="${CFLAGS}" \
      -j${CPU_COUNT}

    # Install cross-compiler
    make installcross

    # Rename binaries with target prefix and move to main bin/
    for bin in "${CROSS_PREFIX}/bin/"*; do
      [[ -f "$bin" ]] || continue
      name=$(basename "$bin")
      mv "$bin" "${PREFIX}/bin/${target}-${name}"
    done
    rmdir "${CROSS_PREFIX}/bin"

  done
fi
