#!/bin/bash
# Docker container healthcheck script
# Verifies that essential build tools are available

set -euo pipefail

# Check essential build tools
if ! command -v debootstrap &> /dev/null; then
    echo "FAIL: debootstrap not found"
    exit 1
fi

if ! command -v qemu-aarch64-static &> /dev/null; then
    echo "FAIL: qemu-aarch64-static not found"  
    exit 1
fi

if ! command -v parted &> /dev/null; then
    echo "FAIL: parted not found"
    exit 1
fi

if ! command -v xz &> /dev/null; then
    echo "FAIL: xz not found"
    exit 1
fi

# Check if builder user exists
if ! id builder &> /dev/null; then
    echo "FAIL: builder user not found"
    exit 1
fi

# Check workspace directories exist
if [[ ! -d /workspace ]] || [[ ! -d /output ]] || [[ ! -d /cache ]]; then
    echo "FAIL: workspace directories missing"
    exit 1
fi

echo "OK: Build environment healthy"
exit 0
