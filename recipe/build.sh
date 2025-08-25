#!/usr/bin/env bash
set -eu

unset build_alias
unset host_alias
unset HOST TARGET_ARCH

# Avoids an annoying 'directory not found'
mkdir -p ${PREFIX}/lib

if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  export OCAML_PREFIX=$PREFIX/Library
  SH_EXT="bat"
elif [[ "${target_platform}" == "osx-arm64" ]]; then
  export OCAML_PREFIX=/tmp/_native && mkdir -p /tmp/_native
  SH_EXT="sh"
else
  export OCAML_PREFIX=$PREFIX
  SH_EXT="sh"
fi

export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

CONFIG_ARGS=(
  --enable-ocamltest
  --enable-shared
  --disable-static
  --mandir=${OCAML_PREFIX}/share/man
  --with-target-bindir=/opt/anaconda1anaconda2anaconda3/bin
)

if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]]; then
  if [[ "${target_platform}" == "osx-arm64" ]]; then
  # --- x86_64 compiler
    _CONFIG_ARGS=(
      --build="x86_64-apple-darwin13.4.0"
      --host="x86_64-apple-darwin13.4.0"
      --target="x86_64-apple-darwin13.4.0"
      AR="x86_64-apple-darwin13.4.0-ar"
      AS="x86_64-apple-darwin13.4.0-clang"
      ASM="x86_64-apple-darwin13.4.0-as"
      ASPP="x86_64-apple-darwin13.4.0-clang -c"
      CC="x86_64-apple-darwin13.4.0-clang"
      CPP="x86_64-apple-darwin13.4.0-clang-cpp"
      LD="x86_64-apple-darwin13.4.0-ld"
      LIPO="x86_64-apple-darwin13.4.0-lipo"
      NM="x86_64-apple-darwin13.4.0-nm"
      NMEDIT="x86_64-apple-darwin13.4.0-nmedit"
      OTOOL="x86_64-apple-darwin13.4.0-otool"
      RANLIB="x86_64-apple-darwin13.4.0-ranlib"
      STRIP="x86_64-apple-darwin13.4.0-strip"
      CFLAGS="-march=core2 -mtune=haswell -mssse3 ${CFLAGS}"
      LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
    )
    bash ./configure -prefix="${OCAML_PREFIX}" "${CONFIG_ARGS[@]}" "${_CONFIG_ARGS[@]}"
    echo "."; echo ".";echo "."; echo "."
    cat Makefile.build_config | grep -v "#" | grep -v "^$"
    cat Makefile.config | grep -v "#" | grep -v "^$"
    echo "."; echo ".";echo "."; echo "."
    make world.opt \
      AR="x86_64-apple-darwin13.4.0-ar" \
      AS="x86_64-apple-darwin13.4.0-clang" \
      ASM="x86_64-apple-darwin13.4.0-as" \
      ASPP="x86_64-apple-darwin13.4.0-clang -c" \
      CC="x86_64-apple-darwin13.4.0-clang" \
      CPP="x86_64-apple-darwin13.4.0-clang-cpp" \
      LD="x86_64-apple-darwin13.4.0-ld" \
      LIPO="x86_64-apple-darwin13.4.0-lipo" \
      NM="x86_64-apple-darwin13.4.0-nm" \
      NMEDIT="x86_64-apple-darwin13.4.0-nmedit" \
      OTOOL="x86_64-apple-darwin13.4.0-otool" \
      RANLIB="x86_64-apple-darwin13.4.0-ranlib" \
      STRIP="x86_64-apple-darwin13.4.0-strip" \
      CFLAGS="-march=core2 -mtune=haswell -mssse3 ${CFLAGS}" \
      LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs" \
      -j${CPU_COUNT} || true
    echo "."; echo ".";echo "."; echo "."
    make runtimeopt \
      AR="x86_64-apple-darwin13.4.0-ar" \
      AS="x86_64-apple-darwin13.4.0-clang" \
      ASM="x86_64-apple-darwin13.4.0-as" \
      ASPP="x86_64-apple-darwin13.4.0-clang -c" \
      CC="x86_64-apple-darwin13.4.0-clang" \
      CPP="x86_64-apple-darwin13.4.0-clang-cpp" \
      LD="x86_64-apple-darwin13.4.0-ld" \
      LIPO="x86_64-apple-darwin13.4.0-lipo" \
      NM="x86_64-apple-darwin13.4.0-nm" \
      NMEDIT="x86_64-apple-darwin13.4.0-nmedit" \
      OTOOL="x86_64-apple-darwin13.4.0-otool" \
      RANLIB="x86_64-apple-darwin13.4.0-ranlib" \
      STRIP="x86_64-apple-darwin13.4.0-strip" \
      CFLAGS="-march=core2 -mtune=haswell -mssse3 ${CFLAGS}" \
      LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs" \
     -j${CPU_COUNT} || true
    echo "."; echo ".";echo "."; echo "."
    make world.opt \
      AR="x86_64-apple-darwin13.4.0-ar" \
      AS="x86_64-apple-darwin13.4.0-clang" \
      ASM="x86_64-apple-darwin13.4.0-as" \
      ASPP="x86_64-apple-darwin13.4.0-clang -c" \
      CC="x86_64-apple-darwin13.4.0-clang" \
      CPP="x86_64-apple-darwin13.4.0-clang-cpp" \
      LD="x86_64-apple-darwin13.4.0-ld" \
      LIPO="x86_64-apple-darwin13.4.0-lipo" \
      NM="x86_64-apple-darwin13.4.0-nm" \
      NMEDIT="x86_64-apple-darwin13.4.0-nmedit" \
      OTOOL="x86_64-apple-darwin13.4.0-otool" \
      RANLIB="x86_64-apple-darwin13.4.0-ranlib" \
      STRIP="x86_64-apple-darwin13.4.0-strip" \
      CFLAGS="-march=core2 -mtune=haswell -mssse3 ${CFLAGS}" \
      LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs" \
      -j${CPU_COUNT} || true
    (cd stdlib && make camlinternalFormatBasics.cmx LDFLAGS="-L../runtime -lasmrun $LDFLAGS") || true
    (head -1 ocamlopt) || true
    (boot/ocamlrun ocamlopt -config | grep -E "(standard_library|bytecomp_c_libraries|native_c_libraries)") || true
    (nm runtime/libasmrun.a | grep -E "(caml_call_gc|caml_initialize|caml_curry2)") || true
    exit 1
    
    make install
    make distclean
    
    export OCAML_PREFIX=${SRC_DIR}/_cross
    _CONFIG_ARGS=(
      --build="x86_64-apple-darwin13.4.0"
      --host="x86_64-apple-darwin13.4.0"
      --target="arm64-apple-darwin13.4.0"
      AR="x86_64-apple-darwin13.4.0-ar"
      AS="x86_64-apple-darwin13.4.0-clang"
      ASM="x86_64-apple-darwin13.4.0-as"
      ASPP="x86_64-apple-darwin13.4.0-clang -c"
      CC="x86_64-apple-darwin13.4.0-clang"
      CPP="x86_64-apple-darwin13.4.0-clang-cpp"
      LD="x86_64-apple-darwin13.4.0-ld"
      NM="x86_64-apple-darwin13.4.0-nm"
      RANLIB="x86_64-apple-darwin13.4.0-ranlib"
      STRIP="x86_64-apple-darwin13.4.0-strip"
      CFLAGS="-march=core2 -mtune=haswell -mssse3 ${CFLAGS}"
      CHECKSTACK_CC="x86_64-apple-darwin13.4.0-clang"
      SAK_CC="x86_64-apple-darwin13.4.0-clang"
      SAK_LINK="x86_64-apple-darwin13.4.0-clang \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)"
    )
    bash ./configure -prefix="${OCAML_PREFIX}" "${CONFIG_ARGS[@]}" "${_CONFIG_ARGS[@]}"
    
    echo "."; echo ".";echo "."; echo "."
    cat Makefile.build_config | grep -v "#" | grep -v "^$"
    cat Makefile.config | grep -v "#" | grep -v "^$"
    
    echo "."; echo ".";echo "."; echo "."
    echo "Make cross-compiler"
    cp "${RECIPE_DIR}"/Makefile.cross .
    patch -p0 < ${RECIPE_DIR}/tmp_Makefile.patch
    make crossopt
    
    echo "."; echo ".";echo "."; echo "."
    echo "Install"
    make install
    make distclean
    
    # --- Cross-compile
    echo "."; echo ".";echo "."; echo "."
    echo "Cross-compiling"
    export PATH="${OCAML_PREFIX}/bin:$PATH"
    OCAMLRUN="${OCAML_PREFIX}"/bin/ocamlrun
    
    # Reset install path
    export OCAML_PREFIX=$PREFIX

    # --- Try to resolve 'Bad CPU' due to missing host exec
    _CONFIG_ARGS=(
      --build="x86_64-apple-darwin13.4.0"
      --host="arm64-apple-darwin20.0.0"
      --target="arm64-apple-darwin20.0.0"
    )
    mkdir -p ${OCAML_PREFIX}/lib
    bash ./configure -prefix="${OCAML_PREFIX}" "${CONFIG_ARGS[@]}" "${_CONFIG_ARGS[@]}"
    make world.opt \
      CHECKSTACK_CC="x86_64-apple-darwin13.4.0-clang" \
      OCAMLRUN="${OCAMLRUN}" \
      SAK_CC="x86_64-apple-darwin13.4.0-clang" \
      SAK_LINK="x86_64-apple-darwin13.4.0-clang \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)" \
      -j${CPU_COUNT}
    make install
  fi
fi
  
# # --- x86_64 compiler
# make core \
#   AS="${CC}" \
#   ASM="${CC}" \
#   ASPP="${CC} -c" \
#   CC="x86_64-apple-darwin13.4.0-clang" \
#   CHECKSTACK_CC="x86_64-apple-darwin13.4.0-clang" \
#   SAK_CC="x86_64-apple-darwin13.4.0-clang" \
#   SAK_LINK="x86_64-apple-darwin13.4.0-clang \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)" \
#   -j${CPU_COUNT} || true

# make coreboot \
#   AS="${CC}" \
#   ASM="${CC}" \
#   ASPP="${CC} -c" \
#   CC="x86_64-apple-darwin13.4.0-clang" \
#   CHECKSTACK_CC="x86_64-apple-darwin13.4.0-clang" \
#   SAK_CC="x86_64-apple-darwin13.4.0-clang" \
#   SAK_LINK="x86_64-apple-darwin13.4.0-clang \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)" \
#   -j${CPU_COUNT} || true

# # --- Cross-compile?
# make opt.opt \
#   AS="${CC}" \
#   ASM="${CC}" \
#   ASPP="${CC} -c" \
#   CHECKSTACK_CC="x86_64-apple-darwin13.4.0-clang" \
#   OCAMLRUN=${SRC_DIR}/runtime/ocamlrun \
#   SAK_CC="x86_64-apple-darwin13.4.0-clang" \
#   SAK_LINK="x86_64-apple-darwin13.4.0-clang \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)" \
#   -j${CPU_COUNT} || true

# make opt.opt.stage0 \
#   AS="${CC}" \
#   ASM="${CC}" \
#   ASPP="${CC} -c" \
#   -j${CPU_COUNT} || true

# make ocaml \
#   AS="${CC}" \
#   ASM="${CC}" \
#   ASPP="${CC} -c" \
#   -j${CPU_COUNT} || true

# for obj in runtime/*.o; do
#   echo "$obj: $(file "$obj" | grep -o 'x86_64\|arm64')"
# done | sort

# make opt.opt \
#   AS="${CC}" \
#   ASM="${CC}" \
#   ASPP="${CC} -c" \
#   -j${CPU_COUNT} || true
#
# make libraryopt \
#   ASM="${CC}"

# Check if cross-compiling - not testing on build architecture
if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
  if [ "$(uname)" = "Darwin" ]; then
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

make install

for bin in ${OCAML_PREFIX}/bin/*
do
  if file "$bin" | grep -q "script executable"; then
    sed -i "s#exec '\([^']*\)'#exec \1#" "$bin"
    sed -i "s#exec ${OCAML_PREFIX}/bin#exec \$(dirname \"\$0\")#" "$bin"
  fi
done

for CHANGE in "activate" "deactivate"
do
  mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
  cp "${RECIPE_DIR}/${CHANGE}.${SH_EXT}" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
done
