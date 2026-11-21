#!/usr/bin/env bash
#
# Privileged, hardware-free integration contract for deterministic CeraLive
# hostnames. Two real avahi-daemon instances run behind private system D-Bus
# sockets in isolated network namespaces. The production allocator is extracted
# verbatim from postinst-lib.sh; only hostname/systemctl/file paths are test seams.
#
# The contract proves both races that mocks cannot model:
#   1. simultaneous first boots on one multicast domain settle as ceralive and
#      ceralive2 even though Avahi's native conflict name is ceralive-2;
#   2. two isolated ceralive devices later joined to one LAN are reconciled, and
#      every identity consumer is restarted only on the device whose name moved.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
POSTINST_ENTRY="${PIPELINE_DIR}/mkosi/customize/postinst-lib.sh"
POSTINST_D="${PIPELINE_DIR}/mkosi/customize/postinst.d"
TAG="$(printf '%06x' "$((BASHPID % 16777215))")"

declare -a NETNS_NAMES=()
declare -a AVAHI_PGIDS=()
declare -a DBUS_PGIDS=()
declare -A OBSERVER_PIDS=()
declare -A OBSERVER_DRAINS=()
declare -A PAIR_A_NS=()
declare -A PAIR_B_NS=()
declare -A PAIR_SW_NS=()

private_group_live() {
  local pgid="$1"
  [[ "$pgid" =~ ^[1-9][0-9]*$ ]] \
    && sudo -n pgrep -g "$pgid" -f -- "$TMP" >/dev/null 2>&1
}

fail() {
  printf 'real-avahi-hostname: FAIL: %s\n' "$*" >&2
  return 1
}

cleanup() {
  local original_rc=$?
  local cleanup_rc=0
  trap - EXIT INT TERM
  set +e

  local pgid ns root
  for root in "${!OBSERVER_PIDS[@]}"; do
    end_avahi_observer "$root"
  done
  for pgid in "${AVAHI_PGIDS[@]}"; do
    if private_group_live "$pgid"; then
      sudo -n kill -TERM -- "-$pgid" 2>/dev/null || true
    fi
  done
  for pgid in "${DBUS_PGIDS[@]}"; do
    if private_group_live "$pgid"; then
      kill -TERM -- "-$pgid" 2>/dev/null || true
    fi
  done
  sleep 0.2
  for pgid in "${AVAHI_PGIDS[@]}"; do
    if private_group_live "$pgid"; then
      sudo -n kill -KILL -- "-$pgid" 2>/dev/null || true
    fi
  done
  for pgid in "${DBUS_PGIDS[@]}"; do
    if private_group_live "$pgid"; then
      kill -KILL -- "-$pgid" 2>/dev/null || true
    fi
  done

  for ns in "${NETNS_NAMES[@]}"; do
    sudo -n ip netns delete "$ns" 2>/dev/null || true
  done

  for ns in "${NETNS_NAMES[@]}"; do
    if sudo -n ip netns list | awk '{print $1}' | grep -Fxc "$ns" >/dev/null; then
      printf 'real-avahi-hostname: cleanup left namespace %s\n' "$ns" >&2
      cleanup_rc=1
    fi
  done
  if pgrep -af -- "$TMP" >/dev/null 2>&1; then
    printf 'real-avahi-hostname: cleanup left a process referencing %s\n' "$TMP" >&2
    pgrep -af -- "$TMP" >&2 || true
    cleanup_rc=1
  fi
  sudo -n rm -rf -- "$TMP" || cleanup_rc=1

  if (( original_rc == 0 && cleanup_rc == 0 )); then
    printf 'CLEANUP=PASS namespaces=0 private-processes=0\n'
    exit 0
  fi
  (( original_rc != 0 )) && exit "$original_rc"
  exit "$cleanup_rc"
}
# postinst-lib.sh is a thin entry that sources the per-concern modules under
# postinst.d/; the claim script is a heredoc inside one of them. Extract from the
# WHOLE set so this harness keeps driving the SHIPPED script rather than silently
# extracting nothing when the heredoc moves between modules.
extract_hostname_script() {
  local postinst_src
  postinst_src="$(cat "$POSTINST_ENTRY" "$POSTINST_D"/*.sh)"
  awk '
    /cat >\/usr\/local\/sbin\/ceralive-set-hostname <<'\''EOF'\''/ { in_script = 1; next }
    in_script && /^EOF$/ { exit }
    in_script { print }
  ' <<<"$postinst_src"
}

create_pair() {
  local label="$1" subnet="$2" connected="$3"
  local ns_a="cl${TAG}${label}a"
  local ns_b="cl${TAG}${label}b"
  local ns_sw="cl${TAG}${label}s"
  local host_a="v${TAG}${label}a"
  local host_b="v${TAG}${label}b"

  NETNS_NAMES+=("$ns_a" "$ns_b" "$ns_sw")
  sudo -n ip netns add "$ns_a"
  sudo -n ip netns add "$ns_b"
  sudo -n ip netns add "$ns_sw"

  sudo -n ip link add "$host_a" type veth peer name peer-a
  sudo -n ip link set "$host_a" netns "$ns_a"
  sudo -n ip link set peer-a netns "$ns_sw"
  sudo -n ip link add "$host_b" type veth peer name peer-b
  sudo -n ip link set "$host_b" netns "$ns_b"
  sudo -n ip link set peer-b netns "$ns_sw"

  sudo -n ip netns exec "$ns_a" ip link set lo up
  sudo -n ip netns exec "$ns_a" ip link set "$host_a" name eth0
  sudo -n ip netns exec "$ns_a" ip addr add "10.245.${subnet}.2/24" dev eth0
  sudo -n ip netns exec "$ns_a" ip link set eth0 up
  sudo -n ip netns exec "$ns_b" ip link set lo up
  sudo -n ip netns exec "$ns_b" ip link set "$host_b" name eth0
  sudo -n ip netns exec "$ns_b" ip addr add "10.245.${subnet}.3/24" dev eth0
  sudo -n ip netns exec "$ns_b" ip link set eth0 up
  sudo -n ip netns exec "$ns_sw" ip link set lo up
  sudo -n ip netns exec "$ns_sw" ip link set peer-a up
  sudo -n ip netns exec "$ns_sw" ip link set peer-b up

  PAIR_A_NS["$label"]="$ns_a"
  PAIR_B_NS["$label"]="$ns_b"
  PAIR_SW_NS["$label"]="$ns_sw"
  if [[ "$connected" = yes ]]; then
    connect_pair "$ns_sw"
  fi
}

connect_pair() {
  local ns_sw="$1"
  sudo -n ip netns exec "$ns_sw" ip link add br0 type bridge stp_state 0 forward_delay 0
  sudo -n ip netns exec "$ns_sw" ip link set br0 up
  sudo -n ip netns exec "$ns_sw" ip link set peer-a master br0
  sudo -n ip netns exec "$ns_sw" ip link set peer-b master br0
}

write_device_wrappers() (
  umask 077
  local root="$1"
  local bin="$root/bin"
  mkdir -p "$bin"

  cat >"$bin/hostnamectl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" = set-hostname && -n "${2:-}" ]] || exit 2
printf 'hostnamectl set-hostname %s\n' "$2" >>"$REAL_CALL_LOG"
printf '%s\n' "$2" >"$REAL_SYSTEM_HOSTNAME"
SH
  cat >"$bin/hostname" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if (( $# == 0 )); then
  cat "$REAL_SYSTEM_HOSTNAME"
else
  printf 'hostname %s\n' "$1" >>"$REAL_CALL_LOG"
  printf '%s\n' "$1" >"$REAL_SYSTEM_HOSTNAME"
fi
SH
  cat >"$bin/ip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -s "$REAL_DEVICE_ROOT/set-hostname.log" ]]; then
  read -r probes <"$REAL_DEVICE_ROOT/probes"
  printf '%s\n' "$((probes + 1))" >"$REAL_DEVICE_ROOT/probes"
fi
exec "$REAL_SUDO" -n /usr/bin/ip netns exec "$REAL_NETNS" /usr/bin/ip "$@"
SH
  cat >"$bin/busctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
if [[ "${args[0]:-}" = --system ]]; then
  args=("${args[@]:1}")
fi
exec "$REAL_BUSCTL" --address="unix:path=$REAL_AVAHI_BUS" "${args[@]}"
SH
  cat >"$bin/avahi-resolve" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec sudo -n env DBUS_SYSTEM_BUS_ADDRESS="unix:path=${REAL_AVAHI_BUS}" \
  /usr/bin/avahi-resolve "$@"
SH
  cat >"$bin/avahi-set-host-name" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
name="${1:?missing host name}"
printf 'avahi-set-host-name %s\n' "$name" >>"$REAL_CALL_LOG"
if [[ "$name" = ceralive && -n "${REAL_START_BARRIER:-}" ]]; then
  : >"${REAL_START_BARRIER}.${REAL_DEVICE_ID}"
  deadline=$((SECONDS + 10))
  until [[ -e "${REAL_START_BARRIER}.a" && -e "${REAL_START_BARRIER}.b" ]]; do
    (( SECONDS < deadline )) || { echo "barrier timeout" >&2; exit 1; }
    sleep 0.02
  done
fi
exec "$REAL_SUDO" -n env DBUS_SYSTEM_BUS_ADDRESS="unix:path=${REAL_AVAHI_BUS}" \
  /usr/bin/avahi-set-host-name "$name"
SH
  cat >"$bin/timeout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${3:-}" = "$REAL_DEVICE_ROOT/bin/avahi-set-host-name" ]] || exec /usr/bin/timeout "$@"
started="$EPOCHREALTIME"
rc=0
/usr/bin/timeout "$@" || rc=$?
printf 'AVAHI_SET_HOSTNAME device=%s at=%s name=%s rc=%s started=%s\n' \
  "$REAL_DEVICE_ID" "$EPOCHREALTIME" "$4" "$rc" "$started" >>"$REAL_DEVICE_ROOT/set-hostname.log"
exit "$rc"
SH
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >>"$REAL_CALL_LOG"
SH
  chmod +x "$bin"/*
)

start_device() {
  local root="$1" ns="$2" seed="$3"
  mkdir -p "$root/run" "$root/state"
  printf '127.0.0.1\tlocalhost\n' >"$root/hosts"
  printf 'factory-seed\n' >"$root/hostname"
  printf 'factory-seed\n' >"$root/system-hostname"
  : >"$root/calls"
  extract_hostname_script >"$root/ceralive-set-hostname"
  chmod +x "$root/ceralive-set-hostname"
  write_device_wrappers "$root"

  cat >"$root/avahi.conf" <<EOF
[server]
host-name=${seed}
use-ipv4=yes
use-ipv6=no
allow-interfaces=eth0
use-iff-running=yes
enable-dbus=yes
disallow-other-stacks=no

[wide-area]
enable-wide-area=no

[publish]
publish-addresses=yes
publish-hinfo=no
publish-workstation=no
EOF

  setsid dbus-daemon --system --nofork --nopidfile \
    --address="unix:path=$root/bus" >"$root/dbus.log" 2>&1 &
  local dbus_pgid=$!
  DBUS_PGIDS+=("$dbus_pgid")
  printf '%s\n' "$dbus_pgid" >"$root/dbus.pgid"
  for _ in $(seq 1 100); do
    [[ -S "$root/bus" ]] && break
    kill -0 "$dbus_pgid" 2>/dev/null || break
    sleep 0.05
  done
  [[ -S "$root/bus" ]] || {
    cat "$root/dbus.log" >&2
    fail "private D-Bus did not create $root/bus"
  }

  setsid sudo -n env RUN_DIR="$root/run" CONF="$root/avahi.conf" \
    DBUS_SYSTEM_BUS_ADDRESS="unix:path=$root/bus" \
    /usr/bin/ip netns exec "$ns" unshare --mount --propagation private \
    bash -c 'mount --bind "$RUN_DIR" /run/avahi-daemon; exec avahi-daemon --no-drop-root --no-chroot --no-rlimits --debug -f "$CONF"' \
    >"$root/avahi.log" 2>&1 &
  local avahi_pgid=$!
  AVAHI_PGIDS+=("$avahi_pgid")
  printf '%s\n' "$avahi_pgid" >"$root/avahi.pgid"

  local state=""
  for _ in $(seq 1 150); do
    state="$(busctl --address="unix:path=$root/bus" call \
      org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetState 2>/dev/null || true)"
    [[ "$state" = 'i 2' ]] && break
    sleep 0.1
  done
  [[ "$state" = 'i 2' ]] || {
    tail -n 80 "$root/avahi.log" >&2 || true
    fail "avahi-daemon did not reach RUNNING for $root (last state: ${state:-none})"
  }
}

stop_device() {
  local root="$1" avahi_pgid dbus_pgid
  avahi_pgid="$(cat "$root/avahi.pgid")"
  dbus_pgid="$(cat "$root/dbus.pgid")"
  private_group_live "$avahi_pgid" \
    && sudo -n kill -TERM -- "-$avahi_pgid" 2>/dev/null || true
  private_group_live "$dbus_pgid" \
    && kill -TERM -- "-$dbus_pgid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    if ! kill -0 "$avahi_pgid" 2>/dev/null && ! kill -0 "$dbus_pgid" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  private_group_live "$avahi_pgid" \
    && sudo -n kill -KILL -- "-$avahi_pgid" 2>/dev/null || true
  private_group_live "$dbus_pgid" \
    && kill -KILL -- "-$dbus_pgid" 2>/dev/null || true
}

end_avahi_observer() {
  local root="$1" observer_pid="${OBSERVER_PIDS[$1]:-}" drain_pid="${OBSERVER_DRAINS[$1]:-}"
  [[ -n "$observer_pid" ]] || return 0
  kill -TERM "$observer_pid" 2>/dev/null || true
  wait "$observer_pid" 2>/dev/null || true
  if [[ -n "$drain_pid" ]]; then
    wait "$drain_pid" || true
  fi
  unset 'OBSERVER_PIDS[$root]' 'OBSERVER_DRAINS[$root]'
}

start_avahi_observer() {
  local root="$1" fd line remaining last=""
  local deadline=$((SECONDS + 5))
  # busctl prints its readiness line only after BecomeMonitor is acknowledged.
  exec {fd}< <(exec timeout -k 1s 165s "$fixture_sudo" -n env LC_ALL=C SYSTEMD_LOG_COLOR=0 \
    "$fixture_busctl" --no-pager --address="unix:path=$root/bus" \
    --match="type='signal',sender='org.freedesktop.Avahi',path='/',interface='org.freedesktop.Avahi.Server',member='StateChanged'" \
    --match="type='signal',sender='org.freedesktop.DBus',path='/org/freedesktop/DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.freedesktop.Avahi'" \
    monitor 2>&1)
  OBSERVER_PIDS["$root"]=$!
  while (( (remaining = deadline - SECONDS) > 0 )) && IFS= read -r -t "$remaining" line <&"$fd"; do
    last="$line"
    if [[ "$line" = 'Monitoring bus message stream.' ]]; then
      # Drain continuously; retain only the last few lines on this private bus.
      awk '{ lines[NR % 48] = substr($0, 1, 512) }
           END { for (i = NR > 48 ? NR - 47 : 1; i <= NR; i++) print lines[i % 48] }' \
        <&"$fd" >"$root/observer.log" &
      OBSERVER_DRAINS["$root"]=$!
      exec {fd}<&-
      return 0
    fi
  done
  exec {fd}<&-
  printf '%s\n' "${last:0:512}" >"$root/observer.log"
  return 1
}

report_avahi_failure() {
  local root="$1" device_id="$2" subscribed="$3" state name probes source
  state="$(timeout 2s "$fixture_busctl" --address="unix:path=$root/bus" call \
    org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetState 2>/dev/null)" || state=unavailable
  name="$(timeout 2s "$fixture_busctl" --address="unix:path=$root/bus" call \
    org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetHostName 2>/dev/null)" || name=unavailable
  read -r probes <"$root/probes"
  tail -n 12 "$root/set-hostname.log"
  printf 'AVAHI_FINAL device=%s probes=%s state=%s name=%s at=%s\n' \
    "$device_id" "$probes" "${state#i }" "${name#s }" "$EPOCHREALTIME"
  printf 'AVAHI_OBSERVER device=%s subscribed=%s\n' "$device_id" "$subscribed"
  for source in observer.log avahi.log dbus.log; do
    printf 'AVAHI_LOG device=%s source=%s\n' "$device_id" "$source"
    tail -n 48 "$root/$source" | cut -c1-512
  done
}

prepare_allocator() (
  umask 077
  local root="$1"
  install -m 0600 /dev/null "$root/probes"
  install -m 0600 /dev/null "$root/set-hostname.log"
  install -m 0600 /dev/null "$root/observer.log"
  printf '0\n' >"$root/probes"
)

observe_allocator() {
  local root="$1" device_id="$2"
  prepare_allocator "$root"
  if ! start_avahi_observer "$root"; then
    end_avahi_observer "$root"
    printf 'AVAHI_OBSERVER_ERROR device=%s reason=subscription-not-acknowledged\n' "$device_id" >&2
    report_avahi_failure "$root" "$device_id" 0
    return 1
  fi
}

collect_allocator() {
  local root="$1" device_id="$2" pid="$3" rc=0 subscribed=0
  wait "$pid" || rc=$?
  [[ -z "${OBSERVER_DRAINS[$root]:-}" ]] || subscribed=1
  end_avahi_observer "$root"
  if (( rc != 0 )); then
    report_avahi_failure "$root" "$device_id" "$subscribed"
  fi
  return "$rc"
}

run_allocator() (
  umask 077
  local root="$1" ns="$2" device_id="$3" mode="${4:-}" barrier="${5:-}"
  # The child inherits the parent's acknowledged observers at launch. A
  # later subscription in the parent cannot satisfy this check.
  [[ -n "${OBSERVER_DRAINS[$root]:-}" ]] || {
    printf 'AVAHI_ALLOCATION_ERROR device=%s reason=observer-not-ready-at-launch\n' "$device_id" >&2
    return 1
  }
  local -a args=()
  [[ -z "$mode" ]] || args+=("$mode")
  # Use the shipped shared deadline and per-attempt probe cap (both default
  # to 120). Either can still win: a probe includes I/O and polling time.
  "$fixture_sudo" -n env -u CERALIVE_HOSTNAME_MAX_WAIT -u CERALIVE_HOSTNAME_MAX_PROBES \
    REAL_DEVICE_ROOT="$root" REAL_SUDO="$fixture_sudo" REAL_BUSCTL="$fixture_busctl" \
    REAL_CALL_LOG="$root/calls" \
    REAL_SYSTEM_HOSTNAME="$root/system-hostname" \
    REAL_NETNS="$ns" \
    REAL_AVAHI_BUS="$root/bus" \
    REAL_DEVICE_ID="$device_id" \
    REAL_START_BARRIER="$barrier" \
    CERALIVE_HOSTNAME_STATE_DIR="$root/state" \
    CERALIVE_HOSTNAME_LOCK_FILE="$root/run/hostname.lock" \
    CERALIVE_HOSTS_FILE="$root/hosts" \
    CERALIVE_HOSTNAME_FILE="$root/hostname" \
    CERALIVE_MACHINE_ID_FILE="${REAL_MACHINE_ID_FILE:-/etc/machine-id}" \
    HOSTNAMECTL_BIN="$root/bin/hostnamectl" \
    HOSTNAME_BIN="$root/bin/hostname" \
    IP_BIN="$root/bin/ip" \
    TIMEOUT_BIN="$root/bin/timeout" \
    SYNC_BIN=/usr/bin/sync \
    AVAHI_SET_HOSTNAME_BIN="$root/bin/avahi-set-host-name" \
    BUSCTL_BIN="$root/bin/busctl" \
    AVAHI_RESOLVE_BIN="$root/bin/avahi-resolve" \
    SYSTEMCTL_BIN="$root/bin/systemctl" \
    CERALIVE_HOSTNAME_MAX_INDEX=8 \
    CERALIVE_HOSTNAME_POLL_INTERVAL="${REAL_POLL_INTERVAL:-1}" \
    CERALIVE_HOSTNAME_STABLE_CHECKS=2 \
    CERALIVE_HOSTNAME_CALL_TIMEOUT=2 \
    CERALIVE_HOSTNAME_LOCK_WAIT=5 \
    bash "$root/ceralive-set-hostname" "${args[@]}"
)

avahi_state() {
  local root="$1"
  busctl --address="unix:path=$root/bus" call \
    org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetState
}

avahi_name() {
  local root="$1" output
  output="$(busctl --address="unix:path=$root/bus" call \
    org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetHostName)"
  if [[ "$output" =~ ^s\ \"([a-z0-9-]+)\"$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  fail "unexpected GetHostName response for $root: $output"
}

expected_for_index() {
  local index="$1"
  if [[ "$index" = 1 ]]; then
    printf 'ceralive\n'
  else
    printf 'ceralive%s\n' "$index"
  fi
}

assert_device_aligned() {
  local root="$1" index expected runtime static hosts published
  index="$(cat "$root/state/host_index")"
  [[ "$index" =~ ^[1-9][0-9]*$ ]] || fail "invalid persisted index for $root: $index"
  expected="$(expected_for_index "$index")"
  runtime="$(cat "$root/system-hostname")"
  static="$(cat "$root/hostname")"
  hosts="$(awk '$1 == "127.0.1.1" {print $2}' "$root/hosts")"
  published="$(avahi_name "$root")"
  [[ "$runtime" = "$expected" ]] || fail "$root runtime=$runtime expected=$expected"
  [[ "$static" = "$expected" ]] || fail "$root hostname-file=$static expected=$expected"
  [[ "$hosts" = "$expected" ]] || fail "$root hosts=$hosts expected=$expected"
  [[ "$published" = "$expected" ]] || fail "$root published=$published expected=$expected"
  [[ "$published" != *-* ]] || fail "$root retained forbidden Avahi suffix: $published"
  [[ "$(avahi_state "$root")" = 'i 2' ]] || fail "$root Avahi is not RUNNING"
  printf 'ALIGN device=%s index=%s runtime=%s hostname_file=%s hosts=%s published=%s\n' \
    "$(basename "$root")" "$index" "$runtime" "$static" "$hosts" "$published"
}

assert_pair_names() {
  local root_a="$1" root_b="$2" actual
  assert_device_aligned "$root_a"
  assert_device_aligned "$root_b"
  actual="$(printf '%s\n%s\n' "$(avahi_name "$root_a")" "$(avahi_name "$root_b")" | sort | paste -sd, -)"
  [[ "$actual" = 'ceralive,ceralive2' ]] || fail "pair published unexpected set: $actual"
  printf 'PUBLISHED_SET=%s\n' "$actual"
}

wait_for_pair() {
  local pid_a="$1" pid_b="$2" label="$3" root_a="$4" root_b="$5" rc_a=0 rc_b=0
  collect_allocator "$root_a" a "$pid_a" || rc_a=$?
  collect_allocator "$root_b" b "$pid_b" || rc_b=$?
  printf '%s_RC device-a=%s device-b=%s\n' "$label" "$rc_a" "$rc_b"
  WAIT_PAIR_OK=0
  (( rc_a == 0 && rc_b == 0 )) && WAIT_PAIR_OK=1
  return 0
}

# Offline regression cases source the fixture, not its privileged entrypoint.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
umask 077
# D-Bus rejects socket paths over 99 bytes, including the device suffix.
TMP="$(mktemp -d /var/tmp/ceralive-real-avahi.XXXXXX)"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command in awk avahi-daemon avahi-set-host-name busctl dbus-daemon flock ip \
               pgrep setsid sudo timeout unshare; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done
sudo -n true 2>/dev/null || fail "passwordless sudo is required for network namespaces"
[[ -r "$POSTINST_ENTRY" ]] || fail "postinst library not found: $POSTINST_ENTRY"
[[ -d "$POSTINST_D" ]] || fail "postinst module dir not found: $POSTINST_D"
printf 'REAL_AVAHI_CONTRACT=START tmp=%s\n' "$TMP"
fixture_sudo=sudo
fixture_busctl=/usr/bin/busctl

create_pair c 1 yes
CONCURRENT_A="$TMP/concurrent/device-a"
CONCURRENT_B="$TMP/concurrent/device-b"
start_device "$CONCURRENT_A" "${PAIR_A_NS[c]}" seed-ca
start_device "$CONCURRENT_B" "${PAIR_B_NS[c]}" seed-cb
observe_allocator "$CONCURRENT_A" a
observe_allocator "$CONCURRENT_B" b
barrier="$TMP/concurrent/start"
run_allocator "$CONCURRENT_A" "${PAIR_A_NS[c]}" a "" "$barrier" \
  >"$TMP/concurrent/device-a.out" 2>&1 & pid_a=$!
run_allocator "$CONCURRENT_B" "${PAIR_B_NS[c]}" b "" "$barrier" \
  >"$TMP/concurrent/device-b.out" 2>&1 & pid_b=$!
wait_for_pair "$pid_a" "$pid_b" CONCURRENT "$CONCURRENT_A" "$CONCURRENT_B"
sed 's/^/CONCURRENT_A: /' "$TMP/concurrent/device-a.out"
sed 's/^/CONCURRENT_B: /' "$TMP/concurrent/device-b.out"
(( WAIT_PAIR_OK == 1 )) || fail "CONCURRENT allocator failed"
assert_pair_names "$CONCURRENT_A" "$CONCURRENT_B"
printf 'CONCURRENT=PASS exact=ceralive,ceralive2\n'
stop_device "$CONCURRENT_A"
stop_device "$CONCURRENT_B"

# Baked-hostname (AVAHI_ERR_NO_CHANGE) regression against REAL avahi. A lone
# first boot whose daemon already publishes the baked name `ceralive` (seed
# below): avahi-set-host-name ceralive returns NO_CHANGE (exit 1). The fixed
# allocator must accept "we already own it" and commit, not die and cascade
# DEPEND failures (real Rock 5B+ regression, 2026-07-19). The prior seeds never
# equalled the first candidate, so this exact path was a CI blind spot.
create_pair p 3 no
PREOWNED_A="$TMP/preowned/device-a"
start_device "$PREOWNED_A" "${PAIR_A_NS[p]}" ceralive
observe_allocator "$PREOWNED_A" a
run_allocator "$PREOWNED_A" "${PAIR_A_NS[p]}" a >"$TMP/preowned/device-a.out" 2>&1 & pid_a=$!
preowned_rc=0
collect_allocator "$PREOWNED_A" a "$pid_a" || preowned_rc=$?
sed 's/^/PREOWNED_A: /' "$TMP/preowned/device-a.out"
(( preowned_rc == 0 )) \
  || fail "PREOWNED allocator failed — baked-hostname NO_CHANGE not accepted as ownership"
[[ "$(avahi_name "$PREOWNED_A")" = ceralive ]] || fail "preowned device did not retain ceralive"
assert_device_aligned "$PREOWNED_A"
printf 'PREOWNED=PASS device-a=ceralive (NO_CHANGE accepted as ownership)\n'
stop_device "$PREOWNED_A"

create_pair m 2 no
MERGE_A="$TMP/late-merge/device-a"
MERGE_B="$TMP/late-merge/device-b"
start_device "$MERGE_A" "${PAIR_A_NS[m]}" seed-ma
start_device "$MERGE_B" "${PAIR_B_NS[m]}" seed-mb
observe_allocator "$MERGE_A" a
observe_allocator "$MERGE_B" b
run_allocator "$MERGE_A" "${PAIR_A_NS[m]}" a >"$TMP/late-merge/device-a.boot.out" 2>&1 & pid_a=$!
run_allocator "$MERGE_B" "${PAIR_B_NS[m]}" b >"$TMP/late-merge/device-b.boot.out" 2>&1 & pid_b=$!
wait_for_pair "$pid_a" "$pid_b" ISOLATED_BOOT "$MERGE_A" "$MERGE_B"
if (( WAIT_PAIR_OK != 1 )); then
  sed 's/^/ISOLATED_A: /' "$TMP/late-merge/device-a.boot.out"
  sed 's/^/ISOLATED_B: /' "$TMP/late-merge/device-b.boot.out"
  fail "ISOLATED_BOOT allocator failed"
fi
[[ "$(avahi_name "$MERGE_A")" = ceralive ]] || fail "isolated device A did not claim ceralive"
[[ "$(avahi_name "$MERGE_B")" = ceralive ]] || fail "isolated device B did not claim ceralive"
printf 'ISOLATED_BOOT=PASS device-a=ceralive device-b=ceralive\n'

connect_pair "${PAIR_SW_NS[m]}"
pre_a=""; pre_b=""; last_pair=""; stable_pair=0
for _ in $(seq 1 300); do
  pre_a="$(avahi_name "$MERGE_A" 2>/dev/null || true)"
  pre_b="$(avahi_name "$MERGE_B" 2>/dev/null || true)"
  current_pair="${pre_a},${pre_b}"
  if [[ "$pre_a" =~ ^ceralive(-[0-9]+)?$ \
        && "$pre_b" =~ ^ceralive(-[0-9]+)?$ \
        && "$pre_a" != "$pre_b" \
        && "$current_pair" = *-* \
        && "$(avahi_state "$MERGE_A" 2>/dev/null || true)" = 'i 2' \
        && "$(avahi_state "$MERGE_B" 2>/dev/null || true)" = 'i 2' ]]; then
    if [[ "$current_pair" = "$last_pair" ]]; then
      stable_pair=$((stable_pair + 1))
    else
      stable_pair=1
      last_pair="$current_pair"
    fi
    (( stable_pair >= 10 )) && break
  else
    stable_pair=0
    last_pair=""
  fi
  sleep 0.1
done
(( stable_pair >= 10 )) \
  || fail "real Avahi did not expose a stable late-merge conflict (a=$pre_a b=$pre_b)"
printf 'LATE_MERGE_CONFLICT=OBSERVED device-a=%s device-b=%s\n' "$pre_a" "$pre_b"
expected_restarts=0
[[ "$pre_a" = ceralive ]] || expected_restarts=$((expected_restarts + 1))
[[ "$pre_b" = ceralive ]] || expected_restarts=$((expected_restarts + 1))

: >"$MERGE_A/calls"
: >"$MERGE_B/calls"
observe_allocator "$MERGE_A" a
observe_allocator "$MERGE_B" b
run_allocator "$MERGE_A" "${PAIR_A_NS[m]}" a reconcile \
  >"$TMP/late-merge/device-a.reconcile.out" 2>&1 & pid_a=$!
run_allocator "$MERGE_B" "${PAIR_B_NS[m]}" b reconcile \
  >"$TMP/late-merge/device-b.reconcile.out" 2>&1 & pid_b=$!
wait_for_pair "$pid_a" "$pid_b" RECONCILE "$MERGE_A" "$MERGE_B"
sed 's/^/RECONCILE_A: /' "$TMP/late-merge/device-a.reconcile.out"
sed 's/^/RECONCILE_B: /' "$TMP/late-merge/device-b.reconcile.out"
(( WAIT_PAIR_OK == 1 )) || fail "RECONCILE allocator failed"
assert_pair_names "$MERGE_A" "$MERGE_B"

restart_line='systemctl --no-block restart ceralive-tls-firstboot.service nginx.service ceralive.service ceralive-hawkbit-provision.service ceralive-healthcheck.service'
restart_count="$(awk -v expected="$restart_line" '$0 == expected { count++ } END { print count + 0 }' \
  "$MERGE_A/calls" "$MERGE_B/calls")"
[[ "$restart_count" = "$expected_restarts" ]] \
  || fail "expected $expected_restarts identity-consumer restarts, observed $restart_count"
printf 'RECONCILE=PASS exact=ceralive,ceralive2 consumer_restarts=%s\n' "$restart_count"
printf 'RESULT=PASS real-avahi arbitration-and-late-merge\n'
