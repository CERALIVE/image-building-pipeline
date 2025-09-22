#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }

show_device_selection() {
    echo ""
    log_info "Available devices for CeraUI streaming appliances:"
    echo ""
    
    # Orange Pi 5+
    echo -e "${GREEN}[1]${NC} ${BLUE}Orange Pi 5+${NC} (${YELLOW}Recommended for most users${NC})"
    echo "    ✓ Excellent HDMI capture with good EMI resistance"
    echo "    ✓ Full-size HDMI input port"
    echo "    ✓ Good USB power delivery for modems"
    echo "    ✓ M.2 2280 slot for storage"
    echo "    💰 ~\$127 total cost"
    echo ""
    
    # Radxa Rock 5B+
    echo -e "${GREEN}[2]${NC} ${BLUE}Radxa Rock 5B+${NC} (${YELLOW}Best for cellular connectivity${NC})"
    echo "    ✓ Best EMI resistance for HDMI capture"
    echo "    ✓ M.2 B-key slot specifically for 4G/5G modems"
    echo "    ✓ Highest USB power delivery (5.45A total)"
    echo "    ✓ On-board WiFi (RTL8852BE)"
    echo "    ⚠️  HDMI port on side (cable management consideration)"
    echo "    ⚠️  Requires SIM card detection workaround"
    echo "    💰 ~\$127 total cost"
    echo ""
    
    echo -e "${GREEN}[3]${NC} ${BLUE}All devices${NC} (build images for all supported devices)"
    echo ""
    
    echo "This is just a test - would normally prompt for input here"
}

# Test the function
show_device_selection
