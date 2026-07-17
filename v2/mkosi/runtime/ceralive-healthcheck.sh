#!/bin/bash
#
# ceralive-healthcheck.sh — gate RAUC `mark-good` on REAL streaming health.
#
# THE HIGHEST-SEVERITY OPERATIONAL TRAP (decisions.md / task 29): a bad bundle
# that merely BOOTS but cannot ENCODE must NOT confirm itself. A naive "kernel
# booted → mark-good" healthcheck would permanently brick every device that
# received that update (recovery = physical reflash). So this script proves the
# streaming stack actually works before calling `rauc mark-good`; if it does not,
# the slot is left UNCONFIRMED and the bootcount adapter rolls it back on the next
# reboot (see platform/boot/ceralive-rauc-boot-adapter.sh + ceralive-boot-state).
#
# HEALTH CHECKS, IN ORDER (ALL must pass within HEALTHCHECK_TIMEOUT):
#   1. ceralive.service is `active`        — the Bun/CeraUI binary that drives
#                                            cerastream/srtla is up (primary signal).
#   2. cerastream binary present + LOADS   — runs under a hard timeout; a dynamic
#   3. srtla_send binary present + LOADS      loader failure (missing libsrt / wrong
#                                            arch) is the canonical can't-encode
#                                            signature → hard fail.
#   4. SRT/SRTLA port reachable            — TCP connect to IRL_SERVER_HOST:PORT;
#                                            NON-FATAL on a fresh offline device.
#
# "REACHABLE" = a TCP connection to the SRT port succeeds. SRT/SRTLA itself is
# UDP; this is deliberately NOT a full SRT handshake (inherited wisdom + brief):
# a successful TCP connect proves the network path + that the cloud edge is
# listening, which is sufficient to confirm reach. The reach check is SKIPPED
# (non-fatal) on a fresh OFFLINE device — when IRL_SERVER_HOST is unset (not yet
# provisioned) OR no non-loopback network interface is up (no link, so no path to
# any receiver). In BOTH cases the local stack checks (service active + binaries
# load) still gate mark-good, so a can't-encode image is still caught and still
# rolls back; a healthy device with no SRT receiver can confirm itself and avoid a
# first-boot rollback loop (the highest brick risk on a single-slot image). Reach
# only HARD-FAILS when the device is BOTH provisioned AND online but the configured
# cloud edge does not answer.
#
# CONFIG (all overridable from /data/ceralive/update.conf; never hardcoded):
#   IRL_SERVER_HOST            irl-srt-server host (empty/offline → skip reach)
#   IRL_SERVER_SRT_PORT        SRT/SRTLA port                       (default 9000)
#   HEALTHCHECK_TIMEOUT        overall seconds to reach health      (default 60)
#   HEALTHCHECK_RETRY_INTERVAL seconds between attempts             (default 5)
#
# IDEMPOTENCY: on success a marker (/data/ceralive/.slot-marked-good) is written
# and the unit's ConditionPathExists makes subsequent boots a no-op. /data is
# SHARED across the A/B slots, so the marker is CLEARED by ceralive-update on every
# new bundle install — a freshly-activated slot must re-prove health before it is
# confirmed (otherwise a healthy slot B would inherit A's marker and roll back).
#
# This is a standalone DEVICE script: it does NOT source the repo lib/common.sh
# (not present on the device). DUAL-TRACK: an inline twin lives in
# mkosi.images/runtime/mkosi.postinst.chroot — keep the two in sync.
#
# NOTE: not `set -e` — the checks are EXPECTED to fail transiently and are retried;
# each is evaluated explicitly so a failing probe never aborts the retry loop.
# shellcheck shell=bash

set -uo pipefail

PROG="ceralive-healthcheck"

# --- config: defaults first, then /data/ceralive/update.conf overrides them ----
CONF="${CERALIVE_HEALTHCHECK_CONF:-/data/ceralive/update.conf}"
MARKER="${CERALIVE_HEALTHCHECK_MARKER:-/data/ceralive/.slot-marked-good}"

CERALIVE_SERVICE="${CERALIVE_SERVICE:-ceralive.service}"
IRL_SERVER_HOST=""
IRL_SERVER_SRT_PORT="9000"
HEALTHCHECK_TIMEOUT="60"
HEALTHCHECK_RETRY_INTERVAL="5"

# Per-probe guards (kept short so a misbehaving binary/port can never hang boot).
BIN_PROBE_TIMEOUT="${BIN_PROBE_TIMEOUT:-5}"
SRT_CONNECT_TIMEOUT="${SRT_CONNECT_TIMEOUT:-5}"

# Test seams: stubbed in the offline proof harness; the real tools on device.
RAUC_BIN="${RAUC_BIN:-rauc}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
# Streaming binaries to probe (resolved via PATH; /usr/bin on device).
# cerastream replaced ceracoder as the sole streaming engine (retired 2026-06-11).
CERASTREAM_BIN="${CERASTREAM_BIN:-cerastream}"
SRTLA_SEND_BIN="${SRTLA_SEND_BIN:-srtla_send}"
# Link-state probe (iproute2); stubbed in the offline proof harness.
IP_BIN="${IP_BIN:-ip}"
# HTTP(S) control-plane probe (task 15): curl hits the CeraUI backend on :80 and
# the nginx TLS front on :443; stubbed in the offline proof harness.
CURL_BIN="${CURL_BIN:-curl}"
HTTP_PROBE_TIMEOUT="${HTTP_PROBE_TIMEOUT:-5}"
HTTP_STATUS_PATH="${HTTP_STATUS_PATH:-/status}"

ts()   { date -u +%H:%M:%SZ; }
log()  { printf '%s %s: %s\n' "$(ts)" "${PROG}" "$*"; }
fail() { printf '%s %s: FAIL: %s\n' "$(ts)" "${PROG}" "$*" >&2; }

load_conf() {
  if [ -r "${CONF}" ]; then
    log "reading config from ${CONF}"
    # shellcheck disable=SC1090
    . "${CONF}"
  else
    log "no readable ${CONF} — using built-in defaults (reach check skipped if IRL_SERVER_HOST unset)"
  fi
}

# Step 1 — the primary health signal: the app that loads the streaming stack.
check_service_active() {
  if "${SYSTEMCTL_BIN}" is-active --quiet "${CERALIVE_SERVICE}"; then
    log "OK: ${CERALIVE_SERVICE} is active"
    return 0
  fi
  fail "${CERALIVE_SERVICE} is NOT active"
  return 1
}

# Steps 2 & 3 — a streaming binary exists, is executable, and its shared libs
# resolve. We do NOT require a specific exit code (srtla_send has no --version and
# prints usage to stderr); we DO fail on a loader error, which
# is the real "boots but can't encode" signature.
check_binary() {
  local bin="$1"
  local path out rc
  path="$(command -v "${bin}" 2>/dev/null || true)"
  if [ -z "${path}" ] || [ ! -x "${path}" ]; then
    fail "streaming binary '${bin}' is missing or not executable"
    return 1
  fi
  out="$(timeout "${BIN_PROBE_TIMEOUT}" "${path}" --version </dev/null 2>&1)"
  rc=$?
  if [ "${rc}" -eq 124 ]; then
    fail "streaming binary '${path}' hung on probe (timed out after ${BIN_PROBE_TIMEOUT}s)"
    return 1
  fi
  if printf '%s' "${out}" | grep -qiE 'error while loading shared libraries|cannot open shared object'; then
    fail "streaming binary '${path}' cannot load its shared libraries (broken encode stack): ${out}"
    return 1
  fi
  log "OK: streaming binary '${path}' present and loads"
  return 0
}

# True when at least one non-loopback link is administratively up — i.e. there is
# some interface on which an SRT receiver could be reached. A fresh OFFLINE device
# has only `lo`, so this is false and the reach probe is skipped (see below). If
# `ip` is unavailable we conservatively report "no network" and skip rather than
# fail, because the local stack checks still gate mark-good.
network_is_up() {
  command -v "${IP_BIN}" >/dev/null 2>&1 || return 1
  "${IP_BIN}" -o link show up 2>/dev/null | grep -v ' lo:' | grep -q 'state UP'
}

# Step 4 — TCP reach to the SRT/SRTLA port (NOT a full SRT handshake; see header).
check_srt_reach() {
   if [ -z "${IRL_SERVER_HOST:-}" ]; then
     log "SKIP: IRL_SERVER_HOST unset in ${CONF} — cannot test SRT reach; relying on local stack checks"
     return 0
   fi
   if ! network_is_up; then
     log "SKIP: no non-loopback interface up (offline device) — SRT reach not testable; relying on local stack checks"
     return 0
   fi
   local host="${IRL_SERVER_HOST}"
   local port="${IRL_SERVER_SRT_PORT:-9000}"
   if command -v nc >/dev/null 2>&1; then
     if nc -z -w"${SRT_CONNECT_TIMEOUT}" "${host}" "${port}" >/dev/null 2>&1; then
       log "OK: SRT port reachable (tcp ${host}:${port})"
       return 0
     fi
   elif timeout "${SRT_CONNECT_TIMEOUT}" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
     log "OK: SRT port reachable (tcp ${host}:${port} via /dev/tcp)"
     return 0
   fi
   fail "SRT port NOT reachable (tcp ${host}:${port}) — cloud edge unreachable"
   return 1
}

# Step 5 — mDNS self-resolution (non-fatal; warns on failure but does not block mark-good).
# The ceralive-hostname.service establishes Avahi ownership before ceralive.service, so
# by the time this healthcheck runs the system and published hostnames agree. This probe
# verifies that the device can resolve its own .local hostname via mDNS, which is the
# primary discovery mechanism on the LAN. Failure is logged as a WARNING with IP-fallback
# guidance; it does NOT trigger a rollback (mDNS absence on a multicast-blocking network
# must not brick the device).
check_mdns_resolution() {
   local hostname fqdn out rc
   hostname="$(hostname 2>/dev/null || true)"
   if [ -z "${hostname}" ]; then
     printf '%s %s: WARN: cannot read hostname — skipping mDNS check\n' "$(ts)" "${PROG}" >&2
     return 0
   fi
   fqdn="${hostname}.local"
   if ! command -v avahi-resolve-host-name >/dev/null 2>&1; then
     printf '%s %s: WARN: avahi-resolve-host-name not found — mDNS resolution not testable\n' "$(ts)" "${PROG}" >&2
     return 0
   fi
   out="$(timeout 5 avahi-resolve-host-name "${fqdn}" 2>&1)"
   rc=$?
   if [ "${rc}" -eq 0 ]; then
     log "OK: mDNS self-resolution works (${fqdn})"
     return 0
   fi
   printf '%s %s: WARN: mDNS self-resolution failed for %s (rc=%d) — device may not be discoverable by .local hostname on the LAN; if the network blocks multicast, find the device by IP address instead\n' "$(ts)" "${PROG}" "${fqdn}" "${rc}" >&2
   return 0
}

# Step 6 — control-plane reachability over BOTH serving paths (task 15, SC3):
#   :80  — the CeraUI backend, which binds port 80 directly.
#   :443 — the nginx TLS front that terminates HTTPS and proxies to :80.
# NON-FATAL by design, exactly like the mDNS probe: check_service_active already
# gates mark-good on the app being up, and the file header is emphatic that a
# can't-encode slot — not a UI/TLS hiccup — is what must roll a slot back. An nginx
# or cert transient must NOT brick a device whose port-80 backend is otherwise
# healthy (port 80 keeps serving regardless), so a failure here WARNs with guidance
# and returns 0. -k on the 443 probe accepts the per-device self-signed cert (SC3).
check_tls_endpoints() {
   if ! command -v "${CURL_BIN}" >/dev/null 2>&1; then
     printf '%s %s: WARN: %s not found — HTTP(S) control-plane probe skipped\n' "$(ts)" "${PROG}" "${CURL_BIN}" >&2
     return 0
   fi
   local code80 code443
   code80="$("${CURL_BIN}" -s -o /dev/null -w '%{http_code}' --max-time "${HTTP_PROBE_TIMEOUT}" \
              "http://127.0.0.1${HTTP_STATUS_PATH}" 2>/dev/null || echo 000)"
   code443="$("${CURL_BIN}" -ks -o /dev/null -w '%{http_code}' --max-time "${HTTP_PROBE_TIMEOUT}" \
               "https://127.0.0.1${HTTP_STATUS_PATH}" 2>/dev/null || echo 000)"
   if [ "${code80}" = "200" ] && [ "${code443}" = "200" ]; then
     log "OK: control plane reachable on :80 (backend) and :443 (nginx TLS) — both 200"
     return 0
   fi
   printf '%s %s: WARN: control-plane probe non-200 (http :80=%s, https :443=%s) — UI may be degraded; port 80 still serves the backend directly, so this does NOT block mark-good. Check ceralive.service, nginx.service and ceralive-tls-firstboot.service\n' \
     "$(ts)" "${PROG}" "${code80}" "${code443}" >&2
   return 0
}

run_checks() {
   check_service_active   || return 1
   check_binary "${CERASTREAM_BIN}" || return 1
   check_binary "${SRTLA_SEND_BIN}" || return 1
   check_srt_reach        || return 1
   check_mdns_resolution  || return 1
   check_tls_endpoints    || return 1
   return 0
}

mark_good() {
  if ! command -v "${RAUC_BIN}" >/dev/null 2>&1; then
    fail "rauc ('${RAUC_BIN}') not found — cannot mark the slot good"
    return 1
  fi
  log "all health checks passed — calling '${RAUC_BIN} status mark-good'"
  if "${RAUC_BIN}" status mark-good; then
    mkdir -p "$(dirname "${MARKER}")"
    printf 'marked-good %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${MARKER}"
    log "slot marked good; wrote idempotency marker ${MARKER}"
    return 0
  fi
  fail "'${RAUC_BIN} status mark-good' failed — slot left unconfirmed (will roll back)"
  return 1
}

main() {
  load_conf

  if [ -e "${MARKER}" ]; then
    log "marker ${MARKER} present — this slot is already confirmed good; no-op"
    exit 0
  fi

  local now deadline attempt
  now="$(date +%s)"
  deadline=$(( now + HEALTHCHECK_TIMEOUT ))
  attempt=0

  while :; do
    attempt=$(( attempt + 1 ))
    log "streaming healthcheck attempt #${attempt} (deadline in $(( deadline - $(date +%s) ))s)"
    if run_checks; then
      mark_good
      exit $?
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      fail "streaming health NOT reached within ${HEALTHCHECK_TIMEOUT}s — NOT calling mark-good; this slot rolls back on the next reboot"
      exit 1
    fi
    log "retrying in ${HEALTHCHECK_RETRY_INTERVAL}s..."
    sleep "${HEALTHCHECK_RETRY_INTERVAL}"
  done
}

main "$@"
