#!/usr/bin/env bash
set -euo pipefail

# Build OrcaSlicer and launch it without blocking the terminal. Optional .3mf
# file(s) are opened in the app.
#   ./build_and_run.sh [file.3mf ...]
#
# Requirements: cmake (and the project's compiler/ninja) on PATH. On Windows run
# from a Git Bash prompt in an environment that can reach the MSVC toolchain
# (e.g. a Developer prompt / after sourcing vcvars64.bat) - cl.exe needs INCLUDE
# and LIB, which a bare Git Bash does not provide.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-${ROOT}/build}"
CONFIG="${CONFIG:-RelWithDebInfo}"
TARGET="${TARGET:-OrcaSlicer_app_gui}"
CMAKE="${CMAKE:-cmake}"

# WSL lacks the Windows toolchain environment: re-run this script under Git Bash.
if [[ -n "${WSL_DISTRO_NAME:-}" && -e "/mnt/c/Program Files/Git/bin/bash.exe" ]]; then
    exec "/mnt/c/Program Files/Git/bin/bash.exe" "$(wslpath -w "${ROOT}")/build_and_run.sh" "$@"
fi

# Resolve the built binary per platform.
case "$(uname -s)" in
    Darwin*)               BINARY="${BUILD_DIR}/bin/OrcaSlicer.app" ;;
    MINGW*|MSYS*|CYGWIN*)  BINARY="${BUILD_DIR}/src/orca-slicer.exe" ;;
    *)                     BINARY="${BUILD_DIR}/src/orca-slicer" ;;
esac

echo "Building OrcaSlicer (${CONFIG}, target ${TARGET})..."
"${CMAKE}" --build "${BUILD_DIR}" --config "${CONFIG}" --target "${TARGET}" --parallel

echo "Launching OrcaSlicer..."
case "$(uname -s)" in
    Darwin*)  open "${BINARY}" "$@" ;;
    MINGW*|MSYS*|CYGWIN*)
        PS="Start-Process -FilePath '$(cygpath -w "${BINARY}")'"
        if [[ $# -gt 0 ]]; then
            ARGS=""
            for a in "$@"; do ARGS="${ARGS}, '$(cygpath -w "$a")'"; done
            PS="${PS} -ArgumentList @(${ARGS#, })"
        fi
        powershell -NoProfile -Command "${PS}"
        ;;
    *)  "${BINARY}" "$@" & ;;
esac
