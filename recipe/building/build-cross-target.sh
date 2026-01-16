# ============================================================================
# CROSS-TARGET BUILD SCRIPT (Stage 3 only)
# Cross-compiles OCaml binaries for target architecture using pre-built
# native OCaml and cross-compiler.
#
# Variables:
#   OCAML_PREFIX            - Where native OCaml is installed (for native tools)
#   CROSS_COMPILER_PREFIX   - Where cross-compiler is installed
#   OCAML_INSTALL_PREFIX    - Where cross-compiled binaries will be installed
# ============================================================================

# Source common functions
source "${RECIPE_DIR}/building/common-functions.sh"

# Only run for cross-compilation targets
if [[ "${build_platform}" == "${target_platform}" ]] || [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
  echo "Not a cross-compilation target, skipping"
  return 0
fi

# ============================================================================
# Configuration
# ============================================================================

: "${OCAML_PREFIX:=${BUILD_PREFIX}}"
: "${CROSS_COMPILER_PREFIX:=${BUILD_PREFIX}}"
: "${OCAML_INSTALL_PREFIX:=${PREFIX}}"

# ============================================================================
# Platform Detection & Toolchain Setup (using common-functions.sh)
# ============================================================================

CONFIG_ARGS+=(--with-target-bindir="${PREFIX}"/bin)
CROSS_ARCH=$(get_target_arch "${host_alias}")
CROSS_PLATFORM=$(get_target_platform "${host_alias}")

# Platform-specific settings
NEEDS_DL=0
DISABLE_GETENTROPY=0
CROSS_MODEL=""
case "${target_platform}" in
  linux-*)
    PLATFORM_TYPE="linux"
    NEEDS_DL=1
    DISABLE_GETENTROPY=1
    [[ "${target_platform}" == "linux-ppc64le" ]] && CROSS_MODEL="ppc64le"
    ;;
  osx-*)
    PLATFORM_TYPE="macos"
    ;;
  *)
    echo "ERROR: Unsupported cross-compilation target: ${target_platform}"
    exit 1
    ;;
esac

if [[ -z ${CROSS_CC:-} ]]; then
  # This is for the case of compatible previous conda-forge OCAML - otherwise, 3-stage sets these correctly
  setup_toolchain "CROSS" "${host_alias}"
  setup_cflags_ldflags "CROSS" "${build_platform}" "${target_platform}"
fi

if [[ -z ${NATIVE_CC:-} ]]; then
  # This is for the case of compatible previous conda-forge OCAML - otherwise, 3-stage sets these correctly
  setup_toolchain "NATIVE" "${build_alias}"
  setup_cflags_ldflags "NATIVE" "${build_platform}" "${target_platform}"
fi

# Ensure CROSS_ASM/NATIVE_ASM are set (fallback for fast path or when setup_toolchain skipped)
if [[ -z "${CROSS_ASM:-}" ]]; then
  if [[ "${target_platform}" == "osx-"* ]]; then
    CROSS_ASM="$(basename "${CROSS_CC}") -c"
  else
    CROSS_ASM="$(basename "${CROSS_AS}")"
  fi
  export CROSS_ASM
fi

if [[ -z "${NATIVE_ASM:-}" ]]; then
  if [[ "${build_platform}" == "osx-"* ]]; then
    NATIVE_ASM="$(basename "${NATIVE_CC}") -c"
  else
    NATIVE_ASM="$(basename "${NATIVE_AS}")"
  fi
  export NATIVE_ASM
fi

# macOS: Set DYLD_LIBRARY_PATH so native compiler can find libzstd at runtime
# (Stage 3 runs native compiler binaries from Stage 1 which are linked against BUILD_PREFIX)
if [[ "${PLATFORM_TYPE}" == "macos" ]]; then
  export DYLD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
  echo "  Set DYLD_LIBRARY_PATH=${DYLD_LIBRARY_PATH}"
fi

echo ""
echo "============================================================"
echo "Cross-target build configuration (Stage 3)"
echo "============================================================"
echo "  Target platform:      ${target_platform}"
echo "  Target triplet:       ${host_alias}"
echo "  Target arch:          ${CROSS_ARCH}"
echo "  Platform type:        ${PLATFORM_TYPE}"
echo "  Native OCaml:         ${OCAML_PREFIX}"
echo "  Cross-compiler:       ${CROSS_COMPILER_PREFIX}"
echo "  Install prefix:       ${OCAML_INSTALL_PREFIX}"
echo "  NATIVE_CC:            ${NATIVE_CC}"
echo "  NATIVE_AR:            ${NATIVE_AR}"
echo "  NATIVE_AS:            ${NATIVE_AS}"
echo "  NATIVE_ASM:           ${NATIVE_ASM}"
echo "  CROSS_CC:             ${CROSS_CC}"
echo "  CROSS_AR:             ${CROSS_AR}"
echo "  CROSS_AS:             ${CROSS_AS}"
echo "  CROSS_ASM:            ${CROSS_ASM}"

# ============================================================================
# Export variables for downstream scripts
# ============================================================================
cat > "${SRC_DIR}/_target_compiler_${target_platform}_env.sh" << EOF
# CONDA_OCAML_* for runtime
export CONDA_OCAML_AR="${CROSS_AR}"
export CONDA_OCAML_AS="${CROSS_ASM}"
export CONDA_OCAML_CC="${CROSS_CC}"
export CONDA_OCAML_RANLIB="${CROSS_RANLIB}"
export CONDA_OCAML_MKEXE="${CROSS_MKEXE:-}"
export CONDA_OCAML_MKDLL="${CROSS_MKDLL:-}"
EOF

# ============================================================================
# Cross-compiler paths
# ============================================================================

CROSS_OCAMLOPT="${CROSS_COMPILER_PREFIX}/bin/${host_alias}-ocamlopt"
CROSS_OCAMLMKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"

# Verify cross-compiler exists
if [[ ! -x "${CROSS_OCAMLOPT}" ]]; then
  echo "ERROR: Cross-compiler not found: ${CROSS_OCAMLOPT}"
  exit 1
fi

# OCAMLLIB must point to cross-compiler's stdlib
export OCAMLLIB="${CROSS_COMPILER_PREFIX}/lib/ocaml-cross-compilers/${host_alias}/lib/ocaml"

echo "  Cross ocamlopt:       ${CROSS_OCAMLOPT}"
echo "  OCAMLLIB:             ${OCAMLLIB}"

# Verify stdlib exists
if [[ ! -f "${OCAMLLIB}/stdlib.cma" ]]; then
  echo "ERROR: Cross-compiler stdlib not found at ${OCAMLLIB}"
  exit 1
fi

# PATH: native tools first, then cross tools
export PATH="${OCAML_PREFIX}/bin:${BUILD_PREFIX}/bin:${PATH}"
hash -r

# ============================================================================
# Configure
# ============================================================================

echo ""
echo "  [1/5] Configuring for ${host_alias} ==="

CONFIG_ARGS+=(
  -prefix="${OCAML_INSTALL_PREFIX}"
  --build="${build_alias}"
  --host="${host_alias}"
  --target="${host_alias}"
  AR="${CROSS_AR}"
  AS="${CROSS_AS}"
  CC="${CROSS_CC}"
  LD="${CROSS_LD}"
  RANLIB="${CROSS_RANLIB}"
  CFLAGS="${CROSS_CFLAGS}"
  LDFLAGS="${CROSS_LDFLAGS}"
)

if [[ "${DISABLE_GETENTROPY}" == "1" ]]; then
  CONFIG_ARGS+=(ac_cv_func_getentropy=no)
fi

# Install conda-ocaml-* wrapper scripts to BUILD_PREFIX (needed during build)
echo "    Installing conda-ocaml-* wrapper scripts to BUILD_PREFIX..."
for wrapper in conda-ocaml-cc conda-ocaml-as conda-ocaml-ar conda-ocaml-ranlib conda-ocaml-mkexe conda-ocaml-mkdll; do
  install -m 755 "${RECIPE_DIR}/scripts/${wrapper}" "${BUILD_PREFIX}/bin/${wrapper}"
done

run_logged "stage3_configure" "${CONFIGURE[@]}" "${CONFIG_ARGS[@]}"

# ============================================================================
# Patch configuration
# ============================================================================

echo "  [2/5] Patching configuration ==="

config_file="utils/config.generated.ml"

# Patch config.generated.ml to use conda-ocaml-* wrapper scripts
# Wrappers expand CONDA_OCAML_* env vars at runtime, compatible with Unix.create_process
sed -i \
  -e 's#^let asm = .*#let asm = {|conda-ocaml-as|}#' \
  -e 's#^let ar = .*#let ar = {|conda-ocaml-ar|}#' \
  -e 's#^let c_compiler = .*#let c_compiler = {|conda-ocaml-cc|}#' \
  -e 's#^let ranlib = .*#let ranlib = {|conda-ocaml-ranlib|}#' \
  -e 's#^let mkexe = .*#let mkexe = {|conda-ocaml-mkexe|}#' \
  -e 's#^let mkdll = .*#let mkdll = {|conda-ocaml-mkdll|}#' \
  -e 's#^let mkmaindll = .*#let mkmaindll = {|conda-ocaml-mkdll|}#' \
  "$config_file"

# PowerPC model
[[ -n "${CROSS_MODEL}" ]] && sed -i "s#^let model = .*#let model = {|${CROSS_MODEL}|}#" "$config_file"

# Apply Makefile.cross patches
apply_cross_patches

# ============================================================================
# Build crosscompiledopt
# ============================================================================

echo "  [3/5] Building crosscompiledopt ==="

(

  CROSSCOMPILEDOPT_ARGS=(
    ARCH="${CROSS_ARCH}"
    CAMLOPT="${CROSS_OCAMLOPT}"
    CROSS_CC="${CROSS_CC}"
    CROSS_AR="${CROSS_AR}"
    CROSS_MKLIB="${CROSS_OCAMLMKLIB}"
    ZSTD_LIBS="-L${PREFIX}/lib -lzstd"
    LIBDIR="${OCAML_INSTALL_PREFIX}/lib/ocaml"
    OCAMLLIB="${OCAMLLIB}"
    LDFLAGS="${CROSS_LDFLAGS}"
    
    CONDA_OCAML_AS="${CROSS_ASM}"
    CONDA_OCAML_CC="${CROSS_CC}"
    CONDA_OCAML_MKEXE="${CROSS_MKEXE:-}"
    CONDA_OCAML_MKDLL="${CROSS_MKDLL:-}"

    AS="${CROSS_AS}"
    ASPP="${CROSS_CC} -c"
    CC="${CROSS_CC}"
    
    SAK_AR="${NATIVE_AR}"
    SAK_CC="${NATIVE_CC}"
    SAK_CFLAGS="${NATIVE_CFLAGS}"
    SAK_LDFLAGS="${NATIVE_LDFLAGS}"
  )

  if [[ "${PLATFORM_TYPE}" == "linux" ]]; then
    CROSSCOMPILEDOPT_ARGS+=(
      CPPFLAGS="-D_DEFAULT_SOURCE"
      # glibc 2.17 (conda-forge sysroot) requires -ldl for dlopen/dlclose/dlsym
      NATIVECCLIBS="-L${PREFIX}/lib -lm -ldl -lzstd"
      BYTECCLIBS="-L${PREFIX}/lib -lm -lpthread -ldl -lzstd"
    )
  fi

  run_logged "crosscompiledopt" "${MAKE[@]}" crosscompiledopt "${CROSSCOMPILEDOPT_ARGS[@]}" -j"${CPU_COUNT}"
)

# ============================================================================
# Build crosscompiledruntime
# ============================================================================

echo "  [4/5] Building crosscompiledruntime ==="

# Fix build_config.h paths for target
sed -i "s#${BUILD_PREFIX}/lib/ocaml#${OCAML_INSTALL_PREFIX}/lib/ocaml#g" runtime/build_config.h
sed -i "s#${build_alias}#${host_alias}#g" runtime/build_config.h

(
  CROSSCOMPILEDRUNTIME_ARGS=(
    ARCH="${CROSS_ARCH}"
    CAMLOPT="${CROSS_OCAMLOPT}"
    AS="${CROSS_AS}"
    ASPP="${CROSS_CC} -c"
    CC="${CROSS_CC}"
    CROSS_CC="${CROSS_CC}"
    CROSS_AR="${CROSS_AR}"
    CROSS_MKLIB="${CROSS_OCAMLMKLIB}"
    CHECKSTACK_CC="${NATIVE_CC}"
    SAK_AR="${NATIVE_AR}"
    SAK_CC="${NATIVE_CC}"
    SAK_CFLAGS="${NATIVE_CFLAGS}"
    ZSTD_LIBS="-L${PREFIX}/lib -lzstd"
    LIBDIR="${OCAML_INSTALL_PREFIX}/lib/ocaml"
    OCAMLLIB="${OCAMLLIB}"
    CONDA_OCAML_AS="${CROSS_ASM}"
    CONDA_OCAML_CC="${CROSS_CC}"
    CONDA_OCAML_MKEXE="${CROSS_MKEXE:-}"
    CONDA_OCAML_MKDLL="${CROSS_MKDLL:-}"
  )

  if [[ "${PLATFORM_TYPE}" == "macos" ]]; then
    CROSSCOMPILEDRUNTIME_ARGS+=(
      LDFLAGS="${CROSS_LDFLAGS}"
      SAK_LDFLAGS="${NATIVE_LDFLAGS}"
    )
  else
    CROSSCOMPILEDRUNTIME_ARGS+=(
      CPPFLAGS="-D_DEFAULT_SOURCE"
      BYTECCLIBS="-L${PREFIX}/lib -lm -lpthread -ldl -lzstd"
      NATIVECCLIBS="-L${PREFIX}/lib -lm -ldl -lzstd"
      SAK_LINK="${NATIVE_CC} \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)"
    )
  fi

  run_logged "crosscompiledruntime" "${MAKE[@]}" crosscompiledruntime "${CROSSCOMPILEDRUNTIME_ARGS[@]}" -j"${CPU_COUNT}"
)

# ============================================================================
# Install
# ============================================================================

echo "  [5/5] Installing ==="

# Replace stripdebug with no-op (can't execute target binaries on build machine)
rm -f tools/stripdebug tools/stripdebug.ml tools/stripdebug.mli tools/stripdebug.cmi tools/stripdebug.cmo
cat > tools/stripdebug.ml << 'STRIPDEBUG'
let () =
  let src = Sys.argv.(1) in
  let dst = Sys.argv.(2) in
  let ic = open_in_bin src in
  let len = in_channel_length ic in
  let buf = Bytes.create len in
  really_input ic buf 0 len;
  close_in ic;
  let oc = open_out_bin dst in
  output oc buf 0 len;
  close_out oc
STRIPDEBUG
"${OCAML_PREFIX}/bin/ocamlc" -o tools/stripdebug tools/stripdebug.ml
rm -f tools/stripdebug.ml tools/stripdebug.cmi tools/stripdebug.cmo

run_logged "installcross" "${MAKE[@]}" installcross

# ============================================================================
# Post-install fixes
# ============================================================================

if [[ "${PLATFORM_TYPE}" == "macos" ]]; then
  echo "    Fixing macOS install names..."

  # Fix stublib overlinking
  for lib in "${OCAML_INSTALL_PREFIX}/lib/ocaml/stublibs/"*.so; do
    [[ -f "$lib" ]] || continue
    for dep in $(otool -L "$lib" 2>/dev/null | grep '\./dll' | awk '{print $1}'); do
      install_name_tool -change "$dep" "@loader_path/$(basename $dep)" "$lib"
    done
  done

  # Set correct install_name for runtime libraries
  for rtlib in libasmrun_shared.so libcamlrun_shared.so; do
    [[ -f "${OCAML_INSTALL_PREFIX}/lib/ocaml/${rtlib}" ]] && \
      install_name_tool -id "@rpath/${rtlib}" "${OCAML_INSTALL_PREFIX}/lib/ocaml/${rtlib}"
  done

  # Fix references in all libraries
  for lib in "${OCAML_INSTALL_PREFIX}/lib/ocaml/"*.so "${OCAML_INSTALL_PREFIX}/lib/ocaml/stublibs/"*.so; do
    [[ -f "$lib" ]] || continue
    install_name_tool -change "runtime/libasmrun_shared.so" "@rpath/libasmrun_shared.so" "$lib" 2>/dev/null || true
    install_name_tool -change "runtime/libcamlrun_shared.so" "@rpath/libcamlrun_shared.so" "$lib" 2>/dev/null || true
  done
fi

# Install conda-ocaml-* wrapper scripts (expand CONDA_OCAML_* env vars for tools like Dune)
echo "    Installing conda-ocaml-* wrapper scripts..."
for wrapper in conda-ocaml-cc conda-ocaml-as conda-ocaml-ar conda-ocaml-ld conda-ocaml-ranlib conda-ocaml-mkexe conda-ocaml-mkdll; do
  install -m 755 "${RECIPE_DIR}/scripts/${wrapper}" "${OCAML_INSTALL_PREFIX}/bin/${wrapper}"
done

# Clean up for potential cross-compiler builds
run_logged "distclean" "${MAKE[@]}"  distclean

echo ""
echo "============================================================"
echo "Cross-target build complete"
echo "============================================================"
echo "  Target:    ${host_alias}"
echo "  Installed: ${OCAML_INSTALL_PREFIX}"
