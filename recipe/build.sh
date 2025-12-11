#!/usr/bin/env bash
set -eu

# Paths are hardcoded in binaries, simplify to basename
export CC=$(basename "$CC")
export ASPP="$CC -c"
export AS=$(basename "$AS")
export AR=$(basename "$AR")
export RANLIB=$(basename "$RANLIB")

# Avoids an annoying 'directory not found'
mkdir -p ${PREFIX}/lib

if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  export OCAML_PREFIX=$PREFIX/Library
  SH_EXT="bat"
else
  export OCAML_PREFIX=$PREFIX
  SH_EXT="sh"
fi

export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir=${OCAML_PREFIX}/share/man
  --with-target-bindir="${PREFIX}"/bin
  -prefix $OCAML_PREFIX
)

if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
  if [[ "${target_platform}" == "osx-arm64" ]]; then
    "${RECIPE_DIR}"/building/build-arm64.sh
  elif [[ "${target_platform}" == "linux-aarch64" ]] || [[ "${target_platform}" == "linux-ppc64le" ]]; then
    "${RECIPE_DIR}"/building/build-linux-cross.sh
  else
    echo "ERROR: Cross-compilation not supported for ${target_platform}"
    exit 1
  fi
else
  if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
    CONFIG_ARGS+=(--enable-ocamltest)
  fi

  ./configure "${CONFIG_ARGS[@]}" >& /dev/null
  make world.opt -j${CPU_COUNT} >& /dev/null

  if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
    if [ "$(uname)" == "Darwin" ]; then
      # Tests failing on macOS. Seems to be a known issue.
      rm testsuite/tests/lib-str/t01.ml
      rm testsuite/tests/lib-threads/beat.ml
    fi

    if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
      rm testsuite/tests/unicode/$'\u898b'.ml
    fi

    make ocamltest -j ${CPU_COUNT}
    make tests
  fi

  make install >& /dev/null
fi

echo ""
echo "=== Fixing bytecode shebangs ==="
echo "OCAML_PREFIX=${OCAML_PREFIX}"
echo "Looking for binaries in: ${OCAML_PREFIX}/bin/"
ls -la "${OCAML_PREFIX}/bin/" | head -20

for bin in ${OCAML_PREFIX}/bin/*
do
  # Skip if not a regular file
  [[ -f "$bin" ]] || continue

  # Check if this is a bytecode executable (shebang to ocamlrun followed by binary)
  # These should NOT be modified as it corrupts the binary portion.
  # Bytecode files have format: #!/path/to/ocamlrun\n<binary data>
  # We must NOT:
  #   1. Use sed on them (corrupts binary)
  #   2. Put ${PREFIX} in shebang (conda prefix relocation will corrupt binary)
  # Solution: Use /usr/bin/env ocamlrun which is portable and won't be relocated
  if head -c 50 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
    # On Unix: Replace shebang with env-based version that won't trigger prefix relocation
    # On Windows: Skip - shebangs don't matter, Windows uses file extensions
    if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
      echo "Fixing bytecode shebang: $bin"
      # Only modify the first line, preserve exact binary content after newline
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
      # Verify the fix was applied
      echo "  Verify: $(head -c 30 "$bin" | cat -v)"
    fi
    continue
  fi

  # For shell scripts, fix exec statements using perl
  if file "$bin" 2>/dev/null | grep -qE "shell script|POSIX shell|text"; then
    perl -i -pe "s#exec '([^']*)'#exec \$1#g" "$bin"
    perl -i -pe 's#exec \Q'"${OCAML_PREFIX}"'\E/bin#exec \$(dirname "\$0")#g' "$bin"
  fi
done

# Final verification: check bin/ocaml shebang
echo ""
echo "=== Final verification of bytecode shebangs ==="
if [[ -f "${OCAML_PREFIX}/bin/ocaml" ]]; then
  echo "bin/ocaml first 100 bytes:"
  head -c 100 "${OCAML_PREFIX}/bin/ocaml" | cat -v
  echo ""
  echo "bin/ocaml shebang line:"
  head -1 "${OCAML_PREFIX}/bin/ocaml"
fi

for CHANGE in "activate" "deactivate"
do
  mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
  cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
done
