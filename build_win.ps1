<#
.SYNOPSIS
    Build OrcaSlicer on Windows with clang-cl + Ninja (+ optional ccache).
#>

param(
    [ValidateSet("x64-clang", "x64-clang-cache", "x64-clang-debug")]
    [string]$Preset,
    [string]$Config = "Release",
    [string]$Target,
    [switch]$Clean,
    [switch]$UnityTestLibslic3r,
    [switch]$NoMetrics,
    [switch]$PackDeps,
    [switch]$SkipDeps,
    [ValidateRange(1, 10)]
    [int]$MetricsInterval = 15,
    [ValidateRange(1, 64)]
    [int]$MaxJobs = 0
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$UnitsDir = Join-Path $RepoRoot "scripts\build_win_steps"
$presetDirs = @{
    "x64-clang"       = "build-clang"
    "x64-clang-cache" = "build-clang-cache"
    "x64-clang-debug" = "build-dbg-clang"
}

. (Join-Path $UnitsDir "native.ps1")
. (Join-Path $UnitsDir "toolchain.ps1")
. (Join-Path $UnitsDir "vsenv.ps1")
. (Join-Path $UnitsDir "deps.ps1")
. (Join-Path $UnitsDir "metrics.ps1")
. (Join-Path $UnitsDir "build.ps1")
. (Join-Path $UnitsDir "ccache_stats.ps1")

# Load the OrcaBuildMetrics module so Show-BuildMetrics can render without Python/rich.
. (Join-Path $RepoRoot "scripts\OrcaBuildMetrics\private\OrcaBuildMetrics-Helpers.ps1")
. (Join-Path $RepoRoot "scripts\OrcaBuildMetrics\public\Show-OrcaBuildMetrics.ps1")


$started = Get-Date
$global:BuildStarted = $started
$metricsJob = $null
$metricsCsv = $null

$configureStr = "-"
$buildStr     = "-"
$totalStr     = "-"
$buildSucceeded = $false

Push-Location $RepoRoot

try {
    function Get-TimeStamp {
        $span = (Get-Date) - $global:BuildStarted
        $h = [math]::Floor($span.TotalHours); $m = [math]::Floor($span.TotalMinutes) % 60; $s = [math]::Round($span.Seconds)
        return "{0}h{1}m{2}s" -f $h, $m, $s
    }

    function Write-Step {
        param([string]$Text)
        $ts = Get-TimeStamp
        Write-Host "[$ts] === $Text ===" -ForegroundColor Cyan
    }

    function Write-Status {
        param(
            [string]$Tag,
            [string]$Text,
            [string]$Color = "DarkGray"
        )
        Write-Host ("  {0,-9} {1}" -f "[$Tag]", $Text) -ForegroundColor $Color
    }

    function Show-BuildMetrics {
        param([string]$CsvPath, [string]$Preset, [string]$Config)
        if (-not $CsvPath -or -not (Test-Path $CsvPath)) { return }
        Write-Host ""
        $code = Show-OrcaBuildMetrics -CsvPath $CsvPath `
            -Title "OrcaSlicer build ($Preset, $Config)"
        Write-Host ""
        if ($code -ne 0) {
            Write-Status "metrics" "Could not render chart (exit $code)." "Yellow"
        }
    }

    $fmt = {
        param($t)
        $h = [math]::Floor($t.TotalHours)
        $m = [math]::Floor($t.TotalMinutes) % 60
        $s = [math]::Round($t.Seconds)
        if ($h) { "{0}h {1:00}m {2:00}s" -f $h, $m, $s }
        elseif ($m) { "{0}m {1:00}s" -f $m, $s }
        else { "{0}s" -f $s }
    }

    # --- 1. Locate Visual Studio and the toolchain ---
    Write-Step "[1/6] Locating Visual Studio and tools..."

    $vsInstall = Find-VsInstall
    if (-not $vsInstall) {
        throw "Visual Studio 2022 or newer with the C++ toolset was not found. Install the 'Desktop development with C++' workload."
    }
    Write-Status "vs"      $vsInstall

    $clangCl = $null
    if ($env:ORCA_CLANG_CL) {
        if (-not (Test-Path $env:ORCA_CLANG_CL)) { throw "ORCA_CLANG_CL points at '$env:ORCA_CLANG_CL', which does not exist." }
        $clangCl = (Resolve-Path $env:ORCA_CLANG_CL).Path
    } else {
        $clangCmd = Get-Command clang-cl -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($clangCmd) {
            $clangCl = $clangCmd.Source
        } else {
            $vsClang = Join-Path $vsInstall "VC\Tools\Llvm\x64\bin\clang-cl.exe"
            if (Test-Path $vsClang) { $clangCl = $vsClang }
        }
    }
    if (-not $clangCl) {
        throw "clang-cl was not found. Install LLVM and add it to PATH, set ORCA_CLANG_CL, or install the C++ Clang tools for Windows component in Visual Studio."
    }

    $cmake = Resolve-Tool "cmake" "ORCA_CMAKE" "Install CMake 3.21 or newer and add it to PATH, or set ORCA_CMAKE."
    $ninja = Resolve-Tool "ninja" "ORCA_NINJA" "Install Ninja and add it to PATH, or set ORCA_NINJA."
    $ccache = $null
    if ($env:ORCA_CCACHE) {
        if (-not (Test-Path $env:ORCA_CCACHE)) { throw "ORCA_CCACHE points at '$env:ORCA_CCACHE', which does not exist." }
        $ccache = (Resolve-Path $env:ORCA_CCACHE).Path
    } else {
        $ccacheCmd = Get-Command ccache -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ccacheCmd) { $ccache = $ccacheCmd.Source }
    }

    $cmakeVersion = (& $cmake --version | Select-Object -First 1)
    if ($cmakeVersion -match "cmake version (\d+)\.(\d+)") {
        if ([int]$Matches[1] -lt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -lt 21)) {
            throw "CMake 3.21 or newer is required, found: $cmakeVersion"
        }
    }

    Write-Status "clang-cl" $clangCl
    Write-Status "cmake"    $cmake
    Write-Status "ninja"    $ninja
    if ($ccache) { Write-Status "ccache" $ccache }

    # --- 2. Choose preset/target ---
    Write-Step "[2/6] Determining build configuration..."
    if ($UnityTestLibslic3r) {
        $Preset = "x64-clang-cache"
        if (-not $Target) { $Target = "libslic3r" }
    } elseif (-not $Preset) {
        # Only use the cache preset when ccache is available AND its dependency
        # tree is actually complete. Otherwise fall back to the plain clang build
        # so a no-argument run just works.
        $cacheManifest = Test-Path "deps\build-clang-cache\.deps-manifest"
        $cachePrefix   = Test-Path "deps\build-clang-cache\OrcaSlicer_dep\usr\local"
        $cacheStamps   = (Get-ChildItem "deps\build-clang-cache" -Filter "*-complete" -Name).Count -gt 0
        $cacheDepsReady = $cacheManifest -and $cachePrefix -and $cacheStamps
        if ((Test-Path "build-clang-cache" -PathType Container) -and $ccache -and $cacheDepsReady) {
            $Preset = "x64-clang-cache"
        } else {
            $Preset = "x64-clang"
        }
    }
    if (-not $Target) { $Target = "all" }
    $buildDir = $presetDirs[$Preset]

    if ($Preset -eq "x64-clang-cache" -and -not $PSBoundParameters.ContainsKey("MetricsInterval")) {
        $MetricsInterval = 3
    }

    Write-Status "preset"  "$Preset ($buildDir)"
    Write-Status "target"  "$Target ($Config)"
    Write-Status "jobs"    ($(if ($MaxJobs -gt 0) { "$MaxJobs" } else { "auto" }))
    if ($Preset -eq "x64-clang-cache" -and -not $ccache) {
        throw "ccache is required for the x64-clang-cache preset. Install it, add it to PATH, or set ORCA_CCACHE."
    }

    # --- 3. Capture the Visual Studio environment ---
    Write-Step "[3/6] Setting up the Visual Studio environment..."
    Capture-VsEnvironment -VsInstall $vsInstall

    $toolDirs = @($clangCl, $cmake, $ninja, $ccache) |
        Where-Object { $_ } |
        ForEach-Object { Split-Path -Parent $_ } |
        Select-Object -Unique
    $env:PATH = ($toolDirs -join ";") + ";" + $env:PATH
    Write-Status "env" "VS x64 environment captured, tool dirs prepended to PATH"

    # --- 4. Start metrics monitor ---
    if (-not $NoMetrics) {
        Write-Step "[4/6] Starting build-process resource monitor..."
        $metricsCsv = Join-Path $env:TEMP "orca-build-metrics-$PID.csv"
        Remove-Item $metricsCsv -ErrorAction SilentlyContinue
        Write-Status "sampler" "Every ${MetricsInterval}s (polling every 2s)"
        try {
            $metricsJob = Start-BuildMonitor -CsvPath $metricsCsv -IntervalSeconds $MetricsInterval
            Write-Status "sampler" "Job started (id $($metricsJob.Id))" "DarkGray"
        } catch {
            Write-Status "sampler" "Unavailable: $($_.Exception.Message)" "Yellow"
            $metricsJob = $null
        }
    } else {
        Write-Step "[4/6] Resource monitoring disabled (-NoMetrics)"
    }

    # --- 5. Ensure dependencies are built ---
    if ($SkipDeps) {
        Write-Step "[5/6] Skipping dependencies (-SkipDeps)"
    } else {
        Write-Step "[5/6] Checking dependencies..."
        $depsBuildDir = if ($Preset -eq "x64-clang-cache") { "deps/build-clang-cache" } else { "deps/build-clang" }
        Check-Dependencies -Cmake $cmake -ClangCl $clangCl -Config $Config -DepsBuildDir $depsBuildDir

        if ($PackDeps) {
            Write-Step "[5.1/6] Packing dependencies..."
            $zipPath = Pack-Dependencies -DepsBuildDir $depsBuildDir -OutputPath (Join-Path $RepoRoot "deps\OrcaSlicer_dep.zip")
            Write-Host ""
            $python = Get-Python
            if ($python) {
                & $python.Source -c '
from rich.console import Console
from rich.rule import Rule
import sys
console = Console()
console.print(Rule("Dependencies packed successfully", style="green"))
console.print("Archive: " + sys.argv[1], style="green")
console.print(Rule(char="\u2501", style="green"))
' $zipPath
            } else {
                Write-Host "==========================================" -ForegroundColor Green
                Write-Host "  Dependencies packed successfully!"      -ForegroundColor Green
                Write-Host "  Archive: $zipPath"
                Write-Host "==========================================" -ForegroundColor Green
            }
            return
        }
    }

    if ($Clean) {
        foreach ($d in @("deps\build-clang", "deps\build-clang-cache")) {
            if (Test-Path $d) {
                Write-Status "clean" "Removing $d"
                Remove-Item $d -Recurse -Force
            }
        }
        if (Test-Path $buildDir) {
            Write-Status "clean" "Removing $buildDir"
            Remove-Item $buildDir -Recurse -Force
        }
    }

    # --- 6. Configure and build ---
    Write-Step "[6/6] Configuring and building..."
    $generator = "Ninja Multi-Config"
    $compiler = $null
    if ($Preset -in @("x64-clang", "x64-clang-cache", "x64-clang-debug")) {
        $compiler = $clangCl
    }
    $cmakeArgs = @()
    if ($Preset -eq "x64-clang-cache") { $cmakeArgs += "-DSLIC3R_UNITY_BUILD=ON" }
    $timing = Configure-Build -Cmake $cmake -BuildDir $buildDir -Config $Config -Target $Target `
                              -UnityTest:$UnityTestLibslic3r -MaxJobs $MaxJobs `
                              -Generator $generator -Compiler $compiler -CMakeArgs $cmakeArgs

    # --- 7. Ccache statistics ---
    Show-CcacheStats -Ccache $ccache -NoMetrics:$NoMetrics

    # --- 8. Resource chart ---
    if ($metricsJob) {
        Stop-Job   $metricsJob -ErrorAction SilentlyContinue
        Remove-Job $metricsJob -Force -ErrorAction SilentlyContinue
        $metricsJob = $null
    }
    Show-BuildMetrics -CsvPath $metricsCsv -Preset $Preset -Config $Config

    # --- 9. Success summary ---
    $total = $timing.ConfigureTime + $timing.BuildTime
    $configureStr = & $fmt $timing.ConfigureTime
    $buildStr     = & $fmt $timing.BuildTime
    $totalStr     = & $fmt $total

    Write-Host "==========================================" -ForegroundColor Green
    if ($UnityTestLibslic3r) {
        Write-Host "  Unity build test PASSED (libslic3r)" -ForegroundColor Green
    } else {
        Write-Host "  Build complete!" -ForegroundColor Green
    }
    Write-Host ""

    Write-Host ("  Total:     {0}" -f $totalStr)
    Write-Host ("  Configure: {0}" -f $configureStr)
    Write-Host ("  Build:     {0}" -f $buildStr)
    Write-Host "==========================================" -ForegroundColor Green

    $buildSucceeded = $true
} catch {
    if ($metricsJob) {
        Stop-Job   $metricsJob -ErrorAction SilentlyContinue
        Remove-Job $metricsJob -Force -ErrorAction SilentlyContinue
        $metricsJob = $null
    }
    Show-BuildMetrics -CsvPath $metricsCsv -Preset $Preset -Config $Config

    Write-Host ""
    Write-Host "BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }
    exit 1
} finally {
    if ($metricsJob) {
        Stop-Job   $metricsJob -ErrorAction SilentlyContinue
        Remove-Job $metricsJob -Force -ErrorAction SilentlyContinue
        $metricsJob = $null
    }
    Pop-Location
}

exit 0