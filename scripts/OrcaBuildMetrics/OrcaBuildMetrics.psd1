@{
    RootModule = 'OrcaBuildMetrics.psm1'
    ModuleVersion = '1.0.0'
    GUID = '8C3F2A1B-4D5E-4F6A-8B7C-9D0E1F2A3B4C'
    Author = 'OrcaSlicer'
    CompanyName = 'OrcaSlicer'
    Copyright = '(c) 2026 OrcaSlicer. All rights reserved.'
    Description = 'Records and renders build performance metrics (CPU %, cores, RAM) for OrcaSlicer builds.'
    FunctionsToExport = @(
        'Start-OrcaBuildMonitor',
        'Stop-OrcaBuildMonitor',
        'Stop-OrcaProcessTree',
        'Show-OrcaBuildMetrics'
    )
    CmdletsToExport = @(
        'Start-OrcaBuildMonitor',
        'Stop-OrcaBuildMonitor',
        'Stop-OrcaProcessTree',
        'Show-OrcaBuildMetrics'
    )
    CompatiblePSEditions = @('Desktop')
    RequiredModules = @()
}
