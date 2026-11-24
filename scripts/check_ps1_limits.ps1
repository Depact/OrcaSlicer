<#
.SYNOPSIS
    Check PowerShell scripts for file length (<= 300 lines) and function length (<= 70 lines).
.DESCRIPTION
    Scans .ps1 files under scripts/build_win_steps and build_win.ps1.
    Exits with code 1 if any file exceeds 300 lines or any function exceeds 70 lines.
    Reports: path:start function (N lines)
#>

param(
    [string[]]$Paths = @("build_win.ps1", "scripts/build_win_steps/*.ps1")
)

$errors = 0

function Get-FunctionLines {
    param([string[]]$Lines)
    $funcStarts = @()
    $inFunction = $false
    $braceDepth = 0
    $funcStartLine = 0
    $funcName = ""

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if (-not $inFunction) {
            if ($line -match '^\s*function\s+(\w+)\s*\{?') {
                $funcName = $Matches[1]
                $inFunction = $true
                $funcStartLine = $i
                # Count opening braces on this line
                $braceDepth = ($line -replace '[^{]', '').Length - ($line -replace '[^}]', '').Length
            }
        } else {
            $braceDepth += ($line -replace '[^{]', '').Length - ($line -replace '[^}]', '').Length
            if ($braceDepth -le 0) {
                $funcLength = $i - $funcStartLine + 1
                $funcStarts += @{ Name = $funcName; Start = $funcStartLine + 1; Length = $funcLength }
                $inFunction = $false
                $funcName = ""
            }
        }
    }
    return $funcStarts
}

foreach ($pattern in $Paths) {
    $files = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        $lines = Get-Content $file.FullName
        $lineCount = $lines.Count
        if ($lineCount -gt 300) {
            Write-Error "$($file.FullName) exceeds 300 lines ($lineCount)"
            $errors++
        }
        $funcs = Get-FunctionLines $lines
        foreach ($f in $funcs) {
            if ($f.Length -gt 70) {
                Write-Error "$($file.FullName):$($f.Start) $($f.Name) ($($f.Length) lines)"
                $errors++
            }
        }
    }
}

if ($errors -gt 0) {
    Write-Error "Total violations: $errors"
    exit 1
} else {
    Write-Host "All PS1 files pass length limits."
    exit 0
}