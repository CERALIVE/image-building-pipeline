#!/bin/bash
#
# ceralive-provision.sh — first-boot WiFi provisioning portal.
#   Part 1 (Task 11): AP-mode trigger + NM-native hotspot bring-up.
#   Part 2 (Task 14): captive-portal lifecycle, credential handoff, and the
#                     four-condition teardown (MAC6 end-state).
#
# Committed standalone artifact (single source of truth under v2/mkosi/runtime/).
# Installed to /usr/local/sbin/ceralive-provision and run by ceralive-provision.service,
# exactly like setup_boot_healthcheck installs ceralive-healthcheck.sh (Task 6 pattern).
#
# WHY: a freshly-flashed appliance with no WiFi credentials and no wired/modem uplink
# is unreachable — there is no way to hand it network config. This brings up a
# self-hosted WPA2 hotspot AND a captive portal so an operator can join it and
# submit WiFi credentials, WITHOUT a screen/keyboard on the device.
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
# CAPTIVE PORTAL (Task 14): served by ceralive-portal.{socket,@.service} (systemd
#   socket activation, Accept=yes) running the bash handler /usr/local/sbin/ceralive-portal
#   on 192.168.42.1:80. The portal is NOT a CeraUI integration (SC2) — it is a plain
#   standalone HTML page. Chosen serving mechanism: systemd socket activation + bash,
#   the lightest viable option ALREADY in the image (no busybox/python3/socat/nc are
#   shipped — socat/netcat were moved to the debug add-on; see manifests/packages/removed.md).
#
#   DNS CAPTURE: an address=/#/192.168.42.1 wildcard dropped into
#   /etc/NetworkManager/dnsmasq-shared.d makes every hostname resolve to the gateway
#   while the AP is up, so the operator's device pops its captive-portal sign-in.
#
#   PORT 80 HANDOFF (the coexistence decision): CeraUI's backend (ceralive.service)
#   binds [80, 8080, 81] in production, trying 80 first (CeraUI rpc/server.ts). On a
#   clean first boot it already owns 0.0.0.0:80 long before the 60-90s grace window
#   elapses, which would shadow the portal's 192.168.42.1:80. So provisioning STOPS
#   ceralive.service before binding the portal (Restart=always does NOT re-fire on an
#   explicit stop), and teardown STARTS it again so CeraUI re-binds 80 on the new
#   uplink IP (MAC6 condition d). The portal owns port 80 only while the AP is up.
#
# CREDENTIAL HANDOFF (the captive-portal handoff problem): the portal POST handler
#   writes the user's WiFi profile via nmcli (credentials land ONLY in NM's own
#   /data-backed system-connections store — never a temp file or config.json), answers
#   the browser with a "connecting…" page, then triggers a DETACHED worker
#   (`ceralive-provision connect <con>` via `systemd-run`, so it survives the
#   per-connection portal service being torn down). The worker drops the AP, switches
#   wlan0 to client mode, and joins the target with a bounded timeout. On success it
#   runs the full teardown; on a wrong passphrase or timeout it deletes the bad
#   profile, writes an error marker the portal shows, and re-arms the AP for a retry —
#   the device never ends up headless-dead.
#
# TEARDOWN CONTRACT (MAC6 end-state — all four conditions):
#   (a) AP mode disabled        — ceralive-ap profile brought down AND deleted.
#   (b) device joined target    — `nmcli connection up <con>` activated + connectivity
#                                 verified (done by the `connect` worker before teardown).
#   (c) portal no longer reachable — ceralive-portal.socket stopped, port 80 freed.
#   (d) CeraUI reachable on new IP — ceralive.service (re)started, re-binds port 80.
#   Exit paths:
#     * `connect` success → teardown_ap KEEP_LINK (does NOT disconnect wlan0; it is
#       carrying the freshly-joined client connection).
#     * `ceralive-provision teardown` (out-of-band) / stale marker → teardown_ap drops
#       wlan0 too (no client connection in that path).
#   Plain `systemctl stop` runs ExecStop=`stop`, a link-down + portal-down clean stop
#   that RETAINS the AP profile + the factory-reset flags so the next boot re-evaluates
#   the trigger and does NOT silently disarm a pending factory reset.
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
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
SYSTEMD_RUN="${SYSTEMD_RUN:-systemd-run}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"   # set empty to skip the outer hard-timeout wrapper
MACHINE_ID_FILE="${CERALIVE_MACHINE_ID_FILE:-/etc/machine-id}"

# CeraUI control-plane service that owns port 80 in production (header §PORT 80
# HANDOFF). Stopped while the AP window is up so the portal can take 80; restarted on
# teardown. Override in tests to point at a stub.
CERAUI_SERVICE="${CERALIVE_CERAUI_SERVICE:-ceralive.service}"

# Captive-portal serving units. The socket is started imperatively when the AP comes
# up and stopped on teardown — installed but NOT enabled at boot.
PORTAL_SOCKET="${CERALIVE_PORTAL_SOCKET:-ceralive-portal.socket}"
PORTAL_SERVICE_GLOB="${CERALIVE_PORTAL_SERVICE_GLOB:-ceralive-portal@*.service}"

# Provisioning state lives on /data: survives reboots AND A/B OTA slot swaps, so the
# factory-reset re-trigger flag and the portal-active marker persist across updates.
STATE_DIR="${CERALIVE_PROVISION_STATE_DIR:-/data/ceralive/provision}"
FORCE_FLAG="${CERALIVE_PROVISION_FORCE_FLAG:-${STATE_DIR}/force-portal}"          # factory-reset re-trigger
ACTIVE_FLAG="${CERALIVE_PROVISION_ACTIVE_FLAG:-${STATE_DIR}/portal-active}"       # set while AP is up; read by the portal
TEARDOWN_FLAG="${CERALIVE_PROVISION_TEARDOWN_FLAG:-${STATE_DIR}/teardown-requested}"
SCAN_CACHE="${CERALIVE_PROVISION_SCAN_CACHE:-${STATE_DIR}/scan.txt}"              # SSID list (single-radio: scanned BEFORE AP up)
ERROR_MARKER="${CERALIVE_PROVISION_ERROR_MARKER:-${STATE_DIR}/last-error}"        # written on a failed join; shown by the portal

# DNS-capture drop-in: NM's shared-mode dnsmasq reads dnsmasq-shared.d at activation.
# Wildcard-resolving every name to the gateway is what pops the captive-portal sign-in.
# Provisioning-scoped: written before AP up, removed on teardown (must NOT linger and
# wildcard a later user hotspot).
DNS_CAPTURE_DIR="${CERALIVE_DNSMASQ_SHARED_DIR:-/etc/NetworkManager/dnsmasq-shared.d}"
DNS_CAPTURE_FILE="${DNS_CAPTURE_DIR}/ceralive-portal.conf"

# AP identity / addressing.
AP_CON_NAME="${CERALIVE_AP_CON_NAME:-ceralive-ap}"   # NM profile name — EXCLUDED from the stored-profile count
AP_IFACE="${CERALIVE_AP_IFACE:-wlan0}"
AP_GW="${CERALIVE_AP_GATEWAY:-192.168.42.1}"
AP_PREFIX="${CERALIVE_AP_PREFIX:-24}"
AP_PASSPHRASE="${CERALIVE_AP_PASSPHRASE:-ceralive-setup}"   # WPA2-PSK; documented default (>=8 chars)

# Target (user) WiFi profile the portal writes. A FIXED name keeps retries idempotent;
# it IS counted by stored_wifi_profile_count, so once written the portal stays down on
# the next boot (EC4).
USER_CON_NAME="${CERALIVE_USER_CON_NAME:-ceralive-wifi}"

# Boot grace window (60-90s) + connectivity poll cadence.
GRACE_SECONDS="${CERALIVE_PROVISION_GRACE:-75}"
POLL_INTERVAL="${CERALIVE_PROVISION_POLL:-5}"

# Credential-handoff timing (the `connect` worker).
CONNECT_FLUSH_DELAY="${CERALIVE_CONNECT_FLUSH_DELAY:-2}"     # let the HTTP response flush before dropping the AP
CONNECT_WAIT="${CERALIVE_CONNECT_WAIT:-45}"                  # nmcli --wait: bounds a bad-PSK auth loop
CONNECT_HARD_TIMEOUT="${CERALIVE_CONNECT_HARD_TIMEOUT:-60}"  # outer guard against a wedged nmcli

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

# --- captive-portal support ----------------------------------------------------

# Single-radio devices cannot scan while in AP mode, so cache the visible SSIDs
# BEFORE switching wlan0 to AP. The portal renders these as a <datalist> AND still
# offers free-text entry. Best-effort: an empty cache just means manual entry only.
cache_scan() {
  mkdir -p "${STATE_DIR}"
  "${NMCLI}" -g SSID dev wifi list --rescan yes 2>/dev/null \
    | sed 's/\\:/:/g' \
    | awk 'NF' \
    | sort -u \
    | head -n 50 >"${SCAN_CACHE}" 2>/dev/null || : >"${SCAN_CACHE}"
  log "cached $(wc -l <"${SCAN_CACHE}" 2>/dev/null || echo 0) visible SSID(s) for the portal"
}

write_dns_capture() {
  mkdir -p "${DNS_CAPTURE_DIR}"
  printf 'address=/#/%s\n' "${AP_GW}" >"${DNS_CAPTURE_FILE}"
  log "installed DNS capture (${DNS_CAPTURE_FILE} → ${AP_GW})"
}

remove_dns_capture() { rm -f "${DNS_CAPTURE_FILE}"; }

# Stopping CeraUI frees 0.0.0.0:80 for the portal's 192.168.42.1:80; an explicit stop
# is not reversed by ceralive.service's Restart=always.
stop_ceraui()  { "${SYSTEMCTL}" stop  "${CERAUI_SERVICE}" >/dev/null 2>&1 || true; }
start_ceraui() { "${SYSTEMCTL}" start "${CERAUI_SERVICE}" >/dev/null 2>&1 || true; }

start_portal_socket() {
  "${SYSTEMCTL}" start "${PORTAL_SOCKET}" >/dev/null 2>&1 \
    || log "WARN: could not start ${PORTAL_SOCKET} (portal will be unreachable)"
}

# Stop the listener (frees port 80) AND any in-flight per-connection instances.
stop_portal_socket() {
  "${SYSTEMCTL}" stop "${PORTAL_SOCKET}" >/dev/null 2>&1 || true
  "${SYSTEMCTL}" stop "${PORTAL_SERVICE_GLOB}" >/dev/null 2>&1 || true
}

# --- AP bring-up (NetworkManager native AP mode) + portal -----------------------
bring_up_ap() {
  local ssid; ssid="$(ap_ssid)"
  log "starting provisioning AP '${ssid}' on ${AP_IFACE} (gateway ${AP_GW}/${AP_PREFIX}, WPA2)"

  # Scan + DNS capture must be in place BEFORE the shared connection activates: the
  # radio can't scan in AP mode, and NM's shared dnsmasq reads dnsmasq-shared.d at
  # activation time.
  cache_scan
  write_dns_capture

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
  # Marker consumed by the captive portal and the teardown contract.
  printf 'ssid=%s\ngateway=%s\niface=%s\ncon=%s\nuser_con=%s\n' \
      "${ssid}" "${AP_GW}" "${AP_IFACE}" "${AP_CON_NAME}" "${USER_CON_NAME}" >"${ACTIVE_FLAG}"

  # Hand port 80 from CeraUI to the captive portal.
  stop_ceraui
  start_portal_socket
  log "provisioning AP active — captive portal on ${AP_GW}:80 (marker ${ACTIVE_FLAG})"
}

# --- clean link-down only (service ExecStop / shutdown) ------------------------
# The AP profile + the /data flags are RETAINED so the next boot re-evaluates the
# trigger; the factory-reset force flag is NOT cleared here. The portal listener is
# stopped and CeraUI is restored to port 80 so a manual `systemctl stop
# ceralive-provision` does not leave the device with no reachable control plane.
stop_ap() {
  log "stopping provisioning AP link (profile + flags retained; portal down, CeraUI restored)"
  stop_portal_socket
  remove_dns_capture
  "${NMCLI}" connection down "${AP_CON_NAME}" >/dev/null 2>&1 || true
  start_ceraui
}

# --- TEARDOWN: full provisioning-mode exit (MAC6 end-state) --------------------
# Arg 1 (KEEP_LINK): when "1", do NOT disconnect wlan0 — it is carrying the freshly
# joined client connection (the `connect` success path). Out-of-band teardown leaves
# it 0 and releases the radio.
teardown_ap() {
  local keep_link="${1:-0}"
  log "tearing down provisioning AP (exit provisioning mode; keep_link=${keep_link})"

  # (c) portal no longer reachable — stop listener + drain instances, freeing port 80.
  stop_portal_socket
  remove_dns_capture

  # (a) AP mode disabled — bring the AP down and DELETE the profile.
  "${NMCLI}" connection down "${AP_CON_NAME}" >/dev/null 2>&1 || true
  "${NMCLI}" connection delete "${AP_CON_NAME}" >/dev/null 2>&1 || true
  if [ "${keep_link}" != "1" ]; then
    "${NMCLI}" device disconnect "${AP_IFACE}" >/dev/null 2>&1 || true
  fi

  rm -f "${ACTIVE_FLAG}" "${FORCE_FLAG}" "${TEARDOWN_FLAG}" "${ERROR_MARKER}"

  # (d) CeraUI reachable on the new IP — restart so it re-binds port 80.
  start_ceraui
  log "provisioning mode cleared (AP profile deleted, flags cleared, CeraUI on port 80)"
}

# --- credential-handoff worker (detached; runs in its own transient unit) ------
# Invoked as `ceralive-provision connect <con>` by the portal via systemd-run, so it
# survives the per-connection portal service being torn down. The portal has ALREADY
# written the <con> NM profile (credentials live only in NM storage). This worker
# switches wlan0 from AP to client mode and joins, then teardown-on-success or
# re-arm-on-failure.
con_ssid() { "${NMCLI}" -g 802-11-wireless.ssid connection show "$1" 2>/dev/null; }

verify_joined() { have_connectivity; }

bounded_connect() {
  local con="$1"
  if [ -n "${TIMEOUT_BIN}" ] && command -v "${TIMEOUT_BIN}" >/dev/null 2>&1; then
    "${TIMEOUT_BIN}" "${CONNECT_HARD_TIMEOUT}" "${NMCLI}" --wait "${CONNECT_WAIT}" connection up "${con}"
  else
    "${NMCLI}" --wait "${CONNECT_WAIT}" connection up "${con}"
  fi
}

connect_target() {
  local con="${1:?connect requires a connection name}"
  local attempt_ssid; attempt_ssid="$(con_ssid "${con}")"
  log "credential handoff: attempting to join '${attempt_ssid:-${con}}' (profile ${con})"

  # Let the browser receive the "connecting…" page before we drop the AP that is
  # carrying its connection.
  sleep "${CONNECT_FLUSH_DELAY}"

  # Drop the AP connection so the radio is free to associate as a client. We do NOT
  # `device disconnect ${AP_IFACE}` here: bringing the AP connection down already frees
  # wlan0, and an explicit device-disconnect would block the very client activation
  # below (and, on success, would tear down the link we just brought up). The full
  # radio release for the FAILURE path is handled by re-arming, and for out-of-band
  # exits by teardown_ap with keep_link=0.
  stop_portal_socket
  "${NMCLI}" connection down "${AP_CON_NAME}" >/dev/null 2>&1 || true

  if bounded_connect "${con}" && verify_joined; then
    log "joined target network (${con}) — finalising provisioning teardown"
    rm -f "${ERROR_MARKER}"
    teardown_ap 1     # KEEP_LINK: wlan0 is carrying the new client connection
    exit 0
  fi

  # FAILURE / TIMEOUT — wrong passphrase, no DHCP, or a wedged join. Delete the bad
  # profile (so it neither lingers nor suppresses a re-trigger), record the reason,
  # and re-arm the AP for a retry. Never leave the device headless-dead.
  log "join FAILED for '${attempt_ssid:-${con}}' — returning to AP mode for retry"
  "${NMCLI}" connection delete "${con}" >/dev/null 2>&1 || true
  mkdir -p "${STATE_DIR}"
  printf 'ssid=%s\nreason=auth_or_timeout\n' "${attempt_ssid}" >"${ERROR_MARKER}"
  bring_up_ap
  exit 1
}

main() {
  local cmd="${1:-start}"
  case "${cmd}" in
    stop)     stop_ap;       exit 0 ;;
    teardown) teardown_ap 0; exit 0 ;;
    connect)  connect_target "${2:-}" ;;   # exits inside (success 0 / failure 1)
    start)    ;;
    *)        die "unknown command: ${cmd} (use: start | stop | teardown | connect <con>)" ;;
  esac

  # Out-of-band teardown request (alt exit path): honor it and exit.
  if [ -e "${TEARDOWN_FLAG}" ]; then
    log "teardown-requested flag present (${TEARDOWN_FLAG}) → exiting provisioning mode"
    teardown_ap 0
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
