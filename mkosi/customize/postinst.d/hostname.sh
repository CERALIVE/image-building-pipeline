#!/usr/bin/env bash
#
# postinst.d/hostname.sh — deterministic first-boot LAN identity.
#
# Sourced by customize/postinst-lib.sh (never executed). Concern: the ONE thing
# an operator needs before anything else works — a predictable name to reach the
# board at. It generates ceralive-set-hostname (the bounded, Avahi-arbitrated
# ceralive / ceralive2 / ceralive3 … claim), its oneshot unit, the reconcile
# service + timer, and the ceralive.service identity drop-in.
#
# This is the ONE module that still embeds its payload as heredocs rather than
# installing a committed artifact from "${CERALIVE_RUNTIME_SRC}". That is
# deliberate and load-bearing for the test suite: tests/real-avahi-hostname-
# contract.sh extracts the claim script straight out of this file and drives it
# against two REAL avahi-daemons in private D-Bus/network namespaces, so the text
# here is the text under test. Do not "modernise" it into a runtime/ artifact
# without moving that harness with it.
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
fi

candidate="$(candidate_for_index "$index")"
if ! publishable_address_present; then
    if ! { [ -e "$INDEX_FILE" ] && local_identity_matches "$candidate"; }; then
        if [[ "$MODE" = reconcile ]]; then
            atomic_write "$RESTART_PENDING_FILE" 0600 "$candidate" \
                || die "failed to persist identity-consumer restart marker"
        fi
        commit_identity "$index" "$candidate" || die "failed to persist provisional hostname identity"
    fi
    if [[ "$MODE" = reconcile && -e "$RESTART_PENDING_FILE" ]]; then
        restart_identity_consumers || die "failed to requeue identity consumers"
        clear_restart_pending || die "failed to clear identity-consumer restart marker"
        printf 'ceralive-set-hostname: completed pending consumer restart for %s.local\n' "$candidate"
    fi
    printf 'ceralive-set-hostname: persisted provisional identity %s.local; no publishable LAN address, deferring publication claim\n' "$candidate"
    exit 0
fi

if [[ "$MODE" = reconcile ]]; then

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
# Start after the daemons exist, but never wait for an uplink. The allocator
# persists a provisional identity and defers publication when the device is offline.
After=systemd-machine-id-commit.service ceralive-migrate-data.service NetworkManager.service avahi-daemon.service
Before=ceralive-tls-firstboot.service ceralive.service
Wants=NetworkManager.service avahi-daemon.service
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
