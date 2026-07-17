#!/bin/bash
#
# ceralive-portal.sh — captive-portal HTTP handler for first-boot WiFi provisioning
# (Task 14, part 2). One instance per TCP connection: systemd's ceralive-portal.socket
# (Accept=yes) passes the connected socket as this process's stdin+stdout (the classic
# inetd model), so the request is read from stdin and the response written to stdout.
#
# WHY this mechanism: the image ships NO busybox httpd / python3 / socat / nc (socat and
# netcat were moved to the debug add-on — see v2/manifests/packages/removed.md), so a
# socket-activated bash handler is the lightest viable HTTP server already present
# (systemd + bash only, zero extra packages). SC2: this is a STANDALONE plain-HTML page,
# NOT a CeraUI frontend integration — no build step, no JS framework.
#
# FLOW:
#   GET  <any path>  → serve the provisioning form. The SSID <datalist> is populated
#                      from the pre-AP scan cache (single radio can't scan in AP mode)
#                      and free-text entry is always allowed. A prior failed attempt is
#                      shown as an error banner (read from the last-error marker).
#   POST /           → validate ssid/passphrase, write the NM profile via nmcli
#                      (credentials go ONLY into NM's /data-backed store — never a file),
#                      answer with a "connecting…" page, then trigger the DETACHED
#                      handoff worker `ceralive-provision connect <con>` via systemd-run
#                      (it must outlive THIS per-connection service, which dies when the
#                      AP — and thus this socket — is torn down).
#
# Credentials are passed to nmcli as quoted argv (no shell string), so there is no
# injection path; nmcli treats the SSID/PSK literally.
#
# shellcheck shell=bash

set -uo pipefail

PROG="ceralive-portal"
log() { logger -t "${PROG}" -- "$*" 2>/dev/null || true; }

# --- config / test seams (overridable for the offline proof harness) ----------
NMCLI="${NMCLI:-nmcli}"
SYSTEMD_RUN="${SYSTEMD_RUN:-systemd-run}"
AP_IFACE="${CERALIVE_AP_IFACE:-wlan0}"
PROVISION_BIN="${CERALIVE_PROVISION_BIN:-/usr/local/sbin/ceralive-provision}"
USER_CON_NAME="${CERALIVE_USER_CON_NAME:-ceralive-wifi}"

STATE_DIR="${CERALIVE_PROVISION_STATE_DIR:-/data/ceralive/provision}"
ACTIVE_FLAG="${CERALIVE_PROVISION_ACTIVE_FLAG:-${STATE_DIR}/portal-active}"
SCAN_CACHE="${CERALIVE_PROVISION_SCAN_CACHE:-${STATE_DIR}/scan.txt}"
ERROR_MARKER="${CERALIVE_PROVISION_ERROR_MARKER:-${STATE_DIR}/last-error}"
HOSTNAME_FILE="${CERALIVE_HOSTNAME_FILE:-/etc/hostname}"
HOST_INDEX_FILE="${CERALIVE_HOSTNAME_INDEX_FILE:-/etc/ceralive/host_index}"
HOSTNAME_BIN="${CERALIVE_HOSTNAME_BIN:-hostname}"
BUSCTL="${CERALIVE_BUSCTL:-busctl}"
TIMEOUT="${CERALIVE_TIMEOUT:-timeout}"

READ_TIMEOUT="${CERALIVE_PORTAL_READ_TIMEOUT:-5}"     # bound a slow/hung client
MAX_BODY="${CERALIVE_PORTAL_MAX_BODY:-4096}"          # cap the POST body read
CONNECT_RUNTIME_MAX="${CERALIVE_CONNECT_RUNTIME_MAX:-120}"  # hard cap on the detached worker

# --- helpers ------------------------------------------------------------------
# HTML-escape untrusted text (scanned SSIDs, submitted values) before echoing it back.
html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "${s}"
}

# Decode application/x-www-form-urlencoded: '+' → space, then %XX → byte.
urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

# Pull one field's raw (still-encoded) value out of an &-joined body.
form_field() {
  local body="$1" key="$2" pair
  local IFS='&'
  for pair in ${body}; do
    case "${pair}" in
      "${key}="*) printf '%s' "${pair#*=}"; return 0 ;;
    esac
  done
  return 0
}

# HTTP/1.0 + Connection: close — no keep-alive ambiguity for a one-shot handler.
send_response() {
  local status="$1" body="$2" len
  len="$(printf '%s' "${body}" | wc -c)"
  printf 'HTTP/1.0 %s\r\n' "${status}"
  printf 'Content-Type: text/html; charset=utf-8\r\n'
  printf 'Content-Length: %s\r\n' "${len}"
  printf 'Cache-Control: no-store\r\n'
  printf 'Connection: close\r\n'
  printf '\r\n'
  printf '%s' "${body}"
}

device_ssid() {
  local s=""
  [ -f "${ACTIVE_FLAG}" ] && s="$(sed -n 's/^ssid=//p' "${ACTIVE_FLAG}" | head -n1)"
  printf '%s' "${s:-CeraLive-Setup}"
}

avahi_publishes() {
  local expected="$1" output signature value extra name line_count
  command -v "${BUSCTL}" >/dev/null 2>&1 || return 1
  command -v "${TIMEOUT}" >/dev/null 2>&1 || return 1
  output="$("${TIMEOUT}" --foreground 3 "${BUSCTL}" --system call \
    org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetState 2>/dev/null)" || return 1
  line_count="$(printf '%s\n' "${output}" | wc -l)" || return 1
  [ "${line_count}" = 1 ] || return 1
  read -r signature value extra <<<"${output}"
  [ "${signature}" = i ] && [ "${value}" = 2 ] && [ -z "${extra:-}" ] || return 1
  output="$("${TIMEOUT}" --foreground 3 "${BUSCTL}" --system call \
    org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetHostName 2>/dev/null)" || return 1
  line_count="$(printf '%s\n' "${output}" | wc -l)" || return 1
  [ "${line_count}" = 1 ] || return 1
  read -r signature value extra <<<"${output}"
  [[ "${signature}" = s && "${value}" = \"*\" && -z "${extra:-}" ]] || return 1
  name="${value#\"}"
  name="${name%\"}"
  [ "${name}" = "${expected}" ]
}

# Return a name only after the persisted claim, hostname file, and runtime
# hostname agree. During an in-flight first-boot claim the portal must not
# advertise the factory seed as though it were the final reachable address.
committed_mdns_name() {
  local index static_name runtime_name expected
  [ -r "${HOST_INDEX_FILE}" ] && [ -r "${HOSTNAME_FILE}" ] || return 1
  index="$(cat -- "${HOST_INDEX_FILE}")" || return 1
  static_name="$(cat -- "${HOSTNAME_FILE}")" || return 1
  runtime_name="$("${HOSTNAME_BIN}" 2>/dev/null)" || return 1
  [[ "${index}" =~ ^[1-9][0-9]*$ ]] && (( index <= 9999 )) || return 1
  if [ "${index}" = 1 ]; then
    expected="ceralive"
  else
    expected="ceralive${index}"
  fi
  [ "${static_name}" = "${expected}" ] && [ "${runtime_name}" = "${expected}" ] || return 1
  avahi_publishes "${expected}" || return 1
  printf '%s.local' "${expected}"
}

# Build <option> rows from the cached scan, HTML-escaped, deduped by the cache writer.
scan_options() {
  local ssid
  [ -f "${SCAN_CACHE}" ] || return 0
  while IFS= read -r ssid; do
    [ -n "${ssid}" ] || continue
    printf '      <option value="%s"></option>\n' "$(html_escape "${ssid}")"
  done <"${SCAN_CACHE}"
}

# Render the error banner from the last-error marker (only after a failed attempt).
error_banner() {
  [ -f "${ERROR_MARKER}" ] || return 0
  local ssid
  ssid="$(sed -n 's/^ssid=//p' "${ERROR_MARKER}" | head -n1)"
  printf '    <div class="err" role="alert">Could not join <b>%s</b>. Check the password and try again.</div>\n' \
    "$(html_escape "${ssid}")"
}

page_head() {
  local title="$1"
  cat <<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>
  :root{color-scheme:light dark}
  body{font-family:system-ui,-apple-system,sans-serif;margin:0;background:#0b1220;color:#e6edf6;
       display:flex;min-height:100vh;align-items:center;justify-content:center}
  .card{width:min(92vw,26rem);background:#121a2b;border:1px solid #243049;border-radius:14px;
        padding:1.5rem 1.4rem;box-shadow:0 10px 40px rgba(0,0,0,.4)}
  h1{font-size:1.15rem;margin:.1rem 0 1rem}
  label{display:block;font-size:.85rem;margin:.9rem 0 .3rem;color:#9fb0c8}
  input{width:100%;box-sizing:border-box;padding:.7rem .8rem;border-radius:9px;border:1px solid #2b3a57;
        background:#0d1526;color:#e6edf6;font-size:1rem}
  button{margin-top:1.2rem;width:100%;padding:.8rem;border:0;border-radius:9px;background:#3b82f6;
         color:#fff;font-size:1rem;font-weight:600;cursor:pointer}
  .muted{color:#7c8aa3;font-size:.78rem;margin-top:1rem;line-height:1.4}
  .err{background:#3a1620;border:1px solid #6b2233;color:#ffd7de;padding:.6rem .75rem;border-radius:9px;
       font-size:.85rem;margin-bottom:.4rem}
</style></head><body><div class="card">
HTML
}

render_form() {
  local dev_ssid; dev_ssid="$(device_ssid)"
  { page_head "Connect CeraLive to WiFi"
    printf '  <h1>Connect %s to WiFi</h1>\n' "$(html_escape "${dev_ssid}")"
    error_banner
    cat <<'HTML'
  <form method="POST" action="/">
    <label for="ssid">Network name (SSID)</label>
    <input id="ssid" name="ssid" list="ssids" autocomplete="off" autocapitalize="off"
           spellcheck="false" required maxlength="32" placeholder="Pick or type a network">
    <datalist id="ssids">
HTML
    scan_options
    cat <<'HTML'
    </datalist>
    <label for="psk">Password</label>
    <input id="psk" name="psk" type="password" autocomplete="off" minlength="8" maxlength="63"
           placeholder="Leave empty for an open network">
    <button type="submit">Connect</button>
  </form>
  <p class="muted">The device will leave this setup hotspot and join your network.
     If the password is wrong, this page reappears so you can retry.</p>
</div></body></html>
HTML
  }
}

render_connecting() {
  local ssid mdns_name destination
  ssid="$(html_escape "$1")"
  mdns_name="$(committed_mdns_name 2>/dev/null || true)"
  if [ -n "${mdns_name}" ]; then
    destination="at <b>$(html_escape "${mdns_name}")</b>"
  else
    destination='using its selected deterministic address: <b>ceralive.local</b>, then <b>ceralive2.local</b>, <b>ceralive3.local</b>, and so on'
  fi
  { page_head "Connecting…"
    printf '  <h1>Connecting to %s…</h1>\n' "${ssid}"
    cat <<'HTML'
  <p class="muted">The CeraLive device is leaving the setup hotspot and joining your
     network now. This hotspot will disappear. If it comes back, the password was
     wrong — reconnect to it and try again. Otherwise the device is online; reach
HTML
    printf '     CeraUI on your network %s.</p>\n' "${destination}"
    cat <<'HTML'
</div></body></html>
HTML
  }
}

render_invalid() {
  local msg; msg="$(html_escape "$1")"
  { page_head "Check your entry"
    printf '    <div class="err" role="alert">%s</div>\n' "${msg}"
    cat <<'HTML'
  <form method="POST" action="/">
    <label for="ssid">Network name (SSID)</label>
    <input id="ssid" name="ssid" list="ssids" autocomplete="off" autocapitalize="off"
           spellcheck="false" required maxlength="32" placeholder="Pick or type a network">
    <datalist id="ssids">
HTML
    scan_options
    cat <<'HTML'
    </datalist>
    <label for="psk">Password</label>
    <input id="psk" name="psk" type="password" autocomplete="off" minlength="8" maxlength="63"
           placeholder="Leave empty for an open network">
    <button type="submit">Connect</button>
  </form>
</div></body></html>
HTML
  }
}

# --- credential handoff -------------------------------------------------------
# Persist the user's network as a NM profile (credentials land ONLY in NM storage).
# Fixed con-name → retries overwrite cleanly; counted by the provision trigger so the
# portal stays down on the next boot once a profile exists (EC4).
write_user_profile() {
  local ssid="$1" psk="$2"
  "${NMCLI}" connection delete "${USER_CON_NAME}" >/dev/null 2>&1 || true
  if [ -n "${psk}" ]; then
    "${NMCLI}" connection add type wifi con-name "${USER_CON_NAME}" ifname "${AP_IFACE}" \
      ssid "${ssid}" autoconnect yes \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "${psk}"
  else
    "${NMCLI}" connection add type wifi con-name "${USER_CON_NAME}" ifname "${AP_IFACE}" \
      ssid "${ssid}" autoconnect yes
  fi
}

# Fire the detached handoff worker in its own transient unit so it survives this
# per-connection service (and the AP) being torn down. RuntimeMaxSec is the hard
# timeout that guarantees a return to AP mode rather than a headless-dead device.
trigger_connect() {
  "${SYSTEMD_RUN}" --no-block --collect \
    --unit=ceralive-provision-connect \
    --property=RuntimeMaxSec="${CONNECT_RUNTIME_MAX}" \
    "${PROVISION_BIN}" connect "${USER_CON_NAME}" >/dev/null 2>&1
}

handle_post() {
  local body="$1" ssid psk
  ssid="$(urldecode "$(form_field "${body}" ssid)")"
  psk="$(urldecode "$(form_field "${body}" psk)")"

  if [ -z "${ssid}" ] || [ "${#ssid}" -gt 32 ]; then
    send_response "200 OK" "$(render_invalid "Enter a network name (1–32 characters).")"
    return 0
  fi
  if [ -n "${psk}" ] && { [ "${#psk}" -lt 8 ] || [ "${#psk}" -gt 63 ]; }; then
    send_response "200 OK" "$(render_invalid "A WPA2 password must be 8–63 characters (or leave it empty for an open network).")"
    return 0
  fi

  if ! write_user_profile "${ssid}" "${psk}"; then
    log "failed to write NM profile for SSID '${ssid}'"
    send_response "200 OK" "$(render_invalid "Could not save the network profile. Please try again.")"
    return 0
  fi

  log "stored NM profile '${USER_CON_NAME}' for SSID '${ssid}'; triggering handoff"
  send_response "200 OK" "$(render_connecting "${ssid}")"
  # Answer first, hand off second — the worker drops the AP that is carrying this socket.
  trigger_connect
}

# --- request loop (single request per connection) -----------------------------
main() {
  local request_line method rest path line content_length=0 body=""

  IFS= read -r -t "${READ_TIMEOUT}" request_line || return 0
  request_line="${request_line%$'\r'}"
  method="${request_line%% *}"
  rest="${request_line#* }"
  path="${rest%% *}"
  : "${path}"   # parsed for completeness; routing is by method (any path serves the form)

  while IFS= read -r -t "${READ_TIMEOUT}" line; do
    line="${line%$'\r'}"
    [ -z "${line}" ] && break
    case "${line}" in
      [Cc]ontent-[Ll]ength:*)
        content_length="${line#*:}"
        content_length="${content_length// /}"
        ;;
    esac
  done
  [[ "${content_length}" =~ ^[0-9]+$ ]] || content_length=0
  if [ "${content_length}" -gt "${MAX_BODY}" ]; then content_length="${MAX_BODY}"; fi

  if [ "${method}" = "POST" ] && [ "${content_length}" -gt 0 ]; then
    IFS= read -r -t "${READ_TIMEOUT}" -N "${content_length}" body || true
  fi

  case "${method}" in
    POST) handle_post "${body}" ;;
    *)    send_response "200 OK" "$(render_form)" ;;   # GET/probe on any path → the form
  esac
  return 0
}

main "$@"
