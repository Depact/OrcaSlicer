function Start-OrcaBuildMonitor {
    <#
    .SYNOPSIS
        Start a background job that samples build-process CPU, cores and RAM to a CSV.
    .DESCRIPTION
        Polls Win32 processes (clang-cl/cl, lld-link/link, ninja/cmake/msbuild,
        ccache) every $PollInterval seconds and writes one sample row every
        $ReportInterval seconds to $CsvPath. Returns the background job so the
        caller can stop it with Stop-OrcaBuildMonitor.
    .PARAMETER CsvPath
        Path to the metrics CSV to append samples to.
    .PARAMETER ReportIntervalSeconds
        Seconds between written sample rows.
    .PARAMETER PollIntervalSeconds
        Seconds between process enumerations (kept short so short-lived
        compiler processes still contribute CPU time).
    #>
    [CmdletBinding()]
    param(
        [string] $CsvPath,
        [int]    $ReportIntervalSeconds = 15,
        [int]    $PollIntervalSeconds   = 2
    )

    $toolCategory = @{
        'clang-cl'   = 'compiler'
        'clang'      = 'compiler'
        'clang++'    = 'compiler'
        'cl'         = 'compiler'
        'lld-link'   = 'linker'
        'link'       = 'linker'
        'ninja'      = 'build'
        'cmake'      = 'build'
        'msbuild'    = 'build'
        'ccache'     = 'ccache'
    }
    $categories = @('compiler', 'linker', 'build', 'ccache')
    $logical    = [Environment]::ProcessorCount
    $reportInterval = [math]::Max(1, $ReportIntervalSeconds)
    $pollInterval   = [math]::Max(1, [math]::Min(2, $reportInterval))

    $worker = {
        param($Path, $Interval, $Poll, $Logical)

        $header = 'timestamp,build_cpu_percent,build_cores,build_rss_gb,' +
            'cores_compiler,cores_linker,cores_build,cores_ccache,' +
            'cpu_compiler,cpu_linker,cpu_build,cpu_ccache,' +
            'ram_compiler,ram_linker,ram_build,ram_ccache'
        Set-Content -LiteralPath $Path -Value $header -Encoding ASCII

        function Write-OrcaBuildSample($Time, $CpuPercent, $Cores, $RssGb,
            $CategoryCores, $CategoryCpu, $CategoryRss) {
            $catText = (@($CategoryCores) | ForEach-Object {
                $_.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
            }) -join ','
            $cpuText = (@($CategoryCpu) | ForEach-Object {
                $_.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
            }) -join ','
            $ramText = (@($CategoryRss) | ForEach-Object {
                $_.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
            }) -join ','
            $line = '{0},{1},{2},{3},{4},{5},{6}' -f $Time.ToString('o'),
                $CpuPercent.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture),
                $Cores.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture),
                $RssGb.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture),
                $catText, $cpuText, $ramText
            Add-Content -LiteralPath $Path -Value $line -Encoding ASCII
        }

        $start = Get-Date
        $zeroCores = @(0.0, 0.0, 0.0, 0.0)
        $zeroCpu   = @(0.0, 0.0, 0.0, 0.0)
        $zeroRss   = @(0.0, 0.0, 0.0, 0.0)
        Write-OrcaBuildSample -Time $start -CpuPercent 0.0 -Cores 0.0 -RssGb 0.0 `
            -CategoryCores $zeroCores -CategoryCpu $zeroCpu -CategoryRss $zeroRss

        $windowStart  = $start
        $accumulatedCpu = @{}
        foreach ($category in @('compiler', 'linker', 'build', 'ccache')) {
            $accumulatedCpu[$category] = 0.0
        }
        $maxRss     = 0.0
        $previousCpu = @{}
        $previousTime = $null

        while ($true) {
            try {
                $now = Get-Date
                $currentCpu = @{}
                $currentCategory = @{}
                $currentRss = @{}
                $rss = 0.0
                foreach ($name in @('clang-cl', 'clang', 'clang++', 'cl', 'lld-link', 'link', 'ninja', 'cmake', 'msbuild', 'ccache')) {
                    $category = @{
                        'clang-cl'   = 'compiler'
                        'clang'      = 'compiler'
                        'clang++'    = 'compiler'
                        'cl'         = 'compiler'
                        'lld-link'   = 'linker'
                        'link'       = 'linker'
                        'ninja'      = 'build'
                        'cmake'      = 'build'
                        'msbuild'    = 'build'
                        'ccache'     = 'ccache'
                    }[$name]
                    foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                        try {
                            $cpuSeconds = if ($null -ne $process.CPU) { [double]$process.CPU } else { 0.0 }
                            $id = [int]$process.Id
                            $currentCpu[$id] = $cpuSeconds
                            $currentCategory[$id] = $category
                            $currentRss[$id] = [double]$process.WorkingSet64
                            $rss += $currentRss[$id]
                        } catch {
                            # Process can exit between enumeration and reading counters.
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
                if ($windowSeconds -ge $Interval) {
                    $categoryCores = @(); $categoryCpu = @(); $categoryRss = @()
                    foreach ($category in @('compiler', 'linker', 'build', 'ccache')) {
                        $categoryCores += [math]::Max(0.0, $accumulatedCpu[$category] / $windowSeconds)
                        $catProcesses = @($currentCpu.Keys | Where-Object { $currentCategory[$_] -eq $category })
                        $catCpu = 0.0; $catRss = 0.0
                        foreach ($procId in $catProcesses) {
                            $lastCpu = $previousCpu[$procId]
                            $delta = if ($null -eq $lastCpu -or $currentCpu[$procId] -lt $lastCpu) {
                                $currentCpu[$procId]
                            } else {
                                $currentCpu[$procId] - $lastCpu
                            }
                            $catCpu += if ($windowSeconds -gt 0) { $delta / $windowSeconds } else { 0.0 }
                            $catRss += $currentRss[$procId]
                        }
                        $categoryCpu += $catCpu
                        $categoryRss += $catRss / 1GB
                    }
                    $cores = ($categoryCores | Measure-Object -Sum).Sum
                    if ($cores -gt $Logical -and $cores -gt 0) {
                        $scale = $Logical / $cores
                        $categoryCores = @($categoryCores | ForEach-Object { $_ * $scale })
                        $cores = [double]$Logical
                    }
                    $cpuPercent = if ($Logical -gt 0) { 100.0 * $cores / $Logical } else { 0.0 }
                    Write-OrcaBuildSample -Time $now -CpuPercent $cpuPercent -Cores $cores -RssGb ($maxRss / 1GB) `
                        -CategoryCores $categoryCores -CategoryCpu $categoryCpu -CategoryRss $categoryRss
                    $windowStart = $now
                    foreach ($category in @('compiler', 'linker', 'build', 'ccache')) {
                        $accumulatedCpu[$category] = 0.0
                    }
                    $maxRss = 0.0
                }

                $previousCpu = $currentCpu
                $previousTime = $now
            } catch {
                # Sampling must never fail the build.
            }
            Start-Sleep -Seconds $Poll
        }
    }

    return Start-Job -ScriptBlock $worker -ArgumentList $CsvPath, $reportInterval, $pollInterval, $logical
}

function Stop-OrcaBuildMonitor {
    <#
    .SYNOPSIS
        Stop a build-monitor job started by Start-OrcaBuildMonitor.
    .DESCRIPTION
        Stops the background job and removes it from the job queue.
    .PARAMETER Job
        The job object returned by Start-OrcaBuildMonitor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Remoting.PSJob] $Job
    )

    try {
        if ($Job.State -eq 'Running') {
            Stop-Job -Job $Job -ErrorAction SilentlyContinue
        }
    } catch {
        # Best effort; never fail the build.
    }
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
}
