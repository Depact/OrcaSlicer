#!/usr/bin/env bash
set -e

# Incrementally build OrcaSlicer and launch it. Optional: pass a .3mf to open.
#   ./build_and_run.sh                       # build + launch
#   ./build_and_run.sh /path/to/file.3mf     # build + launch with a project
#
# Launch is non-blocking: the app runs in the background and the script returns.
#
# Platforms:
#   Linux                ./build_and_run.sh
#   macOS                ./build_and_run.sh
#   Windows (Git Bash)   bash build_and_run.sh   (from a Git Bash prompt, or
#                        C:/Program\ Files/Git/bin/bash.exe build_and_run.sh)
#   Windows (WSL bash)   bash build_and_run.sh   - auto re-executes under Git Bash.

# Work from the script's own directory so the script works regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/build}"
CONFIG="${CONFIG:-Release}"
TARGET="${TARGET:-OrcaSlicer_app_gui}"

# Detect the runtime environment: Git Bash / MSYS2 / Cygwin / WSL / native.
IS_WINDOWS=0
IS_WSL=0
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
esac
if [[ ${IS_WINDOWS} -eq 0 ]] && { [[ -n "${WSL_DISTRO_NAME}" ]] || uname -r 2>/dev/null | grep -qi microsoft; }; then
    IS_WINDOWS=1
    IS_WSL=1
fi

if [[ ${IS_WSL} -eq 1 ]]; then
    # WSL has no Windows env (USERPROFILE etc.) and cannot run the MSVC build
    # directly. Re-execute under Git Bash, which has the full Windows environment.
    GIT_BASH="/mnt/c/Program Files/Git/bin/bash.exe"
    if [[ -e "${GIT_BASH}" ]]; then
        echo "WSL bash detected - re-running under Git Bash."
        exec "${GIT_BASH}" "$(wslpath -w "${SCRIPT_DIR}")/build_and_run.sh" "$@"
    fi
    echo "WSL bash detected but Git Bash not found. Run from Git Bash instead:" >&2
    echo "  C:\\Program Files\\Git\\bin\\bash.exe build_and_run.sh" >&2
    exit 1
fi

# Locate cmake: explicit CMAKE var, then PATH, then the known local tools dir on Windows.
CMAKE_BIN="${CMAKE:-}"
if [[ -z "${CMAKE_BIN}" ]] && command -v cmake >/dev/null 2>&1; then
    CMAKE_BIN="$(command -v cmake)"
fi
if [[ -z "${CMAKE_BIN}" && ${IS_WINDOWS} -eq 1 && -n "${USERPROFILE}" && \
      -e "${USERPROFILE}/tools/cmake-3.31.6-windows-x86_64/bin/cmake.exe" ]]; then
    CMAKE_BIN="${USERPROFILE}/tools/cmake-3.31.6-windows-x86_64/bin/cmake.exe"
fi
if [[ -z "${CMAKE_BIN}" ]]; then
    echo "cmake not found. Set CMAKE=<path to cmake>" >&2
    exit 1
fi
echo "Using cmake: ${CMAKE_BIN}"

# Resolve the binary location per platform.
if [[ "$OSTYPE" == "darwin"* ]]; then
    BINARY="${BINARY:-${BUILD_DIR}/bin/OrcaSlicer.app}"
else
    EXE_SUFFIX=""
    [[ ${IS_WINDOWS} -eq 1 ]] && EXE_SUFFIX=".exe"
    # Prefer src/orca-slicer (Ninja/CMake layout); fall back to bin/orca-slicer.
    if [[ -e "${BUILD_DIR}/src/orca-slicer${EXE_SUFFIX}" ]]; then
        BINARY="${BINARY:-${BUILD_DIR}/src/orca-slicer${EXE_SUFFIX}}"
    else
        BINARY="${BINARY:-${BUILD_DIR}/bin/orca-slicer${EXE_SUFFIX}}"
    fi
fi

if [[ ${IS_WINDOWS} -eq 1 ]]; then
    NPROC="${NUMBER_OF_PROCESSORS:-4}"
else
    NPROC="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
fi

echo "Building Orca Slicer (${CONFIG}, ${NPROC} jobs, target ${TARGET})..."
if [[ ${IS_WINDOWS} -eq 1 ]]; then
    # Git Bash has no MSVC environment. Run the build in one cmd session that sources
    # vcvars64.bat first, via a helper .cmd file (inline cmd quoting through MSYS
    # backslash-escapes quotes and cmd then fails to parse them).
    VCVARS_WIN="C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Auxiliary\\Build\\vcvars64.bat"
    CMAKE_WIN="$(cygpath -w "${CMAKE_BIN}")"
    BUILD_WIN="$(cygpath -w "${BUILD_DIR}")"
    BUILD_CMD="${SCRIPT_DIR}/.build_orca.cmd"
    cat > "${BUILD_CMD}" <<EOF
@echo off
@call "${VCVARS_WIN}" >nul
@if errorlevel 1 exit /b 1
@"${CMAKE_WIN}" --build "${BUILD_WIN}" --config "${CONFIG}" --target "${TARGET}" --parallel ${NPROC}
@exit /b %errorlevel%
EOF
    # Repo path has no spaces; MSYS would mangle the quotes otherwise.
    cmd //c "$(cygpath -w "${BUILD_CMD}")"
    rm -f "${BUILD_CMD}"
else
    "${CMAKE_BIN}" --build "${BUILD_DIR}" --config "${CONFIG}" --target "${TARGET}" --parallel "${NPROC}"
fi

if [[ ! -e "${BINARY}" ]]; then
    echo "Binary not found: ${BINARY}" >&2
    exit 1
fi

echo "Launching Orca Slicer..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    open "${BINARY}" "$@"
elif [[ ${IS_WINDOWS} -eq 1 ]]; then
    # orca-slicer.exe is a console subsystem binary: a plain "&" keeps it attached to
    # the shell and it dies when the script exits. Start-Process detaches it.
    WIN_BINARY="$(cygpath -w "${BINARY}")"
    if [[ $# -ge 1 ]]; then
        WIN_ARG="$(cygpath -w "$1")"
        powershell -NoProfile -Command "Start-Process -FilePath '${WIN_BINARY}' -ArgumentList '${WIN_ARG}'"
    else
        powershell -NoProfile -Command "Start-Process -FilePath '${WIN_BINARY}'"
    fi
else
    "${BINARY}" "$@" &
fi
