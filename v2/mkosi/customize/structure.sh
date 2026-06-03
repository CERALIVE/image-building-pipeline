#!/usr/bin/env bash
#
# customize/structure.sh — CeraLive directory layout + seed configs + branding.
#
# DECOMPOSED FROM: userpatches/customize-image.sh:create_ceraui_structure()
# (L634-770).
#
# UNIFIED NAMING: v1 split paths between /etc/opt/ceraui + /opt/ceraui +
# /var/opt/ceraui + /home/ceraui (internal "ceraui") and /etc/ceralive
# (branding). v2 unifies ALL of it on `ceralive`; the legacy /etc/opt/ceraui ->
# /etc/ceralive/conf.d compatibility symlink (v1 L763) is dropped because nothing
# in the v2 image references the ceraui path anymore.
#
# /etc + /var writes are left IN PLACE here (data-persistence relocation of
# /var/opt/ceralive is task 30, not this task).
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no `|| true`.
# Depends on the `ceralive` user/group existing (created in the base layer by
# users.sh) for the chown of /home/ceralive + /var/opt/ceralive.
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

readonly CERALIVE_USER="${CERALIVE_USER:-ceralive}"

create_ceralive_structure() {
  log_info "creating /etc/ceralive + /opt/ceralive + /var/opt/ceralive layout"
  mkdir -p /etc/opt/ceralive
  mkdir -p /opt/ceralive/bin /opt/ceralive/lib /opt/ceralive/share
  mkdir -p /var/opt/ceralive/cache /var/opt/ceralive/logs
  mkdir -p "/home/${CERALIVE_USER}/.config/ceralive" "/home/${CERALIVE_USER}/.local/share/ceralive"
  mkdir -p /etc/ceralive/conf.d

  log_info "writing /etc/ceralive/release branding"
  cat >/etc/ceralive/release <<'EOF'
NAME="CeraLive"
PRETTY_NAME="CeraLive Streaming Appliance"
ID=ceralive
VERSION_ID="1"
BUILD_BRANCH="stable"
EOF

  log_info "seeding /etc/ceralive/conf.d/*.conf defaults"
  cat >/etc/ceralive/conf.d/srtla.conf <<'EOF'
# SRTLA Bonding Configuration
# Used by srtla_send for link aggregation

# Path to the IPs file that srtla_send reads
# CeraUI updates this file automatically when interfaces change
ips_file=/tmp/srtla_ips

# Default SRT latency in milliseconds
srt_latency=2000

# Connection timeout in milliseconds
connection_timeout=3000
EOF

  cat >/etc/ceralive/conf.d/streaming.conf <<'EOF'
# Streaming Configuration
# Encoder and output settings

# Default video encoder (auto-detected based on hardware)
default_encoder=auto

# Audio encoder (aac|opus)
audio_encoder=aac

# Default video bitrate in bps
bitrate=5000000

# Default framerate
framerate=30

# Keyframe interval (GOP size in frames)
keyframe_interval=60
EOF

  cat >/etc/ceralive/conf.d/network.conf <<'EOF'
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

  cat >/etc/ceralive/conf.d/hardware.conf <<'EOF'
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
hw_accel=auto
EOF

  cat >/etc/ceralive/conf.d/modems.conf <<'EOF'
# Modem Configuration
# USB modem management settings

# Enable ModemManager for cellular modems
enable_modem_manager=true

# Auto-connect modems on boot
auto_connect=true

# Modem priority (lower = higher priority)
default_priority=100

# Enable SMS notifications (if supported)
enable_sms=false
EOF

  log_info "setting ownership for ${CERALIVE_USER} home + var tree"
  chown -R "${CERALIVE_USER}:${CERALIVE_USER}" "/home/${CERALIVE_USER}" /var/opt/ceralive

  log_info "writing login banners"
  echo 'CeraLive Streaming Appliance' >/etc/issue
  echo 'CeraLive Streaming Appliance' >/etc/issue.net

  log_success "CeraLive structure created"
}

create_ceralive_structure "$@"
