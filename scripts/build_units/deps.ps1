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
    param([string]$Cmake, [string]$ClangCl, [string]$Config, [switch]$ForceRebuild)
    $depsBuildDir = "deps/build-clang"
    $depsPrefix = "$depsBuildDir/OrcaSlicer_dep/usr/local"
    $depsManifest = "$depsBuildDir/.deps-manifest"
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
        $depsConfigureLog = New-BuildLogPath "deps-configure"
        Invoke-BuildStep -Label "Dependency configuration" -LogPath $depsConfigureLog -Command $Cmake -Arguments @(
            "-S", "deps", "-B", $depsBuildDir, "-G", "Ninja Multi-Config",
            "-DCMAKE_C_COMPILER=$ClangCl", "-DCMAKE_CXX_COMPILER=$ClangCl")
        $depsBuildLog = New-BuildLogPath "deps-build"
        Invoke-BuildStep -Label "Dependency build" -LogPath $depsBuildLog -Command $Cmake -Arguments @(
            "--build", $depsBuildDir, "--config", $Config, "--target", "deps", "--")
        $currentHash | Set-Content $depsManifest -Encoding ASCII
        Write-Host "  -> Dependencies built successfully" -ForegroundColor Green
    } else {
        if (-not (Test-Path $depsManifest)) {
            $currentHash | Set-Content $depsManifest -Encoding ASCII
        }
        Write-Host "  -> Dependencies found at $depsPrefix (manifest matches)" -ForegroundColor Green
    }
}