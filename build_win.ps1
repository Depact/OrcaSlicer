<#
.SYNOPSIS
    Build OrcaSlicer on Windows with clang-cl + Ninja (+ optional ccache).
.DESCRIPTION
    Run with -Help for a one-page reference of every option.
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
    [int]$MaxJobs = 0,
    [switch]$Help
)

if ($Help) {
    @'
build_win.ps1 - Build OrcaSlicer on Windows (clang-cl + Ninja + optional ccache)

USAGE
  .\build_win.ps1 [options]
  .\build_win.ps1 -Help

OPTIONS
  -Preset <name>
      Which build tree to use.
        x64-clang        clang-cl, no ccache          (build-clang)
        x64-clang-cache  ccache, unity build          (build-clang-cache)
        x64-clang-debug  debug configuration tree     (build-dbg-clang)
      Omit it and the script picks x64-clang-cache when ccache is installed and
      its dependency tree is complete, otherwise x64-clang.

  -Config <name>
      CMake configuration to build. Default: Release.

  -Target <name>
      Build one target instead of everything, for example libslic3r.
      Default: all.

  -Clean
      Delete deps/build-clang, deps/build-clang-cache and the active build
      directory before configuring. Does not touch the source tree.

  -UnityTestLibslic3r
      Force x64-clang-cache and build only libslic3r, using the unity build for
      fast test-and-fix cycles.

  -NoMetrics
      Skip the CPU / cores / RAM sampler and the resource chart afterwards.

  -PackDeps
      Check and build the dependencies, write deps/OrcaSlicer_dep.zip, then
      exit without building OrcaSlicer.

  -SkipDeps
      Trust whatever is already in deps/ and skip the dependency check.

  -MetricsInterval <n>
      Seconds between sampler rows (1-10). Default: 15, or 3 for the
      x64-clang-cache preset.

  -MaxJobs <n>
      Cap parallel compile jobs (1-64). Default: 0, meaning auto.

  -Help
      Print this page and exit.

ENVIRONMENT
  ORCA_CLANG_CL   Path to clang-cl.exe (otherwise PATH or the VS LLVM bundle).
  ORCA_CMAKE      Path to cmake.exe (otherwise PATH).
  ORCA_NINJA      Path to ninja.exe (otherwise PATH).
  ORCA_CCACHE     Path to ccache.exe (otherwise PATH).

EXAMPLES
  .\build_win.ps1
      Build everything with the best preset available on this machine.

  .\build_win.ps1 -Preset x64-clang-cache -Target libslic3r
      Rebuild only the slicing library through ccache.

  .\build_win.ps1 -Clean -PackDeps
      Rebuild the dependencies from scratch and pack them into a zip.

  .\build_win.ps1 -NoMetrics -MaxJobs 8
      Same build without the resource monitor, eight jobs at a time.
'@ | Write-Host
    exit 0
}


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

# Locate PowerShell 7 for PwshSpectreConsole rich output (Python 'rich' is forbidden).
$Pwsh7 = Join-Path $env:LOCALAPPDATA "opencode\pwsh7\pwsh.exe"
if (-not (Test-Path $Pwsh7)) {
    $Pwsh7 = $null
    Write-Status "pwsh7" "PowerShell 7 not found; falling back to plain output." "Yellow"
}
$PwshRenderScript = Join-Path $UnitsDir "render.ps1"

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
        return "{0}:{1}:{2}" -f $h, $m, $s
    }

    function Write-Step {
        param([string]$Text)
        $ts = Get-TimeStamp
        Write-Host "[$ts] $Text"
    }

    function Write-Status {
        param(
            [string]$Tag,
            [string]$Text,
            [string]$Color = "DarkGray"
        )
        Write-Host ("  {0,-9} {1}" -f "[$Tag]", $Text) -ForegroundColor $Color
    }

    # Spectre output has to be produced by PowerShell 7, then replayed through
    # Write-Host: PowerShell 5.1 decodes native stdout with the console code page,
    # which mangles the box-drawing glyphs unless it is switched to UTF-8 here.
    function Invoke-SpectreHelper {
        param([string]$Action, [object[]]$Arguments = @())
        if (-not $Pwsh7) { return $false }
        $previousEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [Text.Encoding]::UTF8
            & $Pwsh7 -NoProfile -File $PwshRenderScript $Action @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        } finally {
            [Console]::OutputEncoding = $previousEncoding
        }
        return $true
    }

    function Show-BuildMetrics {
        param([string]$CsvPath, [string]$Preset, [string]$Config)
        if (-not $CsvPath -or -not (Test-Path $CsvPath)) { return }
        if (-not (Invoke-SpectreHelper -Action "chart" -Arguments @($CsvPath))) {
            Write-Status "metrics" "PowerShell 7 not found; skipping metrics chart." "Yellow"
        }
    }

    $fmt = {
        param($t)
        $h = [math]::Floor($t.TotalHours)
        $m = [math]::Floor($t.TotalMinutes) % 60
        $s = [math]::Round($t.Seconds)
        if ($h) { "\{0\}:\{1:00\}:\{2:00\}" -f $h, $m, $s }
        elseif ($m) { "{0}m {1:00}s" -f $m, $s }
        else { "{0}s" -f $s }
    }

    # --- 1. Locate Visual Studio and the toolchain ---
    Write-Step "[1/7] Locating Visual Studio and tools..."

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
    Write-Step "[2/7] Determining build configuration..."
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
    Write-Step "[3/7] Setting up the Visual Studio environment..."
    Capture-VsEnvironment -VsInstall $vsInstall

    $toolDirs = @($clangCl, $cmake, $ninja, $ccache) |
        Where-Object { $_ } |
        ForEach-Object { Split-Path -Parent $_ } |
        Select-Object -Unique
    $env:PATH = ($toolDirs -join ";") + ";" + $env:PATH
    Write-Status "env" "VS x64 environment captured, tool dirs prepended to PATH"

    # --- 4. Start metrics monitor ---
    if (-not $NoMetrics) {
        Write-Step "[4/7] Starting build-process resource monitor..."
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
        Write-Step "[4/7] Resource monitoring disabled (-NoMetrics)"
    }

    # --- 5. Ensure dependencies are built ---
    if ($SkipDeps) {
        Write-Step "[5/7] Skipping dependencies (-SkipDeps)"
    } else {
        Write-Step "[5/7] Checking dependencies..."
        $depsBuildDir = if ($Preset -eq "x64-clang-cache") { "deps/build-clang-cache" } else { "deps/build-clang" }
        Check-Dependencies -Cmake $cmake -ClangCl $clangCl -Config $Config -DepsBuildDir $depsBuildDir

        if ($PackDeps) {
            Write-Step "[5.1/7] Packing dependencies..."
            $zipPath = Pack-Dependencies -DepsBuildDir $depsBuildDir -OutputPath (Join-Path $RepoRoot "deps\OrcaSlicer_dep.zip")
            Write-Host ""
            if (Invoke-SpectreHelper -Action "rule") {
                [void](Invoke-SpectreHelper -Action "step" -Arguments @("", "Dependencies packed successfully!"))
                [void](Invoke-SpectreHelper -Action "step" -Arguments @("", "Archive: $zipPath"))
                [void](Invoke-SpectreHelper -Action "rule")
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
    Write-Step "[6/7] Configuring and building..."
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

    # --- 7. Build summary ---
    Write-Host ""
    Write-Host ""
    Write-Step "[7/7] Build finished"

    $ccacheLines = @(Show-CcacheStats -Ccache $ccache -NoMetrics:$NoMetrics)
    if ($ccacheLines.Count -gt 0) {
        $ccacheData = Join-Path $env:TEMP "orca-build-ccache.txt"
        $ccacheLines | Set-Content -LiteralPath $ccacheData -Encoding UTF8
        try {
            if (-not (Invoke-SpectreHelper -Action "textpanel" -Arguments @($ccacheData, "Ccache statistics"))) {
                $ccacheLines | ForEach-Object { Write-Host $_ }
            }
        } finally {
            Remove-Item -LiteralPath $ccacheData -ErrorAction SilentlyContinue
        }
    }

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

    $summaryData = Join-Path $env:TEMP "orca-build-summary.txt"
    @($totalStr, $configureStr, $buildStr) | Set-Content -LiteralPath $summaryData -Encoding ASCII
    try {
        $rendered = Invoke-SpectreHelper -Action "panel" -Arguments @($summaryData)
    } finally {
        Remove-Item -LiteralPath $summaryData -ErrorAction SilentlyContinue
    }
    if (-not $rendered) {
        Write-Host ("  Total:     {0}" -f $totalStr)
        Write-Host ("  Configure: {0}" -f $configureStr)
        Write-Host ("  Build:     {0}" -f $buildStr)
    }

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



