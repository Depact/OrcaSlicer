@echo off
REM Incrementally build OrcaSlicer (Ninja) and launch it with the template test file.
REM Usage: build_and_run.bat   (optionally pass another .3mf path as %1)
setlocal

set "ROOT=%~dp0"
set "BUILD_DIR=%ROOT%build"
set "CMAKE=C:\Users\Paul\tools\cmake-3.31.6-windows-x86_64\bin\cmake.exe"
set "EXE=%BUILD_DIR%\src\orca-slicer.exe"

REM Optional: override the file to open on the command line.
if not "%~1"=="" (
    set "TEST_FILE=%~1"
) else (
    set "TEST_FILE=D:\Files\Drawing\2026\08\24.08.26 Template test.3mf"
)

REM If OrcaSlicer is already running, do not kill it - ask the user to close it first.
REM (It locks OrcaSlicer.dll, so the build cannot relink it while it is open.)
tasklist /FI "IMAGENAME eq orca-slicer.exe" 2>nul | find /I "orca-slicer.exe" >nul
if not errorlevel 1 (
    echo OrcaSlicer is already running. Close it first, then run build_and_run again.
    exit /b 1
)

REM Load the MSVC environment (cl, link, ...).
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
    echo vcvars64.bat failed.
    exit /b 1
)

REM Incremental build.
"%CMAKE%" --build "%BUILD_DIR%" --target OrcaSlicer_app_gui -- -j 6
if errorlevel 1 (
    echo BUILD FAILED
    exit /b 1
)

if not exist "%EXE%" (
    echo App not found: %EXE%
    exit /b 1
)

REM Launch the app (with the test file when it exists).
if exist "%TEST_FILE%" (
    start "" "%EXE%" "%TEST_FILE%"
) else (
    start "" "%EXE%"
)
exit /b 0
