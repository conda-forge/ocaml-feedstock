@echo off
REM Test OCaml tool versions on non-unix
REM Verifies all tools report correct version

setlocal enabledelayedexpansion

set VERSION=%1
if "%VERSION%"=="" (
    echo Usage: %0 ^<version^>
    exit /b 1
)

set MODE=%2
if "%MODE%"=="" set MODE=native

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
if /i "%MODE%"=="bytecode" goto :no_native_optp
echo   ocamloptp:
ocamloptp -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1
goto :native_optp_done
:no_native_optp
echo   ocamloptp: SKIPPED (no native backend on this target)
:native_optp_done
echo   ocamlprof:
ocamlprof -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1

if /i "%MODE%"=="bytecode" goto :no_native_compiler
echo Testing native compiler...
echo   ocamlopt:
ocamlopt -version | findstr /C:"%VERSION%" >nul && echo     OK || exit /b 1
goto :native_compiler_done
:no_native_compiler
echo Skipping native compiler checks - no native backend on this target
:native_compiler_done

echo Testing utility tools...
echo   ocamlobjinfo:
ocamlobjinfo -help >nul 2>&1 && echo     OK || exit /b 1
if /i "%MODE%"=="bytecode" goto :no_native_objinfo
echo   ocamlobjinfo.opt:
ocamlobjinfo.opt -help >nul 2>&1 && echo     OK || exit /b 1
goto :native_objinfo_done
:no_native_objinfo
echo   ocamlobjinfo.opt: SKIPPED (no native backend on this target)
:native_objinfo_done
echo   ocamlcmt:
ocamlcmt -help >nul 2>&1 && echo     OK || exit /b 1
echo   ocamlobjinfo.byte:
ocamlobjinfo.byte -help >nul 2>&1 && echo     OK || exit /b 1

echo === All version tests passed ===
