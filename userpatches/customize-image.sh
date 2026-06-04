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

# Setup CeraLive APT repository with mTLS and GPG signing
setup_ceraui_repository() {
    echo "Setting up CeraLive APT repository..."
    
    # Create directories
    mkdir -p /etc/opt/ceraui
    mkdir -p /etc/apt/certs
    mkdir -p /usr/share/keyrings
    
    # === mTLS Certs (CI mode only - secrets injected via environment) ===
    if [[ -n "${APT_CLIENT_CRT_B64:-}" && -n "${APT_CLIENT_KEY_B64:-}" ]]; then
        echo "CI mode: Installing mTLS certificates..."
        echo "$APT_CLIENT_CRT_B64" | base64 -d > /etc/apt/certs/client.crt
        echo "$APT_CLIENT_KEY_B64" | base64 -d > /etc/apt/certs/client.key
        chmod 600 /etc/apt/certs/client.key
        chmod 644 /etc/apt/certs/client.crt
        
        # APT SSL config for mTLS
        cat > /etc/apt/apt.conf.d/99ceralive-ssl << 'SSLEOF'
Acquire::https::apt.ceralive.tv::SslCert "/etc/apt/certs/client.crt";
Acquire::https::apt.ceralive.tv::SslKey  "/etc/apt/certs/client.key";
SSLEOF
        echo "mTLS certificates installed"
    else
        echo "Local mode: Skipping mTLS cert injection (secrets not available)"
    fi
    
    # === GPG Public Key (required for package verification) ===
    if [[ -n "${APT_GPG_PUBLIC_B64:-}" ]]; then
        echo "Installing GPG public key from environment..."
        echo "$APT_GPG_PUBLIC_B64" | base64 -d > /usr/share/keyrings/ceralive-archive-keyring.gpg
    elif [[ -f "/tmp/ceralive-archive-keyring.gpg" ]]; then
        echo "Installing GPG public key from overlay..."
        cp /tmp/ceralive-archive-keyring.gpg /usr/share/keyrings/
    else
        echo "Warning: No GPG public key found. APT verification may fail."
        # Create empty file to prevent errors
        touch /usr/share/keyrings/ceralive-archive-keyring.gpg
    fi
    chmod 644 /usr/share/keyrings/ceralive-archive-keyring.gpg
    
    # === APT Source Configuration ===
    CHANNEL="${CHANNEL:-stable}"
    echo "Configuring APT source for channel: ${CHANNEL}"
    
    cat > /etc/apt/sources.list.d/ceralive.list << EOF
# CeraLive APT Repository
deb [signed-by=/usr/share/keyrings/ceralive-archive-keyring.gpg] https://apt.ceralive.tv/dists/${CHANNEL}/ ./
EOF
    
    echo "CeraLive APT repository configured"
}

# Install pre-fetched .deb packages
install_ceralive_packages() {
    echo "Installing CeraLive packages..."
    
    # Check for pre-fetched .deb files
    if ls /tmp/debs/*.deb 1>/dev/null 2>&1; then
        echo "Found pre-fetched .deb packages:"
        ls -la /tmp/debs/*.deb
        
        # Install all .deb files
        dpkg -i /tmp/debs/*.deb || {
            echo "Some packages failed to install, attempting to fix dependencies..."
            apt-get -f install -y --no-install-recommends
        }
        
        echo "CeraLive packages installed"
    else
        echo "No pre-fetched .deb packages found in /tmp/debs/"
        echo "Skipping CeraLive package installation"
    fi
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
SUBSYSTEMS=="usb", ATTRS{bInterfaceClass}=="0e", ATTRS{bInterfaceSubClass}=="01", GROUP="video", MODE="0664"

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

# Configure SRTLA source policy routing for bonding
configure_srtla_routing() {
    echo "Configuring SRTLA source policy routing..."
    
    # Create srtla IPs file with correct permissions
    touch /tmp/srtla_ips
    chmod 666 /tmp/srtla_ips
    
    # Create routing tables for bonded interfaces (reserve tables 100-199 for modems)
    if ! grep -q "^100" /etc/iproute2/rt_tables 2>/dev/null; then
        cat >> /etc/iproute2/rt_tables << 'EOF'

# SRTLA bonding routing tables
100     modem0
101     modem1
102     modem2
103     modem3
104     modem4
105     modem5
106     modem6
107     modem7
110     wlan_bond
EOF
    fi
    
    # Create dhclient exit hook for source policy routing (modems via DHCP)
    mkdir -p /etc/dhcp/dhclient-exit-hooks.d
    cat > /etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing << 'HOOKEOF'
#!/bin/bash
# SRTLA Source Policy Routing for DHCP interfaces
# This ensures packets are routed out the correct interface based on source IP

# Only process USB network interfaces (modems)
case "$interface" in
    usb*|eth*|enx*)
        ;;
    *)
        exit 0
        ;;
esac

# Extract table number from interface name
case "$interface" in
    usb0|enx*0) TABLE=100 ;;
    usb1|enx*1) TABLE=101 ;;
    usb2|enx*2) TABLE=102 ;;
    usb3|enx*3) TABLE=103 ;;
    usb4|enx*4) TABLE=104 ;;
    usb5|enx*5) TABLE=105 ;;
    usb6|enx*6) TABLE=106 ;;
    usb7|enx*7) TABLE=107 ;;
    *) TABLE="" ;;
esac

[ -z "$TABLE" ] && exit 0

case "$reason" in
    BOUND|RENEW|REBIND|REBOOT)
        if [ -n "$new_ip_address" ] && [ -n "$new_routers" ]; then
            GATEWAY=$(echo "$new_routers" | awk '{print $1}')
            
            # Flush old rules and routes for this table
            ip rule del from "$new_ip_address" table "$TABLE" 2>/dev/null || true
            ip route flush table "$TABLE" 2>/dev/null || true
            
            # Add source-based routing rule
            ip rule add from "$new_ip_address" table "$TABLE" priority 100
            
            # Add default route via this interface's gateway
            ip route add default via "$GATEWAY" dev "$interface" table "$TABLE"
            
            # Also add the local network route
            if [ -n "$new_subnet_mask" ]; then
                NETWORK=$(ipcalc -n "$new_ip_address" "$new_subnet_mask" 2>/dev/null | grep -oP 'NETWORK=\K.*' || echo "")
                PREFIX=$(ipcalc -p "$new_ip_address" "$new_subnet_mask" 2>/dev/null | grep -oP 'PREFIX=\K.*' || echo "24")
                if [ -n "$NETWORK" ]; then
                    ip route add "$NETWORK/$PREFIX" dev "$interface" table "$TABLE" 2>/dev/null || true
                fi
            fi
            
            logger -t srtla-routing "Added source routing for $interface ($new_ip_address) via $GATEWAY table $TABLE"
        fi
        ;;
    EXPIRE|FAIL|RELEASE|STOP)
        # Clean up routing when interface goes down
        ip rule del from "$old_ip_address" table "$TABLE" 2>/dev/null || true
        ip route flush table "$TABLE" 2>/dev/null || true
        logger -t srtla-routing "Removed source routing for $interface table $TABLE"
        ;;
esac
HOOKEOF
    chmod +x /etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing
    
    # Create NetworkManager dispatcher for WiFi source routing
    mkdir -p /etc/NetworkManager/dispatcher.d
    cat > /etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing << 'DISPEOF'
#!/bin/bash
# SRTLA Source Routing for WiFi interfaces managed by NetworkManager

INTERFACE="$1"
ACTION="$2"

# Only process wlan interfaces
case "$INTERFACE" in
    wlan*) ;;
    *) exit 0 ;;
esac

TABLE=110  # wlan_bond table

case "$ACTION" in
    up|dhcp4-change)
        IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        GATEWAY=$(ip route show dev "$INTERFACE" | grep default | awk '{print $3}' | head -1)
        
        if [ -n "$IP" ] && [ -n "$GATEWAY" ]; then
            # Remove old rules for this IP
            ip rule del from "$IP" table "$TABLE" 2>/dev/null || true
            
            # Flush and recreate table routes
            ip route flush table "$TABLE" 2>/dev/null || true
            
            # Add source-based routing
            ip rule add from "$IP" table "$TABLE" priority 100
            ip route add default via "$GATEWAY" dev "$INTERFACE" table "$TABLE"
            
            logger -t srtla-routing "WiFi source routing: $INTERFACE ($IP) via $GATEWAY"
        fi
        ;;
    down)
        # Clean up when interface goes down
        ip rule show | grep "table $TABLE" | while read -r line; do
            IP=$(echo "$line" | grep -oP 'from \K\d+(\.\d+){3}')
            [ -n "$IP" ] && ip rule del from "$IP" table "$TABLE" 2>/dev/null || true
        done
        ip route flush table "$TABLE" 2>/dev/null || true
        logger -t srtla-routing "WiFi source routing removed for $INTERFACE"
        ;;
esac
DISPEOF
    chmod +x /etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing
    
    # Install ipcalc if available (for subnet calculations)
    apt-get install -y ipcalc 2>/dev/null || true
    
    echo "SRTLA source routing configured"
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
    
    # Create modular config directory
    mkdir -p /etc/ceralive/conf.d
    
    # SRTLA bonding configuration
    cat > /etc/ceralive/conf.d/srtla.conf << 'EOF'
# SRTLA Bonding Configuration
# Used by srtla_send for link aggregation

# Path to the IPs file that srtla_send reads
# CeraUI updates this file automatically when interfaces change
ips_file=/tmp/srtla_ips

# Default SRT latency in milliseconds
# Higher values = more buffering, better reliability
# Lower values = less delay, more sensitive to packet loss
srt_latency=2000

# Connection timeout in milliseconds
connection_timeout=3000
EOF

    # Streaming/encoder configuration
    cat > /etc/ceralive/conf.d/streaming.conf << 'EOF'
# Streaming Configuration
# Encoder and output settings

# Default video encoder (auto-detected based on hardware)
# Options: h264_rockchip, h264_nvenc, h264_vaapi, h264_software
default_encoder=auto

# Audio encoder
# Options: aac, opus
audio_encoder=aac

# Default video bitrate in bps
bitrate=5000000

# Default framerate
framerate=30

# Keyframe interval (GOP size in frames)
keyframe_interval=60
EOF

    # Network configuration
    cat > /etc/ceralive/conf.d/network.conf << 'EOF'
# Network Configuration
# Bonding and connectivity settings

# Enable multi-interface bonding via SRTLA
enable_bonding=true

# Prefer wired connections when available
prefer_wired=true

# Automatically reconnect on connection loss
auto_reconnect=true

# Reconnect delay in seconds
reconnect_delay=2
EOF

    # Hardware configuration
    cat > /etc/ceralive/conf.d/hardware.conf << 'EOF'
# Hardware Configuration
# Input devices and hardware acceleration

# Enable HDMI input capture (RK3588 HDMI-RX)
enable_hdmi_input=true

# Enable USB capture devices (webcams, capture cards)
enable_usb_devices=true

# Automatically detect and switch input sources
auto_detect_input=true

# Preferred capture resolution (WxH or 'auto')
capture_resolution=auto

# Hardware acceleration backend (auto-detected)
# Options: rockchip, nvidia, vaapi, none
hw_accel=auto
EOF

    # Modem configuration
    cat > /etc/ceralive/conf.d/modems.conf << 'EOF'
# Modem Configuration
# USB modem management settings

# Enable ModemManager for cellular modems
enable_modem_manager=true

# Auto-connect modems on boot
auto_connect=true

# Modem priority (lower = higher priority)
# USB modems typically get usb0, usb1, etc.
# Priority affects routing table order
default_priority=100

# Enable SMS notifications (if supported)
enable_sms=false
EOF

    # Legacy compatibility symlink
    ln -sf /etc/ceralive/conf.d /etc/opt/ceraui/conf.d 2>/dev/null || true

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
    
    # Setup CeraUI repository (mTLS + GPG)
    setup_ceraui_repository
    
    # Install CeraLive packages from pre-fetched .deb files
    install_ceralive_packages
    
    # Install streaming packages from system repos
    install_streaming_packages
    
    # Setup hardware access
    setup_hardware_access
    
    # Configure SRTLA source routing for bonding
    configure_srtla_routing
    
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