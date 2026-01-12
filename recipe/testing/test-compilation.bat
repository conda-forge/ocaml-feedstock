@echo off
REM Test OCaml compilation capabilities on Windows
REM Exercises bytecode and native compilation

setlocal enabledelayedexpansion

set VERSION=%1
if "%VERSION%"=="" (
    echo Usage: %0 ^<version^>
    exit /b 1
)

echo === OCaml Compilation Tests (Windows) ===

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
echo   bytecode compile: OK

echo   executing...
hi.exe | findstr /C:"Hello World" >nul
if errorlevel 1 (
    echo   bytecode execution: FAILED
    exit /b 1
)
echo   bytecode execution: OK
del hi.exe

REM 2. Native compilation + execution
echo === Testing native compilation ===
echo   compiling...
ocamlopt -o hi.exe hi.ml
if errorlevel 1 (
    echo   native compile: FAILED
    exit /b 1
)
echo   native compile: OK

echo   executing...
hi.exe | findstr /C:"Hello World" >nul
if errorlevel 1 (
    echo   native execution: FAILED
    exit /b 1
)
echo   native execution: OK
del hi.exe

REM 3. Bytecode compiler via ocamlrun
echo === Testing bytecode compiler via ocamlrun ===
ocamlrun %OCAML_PREFIX%\bin\ocamlc.byte -version | findstr /C:"%VERSION%" >nul
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
multi.exe | findstr /C:"From Lib" >nul
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
ocamlopt -o multi.exe lib.cmx main.cmx
if errorlevel 1 (
    echo   native link: FAILED
    exit /b 1
)
multi.exe | findstr /C:"From Lib" >nul
if errorlevel 1 (
    echo   native multi-file execution: FAILED
    exit /b 1
)
echo   native multi-file: OK

REM Cleanup
del hi.ml lib.ml lib.cmi lib.cmo lib.cmx lib.obj main.ml main.cmi main.cmo main.cmx main.obj multi.exe 2>nul

echo === All compilation tests passed ===
