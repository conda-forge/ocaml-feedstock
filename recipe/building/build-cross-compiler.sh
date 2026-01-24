# ============================================================================
# CROSS-COMPILERS BUILD SCRIPT
# Builds cross-compilers for aarch64/ppc64le (on linux-64) or arm64 (on osx-64)
#
# Variables:
#   OCAML_PREFIX         - Where native OCaml is installed (source for native tools)
#   OCAML_INSTALL_PREFIX - Where cross-compilers will be installed (destination)
# ============================================================================

# Source common functions
source "${RECIPE_DIR}/building/common-functions.sh"

if [[ "${target_platform}" != "linux"* ]] && [[ "${target_platform}" != "osx"* ]]; then
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

# macOS: Set DYLD_LIBRARY_PATH so native compiler can find libzstd at runtime
# The native compiler (x86_64) needs BUILD_PREFIX libs, not PREFIX (which has target arch libs)
# Cross-compilation: PREFIX=ARM64, BUILD_PREFIX=x86_64
# Native build: PREFIX=x86_64, BUILD_PREFIX=x86_64 (same)
if [[ "${target_platform}" == "osx"* ]]; then
  if [[ "${CONDA_BUILD_CROSS_COMPILATION:-0}" == "1" ]]; then
    export DYLD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
    export LIBRARY_PATH="${BUILD_PREFIX}/lib:${LIBRARY_PATH:-}"
  else
    export DYLD_LIBRARY_PATH="${PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
    export LIBRARY_PATH="${PREFIX}/lib:${LIBRARY_PATH:-}"
  fi
fi

# Define cross targets based on build platform or explicit env vars
CONFIG_ARGS+=(--with-target-bindir="${PREFIX}"/bin)
declare -a CROSS_TARGETS

# Check if CROSS_TARGET_TRIPLET is explicitly set (gcc pattern: build one target per output)
if [[ -n "${CROSS_TARGET_TRIPLET:-}" ]]; then
  echo "  Using explicit CROSS_TARGET_TRIPLET: ${CROSS_TARGET_TRIPLET}"
  CROSS_TARGETS=("${CROSS_TARGET_TRIPLET}")
else
  # Legacy behavior: build all cross-compilers for this platform
  case "${target_platform}" in
    linux-64)
      CROSS_TARGETS=("aarch64-conda-linux-gnu" "powerpc64le-conda-linux-gnu")
      # Frame pointers configured per-target (PPC doesn't support them)
      ;;
    linux-aarch64)
      CROSS_TARGETS=("aarch64-conda-linux-gnu")
      ;;
    linux-ppc64le)
      CROSS_TARGETS=("powerpc64le-conda-linux-gnu")
      # PPC64LE does not support frame pointers
      ;;
    osx-*)
      CROSS_TARGETS=("arm64-apple-darwin20.0.0")
      ;;
  esac
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

# CRITICAL: Add native OCaml to PATH so configure can find ocamlc
# Configure checks "if the installed OCaml compiler can build the cross compiler"
PATH="${OCAML_PREFIX}/bin:${PATH}"
hash -r
echo "  PATH updated to include: ${OCAML_PREFIX}/bin"

for target in "${CROSS_TARGETS[@]}"; do
  echo ""
  echo "  ------------------------------------------------------------"
  echo "  Building cross-compiler for ${target}"
  echo "  ------------------------------------------------------------"

  # Get target properties using common functions
  CROSS_ARCH=$(get_target_arch "${target}")
  CROSS_PLATFORM=$(get_target_platform "${target}")

  # Handle PowerPC model override
  CROSS_MODEL=""
  [[ "${target}" == "powerpc64le-"* ]] && CROSS_MODEL="ppc64le"

  # Setup macOS ARM64 SDK (must be done before setup_cflags_ldflags)
  if [[ "${target}" == "arm64-apple-darwin"* ]]; then
    echo "  Setting up macOS ARM64 SDK for cross-compilation..."
    setup_macos_sysroot "${target}"
    # CRITICAL: Override BOTH SDKROOT and CONDA_BUILD_SYSROOT
    # conda-forge sets CONDA_BUILD_SYSROOT=/opt/conda-sdks/MacOSX10.13.sdk for x86_64
    # The cross-compiler clang respects CONDA_BUILD_SYSROOT for library lookup
    # Without overriding it, lld finds the wrong SDK even with -syslibroot flags
    export SDKROOT="${ARM64_SYSROOT}"
    export CONDA_BUILD_SYSROOT="${ARM64_SYSROOT}"
    echo "  SDKROOT exported: ${SDKROOT}"
    echo "  CONDA_BUILD_SYSROOT exported: ${CONDA_BUILD_SYSROOT}"
  fi

  # Setup cross-toolchain (sets CROSS_CC, CROSS_AS, CROSS_AR, etc.)
  setup_toolchain "CROSS" "${target}"
  setup_cflags_ldflags "CROSS" "${build_platform}" "${CROSS_PLATFORM}"

  # Platform-specific settings for cross-compiler
  # NEEDS_DL: glibc 2.17 requires explicit -ldl for dlopen/dlclose/dlsym
  # This is used by apply_cross_patches() to add -ldl to Makefile.config
  # CROSS_PLATFORM is "linux-aarch64", "linux-ppc64le", "osx-arm64", etc.
  NEEDS_DL=0
  case "${CROSS_PLATFORM}" in
    linux-*)
      NEEDS_DL=1
      ;;
  esac
  export NEEDS_DL

  # Export CONDA_OCAML_<TARGET_ID>_* variables
  TARGET_ID=$(get_target_id "${target}")

  echo "  Target:        ${target}"
  echo "  Target ID:     ${TARGET_ID}"
  echo "  Arch:          ${CROSS_ARCH}"
  echo "  Platform:      ${CROSS_PLATFORM}"
  echo "  CROSS_AR:      ${CROSS_AR}"
  echo "  CROSS_AS:      ${CROSS_AS}"
  echo "  CROSS_ASM:     ${CROSS_ASM}"
  echo "  CROSS_CC:      ${CROSS_CC}"
  echo "  CROSS_CFLAGS:  ${CROSS_CFLAGS}"
  echo "  CROSS_LD:      ${CROSS_LD}"
  echo "  CROSS_LDFLAGS: ${CROSS_LDFLAGS}"
  echo "  CROSS_RANLIB:  ${CROSS_RANLIB}"

  # ========================================================================
  # Generate standalone toolchain wrappers EARLY (needed during crossopt build)
  # ========================================================================
  # These must exist BEFORE crossopt because config.generated.ml references them.
  # Install in both BUILD_PREFIX/bin (for build-time access) and OCAML_INSTALL_PREFIX/bin (for package)
  echo "  Installing ${target}-ocaml-* toolchain wrappers (build-time)..."

  # Create toolchain wrappers using CROSS_* variables as defaults
  # Format: tool_name:ENV_SUFFIX:default_value
  for tool_pair in "cc:CC:${CROSS_CC}" "as:AS:${CROSS_ASM}" "ar:AR:${CROSS_AR}" \
                   "ld:LD:${CROSS_LD}" "ranlib:RANLIB:${CROSS_RANLIB}" \
                   "mkexe:MKEXE:${CROSS_MKEXE}" "mkdll:MKDLL:${CROSS_MKDLL}"; do
    tool_name="${tool_pair%%:*}"
    rest="${tool_pair#*:}"
    env_suffix="${rest%%:*}"
    default_tool="${rest#*:}"

    # Create in BUILD_PREFIX/bin for build-time PATH access
    wrapper_path="${BUILD_PREFIX}/bin/${target}-ocaml-${tool_name}"
    cat > "${wrapper_path}" << TOOLWRAPPER
#!/usr/bin/env bash
# OCaml cross-compiler toolchain wrapper for ${target}
# Reads CONDA_OCAML_${TARGET_ID}_${env_suffix} or uses default cross-tool
exec \${CONDA_OCAML_${TARGET_ID}_${env_suffix}:-${default_tool}} "\$@"
TOOLWRAPPER
    chmod +x "${wrapper_path}"
  done
  echo "    Created in BUILD_PREFIX: ${target}-ocaml-{cc,as,ar,ld,ranlib,mkexe,mkdll}"

  # Use CROSS_TARGET_PLATFORM if set (gcc pattern), otherwise CROSS_PLATFORM
  _ENV_TARGET="${CROSS_TARGET_PLATFORM:-${CROSS_PLATFORM}}"
  cat > "${SRC_DIR}/_xcross_compiler_${_ENV_TARGET}_env.sh" << EOF
# Generated by build-cross-compiler.sh - do not edit
export "CROSS_AR=${CROSS_AR}"
export "CROSS_AS=${CROSS_AS}"
export "CROSS_ASM=${CROSS_ASM}"
export "CROSS_CC=${CROSS_CC}"
export "CROSS_CFLAGS=${CROSS_CFLAGS}"
export "CROSS_LD=${CROSS_LD}"
export "CROSS_LDFLAGS=${CROSS_LDFLAGS}"
export "CROSS_RANLIB=${CROSS_RANLIB}"
export "CROSS_MKDLL=${CROSS_MKDLL}"
export "CROSS_MKEXE=${CROSS_MKEXE}"

# CONDA_OCAML_* for runtime (use CROSS_* not CONDA_OCAML_* which may be native)
export "CONDA_OCAML_${TARGET_ID}_AR=${CROSS_AR}"
export "CONDA_OCAML_${TARGET_ID}_AS=${CROSS_ASM}"
export "CONDA_OCAML_${TARGET_ID}_CC=${CROSS_CC}"
export "CONDA_OCAML_${TARGET_ID}_RANLIB=${CROSS_RANLIB}"
export "CONDA_OCAML_${TARGET_ID}_MKDLL=${CROSS_MKDLL}"
export "CONDA_OCAML_${TARGET_ID}_MKEXE=${CROSS_MKEXE}"
EOF

  # Installation prefix for this cross-compiler
  OCAML_CROSS_PREFIX="${OCAML_INSTALL_PREFIX}/lib/ocaml-cross-compilers/${target}"
  OCAML_CROSS_LIBDIR="${OCAML_CROSS_PREFIX}/lib/ocaml"
  mkdir -p "${OCAML_CROSS_PREFIX}/bin" "${OCAML_CROSS_LIBDIR}"

  # ========================================================================
  # Clean and configure
  # ========================================================================

  echo "  [1/7] Cleaning previous build..."
  run_logged "pre-cross-distclean" "${MAKE[@]}" distclean > /dev/null 2>&1 || true

  echo "  [2/7] Configuring for ${target}..."
  # PKG_CONFIG=false forces simple "-lzstd" instead of "-L/long/path -lzstd"
  # Do NOT pass CC here - configure needs BUILD compiler
  # ac_cv_func_getentropy=no: conda-forge uses glibc 2.17 sysroot which lacks getentropy
  # CRITICAL: Override CFLAGS/LDFLAGS - conda-build sets them for TARGET (ppc64le)
  # but configure needs BUILD flags (x86_64) to compile the cross-compiler binary
  # NOTE: OCaml 5.4.0+ requires CFLAGS/LDFLAGS as env vars, not configure args.
  export CC="${NATIVE_CC}"
  export CFLAGS="${NATIVE_CFLAGS}"
  export LDFLAGS="${NATIVE_LDFLAGS}"

  # Per-target configure args (frame pointers not supported on PPC)
  declare -a TARGET_CONFIG_ARGS=()
  case "${CROSS_ARCH}" in
    arm64|amd64)
      TARGET_CONFIG_ARGS+=(--enable-frame-pointers)
      ;;
  esac

  run_logged "cross-configure" ${CONFIGURE[@]} \
    -prefix="${OCAML_CROSS_PREFIX}" \
    --mandir="${OCAML_CROSS_PREFIX}"/share/man \
    --host="${build_alias}" \
    --target="${target}" \
    "${CONFIG_ARGS[@]}" \
    "${TARGET_CONFIG_ARGS[@]}" \
    AR="${CROSS_AR}" \
    AS="${NATIVE_AS}" \
    LD="${NATIVE_LD}" \
    NM="${CROSS_NM}" \
    RANLIB="${CROSS_RANLIB}" \
    STRIP="${CROSS_STRIP}" \
    ac_cv_func_getentropy=no \
    ${CROSS_MODEL:+MODEL=${CROSS_MODEL}}

  # ========================================================================
  # Patch Makefile for OCaml 5.4.0 bug: CHECKSTACK_CC undefined
  # ========================================================================
  if ! grep -q "^CHECKSTACK_CC" Makefile.config; then
    echo "    Patching Makefile.config: adding CHECKSTACK_CC = \$(CC)"
    echo 'CHECKSTACK_CC = $(CC)' >> Makefile.config
  fi

  # ========================================================================
  # Patch config.generated.ml
  # ========================================================================

  echo "  [3/7] Patching config.generated.ml..."
  config_file="utils/config.generated.ml"

  # Use ${target}-ocaml-* standalone wrapper scripts (not conda-ocaml-* from native)
  # This makes cross-compiler fully standalone without runtime dependency on native ocaml
  sed -i \
    -e "s#^let asm = .*#let asm = {|${target}-ocaml-as|}#" \
    -e "s#^let ar = .*#let ar = {|${target}-ocaml-ar|}#" \
    -e "s#^let c_compiler = .*#let c_compiler = {|${target}-ocaml-cc|}#" \
    -e "s#^let ranlib = .*#let ranlib = {|${target}-ocaml-ranlib|}#" \
    -e "s#^let mkexe = .*#let mkexe = {|${target}-ocaml-mkexe|}#" \
    -e "s#^let mkdll = .*#let mkdll = {|${target}-ocaml-mkdll|}#" \
    -e "s#^let mkmaindll = .*#let mkmaindll = {|${target}-ocaml-mkdll|}#" \
    "$config_file"
  # CRITICAL: Use the actual PREFIX path that conda will install to
  # OCAML_CROSS_LIBDIR may point to work/_xcross_compiler/... during build
  # We need to use ${PREFIX} (the conda prefix) which will be correct after install
  # Conda/rattler-build will relocate these paths during packaging
  FINAL_STDLIB_PATH="${PREFIX}/lib/ocaml-cross-compilers/${target}/lib/ocaml"
  sed -i "s#^let standard_library_default = .*#let standard_library_default = {|${FINAL_STDLIB_PATH}|}#" "$config_file"

  # CRITICAL: Patch architecture - this is baked into the binary!
  # CROSS_ARCH is set by get_target_arch() - values: arm64, power, amd64
  sed -i "s#^let architecture = .*#let architecture = {|${CROSS_ARCH}|}#" "$config_file"

  # Patch model for PowerPC
  [[ -n "${CROSS_MODEL}" ]] && sed -i "s#^let model = .*#let model = {|${CROSS_MODEL}|}#" "$config_file"

  # Patch native_pack_linker to use cross-linker via wrapper
  sed -i "s#^let native_pack_linker = .*#let native_pack_linker = {|${target}-ocaml-ld -r -o |}#" "$config_file"

  # CRITICAL: Patch native_c_libraries to include -ldl for Linux targets
  # glibc 2.17 requires explicit -ldl for dlopen/dlclose/dlsym/dlerror
  # This value is BAKED INTO the compiler binary, not read from Makefile.config!
  if [[ "${NEEDS_DL}" == "1" ]]; then
    # Add -ldl to native_c_libraries if not already present
    if ! grep -q '"-ldl"' "$config_file"; then
      sed -i 's#^let native_c_libraries = {|\(.*\)|}#let native_c_libraries = {|\1 -ldl|}#' "$config_file"
      echo "    Patched native_c_libraries: added -ldl"
    fi
    # Also patch bytecomp_c_libraries for bytecode
    if ! grep -q 'bytecomp_c_libraries.*-ldl' "$config_file"; then
      sed -i 's#^let bytecomp_c_libraries = {|\(.*\)|}#let bytecomp_c_libraries = {|\1 -ldl|}#' "$config_file"
      echo "    Patched bytecomp_c_libraries: added -ldl"
    fi
  fi

  echo "    Patched architecture=${CROSS_ARCH}"
  [[ -n "${CROSS_MODEL}" ]] && echo "    Patched model=${CROSS_MODEL}"
  echo "    Patched native_pack_linker=${target}-ocaml-ld -r -o"

  # Apply Makefile.cross patches (includes otherlibrariesopt → otherlibrariesopt-cross fix)
  apply_cross_patches

  # ========================================================================
  # Pre-build bytecode runtime with NATIVE tools
  # ========================================================================
  # runtime-all builds BOTH bytecode (libcamlrun*, ocamlrun*) and native (libasmrun*).
  # Bytecode runs on BUILD machine → NATIVE tools; Native is for TARGET → CROSS tools.
  #
  # Strategy (prevents Stdlib__Sys consistency errors - see HISTORY.md):
  # 1. Build runtime-all with NATIVE tools (ARCH=amd64) - stable .cmi files
  # 2. Clean only native runtime files (libasmrun*, amd64.o, *.nd.o)
  # 3. crossopt rebuilds native parts for TARGET (bytecode unchanged)

  echo "  [4/7] Pre-building bytecode runtime and stdlib with native tools..."
  run_logged "runtime-all" "${MAKE[@]}" runtime-all \
    ARCH=amd64 \
    CC="${NATIVE_CC}" \
    CFLAGS="${NATIVE_CFLAGS}" \
    LD="${NATIVE_LD}" \
    LDFLAGS="${NATIVE_LDFLAGS}" \
    SAK_CC="${NATIVE_CC}" \
    SAK_CFLAGS="${NATIVE_CFLAGS}" \
    SAK_LDFLAGS="${NATIVE_LDFLAGS}" \
    ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd" \
    -j"${CPU_COUNT}" || { cat "${LOG_DIR}"/runtime-all.log; exit 1; }

  # NOTE: stdlib pre-build removed - was causing inconsistent assumptions
  # Let crossopt handle stdlib build entirely with consistent variables

  # Clean native runtime files so crossopt rebuilds them for TARGET arch
  # - libasmrun*.a: native runtime static libraries
  # - libasmrun_shared.so: native runtime shared library
  # - amd64*.o: x86_64 assembly objects (crossopt needs arm64*.o)
  # - *.nd.o, *.ni.o, *.npic.o: native code object files (need CROSS CC)
  # - stdlib/*.cmi: bytecode interface files (have ARCH-specific metadata)
  echo "     Cleaning native runtime and stdlib for crossopt rebuild..."
  rm -f runtime/libasmrun*.a runtime/libasmrun_shared.so
  rm -f runtime/amd64*.o runtime/*.nd.o runtime/*.ni.o runtime/*.npic.o
  rm -f runtime/libcomprmarsh.a  # Also needs CROSS tools

  # CRITICAL: Clean stdlib .cmi files - they contain arch-specific metadata
  # The .cmi files from runtime-all were built with ARCH=amd64, but crossopt
  # needs ARCH=arm64. Must force complete rebuild for consistency.
  # This prevents "inconsistent assumptions over implementation Stdlib__Sys" errors
  # between stdlib.cmxa and unix.cmxa (different CRC checksums).
  echo "     Cleaning stdlib compiled files to prevent arch inconsistencies..."
  rm -f stdlib/*.cmi stdlib/*.cmo stdlib/*.cma
  rm -f stdlib/*.cmx stdlib/*.cmxa stdlib/*.o stdlib/*.a

  # ========================================================================
  # Build cross-compiler
  # ========================================================================

  echo "  [5/7] Building cross-compiler (crossopt)..."

  (
    # Export CONDA_OCAML_* for cross-compilation (conda-ocaml-* wrappers expand these)
    # - Use CROSS_ASM (includes "-c" for macOS clang) not CROSS_AS
    # - MKEXE stays NATIVE (links x86_64 cross-compiler binary)
    # - OCAMLLIB will be set by Makefile.cross based on LIBDIR
    export CONDA_OCAML_AS="${CROSS_ASM}"
    export CONDA_OCAML_CC="${CROSS_CC}"
    export CONDA_OCAML_AR="${CROSS_AR}"
    export CONDA_OCAML_RANLIB="${CROSS_RANLIB}"
    export CONDA_OCAML_MKDLL="${CROSS_MKDLL}"

    # Ensure cross-tools are findable in PATH
    PATH="${OCAML_PREFIX}/bin:${PATH}"
    hash -r

    # Native compiler stdlib location (for copying fresh .cmi files in crossopt)
    NATIVE_STDLIB="${OCAML_PREFIX}/lib/ocaml"

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
      CROSS_MKEXE="${CROSS_MKEXE}"
      CROSS_MKDLL="${CROSS_MKDLL}"
      LD="${CROSS_LD}"
      LDFLAGS="${CROSS_LDFLAGS}"
      LIBDIR="${OCAML_CROSS_LIBDIR}"
      NM="${CROSS_NM}"
      RANLIB="${CROSS_RANLIB}"
      STRIP="${CROSS_STRIP}"
      ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd"

      SAK_AR="${NATIVE_AR}"
      SAK_CC="${NATIVE_CC}"
      SAK_CFLAGS="${NATIVE_CFLAGS}"
      SAK_LDFLAGS="${NATIVE_LDFLAGS}"

      # NATIVE tools for building BUILD-platform binaries (profiling.cmx, ocamlopt.opt)
      NATIVE_AS="${NATIVE_AS}"
      NATIVE_ASM="${NATIVE_ASM}"  # Includes "-c" for macOS clang
      NATIVE_CC="${NATIVE_CC}"

      # Native compiler stdlib location (for copying fresh .cmi files)
      NATIVE_STDLIB="${NATIVE_STDLIB}"
    )

    run_logged "crossopt" "${MAKE[@]}" crossopt "${CROSSOPT_ARGS[@]}" -j"${CPU_COUNT}" || { cat "${LOG_DIR}"/crossopt.log; exit 1; }
  )

  # ========================================================================
  # Install cross-compiler
  # ========================================================================

  echo "  [6/7] Installing cross-compiler via 'make installcross'..."

  (
    # Use same environment as crossopt
    export CONDA_OCAML_AS="${CROSS_ASM}"
    export CONDA_OCAML_CC="${CROSS_CC}"
    export CONDA_OCAML_AR="${CROSS_AR}"
    export CONDA_OCAML_RANLIB="${CROSS_RANLIB}"
    export CONDA_OCAML_MKDLL="${CROSS_MKDLL}"
    # CONDA_OCAML_MKEXE intentionally NOT set - use native linker

    PATH="${OCAML_PREFIX}/bin:${PATH}"
    hash -r

    INSTALL_ARGS=(
      PREFIX="${OCAML_CROSS_PREFIX}"
      ARCH="${CROSS_ARCH}"
      AR="${CROSS_AR}"
      AS="${CROSS_AS}"
      ASPP="${CROSS_CC} -c"
      CC="${CROSS_CC}"
      CFLAGS="${CROSS_CFLAGS}"
      CROSS_AR="${CROSS_AR}"
      CROSS_CC="${CROSS_CC}"
      CROSS_MKEXE="${CROSS_MKEXE}"
      CROSS_MKDLL="${CROSS_MKDLL}"
      LD="${CROSS_LD}"
      LDFLAGS="${CROSS_LDFLAGS}"
      NM="${CROSS_NM}"
      RANLIB="${CROSS_RANLIB}"
      STRIP="${CROSS_STRIP}"
    )

    # Clean LIBDIR before install to ensure fresh installation
    # This prevents mixing of files from crossopt build with make install
    echo "    Cleaning LIBDIR before install..."
    rm -rf "${OCAML_CROSS_LIBDIR}"

    run_logged "installcross" "${MAKE[@]}" installcross "${INSTALL_ARGS[@]}"
  )

  # Verify rpath for macOS cross-compiler binaries
  # OCaml embeds @rpath/libzstd.1.dylib - rpath should be set via BYTECCLIBS during build
  # Cross-compiler binaries are in ${PREFIX}/lib/ocaml-cross-compilers/${target}/bin/
  # libzstd is in ${PREFIX}/lib/, so relative path is ../../../../lib
  if [[ "${target_platform}" == "osx"* ]]; then
    echo "  Verifying rpath for macOS cross-compiler binaries..."
    for binary in "${OCAML_CROSS_PREFIX}"/bin/*.opt; do
      if [[ -f "${binary}" ]]; then
        # Check if libzstd is linked via @rpath
        if otool -L "${binary}" 2>/dev/null | grep -q "@rpath/libzstd"; then
          # Check if rpath already exists (either @executable_path or @loader_path)
          if otool -l "${binary}" 2>/dev/null | grep -A2 "LC_RPATH" | grep -qE "@(executable_path|loader_path)"; then
            RPATH=$(otool -l "${binary}" 2>/dev/null | grep -A2 "LC_RPATH" | grep "path" | head -1 | awk '{print $2}')
            echo "    $(basename ${binary}): rpath OK (${RPATH})"
          else
            # No rpath set - add one
            echo "    $(basename ${binary}): adding @loader_path/../../../../lib rpath"
            if install_name_tool -add_rpath @loader_path/../../../../lib "${binary}" 2>&1; then
              codesign -f -s - "${binary}" 2>/dev/null || true
            else
              echo "    WARNING: install_name_tool failed for $(basename ${binary})"
            fi
          fi
        fi
      fi
    done
  fi

  # Post-install fixes for cross-compiler package

  # ld.conf - point to native OCaml's stublibs (same arch as cross-compiler binary)
  # Cross-compiler binary runs on BUILD machine, needs BUILD-arch stublibs
  cat > "${OCAML_CROSS_LIBDIR}/ld.conf" << EOF
${OCAML_PREFIX}/lib/ocaml/stublibs
${OCAML_PREFIX}/lib/ocaml
EOF

  # Remove unnecessary binaries to reduce package size
  # Cross-compiler only needs: ocamlopt, ocamlc, ocamldep, ocamllex, ocamlyacc, ocamlmklib
  echo "  Cleaning up unnecessary binaries..."
  (
    cd "${OCAML_CROSS_PREFIX}/bin"

    # Remove bytecode versions (keep only .opt)
    rm -f ocamlc.byte ocamldep.byte ocamllex.byte ocamlobjinfo.byte ocamlopt.byte

    # Remove toplevel and REPL (not needed for cross-compilation)
    rm -f ocaml

    # Remove bytecode interpreters (cross-compiler produces native code)
    rm -f ocamlrun ocamlrund ocamlruni

    # Remove profiling tools
    rm -f ocamlcp ocamloptp ocamlprof

    # Remove other unnecessary tools
    rm -f ocamlcmt ocamlmktop

    # Optionally remove ocamlobjinfo (only for debugging)
    # rm -f ocamlobjinfo ocamlobjinfo.opt
  )

  # Remove man pages (not needed in cross-compiler package)
  rm -rf "${OCAML_CROSS_PREFIX}/man" 2>/dev/null || true

  # Patch Makefile.config for cross-compilation
  # The installed Makefile.config has BUILD machine settings, we need TARGET settings
  # Also clean up build-time paths that would cause test failures and runtime issues
  echo "  Patching Makefile.config for target ${target}..."
  makefile_config="${OCAML_CROSS_LIBDIR}/Makefile.config"
  if [[ -f "${makefile_config}" ]]; then
    # Architecture
    sed -i "s|^ARCH=.*|ARCH=${CROSS_ARCH}|" "${makefile_config}"

    # TOOLPREF - CRITICAL: Must be TARGET triplet, not BUILD triplet!
    # opam uses this to find the correct cross-toolchain
    sed -i "s|^TOOLPREF=.*|TOOLPREF=${target}-|" "${makefile_config}"

    # Model (for PowerPC)
    if [[ -n "${CROSS_MODEL}" ]]; then
      sed -i "s|^MODEL=.*|MODEL=${CROSS_MODEL}|" "${makefile_config}"
    fi

    # Toolchain - use standalone ${target}-ocaml-* wrappers (not conda-ocaml-* from native)
    sed -i "s|^CC=.*|CC=${target}-ocaml-cc|" "${makefile_config}"
    sed -i "s|^AS=.*|AS=${target}-ocaml-as|" "${makefile_config}"
    sed -i "s|^ASM=.*|ASM=${target}-ocaml-as|" "${makefile_config}"
    sed -i "s|^ASPP=.*|ASPP=${target}-ocaml-cc -c|" "${makefile_config}"
    sed -i "s|^AR=.*|AR=${target}-ocaml-ar|" "${makefile_config}"
    sed -i "s|^RANLIB=.*|RANLIB=${target}-ocaml-ranlib|" "${makefile_config}"

    # CPP - strip build-time path, keep binary name and flags (-E -P)
    # Pattern: CPP=/long/path/to/clang -E -P -> CPP=clang -E -P
    # The ( .*)? is optional to handle CPP without flags
    sed -Ei 's#^(CPP)=/.*/([^/ ]+)( .*)?$#\1=\2\3#' "${makefile_config}"

    # Linker commands - use standalone ${target}-ocaml-* wrappers
    sed -i "s|^NATIVE_PACK_LINKER=.*|NATIVE_PACK_LINKER=${target}-ocaml-ld -r -o|" "${makefile_config}"
    sed -i "s|^MKEXE=.*|MKEXE=${target}-ocaml-mkexe|" "${makefile_config}"
    sed -i "s|^MKDLL=.*|MKDLL=${target}-ocaml-mkdll|" "${makefile_config}"
    sed -i "s|^MKMAINDLL=.*|MKMAINDLL=${target}-ocaml-mkdll|" "${makefile_config}"

    # Library paths - remove hardcoded BUILD paths, use runtime paths
    # bytecomp_c_libraries and native_c_libraries should not have -L paths
    # that point to BUILD_PREFIX - those won't exist at runtime
    # Patterns to catch: conda-bld, rattler-build, build_env, _build_env
    sed -i 's|-L[^ ]*conda-bld[^ ]* ||g' "${makefile_config}"
    sed -i 's|-L[^ ]*rattler-build[^ ]* ||g' "${makefile_config}"
    sed -i 's|-L[^ ]*build_env[^ ]* ||g' "${makefile_config}"
    sed -i 's|-L[^ ]*_build_env[^ ]* ||g' "${makefile_config}"

    # Ensure zstd is linked correctly (will be found via standard paths at runtime)
    # Remove any remaining absolute -L paths before -lzstd
    sed -i 's|-L/[^ ]*/lib -lzstd|-lzstd|g' "${makefile_config}"
    # Also catch -L without trailing -lzstd
    sed -i 's|-L/[^ ]*/lib ||g' "${makefile_config}"

    # Standard library path - use actual ${PREFIX} which conda will relocate
    # The OCAML_CROSS_LIBDIR variable contains build-time work directory path
    # We need to use the FINAL installed path: ${PREFIX}/lib/ocaml-cross-compilers/${target}/lib/ocaml
    FINAL_CROSS_LIBDIR="${PREFIX}/lib/ocaml-cross-compilers/${target}/lib/ocaml"
    FINAL_CROSS_PREFIX="${PREFIX}/lib/ocaml-cross-compilers/${target}"
    sed -i "s|^prefix=.*|prefix=${FINAL_CROSS_PREFIX}|" "${makefile_config}"
    sed -i "s|^LIBDIR=.*|LIBDIR=${FINAL_CROSS_LIBDIR}|" "${makefile_config}"
    sed -i "s|^STUBLIBDIR=.*|STUBLIBDIR=${FINAL_CROSS_LIBDIR}/stublibs|" "${makefile_config}"

    # CRITICAL: Remove or sanitize CONFIGURE_ARGS - it contains build-time paths
    # This is purely informational but fails tests and confuses users
    # Replace the entire line with a sanitized version
    sed -i '/^CONFIGURE_ARGS=/d' "${makefile_config}"
    echo "CONFIGURE_ARGS=# Removed - contained build-time paths" >> "${makefile_config}"

    # Clean any remaining build-time paths in other fields
    # Pattern: /home/*/build_artifacts/*, /home/*/feedstock_root/*
    # Replace with ${PREFIX} which conda will relocate
    sed -i "s|/home/[^/]*/feedstock_root/[^ ]*|${PREFIX}|g" "${makefile_config}"
    sed -i "s|/home/[^/]*/build_artifacts/[^ ]*|${PREFIX}|g" "${makefile_config}"

    # Remove -Wl,-rpath paths that point to build directories
    sed -i 's|-Wl,-rpath,[^ ]*rattler-build[^ ]* ||g' "${makefile_config}"
    sed -i 's|-Wl,-rpath-link,[^ ]*rattler-build[^ ]* ||g' "${makefile_config}"

    # Clean LDFLAGS - remove build-time paths from LDFLAGS and LDFLAGS?= lines
    # These patterns catch conda-bld, rattler-build, build_env paths
    sed -i 's|-L[^ ]*miniforge[^ ]* ||g' "${makefile_config}"
    sed -i 's|-L[^ ]*miniconda[^ ]* ||g' "${makefile_config}"

    echo "    Patched ARCH=${CROSS_ARCH}"
    [[ -n "${CROSS_MODEL}" ]] && echo "    Patched MODEL=${CROSS_MODEL}"
    echo "    Patched toolchain to use ${target}-ocaml-* standalone wrappers"
    echo "    Cleaned build-time paths from prefix/LIBDIR/STUBLIBDIR"
    echo "    Removed CONFIGURE_ARGS (contained build-time paths)"
  else
    echo "    WARNING: Makefile.config not found at ${makefile_config}"
  fi

  # Remove unnecessary library files to reduce package size
  echo "  Cleaning up unnecessary library files..."
  (
    cd "${OCAML_CROSS_LIBDIR}"

    # Remove source files (not needed for compilation)
    find . -name "*.ml" -type f -delete 2>/dev/null || true
    find . -name "*.mli" -type f -delete 2>/dev/null || true

    # Remove typed trees (only for IDE tooling, not compilation)
    find . -name "*.cmt" -type f -delete 2>/dev/null || true
    find . -name "*.cmti" -type f -delete 2>/dev/null || true

    # Remove legacy annotation files
    find . -name "*.annot" -type f -delete 2>/dev/null || true

    # Note: Keep .cma/.cmo - dune bootstrap may need bytecode libraries
    # Note: Keep .cmx/.cmxa/.a/.cmi/.o - required for native compilation
  )

  echo "  Installed via make installcross to: ${OCAML_CROSS_PREFIX}"

  # ========================================================================
  # Verify runtime library architecture
  # ========================================================================
  echo "  Verifying libasmrun.a architecture (expected: ${CROSS_ARCH})..."
  if [[ -f "${OCAML_CROSS_LIBDIR}/libasmrun.a" ]]; then
    _tmpdir=$(mktemp -d)
    (cd "$_tmpdir" && ar x "${OCAML_CROSS_LIBDIR}/libasmrun.a" 2>/dev/null)
    _obj=$(ls "$_tmpdir"/*.o 2>/dev/null | head -1)
    if [[ -n "$_obj" ]]; then
      if [[ "${target_platform}" == "osx"* ]]; then
        _arch_info=$(lipo -info "$_obj" 2>/dev/null || file "$_obj")
      else
        _arch_info=$(readelf -h "$_obj" 2>/dev/null | grep -i "Machine:" || file "$_obj")
      fi
      echo "    libasmrun.a object: $_arch_info"
      # Check architecture matches target (use | not \| with grep -E)
      case "${CROSS_ARCH}" in
        arm64) _expected="arm64|ARM64|AArch64|aarch64" ;;
        aarch64) _expected="AArch64|aarch64|arm64|ARM64" ;;
        power) _expected="PowerPC|ppc64" ;;
        *) _expected="${CROSS_ARCH}" ;;
      esac
      if ! echo "$_arch_info" | grep -qiE "$_expected"; then
        echo "    ✗ ERROR: libasmrun.a has WRONG architecture!"
        echo "    Expected: ${CROSS_ARCH}, Got: $_arch_info"
        rm -rf "$_tmpdir"
        exit 1
      fi
      echo "    ✓ Architecture verified: ${CROSS_ARCH}"
    fi
    rm -rf "$_tmpdir"
  else
    echo "    WARNING: libasmrun.a not found at ${OCAML_CROSS_LIBDIR}/libasmrun.a"
  fi

  # ========================================================================
  # [7/7] Copy toolchain wrappers and generate OCaml compiler wrappers
  # ========================================================================
  # These were created earlier (before crossopt) for build-time use.
  # Now copy to OCAML_INSTALL_PREFIX/bin for the final package.

  echo "  [7/7] Installing wrappers to package..."
  echo "    Copying ${target}-ocaml-* toolchain wrappers..."
  mkdir -p "${OCAML_INSTALL_PREFIX}/bin"

  for tool_name in cc as ar ld ranlib mkexe mkdll; do
    src="${BUILD_PREFIX}/bin/${target}-ocaml-${tool_name}"
    dst="${OCAML_INSTALL_PREFIX}/bin/${target}-ocaml-${tool_name}"
    if [[ -f "${src}" ]]; then
      cp "${src}" "${dst}"
      chmod +x "${dst}"
    else
      echo "    WARNING: ${src} not found"
    fi
  done
  echo "    Copied: ${target}-ocaml-{cc,as,ar,ld,ranlib,mkexe,mkdll}"

  # ========================================================================
  # Generate OCaml compiler wrapper scripts
  # ========================================================================

  for tool in ocamlopt ocamlc ocamldep ocamlobjinfo ocamllex ocamlyacc ocamlmklib; do
    generate_cross_wrapper "${tool}" "${OCAML_INSTALL_PREFIX}" "${target}" "${OCAML_CROSS_PREFIX}"
    (cd "${OCAML_INSTALL_PREFIX}"/bin && ln -s "${target}-${tool}.opt" "${target}-${tool}")
  done

  echo "  Installed: ${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt"
  echo "  Libs:      ${OCAML_CROSS_LIBDIR}/"

  # ========================================================================
  # Basic smoke test
  # ========================================================================

  echo "  Basic smoke test..."
  CROSS_OCAMLOPT="${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt"

  if "${CROSS_OCAMLOPT}" -version | grep -q "${PKG_VERSION}"; then
    echo "    ✓ Version check passed"
  else
    echo "    ✗ ERROR: Version mismatch"
    exit 1
  fi

  ${RECIPE_DIR}/testing/test-cross-compiler-consistency.sh "${OCAML_INSTALL_PREFIX}/bin/${target}-ocamlopt"
  
  echo "  Done: ${target} (comprehensive tests run in post-install)"
done

echo ""
echo "============================================================"
echo "All cross-compilers built successfully"
echo "============================================================"
