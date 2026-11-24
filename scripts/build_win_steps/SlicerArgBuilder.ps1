# Unit: Configure and build
# Extracts the configure+build+install sequence from build_win.ps1 into a reusable function.

function Invoke-ConfigureAndBuild {
    param(
        [string] $Cmake,
        [string] $BuildDir,
        [string] $Config,
        [string] $Target,
        [int]    $MaxJobs,
        [string] $Generator,
        [string] $Compiler,
        [string[]] $CMakeArgs,
        [switch] $NoConfigure,
        [switch] $InstallSlicer
    )

    $timing = Configure-Build -Cmake $Cmake -BuildDir $BuildDir -Config $Config -Target $Target `
        -NoConfigure:$NoConfigure -MaxJobs $MaxJobs `
        -Generator $Generator -Compiler $Compiler -CMakeArgs $CMakeArgs

    $installTime = [TimeSpan]::Zero
    if ($InstallSlicer) {
        $installTime = Install-Build -Cmake $Cmake -BuildDir $BuildDir -Config $Config
    }

    return [pscustomobject]@{
        Timing      = $timing
        InstallTime = $installTime
    }
}

function Get-BaseCmakeArgs {
    param(
        [switch] $NoPch,
        [switch] $Tests,
        [switch] $Msbuild,
        [switch] $Ninja,
        [switch] $ClangCl,
        [string] $Arch
    )

    $cmakeArgs = @()
    if ($NoPch) { $cmakeArgs += "-DSLIC3R_PCH=OFF" }
    if ($Tests) { $cmakeArgs += "-DBUILD_TESTS=ON" }
    $cmakeArgs += "-DORCA_TOOLS=ON"
    if ($Msbuild) { $cmakeArgs += "-A", $Arch }
    if (-not $Ninja -and $ClangCl) { $cmakeArgs += "-T", "ClangCL" }

    return $cmakeArgs
}

function Apply-JpegPinAndEnv {
    param(
        [string[]] $CmakeArgs,
        [string] $DepsDir,
        [string] $ccacheExe,
        [string] $IncludeEnv,
        [string] $RunnerTemp
    )

    $cmakeArgs = $CmakeArgs

    # Point CMake at the deps install dir so find_package(JPEG) etc. find
    # libjpeg-turbo (with JCS_EXT_RGBA) from deps instead of system libjpeg.
    # Strawberry Perl's c\include is added to the compiler include path and
    # contains an older jpeglib.h (no JCS_EXT_RGBA) that wins over deps'
    # libjpeg-turbo due to include-path ordering. Explicitly pin JPEG to deps.
    $depsInstallRoot = $DepsDir
    $depsInstallDir = Join-Path $depsInstallRoot "OrcaSlicer_dep/usr/local"
    if (Test-Path $depsInstallDir -PathType Container) {
        $depsRootFull = (Resolve-Path -LiteralPath $depsInstallRoot).Path
        $depsInstallDir = Join-Path $depsRootFull "OrcaSlicer_dep/usr/local"
        $depsInstallDir = $depsInstallDir.Replace('\', '/')
        $cmakeArgs += "-DDEP_BUILD_DIR=$($depsRootFull.Replace('\', '/'))"
        $cmakeArgs += "-DCMAKE_PREFIX_PATH=$depsInstallDir"
        $cmakeArgs += "-DJPEG_INCLUDE_DIR=$depsInstallDir/include"
        $jpegLib = Join-Path $depsInstallDir "lib/jpeg.lib"
        if (Test-Path $jpegLib -PathType Leaf) {
            $cmakeArgs += "-DJPEG_LIBRARY=$jpegLib"
        }
    }

    # CMake only routes a compile through a cache when it is named as the
    # launcher. Without these two the cache dir stays untouched and the stats
    # printed at the end describe someone else's builds.
    if ($ccacheExe) {
        $cmakeArgs += "-DCMAKE_C_COMPILER_LAUNCHER=$ccacheExe"
        $cmakeArgs += "-DCMAKE_CXX_COMPILER_LAUNCHER=$ccacheExe"
    }

    # Strip Strawberry Perl's MinGW include dir from INCLUDE env var so it
    # can't shadow deps' libjpeg-turbo headers during compilation.
    if ($IncludeEnv) {
        $env:INCLUDE = ($IncludeEnv -split ';' | Where-Object { $_ -notlike '*Strawberry*' }) -join ';'
    }

    # Strawberry Perl is needed for cmake.exe (used by Configure-Build), but
    # its c\include dir contains an older jpeglib.h (no JCS_EXT_RGBA) that
    # shadows deps' libjpeg-turbo. Delete only c\include so cmake.exe keeps
    # working but CMake can't find the stale JPEG header.
    if ($RunnerTemp) {
        $strawberryInclude = Join-Path $RunnerTemp 'Strawberry\c\include'
        if (Test-Path $strawberryInclude -PathType Container) {
            Remove-Item $strawberryInclude -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return $cmakeArgs
}

function Get-SlicerConfigureArgs {
    param(
        [string] $BuildDir,
        [string] $Config,
        [string] $Target,
        [switch] $NoPch,
        [switch] $Tests,
        [switch] $Msbuild,
        [switch] $Ninja,
        [switch] $ClangCl,
        [string] $Arch,
        [string] $DepsDir,
        [string] $ccacheExe,
        [string] $DepsCompiler,
        [string] $IncludeEnv,
        [string] $RunnerTemp
    )

    $baseArgs = Get-BaseCmakeArgs -NoPch:$NoPch -Tests:$Tests -Msbuild:$Msbuild -Ninja:$Ninja -ClangCl:$ClangCl -Arch $Arch
    return Apply-JpegPinAndEnv -CmakeArgs $baseArgs -DepsDir $DepsDir -ccacheExe $ccacheExe -IncludeEnv $IncludeEnv -RunnerTemp $RunnerTemp
}