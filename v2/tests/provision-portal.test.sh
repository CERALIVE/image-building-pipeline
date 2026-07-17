#!/usr/bin/env bash
#
# provision-portal.test.sh — offline proof harness for the first-boot WiFi provisioning
# captive portal (Task 14). Pure static/offline: it stubs nmcli / ip / systemctl /
# systemd-run / timeout / logger in a throwaway PATH and drives the REAL committed
# scripts (ceralive-provision.sh + ceralive-portal.sh) through every provisioning path,
# asserting on the recorded stub calls and the on-disk state.
#
# It proves, without any radio or systemd, the four MAC6 end-state conditions and the
# failure/timeout paths the task requires:
#   (a) AP mode disabled            — ceralive-ap profile deleted
#   (b) device joined target        — nmcli connection up <user-con> attempted + verified
#   (c) portal no longer reachable  — ceralive-portal.socket stopped (port 80 freed)
#   (d) CeraUI reachable on new IP   — ceralive.service (re)started
#   + wrong-passphrase retry path returns to AP mode
#   + hard-timeout path returns to AP mode (never headless-dead)
#
# Run: v2/tests/provision-portal.test.sh   (also gated via tests/manifest.bats)
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$(cd "${HERE}/../mkosi/runtime" && pwd)"
PROVISION="${RUNTIME}/ceralive-provision.sh"
PORTAL="${RUNTIME}/ceralive-portal.sh"

FAILED=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }

# ---- sandbox + stubs ---------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/provision-portal.XXXXXX")"
trap 'rm -rf "${SANDBOX}"' EXIT
BIN="${SANDBOX}/bin"; STATE="${SANDBOX}/state"; DNSDIR="${SANDBOX}/dnsmasq-shared.d"
CALL_LOG="${SANDBOX}/calls.log"; SCAN_SRC="${SANDBOX}/scan-src.txt"
MACHINE_ID="${SANDBOX}/machine-id"
HOSTNAME_FILE="${SANDBOX}/hostname"; HOST_INDEX_FILE="${SANDBOX}/host-index"
mkdir -p "${BIN}" "${STATE}"
printf 'HomeNet\nCafe Wifi\nNeighbour\n' >"${SCAN_SRC}"
printf 'deadbeefcafef00d\n' >"${MACHINE_ID}"

make_stub() { local p="${BIN}/$1"; shift; printf '%s\n' '#!/usr/bin/env bash' "$@" >"${p}"; chmod +x "${p}"; }

# nmcli: records every call; returns programmed data/exit codes. The AP profile ALWAYS
# comes up (so a re-arm during the failure path succeeds); only the USER connection's
# `connection up` exit code is programmable (STUB_USER_UP_RC).
make_stub nmcli \
  'echo "nmcli $*" >>"$CALL_LOG"' \
  'args="$*"' \
  'case "$args" in' \
  '  *"dev wifi list"*) [ -n "${STUB_SCAN_FILE:-}" ] && cat "$STUB_SCAN_FILE"; exit 0 ;;' \
  '  *"-f CONNECTIVITY general status"*) printf "%s\n" "${STUB_CONNECTIVITY:-full}"; exit 0 ;;' \
  '  *"802-11-wireless.ssid connection show"*) printf "%s\n" "${STUB_CON_SSID:-HomeNet}"; exit 0 ;;' \
  '  *"-f NAME,TYPE connection show"*) [ -n "${STUB_PROFILES_FILE:-}" ] && cat "$STUB_PROFILES_FILE"; exit 0 ;;' \
  '  *"connection up"*) case "$args" in *ceralive-ap*) exit 0 ;; *) exit "${STUB_USER_UP_RC:-0}" ;; esac ;;' \
  'esac' \
  'exit 0'

make_stub ip \
  'echo "ip $*" >>"$CALL_LOG"' \
  '[ -n "${STUB_DEFAULT_ROUTE:-}" ] && echo "default via 10.0.0.1"; exit 0'

make_stub systemctl 'echo "systemctl $*" >>"$CALL_LOG"; exit 0'

# systemd-run: records the transient-unit launch but does NOT execute it (--no-block).
make_stub systemd-run 'echo "systemd-run $*" >>"$CALL_LOG"; exit 0'

# timeout: records, then either simulates a hard timeout (STUB_TIMEOUT_RC) or execs the
# wrapped command (dropping the duration arg) so the nmcli stub decides success/failure.
make_stub timeout \
  'echo "timeout $*" >>"$CALL_LOG"' \
  'if [ -n "${STUB_TIMEOUT_RC:-}" ]; then exit "$STUB_TIMEOUT_RC"; fi' \
  'while [ "${1#-}" != "$1" ]; do shift; done' \
  'shift; exec "$@"'

make_stub logger 'exit 0'
make_stub hostname 'printf "%s\n" "${STUB_RUNTIME_HOSTNAME:-factory-seed}"'
make_stub busctl \
  'case "$*" in' \
  '  *GetState) printf '"'"'i %s\n'"'"' "${STUB_AVAHI_STATE:-2}" ;;' \
  '  *GetHostName) printf '"'"'s "%s"\n'"'"' "${STUB_AVAHI_HOSTNAME:-factory-seed}" ;;' \
  '  *) exit 2 ;;' \
  'esac'

export PATH="${BIN}:${PATH}"
export NMCLI="${BIN}/nmcli" IP_BIN="${BIN}/ip" SYSTEMCTL="${BIN}/systemctl"
export SYSTEMD_RUN="${BIN}/systemd-run" TIMEOUT_BIN="${BIN}/timeout"
export CERALIVE_BUSCTL="${BIN}/busctl" CERALIVE_TIMEOUT="${BIN}/timeout"
export CERALIVE_MACHINE_ID_FILE="${MACHINE_ID}"
export CERALIVE_PROVISION_STATE_DIR="${STATE}"
export CERALIVE_DNSMASQ_SHARED_DIR="${DNSDIR}"
export CERALIVE_PROVISION_BIN="${PROVISION}"
export CERALIVE_HOSTNAME_FILE="${HOSTNAME_FILE}"
export CERALIVE_HOSTNAME_INDEX_FILE="${HOST_INDEX_FILE}"
export CERALIVE_HOSTNAME_BIN="${BIN}/hostname"
export CERALIVE_CONNECT_FLUSH_DELAY=0
export CALL_LOG STUB_SCAN_FILE="${SCAN_SRC}"

reset_state() { rm -rf "${STATE}" "${DNSDIR}"; mkdir -p "${STATE}"; : >"${CALL_LOG}"; }
called()     { grep -qF -- "$1" "${CALL_LOG}"; }
state_file() { printf '%s/%s' "${STATE}" "$1"; }

# ===========================================================================
echo "== Scenario A: portal bring-up (port-80 handoff START side) =="
reset_state
: >"$(state_file force-portal)"          # force trigger → skip the 75s grace wait
env STUB_PROFILES_FILE=/dev/null bash "${PROVISION}" start >/dev/null 2>&1
called "nmcli -g SSID dev wifi list"              && pass "scan performed before AP up" || fail "scan performed before AP up"
[ -s "$(state_file scan.txt)" ]                   && pass "scan cached for the portal"   || fail "scan cached for the portal"
[ -f "${DNSDIR}/ceralive-portal.conf" ]           && pass "DNS capture written"          || fail "DNS capture written"
grep -qF 'address=/#/192.168.42.1' "${DNSDIR}/ceralive-portal.conf" && pass "DNS wildcard to gateway" || fail "DNS wildcard to gateway"
called "nmcli connection up ceralive-ap"          && pass "AP profile activated"         || fail "AP profile activated"
called "systemctl stop ceralive.service"          && pass "CeraUI stopped (frees port 80)" || fail "CeraUI stopped (frees port 80)"
called "systemctl start ceralive-portal.socket"   && pass "portal socket started on 80"  || fail "portal socket started on 80"
[ -f "$(state_file portal-active)" ]              && pass "portal-active marker written" || fail "portal-active marker written"

# ===========================================================================
echo "== Scenario B: GET serves the form with scanned SSIDs =="
reset_state
printf 'HomeNet\nCafe Wifi\nNeighbour\n' >"$(state_file scan.txt)"
printf 'ssid=CeraLive-Setup-f00d\ngateway=192.168.42.1\n' >"$(state_file portal-active)"
GET_OUT="$(printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qF '<form method="POST"' <<<"${GET_OUT}"   && pass "serves an HTML form"          || fail "serves an HTML form"
grep -qF 'name="ssid"'         <<<"${GET_OUT}"   && pass "form has an SSID field"        || fail "form has an SSID field"
grep -qF 'name="psk"'          <<<"${GET_OUT}"   && pass "form has a passphrase field"   || fail "form has a passphrase field"
grep -qF '<option value="HomeNet">' <<<"${GET_OUT}" && pass "SSID list populated from scan" || fail "SSID list populated from scan"
grep -qF 'Cafe Wifi'           <<<"${GET_OUT}"   && pass "SSID with a space rendered"    || fail "SSID with a space rendered"
grep -qiF '200 OK'             <<<"${GET_OUT}"   && pass "responds 200 OK"               || fail "responds 200 OK"

# ===========================================================================
echo "== Scenario C: POST writes the NM profile + triggers the detached handoff =="
reset_state
printf 'portal-active' >"$(state_file portal-active)"
printf '2\n' >"${HOST_INDEX_FILE}"
printf 'ceralive2\n' >"${HOSTNAME_FILE}"
export STUB_RUNTIME_HOSTNAME=ceralive2
export STUB_AVAHI_HOSTNAME=ceralive2
POST_OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | bash "${PORTAL}" serve 2>/dev/null)"
called "nmcli connection add type wifi con-name ceralive-wifi" && pass "writes NM profile for the user network" || fail "writes NM profile for the user network"
called "wifi-sec.psk hunter2pass"                && pass "passphrase handed to NM only (not a file)" || fail "passphrase handed to NM only"
called "systemd-run"                             && pass "detached worker launched"     || fail "detached worker launched"
called "ceralive-provision.sh connect ceralive-wifi" && pass "handoff = provision connect <con>" || fail "handoff = provision connect <con>"
grep -qiF 'Connecting' <<<"${POST_OUT}"          && pass "browser gets a connecting page" || fail "browser gets a connecting page"
grep -qF '<b>ceralive2.local</b>' <<<"${POST_OUT}" && pass "connecting page uses the committed collision name" || fail "connecting page uses the committed collision name"
! grep -qF 'selected deterministic address' <<<"${POST_OUT}" && pass "committed collision name does not fall back to deterministic guidance" || fail "committed collision name does not fall back to deterministic guidance"
export STUB_RUNTIME_HOSTNAME=ceralive2
export STUB_AVAHI_HOSTNAME=ceralive-2
STALE_AVAHI_OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qF 'selected deterministic address' <<<"${STALE_AVAHI_OUT}" && pass "stale Avahi publication gets deterministic fallback guidance" || fail "stale Avahi publication gets deterministic fallback guidance"
export STUB_AVAHI_HOSTNAME=ceralive2
export STUB_AVAHI_STATE=1
REGISTERING_AVAHI_OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qF 'selected deterministic address' <<<"${REGISTERING_AVAHI_OUT}" && pass "registering Avahi publication gets deterministic fallback guidance" || fail "registering Avahi publication gets deterministic fallback guidance"
export STUB_AVAHI_STATE=2
export STUB_RUNTIME_HOSTNAME=factory-seed
export STUB_AVAHI_HOSTNAME=ceralive2
UNCOMMITTED_OUT="$(printf 'POST / HTTP/1.1\r\nContent-Length: 28\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\nssid=HomeNet&psk=hunter2pass' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qF 'selected deterministic address' <<<"${UNCOMMITTED_OUT}" && pass "in-flight identity gets deterministic fallback guidance" || fail "in-flight identity gets deterministic fallback guidance"
# credentials must NOT be persisted anywhere but NM (no temp/state file holds the psk)
! grep -rqF 'hunter2pass' "${STATE}" 2>/dev/null && pass "no credential written to /data state" || fail "no credential written to /data state"

# ===========================================================================
echo "== Scenario D: connect SUCCESS -> all four MAC6 conditions =="
reset_state
printf 'portal-active' >"$(state_file portal-active)"
: >"$(state_file force-portal)"
env STUB_USER_UP_RC=0 STUB_CONNECTIVITY=full STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
rc=$?
[ "${rc}" -eq 0 ]                                && pass "connect worker exits 0 on success" || fail "connect worker exits 0 on success"
called "connection up ceralive-wifi"             && pass "(b) joined target network"     || fail "(b) joined target network"
called "nmcli -t -f CONNECTIVITY general status" && pass "(b) join verified by connectivity" || fail "(b) join verified by connectivity"
called "nmcli connection delete ceralive-ap"     && pass "(a) AP profile deleted"        || fail "(a) AP profile deleted"
called "systemctl stop ceralive-portal.socket"   && pass "(c) portal socket stopped (port 80 freed)" || fail "(c) portal socket stopped"
called "systemctl start ceralive.service"        && pass "(d) CeraUI restarted on new IP" || fail "(d) CeraUI restarted on new IP"
! called "nmcli device disconnect wlan0"         && pass "(b) wlan0 NOT dropped (keep_link)" || fail "(b) wlan0 NOT dropped (keep_link)"
[ ! -e "$(state_file portal-active)" ]           && pass "portal-active marker cleared"  || fail "portal-active marker cleared"
[ ! -e "$(state_file force-portal)" ]            && pass "factory-reset flag cleared"    || fail "factory-reset flag cleared"
[ ! -e "${DNSDIR}/ceralive-portal.conf" ]        && pass "DNS capture removed"           || fail "DNS capture removed"

# ===========================================================================
echo "== Scenario E: connect FAILURE (wrong passphrase) -> back to AP mode =="
reset_state
printf 'portal-active' >"$(state_file portal-active)"
env STUB_USER_UP_RC=4 STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
rc=$?
[ "${rc}" -ne 0 ]                                && pass "connect worker exits non-zero on failure" || fail "connect worker exits non-zero on failure"
called "nmcli connection delete ceralive-wifi"   && pass "bad profile deleted"           || fail "bad profile deleted"
[ -f "$(state_file last-error)" ]                && pass "error marker written for the portal" || fail "error marker written for the portal"
grep -qF 'reason=auth_or_timeout' "$(state_file last-error)" && pass "error reason recorded" || fail "error reason recorded"
called "nmcli connection up ceralive-ap"         && pass "AP re-armed for retry"         || fail "AP re-armed for retry"
called "systemctl start ceralive-portal.socket"  && pass "portal restarted for retry"    || fail "portal restarted for retry"
[ -f "${DNSDIR}/ceralive-portal.conf" ]          && pass "DNS capture re-installed"      || fail "DNS capture re-installed"

# ===========================================================================
echo "== Scenario F: form shows the error banner after a failed attempt =="
# (state from Scenario E is intentionally preserved: last-error present)
printf 'HomeNet\n' >"$(state_file scan.txt)"
ERR_OUT="$(printf 'GET / HTTP/1.1\r\n\r\n' | bash "${PORTAL}" serve 2>/dev/null)"
grep -qiF 'Could not join' <<<"${ERR_OUT}"       && pass "error banner shown on retry"   || fail "error banner shown on retry"
grep -qF 'HomeNet'         <<<"${ERR_OUT}"       && pass "failed SSID named in the banner" || fail "failed SSID named in the banner"

# ===========================================================================
echo "== Scenario G: hard timeout during join -> back to AP mode (not headless-dead) =="
reset_state
printf 'portal-active' >"$(state_file portal-active)"
env STUB_TIMEOUT_RC=124 STUB_CON_SSID=HomeNet \
    bash "${PROVISION}" connect ceralive-wifi >/dev/null 2>&1
rc=$?
[ "${rc}" -ne 0 ]                                && pass "timeout -> connect worker fails closed" || fail "timeout -> connect worker fails closed"
called "timeout"                                 && pass "outer hard-timeout guard engaged" || fail "outer hard-timeout guard engaged"
called "nmcli connection up ceralive-ap"         && pass "AP re-armed after timeout"     || fail "AP re-armed after timeout"
called "systemctl start ceralive-portal.socket"  && pass "portal restarted after timeout" || fail "portal restarted after timeout"

# ===========================================================================
echo "== Scenario H: out-of-band teardown verb releases everything =="
reset_state
printf 'portal-active' >"$(state_file portal-active)"
: >"$(state_file teardown-requested)"
bash "${PROVISION}" teardown >/dev/null 2>&1
called "nmcli connection delete ceralive-ap"     && pass "(a) AP profile deleted"        || fail "(a) AP profile deleted"
called "nmcli device disconnect wlan0"           && pass "wlan0 released (no client link)" || fail "wlan0 released (no client link)"
called "systemctl stop ceralive-portal.socket"   && pass "(c) portal stopped"            || fail "(c) portal stopped"
called "systemctl start ceralive.service"        && pass "(d) CeraUI restored"           || fail "(d) CeraUI restored"
[ ! -e "$(state_file portal-active)" ]           && pass "portal-active cleared"         || fail "portal-active cleared"
[ ! -e "$(state_file teardown-requested)" ]      && pass "teardown-requested flag cleared" || fail "teardown-requested flag cleared"

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "RESULT: ALL PASS — captive portal + handoff + 4-condition teardown verified offline"
  exit 0
fi
echo "RESULT: FAILURES above"
exit 1
