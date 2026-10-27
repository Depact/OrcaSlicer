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
$PwshRichHelper = Join-Path $env:TEMP "orca_spectre_helper.ps1"
@'
$env:IgnoreSpectreEncoding = $true
Import-Module PwshSpectreConsole

# Out-String renders plain text and drops colour, so write through a console
# that is told to emit ANSI even though stdout is redirected through PowerShell 5.1.
$consoleSettings = [Spectre.Console.AnsiConsoleSettings]::new()
$consoleSettings.Ansi = [Spectre.Console.AnsiSupport]::Yes
$consoleSettings.Out = [Spectre.Console.AnsiConsoleOutput]::new([Console]::Out)
$console = [Spectre.Console.AnsiConsole]::Create($consoleSettings)
$culture = [System.Globalization.CultureInfo]::InvariantCulture

function Format-ShortNumber {
    param([double]$Value)
    if ([math]::Abs($Value) -ge 10) { return $Value.ToString('0', $culture) }
    return $Value.ToString('0.0', $culture)
}

$action = $args[0]
switch ($action) {
    "step" {
        $ts = [Spectre.Console.Markup]::Escape($args[1])
        $text = [Spectre.Console.Markup]::Escape($args[2])
        Write-Host "$ts $text"
    }
    "rule" { Write-SpectreRule -Color Green3 }
    "chart" {
        $csvPath = $args[1]
        $rows = @(Import-Csv -Path $csvPath -Encoding UTF8)
        if ($rows.Count -eq 0) { return }

        $toolInfo = @(
            @{ Name = 'compiler'; Color = 'green3' },
            @{ Name = 'linker';   Color = 'steelblue1' },
            @{ Name = 'build';    Color = 'orange3' },
            @{ Name = 'ccache';   Color = 'mediumpurple' }
        )
        $metrics = @(
            @{ Title = 'CPU %'; Prefix = 'cpu';   Total = 'build_cpu_percent'; Unit = '%' },
            @{ Title = 'Cores'; Prefix = 'cores'; Total = 'build_cores';       Unit = '' },
            @{ Title = 'RAM';   Prefix = 'ram';   Total = 'build_rss_gb';      Unit = ' GB' }
        )

        # Average equal buckets so a long build still fits on one screen.
        $maxRows = 15
        $groups = @()
        if ($rows.Count -le $maxRows) {
            $groups = @(, $rows)
        } else {
            $size = [math]::Ceiling($rows.Count / $maxRows)
            for ($i = 0; $i -lt $rows.Count; $i += $size) {
                $end = [math]::Min($i + $size - 1, $rows.Count - 1)
                $groups += ,@($rows[$i..$end])
            }
        }

        $first = [datetime]$rows[0].timestamp
        $barWidth = [math]::Min(60, [math]::Max(20, $console.Profile.Width - 26))
        $blocks = @()

        foreach ($metric in $metrics) {
            $samples = foreach ($group in $groups) {
                $values = [ordered]@{}
                $named = 0.0
                foreach ($tool in $toolInfo) {
                    $column = "$($metric.Prefix)_$($tool.Name)"
                    $sum = 0.0
                    foreach ($row in $group) { $sum += [double]$row.$column }
                    $values[$tool.Name] = $sum / $group.Count
                    $named += $values[$tool.Name]
                }
                $totalSum = 0.0
                foreach ($row in $group) { $totalSum += [double]$row.($metric.Total) }
                $total = $totalSum / $group.Count
                [pscustomobject]@{
                    Sec    = [int]((([datetime]$group[0].timestamp) - $first).TotalSeconds)
                    Values = $values
                    Total  = $total
                    Other  = [math]::Max(0.0, $total - $named)
                }
            }

            $peak = ($samples | Measure-Object -Property Total -Maximum).Maximum
            if ($peak -le 0) { continue }
            $peakText = Format-ShortNumber -Value $peak
            $blocks += [Spectre.Console.Markup]::new("[bold]$($metric.Title)[/] [grey]peak $peakText$($metric.Unit)[/]")

            foreach ($sample in $samples) {
                if ($sample.Total -le 0) { continue }
                $chars = [math]::Min($barWidth, [math]::Max(1, [math]::Round($sample.Total / $peak * $barWidth)))
                $bar = ''
                $remaining = $chars
                $remainingValue = $sample.Total
                $segments = @($toolInfo | Where-Object { $sample.Values[$_.Name] -gt 0 })
                for ($i = 0; $i -lt $segments.Count; $i++) {
                    $tool = $segments[$i]
                    $value = $sample.Values[$tool.Name]
                    if ($i -eq $segments.Count - 1 -and $sample.Other -le 0) {
                        $count = $remaining
                    } else {
                        $count = [math]::Round($value / $remainingValue * $remaining)
                        $count = [math]::Max(0, [math]::Min($count, $remaining))
                    }
                    if ($count -gt 0) { $bar += "[$($tool.Color)]" + ([string][char]0x2588 * $count) + "[/]" }
                    $remaining -= $count
                    $remainingValue -= $value
                }
                if ($remaining -gt 0 -and $sample.Other -gt 0) {
                    $bar += "[grey]" + ([string][char]0x2591 * $remaining) + "[/]"
                }
                $elapsed = "{0}:{1:00}" -f [math]::Floor($sample.Sec / 60), ($sample.Sec % 60)
                $valueText = Format-ShortNumber -Value $sample.Total
                $blocks += [Spectre.Console.Markup]::new(("[grey]{0,5}[/] {1} {2}" -f $elapsed, $bar, $valueText))
            }
            $blocks += [Spectre.Console.Markup]::new("")
        }
        $blocks += [Spectre.Console.Markup]::new("[green3]$([char]0x2588)[/] compiler  [steelblue1]$([char]0x2588)[/] linker  [orange3]$([char]0x2588)[/] build  [mediumpurple]$([char]0x2588)[/] ccache  [grey]$([char]0x2591)[/] other")
        $content = [Spectre.Console.Rows]::new([Spectre.Console.Rendering.IRenderable[]]$blocks)
        $panel = $content | Format-SpectrePanel -Header "Resource use" -Color Grey -Expand
        $console.Write($panel)
    }
    "textpanel" {
        $source = $args[1]
        $header = $args[2]
        if (-not (Test-Path $source)) { return }
        $blocks = @()
        foreach ($line in @(Get-Content -LiteralPath $source)) {
            # ccache colourises its own output; strip the escapes and keep the text.
            $clean = [regex]::Replace($line, "\x1b\[[0-9;]*m", "")
            $blocks += [Spectre.Console.Markup]::new([Spectre.Console.Markup]::Escape($clean))
        }
        if ($blocks.Count -eq 0) { return }
        $content = [Spectre.Console.Rows]::new([Spectre.Console.Rendering.IRenderable[]]$blocks)
        $panel = $content | Format-SpectrePanel -Header $header -Color Grey -Expand
        $console.Write($panel)
    }
    "panel" {
        $lines = @(Get-Content $args[1])
        $total     = [Spectre.Console.Markup]::Escape("Total:     $($lines[0])")
        $configure = "[grey]" + [Spectre.Console.Markup]::Escape("Configure: $($lines[1])") + "[/]"
        $build     = "[grey]" + [Spectre.Console.Markup]::Escape("Build:     $($lines[2])") + "[/]"
        $data = @{
            Value = $total
            Children = @(
                @{ Value = $configure; Children = @() }
                @{ Value = $build; Children = @() }
            )
        }
        $tree = Format-SpectreTree -Data $data
        # Grey style colours the tree guides; the node text keeps its own markup.
        $tree.Style = [Spectre.Console.Style]::new([Spectre.Console.Color]::Grey)
        $panel = $tree | Format-SpectrePanel -Header "Build complete!" -Color Green3 -Expand
        $console.Write($panel)
    }
}
'@ | Out-File -FilePath $PwshRichHelper -Encoding utf8

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
            & $Pwsh7 -NoProfile -File $PwshRichHelper $Action @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
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
            if ($Pwsh7) {
                & $Pwsh7 -NoProfile -File $PwshRichHelper rule Green
                & $Pwsh7 -NoProfile -File $PwshRichHelper step "" "Dependencies packed successfully!"
                & $Pwsh7 -NoProfile -File $PwshRichHelper step "" "Archive: $zipPath"
                & $Pwsh7 -NoProfile -File $PwshRichHelper rule Green
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
    $ccacheLines = @(Show-CcacheStats -Ccache $ccache -NoMetrics:$NoMetrics)
    if ($ccacheLines.Count -gt 0) {
        Write-Host ""
        Write-Host ""
        $ccacheData = Join-Path $env:TEMP "orca-build-ccache.txt"
        $ccacheLines | Set-Content -LiteralPath $ccacheData -Encoding UTF8
        try {
            if (-not (Invoke-SpectreHelper -Action "textpanel" -Arguments @($ccacheData, "Ccache statistics"))) {
                Write-Step "[7/7] Ccache statistics..."
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



