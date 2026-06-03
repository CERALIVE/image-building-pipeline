#!/usr/bin/env bash
#
# customize/udev.sh — hardware-access udev rules for the streaming appliance.
#
# DECOMPOSED FROM (UNION): userpatches/customize-image.sh:setup_hardware_access()
# (L237-283) AND scripts/udev-rules.sh (L1-129). v1 main_customization() only
# wrote the SHORT rule set (L242-272); udev-rules.sh held the richer vendor /
# DRM / QMI-MBIM / netdev policy but was a separate, never-invoked script. v2
# folds both into ONE canonical, deduplicated rules file so the comprehensive
# policy actually ships.
#
# UNIFIED NAMING: file 99-ceraui-hardware.rules / 99-ceraui-devices.rules →
# 99-ceralive-hardware.rules; the ceraui-optimize@ unit reference →
# ceralive-optimize@ (SYSTEMD_WANTS no-ops if the unit is absent).
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no `|| true`.
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

setup_hardware_access() {
  log_info "installing udev hardware-access rules (99-ceralive-hardware.rules)"
  mkdir -p /etc/udev/rules.d

  cat >/etc/udev/rules.d/99-ceralive-hardware.rules <<'EOF'
# CeraLive Hardware Access Rules
# Union of customize-image.sh:setup_hardware_access() + scripts/udev-rules.sh.

# =============================================================================
# USB Audio Devices
# =============================================================================
SUBSYSTEM=="sound", GROUP="audio", MODE="0664"
KERNEL=="controlC[0-9]*", GROUP="audio", MODE="0664"
KERNEL=="hwC[0-9]*D[0-9]*", GROUP="audio", MODE="0664"
KERNEL=="midiC[0-9]*D[0-9]*", GROUP="audio", MODE="0664"
SUBSYSTEMS=="usb", ATTRS{bInterfaceClass}=="01", ATTRS{bInterfaceSubClass}=="01", GROUP="audio", MODE="0664"
SUBSYSTEMS=="usb", ATTRS{bInterfaceClass}=="01", ATTRS{bInterfaceSubClass}=="02", GROUP="audio", MODE="0664"

# =============================================================================
# USB Video Devices (webcams, capture cards)
# =============================================================================
SUBSYSTEM=="video4linux", GROUP="video", MODE="0664"
KERNEL=="video[0-9]*", GROUP="video", MODE="0664"
SUBSYSTEMS=="usb", ATTRS{bInterfaceClass}=="0e", ATTRS{bInterfaceSubClass}=="01", GROUP="video", MODE="0664"
ATTRS{idVendor}=="1bcf", GROUP="video", MODE="0664"
ATTRS{idVendor}=="0c45", GROUP="video", MODE="0664"
ATTRS{idVendor}=="046d", GROUP="video", MODE="0664"
ATTRS{idVendor}=="1e4e", GROUP="video", MODE="0664"
ATTRS{idVendor}=="05ac", GROUP="video", MODE="0664"

# =============================================================================
# HDMI Input Capture (RK3588) + DRM render nodes
# =============================================================================
KERNEL=="video0", SUBSYSTEM=="video4linux", ATTRS{name}=="rk_hdmirx", GROUP="video", MODE="0664"
KERNEL=="video*", SUBSYSTEM=="video4linux", ATTRS{name}=="*hdmi*", GROUP="video", MODE="0664"
KERNEL=="card[0-9]*", SUBSYSTEM=="drm", GROUP="video", MODE="0664"
KERNEL=="renderD[0-9]*", SUBSYSTEM=="drm", GROUP="video", MODE="0664"

# =============================================================================
# USB Modem Devices (4G/5G)
# =============================================================================
KERNEL=="ttyUSB[0-9]*", GROUP="dialout", MODE="0664"
KERNEL=="ttyACM[0-9]*", GROUP="dialout", MODE="0664"
KERNEL=="cdc-wdm[0-9]*", GROUP="dialout", MODE="0664"
KERNEL=="wwan[0-9]*", GROUP="dialout", MODE="0664"
SUBSYSTEM=="usb", ATTRS{bInterfaceClass}=="02", ATTRS{bInterfaceSubClass}=="02", GROUP="dialout", MODE="0664"
# Common modem vendors by USB ID (Quectel / Sierra / Huawei / ZTE / Telit)
ATTRS{idVendor}=="2c7c", GROUP="dialout", MODE="0664"
ATTRS{idVendor}=="1199", GROUP="dialout", MODE="0664"
ATTRS{idVendor}=="12d1", GROUP="dialout", MODE="0664"
ATTRS{idVendor}=="19d2", GROUP="dialout", MODE="0664"
ATTRS{idVendor}=="1bc7", GROUP="dialout", MODE="0664"
# USB Mass Storage mode (modems before mode-switching)
SUBSYSTEM=="usb", ATTR{bDeviceClass}=="08", GROUP="plugdev", MODE="0664"

# =============================================================================
# Network Interface Management
# =============================================================================
KERNEL=="eth[0-9]*", GROUP="netdev", MODE="0664"
KERNEL=="wlan[0-9]*", GROUP="netdev", MODE="0664"
KERNEL=="usb[0-9]*", GROUP="netdev", MODE="0664"

# =============================================================================
# GPIO / I2C / SPI (RK3588)
# =============================================================================
SUBSYSTEM=="gpio", GROUP="gpio", MODE="0664"
KERNEL=="gpiochip*", GROUP="gpio", MODE="0664"
KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0664"
KERNEL=="spidev[0-9]*", GROUP="spi", MODE="0664"

# =============================================================================
# Streaming optimization + CeraLive user device permissions
# =============================================================================
KERNEL=="video[0-9]*", ATTR{name}=="*", RUN+="/bin/sh -c 'echo 8 > /sys/class/video4linux/%k/device/video_buffers'"
KERNEL=="video[0-9]*", TAG+="systemd", ENV{SYSTEMD_WANTS}="ceralive-optimize@%k.service"
KERNEL=="video[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
KERNEL=="audio[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
KERNEL=="ttyUSB[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
KERNEL=="ttyACM[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
EOF

  log_success "udev hardware-access rules installed"
}

setup_hardware_access "$@"
