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

configure_debug_access() {
  local user="${CERALIVE_USER:-ceralive}"
  local mode="${CERALIVE_DEBUG_IMAGE:-0}"
  local hash="${CERALIVE_DEBUG_PASSWORD_HASH:-}"

  case "${mode}" in
    0|1) ;;
    *) die "CERALIVE_DEBUG_IMAGE must be 0 or 1" ;;
  esac
  if [[ -n "${hash}" && "${mode}" != "1" ]]; then
    die "CERALIVE_DEBUG_PASSWORD_HASH requires CERALIVE_DEBUG_IMAGE=1"
  fi
  [[ "${mode}" == "1" ]] || return 0
  [[ -n "${hash}" ]] || die "CERALIVE_DEBUG_IMAGE=1 requires CERALIVE_DEBUG_PASSWORD_HASH"
  [[ "${hash}" == '$'* ]] || die "CERALIVE_DEBUG_PASSWORD_HASH must be an encrypted password hash"
  id -u "${user}" >/dev/null || die "lab debug user '${user}' is absent"

  usermod --password "${hash}" "${user}"
  chage -d -1 "${user}"
  install -Dm 0600 /dev/null /etc/ceralive/debug-image
  log "lab debug image: password access enabled for '${user}'"
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
# is reachable at its selected .local name on ANY network out of the box. Scoped to eth0
# ONLY: bonded SRTLA modems / wlan_bond must never get a competing 169.254 route.
[connection-eth0-llv4]
match-device=interface-name:eth0
ipv4.link-local=3
EOF

  # dns=systemd-resolved above makes NetworkManager DELEGATE DNS to resolved (it
  # forwards DHCP servers over D-Bus, never writing resolv.conf itself). resolved
  # only manages /etc/resolv.conf when it IS the symlink to its stub; on a plain
  # file it reports `resolv.conf mode: foreign` and stands down (safety behavior).
  # This minimal mkosi rootfs never ran resolved's postinst trigger, so it ships
  # resolv.conf as an empty 0-byte regular file — with delegation on and resolved
  # refusing a foreign file, NOTHING populates it and every glibc/getent/curl
  # lookup fails despite a valid lease (confirmed live: `resolvectl status` shows
  # the server + `mode: foreign`, `getent hosts` exits 2, CeraUI logs constant
  # "DNS timeout"). `ln -sf` is force+idempotent — fixes the empty file, a stale
  # link, or an already-correct link, safe on every A/B rebuild.
  #
  # In a containerized mkosi build, mkosi ro-binds the host resolv.conf over this
  # path for networked postinst scripts, making it an un-replaceable mountpoint so
  # a bare `ln -sf` dies EBUSY. Do NOT "fix" that by skipping when busy: mkosi's
  # empty 0-byte placeholder would then bake into the image as the permanent
  # resolv.conf and ship a device with ZERO DNS. Unmount the overlay first (safe:
  # privileged customize chroot), then symlink so it persists into the built image;
  # die loudly rather than degrade. Capture the nameservers mkosi provided and seed
  # resolved's stub so LATER postinst steps that hit the network still resolve
  # (e.g. setup_rtmp_gateway fetches MediaMTX from github) — /run is tmpfs at device
  # boot, so this build-only seed never ships and resolved recreates the stub live.
  local mkosi_nameservers=""
  if mountpoint -q /etc/resolv.conf 2>/dev/null; then
    mkosi_nameservers="$(cat /etc/resolv.conf 2>/dev/null || true)"
    umount /etc/resolv.conf \
      || die "could not unmount the mkosi /etc/resolv.conf bind overlay — refusing to bake an empty resolv.conf that leaves the device with no DNS"
  fi
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  if [[ -n "${mkosi_nameservers}" ]]; then
    mkdir -p /run/systemd/resolve
    printf '%s\n' "${mkosi_nameservers}" >/run/systemd/resolve/stub-resolv.conf
  fi

  install_interface_naming
}

# --- 8b. Deterministic interface naming (eth0/eth1/wlan0 .link units) ------
# RK3588 predictable names (wlP2p33s0, enP4p65s0) never matched SRTLA's wlan*/
# eth* routing globs, so wifi/wired uplinks were silently dropped from bonding.
# These .link units rename onboard NICs to stable roles. Per-role Path= rules
# (keyed on the manifest ID_PATH, stable per board model) are required on OPi 5+
# where the dual r8169 NICs would otherwise race a generic Type=ether match.
#
# PROPAGATION CONTRACT: this runs in the RUNTIME SUBIMAGE chroot, so the
# per-role Path= values reach it ONLY via CERALIVE_INTERFACES_eth0/eth1/wlan0
# in mkosi.conf's PassEnvironment=. orchestrate.sh exporting them to the
# top-level image is NOT enough — --environment populates the MAIN image only.
# If a CERALIVE_INTERFACES_* name is ever dropped from PassEnvironment= (it once
# was), "${!var}" reads EMPTY here and eth0/eth1 get NO .link file (only wlan0
# has a generic Type=wlan fallback), so ethernet keeps its kernel name and falls
# out of SRTLA bonding — silently. mkosi.conf's PassEnvironment= MUST stay in
# lockstep with orchestrate.sh:run_mkosi_build()'s env_names; the guard is
# manifest.bats "mkosi PassEnvironment stays in lockstep with … env_names".
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

install_console_font_service() {
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-console-font.service" ]] \
    || die "console font service source not found: ${src}/ceralive-console-font.service (is \$SRCDIR/runtime mounted?)"

  install -m 0644 "${src}/ceralive-console-font.service" /etc/systemd/system/ceralive-console-font.service
}

# --- 9. Services enable/disable (verbatim from postinst section 9) --------
configure_services() {
  log "enabling/disabling services"
  configure_debug_access
  configure_ntp  # install NTP pools before enabling chrony
  install_console_font_service
  local svc
  for svc in systemd-resolved NetworkManager ModemManager chrony avahi-daemon ceralive-console-font; do
    enable_service "${svc}"
  done
  configure_ssh_enablement
  for svc in bluetooth.service cups.service; do
    disable_service "${svc}"
  done
}

# SSH enablement gated on CERALIVE_DEBUG_IMAGE (Todo 42). The base layer installs
# openssh-server, whose Debian postinst preset ALREADY enables ssh.service — so a
# production image must actively DISABLE it, not merely skip the enable, to truly
# ship disabled-by-default. Debug (=1) keeps the historical enabled-by-default plus
# the predefined debug password (configure_debug_access). CERALIVE_DEBUG_IMAGE is
# validated 0/1 upstream (orchestrate.sh + configure_debug_access), so no re-check.
configure_ssh_enablement() {
  local mode="${CERALIVE_DEBUG_IMAGE:-0}"
  if [[ "${mode}" == "1" ]]; then
    enable_service ssh
    log "lab debug image: ssh.service enabled by default"
  else
    disable_service ssh.service
    disable_service ssh.socket
    log "production image: ssh.service NOT enabled (operator enables via CeraUI)"
  fi
}

# --- 10. First-boot unique-hostname service (verbatim, postinst section 10) -
setup_hostname_service() {
  log "installing first-boot unique-hostname service"
  mkdir -p /etc/ceralive

  cat >/usr/local/sbin/ceralive-set-hostname <<'EOF'
#!/bin/bash
set -euo pipefail
MODE="${1:-allocate}"
BASE_NAME="${CERALIVE_BASE_HOSTNAME:-ceralive}"
STATE_DIR="${CERALIVE_HOSTNAME_STATE_DIR:-/etc/ceralive}"
INDEX_FILE="${STATE_DIR}/host_index"
RESTART_PENDING_FILE="${STATE_DIR}/hostname_consumers_pending"
LOCK_FILE="${CERALIVE_HOSTNAME_LOCK_FILE:-/run/ceralive-hostname/hostname.lock}"
HOSTS_FILE="${CERALIVE_HOSTS_FILE:-/etc/hosts}"
HOSTNAME_FILE="${CERALIVE_HOSTNAME_FILE:-/etc/hostname}"
MACHINE_ID_FILE="${CERALIVE_MACHINE_ID_FILE:-/etc/machine-id}"
HOSTNAMECTL_BIN="${HOSTNAMECTL_BIN:-hostnamectl}"
HOSTNAME_BIN="${HOSTNAME_BIN:-hostname}"
IP_BIN="${IP_BIN:-ip}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"
SYNC_BIN="${SYNC_BIN:-sync}"
AVAHI_SET_HOSTNAME_BIN="${AVAHI_SET_HOSTNAME_BIN:-avahi-set-host-name}"
BUSCTL_BIN="${BUSCTL_BIN:-busctl}"
AVAHI_RESOLVE_BIN="${AVAHI_RESOLVE_BIN:-avahi-resolve}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
AP_IFACE="${CERALIVE_AP_IFACE:-wlan0}"
AP_ADDRESS="${CERALIVE_AP_ADDRESS:-192.168.42.1}"
MAX_INDEX="${CERALIVE_HOSTNAME_MAX_INDEX:-9999}"
MAX_WAIT="${CERALIVE_HOSTNAME_MAX_WAIT:-120}"
MAX_PROBES="${CERALIVE_HOSTNAME_MAX_PROBES:-120}"
POLL_INTERVAL="${CERALIVE_HOSTNAME_POLL_INTERVAL:-1}"
STABLE_CHECKS="${CERALIVE_HOSTNAME_STABLE_CHECKS:-3}"
CALL_TIMEOUT="${CERALIVE_HOSTNAME_CALL_TIMEOUT:-3}"
LOCK_WAIT="${CERALIVE_HOSTNAME_LOCK_WAIT:-10}"
CONTENTION_RETRIES="${CERALIVE_HOSTNAME_CONTENTION_RETRIES:-4}"
CONTENTION_BACKOFF_MAX="${CERALIVE_HOSTNAME_CONTENTION_BACKOFF_MAX:-4}"
CLAIM_CONFLICT=10
CONSUMER_UNITS=(
    ceralive-tls-firstboot.service
    nginx.service
    ceralive.service
    ceralive-hawkbit-provision.service
    ceralive-healthcheck.service
)

die() {
    printf 'ceralive-set-hostname: %s\n' "$*" >&2
    exit 1
}

(( $# <= 1 )) || die "usage: ceralive-set-hostname [allocate|reconcile]"
case "$MODE" in
    allocate | reconcile) ;;
    *) die "usage: ceralive-set-hostname [allocate|reconcile]" ;;
esac

[[ "$BASE_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || die "invalid base hostname: $BASE_NAME"
(( ${#BASE_NAME} <= 59 )) || die "base hostname leaves no room for deterministic numbering"
for value in "$MAX_INDEX" "$MAX_WAIT" "$MAX_PROBES" "$POLL_INTERVAL" \
             "$STABLE_CHECKS" "$CALL_TIMEOUT" "$LOCK_WAIT" \
             "$CONTENTION_RETRIES" "$CONTENTION_BACKOFF_MAX"; do
    [[ "$value" =~ ^[0-9]+$ ]] || die "hostname timing/index values must be unsigned integers"
done
(( MAX_INDEX >= 1 && MAX_INDEX <= 9999 )) || die "hostname max index must be 1..9999"
(( MAX_WAIT >= 1 && MAX_WAIT <= 300 )) || die "hostname max wait must be 1..300 seconds"
(( MAX_PROBES >= 1 && MAX_PROBES <= 600 )) || die "hostname max probes must be 1..600"
(( POLL_INTERVAL <= 10 )) || die "hostname poll interval must be 0..10 seconds"
(( STABLE_CHECKS >= 1 && STABLE_CHECKS <= 10 )) || die "hostname stable checks must be 1..10"
(( CALL_TIMEOUT >= 1 && CALL_TIMEOUT <= 10 )) || die "hostname call timeout must be 1..10 seconds"
(( LOCK_WAIT <= 30 )) || die "hostname lock wait must be 0..30 seconds"
(( CONTENTION_RETRIES >= 1 && CONTENTION_RETRIES <= 10 )) \
    || die "hostname contention retries must be 1..10"
(( CONTENTION_BACKOFF_MAX <= 10 )) || die "hostname contention backoff must be 0..10 seconds"

for command in "$HOSTNAMECTL_BIN" "$HOSTNAME_BIN" "$IP_BIN" "$TIMEOUT_BIN" \
               "$SYNC_BIN" "$AVAHI_SET_HOSTNAME_BIN" "$BUSCTL_BIN" \
               "$AVAHI_RESOLVE_BIN" "$SYSTEMCTL_BIN" cksum flock; do
    command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done

[ -r "$MACHINE_ID_FILE" ] || die "machine-id is not readable"
MACHINE_ID="$(cat -- "$MACHINE_ID_FILE")" || die "cannot read machine-id"
machine_id_lines="$(awk 'END { print NR }' "$MACHINE_ID_FILE")" || die "cannot parse machine-id"
[[ "$machine_id_lines" = 1 && "$MACHINE_ID" =~ ^[0-9a-f]{32}$ ]] \
    || die "machine-id is not a committed 32-digit lowercase hexadecimal ID"

candidate_for_index() {
    local i="$1"
    if [ "$i" = "1" ]; then
        printf '%s\n' "$BASE_NAME"
    else
        printf '%s%s\n' "$BASE_NAME" "$i"
    fi
}

publishable_address_present() {
    "$IP_BIN" -o addr show up 2>/dev/null \
        | awk -v ap_iface="$AP_IFACE" -v ap_address="$AP_ADDRESS" '
            $2 == "lo" { next }
            $3 == "inet" {
                split($4, parts, "/")
                ip = parts[1]
                if (ip ~ /^127\./ || ($2 == ap_iface && ip == ap_address)) next
                found = 1
            }
            $3 == "inet6" {
                split($4, parts, "/")
                ip = tolower(parts[1])
                if (ip == "::1" || ip ~ /^fe80:/) next
                found = 1
            }
            END { exit !found }
        '
}

avahi_call() {
    "$TIMEOUT_BIN" --foreground "$CALL_TIMEOUT" "$BUSCTL_BIN" --system call \
        org.freedesktop.Avahi / org.freedesktop.Avahi.Server "$1"
}

read_avahi_state() {
    local output signature value extra line_count
    output="$(avahi_call GetState 2>/dev/null)" || return 1
    line_count="$(printf '%s\n' "$output" | wc -l)" || return 1
    [ "$line_count" = 1 ] || return 1
    read -r signature value extra <<<"$output"
    [[ "$signature" = i && "$value" =~ ^[0-4]$ && -z "${extra:-}" ]] || return 1
    printf '%s\n' "$value"
}

read_avahi_hostname() {
    local output signature value extra name line_count
    output="$(avahi_call GetHostName 2>/dev/null)" || return 1
    line_count="$(printf '%s\n' "$output" | wc -l)" || return 1
    [ "$line_count" = 1 ] || return 1
    read -r signature value extra <<<"$output"
    [[ "$signature" = s && "$value" = \"*\" && -z "${extra:-}" ]] || return 1
    name="${value#\"}"
    name="${name%\"}"
    [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
    printf '%s\n' "$name"
}

# After=avahi-daemon.service only guarantees the daemon process STARTED, not that
# its D-Bus interface answers yet. Poll GetState until it reports a query-ready
# state (1 REGISTERING or 2 RUNNING) so the first claim call is not issued into a
# cold daemon. Best-effort: bounded by the caller's deadline and never fatal.
wait_for_avahi_ready() {
    local deadline="$1" state
    while (( SECONDS < deadline )); do
        if state="$(read_avahi_state)" && [[ "$state" = 1 || "$state" = 2 ]]; then
            return 0
        fi
        (( POLL_INTERVAL == 0 )) || sleep "$POLL_INTERVAL"
    done
    return 0
}

is_avahi_alternative() {
    local candidate="$1" published="$2" suffix
    [[ "$published" = "$candidate"-* ]] || return 1
    suffix="${published#"$candidate"-}"
    [[ "$suffix" =~ ^[0-9]+$ ]]
}

# Ask Avahi whether <candidate>.local is already owned by a different, live host.
# A forward lookup that resolves to an address which reverse-resolves back to the
# same name is proof another device holds the name (we no longer answer for it
# once Avahi has renamed us away). A miss means the name is unclaimed — the
# hyphenated rename we just saw was a transient simultaneous-probe race, not a
# real owner, so the lower deterministic candidate is still ours to keep.
candidate_has_stable_owner() {
    local candidate="$1" fqdn="$1.local" forward reverse addr back
    forward="$("$TIMEOUT_BIN" --foreground "$CALL_TIMEOUT" \
        "$AVAHI_RESOLVE_BIN" -n "$fqdn" 2>/dev/null)" || return 1
    addr="$(printf '%s\n' "$forward" | awk 'NF >= 2 { print $2; exit }')"
    [ -n "$addr" ] || return 1
    reverse="$("$TIMEOUT_BIN" --foreground "$CALL_TIMEOUT" \
        "$AVAHI_RESOLVE_BIN" -a "$addr" 2>/dev/null)" || return 1
    back="$(printf '%s\n' "$reverse" | awk 'NF >= 2 { print $2; exit }')"
    [ "$back" = "$fqdn" ]
}

claim_candidate() {
    local candidate="$1" deadline="$2"
    local attempt probe state published stable retry

    # Retry the SAME deterministic candidate while Avahi keeps renaming us but no
    # other host actually owns the name (the symmetric double-rename race). Only a
    # proven, live owner advances us to the next deterministic index.
    for ((attempt = 1; attempt <= CONTENTION_RETRIES; attempt++)); do
        (( SECONDS < deadline )) || return 1
        if ! "$TIMEOUT_BIN" --foreground "$CALL_TIMEOUT" \
            "$AVAHI_SET_HOSTNAME_BIN" "$candidate" >/dev/null 2>&1; then
            # avahi returns non-zero (AVAHI_ERR_NO_CHANGE) when it already
            # publishes this EXACT name — the baked /etc/hostname=ceralive makes
            # the first candidate a no-op set. That means we already own it:
            # confirm RUNNING + published==candidate and accept. Any other failure
            # (daemon not query-ready, transient D-Bus) retries the SAME candidate
            # within the deadline instead of aborting or advancing the index.
            if state="$(read_avahi_state)" \
                && published="$(read_avahi_hostname)" \
                && [[ "$state" = 2 && "$published" = "$candidate" ]]; then
                return 0
            fi
            (( attempt < CONTENTION_RETRIES )) || return 1
            (( CONTENTION_BACKOFF_MAX == 0 )) \
                || sleep "$(( (RANDOM % CONTENTION_BACKOFF_MAX) + 1 ))"
            continue
        fi

        stable=0
        retry=0
        for ((probe = 1; probe <= MAX_PROBES; probe++)); do
            (( SECONDS < deadline )) || return 1
            if publishable_address_present \
                && state="$(read_avahi_state)" \
                && published="$(read_avahi_hostname)"; then
                if [[ "$state" = 2 && "$published" = "$candidate" ]]; then
                    stable=$((stable + 1))
                    (( stable >= STABLE_CHECKS )) && return 0
                    (( POLL_INTERVAL == 0 )) || sleep "$POLL_INTERVAL"
                    continue
                fi
                if [[ "$state" = 3 ]] \
                    || { [[ "$state" = 2 ]] && is_avahi_alternative "$candidate" "$published"; }; then
                    if candidate_has_stable_owner "$candidate"; then
                        return "$CLAIM_CONFLICT"
                    fi
                    printf 'ceralive-set-hostname: %s.local has no stable owner; retrying the same deterministic candidate\n' \
                        "$candidate" >&2
                    retry=1
                    break
                fi
                [[ "$state" != 4 ]] || return 1
                stable=0
            else
                stable=0
            fi
            (( POLL_INTERVAL == 0 )) || sleep "$POLL_INTERVAL"
        done
        (( retry == 1 )) || return 1
        (( CONTENTION_BACKOFF_MAX == 0 )) || sleep "$(( (RANDOM % CONTENTION_BACKOFF_MAX) + 1 ))"
    done
    return "$CLAIM_CONFLICT"
}

storage_path() {
    local path="$1" link
    if [ -L "$path" ]; then
        link="$(readlink -- "$path")" || return 1
        case "$link" in
            /*) printf '%s\n' "$link" ;;
            *) printf '%s/%s\n' "$(dirname -- "$path")" "$link" ;;
        esac
    else
        printf '%s\n' "$path"
    fi
}

atomic_write() {
    local path="$1" mode="$2" value="$3" target dir tmp
    target="$(storage_path "$path")" || return 1
    dir="$(dirname -- "$target")"
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.ceralive-hostname.XXXXXX")" || return 1
    if ! printf '%s\n' "$value" >"$tmp" \
        || ! chmod "$mode" "$tmp" \
        || ! "$SYNC_BIN" -f "$tmp" \
        || ! mv -f -- "$tmp" "$target" \
        || ! "$SYNC_BIN" -f "$target" \
        || ! "$SYNC_BIN" -f "$dir"; then
        rm -f -- "$tmp"
        return 1
    fi
}

update_hosts_identity() {
    local name="$1" content
    content="$(awk -v name="$name" '
        BEGIN { replaced = 0 }
        $1 == "127.0.1.1" && !replaced {
            printf "127.0.1.1\t%s\n", name
            replaced = 1
            next
        }
        { print }
        END {
            if (!replaced) {
                printf "127.0.1.1\t%s\n", name
            }
        }
    ' "$HOSTS_FILE")" || return 1
    atomic_write "$HOSTS_FILE" 0644 "$content"
}

commit_identity() {
    local index="$1" name="$2"
    if ! "$HOSTNAMECTL_BIN" set-hostname "$name"; then
        command -v "$HOSTNAME_BIN" >/dev/null 2>&1 || return 1
        "$HOSTNAME_BIN" "$name" || return 1
    fi
    atomic_write "$HOSTNAME_FILE" 0644 "$name" || return 1
    update_hosts_identity "$name" || return 1
    atomic_write "$INDEX_FILE" 0644 "$index"
}

read_runtime_hostname() {
    local output line_count
    output="$("$HOSTNAME_BIN" 2>/dev/null)" || return 1
    line_count="$(printf '%s\n' "$output" | wc -l)" || return 1
    [[ "$line_count" = 1 && "$output" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
    printf '%s\n' "$output"
}

read_static_hostname() {
    local output line_count
    [ -r "$HOSTNAME_FILE" ] || return 1
    output="$(cat -- "$HOSTNAME_FILE")" || return 1
    line_count="$(awk 'END { print NR }' "$HOSTNAME_FILE")" || return 1
    [[ "$line_count" = 1 && "$output" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
    printf '%s\n' "$output"
}

hosts_identity_matches() {
    local expected="$1"
    awk -v expected="$expected" '
        $1 == "127.0.1.1" {
            count++
            if (NF != 2 || $2 != expected) bad = 1
        }
        END { exit !(count == 1 && !bad) }
    ' "$HOSTS_FILE"
}

local_identity_matches() {
    local expected="$1" runtime static
    runtime="$(read_runtime_hostname)" || return 1
    static="$(read_static_hostname)" || return 1
    [[ "$runtime" = "$expected" && "$static" = "$expected" ]] || return 1
    hosts_identity_matches "$expected"
}

restart_identity_consumers() {
    "$SYSTEMCTL_BIN" --no-block restart "${CONSUMER_UNITS[@]}"
}

clear_restart_pending() {
    local target dir
    target="$(storage_path "$RESTART_PENDING_FILE")" || return 1
    dir="$(dirname -- "$target")"
    rm -f -- "$target" || return 1
    "$SYNC_BIN" -f "$dir"
}

mkdir -p "$STATE_DIR"
mkdir -p "$(dirname -- "$LOCK_FILE")"
chmod 0700 "$(dirname -- "$LOCK_FILE")"
[ ! -L "$LOCK_FILE" ] || die "hostname lock path must not be a symlink"
exec 9>"$LOCK_FILE"
flock -w "$LOCK_WAIT" 9 || die "timed out waiting for local hostname allocation lock"
chmod 0600 "$LOCK_FILE"

index=1
if [ -e "$INDEX_FILE" ]; then
    persisted="$(cat "$INDEX_FILE")" || die "cannot read persisted hostname index"
    if [[ ! "$persisted" =~ ^[1-9][0-9]*$ ]] || (( persisted > MAX_INDEX )); then
        die "invalid persisted hostname index"
    fi
    index="$persisted"
fi

if [[ "$MODE" = reconcile ]]; then
    [ -e "$INDEX_FILE" ] || die "persisted hostname index is missing during reconciliation"
    candidate="$(candidate_for_index "$index")"

    if ! publishable_address_present; then
        if local_identity_matches "$candidate"; then
            if [ -e "$RESTART_PENDING_FILE" ]; then
                restart_identity_consumers || die "failed to requeue identity consumers"
                clear_restart_pending || die "failed to clear identity-consumer restart marker"
                printf 'ceralive-set-hostname: completed pending consumer restart for %s.local\n' "$candidate"
            fi
            printf 'ceralive-set-hostname: no publishable LAN address; deferring publication reconciliation\n'
            exit 0
        fi
        die "local identity diverged while no publishable LAN address is available"
    fi

    state="$(read_avahi_state)" \
        && published="$(read_avahi_hostname)" \
        || die "cannot read a strict Avahi publication snapshot"
    if local_identity_matches "$candidate"; then
        if [[ "$state" = 2 && "$published" = "$candidate" ]]; then
            if [ -e "$RESTART_PENDING_FILE" ]; then
                restart_identity_consumers || die "failed to requeue identity consumers"
                clear_restart_pending || die "failed to clear identity-consumer restart marker"
                printf 'ceralive-set-hostname: completed pending consumer restart for %s.local\n' "$candidate"
            fi
            printf 'ceralive-set-hostname: identity already aligned at %s.local\n' "$candidate"
            exit 0
        fi
        if [[ "$state" = 1 ]]; then
            printf 'ceralive-set-hostname: publication is still registering; deferring reconciliation\n'
            exit 0
        fi
    fi
    [[ "$state" != 0 && "$state" != 4 ]] \
        || die "Avahi is not able to establish hostname ownership (state $state)"
    [[ "$state" != 1 ]] \
        || die "local identity diverged while Avahi is still registering"
    printf 'ceralive-set-hostname: publication diverged (expected=%s state=%s published=%s); reclaiming deterministically\n' \
        "$candidate" "$state" "$published" >&2
fi

deadline=$((SECONDS + MAX_WAIT))
wait_for_avahi_ready "$deadline"
while (( index <= MAX_INDEX )); do
    candidate="$(candidate_for_index "$index")"
    if claim_candidate "$candidate" "$deadline"; then
        if [[ "$MODE" = reconcile ]]; then
            atomic_write "$RESTART_PENDING_FILE" 0600 "$candidate" \
                || die "failed to persist identity-consumer restart marker"
        fi
        commit_identity "$index" "$candidate" || die "failed to persist hostname identity"
        if [[ "$MODE" = reconcile ]]; then
            restart_identity_consumers || die "failed to requeue identity consumers"
            clear_restart_pending || die "failed to clear identity-consumer restart marker"
            printf 'ceralive-set-hostname: reconciled and established %s.local\n' "$candidate"
        else
            printf 'ceralive-set-hostname: established %s.local\n' "$candidate"
        fi
        exit 0
    else
        rc=$?
    fi
    if [[ "$rc" = "$CLAIM_CONFLICT" ]]; then
        printf 'ceralive-set-hostname: %s.local conflicted; trying next deterministic candidate\n' "$candidate" >&2
        index=$((index + 1))
        continue
    fi
    die "could not establish Avahi ownership of ${candidate}.local within the bounded wait"
done
die "no deterministic hostname available through index $MAX_INDEX"
EOF
  chmod +x /usr/local/sbin/ceralive-set-hostname

  cat >/etc/systemd/system/ceralive-hostname.service <<'EOF'
[Unit]
Description=CeraLive unique hostname setup
Requires=ceralive-migrate-data.service
RequiresMountsFor=/data
# network-online.target (link actually up), NOT just NetworkManager.service (daemon
# up): the mDNS claim cannot succeed before an interface links. On real Rock 5B+ HW
# this unit ran at ~15s and failed by ~15.8s while eth0 linked only at 18.89s, so it
# failed-closed and every Requires= consumer cascaded to "Dependency failed" — a dead
# appliance on first boot. Its sibling network units already wait for this target.
After=systemd-machine-id-commit.service ceralive-migrate-data.service NetworkManager.service network-online.target avahi-daemon.service
Before=ceralive-tls-firstboot.service ceralive.service
Wants=NetworkManager.service network-online.target avahi-daemon.service
ConditionPathExists=/etc/machine-id
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
RuntimeDirectory=ceralive-hostname
RuntimeDirectoryMode=0700
ExecStart=/usr/local/sbin/ceralive-set-hostname
ExecStartPost=/usr/bin/systemctl --no-block start ceralive.service
ExecStartPost=/usr/bin/systemctl --no-block restart ceralive-tls-firstboot.service nginx.service ceralive-hawkbit-provision.service ceralive-healthcheck.service
TimeoutStartSec=150
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable ceralive-hostname.service

  cat >/etc/systemd/system/ceralive-hostname-reconcile.service <<'EOF'
[Unit]
Description=Reconcile CeraLive hostname with the active Avahi publication
Requires=ceralive-hostname.service
After=ceralive-hostname.service NetworkManager.service avahi-daemon.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ceralive-set-hostname reconcile
TimeoutStartSec=150
EOF

  cat >/etc/systemd/system/ceralive-hostname-reconcile.timer <<'EOF'
[Unit]
Description=Detect CeraLive Avahi hostname publication conflicts

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=1s
Unit=ceralive-hostname-reconcile.service

[Install]
WantedBy=timers.target
EOF
  systemctl enable ceralive-hostname-reconcile.timer

  mkdir -p /etc/systemd/system/ceralive.service.d
  # Wants=, not Requires=: a failed unique-hostname claim must NOT take the
  # product down. ceralive.service still boots on the baked default hostname
  # (degraded-but-functional), After= keeps the claim ordered first when it can
  # run, and ceralive-hostname.service's own Restart=on-failure + the reconcile
  # timer keep retrying — ExecStartPost then restarts consumers once it succeeds.
  cat >/etc/systemd/system/ceralive.service.d/05-hostname-identity.conf <<'EOF'
[Unit]
Wants=ceralive-hostname.service
After=ceralive-hostname.service
EOF
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
# artifacts ceralive-ssh-firstboot.{sh,service} and the opt-in, one-shot UART
# bootstrap (single source of truth under
# v2/mkosi/runtime/) instead of inlining them in the runtime postinst — keeps
# postinst.chroot under the 950-line drift ceiling. Mirrors setup_boot_healthcheck.
# Scope is LOCKED to host-key regeneration, PermitRootLogin prohibit-password,
# once-only `chage -d 0 ceralive`, persistent authorized-key stores, and the
# boot-scoped UART CI key guard; see the script header. CERALIVE_RUNTIME_SRC must
# point at the runtime/ source dir.
# ---------------------------------------------------------------------------
setup_ssh_firstboot() {
  log "installing first-boot SSH hardening and one-shot UART CI bootstrap"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-ssh-firstboot.sh" ]] \
    || die "ssh-firstboot source not found: ${src}/ceralive-ssh-firstboot.sh (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-ci-uart-bootstrap.sh" && -f "${src}/ceralive-ci-uart-bootstrap.service" && \
     -f "${src}/ceralive-ci-uart-bootstrap-public.pem" ]] \
    || die "UART bootstrap source not found under ${src}"
  mkdir -p /usr/local/sbin
  install -m 0755 "${src}/ceralive-ssh-firstboot.sh" /usr/local/sbin/ceralive-ssh-firstboot
  install -m 0644 "${src}/ceralive-ssh-firstboot.service" /etc/systemd/system/ceralive-ssh-firstboot.service
  install -m 0755 "${src}/ceralive-ci-uart-bootstrap.sh" /usr/local/sbin/ceralive-ci-uart-bootstrap
  install -m 0644 "${src}/ceralive-ci-uart-bootstrap.service" /etc/systemd/system/ceralive-ci-uart-bootstrap.service
  [[ "${CERALIVE_IMAGE_BUILD_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] \
    || die "CERALIVE_IMAGE_BUILD_COMMIT is not an exact commit SHA"
  install -d -m 0755 /etc/ceralive
  install -m 0444 "${src}/ceralive-ci-uart-bootstrap-public.pem" /etc/ceralive/uart-bootstrap-public.pem
  printf '%s\n' "${CERALIVE_IMAGE_BUILD_COMMIT}" >/etc/ceralive/image-build-commit
  chmod 0444 /etc/ceralive/image-build-commit
  enable_service ceralive-ssh-firstboot.service
  enable_service ceralive-ci-uart-bootstrap.service
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

# ---------------------------------------------------------------------------
# PASETO device-token verification key (ADR-0006 D2): bake the PUBLIC Ed25519
# key into the CeraUI backend runtime env so the device can VERIFY device-control
# / relay-config tokens. CeraUI reads it from the PASETO_PUBLIC_KEY env var
# (apps/backend device-token.ts DEVICE_TOKEN_PUBLIC_KEY_ENV); its PRESENCE gates
# real verification — absent → CeraUI runs the MVP opaque-token path, so a
# key-less dev/local build still boots. The value arrives base64-wrapped in
# $PASETO_PUBLIC_KEY_B64 (orchestrator-forwarded), exactly like $ADDON_KEYRING_B64;
# the decoded payload is the raw-32-byte Ed25519 PUBLIC key in standard base64
# (cert-work/paseto/gen-keys.sh -> paseto.public.raw.b64), the form CeraUI's
# importEd25519PublicKey() consumes. It is written as an ADDITIVE drop-in on the
# ceralive.service unit shipped by the CeraUI .deb (like 10-data-persistence).
# PUBLIC ONLY — a k4.secret / PEM private key here would let a compromised device
# FORGE tokens, so the build FAILS if any private material slipped in.
# PASETO_DROPIN_DIR overrides the drop-in directory for the offline unit test.
# ---------------------------------------------------------------------------
setup_paseto_public_key() {
  local dropin_dir="${PASETO_DROPIN_DIR:-/etc/systemd/system/ceralive.service.d}"
  local dropin="${dropin_dir}/20-paseto-public-key.conf"

  if [[ -z "${PASETO_PUBLIC_KEY_B64:-}" ]]; then
    log "no PASETO public key in env — skipping device-token key provisioning (CeraUI runs the MVP opaque-token path until a key is baked in)"
    return 0
  fi

  local key
  key="$(printf '%s' "${PASETO_PUBLIC_KEY_B64}" | base64 -d | tr -d '\r\n')"
  [[ -n "${key}" ]] || die "PASETO_PUBLIC_KEY_B64 decoded to empty — refusing to bake an unusable key"

  case "${key}" in
    *k4.secret*) die "PASETO_PUBLIC_KEY_B64 carries a k4.secret PRIVATE key — provision the PUBLIC key (k4.public / raw-base64) only" ;;
  esac
  if printf '%s' "${key}" | grep -aq 'PRIVATE KEY'; then
    die "PASETO_PUBLIC_KEY_B64 carries PEM PRIVATE KEY material — provision the PUBLIC key only"
  fi

  log "provisioning PASETO_PUBLIC_KEY into the CeraUI backend runtime env (device-token verification, public key)"
  mkdir -p "${dropin_dir}"
  cat >"${dropin}" <<EOF
[Service]
Environment=PASETO_PUBLIC_KEY=${key}
EOF
  chmod 0644 "${dropin}"
}

# ---------------------------------------------------------------------------
# avahi-daemon restart hardening (defense-in-depth mDNS reliability): stock Debian's
# avahi-daemon.service ships NO Restart= directive, so ANY signal or crash leaves
# avahi-daemon — and therefore <hostname>.local mDNS — permanently dead until the
# next reboot. Confirmed live on real hardware: the daemon was killed by SIGUSR2
# (status=12/USR2 -> result 'signal'), with NRestarts=0 (no restart policy active).
# Operators reach the device by <hostname>.local (docs/FIRST-BOOT.md + the
# deterministic first-boot unique-hostname service), so bake an ADDITIVE drop-in
# that makes systemd auto-restart the daemon after any non-clean exit. The signal
# SOURCE (a CeraUI udev rule's overly-broad pkill) is fixed separately in the CeraUI
# repo (root cause); this is the systemd-level defense-in-depth against ANY future
# cause. Installed from the committed standalone artifact under CERALIVE_RUNTIME_SRC
# (like setup_tls_proxy's nginx drop-in), never inlined here.
# AVAHI_DROPIN_DIR overrides the drop-in directory for the offline unit test.
# ---------------------------------------------------------------------------
setup_avahi_restart() {
  log "hardening avahi-daemon restart policy (additive Restart=on-failure drop-in for mDNS reliability)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/avahi-daemon-restart.dropin.conf" ]] \
    || die "avahi-restart source not found: ${src}/avahi-daemon-restart.dropin.conf (is \$SRCDIR/runtime mounted?)"
  local dropin_dir="${AVAHI_DROPIN_DIR:-/etc/systemd/system/avahi-daemon.service.d}"
  mkdir -p "${dropin_dir}"
  install -m 0644 "${src}/avahi-daemon-restart.dropin.conf" "${dropin_dir}/10-ceralive-restart.conf"
}

# ---------------------------------------------------------------------------
# ceralive.service -> cerastream.service boot ordering (soft hint, defense against a
# real boot race): ceralive.service's initPipelines() boot step connects to
# cerastream's control socket exactly once, so if cerastream isn't up yet the
# connection fails permanently for that boot. Confirmed live: cerastream.service
# started ~2 minutes AFTER ceralive.service in one boot instance, and
# `systemctl show ceralive -p After` had NO mention of cerastream.service. Bake an
# ADDITIVE drop-in on the ceralive.service unit (shipped by the CeraUI .deb, like
# 10-data-persistence / 20-paseto-public-key) that adds After=cerastream.service.
# ORDERING-ONLY — never Requires=: ceralive.service must still boot into its
# "engine unavailable" degraded state (CeraUI helpers/boot-guard.ts::guardNonCritical)
# if cerastream is genuinely absent/masked, and After= on an out-of-transaction unit
# is a harmless no-op. Installed from the committed standalone artifact under
# CERALIVE_RUNTIME_SRC (like setup_avahi_restart / setup_tls_proxy), never inlined.
# CERASTREAM_ORDERING_DROPIN_DIR overrides the drop-in directory for the offline unit test.
# ---------------------------------------------------------------------------
setup_cerastream_ordering() {
  log "ordering ceralive.service after cerastream.service (additive After= boot-ordering drop-in; no hard dependency)"
  local src="${CERALIVE_RUNTIME_SRC:-}"
  [[ -n "${src}" && -f "${src}/ceralive-cerastream-ordering.dropin.conf" ]] \
    || die "cerastream-ordering source not found: ${src}/ceralive-cerastream-ordering.dropin.conf (is \$SRCDIR/runtime mounted?)"
  local dropin_dir="${CERASTREAM_ORDERING_DROPIN_DIR:-/etc/systemd/system/ceralive.service.d}"
  mkdir -p "${dropin_dir}"
  install -m 0644 "${src}/ceralive-cerastream-ordering.dropin.conf" "${dropin_dir}/30-cerastream-ordering.conf"
}

# ---------------------------------------------------------------------------
# RTMP ingest gateway (Todo 14): bake the PINNED MediaMTX relay.
#
# Build-time FETCH of a pinned MediaMTX release (declarative pin: rtmp-gateway/
# mediamtx.recipe.conf) for the TARGET architecture, verified against a per-arch
# sha256 pin — the build FAILS CLOSED on any checksum mismatch. Stages the single
# static binary to /usr/local/bin/mediamtx, the committed RTMP-only config to
# /etc/mediamtx.yml, and the unit to
# /etc/systemd/system/ceralive-rtmp-gateway.service, then enables it.
#
# The relay is a SINGLE-PURPOSE LAN ingest: it accepts a publish at path
# `publish/live` over RTMP (:1935) OR SRT (:4001) and serves that SAME path on
# loopback so cerastream can pull it — `rtmpsrc rtmp://127.0.0.1/publish/live` or
# `srt://127.0.0.1:4001?streamid=read:publish/live` (app=publish, stream=live —
# HARDCODED in cerastream crates/cerastream-core/src/sources/spec.rs). Every other
# MediaMTX protocol (RTSP/HLS/WebRTC/MoQ/API/metrics/pprof/playback) is disabled in
# mediamtx.yml. MediaMTX's built-in SRT server terminates the SRT leg directly
# (Todo 14 B2): cerastream pulls the SRT read stream on loopback, exactly as it
# pulls RTMP — one MediaMTX process owns both ingest protocols.
#
# Runs INSIDE the target-arch chroot, so `dpkg --print-architecture` yields the
# image arch and curl/tar/sha256sum are present (shared.list: curl + ca-certificates
# + coreutils tar/sha256sum). Network is available — same as the apt install step.
#
# CERALIVE_RUNTIME_SRC must point at the runtime/ source dir. Test seams:
#   MEDIAMTX_RECIPE        — override recipe path (default rtmp-gateway/mediamtx.recipe.conf)
#   MEDIAMTX_ARCH          — override detected target arch (default dpkg --print-architecture)
#   MEDIAMTX_LOCAL_TARBALL — use a local tarball instead of fetching (offline verify)
#   MEDIAMTX_DESTROOT      — install-path prefix (default empty = real /usr,/etc; tests use a tmpdir)
# ---------------------------------------------------------------------------
setup_rtmp_gateway() {
  log "installing RTMP ingest gateway (ceralive-rtmp-gateway.service — pinned MediaMTX LAN publish/live relay)"
  local src="${CERALIVE_RUNTIME_SRC:-}/rtmp-gateway"
  local recipe="${MEDIAMTX_RECIPE:-${src}/mediamtx.recipe.conf}"
  [[ -n "${CERALIVE_RUNTIME_SRC:-}" && -f "${recipe}" ]] \
    || die "rtmp-gateway recipe not found: ${recipe} (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/mediamtx.yml" ]] \
    || die "rtmp-gateway config not found: ${src}/mediamtx.yml"
  [[ -f "${src}/ceralive-rtmp-gateway.service" ]] \
    || die "rtmp-gateway unit not found: ${src}/ceralive-rtmp-gateway.service"

  # Load the declarative PIN (KEY=value only).
  local MEDIAMTX_VERSION="" MEDIAMTX_URL_TEMPLATE=""
  # shellcheck source=/dev/null
  source "${recipe}"
  [[ -n "${MEDIAMTX_VERSION}" ]]      || die "${recipe}: MEDIAMTX_VERSION is required"
  [[ -n "${MEDIAMTX_URL_TEMPLATE}" ]] || die "${recipe}: MEDIAMTX_URL_TEMPLATE is required"

  # Target architecture — the chroot IS the image arch.
  local arch="${MEDIAMTX_ARCH:-}"
  if [[ -z "${arch}" ]]; then
    command -v dpkg >/dev/null 2>&1 || die "dpkg not found — cannot resolve target architecture for MediaMTX fetch"
    arch="$(dpkg --print-architecture)"
  fi
  case "${arch}" in
    amd64 | arm64) ;;
    *) die "unsupported architecture for MediaMTX: '${arch}' (recipe pins amd64 + arm64 only)" ;;
  esac

  # Resolve the per-arch sha256 pin (indirect expansion of MEDIAMTX_SHA256_<arch>).
  local sha_var="MEDIAMTX_SHA256_${arch}"
  local expected="${!sha_var:-}"
  [[ -n "${expected}" ]] || die "${recipe}: missing ${sha_var} pin for arch '${arch}'"

  local tmpdir
  tmpdir="$(mktemp -d)"
  local tarball="${tmpdir}/mediamtx.tar.gz"

  # Fetch the pinned tarball (or use a local one for offline verification).
  if [[ -n "${MEDIAMTX_LOCAL_TARBALL:-}" ]]; then
    [[ -f "${MEDIAMTX_LOCAL_TARBALL}" ]] \
      || { rm -rf "${tmpdir}"; die "MEDIAMTX_LOCAL_TARBALL not a file: ${MEDIAMTX_LOCAL_TARBALL}"; }
    cp "${MEDIAMTX_LOCAL_TARBALL}" "${tarball}"
  else
    command -v curl >/dev/null 2>&1 || { rm -rf "${tmpdir}"; die "curl not found — cannot fetch MediaMTX"; }
    local url="${MEDIAMTX_URL_TEMPLATE//\{ver\}/${MEDIAMTX_VERSION}}"
    url="${url//\{arch\}/${arch}}"
    log "fetching MediaMTX ${MEDIAMTX_VERSION} (${arch}) from ${url}"
    curl -fsSL --retry 3 -o "${tarball}" "${url}" \
      || { rm -rf "${tmpdir}"; die "MediaMTX fetch failed: ${url}"; }
  fi

  # FAIL CLOSED on checksum mismatch — this is the pin gate.
  local actual
  actual="$(sha256sum "${tarball}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    rm -rf "${tmpdir}"
    die "MediaMTX ${MEDIAMTX_VERSION} (${arch}) sha256 MISMATCH — build fails closed. expected=${expected} actual=${actual}"
  fi
  log "MediaMTX ${MEDIAMTX_VERSION} (${arch}) sha256 verified: ${actual}"

  # Extract only the static binary from the verified tarball.
  tar -xzf "${tarball}" -C "${tmpdir}" mediamtx \
    || { rm -rf "${tmpdir}"; die "MediaMTX tarball missing 'mediamtx' binary member"; }

  # Stage binary + config + unit. install -D creates parents; DESTROOT is empty in
  # production (absolute /usr,/etc) and a tmpdir in the offline self-test.
  local destroot="${MEDIAMTX_DESTROOT:-}"
  install -D -m 0755 "${tmpdir}/mediamtx" "${destroot}/usr/local/bin/mediamtx"
  install -D -m 0644 "${src}/mediamtx.yml" "${destroot}/etc/mediamtx.yml"
  install -D -m 0644 "${src}/ceralive-rtmp-gateway.service" "${destroot}/etc/systemd/system/ceralive-rtmp-gateway.service"
  rm -rf "${tmpdir}"

  enable_service ceralive-rtmp-gateway.service
}

# ---------------------------------------------------------------------------
# LAN-ingest ingress firewall (Todo 14/15 INGRESS BOUNDARY): the security half
# of the ingest gateway above. Stages the committed nftables ruleset +
# oneshot unit under v2/mkosi/runtime/ingest-firewall/ (single source of truth,
# Task-6 pattern) and enables the unit.
#
# The single MediaMTX gateway accepts an UNAUTHENTICATED publish on BOTH its RTMP
# (:1935) and SRT (:4001) listeners in v1 (no RTMP password, no SRT passphrase —
# DEFERRED.md items 7 & 8), which is only safe on the LAN. The ruleset DROPS both
# ports on the WAN/modem/WWAN/ppp uplink classes (usb*/enx*/ww*/ppp* — the SAME
# classes the SRTLA dispatcher in §6 uses), so the anonymous ingest is reachable
# from LAN/hotspot ONLY. `nft` is provided by the `nftables` package (shared.list);
# this function only stages + enables. CERALIVE_RUNTIME_SRC must point at the
# runtime/ source dir.
# ---------------------------------------------------------------------------
setup_ingest_firewall() {
  log "installing LAN-ingest ingress firewall (ceralive-ingest-firewall.service — drop :1935/:4001 on WAN/modem uplinks; LAN/hotspot only)"
  local src="${CERALIVE_RUNTIME_SRC:-}/ingest-firewall"
  [[ -n "${CERALIVE_RUNTIME_SRC:-}" && -f "${src}/ingest-firewall.nft" ]] \
    || die "ingest-firewall ruleset not found: ${src}/ingest-firewall.nft (is \$SRCDIR/runtime mounted?)"
  [[ -f "${src}/ceralive-ingest-firewall.service" ]] \
    || die "ingest-firewall unit not found: ${src}/ceralive-ingest-firewall.service"

  install -D -m 0644 "${src}/ingest-firewall.nft" /etc/ceralive/ingest-firewall.nft
  install -m 0644 "${src}/ceralive-ingest-firewall.service" /etc/systemd/system/ceralive-ingest-firewall.service

  enable_service ceralive-ingest-firewall.service
}
