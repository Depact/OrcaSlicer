#!/usr/bin/env bash
set -e

# How to run:
#   Linux/macOS:  ./build_and_run.sh [file.3mf]
#   Windows:      bash build_and_run.sh [file.3mf]   (auto-hand-offs to Git Bash)
#   Overrides:    BUILD_DIR= build/  CONFIG=RelWithDebInfo  CMAKE=cmake  TARGET=OrcaSlicer_app_gui
# Builds the app with cmake --build, then launches it non-blocking.

BUILD_DIR="${BUILD_DIR:-build}"
CONFIG="${CONFIG:-RelWithDebInfo}"
TARGET="${TARGET:-OrcaSlicer_app_gui}"
CMAKE="${CMAKE:-cmake}"

log() { echo "[build_and_run] $*"; }

# 'bash' on a Windows PATH is often WSL, which has no Windows toolchain - re-run under Git Bash.
if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    exec "/mnt/c/Program Files/Git/bin/bash.exe" "$(wslpath -w "$(pwd)")/$(basename "$0")" "$@"
fi

# cmake is not on PATH here; fall back to the local tools dir (override with CMAKE=...).
if ! command -v "${CMAKE}" >/dev/null 2>&1 && [[ -n "${USERPROFILE:-}" ]] && \
   [[ -e "${USERPROFILE}/tools/cmake-3.31.6-windows-x86_64/bin/cmake.exe" ]]; then
    CMAKE="${USERPROFILE}/tools/cmake-3.31.6-windows-x86_64/bin/cmake.exe"
fi

log "config: BUILD_DIR=${BUILD_DIR} CONFIG=${CONFIG} TARGET=${TARGET} CMAKE=${CMAKE}"
log "building..."
"${CMAKE}" --build "${BUILD_DIR}" --config "${CONFIG}" --target "${TARGET}" --parallel

case "$OSTYPE" in
    darwin*)
        log "launching ${BUILD_DIR}/bin/OrcaSlicer.app"
        open "${BUILD_DIR}/bin/OrcaSlicer.app" "$@" ;;
    msys*|cygwin*|mingw*)
        # WSL tears down processes it spawned via &, so detach with Start-Process.
        BIN="$(compgen -G "./${BUILD_DIR}/src/orca-slicer*.exe" | head -1)"
        log "launching ${BIN}"
        if [[ $# -gt 0 ]]; then
            powershell -NoProfile -Command "Start-Process -FilePath '$(cygpath -w "${BIN}")' -ArgumentList '$(cygpath -w "$1")'"
        else
            powershell -NoProfile -Command "Start-Process -FilePath '$(cygpath -w "${BIN}")'"
        fi
        ;;
    *)
        log "launching ./${BUILD_DIR}/src/orca-slicer"
        ./"${BUILD_DIR}"/src/orca-slicer* "$@" & ;;
esac
