#!/bin/bash
# ============================================================================
# CROSS-COMPILERS BUILD SCRIPT
# Builds cross-compilers for aarch64/ppc64le (on linux-64) or arm64 (on osx-64)
#
# Variables:
#   OCAML_PREFIX         - Where native OCaml is installed (source for native tools)
#   OCAML_INSTALL_PREFIX - Where cross-compilers will be installed (destination)
# ============================================================================

set -euo pipefail

# Source common functions
source "${RECIPE_DIR}/building/common-functions.sh"

# Only run on native build platforms
if [[ "${target_platform}" != "linux-64" ]] && [[ "${target_platform}" != "osx-64" ]]; then
  echo "No cross-compiler recipe for ${target_platform} ... yet"
  return 0
fi

# ============================================================================
# Configuration
# ============================================================================

# OCAML_PREFIX = where native OCaml is installed (source for native tools)
# OCAML_INSTALL_PREFIX = where cross-compilers will be installed (destination)
: "${OCAML_PREFIX:=${PREFIX}}"
: "${OCAML_INSTALL_PREFIX:=${PREFIX}}"

# Save native CONDA_OCAML_* values BEFORE the loop
# These are needed for building native tools that run on the BUILD machine
NATIVE_AS="${CONDA_OCAML_AS:-${BUILD_PREFIX}/bin/as}"
NATIVE_CC="${CONDA_OCAML_CC:-${CC}}"

# Native OCaml library location
OCAMLLIB="${OCAML_PREFIX}/lib/ocaml"

# Define cross targets based on build platform
declare -a CROSS_TARGETS
if [[ "${target_platform}" == "linux-64" ]]; then
  CROSS_TARGETS=(
    "aarch64-conda-linux-gnu"
    "powerpc64le-conda-linux-gnu"
  )
elif [[ "${target_platform}" == "osx-64" ]]; then
  CROSS_TARGETS=(
    "arm64-apple-darwin20.0.0"
  )
fi

# ============================================================================
# Build loop
# ============================================================================

echo ""
echo "============================================================"
echo "Cross-compiler build configuration"
echo "============================================================"
echo "  Native OCaml (source):    ${OCAML_PREFIX}"
echo "  Cross install (dest):     ${OCAML_INSTALL_PREFIX}"
echo "  Native ocamlopt:          ${OCAML_PREFIX}/bin/ocamlopt"

for target in "${CROSS_TARGETS[@]}"; do
  echo ""
  echo "============================================================"
  echo "Building cross-compiler for ${target}"
  echo "============================================================"

  # Get target properties using common functions
  CROSS_ARCH=$(get_target_arch "${target}")
  CROSS_PLATFORM=$(get_target_platform_type "${target}")
  CROSS_TARGET_ID=$(get_target_id "${target}")

  # Handle PowerPC model override
  CROSS_MODEL=""
  [[ "${target}" == "powerpc64le-"* ]] && CROSS_MODEL="ppc64le"

  # Setup cross-toolchain (sets CROSS_CC, CROSS_AS, CROSS_AR, etc.)
  setup_cross_toolchain "${target}"

  # Export CONDA_OCAML_<TARGET_ID>_* variables
  export_cross_conda_vars "${target}"

  echo "  Target:     ${target}"
  echo "  Arch:       ${CROSS_ARCH}"
  echo "  Platform:   ${CROSS_PLATFORM}"
  echo "  CROSS_CC:   ${CROSS_CC}"
  echo "  CROSS_AS:   ${CROSS_AS}"
  echo "  CROSS_AR:   ${CROSS_AR}"

  # Installation prefix for this cross-compiler
  CROSS_PREFIX="${OCAML_INSTALL_PREFIX}/lib/ocaml-cross-compilers/${target}"
  CROSS_LIBDIR="${CROSS_PREFIX}/lib/ocaml"
  mkdir -p "${CROSS_PREFIX}/bin" "${CROSS_LIBDIR}"

  # ========================================================================
  # Clean and configure
  # ========================================================================

  echo "  [1/5] Cleaning previous build..."
  make distclean > /dev/null 2>&1 || true

  echo "  [2/5] Configuring for ${target}..."
  # PKG_CONFIG=false forces simple "-lzstd" instead of "-L/long/path -lzstd"
  # Do NOT pass CC here - configure needs BUILD compiler
  PKG_CONFIG=false ./configure \
    -prefix="${CROSS_PREFIX}" \
    --target="${target}" \
    "${CONFIG_ARGS[@]}" \
    AR="${CROSS_AR}" \
    RANLIB="${CROSS_RANLIB}" \
    NM="${CROSS_NM}" \
    STRIP="${CROSS_STRIP}" \
    ${CROSS_MODEL:+ac_cv_func_getentropy=no} \
    > "${SRC_DIR}/_logs/crossconfigure_${target}.log" 2>&1 || {
      cat "${SRC_DIR}/_logs/crossconfigure_${target}.log"
      exit 1
    }

  # ========================================================================
  # Patch config.generated.ml
  # ========================================================================

  echo "  [3/5] Patching config.generated.ml..."
  config_file="utils/config.generated.ml"

  if [[ "${CROSS_PLATFORM}" == "macos" ]]; then
    sed -i 's#^let asm = .*#let asm = {|$CONDA_OCAML_CC -c|}#' "$config_file"
    sed -i 's#^let mkdll = .*#let mkdll = {|$CONDA_OCAML_MKDLL -fuse-ld=lld -Wl,-headerpad_max_install_names -undefined dynamic_lookup|}#' "$config_file"
    sed -i 's#^let mkexe = .*#let mkexe = {|$CONDA_OCAML_CC -fuse-ld=lld -Wl,-headerpad_max_install_names|}#' "$config_file"
  else
    sed -i 's#^let asm = .*#let asm = {|$CONDA_OCAML_AS|}#' "$config_file"
    sed -i 's#^let mkdll = .*#let mkdll = {|$CONDA_OCAML_MKDLL|}#' "$config_file"
    sed -i 's#^let mkexe = .*#let mkexe = {|$CONDA_OCAML_CC -Wl,-E|}#' "$config_file"
  fi
  sed -i 's#^let c_compiler = .*#let c_compiler = {|$CONDA_OCAML_CC|}#' "$config_file"
  sed -i 's#^let ar = .*#let ar = {|$CONDA_OCAML_AR|}#' "$config_file"
  sed -i 's#^let ranlib = .*#let ranlib = {|$CONDA_OCAML_RANLIB|}#' "$config_file"
  sed -i "s#^let standard_library_default = .*#let standard_library_default = {|${CROSS_LIBDIR}|}#" "$config_file"
  [[ -n "${CROSS_MODEL}" ]] && sed -i "s#^let model = .*#let model = {|${CROSS_MODEL}|}#" "$config_file"

  # Apply Makefile.cross patches
  cp "${RECIPE_DIR}/building/Makefile.cross" .
  patch -N -p0 < "${RECIPE_DIR}/building/tmp_Makefile.patch" > /dev/null 2>&1 || true

  # ========================================================================
  # Build cross-compiler
  # ========================================================================

  echo "  [4/5] Building cross-compiler (crossopt)..."

  # Set CONDA_OCAML_* for cross-compilation during build
  export CONDA_OCAML_AS="${CROSS_AS}"
  export CONDA_OCAML_CC="${CROSS_CC}"
  export CONDA_OCAML_AR="${CROSS_AR}"
  export CONDA_OCAML_RANLIB="${CROSS_RANLIB}"
  export CONDA_OCAML_MKDLL="${CROSS_MKDLL}"

  # Ensure cross-tools are findable in PATH
  export PATH="${BUILD_PREFIX}/bin:${PATH}"
  hash -r

  # Build arguments
  CROSSOPT_ARGS=(
    ARCH="${CROSS_ARCH}"
    AR="${CROSS_AR}"
    AS="${CROSS_AS}"
    ASPP="${CROSS_CC} -c"
    CAMLOPT=ocamlopt
    CC="${CROSS_CC}"
    CFLAGS="${CROSS_CFLAGS}"
    CROSS_AR="${CROSS_AR}"
    CROSS_CC="${CROSS_CC}"
    CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"
    LD="${CROSS_LD}"
    LDFLAGS="${CROSS_LDFLAGS}"
    LIBDIR="${CROSS_LIBDIR}"
    NM="${CROSS_NM}"
    RANLIB="${CROSS_RANLIB}"
    SAK_CC="${CC}"
    SAK_CFLAGS="${CFLAGS}"
    STRIP="${CROSS_STRIP}"
    ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd"
    NATIVE_AS="${NATIVE_AS}"
    NATIVE_CC="${NATIVE_CC}"
  )

  # Platform-specific args
  if [[ "${CROSS_PLATFORM}" == "macos" ]]; then
    CROSSOPT_ARGS+=(
      SAK_LDFLAGS="-fuse-ld=lld"
      SAK_AR="${BUILD_PREFIX}/bin/llvm-ar"
    )
  fi

  make crossopt "${CROSSOPT_ARGS[@]}" -j"${CPU_COUNT}" \
    > "${SRC_DIR}/_logs/crossopt_${target}.log" 2>&1 || {
      cat "${SRC_DIR}/_logs/crossopt_${target}.log"
      exit 1
    }

  # ========================================================================
  # Install cross-compiler
  # ========================================================================

  echo "  [5/5] Installing cross-compiler artifacts..."

  # Binaries
  cp ocamlopt.opt "${CROSS_PREFIX}/bin/"
  cp ocamlc.opt "${CROSS_PREFIX}/bin/"
  cp tools/ocamldep.opt "${CROSS_PREFIX}/bin/"
  cp tools/ocamlobjinfo.opt "${CROSS_PREFIX}/bin/"

  # Stdlib (bytecode + native + metadata)
  cp stdlib/*.{cma,cmxa,a,cmi,cmo,cmx,o} "${CROSS_LIBDIR}/" 2>/dev/null || true
  cp stdlib/*runtime*info "${CROSS_LIBDIR}/" 2>/dev/null || true

  # Compiler libs
  cp compilerlibs/*.{cma,cmxa,a} "${CROSS_LIBDIR}/" 2>/dev/null || true

  # Runtime
  cp runtime/*.{a,o} "${CROSS_LIBDIR}/" 2>/dev/null || true

  # Otherlibs
  for lib in otherlibs/*/; do
    cp "${lib}"*.{cma,cmxa,a,cmi,cmo,cmx,o} "${CROSS_LIBDIR}/" 2>/dev/null || true
  done

  # Stublibs
  mkdir -p "${CROSS_LIBDIR}/stublibs"
  cp otherlibs/*/dll*.so "${CROSS_LIBDIR}/stublibs/" 2>/dev/null || true

  # ld.conf - point to native OCaml's stublibs (same arch as cross-compiler binary)
  # Cross-compiler binary runs on BUILD machine, needs BUILD-arch stublibs
  cat > "${CROSS_LIBDIR}/ld.conf" << EOF
${OCAML_PREFIX}/lib/ocaml/stublibs
${OCAML_PREFIX}/lib/ocaml
EOF

  # ========================================================================
  # Generate wrapper scripts
  # ========================================================================

  for tool in ocamlopt ocamlc ocamldep ocamlobjinfo; do
    generate_cross_wrapper "${tool}" "${OCAML_INSTALL_PREFIX}" "${target}"
  done

  echo "  Installed: ${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt"
  echo "  Libs:      ${CROSS_LIBDIR}/"

  # ========================================================================
  # Test cross-compiler
  # ========================================================================

  echo "  Testing cross-compiler..."
  "${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt" -version | grep -q "${PKG_VERSION}"

  cat > /tmp/test_cross.ml << 'TESTEOF'
let () = print_endline "Hello from cross-compiled OCaml"
TESTEOF

  if "${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt" -o /tmp/test_cross /tmp/test_cross.ml 2>/dev/null; then
    _file_output=$(file /tmp/test_cross)
    case "${CROSS_ARCH}" in
      arm64)
        echo "$_file_output" | grep -qiE "aarch64|arm64" && echo "  ✓ Produces ${CROSS_ARCH} binaries" || {
          echo "  ✗ ERROR: expected ${CROSS_ARCH}, got: $_file_output"
          exit 1
        }
        ;;
      power)
        echo "$_file_output" | grep -qi "powerpc\|ppc64" && echo "  ✓ Produces ${CROSS_ARCH} binaries" || {
          echo "  ✗ ERROR: expected ${CROSS_ARCH}, got: $_file_output"
          exit 1
        }
        ;;
    esac
    rm -f /tmp/test_cross /tmp/test_cross.ml /tmp/test_cross.{o,cmx,cmi}
  else
    echo "  ✗ ERROR: cross-compilation failed"
    "${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt" -verbose -o /tmp/test_cross /tmp/test_cross.ml || true
    exit 1
  fi

  echo "  Done: ${target}"
done

echo ""
echo "============================================================"
echo "All cross-compilers built successfully"
echo "============================================================"
