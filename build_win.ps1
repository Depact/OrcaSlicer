<#
.SYNOPSIS
    Build OrcaSlicer on Windows with clang-cl + Ninja (+ optional ccache).
.DESCRIPTION
    Run with -Help for a one-page reference of every option.
#>

param(
    [ValidateSet("x64-clang", "x64-clang-cache", "x64-clang-debug")]
    [string]$Preset,
    [string]$Config = "Release",
    [string]$Target,
    [switch]$Clean,
    [switch]$CleanDeps,
    [switch]$NoMetrics,
    [switch]$PackDeps,
    [switch]$SkipDeps,
    [ValidateRange(1, 10)]
    [int]$MetricsInterval = 15,
    [ValidateRange(1, 64)]
    [int]$MaxJobs = 0,
    [switch]$Help,
    [switch]$Deps = $true,
    [switch]$Slicer = $true,
    [switch]$Tests = $true,
    [switch]$ClangCl = $true,
    [switch]$Ninja = $true,
    [switch]$Msvc,
    [switch]$Msbuild,
    [string]$ClangPath,
    [string]$Cache,
    [switch]$NoPch,
    [switch]$NoConfigure,
    [switch]$InstallSlicer,
    [switch]$Launch,
    [switch]$LaunchWait,
    [string]$DepsDir,
    [string]$SlicerDir,
    [string]$Arch
)

if ($Help) {
    @'
build_win.ps1 - Build OrcaSlicer on Windows (clang-cl + Ninja + optional ccache)

USAGE
  .\build_win.ps1 [options]
  .\build_win.ps1 -Help

OPTIONS
  -Preset <name>
      Which build tree to use.
        x64-clang        clang-cl, no ccache          (build-clang)
        x64-clang-cache  clang-cl + ccache            (build-clang)
        x64-clang-debug  debug configuration          (build-dbg-clang)
      Omit it and ccache is enabled automatically when it is on PATH.

  -Config <name>
      CMake configuration to build. Default: Release.

  -Target <name>
      Build one target instead of everything, for example libslic3r.
      Default: all.

  -Clean
      Delete the active build directory before configuring, so it is set up
      from scratch. Dependencies are left alone. (default: off)

  -CleanDeps
      Delete the dependency tree (deps/build, or deps/build-arm64 on ARM64) so
      the next build rebuilds every dependency. Slow; pair it with -Clean. (default: off)

  -NoMetrics
      Skip the CPU / cores / RAM sampler and the resource chart afterwards. (default: off)

  -PackDeps
      Check and build the dependencies, write deps/OrcaSlicer_dep.zip, then
      exit without building OrcaSlicer. (default: off)

  -SkipDeps
      Trust whatever is already in deps/ and skip the dependency check. (default: off)

  -NoPch
      Configure with SLIC3R_PCH=OFF. (default: off)

  -NoConfigure
      Build the existing tree without re-running CMake configure. (default: off)

  -InstallSlicer
      Run the install target afterwards, which fills <build>/OrcaSlicer with a
      runnable tree. (default: off)

  -Launch
      Launch OrcaSlicer after successful build. Auto-enables -InstallSlicer. (default: off)
  -LaunchWait
      Wait for OrcaSlicer to exit before returning. Implies -Launch (and -InstallSlicer). (default: off)

  -MetricsInterval <n>
      Seconds between sampler rows (1-10). Default: 15, or 3 for the
      x64-clang-cache preset.

  -MaxJobs <n>
      Cap parallel compile jobs (1-64). Default: 0, meaning auto.

  ACTION SWITCHES (defaults: on)
  -Deps
      Build the dependencies and stop; the dep tree is the only output.
      A bare run builds dependencies, slicer and tests. (default: on)

  -Slicer
      Build OrcaSlicer. (default: on)

  -Tests
      Build unit tests. (default: on)

  TOOLCHAIN SWITCHES
  -ClangCl
      Use clang-cl compiler. (default: on)

  -Ninja
      Use Ninja generator (faster). (default: on)

  -Msvc
      Use MSVC compiler. (default: off)

  -Msbuild
      Use MSBuild generator. (default: off)

  -Cache <name>
      Enable ccache or sccache. (default: auto - enabled if ccache found in PATH)

  -DepsDir <path>
      Override dependency build directory. (default: deps/build or deps/build-arm64)

  -SlicerDir <path>
      Override slicer build directory. (default: build or build-arm64)

  -Arch <name>
      Target architecture. Default: x64 (or ARM64 on ARM64 hardware).

  -Config <name>
      CMake configuration to build. Default: Release.

  -Help
      Print this page and exit.

ENVIRONMENT
  ORCA_CLANG_CL   Path to clang-cl.exe (otherwise PATH or the VS LLVM bundle).
  ORCA_CMAKE      Path to cmake.exe (otherwise PATH).
  ORCA_NINJA      Path to ninja.exe (otherwise PATH).
  ORCA_CCACHE     Path to ccache.exe (otherwise PATH).

EXAMPLES
  .\build_win.ps1
      Build everything with the best preset available on this machine.

  .\build_win.ps1 -Preset x64-clang-cache -Target libslic3r
      Rebuild only the slicing library through ccache.

  .\build_win.ps1 -CleanDeps -PackDeps
      Rebuild the dependencies from scratch and pack them into a zip.

  .\build_win.ps1 -NoMetrics -MaxJobs 8
      Same build without the resource monitor, eight jobs at a time.
'@ | Write-Host
    exit 0
}

# --- Derive toolchain from individual flags ---
# When Preset is given, translate it to flags. Otherwise flags stand alone.
if ($Preset) {
    switch ($Preset) {
        "x64-clang"       { $ClangCl = $true; $Ninja = $true; $Arch = "x64" }
        "x64-clang-cache" { $ClangCl = $true; $Ninja = $true; $Cache = "ccache"; $Arch = "x64" }
        "x64-clang-debug" { $ClangCl = $true; $Ninja = $true; $Config = "Debug"; $Arch = "x64" }
    }
}

# Defaults
if (-not $Arch) { $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "ARM64" } else { "x64" } }
if (-not $Config) { $Config = "Release" }
# The dependency tree the CI caches as deps/build, or deps/build-arm64 on ARM64.
# -DepsDir overrides it; build_deps.yml and build_orca.yml pass the cache path.
if (-not $DepsDir) {
    $DepsDir = if ($Arch -eq "ARM64") { "deps/build-arm64" } else { "deps/build" }
}
$DepsDir = $DepsDir.Replace('\', '/')

# -Deps on its own means "dependencies only". build_deps.yml calls it that way
# and uploads nothing but the dep tree, so building the slicer there is pure
# waste. Any other action switch keeps the defaults, which is what build_orca.yml
# (-Slicer -Tests) needs so the dep tree is still validated before configure.
$otherAction = $PSBoundParameters.ContainsKey('Slicer') -or
               $PSBoundParameters.ContainsKey('Tests') -or
               $PSBoundParameters.ContainsKey('PackDeps')
if ($PSBoundParameters.ContainsKey('Deps') -and -not $otherAction) {
    $Slicer = $false
    $Tests = $false
}

# Action defaults are on, so a bare run builds everything. This only rejects a
# call that switched every action off.
if (-not ($Deps -or $Slicer -or $PackDeps)) {
    Write-Host "Nothing to do. Pick an action: -Deps, -Slicer or -PackDeps. Run -Help for the full list." -ForegroundColor Yellow
    exit 1
}


# --- Validation ---
if ($ClangCl -and $Msvc) {
    throw "-ClangCl and -Msvc select different compilers."
}
if ($Ninja -and $Msbuild) {
    throw "-Ninja and -Msbuild select different generators."
}
if ($ClangPath -and -not $Ninja) {
    throw "-ClangPath needs the Ninja generator; do not combine it with -Msbuild."
}

# -ClangPath is the command-line form of ORCA_CLANG_CL, which the toolchain
# resolver reads. Nothing below needs the flag itself.
if ($ClangPath) { $env:ORCA_CLANG_CL = $ClangPath }

# Default generator: Ninja unless Msbuild
if (-not $Ninja -and -not $Msbuild) {
    $Ninja = $true
}

# Default compiler: clang-cl when Ninja, MSVC when Msbuild
if (-not $ClangCl -and -not $Msvc) {
    if ($Ninja) { $ClangCl = $true }
    else { $Msvc = $true }
}

# Display preset name (derived from flags when Preset not given)
$displayPreset = $Preset

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$UnitsDir = Join-Path $RepoRoot "scripts\build_win_steps"

. (Join-Path $UnitsDir "native.ps1")
. (Join-Path $UnitsDir "toolchain.ps1")
. (Join-Path $UnitsDir "vsenv.ps1")
. (Join-Path $UnitsDir "deps.ps1")
. (Join-Path $UnitsDir "build.ps1")
. (Join-Path $UnitsDir "render.ps1")
# Auto-enable InstallSlicer when Launch/LaunchWait is used (after render.ps1 for Write-Status)
# -LaunchWait alone must launch too: the switch only says "wait afterwards".
if ($LaunchWait) { $Launch = $true }
if ($Launch) {
    if (-not $InstallSlicer) {
        Write-Status "auto" "InstallSlicer enabled (required by -Launch/-LaunchWait)"
        $InstallSlicer = $true
    }
}
. (Join-Path $UnitsDir "launch.ps1")

# Rendering (Write-Step, Write-Status, Format-Sparkline) lives in render.ps1.

# CI prepends a Strawberry Perl download so OpenSSL's Configure finds perl, and
# that copy ships a cmake.exe that shadows the official one plus a ccache.exe the
# build must not use. A locally installed Strawberry sits after the real CMake on
# PATH and its ccache is the only one the user has, so strip the directory in CI
# only. c\perl\bin is left alone either way for the dep scripts.
if ($env:RUNNER_TEMP) {
    $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notlike '*Strawberry\c\bin' }) -join ';'
}

# Auto-enable ccache if available and not explicitly disabled. Placed after
# the generator/compiler defaults and the render.ps1 dot-source, which is
# what defines Write-Status.
if (-not $Cache -or $Cache -eq "") {
    $ccacheCmd = Get-Command ccache -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ccacheCmd) {
        $Cache = "ccache"
        Write-Status "ccache" "Auto-enabled (found at $($ccacheCmd.Source))"
    } else {
        Write-Warning "ccache not found in PATH - incremental builds will not be cached. Install with 'winget install ccache' for faster rebuilds."
    }
}

# Cache only valid with clang-cl + Ninja
if ($Cache -and $Cache -ne "off") {
    if (-not $Ninja -or -not $ClangCl) {
        throw "-Cache needs -ClangCl and -Ninja."
    }
    # Point ccache at a directory that exists now: CMake reads CCACHE_DIR at
    # configure time, and the CI cache step needs a real path to archive.
    $ccacheDir = if ($env:CCACHE_DIR) { $env:CCACHE_DIR } else { Join-Path $env:USERPROFILE ".ccache" }
    if (-not (Test-Path $ccacheDir)) { New-Item -ItemType Directory -Force -Path $ccacheDir | Out-Null }
    $env:CCACHE_DIR = $ccacheDir
    Write-Status "ccache" "Cache directory: $ccacheDir"
}
$started = Get-Date
$global:BuildStarted = $started

$configureStr = "-"
$buildStr     = "-"
$totalStr     = "-"
$buildSucceeded = $false

Push-Location $RepoRoot

try {
    # --- 1. Locate Visual Studio and the toolchain ---
    Write-Step "[1/7] Locating Visual Studio and tools..."

    $vsInstall = Find-VsInstall
    if (-not $vsInstall) {
        throw "Visual Studio 2022 or newer with the C++ toolset was not found. Install the 'Desktop development with C++' workload."
    }
    Write-Status "vs"      $vsInstall

    # Resolve compiler
    $clangClExe = $null
    $clExe   = $null
    if ($ClangCl) {
        if ($env:ORCA_CLANG_CL) {
            if (-not (Test-Path $env:ORCA_CLANG_CL)) { throw "ORCA_CLANG_CL points at '$env:ORCA_CLANG_CL', which does not exist." }
            $clangClExe = (Resolve-Path $env:ORCA_CLANG_CL).Path
        } else {
            $clangCmd = Get-Command clang-cl -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($clangCmd) {
                $clangClExe = $clangCmd.Source
            } else {
                $vsClang = Join-Path $vsInstall "VC\Tools\Llvm\x64\bin\clang-cl.exe"
                if (Test-Path $vsClang) { $clangClExe = $vsClang }
            }
        }
        if (-not $clangClExe) {
            throw "clang-cl was not found. Install LLVM and add it to PATH, set ORCA_CLANG_CL, or install the C++ Clang tools for Windows component in Visual Studio."
        }
    }
    if ($Msvc) {
        # Prefer the toolset belonging to the VS that vswhere selected. A stale x86
        # entry on PATH otherwise wins and CMake happily configures a 32-bit compiler.
        # Join-Path does not glob, so resolve the toolset with Get-ChildItem. The host
        # arch is the machine running the build, not the target.
        $hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
        $targetArch = if ($Arch -eq "ARM64") { "arm64" } else { "x64" }
        $vsCl = Get-ChildItem -Path (Join-Path $vsInstall "VC\Tools\MSVC\*\bin\Host$hostArch\$targetArch\cl.exe") -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($vsCl) {
            $clExe = $vsCl.FullName
        } else {
            $clCmd = Get-Command cl -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($clCmd) { $clExe = $clCmd.Source }
        }
        if (-not $clExe) {
            throw "cl.exe was not found. Install Visual Studio with the C++ workload, or point -ClangPath/ORCA_CLANG_CL at clang-cl.exe."
        }
        Write-Status "cl" $clExe
    }

    try {
        $cmake = Resolve-Tool "cmake" "ORCA_CMAKE" "Install CMake 3.21 or newer and add it to PATH, or set ORCA_CMAKE."
    } catch {
        # Official CMake not on PATH after stripping Strawberry's bin dirs. Download it
        # from GitHub releases so the slicer build has a working CMake (Strawberry's
        # cmake has a broken FindIconv.cmake that fails the slicer configure).
        Write-Warning "Official CMake not found on PATH. Downloading CMake from GitHub releases..."
        $cmakeVersion = "3.29.3"
        $cmakeDir = Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }) "CMake-$cmakeVersion"
        $cmakeZip = Join-Path $env:TEMP "cmake-$cmakeVersion-windows-x86_64.zip"
        $cmakeUrl = "https://github.com/Kitware/CMake/releases/download/v$cmakeVersion/cmake-$cmakeVersion-windows-x86_64.zip"
        if (-not (Test-Path $cmakeDir)) {
            Invoke-WebRequest -Uri $cmakeUrl -OutFile $cmakeZip -TimeoutSec 300
            Expand-Archive -Path $cmakeZip -DestinationPath $env:TEMP -Force
            Rename-Item -Path (Join-Path $env:TEMP "cmake-$cmakeVersion-windows-x86_64") -NewName $cmakeDir -Force
        }
        $cmake = Join-Path $cmakeDir "bin\cmake.exe"
        if (-not (Test-Path $cmake)) {
            throw "Downloaded CMake not found at $cmake"
        }
        Write-Status "cmake" "$cmake (downloaded from GitHub releases)"
    }
    if ($Ninja) {
        $ninjaExe = Resolve-Tool "ninja" "ORCA_NINJA" "Install Ninja and add it to PATH, or set ORCA_NINJA."
    } else {
        $ninjaExe = $null
    }
    $ccacheExe = $null
    if ($Cache -and $Cache -ne "off") {
        if ($env:ORCA_CCACHE) {
            if (-not (Test-Path $env:ORCA_CCACHE)) { throw "ORCA_CCACHE points at '$env:ORCA_CCACHE', which does not exist." }
            $ccacheExe = (Resolve-Path $env:ORCA_CCACHE).Path
        } else {
            $ccacheCmd = Get-Command ccache -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ccacheCmd) { $ccacheExe = $ccacheCmd.Source }
        }
        if (-not $ccacheExe) { throw "ccache was not found. Install it, add it to PATH, or set ORCA_CCACHE." }
        Write-Status "ccache" $ccacheExe
    }

    $cmakeVersion = (& $cmake --version | Select-Object -First 1)
    if ($cmakeVersion -match "cmake version (\d+)\.(\d+)") {
        if ([int]$Matches[1] -lt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -lt 21)) {
            throw "CMake 3.21 or newer is required, found: $cmakeVersion"
        }
    }

    Write-Status "clang-cl" $clangClExe
    Write-Status "cmake"    $cmake
    Write-Status "ninja"    $ninjaExe
    if ($ccacheExe) { Write-Status "ccache" $ccacheExe }

    # --- 2. Choose build tree and target ---
    Write-Step "[2/7] Determining build configuration..."

    # Build tree names per configuration
    $configDirs = @{
        "release"         = "build"
        "debug"           = "build-dbg"
        "relwithdebinfo"  = "build-dbginfo"
        "minsizerel"      = "build-minsize"
    }
    $configLower = $Config.ToLower()
    if (-not $configDirs.ContainsKey($configLower)) {
        throw "Unknown configuration '$Config'. Known configurations: release, debug, relwithdebinfo, minsizerel."
    }
    $treeName = $configDirs[$configLower]

    # Suffixes for compiler and architecture
    if ($ClangCl) { $treeName += "-clang" }
    if ($Arch -eq "ARM64") { $treeName += "-arm64" }

    $buildDir = $treeName
    if ($SlicerDir) { $buildDir = $SlicerDir }

    if (-not $Target) { $Target = "all" }

    # Cache preset name for display (from flags)
    $displayPreset = if ($Preset) { $Preset }
                     elseif ($ClangCl -and $Ninja -and $Cache -eq "ccache") { "x64-clang-cache" }
                     elseif ($ClangCl -and $Ninja) { "x64-clang" }
                     elseif ($Msvc -and $Ninja) { "x64-msvc" }
                     elseif ($Msvc -and $Msbuild) { "x64-msbuild" }
                     else { "custom" }

    if ($Cache -eq "ccache" -and -not $ccacheExe) {
        throw "ccache is required for cache builds. Install it, add it to PATH, or set ORCA_CCACHE."
    }

    Write-Status "preset"  "$displayPreset ($buildDir)"
    Write-Status "target"  "$Target ($Config)"
    Write-Status "arch"    $Arch
    Write-Status "compiler" $(if ($ClangCl) { "clang-cl" } else { "cl" })
    Write-Status "generator" $(if ($Ninja) { "Ninja" } else { "MSBuild" })
    Write-Status "jobs"    $(if ($MaxJobs -gt 0) { "$MaxJobs" } else { "auto" })

    if ($CleanDeps -and (Test-Path $DepsDir)) {
        Write-Status "clean" "Removing $DepsDir"
        Remove-Item $DepsDir -Recurse -Force
    }
    if ($Clean -and (Test-Path $buildDir)) {
        Write-Status "clean" "Removing $buildDir"
        Remove-Item $buildDir -Recurse -Force
    }

    # --- 3. Capture the Visual Studio environment ---
    Write-Step "[3/7] Setting up the Visual Studio environment..."
    Capture-VsEnvironment -VsInstall $vsInstall -Arch $Arch

    $toolDirs = @($clangClExe, $clExe, $cmake, $ninjaExe, $ccacheExe) |
        Where-Object { $_ } |
        ForEach-Object { Split-Path -Parent $_ } |
        Select-Object -Unique
    $env:PATH = ($toolDirs -join ";") + ";" + $env:PATH
    Write-Status "env" "VS $Arch environment captured, tool dirs prepended to PATH"

    # --- 4. Start resource monitor ---
    if (-not $NoMetrics) {
        Write-Step "[4/7] Starting build-process resource monitor..."
        Start-ResourceMonitor -IntervalSeconds $MetricsInterval
    } else {
        Write-Step "[4/7] Resource monitoring disabled (-NoMetrics)"
    }

    # --- 5. Ensure dependencies are built ---
    if ($SkipDeps) {
        Write-Step "[5/7] Skipping dependencies (-SkipDeps)"
    } else {
        Write-Step "[5/7] Checking dependencies..."
        # One deps tree per architecture, matching the path the CI cache restores
        # (deps/build/OrcaSlicer_dep, or deps/build-arm64/... on ARM64).
        $depsBuildDir = $DepsDir
        $depsCompiler = if ($ClangCl) { $clangClExe } else { $clExe }
        Check-Dependencies -Cmake $cmake -Compiler $depsCompiler -Config $Config -DepsBuildDir $depsBuildDir -MaxJobs $MaxJobs

        if ($PackDeps) {
            Write-Step "[5.1/7] Packing dependencies..."
            $zipPath = Pack-Dependencies -DepsBuildDir $depsBuildDir -OutputPath (Join-Path $RepoRoot "deps\OrcaSlicer_dep.zip")
            Write-Host ""
            Write-Host "  Dependencies packed successfully!" -ForegroundColor Green
            Write-Host "  Archive: $zipPath"
            return
        }
    }

    # -Deps on its own stops here: the dep tree is the whole output, and the CI
    # deps job only uploads that tree.
    if (-not $Slicer) {
        Stop-ResourceMonitor
        Write-Step "[6/6] Dependencies ready in $DepsDir"
        return
    }

    $timing = $null
    if ($Slicer) {
        # --- 6. Configure and build ---
        Write-Step "[6/7] Configuring and building..."
        # Determine the VS generator from the install path
        # Path is like C:\Program Files\Microsoft Visual Studio\2026\Enterprise
        # Match \18\ pattern (backslash, version digits, backslash)
    $vsMajor = if ($vsInstall -match '\\(1[6-9]|[2-9][0-9])\\') { $matches[0].Trim('\') } else { "17" }
        Write-Status "vsMajor" $vsMajor
        $vsGenMap = @{ 16 = "Visual Studio 16 2019"; 17 = "Visual Studio 17 2022"; 18 = "Visual Studio 18 2026" }
        $generator = if ($Msbuild) { $vsGenMap[$vsMajor] } else { "Ninja Multi-Config" }
        if (-not $generator) { $generator = "Visual Studio 17 2022" }
        Write-Status "generator" $generator
        $compiler = if ($ClangCl) { $clangClExe } else { $clExe }
        $cmakeArgs = @()
        if ($NoPch) { $cmakeArgs += "-DSLIC3R_PCH=OFF" }
        if ($Tests) {
            $cmakeArgs += "-DBUILD_TESTS=ON"
        }
        # Enable ORCA_TOOLS to build generate_system_cache.exe for preset cache generation
        $cmakeArgs += "-DORCA_TOOLS=ON"
        # MSBuild generator needs the -A architecture flag
        if ($Msbuild) {
            $cmakeArgs += "-A", $Arch
        }
        # Ninja + clang-cl under VS generator needs ClangCL toolset
        if (-not $Ninja -and $ClangCl) {
            $cmakeArgs += "-T", "ClangCL"
        }
        # For MSBuild generator, don't pass compiler explicitly; use toolset instead
        $configureCompiler = if ($Msbuild) { $null } else { $compiler }
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
            # CMake writes install(DIRECTORY) paths into cmake_install.cmake
            # verbatim, where a backslash becomes an escape (\a in \a\...).
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
        if ($env:INCLUDE) {
            $env:INCLUDE = ($env:INCLUDE -split ';' | Where-Object { $_ -notlike '*Strawberry*' }) -join ';'
        }
        # Strawberry Perl is needed for cmake.exe (used by Configure-Build), but
        # its c\include dir contains an older jpeglib.h (no JCS_EXT_RGBA) that
        # shadows deps' libjpeg-turbo. Delete only c\include so cmake.exe keeps
        # working but CMake can't find the stale JPEG header.
        if ($env:RUNNER_TEMP) {
            $strawberryInclude = Join-Path $env:RUNNER_TEMP 'Strawberry\c\include'
            if (Test-Path $strawberryInclude -PathType Container) {
                Remove-Item $strawberryInclude -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $timing = Configure-Build -Cmake $cmake -BuildDir $buildDir -Config $Config -Target $Target `
                                  -NoConfigure:$NoConfigure -MaxJobs $MaxJobs `
                                  -Generator $generator -Compiler $configureCompiler -CMakeArgs $cmakeArgs

        # --- 6.1 Install ---
        $installTime = [TimeSpan]::Zero
        if ($InstallSlicer) {
            Write-Step "[6.1/7] Installing into $buildDir/OrcaSlicer..."
            $installTime = Install-Build -Cmake $cmake -BuildDir $buildDir -Config $Config
        }

        # --- 7. Build summary ---
        Write-Host ""
        Write-Host ""

        Write-Step "[7/7] Build finished"

        Show-CcacheStats -CcachePath $ccacheExe

        # --- 8. Resource summary ---
        Stop-ResourceMonitor
        Show-ResourceSummary

        # --- 9. Success summary ---
        $total = $timing.ConfigureTime + $timing.BuildTime + $installTime
        $configureStr = Format-Duration $timing.ConfigureTime
        $buildStr     = Format-Duration $timing.BuildTime
        $totalStr     = Format-Duration $total

        Write-Host ("  Total:     {0}" -f $totalStr)
        Write-Host ("  Configure: {0}" -f $configureStr)
        Write-Host ("  Build:     {0}" -f $buildStr)
        if ($installTime.TotalSeconds -ge 1) {
            Write-Host ("  Install:   {0}" -f (Format-Duration $installTime))
        }

        $buildSucceeded = $true
        # --- 6.2 Launch ---
        # InstallSlicer is guaranteed here (auto-enabled above), so the install
        # tree always exists by the time Launch-Application looks for the exe.
        if ($Launch -and $buildSucceeded) {
            Launch-Application -BuildDir $buildDir -Config $Config -Wait:$LaunchWait
        }



    }
} catch {
    Stop-ResourceMonitor
    Show-ResourceSummary

    Write-Host ""
    Write-Host "BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo) {
        Write-Host ("COMMAND: " + $_.InvocationInfo.MyCommand) -ForegroundColor DarkRed
        Write-Host ("INVOKED AS: " + $_.InvocationInfo.InvocationName) -ForegroundColor DarkRed
        Write-Host ("AT LINE: " + $_.InvocationInfo.ScriptLineNumber + " -> " + "$($_.InvocationInfo.Line)".Trim()) -ForegroundColor DarkRed
        Write-Host ("EXCEPTION: " + $_.Exception.GetType().FullName) -ForegroundColor DarkRed
    }
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }
    exit 1
} finally {
    Stop-ResourceMonitor
    Pop-Location
}

exit 0



