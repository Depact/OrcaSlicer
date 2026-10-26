# Unit: Visual Studio environment
# Captures the VS devcmd environment into the current PowerShell process.

function Capture-VsEnvironment {
    param([string]$VsInstall)
    $vcvarsall = Join-Path $VsInstall "VC\Auxiliary\Build\vcvarsall.bat"
    $tempBat = Join-Path $env:TEMP "orca-vcvars-$PID.bat"
    $tempEnv = Join-Path $env:TEMP "orca-vcvars-$PID.txt"
    try {
        $body = "@echo off`r\ncall `"$vcvarsall`" x64 >nul 2>&1`r\nset > `"$tempEnv`" 2>&1`r\n"
        [IO.File]::WriteAllText($tempBat, $body, [Text.Encoding]::ASCII)
        & cmd.exe /d /c "call `"$tempBat`""
        if (-not (Test-Path $tempEnv)) {
            throw "vcvarsall.bat did not produce an environment file. Run '`"$vcvarsall`" x64' to see the error."
        }
        Get-Content $tempEnv | ForEach-Object {
            if ($_ -match "^([^=]+)=(.*)$") {
                [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
            }
        }
        # vcvarsall prints a benign VsDevCmd error and can still end up with an
        # x86-only LIB. Catch that here instead of at link time, where it shows
        # up as a baffling "machine type x86 conflicts with x64" error.
        if (-not $env:LIB -or $env:LIB -notmatch '(?i)\\x64') {
            # Try to find and set the x64 library paths manually
            $msvcVersion = Get-ChildItem "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC" | Sort-Object Name -Descending | Select-Object -First 1
            if ($msvcVersion) {
                $msvcLibPath = Join-Path $msvcVersion.FullName "lib\x64"
                if (Test-Path $msvcLibPath) {
                    $ucrtPath = (Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\Lib" | Sort-Object Name -Descending | Select-Object -First 1).FullName
                    $ucrtLibPath = Join-Path $ucrtPath "ucrt\x64"
                    $umLibPath = Join-Path $ucrtPath "um\x64"
                    $libPaths = @($msvcLibPath)
                    if (Test-Path $ucrtLibPath) { $libPaths += $ucrtLibPath }
                    if (Test-Path $umLibPath) { $libPaths += $umLibPath }
                    $env:LIB = ($libPaths -join ";") + ";" + ($env:LIB)
                }
            }
            if (-not $env:LIB -or $env:LIB -notmatch '(?i)\\x64') {
                throw "The Visual Studio environment has no x64 library path in LIB. Running '`"$vcvarsall`" x64' directly may show the cause."
            }
        }
    } finally {
        Remove-Item $tempBat, $tempEnv -ErrorAction SilentlyContinue
    }
}