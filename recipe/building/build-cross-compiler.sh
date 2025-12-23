# ============================================================================
# CROSS-COMPILERS (only on linux-64 and osx-64)
# ============================================================================
if [[ "${target_platform}" == "linux-64" ]] || [[ "${target_platform}" == "osx-64" ]]; then

  # Define cross targets based on build platform
  declare -A CROSS_TARGETS
  if [[ "${target_platform}" == "linux-64" ]]; then
    CROSS_TARGETS=(
      ["aarch64-conda-linux-gnu"]="arm64:linux"
      ["powerpc64le-conda-linux-gnu"]="power:linux:ppc64le"
    )
  elif [[ "${target_platform}" == "osx-64" ]]; then
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
    # macOS: clang cross-compilers may not have -cc symlink, only -clang
    _CC="${BUILD_PREFIX}/bin/${target}-cc"
    if [[ ! -x "${_CC}" ]]; then
      _CC_FALLBACK="${BUILD_PREFIX}/bin/${target}-clang"
      if [[ -x "${_CC_FALLBACK}" ]]; then
        echo "     NOTE: ${target}-cc not found, using ${target}-clang"
        _CC="${_CC_FALLBACK}"
      fi
    fi

    if [[ "${_PLATFORM}" == "macos" ]]; then
      # macOS: use clang's integrated assembler (no separate -as binary)
      _AS="${_CC}"
    else
      _AS="${BUILD_PREFIX}/bin/${target}-as"
    fi

    if [[ "${_PLATFORM}" == "macos" ]]; then
      # macOS: use LLVM tools consistently (GNU tools incompatible with ld64)
      _AR="${BUILD_PREFIX}/bin/llvm-ar"
      _RANLIB="${BUILD_PREFIX}/bin/llvm-ranlib"
      _NM="${BUILD_PREFIX}/bin/llvm-nm"
      _STRIP="${BUILD_PREFIX}/bin/llvm-strip"
      _LD="${BUILD_PREFIX}/bin/ld.lld"
      _CFLAGS="-ftree-vectorize -fPIC -O3 -pipe -isystem $BUILD_PREFIX/include"
      _LDFLAGS="-fuse-ld=lld"
    else
      _AR="${BUILD_PREFIX}/bin/${target}-ar"
      _RANLIB="${BUILD_PREFIX}/bin/${target}-ranlib"
      _NM="${BUILD_PREFIX}/bin/${target}-nm"
      _STRIP="${BUILD_PREFIX}/bin/${target}-strip"
      _LD="${BUILD_PREFIX}/bin/${target}-ld"
      _CFLAGS="-ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe -isystem $BUILD_PREFIX/include"
      _LDFLAGS=""
    fi

    # Without distclean, stale header.o (x86_64) causes "Relocations in generic ELF" errors
    echo "     distclean"
    make distclean > /dev/null 2>&1 || true

    # Configure for cross target (uses installed native tools from PATH)
    # AR/RANLIB must be passed to configure so Makefile.config gets correct tools
    # On macOS, must use LLVM tools (GNU tools incompatible with ld64)
    # NOTE: Do NOT pass CC here - configure needs BUILD compiler to build the cross-compiler binary
    # The TARGET compiler (_CC) is patched into config.generated.ml later
    echo "     configure"
    ./configure -prefix="${CROSS_PREFIX}" \
      --target="${target}" \
      "${CONFIG_ARGS[@]}" \
      AR="${_AR}" \
      RANLIB="${_RANLIB}" \
      NM="${_NM}" \
      STRIP="${_STRIP}" \
      ${_MODEL:+ac_cv_func_getentropy=no} > "${SRC_DIR}"/_logs/crossconfigure.log 2>&1 || { cat "${SRC_DIR}"/_logs/crossconfigure.log; exit 1; }

    # Patch config.generated.ml for cross output
    as=$(basename ${_AS})
    cc=$(basename ${_CC})
    config_file="utils/config.generated.ml"
    if [[ "${_PLATFORM}" == "macos" ]]; then
      sed -i "s#^let asm = .*#let asm = {|${cc} -c|}#" "$config_file"
      sed -i "s#^let mkdll = .*#let mkdll = {|${cc} -shared -undefined dynamic_lookup|}#" "$config_file"
      sed -i "s#^let mkexe = .*#let mkexe = {|${cc}|}#" "$config_file"
    else
      sed -i "s#^let asm = .*#let asm = {|${as}|}#" "$config_file"
      sed -i "s#^let mkdll = .*#let mkdll = {|${cc} -shared|}#" "$config_file"
      sed -i "s#^let mkexe = .*#let mkexe = {|${cc} -Wl,-E|}#" "$config_file"
    fi
    sed -i "s#^let c_compiler = .*#let c_compiler = {|${cc}|}#" "$config_file"
    sed -i "s#^let standard_library_default = .*#let standard_library_default = {|${CROSS_PREFIX}/lib/ocaml|}#" "$config_file"
    [[ -n "${_MODEL}" ]] && sed -i "s#^let model = .*#let model = {|${_MODEL}|}#" "$config_file"

    # Apply cross patches
    echo "     patch Makefile.cross"
    cp "${RECIPE_DIR}"/building/Makefile.cross .
    patch -N -p0 < "${RECIPE_DIR}"/building/tmp_Makefile.patch > /dev/null 2>&1 || true

    _CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"

    # Build cross-compiler
    # CRITICAL: LIBDIR must be explicitly set to prevent MAKEFLAGS inheritance
    # from parent (native) build which has LIBDIR=${PREFIX}/lib/ocaml
    echo "     crossopt"

    # Common crossopt args
    _CROSSOPT_ARGS=(
      ARCH="${_ARCH}"
      AR="${_AR}"
      AS="${_AS}"
      ASPP="${_CC} -c"
      CAMLOPT=ocamlopt
      CC="${_CC}"
      CFLAGS="${_CFLAGS}"
      CROSS_AR="${_AR}"
      CROSS_CC="${_CC}"
      CROSS_MKLIB="${_CROSS_MKLIB}"
      LD="${_LD}"
      LDFLAGS="${_LDFLAGS}"
      LIBDIR="${CROSS_PREFIX}/lib/ocaml"
      NM="${_NM}"
      RANLIB="${_RANLIB}"
      SAK_CC="${CC}"
      SAK_CFLAGS="${CFLAGS}"
      STRIP="${_STRIP}"
      ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd"
    )

    # Platform-specific args
    if [[ "${_PLATFORM}" == "macos" ]]; then
      _CROSSOPT_ARGS+=(SAK_LDFLAGS="-fuse-ld=lld")
    fi

    make crossopt "${_CROSSOPT_ARGS[@]}" -j${CPU_COUNT} > "${SRC_DIR}"/_logs/crossopt.log 2>&1 || { cat "${SRC_DIR}"/_logs/crossopt.log; exit 1; }

    # Install cross-compiler artifacts directly (skip make installcross - too complex)
    # Install to CROSS_PREFIX which matches what configure baked into the binary
    echo "     installing cross-compiler artifacts"

    CROSS_LIBDIR="${CROSS_PREFIX}/lib/ocaml"
    mkdir -p "${CROSS_LIBDIR}" "${CROSS_PREFIX}/bin"

    # Cross-compiler binary (runs on build, emits target code)
    cp ocamlopt.opt "${CROSS_PREFIX}/bin/ocamlopt.opt"

    # Create wrapper script that sets OCAMLLIB to cross-compiled libs
    # Uses self-contained path resolution (doesn't depend on OCAML_PREFIX being set)
    cat > "${PREFIX}/bin/${target}-ocamlopt" << 'WRAPPER'
#!/bin/sh
_prefix="$(cd "$(dirname "$0")/.." && pwd)"
export OCAMLLIB="${_prefix}/ocaml-cross-compilers/__TARGET__/lib/ocaml"
exec "${_prefix}/ocaml-cross-compilers/__TARGET__/bin/ocamlopt.opt" "$@"
WRAPPER
    sed -i "s#__TARGET__#${target}#g" "${PREFIX}/bin/${target}-ocamlopt"
    chmod +x "${PREFIX}/bin/${target}-ocamlopt"

    # Stdlib - need .cmx and .o files too for native compilation
    cp stdlib/*.cmxa stdlib/*.a stdlib/*.cmi stdlib/*.cmx stdlib/*.o "${CROSS_LIBDIR}/" 2>/dev/null || true

    # Compiler libs
    cp compilerlibs/*.cmxa compilerlibs/*.a compilerlibs/*.cmx "${CROSS_LIBDIR}/" 2>/dev/null || true

    # Runtime
    cp runtime/*.a runtime/*.o "${CROSS_LIBDIR}/" 2>/dev/null || true

    # Otherlibs (unix, str, dynlink, etc.)
    for lib in otherlibs/*/; do
      cp "${lib}"*.cmxa "${lib}"*.a "${lib}"*.cmi "${lib}"*.cmx "${lib}"*.o "${CROSS_LIBDIR}/" 2>/dev/null || true
    done

    # Stublibs
    mkdir -p "${CROSS_LIBDIR}/stublibs"
    cp otherlibs/*/dll*.so "${CROSS_LIBDIR}/stublibs/" 2>/dev/null || true

    # Create ld.conf for stublibs discovery
    # CRITICAL: Cross-compiler binary is x86-64 (runs on build machine)
    # It needs x86-64 stublibs at runtime, NOT the cross-compiled (aarch64/ppc64le) ones
    # Point to NATIVE OCaml's stublibs (same arch as cross-compiler binary)
    cat > "${CROSS_LIBDIR}/ld.conf" << LDCONF
${PREFIX}/lib/ocaml/stublibs
${PREFIX}/lib/ocaml
LDCONF

    echo "     installed: ${PREFIX}/bin/${target}-ocamlopt -> ${CROSS_PREFIX}/bin/ocamlopt.opt"
    echo "     libs:      ${CROSS_LIBDIR}/"

    # Quick sanity test - compile a simple program and verify architecture
    echo "     testing cross-compiler..."
    "${PREFIX}/bin/${target}-ocamlopt" -version | grep -q ${PKG_VERSION}

    cat > /tmp/test_cross.ml << 'EOF'
let () = print_endline "Hello from cross-compiled OCaml"
EOF

    if "${PREFIX}/bin/${target}-ocamlopt" -o /tmp/test_cross /tmp/test_cross.ml 2>/dev/null; then
      # Verify binary architecture
      _file_output=$(file /tmp/test_cross)
      case "${_ARCH}" in
        arm64)
          if echo "$_file_output" | grep -qiE "aarch64|arm64"; then
            echo "     ✓ cross-compiler produces ${_ARCH} binaries"
          else
            echo "     ✗ ERROR: expected ${_ARCH}, got: $_file_output"
            exit 1
          fi
          ;;
        power)
          if echo "$_file_output" | grep -qi "powerpc\|ppc64"; then
            echo "     ✓ cross-compiler produces ${_ARCH} binaries"
          else
            echo "     ✗ ERROR: expected ${_ARCH}, got: $_file_output"
            exit 1
          fi
          ;;
      esac
      rm -f /tmp/test_cross /tmp/test_cross.ml /tmp/test_cross.o /tmp/test_cross.cmx /tmp/test_cross.cmi
    else
      echo "     ✗ ERROR: cross-compilation failed"
      # Try again with verbose output
      "${PREFIX}/bin/${target}-ocamlopt" -verbose -o /tmp/test_cross /tmp/test_cross.ml || true
      exit 1
    fi

    echo "=== Done ==="
  done
fi
