# Branch Changes: `feat/build-performance-squashed-polygon` vs `main`

## Summary
Branch: `feat/build-performance-squashed-polygon` (fork: `Depact/OrcaSlicer`)
Base: `main` (upstream `OrcaSlicer/OrcaSlicer`)
Commits: ~15 commits squashed into single logical changes
Files changed: 25 files, +2617/-2864 lines

---

## ✅ REASONABLE CHANGES (Ready / Intentional)

### 1. Build Script Refactor (Core)
| File | Change | Rationale |
|------|--------|-----------|
| `build_win.ps1` | 654→273 lines, split into 10 modules | Modularity, maintainability, ≤300 lines/file |
| `scripts/build_win_steps/build_win_orchestrator.ps1` | New: `Invoke-BuildStep`, resource monitor, log paths | Streaming output, resource tracking |
| `scripts/build_win_steps/build_win_toolchain_resolver.ps1` | New: `Resolve-Toolchain`, `Find-VsInstall`, `Resolve-Compiler`, `Resolve-Cmake` | Toolchain isolation |
| `scripts/build_win_steps/build_win_build_layout_resolver.ps1` | New: `Resolve-BuildLayout`, `Resolve-BuildTree`, `Resolve-BuildPreset` | Layout logic isolation |
| `scripts/build_win_steps/build_win_vs_environment_capture.ps1` | New: `Capture-VsEnvironment`, `Ensure-Ml64InPath`, `Repair-VsLibPath` | VS env capture isolation |
| `scripts/build_win_steps/build_win_dependency_tasks.ps1` | New: `Check-Dependencies`, `Test-DepsTree`, `Invoke-DepsBuild`, `Pack-Dependencies` | Deps logic isolation |
| `scripts/build_win_steps/build_win_cmake_invocation.ps1` | New: `Configure-Build`, `Install-Build`, `Invoke-ConfigureStep`, `Invoke-BuildTarget` | CMake invoke isolation |
| `scripts/build_win_steps/build_win_console_output.ps1` | New: `Show-BuildSummary`, `Format-Sparkline`, `Show-CcacheStats` | Console output isolation |
| `scripts/build_win_steps/build_win_slicer_arg_builder.ps1` | New: `Get-SlicerConfigureArgs`, `Pin-JpegToDeps`, `Add-CcacheLaunchers` | Slicer-specific CMake args |
| `scripts/build_win_steps/build_win_launch.ps1` | New: `Launch-Application` | Launch isolation |
| `scripts/build_win_steps/build_win_resource_sampler.ps1` | New: Resource sampler (background job) | Resource monitoring |

### 2. Code Quality & Style
| File | Change | Rationale |
|------|--------|-----------|
| `scripts/check_ps1_limits.ps1` | New: Enforces ≤300 lines/file, ≤70 lines/function | Enforced in CI |
| `scripts/build_win_steps/build_win_vs_environment_capture.ps1` | Extracted `Resolve-VcvarsallArch`, `Build-VcvarsallBatchBody`, `Ensure-VsLibPathHasArch` | Self-documenting |
| `scripts/build_win_steps/build_win_slicer_arg_builder.ps1` | Extracted `Pin-JpegToDeps`, `Add-CcacheLaunchers`, `Strip-StrawberryIncludeFromIncludeEnv`, `Remove-StrawberryJpegInclude` | Self-documenting |
| `scripts/build_win_steps/build_win_toolchain_resolver.ps1` | Extracted `Download-CmakeFromGitHub` | Self-documenting |
| `scripts/build_win_steps/build_win_resource_sampler.ps1` | Extracted `Update-PeakRssSplit` | Self-documenting |
| `scripts/build_preset_cache.ps1` | Extracted `Remove-StaleCaches`, `Remove-EmptyDirsDeepestFirst`, `Remove-PresetJsonsListedInProfile` | Self-documenting |

### 3. CI/CD Improvements
| File | Change | Rationale |
|------|--------|-----------|
| `.github/workflows/build_orca.yml` | Removed `runner.os != 'Windows'` from "Enable compiler cache" | **Enables ccache on Windows** (critical fix) |
| `.github/workflows/build_orca.yml` | Self-hosted vs GitHub-hosted cache separation | Proper cache isolation |
| `.github/workflows/build_orca.yml` | Strawberry Perl download + PATH prepending | Fixes cmake/perl on hosted runners |
| `.github/workflows/build_orca.yml` | `actions/cache` key/prefix improvements | Better cache keys, fallback chains |
| `.github/workflows/build_orca.yml` | Windows MSVC build: `windows-latest` → `windows-2022` | Explicit version |
| `.github/workflows/build_all.yml` | `check_ps1_limits.ps1` in CI gate | Enforces style limits |
| `.github/workflows/build_all.yml` | SELF_HOSTED routing across all jobs | Proper runner selection |
| `.github/workflows/build_check_cache.yml` | Sparse-checkout disable + gzip PATH fix | Self-hosted compatibility |
| `.github/workflows/build_check_cache.yml` | Cache key/prefix improvements | Better cache hits |
| `.github/workflows/build_orca.yml` | Windows: Strawberry Perl portable zip + PATH prepend | Fixes perl/cmke on hosted |
| `.github/workflows/build_orca.yml` | ccache on Windows enabled (removed OS exclusion) | **Critical fix** |
| `.github/workflows/build_orca.yml` | ccache action: self-hosted + cloud cache paths | Proper cache paths |
| `.github/workflows/build_orca.yml` | Windows: `pwsh` → `powershell` | Consistency |
| `.github/workflows/build_orca.yml` | Windows: Strawberry Perl portable zip download | Fixes perl on hosted |
| `.github/workflows/build_orca.yml` | `build_win.ps1` replaces `build_win.bat` | Modern script |
| `.github/workflows/build_orca.yml` | Windows: `-Clean` flag support | Incremental builds |
| `.github/workflows/build_orca.yml` | Windows: `-Cache` flag for ccache | ccache control |
| `.github/workflows/build_orca.yml` | Windows: `InstallSlicer` + `Launch` flags | Auto-install on launch |
| `.github/workflows/build_orca.yml` | NSIS cache: self-hosted aware | Cache isolation |
| `.github/workflows/build_orca.yml` | Signing: `!vars.SELF_HOSTED` guards | Hosted-only signing |
| `.github/workflows/build_orca.yml` | Deploy: `!vars.SELF_HOSTED` guards | Hosted-only deploy |
| `.github/workflows/build_orca.yml` | Linux: `build_linux.sh -istrlL` (no P) | Simplified flags |
| `.github/workflows/build_orca.yml` | Linux: Build system preset cache step added | Preset caching |
| `.github/workflows/build_orca.yml` | ccache stats: `runner.os != 'Windows'` (stats only) | Stats only on non-Win |

### 4. Build System
| File | Change | Rationale |
|------|--------|-----------|
| `CMakeLists.txt` | `ORCA_TOOLS=ON` for `generate_system_cache` | Preset cache tool |
| `deps/PNG/PNG.cmake` | Minor fix | Upstream sync |
| `README.md` | Updated Quick Start + Performance Tips | Documentation |
| `.gitignore` | Added build artifacts | Cleanliness |

---

## ⚠️ NEEDS FIXING / REVIEW

### 1. Windows ccache Save (Critical)
**File**: `.github/workflows/build_orca.yml` line 1077
```yaml
if: ${{ always() && !vars.SELF_HOSTED && steps.ccache_save.outcome == 'success' && runner.os != 'Windows' }}
```
**Issue**: `runner.os != 'Windows'` prevents cache cleanup on Windows. Windows cache entries never pruned → storage growth.
**Fix**: Remove `runner.os != 'Windows'` or add Windows-specific cleanup.

### 2. Windows ccache Save (Missing)
**File**: `.github/workflows/build_orca.yml` line 1068-1074
```yaml
- name: Save compiler cache (GitHub-hosted cloud)
  if: ${{ always() && !vars.SELF_HOSTED && steps.ccache_restore.outcome == 'success' && github.event_name != 'pull_request' }}
```
**Issue**: Windows ccache saved but never cleaned. The "Drop older" step (line 1077) skips Windows.
**Fix**: Add Windows cleanup or document intentional retention.

### 3. ccache Stats on Windows
**File**: `.github/workflows/build_orca.yml` line 1048
```yaml
if: ${{ always() && steps.ccache.outcome == 'success' && runner.os != 'Windows' }}
```
**Issue**: ccache stats not printed on Windows. Stats useful for debugging.
**Fix**: Remove `runner.os != 'Windows'` or add Windows-specific stats step.

### 4. Windows `build_win.ps1` Strawberry Perl PATH
**File**: `build_win.ps1` line 208
```powershell
$env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notlike '*Strawberry\c\bin' }) -join ';'
```
**Issue**: Removes Strawberry `c\bin` but keeps `perl\bin`. However ccache.exe lives in `c\bin`. Current code finds ccache BEFORE stripping, then passes full path via `CMAKE_C_COMPILER_LAUNCHER`. Works but fragile.
**Review**: Ensure ccache path resolution happens before PATH strip.

### 5. `build_check_cache.yml` Uses `actions/checkout@v4`
**File**: `.github/workflows/build_check_cache.yml` line 58
```yaml
uses: actions/checkout@v4
```
**Issue**: All other workflows use `v7`. v4 works but inconsistent.
**Fix**: Upgrade to `v7` for consistency (supports larger files, better sparse-checkout).

### 6. Windows ccache Save - Missing `enableCrossOsArchive`
**File**: `.github/workflows/build_orca.yml` line 1071-1074
```yaml
- name: Save compiler cache (GitHub-hosted cloud)
  uses: actions/cache/save@v6
  with:
    path: ${{ github.workspace }}/.ccache
    key: ${{ env.CCACHE_ENTRY }}
```
**Issue**: Missing `enableCrossOsArchive: true` (present in self-hosted save at line 1066).
**Fix**: Add `enableCrossOsArchive: true` for cross-platform cache restore.

### 7. Linux ccache Stats Exclusion
**File**: `.github/workflows/build_orca.yml` line 1048
```yaml
if: ${{ always() && steps.ccache.outcome == 'success' && runner.os != 'Windows' }}
```
**Note**: Stats only on Linux/macOS. Acceptable but worth documenting why.

### 8. `build_optional.yml` Windows MSVC Runner
**File**: `.github/workflows/build_optional.yml` line 186
```yaml
os: windows-2022
```
**Note**: Changed from `windows-latest` to `windows-2022`. Explicit version is good but verify VS2022 has MSVC components.

### 9. `build_optional.yml` ARM64 Runner
**File**: `.github/workflows/build_optional.yml` line 153, 168
```yaml
os: windows-11-vs2026-arm
```
**Note**: Uses `windows-11-vs2026-arm` (preview). May be unstable. Verify availability.

### 10. Removed Files (Breaking?)
- `build_win.bat` - Deleted (replaced by `build_win.ps1`)
- `scripts/test_build_win.ps1` - Deleted (replaced by `scripts/test_check_exception_throw_info.ps1` + `scripts/test_prune_cached_presets.ps1`)
- `scripts/test_build_win.ps1` tests removed - ensure coverage maintained

---

## 📋 PRIORITY FIXES (Before Merge)

| Priority | Issue | File | Effort |
|----------|-------|------|--------|
| **P0** | Windows ccache cleanup missing | `build_orca.yml` line 1077 | 5 min |
| **P0** | Windows ccache stats missing | `build_orca.yml` line 1048 | 1 min |
| **P1** | `enableCrossOsArchive` missing on Windows save | `build_orca.yml` line 1071 | 1 min |
| **P1** | `build_check_cache.yml` checkout v4→v7 | `build_check_cache.yml` | 5 min |
| **P2** | Document Windows ccache behavior | README/comments | 10 min |
| **P3** | `windows-11-vs2026-arm` stability | `build_optional.yml` | Research |

---

## ✅ VERIFIED WORKING
- [x] Local build: `.\build_win.ps1 -Target libslic3r -Clean` → success
- [x] Local build: `.\build_win.ps1 -Target libslic3r -NoConfigure` → 1s (incremental)
- [x] ccache status shows after build: `ccache: 12.1% hit rate (4826/39934), 2.9 / 18.6 (15.43%)`
- [x] All tests pass: 9 + 5 = 14 passed
- [x] Style checks pass: ≤300 lines/file, ≤70 lines/function
- [x] SELF_HOSTED routing works
- [x] SELF_HOSTED cache paths work
- [x] GitHub-hosted cache works (deps + compiler cache)
- [x] ccache enabled on Windows (fixed)
- [x] Self-documenting code: 10 "what" comments → 10 functions
- [x] ccache status compact: `ccache: 12.1% hit rate (4826/39934), 2.9 / 18.6 (15.43%)`
- [x] ccache `--print-stats` parsing (no regex)
- [x] Strawberry Perl PATH stripping at 3 points
- [x] `build_check_cache.yml` sparse-checkout + gzip PATH fix
- [x] `build_orca.yml` Windows ccache enabled (removed OS exclusion)

---

## 📝 Notes
- Branch is rebased on latest `main` (upstream `OrcaSlicer/OrcaSlicer`)
- All changes are in `feat/build-performance-squashed-polygon` on `Depact/OrcaSlicer` fork
- CI runs dispatched and monitored via GitHub API
- Local validation passes on Windows (Strawberry Perl PATH fix works)