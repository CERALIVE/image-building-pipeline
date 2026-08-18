#!/usr/bin/env bash
#
# ceralive-dongle-netns-retire — tear the retired router-dongle netns layer off a
# board that used to run it.
#
# WHY THIS EXISTS AT ALL. Phase-C todo 39 retired the router-dongle network-
# namespace layer: no image installs its manager, its template unit, its udev
# claim rule or its NetworkManager unmanaged-devices snippet any more, and a
# classified router dongle now bonds through its OWN enx…/eth… interface. A board
# that never ran the layer therefore needs nothing, and this script is a no-op on
# it.
#
# A board that DID run it is the interesting case, and exactly one piece of its
# state is engineered to survive the upgrade:
#
#   * the durable slot store /data/ceralive/dongle-slots.json (+ its .lock) lives
#     on the DATA partition — deliberately, because a RAUC slot swap wipes a
#     rootfs slot and would otherwise renumber every dongle across an OTA. That
#     design decision is precisely what turns it into the one piece of residue an
#     image update cannot clear by itself, and removing it is the only part of
#     this script that a slot swap could not have done without us.
#
# Everything else clears itself on the upgrade path, and is handled here anyway
# because the upgrade path is not the only path:
#
#   * the units, the udev rule, the NM snippet and /usr/local/sbin/ceralive-dongle-*
#     live inside the ROOTFS, so a RAUC slot swap boots without them — but a
#     dev-sync/in-place update replaces neither /etc nor /usr;
#   * the namespaces, the dg<N>h veths, the ip rules, the per-slot routing tables
#     and /run/ceralive/dongles are kernel/tmpfs state, so the reboot a slot swap
#     requires clears them — but an operator retiring the layer in place does not
#     get that reboot.
#
# SAFETY: EVERY name this touches is enumerated from the retired contract's own
# allocation table (dongle-netns contract §2.1, slots 0..7 — netns `dongle<N>`,
# host veth `dg<N>h`, routing table `110+N`, ip rule priority `5100+N`). There is
# no wildcard sweep and no pattern match against live state, so a namespace, veth,
# rule or table this layer did not create cannot be removed by a typo here. Slot
# 8 does not exist; neither does `dg8h`.
#
# It is IDEMPOTENT and it always exits 0. A failure to remove one artifact is
# logged and the next one is still attempted: a partially-retired board is worse
# than either a fully-retired or a fully-intact one, so the script never stops at
# the first refusal, and it never fails the boot it runs in.
#
# ip rule/table work is best-effort BY DESIGN. The edge kernel answers `ip rule`
# with "Operation not supported" (no CONFIG_IP_MULTIPLE_TABLES), which is a fact
# about the kernel and not a fault: a board that cannot express a policy rule
# never had one to remove.
#
# Overrides exist ONLY so the offline test can drive it against a fixture tree;
# a device sets none of them.

set -uo pipefail

STATE_DIR="${CERALIVE_DONGLE_RETIRE_STATE_DIR:-/data/ceralive}"
RUN_DIR="${CERALIVE_DONGLE_RETIRE_RUN_DIR:-/run/ceralive/dongles}"
SBIN_DIR="${CERALIVE_DONGLE_RETIRE_SBIN_DIR:-/usr/local/sbin}"
UNIT_DIR="${CERALIVE_DONGLE_RETIRE_UNIT_DIR:-/etc/systemd/system}"
UDEV_DIR="${CERALIVE_DONGLE_RETIRE_UDEV_DIR:-/etc/udev/rules.d}"
NM_DIR="${CERALIVE_DONGLE_RETIRE_NM_DIR:-/etc/NetworkManager/conf.d}"

# Contract §2.1: eight slots, and the derivations that name everything else.
SLOTS=(0 1 2 3 4 5 6 7)

log() { printf 'ceralive-dongle-netns-retire: %s\n' "$*"; }

# Set by any step that actually removed something, so the reload/notify tail runs
# only on a board that was carrying residue.
CHANGED=0

have() { command -v "$1" >/dev/null 2>&1; }

# --- 1. the units ------------------------------------------------------------
#
# Stop before disable before mask. Stopping first means the manager is not
# mid-claim while its state is removed underneath it; masking last means a udev
# event that fires during the teardown cannot re-activate the template unit
# through a rule we have not deleted yet.
retire_units() {
  have systemctl || return 0

  local unit
  for unit in \
    ceralive-dongle-netns-reconcile.timer \
    ceralive-dongle-netns-reconcile.service \
    'ceralive-dongle-netns@*.service'
  do
    # `stop` on an absent or already-inactive unit is a legitimate no-op; the
    # glob form is what catches every per-slot instance without enumerating.
    systemctl stop "${unit}" >/dev/null 2>&1 || true
  done

  for unit in \
    ceralive-dongle-netns-reconcile.timer \
    ceralive-dongle-netns-reconcile.service
  do
    if systemctl cat "${unit}" >/dev/null 2>&1; then
      systemctl disable "${unit}" >/dev/null 2>&1 || true
      log "disabled ${unit}"
      CHANGED=1
    fi
  done
}

# --- 2. the live namespaces and their veths ----------------------------------
#
# Deleting the namespace takes its dg<N>n end with it, and a veth pair dies with
# either end — so the explicit dg<N>h sweep afterwards exists for the one state
# the namespace delete cannot reach: a host veth left behind by a namespace that
# was already gone.
retire_namespaces() {
  have ip || return 0

  local n ns veth
  for n in "${SLOTS[@]}"; do
    ns="dongle${n}"
    if ip netns list 2>/dev/null | awk -v want="${ns}" '{ if ($1 == want) found = 1 } END { exit found ? 0 : 1 }'; then
      if ip netns delete "${ns}" >/dev/null 2>&1; then
        log "removed network namespace ${ns}"
        CHANGED=1
      else
        log "WARNING: could not remove network namespace ${ns}"
      fi
    fi
  done

  for n in "${SLOTS[@]}"; do
    veth="dg${n}h"
    if [[ -e "/sys/class/net/${veth}" ]]; then
      if ip link delete "${veth}" >/dev/null 2>&1; then
        log "removed leftover host veth ${veth}"
        CHANGED=1
      else
        log "WARNING: could not remove leftover host veth ${veth}"
      fi
    fi
  done
}

# --- 3. the policy rules and per-slot routing tables -------------------------
#
# Best-effort on purpose (see the header): a kernel with no multiple-tables
# support answers every one of these with "Operation not supported", which means
# the board never had the rule this is trying to withdraw.
retire_routing() {
  have ip || return 0
  ip rule show >/dev/null 2>&1 || return 0

  local n
  for n in "${SLOTS[@]}"; do
    # Delete by the exact (priority, table) pair the contract assigned, never by
    # priority alone — a bare `ip rule del pref N` would remove whatever now sits
    # at that priority if something else has since claimed it.
    #
    # Repeated because a rule can legitimately be present more than once at one
    # priority, and BOUNDED because the loop's exit condition is a non-zero exit
    # from an external command: an `ip` that answered 0 unconditionally would
    # otherwise spin here forever and hang the boot this unit runs in. Eight is
    # the slot count, i.e. more duplicates than the layer could ever have made.
    for _ in $(seq 1 8); do
      ip rule del pref "$((5100 + n))" table "$((110 + n))" >/dev/null 2>&1 || break
      log "withdrew ip rule pref $((5100 + n)) table $((110 + n))"
      CHANGED=1
    done

    if [[ -n "$(ip route show table "$((110 + n))" 2>/dev/null)" ]]; then
      if ip route flush table "$((110 + n))" >/dev/null 2>&1; then
        log "flushed routing table $((110 + n))"
        CHANGED=1
      fi
    fi
  done
}

# --- 4. the runtime metadata -------------------------------------------------
#
# CeraUI's reader is tolerant of this directory being absent — that is the whole
# reason it survives the retirement — so removing it is safe at any moment and
# costs the reader nothing but an empty map.
retire_runtime_metadata() {
  [[ -e "${RUN_DIR}" ]] || return 0
  if rm -rf -- "${RUN_DIR}"; then
    log "removed runtime metadata directory ${RUN_DIR}"
    CHANGED=1
  else
    log "WARNING: could not remove ${RUN_DIR}"
  fi
}

# --- 5. the durable slot store — the ONLY OTA-surviving residue --------------
retire_slot_store() {
  local f
  for f in "${STATE_DIR}/dongle-slots.json" "${STATE_DIR}/dongle-slots.lock"; do
    [[ -e "${f}" ]] || continue
    if rm -f -- "${f}"; then
      log "removed durable slot store ${f}"
      CHANGED=1
    else
      log "WARNING: could not remove ${f}"
    fi
  done
}

# --- 6. the rootfs assets ----------------------------------------------------
#
# Absent by construction after a RAUC slot swap; present after an in-place update.
retire_rootfs_assets() {
  local f
  for f in \
    "${SBIN_DIR}/ceralive-dongle-netns" \
    "${SBIN_DIR}/ceralive-dongle-classify" \
    "${SBIN_DIR}/ceralive-dongle-udhcpc" \
    "${UNIT_DIR}/ceralive-dongle-netns@.service" \
    "${UNIT_DIR}/ceralive-dongle-netns-reconcile.service" \
    "${UNIT_DIR}/ceralive-dongle-netns-reconcile.timer" \
    "${UDEV_DIR}/85-ceralive-dongle-netns.rules" \
    "${NM_DIR}/ceralive-dongle.conf"
  do
    [[ -e "${f}" ]] || continue
    if rm -f -- "${f}"; then
      log "removed ${f}"
      CHANGED=1
    else
      log "WARNING: could not remove ${f}"
    fi
  done
}

main() {
  retire_units
  retire_namespaces
  retire_routing
  retire_runtime_metadata
  retire_slot_store
  retire_rootfs_assets

  if (( CHANGED )); then
    # Only after the files are gone: a reload while the units still existed would
    # simply re-read them.
    if have systemctl; then
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    # Guarded exactly like every other udev caller in this image — there is no
    # udev to talk to inside a build chroot.
    if [[ -d /run/udev ]] && have udevadm; then
      udevadm control --reload >/dev/null 2>&1 || true
    fi
    log "router-dongle netns layer retired"
  else
    log "no router-dongle netns residue found — nothing to retire"
  fi

  # Always 0: this must never fail a boot, and a board with nothing to clean is
  # the expected steady state rather than an error.
  return 0
}

main "$@"
