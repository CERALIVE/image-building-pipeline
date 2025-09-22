#!/bin/bash
set -euo pipefail

# Auto-detect number of build jobs if not specified
if [[ "${BUILD_JOBS:-0}" == "0" ]]; then
    export BUILD_JOBS="$(nproc)"
fi

echo "CeraLive Image Builder Docker Environment"
echo "======================================"
echo "Build jobs: ${BUILD_JOBS}"
echo "Workspace: ${WORKSPACE:-/workspace}"
echo "Output: ${OUTPUT_DIR:-/output}"
echo "Cache: ${CACHE_DIR:-/cache}"
echo ""

# Ensure directories exist
mkdir -p "${OUTPUT_DIR:-/output}" "${CACHE_DIR:-/cache}"

# Execute command as root (needed for image building with loop devices)
exec "$@"
