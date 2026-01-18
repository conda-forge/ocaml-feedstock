# OCaml Cross-Compiler Build History

## Stdlib__Sys Consistency Error (2026-01-14)

### Problem
Cross-compiler builds for OCaml 5.3.0 consistently failed with:
```
Error: Files "unix.cmxa" and "stdlib.cmxa"
       make inconsistent assumptions over implementation "Stdlib__Sys"
```

### Root Cause
The `crossopt` target in Makefile.cross was building `runtime-all` from scratch at the start of the build. This caused .cmi (Compiled Module Interface) files to be regenerated multiple times with different CRC checksums:

1. `runtime-all` built stdlib with initial .cmi files
2. `stdlib allopt` rebuilt stdlib native code, regenerating .cmi files (new checksums)
3. `otherlibrariesopt` built unix.cmxa referencing the NEW stdlib .cmi checksums
4. But stdlib.cmxa still contained references to OLD checksums → inconsistent assumptions

### Why Native Builds Worked
Native builds didn't trigger this issue because the build sequence was different - no intermediate .cmi regeneration between stdlib and otherlibs.

### Solution (Ported from OCaml 5.4.0)
Add a pre-build step that stabilizes the bytecode runtime before `crossopt`:

1. **Pre-build runtime-all** with NATIVE tools (ARCH=amd64) → creates stable bytecode runtime
2. **Clean ONLY native runtime** files (libasmrun*.a, amd64.o, *.nd.o) → leaves bytecode intact
3. **crossopt rebuilds** just the native runtime for TARGET arch → bytecode parts unchanged

This ensures .cmi files are built ONCE and remain stable throughout the build.

### Files Modified
- `recipe/building/build-cross-compiler.sh`: Added pre-build step (lines 210-258)
- `recipe/build.sh`: Fixed undefined `OCAML_TARGET_INSTALL_PREFIX` variable (line 174)

### Commits
- `e95449c`: Apply 5.4.0 pre-build strategy to fix Stdlib__Sys consistency
- `70dea42`: Define OCAML_TARGET_INSTALL_PREFIX before use in cross-compilation path

### Debugging Attempts (20+)
Prior to discovering the 5.4.0 solution, multiple approaches were attempted:
- Atomic builds (single make invocation for stdlib + otherlibs)
- OPTCOMPILER= COMPILER_DEPS= flag combinations
- Cleaning strategies (.cmi only, .cmxa only, both)
- Flag symmetry between stdlib and otherlibs
- Touching files to prevent timestamp rebuilds
- Using `make -t` to mark targets as built
- Complete rebuilds from scratch

All failed because the fundamental issue was .cmi regeneration during `runtime-all`.

### References
- OCaml 5.4.0 branch: `mnt/v5.4.0_0`
- OCaml 5.4.0 build-cross-compiler.sh: lines 252-288 (pre-build strategy)
