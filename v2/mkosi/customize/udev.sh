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
# 99-ceralive-hardware.rules. The dangling SYSTEMD_WANTS=ceralive-optimize@%k
# want was removed: no such unit ships in the image (the rule was a permanent
# no-op pointing at a never-provided template unit).
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
KERNEL=="video[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
KERNEL=="audio[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
KERNEL=="ttyUSB[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
KERNEL=="ttyACM[0-9]*", RUN+="/bin/chmod g+rw /dev/%k"
EOF

  log_success "udev hardware-access rules installed"
}

# generate_modem_slot_uid_rules — fail-closed generator for per-slot ModemManager
# UID naming. The permanent generic modem rules in setup_hardware_access (the
# "USB Modem Devices (4G/5G)" block, dialout group-tagging by kernel node + vendor
# ID) always ship and are NOT touched here. This function emits an ADDITIONAL
# 78-mm-ceralive-slot-uid.rules ONLY when the board's modem_ports status is
# `verified` and carries slot ID_PATHs — mapping each physical slot to a stable
# ID_MM_PHYSDEV_UID so ModemManager reports a deterministic slot identity
# regardless of ttyUSB enumeration order.
#
# FAIL-CLOSED (no permissive fallback): any status other than an explicit
# `verified` — `unverified` (the shipped default), unset, or anything else —
# emits ZERO generated slot-uid rules and removes any stale generated file, so an
# A/B slot never keeps rules the current manifest no longer authorizes. Slot
# verification is a hardware-gated step (v2/docs/modem-matrix.md §7); until it is
# done, the generic rules alone govern modem access.
generate_modem_slot_uid_rules() {
  local rules_dir="${MODEM_SLOT_RULES_DIR:-/etc/udev/rules.d}"
  local rules_file="${rules_dir}/78-mm-ceralive-slot-uid.rules"
  local status="${CERALIVE_MODEM_PORTS_STATUS:-unverified}"

  if [[ "${status}" != "verified" ]]; then
    rm -f "${rules_file}"
    log_info "modem slot-uid rules: modem_ports status='${status}' (not verified) — emitting NO generated slot-uid rules (fail-closed; generic modem rules still apply)"
    return 0
  fi

  local slots="${CERALIVE_MODEM_PORTS_SLOTS:-}"
  [[ -n "${slots}" ]] \
    || die "modem_ports status=verified but no slot definitions (CERALIVE_MODEM_PORTS_SLOTS empty) — refusing to emit an empty verified rule set"

  mkdir -p "${rules_dir}"
  {
    printf '# CeraLive generated modem slot-UID rules — DO NOT EDIT.\n'
    printf '# Emitted from board modem_ports (status: verified). One stable\n'
    printf '# ID_MM_PHYSDEV_UID per hardware-verified physical modem slot.\n'
    local pair name id_path
    for pair in ${slots}; do
      name="${pair%%=*}"
      id_path="${pair#*=}"
      [[ -n "${name}" && -n "${id_path}" && "${name}" != "${id_path}" ]] \
        || die "malformed modem slot definition '${pair}' (expected <name>=<ID_PATH>)"
      printf 'ACTION=="add|bind", SUBSYSTEM=="usb", ENV{ID_PATH}=="%s", ENV{ID_MM_PHYSDEV_UID}="%s"\n' \
        "${id_path}" "${name}"
    done
  } >"${rules_file}"
  log_success "modem slot-uid rules: emitted $(basename "${rules_file}") for verified slots: ${slots}"
}

setup_hardware_access "$@"
generate_modem_slot_uid_rules "$@"
