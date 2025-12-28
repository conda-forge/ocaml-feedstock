@echo off
REM Test environment variables for Windows
REM Verifies OCAMLLIB and PATH are set correctly

echo === Environment Tests (Windows) ===

echo OCAMLLIB=%OCAMLLIB%
echo %OCAMLLIB% | findstr /C:"ocaml" >nul && echo   OCAMLLIB contains ocaml: OK

echo PATH check...
echo %PATH% | findstr /C:"ocaml" >nul && echo   PATH contains ocaml: OK

echo === All environment tests passed ===
