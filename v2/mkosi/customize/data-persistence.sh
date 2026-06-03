#!/usr/bin/env bash
#
# customize/data-persistence.sh — relocate ALL user-mutable state onto the shared
# `/data` partition so an A/B (RAUC) OS-slot swap never wipes user config, and
# wire the device-side OS-update entrypoint.
#
# WHY (Stage 4, task 30): the two rootfs slots (rootfs_a / rootfs_b) are
# overwritten atomically by a RAUC update — anything written into a slot is lost
# on the next swap. The frozen partition contract (docs/partition-contract.md §6)
# makes the trailing `data` partition (PARTLABEL=data, mounted at /data) the
# SINGLE source of truth for everything the user/runtime mutates. This module is
# the IMPLEMENTATION of that contract: it binds the live state directories onto
# /data and provides a one-time migration off the legacy /etc/ceralive location.
#
# WHAT MOVES TO /data (contract §6):
#   /data/ceralive/            CeraUI working-dir JSON (config.json, setup.json,
#                              auth_tokens.json, dns_cache.json,
#                              gsm_operator_cache.json, relays_cache.json,
#                              revision) + host_index/host.lock + machine-id +
#                              update.conf  ← bind to /opt/ceralive (WorkingDirectory)
#   /data/log/                 system + app logs              ← bind to /var/log
#   /data/nm/system-connections/  WiFi credentials / NM profiles
#                                              ← bind to /etc/NetworkManager/system-connections
#   /data/srtla/               persisted SRTLA routing/bonding state (runtime-derived)
#
# WHAT STAYS IN THE ROOTFS (read-only seeds — code, not state):
#   /etc/ceralive/conf.d/*.conf, /etc/ceralive/release, /etc/iproute2/rt_tables,
#   the dhclient/NM dispatcher hooks. These are reprovisioned by every slot and
#   are intentionally NOT bound to /data (see structure.sh + networking-srtla.sh).
#
# MECHANISM (all declarative, survives reboot):
#   * a /data fstab entry by PARTLABEL=data (idempotent),
#   * three systemd bind `.mount` units (dir binds), each ordered AFTER the
#     migration so first-boot seeding happens before the bind shadows the rootfs,
#   * `ceralive-migrate-data.service` — a oneshot that builds the /data skeleton,
#     performs the one-time legacy config migration, persists machine-id, and
#     seeds /var/log + the CeraUI working dir before they are shadowed,
#   * a ceralive.service drop-in so CeraUI starts only after /data is in place,
#   * `/usr/local/bin/ceralive-update` — the device-side RAUC update entrypoint
#     that `system.startUpdate()` will call (bundle URL read from /data, never
#     hardcoded; see EVIDENCE / cross-repo note in .omo/evidence/task-30-*).
#
# STRICT semantics (common.sh DESIGN RULE): the BUILD-TIME logic in this module
# is strict — no `|| true`. The emitted RUNTIME payload scripts (migrate +
# update) run on the LIVE device against transient state and keep their own
# narrow, justified guards exactly like networking-srtla.sh's dhclient/NM hooks.
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no build-time `|| true`.
# Depends on /opt/ceralive + /etc/ceralive existing (structure.sh) and the
# ceralive.service unit shipped by the CeraUI .deb (drop-in is additive).
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

# Canonical /data layout (docs/partition-contract.md §6). Configuration, not secrets.
readonly DATA_ROOT="${CERALIVE_DATA_ROOT:-/data}"
readonly DATA_PARTLABEL="${CERALIVE_DATA_PARTLABEL:-data}"

# Live state dir  ->  /data backing dir. The CeraUI WorkingDirectory is
# /opt/ceralive (contract §6 + decisions.md task-8); /var/log + the NM
# system-connections dir follow the same bind pattern.
readonly CERAUI_WORKDIR="/opt/ceralive"
readonly NM_CONNECTIONS="/etc/NetworkManager/system-connections"

# ---------------------------------------------------------------------------
# 1. Mount the /data partition (PARTLABEL=data) — idempotent fstab entry.
#    The GPT label is fixed by the frozen contract; mounting by PARTLABEL is
#    mandatory (FS-UUIDs are unstable across slot updates, contract §3).
# ---------------------------------------------------------------------------
install_data_fstab() {
  if grep -qE "^[^#]*[[:space:]]${DATA_ROOT}[[:space:]]" /etc/fstab 2>/dev/null; then
    log_info "/etc/fstab already mounts ${DATA_ROOT} — leaving as-is"
    return 0
  fi
  log_info "adding ${DATA_ROOT} fstab entry (PARTLABEL=${DATA_PARTLABEL})"
  mkdir -p "${DATA_ROOT}"
  printf 'PARTLABEL=%s\t%s\text4\tdefaults,noatime,nofail,x-systemd.growfs\t0\t2\n' \
    "${DATA_PARTLABEL}" "${DATA_ROOT}" >>/etc/fstab
}

# ---------------------------------------------------------------------------
# 2. systemd bind `.mount` units. Each binds a /data subdir over the live path,
#    is ordered AFTER the migration (so seeding precedes the bind), and is pulled
#    in by local-fs.target. Unit filenames are derived with systemd-escape so the
#    dash in `system-connections` is escaped correctly (\x2d).
# ---------------------------------------------------------------------------
write_bind_mount_unit() {
  local src="$1" dst="$2" unit
  unit="$(systemd-escape -p --suffix=mount "${dst}")"
  log_info "writing bind mount unit ${unit} (${dst} <- ${src})"
  cat >"/etc/systemd/system/${unit}" <<EOF
[Unit]
Description=CeraLive persistent state bind: ${dst} backed by ${src}
Documentation=file:///usr/share/doc/ceralive/partition-contract.md
# Seed first, then shadow: the bind must come up only after migration has
# populated ${src} from the rootfs seed.
Requires=ceralive-migrate-data.service
After=ceralive-migrate-data.service
RequiresMountsFor=${DATA_ROOT}
Before=ceralive.service

[Mount]
What=${src}
Where=${dst}
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
EOF
  systemctl enable "${unit}"
}

# ---------------------------------------------------------------------------
# 3. One-time migration + /data skeleton (RUNTIME payload — runs on the device).
#    Narrow `|| true` guards here are for transient live-system state only, NOT
#    build-time; identical rationale to networking-srtla.sh's dhclient/NM hooks.
# ---------------------------------------------------------------------------
write_migrate_script() {
  log_info "installing /usr/local/sbin/ceralive-migrate-data (one-time state migration)"
  mkdir -p /usr/local/sbin
  cat >/usr/local/sbin/ceralive-migrate-data <<EOF
#!/bin/bash
# CeraLive first-boot data migration + /data skeleton. Idempotent: every step is
# guarded so re-runs (and A/B slot swaps) are no-ops once /data is populated.
set -euo pipefail

DATA="${DATA_ROOT}"
WORKDIR="${CERAUI_WORKDIR}"
NM_CONN="${NM_CONNECTIONS}"
EOF
  cat >>/usr/local/sbin/ceralive-migrate-data <<'EOF'

log() { logger -t ceralive-migrate -- "$*" 2>/dev/null || true; echo "ceralive-migrate: $*"; }

[ -d "$DATA" ] || { log "ERROR: $DATA does not exist (data partition not mounted?)"; exit 1; }

# --- /data skeleton (contract §6) -----------------------------------------
mkdir -p "$DATA/ceralive" "$DATA/log" "$DATA/nm/system-connections" "$DATA/srtla"
chmod 0755 "$DATA/ceralive" "$DATA/log" "$DATA/srtla"
chmod 0700 "$DATA/nm" "$DATA/nm/system-connections"

# --- ONE-TIME legacy config migration -------------------------------------
# Legacy CeraUI config seed lived at /etc/ceralive/config.json (the .deb seed).
# Copy it onto /data exactly once, then remove the legacy copy so the data
# partition is the single source of truth.
if [ -f /etc/ceralive/config.json ] && [ ! -e "$DATA/ceralive/config.json" ]; then
    log "migrating legacy /etc/ceralive/config.json -> $DATA/ceralive/config.json"
    cp -a /etc/ceralive/config.json "$DATA/ceralive/config.json"
    rm -f /etc/ceralive/config.json
fi

# --- seed the CeraUI working dir before the bind shadows it ----------------
# On first boot /opt/ceralive still shows the rootfs seed (no bind yet). Copy any
# seed JSON / revision marker across so the device keeps shipped defaults.
if [ -d "$WORKDIR" ] && ! mountpoint -q "$WORKDIR"; then
    for f in "$WORKDIR"/*.json "$WORKDIR/revision"; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        [ -e "$DATA/ceralive/$base" ] || cp -a "$f" "$DATA/ceralive/$base"
    done
fi

# --- seed /var/log structure before the bind shadows it --------------------
if ! mountpoint -q /var/log; then
    cp -a /var/log/. "$DATA/log/" 2>/dev/null || true
fi

# --- seed NM connections before the bind shadows them ----------------------
if [ -d "$NM_CONN" ] && ! mountpoint -q "$NM_CONN"; then
    cp -a "$NM_CONN"/. "$DATA/nm/system-connections/" 2>/dev/null || true
fi

# --- persist machine-id across A/B slots -----------------------------------
# Each rootfs slot is built with its own /etc/machine-id; binding the /data copy
# keeps host identity (and the derived hostname) stable across slot swaps.
if [ -s /etc/machine-id ] && [ ! -s "$DATA/ceralive/machine-id" ]; then
    cp -a /etc/machine-id "$DATA/ceralive/machine-id"
fi
if [ -s "$DATA/ceralive/machine-id" ] && ! mountpoint -q /etc/machine-id; then
    mount --bind "$DATA/ceralive/machine-id" /etc/machine-id 2>/dev/null || true
fi

# --- relocate first-boot hostname index/lock onto /data (contract §6) ------
# ceralive-set-hostname reads /etc/ceralive/{host_index,hostname.lock}; symlink
# them onto /data so the chosen hostname survives an OS update.
for n in host_index hostname.lock; do
    if [ -e "/etc/ceralive/$n" ] && [ ! -L "/etc/ceralive/$n" ]; then
        [ -e "$DATA/ceralive/$n" ] || cp -a "/etc/ceralive/$n" "$DATA/ceralive/$n"
        rm -f "/etc/ceralive/$n"
    fi
    [ -L "/etc/ceralive/$n" ] || ln -s "$DATA/ceralive/$n" "/etc/ceralive/$n" 2>/dev/null || true
done

# --- OTA update config seed (RAUC bundle URL lives on /data, never hardcoded) -
if [ ! -e "$DATA/ceralive/update.conf" ]; then
    log "seeding $DATA/ceralive/update.conf (OTA disabled until BUNDLE_URL is set)"
    cat >"$DATA/ceralive/update.conf" <<'CONF'
# CeraLive OS update (RAUC) configuration — lives on the persistent /data
# partition, editable on the device. Consumed by /usr/local/bin/ceralive-update.
#
# BUNDLE_URL : full URL (or apt.ceralive.tv bundle path) of the .raucb to install.
#              Leave EMPTY to keep OTA disabled until a device is provisioned.
# CHANNEL    : release channel hint (informational; the URL is authoritative).
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
}

write_migrate_service() {
  log_info "installing ceralive-migrate-data.service (oneshot, before CeraUI + bind mounts)"
  cat >/etc/systemd/system/ceralive-migrate-data.service <<EOF
[Unit]
Description=CeraLive one-time data migration + /data skeleton
Documentation=file:///usr/share/doc/ceralive/partition-contract.md
# RequiresMountsFor injects the correct Requires=+After= on whichever mount unit
# provides ${DATA_ROOT} (e.g. data.mount) — no hand-built unit name needed.
RequiresMountsFor=${DATA_ROOT}
After=local-fs.target
# Must finish before anything that reads the migrated state.
Before=ceralive-hostname.service ceralive.service
ConditionPathIsMountPoint=${DATA_ROOT}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ceralive-migrate-data

[Install]
WantedBy=local-fs.target
EOF
  systemctl enable ceralive-migrate-data.service
}

# ---------------------------------------------------------------------------
# 4. ceralive.service drop-in — additive ordering so CeraUI starts only once its
#    config/log directories are /data-backed. Does NOT modify the CeraUI-shipped
#    unit (cross-repo); a drop-in is the supported override mechanism.
# ---------------------------------------------------------------------------
write_service_dropin() {
  log_info "installing ceralive.service drop-in (wait for /data binds)"
  mkdir -p /etc/systemd/system/ceralive.service.d
  cat >/etc/systemd/system/ceralive.service.d/10-data-persistence.conf <<EOF
# Ensure the persistent-state binds are in place before CeraUI reads config.json.
[Unit]
RequiresMountsFor=${CERAUI_WORKDIR} /var/log
After=ceralive-migrate-data.service
EOF
}

# ---------------------------------------------------------------------------
# 5. /usr/local/bin/ceralive-update — the device-side RAUC update entrypoint.
#    This is what CeraUI's `system.startUpdate()` RPC will call once the apt-get
#    path is reconciled to RAUC (deferred cross-repo CeraUI change; documented in
#    .omo/evidence/task-30-persist.md). The bundle URL comes from
#    /data/ceralive/update.conf — it is NEVER hardcoded here.
# ---------------------------------------------------------------------------
write_update_script() {
  log_info "installing /usr/local/bin/ceralive-update (RAUC update entrypoint)"
  mkdir -p /usr/local/bin
  cat >/usr/local/bin/ceralive-update <<EOF
#!/bin/bash
# CeraLive OS update entrypoint — invoked by CeraUI system.startUpdate() (target
# wiring; see cross-repo note). Installs a RAUC bundle whose URL is read from the
# persistent /data config; the post-reboot boot-confirmation (mark-good) is the
# task-29 healthcheck gate executed by the bootcount adapter on the new slot.
set -euo pipefail

CONF="${DATA_ROOT}/ceralive/update.conf"
DATA="${DATA_ROOT}"
EOF
  cat >>/usr/local/bin/ceralive-update <<'EOF'

die() { echo "ceralive-update: $*" >&2; exit 1; }

# --- pre-flight healthcheck gate (task 29) ---------------------------------
command -v rauc >/dev/null 2>&1 || die "rauc is not installed"
mountpoint -q "$DATA" || die "$DATA is not mounted; refusing to update"
[ -f "$CONF" ] || die "no $CONF; OTA is not provisioned on this device"

# shellcheck disable=SC1090
. "$CONF"
[ -n "${BUNDLE_URL:-}" ] || die "BUNDLE_URL is empty in $CONF; OTA disabled"

# Never update mid-stream (mirrors CeraUI getIsStreaming() guard). The encoder
# runs as ceracoder.service; bail if it (or srtla) is active.
for svc in ceracoder.service srtla.service; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        die "stream active ($svc); refusing to update"
    fi
done

echo "ceralive-update: installing RAUC bundle from $CONF"
echo "ceralive-update: BUNDLE_URL=$BUNDLE_URL CHANNEL=${CHANNEL:-?}"
rauc install "$BUNDLE_URL"

# Force the freshly-activated slot to re-prove streaming health before it is
# confirmed: /data is shared across A/B, so the new slot must NOT inherit this
# slot's mark-good marker (task 29). The boot healthcheck re-creates it on success.
rm -f "$DATA/ceralive/.slot-marked-good"

echo "ceralive-update: bundle installed to the inactive slot."
echo "ceralive-update: reboot to boot it; the task-29 healthcheck confirms (mark-good) or rolls back."
exit 0
EOF
  chmod +x /usr/local/bin/ceralive-update
}

setup_data_persistence() {
  install_data_fstab

  write_migrate_script
  write_migrate_service

  write_bind_mount_unit "${DATA_ROOT}/ceralive"            "${CERAUI_WORKDIR}"
  write_bind_mount_unit "${DATA_ROOT}/log"                 "/var/log"
  write_bind_mount_unit "${DATA_ROOT}/nm/system-connections" "${NM_CONNECTIONS}"

  write_service_dropin
  write_update_script

  log_success "data persistence configured (state on ${DATA_ROOT}; migration + RAUC update wired)"
}

setup_data_persistence "$@"
