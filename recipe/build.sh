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

  # if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
  #   if [ "$(uname)" == "Darwin" ]; then
  #     # Tests failing on macOS. Seems to be a known issue.
  #     rm testsuite/tests/lib-str/t01.ml
  #     rm testsuite/tests/lib-threads/beat.ml
  #   fi

  #   if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  #     rm testsuite/tests/unicode/$'\u898b'.ml
  #   fi

  #   make ocamltest -j ${CPU_COUNT}
  #   make tests
  # fi

  make install >& /dev/null
fi

echo ""
echo "=== Fixing bytecode wrappers ==="
echo "OCAML_PREFIX=${OCAML_PREFIX}"
echo "Looking for binaries in: ${OCAML_PREFIX}/bin/"
ls -la "${OCAML_PREFIX}/bin/" | head -20

for bin in ${OCAML_PREFIX}/bin/*
do
  # Skip if not a regular file or is a symlink
  [[ -f "$bin" ]] || continue
  [[ -L "$bin" ]] && continue

  # OCaml bytecode executables are shell script wrappers with embedded bytecode:
  #   Line 1: #!/usr/bin/sh
  #   Line 2: exec '/hardcoded/path/bin/ocamlrun' "$0" "$@"
  #   Line 3+: <binary bytecode data>
  #
  # We need to fix line 2 to use a relative path, but we MUST preserve
  # the exact binary content after line 2 (no sed, no text processing on bytecode).
  #
  # The fix: Replace exec line to use $(dirname "$0")/ocamlrun

  # Need 300+ bytes because conda placeholder paths are very long (~230 chars)
  if head -c 350 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
    if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
      echo "Fixing bytecode wrapper: $bin"

      # Use perl to safely handle the binary content after the shell wrapper
      perl -e '
        use strict;
        use warnings;

        my $file = $ARGV[0];
        open(my $fh, "<:raw", $file) or die "Cannot open $file: $!";
        my $content = do { local $/; <$fh> };
        close($fh);

        # Find the first two newlines (end of shebang and end of exec line)
        my $first_nl = index($content, "\n");
        my $second_nl = index($content, "\n", $first_nl + 1);

        if ($first_nl > 0 && $second_nl > $first_nl) {
            my $shebang = substr($content, 0, $first_nl);
            my $exec_line = substr($content, $first_nl + 1, $second_nl - $first_nl - 1);
            my $rest = substr($content, $second_nl);  # includes the newline

            print "  Shebang: $shebang\n";
            print "  Old exec: $exec_line\n";

            # Check if this is the expected format
            if ($exec_line =~ /exec.*ocamlrun.*\"\$0\".*\"\$\@\"/) {
                # Replace with relative path version
                # Use double quotes for the exec so variable expansion works
                my $new_exec = q{exec "$(dirname "$0")/ocamlrun" "$0" "$@"};
                print "  New exec: $new_exec\n";

                my $new_content = $shebang . "\n" . $new_exec . $rest;

                open(my $out, ">:raw", $file) or die "Cannot write $file: $!";
                print $out $new_content;
                close($out);
            } else {
                print "  SKIP: exec line format not recognized\n";
            }
        } else {
            print "  WARNING: Could not find expected structure in $file\n";
        }
      ' "$bin"

      # Verify the fix
      echo "  Result: $(head -2 "$bin")"
    fi
    continue
  fi

  # For pure shell scripts (no bytecode), fix exec statements
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

# Fix hardcoded BUILD_PREFIX paths in Makefile.config
# The build_env paths won't exist at runtime, replace with standard tool names
if [[ -f "${OCAML_PREFIX}/lib/ocaml/Makefile.config" ]]; then
  echo ""
  echo "=== Fixing Makefile.config paths ==="
  # Replace BUILD_PREFIX paths with just the tool basename
  # e.g., /path/to/build_env/bin/x86_64-conda-linux-gnu-strip -> strip
  sed -i 's|STRIP=.*/build_env/.*/\(.*-\)\?strip|STRIP=strip|g' "${OCAML_PREFIX}/lib/ocaml/Makefile.config"

  # Show what's left with build paths (should be none critical)
  echo "Remaining build paths in Makefile.config:"
  grep -n "build_artifacts\|build_env" "${OCAML_PREFIX}/lib/ocaml/Makefile.config" || echo "  (none)"
fi

for CHANGE in "activate" "deactivate"
do
  mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
  cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
done
