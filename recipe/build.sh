#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'                                                                                                                                                       

mkdir -p "${PREFIX}"/lib "${SRC_DIR}"/_logs

# Platform detection and OCAML_PREFIX setup
if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export OCAML_PREFIX="${PREFIX}"
  SH_EXT="sh"
else
  export OCAML_PREFIX="${PREFIX}"/Library
  SH_EXT="bat"
fi

export OCAMLLIB="${OCAML_PREFIX}/lib/ocaml"

CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir="${OCAML_PREFIX}"/share/man
  -prefix "${OCAML_PREFIX}"
)

if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
  # Cross-compilation: use unified 3-stage build script
  source "${RECIPE_DIR}/building/cross-compile.sh"
else
  # Native build: self-bootstrap

  # non-Unix: setup mingw toolchain
  if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
    _MINGW_CC=$(find "${BUILD_PREFIX}" -name "x86_64-w64-mingw32-gcc.exe" -type f 2>/dev/null | head -1)
    if [[ -n "${_MINGW_CC}" ]]; then
      _MINGW_DIR=$(dirname "${_MINGW_CC}")
      AR="${_MINGW_DIR}/x86_64-w64-mingw32-ar"
      AS="${_MINGW_DIR}/x86_64-w64-mingw32-as"
      CC="${_MINGW_CC}"
      RANLIB="${_MINGW_DIR}/x86_64-w64-mingw32-ranlib"
      export PATH="${_MINGW_DIR}:${PATH}"

      # Create 'gcc' alias for windres preprocessor
      if [[ ! -f "${_MINGW_DIR}/gcc.exe" ]]; then
        cp "${_MINGW_CC}" "${_MINGW_DIR}/gcc.exe"
      fi
    fi

    # Find and setup windres
    _WINDRES=$(find "${BUILD_PREFIX}" \( -name "x86_64-w64-mingw32-windres.exe" -o -name "windres.exe" \) 2>/dev/null | head -1)
    if [[ -n "${_WINDRES}" ]]; then
      _WINDRES_DIR=$(dirname "${_WINDRES}")
      export PATH="${_WINDRES_DIR}:${PATH}"
      if [[ ! -f "${_WINDRES_DIR}/windres.exe" ]]; then
        cp "${_WINDRES}" "${_WINDRES_DIR}/windres.exe"
      fi
    fi
  fi

  # Simplify compiler paths to basenames (hardcoded in binaries)
  export CC=$(basename "${CC}")
  export ASPP="$CC -c"
  export AS=$(basename "${AS:-as}")
  export AR=$(basename "${AR:-ar}")
  export RANLIB=$(basename "${RANLIB:-ranlib}")

  # Platform-specific linker flags
  if [[ "${target_platform}" == "osx-"* ]]; then
    # macOS: lld for ld64/ar compatibility, headerpad for install_name_tool
    export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld -Wl,-headerpad_max_install_names -L${PREFIX}/lib"
    export LIBRARY_PATH="${PREFIX}/lib:${LIBRARY_PATH:-}"
    export DYLD_LIBRARY_PATH="${PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
  elif [[ "${target_platform}" == "linux-"* ]]; then
    export LDFLAGS="${LDFLAGS:-} -L${PREFIX}/lib"
    export LIBRARY_PATH="${PREFIX}/lib:${LIBRARY_PATH:-}"
  fi

  export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH:-}"

  if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
    CONFIG_ARGS+=(--enable-ocamltest)
  fi

  ./configure "${CONFIG_ARGS[@]}" LDFLAGS="${LDFLAGS:-}" > "${SRC_DIR}"/_logs/configure.log 2>&1 || { cat "${SRC_DIR}"/_logs/configure.log; exit 1; }

  # non-Unix: fix TOOLCHAIN and FLEXDLL_CHAIN, build flexdll support object
  if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
    if [[ -f "Makefile.config" ]]; then
      # Fix TOOLCHAIN (used by flexdll directly)
      if ! grep -qE "^TOOLCHAIN[[:space:]]*=.*mingw64" Makefile.config; then
        if grep -qE "^TOOLCHAIN" Makefile.config; then
          perl -i -pe 's/^TOOLCHAIN.*/TOOLCHAIN=mingw64/' Makefile.config
        else
          echo "TOOLCHAIN=mingw64" >> Makefile.config
        fi
      fi

      # Fix FLEXDLL_CHAIN (used by OCaml to pass CHAINS to flexdll)
      if ! grep -qE "^FLEXDLL_CHAIN[[:space:]]*=.*mingw64" Makefile.config; then
        if grep -qE "^FLEXDLL_CHAIN" Makefile.config; then
          perl -i -pe 's/^FLEXDLL_CHAIN.*/FLEXDLL_CHAIN=mingw64/' Makefile.config
        else
          echo "FLEXDLL_CHAIN=mingw64" >> Makefile.config
        fi
      fi

      # Build flexdll support object for NATIVECCLIBS
      if [[ -d "flexdll" ]]; then
        make -C flexdll TOOLCHAIN=mingw64 flexdll_mingw64.o 2>/dev/null || true
        if [[ -f "flexdll/flexdll_mingw64.o" ]]; then
          FLEXDLL_OBJ="${SRC_DIR}/flexdll/flexdll_mingw64.o"
          if grep -q "^NATIVECCLIBS" Makefile.config; then
            perl -i -pe "s|^(NATIVECCLIBS=.*)|\$1 ${FLEXDLL_OBJ}|" Makefile.config
          else
            echo "NATIVECCLIBS=${FLEXDLL_OBJ}" >> Makefile.config
          fi
        fi
      fi
    fi
  fi

  # Patch config.generated.ml with compiler paths for build
  config_file="utils/config.generated.ml"
  if [[ -f "$config_file" ]]; then
    if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
      _FULL_CC=$(command -v "${CC}" 2>/dev/null || echo "${CC}")
      _FULL_AS=$(command -v "${AS}" 2>/dev/null || echo "${AS}")
      export _FULL_CC _FULL_AS

      if [[ "${target_platform}" == "osx-"* ]]; then
        export _BUILD_MKEXE="${_FULL_CC} -fuse-ld=lld -Wl,-headerpad_max_install_names"
        export _BUILD_MKDLL="${_FULL_CC} -fuse-ld=lld -Wl,-headerpad_max_install_names -shared -undefined dynamic_lookup"
      else
        # Linux: -Wl,-E exports symbols for ocamlnat (native toplevel)
        export _BUILD_MKEXE="${_FULL_CC} -Wl,-E"
        export _BUILD_MKDLL="${_FULL_CC} -shared"
      fi

      perl -i -pe 's/^let asm = .*/let asm = {|$ENV{_FULL_AS}|}/' "$config_file"
      perl -i -pe 's/^let c_compiler = .*/let c_compiler = {|$ENV{_FULL_CC}|}/' "$config_file"
      perl -i -pe 's/^let mkexe = .*/let mkexe = {|$ENV{_BUILD_MKEXE}|}/' "$config_file"
      perl -i -pe 's/^let mkdll = .*/let mkdll = {|$ENV{_BUILD_MKDLL}|}/' "$config_file"
      perl -i -pe 's/^let mkmaindll = .*/let mkmaindll = {|$ENV{_BUILD_MKDLL}|}/' "$config_file"
    else
      # non-Unix: use placeholders for runtime
      perl -i -pe 's/^let asm = .*/let asm = {|%AS%|}/' "$config_file"
      perl -i -pe 's/^let c_compiler = .*/let c_compiler = {|%CC%|}/' "$config_file"
    fi
  fi

  make world.opt -j"${CPU_COUNT}" > "${SRC_DIR}"/_logs/world.log 2>&1 || { cat "${SRC_DIR}"/_logs/world.log; exit 1; }

  # non-Unix: remove problematic unicode test file
  if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
    rm -f testsuite/tests/unicode/$'\u898b'.ml
  fi

  if [[ "${SKIP_MAKE_TESTS:-0}" == "0" ]]; then
    make ocamltest -j "${CPU_COUNT}" > "${SRC_DIR}"/_logs/ocamltest.log 2>&1 || { cat "${SRC_DIR}"/_logs/ocamltest.log; }
    make tests > "${SRC_DIR}"/_logs/tests.log 2>&1 || { grep -3 'tests failed' "${SRC_DIR}"/_logs/tests.log; }
  fi

  make install > "${SRC_DIR}"/_logs/install.log 2>&1 || { cat "${SRC_DIR}"/_logs/install.log; exit 1; }
fi

# Post-install fixes

# Fix Makefile.config: replace BUILD_PREFIX paths with PREFIX
if [[ -f "${OCAML_PREFIX}/lib/ocaml/Makefile.config" ]]; then
  perl -i -pe "s#${BUILD_PREFIX}#${PREFIX}#g" "${OCAML_PREFIX}/lib/ocaml/Makefile.config"
  perl -i -pe 's|STRIP=.*/build_env/.*/(?:.*-)?strip|STRIP=strip|g' "${OCAML_PREFIX}/lib/ocaml/Makefile.config"
fi

# Fix config.ml: replace build-time paths with runtime shell variables
CONFIG_ML="${OCAML_PREFIX}/lib/ocaml/config.ml"
if [[ -f "$CONFIG_ML" ]]; then
  if [[ "${target_platform}" == "linux-"* ]]; then
    perl -i -pe 's/^let asm = .*/let asm = {|\$AS|}/' "$CONFIG_ML"
    perl -i -pe 's/^let c_compiler = .*/let c_compiler = {|\$CC|}/' "$CONFIG_ML"
    perl -i -pe 's/^let mkexe = .*/let mkexe = {|\$CC -Wl,-E|}/' "$CONFIG_ML"
    perl -i -pe 's/^let mkdll = .*/let mkdll = {|\$CC -shared|}/' "$CONFIG_ML"
    perl -i -pe 's/^let mkmaindll = .*/let mkmaindll = {|\$CC -shared|}/' "$CONFIG_ML"
  elif [[ "${target_platform}" == "osx-"* ]]; then
    perl -i -pe 's/^let asm = .*/let asm = {|\$AS|}/' "$CONFIG_ML"
    perl -i -pe 's/^let c_compiler = .*/let c_compiler = {|\$CC|}/' "$CONFIG_ML"
    perl -i -pe 's/^let mkexe = .*/let mkexe = {|\$CC -fuse-ld=lld -Wl,-headerpad_max_install_names|}/' "$CONFIG_ML"
    perl -i -pe 's/^let mkdll = .*/let mkdll = {|\$CC -fuse-ld=lld -Wl,-headerpad_max_install_names -shared -undefined dynamic_lookup|}/' "$CONFIG_ML"
    perl -i -pe 's/^let mkmaindll = .*/let mkmaindll = {|\$CC -fuse-ld=lld -Wl,-headerpad_max_install_names -shared -undefined dynamic_lookup|}/' "$CONFIG_ML"
  fi
fi

# non-Unix: replace symlinks with copies
if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  for bin in "${OCAML_PREFIX}"/bin/*; do
    if [[ -L "$bin" ]]; then
      target=$(readlink "$bin")
      rm "$bin"
      cp "${OCAML_PREFIX}/bin/${target}" "$bin"
    fi
  done
fi

# Fix bytecode wrapper shebangs
for bin in "${OCAML_PREFIX}"/bin/*; do
  [[ -f "$bin" ]] || continue
  [[ -L "$bin" ]] && continue

  # Check for ocamlrun reference (need 350 bytes for long conda placeholder paths)
  if head -c 350 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
    if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
      perl -e '
        use strict;
        use warnings;

        my $file = $ARGV[0];
        open(my $fh, "<:raw", $file) or die "Cannot open $file: $!";
        my $content = do { local $/; <$fh> };
        close($fh);

        my $first_nl = index($content, "\n");
        exit 0 if $first_nl < 0;

        my $shebang = substr($content, 0, $first_nl);

        if ($shebang =~ m{^#!.*/bin/sh}) {
            # Shell wrapper format: fix the exec line
            my $second_nl = index($content, "\n", $first_nl + 1);
            if ($second_nl > $first_nl) {
                my $exec_line = substr($content, $first_nl + 1, $second_nl - $first_nl - 1);
                my $rest = substr($content, $second_nl);

                if ($exec_line =~ /exec.*ocamlrun.*\"\$0\".*\"\$\@\"/) {
                    my $new_exec = q{exec "$(dirname "$0")/ocamlrun" "$0" "$@"};
                    my $new_content = $shebang . "\n" . $new_exec . $rest;
                    open(my $out, ">:raw", $file) or die "Cannot write $file: $!";
                    print $out $new_content;
                    close($out);
                }
            }
        } elsif ($shebang =~ m{^#!.*ocamlrun}) {
            # Direct ocamlrun shebang (cross-compiled): use env
            my $rest = substr($content, $first_nl);
            my $new_content = "#!/usr/bin/env ocamlrun" . $rest;
            open(my $out, ">:raw", $file) or die "Cannot write $file: $!";
            print $out $new_content;
            close($out);
        }
      ' "$bin" 2>/dev/null || true
    fi
    continue
  fi

  # Pure shell scripts: fix exec statements
  if file "$bin" 2>/dev/null | grep -qE "shell script|POSIX shell|text"; then
    perl -i -pe "s#exec '([^']*)'#exec \$1#g" "$bin"
    perl -i -pe 's#exec \Q'"${OCAML_PREFIX}"'\E/bin#exec \$(dirname "\$0")#g' "$bin"
  fi
done

# Install activation scripts
for CHANGE in "activate" "deactivate"; do
  mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
  cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
done
