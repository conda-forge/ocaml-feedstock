@echo off
REM Test OCaml tool versions on non-unix
REM Verifies all tools report correct version

setlocal enabledelayedexpansion

set VERSION=%1
if "%VERSION%"=="" (
    echo Usage: %0 ^<version^>
    exit /b 1
)

echo === OCaml Tool Version Tests (expecting %VERSION%) ===

echo Testing core tools...
echo   ocamlc:
ocamlc -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1
echo   ocamldep:
ocamldep -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1
echo   ocamllex:
ocamllex -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1
echo   ocamlrun:
ocamlrun -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1
echo   ocamlyacc:
ocamlyacc -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1

echo Testing interactive tools...
echo   ocaml:
ocaml -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1
echo   ocamlcp:
ocamlcp -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1
echo   ocamlmklib:
ocamlmklib -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1
echo   ocamlmktop:
ocamlmktop -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1
echo   ocamloptp:
ocamloptp -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1
echo   ocamlprof:
ocamlprof -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1

echo Testing native compiler...
echo   ocamlopt:
ocamlopt -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1

echo Testing utility tools...
echo   ocamlobjinfo:
ocamlobjinfo -help >nul 2>&1 && echo     OK || exit /b 1
REM W34 2026-07-29: zig-compiled Windows native builds never produce a
REM literal ocamlobjinfo.opt binary (same "opt variant not produced on
REM zig/Windows" condition as W32/W33). Guard with `where` so this test
REM skips gracefully instead of hard-failing when the .opt binary is
REM absent; plain ocamlobjinfo above already covers the tool's behavior.
echo   ocamlobjinfo.opt:
where ocamlobjinfo.opt >nul 2>&1
if errorlevel 1 (
    echo     SKIP: ocamlobjinfo.opt not present ^(zig+Windows native build^)
) else (
    ocamlobjinfo.opt -help >nul 2>&1 && echo     OK || exit /b 1
)
echo   ocamlcmt:
ocamlcmt -help >nul 2>&1 && echo     OK || exit /b 1
echo   ocamlobjinfo.byte:
ocamlobjinfo.byte -help >nul 2>&1 && echo     OK || exit /b 1

echo === All version tests passed ===
