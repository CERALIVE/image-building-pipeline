#!/usr/bin/env bash
#
# customize/postinst-lib.sh — SINGLE SOURCE OF TRUTH for the runtime customization
# logic that used to be duplicated ("dual-track") between the wired runtime
# executor mkosi.images/runtime/mkosi.postinst.chroot and the decomposed
# customize/*.sh modules (see Task 6).
#
# It is SOURCED (never executed) by:
#   * mkosi.images/runtime/mkosi.postinst.chroot — via "${SRCDIR}/customize/
#     postinst-lib.sh" (mkosi mounts $SRCDIR=v2/mkosi inside the .chroot postinst),
#   * customize/services.sh and customize/data-persistence.sh — via their own dir,
#     so the canonical decomposed modules and the wired postinst share ONE copy.
#
# SELF-CONTAINED: it does NOT hard-depend on lib/common.sh (the runtime postinst
# is standalone and runs in a chroot where the repo tree's lib/ is not mounted).
# It provides FALLBACK log()/die() only when the caller has not already defined
# them, so callers that DO source common.sh (the customize modules) keep their
# own structured loggers, and the standalone postinst keeps its own log().
#
# Payload scripts/units for the boot healthcheck (task 29) and cert rotation
# (task 42) are NOT re-embedded here as heredocs — they are INSTALLED from the
# committed canonical artifacts under "${CERALIVE_RUNTIME_SRC}" (the runtime/
# source dir), exactly as customize/services.sh does. Callers MUST export
# CERALIVE_RUNTIME_SRC before calling setup_boot_healthcheck / setup_cert_rotation.
#
# shellcheck shell=bash

# --- Fallback helpers (defined only if the caller has not) -------------------
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[runtime-lib] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() { log "FATAL: $*"; exit 1; }
fi

# Idempotent group creation (replaces v1's `|| true`).
ensure_group() {
  local grp="$1"
  getent group "${grp}" >/dev/null || groupadd --system "${grp}"
}

enable_service() {
  # A service we EXPECT must be enableable; a missing unit is a parity failure.
  local svc="$1"
  systemctl enable "${svc}"
}

disable_service() {
  # Disabling a not-installed unit is a legitimate no-op (the package was never
  # added to this minimal image) — skip cleanly when the unit file is absent.
  local svc="$1"
  if systemctl list-unit-files "${svc}" >/dev/null 2>&1 \
     && systemctl list-unit-files "${svc}" | grep -q "${svc}"; then
    systemctl disable "${svc}"
  else
    log "service ${svc} not present — nothing to disable"
  fi
}

# --- 8. Networking (verbatim from postinst section 8) ---------------------
configure_networking() {
  log "configuring networking (NetworkManager + mDNS)"
  echo "ceralive" >/etc/hostname
  if grep -q '^127.0.1.1' /etc/hosts; then
    sed -i 's/^127.0.1.1.*/127.0.1.1\tceralive/g' /etc/hosts
  else
    printf '127.0.1.1\tceralive\n' >>/etc/hosts
  fi

  if ! grep -q '^hosts:.*mdns' /etc/nsswitch.conf 2>/dev/null; then
    sed -i 's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns mdns4/g' /etc/nsswitch.conf
  fi

  mkdir -p /etc/NetworkManager/conf.d
  cat >/etc/NetworkManager/conf.d/ceralive.conf <<'EOF'
[main]
dns=systemd-resolved
systemd-resolved=true

[device]
wifi.scan-rand-mac-address=yes

# IPv4 link-local fallback on the wired control port. Without this, a network
# that offers no DHCP/RA (dead or hostile DHCP server, dumb switch, a laptop
# plugged in directly) leaves the appliance with NO IPv4 address at all and
# unreachable over v4. link-local=enabled (=3) always assigns a 169.254/16
# address (RFC 3927) alongside any lease, so combined with avahi mDNS the device
# is reachable at ceralive.local on ANY network out of the box. Scoped to eth0
# ONLY: bonded SRTLA modems / wlan_bond must never get a competing 169.254 route.
[connection-eth0-llv4]
match-device=interface-name:eth0
ipv4.link-local=3
EOF

  install_interface_naming
}

# --- 8b. Deterministic interface naming (eth0/eth1/wlan0 .link units) ------
# RK3588 predictable names (wlP2p33s0, enP4p65s0) never matched SRTLA's wlan*/
# eth* routing globs, so wifi/wired uplinks were silently dropped from bonding.
# These .link units rename onboard NICs to stable roles. Per-role Path= rules
# (keyed on the manifest ID_PATH, stable per board model) are required on OPi 5+
# where the dual r8169 NICs would otherwise race a generic Type=ether match.
install_interface_naming() {
  log "installing deterministic interface naming (.link units + loose rp_filter)"
  mkdir -p /etc/systemd/network

  local role var val
  for role in eth0 eth1 wlan0; do
    var="CERALIVE_INTERFACES_${role}"
    val="${!var:-}"
    [[ -n "${val}" && "${val}" != FIXME* ]] || continue
    cat >"/etc/systemd/network/10-ceralive-${role}.link" <<EOF
[Match]
Path=${val}

[Link]
Name=${role}
EOF
  done

  # Fallback ONLY when the board manifest has no onboard-wifi Path: match by
  # Type=wlan. A Path= rule (emitted above) is onboard-scoped and lets USB wifi
  # dongles keep their kernel names (wlan1+/wlx<mac>); a Type=wlan rule would
  # instead try to rename EVERY wireless NIC to wlan0 and collide (EEXIST).
  local wlan0_path="${CERALIVE_INTERFACES_wlan0:-}"
  if [[ -z "${wlan0_path}" || "${wlan0_path}" == FIXME* ]]; then
    cat >/etc/systemd/network/10-ceralive-wlan0.link <<'EOF'
[Match]
Type=wlan

[Link]
Name=wlan0
EOF
  fi

  # rp_filter=2 (loose) validates the return path on ANY interface, not just the
  # arrival one — strict RPF silently drops modem return traffic under multi-WAN
  # source-policy routing.
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/60-ceralive-rp-filter.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
}

# --- 8c. NTP configuration (chrony pools) --------------------------------
configure_ntp() {
  log "configuring NTP (chrony pools)"
  mkdir -p /etc/chrony/conf.d
  # Install the ceralive-ntp.conf drop-in with explicit public NTP pools.
  # This file is staged into the image at build time by the customize layer.
  if [[ -f "${CERALIVE_CUSTOMIZE_SRC:-}/ceralive-ntp.conf" ]]; then
    cp "${CERALIVE_CUSTOMIZE_SRC}/ceralive-ntp.conf" /etc/chrony/conf.d/ceralive-ntp.conf
  else
    # Fallback: inline the config if the file is not available (e.g., in the
    # standalone postinst context where the customize dir is not mounted).
    cat >/etc/chrony/conf.d/ceralive-ntp.conf <<'EOF'
pool pool.ntp.org iburst
pool ntp.ubuntu.com iburst
makestep 1 3
EOF
  fi
}

# --- 9. Services enable/disable (verbatim from postinst section 9) --------
configure_services() {
  log "enabling/disabling services"
  configure_ntp  # install NTP pools before enabling chrony
  local svc
  for svc in systemd-resolved NetworkManager ModemManager ssh chrony avahi-daemon ceralive-console-font; do
    enable_service "${svc}"
  done
  for svc in bluetooth.service cups.service; do
    disable_service "${svc}"
  done
}

# --- 10. First-boot unique-hostname service (verbatim, postinst section 10) -
setup_hostname_service() {
  log "installing first-boot unique-hostname service"
  mkdir -p /etc/ceralive

  cat >/usr/local/sbin/ceralive-set-hostname <<'EOF'
#!/bin/bash
set -euo pipefail
BASE_NAME="ceralive"
INDEX_FILE="/etc/ceralive/host_index"
LOCK_FILE="/etc/ceralive/hostname.lock"
[ -f "$LOCK_FILE" ] && exit 0

index=""
if [ -s "$INDEX_FILE" ]; then
    index="$(sed -E 's/[^0-9]//g' "$INDEX_FILE")"
fi
if [ -z "$index" ]; then
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
  systemctl enable ceralive-hostname.service
}

# --- 12. Persist user-mutable state on /data (verbatim, postinst section 12) -
setup_data_persistence() {
  local data_root="/data" data_partlabel="data"
  local workdir="/opt/ceralive" nm_conn="/etc/NetworkManager/system-connections"

  log "persisting CeraLive state on ${data_root} (config/logs/wifi/srtla)"

  if ! grep -qE "^[^#]*[[:space:]]${data_root}[[:space:]]" /etc/fstab 2>/dev/null; then
    mkdir -p "${data_root}"
    printf 'PARTLABEL=%s\t%s\text4\tdefaults,noatime,nofail,x-systemd.growfs\t0\t2\n' \
      "${data_partlabel}" "${data_root}" >>/etc/fstab
  fi

  mkdir -p /usr/local/sbin
  cat >/usr/local/sbin/ceralive-migrate-data <<EOF
#!/bin/bash
# CeraLive first-boot data migration + /data skeleton. Idempotent; re-runs and
# A/B slot swaps are no-ops once /data is populated.
set -euo pipefail
DATA="${data_root}"
WORKDIR="${workdir}"
NM_CONN="${nm_conn}"
EOF
  cat >>/usr/local/sbin/ceralive-migrate-data <<'EOF'

log() { logger -t ceralive-migrate -- "$*" 2>/dev/null || true; echo "ceralive-migrate: $*"; }

[ -d "$DATA" ] || { log "ERROR: $DATA missing (data partition not mounted?)"; exit 1; }

mkdir -p "$DATA/ceralive" "$DATA/log" "$DATA/nm/system-connections" "$DATA/srtla"
# OTA (task 41): RAUC bundle download dir + the rendered per-device hawkBit
# updater config dir, BOTH on /data (never the rootfs slot). The updater config
# carries the DDI token → 0700.
mkdir -p "$DATA/ceralive/rauc-downloads" "$DATA/ceralive/hawkbit-updater"
chmod 0755 "$DATA/ceralive" "$DATA/log" "$DATA/srtla" "$DATA/ceralive/rauc-downloads"
chmod 0700 "$DATA/nm" "$DATA/nm/system-connections" "$DATA/ceralive/hawkbit-updater"

# Cert-rotation store (task 42): persistent intermediate/leaf certs + the staging
# dir a rotation bundle's install hook drops candidates into. The .rauc-certs-slot
# placeholder is the [slot.certs.0] device referenced by /etc/rauc/system.conf so a
# cert-rotation .raucb can target it without a reflash. On /data → survives A/B.
mkdir -p "$DATA/ceralive/certs/incoming"
chmod 0755 "$DATA/ceralive/certs" "$DATA/ceralive/certs/incoming"
[ -e "$DATA/ceralive/certs/.rauc-certs-slot" ] || : >"$DATA/ceralive/certs/.rauc-certs-slot"

# ONE-TIME legacy config migration: /etc/ceralive/config.json -> /data, then drop
# the legacy copy so /data is the single source of truth.
if [ -f /etc/ceralive/config.json ] && [ ! -e "$DATA/ceralive/config.json" ]; then
    log "migrating legacy /etc/ceralive/config.json -> $DATA/ceralive/config.json"
    cp -a /etc/ceralive/config.json "$DATA/ceralive/config.json"
    rm -f /etc/ceralive/config.json
fi

# Seed the CeraUI working dir + /var/log + NM connections before the binds shadow
# them (first boot only — guarded by mountpoint checks).
if [ -d "$WORKDIR" ] && ! mountpoint -q "$WORKDIR"; then
    for f in "$WORKDIR"/*.json "$WORKDIR/revision"; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        [ -e "$DATA/ceralive/$base" ] || cp -a "$f" "$DATA/ceralive/$base"
    done
fi
if ! mountpoint -q /var/log; then
    cp -a /var/log/. "$DATA/log/" 2>/dev/null || true
fi
if [ -d "$NM_CONN" ] && ! mountpoint -q "$NM_CONN"; then
    cp -a "$NM_CONN"/. "$DATA/nm/system-connections/" 2>/dev/null || true
fi

# Persist machine-id across A/B slots so host identity (and hostname) is stable.
if [ -s /etc/machine-id ] && [ ! -s "$DATA/ceralive/machine-id" ]; then
    cp -a /etc/machine-id "$DATA/ceralive/machine-id"
fi
if [ -s "$DATA/ceralive/machine-id" ] && ! mountpoint -q /etc/machine-id; then
    mount --bind "$DATA/ceralive/machine-id" /etc/machine-id 2>/dev/null || true
fi

# Relocate first-boot hostname index/lock onto /data (contract §6).
for n in host_index hostname.lock; do
    if [ -e "/etc/ceralive/$n" ] && [ ! -L "/etc/ceralive/$n" ]; then
        [ -e "$DATA/ceralive/$n" ] || cp -a "/etc/ceralive/$n" "$DATA/ceralive/$n"
        rm -f "/etc/ceralive/$n"
    fi
    [ -L "/etc/ceralive/$n" ] || ln -s "$DATA/ceralive/$n" "/etc/ceralive/$n" 2>/dev/null || true
done

# RAUC bundle URL lives on /data (never hardcoded). Seed a disabled default.
if [ ! -e "$DATA/ceralive/update.conf" ]; then
    log "seeding $DATA/ceralive/update.conf (OTA disabled until BUNDLE_URL is set)"
    cat >"$DATA/ceralive/update.conf" <<'CONF'
# CeraLive OS update (RAUC) configuration — persistent /data, editable on device.
# Consumed by /usr/local/bin/ceralive-update.
# BUNDLE_URL : full URL / apt.ceralive.tv path of the .raucb. Empty = OTA disabled.
# CHANNEL    : release channel hint (informational; URL is authoritative).
BUNDLE_URL=
CHANNEL=stable
# Boot healthcheck (task 29) — gates `rauc mark-good` on real streaming health.
# IRL_SERVER_HOST            : irl-srt-server host for the SRT reach check (empty = skip).
# IRL_SERVER_SRT_PORT        : SRT/SRTLA port (TCP-reach probed).
# HEALTHCHECK_TIMEOUT        : seconds to reach health before giving up (→ rollback).
# HEALTHCHECK_RETRY_INTERVAL : seconds between health attempts.
IRL_SERVER_HOST=
IRL_SERVER_SRT_PORT=9000
HEALTHCHECK_TIMEOUT=60
HEALTHCHECK_RETRY_INTERVAL=5
CONF
    chmod 0644 "$DATA/ceralive/update.conf"
fi

log "data persistence ready (config/logs/wifi/srtla on $DATA)"
exit 0
EOF
  chmod +x /usr/local/sbin/ceralive-migrate-data

  cat >/etc/systemd/system/ceralive-migrate-data.service <<EOF
[Unit]
Description=CeraLive one-time data migration + /data skeleton
RequiresMountsFor=${data_root}
After=local-fs.target
Before=ceralive-hostname.service ceralive.service
ConditionPathIsMountPoint=${data_root}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ceralive-migrate-data

[Install]
WantedBy=local-fs.target
EOF
  enable_service ceralive-migrate-data.service

  local spec src dst unit
  for spec in "${data_root}/ceralive:${workdir}" \
              "${data_root}/log:/var/log" \
              "${data_root}/nm/system-connections:${nm_conn}"; do
    src="${spec%%:*}"
    dst="${spec#*:}"
    unit="$(systemd-escape -p --suffix=mount "${dst}")"
    cat >"/etc/systemd/system/${unit}" <<EOF
[Unit]
Description=CeraLive persistent state bind: ${dst} backed by ${src}
Requires=ceralive-migrate-data.service
After=ceralive-migrate-data.service
RequiresMountsFor=${data_root}
Before=ceralive.service

[Mount]
What=${src}
Where=${dst}
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
EOF
    enable_service "${unit}"
  done

  mkdir -p /etc/systemd/system/ceralive.service.d
  cat >/etc/systemd/system/ceralive.service.d/10-data-persistence.conf <<EOF
[Unit]
RequiresMountsFor=${workdir} /var/log
After=ceralive-migrate-data.service
EOF

  mkdir -p /usr/local/bin
  cat >/usr/local/bin/ceralive-update <<EOF
#!/bin/bash
# CeraLive OS update entrypoint — invoked by CeraUI system.startUpdate() (target
# wiring). Installs a RAUC bundle whose URL
# is read from persistent /data; the post-reboot mark-good is the task-29 gate.
set -euo pipefail
CONF="${data_root}/ceralive/update.conf"
DATA="${data_root}"
EOF
  cat >>/usr/local/bin/ceralive-update <<'EOF'

die() { echo "ceralive-update: $*" >&2; exit 1; }

command -v rauc >/dev/null 2>&1 || die "rauc is not installed"
mountpoint -q "$DATA" || die "$DATA is not mounted; refusing to update"
[ -f "$CONF" ] || die "no $CONF; OTA is not provisioned on this device"

# shellcheck disable=SC1090
. "$CONF"
[ -n "${BUNDLE_URL:-}" ] || die "BUNDLE_URL is empty in $CONF; OTA disabled"

for svc in cerastream.service srtla.service srtla-send.service; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        die "stream active ($svc); refusing to update"
    fi
done

echo "ceralive-update: installing RAUC bundle from $CONF (BUNDLE_URL=$BUNDLE_URL)"
rauc install "$BUNDLE_URL"

# Force the freshly-activated slot to re-prove streaming health before it is
# confirmed: /data is shared across A/B, so the new slot must NOT inherit this
# slot's mark-good marker (task 29). The boot healthcheck re-creates it on success.
rm -f "$DATA/ceralive/.slot-marked-good"

echo "ceralive-update: installed to inactive slot; reboot to activate (task-29 mark-good confirms or rolls back)."
exit 0
EOF
  chmod +x /usr/local/bin/ceralive-update
}

# ---------------------------------------------------------------------------
# Boot healthcheck (task 29) + cert rotation (task 42): install the COMMITTED
# canonical artifacts (single source of truth) instead of re-embedding stripped
# heredoc twins. Mirrors customize/services.sh::install_healthcheck_service /
# install_cert_rotation. CERALIVE_RUNTIME_SRC must point at the runtime/ source
# dir (postinst: "${SRCDIR}/runtime"; customize: "${SERVICES_DIR}/../runtime").
# ---------------------------------------------------------------------------
setup_boot_healthcheck() {
  log "installing boot healthcheck (ceralive-healthcheck.service — gates rauc mark-good)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-healthcheck.sh" ]] \
    || die "boot healthcheck source not found: ${src}/ceralive-healthcheck.sh (is \$SRCDIR/runtime mounted?)"
  mkdir -p /usr/local/bin
  install -m 0755 "${src}/ceralive-healthcheck.sh" /usr/local/bin/ceralive-healthcheck.sh
  install -m 0644 "${src}/ceralive-healthcheck.service" /etc/systemd/system/ceralive-healthcheck.service
  enable_service ceralive-healthcheck.service
}

setup_cert_rotation() {
  log "installing cert rotation (intermediate/leaf through-channel; root immutable)"
  local src="${CERALIVE_RUNTIME_SRC:-}/cert-rotation"
  [[ -n "${CERALIVE_RUNTIME_SRC:-}" && -f "${src}/cert-rotation.sh" ]] \
    || die "cert-rotation source not found: ${src}/cert-rotation.sh (is \$SRCDIR/runtime mounted?)"
  mkdir -p /usr/local/bin /etc/ceralive
  install -m 0755 "${src}/cert-rotation.sh" /usr/local/bin/cert-rotation.sh
  install -m 0644 "${src}/cert-rotation.conf" /etc/ceralive/cert-rotation.conf
  install -m 0644 "${src}/cert-rotation.service" /etc/systemd/system/cert-rotation.service
  install -m 0644 "${src}/cert-rotation-expiry.service" /etc/systemd/system/cert-rotation-expiry.service
  install -m 0644 "${src}/cert-rotation-expiry.timer" /etc/systemd/system/cert-rotation-expiry.timer
  enable_service cert-rotation.service
  enable_service cert-rotation-expiry.timer
}

# --- 17. First-boot WiFi provisioning portal (tasks 11 + 14) ------------------
# Installs the committed canonical artifacts under v2/mkosi/runtime/ (single source of
# truth — no inline twin, Task 6 pattern), mirroring setup_boot_healthcheck /
# setup_cert_rotation. The provision script brings up an NM-native AP-mode hotspot ONLY
# when there are no stored (non-AP) WiFi profiles on /data AND no link-up connectivity
# appears within a boot grace window; a /data force flag (factory-reset hook) re-triggers
# it even when profiles exist.
#
# Task 14 adds the captive portal: ceralive-portal.sh (the inetd-style bash HTTP handler)
# plus its socket-activation units ceralive-portal.{socket,@.service}. The socket + the
# per-connection template are installed but NOT enabled — ceralive-provision starts the
# socket imperatively when the AP comes up and stops it on teardown, so port 80 is taken
# from CeraUI only for the duration of provisioning. CERALIVE_RUNTIME_SRC must point at
# the runtime/ source dir.
setup_provisioning() {
  log "installing first-boot WiFi provisioning portal (ceralive-provision.service + captive portal)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-provision.sh" ]] \
    || die "provisioning source not found: ${src}/ceralive-provision.sh (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-portal.sh" ]] \
    || die "captive-portal source not found: ${src}/ceralive-portal.sh (is \$SRCDIR/runtime mounted?)"
  mkdir -p /usr/local/sbin
  install -m 0755 "${src}/ceralive-provision.sh" /usr/local/sbin/ceralive-provision
  install -m 0755 "${src}/ceralive-portal.sh"    /usr/local/sbin/ceralive-portal
  install -m 0644 "${src}/ceralive-provision.service"  /etc/systemd/system/ceralive-provision.service
  install -m 0644 "${src}/ceralive-portal.socket"      /etc/systemd/system/ceralive-portal.socket
  install -m 0644 "${src}/ceralive-portal@.service"    /etc/systemd/system/ceralive-portal@.service
  # Only the trigger service is enabled at boot; the portal socket + template are driven
  # imperatively by ceralive-provision (start on AP up, stop on teardown).
  enable_service ceralive-provision.service
}

# ---------------------------------------------------------------------------
# First-boot SSH hardening (task 10, SC4): install the COMMITTED standalone
# artifacts ceralive-ssh-firstboot.{sh,service} (single source of truth under
# v2/mkosi/runtime/) instead of inlining them in the runtime postinst — keeps
# postinst.chroot under the 950-line drift ceiling. Mirrors setup_boot_healthcheck.
# Scope is LOCKED to host-key regen + PermitRootLogin prohibit-password + a once-
# only `chage -d 0 ceralive`; see the script header. CERALIVE_RUNTIME_SRC must
# point at the runtime/ source dir.
# ---------------------------------------------------------------------------
setup_ssh_firstboot() {
  log "installing first-boot SSH hardening (ceralive-ssh-firstboot.service — host keys + root pw-login + forced change)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-ssh-firstboot.sh" ]] \
    || die "ssh-firstboot source not found: ${src}/ceralive-ssh-firstboot.sh (is \$SRCDIR/runtime mounted?)"
  mkdir -p /usr/local/sbin
  install -m 0755 "${src}/ceralive-ssh-firstboot.sh" /usr/local/sbin/ceralive-ssh-firstboot
  install -m 0644 "${src}/ceralive-ssh-firstboot.service" /etc/systemd/system/ceralive-ssh-firstboot.service
  enable_service ceralive-ssh-firstboot.service
}

# ---------------------------------------------------------------------------
# CeraUI TLS front (task 15, SC3): nginx terminates HTTPS on 443 and proxies to
# the CeraUI backend on 127.0.0.1:80 (WebSocket-upgrade aware, EC6). Port 80 is
# LEFT to the backend — nginx must NOT bind it and there is NO 80->443 redirect.
# Installs the COMMITTED canonical artifacts under v2/mkosi/runtime/ (single source
# of truth, no inline twin — Task 6 pattern), mirroring setup_ssh_firstboot. The
# cert is per-device self-signed, generated on first boot into /data by
# ceralive-tls-firstboot.service; nginx is ordered AFTER it via a drop-in.
# CERALIVE_RUNTIME_SRC must point at the runtime/ source dir.
# ---------------------------------------------------------------------------
setup_tls_proxy() {
  log "installing CeraUI TLS front (nginx 443 -> 127.0.0.1:80 + first-boot self-signed cert)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-tls-firstboot.sh" ]] \
    || die "tls-proxy source not found: ${src}/ceralive-tls-firstboot.sh (is \$SRCDIR/runtime mounted?)"

  # (1) First-boot cert generator + its oneshot unit.
  mkdir -p /usr/local/sbin
  install -m 0755 "${src}/ceralive-tls-firstboot.sh" /usr/local/sbin/ceralive-tls-firstboot
  install -m 0644 "${src}/ceralive-tls-firstboot.service" /etc/systemd/system/ceralive-tls-firstboot.service

  # (2) nginx 443 TLS site. Symlink (not copy) sites-available -> sites-enabled so
  # the layout matches Debian's nginx convention exactly.
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  install -m 0644 "${src}/ceralive-tls.nginx.conf" /etc/nginx/sites-available/ceralive-tls.conf
  ln -sf ../sites-available/ceralive-tls.conf /etc/nginx/sites-enabled/ceralive-tls.conf

  # (3) SC3: nginx binds 443 ONLY. The stock nginx-light ships a default site that
  # listens on :80 — remove it so nginx never competes with the backend for port 80.
  rm -f /etc/nginx/sites-enabled/default

  # (4) Order nginx AFTER first-boot cert generation (hard dependency drop-in).
  mkdir -p /etc/systemd/system/nginx.service.d
  install -m 0644 "${src}/ceralive-tls-nginx.dropin.conf" /etc/systemd/system/nginx.service.d/10-ceralive-tls.conf

  enable_service ceralive-tls-firstboot.service
  enable_service nginx.service
}
