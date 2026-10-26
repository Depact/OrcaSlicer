# Unit: Dependency management
# Verifies dependency source integrity via manifest hash and builds deps when needed.

function Get-DepsManifestHash {
    # Hash the dep source directories so we detect upstream dependency
    # changes instead of relying on a stale prebuilt tree.
    $hash = [System.Security.Cryptography.SHA256]::Create()
    $manifestBuilder = New-Object System.Text.StringBuilder
    $depSrcs = Get-ChildItem "$RepoRoot\deps_src" -Directory | Sort-Object Name
    foreach ($dep in $depSrcs) {
        $files = Get-ChildItem $dep.FullName -Recurse -File | Sort-Object FullName
        foreach ($file in $files) {
            $manifestBuilder.AppendLine($file.FullName) > $null
            $manifestBuilder.AppendLine($file.Length.ToString()) > $null
            $manifestBuilder.AppendLine($file.LastWriteTimeUtc.ToString("O")) > $null
        }
    }
    $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestBuilder.ToString())
    return [BitConverter]::ToString($hash.ComputeHash($manifestBytes)).Replace("-", "").ToLower()
}

function Check-Dependencies {
    param([string]$Cmake, [string]$ClangCl, [string]$Config, [switch]$ForceRebuild, [string]$DepsBuildDir)
    if (-not $DepsBuildDir) { $DepsBuildDir = "deps/build-clang" }
    $depsPrefix = "$DepsBuildDir/OrcaSlicer_dep/usr/local"
    $depsManifest = "$DepsBuildDir/.deps-manifest"
    
    $currentHash = Get-DepsManifestHash
    $storedHash = $null
    if (Test-Path $depsManifest) { $storedHash = Get-Content $depsManifest -TotalCount 1 }

    $needsRebuild = $ForceRebuild -or -not (Test-Path $depsPrefix -PathType Container)
    if (-not $needsRebuild -and $storedHash -and $currentHash -ne $storedHash) {
        $needsRebuild = $true
        Write-Host "  -> Dependency source changed since last build; rebuilding..." -ForegroundColor Yellow
    }

    if ($needsRebuild) {
        Write-Host "  -> Building dependencies for clang-cl + Ninja..." -ForegroundColor Yellow
        Invoke-BuildStep -Label "Dependency configuration" -Command $Cmake -Arguments @(
            "-S", "deps", "-B", $DepsBuildDir, "-G", "Ninja Multi-Config",
            "-DCMAKE_C_COMPILER=$ClangCl", "-DCMAKE_CXX_COMPILER=$ClangCl")
        Invoke-BuildStep -Label "Dependency build" -Command $Cmake -Arguments @(
            "--build", $DepsBuildDir, "--config", $Config, "--target", "deps", "--")
        $currentHash | Set-Content $depsManifest -Encoding ASCII
        Write-Host "  -> Dependencies built successfully" -ForegroundColor Green
    } else {
        if (-not (Test-Path $depsManifest)) {
            $currentHash | Set-Content $depsManifest -Encoding ASCII
        }
        # Check if Boost is available system-wide before using deps
        $boostLibPath = "${depsPrefix}/lib/libboost*.lib"
        if (-not (Get-ChildItem $boostLibPath -ErrorAction SilentlyContinue)) {
            Write-Host "  -> WARNING: No Boost libraries found in deps. This may indicate a Build failure or partial installation. " -ForegroundColor Yellow
            Write-Host "     OrcaSlicer requires Boost to build. Try rebuilding dependencies or install Boost system-wide." -ForegroundColor Yellow
        }
        Write-Host "  -> Dependencies found at $depsPrefix (manifest matches)" -ForegroundColor Green
    }
}

function Pack-Dependencies {
    param([string]$DepsBuildDir, [string]$OutputPath)
    $depsPrefix = "$DepsBuildDir/OrcaSlicer_dep"
    if (-not (Test-Path $depsPrefix -PathType Container)) {
        throw "Dependencies not found at $depsPrefix. Build them first."
    }

    $date = Get-Date -Format "yyyyMMdd"
    $arch = "x64"
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { $arch = "arm64" }
    $zipName = "OrcaSlicer_dep_win-${arch}_${date}.zip"
    $zipPath = Join-Path (Split-Path $OutputPath -Parent) $zipName

    # Use system tar (Windows 10 1803+) or 7z if available
    $zipper = $null
    if (Test-Path "$env:SystemRoot\System32\tar.exe") { $zipper = "$env:SystemRoot\System32\tar.exe -a -c -f" }
    elseif (Test-Path "$RepoRoot\tools\7z.exe") { $zipper = "$RepoRoot\tools\7z.exe a" }

    if (-not $zipper) {
        throw "No archiver found. Install 7-Zip or ensure Windows has System32\tar.exe."
    }

    Write-Host "  -> Packing dependencies to $zipPath..." -ForegroundColor Yellow
    Push-Location $DepsBuildDir
    try {
        & $zipper $zipPath OrcaSlicer_dep
    } finally {
        Pop-Location
    }

    if (-not (Test-Path $zipPath)) {
        throw "Failed to create dependency archive: $zipPath"
    }

    Write-Host "  -> Dependencies packed: $zipPath" -ForegroundColor Green
    return $zipPath
}