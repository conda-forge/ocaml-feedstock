@echo off
REM Merged test suite for OCaml package integrity (native mode)
REM Combines environment validation and configuration sanity checks
REM Verifies no build-time paths leaked, OCAMLLIB/PATH set, and configs are clean

setlocal EnableDelayedExpansion

REM Bytecode-only targets have no ocamlc.opt
where ocamlc.opt >nul 2>&1
if errorlevel 1 (set "OCAMLC_CFG=ocamlc") else (set "OCAMLC_CFG=ocamlc.opt")
echo   config queried with %OCAMLC_CFG%

echo === Package Integrity Tests ===
echo.

REM =============================================================================
REM ENVIRONMENT VALIDATION
REM =============================================================================
echo === Environment Tests (native mode) ===

echo OCAMLLIB=%OCAMLLIB%
echo %OCAMLLIB% | findstr /C:"ocaml" >nul && echo   OCAMLLIB contains ocaml: OK

echo PATH check...
echo %PATH% | findstr /C:"ocaml" >nul && echo   PATH contains ocaml: OK
echo.

REM =============================================================================
REM OCAML CONFIG VALIDATION
REM =============================================================================
echo === OCAML Config Tests ===
echo.
echo Checking %OCAMLC_CFG% -config-var values...
echo.

REM Check config vars don't contain build-time paths
for /f "delims=" %%i in ('%OCAMLC_CFG% -config-var standard_library') do set "STDLIB_PATH=%%i"
if not defined STDLIB_PATH (
    echo ERROR: %OCAMLC_CFG% -config-var failed
    exit /b 1
)
echo   standard_library=%STDLIB_PATH%

for /f "delims=" %%i in ('%OCAMLC_CFG% -config-var bytecomp_c_compiler') do set "CC_PATH=%%i"
echo   bytecomp_c_compiler=%CC_PATH%

for /f "delims=" %%i in ('%OCAMLC_CFG% -config-var native_c_compiler') do set "CC_PATH=%%i"
echo   native_c_compiler=%CC_PATH%

for /f "delims=" %%i in ('%OCAMLC_CFG% -config-var c_compiler') do set "CC_PATH=%%i"
echo   c_compiler=%CC_PATH%

REM Should not contain rattler-build_ from another job
echo %CC_PATH% | findstr /i "rattler-build_" >nul 2>&1
if %errorlevel%==0 (
    echo ERROR: c_compiler contains build-time path: %CC_PATH%
    exit /b 1
)
echo   c_compiler: clean

for /f "delims=" %%i in ('%OCAMLC_CFG% -config-var asm') do set "ASM_PATH=%%i"
echo   asm=%ASM_PATH%
echo %ASM_PATH% | findstr /i "rattler-build_" >nul 2>&1
if %errorlevel%==0 (
    echo ERROR: asm contains build-time path: %ASM_PATH%
    exit /b 1
)
echo   asm: clean
echo.

REM Check library paths don't contain build-time paths
echo Checking compiler library paths...
echo.

for /f "delims=" %%i in ('%OCAMLC_CFG% -config-var bytecomp_c_libraries') do set "BYTECCLIBS=%%i"
echo   bytecomp_c_libraries=%BYTECCLIBS%
echo %BYTECCLIBS% | findstr /i "rattler-build_ conda-bld build_env" >nul 2>&1
if %errorlevel%==0 (
    echo ERROR: bytecomp_c_libraries contains build-time path: %BYTECCLIBS%
    exit /b 1
)
echo   bytecomp_c_libraries: clean

REM Non-unix builds link zstd, so compression_c_libraries must name it
for /f "delims=" %%i in ('%OCAMLC_CFG% -config-var compression_c_libraries 2^>nul') do set "ZSTDLIBS=%%i"
if not defined ZSTDLIBS (
    echo ERROR: compression_c_libraries is empty, zstd is not linked
    exit /b 1
)
echo   compression_c_libraries=%ZSTDLIBS%
echo %ZSTDLIBS% | findstr /i "zstd" >nul 2>&1
if errorlevel 1 (
    echo ERROR: compression_c_libraries does not name zstd: %ZSTDLIBS%
    exit /b 1
)
echo %ZSTDLIBS% | findstr /i "rattler-build_ conda-bld build_env" >nul 2>&1
if %errorlevel%==0 (
    echo ERROR: compression_c_libraries contains build-time path: %ZSTDLIBS%
    exit /b 1
)
echo   compression_c_libraries: clean
echo %BYTECCLIBS% | findstr /i "zstd" >nul 2>&1
if errorlevel 1 (
    echo ERROR: bytecomp_c_libraries does not name zstd: %BYTECCLIBS%
    exit /b 1
)
echo   bytecomp_c_libraries: zstd present

REM Check native_c_libraries for build-time paths
for /f "delims=" %%i in ('%OCAMLC_CFG% -config-var native_c_libraries 2^>nul') do set "NATIVECCLIBS=%%i"
if defined NATIVECCLIBS (
    echo   native_c_libraries=%NATIVECCLIBS%
    echo %NATIVECCLIBS% | findstr /i "rattler-build_ conda-bld build_env" >nul 2>&1
    if !errorlevel!==0 (
        echo ERROR: native_c_libraries contains build-time path: %NATIVECCLIBS%
        exit /b 1
    )
    echo   native_c_libraries: clean
) else (
    echo   native_c_libraries: N/A
)
echo.

REM =============================================================================
REM MAKEFILE.CONFIG VALIDATION
REM =============================================================================
echo Checking Makefile.config for build-time paths...
set "MAKEFILE_CONFIG=%PREFIX%\lib\ocaml\Makefile.config"
if exist "%MAKEFILE_CONFIG%" (
    findstr /i "rattler-build_ conda-bld build_env" "%MAKEFILE_CONFIG%" >nul 2>&1
    if !errorlevel!==0 (
        echo ERROR: Makefile.config contains build-time paths:
        findstr /i "rattler-build_ conda-bld build_env" "%MAKEFILE_CONFIG%"
        exit /b 1
    )
    echo   Makefile.config: clean
) else (
    echo   Makefile.config: not found (OK)
)
echo.

REM =============================================================================
REM STAGING PREFIXES IN SHIPPED FILES
REM =============================================================================
REM Paths compiled into binaries and libraries are invisible to -config-var, so
REM scan the bytes of every shipped file. .cmt/.cmti record the build command
REM line and load path, never a runtime path, so they are skipped.
echo Scanning shipped files for build-time staging prefixes...
set "STAGING_HITS="
for /f "delims=" %%i in ('grep -rlaE --exclude=*.cmt --exclude=*.cmti -e "[/\\]_native_compiler" -e "[/\\]_xcross_compiler" -e "[/\\]_target_compiler" "%PREFIX%\Library\bin" "%PREFIX%\Library\lib\ocaml" 2^>nul') do set "STAGING_HITS=!STAGING_HITS! %%i"
if defined STAGING_HITS (
    echo ERROR: shipped files contain build-time staging prefixes:
    echo !STAGING_HITS!
    exit /b 1
)
echo   staging prefixes: none
echo.

REM =============================================================================
REM CONFIG IS OPAQUE TO OTHER COMPILER-LIBS UNITS
REM =============================================================================
REM Config bakes per-build paths; units importing its implementation with a CRC
REM would change CRC on every rebuild. ocamlobjinfo prints an all-dash CRC for
REM an opaque import, so clflags.cmx must list Config with dashes. Bytecode-only
REM builds ship no .cmx.
echo Checking Config is imported without an implementation CRC...
set "CLFLAGS_CMX=%PREFIX%\Library\lib\ocaml\compiler-libs\clflags.cmx"
if not exist "%CLFLAGS_CMX%" (
    if exist "%PREFIX%\Library\bin\ocamlopt.exe" (
        echo ERROR: %CLFLAGS_CMX% not found
        exit /b 1
    )
    echo   clflags.cmx: not shipped ^(bytecode-only^), skipped
    goto :config_done
)
set "OBJINFO_OUT=%TEMP%\ocaml-clflags-objinfo.txt"
ocamlobjinfo "%CLFLAGS_CMX%" > "%OBJINFO_OUT%"
if errorlevel 1 (
    echo ERROR: ocamlobjinfo failed on %CLFLAGS_CMX%
    exit /b 1
)
grep -qE "^[[:space:]]+-+[[:space:]]+Config[[:space:]]*$" "%OBJINFO_OUT%"
if errorlevel 1 (
    echo ERROR: clflags.cmx does not import Config without a CRC:
    grep -E "[[:space:]]Config[[:space:]]*$" "%OBJINFO_OUT%"
    exit /b 1
)
echo   clflags.cmx: Config imported without CRC
:config_done
echo.

REM =============================================================================
REM FINAL SUMMARY
REM =============================================================================
echo === All package integrity tests passed ===
exit /b 0
