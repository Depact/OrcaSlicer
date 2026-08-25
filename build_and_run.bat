@echo off
REM Incrementally build OrcaSlicer (Ninja) and launch it with the template test file.
REM Usage: build_and_run.bat   (optionally pass another .3mf path as %1)
setlocal EnableDelayedExpansion

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

REM Close any running instance - it locks OrcaSlicer.dll and would block the link.
taskkill /IM orca-slicer.exe /F >nul 2>&1

REM Wait until the old instance is fully gone (releases the DLL / single-instance mutex).
REM Bounded loop - never wait forever.
set /a wait_sec = 0
:waitkill
tasklist /FI "IMAGENAME eq orca-slicer.exe" 2>nul | find /I "orca-slicer.exe" >nul
if not errorlevel 1 (
    if !wait_sec! GEQ 15 (
        echo Old OrcaSlicer instance did not exit; aborting.
        exit /b 1
    )
    set /a wait_sec += 1
    timeout /t 1 /nobreak >nul
    goto :waitkill
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

REM Launch the app (with the test file when it exists). orca-slicer.exe is a console
REM subsystem binary, so "start" would block the script until the app closes; PowerShell
REM Start-Process detaches it and returns immediately.
if exist "%TEST_FILE%" (
    powershell -NoProfile -Command "Start-Process -FilePath '%EXE%' -ArgumentList '%TEST_FILE%'"
) else (
    powershell -NoProfile -Command "Start-Process -FilePath '%EXE%'"
)
exit /b 0
