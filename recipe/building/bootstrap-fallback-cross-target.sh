#!/usr/bin/env bash
# bootstrap-fallback-cross-target.sh
#
# PURPOSE: Enable first-time builds of cross-target OCaml on new arches (e.g. s390x, riscv64)
# where no pre-published ocaml_<arch> package exists yet in any channel.
#
# LIFECYCLE: This file exists only until an `ocaml_<arch>` package is published to a channel
# and the recipe-level build dependency is restored. Once that dep is active, the
# `$CROSS_COMPILER_DIR/lib/ocaml/stdlib.cma` check in build.sh will pass immediately and
# this function will never be called. At that point this script is dead code and can be
# removed entirely.
#
# USAGE: Designed to be sourced by build.sh immediately before the hard-fail stdlib.cma check.
# Can also be run standalone for testing: bash recipe/building/bootstrap-fallback-cross-target.sh
#
# IMPLEMENTATION NOTE: Uses a staging dir (`_xcross_compiler_fallback/`) to avoid the
# self-referential cp error that occurs when OCAML_INSTALL_PREFIX=BUILD_PREFIX directly.
# build_cross_compiler() step 7/7 copies wrappers from OCAML_INSTALL_PREFIX/bin/ into
# BUILD_PREFIX/bin/ -- if they are the same directory, cp fails with "same file" error.
# This mirrors the pattern used by the native cross-compiler mode at build.sh:5988-6085:
# build into a staging dir first, then tar-transfer into the final destination.

bootstrap_cross_target_from_inline() {
    echo ""
    echo "[bootstrap-fallback] first-build path for ${target_platform:-<unknown target_platform>}"
    echo "[bootstrap-fallback] CROSS_COMPILER_DIR=${CROSS_COMPILER_DIR:-<unset>}"
    echo "[bootstrap-fallback] CROSS_TARGET=${CROSS_TARGET:-<unset>}"

    # If the expected stdlib.cma already exists, nothing to do.
    if [[ -f "${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma" ]]; then
        echo "[bootstrap-fallback] stdlib.cma already present - no-op, returning."
        return 0
    fi

    # Ensure build_cross_compiler() is available (it is defined in build.sh, which sources
    # this file, so it should already be in scope; guard with type check for safety).
    if ! declare -f build_cross_compiler > /dev/null 2>&1; then
        echo "[bootstrap-fallback] ERROR: build_cross_compiler() not defined in scope."
        echo "[bootstrap-fallback] This script must be sourced from build.sh after build_cross_compiler() is defined."
        return 1
    fi

    # CONDA_TOOLCHAIN_BUILD is set by conda's compiler activation on Linux but not on Windows.
    # Mirror the pattern used in build.sh:5863-5867: default to x86_64-w64-mingw32 for non-unix.
    if [[ -z "${CONDA_TOOLCHAIN_BUILD:-}" ]]; then
        if ! is_unix; then
            CONDA_TOOLCHAIN_BUILD="x86_64-w64-mingw32"
            echo "[bootstrap-fallback] CONDA_TOOLCHAIN_BUILD defaulted to x86_64-w64-mingw32 (non-unix)"
        else
            echo "[bootstrap-fallback] ERROR: CONDA_TOOLCHAIN_BUILD not set on unix build."
            echo "[bootstrap-fallback] Cannot call setup_toolchain for native build-host compiler."
            return 1
        fi
    fi

    # Staging dir - distinct from the cross-compiler mode's _xcross_compiler/ dir so both
    # can coexist in the unlikely event both paths run in the same build.
    local _staging_dir="${SRC_DIR}/_xcross_compiler_fallback"
    mkdir -p "${_staging_dir}"

    echo ""
    echo "[bootstrap-fallback] Invoking build_cross_compiler() to populate ${CROSS_COMPILER_DIR} ..."
    echo "[bootstrap-fallback] (this may take several minutes -- bootstrapping a fresh cross-compiler for first-build)"
    echo "[bootstrap-fallback] build_platform=${build_platform:-${target_platform}}"
    echo "[bootstrap-fallback] CONDA_TOOLCHAIN_BUILD=${CONDA_TOOLCHAIN_BUILD}"
    echo "[bootstrap-fallback] staging dir: ${_staging_dir}"

    # Run build_cross_compiler() in a subshell so env exports do not leak.
    # Mirror the setup from the cross-compiler block in build.sh (lines 5988-6008):
    #   1. setup_toolchain "NATIVE" to populate NATIVE_CC, NATIVE_AR, etc.
    #   2. setup_cflags_ldflags "NATIVE" for the build-host's flags.
    #   3. OCAML_PREFIX = BUILD_PREFIX (native OCaml tools installed there).
    #   4. OCAMLLIB  = BUILD_PREFIX/lib/ocaml (native stdlib).
    #   5. OCAML_INSTALL_PREFIX = _staging_dir (NOT BUILD_PREFIX) so build_cross_compiler()
    #      writes wrappers into staging/bin/, avoiding the self-referential cp error.
    # The subshell must cd to $SRC_DIR because configure/make operate on the OCaml source tree.
    (
        set -euo pipefail

        cd "${SRC_DIR}"

        # Setup native (build-host) toolchain variables.
        setup_toolchain "NATIVE" "${CONDA_TOOLCHAIN_BUILD}"
        if is_unix; then
            setup_cflags_ldflags "NATIVE" "${build_platform:-${target_platform}}" "${target_platform}"
        else
            export NATIVE_CFLAGS="${NATIVE_CFLAGS:-}"
            export NATIVE_LDFLAGS="${NATIVE_LDFLAGS:-}"
        fi

        export OCAML_PREFIX="${BUILD_PREFIX}"
        export OCAMLLIB="${OCAML_PREFIX}/lib/ocaml"
        # Write into staging dir, NOT BUILD_PREFIX, to avoid self-referential cp in step 7/7.
        export OCAML_INSTALL_PREFIX="${_staging_dir}"

        build_cross_compiler
    )
    local _rc=$?

    if [[ ${_rc} -ne 0 ]]; then
        echo "[bootstrap-fallback] build_cross_compiler() exited with status ${_rc}."
        echo "[bootstrap-fallback] Leaving CROSS_COMPILER_DIR empty; existing hard-fail check will report the error."
        return 0
    fi

    # Transfer staged output into BUILD_PREFIX so the cross-target block downstream
    # finds the cross-compiler at CROSS_COMPILER_DIR (= BUILD_PREFIX/lib/ocaml-cross-compilers/CROSS_TARGET).
    echo "[bootstrap-fallback] Transferring staged cross-compiler from ${_staging_dir} into BUILD_PREFIX ..."

    # Transfer the cross-compiler tree.
    if [[ -d "${_staging_dir}/lib/ocaml-cross-compilers" ]]; then
        mkdir -p "${BUILD_PREFIX}/lib"
        if is_unix; then
            cp -a "${_staging_dir}/lib/ocaml-cross-compilers/." "${BUILD_PREFIX}/lib/ocaml-cross-compilers/"
        else
            # [W7ZZ] round 63: Windows MSYS2 cannot create symbolic links without the
            # SeCreateSymbolicLink privilege. `cp -a` tried to reproduce the OCaml install
            # tree's symlinks and died as the FIRST AND ONLY fatal error of round 62:
            #   cp: cannot create symbolic link
            #     '.../ocaml-cross-compilers/aarch64-w64-mingw32/bin/ocamldep.exe':
            #     No such file or directory
            # (Azure build 1566480 log:24954-24955, immediately after log:24951
            # "All cross-compilers built successfully" - everything upstream worked.)
            #
            # NOT A NEW MECHANISM: bootstrap-fallback-native.sh:153-167 already hit and
            # solved the identical problem with `cp -rL`, and its comment names the same
            # cause (symlinks such as ocamlc.exe -> ocamlopt.exe). This mirrors that proven
            # idiom rather than adding a third way to copy files.
            #
            # GUARD SCOPE IS DELIBERATE: this helper is SHARED by every cross target.
            # linux-s390x (13/13 tests green), ppc64le, aarch64 and riscv64 all transfer
            # fine with `cp -a`, so the Windows branch must not become the common path.
            # `is_unix` is the same discriminator the native sibling uses.
            echo "[W7ZZ-DIAG] non-unix transfer: dereferencing symlinks (cp -rL)"
            echo "[W7ZZ-DIAG] symlinks in staging tree that will be dereferenced:"
            find "${_staging_dir}/lib/ocaml-cross-compilers" -type l -printf '  %p -> %l\n' 2>/dev/null | head -40 || true

            # [W8AA] round 64: cp -rL DEREFERENCES symlinks, so a DANGLING symlink is
            # FATAL ("cp: cannot stat"), which is how round 63 died at
            # log:23747-23748 (Azure build 1566508):
            #   cp: cannot stat '.../aarch64-w64-mingw32/bin/ocamldep.exe'
            #   cp: cannot stat '.../aarch64-w64-mingw32/bin/ocamlobjinfo.exe'
            # The round-63 find listing showed 6 symlinks: flexlink/ocamlc/ocamllex/
            # ocamlopt -> *.opt.exe all resolve and copied fine, while ocamldep.exe ->
            # ocamldep.byte.exe and ocamlobjinfo.exe -> ocamlobjinfo.byte.exe are
            # DANGLING - the .byte.exe variants are never built for the cross-compiler.
            # NOT A NEW MECHANISM: build.sh:11991-12003 (v05_03BL) already prunes
            # dangling symlinks before the tar transfer for exactly this reason, and
            # its comment names the same cause (installcross makes links whose target
            # was never built because allopt was skipped). This mirrors that idiom.
            # Policy matches v05_03BL: DROP the dangling link, do not retarget it.
            _w8aa_dangling=0
            while IFS= read -r -d '' _w8aa_lnk; do
                if [[ ! -e "$_w8aa_lnk" ]]; then
                    rm -f "$_w8aa_lnk"
                    _w8aa_dangling=$((_w8aa_dangling+1))
                fi
            done < <(find "${_staging_dir}/lib/ocaml-cross-compilers" -type l -print0 2>/dev/null)
            echo "[W8AA] removed ${_w8aa_dangling} dangling symlinks from ${_staging_dir}/lib/ocaml-cross-compilers"

            cp -rL "${_staging_dir}/lib/ocaml-cross-compilers/." "${BUILD_PREFIX}/lib/ocaml-cross-compilers/"

            # [W8AA-B] round 64 DIAGNOSTIC ONLY: we know two links dangle, but not
            # whether ocamldep/ocamlobjinfo exist in ANY form. If they are absent
            # entirely the cross-compiler is incomplete and that will surface later
            # as a far more confusing error. List what is actually there.
            echo "[W8AA-B] regular files in cross-compiler bin after transfer:"
            ls -la "${BUILD_PREFIX}/lib/ocaml-cross-compilers/"*/bin/ 2>/dev/null | head -60 || true
        fi
    fi

    # Transfer ONLY the target-prefixed toolchain wrappers (e.g. s390x-conda-linux-gnu-ocaml-*).
    # Do NOT copy unprefixed binaries that would shadow build-host binaries already in BUILD_PREFIX/bin/.
    if [[ -d "${_staging_dir}/bin" ]]; then
        mkdir -p "${BUILD_PREFIX}/bin"
        find "${_staging_dir}/bin" -maxdepth 1 -type f -name "${CROSS_TARGET}-*" \
            -exec cp -a {} "${BUILD_PREFIX}/bin/" \;
        find "${_staging_dir}/bin" -maxdepth 1 -type l -name "${CROSS_TARGET}-*" \
            -exec cp -a {} "${BUILD_PREFIX}/bin/" \;
    fi

    # Re-check after transfer.
    if [[ -f "${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma" ]]; then
        echo "[bootstrap-fallback] SUCCESS: stdlib.cma now present at ${CROSS_COMPILER_DIR}/lib/ocaml/stdlib.cma"
    else
        echo "[bootstrap-fallback] FAILURE: stdlib.cma still missing after build_cross_compiler() and transfer."
        echo "[bootstrap-fallback] The existing hard-fail check will report the definitive error."
    fi

    return 0
}

# Allow standalone execution for manual testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[bootstrap-fallback] Running standalone (not sourced)."
    echo "[bootstrap-fallback] Set CROSS_COMPILER_DIR, CROSS_TARGET, SRC_DIR, target_platform,"
    echo "[bootstrap-fallback] CONDA_TOOLCHAIN_BUILD, BUILD_PREFIX before calling."
    bootstrap_cross_target_from_inline
fi
