# Unit: Build process metrics
# Monitors build-process CPU, cores and RAM during configure/build.
# Renders an ASCII chart at the end via scripts/build_metrics.py.

function Stop-ProcessTree {
    param([int]$Pid)
    try {
        $proc = Get-Process -Id $Pid -ErrorAction SilentlyContinue
        if ($proc) {
            $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$Pid" -ErrorAction SilentlyContinue
            foreach ($child in $children) {
                Stop-ProcessTree -Pid $child.ProcessId -ErrorAction SilentlyContinue
            }
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # Process tree cleanup must never fail the build.
    }
}

function Start-BuildMonitor {
    param([string]$CsvPath, [int]$IntervalSeconds)
    $worker = {
        param($Path, $Interval)
        $header = "timestamp,build_cpu_percent,build_cores,build_rss_gb,cores_compiler,cores_linker,cores_build,cores_ccache,cpu_compiler,cpu_linker,cpu_build,cpu_ccache,ram_compiler,ram_linker,ram_build,ram_ccache"
        Set-Content -LiteralPath $Path -Value $header -Encoding ASCII
        $toolCategory = @{
            "clang-cl" = "compiler"
            "clang"    = "compiler"
            "clang++"  = "compiler"
            "cl"       = "compiler"
            "lld-link" = "linker"
            "link"     = "linker"
            "ninja"    = "build"
            "cmake"    = "build"
            "msbuild"  = "build"
            "ccache"   = "ccache"
        }
        $categories = @("compiler", "linker", "build", "ccache")
        $logical = [Environment]::ProcessorCount
        $reportInterval = [math]::Max(1, $Interval)
        # Poll faster than the reporting interval so compiler processes that
        # live for only a few seconds still contribute their CPU time.
        $pollInterval = [math]::Max(1, [math]::Min(2, $reportInterval))

        function Write-Sample($Time, $CpuPercent, $Cores, $RssGb, $CategoryCores, $CategoryCpu, $CategoryRss) {
            $categoryText = (@($CategoryCores) | ForEach-Object {
                $_.ToString("0.00", [Globalization.CultureInfo]::InvariantCulture)
            }) -join ","
            $cpuText = (@($CategoryCpu) | ForEach-Object {
                $_.ToString("0.0", [Globalization.CultureInfo]::InvariantCulture)
            }) -join ","
            $ramText = (@($CategoryRss) | ForEach-Object {
                $_.ToString("0.00", [Globalization.CultureInfo]::InvariantCulture)
            }) -join ","
            $line = "{0},{1},{2},{3},{4},{5},{6}" -f $Time.ToString("o"),
                $CpuPercent.ToString("0.0", [Globalization.CultureInfo]::InvariantCulture),
                $Cores.ToString("0.00", [Globalization.CultureInfo]::InvariantCulture),
                $RssGb.ToString("0.00", [Globalization.CultureInfo]::InvariantCulture),
                $categoryText, $cpuText, $ramText
            Add-Content -LiteralPath $Path -Value $line -Encoding ASCII
        }

        $start = Get-Date
        $zeroCores = @(0.0, 0.0, 0.0, 0.0)
        $zeroCpu = @(0.0, 0.0, 0.0, 0.0)
        $zeroRss = @(0.0, 0.0, 0.0, 0.0)
        Write-Sample $start 0.0 0.0 0.0 $zeroCores $zeroCpu $zeroRss
        $windowStart = $start
        $accumulatedCpu = @{}
        foreach ($category in $categories) { $accumulatedCpu[$category] = 0.0 }
        $maxRss = 0.0
        $previousCpu = @{}
        $previousTime = $null

        while ($true) {
            try {
                $now = Get-Date
                $currentCpu = @{}
                $currentCategory = @{}
                $currentRss = @{}
                $rss = 0.0
                foreach ($name in $toolCategory.Keys) {
                    $category = $toolCategory[$name]
                    foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                        try {
                            $cpuSeconds = if ($null -ne $process.CPU) { [double]$process.CPU } else { 0.0 }
                            $id = [int]$process.Id
                            $currentCpu[$id] = $cpuSeconds
                            $currentCategory[$id] = $category
                            $currentRss[$id] = [double]$process.WorkingSet64
                            $rss += $currentRss[$id]
                        } catch {
                            # The process can exit between enumeration and reading its counters.
                        }
                    }
                }

                if ($null -ne $previousTime) {
                    foreach ($id in $currentCpu.Keys) {
                        $lastCpu = $previousCpu[$id]
                        $delta = if ($null -eq $lastCpu -or $currentCpu[$id] -lt $lastCpu) {
                            $currentCpu[$id]
                        } else {
                            $currentCpu[$id] - $lastCpu
                        }
                        if ($delta -gt 0) {
                            $accumulatedCpu[$currentCategory[$id]] += $delta
                        }
                    }
                }
                $maxRss = [math]::Max($maxRss, $rss)

                $windowSeconds = ($now - $windowStart).TotalSeconds
                if ($windowSeconds -ge $reportInterval) {
                    $categoryCores = @()
                    $categoryCpu = @()
                    $categoryRss = @()
                    foreach ($category in $categories) {
                        $categoryCores += [math]::Max(0.0, $accumulatedCpu[$category] / $windowSeconds)
                        # Calculate per-process CPU% for this category
                        $catProcesses = @($currentCpu.Keys | Where-Object { $currentCategory[$_] -eq $category })
                        $catCpu = 0.0
                        $catRss = 0.0
                        foreach ($pid in $catProcesses) {
                            $lastCpu = $previousCpu[$pid]
                            $delta = if ($null -eq $lastCpu -or $currentCpu[$pid] -lt $lastCpu) {
                                $currentCpu[$pid]
                            } else {
                                $currentCpu[$pid] - $lastCpu
                            }
                            $catCpu += if ($windowSeconds -gt 0) { $delta / $windowSeconds } else { 0.0 }
                            $catRss += $currentRss[$pid]
                        }
                        $categoryCpu += $catCpu
                        $categoryRss += $catRss / 1GB
                    }
                    $cores = ($categoryCores | Measure-Object -Sum).Sum
                    if ($cores -gt $logical -and $cores -gt 0) {
                        # New processes can contribute their full CPU time on their
                        # first sample. Keep the stacked total within the machine.
                        $scale = $logical / $cores
                        $categoryCores = @($categoryCores | ForEach-Object { $_ * $scale })
                        $cores = [double]$logical
                    }
                    $cpuPercent = if ($logical -gt 0) { 100.0 * $cores / $logical } else { 0.0 }
                    Write-Sample $now $cpuPercent $cores ($maxRss / 1GB) $categoryCores $categoryCpu $categoryRss
                    $windowStart = $now
                    foreach ($category in $categories) { $accumulatedCpu[$category] = 0.0 }
                    $maxRss = 0.0
                }

                $previousCpu = $currentCpu
                $previousTime = $now
            } catch {
                # Sampling must never fail the build.
            }
            Start-Sleep -Seconds $pollInterval
        }
    }
    return Start-Job -ScriptBlock $worker -ArgumentList $CsvPath, $IntervalSeconds
}
