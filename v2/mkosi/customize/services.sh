#!/usr/bin/env bash
#
# customize/services.sh — systemd service enablement + network-service config +
# the first-boot unique-hostname service.
#
# DECOMPOSED FROM (MERGE): userpatches/customize-image.sh:configure_services()
# (L511-542), the service/network-config half of configure_networking()
# (L471-509) and setup_hostname_service() (L544-622). These are kept in one
# module because they all configure the SAME subsystem — the appliance's network
# services and their boot-time wiring.
#
# v1 CONTRADICTION RESOLVED: v1 BOTH enabled (L519) and disabled (L534)
# ModemManager. v2 ENABLES it (cellular modems are core to bonded streaming) and
# drops it from the disable set — matching the authoritative v2 runtime port.
#
# STRICT semantics (common.sh DESIGN RULE):
#   * enable: a unit we EXPECT must be enableable — a missing unit is a parity
#     failure, so `systemctl enable` runs without `|| true` (v1 swallowed it).
#   * disable: disabling a never-installed unit is a legitimate no-op — guarded
#     by an explicit list-unit-files check, NOT `2>/dev/null || true`.
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no `|| true`.
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

SERVICES_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Committed source artifacts (boot healthcheck): v2/mkosi/runtime/ceralive-healthcheck.{sh,service}
RUNTIME_SRC_DIR="$(CDPATH='' cd -- "${SERVICES_DIR}/../runtime" 2>/dev/null && pwd || true)"

readonly CERALIVE_HOSTNAME="${CERALIVE_HOSTNAME:-ceralive}"

# Services that MUST exist + be enabled (v1 L516-528, configuration reconciled).
readonly CERALIVE_ENABLE_SERVICES="systemd-resolved NetworkManager ModemManager ssh chrony avahi-daemon"
# Services to disable IF present (minimal footprint; v1 L531-535 minus the
# self-contradictory ModemManager + the redundant systemd-networkd from L481).
readonly CERALIVE_DISABLE_SERVICES="bluetooth.service cups.service systemd-networkd.service"

enable_service() {
  # A missing unit here is a parity failure — fail loudly (no `|| true`).
  systemctl enable "$1"
}

disable_service() {
  # Disabling a not-installed unit is a legitimate no-op on a minimal image.
  local svc="$1"
  if systemctl list-unit-files "${svc}" >/dev/null 2>&1 \
     && systemctl list-unit-files "${svc}" | grep -q "${svc}"; then
    systemctl disable "${svc}"
  else
    log_info "service ${svc} not present — nothing to disable"
  fi
}

# NetworkManager + mDNS + static hostname/hosts (v1 configure_networking L484-506).
configure_network_services() {
  log_info "configuring static hostname '${CERALIVE_HOSTNAME}' + /etc/hosts"
  echo "${CERALIVE_HOSTNAME}" >/etc/hostname
  if grep -q '^127.0.1.1' /etc/hosts 2>/dev/null; then
    sed -i "s/^127.0.1.1.*/127.0.1.1\t${CERALIVE_HOSTNAME}/g" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "${CERALIVE_HOSTNAME}" >>/etc/hosts
  fi

  log_info "enabling mDNS (.local) resolution in /etc/nsswitch.conf"
  if ! grep -q '^hosts:.*mdns' /etc/nsswitch.conf 2>/dev/null; then
    sed -i 's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns mdns4/g' /etc/nsswitch.conf
  fi

  log_info "writing NetworkManager conf.d/ceralive.conf (dns=systemd-resolved)"
  mkdir -p /etc/NetworkManager/conf.d
  cat >/etc/NetworkManager/conf.d/ceralive.conf <<'EOF'
[main]
# CeraLive NetworkManager configuration
dns=systemd-resolved
systemd-resolved=true

[device]
# Manage all devices
wifi.scan-rand-mac-address=yes
EOF
}

# First-boot unique-hostname service (v1 setup_hostname_service L544-622).
install_hostname_service() {
  log_info "installing first-boot unique-hostname service (ceralive-hostname.service)"
  mkdir -p /etc/ceralive

  cat >/usr/local/sbin/ceralive-set-hostname <<'EOF'
#!/bin/bash
set -euo pipefail

BASE_NAME="ceralive"
INDEX_FILE="/etc/ceralive/host_index"
LOCK_FILE="/etc/ceralive/hostname.lock"

# Do nothing if already set once.
[ -f "$LOCK_FILE" ] && exit 0

index=""
if [ -s "$INDEX_FILE" ]; then
    index="$(sed -E 's/[^0-9]//g' "$INDEX_FILE")"
fi

if [ -z "$index" ]; then
    # Derive a stable number from machine-id (1..9999).
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

hostnamectl set-hostname "$NEW_HOSTNAME" || echo "$NEW_HOSTNAME" >/etc/hostname

if grep -qE '^127\.0\.1\.1\b' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
else
    printf '127.0.1.1\t%s\n' "${NEW_HOSTNAME}" >>/etc/hosts
fi
if ! grep -qE '^127\.0\.0\.1\b.*\blocalhost\b' /etc/hosts; then
    sed -i 's/^127\.0\.0\.1.*/127.0.0.1\tlocalhost/' /etc/hosts
fi

: >"$LOCK_FILE"
EOF
  chmod +x /usr/local/sbin/ceralive-set-hostname

  cat >/etc/systemd/system/ceralive-hostname.service <<'EOF'
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

  enable_service ceralive-hostname.service
}

# Boot healthcheck (task 29): gate `rauc mark-good` on REAL streaming health so a
# boots-but-can't-encode slot rolls back instead of confirming itself. Installs the
# committed runtime artifacts and enables the oneshot unit. DUAL-TRACK: the wired
# runtime executor mkosi.images/runtime/mkosi.postinst.chroot carries an inline twin.
install_healthcheck_service() {
  log_info "installing boot healthcheck (ceralive-healthcheck.service — gates rauc mark-good)"
  [[ -n "${RUNTIME_SRC_DIR}" && -f "${RUNTIME_SRC_DIR}/ceralive-healthcheck.sh" ]] \
    || die "boot healthcheck source not found under ${SERVICES_DIR}/../runtime"
  mkdir -p /usr/local/bin
  install -m 0755 "${RUNTIME_SRC_DIR}/ceralive-healthcheck.sh" /usr/local/bin/ceralive-healthcheck.sh
  install -m 0644 "${RUNTIME_SRC_DIR}/ceralive-healthcheck.service" /etc/systemd/system/ceralive-healthcheck.service
  enable_service ceralive-healthcheck.service
}

configure_services() {
  configure_network_services

  log_info "enabling services: ${CERALIVE_ENABLE_SERVICES}"
  local svc
  for svc in ${CERALIVE_ENABLE_SERVICES}; do
    enable_service "${svc}"
  done

  log_info "disabling services (if present): ${CERALIVE_DISABLE_SERVICES}"
  for svc in ${CERALIVE_DISABLE_SERVICES}; do
    disable_service "${svc}"
  done

  install_hostname_service
  install_healthcheck_service

  log_success "services configured"
}

configure_services "$@"
