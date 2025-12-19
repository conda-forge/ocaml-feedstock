#!/usr/bin/env bash
set -eu

# Windows: find mingw toolchain and add to PATH
if [[ "${target_platform:-}" != "linux-"* ]] && [[ "${target_platform:-}" != "osx-"* ]]; then
  _MINGW_GCC=$(find "${BUILD_PREFIX}" -name "x86_64-w64-mingw32-gcc.exe" -type f 2>/dev/null | head -1)
  if [[ -n "${_MINGW_GCC}" ]]; then
    _MINGW_DIR=$(dirname "${_MINGW_GCC}")
    export PATH="${_MINGW_DIR}:${PATH}"

    # Create 'gcc' alias for windres preprocessor (windres calls 'gcc' not 'x86_64-w64-mingw32-gcc')
    if [[ ! -f "${_MINGW_DIR}/gcc.exe" ]]; then
      cp "${_MINGW_GCC}" "${_MINGW_DIR}/gcc.exe"
    fi
  fi

  # Find windres (needed by flexdll to create version resources)
  _WINDRES=$(find "${BUILD_PREFIX}" \( -name "x86_64-w64-mingw32-windres.exe" -o -name "windres.exe" \) 2>/dev/null | head -1)
  if [[ -n "${_WINDRES}" ]]; then
    _WINDRES_DIR=$(dirname "${_WINDRES}")
    export PATH="${_WINDRES_DIR}:${PATH}"
    # Create 'windres' copy if only prefixed version exists
    if [[ ! -f "${_WINDRES_DIR}/windres" ]] && [[ ! -f "${_WINDRES_DIR}/windres.exe" ]]; then
      cp "${_WINDRES}" "${_WINDRES_DIR}/windres.exe"
    fi
  fi

  echo "=== Windows PATH setup ==="
  echo "PATH (first 500 chars): ${PATH:0:500}"
  which gcc 2>/dev/null || echo "gcc not found in PATH"
  which windres 2>/dev/null || echo "windres not found in PATH"
fi

# Paths are hardcoded in binaries, simplify to basename
export CC=$(basename "${CC:-x86_64-w64-mingw32-gcc}")
export ASPP="$CC -c"
export AS=$(basename "${AS:-x86_64-w64-mingw32-as}")
export AR=$(basename "${AR:-x86_64-w64-mingw32-ar}")
export RANLIB=$(basename "${RANLIB:-x86_64-w64-mingw32-ranlib}")

mkdir -p ${PREFIX}/lib "${SRC_DIR}"/_logs

if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  export OCAML_PREFIX="${PREFIX}/Library"
  SH_EXT="bat"
else
  export OCAML_PREFIX="${PREFIX}"
  SH_EXT="sh"
fi

export OCAMLLIB="${OCAML_PREFIX}/lib/ocaml"

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
  if [[ ${SKIP_MAKE_TEST:-"0"} == "0" ]]; then
    CONFIG_ARGS+=(--enable-ocamltest)
  fi

  # macOS: use lld to avoid ld64/ar incompatibility (ld64 rejects LLVM ar archives)
  # Also add -headerpad_max_install_names so install_name_tool can modify rpaths during packaging
  # And -L${PREFIX}/lib so linker can find zstd
  if [[ "${target_platform}" == "osx-"* ]]; then
    export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld -Wl,-headerpad_max_install_names -L${PREFIX}/lib"
    export LIBRARY_PATH="${PREFIX}/lib:${LIBRARY_PATH:-}"
    # Set DYLD_LIBRARY_PATH so freshly-built ocamlc.opt can find libzstd at runtime during build
    export DYLD_LIBRARY_PATH="${PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
  fi

  ./configure "${CONFIG_ARGS[@]}" LDFLAGS="${LDFLAGS:-}" > "${SRC_DIR}"/_logs/configure.log 2>&1 || { cat "${SRC_DIR}"/_logs/configure.log; exit 1; }

  # Windows: ensure TOOLCHAIN and FLEXDLL_CHAIN are set to mingw64 (not empty)
  # TOOLCHAIN is used by flexdll's Makefile directly (via include of Makefile.config)
  # FLEXDLL_CHAIN is used by OCaml to pass CHAINS=$(FLEXDLL_CHAIN) to flexdll
  # If empty, flexdll defaults to building ALL chains including 32-bit mingw
  # which requires i686-w64-mingw32-gcc that conda-forge doesn't provide
  if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
    if [[ -f "Makefile.config" ]]; then
      echo "=== Windows toolchain fix ==="
      echo "Before fix:"
      grep -E "^(TOOLCHAIN|FLEXDLL_CHAIN)" Makefile.config || echo "  (not found)"

      # Fix TOOLCHAIN (used by flexdll directly)
      if ! grep -qE "^TOOLCHAIN[[:space:]]*=.*mingw64" Makefile.config; then
        echo "Fixing TOOLCHAIN..."
        if grep -qE "^TOOLCHAIN" Makefile.config; then
          perl -i -pe 's/^TOOLCHAIN.*/TOOLCHAIN=mingw64/' Makefile.config
        else
          echo "TOOLCHAIN=mingw64" >> Makefile.config
        fi
      fi

      # Fix FLEXDLL_CHAIN (used by OCaml to pass CHAINS to flexdll)
      if ! grep -qE "^FLEXDLL_CHAIN[[:space:]]*=.*mingw64" Makefile.config; then
        echo "Fixing FLEXDLL_CHAIN..."
        if grep -qE "^FLEXDLL_CHAIN" Makefile.config; then
          perl -i -pe 's/^FLEXDLL_CHAIN.*/FLEXDLL_CHAIN=mingw64/' Makefile.config
        else
          echo "FLEXDLL_CHAIN=mingw64" >> Makefile.config
        fi
      fi

      echo "After fix:"
      grep -E "^(TOOLCHAIN|FLEXDLL_CHAIN)" Makefile.config || echo "  (not found)"
    fi
  fi

  # Patch config.generated.ml with actual compiler paths for BUILD
  # OCaml can't expand $CC - it treats it as literal string
  # Use $ENV{} to expand Perl environment variables during patching
  config_file="utils/config.generated.ml"
  if [[ -f "$config_file" ]] && [[ "${target_platform}" == "linux-"* || "${target_platform}" == "osx-"* ]]; then
    echo "Patching $config_file for build..."
    # Need full path to CC for build (basename was exported above, get original)
    _FULL_CC=$(command -v "${CC}" 2>/dev/null || echo "${CC}")
    export _FULL_CC
    export _FULL_AS=$(command -v "${AS}" 2>/dev/null || echo "${AS}")
    if [[ "${target_platform}" == "osx-"* ]]; then
      export _BUILD_MKEXE="${_FULL_CC} -fuse-ld=lld"
      export _BUILD_MKDLL="${_FULL_CC} -fuse-ld=lld -shared -undefined dynamic_lookup"
    else
      # Linux: -Wl,-E exports all symbols from executable for ocamlnat (native toplevel)
      # Without this, dynamically loaded .so files can't resolve caml_alloc1, caml_initialize, etc.
      export _BUILD_MKEXE="${_FULL_CC} -Wl,-E"
      export _BUILD_MKDLL="${_FULL_CC} -shared"
    fi
    perl -i -pe 's/^let asm = .*/let asm = {|$ENV{_FULL_AS}|}/' "$config_file"
    perl -i -pe 's/^let c_compiler = .*/let c_compiler = {|$ENV{_FULL_CC}|}/' "$config_file"
    perl -i -pe 's/^let mkexe = .*/let mkexe = {|$ENV{_BUILD_MKEXE}|}/' "$config_file"
    perl -i -pe 's/^let mkdll = .*/let mkdll = {|$ENV{_BUILD_MKDLL}|}/' "$config_file"
    perl -i -pe 's/^let mkmaindll = .*/let mkmaindll = {|$ENV{_BUILD_MKDLL}|}/' "$config_file"
  fi

  make world.opt -j${CPU_COUNT} > "${SRC_DIR}"/_logs/world.log 2>&1 || { cat "${SRC_DIR}"/_logs/world.log; exit 1; }

  if [[ ${SKIP_MAKE_TEST:-"0"} == "0" ]]; then
    make ocamltest -j ${CPU_COUNT} > "${SRC_DIR}"/_logs/ocamltest.log 2>&1 || { cat "${SRC_DIR}"/_logs/ocamltest.log; exit 1; }
    
    # Let's simply document the failed tests
    make tests > "${SRC_DIR}"/_logs/tests.log 2>&1 || { grep -3 'tests failed' "${SRC_DIR}"/_logs/tests.log; }
  fi

  make install > "${SRC_DIR}"/_logs/install.log 2>&1 || { cat "${SRC_DIR}"/_logs/install.log; exit 1; }

  # Fix compiled-in tool paths for runtime
  # During build we used actual paths (e.g., /path/to/clang -fuse-ld=lld)
  # For runtime we use shell variables that get expanded by user's environment
  echo ""
  echo "=== Fixing compiled-in tool paths for runtime ==="
  CONFIG_ML="${OCAML_PREFIX}/lib/ocaml/config.ml"
  if [[ -f "$CONFIG_ML" ]]; then
    echo "Patching $CONFIG_ML for runtime tool names..."

    # Show current values
    echo "  Before:"
    grep -E "^let (asm|c_compiler|mkexe) =" "$CONFIG_ML" | head -3

    if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
      # Unix: use shell variables that get expanded at runtime
      perl -i -pe 's/^let asm = \{\|.*\|\}/let asm = {|\$AS|}/' "$CONFIG_ML"
      perl -i -pe 's/^let c_compiler = \{\|.*\|\}/let c_compiler = {|\$CC|}/' "$CONFIG_ML"
      if [[ "${target_platform}" == "osx-"* ]]; then
        # macOS: keep -fuse-ld=lld for runtime to avoid ld64/ar incompatibility
        perl -i -pe 's/^let mkexe = \{\|.*\|\}/let mkexe = {|\$CC -fuse-ld=lld|}/' "$CONFIG_ML"
        perl -i -pe 's/^let mkdll = \{\|.*\|\}/let mkdll = {|\$CC -fuse-ld=lld -shared -undefined dynamic_lookup|}/' "$CONFIG_ML"
        perl -i -pe 's/^let mkmaindll = \{\|.*\|\}/let mkmaindll = {|\$CC -fuse-ld=lld -shared -undefined dynamic_lookup|}/' "$CONFIG_ML"
      else
        # Linux: -Wl,-E exports all symbols from executable for ocamlnat (native toplevel)
        perl -i -pe 's/^let mkexe = \{\|.*\|\}/let mkexe = {|\$CC -Wl,-E|}/' "$CONFIG_ML"
        perl -i -pe 's/^let mkdll = \{\|.*\|\}/let mkdll = {|\$CC -shared|}/' "$CONFIG_ML"
        perl -i -pe 's/^let mkmaindll = \{\|.*\|\}/let mkmaindll = {|\$CC -shared|}/' "$CONFIG_ML"
      fi
    else
      # Windows: use mingw tool basenames (must be in PATH)
      perl -i -pe 's/^let asm = \{\|.*\|\}/let asm = {|as|}/' "$CONFIG_ML"
      perl -i -pe 's/^let c_compiler = \{\|.*\|\}/let c_compiler = {|gcc|}/' "$CONFIG_ML"
    fi

    echo "  After:"
    grep -E "^let (asm|c_compiler|mkexe) =" "$CONFIG_ML" | head -3
  else
    echo "WARNING: $CONFIG_ML not found, skipping tool path fixes"
  fi
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
      # Handles two formats:
      #   1. Shell wrapper: #!/bin/sh\nexec '/path/ocamlrun' "$0" "$@"\n<bytecode>
      #   2. Direct shebang: #!/path/ocamlrun\n<bytecode> (cross-compiled)
      perl -e '
        use strict;
        use warnings;

        my $file = $ARGV[0];
        open(my $fh, "<:raw", $file) or die "Cannot open $file: $!";
        my $content = do { local $/; <$fh> };
        close($fh);

        my $first_nl = index($content, "\n");
        die "No newline found in $file" if $first_nl < 0;

        my $shebang = substr($content, 0, $first_nl);
        print "  Shebang: $shebang\n";

        # Check if this is a shell wrapper (#!/bin/sh or #!/usr/bin/sh)
        if ($shebang =~ m{^#!.*/bin/sh}) {
            # Shell wrapper format: fix the exec line
            my $second_nl = index($content, "\n", $first_nl + 1);
            if ($second_nl > $first_nl) {
                my $exec_line = substr($content, $first_nl + 1, $second_nl - $first_nl - 1);
                my $rest = substr($content, $second_nl);

                print "  Old exec: $exec_line\n";

                if ($exec_line =~ /exec.*ocamlrun.*\"\$0\".*\"\$\@\"/) {
                    my $new_exec = q{exec "$(dirname "$0")/ocamlrun" "$0" "$@"};
                    print "  New exec: $new_exec\n";

                    my $new_content = $shebang . "\n" . $new_exec . $rest;
                    open(my $out, ">:raw", $file) or die "Cannot write $file: $!";
                    print $out $new_content;
                    close($out);
                } else {
                    print "  SKIP: exec line not recognized\n";
                }
            }
        } elsif ($shebang =~ m{^#!.*ocamlrun}) {
            # Direct ocamlrun shebang (cross-compiled): replace with env-based
            my $rest = substr($content, $first_nl);
            my $new_shebang = "#!/usr/bin/env ocamlrun";
            print "  New shebang: $new_shebang\n";

            my $new_content = $new_shebang . $rest;
            open(my $out, ">:raw", $file) or die "Cannot write $file: $!";
            print $out $new_content;
            close($out);
        } else {
            print "  SKIP: unknown format\n";
        }
      ' "$bin" 2>&1 || echo "  ERROR processing $bin"

      # Verify the fix (only show text portion)
      echo "  Result: $(head -1 "$bin")"
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
  echo "bin/ocaml shebang:"
  head -1 "${OCAML_PREFIX}/bin/ocaml"
  # Show second line only if it's a shell wrapper
  if head -1 "${OCAML_PREFIX}/bin/ocaml" | grep -q '/bin/sh'; then
    echo "bin/ocaml exec line:"
    head -2 "${OCAML_PREFIX}/bin/ocaml" | tail -1
  fi
fi

# Fix hardcoded BUILD_PREFIX paths in Makefile.config
# The build_env paths won't exist at runtime, replace with standard tool names
if [[ -f "${OCAML_PREFIX}/lib/ocaml/Makefile.config" ]]; then
  echo ""
  echo "=== Fixing Makefile.config paths ==="
  # Replace BUILD_PREFIX paths with just the tool basename
  # e.g., /path/to/build_env/bin/x86_64-conda-linux-gnu-strip -> strip
  # Use perl -i for cross-platform compatibility (macOS sed -i is different)
  perl -i -pe 's|STRIP=.*/build_env/.*/(?:.*-)?strip|STRIP=strip|g' "${OCAML_PREFIX}/lib/ocaml/Makefile.config"

  # Show what's left with build paths (should be none critical)
  echo "Remaining build paths in Makefile.config:"
  grep -n "build_artifacts\|build_env" "${OCAML_PREFIX}/lib/ocaml/Makefile.config" || echo "  (none)"
fi

# Verify artifacts
echo "=== Checking stublib architecture ==="
file ${OCAML_PREFIX}/lib/ocaml/stublibs/dllunixnat.so || echo "file command failed"
readelf -h ${OCAML_PREFIX}/lib/ocaml/stublibs/dllunixnat.so | grep Machine || echo "readelf failed"

for CHANGE in "activate" "deactivate"
do
  mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
  cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
done
