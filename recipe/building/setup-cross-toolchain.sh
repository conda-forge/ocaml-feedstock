#!/bin/bash
# Cross-compilation toolchain setup
# Source this file with: source "${RECIPE_DIR}/building/setup-cross-toolchain.sh"

# Setup cross-compilation toolchain variables
# Sets up both TARGET toolchain (for building target code) and BUILD toolchain (for build-time tools)
#
# Arguments:
#   $1 - platform type ("macos" or "linux")
#
# Required environment variables:
#   CC, AR, AS (target toolchain from conda)
#   CFLAGS, LDFLAGS (target flags from conda)
#   BUILD_PREFIX (conda build prefix)
#   build_alias (conda build alias, e.g., x86_64-conda-linux-gnu)
#
# Exports:
#   _CC, _AR, _RANLIB, _AS, _CFLAGS, _LDFLAGS (target toolchain)
#   _BUILD_AR, _BUILD_RANLIB, _BUILD_NM, _BUILD_CFLAGS, _BUILD_LDFLAGS (build toolchain)
#   _CROSS_AS (platform-specific assembler)
setup_cross_toolchain() {
  local platform_type="$1"

  echo "Setting up cross-compilation toolchain for ${platform_type}..."

  # ============================================================================
  # TARGET cross-compiler (for building target code)
  # ============================================================================

  # macOS clang cross-compilers may not have -cc symlink, only -clang
  _CC="${CC}"
  if [[ ! -x "${_CC}" ]] && [[ "${_CC}" == *"-cc" ]]; then
    _CC_FALLBACK="${_CC%-cc}-clang"
    if [[ -x "${_CC_FALLBACK}" ]]; then
      echo "NOTE: ${_CC} not found, using ${_CC_FALLBACK}"
      _CC="${_CC_FALLBACK}"
    fi
  fi

  _AR="${AR}"
  _RANLIB="${_AR%-ar}-ranlib"
  _CFLAGS="${CFLAGS:-}"
  _LDFLAGS="${LDFLAGS:-}"

  if [[ "${platform_type}" == "linux" ]]; then
    _AS="${AS}"
  fi

  # Platform-specific LDFLAGS for target
  if [[ "${platform_type}" == "macos" ]]; then
    _LDFLAGS="-fuse-ld=lld -Wl,-headerpad_max_install_names ${_LDFLAGS}"
  fi

  # ============================================================================
  # BUILD platform toolchain (for Stage 1 native build and SAK tools)
  # ============================================================================

  if [[ "${platform_type}" == "macos" ]]; then
    # macOS: MUST use LLVM tools (GNU ar format incompatible with ld64)
    # MUST include -L${BUILD_PREFIX}/lib -lzstd to find x86_64 zstd (not arm64 from $PREFIX)
    _BUILD_AR="${BUILD_PREFIX}/bin/llvm-ar"
    _BUILD_RANLIB="${BUILD_PREFIX}/bin/llvm-ranlib"
    _BUILD_NM="${BUILD_PREFIX}/bin/llvm-nm"
    _BUILD_CFLAGS="-march=core2 -mtune=haswell -mssse3 -I${BUILD_PREFIX}/include"
    _BUILD_LDFLAGS="-fuse-ld=lld -L${BUILD_PREFIX}/lib -lzstd -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
    _CROSS_AS="${_CC}"  # macOS: clang integrated assembler for cross
  else
    # Linux: Use binutils from build platform
    _BUILD_AR="${BUILD_PREFIX}/bin/${build_alias}-ar"
    _BUILD_RANLIB="${BUILD_PREFIX}/bin/${build_alias}-ranlib"
    _BUILD_NM="${BUILD_PREFIX}/bin/${build_alias}-nm"
    _BUILD_CFLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -I${BUILD_PREFIX}/include"
    _BUILD_LDFLAGS="-L${BUILD_PREFIX}/lib -lzstd -Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections"
    _CROSS_AS="${_AS}"  # Linux: binutils assembler for cross
  fi

  # Export for use in make commands
  export CROSS_CC="${_CC}"
  export CROSS_AR="${_AR}"

  echo "Target toolchain: CC=${_CC}, AR=${_AR}, AS=${_CROSS_AS}"
  echo "Build toolchain: AR=${_BUILD_AR}, CC=${CC_FOR_BUILD}"
}
