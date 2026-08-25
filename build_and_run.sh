#!/usr/bin/env bash
set -e

BUILD_DIR="${BUILD_DIR:-build}"
CONFIG="${CONFIG:-RelWithDebInfo}"
CMAKE="${CMAKE:-cmake}"

# 'bash' on a Windows PATH is often WSL, which has no Windows toolchain - re-run under Git Bash.
if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    exec "/mnt/c/Program Files/Git/bin/bash.exe" "$(wslpath -w "$(pwd)")/$(basename "$0")" "$@"
fi

# cmake is not on PATH here; fall back to the local tools dir (override with CMAKE=...).
if ! command -v "${CMAKE}" >/dev/null 2>&1 && [[ -n "${USERPROFILE:-}" ]] && \
   [[ -e "${USERPROFILE}/tools/cmake-3.31.6-windows-x86_64/bin/cmake.exe" ]]; then
    CMAKE="${USERPROFILE}/tools/cmake-3.31.6-windows-x86_64/bin/cmake.exe"
fi

"${CMAKE}" --build "${BUILD_DIR}" --config "${CONFIG}" --target OrcaSlicer_app_gui --parallel

case "$OSTYPE" in
    darwin*)  open "${BUILD_DIR}/bin/OrcaSlicer.app" "$@" ;;
    msys*|cygwin*|mingw*)
        # WSL tears down processes it spawned via &, so detach with Start-Process.
        BIN="$(compgen -G "./${BUILD_DIR}/src/orca-slicer*.exe" | head -1)"
        if [[ $# -gt 0 ]]; then
            powershell -NoProfile -Command "Start-Process -FilePath '$(cygpath -w "${BIN}")' -ArgumentList '$(cygpath -w "$1")'"
        else
            powershell -NoProfile -Command "Start-Process -FilePath '$(cygpath -w "${BIN}")'"
        fi
        ;;
    *)  ./"${BUILD_DIR}"/src/orca-slicer* "$@" & ;;
esac
