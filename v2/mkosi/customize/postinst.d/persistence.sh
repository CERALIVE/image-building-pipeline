#!/usr/bin/env bash
#
# postinst.d/persistence.sh — what survives a slot swap, and what must not change
# outside one.
#
# Sourced by customize/postinst-lib.sh (never executed). One concern seen from
# both sides of the A/B boundary:
#
#   * setup_data_persistence  the /data skeleton, the first-boot migration and
#                             the bind mounts that keep config, logs, WiFi
#                             profiles and machine-id ACROSS a RAUC slot swap —
#                             plus /usr/local/bin/ceralive-update, the entrypoint
#                             that performs the swap.
#   * freeze_boot_packages    the apt-mark holds + name+version pin that stop the
#                             boot stack changing WITHOUT one, because
#                             docs/partition-contract.md rule 3 puts
#                             kernel/DTB/initrd inside the slot.
#
# They are the same contract read forwards and backwards — state is persistent
# because the rootfs is disposable, and the rootfs is only safely disposable
# because apt cannot rewrite the boot stack underneath a committed slot.
#
# CALL ORDER IS NOT DEFINED HERE. freeze_boot_packages must run LAST in the
# runtime executor's main(), after every apt transaction in that layer; that
# ordering lives in mkosi.images/runtime/mkosi.postinst.chroot and moving the
# definition into this module does not touch it.
#
# resolve_partlabel: deliberately NOT re-implemented here. There are exactly
# three copies of that resolver in the repo (lib/common.sh, the entry
# postinst-lib.sh, and platform/boot/install-boot.sh) and a fourth would be one
# more place for the bench-label overlay to drift. This module is always sourced
# through the entry, which provides it.
#
# CHROOT-SAFE STANDALONE: like every module under postinst.d/, this file carries
# its own declare -F-guarded log()/die() fallbacks. The modules are sourced
# inside mkosi SUBIMAGE CHROOTS where the repo's lib/ is NOT mounted, so a module
# must never assume that anything else has already been sourced.
#
# shellcheck shell=bash

if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[runtime-lib] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() { log "FATAL: $*"; exit 1; }
fi


# --- 12. Persist user-mutable state on /data (verbatim, postinst section 12) -
setup_data_persistence() {
  local data_root="/data" data_partlabel
  data_partlabel="$(resolve_partlabel data)"
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
# them (first boot only — guarded by mountpoint checks). "public" is the frontend
# static-serving symlink ($WORKDIR/public -> /var/www/ceralive) the CeraUI .deb
# ships; the $DATA/ceralive:$WORKDIR bind below shadows it, so it must be seeded
# onto /data or the frontend 404s. cp -a copies the symlink itself (never the bulk
# /var/www asset tree, which stays on the rootfs to track image/OTA updates); the
# -L guards catch a target-absent symlink and never clobber an existing /data entry.
if [ -d "$WORKDIR" ] && ! mountpoint -q "$WORKDIR"; then
    for f in "$WORKDIR"/*.json "$WORKDIR/revision" "$WORKDIR/public"; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        base="$(basename "$f")"
        [ -e "$DATA/ceralive/$base" ] || [ -L "$DATA/ceralive/$base" ] || cp -a "$f" "$DATA/ceralive/$base"
    done
fi
if ! mountpoint -q /var/log; then
    cp -a /var/log/. "$DATA/log/" 2>/dev/null || true
fi
if [ -d "$NM_CONN" ] && ! mountpoint -q "$NM_CONN"; then
    cp -a "$NM_CONN"/. "$DATA/nm/system-connections/" 2>/dev/null || true
fi

# Persist machine-id across A/B slots so host identity and setup identifiers are stable.
if [ -s /etc/machine-id ] && [ ! -s "$DATA/ceralive/machine-id" ]; then
    cp -a /etc/machine-id "$DATA/ceralive/machine-id"
fi
if [ -s "$DATA/ceralive/machine-id" ] && ! mountpoint -q /etc/machine-id; then
    mount --bind "$DATA/ceralive/machine-id" /etc/machine-id 2>/dev/null || true
fi

# Relocate first-boot hostname state onto /data (contract §6). The local
# allocation lock stays under /run because it is process coordination only.
for n in host_index hostname_consumers_pending; do
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
# Seeds the /data skeleton (log, ceralive, nm) that the bind mounts below shadow,
# so it MUST run in the local-fs setup phase: after ${data_root} is mounted (via
# RequiresMountsFor) and BEFORE local-fs.target. A normal service inherits
# After=basic.target (basic is After sysinit After local-fs); combined with the
# bind mounts being Before=local-fs.target and After=this unit, that forms a
# local-fs.target ordering cycle. DefaultDependencies=no keeps it out of that
# late chain — RequiresMountsFor still orders it after the data mount.
DefaultDependencies=no
Conflicts=shutdown.target
RequiresMountsFor=${data_root}
Before=local-fs.target shutdown.target ceralive-hostname.service ceralive.service
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
# KERNEL FREEZE GUARDRAILS — the boot stack changes ONLY via a RAUC full-image
# update, never via on-device apt.
#
# `docs/partition-contract.md` §1 rule 3 ("Kernel rides with the rootfs") makes
# kernel/DTB/initrd part of the rootfs SLOT, so the only sanctioned way to change
# them is to write a whole new slot. An `apt-get upgrade` on the running device
# would instead swap the kernel underneath a slot whose `/boot` the A/B selector
# has already committed to, producing a slot that no longer matches what was
# verified at install time. This function bakes the guardrails that stop it.
#
# TWO MECHANISMS, deliberately layered:
#
#   1. dpkg HOLDS (`apt-mark hold`) — the PRIMARY mechanism. A hold lives in
#      /var/lib/dpkg/status as `Status: hold ok installed`; apt refuses to
#      upgrade or remove a held package in any ordinary transaction, and the
#      refusal is a hard stop rather than a preference ranking.
#   2. An apt PREFERENCES entry (/etc/apt/preferences.d/ceralive-kernel-freeze)
#      pinning each package BY EXACT NAME to the version that is installed, at
#      priority 1001 — the supplementary belt to the hold's braces. It is
#      name+version pinning, NOT origin pinning, and that is forced by how these
#      packages arrive: the boot BSP is installed from a LOCAL, build-time-only
#      package directory that has no apt origin identity on the device at all
#      (mkosi's ephemeral `file:/repository`, gone by the time the image ships).
#      There is no `Pin: origin …` or `Pin: release …` expression that can
#      designate "the staged local set", so the only expressible pin is the one
#      written here: the literal package name plus the literal installed version.
#
# THE PIN'S LIMITATION IS REAL AND IS NOT A BUG. Apt preferences rank CANDIDATE
# versions; they do not forbid an operator from naming another version
# explicitly. `apt-get install <pkg>=<other>`, `--allow-downgrades`, a
# `-o Dir::Etc::Preferences=` override, or a plain `dpkg -i` all bypass it. That
# is precisely why the hold is primary: `apt-mark hold` also blocks the explicit
# `apt-get install <pkg>` form (apt reports the package as held back and makes no
# change) and can only be undone by a deliberate `apt-mark unhold` or an explicit
# `--allow-change-held-packages`. Neither mechanism is claimed to stop a root
# operator who has decided to override it; both stop the ACCIDENT.
#
# RAUC DOES NOT CONSULT EITHER MECHANISM, and must not be expected to. RAUC
# writes the whole INACTIVE slot (mkfs + image copy) — it never runs dpkg or apt,
# so the running slot's holds are simply not in its path. The new slot arrives
# with its OWN /var/lib/dpkg/status, carrying the holds that ITS build baked, and
# those govern that slot's apt from its first boot. Each image therefore freezes
# itself; the freeze is not fleet state that an update has to preserve.
#
# SCOPE IS THE BOOT STACK ONLY. The package names come from the resolved manifest
# (KERNEL_PACKAGES / DTB_PACKAGES / UBOOT_PACKAGES / FIRMWARE_PACKAGES), so the
# per-board U-Boot package is picked up automatically and no name is hardcoded
# here. First-party CeraLive packages — cerastream, CeraUI (`ceralive-device`),
# srtla-send-rs, the forked libsrt and the ModemManager closure — MUST stay
# apt-updatable from apt.ceralive.tv, so they are refused by name below: a
# manifest that ever routed one of them into a boot-BSP field fails the build
# instead of silently shipping an unupdatable app layer.
# ---------------------------------------------------------------------------

# Package names that may NEVER be frozen. These are the first-party CeraLive
# packages the device updates over apt from apt.ceralive.tv (see the app layer's
# SYSEXT_APP_PKGS / APPFS_APP_PKGS / RUNTIME_APP_PKGS classification). Holding any
# of them would break the ordinary software-update path CeraUI drives.
CERALIVE_NEVER_FREEZE_PKGS="${CERALIVE_NEVER_FREEZE_PKGS:-cerastream ceralive-device srtla-send-rs srtla gstreamer1.0-libuvch264src libsrt1.5-ceralive rauc-hawkbit-updater modemmanager libmm-glib0 libmbim-glib4 libmbim-proxy libmbim-utils libqmi-glib5 libqmi-proxy libqmi-utils libqrtr-glib0}"

freeze_boot_packages() {
  local pref_dir="${CERALIVE_APT_PREFERENCES_DIR:-/etc/apt/preferences.d}"
  local pref_file="${pref_dir}/ceralive-kernel-freeze"

  local -a declared=()
  read -r -a declared <<<"${KERNEL_PACKAGES:-} ${DTB_PACKAGES:-} ${UBOOT_PACKAGES:-} ${FIRMWARE_PACKAGES:-}"

  # Dedupe while preserving manifest order (kernel, dtb, u-boot, firmware).
  local pkg seen=" " candidates=()
  for pkg in ${declared[@]+"${declared[@]}"}; do
    [[ -n "${pkg}" ]] || continue
    [[ "${seen}" == *" ${pkg} "* ]] && continue
    seen+="${pkg} "
    candidates+=("${pkg}")
  done

  if (( ${#candidates[@]} == 0 )); then
    log "kernel freeze: manifest declares no kernel/DTB/U-Boot/firmware packages — nothing to freeze"
    return 0
  fi

  # Fail-closed guard: an app-layer package must never reach the freeze set.
  for pkg in "${candidates[@]}"; do
    if [[ " ${CERALIVE_NEVER_FREEZE_PKGS} " == *" ${pkg} "* ]]; then
      die "kernel freeze: refusing to hold first-party package '${pkg}' — CeraLive app packages must stay apt-updatable (it reached the freeze set via KERNEL/DTB/UBOOT/FIRMWARE_PACKAGES; fix the manifest)"
    fi
  done

  # Only INSTALLED packages can be held or pinned to an installed version.
  local -a frozen=() versions=() absent=()
  local state version
  for pkg in "${candidates[@]}"; do
    state="$(dpkg-query -W -f='${db:Status-Status} ${Version}' "${pkg}" 2>/dev/null || true)"
    version="${state#* }"
    if [[ "${state%% *}" != "installed" || -z "${version}" ]]; then
      absent+=("${pkg}")
      continue
    fi
    frozen+=("${pkg}")
    versions+=("${version}")
  done

  if (( ${#absent[@]} > 0 )); then
    # On a full device build the platform layer installed every declared boot-BSP
    # package, so an absent one means the freeze would silently be partial.
    if [[ "${INSTALL_BOOT_BSP:-1}" == "1" ]]; then
      die "kernel freeze: declared boot package(s) not installed: ${absent[*]} — INSTALL_BOOT_BSP=1 promised them, so freezing only part of the boot stack would ship an image whose kernel apt can still replace"
    fi
    log "kernel freeze: INSTALL_BOOT_BSP=0 parity build — skipping uninstalled boot package(s): ${absent[*]}"
  fi

  if (( ${#frozen[@]} == 0 )); then
    log "kernel freeze: no declared boot package is installed (parity build) — no holds, no pin file"
    rm -f "${pref_file}"
    return 0
  fi

  log "kernel freeze: holding ${#frozen[@]} boot package(s) — ${frozen[*]}"
  apt-mark hold "${frozen[@]}"

  # VERIFY the holds actually landed. A hold that silently did not apply would put
  # an apt-upgradable kernel straight back into the fleet on an image that
  # otherwise builds, boots and passes every other gate (same fail-closed
  # discipline as mask_service).
  local held; held=" $(apt-mark showhold | tr '\n' ' ')"
  for pkg in "${frozen[@]}"; do
    [[ "${held}" == *" ${pkg} "* ]] \
      || die "kernel freeze: 'apt-mark hold ${pkg}' did not land — dpkg does not report it as held"
  done
  # …and that the guard held in the other direction too: no first-party package
  # may be on the hold list when we are done, whatever put it there.
  # shellcheck disable=SC2086  # the never-freeze list is a space-separated set, split on purpose
  for pkg in ${CERALIVE_NEVER_FREEZE_PKGS}; do
    if [[ "${held}" == *" ${pkg} "* ]]; then
      die "kernel freeze: first-party package '${pkg}' is on dpkg's hold list — CeraLive app packages must stay apt-updatable"
    fi
  done

  # Supplementary name+version pin (see the header for why not an origin pin, and
  # for the documented bypass limitation).
  mkdir -p "${pref_dir}"
  {
    printf '# CeraLive kernel freeze — generated by postinst-lib.sh::freeze_boot_packages.\n'
    printf '#\n'
    printf '# The boot stack changes ONLY via a RAUC full-image update (see\n'
    printf '# docs/partition-contract.md rule 3 and v2/docs/kernel-freeze-contract.md).\n'
    printf '# The PRIMARY mechanism is the dpkg hold on each package below\n'
    printf '# (`apt-mark showhold`); this pin is supplementary.\n'
    printf '#\n'
    printf '# Name+version, not origin: these packages were installed from a local\n'
    printf '# build-time package directory that has no apt origin identity on the\n'
    printf '# device, so no `Pin: origin`/`Pin: release` expression can designate them.\n'
    printf '#\n'
    printf '# LIMITATION: apt preferences rank candidate versions; they do not forbid an\n'
    printf '# explicitly named one. `apt-get install <pkg>=<version>`, --allow-downgrades,\n'
    printf '# -o Dir::Etc::Preferences=, and `dpkg -i` all bypass this file. The dpkg hold\n'
    printf '# is what blocks those ordinary apt forms; neither stops a root operator who\n'
    printf '# has decided to override the freeze on purpose.\n'
    local i
    for (( i = 0; i < ${#frozen[@]}; i++ )); do
      printf '\nPackage: %s\nPin: version %s\nPin-Priority: 1001\n' "${frozen[i]}" "${versions[i]}"
    done
  } >"${pref_file}"
  chmod 0644 "${pref_file}"
  log "kernel freeze: wrote ${pref_file} (name+version pins for ${#frozen[@]} package(s))"
}
