#!/bin/bash
set -euo pipefail

# CeraUI Image Testing Script
# Basic validation of built images

DEVICE="${1:-}"
VARIANT="${2:-standard}"

if [[ -z "$DEVICE" ]]; then
    echo "Usage: $0 <device> [variant]"
    exit 1
fi

IMAGE_DIR="images/${DEVICE}/${VARIANT}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[TEST]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

test_passed=0
test_failed=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    
    log_info "Running: $test_name"
    
    if eval "$test_command"; then
        log_pass "$test_name"
        ((test_passed++))
    else
        log_fail "$test_name"
        ((test_failed++))
    fi
}

# Test 1: Check if image file exists
run_test "Image file exists" "[[ -f ${IMAGE_DIR}/ceraui-${DEVICE}-${VARIANT}-*.img.xz ]]"

# Test 2: Check image file size (should be reasonable)
run_test "Image size validation" "[[ \$(find ${IMAGE_DIR} -name '*.img.xz' -size +100M -size -4G | wc -l) -gt 0 ]]"

# Test 3: Check if checksums exist
run_test "Checksum files exist" "[[ -f ${IMAGE_DIR}/checksums.sha256 ]]"

# Test 4: Validate checksums
if [[ -f "${IMAGE_DIR}/checksums.sha256" ]]; then
    run_test "SHA256 checksum validation" "cd ${IMAGE_DIR} && sha256sum -c checksums.sha256"
fi

# Test 5: Test image extraction
run_test "Image extraction test" "
    temp_dir=\$(mktemp -d)
    trap 'rm -rf \$temp_dir' EXIT
    xz -t ${IMAGE_DIR}/ceraui-${DEVICE}-${VARIANT}-*.img.xz
"

# Test 6: Basic image structure validation (if we can extract it)
run_test "Image structure validation" "
    temp_dir=\$(mktemp -d)
    temp_image=\"\$temp_dir/test.img\"
    trap 'rm -rf \$temp_dir' EXIT
    
    # Extract image
    xz -dc ${IMAGE_DIR}/ceraui-${DEVICE}-${VARIANT}-*.img.xz > \"\$temp_image\"
    
    # Check if it's a valid disk image
    file \"\$temp_image\" | grep -q 'DOS/MBR boot sector'
"

# Test 7: Partition table validation
run_test "Partition table validation" "
    temp_dir=\$(mktemp -d)
    temp_image=\"\$temp_dir/test.img\"
    trap 'rm -rf \$temp_dir' EXIT
    
    # Extract image
    xz -dc ${IMAGE_DIR}/ceraui-${DEVICE}-${VARIANT}-*.img.xz > \"\$temp_image\"
    
    # Check partition table
    sfdisk -l \"\$temp_image\" | grep -q 'Linux'
"

# Summary
echo ""
log_info "Test Summary"
echo "============="
log_pass "Tests passed: $test_passed"
if [[ $test_failed -gt 0 ]]; then
    log_fail "Tests failed: $test_failed"
    exit 1
else
    log_pass "All tests passed!"
fi

echo ""
log_info "Image Details:"
echo "Device: $DEVICE"
echo "Variant: $VARIANT"
echo "Location: $IMAGE_DIR"

if [[ -f "${IMAGE_DIR}/ceraui-${DEVICE}-${VARIANT}"-*.img.xz ]]; then
    image_file=$(ls "${IMAGE_DIR}/ceraui-${DEVICE}-${VARIANT}"-*.img.xz)
    image_size=$(ls -lh "$image_file" | awk '{print $5}')
    echo "Image size: $image_size"
    
    # Extract and get uncompressed size
    temp_dir=$(mktemp -d)
    trap 'rm -rf $temp_dir' EXIT
    xz -dc "$image_file" > "$temp_dir/test.img"
    uncompressed_size=$(ls -lh "$temp_dir/test.img" | awk '{print $5}')
    echo "Uncompressed size: $uncompressed_size"
fi

echo ""
log_pass "Image validation completed successfully!"
