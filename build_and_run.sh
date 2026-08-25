#!/usr/bin/env bash
set -e

# Incrementally build OrcaSlicer and launch it. Optional: pass a .3mf to open.
#   ./build_and_run.sh                       # build + launch
#   ./build_and_run.sh /path/to/file.3mf     # build + launch with a project
#
# Launch is non-blocking: the app runs in the background and the script returns.

BUILD_DIR="${BUILD_DIR:-build}"
CONFIG="${CONFIG:-Release}"

# Resolve the binary location per platform.
if [[ "$OSTYPE" == "darwin"* ]]; then
    BINARY="${BINARY:-${BUILD_DIR}/bin/OrcaSlicer.app}"
else
    # Prefer src/orca-slicer (Ninja/CMake layout); fall back to bin/orca-slicer.
    if [[ -x "${BUILD_DIR}/src/orca-slicer" ]]; then
        BINARY="${BINARY:-${BUILD_DIR}/src/orca-slicer}"
    else
        BINARY="${BINARY:-${BUILD_DIR}/bin/orca-slicer}"
    fi
fi

echo "Building Orca Slicer (${CONFIG})..."
cmake --build "${BUILD_DIR}" --config "${CONFIG}" --parallel \
    $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

if [[ ! -e "${BINARY}" ]]; then
    echo "Binary not found: ${BINARY}" >&2
    exit 1
fi

echo "Launching Orca Slicer..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    open "${BINARY}" "$@"
else
    "${BINARY}" "$@" &
fi
