#!/usr/bin/env bash
set -eu

run_and_log() {
  local _logname="$1"
  shift
  local cmd=("$@")

  # Create log directory if it doesn't exist
  mkdir -p "${SRC_DIR}/_logs"

  echo " ";echo "|";echo "|";echo "|";echo "|"
  echo "Running: ${cmd[*]}"
  local start_time=$(date +%s)
  local exit_status_file=$(mktemp)
  # Run the command in a subshell to prevent set -e from terminating
  (
    # Temporarily disable errexit in this subshell
    set +e
    "${cmd[@]}" > "${SRC_DIR}/_logs/${_log_index}_${_logname}.log" 2>&1
    echo $? > "$exit_status_file"
  ) &
  local cmd_pid=$!
  local tail_counter=0

  # Periodically flush and show progress
  while kill -0 $cmd_pid 2>/dev/null; do
    sync
    echo -n "."
    sleep 5
    let "tail_counter += 1"

    if [ $tail_counter -ge 22 ]; then
      echo "."
      tail -5 "${SRC_DIR}/_logs/${_log_index}_${_logname}.log"
      tail_counter=0
    fi
  done

  wait $cmd_pid || true  # Use || true to prevent set -e from triggering
  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  local exit_code=$(cat "$exit_status_file")
  rm "$exit_status_file"

  echo "."
  echo "---------------------------------------------------------------------------"
  printf "Command: %s\n" "${cmd[*]} in ${duration}s"
  echo "Exit code: $exit_code"
  echo "---------------------------------------------------------------------------"

  # Show more context on failure
  if [[ $exit_code -ne 0 ]]; then
    echo "COMMAND FAILED - Last 50 lines of log:"
    tail -50 "${SRC_DIR}/_logs/${_log_index}_${_logname}.log"
  else
    echo "COMMAND SUCCEEDED - Last 20 lines of log:"
    tail -20 "${SRC_DIR}/_logs/${_log_index}_${_logname}.log"
  fi

  echo "---------------------------------------------------------------------------"
  echo "Full log: ${SRC_DIR}/_logs/${_log_index}_${_logname}.log"
  echo "|";echo "|";echo "|";echo "|"

  let "_log_index += 1"
  return $exit_code
}

unset build_alias
unset host_alias
unset HOST TARGET_ARCH

# Avoids an annoying 'directory not found'
mkdir -p ${PREFIX}/lib
_log_index=0

if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  export OCAML_PREFIX=$PREFIX/Library
  SH_EXT="bat"
elif [[ "${target_platform}" == "osx-arm64" ]]; then
  export OCAML_PREFIX=${SRC_DIR}/_native && mkdir -p ${SRC_DIR}/_native
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
      AR="x86_64-apple-darwin13.4.0-ar"
      AS="x86_64-apple-darwin13.4.0-as"
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
    _TARGET=(
      --target="x86_64-apple-darwin13.4.0"
    )
    run_and_log "configure native" ./configure -prefix="${OCAML_PREFIX}" "${CONFIG_ARGS[@]}" "${_CONFIG_ARGS[@]}" "${_TARGET[@]}"
    run_and_log "world native" make world.opt -j${CPU_COUNT}
    run_and_log "install native" make install
    run_and_log "distclean native" make distclean
    
    # Set environment for locally installed ocaml
    _PATH="${PATH}"
    export PATH="${OCAML_PREFIX}/bin:${_PATH}"
    export OCAMLLIB=$OCAML_PREFIX/lib/ocaml
    
    # Set environment for cross-compiler installation
    export OCAML_PREFIX=${SRC_DIR}/_cross
    _TARGET=(
      --target="arm64-apple-darwin20.0.0"
    )
    run_and_log "configure cross" ./configure -prefix="${OCAML_PREFIX}" "${CONFIG_ARGS[@]}" "${_CONFIG_ARGS[@]}" "${_TARGET[@]}"
    cp "${RECIPE_DIR}"/Makefile.cross .
    patch -p0 < ${RECIPE_DIR}/tmp_Makefile.patch
    run_and_log "make cross" make crossopt -j${CPU_COUNT}
    run_and_log "install cross" make installcross
    run_and_log "distclean" make distclean
    
    # --- Cross-compile
    export PATH="${OCAML_PREFIX}/bin:${_PATH}"
    export OCAMLLIB=$OCAML_PREFIX/lib/ocaml
    
    # Reset to final install path
    export OCAML_PREFIX=$PREFIX

    _CONFIG_ARGS=(
      --build="x86_64-apple-darwin13.4.0"
      --host="arm64-apple-darwin20.0.0"
      --target="arm64-apple-darwin20.0.0"
    )
    run_and_log "configure cross-compiled" ./configure -prefix="${OCAML_PREFIX}" "${CONFIG_ARGS[@]}" "${_CONFIG_ARGS[@]}"
    make crossopt \
      OCAMLRUN="${SRC_DIR}/_cross/bin/ocamlrun" \
      NEW_OCAMLRUN="${SRC_DIR}/_cross/bin/ocamlrun" \
      CAMLC="${SRC_DIR}/_cross/bin/ocamlc" \
      CAMLOPT="${SRC_DIR}/_cross/bin/ocamlopt" \
      BEST_OCAMLC="${SRC_DIR}/_cross/bin/ocamlc" \
      BEST_OCAMLOPT="${SRC_DIR}/_cross/bin/ocamlopt" \
      BOOT_OCAMLLEX="${SRC_DIR}/_cross/bin/ocamllex" \
      OCAMLYACC="${SRC_DIR}/_cross/bin/ocamlyacc" \
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
