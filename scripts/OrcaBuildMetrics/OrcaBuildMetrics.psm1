# OrcaBuildMetrics.psm1
# Root module: records and renders build performance metrics.
#
# Public functions (exported):
#   Start-OrcaBuildMonitor   - sample build-process CPU/cores/RAM to a CSV
#   Stop-OrcaBuildMonitor    - stop a running monitor job
#   Stop-OrcaProcessTree     - kill a process and its descendants
#   Show-OrcaBuildMetrics    - render a metrics CSV to a stacked ASCII chart
#
# Private helpers live in private/OrcaBuildMetrics-Helpers.ps1 and are NOT
# exported (use InModuleScope in tests to reach them).

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$publicDir  = Join-Path $PSScriptRoot 'public'
$privateDir = Join-Path $PSScriptRoot 'private'

# Private helpers first (public functions depend on them).
Get-ChildItem -Path $privateDir -Filter '*.ps1' -File | ForEach-Object {
    . $_.FullName
}

# Public functions.
Get-ChildItem -Path $publicDir -Filter '*.ps1' -File | ForEach-Object {
    . $_.FullName
}

Export-ModuleMember -Function Start-OrcaBuildMonitor, Stop-OrcaBuildMonitor, Stop-OrcaProcessTree, Show-OrcaBuildMetrics
