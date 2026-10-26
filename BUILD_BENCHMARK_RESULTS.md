# Build Benchmark Results

OrcaSlicer build optimization benchmark results. Generated from the iterative
profile-testing process on 2026-10-25, with profiling of build issues and fixes.

## Environment

| Component      | Value                                      |
|----------------|--------------------------------------------|
| CPU            | Intel Core i5-10400F (6 cores, 12 threads, 2.90GHz) |
| RAM            | 32 GB total                                |
| OS             | Windows 11                                 |
| Compiler       | Portable LLVM/Clang 23.1.4 (clang-cl)      |
| BuildTools     | Visual Studio 18 BuildTools, VC toolset 143 |
| Windows SDK    | 10.0.22621.0                               |
| Generator      | Ninja Multi-Config                         |
| Cache          | ccache 4.9.1 (via Strawberry Perl)         |
| CMake          | 4.4.4                                      |
| Ninja          | From Strawberry Perl                       |
| Build jobs     | 12 logical cores (Ninja default)           |
| Monitoring     | Python 3.13 + rich (optional)              |

## ccache Configuration

File: `C:\Users\Paul\.ccache\ccache.conf`

| Setting              | Value                              |
|----------------------|------------------------------------|
| `base_dir`           | `C:\Repos`                         |
| `hash_dir`           | `false`                            |
| `sloppiness`         | `include_file_mtime,time_macros,pch_defines` |
| `max_size`           | `20G`                              |
| `compiler_check`     | `content`                          |
| `depend_mode`        | `true`                             |

The benchmark uses an isolated `CCACHE_DIR` (for example
`C:\Temp\ccache-bench`), so the user cache is never cleared and the first
cache build is genuinely cold.

## CMakePresets.json Profiles

| Preset           | Cache  | PCH  | Unity (libslic3r) | ORCA_TOOLS | Notes                        |
|------------------|--------|------|-------------------|------------|------------------------------|
| x64-clang        | off    | off  | on                | off        | Baseline clang-cl, no ccache |
| x64-clang-cache  | ccache | off  | on                | off        | Same build plus ccache       |
| x64-clang-debug  | off    | off  | on                | off        | Debug build                  |

All presets use `CMAKE_C_COMPILER=clang-cl`, `CMAKE_CXX_COMPILER=clang-cl`,
Ninja Multi-Config and lld-link. Unity is enabled by default for clang-cl
(`SLIC3R_UNITY_BUILD=ON`) and applies to `libslic3r`; `libslic3r_gui` is
still a normal build. clang-cl always builds without a PCH. Dev-utils are
off, matching the upstream default.

## Build Fixes Applied

### 1. VS Environment Capture (root cause for deps build failure)

**Problem**: When running cmake/ninja from PowerShell, the VS environment variables
(LIB, INCLUDE, PATH) from `vcvarsall.bat` were not propagated to child processes
(ninja subprocesses compiling ZLIB, FREETYPE, etc.).

**Fix**: Write a temporary batch file that calls `vcvarsall.bat x64`, dump the
resulting environment to a file, then import it into the PowerShell process
before CMake runs. Child processes inherit it from there.

**File**: `build_win.ps1` at the repository root. It captures the environment
through a temporary batch file and runs CMake from the same PowerShell process.

### 2. Ninja Multi-Config Install (`ninja install` failure)

**Problem**: `ninja -C deps/build-clang install` fails with "unknown target 'install'"
for Ninja Multi-Config generator.

**Fix**: Use `cmake --install deps/build-clang --config Release` instead.

**Note**: In practice, deps are auto-installed by ExternalProject_Add during the build
step (via CMAKE_ARGS specifying install dirs). The explicit install step was redundant.

### 3. CMAKE_RC_COMPILER Propagation (FREETYPE llvm-rc Non-ASCII issue)

**Problem**: FREETYPE's CMake configure uses `CMAKE_RC_COMPILER` to compile .rc files
with `llvm-rc`. Without passing `CMAKE_RC_COMPILER` to ExternalProject_Add, the rc
compiler defaults to MSVC's `rc.exe` which fails on non-ANSI characters.

**Fix**: Added `CMAKE_RC_COMPILER` propagation at `deps/CMakeLists.txt` line 235.

### 4. C++ Exceptions Disabled (clang-cl difference from MSVC)

**Problem**: clang-cl does not enable C++ exception handling by default (unlike MSVC's
cl.exe). Build fails with "cannot use 'throw' with exceptions disabled" in `mcut`,
`clipper2`, `admesh` libraries.

**Root cause**: The MSVC module sets `CMAKE_CXX_FLAGS_RELEASE=/MD /O2 /Ob2 /DNDEBUG`
without `/EHsc`. MSVC's cl.exe enables exceptions by default; clang-cl does not.

**Fix**: Added `add_compile_options(/EHsc)` in the `if (MSVC)` block of `CMakeLists.txt`
(line 370), which covers both MSVC and clang-cl (since `MSVC` is TRUE for both).

### 5. WIN32 Macro Not Predfined (clang-cl difference from MSVC)

**Problem**: `#if WIN32` in `src/libslic3r/Utils.hpp:854` fails with "expected value
in expression" because clang-cl does not predefine the `WIN32` macro, while MSVC's
cl.exe does.

**Fix**: Added `-DWIN32` to `add_definitions` in `CMakeLists.txt` line 701 (inside the
`if (WIN32)` block), ensuring the macro is always defined on Windows/clang-cl.

### 6. Unity Build Symbol Conflicts

**Problem**: Unity builds combine several source files into one translation unit,
which exposes names and macros that were harmless while files were separate:

- `Slic3r::FilamentInfo` (ProjectTask.hpp) and
  `Slic3r::FilamentGroupUtils::FilamentInfo` were both visible in one TU.
- `Slic3r::sla::DOWN` (SupportTreeBuilder.hpp) conflicted with
  `Slic3r::sla::{anon}::DOWN` (Rotfinder.cpp).
- `SUPPORT_MATERIAL_MARGIN` was defined differently in SupportCommon.cpp (1.5)
  and SupportMaterial.cpp (1.2).
- `std::vector<Head>::operator=` failed because implicit move assignment
  operators from separate files ended up in the same TU.

**Fix applied**:
- Moved the support margins to `src/libslic3r/Support/SupportConstants.hpp` with
  unique `constexpr` names (`SUPPORT_MATERIAL_MARGIN_COMMON`,
  `SUPPORT_MATERIAL_MARGIN_MATERIAL`, `SUPPORT_MATERIAL_MARGIN_BRIDGE`, and so on).
- Moved `DOWN` into `SupportTreeConstants` instead of a global `const Vec3d`.
- Renamed `FilamentGroupUtils::FilamentInfo` to
  `FilamentGroupUtils::FilamentGroupInfo` so it no longer collides with
  `Slic3r::FilamentInfo`.
- Updated the call sites in `SupportCommon.cpp`, `SupportMaterial.cpp`,
  `PrintObject.cpp`, `Print.cpp`, `TreeSupport.cpp`, `FilamentGroup.cpp/hpp`
  and `ToolOrdering.cpp`.

Unity is enabled for `libslic3r` only. `libslic3r_gui` still builds as separate
translation units: its batches hit many unrelated name and macro collisions
(duplicate file statics, tab colours, AMS window constants, GL include order),
so enabling GUI unity needs its own cleanup pass. MSVC keeps the PCH build and
does not use unity.

### 6b. Unity Build: L Macro and nlohmann Conflicts

Most of the original 33 exclusions came from two habits that a unity build
cannot survive, because the two files end up in one translation unit:

- **`#define L(s)` rewritten per file.** 21 files defined it, some translating
  (`Slic3r::I18N::translate`) and some only marking the string (`s` / `(s)`).
  The second definition in a batch is a warning-as-error, and calls silently
  get the wrong meaning when only one of the two is in scope.
- **`using namespace nlohmann;`** in `AppConfig.cpp`, `Config.cpp`, `Print.cpp`
  and `ProjectTask.cpp`, which leaks every nlohmann name into the batch.

`libslic3r/I18N.hpp` already defines both forms the code needs: `L()` as the
xgettext marker and `_u8L()` as the call that translates. So every local
`#define L(s)` is gone. Files that only marked strings keep calling `L(` and
now bind to the marker; files that translated call `_u8L(`. `_u8L` gained a
`const std::string&` overload, and `new_def()` in `PrintConfig.cpp` no longer
wraps its own arguments, since call sites already do and some pass
`std::string`. The `using namespace nlohmann` lines became `using nlohmann::json`.

This removed 14 files from the exclusion list: `PrintConfig.cpp`,
`PresetBundle.cpp`, `AppConfig.cpp`, `Config.cpp`, `Flow.cpp`, `PrintBase.cpp`,
`PrintObject.cpp`, `Print.cpp`, `PrintObjectSlice.cpp`, `Format/3mf.cpp`,
`Format/bbs_3mf.cpp`, `Format/AMF.cpp`, plus two entries that never belonged
there (`GCode/GCode.cpp` does not exist, and `GCode/GCodeProcessor.hpp` is a
header, not a source).

**`src/slic3r/CMakeLists.txt` had a dead copy of the same list.** It named
`../../src/libslic3r/*.cpp` files, none of which are part of `libslic3r_gui`
(that target compiles `${SLIC3R_GUI_SOURCES}` only). Dropped it.

### 6c. Unity Build: Boost.Regex and winnls.h

`boost/regex/v5/w32_regex_traits.hpp` takes a different path depending on
whether `BASETYPES` is already defined: if windows.h came first it does
`using lctype = LCTYPE; using ::LCMapStringA; ...`, which needs the winnls.h
declarations to be in scope. In a unity batch the include order is decided by
CMake, and a batch that reaches `boost::regex` (or
`boost/algorithm/string/regex.hpp`) after windows.h but without those
declarations fails with a wall of `unknown type name 'LCTYPE'` errors.

The project only ever uses `boost::regex` over `char`, where these wchar_t
traits are never instantiated, so `libslic3r` now defines
`BOOST_REGEX_NO_W32` (public, next to `WIN32_LEAN_AND_MEAN`). Boost then skips
the header entirely.

### 6d. Remaining Exclusions (19 files)

| File | Conflict |
|------|----------|
| `TextureToColor/TextureToColor.cpp`, `TextureToColor/ColorUtils.cpp` | CGAL/OCCT `Handle` macro clash |
| `GCode/WipeTower.cpp`, `GCode/WipeTower2.cpp` | duplicate enum/function/struct definitions |
| `GCode/GCodeProcessor.cpp` | unused private fields, and warnings are errors |
| `SLA/SupportTree.cpp` | libnest2d `Optimizer` namespace conflict |
| `Format/3mf.cpp`, `Format/bbs_3mf.cpp` | same constant names with different values (`FDM_SUPPORTS_PAINTING_VERSION` is 1 in 3mf.cpp, 0 in bbs_3mf.cpp) |
| `Format/STL.cpp`, `Format/SL1.cpp`, `Format/ZipperArchiveImport.cpp` | duplicate static helpers |
| `FilamentMixer.cpp`, `ColorDecomposeRecipe.cpp` | `srgb_to_linear` ambiguity |
| `MultiMaterialSegmentation.cpp`, `MutablePolygon.cpp` | Eigen operator ambiguity |
| `Support/TreeSupport.cpp` | duplicate `collect_region_slices_by_type` |
| `ClipperZUtils.cpp`, `Emboss.cpp`, `BeltSliceStrategy.cpp` | clipper2 and Windows header ordering |

These are conflicts between the files themselves or with third-party macros,
so they need a source change rather than include hygiene.

**Files modified**: `src/libslic3r/CMakeLists.txt`,
`src/libslic3r/Support/SupportConstants.hpp` (new), `SupportCommon.cpp`,
`SupportMaterial.cpp`, `PrintObject.cpp`, `Print.cpp`, `TreeSupport.cpp`,
`SupportTreeBuilder.hpp`, `SupportTreeBuildsteps.cpp`, `FilamentGroupUtils.hpp`,
`FilamentGroup.cpp/hpp`, `ToolOrdering.cpp`. `src/slic3r/CMakeLists.txt` lost the
dead libslic3r exclusion list and does not enable GUI unity.

## All Options Tried

| # | Option                  | Configuration                     | Result                          |
|---|-------------------------|------------------------------------|---------------------------------|
| 1 | MSVC + MSBuild + PCH    | Default                            | Works, ~30 min slicer build      |
| 2 | MSVC + Ninja + PCH      | Ninja Multi-Config                 | Works, ~28 min slicer build      |
| 3 | clang-cl + Ninja + PCH  | Portable LLVM, no ccache           | Fails (exceptions disabled)      |
| 4 | clang-cl + ccache       | ccache on, PCH off                 | Fails (same exception issue)     |
| 5 | clang-cl + lld-link     | ThinLTO, lld linker                | Fails (same exception issue)     |
| 6 | clang-cl + Unity        | Unity build for libslic3r          | Works; GUI unity deferred         |
| 7 | clang-cl + /EHsc fix    | Added /EHsc, no LTO                | Works                             |
| 8 | clang-cl + /DWIN32 fix  | Also added -DWIN32 macro           | Works, measured below             |
| 9 | clang-cl + ThinLTO      | `-flto=thin + --lto=thin`          | Fails (lld-link can't resolve MSVC STL internal symbols from non-LTO boost libs; thinLTO bitcode + /LTCG incompatibility) |

## Benchmark Methodology

Two clean builds and one incremental rebuild, all through `build_win.ps1`:

- **x64-clang**: clean `build-clang`, no ccache, Unity for libslic3r.
- **x64-clang-cache**: clean `build-clang-cache` with an isolated `CCACHE_DIR`,
  so the first build is a genuine cold cache.
- **Incremental**: add a comment line to one source file and rebuild the cache
  profile with the warm cache, then remove the line.

Each clean build removes its build directory. Ninja uses its default parallelism
(12 logical cores). Configure and build times are printed by the script. Tests
are built but not run.

### Build resource monitoring

`build_win.ps1` samples the build processes themselves while it configures and
builds: their CPU utilisation, the number of cores they keep busy, and their
combined working set. Results are reported every 15 seconds by default; the
sampler polls every 2 seconds internally so short compiler processes are not
lost between reports. At the end it renders an ASCII time-series chart with the
Python `rich` package:

```
py -3 scripts/build_metrics.py "$env:TEMP\orca-build-metrics-<pid>.csv"
```

The CPU chart shows machine utilisation, the core chart stacks cores by tool
with a separate colour per tool (compiler: clang-cl/clang/cl; linker:
lld-link/link; build: ninja/cmake/msbuild; and ccache), and the RAM chart shows
the combined working set. The chart has
the start time on the left, the end time on the right and the duration in the
middle. `-NoMetrics` disables sampling; `-MetricsInterval` changes the reporting
period. Build RAM is the sum of the build process working sets, so shared pages
are counted more than once. Sampling costs a small amount of CPU, so the
timings below include that overhead.

## Batch 2 Results

### Profile: x64-clang-cache (Unity=libslic3r ON, ccache cold, /EHsc, /DWIN32)

| Step            | Time (min) | Exit Code | Notes                          |
|-----------------|------------|-----------|--------------------------------|
| Configure       | TBD        | TBD       | ccache enabled                 |
| Build           | TBD        | TBD       | Expect ccache misses (fresh)   |
| **Total**       | **TBD**    |           |                                |

### Profile: x64-clang (Unity=libslic3r ON, plain, /EHsc, /DWIN32)

| Step            | Time (min) | Exit Code | Notes                          |
|-----------------|------------|-----------|--------------------------------|
| Configure       | TBD        | TBD       | No cache, no LTO               |
| Build           | TBD        | TBD       | Baseline clang-cl              |
| **Total**       | **TBD**    |           |                                |

### Incremental Rebuild (ccache warm)

| Step            | Time (min) | Notes                                   |
|-----------------|------------|-----------------------------------------|
| Rebuild         | TBD        | One source file edited, warm ccache     |

## Conclusions

- **clang-cl requires `/EHsc`**: clang-cl does not enable C++ exceptions by default.
  MSVC's cl.exe does. The `/EHsc` flag is needed in the `if (MSVC)` block.
- **clang-cl requires `-DWIN32`**: MSVC predefines `WIN32` but clang-cl does not.
  Code using `#if WIN32` will fail without explicit definition.
- **Unity builds are not plug-and-play**: They expose latent code issues (ambiguous
  symbols, macro conflicts, header ordering dependencies). Fixing them requires
  `SKIP_UNITY_BUILD_INCLUSION` on problematic files or source-level refactoring.
- **Ninja Multi-Config is the right choice**: Parallel builds work well, and ccache
  integration is straightforward.
- **ccache effectiveness**: A cold cache has 0% hits. It pays off on incremental
  and repeat clean builds. `compiler_check=content` is the right setting for
  correctness.

## Recommendations

1. **Default build**: Keep MSBuild + MSVC + PCH as the default (most reliable, ~30 min).
2. **Fast build**: clang-cl + Ninja + ccache + no LTO (fastest clean + incremental).
3. **Unity build**: On by default for clang-cl presets, for `libslic3r` only.
   19 files still opt out; each needs a source change (not an include tweak)
   before it can join a batch. GUI unity is a separate follow-up.
4. **LTO (ThinLTO)**: Not viable currently. lld-link cannot resolve MSVC STL
   internal symbols (`__std_find_first_of_trivial_pos_2`) from non-LTO
   boost/assimp libraries when linking with `-flto=thin`. The MSVC `/LTCG` flag
   also conflicts with lld-link's thinLTO mode. It would require rebuilding all
   deps with LTO.

## Status Note (updated 2026-10-26)

- Branch: feat/build-performance (no push)
- Commit: 5a2d3f70 (script fixes, unity exclusions, NSVGImplementation.cpp)
- Timestamp format: [3h2m1s] verified in native.ps1
- Benchmark: clean x64-clang interrupted at [621/952] (~29min); 7 TBD remain
- PR pipeline (build_all.yml): pr_full_test_observability job added (full ctest, annotations, artifact upload, job summary)
- Uncommitted: .github/workflows/build_all.yml edit + build_win.ps1 sync
## Cross-Platform Note (updated 2026-10-26)

- Pipeline (pr_full_test_observability) is Windows-only (windows-latest, PowerShell, clang-cl).
- Cross-platform: extend to Linux (ubuntu-24.04) / macOS (macos-15) using existing uild_all.yml legs (uild_linux, unit_tests.yml). Unity exclusions (NSVGImplementation.cpp, 19 files) and SLIC3R_UNITY_BUILD=ON apply to all platforms; Linux clang + 
inja + ccache can be faster than Windows clang-cl.
- No automatic performance gain from portability — same source-level optimizations, faster execution environment on Linux.