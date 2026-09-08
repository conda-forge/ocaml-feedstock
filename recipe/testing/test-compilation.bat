@echo off
@REM W4AA Strategy B: extend FLEXLINKFLAGS with -L paths for ocaml-x86_64-imports
@REM ensures flexlink invoked via ocamlopt's MKEXE can resolve _tls_index, pthread_*
echo [W4AA-B-APPLIED] test-compilation.bat injecting -L paths into FLEXLINKFLAGS
set "FLEXLINKFLAGS=%FLEXLINKFLAGS% -L%PREFIX%/Library/lib/ocaml-x86_64-imports -L%PREFIX%/Library/lib -L%PREFIX%/Library/mingw-w64/x86_64-w64-mingw32/lib"
echo [W4AA-B] FLEXLINKFLAGS=%FLEXLINKFLAGS%
REM W5K-revert: W3TT-B1 was injecting -stack 8388608 which overrode MKEXE's 32MB.
REM MKEXE now ships 32MB by default (W5G + earlier reverts); test no longer needs override.
REM set FLEXLINKFLAGS=-stack 8388608 %FLEXLINKFLAGS%
REM Test OCaml compilation capabilities on non-unix
REM Exercises bytecode and native compilation

setlocal enabledelayedexpansion

set VERSION=%1
if "%VERSION%"=="" (
    echo Usage: %0 ^<version^>
    exit /b 1
)

echo === OCaml Compilation Tests (non-unix) ===

REM Create test file
echo print_endline "Hello World"> hi.ml

REM 1. Bytecode compilation + execution
echo === Testing bytecode compilation ===
echo   compiling...
ocamlc -o hi.exe hi.ml
if errorlevel 1 (
    echo   bytecode compile: FAILED
    exit /b 1
)
:: W4EE-A: preserve bytecode hi.exe before native overwrite (for comparison run)
if exist hi.exe copy /Y hi.exe hi_byte.exe >nul
echo   bytecode compile: OK

echo   executing via ocamlrun...
REM Windows bytecode executables need ocamlrun (no shebang support)
ocamlrun hi.exe | findstr /C:"Hello World" >nul
if errorlevel 1 (
    echo   bytecode execution: FAILED
    exit /b 1
)
echo   bytecode execution: OK
del hi.exe

REM 2. Native compilation + execution
echo === Testing native compilation ===
echo   compiling...
REM W3EE: echo FLEXLINKFLAGS and append -v so flexlink emits verbose search output.
REM If verbose output appears: flexlink honors FLEXLINKFLAGS env (env is sufficient).
REM If no verbose output: flexlink ignores FLEXLINKFLAGS env (command-line -L is what matters).
echo [W3EE] FLEXLINKFLAGS=%FLEXLINKFLAGS%
set FLEXLINKFLAGS=%FLEXLINKFLAGS% -v
REM W3DD: pass -verbose so flexlink logs library resolution attempts in the CI output
REM W5J-DIAG-2: flexlink version and defaults probe (before hi.exe link)
echo [W5J-DIAG-2] flexlink version:
flexlink --help 2>&1 | findstr /n "" | findstr "^1:"
echo [W5J-DIAG-2] flexlink -help stack/reserve entries:
flexlink -help 2>&1 | findstr /i "stack reserve" || echo [W5J-DIAG-2] no stack/reserve in flexlink -help
echo [W5J-DIAG-2] FLEXLINKFLAGS=%FLEXLINKFLAGS%
echo [W5J-DIAG-2] OCAML_FLEXLINK=%OCAML_FLEXLINK%
echo [W5J-DIAG-2] OCAMLC=%OCAMLC%
echo [W5J-DIAG-2] which flexlink:
where flexlink 2>&1
echo [W5J-DIAG-2] MKEXE from Makefile.config:
findstr /B "MKEXE" "%PREFIX%\Library\lib\ocaml\Makefile.config" 2>nul || echo [W5J-DIAG-2] Makefile.config not found or no MKEXE
echo [W5J-DIAG-2] libasmrun.lib .drectve strings probe:
python -c "import subprocess,os; lib=os.path.join(os.environ.get('PREFIX',''),'Library','lib','ocaml','libasmrun.lib'); d=open(lib,'rb').read() if os.path.exists(lib) else b''; idx=d.find(b'.drectve'); print('[W5J-DIAG-2] .drectve section found at offset',idx) if idx>=0 else print('[W5J-DIAG-2] no .drectve in libasmrun.lib'); snippet=d[idx:idx+256] if idx>=0 else b''; print('[W5J-DIAG-2] drectve bytes:', snippet[:128])" 2>&1 || echo [W5J-DIAG-2] python drectve probe failed
echo [W5J-DIAG-2] --- beginning ocamlopt verbose link for hi.exe (set echo on) ---
echo on
REM W5L-revert: removed 8MB stack override; MKEXE 32MB default is correct.
REM W4BB-B: -cclib args land AFTER Config.mkexe's baked "-stack 33554432" in the flexlink argv; flexlink last-wins, so this forces 8MB even if the baked value survives. FLEXLINKFLAGS env (W3TT-B1) is parsed BEFORE argv so it cannot override mkexe.
REM rem W5L-revert: ocamlopt -cclib "-stack 8388608" was overriding MKEXE's 32MB; use 32MB default.
rem W5M-A: 256MB brute-force test - if hi.exe STILL crashes STATUS_STACK_OVERFLOW, it's infinite recursion in CRT init, not just large frame
rem W5M-D removed: -Wl,-Map,hi.map rejected by zig cc (flexlink strips -Wl, prefix). For COFF lld-link, correct syntax is -cclib "-Xlinker /MAP:hi.map" -- not retried this round.
ocamlopt -verbose -ccopt "-L%PREFIX%/Library/lib/ocaml-x86_64-imports" -cclib "-stack 268435456" -o hi.exe hi.ml
@echo off
echo [W5J-DIAG-2] --- end ocamlopt verbose link ---
if errorlevel 1 (
    echo   native compile: FAILED
    exit /b 1
)
echo   native compile: OK

REM W4BB-C: dump PE optional-header stack reserve/commit so the effective values are known, not guessed
where python >nul 2>nul
if not errorlevel 1 (
    python -c "import struct; d=open('hi.exe','rb').read(); o=struct.unpack_from('<I',d,0x3c)[0]; r=struct.unpack_from('<Q',d,o+24+72)[0]; c=struct.unpack_from('<Q',d,o+24+80)[0]; print('[W4BB-C] hi.exe SizeOfStackReserve='+str(r)+' SizeOfStackCommit='+str(c))"
) else (
    echo [W4BB-C] python unavailable, skipping PE header dump
)

:: ============================================================
:: W4EE: dynamic trace/debug pre-run diagnostics
:: ============================================================
echo [W4EE-B] hi.exe (native) headers via dumpbin:
where dumpbin >nul 2>&1 && (dumpbin /headers hi.exe 2>nul | findstr /R /C:"entry point" /C:"subsystem" /C:"SizeOfStackReserve" /C:"SizeOfStackCommit" /C:"ImageBase" /C:"machine") || echo [W4EE-B] dumpbin NOT in PATH
echo [W4EE-C] hi.exe (native) imports:
where dumpbin >nul 2>&1 && (dumpbin /imports hi.exe 2>nul | findstr /R /C:"DLL name" /C:"WinMain" /C:"wWinMain" /C:"wmain" /C:"caml_main" /C:"main" /C:"atexit" /C:"_fpreset" /C:"_initterm" /C:"mainCRTStartup" /C:"_DllMainCRTStartup") || echo [W4EE-C] dumpbin NOT in PATH
echo [W4EE-D] hi_byte.exe (bytecode) headers for comparison:
if exist hi_byte.exe (where dumpbin >nul 2>&1 && (dumpbin /headers hi_byte.exe 2>nul | findstr /R /C:"entry point" /C:"subsystem" /C:"SizeOfStackReserve") || echo [W4EE-D] dumpbin NOT in PATH) else echo [W4EE-D] hi_byte.exe NOT preserved
echo [W4EE-E] Configure WerFault LocalDumps for hi.exe
set W4EE_DUMP_DIR=%TEMP%\hi_w4ee_dumps
if not exist "%W4EE_DUMP_DIR%" mkdir "%W4EE_DUMP_DIR%" 2>nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\hi.exe" /v DumpFolder /t REG_EXPAND_SZ /d "%W4EE_DUMP_DIR%" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\hi.exe" /v DumpCount /t REG_DWORD /d 5 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\hi.exe" /v DumpType /t REG_DWORD /d 2 /f >nul 2>&1
reg query "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\hi.exe" 2>nul && echo [W4EE-E] WER LocalDumps configured || echo [W4EE-E] WER reg add failed (likely non-admin)
echo [W4EE-F] Bytecode hi_byte.exe smoke test (compare to upcoming native crash):
if exist hi_byte.exe (
  hi_byte.exe
  echo [W4EE-F] hi_byte.exe exit code: %ERRORLEVEL%
) else echo [W4EE-F] hi_byte.exe NOT preserved - skipping
:: ============================================================
:: end W4EE pre-run block
:: ============================================================

REM W3II: Windows version info (once, before hi.exe diagnostics)
echo [W3II] Windows version:
ver
systeminfo 2>nul | findstr /C:"OS Name" /C:"OS Version" /C:"System Type"

REM W3II: REAL DLL imports existence check (via 'where') for hi.exe
echo [W3II] hi.exe REAL DLL imports existence check (via where):
for %%d in (kernel32.dll msvcrt.dll ucrt.dll ucrtbase.dll ws2_32.dll VERSION.dll api-ms-win-core-synch-l1-2-0.dll SHLWAPI.dll SHELL32.dll ole32.dll) do (
    where %%d >nul 2>&1 && echo   [W3II] FOUND: %%d || echo   [W3II] MISSING: %%d
)

REM W3HH: dump hi.exe actual PE import table via pefile
echo [W3HH] hi.exe PE import table (via pefile):
python -c "import pefile; pe=pefile.PE('hi.exe'); [print('  [W3HH] imports: '+e.dll.decode()) for e in pe.DIRECTORY_ENTRY_IMPORT]" 2>&1

REM W3II: dump hi.exe PE delay-import table via pefile
echo [W3II] hi.exe PE delay-import table (via pefile):
python -c "import pefile; pe=pefile.PE('hi.exe'); [print('  [W3II] delay-imports: '+e.dll.decode()) for e in getattr(pe,'DIRECTORY_ENTRY_DELAY_IMPORT',[])]" 2>&1

REM W3KK: per-symbol imports for CRT DLLs to identify missing entrypoint
echo [W3KK] hi.exe per-symbol imports for CRT DLLs (ucrt/ucrtbase/msvcrt):
python -c "import pefile; pe=pefile.PE('hi.exe'); [print('  [W3KK] '+e.dll.decode()+': '+(imp.name.decode() if imp.name else 'ord '+str(imp.ordinal))) for e in pe.DIRECTORY_ENTRY_IMPORT if e.dll.decode().lower() in ('ucrt.dll','ucrtbase.dll','msvcrt.dll') for imp in e.imports]" 2>&1

REM W3FF: prepend conda runtime DLL dir to PATH so loader finds installed DLLs
echo [W3FF] prepending %PREFIX%\Library\bin to PATH for runtime DLL resolution
set PATH=%PREFIX%\Library\bin;%PATH%

REM W4BB-C: enable OCaml runtime backtrace in case the crash is in OCaml code, not CRT init
set OCAMLRUNPARAM=b
REM W3NN: start without /B creates a new console; stdio redirections apply to start,
REM not to the child, so output never reaches the redirected file. Direct invocation
REM is synchronous for console children and captures %ERRORLEVEL% correctly.
echo [W3NN] running hi.exe directly (no 'start /WAIT' - new-console eats stdio redirects):
hi.exe > hi_stdout.txt 2> hi_stderr.txt
set HI_RAW_EXIT=%ERRORLEVEL%
:: ============================================================
:: W4EE: post-crash diagnostics
:: ============================================================
echo [W4EE-G] Crash dump search in %%W4EE_DUMP_DIR%%:
if defined W4EE_DUMP_DIR dir /b "%W4EE_DUMP_DIR%\hi.exe.*.dmp" 2>nul
echo [W4EE-G] Crash dumps in LocalAppData\CrashDumps:
if defined LOCALAPPDATA dir /b "%LOCALAPPDATA%\CrashDumps\hi*.dmp" 2>nul
echo [W4EE-H] Recent AppCrash events (Event ID 1000):
wevtutil qe Application /q:"*[System[(EventID=1000)]]" /c:3 /rd:true /f:text 2>nul || echo [W4EE-H] wevtutil unavailable
echo [W4EE-I] cdb.exe stack-walk on dumps (if cdb in PATH):
where cdb >nul 2>&1 && (
  if defined W4EE_DUMP_DIR for %%D in ("%W4EE_DUMP_DIR%\hi.exe.*.dmp") do (
    echo [W4EE-I] === Analyzing %%~nxD ===
    cdb -z "%%D" -lines -c "k;kn 50;!analyze -v;qq" 2>&1 | findstr /R /V /C:"^Loading" /C:"^Reading" /C:"^Microsoft" /C:"^Copyright"
  )
) || echo [W4EE-I] cdb.exe NOT in PATH
:: ============================================================
:: end W4EE post-crash block
:: ============================================================
:: W4II: fault-offset symbolization via python script (W4LL replacement)
echo [W4II] === end symbolization ===
:: end W4II
echo [W5M-B] Symbolizing hi.exe fault region around PE offset 0x4f0f5
where llvm-objdump >nul 2>nul && (
    echo [W5M-B] --- imports table ---
    llvm-objdump -p hi.exe 2>nul | findstr /C:"DLL Name" /C:"Hint/Name" /C:"Ordinal"
    echo [W5M-B] --- disassembly 0x14004e000 - 0x14004f200 ---
    llvm-objdump -d --start-address=0x14004e000 --stop-address=0x14004f200 hi.exe 2>nul | findstr /R /C:"^0x14004[ef][0-9a-f]" /C:"callq" /C:"<" /C:">"
) || echo [W5M-B] llvm-objdump unavailable
echo [W5M-B] --- check for known recursive-init candidates ---
where llvm-nm >nul 2>nul && llvm-nm hi.exe 2>nul | findstr /R /C:"pthread" /C:"_chkstk" /C:"_setjmp" /C:"_security_init_cookie" /C:"_RTC_" /C:"__main" /C:"_initterm" /C:"_acmdln" /C:"_get_initial_narrow" || echo [W5M-B] llvm-nm unavailable
echo [W5M-B] --- end symbolization ---
REM [W5M-C] Resolve llvm-nm with hardcoded fallback and dump full symbol table
set "LLVM_NM="
for /f "delims=" %%P in ('where llvm-nm 2^>nul') do set "LLVM_NM=%%P"
if not defined LLVM_NM (
    set "LLVM_NM=C:\Program Files\LLVM\bin\llvm-nm.EXE"
    echo [W5M-C] where llvm-nm returned nothing - falling back to hardcoded path
)
echo [W5M-C] LLVM_NM resolved to: %LLVM_NM%
if exist "%LLVM_NM%" (
    echo [W5M-C-NM-BEGIN]
    "%LLVM_NM%" -n hi.exe 2>&1
    echo [W5M-C-NM-END]
    echo [W5M-C-NM-RANGE-BEGIN]
    "%LLVM_NM%" -n hi.exe 2>&1 | findstr /R /C:"0000000014004e" /C:"0000000014004f"
    echo [W5M-C-NM-RANGE-END]
) else (
    echo [W5M-C] llvm-nm NOT found at %LLVM_NM% - symbol dump skipped
)
echo [W5M-D] linker map + import table probes
echo [W5M-D-MAP-BEGIN]
if exist hi.map (
    type hi.map
) else (
    echo [W5M-D] hi.map NOT FOUND - linker did not honor -Wl,-Map flag
)
echo [W5M-D-MAP-END]

echo [W5M-D-MAP-RANGE-BEGIN]
if exist hi.map (
    rem filter map for symbols whose RVA falls in 0x4ea00..0x4f300 window
    findstr /R /C:"0x000000000004e" /C:"0x000000000004f" hi.map
    findstr /R /C:" 0000000000004e" /C:" 0000000000004f" hi.map
)
echo [W5M-D-MAP-RANGE-END]

set "LLVM_OBJDUMP="
for /f "delims=" %%P in ('where llvm-objdump 2^>nul') do set "LLVM_OBJDUMP=%%P"
if not defined LLVM_OBJDUMP (
    set "LLVM_OBJDUMP=C:\Program Files\LLVM\bin\llvm-objdump.EXE"
    echo [W5M-D] where llvm-objdump returned nothing - falling back to hardcoded path
)
echo [W5M-D] LLVM_OBJDUMP resolved to: %LLVM_OBJDUMP%

echo [W5M-D-IMPORTS-BEGIN]
if exist "%LLVM_OBJDUMP%" (
    "%LLVM_OBJDUMP%" --private-headers hi.exe 2>&1
) else (
    echo [W5M-D] llvm-objdump unavailable
)
echo [W5M-D-IMPORTS-END]

echo [W5M-D-IMPORTS-DLL-BEGIN]
rem extract just DLL Name and Import lines for compact analysis
if exist "%LLVM_OBJDUMP%" (
    "%LLVM_OBJDUMP%" --private-headers hi.exe 2>&1 | findstr /R /C:"DLL Name" /C:" pthread" /C:" mcfgthread" /C:" msvcrt" /C:" ucrtbase" /C:" KERNEL32" /C:" _initterm" /C:" _security"
)
echo [W5M-D-IMPORTS-DLL-END]

echo [W5M-G] function-boundary probe via .pdata
echo [W5M-G-UNWIND-BEGIN]
if exist "%LLVM_OBJDUMP%" (
    "%LLVM_OBJDUMP%" --unwind-info hi.exe 2>&1
) else (
    echo [W5M-G] llvm-objdump unavailable
)
echo [W5M-G-UNWIND-END]

set "LLVM_READOBJ="
for /f "delims=" %%P in ('where llvm-readobj 2^>nul') do set "LLVM_READOBJ=%%P"
if not defined LLVM_READOBJ (
    set "LLVM_READOBJ=C:\Program Files\LLVM\bin\llvm-readobj.EXE"
    echo [W5M-G] where llvm-readobj returned nothing - falling back to hardcoded path
)
echo [W5M-G] LLVM_READOBJ resolved to: %LLVM_READOBJ%

echo [W5M-G-FUNCS-BEGIN]
if exist "%LLVM_READOBJ%" (
    "%LLVM_READOBJ%" --unwind hi.exe 2>&1
) else (
    echo [W5M-G] llvm-readobj unavailable
)
echo [W5M-G-FUNCS-END]

echo [W5M-G-DWARF-BEGIN]
if exist "%LLVM_OBJDUMP%" (
    "%LLVM_OBJDUMP%" --dwarf=info hi.exe 2>&1 | findstr /R /C:"DW_TAG_subprogram" /C:"DW_AT_name" /C:"DW_AT_low_pc" /C:"DW_AT_high_pc" /C:"caml_"
) else (
    echo [W5M-G] llvm-objdump unavailable
)
echo [W5M-G-DWARF-END]

rem Symbolize the two crash-site RVAs (will work only if DWARF is present)
set "LLVM_SYMBOLIZER="
for /f "delims=" %%P in ('where llvm-symbolizer 2^>nul') do set "LLVM_SYMBOLIZER=%%P"
if not defined LLVM_SYMBOLIZER set "LLVM_SYMBOLIZER=C:\Program Files\LLVM\bin\llvm-symbolizer.EXE"
echo [W5M-G-SYMBOLIZE-BEGIN]
if exist "%LLVM_SYMBOLIZER%" (
    echo --- 0x4ead0 ---
    "%LLVM_SYMBOLIZER%" --obj=hi.exe 0x4ead0 2>&1
    echo --- 0x4f0e0 ---
    "%LLVM_SYMBOLIZER%" --obj=hi.exe 0x4f0e0 2>&1
    echo --- 0x4f0f5 ---
    "%LLVM_SYMBOLIZER%" --obj=hi.exe 0x4f0f5 2>&1
) else (
    echo [W5M-G] llvm-symbolizer unavailable
)
echo [W5M-G-SYMBOLIZE-END]

echo [W5M-I] OCaml runtime archive symbol probe (bounded, no recursive dir)

rem === Explicit candidate paths (most likely first) ===
set "ASMRUN_LIB="
for %%C in (
    "%PREFIX%\Library\lib\ocaml\libasmrun.a"
    "%PREFIX%\Library\lib\ocaml\asmrun.lib"
    "%PREFIX%\Library\lib\ocaml-x86_64-imports\libasmrun.a"
    "%PREFIX%\Library\lib\ocaml-x86_64-imports\asmrun.lib"
    "%PREFIX%\lib\ocaml\libasmrun.a"
    "%PREFIX%\lib\ocaml\asmrun.lib"
    "%PREFIX%\Library\lib\libasmrun.a"
    "%PREFIX%\Library\lib\asmrun.lib"
    "%BUILD_PREFIX%\Library\lib\ocaml\libasmrun.a"
    "%BUILD_PREFIX%\Library\lib\ocaml\asmrun.lib"
    "%BUILD_PREFIX%\Library\lib\ocaml-x86_64-imports\libasmrun.a"
    "%BUILD_PREFIX%\lib\ocaml\libasmrun.a"
    "%BUILD_PREFIX%\lib\ocaml\asmrun.lib"
) do (
    if exist %%C if not defined ASMRUN_LIB set "ASMRUN_LIB=%%~C"
)
echo [W5M-I] explicit-probe result: ASMRUN_LIB=%ASMRUN_LIB%

rem === Bounded subtree search if explicit probe missed ===
if not defined ASMRUN_LIB (
    echo [W5M-I] explicit candidates missed; trying bounded where /r searches
    echo [W5M-I-WHERE-BEGIN]
    if exist "%PREFIX%" (
        echo --- where /r PREFIX libasmrun.a ---
        where /r "%PREFIX%" libasmrun.a 2>nul
        echo --- where /r PREFIX asmrun.lib ---
        where /r "%PREFIX%" asmrun.lib 2>nul
    )
    if exist "%BUILD_PREFIX%" (
        echo --- where /r BUILD_PREFIX libasmrun.a ---
        where /r "%BUILD_PREFIX%" libasmrun.a 2>nul
        echo --- where /r BUILD_PREFIX asmrun.lib ---
        where /r "%BUILD_PREFIX%" asmrun.lib 2>nul
    )
    echo [W5M-I-WHERE-END]

    rem Capture first match from where /r if any
    for /f "delims=" %%F in ('where /r "%PREFIX%" libasmrun.a 2^>nul') do (
        if not defined ASMRUN_LIB set "ASMRUN_LIB=%%F"
    )
    if not defined ASMRUN_LIB for /f "delims=" %%F in ('where /r "%BUILD_PREFIX%" libasmrun.a 2^>nul') do (
        if not defined ASMRUN_LIB set "ASMRUN_LIB=%%F"
    )
    if not defined ASMRUN_LIB for /f "delims=" %%F in ('where /r "%PREFIX%" asmrun.lib 2^>nul') do (
        if not defined ASMRUN_LIB set "ASMRUN_LIB=%%F"
    )
    if not defined ASMRUN_LIB for /f "delims=" %%F in ('where /r "%BUILD_PREFIX%" asmrun.lib 2^>nul') do (
        if not defined ASMRUN_LIB set "ASMRUN_LIB=%%F"
    )
    echo [W5M-I] post-where ASMRUN_LIB=%ASMRUN_LIB%
)

if not defined ASMRUN_LIB (
    echo [W5M-I] FATAL-DIAG: libasmrun.a/asmrun.lib not found anywhere under PREFIX or BUILD_PREFIX
    echo [W5M-I] PREFIX=%PREFIX%
    echo [W5M-I] BUILD_PREFIX=%BUILD_PREFIX%
    rem Last resort: list immediate subdirs of likely roots so a future round can target the right path
    echo [W5M-I-LS-PREFIX-BEGIN]
    if exist "%PREFIX%\Library\lib" dir /b "%PREFIX%\Library\lib" 2>nul
    if exist "%PREFIX%\lib" dir /b "%PREFIX%\lib" 2>nul
    echo [W5M-I-LS-PREFIX-END]
    echo [W5M-I-LS-BUILD-BEGIN]
    if exist "%BUILD_PREFIX%\Library\lib" dir /b "%BUILD_PREFIX%\Library\lib" 2>nul
    if exist "%BUILD_PREFIX%\lib" dir /b "%BUILD_PREFIX%\lib" 2>nul
    echo [W5M-I-LS-BUILD-END]
    goto W5M_I_END
)

echo [W5M-I-NM-BEGIN]
if exist "%LLVM_NM%" (
    "%LLVM_NM%" --print-size --size-sort "%ASMRUN_LIB%" 2>&1 | findstr /R /C:"caml_apply" /C:"caml_send" /C:"caml_curry" /C:"caml_tuplify"
) else (
    echo [W5M-I] llvm-nm unavailable
)
echo [W5M-I-NM-END]

echo [W5M-I-NM-FULL-BEGIN]
if exist "%LLVM_NM%" (
    "%LLVM_NM%" --print-size --size-sort "%ASMRUN_LIB%" 2>&1
)
echo [W5M-I-NM-FULL-END]

echo [W5M-I-OBJDUMP-SYMS-BEGIN]
if exist "%LLVM_OBJDUMP%" (
    "%LLVM_OBJDUMP%" --syms "%ASMRUN_LIB%" 2>&1 | findstr /R /C:"caml_apply" /C:"caml_send" /C:"caml_curry" /C:"caml_tuplify"
)
echo [W5M-I-OBJDUMP-SYMS-END]

echo [W5M-I-SIZE-MATCH-BEGIN]
if exist "%LLVM_NM%" (
    "%LLVM_NM%" --print-size --size-sort "%ASMRUN_LIB%" 2>&1 | findstr /R /C:" 0000000000000083 " /C:" 00000000000000c5 " /C:" 0000000000000084 " /C:" 00000000000000c6 "
)
echo [W5M-I-SIZE-MATCH-END]

:W5M_I_END
echo [W5M-I] probe complete

echo [W5M-J] env-aware libasmrun probe (env dump + ocamlopt-relative discovery)

rem === Dump environment for diagnostic visibility ===
echo [W5M-J-ENV-BEGIN]
echo PREFIX=%PREFIX%
echo CONDA_PREFIX=%CONDA_PREFIX%
echo LIBRARY_PREFIX=%LIBRARY_PREFIX%
echo TEST_PREFIX=%TEST_PREFIX%
echo BUILD_PREFIX=%BUILD_PREFIX%
echo RECIPE_DIR=%RECIPE_DIR%
echo SRC_DIR=%SRC_DIR%
echo CD=%CD%
echo [W5M-J-ENV-END]

rem === Discover ocamlopt path ===
echo [W5M-J-WHERE-OCAMLOPT-BEGIN]
where ocamlopt 2>&1
where ocamlopt.opt 2>&1
where ocamlc 2>&1
echo [W5M-J-WHERE-OCAMLOPT-END]

set "OCAML_BIN="
for /f "delims=" %%F in ('where ocamlopt 2^>nul') do (
    if not defined OCAML_BIN set "OCAML_BIN=%%~dpF"
)
if not defined OCAML_BIN for /f "delims=" %%F in ('where ocamlc 2^>nul') do (
    if not defined OCAML_BIN set "OCAML_BIN=%%~dpF"
)
echo [W5M-J] OCAML_BIN derived to: %OCAML_BIN%

rem === Probe explicit candidate paths with multiple env var fallbacks ===
set "ASMRUN_LIB_J="
for %%C in (
    "%PREFIX%\Library\lib\ocaml\libasmrun.lib"
    "%CONDA_PREFIX%\Library\lib\ocaml\libasmrun.lib"
    "%LIBRARY_PREFIX%\lib\ocaml\libasmrun.lib"
    "%TEST_PREFIX%\Library\lib\ocaml\libasmrun.lib"
    "%PREFIX%\Library\lib\ocaml-x86_64-imports\libasmrun.lib"
    "%CONDA_PREFIX%\Library\lib\ocaml-x86_64-imports\libasmrun.lib"
    "%OCAML_BIN%..\lib\ocaml\libasmrun.lib"
    "%OCAML_BIN%..\..\lib\ocaml\libasmrun.lib"
    "%OCAML_BIN%..\lib\ocaml-x86_64-imports\libasmrun.lib"
    "%CD%\ocaml\libasmrun.lib"
    "%CD%\..\ocaml\libasmrun.lib"
    "%CD%\..\lib\ocaml\libasmrun.lib"
    "%CD%\..\Library\lib\ocaml\libasmrun.lib"
    "%PREFIX%\Library\lib\ocaml\libasmrun.a"
    "%PREFIX%\Library\lib\ocaml\asmrun.lib"
    "%CONDA_PREFIX%\Library\lib\ocaml\libasmrun.a"
    "%CONDA_PREFIX%\Library\lib\ocaml\asmrun.lib"
    "%LIBRARY_PREFIX%\lib\ocaml\libasmrun.a"
    "%LIBRARY_PREFIX%\lib\ocaml\asmrun.lib"
    "%TEST_PREFIX%\Library\lib\ocaml\libasmrun.a"
    "%TEST_PREFIX%\Library\lib\ocaml\asmrun.lib"
    "%PREFIX%\Library\lib\ocaml-x86_64-imports\libasmrun.a"
    "%CONDA_PREFIX%\Library\lib\ocaml-x86_64-imports\libasmrun.a"
    "%OCAML_BIN%..\lib\ocaml\libasmrun.a"
    "%OCAML_BIN%..\lib\ocaml\asmrun.lib"
    "%OCAML_BIN%..\..\lib\ocaml\libasmrun.a"
    "%OCAML_BIN%..\..\lib\ocaml\asmrun.lib"
    "%OCAML_BIN%..\lib\ocaml-x86_64-imports\libasmrun.a"
    "%CD%\ocaml\libasmrun.a"
    "%CD%\ocaml\asmrun.lib"
    "%CD%\..\ocaml\libasmrun.a"
    "%CD%\..\ocaml\asmrun.lib"
    "%CD%\..\lib\ocaml\libasmrun.a"
    "%CD%\..\Library\lib\ocaml\libasmrun.a"
) do (
    if exist %%C if not defined ASMRUN_LIB_J set "ASMRUN_LIB_J=%%~C"
)
echo [W5M-J] explicit-probe result: ASMRUN_LIB_J=%ASMRUN_LIB_J%

rem === If still missing, bounded where /r on roots that DO exist ===
if not defined ASMRUN_LIB_J (
    echo [W5M-J] explicit candidates missed; trying bounded where /r on derived roots
    if defined OCAML_BIN (
        echo --- where /r OCAML_BIN\.. libasmrun.lib ---
        where /r "%OCAML_BIN%.." libasmrun.lib 2>nul
        echo --- where /r OCAML_BIN\.. libasmrun.a ---
        where /r "%OCAML_BIN%.." libasmrun.a 2>nul
        echo --- where /r OCAML_BIN\.. asmrun.lib ---
        where /r "%OCAML_BIN%.." asmrun.lib 2>nul
        for /f "delims=" %%F in ('where /r "%OCAML_BIN%.." libasmrun.lib 2^>nul') do (
            if not defined ASMRUN_LIB_J set "ASMRUN_LIB_J=%%F"
        )
        for /f "delims=" %%F in ('where /r "%OCAML_BIN%.." libasmrun.a 2^>nul') do (
            if not defined ASMRUN_LIB_J set "ASMRUN_LIB_J=%%F"
        )
        if not defined ASMRUN_LIB_J for /f "delims=" %%F in ('where /r "%OCAML_BIN%.." asmrun.lib 2^>nul') do (
            if not defined ASMRUN_LIB_J set "ASMRUN_LIB_J=%%F"
        )
    )
    echo [W5M-J] post-where ASMRUN_LIB_J=%ASMRUN_LIB_J%
)

if not defined ASMRUN_LIB_J (
    echo [W5M-J] FATAL-DIAG: still not found; dumping CWD listings (bounded, no recursion)
    echo [W5M-J-CD-BEGIN]
    dir /b "%CD%" 2>nul
    echo [W5M-J-CD-END]
    if defined OCAML_BIN (
        echo [W5M-J-OCAML-BIN-BEGIN]
        dir /b "%OCAML_BIN%" 2>nul
        dir /b "%OCAML_BIN%.." 2>nul
        if exist "%OCAML_BIN%..\lib" dir /b "%OCAML_BIN%..\lib" 2>nul
        if exist "%OCAML_BIN%..\lib\ocaml" dir /b "%OCAML_BIN%..\lib\ocaml" 2>nul
        echo [W5M-J-OCAML-BIN-END]
    )
    goto W5M_J_END
)

echo [W5M-J-NM-BEGIN]
if exist "%LLVM_NM%" (
    "%LLVM_NM%" --print-size --size-sort "%ASMRUN_LIB_J%" 2>&1 | findstr /R /C:"caml_apply" /C:"caml_send" /C:"caml_curry" /C:"caml_tuplify"
) else (
    echo [W5M-J] llvm-nm unavailable
)
echo [W5M-J-NM-END]

echo [W5M-J-NM-FULL-BEGIN]
if exist "%LLVM_NM%" (
    "%LLVM_NM%" --print-size --size-sort "%ASMRUN_LIB_J%" 2>&1
)
echo [W5M-J-NM-FULL-END]

echo [W5M-J-OBJDUMP-SYMS-BEGIN]
if exist "%LLVM_OBJDUMP%" (
    "%LLVM_OBJDUMP%" --syms "%ASMRUN_LIB_J%" 2>&1 | findstr /R /C:"caml_apply" /C:"caml_send" /C:"caml_curry" /C:"caml_tuplify"
)
echo [W5M-J-OBJDUMP-SYMS-END]

echo [W5M-J-SIZE-MATCH-BEGIN]
if exist "%LLVM_NM%" (
    "%LLVM_NM%" --print-size --size-sort "%ASMRUN_LIB_J%" 2>&1 | findstr /R /C:" 0000000000000083 " /C:" 00000000000000c5 " /C:" 0000000000000084 " /C:" 00000000000000c6 "
)
echo [W5M-J-SIZE-MATCH-END]

:W5M_J_END
echo [W5M-J] probe complete

echo [W5M-L] direct probe avoiding for-loop pitfalls
set "ASMRUN_LIB_L="
if defined OCAML_BIN (
    if exist "%OCAML_BIN%..\lib\ocaml\libasmrun.lib" set "ASMRUN_LIB_L=%OCAML_BIN%..\lib\ocaml\libasmrun.lib"
)
if not defined ASMRUN_LIB_L if defined OCAML_BIN (
    if exist "%OCAML_BIN%..\..\lib\ocaml\libasmrun.lib" set "ASMRUN_LIB_L=%OCAML_BIN%..\..\lib\ocaml\libasmrun.lib"
)
if not defined ASMRUN_LIB_L if defined OCAML_BIN (
    if exist "%OCAML_BIN%..\lib\ocaml\libasmrund.lib" set "ASMRUN_LIB_L=%OCAML_BIN%..\lib\ocaml\libasmrund.lib"
)
echo [W5M-L] ASMRUN_LIB_L=%ASMRUN_LIB_L%

if defined ASMRUN_LIB_L (
    if exist "%LLVM_NM%" (
        echo [W5M-L-NM-BEGIN]
        "%LLVM_NM%" --print-size --size-sort "%ASMRUN_LIB_L%" 2>&1 | findstr /R /C:"caml_apply" /C:"caml_send" /C:"caml_curry" /C:"caml_tuplify"
        echo [W5M-L-NM-END]

        echo [W5M-L-SIZE-MATCH-BEGIN]
        "%LLVM_NM%" --print-size --size-sort "%ASMRUN_LIB_L%" 2>&1 | findstr /R /C:" 0000000000000083 " /C:" 00000000000000c5 " /C:" 0000000000000084 " /C:" 00000000000000c6 "
        echo [W5M-L-SIZE-MATCH-END]

        echo [W5M-L-NM-FULL-BEGIN]
        "%LLVM_NM%" --print-size --size-sort "%ASMRUN_LIB_L%" 2>&1
        echo [W5M-L-NM-FULL-END]
    ) else (
        echo [W5M-L] LLVM_NM not available
    )

    if exist "%LLVM_OBJDUMP%" (
        echo [W5M-L-OBJDUMP-BEGIN]
        "%LLVM_OBJDUMP%" --syms "%ASMRUN_LIB_L%" 2>&1 | findstr /R /C:"caml_apply" /C:"caml_send" /C:"caml_curry" /C:"caml_tuplify"
        echo [W5M-L-OBJDUMP-END]
    )
) else (
    echo [W5M-L] FATAL: ASMRUN_LIB_L not set; OCAML_BIN=%OCAML_BIN%; check W5M-J dir listings for actual layout
)

echo [W5M-L] probe complete

echo [W5M-M] simpler-program probes + ocamlopt .s dump

rem === S-Dump: emit hi.s via ocamlopt -S (preserves intermediate assembly) ===
echo [W5M-M-S-DUMP-BEGIN]
if exist hi.ml (
    ocamlopt -S hi.ml -o hi_sdump.exe 2>&1
    if exist hi.s (
        echo --- hi.s content ---
        type hi.s
        echo --- end hi.s ---
    ) else (
        echo [W5M-M] hi.s not produced - ocamlopt may have output elsewhere; checking *.s in CWD
        for %%S in (*.s) do (
            echo --- %%S ---
            type %%S
            echo --- end %%S ---
        )
    )
)
echo [W5M-M-S-DUMP-END]

rem === Probe: three increasingly complex test programs ===
echo [W5M-M-PROBE0-BEGIN] no-apply test
echo let _ = 1 > hi0.ml
ocamlopt -verbose -ccopt "-L%PREFIX%/Library/lib/ocaml-x86_64-imports" -cclib "-stack 268435456" -cclib "-link" -cclib "-Wl,-Map=hi0.map" -o hi0.exe hi0.ml 2>&1
set "HI0_EC=NO-BUILD"
if exist hi0.exe (
    echo --- running hi0.exe ---
    hi0.exe
    call set "HI0_EC=%%ERRORLEVEL%%"
) else (
    echo [W5M-M] hi0.exe NOT BUILT
)
echo [W5M-M] hi0.exe exit code: %HI0_EC%
echo [W5M-M-PROBE0-END]

echo [W5M-M-PROBE1-BEGIN] apply1 test (print_int)
echo let _ = print_int 42 > hi1.ml
ocamlopt -verbose -ccopt "-L%PREFIX%/Library/lib/ocaml-x86_64-imports" -cclib "-stack 268435456" -o hi1.exe hi1.ml 2>&1
set "HI1_EC=NO-BUILD"
if exist hi1.exe (
    echo --- running hi1.exe ---
    hi1.exe
    call set "HI1_EC=%%ERRORLEVEL%%"
) else (
    echo [W5M-M] hi1.exe NOT BUILT
)
echo [W5M-M] hi1.exe exit code: %HI1_EC%
echo [W5M-M-PROBE1-END]

echo [W5M-M-PROBE2-BEGIN] curry1+apply1 test
echo let f x = x + 1 in print_int ^(f 0^) > hi2.ml
ocamlopt -verbose -ccopt "-L%PREFIX%/Library/lib/ocaml-x86_64-imports" -cclib "-stack 268435456" -o hi2.exe hi2.ml 2>&1
set "HI2_EC=NO-BUILD"
if exist hi2.exe (
    echo --- running hi2.exe ---
    hi2.exe
    call set "HI2_EC=%%ERRORLEVEL%%"
) else (
    echo [W5M-M] hi2.exe NOT BUILT
)
echo [W5M-M] hi2.exe exit code: %HI2_EC%
echo [W5M-M-PROBE2-END]

echo [W5M-M-PROBE3-BEGIN] hi.s for probe1 (apply1)
if exist hi1.ml (
    ocamlopt -S hi1.ml -o hi1_sdump.exe 2>&1
    if exist hi1.s (
        echo --- hi1.s content ---
        type hi1.s
        echo --- end hi1.s ---
    )
)
echo [W5M-M-PROBE3-END]

echo [W5M-M-SUMMARY] hi0=%HI0_EC% hi1=%HI1_EC% hi2=%HI2_EC%
echo.
echo [W5M-S] === default-stack / small-stack probes + PE-header diff ===
REM W5M-S: hi0 above links with -cclib "-stack 268435456" (256MB). Test whether that flag triggers STATUS_STACK_OVERFLOW.
echo let _ = 1 > hi0d.ml
ocamlopt -verbose -ccopt "-L%PREFIX%/Library/lib/ocaml-x86_64-imports" -o hi0d.exe hi0d.ml 2>&1
set "HI0D_EC=NO-BUILD"
if exist hi0d.exe ( echo --- running hi0d.exe ^(default stack^) --- & hi0d.exe & call set "HI0D_EC=%%ERRORLEVEL%%" ) else ( echo [W5M-S] hi0d.exe NOT BUILT )
echo [W5M-S] hi0d.exe exit code: %HI0D_EC%
echo let _ = 1 > hi0s.ml
ocamlopt -verbose -ccopt "-L%PREFIX%/Library/lib/ocaml-x86_64-imports" -cclib "-stack 8388608" -o hi0s.exe hi0s.ml 2>&1
set "HI0S_EC=NO-BUILD"
if exist hi0s.exe ( echo --- running hi0s.exe ^(8MB stack^) --- & hi0s.exe & call set "HI0S_EC=%%ERRORLEVEL%%" ) else ( echo [W5M-S] hi0s.exe NOT BUILT )
echo [W5M-S] hi0s.exe exit code: %HI0S_EC%
set "OCAML_OPT_EXE="
for /f "delims=" %%F in ('where ocamlopt 2^>nul') do if not defined OCAML_OPT_EXE set "OCAML_OPT_EXE=%%F"
echo [W5M-S] working compiler exe: %OCAML_OPT_EXE%
where python >nul 2>nul
if not errorlevel 1 (
  if exist hi0.exe python -c "import struct; d=open('hi0.exe','rb').read(); h=struct.unpack_from('<I',d,0x3c)[0]+24; print('[W5M-S] hi0.exe Reserve='+str(struct.unpack_from('<Q',d,h+72)[0])+' Commit='+str(struct.unpack_from('<Q',d,h+80)[0])+' Entry='+hex(struct.unpack_from('<I',d,h+16)[0])+' Subsystem='+str(struct.unpack_from('<H',d,h+68)[0])+' TLSrva='+hex(struct.unpack_from('<I',d,h+112+72)[0] if struct.unpack_from('<I',d,h+108)[0]>9 else 0))"
  if exist hi0d.exe python -c "import struct; d=open('hi0d.exe','rb').read(); h=struct.unpack_from('<I',d,0x3c)[0]+24; print('[W5M-S] hi0d.exe Reserve='+str(struct.unpack_from('<Q',d,h+72)[0])+' Commit='+str(struct.unpack_from('<Q',d,h+80)[0])+' Entry='+hex(struct.unpack_from('<I',d,h+16)[0])+' Subsystem='+str(struct.unpack_from('<H',d,h+68)[0])+' TLSrva='+hex(struct.unpack_from('<I',d,h+112+72)[0] if struct.unpack_from('<I',d,h+108)[0]>9 else 0))"
  if exist hi0s.exe python -c "import struct; d=open('hi0s.exe','rb').read(); h=struct.unpack_from('<I',d,0x3c)[0]+24; print('[W5M-S] hi0s.exe Reserve='+str(struct.unpack_from('<Q',d,h+72)[0])+' Commit='+str(struct.unpack_from('<Q',d,h+80)[0])+' Entry='+hex(struct.unpack_from('<I',d,h+16)[0])+' Subsystem='+str(struct.unpack_from('<H',d,h+68)[0])+' TLSrva='+hex(struct.unpack_from('<I',d,h+112+72)[0] if struct.unpack_from('<I',d,h+108)[0]>9 else 0))"
  if defined OCAML_OPT_EXE python -c "import struct,sys; d=open(sys.argv[1],'rb').read(); h=struct.unpack_from('<I',d,0x3c)[0]+24; print('[W5M-S] WORKING '+sys.argv[1]+' Reserve='+str(struct.unpack_from('<Q',d,h+72)[0])+' Commit='+str(struct.unpack_from('<Q',d,h+80)[0])+' Entry='+hex(struct.unpack_from('<I',d,h+16)[0])+' Subsystem='+str(struct.unpack_from('<H',d,h+68)[0])+' TLSrva='+hex(struct.unpack_from('<I',d,h+112+72)[0] if struct.unpack_from('<I',d,h+108)[0]>9 else 0))" "%OCAML_OPT_EXE%"
) else (
  echo [W5M-S] python unavailable, skipping PE diff
)
echo [W5M-S] EC-SUMMARY hi0_256MB=%HI0_EC% hi0d_default=%HI0D_EC% hi0s_8MB=%HI0S_EC%
echo.
echo [W7W] === /MAP of EXACT hi0.exe: name recursing startup fn (doc 8.2 meta-lesson) ===
if exist hi0.map echo [W7W] hi0.map created
if exist hi0.map for %%S in (hi0.map) do echo [W7W] hi0.map size=%%~zS
if exist hi0.map echo [W7W] --- symbols in crash region (RVA band 0004e/0004f) ---
if exist hi0.map findstr /i "0004e 0004f" hi0.map
if exist hi0.map echo [W7W] --- likely startup/recursion symbols (any RVA) ---
if exist hi0.map findstr /i "caml_start_program caml_startup caml_main WinMain mainCRTStartup __tmainCRT tlssup gccmain __do_global __main flexdll _pei386 atexit setjmp longjmp" hi0.map
if not exist hi0.map echo [W7W] hi0.map NOT created - lld-link /MAP not honored; rely on W5M-V objdump
echo [W7W] === end ===
echo [W5M-T] === symbolize fault 0x4f1e5 + 0x4ebc0, dump sections/TLS, disasm window ===
REM W5M-T: name the pre-init recursing startup function. hi0.exe crashes pre-caml_startup_common; W5M-S proved it is stack-size-independent.
echo let _ = 1 > hi0t.ml
ocamlopt -g -verbose -ccopt "-L%PREFIX%/Library/lib/ocaml-x86_64-imports" -cclib "-link" -cclib "-Wl,-Map=hi0t.map" -o hi0t.exe hi0t.ml 2>&1
if exist hi0t.map echo [W5M-T] hi0t.map created
if exist hi0t.map for %%S in (hi0t.map) do echo [W5M-T] hi0t.map size=%%~zS
if exist hi0t.map findstr /i "4ebc0 4f1e5 mainCRTStartup _pei386 flexdll WinMain atexit" hi0t.map
if not exist hi0t.map echo [W5M-T] hi0t.map NOT created - map flag not honored
set "PYOK=0"
where python >nul 2>nul && set "PYOK=1"
if "%PYOK%"=="1" if exist hi0.exe python -c "import struct; d=open('hi0.exe','rb').read(); pe=struct.unpack_from('<I',d,0x3c)[0]; opt=pe+24; ns=struct.unpack_from('<H',d,pe+6)[0]; osz=struct.unpack_from('<H',d,pe+20)[0]; base=struct.unpack_from('<Q',d,opt+24)[0]; sec=opt+osz; S=[(d[sec+i*40:sec+i*40+8].rstrip(b'\x00').decode('latin1'),struct.unpack_from('<I',d,sec+i*40+12)[0],struct.unpack_from('<I',d,sec+i*40+8)[0],struct.unpack_from('<I',d,sec+i*40+20)[0]) for i in range(ns)]; print('[W5M-T] hi0.exe base='+hex(base)); [print('[W5M-T] sect '+n+' VA='+hex(va)+' VS='+hex(vs)+' Raw='+hex(rp)) for (n,va,vs,rp) in S]; f=lambda r:next((n+'+'+hex(r-va)+' off='+hex(rp+(r-va)) for (n,va,vs,rp) in S if va<=r<va+vs),'N/A'); print('[W5M-T] RVA 0x4f1e5 -> '+f(0x4f1e5)); print('[W5M-T] RVA 0x4ebc0 -> '+f(0x4ebc0))"
if "%PYOK%"=="1" if exist hi0.exe python -c "import struct; d=open('hi0.exe','rb').read(); pe=struct.unpack_from('<I',d,0x3c)[0]; opt=pe+24; ns=struct.unpack_from('<H',d,pe+6)[0]; osz=struct.unpack_from('<H',d,pe+20)[0]; base=struct.unpack_from('<Q',d,opt+24)[0]; dd=opt+112; tls=struct.unpack_from('<I',d,dd+72)[0]; sec=opt+osz; S=[(struct.unpack_from('<I',d,sec+i*40+12)[0],struct.unpack_from('<I',d,sec+i*40+8)[0],struct.unpack_from('<I',d,sec+i*40+20)[0]) for i in range(ns)]; o=lambda r:next((rp+(r-va) for (va,vs,rp) in S if va<=r<va+vs),None); print('[W5M-T] TLSrva='+hex(tls)); to=o(tls); cbva=(struct.unpack_from('<Q',d,to+24)[0] if to else 0); print('[W5M-T] TLS AddrOfCallbacks VA='+hex(cbva)); co=(o(cbva-base) if cbva else None); raw=([struct.unpack_from('<Q',d,co+i*8)[0] for i in range(32)] if co else []); cbs=(raw[:raw.index(0)] if 0 in raw else raw); [print('[W5M-T] TLS callback RVA='+hex(c-base)) for c in cbs]; print('[W5M-T] TLS callback count='+str(len(cbs)))"
set "W5MT_OD="
for %%X in (llvm-objdump.exe objdump.exe x86_64-w64-mingw32-objdump.exe) do if not defined W5MT_OD for /f "delims=" %%P in ('where %%X 2^>nul') do if not defined W5MT_OD set "W5MT_OD=%%P"
echo [W5M-T] objdump=%W5MT_OD%
if defined W5MT_OD if exist hi0.exe "%W5MT_OD%" -d --start-address=0x14004e800 --stop-address=0x14004f400 hi0.exe
echo [W5M-T] === end ===
echo.
echo [W5M-U] === TLS model classification (emutls vs native PE TLS) ===
REM W5M-U: zig-session hypothesis - caml_state TLS access. emutls/__tls_get_addr => emulated TLS (startup ctors, can recurse pre-init). %gs/%fs only => native PE TLS.
set "W5MU_LIB="
for %%L in ("%PREFIX%\Library\lib\ocaml\libasmrun.lib" "%PREFIX%\Library\lib\ocaml\libasmrunnat.lib" "%PREFIX%\Library\lib\ocaml\libasmrun.a") do if not defined W5MU_LIB if exist %%L set "W5MU_LIB=%%~L"
echo [W5M-U] runtime lib: %W5MU_LIB%
set "W5MU_NM="
for %%X in (llvm-nm.exe nm.exe x86_64-w64-mingw32-nm.exe) do if not defined W5MU_NM for /f "delims=" %%P in ('where %%X 2^>nul') do if not defined W5MU_NM set "W5MU_NM=%%P"
echo [W5M-U] nm=%W5MU_NM%
if defined W5MU_NM if defined W5MU_LIB "%W5MU_NM%" "%W5MU_LIB%" 2>nul | findstr /i "emutls __tls_get_addr Caml_state caml_state"
if defined W5MT_OD if defined W5MU_LIB "%W5MT_OD%" -d "%W5MU_LIB%" 2>nul | findstr /i "emutls __tls_get_addr %%gs: %%fs:"
echo [W5M-U] interpretation: emutls/__tls_get_addr present =^> emulated TLS ; only %%gs:/%%fs: =^> native PE TLS
echo [W5M-U] === end ===
echo.
echo [W5M-V] === name recursing startup fn: imports + pdata bounds + entry/recursion disasm ===
REM W5M-V: crash = mutual recursion ~0x4f1b0<->0x4f100 in startup .text (W5M-U refuted emutls; native PE TLS). Identify via import names, .pdata fn bounds, entry trace, vs working ocamlopt.exe.
set "W5MV_RO="
for %%X in (llvm-readobj.exe llvm-readobj) do if not defined W5MV_RO for /f "delims=" %%P in ('where %%X 2^>nul') do if not defined W5MV_RO set "W5MV_RO=%%P"
echo [W5M-V] readobj=%W5MV_RO% objdump=%W5MT_OD%
if defined W5MV_RO if exist hi0.exe echo [W5M-V] --- hi0.exe coff-imports ---
if defined W5MV_RO if exist hi0.exe "%W5MV_RO%" --coff-imports hi0.exe 2>nul
if defined W5MV_RO if exist hi0.exe echo [W5M-V] --- hi0.exe .pdata unwind bounds (filter 0x4e/0x4f) ---
if defined W5MV_RO if exist hi0.exe "%W5MV_RO%" --unwind hi0.exe 2>nul | findstr /i "0x14004e 0x14004f"
if defined W5MT_OD if exist hi0.exe echo [W5M-V] --- hi0.exe entry trace (Entry 0x73c0) ---
if defined W5MT_OD if exist hi0.exe "%W5MT_OD%" -d --start-address=0x140007200 --stop-address=0x140008000 hi0.exe
if defined W5MT_OD if exist hi0.exe echo [W5M-V] --- hi0.exe recursion+callers 0x4f080-0x4f2c0 ---
if defined W5MT_OD if exist hi0.exe "%W5MT_OD%" -d --start-address=0x14004f080 --stop-address=0x14004f2c0 hi0.exe
set "W5MV_OE="
for /f "delims=" %%P in ('where ocamlopt 2^>nul') do if not defined W5MV_OE set "W5MV_OE=%%P"
if defined W5MT_OD if defined W5MV_OE echo [W5M-V] --- WORKING ocamlopt.exe entry trace (Entry 0x104f0) ---
if defined W5MT_OD if defined W5MV_OE "%W5MT_OD%" -d --start-address=0x140010200 --stop-address=0x140011000 "%W5MV_OE%"
echo [W5M-V] === end ===
echo [W7Y] === disasm LIVE fault VA (re-run hi0.exe, parse [W7U] addr; fixes stale-hardcoded symbolize) ===
set "W7Y_VA="
if exist hi0.exe hi0.exe > hi0_w7y.txt 2>&1
if exist hi0_w7y.txt for /f "tokens=2 delims==" %%A in ('findstr /c:"[W7U] addr=" hi0_w7y.txt') do set "W7Y_VA=%%A"
if defined W7Y_VA echo [W7Y] live fault VA=%W7Y_VA%
if not defined W7Y_VA echo [W7Y] no [W7U] addr captured; using fixed fault-region window
set "W7Y_START=0x14004f6c0"
set "W7Y_STOP=0x14004f8c0"
if defined W7Y_VA if "%PYOK%"=="1" for /f %%S in ('python -c "va=int('%W7Y_VA%',16);print(hex(va-0x140))"') do set "W7Y_START=%%S"
if defined W7Y_VA if "%PYOK%"=="1" for /f %%T in ('python -c "va=int('%W7Y_VA%',16);print(hex(va+0x140))"') do set "W7Y_STOP=%%T"
echo [W7Y] disasm window %W7Y_START% - %W7Y_STOP% (base 0x140000000)
if defined W5MT_OD if exist hi0.exe "%W5MT_OD%" -d --start-address=%W7Y_START% --stop-address=%W7Y_STOP% hi0.exe
if defined W7Y_VA if "%PYOK%"=="1" python -c "va=int('%W7Y_VA%',16);print('[W7Y] fault RVA='+hex(va-0x140000000))"
echo [W7Z] === unwind (.pdata) function bounds near fault -- names stripped funcs incl callee ~0x4ebc0 ===
if defined W5MT_OD if exist hi0.exe "%W5MT_OD%" --unwind-info hi0.exe > hi0_unwind.txt 2>&1
if exist hi0_unwind.txt findstr /c:"14004e" /c:"14004f" hi0_unwind.txt
echo [W7Z] === imports (.idata) -- resolve fault-adjacent IAT thunks (0x66110 / 0x65f20) ===
if defined W5MT_OD if exist hi0.exe "%W5MT_OD%" -p hi0.exe > hi0_imports.txt 2>&1
if exist hi0_imports.txt type hi0_imports.txt
echo [W7Z] === disasm callee neighborhood (recursion target ~0x4ebc0) ===
if defined W5MT_OD if exist hi0.exe "%W5MT_OD%" -d --start-address=0x14004ea00 --stop-address=0x14004ee00 hi0.exe
echo [W7Y] === end ===
echo.
echo [W6A-MAP] === zig-feedstock diag: named map twin of hi.exe -- DO NOT REMOVE until recursion pair named ^&^& fixed ===
REM W6A-MAP (zig session): native hi.exe crashes 0xC00000FD via infinite mutual recursion (~.text 0x4f1d0 ^<-^> 0x4ebc0). hi.exe is STRIPPED. Relink a mapped+symbol twin from the SAME hi.ml so the RVAs resolve to names. build-29 zig wrapper translates -Wl,-Map -^> /MAP:. NON-FATAL: always continue.
if exist hi.ml ocamlopt -verbose -ccopt "-L%PREFIX%/Library/lib/ocaml-x86_64-imports" -cclib "-stack 268435456" -g -o hi_map.exe hi.ml >hi_map_verbose.txt 2>&1
if exist hi_map_verbose.txt type hi_map_verbose.txt
if not exist hi.ml echo [W6A-MAP] hi.ml missing - cannot build mapped twin (non-fatal)
if exist hi_map.exe echo [W6A-MAP] hi_map.exe built (unstripped -g twin)
echo [W7D] === CRT ctor-table + crash-range symbols (hi_map.exe) ===
if exist hi_map.exe (
  where llvm-objdump >nul 2>nul && where python >nul 2>nul && (
    echo [W7D] --- CRT section hex dump ---
    llvm-objdump -s hi_map.exe >hi_map_sects_w7d.txt 2>&1
    python -c "import re; d=open('hi_map_sects_w7d.txt').read(); [print(m.group()) for m in re.finditer(r'Contents of section [^\n]*CRT[^\n]*:[\s\S]*?(?=Contents of section |\Z)', d)]"
    del hi_map_sects_w7d.txt 2>nul
  ) || echo [W7D] objdump/python unavailable (non-fatal)
  where llvm-nm >nul 2>nul && (
    echo [W7D] --- symbols in crash RVA 0x4e000-0x4ffff ---
    llvm-nm -n --defined-only hi_map.exe 2>nul | findstr /r "^0000000014004[ef]"
    echo [W7D] --- ctor/reloc/init named symbols ---
    llvm-nm -n --defined-only hi_map.exe 2>nul | findstr /i "global_ctor pei386 flexdll caml_startup __main __do_global runtime_reloc"
  ) || echo [W7D] llvm-nm unavailable (non-fatal)
) else echo [W7D] hi_map.exe not found (non-fatal)
echo [W7D] === end ===
echo [W6A-MAP v2] name recursion pair via DWARF - no -Map, no build-29 needed. v1 failed: flexlink stripped -Wl, to bare -Map= (only build-29 zig translates). DWARF .debug_* from -g libasmrun survive COFF strip; read by symbolizer/addr2line, not COFF symtab.
echo [W6A-MAP v2] RVAs shift per build - VA = 0x140000000 + WER Fault offset. Current fault set: 0x4f1e5 0x4ebc0 0x4f100 0x4f1b0 0x4f140 0x4eba0. W7C new: 0x4f375 0x4f3b5 0x4f364.
echo [W6A-MAP v2] llvm-symbolizer on -g twin hi_map.exe:
where llvm-symbolizer >nul 2>nul && llvm-symbolizer --obj=hi_map.exe 0x14004f1e5 0x14004ebc0 0x14004f100 0x14004f1b0 0x14004f140 0x14004eba0 0x14004f375 0x14004f3b5 0x14004f364 0x14000b250 0x14004f800 0x14004f1a0 2>nul || echo [W6A-MAP v2] llvm-symbolizer unavailable/failed (non-fatal)
echo [W6A-MAP v2] llvm-addr2line on -g twin hi_map.exe:
where llvm-addr2line >nul 2>nul && llvm-addr2line -f -i -e hi_map.exe 0x14004f1e5 0x14004ebc0 0x14004f100 0x14004f1b0 0x14004f140 0x14004eba0 0x14004f375 0x14004f3b5 0x14004f364 0x14000b250 0x14004f800 0x14004f1a0 2>nul || echo [W6A-MAP v2] llvm-addr2line unavailable/failed (non-fatal)
echo [W6A-MAP v2] one-shot: symbolize EXISTING stripped hi.exe (may already carry DWARF - no relink):
where llvm-symbolizer >nul 2>nul && llvm-symbolizer --obj=hi.exe 0x14004f1e5 0x14004ebc0 2>nul || echo [W6A-MAP v2] hi.exe symbolize skipped (non-fatal)
echo [W6A-MAP v2] fallback: objdump -d -l source-line disasm over fault window:
where llvm-objdump >nul 2>nul && llvm-objdump -d -l --start-address=0x14004e000 --stop-address=0x14004f300 hi_map.exe 2>nul | findstr /i ".c: caml_ _initterm CRTStartup TlsCallback __scrt pthread try_realloc scan_stack" || echo [W6A-MAP v2] objdump fallback skipped (non-fatal)
echo [W9] === back-edge hunt: DYNAMIC ctor disasm (parse [W7Q] ctor= from hi0_w7y.txt) ===
set "W9_CTOR="
if exist hi0_w7y.txt for /f "tokens=2 delims==" %%A in ('findstr /c:"[W7Q] ctor=" hi0_w7y.txt') do set "W9_CTOR=%%A"
if not defined W9_CTOR echo [W9] no [W7Q] ctor= captured; using fixed 0x14000b250
if not defined W9_CTOR set "W9_CTOR=0x14000b250"
echo [W9] live ctor VA=%W9_CTOR%
set "W9_CS=0x14000b210"
set "W9_CE=0x14000b2e0"
if "%PYOK%"=="1" for /f %%S in ('python -c "va=int('%W9_CTOR%',16);print(hex(va-0x40))"') do set "W9_CS=%%S"
if "%PYOK%"=="1" for /f %%T in ('python -c "va=int('%W9_CTOR%',16);print(hex(va+0xa0))"') do set "W9_CE=%%T"
echo [W9] ctor disasm window %W9_CS% - %W9_CE% (names recursion back-edge; -l gives source)
if defined W5MT_OD if exist hi_map.exe "%W5MT_OD%" -d -l --start-address=%W9_CS% --stop-address=%W9_CE% hi_map.exe
if defined W5MT_OD if exist hi0.exe "%W5MT_OD%" -d --start-address=%W9_CS% --stop-address=%W9_CE% hi0.exe
where llvm-symbolizer >nul 2>nul && llvm-symbolizer --obj=hi_map.exe %W9_CTOR% 2>nul || echo [W9] ctor symbolize skipped (non-fatal)
echo [W9] === end ===
echo [W10] === name via REAL hi0.exe DWARF (twin hi_map.exe layout does NOT match hi0.exe - W9 proved it) ===
set "W10_FAULT=%W7Y_VA%"
if not defined W10_FAULT set "W10_FAULT=0x14004f815"
echo [W10] symbolizing hi0.exe DIRECTLY at fault %W10_FAULT% + crash-region set (0x4f800 caller / 0x4ebc0 callee / 0x4f1a0 / 0xb250)
where llvm-symbolizer >nul 2>nul && llvm-symbolizer --obj=hi0.exe %W10_FAULT% 0x14004f800 0x14004ebc0 0x14004f1a0 0x14000b250 2>nul || echo [W10] hi0 llvm-symbolizer skipped (non-fatal)
where llvm-addr2line >nul 2>nul && llvm-addr2line -f -i -e hi0.exe %W10_FAULT% 0x14004f800 0x14004ebc0 0x14004f1a0 0x14000b250 2>nul || echo [W10] hi0 addr2line skipped (non-fatal)
echo [W10] objdump -d -l over func@0x4f800 (source lines from any embedded DWARF in the REAL binary):
where llvm-objdump >nul 2>nul && llvm-objdump -d -l --start-address=0x14004f7e0 --stop-address=0x14004f8d0 hi0.exe 2>nul | findstr /i ".c: .ml: __main CRTStartup do_global enum_import pesect gccmain caml_ WinMain tls" || echo [W10] hi0 objdump -l skipped (non-fatal)
echo [W10] === end ===
echo [W11] === back-edge: who calls main@0x4f800 / __main@0x4ebc0? (xref on REAL hi0.exe) ===
where llvm-objdump >nul 2>nul && llvm-objdump -f hi0.exe 2>nul | findstr /i "start entry address" || echo [W11] objdump -f skipped (non-fatal)
echo [W11] --- all sites referencing main@0x14004f800 or __main@0x14004ebc0 (the callers) ---
where llvm-objdump >nul 2>nul && llvm-objdump -d hi0.exe 2>nul | findstr /C:"14004f800" /C:"14004ebc0" || echo [W11] xref skipped (non-fatal)
echo [W11] --- main full body (crtexewin.c:33) ---
where llvm-objdump >nul 2>nul && llvm-objdump -d -l --start-address=0x14004f800 --stop-address=0x14004f8d0 hi0.exe 2>nul
echo [W11] --- __main body (gccmain.c:57) ---
where llvm-objdump >nul 2>nul && llvm-objdump -d -l --start-address=0x14004ebc0 --stop-address=0x14004ec80 hi0.exe 2>nul
echo [W11] === end ===
echo [W12] === live-symbol xref (no hardcoded VA): resolve WinMain/wWinMain/main/caml_main from symtab ===
where llvm-objdump >nul 2>nul && llvm-objdump -t hi0.exe 2>nul | findstr /i /C:"caml_main" /C:"WinMain" /C:"wWinMain" /C:" main" /C:"crtexewin" /C:"__main" || echo [W12] symtab xref skipped (non-fatal)
echo [W12] --- disasm WinMain + wWinMain bodies (confirm they now branch to caml_main, NOT main) ---
where llvm-objdump >nul 2>nul && llvm-objdump -d -l --disassemble-symbols=WinMain,wWinMain hi0.exe 2>nul || echo [W12] WinMain/wWinMain disasm skipped (non-fatal)
echo [W12] --- if hi0.exe still crashed, live fault window was already dumped by [W7Y] above (VA=%W7Y_VA%) ---
echo [W12] === end ===
echo [W6A-MAP] === end ===
echo [W7B] === MAP probe: name recursion pair via flexlink -verbose link-cmd re-run ===
REM W7B: build hi_map.exe with -verbose to capture the underlying zig cc link command
REM then re-run that exact command appended with -Wl,-Map=hi_probe.map (bypasses flexlink
REM stripping of -Wl, prefix; zig cc passes -Map= to lld-link as /MAP:).
REM Also: W7B VEH in winmain_stub_native.c prints [W7B] fault_addr= at crash time.
REM W17: W7B MAP-probe block fully neutralized (diagnostic-only). The recursion pair
REM was solved by W12 (WinMain->caml_main) + W15 (weak caml_main); the MAP re-run was
REM already skipped by W16. But W16 LEFT the `type hi_probe_verb.txt` dump, the
REM `for /f ... findstr` capture into W7B_LNKCMD, and `echo %W7B_LNKCMD%` INSIDE the
REM `if defined (...)` paren-block. The captured flexlink line contains the
REM `(x86_64-w64-mingw32-gcc):`/`C:\...` tokens whose parens+colon made cmd.exe abort
REM the whole test script with "colon was unexpected at this time" -> exit 255, AFTER
REM all real tests (hi/hi0/hi1/hi2/hi0d/hi0s) had already passed. W17 removes the
REM type/for-f/var-echo machinery entirely; no build, no capture, no raw echo.
echo [W7B] SKIPPED by W17 - diagnostic-only MAP probe removed; recursion solved by W12 + W15, all real tests pass above
echo [W7B] === end ===
echo [W5M-M] probes complete

echo [W3II] hi.exe raw exit code: %HI_RAW_EXIT%
echo [W3II] hi.exe stdout:
type hi_stdout.txt
echo [W3II] hi.exe stderr:
type hi_stderr.txt
type hi_stdout.txt | findstr /C:"Hello World" >nul
set HI_EXIT=%ERRORLEVEL%
echo [W3FF] hi.exe findstr exit code: %HI_EXIT%
REM W3PP: collapse multi-line if (...) and remove parens from echo strings.
REM cmd.exe parens-depth counter silently aborts script when echo body has literal parens.
if "%HI_RAW_EXIT%" neq "0" (echo   native execution FAILED [non-zero exit] & exit /b 1)
if "%HI_EXIT%" neq "0" (echo   native execution FAILED [output check] & exit /b 1)
echo   native execution: OK
echo [W3OO] section 2 complete, proceeding to section 3
del hi.exe hi_stdout.txt hi_stderr.txt 2>nul

REM 3. Bytecode compiler via ocamlrun
REM W3OO: don't depend on %OCAML_PREFIX% (set via activation but defensive);
REM use %PREFIX%\Library directly. Installed file has .exe suffix on Windows.
echo === Testing bytecode compiler via ocamlrun ===
echo [W3OO] OCAML_PREFIX="%OCAML_PREFIX%"  PREFIX="%PREFIX%"
set "_OCAMLC_BYTE=%PREFIX%\Library\bin\ocamlc.byte.exe"
if not exist "%_OCAMLC_BYTE%" set "_OCAMLC_BYTE=%PREFIX%\Library\bin\ocamlc.byte"
if not exist "%_OCAMLC_BYTE%" (
    echo [W3OO] ocamlc.byte not found at %PREFIX%\Library\bin\ - FAILED
    exit /b 1
)
echo [W3OO] using _OCAMLC_BYTE=%_OCAMLC_BYTE%
ocamlrun "%_OCAMLC_BYTE%" -version | findstr /C:"%VERSION%" >nul
if errorlevel 1 (
    echo   ocamlc.byte via ocamlrun: FAILED
    exit /b 1
)
echo   ocamlc.byte via ocamlrun: OK

REM 4. Multi-file compilation
echo === Testing multi-file compilation ===
echo let greet () = print_endline "From Lib"> lib.ml
echo let () = Lib.greet ()> main.ml

echo   bytecode multi-file...
ocamlc -c lib.ml
if errorlevel 1 (
    echo   lib.ml compile: FAILED
    exit /b 1
)
ocamlc -c main.ml
if errorlevel 1 (
    echo   main.ml compile: FAILED
    exit /b 1
)
ocamlc -o multi.exe lib.cmo main.cmo
if errorlevel 1 (
    echo   bytecode link: FAILED
    exit /b 1
)
ocamlrun multi.exe | findstr /C:"From Lib" >nul
if errorlevel 1 (
    echo   bytecode multi-file execution: FAILED
    exit /b 1
)
echo   bytecode multi-file: OK
del multi.exe

echo   native multi-file...
ocamlopt -c lib.ml
if errorlevel 1 (
    echo   lib.ml native compile: FAILED
    exit /b 1
)
ocamlopt -c main.ml
if errorlevel 1 (
    echo   main.ml native compile: FAILED
    exit /b 1
)
REM W3DD: -verbose propagates to flexlink so link step shows library resolution
ocamlopt -verbose -ccopt "-L%PREFIX%/Library/lib/ocaml-x86_64-imports" -o multi.exe lib.cmx main.cmx
if errorlevel 1 (
    echo   native link: FAILED
    exit /b 1
)

REM W3II: REAL DLL imports existence check (via 'where') for multi.exe
echo [W3II] multi.exe REAL DLL imports existence check (via where):
for %%d in (kernel32.dll msvcrt.dll ucrt.dll ucrtbase.dll ws2_32.dll VERSION.dll api-ms-win-core-synch-l1-2-0.dll SHLWAPI.dll SHELL32.dll ole32.dll) do (
    where %%d >nul 2>&1 && echo   [W3II] FOUND: %%d || echo   [W3II] MISSING: %%d
)

REM W3HH: dump multi.exe actual PE import table via pefile
echo [W3HH] multi.exe PE import table (via pefile):
python -c "import pefile; pe=pefile.PE('multi.exe'); [print('  [W3HH] imports: '+e.dll.decode()) for e in pe.DIRECTORY_ENTRY_IMPORT]" 2>&1

REM W3II: dump multi.exe PE delay-import table via pefile
echo [W3II] multi.exe PE delay-import table (via pefile):
python -c "import pefile; pe=pefile.PE('multi.exe'); [print('  [W3II] delay-imports: '+e.dll.decode()) for e in getattr(pe,'DIRECTORY_ENTRY_DELAY_IMPORT',[])]" 2>&1

REM W3KK: per-symbol imports for CRT DLLs to identify missing entrypoint
echo [W3KK] multi.exe per-symbol imports for CRT DLLs (ucrt/ucrtbase/msvcrt):
python -c "import pefile; pe=pefile.PE('multi.exe'); [print('  [W3KK] '+e.dll.decode()+': '+(imp.name.decode() if imp.name else 'ord '+str(imp.ordinal))) for e in pe.DIRECTORY_ENTRY_IMPORT if e.dll.decode().lower() in ('ucrt.dll','ucrtbase.dll','msvcrt.dll') for imp in e.imports]" 2>&1

REM W3FF: PATH already prepended for runtime DLL resolution (done before hi.exe section)
REM W3NN: same fix as hi.exe block - avoid 'start /WAIT' new-console stdio loss.
echo [W3NN] running multi.exe directly (no 'start /WAIT' - new-console eats stdio redirects):
multi.exe > multi_stdout.txt 2> multi_stderr.txt
set MULTI_RAW_EXIT=%ERRORLEVEL%
echo [W3II] multi.exe raw exit code: %MULTI_RAW_EXIT%
echo [W3II] multi.exe stdout:
type multi_stdout.txt
echo [W3II] multi.exe stderr:
type multi_stderr.txt
type multi_stdout.txt | findstr /C:"From Lib" >nul
set MULTI_EXIT=%ERRORLEVEL%
echo [W3FF] multi.exe findstr exit code: %MULTI_EXIT%
REM W3PP: same single-line collapse + bracket substitution as hi.exe block.
if "%MULTI_RAW_EXIT%" neq "0" (echo   native multi-file execution FAILED [non-zero exit] & exit /b 1)
if "%MULTI_EXIT%" neq "0" (echo   native multi-file execution FAILED [output check] & exit /b 1)
echo   native multi-file: OK

REM Cleanup
del hi.ml lib.ml lib.cmi lib.cmo lib.cmx lib.obj main.ml main.cmi main.cmo main.cmx main.obj multi.exe multi_stdout.txt multi_stderr.txt 2>nul

echo === All compilation tests passed ===
