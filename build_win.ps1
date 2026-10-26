<#
.SYNOPSIS
    Build OrcaSlicer on Windows with clang-cl + Ninja (+ optional ccache).

.DESCRIPTION
    This is the only sanctioned Windows build entry point. Do not drive CMake
    or Ninja directly: the Visual Studio environment, compiler discovery and
    dependency build are all set up here.

    With no arguments the script picks a build automatically:
      build-clang-cache exists -> incremental x64-clang-cache (ccache)
      otherwise                -> clean x64-clang

    The build processes' CPU, core use and memory are sampled while the build
    runs and rendered as an ASCII chart at the end when Python and rich are
    available.

    Examples:
      .\build_win.ps1
      .\build_win.ps1 -Preset x64-clang-cache -Clean
      .\build_win.ps1 -UnityTest
      .\build_win.ps1 -NoMetrics
      .\build_win.ps1 -MaxJobs 8

.PARAMETER Preset
    CMake configure preset: x64-clang, x64-clang-cache or x64-clang-debug.
    Defaults to the automatic choice described above.

.PARAMETER Config
    Build configuration. Defaults to Release.

.PARAMETER Target
    Build target. Defaults to all, or libslic3r with -UnityTest.

.PARAMETER Clean
    Delete the preset's build directory before configuring.

.PARAMETER UnityTestLibslic3r
    Configure with SLIC3R_UNITY_BUILD=ON and build only libslic3r (quick smoke test).

.PARAMETER NoMetrics
    Skip build-process CPU, core and memory sampling.

.PARAMETER MetricsInterval
    Seconds between reported resource samples. Defaults to 15. The sampler
    itself polls every 2 seconds so short compiler processes are included.
    For cached runs (x64-clang-cache), defaults to 3 seconds.

.PARAMETER MaxJobs
    Max parallel Ninja jobs. Passed as -j to Ninja via CMake. Defaults to
    0 (let Ninja decide, usually logical core count).

.NOTES
    Requires Visual Studio 2022 or newer with the C++ toolset, clang-cl, CMake 3.21+,
    Ninja and ccache on PATH. Individual tools can be overridden with
    ORCA_CLANG_CL, ORCA_CMAKE, ORCA_NINJA and ORCA_CCACHE.
    ccache is only needed for the cache presets. The resource chart needs
    Python 3 with rich; without it the raw CSV path is printed instead.
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
$UnitsDir = Join-Path $RepoRoot "scripts\build_units"
$presetDirs = @{
    "x64-clang"       = "build-clang"
    "x64-clang-cache" = "build-clang-cache"
    "x64-clang-debug" = "build-dbg-clang"
}

# Source all build units so their functions are available in this scope.
. (Join-Path $UnitsDir "native.ps1")
. (Join-Path $UnitsDir "toolchain.ps1")
. (Join-Path $UnitsDir "vsenv.ps1")
. (Join-Path $UnitsDir "deps.ps1")
. (Join-Path $UnitsDir "metrics.ps1")
. (Join-Path $UnitsDir "build.ps1")
. (Join-Path $UnitsDir "ccache_stats.ps1")

$started = Get-Date
$global:BuildStarted = $started
$metricsJob = $null
$metricsCsv = $null
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
        $python = Get-Command py -ErrorAction SilentlyContinue
        if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
        if ($python) {
            & $python "$RepoRoot\scripts\build_units\rich_utils.py" step $ts $Text
        } else {
            Write-Host "[$ts] $Text"
        }
    }

    function Ensure-RichInstalled {
        $python = Get-Command py -ErrorAction SilentlyContinue
        if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
        if ($python) {
            try {
                & $python -c "import rich" -ErrorAction Stop
            } catch {
                Write-Host "  -> Installing 'rich' for enhanced output..." -ForegroundColor Yellow

                & $python -m pip install rich -q
            }
        }
    }

    # --- 1. Locate Visual Studio and the toolchain ---
    Write-Step "[1/5] Locating Visual Studio and tools..."
    Ensure-RichInstalled

    $vsInstall = Find-VsInstall
    if (-not $vsInstall) {
        throw "Visual Studio 2022 or newer with the C++ toolset was not found. Install the 'Desktop development with C++' workload."
    }
    Write-Host "  -> Visual Studio: $vsInstall" -ForegroundColor DarkGray

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

    Write-Host "  -> clang-cl: $clangCl" -ForegroundColor DarkGray
    Write-Host "  -> cmake:    $cmake" -ForegroundColor DarkGray
    if ($ccache) { Write-Host "  -> ccache:   $ccache" -ForegroundColor DarkGray }

    # --- 2. Capture the Visual Studio environment ---
    Write-Step "[2/5] Setting up the Visual Studio environment..."
    Capture-VsEnvironment -VsInstall $vsInstall

    # Put the chosen tools first: VsDevCmd may otherwise expose a different clang.
    $toolDirs = @($clangCl, $cmake, $ninja, $ccache) |
        Where-Object { $_ } |
        ForEach-Object { Split-Path -Parent $_ } |
        Select-Object -Unique
    $env:PATH = ($toolDirs -join ";") + ";" + $env:PATH

    # Start metrics monitoring BEFORE dependency check so we capture full build activity
    if (-not $NoMetrics) {
        $metricsCsv = Join-Path $env:TEMP "orca-build-metrics-$PID.csv"
        Remove-Item $metricsCsv -ErrorAction SilentlyContinue
        Write-Host "  -> Sampling build-process CPU, cores and RAM every ${MetricsInterval}s (2s poll)..." -ForegroundColor DarkGray
        try {
            $metricsJob = Start-BuildMonitor -CsvPath $metricsCsv -IntervalSeconds $MetricsInterval
        } catch {
            Write-Host "  -> Resource sampling unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
            $metricsJob = $null
        }
    }

    # --- 4. Choose the preset and target ---
    Write-Step "[4/5] Determining build configuration..."
    if ($UnityTestLibslic3r) {
        $Preset = "x64-clang-cache"
        if (-not $Target) { $Target = "libslic3r" }
    } elseif (-not $Preset) {
        if (Test-Path "build-clang-cache" -PathType Container) {
            $Preset = "x64-clang-cache"
        } else {
            $Preset = "x64-clang"
        }
    }
    if (-not $Target) { $Target = "all" }
    $buildDir = $presetDirs[$Preset]
    Write-Host "  -> Preset: $Preset ($buildDir)" -ForegroundColor DarkGray
    Write-Host "  -> Target: $Target, configuration: $Config" -ForegroundColor DarkGray
    if ($Preset -eq "x64-clang-cache" -and -not $ccache) {
        throw "ccache is required for the x64-clang-cache preset. Install it, add it to PATH, or set ORCA_CCACHE."
    }

    # Use 3s sampling for cached runs (x64-clang-cache), 15s for clean builds
    if ($Preset -eq "x64-clang-cache") {
        $MetricsInterval = 3
    }

    # --- 3. Ensure dependencies are built for clang-cl ---
    if ($SkipDeps) {
        Write-Step "[3/5] Skipping dependencies (--skip-deps)"
    } else {
        Write-Step "[3/5] Checking dependencies..."
        $depsBuildDir = if ($Preset -eq "x64-clang-cache") { "deps/build-clang-cache" } else { "deps/build-clang" }
        Check-Dependencies -Cmake $cmake -ClangCl $clangCl -Config $Config -DepsBuildDir $depsBuildDir

        if ($PackDeps) {
            Write-Step "[3.5/5] Packing dependencies..."
            $zipPath = Pack-Dependencies -DepsBuildDir $depsBuildDir -OutputPath (Join-Path $RepoRoot "deps\OrcaSlicer_dep.zip")
            Write-Host "  -> Dependency archive: $zipPath"
            Write-Host ""
            $python = Get-Command py -ErrorAction SilentlyContinue
            if ($python) {
                & $python -c '
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
                Write-Host "  Dependencies packed successfully!" -ForegroundColor Green
                Write-Host "  Archive: $zipPath"
                Write-Host "==========================================" -ForegroundColor Green
            }
            exit 0
        }
    }

    if ($Clean -and (Test-Path $buildDir)) {
        Write-Host "  -> Removing $buildDir"
        Remove-Item $buildDir -Recurse -Force
    }

    # --- 5. Configure and build ---
    Write-Step "[5/5] Configuring and building..."
    $generator = "Ninja Multi-Config"
    $compiler = $null
    if ($Preset -eq "x64-clang" -or $Preset -eq "x64-clang-cache" -or $Preset -eq "x64-clang-debug") {
        $compiler = $clangCl
    }
    $cmakeArgs = @()
    if ($Preset -eq "x64-clang-cache") { $cmakeArgs += "-DSLIC3R_UNITY_BUILD=ON" }
    $timing = Configure-Build -Cmake $cmake -BuildDir $buildDir -Config $Config -Target $Target -UnityTest:$UnityTestLibslic3r -MaxJobs $MaxJobs -Generator $generator -Compiler $compiler -CMakeArgs $cmakeArgs

    # --- 6. Ccache statistics ---
    Show-CcacheStats -Ccache $ccache -NoMetrics:$NoMetrics

    $total = (Get-Date) - $started
    Write-Host ""
    $python = Get-Command py -ErrorAction SilentlyContinue
    if ($python) {
        & $python "$RepoRoot\scripts\build_units\rich_utils.py" rule green
    } else {
        Write-Host "=========================================="
    }
    if ($UnityTestLibslic3r) {
        Write-Host "  Unity build test PASSED (libslic3r)" -ForegroundColor Green
    } else {
        Write-Host "  Build complete!" -ForegroundColor Green
    }
    Write-Host ""
    $fmt = { param($t) $h = [math]::Floor($t.TotalHours); $m = [math]::Floor($t.TotalMinutes) % 60; $s = [math]::Round($t.Seconds); if ($h) { "{0}h {1:00}m {2:00}s" -f $h, $m, $s } elseif ($m) { "{0}m {1:00}s" -f $m, $s } else { "{0}s" -f $s } }
    $configureStr = & $fmt $timing.ConfigureTime
    $buildStr     = & $fmt $timing.BuildTime
    $totalStr     = & $fmt $total
} catch {
    Write-Host ""
    Write-Host "BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($metricsJob) {
        Stop-Job $metricsJob -ErrorAction SilentlyContinue
        Remove-Job $metricsJob -Force -ErrorAction SilentlyContinue
        if ($metricsCsv -and (Test-Path $metricsCsv)) {
            $renderer = Join-Path $RepoRoot "scripts\build_metrics.py"
            $python = Get-Command py -ErrorAction SilentlyContinue
            if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
            if ($python -and (Test-Path $renderer)) {
                Write-Host ""
                $renderArgs = @()
                if ($python.Name -match "^py(\.exe)?$") { $renderArgs += "-3" }
                $renderArgs += $renderer
                $renderArgs += $metricsCsv
                $renderArgs += "--title"
                $renderArgs += "OrcaSlicer build ($Preset, $Config)"
                try {
                    & $python.Source @renderArgs
                } catch {
                    Write-Host "  -> Could not render metrics: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  -> Metrics saved to $metricsCsv (install Python with rich for the chart)." -ForegroundColor Yellow
            }
        }
    }
    # Timing breakdown using Rich Tree widget (Total is parent)
    $python = Get-Command py -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
    if ($python) {
        & $python "$RepoRoot\scripts\build_units\rich_utils.py" tree $totalStr $configureStr $buildStr
    } else {
        Write-Host ("  Total:     {0}" -f $totalStr)
        Write-Host ("  Configure: {0}" -f $configureStr)
        Write-Host ("  Build:     {0}" -f $buildStr)
    }
    Pop-Location
}

exit 0