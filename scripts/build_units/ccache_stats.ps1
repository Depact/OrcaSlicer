# Unit: Ccache statistics
# Displays ccache cache hit rates and storage consumption after the build.

function Show-CcacheStats {
    param([string]$Ccache, [switch]$NoMetrics)
    if ($Ccache -and -not $NoMetrics) {
        Write-Host ""
        Write-Host "[6/6] Ccache statistics..." -ForegroundColor Gray
        & $Ccache -s
    }
}
