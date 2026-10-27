function Show-OrcaBuildMetrics {
    <#
    .SYNOPSIS
        Render a build-metrics CSV to a stacked ASCII chart and print it.
    .DESCRIPTION
        Reads the CSV produced by Start-OrcaBuildMonitor and renders CPU %,
        Cores and RAM as stacked per-tool bar charts (compiler / linker /
        build / ccache, with an "other" residual). Pure PowerShell: no Python
        or 'rich' dependency required.
    .PARAMETER CsvPath
        Path to the metrics CSV.
    .PARAMETER Title
        Title printed above the chart.
    #>
    [CmdletBinding()]
    param(
        [string] $CsvPath,
        [string] $Title = 'Build resource usage'
    )

    if (-not (Test-Path -Path $CsvPath -PathType Leaf)) {
        Write-Host "Metrics CSV not found: $CsvPath" -ForegroundColor Red
        return 1
    }

    $report = Get-OrcaBuildMetricsReport -CsvPath $CsvPath -Title $Title
    Write-Host $report
    return 0
}
