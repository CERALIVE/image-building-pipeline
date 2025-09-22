#!/bin/bash
set -euo pipefail

# CeraUI USB Device Access Configuration
# Creates comprehensive udev rules for streaming devices

RULES_FILE="/etc/udev/rules.d/99-ceraui-devices.rules"

cat > "$RULES_FILE" << 'EOF'
# CeraUI USB Device Access Rules
# Comprehensive rules for streaming and modem devices

# =============================================================================
# USB Audio Devices
# =============================================================================

# Standard USB Audio devices
SUBSYSTEM=="sound", GROUP="audio", MODE="0664"
KERNEL=="controlC[0-9]*", GROUP="audio", MODE="0664"
KERNEL=="hwC[0-9]*D[0-9]*", GROUP="audio", MODE="0664"
KERNEL=="midiC[0-9]*D[0-9]*", GROUP="audio", MODE="0664"

# USB Audio interfaces by vendor (common streaming interfaces)
SUBSYSTEMS=="usb", ATTRS{bInterfaceClass}=="01", ATTRS{bInterfaceSubClass}=="01", GROUP="audio", MODE="0664"
SUBSYSTEMS=="usb", ATTRS{bInterfaceClass}=="01", ATTRS{bInterfaceSubClass}=="02", GROUP="audio", MODE="0664"

# =============================================================================
# USB Video Devices (Cameras, Capture Cards)
# =============================================================================

# Video4Linux devices
SUBSYSTEM=="video4linux", GROUP="video", MODE="0664"
KERNEL=="video[0-9]*", GROUP="video", MODE="0664"

# USB Video Class (UVC) devices
SUBSYSTEMS=="usb", ATTRS{bInterfaceClass}=="0e", ATTRS{bInterfaceSubClass}=="01", GROUP="video", MODE="0664"

# Common USB capture cards and cameras
ATTRS{idVendor}=="1bcf", ATTRS{idProduct}=="*", GROUP="video", MODE="0664"  # Sunplus cameras
ATTRS{idVendor}=="0c45", ATTRS{idProduct}=="*", GROUP="video", MODE="0664"  # Microdia cameras
ATTRS{idVendor}=="046d", ATTRS{idProduct}=="*", GROUP="video", MODE="0664"  # Logitech cameras
ATTRS{idVendor}=="1e4e", ATTRS{idProduct}=="*", GROUP="video", MODE="0664"  # Cubetek cameras
ATTRS{idVendor}=="05ac", ATTRS{idProduct}=="*", GROUP="video", MODE="0664"  # Apple cameras

# =============================================================================
# HDMI Input Capture (Rockchip specific)
# =============================================================================

# Rockchip HDMI input device
KERNEL=="video0", SUBSYSTEM=="video4linux", ATTRS{name}=="rk_hdmirx", GROUP="video", MODE="0664"
KERNEL=="video*", SUBSYSTEM=="video4linux", ATTRS{name}=="*hdmi*", GROUP="video", MODE="0664"

# DRM devices for hardware acceleration
KERNEL=="card[0-9]*", SUBSYSTEM=="drm", GROUP="video", MODE="0664"
KERNEL=="renderD[0-9]*", SUBSYSTEM=="drm", GROUP="video", MODE="0664"

# =============================================================================
# USB Modem Devices (4G/5G)
# =============================================================================

# USB Serial devices (AT command interfaces)
KERNEL=="ttyUSB[0-9]*", GROUP="dialout", MODE="0664"
KERNEL=="ttyACM[0-9]*", GROUP="dialout", MODE="0664"

# USB CDC-WDM devices (QMI/MBIM interfaces)
KERNEL=="cdc-wdm[0-9]*", GROUP="dialout", MODE="0664"

# USB network interfaces from modems
KERNEL=="wwan[0-9]*", GROUP="dialout", MODE="0664"

# Common modem vendors by USB ID
# Quectel modems
ATTRS{idVendor}=="2c7c", GROUP="dialout", MODE="0664"
# Sierra Wireless modems  
ATTRS{idVendor}=="1199", GROUP="dialout", MODE="0664"
# Huawei modems
ATTRS{idVendor}=="12d1", GROUP="dialout", MODE="0664"
# ZTE modems
ATTRS{idVendor}=="19d2", GROUP="dialout", MODE="0664"
# Telit modems
ATTRS{idVendor}=="1bc7", GROUP="dialout", MODE="0664"

# USB Mass Storage mode (modems before switching)
SUBSYSTEM=="usb", ATTR{bDeviceClass}=="08", GROUP="plugdev", MODE="0664"

# =============================================================================
# Network Management
# =============================================================================

# Network interface management
KERNEL=="eth[0-9]*", GROUP="netdev", MODE="0664"
KERNEL=="wlan[0-9]*", GROUP="netdev", MODE="0664"
KERNEL=="usb[0-9]*", GROUP="netdev", MODE="0664"

# =============================================================================
# Power Management and GPIO
# =============================================================================

# GPIO devices (for hardware control)
SUBSYSTEM=="gpio", GROUP="gpio", MODE="0664"
KERNEL=="gpiochip[0-9]*", GROUP="gpio", MODE="0664"

# I2C devices (for sensors and control)
KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0664"

# =============================================================================
# Custom Rules for Streaming Optimization
# =============================================================================

# Increase buffer sizes for video devices
KERNEL=="video[0-9]*", ATTR{name}=="*", RUN+="/bin/sh -c 'echo 8 > /sys/class/video4linux/%k/device/video_buffers'"

# Set scheduler for media processes
KERNEL=="video[0-9]*", TAG+="systemd", ENV{SYSTEMD_WANTS}="ceraui-optimize@%k.service"

# =============================================================================
# Device Permissions for CeraUI User
# =============================================================================

# Ensure ceraui user has access to all streaming devices
KERNEL=="video[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
KERNEL=="audio[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
KERNEL=="ttyUSB[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
KERNEL=="ttyACM[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"

EOF

echo "CeraUI udev rules created at $RULES_FILE"
echo "Run 'sudo udevadm control --reload-rules && sudo udevadm trigger' to apply"
