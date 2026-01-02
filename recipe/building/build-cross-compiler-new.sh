# ============================================================================
# CROSS-COMPILERS BUILD SCRIPT
# Builds cross-compilers for aarch64/ppc64le (on linux-64) or arm64 (on osx-64)
#
# Variables:
#   OCAML_PREFIX         - Where native OCaml is installed (source for native tools)
#   OCAML_INSTALL_PREFIX - Where cross-compilers will be installed (destination)
# ============================================================================

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

  # Handle PowerPC model override
  CROSS_MODEL=""
  [[ "${target}" == "powerpc64le-"* ]] && CROSS_MODEL="ppc64le"

  # Setup cross-toolchain (sets CROSS_CC, CROSS_AS, CROSS_AR, etc.)
  setup_cross_toolchain "${target}"

  # Export CONDA_OCAML_<TARGET_ID>_* variables
  TARGET_ID=$(get_target_id "${target}")

  echo "  Target:     ${target}"
  echo "  Arch:       ${CROSS_ARCH}"
  echo "  CROSS_CC:   ${CROSS_CC}"
  echo "  CROSS_AS:   ${CROSS_AS}"
  echo "  CROSS_AR:   ${CROSS_AR}"

  # Installation prefix for this cross-compiler
  OCAML_CROSS_PREFIX="${OCAML_INSTALL_PREFIX}/lib/ocaml-cross-compilers/${target}"
  OCAML_CROSS_LIBDIR="${OCAML_CROSS_PREFIX}/lib/ocaml"
  mkdir -p "${OCAML_CROSS_PREFIX}/bin" "${OCAML_CROSS_LIBDIR}"

  # ========================================================================
  # Clean and configure
  # ========================================================================

  echo "  [1/5] Cleaning previous build..."
  run_logged "pre-cross-distclean" "${MAKE[@]}" distclean > /dev/null 2>&1 || true

  echo "  [2/5] Configuring for ${target}..."
  # PKG_CONFIG=false forces simple "-lzstd" instead of "-L/long/path -lzstd"
  # Do NOT pass CC here - configure needs BUILD compiler
  run_logged "cross-contigure" "${CONFIGURE[@]}" \
    -prefix="${OCAML_CROSS_PREFIX}" \
    --target="${target}" \
    "${CONFIG_ARGS[@]}" \
    PKG_CONFIG=false \
    AR="${CROSS_AR}" \
    RANLIB="${CROSS_RANLIB}" \
    NM="${CROSS_NM}" \
    STRIP="${CROSS_STRIP}" \
    ${CROSS_MODEL:+ac_cv_func_getentropy=no}

  # ========================================================================
  # Patch config.generated.ml
  # ========================================================================

  echo "  [3/5] Patching config.generated.ml..."
  config_file="utils/config.generated.ml"

  if [[ "${target_platform}" == "osx"* ]]; then
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
  sed -i "s#^let standard_library_default = .*#let standard_library_default = {|${OCAML_CROSS_LIBDIR}|}#" "$config_file"
  [[ -n "${CROSS_MODEL}" ]] && sed -i "s#^let model = .*#let model = {|${CROSS_MODEL}|}#" "$config_file"

  # Apply "${MAKE[@]}"file.cross patches
  cp "${RECIPE_DIR}/building/Makefile.cross" .
  patch -N -p0 < "${RECIPE_DIR}/building/tmp_Makefile.patch" > /dev/null 2>&1 || true

  # ========================================================================
  # Build cross-compiler
  # ========================================================================

  echo "  [4/5] Building cross-compiler (crossopt)..."

  (
    # Set CONDA_OCAML_* for cross-compilation during build
    CONDA_OCAML_AS="${CROSS_AS}"
    CONDA_OCAML_CC="${CROSS_CC}"
    CONDA_OCAML_AR="${CROSS_AR}"
    CONDA_OCAML_RANLIB="${CROSS_RANLIB}"
    CONDA_OCAML_MKDLL="${CROSS_MKDLL}"

    # Ensure cross-tools are findable in PATH
    PATH="${OCAML_PREFIX}/bin:${PATH}"
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
      LIBDIR="${OCAML_CROSS_LIBDIR}"
      NM="${CROSS_NM}"
      RANLIB="${CROSS_RANLIB}"
      SAK_CC="${CC}"
      SAK_CFLAGS="${CFLAGS}"
      STRIP="${CROSS_STRIP}"
      ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd"
      # NATIVE_AS="${NATIVE_AS}"
      # NATIVE_CC="${NATIVE_CC}"
    )

    # Platform-specific args
    if [[ "${target_platform}" == "osx"* ]]; then
      CROSSOPT_ARGS+=(
        SAK_LDFLAGS="-fuse-ld=lld"
        SAK_AR="${BUILD_PREFIX}/bin/llvm-ar"
      )
    fi

    run_logged "crossopt" "${MAKE[@]}" crossopt "${CROSSOPT_ARGS[@]}" -j"${CPU_COUNT}"
  )

  # ========================================================================
  # Install cross-compiler
  # ========================================================================

  echo "  [5/5] Installing cross-compiler artifacts..."

  # Binaries
  cp ocamlopt.opt "${OCAML_CROSS_PREFIX}/bin/"
  cp ocamlc.opt "${OCAML_CROSS_PREFIX}/bin/"
  cp tools/ocamldep.opt "${OCAML_CROSS_PREFIX}/bin/"
  cp tools/ocamlobjinfo.opt "${OCAML_CROSS_PREFIX}/bin/"

  # Stdlib (bytecode + native + metadata)
  cp stdlib/*.{cma,cmxa,a,cmi,cmo,cmx,o} "${OCAML_CROSS_LIBDIR}/" 2>/dev/null || true
  cp stdlib/*runtime*info "${OCAML_CROSS_LIBDIR}/" 2>/dev/null || true

  # Compiler libs
  cp compilerlibs/*.{cma,cmxa,a} "${OCAML_CROSS_LIBDIR}/" 2>/dev/null || true

  # Runtime
  cp runtime/*.{a,o} "${OCAML_CROSS_LIBDIR}/" 2>/dev/null || true

  # Otherlibs
  for lib in otherlibs/*/; do
    cp "${lib}"*.{cma,cmxa,a,cmi,cmo,cmx,o} "${OCAML_CROSS_LIBDIR}/" 2>/dev/null || true
  done

  # Stublibs
  mkdir -p "${OCAML_CROSS_LIBDIR}/stublibs"
  cp otherlibs/*/dll*.so "${OCAML_CROSS_LIBDIR}/stublibs/" 2>/dev/null || true

  # ld.conf - point to native OCaml's stublibs (same arch as cross-compiler binary)
  # Cross-compiler binary runs on BUILD machine, needs BUILD-arch stublibs
  cat > "${OCAML_CROSS_LIBDIR}/ld.conf" << EOF
${OCAML_PREFIX}/lib/ocaml/stublibs
${OCAML_PREFIX}/lib/ocaml
EOF

  # ========================================================================
  # Generate wrapper scripts
  # ========================================================================

  for tool in ocamlopt ocamlc ocamldep ocamlobjinfo; do
    generate_cross_wrapper "${tool}" "${OCAML_INSTALL_PREFIX}" "${target}" "${OCAML_CROSS_PREFIX}"
  done

  echo "  Installed: ${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt"
  echo "  Libs:      ${OCAML_CROSS_LIBDIR}/"
  echo "  ocamlopt:  ${OCAML_CROSS_PREFIX}/bin/ocamlopt $(ls -1 ${OCAML_CROSS_PREFIX}/bin/ocamlopt)"

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
