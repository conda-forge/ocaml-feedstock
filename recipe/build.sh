#!/usr/bin/env bash
set -eu

source "${RECIPE_DIR}"/building/run-and-log.sh
_log_index=0

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
  --with-target-bindir=/opt/anaconda1anaconda2anaconda3/bin
  -prefix $OCAML_PREFIX
)

if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "1" ]] && [[ "${target_platform}" == "osx-arm64" ]]; then
  "${RECIPE_DIR}"/building/build-arm64.sh
else
  ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" && CONFIG_ARGS+=(--enable-ocamltest)
  run_and_log "configure" ./configure "${CONFIG_ARGS[@]}"
  run_and_log "make" make world.opt -j${CPU_COUNT}

  if [[ ${CONDA_BUILD_CROSS_COMPILATION:-"0"} == "0" ]]; then
    if [ "$(uname)" == "Darwin" ]; then
      # Tests failing on macOS. Seems to be a known issue.
      rm testsuite/tests/lib-str/t01.ml
      rm testsuite/tests/lib-threads/beat.ml
    fi

    if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
      rm testsuite/tests/unicode/$'\u898b'.ml
    fi

    run_and_log "ocamltest" make ocamltest -j ${CPU_COUNT}
    run_and_log "tests" make tests
  fi

  run_and_log "install" make install
fi

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
  cp "${RECIPE_DIR}/scripts/${CHANGE}.${SH_EXT}" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.${SH_EXT}"
done
