function Stop-OrcaProcessTree {
    <#
    .SYNOPSIS
        Stop a process and all of its descendants.
    .DESCRIPTION
        Recursively kills a process tree. Failures are swallowed so process-tree
        cleanup can never fail the build.
    .PARAMETER ProcessId
        The ID of the root process to stop.
    #>
    [CmdletBinding()]
    param([int]$ProcessId)

    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $proc) { return }
        $children = Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $ProcessId) `
            -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            Stop-OrcaProcessTree -ProcessId $child.ProcessId
        }
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch {
        # Process tree cleanup must never fail the build.
    }
}
