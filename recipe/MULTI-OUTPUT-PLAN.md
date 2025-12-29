# Multi-Output Cross-Compiler Plan for OCaml 5.4.0

## Overview

This plan converts the OCaml feedstock to use conda-forge's multi-output pattern, enabling:
1. **Parallel builds** of cross-compilers on native platforms
2. **Cross builds always use optimized Stage 3** path (no 3-stage bootstrap)
3. **Smaller packages** - cross-compilers are separate (~100MB each vs 300MB combined)
4. **Better caching** - conda caches each output independently

## Build Flow

### Native Platforms (linux-64, osx-64)
Build **4 outputs** in this order:
1. `ocaml-cross-compiler_linux-aarch64` (linux-64 only)
2. `ocaml-cross-compiler_linux-ppc64le` (linux-64 only)
3. `ocaml-cross-compiler_osx-arm64` (osx-64 only)
4. `ocaml` (main package)

### Cross Platforms (linux-aarch64, linux-ppc64le, osx-arm64)
Build **1 output**:
1. `ocaml` - depends on corresponding cross-compiler output from same recipe

**Dependency Resolution:**
- Cross builds have `pin_subpackage("ocaml-cross-compiler_*", exact=True)` in build requirements
- conda-build resolves this to the cross-compiler output from **the same recipe**
- Waits for native platform to finish building the cross-compiler output
- Then uses it to build the cross platform's `ocaml` output

## Files Created

1. `/tmp/claude/recipe-multi-output.yaml` - New recipe with outputs structure
2. `/tmp/claude/build-cross-compiler-aarch64.sh` - Wrapper for aarch64 cross-compiler
3. `/tmp/claude/build-cross-compiler-ppc64le.sh` - Wrapper for ppc64le cross-compiler
4. `/tmp/claude/build-cross-compiler-osx-arm64.sh` - Wrapper for arm64 cross-compiler

## Changes Required to Existing Scripts

### `building/build-cross-compiler.sh`
Currently builds ALL cross-compilers. Needs to be modified to build ONLY the target specified by:
- `$CROSS_TARGET_PLATFORM` (e.g., "linux-aarch64")
- `$CROSS_HOST_ALIAS` (e.g., "aarch64-conda-linux-gnu")

**Before:**
```bash
# Builds aarch64, ppc64le, and arm64 cross-compilers
for target in aarch64-conda-linux-gnu powerpc64le-conda-linux-gnu arm64-apple-darwin20.0.0; do
  build_cross_compiler "$target"
done
```

**After:**
```bash
# Build only the specified cross-compiler
if [[ -n "${CROSS_HOST_ALIAS:-}" ]]; then
  build_cross_compiler "${CROSS_HOST_ALIAS}"
else
  # Fallback: build all (for backward compatibility)
  ...
fi
```

### `building/cross-compile.sh`
Change the cross-compiler check from:
```bash
if [[ ! -d "${BUILD_PREFIX}/lib/ocaml-cross-compilers" ]]; then
```

To:
```bash
if [[ ! -d "${BUILD_PREFIX}/lib/ocaml-cross-compilers/${host_alias}" ]]; then
```

Because cross-compilers are now in separate packages, not a monolithic directory.

### `build.sh`
The fallback logic we added can be simplified since cross builds ALWAYS have the cross-compiler available (via pin_subpackage).

## Benefits vs 3-Stage Bootstrap

### First Build of 5.4.0
**Before (single output):**
- All platforms build in parallel
- Cross platforms use `archives/cross-compile.sh` (3-stage, ~40 min)
- Total time: ~40 min for slowest platform

**After (multi-output):**
- Native platforms build cross-compiler outputs first (~15 min)
- Cross platforms wait for cross-compilers, then build (~10 min with Stage 3 only)
- Total time: ~25 min (15+10, sequential but faster overall)

### Subsequent Builds (5.4.1, 5.5.0, etc.)
**Before:**
- Cross platforms use existing 5.4.0 ocaml package for cross-compilers
- Might fail if source code changed too much between versions

**After:**
- Cross platforms use cross-compilers from **the same recipe version**
- Always guaranteed to work (matching version)
- Still uses fast Stage 3 path

## Testing Strategy

1. **Test on your fork first** with multi-output recipe
2. **Verify build order**: Native platforms build cross-compiler outputs before main ocaml
3. **Verify cross builds**: Wait for cross-compilers, use Stage 3 only
4. **Verify package sizes**: Cross-compiler packages ~100MB each, not 300MB combined
5. **Verify installation**: `conda install ocaml` on aarch64 pulls in correct cross-compiler automatically

## Migration Path

1. Create PR with multi-output recipe
2. Test thoroughly on fork
3. Once working, merge to conda-forge
4. `archives/cross-compile.sh` becomes legacy (kept for emergencies only)

## Questions to Resolve

1. **Cross-compiler host_alias values** - need to verify exact values used by conda-forge:
   - Linux aarch64: `aarch64-conda-linux-gnu` ✓
   - Linux ppc64le: `powerpc64le-conda-linux-gnu` ✓
   - macOS arm64: `arm64-apple-darwin20.0.0` (verify SDK version)

2. **Skip conditions** - verify syntax for `skip: ${{ not (linux64 or osx64) }}`

3. **Pin_subpackage behavior** - confirm it waits for outputs from same recipe

## Next Steps

1. Copy files from /tmp/claude/ to recipe directory
2. Modify `building/build-cross-compiler.sh` to accept CROSS_TARGET_PLATFORM
3. Test locally with conda-build
4. Push to feat/multi-output-cross-compilers branch
5. Monitor CI builds
