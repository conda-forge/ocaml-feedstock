@echo off
REM Test environment variables and resource file paths
REM Verifies no build-time paths leaked into installed package

setlocal EnableDelayedExpansion

echo === OCAML config Tests ===

REM Check config vars don't contain build-time paths
echo Checking ocamlc.opt -config-var values...

for /f "delims=" %%i in ('ocamlc.opt -config-var standard_library') do set "STDLIB_PATH=%%i"
echo   standard_library=%STDLIB_PATH%

for /f "delims=" %%i in ('ocamlc.opt -config-var bytecomp_c_compiler') do set "CC_PATH=%%i"
echo   bytecomp_c_compiler=%CC_PATH%

for /f "delims=" %%i in ('ocamlc.opt -config-var native_c_compiler') do set "CC_PATH=%%i"
echo   native_c_compiler=%CC_PATH%

for /f "delims=" %%i in ('ocamlc.opt -config-var c_compiler') do set "CC_PATH=%%i"
echo   c_compiler=%CC_PATH%

REM Should not contain rattler-build_ from another job
echo %CC_PATH% | findstr /i "rattler-build_" >nul 2>&1
if %errorlevel%==0 (
    echo ERROR: c_compiler contains build-time path: %CC_PATH%
    exit /b 1
)
echo   c_compiler: clean

for /f "delims=" %%i in ('ocamlc.opt -config-var asm') do set "ASM_PATH=%%i"
echo   asm=%ASM_PATH%
echo %ASM_PATH% | findstr /i "rattler-build_" >nul 2>&1
if %errorlevel%==0 (
    echo ERROR: asm contains build-time path: %ASM_PATH%
    exit /b 1
)
echo   asm: clean

REM Check library paths don't contain build-time paths
for /f "delims=" %%i in ('ocamlc.opt -config-var bytecomp_c_libraries') do set "BYTECCLIBS=%%i"
echo   bytecomp_c_libraries=%BYTECCLIBS%
echo %BYTECCLIBS% | findstr /i "rattler-build_ conda-bld build_env" >nul 2>&1
if %errorlevel%==0 (
    echo ERROR: bytecomp_c_libraries contains build-time path: %BYTECCLIBS%
    exit /b 1
)
echo   bytecomp_c_libraries: clean

REM compression_c_libraries may not exist in all OCaml versions
for /f "delims=" %%i in ('ocamlc.opt -config-var compression_c_libraries 2^>nul') do set "ZSTDLIBS=%%i"
if defined ZSTDLIBS (
    echo   compression_c_libraries=%ZSTDLIBS%
    echo %ZSTDLIBS% | findstr /i "rattler-build_ conda-bld build_env" >nul 2>&1
    if %errorlevel%==0 (
        echo ERROR: compression_c_libraries contains build-time path: %ZSTDLIBS%
        exit /b 1
    )
    echo   compression_c_libraries: clean
) else (
    echo   compression_c_libraries: N/A
)

REM Check native_c_libraries for build-time paths
for /f "delims=" %%i in ('ocamlc.opt -config-var native_c_libraries 2^>nul') do set "NATIVECCLIBS=%%i"
if defined NATIVECCLIBS (
    echo   native_c_libraries=%NATIVECCLIBS%
    echo %NATIVECCLIBS% | findstr /i "rattler-build_ conda-bld build_env" >nul 2>&1
    if %errorlevel%==0 (
        echo ERROR: native_c_libraries contains build-time path: %NATIVECCLIBS%
        exit /b 1
    )
    echo   native_c_libraries: clean
) else (
    echo   native_c_libraries: N/A
)

REM Check Makefile.config for hardcoded build paths
set "MAKEFILE_CONFIG=%PREFIX%\lib\ocaml\Makefile.config"
if exist "%MAKEFILE_CONFIG%" (
    echo Checking Makefile.config for build-time paths...
    findstr /i "rattler-build_ conda-bld build_env" "%MAKEFILE_CONFIG%" >nul 2>&1
    if %errorlevel%==0 (
        echo ERROR: Makefile.config contains build-time paths:
        findstr /i "rattler-build_ conda-bld build_env" "%MAKEFILE_CONFIG%"
        exit /b 1
    )
    echo   Makefile.config: clean
)

echo === OCAML config tests passed ===
exit /b 0
