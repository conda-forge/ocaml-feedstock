@echo off
REM Test dune project build for ocaml-devel metapackage
REM Verifies that the full development toolchain works together
setlocal enabledelayedexpansion

echo === Test: Dune Project Build ===
echo.

REM Create temporary project directory
set TESTDIR=%TEMP%\ocaml-dune-test-%RANDOM%
mkdir "%TESTDIR%"
cd /d "%TESTDIR%"

echo Creating test dune project...

REM Create dune-project file
(
echo ^(lang dune 3.0^)
echo ^(name hello_dune^)
) > dune-project

REM Create dune file
(
echo ^(executable
echo  ^(name hello^)
echo  ^(public_name hello_dune^)^)
) > dune

REM Create hello.ml
(
echo let ^(^) =
echo   print_endline "Hello from dune-built OCaml!";
echo   Printf.printf "OCaml version: %%s\n" Sys.ocaml_version
) > hello.ml

echo Project structure:
dir

echo.
echo Building with dune...
dune build
if %errorlevel% neq 0 (
    echo FAIL: dune build failed
    cd /d %TEMP%
    rmdir /s /q "%TESTDIR%" 2>nul
    exit /b 1
)

echo.
echo Running built executable...
dune exec ./hello.exe
if %errorlevel% neq 0 (
    echo FAIL: dune exec failed
    cd /d %TEMP%
    rmdir /s /q "%TESTDIR%" 2>nul
    exit /b 1
)

echo.
echo Testing dune clean...
dune clean

echo.
echo === Dune project build test PASSED ===

REM Cleanup
cd /d %TEMP%
rmdir /s /q "%TESTDIR%" 2>nul

exit /b 0
