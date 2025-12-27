# ============================================================================
# CROSS-COMPILERS (only on linux-64 and osx-64)
# ============================================================================
if [[ "${target_platform}" == "linux-64" ]] || [[ "${target_platform}" == "osx-64" ]]; then

  # Set OCAMLLIB to installed native ocaml
  export OCAMLLIB="${PREFIX}/lib/ocaml"

  # Define cross targets based on build platform
  declare -A CROSS_TARGETS
  if [[ "${target_platform}" == "linux-64" ]]; then
    CROSS_TARGETS=(
      ["aarch64-conda-linux-gnu"]="arm64:linux"
      ["powerpc64le-conda-linux-gnu"]="power:linux:ppc64le"
    )
    _CC="${CC}"
  elif [[ "${target_platform}" == "osx-64" ]]; then
    CROSS_TARGETS=(
      ["arm64-apple-darwin20.0.0"]="arm64:macos"
    )
    _CC="clang"
  fi

  for target in "${!CROSS_TARGETS[@]}"; do
    IFS=':' read -r _ARCH _PLATFORM _MODEL <<< "${CROSS_TARGETS[$target]}"

    echo "=== Building cross-compiler for ${target} ==="

    CROSS_PREFIX="${PREFIX}/lib/ocaml-cross-compilers/${target}"
    mkdir -p "${CROSS_PREFIX}/bin" "${CROSS_PREFIX}/lib/ocaml"

    _CC="${BUILD_PREFIX}/bin/${target}-${CC##*-}"
    _AS="${BUILD_PREFIX}/bin/${target}-as"
    [[ "${_PLATFORM}" == "macos" ]] && _AS="${_CC}"

    if [[ "${_PLATFORM}" == "macos" ]]; then
      # macOS: use LLVM tools consistently (GNU tools incompatible with ld64)
      _AR="${BUILD_PREFIX}/bin/llvm-ar"
      _RANLIB="${BUILD_PREFIX}/bin/llvm-ranlib"
      _NM="${BUILD_PREFIX}/bin/llvm-nm"
      _STRIP="${BUILD_PREFIX}/bin/llvm-strip"
      _LD="${BUILD_PREFIX}/bin/ld.lld"
      _ARM64_SYSROOT=""
      for _try_sysroot in /opt/conda-sdks/*"${ARM64_SDK}".sdk; do
        [[ -z "${_try_sysroot}" ]] && continue  # Skip empty entries
        if [[ -d "${_try_sysroot}/usr/include" ]] || [[ -d "${_try_sysroot}/System/Library" ]]; then
          _ARM64_SYSROOT="${_try_sysroot}"
          echo "     Found ARM64 SDK at: ${_ARM64_SYSROOT}"
          break
        fi
      done
      # If no SDK found, try to query the cross-compiler for its default sysroot
      if [[ -z "${_ARM64_SYSROOT}" ]]; then
        # Try to get default sysroot from the cross-compiler
        _CLANG_DEFAULT_SYSROOT=$("${_CC}" --print-sysroot 2>/dev/null || true)
        if [[ -n "${_CLANG_DEFAULT_SYSROOT}" ]] && [[ -d "${_CLANG_DEFAULT_SYSROOT}" ]]; then
          _ARM64_SYSROOT="${_CLANG_DEFAULT_SYSROOT}"
          echo "     Found ARM64 SDK via clang --print-sysroot: ${_ARM64_SYSROOT}"
        fi
      fi

      if [[ -z "${_ARM64_SYSROOT}" ]]; then
        echo "     WARNING: No ARM64 SDK found in any of the searched locations"
        echo "     Searched: ${_SYSROOT_SEARCH[*]}"
        echo "     BUILD_PREFIX: ${BUILD_PREFIX}"
        echo "     CONDA_BUILD_SYSROOT: ${CONDA_BUILD_SYSROOT:-unset}"
        ls -la "${BUILD_PREFIX}/${target}/" 2>/dev/null || echo "     No ${BUILD_PREFIX}/${target}/ directory"
        ls -la /opt/*.sdk 2>/dev/null || echo "     No /opt/*.sdk directories"
        echo "     Proceeding without explicit -isysroot (clang will use its default)"
        _CFLAGS="-ftree-vectorize -fPIC -O3 -pipe -isystem $BUILD_PREFIX/include"
      else
        _CFLAGS="-ftree-vectorize -fPIC -O3 -pipe -isystem $BUILD_PREFIX/include -isysroot ${_ARM64_SYSROOT}"
      fi
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
    # CRITICAL: Use basenames only (not full paths) so binaries are relocatable
    as=$(basename ${_AS})
    cc=$(basename ${_CC})
    ar=$(basename ${_AR})
    ranlib=$(basename ${_RANLIB})
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
    sed -i "s#^let ar = .*#let ar = {|${ar}|}#" "$config_file"
    sed -i "s#^let ranlib = .*#let ranlib = {|${ranlib}|}#" "$config_file"
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

    # Cross-compiler binaries (run on build, emit target code)
    cp ocamlopt.opt "${CROSS_PREFIX}/bin/ocamlopt.opt"
    cp ocamlc.opt "${CROSS_PREFIX}/bin/ocamlc.opt"
    cp tools/ocamldep.opt "${CROSS_PREFIX}/bin/ocamldep.opt"
    cp tools/ocamlobjinfo.opt "${CROSS_PREFIX}/bin/ocamlobjinfo.opt"

    # Create wrapper script for ocamlopt that sets OCAMLLIB to cross-compiled libs
    # Uses self-contained path resolution (doesn't depend on OCAML_PREFIX being set)
    cat > "${PREFIX}/bin/${target}-ocamlopt" << 'WRAPPER'
#!/bin/sh
_prefix="$(cd "$(dirname "$0")/.." && pwd)"
export OCAMLLIB="${_prefix}/lib/ocaml-cross-compilers/__TARGET__/lib/ocaml"
exec "${_prefix}/lib/ocaml-cross-compilers/__TARGET__/bin/ocamlopt.opt" "$@"
WRAPPER
    sed -i "s#__TARGET__#${target}#g" "${PREFIX}/bin/${target}-ocamlopt"
    chmod +x "${PREFIX}/bin/${target}-ocamlopt"

    # Create wrapper script for ocamlc (bytecode compiler) with same OCAMLLIB
    cat > "${PREFIX}/bin/${target}-ocamlc" << 'WRAPPER'
#!/bin/sh
_prefix="$(cd "$(dirname "$0")/.." && pwd)"
export OCAMLLIB="${_prefix}/lib/ocaml-cross-compilers/__TARGET__/lib/ocaml"
exec "${_prefix}/lib/ocaml-cross-compilers/__TARGET__/bin/ocamlc.opt" "$@"
WRAPPER
    sed -i "s#__TARGET__#${target}#g" "${PREFIX}/bin/${target}-ocamlc"
    chmod +x "${PREFIX}/bin/${target}-ocamlc"

    # Create wrapper script for ocamldep (dependency analyzer) with same OCAMLLIB
    cat > "${PREFIX}/bin/${target}-ocamldep" << 'WRAPPER'
#!/bin/sh
_prefix="$(cd "$(dirname "$0")/.." && pwd)"
export OCAMLLIB="${_prefix}/lib/ocaml-cross-compilers/__TARGET__/lib/ocaml"
exec "${_prefix}/lib/ocaml-cross-compilers/__TARGET__/bin/ocamldep.opt" "$@"
WRAPPER
    sed -i "s#__TARGET__#${target}#g" "${PREFIX}/bin/${target}-ocamldep"
    chmod +x "${PREFIX}/bin/${target}-ocamldep"

    # Create wrapper script for ocamlobjinfo (object file inspector) with same OCAMLLIB
    cat > "${PREFIX}/bin/${target}-ocamlobjinfo" << 'WRAPPER'
#!/bin/sh
_prefix="$(cd "$(dirname "$0")/.." && pwd)"
export OCAMLLIB="${_prefix}/lib/ocaml-cross-compilers/__TARGET__/lib/ocaml"
exec "${_prefix}/lib/ocaml-cross-compilers/__TARGET__/bin/ocamlobjinfo.opt" "$@"
WRAPPER
    sed -i "s#__TARGET__#${target}#g" "${PREFIX}/bin/${target}-ocamlobjinfo"
    chmod +x "${PREFIX}/bin/${target}-ocamlobjinfo"

    # Stdlib - need both bytecode (.cmo, .cma) and native (.cmx, .cmxa) files plus metadata
    # CRITICAL: .cmo files needed by CAMLC=ocamlc in Makefile.cross (prevents "Cannot find file std_exit.cmo")
    # Also need runtime-launch-info and other metadata files for ocamlc
    echo "     copying stdlib files..."
    cp stdlib/*.cma stdlib/*.cmxa stdlib/*.a stdlib/*.cmi stdlib/*.cmo stdlib/*.cmx stdlib/*.o "${CROSS_LIBDIR}/" || {
      echo "     ERROR: Failed to copy stdlib files for ${target}"
      ls -la stdlib/*.{cma,cmxa,a,cmi,cmo,cmx,o} 2>&1 | head -20
      exit 1
    }
    # Copy metadata files (runtime-launch-info, target_runtime-launch-info, etc.)
    if ls stdlib/*runtime*info 1>/dev/null 2>&1; then
      cp stdlib/*runtime*info "${CROSS_LIBDIR}/"
      echo "     copied runtime info files"
    else
      echo "     Warning: No runtime info files found - listing stdlib:"
      ls -la stdlib/ | grep -E "runtime|launch|info" || echo "     (none found)"
    fi

    # Compiler libs - only need archive files (.cma, .cmxa, .a)
    # Individual .cmo/.cmx files are packaged inside the archives
    echo "     copying compilerlibs files..."
    cp compilerlibs/*.cma compilerlibs/*.cmxa compilerlibs/*.a "${CROSS_LIBDIR}/" || {
      echo "     ERROR: Failed to copy compilerlibs files for ${target}"
      ls -la compilerlibs/*.{cma,cmxa,a} 2>&1 | head -20
      exit 1
    }

    # Runtime
    echo "     copying runtime files..."
    cp runtime/*.a runtime/*.o "${CROSS_LIBDIR}/" || {
      echo "     ERROR: Failed to copy runtime files for ${target}"
      ls -la runtime/*.{a,o} 2>&1 | head -20
      exit 1
    }

    # Otherlibs (unix, str, dynlink, etc.) - copy archives and any standalone modules
    # Some otherlibs have individual .cmo/.cmx files, others only have archives
    echo "     copying otherlibs files..."
    for lib in otherlibs/*/; do
      # Copy what exists - use 2>/dev/null to ignore missing patterns
      cp "${lib}"*.cma "${lib}"*.cmxa "${lib}"*.a "${lib}"*.cmi "${CROSS_LIBDIR}/" 2>/dev/null || true
      cp "${lib}"*.cmo "${lib}"*.cmx "${lib}"*.o "${CROSS_LIBDIR}/" 2>/dev/null || true
    done

    # Stublibs
    mkdir -p "${CROSS_LIBDIR}/stublibs"
    cp otherlibs/*/dll*.so "${CROSS_LIBDIR}/stublibs/" 2>/dev/null || {
      echo "     Warning: No stublib .so files to copy"
    }

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
