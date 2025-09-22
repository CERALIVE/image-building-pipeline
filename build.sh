#!/bin/bash
set -euo pipefail

# CeraLive Armbian Native Build Script
# Uses Armbian's official build framework for clean, optimized images

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Default values
DEVICE=""
ENVIRONMENT="auto"
VARIANT="standard"
CLEAN=false
VERBOSE=false
ALL_DEVICES=false
TEST_ONLY=false
ARMBIAN_DIR="${PROJECT_ROOT}/armbian-build"

# Device configuration
declare -A DEVICE_CONFIG=(
    ["orangepi5plus"]="BOARD=orangepi5-plus BRANCH=vendor"
    ["rock5bplus"]="BOARD=rock-5b-plus BRANCH=vendor"
)

show_usage() {
    cat << EOF
CeraLive Armbian Native Build Pipeline

Usage: $0 [OPTIONS]

OPTIONS:
    -d, --device DEVICE        Target device (orangepi5plus, rock5bplus) [interactive if not specified]
    -e, --environment ENV      Build environment (auto, docker, local) [default: auto]
    -v, --variant VARIANT      Image variant (minimal, standard, development) [default: standard]
    -c, --clean               Clean build (remove previous artifacts)
    -a, --all                 Build for all supported devices
    --verbose                 Enable verbose output
    -t, --test                Test setup only (don't build)
    --setup-deps              Install build dependencies for local building
    --start-docker            Start Docker daemon (if installed but not running)
    -h, --help                Show this help message

DEVICES:
    orangepi5plus             Orange Pi 5+ (RK3588S) - Optimized for streaming
    rock5bplus                Radxa Rock 5B+ (RK3588) - Full feature streaming appliance

VARIANTS:
    minimal                   Basic CeraLive streaming functionality only
    standard                  Full streaming feature set with CeraLive (recommended)
    development               Development tools, debug symbols, and extra packages

EXAMPLES:
    $0                                     # Interactive device selection
    $0 -d orangepi5plus                    # Build Orange Pi 5+ standard image
    $0 -d rock5bplus -v development        # Build Rock 5B+ development image
    $0 --all --clean                      # Clean build for all devices

This script uses Armbian's native build framework for optimal results.
EOF
}

detect_environment() {
    local detected_env=""
    local missing_deps=()
    
    if [[ "$VERBOSE" == true ]]; then
        log_info "🔍 Detecting build environment..." >&2
    fi
    
    # Check Docker availability
    if command -v docker &> /dev/null; then
        if [[ "$VERBOSE" == true ]]; then
            log_info "✓ Docker binary found: $(which docker)" >&2
        fi
        
        if docker info &> /dev/null; then
            detected_env="docker"
            if [[ "$VERBOSE" == true ]]; then
                log_info "✓ Docker daemon is running and accessible" >&2
                docker version --format "Docker version: {{.Server.Version}}" >&2 2>/dev/null || true
            else
                log_info "✓ Docker detected and running" >&2
            fi
        else
            log_warning "Docker found but daemon not running" >&2
            if [[ "$VERBOSE" == true ]]; then
                log_info "💡 Try: sudo systemctl start docker" >&2
                log_info "💡 Or: sudo service docker start" >&2
            fi
        fi
    else
        if [[ "$VERBOSE" == true ]]; then
            log_info "❌ Docker not found in PATH" >&2
        fi
    fi
    
    # Check for local build tools (skip if Docker will be used)
    if [[ "$detected_env" != "docker" ]]; then
        if [[ "$VERBOSE" == true ]]; then
            log_info "🔍 Checking local build dependencies..." >&2
        fi
        
        local required_tools=("debootstrap" "qemu-aarch64-static" "kpartx" "xz-utils" "parted")
        local has_all_deps=true
        
        for tool in "${required_tools[@]}"; do
            if command -v "$tool" &> /dev/null || dpkg -l | grep -q "^ii  $tool "; then
                if [[ "$VERBOSE" == true ]]; then
                    log_info "✓ $tool found" >&2
                fi
            else
                missing_deps+=("$tool")
                has_all_deps=false
                if [[ "$VERBOSE" == true ]]; then
                    log_warning "❌ $tool missing" >&2
                fi
            fi
        done
        
        if [[ "$has_all_deps" == true ]]; then
            detected_env="local"
            log_info "✓ Local build tools detected" >&2
        else
            if [[ "${#missing_deps[@]}" -gt 0 ]]; then
                log_warning "Local build dependencies missing: ${missing_deps[*]}" >&2
            fi
        fi
    else
        if [[ "$VERBOSE" == true ]]; then
            log_info "Skipping local dependency checks (using Docker)" >&2
        fi
    fi
    
    # Validate final environment
    if [[ "$detected_env" == "docker" ]] && ! docker info &> /dev/null; then
        detected_env=""
    fi
    
    if [[ -z "$detected_env" ]]; then
        log_error "No suitable build environment detected!" >&2
        echo "" >&2
        log_info "Available options:" >&2
        log_info "  1. Install Docker (recommended):" >&2
        log_info "     - Ubuntu/Debian: sudo apt install docker.io && sudo systemctl start docker" >&2
        log_info "     - Or follow: https://docs.docker.com/engine/install/" >&2
        echo "" >&2
        log_info "  2. Install local build tools:" >&2
        log_info "     - Ubuntu/Debian: sudo apt install debootstrap qemu-user-static parted kpartx xz-utils" >&2
        echo "" >&2
        return 1
    fi
    
    if [[ "$VERBOSE" == true ]]; then
        log_success "🎯 Selected build environment: $detected_env" >&2
    fi
    
    echo "$detected_env"
}

setup_dependencies() {
    log_info "🔧 Installing local build dependencies..."
    
    if command -v apt &> /dev/null; then
        log_info "📦 Detected Debian/Ubuntu system"
        log_info "Installing: debootstrap qemu-user-static parted kpartx xz-utils"
        
        if sudo apt update && sudo apt install -y debootstrap qemu-user-static parted kpartx xz-utils; then
            log_success "✅ Dependencies installed successfully!"
            log_info "💡 You can now run: $0 -d <device> with local building"
        else
            log_error "❌ Failed to install dependencies"
            return 1
        fi
    elif command -v yum &> /dev/null; then
        log_info "📦 Detected RHEL/CentOS system"
        log_info "Installing equivalent packages..."
        sudo yum install -y debootstrap qemu-user-static parted kpartx xz
    elif command -v pacman &> /dev/null; then
        log_info "📦 Detected Arch system"
        log_info "Installing equivalent packages..."
        sudo pacman -S debootstrap qemu-arch-extra parted xz
    else
        log_error "❌ Unsupported package manager"
        log_info "Please manually install: debootstrap qemu-user-static parted kpartx xz-utils"
        return 1
    fi
}

start_docker_daemon() {
    log_info "🐳 Starting Docker daemon..."
    
    if ! command -v docker &> /dev/null; then
        log_error "❌ Docker not installed"
        log_info "💡 Install Docker first with: $0 --setup-docker"
        return 1
    fi
    
    if docker info &> /dev/null; then
        log_success "✅ Docker daemon is already running"
        return 0
    fi
    
    log_info "Starting Docker service..."
    
    # Try systemctl first (most modern systems)
    if command -v systemctl &> /dev/null; then
        if sudo systemctl start docker && sudo systemctl enable docker; then
            log_success "✅ Docker started with systemctl"
        else
            log_warning "⚠️  systemctl failed, trying service command..."
        fi
    fi
    
    # Try service command (older systems)
    if ! docker info &> /dev/null && command -v service &> /dev/null; then
        if sudo service docker start; then
            log_success "✅ Docker started with service command"
        else
            log_error "❌ Failed to start Docker"
            return 1
        fi
    fi
    
    # Final verification
    sleep 2
    if docker info &> /dev/null; then
        log_success "✅ Docker daemon is now running!"
        log_info "💡 You can now run: $0 -d <device>"
    else
        log_error "❌ Docker daemon failed to start"
        log_info "💡 Try manually: sudo systemctl start docker"
        return 1
    fi
}

select_device_interactive() {
    local options=(
        "Orange Pi 5+:orangepi5plus"
        "Radxa Rock 5B+:rock5bplus" 
        "All devices:all"
    )
    local current=0
    local total=${#options[@]}
    
    # Check if terminal supports advanced features
    if [[ -t 0 ]] && [[ -t 1 ]] && command -v tput &> /dev/null; then
        select_device_interactive_fancy
    else
        select_device_simple
    fi
}

select_device_simple() {
    echo ""
    log_info "Select target device:"
    echo ""
    echo -e "${GREEN}[1]${NC} Orange Pi 5+ (Streaming optimized)"
    echo -e "${GREEN}[2]${NC} Radxa Rock 5B+ (Full feature appliance)"
    echo -e "${GREEN}[3]${NC} All devices"
    echo ""
    
    while true; do
        read -p "Device [1-3]: " choice
        case $choice in
            1) DEVICE="orangepi5plus"; return 0 ;;
            2) DEVICE="rock5bplus"; return 0 ;;
            3) ALL_DEVICES=true; return 0 ;;
            q|Q) log_info "Build cancelled"; exit 0 ;;
            *) log_warning "Invalid choice. Enter 1, 2, 3, or 'q' to quit." ;;
        esac
    done
}

select_device_interactive_fancy() {
    local options=(
        "Orange Pi 5+:orangepi5plus"
        "Radxa Rock 5B+:rock5bplus"
        "All devices:all"
    )
    local current=0
    local total=${#options[@]}
    
    tput civis  # Hide cursor
    trap 'tput cnorm; exit 130' INT
    trap 'tput cnorm' EXIT
    
    render_full_menu() {
        clear
        echo ""
        log_info "Select target device:"
        echo ""
        echo -e "${YELLOW}Use ↑/↓ arrows or 1-3 to select, Enter to confirm${NC}"
        echo ""
        
        for i in "${!options[@]}"; do
            IFS=':' read -r name device_code <<< "${options[$i]}"
            if [[ $i -eq $current ]]; then
                echo -e "${GREEN}► [$(($i + 1))] ${BLUE}${name}${NC}"
            else
                echo -e "${GREEN}  [$(($i + 1))]${NC} ${name}"
            fi
        done
        echo ""
        echo -e "${BLUE}Current: ${options[$current]%%:*}${NC} (Enter to confirm)"
    }
    
    render_full_menu
    
    while true; do
        read -rsn1 key
        
        case $key in
            $'\x1b')  # ESC sequence
                read -rsn2 -t 1 key || key=""
                case $key in
                    '[A')  # Up arrow
                        if [[ $current -gt 0 ]]; then
                            current=$((current - 1))
                            render_full_menu
                        fi
                        ;;
                    '[B')  # Down arrow
                        if [[ $current -lt $((total - 1)) ]]; then
                            current=$((current + 1))
                            render_full_menu
                        fi
                        ;;
                esac
                ;;
            '')  # Enter key
                break
                ;;
            [1-3])  # Number keys
                if [[ $key -ge 1 ]] && [[ $key -le $total ]]; then
                    current=$((key - 1))
                    break
                fi
                ;;
            'q'|'Q')  # Quit
                tput cnorm
                echo ""
                log_info "Build cancelled"
                exit 0
                ;;
        esac
    done
    
    tput cnorm  # Restore cursor
    
    IFS=':' read -r name device_code <<< "${options[$current]}"
    echo ""
    log_info "Selected: ${name}"
    
    if [[ "$device_code" == "all" ]]; then
        ALL_DEVICES=true
    else
        DEVICE="$device_code"
    fi
}

setup_armbian_source() {
    log_info "Setting up Armbian build framework..."
    
    if [[ ! -d "$ARMBIAN_DIR" ]]; then
        log_info "Cloning Armbian build framework (this may take a few minutes)..."
        log_info "Repository: https://github.com/armbian/build.git"
        
        # Show progress during clone
        if git clone --progress --depth=1 https://github.com/armbian/build.git "$ARMBIAN_DIR"; then
            log_success "Armbian build framework cloned successfully"
        else
            log_error "Failed to clone Armbian build framework"
            log_info "Please check your internet connection and try again"
            return 1
        fi
    else
        log_info "Updating Armbian build framework..."
        if (cd "$ARMBIAN_DIR" && git pull); then
            log_success "Armbian build framework updated"
        else
            log_warning "Failed to update Armbian build framework, continuing with existing version"
        fi
    fi
    
    # Verify the clone was successful
    if [[ ! -f "$ARMBIAN_DIR/compile.sh" ]]; then
        log_error "Armbian build framework is incomplete (missing compile.sh)"
        log_info "Removing incomplete directory and retrying..."
        rm -rf "$ARMBIAN_DIR"
        return 1
    fi
    
    # Create userpatches directory structure
    setup_userpatches
}

setup_userpatches() {
    local userpatches_dir="${ARMBIAN_DIR}/userpatches"
    
    log_info "Setting up CeraLive userpatches..."
    
    # Create userpatches structure
    mkdir -p "$userpatches_dir"/{overlay,config}
    
    # Copy our userpatches from the project
    if [[ -d "${PROJECT_ROOT}/userpatches" ]]; then
        cp -r "${PROJECT_ROOT}/userpatches/"* "$userpatches_dir/"
    fi
    
    log_success "Userpatches configured for CeraLive"
}

build_device_armbian() {
    local device="$1"
    local start_time=$(date +%s)
    
    log_info "Starting Armbian native build for device: $device"
    log_info "Environment: $ENVIRONMENT"
    log_info "Variant: $VARIANT"
    
    # Get device configuration
    if [[ -z "${DEVICE_CONFIG[$device]:-}" ]]; then
        log_error "Unknown device: $device"
        return 1
    fi
    
    local board_config="${DEVICE_CONFIG[$device]}"
    
    # Set build parameters
    local build_params=(
        "$board_config"
        "RELEASE=bookworm"
        "BUILD_MINIMAL=yes"
        "BUILD_DESKTOP=no"
        "KERNEL_CONFIGURE=no"
        "USERPATCHES_PATH=${ARMBIAN_DIR}/userpatches"
    )
    
    # Add variant-specific parameters
    case "$VARIANT" in
        minimal)
            build_params+=("BUILD_MINIMAL=yes" "INSTALL_HEADERS=no")
            ;;
        standard)
            build_params+=("BUILD_MINIMAL=no" "INSTALL_HEADERS=no")
            ;;
        development)
            build_params+=("BUILD_MINIMAL=no" "INSTALL_HEADERS=yes")
            ;;
    esac
    
    # Add environment-specific parameters
    if [[ "$ENVIRONMENT" == "docker" ]]; then
        build_params+=("DOCKER_ARMBIAN_BUILD=yes")
    fi
    
    if [[ "$CLEAN" == true ]]; then
        build_params+=("CLEAN_LEVEL=make,cache,sources")
    fi
    
    if [[ "$VERBOSE" == true ]]; then
        build_params+=("PROGRESS_LOG_TO_FILE=yes")
    fi
    
    if [[ "$VERBOSE" == true ]]; then
        log_info "🔧 Build parameters:" >&2
        for param in "${build_params[@]}"; do
            log_info "  - $param" >&2
        done
    else
        log_info "Building with parameters: ${build_params[*]}"
    fi
    
    # Run Armbian build
    (
        cd "$ARMBIAN_DIR"
        
        # Create build command
        local build_cmd="./compile.sh"
        for param in "${build_params[@]}"; do
            build_cmd+=" $param"
        done
        
        if [[ "$VERBOSE" == true ]]; then
            log_info "🚀 Executing full command: $build_cmd" >&2
            echo "============================================" >&2
            echo "ARMBIAN BUILD OUTPUT (VERBOSE MODE):" >&2
            echo "============================================" >&2
            eval "$build_cmd" 2>&1 | tee "/tmp/armbian-build-${device}-$(date +%Y%m%d-%H%M%S).log"
        else
            log_info "Executing: $build_cmd"
            log_info "⏳ Building image (this may take 30-60 minutes)..."
            log_info "💡 Use --verbose flag to see detailed build output"
            log_info ""
            
            # Stream filtered output for key progress indicators
            eval "$build_cmd" 2>&1 | while IFS= read -r line; do
                # Show important progress markers
                if [[ "$line" =~ (Downloading|Extracting|Configuring|Installing|Building|Compiling|Creating.*image|Preparing|Copying) ]]; then
                    echo "🔄 [PROGRESS] $line" >&2
                elif [[ "$line" =~ (ERROR|FAILED|error:|failed:) ]]; then
                    echo "❌ [ERROR] $line" >&2
                elif [[ "$line" =~ (WARNING|warning:) ]]; then
                    echo "⚠️  [WARN] $line" >&2
                elif [[ "$line" =~ (✓|✅|SUCCESS|Finished|Complete|Done) ]]; then
                    echo "✅ [SUCCESS] $line" >&2
                elif [[ "$line" =~ (Starting|Begin|Initiating) ]]; then
                    echo "🚀 [START] $line" >&2
                elif [[ "$line" =~ (%|/100|[0-9]+\.[0-9]+.*MB|[0-9]+.*KB/s) ]]; then
                    echo "📊 [PROGRESS] $line" >&2
                fi
            done
        fi
    )
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_success "Armbian build completed for $device in ${duration}s"
    
    # Copy result to our output directory
    copy_build_results "$device"
}

copy_build_results() {
    local device="$1"
    local timestamp="$(date +%Y%m%d-%H%M%S)"
    local output_dir="${PROJECT_ROOT}/images/${device}/${VARIANT}"
    local armbian_output="${ARMBIAN_DIR}/output/images"
    
    mkdir -p "$output_dir"
    
    if [[ -d "$armbian_output" ]]; then
        # Rename Armbian outputs to include brand (replace 'unofficial' -> 'ceralive')
        shopt -s nullglob
        for f in "$armbian_output"/Armbian-unofficial_*; do
            [[ -e "$f" ]] || break
            mv -v "$f" "${f/Armbian-unofficial_/Armbian-ceralive_}" || true
        done
        
        log_info "Copying build results to: $output_dir"
        mkdir -p "$output_dir"
        
        shopt -s nullglob
        for img in "$armbian_output"/*.img; do
            base="$(basename "$img")"
            # Normalize name: CERALIVE_<device>_<release>_<branch>_<timestamp>.img
            release_part="$(echo "$base" | sed -E 's/.*_(Bookworm|bookworm|Bullseye|bullseye|Noble|noble).*/\1/i' | tr '[:upper:]' '[:lower:]')"
            branch_part="$(echo "$base" | sed -E 's/.*_(current|edge|vendor).*/\1/i' | tr '[:upper:]' '[:lower:]')"
            branch_label="$branch_part"
            if [[ "$branch_part" == "vendor" || "$branch_part" == "current" || -z "$branch_part" ]]; then
                branch_label="stable"
            fi
            newname="CERALIVE_${device}_${release_part:-bookworm}_${branch_label}_${timestamp}.img"
            cp -v "$img" "$output_dir/$newname"
            # Copy checksum if present and rename accordingly
            if [[ -f "$img.sha" ]]; then
                sha_newname="$newname.sha"
                cp -v "$img.sha" "$output_dir/$sha_newname" || true
            fi
            # Notes file
            if [[ -f "$img.txt" ]]; then
                txt_newname="${newname%.img}.txt"
                cp -v "$img.txt" "$output_dir/$txt_newname" || true
            fi
        done
        shopt -u nullglob
        
        log_success "Build results copied to: $output_dir"
        log_info "Latest image: $(ls -1t "$output_dir"/*.img | head -n1)"
    else
        log_warning "No build results found in: $armbian_output"
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--device)
            DEVICE="$2"
            shift 2
            ;;
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -v|--variant)
            VARIANT="$2"
            shift 2
            ;;
        -c|--clean)
            CLEAN=true
            shift
            ;;
        -a|--all)
            ALL_DEVICES=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -t|--test)
            TEST_ONLY=true
            shift
            ;;
        --setup-deps)
            setup_dependencies
            exit 0
            ;;
        --start-docker)
            start_docker_daemon
            exit 0
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown parameter: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    log_info "CeraLive Armbian Native Build Pipeline"
    log_info "===================================="
    
    # Handle device selection
    if [[ "$ALL_DEVICES" == false ]] && [[ -z "$DEVICE" ]]; then
        log_info "No device specified. Starting interactive selection..."
        
        # Check if we're in a non-interactive environment
        if [[ ! -t 0 ]] && [[ ! -t 1 ]] && [[ -z "$TERM" ]]; then
            log_error "No device specified and running in non-interactive mode"
            log_info "Use --device DEVICE or --all for automated builds"
            show_usage
            exit 1
        fi
        
        select_device_interactive
    fi
    
    # Validate environment
    if [[ "$ENVIRONMENT" == "auto" ]]; then
        if ENVIRONMENT=$(detect_environment); then
            log_info "Auto-detected environment: $ENVIRONMENT"
        else
            log_error "Environment detection failed"
            exit 1
        fi
    fi
    
    # Setup Armbian source
    if ! setup_armbian_source; then
        log_error "Failed to setup Armbian build framework"
        exit 1
    fi
    
    # If test mode, just verify setup and exit
    if [[ "$TEST_ONLY" == true ]]; then
        log_success "✅ Armbian build framework setup completed successfully!"
        log_info "Framework location: $ARMBIAN_DIR"
        log_info "Compile script: $ARMBIAN_DIR/compile.sh"
        log_info "Userpatches: $ARMBIAN_DIR/userpatches"
        log_info ""
        log_info "🚀 Ready to build! Run without --test flag to start building images."
        exit 0
    fi
    
    # Build devices
    if [[ "$ALL_DEVICES" == true ]]; then
        for device in "${!DEVICE_CONFIG[@]}"; do
            build_device_armbian "$device"
        done
    else
        # Validate device
        if [[ -z "${DEVICE_CONFIG[$DEVICE]:-}" ]]; then
            log_error "Invalid device: $DEVICE"
            log_info "Valid devices: ${!DEVICE_CONFIG[*]}"
            exit 1
        fi
        
        build_device_armbian "$DEVICE"
    fi
    
    log_success "CeraLive build pipeline completed!"
}

main "$@"