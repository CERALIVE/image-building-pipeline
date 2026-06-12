#!/bin/bash
#
# ceralive-provision.sh — first-boot WiFi provisioning portal: AP-mode trigger +
# bring-up (Task 11, part 1). The captive-portal page + credential logic is Task 14.
#
# Committed standalone artifact (single source of truth under v2/mkosi/runtime/).
# Installed to /usr/local/sbin/ceralive-provision and run by ceralive-provision.service,
# exactly like setup_boot_healthcheck installs ceralive-healthcheck.sh (Task 6 pattern).
#
# WHY: a freshly-flashed appliance with no WiFi credentials and no wired/modem uplink
# is unreachable — there is no way to hand it network config. This brings up a
# self-hosted WPA2 hotspot so an operator can join it and (Task 14) submit WiFi
# credentials, WITHOUT a screen/keyboard on the device.
#
# TRIGGER LOGIC (evaluated at runtime; the unit cannot express it as static Conditions):
#   1. RE-TRIGGER (factory-reset hook): if the force flag exists, start the portal
#      unconditionally — even when WiFi profiles already exist.
#   2. DEFAULT TRIGGER: start the portal IFF there are NO stored (non-AP) NM WiFi
#      profiles on /data AND no link-up connectivity appears within a boot grace
#      window (60-90s). Either a stored profile OR connectivity suppresses it.
#
#   EC4: a RAUC A/B update that PRESERVES /data keeps the stored WiFi profiles, so
#        condition (2) is false and the portal correctly does NOT start after an OTA.
#   CONFLICT SAFETY: the AP only comes up when there is ZERO connectivity, so srtla
#        bonding/streaming is impossible anyway and the AP never contends with the
#        srtla WiFi source-routing for a live uplink. The AP also leaves wlan0 with
#        no default route, so the srtla NM dispatcher (90-srtla-wifi-routing) sees an
#        empty GATEWAY and installs no rule/route in table 120 — it is a no-op while
#        the portal is up.
#
# AP MODE: NetworkManager-NATIVE AP (802-11-wireless.mode ap + ipv4.method shared).
#   Preferred over hostapd+dnsmasq — fewer moving parts and NO extra packages: NM
#   drives wpa_supplicant in AP mode and runs its internal dnsmasq for DHCP on the
#   shared subnet. hostapd remains in the image only as an evidence-gated fallback
#   (NOT used here). NM-native AP is supported since NM 1.0; the image ships NM 1.42
#   (Debian bookworm). HW caveat: AP mode also needs the wlan driver to support it
#   (RK3588 onboard chip dependent) — see image-building-pipeline/AGENTS.md.
#
# TEARDOWN CONTRACT (Task 14 — how the portal exits provisioning mode cleanly):
#   The captive portal, once it has stored a real WiFi profile, MUST exit AP mode by
#   EITHER
#     * running   /usr/local/sbin/ceralive-provision teardown          (preferred), OR
#     * creating  /data/ceralive/provision/teardown-requested  then
#       restarting ceralive-provision.service (the start path honors the flag).
#   `teardown` brings the AP profile down, DELETES it, releases wlan0, and clears the
#   portal-active marker AND the factory-reset force flag, so the next boot evaluates
#   the trigger cleanly and does NOT re-enter the portal now that a profile exists.
#   (Plain `systemctl stop` runs ExecStop=`stop`, a link-down-only clean stop that
#   RETAINS the profile + flags — shutdown must not silently disarm a factory reset.)
#
# This is a standalone DEVICE script: it does NOT source the repo lib/common.sh
# (not present on the device). NOT `set -e`: the trigger probes are EXPECTED to fail
# transiently (NM still settling) and are evaluated explicitly in a grace loop.
#
# shellcheck shell=bash

set -uo pipefail

PROG="ceralive-provision"

log()  { logger -t "${PROG}" -- "$*" 2>/dev/null || true; echo "${PROG}: $*"; }
die()  { log "FATAL: $*"; exit 1; }

# --- config / test seams (overridable for the offline proof harness) ----------
NMCLI="${NMCLI:-nmcli}"
IP_BIN="${IP_BIN:-ip}"
MACHINE_ID_FILE="${CERALIVE_MACHINE_ID_FILE:-/etc/machine-id}"

# Provisioning state lives on /data: survives reboots AND A/B OTA slot swaps, so the
# factory-reset re-trigger flag and the portal-active marker persist across updates.
STATE_DIR="${CERALIVE_PROVISION_STATE_DIR:-/data/ceralive/provision}"
FORCE_FLAG="${CERALIVE_PROVISION_FORCE_FLAG:-${STATE_DIR}/force-portal}"          # factory-reset re-trigger
ACTIVE_FLAG="${CERALIVE_PROVISION_ACTIVE_FLAG:-${STATE_DIR}/portal-active}"       # set while AP is up; read by Task 14
TEARDOWN_FLAG="${CERALIVE_PROVISION_TEARDOWN_FLAG:-${STATE_DIR}/teardown-requested}"

# AP identity / addressing.
AP_CON_NAME="${CERALIVE_AP_CON_NAME:-ceralive-ap}"   # NM profile name — EXCLUDED from the stored-profile count
AP_IFACE="${CERALIVE_AP_IFACE:-wlan0}"
AP_GW="${CERALIVE_AP_GATEWAY:-192.168.42.1}"
AP_PREFIX="${CERALIVE_AP_PREFIX:-24}"
AP_PASSPHRASE="${CERALIVE_AP_PASSPHRASE:-ceralive-setup}"   # WPA2-PSK; documented default (>=8 chars)

# Boot grace window (60-90s) + connectivity poll cadence.
GRACE_SECONDS="${CERALIVE_PROVISION_GRACE:-75}"
POLL_INTERVAL="${CERALIVE_PROVISION_POLL:-5}"

# --- SSID short-id: machine-id derived, mirroring ceralive-set-hostname --------
ap_ssid() {
  local mid
  mid="$(tr -cd 'a-f0-9' <"${MACHINE_ID_FILE}" 2>/dev/null | tail -c 4)"
  [ -n "${mid}" ] || mid="0000"
  printf 'CeraLive-Setup-%s' "${mid}"
}

# --- stored WiFi profile count (EXCLUDING our own AP profile) ------------------
# A real user WiFi profile means the device can rejoin an uplink, so the portal must
# NOT start (EC4). Our own ${AP_CON_NAME} profile is excluded — it is created by THIS
# script and must never suppress its own re-trigger.
stored_wifi_profile_count() {
  "${NMCLI}" -t -f NAME,TYPE connection show 2>/dev/null \
    | awk -F: -v ap="${AP_CON_NAME}" '
        $2 == "802-11-wireless" && $1 != ap { n++ }
        END { print n + 0 }'
}

# --- connectivity probe --------------------------------------------------------
# "link-up connectivity" = NM reports a connected state (full/limited/portal) OR a
# default route exists. Either means an uplink (wired / modem / known WiFi) is
# carrying IP, so streaming is possible and the AP must not contend for wlan0.
# Errs toward NOT starting the AP (the conservative, conflict-safe choice).
have_connectivity() {
  local state
  state="$("${NMCLI}" -t -f CONNECTIVITY general status 2>/dev/null)"
  case "${state}" in
    full|limited|portal) return 0 ;;
  esac
  if "${IP_BIN}" -4 route show default 2>/dev/null | grep -q '^default '; then
    return 0
  fi
  return 1
}

# --- decision: should the provisioning portal start this boot? -----------------
should_start_portal() {
  if [ -e "${FORCE_FLAG}" ]; then
    log "force-portal flag present (${FORCE_FLAG}) → starting portal regardless of profiles/connectivity"
    return 0
  fi

  local n; n="$(stored_wifi_profile_count)"
  if [ "${n}" -gt 0 ]; then
    log "found ${n} stored WiFi profile(s) on /data → portal not needed (EC4: OTA-preserved profiles keep it down)"
    return 1
  fi

  log "no stored WiFi profiles — waiting up to ${GRACE_SECONDS}s for any link-up connectivity"
  local waited=0
  while [ "${waited}" -lt "${GRACE_SECONDS}" ]; do
    if have_connectivity; then
      log "connectivity detected after ${waited}s → portal not needed"
      return 1
    fi
    sleep "${POLL_INTERVAL}"
    waited=$(( waited + POLL_INTERVAL ))
  done

  log "grace expired (${GRACE_SECONDS}s): no profiles + no connectivity → portal required"
  return 0
}

# --- AP bring-up (NetworkManager native AP mode) -------------------------------
bring_up_ap() {
  local ssid; ssid="$(ap_ssid)"
  log "starting provisioning AP '${ssid}' on ${AP_IFACE} (gateway ${AP_GW}/${AP_PREFIX}, WPA2)"

  # Idempotent: drop any prior profile so settings always match this script. The
  # profile is autoconnect=no — it must come up ONLY when the trigger fires, never
  # automatically on a boot where a real uplink exists.
  "${NMCLI}" connection delete "${AP_CON_NAME}" >/dev/null 2>&1 || true
  "${NMCLI}" connection add \
      type wifi ifname "${AP_IFACE}" con-name "${AP_CON_NAME}" \
      autoconnect no ssid "${ssid}" \
      802-11-wireless.mode ap 802-11-wireless.band bg \
      ipv4.method shared ipv4.addresses "${AP_GW}/${AP_PREFIX}" \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "${AP_PASSPHRASE}" \
    || die "failed to create AP connection profile '${AP_CON_NAME}'"

  "${NMCLI}" connection up "${AP_CON_NAME}" \
    || die "failed to activate AP connection '${AP_CON_NAME}' on ${AP_IFACE}"

  mkdir -p "${STATE_DIR}"
  # Marker consumed by the captive portal (Task 14) and the teardown contract.
  printf 'ssid=%s\ngateway=%s\niface=%s\ncon=%s\n' \
      "${ssid}" "${AP_GW}" "${AP_IFACE}" "${AP_CON_NAME}" >"${ACTIVE_FLAG}"
  log "provisioning AP active — portal marker at ${ACTIVE_FLAG}"
}

# --- clean link-down only (service ExecStop / shutdown) ------------------------
# Profile + flags are RETAINED so the next boot re-evaluates the trigger; the
# factory-reset force flag is NOT cleared here (only an explicit teardown clears it).
stop_ap() {
  log "stopping provisioning AP link (profile + flags retained)"
  "${NMCLI}" connection down "${AP_CON_NAME}" >/dev/null 2>&1 || true
}

# --- TEARDOWN: full provisioning-mode exit (Task 14 contract) ------------------
teardown_ap() {
  log "tearing down provisioning AP (exit provisioning mode)"
  "${NMCLI}" connection down "${AP_CON_NAME}" >/dev/null 2>&1 || true
  "${NMCLI}" connection delete "${AP_CON_NAME}" >/dev/null 2>&1 || true
  "${NMCLI}" device disconnect "${AP_IFACE}" >/dev/null 2>&1 || true
  rm -f "${ACTIVE_FLAG}" "${FORCE_FLAG}" "${TEARDOWN_FLAG}"
  log "provisioning mode cleared (AP profile deleted, ${AP_IFACE} released, flags cleared)"
}

main() {
  local cmd="${1:-start}"
  case "${cmd}" in
    stop)     stop_ap;     exit 0 ;;
    teardown) teardown_ap; exit 0 ;;
    start)    ;;
    *)        die "unknown command: ${cmd} (use: start | stop | teardown)" ;;
  esac

  # Out-of-band teardown request (Task 14 alt path): honor it and exit.
  if [ -e "${TEARDOWN_FLAG}" ]; then
    log "teardown-requested flag present (${TEARDOWN_FLAG}) → exiting provisioning mode"
    teardown_ap
    exit 0
  fi

  if should_start_portal; then
    bring_up_ap
  else
    if [ -e "${ACTIVE_FLAG}" ]; then
      log "stale portal marker but portal no longer required → tearing down"
      teardown_ap
    fi
    log "provisioning portal not started"
  fi
  exit 0
}

main "$@"
