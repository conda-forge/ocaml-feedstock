#!/usr/bin/env bash
set -eu

# Cross-compilation script for linux-aarch64 and linux-ppc64le from linux-64
# This follows the same 3-stage pattern as build-arm64.sh (for macOS):
#   Stage 1: Build native x86_64 compiler
#   Stage 2: Build cross-compiler (runs on x86_64, targets aarch64/ppc64le)
#   Stage 3: Use cross-compiler to build final target binaries

# Save original environment
_build_alias="$build_alias"
_host_alias="$host_alias"
_OCAML_PREFIX="${OCAML_PREFIX}"
_CC="${CC}"
_AR="${AR}"
_AS="${AS}"
_RANLIB="${RANLIB}"
_CFLAGS="${CFLAGS:-}"
_LDFLAGS="${LDFLAGS:-}"

# Clear cross-compilation environment for Stage 1
unset build_alias
unset host_alias
unset HOST TARGET_ARCH

# Stage 1: Build native x86_64 compiler
echo "=== Stage 1: Building native x86_64 OCaml compiler ==="
export OCAML_PREFIX=${SRC_DIR}/_native && mkdir -p ${SRC_DIR}/_native
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# Ensure linker can find zstd from BUILD_PREFIX
export LIBRARY_PATH="${BUILD_PREFIX}/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir=${OCAML_PREFIX}/share/man
)

# Configure for native x86_64 build
# Note: zstd from BUILD_PREFIX is needed for linking ocamlc.opt/ocamlopt.opt
# We add -lzstd to LDFLAGS to ensure it's linked in all stages
_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_build_alias"
  AR="$_build_alias-ar"
  AS="$_build_alias-as"
  ASPP="${CC_FOR_BUILD} -c"
  CC="${CC_FOR_BUILD}"
  LD="$_build_alias-ld"
  NM="$_build_alias-nm"
  RANLIB="$_build_alias-ranlib"
  STRIP="$_build_alias-strip"
  CFLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -I${BUILD_PREFIX}/include"
  LDFLAGS="-L${BUILD_PREFIX}/lib -lzstd -Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections -Wl,-rpath,${OCAML_PREFIX}/lib -Wl,-rpath-link,${OCAML_PREFIX}/lib -Wl,-rpath,${BUILD_PREFIX}/lib"
)

_TARGET=(
  --target="$_build_alias"
)

./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}" \
  "${_TARGET[@]}"

make world.opt -j${CPU_COUNT}
make install

# Save build_config.h for cross-compiled runtime
cp runtime/build_config.h "${SRC_DIR}"

make distclean


# Stage 2: Build cross-compiler (runs on x86_64, emits target code)
echo "=== Stage 2: Building cross-compiler (x86_64 -> ${_host_alias}) ==="
_PATH="${PATH}"
export PATH="${OCAML_PREFIX}/bin:${_PATH}"
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# Cross-compiler installs to separate directory
export OCAML_PREFIX=${SRC_DIR}/_cross

# Ensure linker can find zstd from BUILD_PREFIX
# LIBRARY_PATH is used by GCC to find libraries during linking
export LIBRARY_PATH="${BUILD_PREFIX}/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

_TARGET=(
  --target="$_host_alias"
)

./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}" \
  "${_TARGET[@]}"

# Apply cross-compilation patches
cp "${RECIPE_DIR}"/building/Makefile.cross .
patch -p0 < ${RECIPE_DIR}/building/tmp_Makefile.patch

# crossopt builds TARGET runtime assembly - needs TARGET assembler and compiler
# SAK_CC for build-time tools that run on build machine
make crossopt \
  AS="${_AS}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  SAK_CC="${CC_FOR_BUILD}" \
  SAK_LINK="${CC_FOR_BUILD}" \
  ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd" \
  -j${CPU_COUNT}
make installcross
make distclean


# Stage 3: Cross-compile final binaries for target architecture
echo "=== Stage 3: Cross-compiling final binaries for ${_host_alias} ==="
export PATH="${OCAML_PREFIX}/bin:${_PATH}"
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# Reset to final install path
export OCAML_PREFIX="${_OCAML_PREFIX}"

# Stage 3 config: use target cross-toolchain for native code
_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_host_alias"
  --target="$_host_alias"
  --with-target-bindir="${PREFIX}"/bin
  AR="${_AR}"
  AS="${_AS}"
  CC="${_CC}"
  RANLIB="${_RANLIB}"
  CFLAGS="${_CFLAGS}"
  LDFLAGS="${_LDFLAGS}"
)

./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}"

# Apply cross-compilation patches (needed again after configure regenerates Makefile)
cp "${RECIPE_DIR}"/building/Makefile.cross .
patch -p0 < ${RECIPE_DIR}/building/tmp_Makefile.patch

# Build with target cross-toolchain
make crosscompiledopt \
  CAMLOPT=ocamlopt \
  AS="${_AS}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  -j${CPU_COUNT}

# Fix build_config.h paths for target
perl -pe 's#\$SRC_DIR/_native/lib/ocaml#\$PREFIX/lib/ocaml#g' "${SRC_DIR}"/build_config.h > runtime/build_config.h
perl -i -pe "s#${_build_alias}#${_host_alias}#g" runtime/build_config.h

echo "=== build_config.h for target ==="
cat runtime/build_config.h
echo "================================="

# Build runtime with target cross-toolchain
make crosscompiledruntime \
  CAMLOPT=ocamlopt \
  AS="${_AS}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  CHECKSTACK_CC="${CC_FOR_BUILD}" \
  SAK_CC="${CC_FOR_BUILD}" \
  SAK_LINK="${CC_FOR_BUILD} \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)" \
  -j${CPU_COUNT}

make installcross

# Fix bytecode shebangs
# Bytecode executables have format: #!/path/to/ocamlrun\n<binary data>
# We must replace the shebang with #!/usr/bin/env ocamlrun to:
#   1. Avoid hardcoded paths that won't exist after installation
#   2. Prevent conda prefix relocation from corrupting the binary data
echo ""
echo "=== Fixing bytecode shebangs ==="
for bin in "${OCAML_PREFIX}"/bin/*; do
  # Skip if not a regular file
  [[ -f "$bin" ]] || continue

  # Check if this is a bytecode executable (shebang contains ocamlrun)
  if head -c 50 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
    echo "Fixing bytecode shebang: $bin"
    # Using perl in binary mode to safely handle bytecode after the shebang
    perl -e '
      my $file = $ARGV[0];
      open(my $fh, "<:raw", $file) or die "Cannot open $file: $!";
      my $content = do { local $/; <$fh> };
      close($fh);

      my $newline_pos = index($content, "\n");
      if ($newline_pos > 0 && substr($content, 0, 2) eq "#!") {
          my $old_shebang = substr($content, 0, $newline_pos);
          print "  Old shebang: $old_shebang\n";
          my $new_content = "#!/usr/bin/env ocamlrun" . substr($content, $newline_pos);
          open(my $out, ">:raw", $file) or die "Cannot write $file: $!";
          print $out $new_content;
          close($out);
          print "  New shebang: #!/usr/bin/env ocamlrun\n";
      } else {
          print "  WARNING: No shebang found in $file\n";
      }
    ' "$bin"
  fi
done

echo ""
echo "=== Cross-compilation complete for ${_host_alias} ==="
