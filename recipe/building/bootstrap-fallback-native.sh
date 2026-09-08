#!/usr/bin/env bash
# bootstrap-fallback-native.sh
#
# PURPOSE: Enable cross-target builds on build hosts where no native ocamlc is
# pre-installed (e.g. win-arm64 where ocaml_win-64 cannot be listed as a dep
# due to m2w64 conflicts). This fallback builds native OCaml inline and
# installs it into BUILD_PREFIX so the subsequent cross-target build finds it.
#
# LIFECYCLE: This file exists only until the native ocaml_<build_platform>
# package can be listed as a proper build dependency again. Once that dep is
# restored, ocamlc will already be present in BUILD_PREFIX/bin/ (or
# BUILD_PREFIX/Library/bin/ on Windows) and this function returns immediately
# (no-op). At that point this script is dead code and can be removed.
#
# CHAIN ORDER (invoked by build.sh in this order):
#   1. bootstrap_native_from_inline   (THIS FILE) - ensures native ocamlc on host
#   2. bootstrap_cross_target_from_inline           - ensures cross-compiler tree
#
# USAGE: Designed to be sourced by build.sh immediately before the
# bootstrap-fallback-cross-target.sh hook (which itself runs before the hard-fail
# stdlib.cma check). Can also be run standalone for testing.
#
# IMPLEMENTATION NOTE: Uses a staging dir (_native_compiler_fallback/) so that
# build_native()'s internal steps do not conflict with an already-partial
# BUILD_PREFIX layout. On Windows, build_native() appends /Library to
# OCAML_INSTALL_PREFIX, so we mirror that when transferring.

bootstrap_native_from_inline() {
    echo ""
    echo "[bootstrap-native-fallback] first-build path for ${target_platform:-<unknown target_platform>}"
    echo "[bootstrap-native-fallback] BUILD_PREFIX=${BUILD_PREFIX:-<unset>}"

    # ------------------------------------------------------------------
    # Step 1: Check if native ocamlc is already present. If yes, no-op.
    # ------------------------------------------------------------------
    local _ocamlc_found=0
    if [[ -x "${BUILD_PREFIX}/bin/ocamlc" ]]; then
        echo "[bootstrap-native-fallback] Found ocamlc at ${BUILD_PREFIX}/bin/ocamlc - no-op, returning."
        _ocamlc_found=1
    elif [[ -x "${BUILD_PREFIX}/bin/ocamlc.exe" ]]; then
        echo "[bootstrap-native-fallback] Found ocamlc at ${BUILD_PREFIX}/bin/ocamlc.exe - no-op, returning."
        _ocamlc_found=1
    elif [[ -x "${BUILD_PREFIX}/Library/bin/ocamlc.exe" ]]; then
        echo "[bootstrap-native-fallback] Found ocamlc at ${BUILD_PREFIX}/Library/bin/ocamlc.exe - no-op, returning."
        _ocamlc_found=1
    elif command -v ocamlc > /dev/null 2>&1; then
        echo "[bootstrap-native-fallback] Found ocamlc on PATH ($(command -v ocamlc)) - no-op, returning."
        _ocamlc_found=1
    fi

    if [[ ${_ocamlc_found} -eq 1 ]]; then
        return 0
    fi

    echo "[bootstrap-native-fallback] Native ocamlc not found - running inline build."

    # ------------------------------------------------------------------
    # Step 2: Guard - build_native() must be in scope.
    # ------------------------------------------------------------------
    if ! declare -f build_native > /dev/null 2>&1; then
        echo "[bootstrap-native-fallback] ERROR: build_native() not defined in scope."
        echo "[bootstrap-native-fallback] This script must be sourced from build.sh after build_native() is defined."
        return 1
    fi

    # ------------------------------------------------------------------
    # Step 3: Guard - CONDA_TOOLCHAIN_BUILD. Mirror build.sh and
    # bootstrap-fallback-cross-target.sh defaults.
    # ------------------------------------------------------------------
    if [[ -z "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
        if ! is_unix; then
            CONDA_TOOLCHAIN_BUILD="x86_64-w64-mingw32"
            echo "[bootstrap-native-fallback] CONDA_TOOLCHAIN_BUILD defaulted to x86_64-w64-mingw32 (non-unix)"
        else
            echo "[bootstrap-native-fallback] ERROR: CONDA_TOOLCHAIN_BUILD not set on unix build."
            echo "[bootstrap-native-fallback] Cannot call build_native() without a toolchain triplet."
            return 1
        fi
    fi

    # ------------------------------------------------------------------
    # Step 4: Prepare staging dir.
    # ------------------------------------------------------------------
    local _staging_dir="${SRC_DIR}/_native_compiler_fallback"
    mkdir -p "${_staging_dir}"

    echo ""
    echo "[bootstrap-native-fallback] Invoking build_native() to populate ${_staging_dir} ..."
    echo "[bootstrap-native-fallback] (this may take several minutes - bootstrapping a fresh native compiler)"
    echo "[bootstrap-native-fallback] target_platform=${target_platform:-?}"
    echo "[bootstrap-native-fallback] CONDA_TOOLCHAIN_BUILD=${CONDA_TOOLCHAIN_BUILD}"
    echo "[bootstrap-native-fallback] staging dir: ${_staging_dir}"

    # ------------------------------------------------------------------
    # Step 5: Run build_native() in a subshell so env exports do not leak.
    #
    # build_native() reads:
    #   OCAML_INSTALL_PREFIX  - where to install (defaults to PREFIX if unset)
    #   OCAML_PREFIX          - where the host native OCaml already lives
    #   CONDA_TOOLCHAIN_BUILD - build-host triplet
    # On Windows (non-unix), build_native() appends /Library to
    # OCAML_INSTALL_PREFIX internally (line ~313 of build.sh).
    # We therefore set OCAML_INSTALL_PREFIX to the staging dir WITHOUT /Library;
    # build_native() will append it on Windows itself.
    # ------------------------------------------------------------------
    (
        set -euo pipefail

        cd "${SRC_DIR}"

        export OCAML_PREFIX="${BUILD_PREFIX}"
        export OCAML_INSTALL_PREFIX="${_staging_dir}"

        # Override target context so build_native() sees a pure native build (build_platform == target_platform).
        # The outer cross-target build has target_platform=win-arm64; for OUR native bootstrap we want
        # build_native() to act as if target_platform == build_platform (e.g., win-64).
        export target_platform="${build_platform}"
        export OCAML_TARGET_PLATFORM="${build_platform}"
        # Reset OCAML_TARGET_TRIPLET too — build_native may derive it. For win-64 it's x86_64-w64-mingw32
        # (matching CONDA_TOOLCHAIN_BUILD which we already defaulted).
        export OCAML_TARGET_TRIPLET="${CONDA_TOOLCHAIN_BUILD}"
        echo "[bootstrap-native-fallback] Override: target_platform=${target_platform} OCAML_TARGET_TRIPLET=${OCAML_TARGET_TRIPLET} (was inherited from outer cross-target context)"

        build_native
    )
    local _rc=$?

    if [[ ${_rc} -ne 0 ]]; then
        echo "[bootstrap-native-fallback] build_native() exited with status ${_rc}."
        echo "[bootstrap-native-fallback] Native compiler build failed; cross-target build will likely also fail."
        return 0
    fi

    # ------------------------------------------------------------------
    # Step 6: Transfer staged output into BUILD_PREFIX.
    #
    # On unix:    staging/bin/*        -> BUILD_PREFIX/bin/
    #             staging/lib/ocaml/*  -> BUILD_PREFIX/lib/ocaml/
    # On Windows: build_native() wrote into staging/Library/bin/ etc.
    #             Transfer staging/Library/ -> BUILD_PREFIX/Library/
    # ------------------------------------------------------------------
    echo "[bootstrap-native-fallback] Transferring staged native compiler from ${_staging_dir} into BUILD_PREFIX ..."

    if is_unix; then
        if [[ -d "${_staging_dir}/bin" ]]; then
            mkdir -p "${BUILD_PREFIX}/bin"
            cp -a "${_staging_dir}/bin/." "${BUILD_PREFIX}/bin/"
        fi
        if [[ -d "${_staging_dir}/lib/ocaml" ]]; then
            mkdir -p "${BUILD_PREFIX}/lib/ocaml"
            cp -a "${_staging_dir}/lib/ocaml/." "${BUILD_PREFIX}/lib/ocaml/"
        fi
    else
        # Windows: build_native() appended /Library to OCAML_INSTALL_PREFIX
        # Use cp -rL (dereference symlinks) because Windows MSYS2 cannot create
        # symbolic links without SeCreateSymbolicLink privilege.  The OCaml install
        # tree contains symlinks (e.g. ocamlc.exe -> ocamlopt.exe) that cp -a would
        # try to reproduce as symlinks, causing "cannot create symbolic link" errors.
        if [[ -d "${_staging_dir}/Library" ]]; then
            mkdir -p "${BUILD_PREFIX}/Library"
            cp -rL "${_staging_dir}/Library/." "${BUILD_PREFIX}/Library/"
        fi
        # Also copy top-level bin/ if present (belt-and-suspenders)
        if [[ -d "${_staging_dir}/bin" ]]; then
            mkdir -p "${BUILD_PREFIX}/bin"
            cp -rL "${_staging_dir}/bin/." "${BUILD_PREFIX}/bin/"
        fi
    fi

    # ------------------------------------------------------------------
    # Step 7: Verify post-transfer.
    # ------------------------------------------------------------------
    local _verified=0
    if [[ -x "${BUILD_PREFIX}/bin/ocamlc" ]]; then
        _verified=1
    elif [[ -x "${BUILD_PREFIX}/bin/ocamlc.exe" ]]; then
        _verified=1
    elif [[ -x "${BUILD_PREFIX}/Library/bin/ocamlc.exe" ]]; then
        _verified=1
    fi

    if [[ ${_verified} -eq 1 ]]; then
        echo "[bootstrap-native-fallback] SUCCESS: native ocamlc now present in BUILD_PREFIX."
    else
        echo "[bootstrap-native-fallback] FAILURE: ocamlc still missing after build_native() and transfer."
        echo "[bootstrap-native-fallback] Continuing anyway; downstream checks will report the definitive error."
    fi

    return 0
}

# Allow standalone execution for manual testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[bootstrap-native-fallback] Running standalone (not sourced)."
    echo "[bootstrap-native-fallback] Set SRC_DIR, BUILD_PREFIX, PREFIX, target_platform,"
    echo "[bootstrap-native-fallback] CONDA_TOOLCHAIN_BUILD before calling."
    bootstrap_native_from_inline
fi
