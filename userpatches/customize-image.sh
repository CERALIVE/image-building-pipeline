#!/bin/bash
# CeraLive Image Customization Script for Armbian
# This script runs in chroot environment during image creation

set -e
set -o pipefail
set -x
export DEBIAN_FRONTEND=noninteractive
trap 'echo "[CeraLive] ERROR at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# Accept parameters from Armbian (RELEASE FAMILY BOARD BUILD_DESKTOP ARCH)
if [ $# -ge 3 ]; then
    RELEASE="${1:-${RELEASE:-bookworm}}"
    LINUXFAMILY="${2:-${LINUXFAMILY:-}}"
    BOARD="${3:-${BOARD:-unknown}}"
    BUILD_DESKTOP="${4:-${BUILD_DESKTOP:-no}}"
    ARCH="${5:-${ARCH:-arm64}}"
fi

# Get build information (env overrides still supported)
BOARD="${BOARD:-unknown}"
BRANCH="${BRANCH:-current}"
RELEASE="${RELEASE:-bookworm}"
BUILD_DESKTOP="${BUILD_DESKTOP:-no}"
VARIANT="${VARIANT:-standard}"

echo "CeraLive Customization - Board: $BOARD, Release: $RELEASE, Variant: $VARIANT"

# Create CeraUI user and groups
create_ceraui_user() { # keep internal user/path as ceraui; branding is CeraLive
    echo "Creating CeraLive user and configuring permissions..."
    
    # Ensure required groups exist before adding the user to them
    for grp in sudo audio video dialout plugdev netdev gpio i2c spi; do
        getent group "$grp" >/dev/null || groupadd -f "$grp" || true
    done
    
    # Create ceraui user
    id -u ceraui >/dev/null 2>&1 || useradd -m -s /bin/bash ceraui
    # Do not set a static password in images; leave locked or handle via first-boot
    passwd -l ceraui || true
    
    # Add to required groups for hardware access
    usermod -aG sudo,audio,video,dialout,plugdev,netdev,gpio,i2c,spi ceraui || true
    
    # Lock root password for security
    passwd -l root || true
    
    echo "CeraLive user configured successfully"
}

# Install minimal APT sources (as requested)
configure_minimal_apt() {
    echo "Configuring minimal APT sources..."
    mkdir -p /etc/apt/sources.list.d

    # Backup legacy sources.list if present
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.backup || true
    fi

    # Use deb822 format preferred by Debian/Armbian
    cat > /etc/apt/sources.list.d/debian.sources << EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${RELEASE}
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: ${RELEASE}-security
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: ${RELEASE}-updates
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

    # Ensure apt can run non-interactively inside chroot
    echo 'APT::Install-Recommends "false";' > /etc/apt/apt.conf.d/99ceraui
    echo 'DPkg::Options { "--force-confdef"; "--force-confold"; };' >> /etc/apt/apt.conf.d/99ceraui

    echo "Minimal APT sources configured"
}

# Add CeraUI custom repository
setup_ceraui_repository() {
    echo "Setting up CeraLive custom repository..."
    
    # Create repository directory
    mkdir -p /etc/opt/ceraui
    
    # Add CeraUI repository (placeholder - replace with actual repo)
    cat > /etc/apt/sources.list.d/ceraui.list << 'EOF'
# CeraUI Custom Repository
# deb [signed-by=/etc/opt/ceraui/ceralive.gpg] https://repo.ceralive.com/debian bookworm main
# Note: Uncomment above line when repository is available
EOF
    
    # Create placeholder GPG key file
    cat > /etc/opt/ceraui/ceralive.gpg << 'EOF'
# TODO: Add actual CERALIVE repository GPG key here
# This will be needed when the custom repository is set up
EOF
    
    echo "CeraUI repository configuration created"
}

# Install streaming and hardware packages
install_streaming_packages() {
    echo "Installing streaming and hardware acceleration packages..."
    
    # Update package lists (tolerate transient failures)
    if ! apt-get update; then
        echo "Warning: apt-get update failed once; retrying..."
        sleep 2
        apt-get update || echo "Warning: apt-get update failed; continuing best-effort"
    fi
    
    # Essential packages for CeraUI streaming
    STREAMING_PACKAGES=(
        # GStreamer and multimedia
        "gstreamer1.0-tools"
        "gstreamer1.0-plugins-base"
        "gstreamer1.0-plugins-good"
        "gstreamer1.0-plugins-bad"
        "gstreamer1.0-plugins-ugly"
        "gstreamer1.0-libav"

        # Network and streaming
        "wget"
        "curl"
        "socat"
        "netcat-openbsd"
        "iperf3"

        # USB and hardware tools
        "usbutils"
        "pciutils"
        "i2c-tools"
        "can-utils"

        # System monitoring
        "htop"
        "iotop"
        "nethogs"
        "vnstat"

        # WiFi management
        "wireless-tools"
        "wpasupplicant"
        "hostapd"
        "dnsmasq"
        
        # mDNS hostname resolution
        "avahi-daemon"
        "libnss-mdns"

        # CPU governor
        "cpufrequtils"

        # Modem management (CLI only)
        "modemmanager"
        "libqmi-utils"
        "libmbim-utils"
        "usb-modeswitch"
    )
    # Append dev tools only when requested (avoid set -e pitfalls)
    if [ "$VARIANT" = "development" ]; then
        STREAMING_PACKAGES+=("build-essential" "git" "vim" "nano" "screen" "tmux")
    fi
    
    # Install packages in one transaction, non-interactive, without recommends
    echo "Installing packages: ${STREAMING_PACKAGES[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${STREAMING_PACKAGES[@]}" \
        || { echo "Warning: initial apt install failed; retrying once"; sleep 2; DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 install -y --no-install-recommends "${STREAMING_PACKAGES[@]}" || true; }
    
    echo "Streaming packages installed (best effort)"
}

# Configure hardware access and udev rules
setup_hardware_access() {
    echo "Setting up hardware access rules..."
    
    # Create udev rules for USB devices and hardware access
    cat > /etc/udev/rules.d/99-ceraui-hardware.rules << 'EOF'
# CeraUI Hardware Access Rules
# USB Audio devices
SUBSYSTEM=="sound", GROUP="audio", MODE="0664"
KERNEL=="controlC[0-9]*", GROUP="audio", MODE="0664"

# USB Video devices (webcams, capture cards)
SUBSYSTEM=="video4linux", GROUP="video", MODE="0664"
KERNEL=="video[0-9]*", GROUP="video", MODE="0664"

# USB Serial devices (modems)
KERNEL=="ttyUSB[0-9]*", GROUP="dialout", MODE="0664"
KERNEL=="ttyACM[0-9]*", GROUP="dialout", MODE="0664"

# USB Mass storage (modems in storage mode)
SUBSYSTEM=="usb", ATTR{bDeviceClass}=="08", GROUP="plugdev", MODE="0664"

# Modem management interfaces
SUBSYSTEM=="usb", ATTRS{bInterfaceClass}=="02", ATTRS{bInterfaceSubClass}=="02", GROUP="dialout", MODE="0664"

# RK3588 HDMI capture (if available)
KERNEL=="video0", SUBSYSTEM=="video4linux", ATTRS{name}=="rk_hdmirx", GROUP="video", MODE="0664"

# GPIO access for RK3588
SUBSYSTEM=="gpio", GROUP="gpio", MODE="0664"
KERNEL=="gpiochip*", GROUP="gpio", MODE="0664"

# I2C and SPI access
KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0664"
KERNEL=="spidev[0-9]*", GROUP="spi", MODE="0664"
EOF
    
    # Create additional groups if they don't exist
    groupadd -f gpio
    groupadd -f i2c
    groupadd -f spi
    
    # Add ceraui user to hardware groups
    usermod -aG gpio,i2c,spi ceraui
    
    echo "Hardware access rules configured"
}

# Apply system optimizations for streaming
apply_streaming_optimizations() {
    echo "Applying streaming performance optimizations..."
    
    # Network optimizations for streaming
    cat > /etc/sysctl.d/99-ceraui-streaming.conf << 'EOF'
# CeraUI Streaming Optimizations

# Network buffer sizes for streaming
net.core.rmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_default = 262144
net.core.wmem_max = 16777216

# TCP optimizations
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr

# Reduce swappiness for better performance
vm.swappiness = 10

# File system optimizations
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF
    
    # Configure CPU governor for performance (ensure cpufrequtils is present)
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]; then
        echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
    fi
    
    # Configure tmpfs for temporary streaming files
    echo 'tmpfs /tmp tmpfs defaults,noatime,size=1G 0 0' >> /etc/fstab
    
    echo "Streaming optimizations applied"
}

# Configure WiFi and networking
configure_networking() {
    echo "Configuring networking for CeraLive..."
    
    # Enable core services (prefer NetworkManager, avoid enabling systemd-networkd simultaneously)
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable systemd-resolved || true
        systemctl enable NetworkManager || true
        systemctl enable avahi-daemon || true
        # Do not enable systemd-networkd when NetworkManager manages interfaces
        systemctl disable systemd-networkd 2>/dev/null || true
    fi

    # Ensure hostname is set to 'ceralive'
    echo "ceralive" > /etc/hostname
    sed -i 's/^127.0.1.1.*/127.0.1.1\tceralive/g' /etc/hosts || echo -e "127.0.1.1\tceralive" >> /etc/hosts

    # Ensure mDNS (.local) resolution is enabled
    if grep -q '^hosts:.*mdns' /etc/nsswitch.conf 2>/dev/null; then
        true
    else
        sed -i 's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns mdns4/g' /etc/nsswitch.conf || true
    fi

    # Configure NetworkManager for WiFi management
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/ceralive.conf << 'EOF'
[main]
# CeraLive NetworkManager configuration
dns=systemd-resolved
systemd-resolved=true

[device]
# Manage all devices
wifi.scan-rand-mac-address=yes
EOF
    
    echo "Networking configured"
}

# Install and configure services
configure_services() {
    echo "Configuring CeraUI services..."
    
    # Enable required services (guard inside chroot)
    ENABLE_SERVICES=(
        "systemd-resolved" 
        "NetworkManager"
        "ModemManager"
        "ssh"
        "chrony"
    )
    
    if command -v systemctl >/dev/null 2>&1; then
        for service in "${ENABLE_SERVICES[@]}"; do
            systemctl enable "$service" 2>/dev/null || echo "Warning: Could not enable $service"
        done
    fi
    
    # Disable unnecessary services for minimal footprint
    DISABLE_SERVICES=(
        "bluetooth"
        "cups"
        "ModemManager"
    )
    
    for service in "${DISABLE_SERVICES[@]}"; do
        systemctl disable "$service" 2>/dev/null || true
    done
    
    echo "Services configured"
}

setup_hostname_service() {
    echo "Installing CeraLive hostname auto-config service..."

    mkdir -p /etc/ceralive

    # First-boot script
    cat > /usr/local/sbin/ceralive-set-hostname << 'EOF'
#!/bin/bash
set -euo pipefail

BASE_NAME="ceralive"
INDEX_FILE="/etc/ceralive/host_index"
LOCK_FILE="/etc/ceralive/hostname.lock"

# Do nothing if already set once
if [ -f "$LOCK_FILE" ]; then
    exit 0
fi

index=""
if [ -s "$INDEX_FILE" ]; then
    index="$(cat "$INDEX_FILE" | sed -E 's/[^0-9]//g')"
fi

if [ -z "$index" ]; then
    # Derive stable number from machine-id (1..9999)
    mid="$(tr -cd 'a-f0-9' </etc/machine-id | tail -c 4)"
    [ -n "$mid" ] || mid="0001"
    num=$(( 16#$mid ))
    index=$(( (num % 9999) + 1 ))
fi

if [ "$index" = "1" ]; then
    NEW_HOSTNAME="${BASE_NAME}"
else
    NEW_HOSTNAME="${BASE_NAME}-${index}"
fi

# Apply hostname
hostnamectl set-hostname "$NEW_HOSTNAME" || echo "$NEW_HOSTNAME" > /etc/hostname

# Update hosts
if grep -qE '^127\.0\.1\.1\b' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts || true
else
    echo -e "127.0.1.1\t${NEW_HOSTNAME}" >> /etc/hosts
fi
# Ensure localhost remains
if ! grep -qE '^127\.0\.0\.1\b.*\blocalhost\b' /etc/hosts; then
    sed -i 's/^127\.0\.0\.1.*/127.0.0.1\tlocalhost/' /etc/hosts || echo -e "127.0.0.1\tlocalhost" >> /etc/hosts
fi

# Mark done
: > "$LOCK_FILE"
EOF
    chmod +x /usr/local/sbin/ceralive-set-hostname

    # Systemd unit
    cat > /etc/systemd/system/ceralive-hostname.service << 'EOF'
[Unit]
Description=CeraLive unique hostname setup
After=systemd-machine-id-commit.service
Before=network-pre.target avahi-daemon.service
Wants=network-pre.target
ConditionPathExists=/etc/machine-id

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ceralive-set-hostname
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable ceralive-hostname.service || true
    fi
}


# Copy overlay files if they exist
copy_overlay_files() {
    if [ -d "/tmp/overlay" ]; then
        echo "Copying overlay files..."
        cp -rv /tmp/overlay/* / || true
        echo "Overlay files copied"
    fi
}

# Create CeraUI directories and configuration
create_ceraui_structure() {
    echo "Creating CeraLive directory structure..."
    
    # Core dirs (internal tool still uses ceraui paths)
    mkdir -p /etc/opt/ceraui
    mkdir -p /opt/ceraui/{bin,lib,share}
    mkdir -p /var/opt/ceraui/{cache,logs}
    mkdir -p /home/ceraui/{.config/ceraui,.local/share/ceraui}

    # Branding files
    mkdir -p /etc/ceralive
    cat > /etc/ceralive/release << 'EOF'
NAME="CeraLive"
PRETTY_NAME="CeraLive Streaming Appliance"
ID=ceralive
VERSION_ID="1"
BUILD_BRANCH="stable"
EOF

    # Set ownership
    chown -R ceraui:ceraui /home/ceraui
    chown -R ceraui:ceraui /var/opt/ceraui
    
    # Placeholder configuration (legacy path retained for tool compatibility)
    cat > /etc/opt/ceraui/ceraui.conf << 'EOF'
# CeraLive Configuration File (legacy path for tool compatibility)
[streaming]
# Streaming configuration will be added here
default_encoder=h264_rockchip
audio_encoder=aac
bitrate=5000000
framerate=30

[network]
# Network configuration
enable_bonding=true
srtla_port=5000

[hardware]
# Hardware configuration
enable_hdmi_input=true
enable_usb_devices=true
auto_detect_input=true
EOF

    # Login banners
    echo 'CeraLive Streaming Appliance' > /etc/issue
    echo 'CeraLive Streaming Appliance' > /etc/issue.net
    
    echo "CeraLive structure created"
}

# Main customization function
main_customization() {
    echo "Starting CeraUI customization for $BOARD..."
    
    # Configure minimal APT sources
    configure_minimal_apt
    
    # Create CeraUI user
    create_ceraui_user
    
    # Setup CeraUI repository
    setup_ceraui_repository
    
    # Install streaming packages
    install_streaming_packages
    
    # Setup hardware access
    setup_hardware_access
    
    # Apply optimizations
    apply_streaming_optimizations
    
    # Configure networking
    configure_networking
    
    # Configure services
    configure_services

    # Install first-boot hostname service
    setup_hostname_service
    
    # Create CeraUI structure
    create_ceraui_structure
    
    # Copy overlay files
    copy_overlay_files
    
    # Clean up APT cache to save space
    apt-get autoremove -y || true
    apt-get autoclean || true
    
    echo "CeraUI customization completed successfully!"
}

# Run main customization
main_customization