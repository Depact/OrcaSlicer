# Unit: Native process invocation
# Shared helper so every CMake/Ninja call streams its output, keeps a log and
# turns a non-zero exit code into a terminating error with a visible tail.

function Invoke-BuildStep {
    param(
        [string]$Label,
        [string]$LogPath,
        [string[]]$Command,
        [string[]]$Arguments
    )

    $previousPreference = $ErrorActionPreference
    $exceptionCaught = $null
    # Native tools report progress and errors on stderr. With 'Stop' the first
    # such line becomes a terminating error that hides the real failure, so the
    # preference is relaxed for the duration of the call.
    $ErrorActionPreference = "Continue"
    $lastLine = @("")  # Array to hold mutable reference across ForEach-Object scope
    try {
        & $Command @Arguments 2>&1 | ForEach-Object {
            # Skip empty/whitespace-only lines
            if (-not ($_.ToString().Trim())) { return }
            $span = if ($global:BuildStarted) { (Get-Date) - $global:BuildStarted } else { [TimeSpan]::Zero }
            $h = [math]::Floor($span.TotalHours)
            $m = [math]::Floor($span.TotalMinutes) % 60
            $s = [math]::Round($span.Seconds)
            $ts = "[{0}h{1}m{2}s]" -f $h, $m, $s
            $raw = if ($_ -is [System.Management.Automation.ErrorRecord]) { $ts + " [ERR] " + $_.ToString() } else { $ts + " " + $_ }
            # Skip exact duplicate lines (CMake sometimes outputs same message twice)
            if ($raw -eq $lastLine[0]) { return }
            $lastLine[0] = $raw
            # Color real errors red (not CMake's [ERR] trace messages), normal output gray
            $isRealError = $raw -match '(?i)(error:|fatal:|FAILED:|^error\s|^fatal\s|^\s*error\s)'
            $line = if ($isRealError) { Write-Host $raw -ForegroundColor Red; $raw } else { Write-Host $raw -ForegroundColor DarkGray; $raw }
            $line | Tee-Object -FilePath $LogPath -Append
        }
        $exitCode = $LASTEXITCODE
        $exceptionCaught = $null
    } catch {
        $exceptionCaught = $_
        $exitCode = 1
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exceptionCaught) {
        Write-Host "--- $Label threw $($exceptionCaught.GetType().Name): $($exceptionCaught.Exception.Message) ---" -ForegroundColor Red
        throw "$Label failed due to exception ($($exceptionCaught.GetType().Name)): $($exceptionCaught.Exception.Message). Log: $LogPath"
    }
    if ($exitCode -ne 0) {
        Write-Host ""
        Write-Host "--- $Label failed (exit $exitCode); last 60 log lines ---" -ForegroundColor Red
        Get-Content $LogPath -Tail 60 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host $_ -ForegroundColor Red }
        Write-Host "--- full log: $LogPath ---" -ForegroundColor Red
        throw "$Label failed with exit code $exitCode. Log: $LogPath"
    }
}

function New-BuildLogPath {
    param([string]$Name)
    $logDir = Join-Path $env:TEMP "orca-build-logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    return (Join-Path $logDir ("{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $Name))
}
