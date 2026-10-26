# Unit: Configure and build
# Runs CMake configure and Ninja build with timing and metrics.
# Native output streaming, logging and failure reporting live in native.ps1.

function Configure-Build {
    param(
        [string]$Cmake,
        [string]$Preset,
        [string]$BuildDir,
        [string]$Config,
        [string]$Target,
        [switch]$UnityTestLibslic3r,
        [int]$MaxJobs
    )
    Write-Host ""

    $configureLog = New-BuildLogPath "configure"
    $buildLog = New-BuildLogPath "build"

    $configureStarted = Get-Date
    $configureArgs = @("--preset", $Preset)
    if ($UnityTestLibslic3r) { $configureArgs += "-DSLIC3R_UNITY_BUILD=ON" }
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