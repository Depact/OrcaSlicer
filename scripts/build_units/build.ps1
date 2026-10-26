# Unit: Configure and build
# Runs CMake configure and Ninja build with timing and metrics.
# Native output streaming, logging and failure reporting live in native.ps1.

function Configure-Build {
    param(
        [string]$Cmake,
        [string]$BuildDir,
        [string]$Config,
        [string]$Target,
        [switch]$UnityTestLibslic3r,
        [int]$MaxJobs,
        [string]$Generator = "Ninja Multi-Config",
        [string]$Compiler,
        [string[]]$CMakeArgs
    )
    Write-Host ""

    $configureLog = New-BuildLogPath "configure"
    $buildLog = New-BuildLogPath "build"

    $configureStarted = Get-Date
    # Remove CMakeCache.txt to force fresh configure (avoids "variables changed" error on preset/compiler change)
    $cmakeCache = Join-Path $BuildDir "CMakeCache.txt"
    if (Test-Path $cmakeCache) {
        Remove-Item $cmakeCache -Force -ErrorAction SilentlyContinue
    }
    $configureArgs = @("-S", (Get-Location).Path, "-B", $BuildDir, "-G", $Generator)
    if ($Compiler) {
        $configureArgs += "-DCMAKE_C_COMPILER=$Compiler"
        $configureArgs += "-DCMAKE_CXX_COMPILER=$Compiler"
    }
    if ($UnityTestLibslic3r) { $configureArgs += "-DSLIC3R_UNITY_BUILD=ON" }
    if ($CMakeArgs) { $configureArgs += $CMakeArgs }
    $configureArgs += "-DCMAKE_BUILD_TYPE=$Config"
    
    $ts = Get-TimeStamp
    Write-Host "[$ts] >>> $cmake $($configureArgs -join ' ')"
    Invoke-BuildStep -Label "CMake configure" -LogPath $configureLog -Command $Cmake -Arguments $configureArgs
    $configureTime = (Get-Date) - $configureStarted

    Write-Host ""
    $buildStarted = Get-Date
    $ts = Get-TimeStamp
    $buildArgs = @("--build", $BuildDir, "--config", $Config, "--target", $Target)
    if ($MaxJobs -gt 0) { $buildArgs += @("--", "-j", "$MaxJobs") }
    Write-Host "[$ts] >>> $cmake $($buildArgs -join ' ')"
    Invoke-BuildStep -Label "Build" -LogPath $buildLog -Command $Cmake -Arguments $buildArgs
    $buildTime = (Get-Date) - $buildStarted

    return @{
        ConfigureTime = $configureTime
        BuildTime     = $buildTime
        BuildLog      = $buildLog
    }
}