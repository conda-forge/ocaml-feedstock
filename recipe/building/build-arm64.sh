#!/usr/bin/env bash
set -eu

# Save cross-compilation environment for Stage 3
_build_alias="$build_alias"
_host_alias="$host_alias"
_OCAML_PREFIX="${OCAML_PREFIX}"
_CC="${CC}"
_AR="${AR}"
_RANLIB="${RANLIB}"
_CFLAGS="${CFLAGS:-}"
_LDFLAGS="${LDFLAGS:-}"

unset build_alias
unset host_alias
unset HOST TARGET_ARCH

export OCAML_PREFIX=${SRC_DIR}/_native && mkdir -p ${SRC_DIR}/_native
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir=${OCAML_PREFIX}/share/man
)


# --- x86_64 compiler
_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_build_alias"
  AR="$_build_alias-ar"
  AS="$_build_alias-as"
  ASPP="${CC_FOR_BUILD} -c"
  CC="${CC_FOR_BUILD}"
  CPP="$_build_alias-clang-cpp"
  LD="$_build_alias-ld"
  LIPO="$_build_alias-lipo"
  NM="$_build_alias-nm"
  NMEDIT="$_build_alias-nmedit"
  OTOOL="$_build_alias-otool"
  RANLIB="$_build_alias-ranlib"
  STRIP="$_build_alias-strip"
  CFLAGS="-march=core2 -mtune=haswell -mssse3 ${CFLAGS}"
  LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
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

# Save for cross-compiled runtime
cp runtime/build_config.h "${SRC_DIR}"

make distclean


# --- Build cross-compiler
_PATH="${PATH}"
export PATH="${OCAML_PREFIX}/bin:${_PATH}"
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# Set environment for cross-compiler installation
export OCAML_PREFIX=${SRC_DIR}/_cross

_TARGET=(
  --target="$_host_alias"
)
./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}" \
  "${_TARGET[@]}"

# patch for cross: This is changing in 5.4.0
cp "${RECIPE_DIR}"/building/Makefile.cross .
patch -p0 < ${RECIPE_DIR}/building/tmp_Makefile.patch

# crossopt builds TARGET runtime assembly - needs TARGET assembler and compiler
# CFLAGS for target (override x86_64 flags from configure)
# SAK_CC/SAK_LINK for build-time tools that run on build machine
# Use clang as assembler on macOS (integrated ARM64 assembler)
make crossopt \
  AS="${_CC}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  CFLAGS="${_CFLAGS}" \
  SAK_CC="${CC_FOR_BUILD}" \
  SAK_LINK="${CC_FOR_BUILD} \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)" \
  -j${CPU_COUNT}
make installcross
make distclean


# --- Cross-compile (Stage 3: build native ARM64 binaries)
export PATH="${OCAML_PREFIX}/bin:${_PATH}"
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# Reset to final install path
export OCAML_PREFIX="${_OCAML_PREFIX}"

# Stage 3 config: use ARM64 cross-toolchain for native code
_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_host_alias"
  --target="$_host_alias"
  --with-target-bindir="${PREFIX}"/bin
  AR="${_AR}"
  CC="${_CC}"
  RANLIB="${_RANLIB}"
  CFLAGS="${_CFLAGS}"
  LDFLAGS="${_LDFLAGS}"
)
./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}"

# Apply cross-compilation patches
cp "${RECIPE_DIR}"/building/Makefile.cross .
patch -p0 < ${RECIPE_DIR}/building/tmp_Makefile.patch

# Build with ARM64 cross-toolchain
# Use clang as assembler on macOS (integrated ARM64 assembler)
make crosscompiledopt \
  CAMLOPT=ocamlopt \
  AS="${_CC}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  -j${CPU_COUNT}

perl -pe 's#\$SRC_DIR/_native/lib/ocaml#\$PREFIX/lib/ocaml#g' "${SRC_DIR}"/build_config.h > runtime/build_config.h
perl -i -pe "s#${_build_alias}#${_host_alias}#g" runtime/build_config.h

echo ".";echo ".";echo ".";echo ".";
cat runtime/build_config.h
echo ".";echo ".";echo ".";echo ".";

# Build runtime with ARM64 cross-toolchain
make crosscompiledruntime \
  CAMLOPT=ocamlopt \
  AS="${_CC}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  CHECKSTACK_CC="${CC_FOR_BUILD}" \
  SAK_CC="${CC_FOR_BUILD}" \
  SAK_LINK="${CC_FOR_BUILD} \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)" \
  -j${CPU_COUNT}
make installcross

# Fix overlinking in stublibs - change ./dll*.so to @loader_path/dll*.so
echo ""
echo "=== Fixing stublib overlinking ==="
for lib in "${OCAML_PREFIX}/lib/ocaml/stublibs/"*.so; do
  [[ -f "$lib" ]] || continue
  echo "Checking: $lib"
  for dep in $(otool -L "$lib" 2>/dev/null | grep '\./dll' | awk '{print $1}'); do
    echo "  Fixing: $dep -> @loader_path/$(basename $dep)"
    install_name_tool -change "$dep" "@loader_path/$(basename $dep)" "$lib"
  done
done

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
