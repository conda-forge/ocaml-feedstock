#!/usr/bin/env bash
set -eu

# Cross-compilation script for linux-aarch64 and linux-ppc64le from linux-64
#
# CACHING: Set these environment variables to speed up iteration:
#   OCAML_BUILD_CACHE=1    Enable caching (default: 1)
#   OCAML_CACHE_DEV_MODE=1 Ignore build script changes for cache key
#   OCAML_START_STAGE=N    Skip stages before N (1, 2, or 3)
#
# LOGGING: Build output is redirected to log files in $SRC_DIR/build_logs/
#   OCAML_BUILD_VERBOSE=1  Show output on terminal instead of log files
#
# Example: To iterate on Stage 3 only:
#   OCAML_START_STAGE=3 rattler-build build ...

# Source cache helper
source "${RECIPE_DIR}/building/cache-helper.sh"

# Setup logging
LOG_DIR="${SRC_DIR}/build_logs"
mkdir -p "${LOG_DIR}"

# run_logged: Run a command with output to log file
# Usage: run_logged <logname> <command> [args...]
run_logged() {
  local logname="$1"
  shift
  local logfile="${LOG_DIR}/${logname}.log"

  echo "=== Running: $* ===" | tee -a "${logfile}"
  echo "    Log file: ${logfile}"

  if [[ "${OCAML_BUILD_VERBOSE:-0}" == "1" ]]; then
    # Verbose mode: show on terminal and log
    "$@" 2>&1 | tee -a "${logfile}"
    return ${PIPESTATUS[0]}
  else
    # Quiet mode: only log, show summary on error
    if "$@" >> "${logfile}" 2>&1; then
      echo "    ✓ Success (see ${logfile} for details)"
      return 0
    else
      local rc=$?
      echo "    ✗ FAILED (exit code ${rc})"
      echo "    Last 50 lines of log:"
      tail -50 "${logfile}"
      return ${rc}
    fi
  fi
}

# This follows the same 3-stage pattern as build-arm64.sh (for macOS):
#   Stage 1: Build native x86_64 compiler
#   Stage 2: Build cross-compiler (runs on x86_64, targets aarch64/ppc64le)
#   Stage 3: Use cross-compiler to build final target binaries

# Save original environment
_build_alias="$build_alias"
_host_alias="$host_alias"
_OCAML_PREFIX="${OCAML_PREFIX}"
# conda_build.sh strips path from CC with $(basename "$CC"), restore full path
_CC="${BUILD_PREFIX}/bin/${CC}"
_AR="${BUILD_PREFIX}/bin/${AR}"
_AS="${BUILD_PREFIX}/bin/${AS}"
_RANLIB="${BUILD_PREFIX}/bin/${RANLIB}"
_CFLAGS="${CFLAGS:-}"
_LDFLAGS="${LDFLAGS:-}"

# Clear cross-compilation environment for Stage 1
unset build_alias
unset host_alias
unset HOST TARGET_ARCH

# Initialize cache based on target platform
cache_init "${target_platform}"

# Stage 1: Build native x86_64 compiler
echo "=== Stage 1: Building native x86_64 OCaml compiler ==="
export OCAML_PREFIX=${SRC_DIR}/_native && mkdir -p ${SRC_DIR}/_native
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# Ensure linker can find zstd from BUILD_PREFIX
export LIBRARY_PATH="${BUILD_PREFIX}/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

# Common configure args used by all stages
CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir=${OCAML_PREFIX}/share/man
)

# Configure args for native x86_64 build (used by Stage 1 and Stage 2)
# Note: zstd from BUILD_PREFIX is needed for linking ocamlc.opt/ocamlopt.opt
# We add -lzstd to LDFLAGS to ensure it's linked in all stages
_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_build_alias"
  AR="$_build_alias-ar"
  AS="$_build_alias-as"
  ASPP="${CC_FOR_BUILD} -c"
  CC="${CC_FOR_BUILD}"
  LD="$_build_alias-ld"
  NM="$_build_alias-nm"
  RANLIB="$_build_alias-ranlib"
  STRIP="$_build_alias-strip"
  CFLAGS="-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -I${BUILD_PREFIX}/include"
  LDFLAGS="-L${BUILD_PREFIX}/lib -lzstd -Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections -Wl,-rpath,${OCAML_PREFIX}/lib -Wl,-rpath-link,${OCAML_PREFIX}/lib -Wl,-rpath,${BUILD_PREFIX}/lib"
)

# Determine target ARCH for OCaml (used by Stage 2 and Stage 3)
# OCaml uses: amd64, arm64, power, i386, etc.
if [[ "${target_platform}" == "linux-aarch64" ]]; then
  _TARGET_ARCH="arm64"
elif [[ "${_host_alias}" == "linux-ppc64le" ]]; then
  _TARGET_ARCH="power"
else
  _TARGET_ARCH="amd64"
fi
echo "Target ARCH: ${_TARGET_ARCH}"

# Try to restore Stage 1 from cache
if cache_restore "stage1" "${SRC_DIR}/_native" && cache_restore_build_config; then
  echo "=== Stage 1: Restored from cache, skipping build ==="
  # Fix up paths - cached binaries have old BUILD_PREFIX baked in
  cache_fixup_paths
else
  _TARGET=(
    --target="$_build_alias"
  )

  run_logged "stage1_configure" ./configure \
    -prefix="${OCAML_PREFIX}" \
    "${CONFIG_ARGS[@]}" \
    "${_CONFIG_ARGS[@]}" \
    "${_TARGET[@]}"

  run_logged "stage1_world" make world.opt -j${CPU_COUNT}
  run_logged "stage1_install" make install

  # Save build_config.h for cross-compiled runtime
  cp runtime/build_config.h "${SRC_DIR}"

  # Save Stage 1 to cache
  cache_save "stage1" "${SRC_DIR}/_native"
  cache_save_build_config
  cache_save_paths

  make distclean
fi


# Stage 2: Build cross-compiler (runs on x86_64, emits target code)
echo "=== Stage 2: Building cross-compiler (x86_64 -> ${_host_alias}) ==="
_PATH="${PATH}"
export PATH="${SRC_DIR}/_native/bin:${_PATH}"
export OCAMLLIB=${SRC_DIR}/_native/lib/ocaml

# Cross-compiler installs to separate directory
export OCAML_PREFIX=${SRC_DIR}/_cross

# Ensure linker can find zstd from BUILD_PREFIX
# LIBRARY_PATH is used by GCC to find libraries during linking
export LIBRARY_PATH="${BUILD_PREFIX}/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

# Try to restore Stage 2 from cache
if cache_restore "stage2" "${SRC_DIR}/_cross"; then
  echo "=== Stage 2: Restored from cache, skipping build ==="
  # Fix up paths - cached binaries have old BUILD_PREFIX baked in
  cache_fixup_paths
else
  _TARGET=(
    --target="$_host_alias"
  )

  # Disable getentropy for cross-compilation: configure tests with BUILD compiler
  # but TARGET sysroot (glibc 2.17) doesn't have sys/random.h (added in glibc 2.25)
  run_logged "stage2_configure" ./configure \
    -prefix="${OCAML_PREFIX}" \
    "${CONFIG_ARGS[@]}" \
    "${_CONFIG_ARGS[@]}" \
    "${_TARGET[@]}" \
    ac_cv_func_getentropy=no

  # Patch Config.asm in utils/config.generated.ml: configure detects from CC (BUILD)
  # but for cross-compiler we need the TARGET assembler
  echo "Stage 2: Fixing assembler path in utils/config.generated.ml"
  echo "  From: $(grep 'let asm =' utils/config.generated.ml)"
  export _TARGET_ASM="${_AS}"
  perl -i -pe 's/^let asm = .*/let asm = {|$ENV{_TARGET_ASM}|}/' utils/config.generated.ml
  echo "  To:   $(grep 'let asm =' utils/config.generated.ml)"

  # Patch Config.mkdll/mkmaindll: configure uses BUILD linker but cross-compiler
  # needs TARGET linker for creating .cmxs shared libraries
  # Format: "compiler -shared -L." - OCaml adds -o and files separately
  # -L. needed so linker finds just-built stub libraries (libcaml*.a) in current dir
  echo "Stage 2: Fixing mkdll/mkmaindll in utils/config.generated.ml"
  echo "  Old mkdll: $(grep 'let mkdll =' utils/config.generated.ml)"
  export _MKDLL="${_CC} -shared -L."
  perl -i -pe 's/^let mkdll = .*/let mkdll = {|$ENV{_MKDLL}|}/' utils/config.generated.ml
  perl -i -pe 's/^let mkmaindll = .*/let mkmaindll = {|$ENV{_MKDLL}|}/' utils/config.generated.ml
  echo "  New mkdll: $(grep 'let mkdll =' utils/config.generated.ml)"

  # Patch Config.c_compiler: configure detects BUILD compiler but cross-compiler
  # needs TARGET cross-compiler for linking native programs (ocamlopt uses this)
  echo "Stage 2: Fixing c_compiler in utils/config.generated.ml"
  echo "  Old c_compiler: $(grep 'let c_compiler =' utils/config.generated.ml)"
  export _CC_TARGET="${_CC}"
  perl -i -pe 's/^let c_compiler = .*/let c_compiler = {|$ENV{_CC_TARGET}|}/' utils/config.generated.ml
  echo "  New c_compiler: $(grep 'let c_compiler =' utils/config.generated.ml)"

  # Patch Config.mkexe: configure sets BUILD linker but cross-compiler needs TARGET
  # mkexe is used by Ccomp.call_linker for linking native executables (ocamlc.opt, ocamlopt.opt)
  # Format: "compiler [ldflags]" - must include -Wl,-E for symbol export
  echo "Stage 2: Fixing mkexe in utils/config.generated.ml"
  echo "  Old mkexe: $(grep 'let mkexe =' utils/config.generated.ml)"
  export _MKEXE="${_CC} -Wl,-E ${_LDFLAGS}"
  perl -i -pe 's/^let mkexe = .*/let mkexe = {|$ENV{_MKEXE}|}/' utils/config.generated.ml
  echo "  New mkexe: $(grep 'let mkexe =' utils/config.generated.ml)"

  # Patch Config.native_c_libraries: add -ldl for TARGET (glibc 2.17 needs explicit -ldl)
  # Configure tests with BUILD compiler (modern glibc has dlopen in libc) but TARGET needs -ldl
  # This is baked into the cross-compiler and used when linking native executables
  echo "Stage 2: Fixing native_c_libraries in utils/config.generated.ml"
  echo "  Old native_c_libraries: $(grep 'let native_c_libraries =' utils/config.generated.ml)"
  perl -i -pe 's/^let native_c_libraries = \{\|(.*)\|\}/let native_c_libraries = {|$1 -ldl|}/' utils/config.generated.ml
  echo "  New native_c_libraries: $(grep 'let native_c_libraries =' utils/config.generated.ml)"

  # Apply cross-compilation patches
  cp "${RECIPE_DIR}"/building/Makefile.cross .
  patch -N -p0 < ${RECIPE_DIR}/building/tmp_Makefile.patch || true

  # Fix BYTECCLIBS for cross-compilation: configure tests dlopen with BUILD compiler
  # (modern glibc ≥2.34 has dlopen in libc), but TARGET sysroot (glibc 2.17) needs -ldl
  echo "Stage 2: Appending -ldl to BYTECCLIBS in Makefile.config"
  perl -i -pe 's/^(BYTECCLIBS=.*)$/$1 -ldl/' Makefile.config
  grep '^BYTECCLIBS' Makefile.config

  # Setup cross-ocamlmklib wrapper
  # The native ocamlmklib has BUILD linker baked in (Config.mkdll, Config.ar)
  # The wrapper uses CROSS_CC/CROSS_AR environment variables for cross-compilation
  chmod +x "${RECIPE_DIR}"/building/cross-ocamlmklib.sh
  export CROSS_CC="${_CC}"
  export CROSS_AR="${_AR}"
  _CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"

  echo "Target ARCH for crossopt: ${_TARGET_ARCH}"

  # crossopt builds TARGET runtime assembly - needs TARGET assembler and compiler
  # ARCH for correct assembly file selection (configure detected wrong arch)
  # CC/CROSS_CC/CROSS_AR for target C compilation (otherlibs stub libraries)
  # CROSS_MKLIB for cross-aware ocamlmklib wrapper (C stub library builds)
  # CAMLOPT=ocamlopt uses native ocamlopt from PATH (not Makefile.config's complex definition)
  # CFLAGS for target (override x86_64 flags from configure)
  # CPPFLAGS for feature test macros (getentropy needs _DEFAULT_SOURCE on glibc)
  # SAK_CC/SAK_LINK for build-time tools that run on build machine
  run_logged "stage2_crossopt" make crossopt \
    ARCH="${_TARGET_ARCH}" \
    AS="${_AS}" \
    ASPP="${_CC} -c" \
    CC="${_CC}" \
    CROSS_CC="${_CC}" \
    CROSS_AR="${_AR}" \
    CROSS_MKLIB="${_CROSS_MKLIB}" \
    CAMLOPT=ocamlopt \
    CFLAGS="${_CFLAGS}" \
    CPPFLAGS="-D_DEFAULT_SOURCE" \
    SAK_CC="${CC_FOR_BUILD}" \
    ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd" \
    -j${CPU_COUNT}
  run_logged "stage2_installcross" make installcross

  # Save Stage 2 to cache
  cache_save "stage2" "${SRC_DIR}/_cross"
  cache_save_paths

  make distclean
fi


# Stage 3: Cross-compile final binaries for target architecture
echo "=== Stage 3: Cross-compiling final binaries for ${_host_alias} ==="

# Setup cross-ocamlmklib wrapper (may not be set if Stage 2 was restored from cache)
# The native ocamlmklib has BUILD linker baked in (Config.mkdll, Config.ar)
# The wrapper uses CROSS_CC/CROSS_AR environment variables for cross-compilation
chmod +x "${RECIPE_DIR}"/building/cross-ocamlmklib.sh
export CROSS_CC="${_CC}"
export CROSS_AR="${_AR}"
_CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"

# CRITICAL: Save cross-compiler path BEFORE changing OCAML_PREFIX
# _cross/bin/ocamlopt.opt is an x86_64 binary that produces ARM64 code
# _native/bin/ocamlopt.opt is an x86_64 binary that produces x86_64 code
# We MUST use the cross-compiler, or we get "Relocations in generic ELF (EM: 183)"
_CROSS_OCAMLOPT="${OCAML_PREFIX}/bin/ocamlopt"
echo "Stage 3: Using cross-compiler: ${_CROSS_OCAMLOPT}"
file "${_CROSS_OCAMLOPT}.opt" || true

# PATH order: _native first for ocamlrun (x86_64 bytecode interpreter)
# OCAMLRUN must be x86_64 to run bytecode during build
export PATH="${SRC_DIR}/_native/bin:${OCAML_PREFIX}/bin:${_PATH}"
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# Reset to final install path
export OCAML_PREFIX="${_OCAML_PREFIX}"

# Stage 3 config: use target cross-toolchain for native code
_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_host_alias"
  --target="$_host_alias"
  --with-target-bindir="${PREFIX}"/bin
  AR="${_AR}"
  AS="${_AS}"
  CC="${_CC}"
  RANLIB="${_RANLIB}"
  CFLAGS="${_CFLAGS}"
  LDFLAGS="${_LDFLAGS}"
)

# Disable getentropy: TARGET sysroot (glibc 2.17) doesn't have sys/random.h
run_logged "stage3_configure" ./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}" \
  ac_cv_func_getentropy=no

# Apply cross-compilation patches (needed again after configure regenerates Makefile)
cp "${RECIPE_DIR}"/building/Makefile.cross .
patch -N -p0 < ${RECIPE_DIR}/building/tmp_Makefile.patch || true

# Fix BYTECCLIBS for cross-compilation: TARGET sysroot (glibc 2.17) needs -ldl
echo "Stage 3: Appending -ldl to BYTECCLIBS in Makefile.config"
perl -i -pe 's/^(BYTECCLIBS=.*)$/$1 -ldl/' Makefile.config
grep '^BYTECCLIBS' Makefile.config

# Fix NATIVECCLIBS: add -ldl for native code linking (dlopen/dlclose/dlsym)
echo "Stage 3: Appending -ldl to NATIVECCLIBS in Makefile.config"
perl -i -pe 's/^(NATIVECCLIBS=.*)$/$1 -ldl/' Makefile.config
grep '^NATIVECCLIBS' Makefile.config

# Build with target cross-toolchain
# CRITICAL: Use _CROSS_OCAMLOPT (cross-compiler) not ocamlopt from PATH (native)
# The cross-compiler produces ARM64 code and links with ARM64 stdlib
# ZSTD_LIBS: Link against HOST (aarch64) zstd library for compression support
run_logged "stage3_crosscompiledopt" make crosscompiledopt \
  ARCH="${_TARGET_ARCH}" \
  CAMLOPT="${_CROSS_OCAMLOPT}" \
  AS="${_AS}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  CROSS_CC="${_CC}" \
  CROSS_AR="${_AR}" \
  CROSS_MKLIB="${_CROSS_MKLIB}" \
  CPPFLAGS="-D_DEFAULT_SOURCE" \
  ZSTD_LIBS="-L${PREFIX}/lib -lzstd" \
  -j${CPU_COUNT}

# Fix build_config.h paths for target
perl -pe 's#\$SRC_DIR/_native/lib/ocaml#\$PREFIX/lib/ocaml#g' "${SRC_DIR}"/build_config.h > runtime/build_config.h
perl -i -pe "s#${_build_alias}#${_host_alias}#g" runtime/build_config.h

echo "=== build_config.h for target ==="
cat runtime/build_config.h
echo "================================="

# Build runtime with target cross-toolchain
# BYTECCLIBS needed for dlopen/dlclose/dlsym (glibc 2.17 needs -ldl) and zstd compression
# ZSTD_LIBS for finding aarch64 zstd library
run_logged "stage3_crosscompiledruntime" make crosscompiledruntime \
  ARCH="${_TARGET_ARCH}" \
  CAMLOPT="${_CROSS_OCAMLOPT}" \
  AS="${_AS}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  CROSS_CC="${_CC}" \
  CROSS_AR="${_AR}" \
  CROSS_MKLIB="${_CROSS_MKLIB}" \
  CPPFLAGS="-D_DEFAULT_SOURCE" \
  BYTECCLIBS="-L${PREFIX}/lib -lm -lpthread -ldl -lzstd" \
  ZSTD_LIBS="-L${PREFIX}/lib -lzstd" \
  CHECKSTACK_CC="${CC_FOR_BUILD}" \
  SAK_CC="${CC_FOR_BUILD}" \
  -j${CPU_COUNT}

run_logged "stage3_installcross" make installcross

# Fix bytecode shebangs
# Bytecode executables have format: #!/path/to/ocamlrun\n<binary data>
# We must replace the shebang with #!/usr/bin/env ocamlrun to:
#   1. Avoid hardcoded paths that won't exist after installation
#   2. Prevent conda prefix relocation from corrupting the binary data
echo ""
echo "=== Fixing bytecode shebangs ==="
for bin in "${OCAML_PREFIX}"/bin/*; do
  # Skip if not a regular file
  [[ -f "$bin" ]] || continue

  # Check if this is a bytecode executable (shebang contains ocamlrun)
  if head -c 50 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
    echo "Fixing bytecode shebang: $bin"
    # Using perl in binary mode to safely handle bytecode after the shebang
    perl -e '
      my $file = $ARGV[0];
      open(my $fh, "<:raw", $file) or die "Cannot open $file: $!";
      my $content = do { local $/; <$fh> };
      close($fh);

      my $newline_pos = index($content, "\n");
      if ($newline_pos > 0 && substr($content, 0, 2) eq "#!") {
          my $old_shebang = substr($content, 0, $newline_pos);
          print "  Old shebang: $old_shebang\n";
          my $new_content = "#!/usr/bin/env ocamlrun" . substr($content, $newline_pos);
          open(my $out, ">:raw", $file) or die "Cannot write $file: $!";
          print $out $new_content;
          close($out);
          print "  New shebang: #!/usr/bin/env ocamlrun\n";
      } else {
          print "  WARNING: No shebang found in $file\n";
      }
    ' "$bin"
  fi
done

echo ""
echo "=== Cross-compilation complete for ${_host_alias} ==="
