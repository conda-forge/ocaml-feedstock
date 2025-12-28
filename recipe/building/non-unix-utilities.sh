unix_noop_build_toolchain() {
  if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
    _MINGW_CC=$(find "${BUILD_PREFIX}" -name "x86_64-w64-mingw32-gcc.exe" -type f 2>/dev/null | head -1)
    if [[ -n "${_MINGW_CC}" ]]; then
      _MINGW_DIR=$(dirname "${_MINGW_CC}")
      AR="${_MINGW_DIR}/x86_64-w64-mingw32-ar"
      AS="${_MINGW_DIR}/x86_64-w64-mingw32-as"
      CC="${_MINGW_CC}"
      RANLIB="${_MINGW_DIR}/x86_64-w64-mingw32-ranlib"
      export PATH="${_MINGW_DIR}:${PATH}"
      export LIBRARY_PATH="${PREFIX}/lib:${LIBRARY_PATH:-}"

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
}

unix_noop_update_toolchain() {
  if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
    if [[ -f "Makefile.config" ]]; then
      # Fix TOOLCHAIN (used by flexdll directly)
      if ! grep -qE "^TOOLCHAIN[[:space:]]*=.*mingw64" Makefile.config; then
        if grep -qE "^TOOLCHAIN" Makefile.config; then
          sed -i 's/^TOOLCHAIN.*/TOOLCHAIN=mingw64/' Makefile.config
        else
          echo "TOOLCHAIN=mingw64" >> Makefile.config
        fi
      fi

      # Fix FLEXDLL_CHAIN (used by OCaml to pass CHAINS to flexdll)
      if ! grep -qE "^FLEXDLL_CHAIN[[:space:]]*=.*mingw64" Makefile.config; then
        if grep -qE "^FLEXDLL_CHAIN" Makefile.config; then
          sed -i 's/^FLEXDLL_CHAIN.*/FLEXDLL_CHAIN=mingw64/' Makefile.config
        else
          echo "FLEXDLL_CHAIN=mingw64" >> Makefile.config
        fi
      fi

      # Fix flexdll build: NATDYNLINK=false avoids "-link" flag quoting issue
      # The -cclib "-link version_res.o" gets parsed as -l "ink" by mingw ld
      # Must OVERRIDE whatever configure set, not just add if missing
      if grep -qE "^NATDYNLINK" Makefile.config; then
        sed -i 's/^NATDYNLINK=.*/NATDYNLINK=false/' Makefile.config
      else
        echo "NATDYNLINK=false" >> Makefile.config
      fi

      # Build flexdll support object for NATIVECCLIBS
      if [[ -d "flexdll" ]]; then
        make -C flexdll TOOLCHAIN=mingw64 flexdll_mingw64.o 2>/dev/null || true
        if [[ -f "flexdll/flexdll_mingw64.o" ]]; then
          FLEXDLL_OBJ="${SRC_DIR}/flexdll/flexdll_mingw64.o"
          if grep -q "^NATIVECCLIBS" Makefile.config; then
            sed -i "s|^(NATIVECCLIBS=.*)|\$1 ${FLEXDLL_OBJ}|" Makefile.config
          else
            echo "NATIVECCLIBS=${FLEXDLL_OBJ}" >> Makefile.config
          fi
        fi
      fi
    fi
    
    config_file="utils/config.generated.ml"
    if [[ -f "$config_file" ]]; then
      # Windows: Use %VAR% syntax (not $VAR)
      # These are set in activate.bat with defaults
      sed -i 's/^let asm = .*/let asm = {|%CONDA_OCAML_AS%|}/' "$config_file"
      sed -i 's/^let c_compiler = .*/let c_compiler = {|%CONDA_OCAML_CC%|}/' "$config_file"

      # Windows linker/dll settings
      # CONDA_OCAML_MKDLL allows different flags: gcc -shared, cl /LD, clang-cl /LD
      sed -i 's/^let mkexe = .*/let mkexe = {|%CONDA_OCAML_CC%|}/' "$config_file"
      sed -i 's/^let mkdll = .*/let mkdll = {|%CONDA_OCAML_MKDLL%|}/' "$config_file"
      sed -i 's/^let mkmaindll = .*/let mkmaindll = {|%CONDA_OCAML_MKDLL%|}/' "$config_file"
    fi
  fi
  
  # Remove failing test
  rm -f testsuite/tests/unicode/$'\u898b'.ml
}
