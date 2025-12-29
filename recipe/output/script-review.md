# OCaml Feedstock Build Scripts Review

## Executive Summary

Reviewed 3 main build scripts totaling ~1,072 lines of code for:
1. **Duplication** - Shared code across multiple scripts
2. **Debug/Temporary Code** - Diagnostic output and commented sections
3. **Convoluted Constructs** - Overly complex logic

---

## 1. Code Duplication

### 1.1 Shared Helper Functions (HIGH Priority)

**Location**: Beginning of both cross-compile scripts

```bash
# DUPLICATED in:
# - recipe/building/cross-compile.sh (lines 1-23)
# - recipe/archives/cross-compile.sh (lines 1-23)

run_logged() { ... }              # Identical - 15 lines
_ensure_full_path() { ... }       # Identical - 3 lines
apply_cross_patches() { ... }     # Nearly identical - 8 lines (minor diff in line 32-33)
```

**Recommendation**: Extract to `recipe/building/common-functions.sh`

```bash
# Proposed: recipe/building/common-functions.sh
run_logged() { ... }
_ensure_full_path() { ... }
apply_cross_patches() { ... }
```

**Impact**: Reduces duplication by ~26 lines per script (52 lines total)

---

### 1.2 Platform Configuration Block (MEDIUM Priority)

**Location**: Platform detection and variable setup

```bash
# DUPLICATED in:
# - recipe/building/cross-compile.sh (lines 43-75)
# - recipe/archives/cross-compile.sh (lines 49-81)

case "${target_platform}" in
  osx-arm64) ... ;;
  linux-aarch64) ... ;;
  linux-ppc64le) ... ;;
esac

_GETENTROPY_ARGS=()
CONFIG_ARGS=(--enable-shared --disable-static)
```

**Difference**: archives script has CC_FOR_BUILD fallback detection (lines 40-47)

**Recommendation**: Extract platform config to sourced file OR keep duplicated (it's small and clear)

**Impact**: Would save ~35 lines but may reduce readability

---

### 1.3 Toolchain Detection (MEDIUM Priority)

**Location**: Cross-compiler path resolution

```bash
# DUPLICATED in:
# - recipe/building/cross-compile.sh (lines 87-106)
# - recipe/archives/cross-compile.sh (lines 91-128)

_CC="${CC}"
if [[ ! -x "${_CC}" ]] && [[ "${_CC}" == *"-cc" ]]; then
  _CC_FALLBACK="${_CC%-cc}-clang"
  ...
fi

# BUILD platform toolchain setup
if [[ "${_PLATFORM_TYPE}" == "macos" ]]; then
  _BUILD_AR="${BUILD_PREFIX}/bin/llvm-ar"
  ...
fi
```

**Recommendation**: Extract to function in common-functions.sh

```bash
setup_cross_toolchain() {
  # Returns _CC, _AR, _AS, _BUILD_*, etc.
}
```

**Impact**: Would save ~40 lines per script (80 lines total)

---

### 1.4 Config.generated.ml Patching (HIGH Priority)

**Location**: Patching OCaml config after configure

```bash
# DUPLICATED (with minor variations) in:
# - recipe/building/cross-compile.sh (lines 179-204)
# - recipe/archives/cross-compile.sh (lines 208-276, 298-326)

sed -i 's/^let asm = .*/let asm = {|\$AS|}/' "$config_file"
sed -i 's/^let c_compiler = .*/let c_compiler = {|\$CC|}/' "$config_file"
sed -i 's/^let mkdll = .*/let mkdll = {|\$CC -shared ...|}/' "$config_file"
...
```

**Complexity**: 10-15 sed commands per invocation, appears 3 times across scripts

**Recommendation**: Extract to `recipe/building/patch-config-generated.sh`

```bash
# Usage: patch_config_generated <config_file> <platform_type> <model>
patch_config_generated() {
  local config_file="$1"
  local platform_type="$2"
  local model="${3:-}"

  sed -i 's/^let asm = .*/let asm = {|\$AS|}/' "$config_file"
  # ... all other patches
}
```

**Impact**: Reduces duplication by ~40 lines, improves maintainability

---

### 1.5 Post-Install Fixes (MEDIUM Priority)

**Location**: Final fixups after installation

```bash
# DUPLICATED in:
# - recipe/building/cross-compile.sh (lines 274-317)
# - recipe/archives/cross-compile.sh (lines 384-427)

# macOS stublib overlinking fix
for lib in "${OCAML_PREFIX}/lib/ocaml/stublibs/"*.so; do
  install_name_tool -change ...
done

# Bytecode wrapper shebang fix
for bin in "${OCAML_PREFIX}"/bin/*; do
  fix_ocamlrun_shebang ...
done
```

**Recommendation**: Already sourcing `fix-ocamlrun-shebang.sh` - good pattern
Could extract macOS fixes to `recipe/building/fix-macos-install.sh`

**Impact**: Would save ~43 lines per script

---

## 2. Debug/Temporary Code

### 2.1 Debug Output (LOW Priority - Keep for now)

**Location**: recipe/building/cross-compile.sh:155-156

```bash
echo "DEBUG: OCAMLLIB=${OCAMLLIB}"
ls -la "${OCAMLLIB}/"*.cmo 2>/dev/null | head -5 || echo "WARNING: No .cmo files in OCAMLLIB"
```

**Status**: KEEP - This is validating a critical fix (cross-compiler stdlib path)

**Recommendation**: Consider making it conditional on `OCAML_DEBUG` env var once stable

---

### 2.2 Verbose SDK Detection (LOW Priority)

**Location**: recipe/building/build-cross-compiler.sh:63-68

```bash
echo "     WARNING: No ARM64 SDK found in any of the searched locations"
echo "     Searched: ${_SYSROOT_SEARCH[*]}"
ls -la "${BUILD_PREFIX}/${target}/" 2>/dev/null || ...
ls -la /opt/*.sdk 2>/dev/null || ...
```

**Status**: KEEP - Helps debug CI failures on macOS

**Recommendation**: Once cross-compilation is stable, move to `if [[ -n "${OCAML_DEBUG}" ]]` block

---

### 2.3 File Listing for Validation (LOW Priority)

**Location**: recipe/building/build-cross-compiler.sh:228, 237, 245, 253

```bash
ls -la stdlib/*.{cma,cmxa,a,cmi,cmo,cmx,o} 2>&1 | head -20
ls -la stdlib/ | grep -E "runtime|launch|info" || echo "     (none found)"
ls -la compilerlibs/*.{cma,cmxa,a} 2>&1 | head -20
ls -la runtime/*.{a,o} 2>&1 | head -20
```

**Status**: KEEP - Validates critical cross-compiler package contents

**Recommendation**: Make conditional on `OCAML_VERBOSE` once packaging is stable

---

### 2.4 Commented-Out Code (HIGH Priority - Clean up)

**Location**: Both cross-compile scripts

```bash
# recipe/building/cross-compile.sh:235
#sed "s#${BUILD_PREFIX}/lib/ocaml#${PREFIX}/lib/ocaml#g" "${SRC_DIR}"/build_config.h > runtime/build_config.h

# recipe/archives/cross-compile.sh:355
#sed "s#${BUILD_PREFIX}/lib/ocaml#${PREFIX}/lib/ocaml#g" "${SRC_DIR}"/build_config.h > runtime/build_config.h
```

**Status**: DELETE - Old approach, replaced by `sed -i` on runtime/build_config.h directly (line 236)

**Recommendation**: Remove commented line in both scripts

---

## 3. Convoluted Constructs

### 3.1 Makefile.cross Dynlink Fix (MEDIUM Complexity)

**Location**: recipe/building/cross-compile.sh:30-33

```bash
apply_cross_patches() {
  # ...
  # Fix dynlink "inconsistent assumptions" error:
  # Use otherlibrariesopt-cross target which calls dynlink-allopt with proper CAMLOPT/BEST_OCAMLOPT
  sed -i 's/otherlibrariesopt ocamltoolsopt/otherlibrariesopt-cross ocamltoolsopt/g' Makefile.cross
  sed -i 's/\$(MAKE) otherlibrariesopt /\$(MAKE) otherlibrariesopt-cross /g' Makefile.cross
}
```

**Issue**: Missing from archives script - will cause "inconsistent assumptions" errors

**Recommendation**: **ADD to archives/cross-compile.sh apply_cross_patches()** (this is a BUG!)

---

### 3.2 Multiple sed Patterns on Same File (MEDIUM Complexity)

**Location**: Config.generated.ml patching

```bash
# 10-15 separate sed -i calls on same file
sed -i 's/^let asm = .*/...' "$config_file"
sed -i 's/^let c_compiler = .*/...' "$config_file"
sed -i 's/^let mkdll = .*/...' "$config_file"
# ... 10 more
```

**Issue**: Each `sed -i` reads and rewrites the file - inefficient

**Recommendation**: Use multi-expression sed OR use a HERE document with perl

```bash
# Option 1: Multi-expression sed
sed -i \
  -e 's/^let asm = .*/let asm = {|\$AS|}/' \
  -e 's/^let c_compiler = .*/let c_compiler = {|\$CC|}/' \
  -e 's/^let mkdll = .*/let mkdll = {|\$CC -shared|}/' \
  "$config_file"

# Option 2: Perl (already using perl elsewhere)
perl -i -pe '
  s/^let asm = .*/let asm = {|\$ENV{AS}|}/;
  s/^let c_compiler = .*/let c_compiler = {|\$ENV{CC}|}/;
  s/^let mkdll = .*/let mkdll = {|\$ENV{CC} -shared|}/;
' "$config_file"
```

**Impact**: Slight performance improvement, cleaner code

---

### 3.3 Conditional _MODEL Patching (LOW Complexity)

**Location**: recipe/building/cross-compile.sh:202-204

```bash
if [[ -n "${_MODEL:-}" ]]; then
  sed -i "s/^let model = .*/let model = {|${_MODEL}|}/" "$config_file"
fi
```

**Issue**: _MODEL only set for ppc64le - could be clearer

**Recommendation**: Document or consolidate with main sed block

```bash
# Consolidate with platform-specific sed block
if [[ "${_PLATFORM_TYPE}" == "linux" ]]; then
  sed -i '...' "$config_file"
  [[ "${target_platform}" == "linux-ppc64le" ]] && \
    sed -i "s/^let model = .*/let model = {|ppc64le|}/" "$config_file"
fi
```

---

### 3.4 Stripdebug Replacement Logic (MEDIUM Complexity)

**Location**: recipe/building/cross-compile.sh:261-267

```bash
echo "Replacing stripdebug with no-op version for cross-compilation..."
rm -f tools/stripdebug tools/stripdebug.ml tools/stripdebug.mli tools/stripdebug.cmi tools/stripdebug.cmo
cp "${RECIPE_DIR}/building/stripdebug-noop.ml" tools/stripdebug.ml
ocamlc -o tools/stripdebug tools/stripdebug.ml
rm -f tools/stripdebug.ml tools/stripdebug.cmi tools/stripdebug.cmo
```

**Issue**: ONLY applied in building/cross-compile.sh - archives script will FAIL at installcross

**Recommendation**: **ADD to archives/cross-compile.sh before line 380 (installcross)** (this is a BUG!)

---

## 4. Bugs Found During Review

### 4.1 🐛 Missing Dynlink Fix in archives/cross-compile.sh

**Severity**: HIGH

**Location**: recipe/archives/cross-compile.sh:25-32 (apply_cross_patches)

**Issue**: Missing the sed commands that replace `otherlibrariesopt` → `otherlibrariesopt-cross`

**Fix**:
```bash
apply_cross_patches() {
  cp "${RECIPE_DIR}"/building/Makefile.cross .
  patch -N -p0 < "${RECIPE_DIR}"/building/tmp_Makefile.patch || true

  # ADD THESE LINES:
  sed -i 's/otherlibrariesopt ocamltoolsopt/otherlibrariesopt-cross ocamltoolsopt/g' Makefile.cross
  sed -i 's/\$(MAKE) otherlibrariesopt /\$(MAKE) otherlibrariesopt-cross /g' Makefile.cross

  if [[ "${_NEEDS_DL}" == "1" ]]; then
    perl -i -pe 's/^(BYTECCLIBS=.*)$/$1 -ldl/' Makefile.config
  fi
}
```

---

### 4.2 🐛 Missing Stripdebug Workaround in archives/cross-compile.sh

**Severity**: HIGH

**Location**: recipe/archives/cross-compile.sh - missing before line 380 (stage3_installcross)

**Issue**: Will fail at `make installcross` trying to execute target binaries

**Fix**: Add before line 380:
```bash
# Replace stripdebug with a no-op for cross-compilation
echo "Replacing stripdebug with no-op version for cross-compilation..."
rm -f tools/stripdebug tools/stripdebug.ml tools/stripdebug.mli tools/stripdebug.cmi tools/stripdebug.cmo
cp "${RECIPE_DIR}/building/stripdebug-noop.ml" tools/stripdebug.ml
ocamlc -o tools/stripdebug tools/stripdebug.ml
rm -f tools/stripdebug.ml tools/stripdebug.cmi tools/stripdebug.cmo

run_logged "stage3_installcross" make installcross
```

---

## 5. Refactoring Recommendations

### Priority Matrix

| Priority | Item | Lines Saved | Risk | Effort |
|----------|------|-------------|------|--------|
| **1. HIGH** | Fix bugs in archives script | 0 | LOW | 5 min |
| **2. HIGH** | Extract common functions | ~52 | LOW | 15 min |
| **3. HIGH** | Extract config.generated.ml patching | ~40 | MEDIUM | 20 min |
| **4. HIGH** | Remove commented code | ~2 | LOW | 2 min |
| **5. MEDIUM** | Extract toolchain setup | ~80 | MEDIUM | 30 min |
| **6. MEDIUM** | Extract post-install fixes | ~43 | MEDIUM | 20 min |
| **7. LOW** | Consolidate sed commands | ~0 | LOW | 10 min |
| **8. LOW** | Add debug conditionals | ~0 | LOW | 15 min |

**Total Potential Savings**: ~217 lines of duplicated code

---

## 6. Proposed File Structure

```
recipe/building/
├── common-functions.sh          # NEW: run_logged, _ensure_full_path, apply_cross_patches
├── setup-cross-toolchain.sh     # NEW: _CC, _AR, _BUILD_* setup
├── patch-config-generated.sh    # NEW: config.generated.ml patching
├── fix-ocamlrun-shebang.sh      # EXISTS: shebang fixes
├── fix-macos-install.sh         # NEW: macOS post-install fixes
├── stripdebug-noop.ml           # EXISTS: no-op stripdebug
├── cross-ocamlmklib.sh          # EXISTS: mklib wrapper
├── build-cross-compiler.sh      # EXISTS: builds cross-compilers in native
├── cross-compile.sh             # EXISTS: Stage 3 only (optimized)
└── Makefile.cross               # EXISTS: shared makefile

recipe/archives/
└── cross-compile.sh             # EXISTS: Full 3-stage bootstrap
```

---

## 7. Immediate Actions (Before Merge)

1. ✅ **Fix archives/cross-compile.sh dynlink sed** (CRITICAL - will break build)
2. ✅ **Fix archives/cross-compile.sh stripdebug** (CRITICAL - will break installcross)
3. ✅ **Remove commented sed lines** (both scripts, line 235/355)

---

## 8. Post-Merge Refactoring (Optional)

1. Extract common-functions.sh
2. Extract patch-config-generated.sh
3. Extract setup-cross-toolchain.sh
4. Add debug conditionals (OCAML_DEBUG, OCAML_VERBOSE env vars)
5. Consolidate multiple sed calls into single perl/sed invocation

---

## Summary

**Current State**:
- 1,072 lines across 3 scripts
- ~217 lines of duplication (20%)
- 2 critical bugs in archives/cross-compile.sh
- 2 lines of dead commented code

**After Critical Fixes**:
- 2 bugs fixed
- 2 lines removed
- Ready for merge

**After Full Refactoring** (optional):
- ~855 lines (20% reduction)
- 5 shared modules for maintainability
- Consistent debug output handling
