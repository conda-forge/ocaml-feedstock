#!/usr/bin/env bash
set -eu

# Cross-compilation script for osx-arm64 from osx-64
#
# LOGGING: Build output is redirected to log files in $SRC_DIR/build_logs/
#   OCAML_BUILD_VERBOSE=1  Show output on terminal instead of log files

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

# This follows the same 3-stage pattern as build-linux-cross.sh:
#   Stage 1: Build native x86_64 compiler
#   Stage 2: Build cross-compiler (runs on x86_64, targets arm64)
#   Stage 3: Use cross-compiler to build final target binaries

# Save original environment
_build_alias="$build_alias"
_host_alias="$host_alias"
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
_AR="$(_ensure_full_path "${AR}")"
# Derive RANLIB from AR (conda doesn't always set RANLIB correctly for cross-compilation)
# AR=arm64-apple-darwin20.0.0-ar -> RANLIB=arm64-apple-darwin20.0.0-ranlib
_RANLIB="${_AR%-ar}-ranlib"
_CFLAGS="${CFLAGS:-}"
_LDFLAGS="${LDFLAGS:-}"

# macOS: Add -fuse-ld=lld to use LLVM's linker (ld64 _2 rebuild incompatible with LLVM ar)
_LDFLAGS="-fuse-ld=lld ${_LDFLAGS}"

echo "Cross-compiler paths (resolved):"
echo "  CC=${CC} -> _CC=${_CC}"
echo "  AR=${AR} -> _AR=${_AR}"
echo "  RANLIB (derived from AR) -> _RANLIB=${_RANLIB}"

# Clear cross-compilation environment for Stage 1
# CRITICAL: Unset LDFLAGS/CFLAGS - conda-build sets these with -L$PREFIX/lib
# which causes the linker to find arm64 libraries instead of x86_64
unset build_alias host_alias HOST TARGET_ARCH
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS

# Stage 1: Build native x86_64 compiler
echo "=== Stage 1: Building native x86_64 OCaml compiler ==="
export OCAML_PREFIX=${SRC_DIR}/_native && mkdir -p ${SRC_DIR}/_native
export OCAMLLIB=$OCAML_PREFIX/lib/ocaml

# CRITICAL: Override PKG_CONFIG_PATH for Stage 1 to find x86_64 zstd in BUILD_PREFIX
# Without this, pkg-config finds arm64 zstd from $PREFIX causing:
#   "ignoring file $PREFIX/lib/libzstd.dylib, building for macOS-x86_64 but
#    attempting to link with file built for macOS-arm64"
export PKG_CONFIG_PATH="${BUILD_PREFIX}/lib/pkgconfig:${BUILD_PREFIX}/share/pkgconfig"

# Ensure linker can find zstd from BUILD_PREFIX
export LIBRARY_PATH="${BUILD_PREFIX}/lib:${LIBRARY_PATH:-}"
export DYLD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"

# Common configure args used by all stages
CONFIG_ARGS=(
  --enable-shared
  --disable-static
  --mandir=${OCAML_PREFIX}/share/man
)

# Configure args for native x86_64 build (used by Stage 1 and Stage 2)
_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_build_alias"
  AR="$_build_alias-ar"
  AS="$_build_alias-as"
  ASPP="${CC_FOR_BUILD} -c"
  CC="${CC_FOR_BUILD}"
  CPP="$_build_alias-clang-cpp"
  LD="$_build_alias-ld"
  LIPO="$_build_alias-lipo"
  NM="$_build_alias-nm"
  NMEDIT="$_build_alias-nmedit"
  OTOOL="$_build_alias-otool"
  RANLIB="$_build_alias-ranlib"
  STRIP="$_build_alias-strip"
  CFLAGS="-march=core2 -mtune=haswell -mssse3 -I${BUILD_PREFIX}/include"
  # -fuse-ld=lld: Use LLVM's linker to match LLVM's ar (ld64 _2 rebuild incompatible)
  LDFLAGS="-fuse-ld=lld -L${BUILD_PREFIX}/lib -lzstd -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs -Wl,-rpath,${OCAML_PREFIX}/lib -Wl,-rpath,${BUILD_PREFIX}/lib"
)

# Target ARCH for OCaml (arm64 for macOS ARM)
# This is used by Stage 2 and Stage 3 for cross-compilation
_TARGET_ARCH="arm64"

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

make distclean


# Stage 2: Build cross-compiler (runs on x86_64, emits arm64 code)
echo "=== Stage 2: Building cross-compiler (x86_64 -> ${_host_alias}) ==="
_PATH="${PATH}"
export PATH="${SRC_DIR}/_native/bin:${_PATH}"
export OCAMLLIB=${SRC_DIR}/_native/lib/ocaml

# Cross-compiler installs to separate directory
export OCAML_PREFIX=${SRC_DIR}/_cross

# CRITICAL: Keep PKG_CONFIG_PATH pointing to x86_64 zstd in BUILD_PREFIX
# The cross-compiler binary runs on x86_64, so it needs x86_64 zstd
export PKG_CONFIG_PATH="${BUILD_PREFIX}/lib/pkgconfig:${BUILD_PREFIX}/share/pkgconfig"

# Ensure linker can find zstd from BUILD_PREFIX
export LIBRARY_PATH="${BUILD_PREFIX}/lib:${LIBRARY_PATH:-}"
export DYLD_LIBRARY_PATH="${BUILD_PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"

_TARGET=(
  --target="$_host_alias"
)

run_logged "stage2_configure" ./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}" \
  "${_TARGET[@]}"

# Patch utils/config.generated.ml for cross-compilation
# These values are baked into the cross-compiler and used at compile time
echo "Stage 2: Patching utils/config.generated.ml for cross-compilation..."
# CRITICAL: macOS clang needs -c flag or it tries to link (causing "_main" symbol error)
export _TARGET_ASM="${_CC} -c"
export _MKDLL="${_CC} -shared -undefined dynamic_lookup -L."
export _CC_TARGET="${_CC}"
export _MKEXE="${_CC} ${_LDFLAGS}"
perl -i -pe 's/^let asm = .*/let asm = {|$ENV{_TARGET_ASM}|}/' utils/config.generated.ml
perl -i -pe 's/^let mkdll = .*/let mkdll = {|$ENV{_MKDLL}|}/' utils/config.generated.ml
perl -i -pe 's/^let mkmaindll = .*/let mkmaindll = {|$ENV{_MKDLL}|}/' utils/config.generated.ml
perl -i -pe 's/^let c_compiler = .*/let c_compiler = {|$ENV{_CC_TARGET}|}/' utils/config.generated.ml
perl -i -pe 's/^let mkexe = .*/let mkexe = {|$ENV{_MKEXE}|}/' utils/config.generated.ml
echo "  Done (asm, mkdll, c_compiler, mkexe patched)"

# Apply cross-compilation patches
cp "${RECIPE_DIR}"/building/Makefile.cross .
patch -N -p0 < ${RECIPE_DIR}/building/tmp_Makefile.patch || true

# Setup cross-ocamlmklib wrapper
# The native ocamlmklib has BUILD linker baked in (Config.mkdll, Config.ar)
# The wrapper uses CROSS_CC/CROSS_AR environment variables for cross-compilation
chmod +x "${RECIPE_DIR}"/building/cross-ocamlmklib.sh
export CROSS_CC="${_CC}"
export CROSS_AR="${_AR}"
_CROSS_MKLIB="${RECIPE_DIR}/building/cross-ocamlmklib.sh"

# SAK_CFLAGS: BUILD-appropriate CFLAGS for sak tool (runs on x86_64 build machine)
# Must NOT contain target-specific flags
_SAK_CFLAGS="-march=core2 -mtune=haswell -mssse3 -I${BUILD_PREFIX}/include"

echo "Target ARCH for crossopt: ${_TARGET_ARCH}"

# crossopt builds TARGET runtime assembly - needs TARGET assembler and compiler
# ARCH for correct assembly file selection (configure detected wrong arch)
# CC/CROSS_CC/CROSS_AR for target C compilation (otherlibs stub libraries)
# CROSS_MKLIB for cross-aware ocamlmklib wrapper (C stub library builds)
# CAMLOPT=ocamlopt uses native ocamlopt from PATH (not Makefile.config's complex definition)
# CFLAGS for target (override x86_64 flags from configure)
# SAK_CC/SAK_CFLAGS for build-time tools that run on build machine (NOT target CFLAGS!)
# Use clang as assembler on macOS (integrated ARM64 assembler)
run_logged "stage2_crossopt" make crossopt \
  ARCH="${_TARGET_ARCH}" \
  AS="${_CC}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  CROSS_CC="${_CC}" \
  CROSS_AR="${_AR}" \
  CROSS_MKLIB="${_CROSS_MKLIB}" \
  CAMLOPT=ocamlopt \
  CFLAGS="${_CFLAGS}" \
  SAK_CC="${CC_FOR_BUILD}" \
  SAK_CFLAGS="${_SAK_CFLAGS}" \
  SAK_LDFLAGS="-fuse-ld=lld" \
  ZSTD_LIBS="-L${BUILD_PREFIX}/lib -lzstd" \
  -j${CPU_COUNT}
run_logged "stage2_installcross" make installcross

make distclean


# Stage 3: Cross-compile final binaries for target architecture
echo "=== Stage 3: Cross-compiling final binaries for ${_host_alias} ==="

# CRITICAL: Reset PKG_CONFIG_PATH to point to ARM64 zstd in PREFIX
# Stage 3 builds ARM64 binaries that need ARM64 zstd at runtime
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"

# Setup cross-ocamlmklib wrapper
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

# Stage 3 config: use ARM64 cross-toolchain for native code
_CONFIG_ARGS=(
  --build="$_build_alias"
  --host="$_host_alias"
  --target="$_host_alias"
  --with-target-bindir="${PREFIX}"/bin
  AR="${_AR}"
  CC="${_CC}"
  RANLIB="${_RANLIB}"
  CFLAGS="${_CFLAGS}"
  LDFLAGS="${_LDFLAGS}"
)

run_logged "stage3_configure" ./configure \
  -prefix="${OCAML_PREFIX}" \
  "${CONFIG_ARGS[@]}" \
  "${_CONFIG_ARGS[@]}"

# Apply cross-compilation patches (needed again after configure regenerates Makefile)
cp "${RECIPE_DIR}"/building/Makefile.cross .
patch -N -p0 < ${RECIPE_DIR}/building/tmp_Makefile.patch || true

# Patch config files for RUNTIME (Stage 3)
# OCaml 5.3+ uses utils/config.generated.ml (configure generates from .in template)
# CRITICAL: The installed binaries need GENERIC tool paths (cc, as) that work at RUNTIME,
# NOT the build-time cross-compiler paths (arm64-apple-darwin-cc) which don't exist at runtime.
# The BUILD itself uses cross-compiler via make variables, but the compiled-in config is for RUNTIME.
# macOS: -undefined dynamic_lookup is needed for macOS shared libraries
echo "Stage 3: Patching config files for RUNTIME paths..."
echo "  Setting shell variables \$AS and \$CC (expanded by conda's compiler activation)"

config_file="utils/config.generated.ml"
echo "  Patching: $config_file"
# Use shell variables $AS and $CC so conda's compiler activation sets the right tools
# OCaml invokes these via system() which expands shell variables
perl -i -pe 's/^let asm = .*/let asm = {|\$AS|}/' "$config_file"
perl -i -pe 's/^let c_compiler = .*/let c_compiler = {|\$CC|}/' "$config_file"
perl -i -pe 's/^let mkdll = .*/let mkdll = {|\$CC -shared -undefined dynamic_lookup|}/' "$config_file"
perl -i -pe 's/^let mkmaindll = .*/let mkmaindll = {|\$CC -shared -undefined dynamic_lookup|}/' "$config_file"
perl -i -pe 's/^let mkexe = .*/let mkexe = {|\$CC|}/' "$config_file"

echo "  Verifying patched values in utils/config.generated.ml:"
grep -E "^let (asm|c_compiler|mkdll|mkexe) =" utils/config.generated.ml

# Debug: Show key variables before crosscompiledopt
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  STAGE 3 DEBUG: Key variables before crosscompiledopt           ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  _TARGET_ARCH = ${_TARGET_ARCH}"
echo "║  _CROSS_OCAMLOPT = ${_CROSS_OCAMLOPT}"
echo "║  _CC = ${_CC}"
echo "║  Cross-compiler: $(file "${_CROSS_OCAMLOPT}.opt" 2>/dev/null | cut -d: -f2 || echo 'NOT FOUND')"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Build with ARM64 cross-toolchain
# CRITICAL: Use _CROSS_OCAMLOPT (cross-compiler) not ocamlopt from PATH (native)
# The cross-compiler produces ARM64 code and links with ARM64 stdlib
# ZSTD_LIBS: Link against HOST (arm64) zstd library for compression support
# Use clang as assembler on macOS (integrated ARM64 assembler)
run_logged "stage3_crosscompiledopt" make crosscompiledopt \
  ARCH="${_TARGET_ARCH}" \
  CAMLOPT="${_CROSS_OCAMLOPT}" \
  AS="${_CC}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  CROSS_CC="${_CC}" \
  CROSS_AR="${_AR}" \
  CROSS_MKLIB="${_CROSS_MKLIB}" \
  LDFLAGS="${_LDFLAGS}" \
  SAK_LDFLAGS="-fuse-ld=lld" \
  ZSTD_LIBS="-L${PREFIX}/lib -lzstd" \
  -j${CPU_COUNT}

# Debug: Verify built binary architectures after crosscompiledopt
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  STAGE 3 DEBUG: Built binary architectures                      ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  ocamlopt.opt: $(file ocamlopt.opt 2>/dev/null | cut -d: -f2 || echo 'NOT FOUND')"
echo "║  ocamlc.opt:   $(file ocamlc.opt 2>/dev/null | cut -d: -f2 || echo 'NOT FOUND')"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Runtime library (libasmrun.a) objects:                         ║"
if [[ -f runtime/libasmrun.a ]]; then
  rm -rf /tmp/ocaml_debug && mkdir -p /tmp/ocaml_debug
  cd /tmp/ocaml_debug && ar -x "${SRC_DIR}/runtime/libasmrun.a" 2>/dev/null
  for f in *.o; do
    [[ -f "$f" ]] && echo "║    $f: $(file "$f" | cut -d: -f2)" | head -c 70
    echo ""
  done | head -5
  cd "${SRC_DIR}"
else
  echo "║    libasmrun.a NOT FOUND"
fi
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Fix build_config.h paths for target
# CRITICAL: Use double quotes so ${SRC_DIR} and ${PREFIX} are shell-expanded
# The file contains the actual path (e.g., /Users/conda/.../work/_native/lib/ocaml)
# not the literal string "$SRC_DIR/_native/lib/ocaml"
echo "Fixing build_config.h: ${SRC_DIR}/_native/lib/ocaml -> ${PREFIX}/lib/ocaml"
perl -pe "s#${SRC_DIR}/_native/lib/ocaml#${PREFIX}/lib/ocaml#g" "${SRC_DIR}"/build_config.h > runtime/build_config.h
perl -i -pe "s#${_build_alias}#${_host_alias}#g" runtime/build_config.h

echo "=== build_config.h for target ==="
cat runtime/build_config.h
echo "================================="

# Build runtime with ARM64 cross-toolchain
# ZSTD_LIBS for finding arm64 zstd library
# SAK_CC/SAK_CFLAGS for build-time tools that run on build machine
run_logged "stage3_crosscompiledruntime" make crosscompiledruntime \
  ARCH="${_TARGET_ARCH}" \
  CAMLOPT="${_CROSS_OCAMLOPT}" \
  AS="${_CC}" \
  ASPP="${_CC} -c" \
  CC="${_CC}" \
  CROSS_CC="${_CC}" \
  CROSS_AR="${_AR}" \
  CROSS_MKLIB="${_CROSS_MKLIB}" \
  LDFLAGS="${_LDFLAGS}" \
  CHECKSTACK_CC="${CC_FOR_BUILD}" \
  SAK_CC="${CC_FOR_BUILD}" \
  SAK_CFLAGS="${_SAK_CFLAGS}" \
  SAK_LDFLAGS="-fuse-ld=lld" \
  ZSTD_LIBS="-L${PREFIX}/lib -lzstd" \
  -j${CPU_COUNT}

run_logged "stage3_installcross" make installcross

# Fix overlinking in stublibs - change ./dll*.so to @loader_path/dll*.so
echo ""
echo "=== Fixing stublib overlinking ==="
for lib in "${OCAML_PREFIX}/lib/ocaml/stublibs/"*.so; do
  [[ -f "$lib" ]] || continue
  echo "Checking: $lib"
  for dep in $(otool -L "$lib" 2>/dev/null | grep '\./dll' | awk '{print $1}'); do
    echo "  Fixing: $dep -> @loader_path/$(basename $dep)"
    install_name_tool -change "$dep" "@loader_path/$(basename $dep)" "$lib"
  done
done

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
  # Use 256 bytes to capture long conda build paths like:
  # /home/conda/feedstock_root/build_artifacts/bld/rattler-build_ocaml_.../work/_cross/bin/ocamlrun
  if head -c 256 "$bin" 2>/dev/null | grep -q 'ocamlrun'; then
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

echo "=== Fixing install names for shared libraries ==="
if [[ -f "${OCAML_PREFIX}/lib/ocaml/libasmrun_shared.so" ]]; then
  install_name_tool -id "@rpath/libasmrun_shared.so" "${OCAML_PREFIX}/lib/ocaml/libasmrun_shared.so"
fi
if [[ -f "${OCAML_PREFIX}/lib/ocaml/libcamlrun_shared.so" ]]; then
  install_name_tool -id "@rpath/libcamlrun_shared.so" "${OCAML_PREFIX}/lib/ocaml/libcamlrun_shared.so"
fi

# Also fix any references to these libraries in other binaries
for lib in "${OCAML_PREFIX}/lib/ocaml/"*.so "${OCAML_PREFIX}/lib/ocaml/stublibs/"*.so; do
  if [[ -f "$lib" ]]; then
    # Fix references to build-time paths
    install_name_tool -change "runtime/libasmrun_shared.so" "@rpath/libasmrun_shared.so" "$lib" 2>/dev/null || true
    install_name_tool -change "runtime/libcamlrun_shared.so" "@rpath/libcamlrun_shared.so" "$lib" 2>/dev/null || true
  fi
done

echo ""
echo "=== Cross-compilation complete for ${_host_alias} ==="
