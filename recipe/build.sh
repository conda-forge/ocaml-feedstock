#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Avoids an annoying 'directory not found'
mkdir -p "${PREFIX}"/lib

if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export OCAML_PREFIX="${PREFIX}"
  SH_EXT="sh"
else
  export OCAML_PREFIX="${PREFIX}"/Library
  SH_EXT="bat"
fi

CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir="${OCAML_PREFIX}"/share/man
  -prefix "${OCAML_PREFIX}"
)

if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
  # Cross-compilation: use separate script for 3-stage build
  # This builds NATIVE target binaries (not just a cross-compiler)
  #
  # The script will be REMOVED once OCaml 5.4.0 is available natively on conda-forge.
  # At that point, we can simplify to a 2-stage process using native 5.4.0 to cross-compile.
  #
  # Current 3-stage process:
  #   Stage 1: Build native OCaml for build platform (x86_64)
  #   Stage 2: Build cross-compiler (runs on x86_64, generates target code)
  #   Stage 3: Use cross-compiler to build native target binaries

  export OCAMLLIB="${OCAML_PREFIX}/lib/ocaml"
  source "${RECIPE_DIR}/building/cross-compile.sh"
else
  # Native build: self-bootstrap
  # Set up compiler variables (paths are hardcoded in binaries, simplify to basename)
  export CC=$(basename "${CC}")
  export ASPP="$CC -c"
  # Windows (MSYS2/MinGW) doesn't set AS/AR/RANLIB - provide defaults
  export AS=$(basename "${AS:-as}")
  export AR=$(basename "${AR:-ar}")
  export RANLIB=$(basename "${RANLIB:-ranlib}")

  # Windows: flexdll needs windres with proper preprocessor setup
  if [[ "${target_platform}" == "win-"* ]]; then
    # Create shell script wrapper for windres that sets up the preprocessor
    # Make calls 'windres' from MSYS2 bash, so we need a shell script
    cat > "${BUILD_PREFIX}/Library/bin/windres" << EOF
#!/bin/bash
# Windres wrapper to set up GCC preprocessor
REAL_WINDRES="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-windres.exe"
CPP="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-cpp.exe"
exec "\${REAL_WINDRES}" --preprocessor="\${CPP}" --preprocessor-arg=-E --preprocessor-arg=-xc-header --preprocessor-arg=-DRC_INVOKED "\$@"
EOF
    chmod +x "${BUILD_PREFIX}/Library/bin/windres"
  fi

  [[ "${SKIP_MAKE_TESTS:-"0"}" == "0" ]] && CONFIG_ARGS+=(--enable-ocamltest)

  ./configure "${CONFIG_ARGS[@]}" # >& /dev/null

  # Patch config to use shell variables (like cross-compilation does)
  # This avoids baking in placeholder paths that break with prefix relocation
  config_file="utils/config.generated.ml"
  if [[ -f "$config_file" ]]; then
    perl -i -pe 's/^let asm = .*/let asm = {|\$AS|}/' "$config_file"
    perl -i -pe 's/^let c_compiler = .*/let c_compiler = {|\$CC|}/' "$config_file"
    perl -i -pe 's/^let mkexe = .*/let mkexe = {|\$CC|}/' "$config_file"
    if [[ "${target_platform}" == "osx-"* ]]; then
      perl -i -pe 's/^let mkdll = .*/let mkdll = {|\$CC -shared -undefined dynamic_lookup|}/' "$config_file"
    else
      perl -i -pe 's/^let mkdll = .*/let mkdll = {|\$CC -shared|}/' "$config_file"
    fi
    perl -i -pe 's/^let mkmaindll = .*/let mkmaindll = {|\$CC -shared|}/' "$config_file"
  fi

  make world.opt -j"${CPU_COUNT}" # >& /dev/null

  if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
    rm testsuite/tests/unicode/$'\u898b'.ml
  fi

  [[ "${SKIP_MAKE_TESTS:-"0"}" == "0" ]] && make ocamltest -j "${CPU_COUNT}"
  [[ "${SKIP_MAKE_TESTS:-"0"}" == "0" ]] && make tests
  make install >& /dev/null
fi

# Fix Makefile.config: replace BUILD_PREFIX paths with PREFIX paths
# BUILD_PREFIX won't be relocated by conda, so we need to use PREFIX
if [[ -f "${OCAML_PREFIX}/lib/ocaml/Makefile.config" ]]; then
  perl -pe -i "s#${BUILD_PREFIX}#${PREFIX}#g" "${OCAML_PREFIX}/lib/ocaml/Makefile.config"
fi

# Windows doesn't support symlinks - replace with copies
if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  for bin in "${OCAML_PREFIX}"/bin/*; do
    if [[ -L "$bin" ]]; then
      target=$(readlink "$bin")
      rm "$bin"
      cp "${OCAML_PREFIX}/bin/${target}" "$bin"
    fi
  done
fi

# Fix shebangs and exec paths in installed scripts
for bin in "${OCAML_PREFIX}"/bin/*
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

# Fix hardcoded BUILD_PREFIX paths in Makefile.config
# The build_env paths won't exist at runtime, replace with standard tool names
if [[ -f "${OCAML_PREFIX}/lib/ocaml/Makefile.config" ]]; then
  echo ""
  echo "=== Fixing Makefile.config paths ==="
  # Replace BUILD_PREFIX paths with just the tool basename
  # e.g., /path/to/build_env/bin/x86_64-conda-linux-gnu-strip -> strip
  perl -i -pe 's|STRIP=.*/build_env/.*/(?:.*-)?strip|STRIP=strip|g' "${OCAML_PREFIX}/lib/ocaml/Makefile.config"
fi

for CHANGE in "activate" "deactivate"
do
  mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
  cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
done
