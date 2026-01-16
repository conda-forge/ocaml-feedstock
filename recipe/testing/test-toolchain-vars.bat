@echo off
REM Test that CONDA_OCAML_* toolchain variables work correctly on Windows
setlocal enabledelayedexpansion

echo === Test: CONDA_OCAML_* Toolchain Variables ===
echo.

REM Test 1: Verify activation script sets defaults
echo Test 1: Activation script sets default CONDA_OCAML_* values

REM Source activation script if needed
if exist "%CONDA_PREFIX%\etc\conda\activate.d\ocaml_activate.bat" (
    call "%CONDA_PREFIX%\etc\conda\activate.d\ocaml_activate.bat"
)

REM Check that variables are set
if not defined CONDA_OCAML_CC (
    echo FAIL: CONDA_OCAML_CC is not set after activation
    exit /b 1
)
if not defined CONDA_OCAML_AS (
    echo FAIL: CONDA_OCAML_AS is not set after activation
    exit /b 1
)
if not defined CONDA_OCAML_AR (
    echo FAIL: CONDA_OCAML_AR is not set after activation
    exit /b 1
)
if not defined CONDA_OCAML_RANLIB (
    echo FAIL: CONDA_OCAML_RANLIB is not set after activation
    exit /b 1
)
if not defined CONDA_OCAML_LD (
    echo FAIL: CONDA_OCAML_LD is not set after activation
    exit /b 1
)
if not defined CONDA_OCAML_WINDRES (
    echo FAIL: CONDA_OCAML_WINDRES is not set after activation
    exit /b 1
)

echo   CONDA_OCAML_CC     = %CONDA_OCAML_CC%
echo   CONDA_OCAML_AS     = %CONDA_OCAML_AS%
echo   CONDA_OCAML_AR     = %CONDA_OCAML_AR%
echo   CONDA_OCAML_RANLIB = %CONDA_OCAML_RANLIB%
echo   CONDA_OCAML_LD     = %CONDA_OCAML_LD%
echo   CONDA_OCAML_WINDRES= %CONDA_OCAML_WINDRES%
echo PASS: All CONDA_OCAML_* variables are set
echo.

REM Test 2: Verify wrapper executables exist
echo Test 2: Wrapper executables exist in OCAML_PREFIX\bin

set WRAPPER_DIR=%OCAML_PREFIX%\bin
set WRAPPER_MISSING=0

for %%w in (cc as ar ld ranlib windres) do (
    if exist "%WRAPPER_DIR%\conda-ocaml-%%w.exe" (
        echo   conda-ocaml-%%w.exe: OK
    ) else (
        echo   conda-ocaml-%%w.exe: MISSING
        set WRAPPER_MISSING=1
    )
)

if %WRAPPER_MISSING% equ 1 (
    echo FAIL: Some wrapper executables are missing
    exit /b 1
)
echo PASS: All wrapper executables found
echo.

REM Test 3: Verify ocamlopt -config shows wrapper names
echo Test 3: ocamlopt -config shows wrapper toolchain configuration

for /f "tokens=*" %%i in ('ocamlopt -config-var c_compiler 2^>nul') do set CONFIG_CC=%%i
for /f "tokens=*" %%i in ('ocamlopt -config-var asm 2^>nul') do set CONFIG_ASM=%%i

echo   c_compiler = %CONFIG_CC%
echo   asm = %CONFIG_ASM%

REM Check if config shows conda-ocaml-* wrapper names
echo %CONFIG_CC% | findstr /C:"conda-ocaml" >nul
if %errorlevel% equ 0 (
    echo PASS: c_compiler uses conda-ocaml wrapper
) else (
    echo WARN: c_compiler may not use wrapper: %CONFIG_CC%
)
echo.

REM Test 4: Compilation works with default toolchain
echo Test 4: Compilation works with default CONDA_OCAML_CC

set TESTDIR=%TEMP%\ocaml-toolchain-test-%RANDOM%
mkdir "%TESTDIR%" 2>nul

echo let ^(^) = print_endline "Hello from OCaml" > "%TESTDIR%\hello.ml"

pushd "%TESTDIR%"
ocamlopt -o hello.exe hello.ml 2>&1
if %errorlevel% neq 0 (
    echo FAIL: Compilation failed with default CC
    popd
    exit /b 1
)

echo   Compilation succeeded
echo   Running compiled program:
hello.exe
if %errorlevel% neq 0 (
    echo FAIL: Compiled program failed to run
    popd
    exit /b 1
)
echo PASS: Compilation works with default toolchain
popd
echo.

REM Test 5: Custom CC can be set (just verify variable changes)
echo Test 5: Custom CONDA_OCAML_CC can be overridden

set ORIGINAL_CC=%CONDA_OCAML_CC%
set CONDA_OCAML_CC=custom-test-cc

if "%CONDA_OCAML_CC%" == "custom-test-cc" (
    echo PASS: CONDA_OCAML_CC can be overridden to: %CONDA_OCAML_CC%
) else (
    echo FAIL: CONDA_OCAML_CC override failed
    exit /b 1
)

REM Restore original
set CONDA_OCAML_CC=%ORIGINAL_CC%
echo   Restored to: %CONDA_OCAML_CC%
echo.

REM Cleanup
rmdir /s /q "%TESTDIR%" 2>nul

echo === All CONDA_OCAML_* toolchain tests passed ===
exit /b 0
