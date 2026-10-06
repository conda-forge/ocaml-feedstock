@echo off
REM Test OCaml compilation capabilities on non-unix
REM Exercises bytecode and native compilation

setlocal enabledelayedexpansion

set VERSION=%1
if "%VERSION%"=="" (
    echo Usage: %0 ^<version^>
    exit /b 1
)

set MODE=%2
if "%MODE%"=="" set MODE=native

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
if /i "%MODE%"=="bytecode" goto :no_native_compilation
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
goto :native_compilation_done
:no_native_compilation
echo === Skipping native compilation - no native backend on this target ===
:native_compilation_done

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
ocamlrun multi.exe | findstr /C:"From Lib" >nul
if errorlevel 1 (
    echo   bytecode multi-file execution: FAILED
    exit /b 1
)
echo   bytecode multi-file: OK
del multi.exe

if /i "%MODE%"=="bytecode" goto :no_native_multifile
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
goto :native_multifile_done
:no_native_multifile
echo   native multi-file: SKIPPED (no native backend on this target)
:native_multifile_done

REM 5. Bytecode toplevel loading C-stub libraries, and custom/complete-exe linking
REM Each step is bounded by run-with-timeout.ps1 so a hang fails fast instead of stalling CI
set "RWT=powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-with-timeout.ps1""
echo === Testing toplevel with C stub libraries and custom linking ===

echo let () = print_endline (if Str.string_match (Str.regexp "a+") "aaa" 0 then "str ok" else "str bad")> str_t.ml
set /a STUB_FAILS=0
set "STUB_LIST="

REM FLEXDLL_RELOCATE=0: initer skips relocation but runs the CRT DLL entry; isolates CRT/DllMain init
echo   LoadLibrary dllcamlstrbyt.dll...
set "FLEXDLL_RELOCATE=0"
for /f "delims=" %%i in ('ocamlc -where') do set "OCAMLWHERE=%%i"
set "STR_DLL=!OCAMLWHERE!\stublibs\dllcamlstrbyt.dll"
echo   dll: !STR_DLL!
set "T_OK=1"
if not exist "!STR_DLL!" (
    dir /b "!OCAMLWHERE!\stublibs"
    set "T_OK=0"
) else (
    %RWT% 120 powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0load-dll.ps1" "!STR_DLL!" > t_out.txt 2>&1
    if not "!errorlevel!"=="0" set "T_OK=0"
    type t_out.txt
    findstr /C:"load ok" t_out.txt >nul
    if errorlevel 1 set "T_OK=0"
)
if "%T_OK%"=="0" (
    echo   LoadLibrary dllcamlstrbyt.dll: FAILED
    set /a STUB_FAILS+=1
    set "STUB_LIST=!STUB_LIST! LoadLibrary-dllcamlstrbyt"
) else (
    echo   LoadLibrary dllcamlstrbyt.dll: OK
)
set "FLEXDLL_RELOCATE="

REM ocamlrun dlopen of dllcamlstr outside the toplevel: isolates whether the hang needs the toplevel
echo   bytecode exe with str.cma...
del str_t.byte.exe 2>nul
set "T_OK=1"
ocamlc -I +str str.cma str_t.ml -o str_t.byte.exe
if errorlevel 1 (
    set "T_OK=0"
) else (
    %RWT% 120 ocamlrun str_t.byte.exe > t_out.txt 2>&1
    if not "!errorlevel!"=="0" set "T_OK=0"
    type t_out.txt
    findstr /C:"str ok" t_out.txt >nul
    if errorlevel 1 set "T_OK=0"
)
if "%T_OK%"=="0" (
    echo   bytecode exe str.cma: FAILED
    set /a STUB_FAILS+=1
    set "STUB_LIST=!STUB_LIST! str.cma-bytecode-exe"
) else (
    echo   bytecode exe str.cma: OK
)

echo   ocaml with str.cma...
%RWT% 120 ocaml -I +str str.cma str_t.ml > t_out.txt 2>&1
set "T_RC=%errorlevel%"
type t_out.txt
set "T_OK=1"
if not "%T_RC%"=="0" set "T_OK=0"
findstr /C:"str ok" t_out.txt >nul
if errorlevel 1 set "T_OK=0"
if "%T_OK%"=="0" (
    echo   str.cma toplevel: FAILED
    set /a STUB_FAILS+=1
    set "STUB_LIST=!STUB_LIST! str.cma-toplevel"
) else (
    echo   str.cma toplevel: OK
)

echo let () = Printf.printf "unix ok %%b\n" (Unix.getpid () ^> 0)> unix_t.ml
echo   ocaml with unix.cma...
%RWT% 120 ocaml -I +unix unix.cma unix_t.ml > t_out.txt 2>&1
set "T_RC=%errorlevel%"
type t_out.txt
set "T_OK=1"
if not "%T_RC%"=="0" set "T_OK=0"
findstr /C:"unix ok true" t_out.txt >nul
if errorlevel 1 set "T_OK=0"
if "%T_OK%"=="0" (
    echo   unix.cma toplevel: FAILED
    set /a STUB_FAILS+=1
    set "STUB_LIST=!STUB_LIST! unix.cma-toplevel"
) else (
    echo   unix.cma toplevel: OK
)

echo let () = let pid = Unix.create_process "ocamlc" [^|"ocamlc"; "-version"^|] Unix.stdin Unix.stdout Unix.stderr in match Unix.waitpid [] pid with (_, Unix.WEXITED n) -^> exit n ^| _ -^> exit (1)> spawn_t.ml
echo   ocaml spawning ocamlc...
%RWT% 120 ocaml -I +unix unix.cma spawn_t.ml > t_out.txt 2>&1
set "T_RC=%errorlevel%"
type t_out.txt
if not "%T_RC%"=="0" (
    echo   spawn ocamlc: FAILED
    set /a STUB_FAILS+=1
    set "STUB_LIST=!STUB_LIST! spawn-ocamlc"
) else (
    echo   spawn ocamlc: OK
)

echo   ocamlc -custom...
set "T_OK=1"
del hello_custom.exe 2>nul
%RWT% 300 ocamlc -custom -o hello_custom.exe hi.ml
if errorlevel 1 set "T_OK=0"
if "%T_OK%"=="1" (
    %RWT% 300 .\hello_custom.exe > t_out.txt 2>&1
    findstr /C:"Hello World" t_out.txt >nul
    if errorlevel 1 set "T_OK=0"
)
if "%T_OK%"=="0" (
    echo   ocamlc -custom: FAILED
    set /a STUB_FAILS+=1
    set "STUB_LIST=!STUB_LIST! ocamlc--custom"
) else (
    echo   ocamlc -custom: OK
)

echo   ocamlc -output-complete-exe...
set "T_OK=1"
del hello_complete.exe 2>nul
%RWT% 300 ocamlc -output-complete-exe -o hello_complete.exe hi.ml
if errorlevel 1 set "T_OK=0"
if "%T_OK%"=="1" (
    %RWT% 300 .\hello_complete.exe > t_out.txt 2>&1
    findstr /C:"Hello World" t_out.txt >nul
    if errorlevel 1 set "T_OK=0"
)
if "%T_OK%"=="0" (
    echo   ocamlc -output-complete-exe: FAILED
    set /a STUB_FAILS+=1
    set "STUB_LIST=!STUB_LIST! ocamlc--output-complete-exe"
) else (
    echo   ocamlc -output-complete-exe: OK
)

REM User C stubs compiled by ocamlc must see the UNICODE defines (dune spawn_stubs.c relies on them).
REM win-64 keeps upstream cppflags (no UNICODE), so this test is aarch64-only; the target comes from ocamlc -config.
ocamlc -config > cfg_out.txt 2>&1
findstr /B /C:"target:" cfg_out.txt | findstr /I /C:"aarch64" >nul
if errorlevel 1 (
    echo   ocamlc -c TCHAR stub: SKIPPED ^(win-64 keeps upstream cppflags^)
) else (
    echo   ocamlc -c TCHAR stub...
    > tstub.c echo #include ^<windows.h^>
    >> tstub.c echo int tstub_probe^(WCHAR *cmd^) {
    >> tstub.c echo   TCHAR buf[MAX_PATH];
    >> tstub.c echo   STARTUPINFO si; PROCESS_INFORMATION pi;
    >> tstub.c echo   GetModuleFileName^(NULL, buf, MAX_PATH^);
    >> tstub.c echo   return CreateProcess^(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, ^&si, ^&pi^) ? 1 : 0;
    >> tstub.c echo }
    set "T_OK=1"
    del tstub.obj tstub.o 2>nul
    %RWT% 300 ocamlc -c tstub.c > t_out.txt 2>&1
    if errorlevel 1 set "T_OK=0"
    type t_out.txt
    findstr /B /C:"ocamlc_cppflags:" cfg_out.txt | findstr /C:"-DUNICODE" >nul
    if errorlevel 1 (
        findstr /B /C:"ocamlc_cppflags:" cfg_out.txt
        set "T_OK=0"
    )
    if "!T_OK!"=="0" (
        echo   ocamlc -c TCHAR stub: FAILED
        set /a STUB_FAILS+=1
        set "STUB_LIST=!STUB_LIST! ocamlc--c-tchar-stub"
    ) else (
        echo   ocamlc -c TCHAR stub: OK
    )
)

REM A stub with a stack frame over 4 KB calls __chkstk, which flexlink must resolve from an archive it is given
echo   ocamlc -output-complete-exe __chkstk...
> bigstub.c echo #include ^<caml/mlvalues.h^>
>> bigstub.c echo value big_probe(value u){ volatile char buf[8192]; buf[0]=1; buf[8191]=2; return Val_int(buf[0]+buf[8191]); }
> bigmain.ml echo external big_probe : unit -^> int = "big_probe"
>> bigmain.ml echo let () = Printf.printf "big ok %%d\n" (big_probe ())
set "T_OK=1"
del bigtest.exe 2>nul
%RWT% 300 ocamlc -output-complete-exe -o bigtest.exe bigstub.c bigmain.ml
if errorlevel 1 set "T_OK=0"
if "%T_OK%"=="1" (
    %RWT% 300 .\bigtest.exe > t_out.txt 2>&1
    findstr /C:"big ok 3" t_out.txt >nul
    if errorlevel 1 set "T_OK=0"
)
if "%T_OK%"=="0" (
    echo   ocamlc -output-complete-exe __chkstk: FAILED
    set /a STUB_FAILS+=1
    set "STUB_LIST=!STUB_LIST! ocamlc--output-complete-exe-chkstk"
) else (
    echo   ocamlc -output-complete-exe __chkstk: OK
)

if not "%STUB_FAILS%"=="0" (
    echo === %STUB_FAILS% stub/custom-link test^(s^) FAILED:%STUB_LIST% ===
    exit /b 1
)

REM Cleanup
del hi.ml lib.ml lib.cmi lib.cmo lib.cmx lib.obj main.ml main.cmi main.cmo main.cmx main.obj multi.exe 2>nul
del str_t.ml str_t.cmi str_t.cmo str_t.byte.exe unix_t.ml unix_t.cmi unix_t.cmo spawn_t.ml spawn_t.cmi spawn_t.cmo hello_custom.exe hello_complete.exe t_out.txt tstub.c tstub.obj tstub.o cfg_out.txt 2>nul
del bigstub.c bigstub.obj bigstub.o bigmain.ml bigmain.cmi bigmain.cmo bigmain.cmx bigmain.obj bigtest.exe 2>nul

echo === All compilation tests passed ===
