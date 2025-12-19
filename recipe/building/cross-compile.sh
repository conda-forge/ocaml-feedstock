#!/usr/bin/env bash
# Cross-compilation script for OCaml 5.4.0
#
# This script builds NATIVE target binaries using a 3-stage process:
#   Stage 1: Build native OCaml for the build platform (x86_64)
#   Stage 2: Build cross-compiler (runs on x86_64, generates target code)
#   Stage 3: Use cross-compiler to build native target binaries
#
# Supports: osx-arm64, linux-aarch64, linux-ppc64le (from x86_64)
#
# This script will be REMOVED once OCaml 5.4.0 is available natively on conda-forge.
# At that point, we can use the native 5.4.0 package to cross-compile directly.

set -euo pipefail

# Log file for build output inspection
BUILD_LOG="${SRC_DIR}/cross-compile.log"
exec > >(tee -a "${BUILD_LOG}") 2>&1

echo "============================================================"
echo "OCaml ${PKG_VERSION} Cross-Compilation for ${target_platform}"
echo "Build platform: ${build_platform}"
echo "Log file: ${BUILD_LOG}"
echo "============================================================"

# Save original cross-compilation environment
_build_alias="${build_alias}"
_host_alias="${host_alias}"
_OCAML_PREFIX="${OCAML_PREFIX}"

# Ensure cross-compiler paths are absolute
# conda_build.sh sometimes strips paths, sometimes doesn't - handle both cases
_ensure_full_path() {
  local cmd="$1"
  if [[ "$cmd" == /* ]]; then
    # Already absolute path
    echo "$cmd"
  else
    # Relative - prepend BUILD_PREFIX/bin
    echo "${BUILD_PREFIX}/bin/${cmd}"
  fi
}
_CC="$(_ensure_full_path "${CC}")"
_CXX="$(_ensure_full_path "${CXX:-}")"
_AR="$(_ensure_full_path "${AR}")"
_AS="$(_ensure_full_path "${AS}")"
_RANLIB="$(_ensure_full_path "${RANLIB}")"
_CFLAGS="${CFLAGS:-}"
_LDFLAGS="${LDFLAGS:-}"
_PATH="${PATH}"

# macOS: Add -fuse-ld=lld to use LLVM's linker (ld64 _2 rebuild incompatible with LLVM ar)
if [[ "${build_platform}" == "osx-"* ]]; then
  _LDFLAGS="-fuse-ld=lld ${_LDFLAGS}"
fi

echo "Cross-compiler paths (resolved):"
echo "  CC=${CC} -> _CC=${_CC}"
echo "  AR=${AR} -> _AR=${_AR}"
echo "  AS=${AS} -> _AS=${_AS}"
echo "  RANLIB=${RANLIB} -> _RANLIB=${_RANLIB}"

# Common configure arguments
CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir="${OCAML_PREFIX}"/share/man
)

# ============================================================================
# Stage 1: Build native OCaml for build platform
# ============================================================================
echo ""
echo "=== Stage 1: Building native OCaml ${PKG_VERSION} for ${build_platform} ==="
echo ""

# Clear cross-compilation environment
unset build_alias host_alias HOST TARGET_ARCH
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS

STAGE1_PREFIX="${SRC_DIR}/_native"
mkdir -p "${STAGE1_PREFIX}"
export OCAML_PREFIX="${STAGE1_PREFIX}"
export OCAMLLIB="${OCAML_PREFIX}/lib/ocaml"

# CRITICAL: Override PKG_CONFIG_PATH for Stage 1 to find x86_64 zstd in BUILD_PREFIX
# Without this, pkg-config finds target-arch zstd from $PREFIX causing linker errors
export PKG_CONFIG_PATH="${BUILD_PREFIX}/lib/pkgconfig:${BUILD_PREFIX}/share/pkgconfig"

# Ensure linker can find zstd from BUILD_PREFIX
export LIBRARY_PATH="${BUILD_PREFIX}/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

echo "Stage 1 PKG_CONFIG_PATH: ${PKG_CONFIG_PATH}"

# Platform-specific compiler setup for Stage 1
if [[ "${build_platform}" == "osx-"* ]]; then
  # macOS: use clang with build_alias prefix
  _STAGE1_CONFIG_ARGS=(
    --build="${_build_alias}"
    --host="${_build_alias}"
    AR="${_build_alias}-ar"
    AS="${_build_alias}-as"
    ASPP="${CC_FOR_BUILD} -c"
    CC="${CC_FOR_BUILD}"
    CPP="${_build_alias}-clang-cpp"
    LD="${_build_alias}-ld"
    LIPO="${_build_alias}-lipo"
    NM="${_build_alias}-nm"
    NMEDIT="${_build_alias}-nmedit"
    OTOOL="${_build_alias}-otool"
    RANLIB="${_build_alias}-ranlib"
    STRIP="${_build_alias}-strip"
    CFLAGS="-march=core2 -mtune=haswell -mssse3"
    # -fuse-ld=lld: Use LLVM's linker to match LLVM's ar (ld64 _2 rebuild incompatible)
    LDFLAGS="-fuse-ld=lld -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs"
  )
else
  # Linux: use gcc with build_alias prefix
  _STAGE1_CONFIG_ARGS=(
    --build="${_build_alias}"
    --host="${_build_alias}"
    AR="${_build_alias}-ar"
    AS="${_build_alias}-as"
    ASPP="${CC_FOR_BUILD} -c"
    CC="${CC_FOR_BUILD}"
    LD="${_build_alias}-ld"
    NM="${_build_alias}-nm"
    RANLIB="${_build_alias}-ranlib"
    STRIP="${_build_alias}-strip"
    CFLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe"
    LDFLAGS="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--gc-sections"
  )
fi

echo "Stage 1 compiler: ${CC_FOR_BUILD}"

./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_STAGE1_CONFIG_ARGS[@]}" \
  --target="${_build_alias}"

make world.opt CPPFLAGS="-D_DEFAULT_SOURCE" -j"${CPU_COUNT}"
make install

# Save build_config.h for Stage 3 runtime build
cp runtime/build_config.h "${SRC_DIR}/build_config.h.stage1"

make distclean

# ============================================================================
# Stage 2: Build cross-compiler (runs on build platform, generates target code)
# ============================================================================
echo ""
echo "=== Stage 2: Building cross-compiler (${_build_alias} -> ${_host_alias}) ==="
echo ""

export PATH="${STAGE1_PREFIX}/bin:${_PATH}"
export OCAMLLIB="${STAGE1_PREFIX}/lib/ocaml"

STAGE2_PREFIX="${SRC_DIR}/_cross"
mkdir -p "${STAGE2_PREFIX}"
export OCAML_PREFIX="${STAGE2_PREFIX}"

# CRITICAL: Keep PKG_CONFIG_PATH pointing to x86_64 zstd in BUILD_PREFIX
# The cross-compiler binary runs on x86_64, so it needs x86_64 zstd
export PKG_CONFIG_PATH="${BUILD_PREFIX}/lib/pkgconfig:${BUILD_PREFIX}/share/pkgconfig"

# Ensure linker can find zstd from BUILD_PREFIX
export LIBRARY_PATH="${BUILD_PREFIX}/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

echo "Stage 2 PKG_CONFIG_PATH: ${PKG_CONFIG_PATH}"

# Setup cross-ocamlmklib wrapper
# The native ocamlmklib has BUILD linker baked in (Config.mkdll, Config.ar)
# The wrapper uses CROSS_CC/CROSS_AR environment variables for cross-compilation
chmod +x "${RECIPE_DIR}"/building/cross-ocamlmklib.sh
export CROSS_CC="${_CC}"
export CROSS_AR="${_AR}"
_CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"

echo "Stage 2 CROSS_MKLIB: ${_CROSS_MKLIB}"

# Stage 2 configure: Build a cross-compiler (runs on BUILD, generates TARGET code)
# - CC/LD/etc. = BUILD tools (to compile the compiler itself)
# - AS = TARGET assembler (ocamlopt invokes this to assemble generated code)
# Important: DON'T pass CFLAGS here - they go to Makefile.config and would
# leak x86_64 flags to TARGET compiler in crossopt
_STAGE2_CONFIG_ARGS=(
  --build="${_build_alias}"
  --host="${_build_alias}"
  AR="${_build_alias}-ar"
  AS="${_AS}"                   # TARGET assembler - used by ocamlopt for generated code
  ASPP="${_CC} -c"              # TARGET C compiler as assembler-with-preprocessor
  CC="${CC_FOR_BUILD}"          # BUILD compiler - to compile the OCaml compiler itself
  LD="${_build_alias}-ld"
  NM="${_build_alias}-nm"
  RANLIB="${_build_alias}-ranlib"
  STRIP="${_build_alias}-strip"
)
if [[ "${build_platform}" == "osx-"* ]]; then
  _STAGE2_CONFIG_ARGS+=(
    CPP="${_build_alias}-clang-cpp"
    LIPO="${_build_alias}-lipo"
    NMEDIT="${_build_alias}-nmedit"
    OTOOL="${_build_alias}-otool"
  )
fi

# Disable getentropy for cross-compilation: configure tests with BUILD compiler
# but TARGET sysroot (glibc 2.17) doesn't have sys/random.h (added in glibc 2.25)
./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_STAGE2_CONFIG_ARGS[@]}" \
  --target="${_host_alias}" \
  ac_cv_func_getentropy=no

# Patch utils/config.generated.ml for cross-compilation
# Configure detects BUILD compiler/tools but cross-compiler needs TARGET tools baked in
echo "Stage 2: Patching utils/config.generated.ml for cross-compiler..."

# ASM: TARGET assembler (macOS clang needs -c flag to prevent linking)
if [[ "${build_platform}" == "osx-"* ]]; then
  export _TARGET_ASM="${_CC} -c"
else
  export _TARGET_ASM="${_AS}"
fi
perl -i -pe 's/^let asm = .*/let asm = {|$ENV{_TARGET_ASM}|}/' utils/config.generated.ml

# MKDLL/MKMAINDLL: TARGET linker for .cmxs shared libraries
if [[ "${build_platform}" == "osx-"* ]]; then
  export _MKDLL="${_CC} -shared -undefined dynamic_lookup -L."
else
  export _MKDLL="${_CC} -shared -L."
fi
perl -i -pe 's/^let mkdll = .*/let mkdll = {|$ENV{_MKDLL}|}/' utils/config.generated.ml
perl -i -pe 's/^let mkmaindll = .*/let mkmaindll = {|$ENV{_MKDLL}|}/' utils/config.generated.ml

# C_COMPILER: TARGET cross-compiler for native linking
export _CC_TARGET="${_CC}"
perl -i -pe 's/^let c_compiler = .*/let c_compiler = {|$ENV{_CC_TARGET}|}/' utils/config.generated.ml

# MKEXE: TARGET linker for native executables (Linux needs -Wl,-E)
if [[ "${build_platform}" == "osx-"* ]]; then
  export _MKEXE="${_CC} ${_LDFLAGS}"
else
  export _MKEXE="${_CC} -Wl,-E ${_LDFLAGS}"
fi
perl -i -pe 's/^let mkexe = .*/let mkexe = {|$ENV{_MKEXE}|}/' utils/config.generated.ml

# MODEL: PowerPC requires "ppc64le" (assertion in asmcomp/power/arch.ml:54)
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  perl -i -pe 's/^let model = .*/let model = {|ppc64le|}/' utils/config.generated.ml
fi

# NATIVE_C_LIBRARIES: add -ldl for Linux glibc 2.17
if [[ "${build_platform}" != "osx-"* ]]; then
  perl -i -pe 's/^let native_c_libraries = \{\|(.*)\|\}/let native_c_libraries = {|$1 -ldl|}/' utils/config.generated.ml
fi

echo "  Patched: asm, mkdll, mkmaindll, c_compiler, mkexe$(
  [[ "${target_platform}" == "linux-ppc64le" ]] && echo ", model"
)$(
  [[ "${build_platform}" != "osx-"* ]] && echo ", native_c_libraries"
)"

# Apply conda-forge cross-compilation patches
cp "${RECIPE_DIR}/building/Makefile.cross" .
# Use -N to skip if already applied, || true to not fail if reversed
patch -N -p0 < "${RECIPE_DIR}/building/Makefile.patch" || true

# Fix BYTECCLIBS for cross-compilation: configure tests dlopen with BUILD compiler
# (modern glibc ≥2.34 has dlopen in libc), but TARGET sysroot (glibc 2.17) needs -ldl.
# Append -ldl to whatever configure detected (don't hardcode the full string).
if [[ "${build_platform}" != "osx-"* ]]; then
  echo "Stage 2: Appending -ldl to BYTECCLIBS in Makefile.config"
  perl -i -pe 's/^(BYTECCLIBS=.*)$/$1 -ldl/' Makefile.config
  grep '^BYTECCLIBS' Makefile.config
fi

# crossopt builds TARGET runtime assembly (arm64.S, power.S) which needs TARGET assembler
# macOS: use clang as assembler (integrated ARM64 assembler)
# Linux: use binutils cross-assembler
if [[ "${build_platform}" == "osx-"* ]]; then
  _STAGE2_AS="${_CC}"
else
  _STAGE2_AS="${_AS}"
fi

# SAK_CFLAGS: BUILD-appropriate CFLAGS for sak tool (runs on build machine, not target)
# Must NOT contain target-specific flags like -mtune=power8
if [[ "${build_platform}" == "osx-"* ]]; then
  _SAK_CFLAGS="-march=core2 -mtune=haswell -mssse3"
else
  _SAK_CFLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe"
fi

# Determine target ARCH for OCaml (configure detected build arch, not target)
# OCaml uses: amd64, arm64, power, i386, etc.
if [[ "${_host_alias}" == *"aarch64"* ]] || [[ "${_host_alias}" == *"arm64"* ]]; then
  _TARGET_ARCH="arm64"
elif [[ "${_host_alias}" == *"ppc64le"* ]] || [[ "${_host_alias}" == *"powerpc64le"* ]]; then
  _TARGET_ARCH="power"
else
  _TARGET_ARCH="amd64"
fi
echo "Target ARCH for crossopt: ${_TARGET_ARCH}"

# crossopt needs:
# - ARCH for correct runtime assembly file selection (configure detected wrong arch)
# - CAMLOPT=ocamlopt to use native ocamlopt from Stage 1 (via PATH) - REQUIRED!
# - CC for target code (runtime shared libs)
# - CFLAGS for target C compilation flags
# - CPPFLAGS for feature test macros (getentropy needs _DEFAULT_SOURCE on glibc)
# - SAK_CC/SAK_CFLAGS/SAK_LINK for build-time tools (sak runs on build machine)
# - CROSS_MKLIB for cross-compilation of otherlibs (uses CROSS_CC/CROSS_AR)
# - ZSTD_LIBS to link against BUILD zstd (cross-compiler runs on build machine)
make crossopt \
  ARCH="${_TARGET_ARCH}" \
  AS="${_STAGE2_AS}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  CROSS_CC="${_CC}" \
  CROSS_AR="${_AR}" \
  CROSS_MKLIB="${_CROSS_MKLIB}" \
  CAMLOPT=ocamlopt \
  CFLAGS="${_CFLAGS}" \
  CPPFLAGS="-D_DEFAULT_SOURCE" \
  SAK_CC="${CC_FOR_BUILD}" \
  SAK_CFLAGS="${_SAK_CFLAGS}" \
  SAK_LINK="${CC_FOR_BUILD} \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)" \
  ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd" \
  -j"${CPU_COUNT}"
make installcross
make distclean

# ============================================================================
# Stage 3: Build native target binaries using the cross-compiler
# ============================================================================
echo ""
echo "=== Stage 3: Building native ${_host_alias} binaries ==="
echo ""

# PATH order: STAGE1 first (for host tools like ocamlrun), then STAGE2 (for cross-compiler)
export PATH="${STAGE1_PREFIX}/bin:${STAGE2_PREFIX}/bin:${_PATH}"
export OCAMLLIB="${STAGE2_PREFIX}/lib/ocaml"

# CRITICAL: Reset PKG_CONFIG_PATH to point to target-arch zstd in PREFIX
# Stage 3 builds target binaries that need target-arch zstd at runtime
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"

# Save cross-compiler path (x86_64 binary that generates TARGET code)
_CROSS_OCAMLOPT="${STAGE2_PREFIX}/bin/ocamlopt"

# Reset to final install prefix
export OCAML_PREFIX="${_OCAML_PREFIX}"

_STAGE3_CONFIG_ARGS=(
  --build="${_build_alias}"
  --host="${_host_alias}"
  --target="${_host_alias}"
  --with-target-bindir="${PREFIX}/bin"
  AR="${_AR}"
  AS="${_AS}"
  CC="${_CC}"
  RANLIB="${_RANLIB}"
  CFLAGS="${_CFLAGS}"
  LDFLAGS="${_LDFLAGS}"
)

# Platform-specific tools setup
if [[ "${build_platform}" == "osx-"* ]]; then
  # macOS cross-compilation: tools use host_alias prefix
  _STAGE3_CONFIG_ARGS+=(
    LD="${_host_alias}-ld"
    NM="${_host_alias}-nm"
    STRIP="${_host_alias}-strip"
    LIPO="${_host_alias}-lipo"
    OTOOL="${_host_alias}-otool"
  )
else
  # Linux cross-compilation
  _STAGE3_CONFIG_ARGS+=(
    LD="${_host_alias}-ld"
    NM="${_host_alias}-nm"
    STRIP="${_host_alias}-strip"
  )
fi

# Platform-specific assembler setup (ASPP = assembler with C preprocessor)
# ARM64 variants: aarch64 (Linux), arm64 (macOS)
if [[ "${_host_alias}" == *"aarch64"* ]] || [[ "${_host_alias}" == *"arm64"* ]]; then
  _STAGE3_CONFIG_ARGS+=(ASPP="${_CC} -c")
elif [[ "${_host_alias}" == *"ppc64le"* ]] || [[ "${_host_alias}" == *"powerpc64le"* ]]; then
  _STAGE3_CONFIG_ARGS+=(ASPP="${_CC} -c")
fi

# Disable getentropy: TARGET sysroot (glibc 2.17) doesn't have sys/random.h
./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_STAGE3_CONFIG_ARGS[@]}" \
  ac_cv_func_getentropy=no

# Apply conda-forge cross-compilation patches (needed again after configure regenerates Makefile)
cp "${RECIPE_DIR}/building/Makefile.cross" .
patch -N -p0 < "${RECIPE_DIR}/building/Makefile.patch" || true

# Fix BYTECCLIBS for cross-compilation: configure tests dlopen with BUILD compiler
# (modern glibc ≥2.34 has dlopen in libc), but TARGET sysroot (glibc 2.17) needs -ldl.
# Append -ldl to whatever configure detected (don't hardcode the full string).
if [[ "${build_platform}" != "osx-"* ]]; then
  echo "Stage 3: Appending -ldl to BYTECCLIBS in Makefile.config"
  perl -i -pe 's/^(BYTECCLIBS=.*)$/$1 -ldl/' Makefile.config
  grep '^BYTECCLIBS' Makefile.config
fi

# Patch config for RUNTIME - use shell variables $AS/$CC instead of hardcoded paths
# These get expanded by conda's compiler activation at runtime
echo "Stage 3: Patching config for runtime (using \$AS/\$CC shell variables)..."

if [[ "${build_platform}" == "osx-"* ]]; then
  export _RUNTIME_MKDLL="\$CC -shared -undefined dynamic_lookup"
else
  export _RUNTIME_MKDLL="\$CC -shared"
fi

config_file="utils/config.generated.ml"
perl -i -pe 's/^let asm = .*/let asm = {|\$AS|}/' "$config_file"
perl -i -pe 's/^let c_compiler = .*/let c_compiler = {|\$CC|}/' "$config_file"
perl -i -pe 's/^let mkdll = .*/let mkdll = {|$ENV{_RUNTIME_MKDLL}|}/' "$config_file"
perl -i -pe 's/^let mkmaindll = .*/let mkmaindll = {|$ENV{_RUNTIME_MKDLL}|}/' "$config_file"
perl -i -pe 's/^let mkexe = .*/let mkexe = {|\$CC|}/' "$config_file"
if [[ "${build_platform}" != "osx-"* ]]; then
  perl -i -pe 's/^let native_c_libraries = \{\|(.*)\|\}/let native_c_libraries = {|$1 -ldl|}/' "$config_file"
fi
if [[ "${target_platform}" == "linux-ppc64le" ]]; then
  perl -i -pe 's/^let model = .*/let model = {|ppc64le|}/' "$config_file"
fi

# Build native target binaries using cross-compiler
# Pass AS/CC explicitly to ensure cross-assembler is used for ARM64/PPC64LE assembly
# macOS: use clang as assembler (integrated ARM64 assembler works better than standalone as)
# Linux: use binutils cross-assembler
if [[ "${build_platform}" == "osx-"* ]]; then
  _CROSS_AS="${_CC}"
else
  _CROSS_AS="${_AS}"
fi

# Build with target cross-toolchain
# CRITICAL: Use _CROSS_OCAMLOPT (cross-compiler) not ocamlopt from PATH (native)
# The cross-compiler produces ARM64/PPC64LE code and links with correct stdlib
# ZSTD_LIBS: Link against HOST (target arch) zstd library for compression support
make crosscompiledopt \
  ARCH="${_TARGET_ARCH}" \
  CAMLOPT="${_CROSS_OCAMLOPT}" \
  AS="${_CROSS_AS}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  CROSS_CC="${_CC}" \
  CROSS_AR="${_AR}" \
  CROSS_MKLIB="${_CROSS_MKLIB}" \
  CPPFLAGS="-D_DEFAULT_SOURCE" \
  ZSTD_LIBS="-L${PREFIX}/lib -lzstd" \
  -j"${CPU_COUNT}"

# Fix build_config.h for target runtime
cp "${SRC_DIR}/build_config.h.stage1" runtime/build_config.h
perl -i -pe "s#${STAGE1_PREFIX}/lib/ocaml#${PREFIX}/lib/ocaml#g" runtime/build_config.h
perl -i -pe "s#${_build_alias}#${_host_alias}#g" runtime/build_config.h

# BYTECCLIBS: Linux glibc 2.17 needs explicit -ldl for dlopen/dlclose/dlsym
_BYTECCLIBS="-lm -lpthread"
if [[ "${build_platform}" != "osx-"* ]]; then
  _BYTECCLIBS="-lm -lpthread -ldl"
fi

# Build runtime with target cross-toolchain
# BYTECCLIBS needed for dlopen/dlclose/dlsym (glibc 2.17 needs -ldl) and zstd compression
# ZSTD_LIBS for finding target-arch zstd library
# SAK_CC/SAK_CFLAGS for build-time tools that run on build machine
make crosscompiledruntime \
  ARCH="${_TARGET_ARCH}" \
  CAMLOPT="${_CROSS_OCAMLOPT}" \
  AS="${_CROSS_AS}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  CROSS_CC="${_CC}" \
  CROSS_AR="${_AR}" \
  CROSS_MKLIB="${_CROSS_MKLIB}" \
  CPPFLAGS="-D_DEFAULT_SOURCE" \
  BYTECCLIBS="${_BYTECCLIBS} -L${PREFIX}/lib -lzstd" \
  ZSTD_LIBS="-L${PREFIX}/lib -lzstd" \
  CHECKSTACK_CC="${CC_FOR_BUILD}" \
  SAK_CC="${CC_FOR_BUILD}" \
  SAK_CFLAGS="${_SAK_CFLAGS}" \
  SAK_LINK="${CC_FOR_BUILD} \$(OC_LDFLAGS) \$(LDFLAGS) \$(OUTPUTEXE)\$(1) \$(2)" \
  -j"${CPU_COUNT}"

# Install
make installcross

# Set OCAMLLIB for post-install processing
export OCAMLLIB="${OCAML_PREFIX}/lib/ocaml"

# Fix installed config.ml with runtime-friendly tool paths ($AS/$CC shell variables)
CONFIG_ML="${OCAML_PREFIX}/lib/ocaml/config.ml"
if [[ -f "$CONFIG_ML" ]]; then
  echo "Patching installed config.ml for runtime..."
  perl -i -pe 's/^let asm = \{\|.*\|\}/let asm = {|\$AS|}/' "$CONFIG_ML"
  perl -i -pe 's/^let c_compiler = \{\|.*\|\}/let c_compiler = {|\$CC|}/' "$CONFIG_ML"
fi

# Fix bytecode shebangs - replace hardcoded paths with #!/usr/bin/env ocamlrun
echo "Fixing bytecode shebangs..."
_shebang_count=0
for bin in "${OCAML_PREFIX}"/bin/*; do
  [[ -f "$bin" ]] || continue
  if head -c 256 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
    perl -e '
      my $file = $ARGV[0];
      open(my $fh, "<:raw", $file) or die "Cannot open $file: $!";
      my $content = do { local $/; <$fh> };
      close($fh);
      my $newline_pos = index($content, "\n");
      if ($newline_pos > 0 && substr($content, 0, 2) eq "#!") {
          my $new_content = "#!/usr/bin/env ocamlrun" . substr($content, $newline_pos);
          open(my $out, ">:raw", $file) or die "Cannot write $file: $!";
          print $out $new_content;
          close($out);
      }
    ' "$bin"
    ((_shebang_count++)) || true
  fi
done
echo "  Fixed ${_shebang_count} bytecode executables"

echo ""
echo "=== Cross-compilation complete for ${_host_alias} ==="
