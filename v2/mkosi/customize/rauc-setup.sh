#!/usr/bin/env bash
#
# customize/rauc-setup.sh — RAUC A/B update client wiring (Stage 4, task 26).
#
# Makes the FIRST FLASH update-capable by installing the two pieces the boot
# integration (task 27, platform/boot/install-boot.sh) deliberately left to the
# PKI tasks:
#   1. the device KEYRING  — the immutable root CA (cert-work/rauc/root-ca.pem)
#      that every signed .raucb is verified against → /etc/rauc/ceralive-keyring.pem
#   2. rauc.service         — installed so the D-Bus-activated OS-update client is available.
# It also drops a FALLBACK /etc/rauc/system.conf for builds where the board-aware
# generator did NOT run (x86 / parity / no-boot-BSP); on a real arm64 device,
# install-boot.sh has already written the authoritative board-keyed system.conf
# and this module leaves it untouched (single source of truth on hardware).
#
# WHAT THIS MODULE MUST NOT DO:
#   * embed any PRIVATE key — only the PUBLIC root CA cert goes in the keyring
#     (cert-work/rauc/README.txt: "Device RAUC keyring : root-ca.pem ONLY").
#   * reinstall the custom bootloader adapter — that is install-boot.sh's job
#     (platform layer, board-specific); duplicating it here would fight it.
#
# KEYRING DELIVERY: the root CA is PUBLIC and committed at
# v2/mkosi/runtime/rauc/ceralive-keyring.pem. It reaches this chroot module the
# same way the apt GPG public key does — base64 in $RAUC_ROOT_CA_B64 (forwarded by
# lib/orchestrate.sh). Run straight from the source tree (offline test / `run-all`
# from a checkout) it falls back to reading the committed file directly.
#
# DUAL-TRACK (see data-persistence.sh): the wired runtime executor
# mkosi.images/runtime/mkosi.postinst.chroot carries an inline `setup_rauc_client`
# twin of this module — keep the two in sync.
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no `|| true`.
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

RAUC_SETUP_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Source artifacts (committed): v2/mkosi/runtime/rauc/{ceralive-keyring.pem,system.conf}
RAUC_SRC_DIR="$(CDPATH='' cd -- "${RAUC_SETUP_DIR}/../runtime/rauc" 2>/dev/null && pwd || true)"

readonly RAUC_KEYRING_DEST="/etc/rauc/ceralive-keyring.pem"
readonly RAUC_SYSTEM_CONF="/etc/rauc/system.conf"
# Compatible string: the orchestrator ALWAYS sets it from the resolved manifest
# (lib/orchestrate.sh: COMPATIBLE_STRING=ceralive-${FAMILY}). Must equal the compatible
# baked into the signed bundle, or `rauc install` rejects it (foreign-bundle guard).
# ARCH-NEUTRAL fallback: the runtime layer carries ZERO SoC/family assumptions, so the
# default must not name an arch. 'ceralive-unknown' is a fail-closed sentinel that
# matches NO bundle (rauc refuses all) until a real COMPATIBLE_STRING is supplied.
readonly RAUC_COMPATIBLE="${COMPATIBLE_STRING:-ceralive-unknown}"

# Install the root CA into the device keyring. PUBLIC cert only — never a key.
install_keyring() {
  mkdir -p /etc/rauc
  if [[ -n "${RAUC_ROOT_CA_B64:-}" ]]; then
    log_info "installing RAUC device keyring (root CA) from env (RAUC_ROOT_CA_B64)"
    printf '%s' "${RAUC_ROOT_CA_B64}" | base64 -d >"${RAUC_KEYRING_DEST}"
  elif [[ -n "${RAUC_SRC_DIR}" && -s "${RAUC_SRC_DIR}/ceralive-keyring.pem" ]]; then
    log_info "installing RAUC device keyring (root CA) from committed source tree"
    cp -f "${RAUC_SRC_DIR}/ceralive-keyring.pem" "${RAUC_KEYRING_DEST}"
  else
    # Mirror apt-ceralive-repo.sh's explicit dev branch: a loud placeholder, never
    # a silent skip. An empty keyring makes `rauc install` refuse every bundle
    # (fail-closed) until the real root CA is baked in.
    log_warn "no RAUC root CA in env or source tree — writing EMPTY keyring placeholder (build will reject all bundles until the real root CA is provided)"
    : >"${RAUC_KEYRING_DEST}"
  fi
  chmod 0644 "${RAUC_KEYRING_DEST}"

  # Refuse to ship a keyring that smuggles a private key (defence in depth).
  if grep -q 'PRIVATE KEY' "${RAUC_KEYRING_DEST}"; then
    die "RAUC keyring ${RAUC_KEYRING_DEST} contains a PRIVATE KEY — the device keyring must hold ONLY the public root CA"
  fi
}

# Fallback system.conf — only when the board-aware generator (install-boot.sh) did
# not already write one. On arm64 device builds we MUST NOT clobber the authoritative
# board-keyed file (it carries compatible=ceralive-${FAMILY} + single-slot handling).
install_system_conf_fallback() {
  if [[ -e "${RAUC_SYSTEM_CONF}" ]]; then
    log_info "system.conf already present (board-aware generator ran) — leaving it authoritative, not overwriting"
    return 0
  fi
  log_info "writing fallback ${RAUC_SYSTEM_CONF} (compatible=${RAUC_COMPATIBLE})"
  mkdir -p /etc/rauc
  if [[ -n "${RAUC_SRC_DIR}" && -s "${RAUC_SRC_DIR}/system.conf" ]]; then
    sed -e "s|@COMPATIBLE_STRING@|${RAUC_COMPATIBLE}|g" \
      "${RAUC_SRC_DIR}/system.conf" >"${RAUC_SYSTEM_CONF}"
  else
    # Self-contained heredoc twin (chroot has no source tree). Keep in sync with
    # v2/mkosi/runtime/rauc/system.conf and install-boot.sh.
    cat >"${RAUC_SYSTEM_CONF}" <<EOF
[system]
compatible=${RAUC_COMPATIBLE}
bootloader=custom
boot-attempts=3

[handlers]
bootloader-custom-backend=/usr/lib/rauc/ceralive-rauc-boot-adapter

[keyring]
path=${RAUC_KEYRING_DEST}

[slot.rootfs.0]
device=/dev/disk/by-partlabel/rootfs_a
type=ext4
bootname=A

[slot.rootfs.1]
device=/dev/disk/by-partlabel/rootfs_b
type=ext4
bootname=B
EOF
  fi
  chmod 0644 "${RAUC_SYSTEM_CONF}"
}

# Verify the RAUC client. rauc.service is D-Bus-activated (Type=dbus, no [Install]
# section), so `systemctl enable` on it legitimately fails — that is NOT an error,
# the unit is reachable on demand. A MISSING unit, however, means the `rauc`
# package (shared.list) was not installed → a parity failure (fail loud).
enable_rauc_service() {
  if [[ ! -f /lib/systemd/system/rauc.service && ! -f /usr/lib/systemd/system/rauc.service ]]; then
    die "rauc.service not present — the 'rauc-service' package (shared.list) is not installed; cannot make the image update-capable"
  fi
  if systemctl enable rauc.service 2>/dev/null; then
    log_info "rauc.service enabled"
  else
    log_info "rauc.service is D-Bus-activated (no [Install]) — live on demand via the rauc CLI; no explicit enable needed"
  fi
}

setup_rauc_client() {
  log_info "wiring RAUC A/B update client (keyring + system.conf + service)"
  install_keyring
  install_system_conf_fallback
  enable_rauc_service
  log_success "RAUC update client ready (keyring=${RAUC_KEYRING_DEST}, compatible guard active)"
}

setup_rauc_client "$@"
