#!/bin/bash
set -euo pipefail

# Test the interactive device selection function
source build.sh

echo "Testing interactive device selection..."
echo "This should show the full device menu:"
echo ""

select_device_interactively

echo ""
echo "Selected device: $DEVICE"
if [[ "$ALL_DEVICES" == true ]]; then
    echo "All devices selected"
fi
