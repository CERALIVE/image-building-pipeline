#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
VERIFY="${V2}/ci/verify-and-flash-candidate.sh"
TMP="$(mktemp -d)"
proof4_owned_pgids=()
proof4_run_id="${CERALIVE_PROOF4_RUN_ID:-proof4-${BASHPID}-${RANDOM}}"
proof4_group_members() {
  local pgid="$1"
  ps -eo pid=,pgid= | awk -v pgid="${pgid}" '$2 == pgid { print $1 }'
}
proof4_assert_owned_group() {
  local pgid="$1" pid marker pid_pgid pid_sid self_pgid members=()
  mapfile -t members < <(proof4_group_members "${pgid}")
  (( ${#members[@]} > 0 )) || return 3
  self_pgid="$(ps -o pgid= -p "${BASHPID}")"
  self_pgid="${self_pgid//[[:space:]]/}"
  [[ "${pgid}" != "${self_pgid}" ]] || {
    printf 'refusing to signal worker/test pgid=%s\n' "${pgid}" >&2
    return 1
  }
  for pid in "${members[@]}"; do
    if ! read -r pid_pgid pid_sid < <(ps -o pgid=,sid= -p "${pid}"); then
      [[ ! -e "/proc/${pid}" ]] && continue
      return 1
    fi
    pid_pgid="${pid_pgid//[[:space:]]/}"
    pid_sid="${pid_sid//[[:space:]]/}"
    [[ "${pid_pgid}" == "${pgid}" && "${pid_sid}" == "${pgid}" ]] || {
      printf 'refusing to signal pid=%s with pgid=%s sid=%s expected=%s\n' \
        "${pid}" "${pid_pgid}" "${pid_sid}" "${pgid}" >&2
      return 1
    }
    if [[ ! -r "/proc/${pid}/environ" ]]; then
      [[ ! -e "/proc/${pid}" ]] && continue
      return 1
    fi
    marker="$(tr '\0' '\n' <"/proc/${pid}/environ" | \
      sed -n 's/^CERALIVE_PROOF4_RUN_ID=//p')"
    [[ "${marker}" == "${proof4_run_id}" ]] || {
      printf 'refusing to signal unowned pid=%s pgid=%s marker=%s\n' \
        "${pid}" "${pgid}" "${marker:-missing}" >&2
      return 1
    }
  done
}
proof4_cleanup_group() {
  local pgid="$1" pid members=() marker
  mapfile -t members < <(proof4_group_members "${pgid}")
  for pid in "${members[@]}"; do
    if [[ ! -r "/proc/${pid}/environ" ]]; then
      [[ ! -e "/proc/${pid}" ]] && continue
      return 1
    fi
    marker="$(tr '\0' '\n' <"/proc/${pid}/environ" | \
      sed -n 's/^CERALIVE_PROOF4_RUN_ID=//p')"
    [[ "${marker}" == "${proof4_run_id}" ]] || {
      printf 'refusing to signal unowned pid=%s pgid=%s marker=%s\n' \
        "${pid}" "${pgid}" "${marker:-missing}" >&2
      return 1
    }
  done
  if (( ${#members[@]} > 0 )); then
    proof4_assert_owned_group "${pgid}"
    kill -TERM -- "-${pgid}" 2>/dev/null || true
    for _ in $(seq 1 25); do
      mapfile -t members < <(proof4_group_members "${pgid}")
      (( ${#members[@]} == 0 )) && break
      sleep 0.02
    done
    mapfile -t members < <(proof4_group_members "${pgid}")
    if (( ${#members[@]} > 0 )); then
      proof4_assert_owned_group "${pgid}"
      kill -KILL -- "-${pgid}" 2>/dev/null || true
    fi
  fi
  for _ in $(seq 1 100); do
    mapfile -t members < <(proof4_group_members "${pgid}")
    (( ${#members[@]} == 0 )) && break
    sleep 0.02
  done
  mapfile -t members < <(proof4_group_members "${pgid}")
  (( ${#members[@]} == 0 ))
}
proof4_forget_owned_group() {
  local target="$1" pgid retained=()
  for pgid in "${proof4_owned_pgids[@]}"; do
    [[ "${pgid}" == "${target}" ]] || retained+=("${pgid}")
  done
  proof4_owned_pgids=("${retained[@]}")
}
proof4_run_id_pgids() {
  local pid pgid marker self_pgid
  self_pgid="$(ps -o pgid= -p "${BASHPID}")"
  self_pgid="${self_pgid//[[:space:]]/}"
  ps -eo pid=,pgid= | while read -r pid pgid; do
    [[ "${pgid}" != "${self_pgid}" ]] || continue
    [[ -r "/proc/${pid}/environ" ]] || continue
    marker="$({ tr '\0' '\n' <"/proc/${pid}/environ"; } 2>/dev/null | \
      sed -n 's/^CERALIVE_PROOF4_RUN_ID=//p')" || continue
    [[ "${marker}" == "${proof4_run_id}" ]] || continue
    printf '%s\n' "${pgid}"
  done | sort -u
}
proof4_cleanup_run_groups() {
  local pgid
  while read -r pgid; do
    [[ -n "${pgid}" ]] || continue
    proof4_cleanup_group "${pgid}" || true
  done < <(proof4_run_id_pgids)
}
cleanup() {
  local pgid
  for pgid in "${proof4_owned_pgids[@]}"; do
    proof4_cleanup_group "${pgid}" || true
  done
  proof4_cleanup_run_groups
  rm -rf "${TMP}"
}
trap cleanup EXIT
openssl genpkey -algorithm ED25519 -out "${TMP}/uart-signing.pem" >/dev/null 2>&1
chmod 0600 "${TMP}/uart-signing.pem"
openssl pkey -in "${TMP}/uart-signing.pem" -pubout -out "${TMP}/uart-public.pem" >/dev/null 2>&1
openssl genpkey -algorithm ED25519 -out "${TMP}/wrong-uart-signing.pem" >/dev/null 2>&1
openssl pkey -in "${TMP}/wrong-uart-signing.pem" -pubout -out "${TMP}/wrong-uart-public.pem" >/dev/null 2>&1

[[ -x "${VERIFY}" ]]
printf 'candidate-bytes\n' >"${TMP}/candidate.raw"
truncate -s 4096 "${TMP}/candidate.raw"
printf 'bundle\n' >"${TMP}/candidate.raucb"
printf 'keyring\n' >"${TMP}/keyring.pem"
printf 'loader\n' >"${TMP}/loader.bin"
printf 'serial\n' >"${TMP}/serial"
printf 'private\n' >"${TMP}/id"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockCandidateKey contract\n' >"${TMP}/id.pub"
sha="$(sha256sum "${TMP}/candidate.raw" | cut -d' ' -f1)"
loader_sha="$(sha256sum "${TMP}/loader.bin" | cut -d' ' -f1)"

cat >"${TMP}/preflash" <<'EOF'
#!/usr/bin/env bash
printf 'preflash %s\n' "$*" >>"${MOCK_FLASH_LOG}"
EOF
cat >"${TMP}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
known_hosts="" global_known_hosts=""
for arg in "$@"; do
  case "${arg}" in
    UserKnownHostsFile=*) known_hosts="${arg#*=}" ;;
    GlobalKnownHostsFile=*) global_known_hosts="${arg#*=}" ;;
  esac
done
[[ -n "${known_hosts}" && "${global_known_hosts}" == /dev/null ]]
[[ " $* " == *" -i ${MOCK_SSH_IDENTITY} "* && " $* " == *" IdentitiesOnly=yes "* ]]
cmd="${*: -1}"
printf 'ssh %s\n' "${cmd}" >>"${MOCK_FLASH_LOG}"
state="$(cat "${MOCK_DEVICE_STATE_FILE}" 2>/dev/null || printf online)"
case "${cmd}" in
  *'findmnt -n -o SOURCE /'*)
    printf '%s\n' "${MOCK_BOOT_ROOT_PARENT:-mmcblk0}"
    ;;
  *'/ci-access/'*)
    printf 'challenge=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    printf 'candidate_commit=1111111111111111111111111111111111111111\n'
    ;;
  true)
    grep -q '^new-host-key$' "${known_hosts}" || printf 'new-host-key\n' >"${known_hosts}"
    count_file="${MOCK_SSH_COUNT_FILE}"
    count="$(cat "${count_file}" 2>/dev/null || echo 0)"
    count=$((count + 1)); printf '%s\n' "${count}" >"${count_file}"
    [[ "${MOCK_RECONNECT_MODE:-success}" == success && "${count}" -ge 2 ]]
    ;;
  *sha256sum*)
    printf 'mutable post-boot media must not be used for candidate identity\n' >&2
    exit 90
    ;;
  *) exit 0 ;;
esac
EOF
cat >"${TMP}/rkdeveloptool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rkdeveloptool %s\n' "$*" >>"${MOCK_FLASH_LOG}"
wait_for_interrupt() {
  [[ -z "${MOCK_RK_PID_FILE:-}" ]] || printf '%s\n' "$$" >"${MOCK_RK_PID_FILE}"
  if [[ "${MOCK_RK_IGNORE_TERM:-0}" == 1 ]]; then
    trap ':' TERM INT
  else
    trap 'exit 143' TERM INT
  fi
  while :; do sleep 1; done
}
proof4_process_record() {
  local role="$1" output="$2" pid="${BASHPID}" ppid pgid stat starttime fd1 fd2
  read -r ppid pgid stat < <(ps -o ppid=,pgid=,stat= -p "${pid}")
  ppid="${ppid//[[:space:]]/}"
  pgid="${pgid//[[:space:]]/}"
  stat="${stat//[[:space:]]/}"
  starttime="$(awk '{print $22}' "/proc/${pid}/stat")"
  fd1="$(readlink "/proc/${pid}/fd/1")"
  fd2="$(readlink "/proc/${pid}/fd/2")"
  printf 'role=%s pid=%s ppid=%s pgid=%s stat=%s starttime=%s fd1=%s fd2=%s\n' \
    "${role}" "${pid}" "${ppid}" "${pgid}" "${stat}" "${starttime}" "${fd1}" "${fd2}" \
    >"${output}"
}
proof4_term_ignoring_descendant() {
  proof4_process_record child "${MOCK_PROOF4_PROCESS_DIR}/child.info"
  trap 'printf "child TERM observed and ignored at %s\n" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >>"${MOCK_PROOF4_PROCESS_DIR}/signals.log"' TERM
  : >"${MOCK_PROOF4_PROCESS_DIR}/child.ready"
  while :; do sleep 0.05 || true; done
}
proof4_db_process_tree() {
  local mode="$1" child_pid
  proof4_process_record leader "${MOCK_PROOF4_PROCESS_DIR}/leader.info"
  trap 'printf "leader TERM observed and ignored at %s\n" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >>"${MOCK_PROOF4_PROCESS_DIR}/signals.log"' TERM
  proof4_term_ignoring_descendant &
  child_pid=$!
  printf '%s\n' "${child_pid}" >"${MOCK_PROOF4_PROCESS_DIR}/child.pid"
  for _ in $(seq 1 100); do
    [[ -e "${MOCK_PROOF4_PROCESS_DIR}/child.ready" ]] && break
    sleep 0.01
  done
  [[ -e "${MOCK_PROOF4_PROCESS_DIR}/child.ready" ]]
  if [[ "${mode}" == leader-exits ]]; then
    printf 'leader-exited-with-live-descendant\n' >"${MOCK_PROOF4_PROCESS_DIR}/leader-exited"
    exit 0
  fi
  while :; do sleep 0.05 || true; done
}
case "${1:-}" in
  ld)
    if [[ -n "${MOCK_PROOF4_REENUM_SCENARIO:-}" ]]; then
      call_count="$(cat "${MOCK_PROOF4_LD_COUNT_FILE}" 2>/dev/null || printf 0)"
      call_count=$((call_count + 1))
      printf '%s\n' "${call_count}" >"${MOCK_PROOF4_LD_COUNT_FILE}"
      if (( call_count == 1 )); then
        printf 'DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=101 Maskrom\n'
        printf 'ld:initial:Vid=0x2207,Pid=0x350b,LocationID=101:Maskrom\n' \
          >>"${MOCK_PROOF4_EVENT_LOG}"
        exit 0
      fi
      case "${MOCK_PROOF4_REENUM_SCENARIO}" in
        timeout)
          printf 'DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=101 Maskrom\n'
          printf 'ld:transient-same-maskrom\n' >>"${MOCK_PROOF4_EVENT_LOG}"
          ;;
        transient)
          case "${call_count}" in
            2) printf 'ld:transient-zero-device\n' >>"${MOCK_PROOF4_EVENT_LOG}" ;;
            3)
              printf 'DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=101 Maskrom\n'
              printf 'ld:transient-same-maskrom\n' >>"${MOCK_PROOF4_EVENT_LOG}"
              ;;
            *)
              printf 'Loader\n' >"${MOCK_HANDOFF_STATE_FILE}"
              printf 'DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=101 Loader\n'
              printf 'ld:loader:same-identity\n' >>"${MOCK_PROOF4_EVENT_LOG}"
              ;;
          esac
          ;;
        malformed)
          printf 'this is not an rkdeveloptool device listing\n'
          printf 'ld:malformed\n' >>"${MOCK_PROOF4_EVENT_LOG}"
          ;;
        wrong-identity)
          printf 'DevNo=1 Vid=0x2207,Pid=0x330c,LocationID=101 Loader\n'
          printf 'ld:wrong-identity\n' >>"${MOCK_PROOF4_EVENT_LOG}"
          ;;
        changed-location)
          printf 'DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=102 Loader\n'
          printf 'ld:changed-location\n' >>"${MOCK_PROOF4_EVENT_LOG}"
          ;;
        multiple)
          printf 'DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=101 Loader\n'
          printf 'DevNo=2 Vid=0x2207,Pid=0x350b,LocationID=101 Loader\n'
          printf 'ld:multiple\n' >>"${MOCK_PROOF4_EVENT_LOG}"
          ;;
        wrong-mode)
          printf 'DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=101 Rockusb\n'
          printf 'ld:wrong-mode\n' >>"${MOCK_PROOF4_EVENT_LOG}"
          ;;
      esac
      exit 0
    fi
    if [[ -n "${MOCK_HANDOFF_STATE_FILE:-}" && -z "${MOCK_PROOF4_REENUM_SCENARIO:-}" ]]; then
      handoff_state="$(cat "${MOCK_HANDOFF_STATE_FILE}")"
      printf 'DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=101 %s\n' "${handoff_state}"
      printf 'ld:%s:Vid=0x2207,Pid=0x350b,LocationID=101\n' "${handoff_state}" \
        >>"${MOCK_HANDOFF_EVENT_LOG}"
      exit 0
    fi
    usb_mode=Maskrom
    [[ ! -e "${MOCK_FLASH_LOG}.db-complete" ]] || usb_mode=Loader
    [[ "${MOCK_USB_MODE:-single}" == loader ]] && usb_mode=Loader
    if [[ "${MOCK_USB_MODE:-single}" == wrong-soc ]]; then
      printf 'DevNo=1 Vid=0x2207,Pid=0x330c,LocationID=101 Maskrom\n'
    else
      printf 'DevNo=1 Vid=0x2207,Pid=0x350b,LocationID=101 %s\n' "${usb_mode}"
    fi
    if [[ "${MOCK_USB_MODE:-single}" == multiple ]]; then
      printf 'DevNo=2 Vid=0x2207,Pid=0x350b,LocationID=102 Maskrom\n'
    fi
    if [[ -n "${MOCK_REPLACE_LOADER_AFTER_VALIDATION:-}" ]]; then
      printf 'replacement-loader\n' >"${MOCK_LOADER_SOURCE}"
    fi
    ;;
  db)
    if [[ -n "${MOCK_PROOF4_DB_MODE:-}" ]]; then
      proof4_db_process_tree "${MOCK_PROOF4_DB_MODE}"
    fi
    if [[ -n "${MOCK_HANDOFF_STATE_FILE:-}" && -z "${MOCK_PROOF4_REENUM_SCENARIO:-}" ]]; then
      [[ "$(cat "${MOCK_HANDOFF_STATE_FILE}")" == Maskrom ]]
      printf 'db:start\n' >>"${MOCK_HANDOFF_EVENT_LOG}"
      printf 'Loader\n' >"${MOCK_HANDOFF_STATE_FILE}"
      printf 'db:complete\n' >>"${MOCK_HANDOFF_EVENT_LOG}"
    fi
    if [[ -n "${MOCK_REPLACE_LOADER_AFTER_VALIDATION:-}" ]]; then
      [[ "$2" != "${MOCK_LOADER_SOURCE}" ]]
      grep -qx 'loader' "$2"
    fi
    if [[ "${MOCK_FLASH_MODE:-exact}" == db-wait ]]; then wait_for_interrupt; fi
    [[ "${MOCK_FLASH_MODE:-exact}" != db-fail ]] || exit 70
    : >"${MOCK_FLASH_LOG}.db-complete"
    ;;
  rfi)
    if [[ -n "${MOCK_PROOF4_REENUM_SCENARIO:-}" ]]; then
      printf 'rfi\n' >>"${MOCK_PROOF4_EVENT_LOG}"
      if [[ "$(cat "${MOCK_HANDOFF_STATE_FILE}")" != Loader ]]; then
        printf 'fixture rejected rfi before same-fixture Loader re-enumeration\n' >&2
        exit 91
      fi
    fi
    if [[ -n "${MOCK_HANDOFF_STATE_FILE:-}" ]]; then
      [[ "$(cat "${MOCK_HANDOFF_STATE_FILE}")" == Loader ]]
      printf 'reenumeration:Loader:Vid=0x2207,Pid=0x350b,LocationID=101\n' \
        >>"${MOCK_HANDOFF_EVENT_LOG}"
      printf 'rfi\n' >>"${MOCK_HANDOFF_EVENT_LOG}"
    fi
    printf 'Flash Size: %s Sectors\n' "${MOCK_TARGET_SECTORS:-195312}"
    ;;
  rid)
    printf 'Flash ID: mock-emmc\n'
    ;;
  wl)
    if [[ "${MOCK_FLASH_MODE:-exact}" == wl-wait ]]; then wait_for_interrupt; fi
    cp "$3" "${MOCK_MEDIA}"
    chmod 600 "${MOCK_MEDIA}"
    case "${MOCK_FLASH_MODE:-exact}" in
      wrong) printf 'X' | dd of="${MOCK_MEDIA}" bs=1 seek=1024 conv=notrunc status=none ;;
      snapshot-grow)
        chmod 600 "$3"
        truncate -s $(( $(stat -c %s "$3") + 512 )) "$3"
        ;;
    esac
    ;;
  rl)
    [[ "$2" == 0 && "$3" == 8 ]]
    [[ -z "${MOCK_READBACK_PATH_FILE:-}" ]] || printf '%s\n' "$4" >"${MOCK_READBACK_PATH_FILE}"
    case "${MOCK_FLASH_MODE:-exact}" in
      readback-fail) exit 71 ;;
      readback-wait|rl-wait) wait_for_interrupt ;;
      *) cp "${MOCK_MEDIA}" "$4" ;;
    esac
    ;;
  rd)
    if [[ "${MOCK_FLASH_MODE:-exact}" == rd-wait ]]; then wait_for_interrupt; fi
    printf 'B' | dd of="${MOCK_MEDIA}" bs=1 seek=2048 conv=notrunc status=none
    printf 'booting\n' >"${MOCK_DEVICE_STATE_FILE}"
    ;;
esac
EOF
cat >"${TMP}/uart" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
uart_log="" authorized_line_out="" ready_out="" start_signal=""
challenge="" candidate_commit=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uart-log) uart_log="$2"; shift 2 ;;
    --authorized-line-out) authorized_line_out="$2"; shift 2 ;;
    --ready-out) ready_out="$2"; shift 2 ;;
    --start-signal) start_signal="$2"; shift 2 ;;
    --challenge) challenge="$2"; shift 2 ;;
    --candidate-commit) candidate_commit="$2"; shift 2 ;;
    *) shift 2 ;;
  esac
done
printf 'restrict,expiry-time="20990101000000Z" ssh-ed25519 AAAA mock\n' >"${authorized_line_out}"
: >"${ready_out}"
while [[ ! -e "${start_signal}" ]]; do sleep 0.02; done
printf 'CERALIVE_UART_PROVISIONED %s %s\n' "${challenge}" "${candidate_commit}" >"${uart_log}"
EOF
chmod +x "${TMP}/preflash" "${TMP}/ssh" "${TMP}/rkdeveloptool" "${TMP}/uart"

common=(
  --image "${TMP}/candidate.raw"
  --bundle "${TMP}/candidate.raucb"
  --keyring "${TMP}/keyring.pem"
  --loader "${TMP}/loader.bin"
  --loader-sha256 "${loader_sha}"
  --board rock-5b-plus
  --board-ip 192.0.2.10
  --candidate-commit 1111111111111111111111111111111111111111
  --image-sha256 "${sha}"
  --serial-dev "${TMP}/serial"
  --uart-log "${TMP}/uart.log"
  --authorized-key "${TMP}/id.pub"
  --access-id gh-123-1
  --access-expires 20990101000000Z
  --host-epoch 4070908800
  --ssh-identity "${TMP}/id"
  --challenge aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --expected-maskrom-id-sha256 "$(printf '%s' 'Vid=0x2207,Pid=0x350b,LocationID=101 Maskrom' | sha256sum | cut -d' ' -f1)"
  --uart-signing-key "${TMP}/uart-signing.pem"
  --known-hosts "${TMP}/known-hosts"
  --authorized-line-out "${TMP}/authorized-line"
  --identity-out "${TMP}/identity.txt"
)
base_env=(
  "RUNNER_TEMP=${TMP}"
  "MOCK_SSH_IDENTITY=${TMP}/id"
  "CERALIVE_RKDEVELOPTOOL_BIN=${TMP}/rkdeveloptool"
  "CERALIVE_UART_HELPER_BIN=${TMP}/uart"
  "CERALIVE_PREFLASH_BIN=${TMP}/preflash"
  "CERALIVE_SSH_BIN=${TMP}/ssh"
  "CERALIVE_RECONNECT_ATTEMPTS=3"
  "CERALIVE_RECONNECT_DELAY=0"
  "CERALIVE_UART_PUBLIC_KEY_FILE=${TMP}/uart-public.pem"
)

assert_healthy_loader_handoff() {
  local case_dir="${TMP}/healthy-loader-handoff"
  local expected_events
  mkdir -p "${case_dir}"
  printf 'Maskrom\n' >"${case_dir}/usb-state"
  expected_events=$'ld:Maskrom:Vid=0x2207,Pid=0x350b,LocationID=101\n'\
$'db:start\n'\
$'db:complete\n'\
$'ld:Loader:Vid=0x2207,Pid=0x350b,LocationID=101\n'\
$'reenumeration:Loader:Vid=0x2207,Pid=0x350b,LocationID=101\n'\
$'rfi'
  rm -f "${TMP}/identity.txt"
  env "${base_env[@]}" MOCK_RECONNECT_MODE=success \
    MOCK_HANDOFF_STATE_FILE="${case_dir}/usb-state" \
    MOCK_HANDOFF_EVENT_LOG="${case_dir}/events.log" \
    MOCK_MEDIA="${case_dir}/media.raw" MOCK_SSH_COUNT_FILE="${case_dir}/count" \
    MOCK_FLASH_LOG="${case_dir}/flash.log" MOCK_DEVICE_STATE_FILE="${case_dir}/state" \
    "${VERIFY}" "${common[@]}" >"${case_dir}/verify.log" 2>&1
  [[ "$(<"${case_dir}/usb-state")" == Loader ]]
  [[ "$(<"${case_dir}/events.log")" == "${expected_events}" ]]
  [[ "$(grep -c '^db:start$' "${case_dir}/events.log")" -eq 1 ]]
  printf 'healthy loader handoff: db completed before same-fixture Loader re-enumeration before rfi (exit=0)\n'
}

assert_healthy_loader_handoff
if [[ "${CERALIVE_PROOF4_CASE:-}" == healthy ]]; then
  exit 0
fi

proof4_live_and_zombie_counts() {
  local pgid="$1" live=0 zombie=0 stat
  while read -r stat; do
    [[ -n "${stat}" ]] || continue
    if [[ "${stat}" == Z* ]]; then
      zombie=$((zombie + 1))
    else
      live=$((live + 1))
    fi
  done < <(ps -eo pgid=,stat= | awk -v pgid="${pgid}" '$1 == pgid { print $2 }')
  printf '%s %s\n' "${live}" "${zombie}"
}

proof4_run_verifier() {
  local case_dir="$1" db_mode="$2" reenum_scenario="$3"
  local watchdog_pid watchdog_fd started_ms ended_ms verifier_stat session_observed=0
  mkdir -p "${case_dir}/process"
  mkfifo -- "${case_dir}/watchdog.cancel"
  exec {watchdog_fd}<>"${case_dir}/watchdog.cancel"
  proof4_db_pgid=""
  printf 'Maskrom\n' >"${case_dir}/usb-state"
  : >"${case_dir}/events.log"
  : >"${case_dir}/flash.log"
  started_ms="$(date +%s%3N)"
  setsid env "${base_env[@]}" \
    CERALIVE_PROOF4_RUN_ID="${proof4_run_id}" \
    CERALIVE_RKDEVELOPTOOL_DB_TIMEOUT_SECONDS=1 \
    CERALIVE_LOADER_REENUMERATION_TIMEOUT_SECONDS=1 \
    CERALIVE_LOADER_REENUMERATION_POLL_SECONDS=0.05 \
    MOCK_PROOF4_DB_MODE="${db_mode}" \
    MOCK_PROOF4_PROCESS_DIR="${case_dir}/process" \
    MOCK_PROOF4_REENUM_SCENARIO="${reenum_scenario}" \
    MOCK_PROOF4_LD_COUNT_FILE="${case_dir}/ld-count" \
    MOCK_PROOF4_EVENT_LOG="${case_dir}/events.log" \
    MOCK_HANDOFF_STATE_FILE="${case_dir}/usb-state" \
    MOCK_HANDOFF_EVENT_LOG="${case_dir}/events.log" \
    MOCK_RECONNECT_MODE=success MOCK_MEDIA="${case_dir}/media.raw" \
    MOCK_SSH_COUNT_FILE="${case_dir}/count" MOCK_FLASH_LOG="${case_dir}/flash.log" \
    MOCK_DEVICE_STATE_FILE="${case_dir}/state" \
    "${VERIFY}" "${common[@]}" >"${case_dir}/verify.log" 2>&1 &
  proof4_verify_pid=$!
  proof4_verify_pgid="${proof4_verify_pid}"
  proof4_owned_pgids+=("${proof4_verify_pgid}")
  for _ in $(seq 1 100); do
    if proof4_assert_owned_group "${proof4_verify_pgid}" 2>/dev/null; then
      session_observed=1
      break
    fi
    verifier_stat="$(ps -o stat= -p "${proof4_verify_pid}" 2>/dev/null || true)"
    [[ -z "${verifier_stat}" || "${verifier_stat}" == *Z* ]] && break
    sleep 0.01
  done
  if (( session_observed == 0 )) && \
     verifier_stat="$(ps -o stat= -p "${proof4_verify_pid}" 2>/dev/null || true)" && \
     [[ -n "${verifier_stat}" && "${verifier_stat}" != *Z* ]]; then
    printf 'FIXTURE_ERROR: verifier did not establish a separately owned session pgid=%s\n' \
      "${proof4_verify_pgid}" >&2
    exec {watchdog_fd}>&-
    return 2
  fi
  (
    if IFS= read -r -t 4 _ <&"${watchdog_fd}"; then
      exit 0
    fi
    if ! proof4_assert_owned_group "${proof4_verify_pgid}"; then
      printf 'outer-watchdog-refused utc=%s pgid=%s reason=ownership-check\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" "${proof4_verify_pgid}" \
        >"${case_dir}/watchdog.log"
      exit 1
    fi
    printf 'outer-watchdog-fired utc=%s pgid=%s action=TERM\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" "${proof4_verify_pgid}" \
      >"${case_dir}/watchdog.log"
    kill -TERM -- "-${proof4_verify_pgid}" 2>/dev/null || true
    sleep 0.4
    if proof4_assert_owned_group "${proof4_verify_pgid}"; then
      printf 'outer-watchdog utc=%s pgid=%s action=KILL\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" "${proof4_verify_pgid}" \
        >>"${case_dir}/watchdog.log"
      kill -KILL -- "-${proof4_verify_pgid}" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!

  if [[ -n "${db_mode}" ]]; then
    for _ in $(seq 1 200); do
      [[ -s "${case_dir}/process/leader.info" && -s "${case_dir}/process/child.info" ]] && break
      sleep 0.01
    done
    if [[ -s "${case_dir}/process/leader.info" ]]; then
      proof4_db_pgid="$(sed -nE \
        's/^role=leader pid=[0-9]+ ppid=[0-9]+ pgid=([0-9]+) .*/\1/p' \
        "${case_dir}/process/leader.info")"
      [[ "${proof4_db_pgid}" =~ ^[1-9][0-9]*$ ]] || {
        printf 'FIXTURE_ERROR: process tree published an invalid db pgid\n' >&2
        proof4_cleanup_group "${proof4_verify_pgid}" || true
        printf 'cancel\n' >&"${watchdog_fd}" || true
        wait "${watchdog_pid}" 2>/dev/null || true
        exec {watchdog_fd}>&-
        return 2
      }
      proof4_owned_pgids+=("${proof4_db_pgid}")
    fi
    if [[ ! -s "${case_dir}/process/leader.info" || ! -s "${case_dir}/process/child.info" ]]; then
      printf 'FIXTURE_ERROR: process tree did not publish leader and child identity\n' >&2
      [[ -z "${proof4_db_pgid}" ]] || proof4_cleanup_group "${proof4_db_pgid}" || true
      proof4_cleanup_run_groups
      proof4_cleanup_group "${proof4_verify_pgid}" || true
      printf 'cancel\n' >&"${watchdog_fd}" || true
      wait "${watchdog_pid}" 2>/dev/null || true
      exec {watchdog_fd}>&-
      return 2
    fi
    proof4_assert_owned_group "${proof4_db_pgid}" || {
      printf 'FIXTURE_ERROR: nested db process group ownership was not established\n' >&2
      proof4_cleanup_group "${proof4_db_pgid}" || true
      proof4_cleanup_group "${proof4_verify_pgid}" || true
      printf 'cancel\n' >&"${watchdog_fd}" || true
      wait "${watchdog_pid}" 2>/dev/null || true
      exec {watchdog_fd}>&-
      return 2
    }
    printf 'PROCESS_SNAPSHOT case=%s\n' "$(basename "${case_dir}")"
    cat "${case_dir}/process/leader.info" "${case_dir}/process/child.info"
    ps -o pid=,ppid=,pgid=,stat=,args= -g "${proof4_verify_pgid}" || true
  fi

  set +e
  wait "${proof4_verify_pid}"
  proof4_rc=$?
  set -e
  ended_ms="$(date +%s%3N)"
  proof4_elapsed_ms=$((ended_ms - started_ms))
  if (( proof4_rc != 0 )); then
    printf 'VERIFIER_DIAGNOSTIC case=%s rc=%s\n' "$(basename "${case_dir}")" "${proof4_rc}"
    cat "${case_dir}/verify.log"
  fi
  if [[ -e "${case_dir}/watchdog.log" ]]; then
    proof4_watchdog_fired=1
  else
    proof4_watchdog_fired=0
    printf 'cancel\n' >&"${watchdog_fd}"
  fi
  wait "${watchdog_pid}" 2>/dev/null || true
  exec {watchdog_fd}>&-
}

proof4_finish_case_cleanup() {
  local case_dir="$1" live zombie db_live=0 db_zombie=0 total_live total_zombie
  local info pid recorded_start current_start exact_matches=0
  read -r live zombie < <(proof4_live_and_zombie_counts "${proof4_verify_pgid}")
  if [[ -n "${proof4_db_pgid:-}" ]]; then
    read -r db_live db_zombie < <(proof4_live_and_zombie_counts "${proof4_db_pgid}")
  fi
  total_live=$((live + db_live))
  total_zombie=$((zombie + db_zombie))
  for info in "${case_dir}"/process/{leader,child}.info; do
    [[ -s "${info}" ]] || continue
    pid="$(sed -nE 's/^role=[^ ]+ pid=([0-9]+).*/\1/p' "${info}")"
    recorded_start="$(sed -nE 's/.* starttime=([0-9]+) .*/\1/p' "${info}")"
    if [[ -r "/proc/${pid}/stat" ]]; then
      current_start="$(awk '{print $22}' "/proc/${pid}/stat")"
      [[ "${current_start}" != "${recorded_start}" ]] || exact_matches=$((exact_matches + 1))
    fi
  done
  if [[ -n "${proof4_db_pgid:-}" ]]; then
    proof4_cleanup_group "${proof4_db_pgid}" || true
  fi
  proof4_cleanup_group "${proof4_verify_pgid}" || true
  proof4_cleanup_run_groups
  proof4_forget_owned_group "${proof4_verify_pgid}"
  [[ -z "${proof4_db_pgid:-}" ]] || proof4_forget_owned_group "${proof4_db_pgid}"
  printf 'CLEANUP_RECEIPT case=%s verifier_pgid=%s db_pgid=%s remaining_live=%s remaining_zombie=%s exact_pid_start_matches=%s\n' \
    "$(basename "${case_dir}")" "${proof4_verify_pgid}" "${proof4_db_pgid:-none}" \
    "${total_live}" "${total_zombie}" "${exact_matches}"
  proof4_remaining_live="${total_live}"
  proof4_remaining_zombie="${total_zombie}"
  proof4_exact_pid_start_matches="${exact_matches}"
}

proof4_contract_result() {
  local outcome="$1" contract="$2" observable="$3"
  printf 'CONTRACT_%s: %s | %s\n' "${outcome}" "${contract}" "${observable}"
}

assert_invalid_loader_handoff_overrides() {
  local name value label output rc case_dir="${TMP}/proof4-invalid-overrides"
  local cases=(
    CERALIVE_RKDEVELOPTOOL_DB_TIMEOUT_SECONDS 0
    CERALIVE_RKDEVELOPTOOL_DB_TIMEOUT_SECONDS invalid
    CERALIVE_RKDEVELOPTOOL_DB_TIMEOUT_SECONDS 61
    CERALIVE_LOADER_REENUMERATION_TIMEOUT_SECONDS 0
    CERALIVE_LOADER_REENUMERATION_TIMEOUT_SECONDS invalid
    CERALIVE_LOADER_REENUMERATION_TIMEOUT_SECONDS 61
    CERALIVE_LOADER_REENUMERATION_POLL_SECONDS 0
    CERALIVE_LOADER_REENUMERATION_POLL_SECONDS invalid
    CERALIVE_LOADER_REENUMERATION_POLL_SECONDS 5.1
    CERALIVE_RKDEVELOPTOOL_TERM_GRACE_SECONDS 0
    CERALIVE_RKDEVELOPTOOL_TERM_GRACE_SECONDS invalid
    CERALIVE_RKDEVELOPTOOL_TERM_GRACE_SECONDS 11
    CERALIVE_RKDEVELOPTOOL_KILL_REAP_GRACE_SECONDS 0
    CERALIVE_RKDEVELOPTOOL_KILL_REAP_GRACE_SECONDS invalid
    CERALIVE_RKDEVELOPTOOL_KILL_REAP_GRACE_SECONDS 11
  )
  mkdir -p "${case_dir}"
  while (( ${#cases[@]} > 0 )); do
    name="${cases[0]}"
    value="${cases[1]}"
    cases=("${cases[@]:2}")
    label="${name,,}-${value}"
    rm -f "${case_dir}/${label}.flash.log"
    set +e
    output="$(env "${base_env[@]}" "${name}=${value}" \
      MOCK_FLASH_LOG="${case_dir}/${label}.flash.log" \
      "${VERIFY}" "${common[@]}" 2>&1)"
    rc=$?
    set -e
    if (( rc == 2 )) && [[ ! -e "${case_dir}/${label}.flash.log" ]] &&
       [[ "${output}" == *"${name} must be a positive"* ]]; then
      proof4_contract_result PASS "${name}=${value} is rejected before rkdeveloptool" \
        'rc=2 rkdeveloptool_calls=0'
    else
      proof4_contract_result FAIL "${name}=${value} is rejected before rkdeveloptool" \
        "rc=${rc} flash_log=$([[ -e "${case_dir}/${label}.flash.log" ]] && echo present || echo absent)"
      return 1
    fi
  done
}

run_proof4_red_contract() {
  local failures=0 case_dir child_pid child_start current_start
  local leader_pid fd1 fd2 scenario expected_pattern

  assert_invalid_loader_handoff_overrides || return 2

  case_dir="${TMP}/proof4-db-command-timeout"
  proof4_run_verifier "${case_dir}" hang timeout || return 2
  cat "${case_dir}/watchdog.log" 2>/dev/null || true
  cat "${case_dir}/process/signals.log" 2>/dev/null || true
  if (( proof4_rc != 0 )); then
    proof4_contract_result PASS 'db command timeout returns nonzero' "rc=${proof4_rc}"
  else
    proof4_contract_result FAIL 'db command timeout returns nonzero' 'rc=0'
    failures=$((failures + 1))
  fi
  if (( proof4_watchdog_fired == 0 )) && \
     grep -Fq 'rkdeveloptool db command timed out' "${case_dir}/verify.log"; then
    proof4_contract_result PASS 'db command timeout is internally bounded and diagnostic is preserved' \
      "elapsed_ms=${proof4_elapsed_ms}"
  else
    proof4_contract_result FAIL 'db command timeout is internally bounded and diagnostic is preserved' \
      "outer_watchdog=${proof4_watchdog_fired} elapsed_ms=${proof4_elapsed_ms} diagnostic=missing"
    failures=$((failures + 1))
  fi
  if ! grep -Fq 'loader re-enumeration timed out' "${case_dir}/verify.log"; then
    proof4_contract_result PASS 'db command timeout remains distinct from re-enumeration timeout' \
      'no re-enumeration-timeout diagnostic on hung db command'
  else
    proof4_contract_result FAIL 'db command timeout remains distinct from re-enumeration timeout' \
      'wrong timeout diagnostic'
    failures=$((failures + 1))
  fi
  if grep -Eq '^rkdeveloptool (rfi|wl|rl|rd)' "${case_dir}/flash.log"; then
    proof4_contract_result FAIL 'hung db makes zero downstream rfi|wl|rl|rd calls' 'downstream call observed'
    failures=$((failures + 1))
  else
    proof4_contract_result PASS 'hung db makes zero downstream rfi|wl|rl|rd calls' 'count=0'
  fi
  if (( proof4_watchdog_fired == 0 )) && [[ -s "${case_dir}/process/signals.log" ]]; then
    proof4_contract_result PASS 'production sends process-group TERM before KILL/reap' \
      "$(tr '\n' ';' <"${case_dir}/process/signals.log")"
  else
    proof4_contract_result FAIL 'production sends process-group TERM before KILL/reap' \
      'only the outer watchdog forced escalation'
    failures=$((failures + 1))
  fi
  proof4_finish_case_cleanup "${case_dir}"
  if (( proof4_remaining_live == 0 && proof4_remaining_zombie == 0 &&
        proof4_exact_pid_start_matches == 0 )); then
    proof4_contract_result PASS 'db timeout leaves no live child and no zombie after completion' \
      'remaining_live=0 remaining_zombie=0 exact_pid_start_matches=0'
  else
    proof4_contract_result FAIL 'db timeout leaves no live child and no zombie after completion' \
      "remaining_live=${proof4_remaining_live} remaining_zombie=${proof4_remaining_zombie} exact_pid_start_matches=${proof4_exact_pid_start_matches}"
    failures=$((failures + 1))
  fi

  case_dir="${TMP}/proof4-leader-exits"
  proof4_run_verifier "${case_dir}" leader-exits timeout || return 2
  read -r _ child_pid _ _ _ child_start fd1 fd2 < <(
    sed -E 's/^[^ ]+ pid=([^ ]+) ppid=([^ ]+) pgid=([^ ]+) stat=([^ ]+) starttime=([^ ]+) fd1=([^ ]+) fd2=(.*)$/child \1 \2 \3 \4 \5 \6 \7/' \
      "${case_dir}/process/child.info"
  )
  leader_pid="$(sed -nE 's/^role=leader pid=([0-9]+).*/\1/p' "${case_dir}/process/leader.info")"
  if [[ -s "${case_dir}/process/leader-exited" && ! -e "/proc/${leader_pid}" &&
        ! -e "/proc/${child_pid}" && "${fd1}" == *'/verify.log' &&
        "${fd2}" == *'/verify.log' ]]; then
    proof4_contract_result PASS 'leader exit occurred with an exact live descendant retaining descriptors before production cleanup' \
      "leader_pid=${leader_pid} child_pid=${child_pid} child_start=${child_start} fd1=${fd1} fd2=${fd2} post_cleanup=absent"
  else
    printf 'FIXTURE_ERROR: durable leader-exit descendant evidence or production cleanup was not observed\n' >&2
    proof4_finish_case_cleanup "${case_dir}"
    return 2
  fi
  if (( proof4_rc != 0 )) &&
     grep -Fq 'rkdeveloptool db leader exited while process-group descendants survived' \
       "${case_dir}/verify.log" &&
     ! grep -Fq 'loader re-enumeration timed out' "${case_dir}/verify.log"; then
    proof4_contract_result PASS 'leader-exit descendant survival fails before loader re-enumeration' \
      "rc=${proof4_rc} elapsed_ms=${proof4_elapsed_ms}"
  else
    proof4_contract_result FAIL 'leader-exit descendant survival fails before loader re-enumeration' \
      "rc=${proof4_rc}; descendant diagnostic missing or re-enumeration started"
    failures=$((failures + 1))
  fi
  if grep -Eq '^rkdeveloptool (rfi|wl|rl|rd)' "${case_dir}/flash.log"; then
    proof4_contract_result FAIL 'failed re-enumeration makes zero downstream rfi|wl|rl|rd calls' \
      "$(grep -E '^rkdeveloptool (rfi|wl|rl|rd)' "${case_dir}/flash.log" | tr '\n' ';')"
    failures=$((failures + 1))
  else
    proof4_contract_result PASS 'failed re-enumeration makes zero downstream rfi|wl|rl|rd calls' 'count=0'
  fi
  if kill -0 "${child_pid}" 2>/dev/null; then
    proof4_contract_result FAIL 'production owns descendant after leader exit' \
      "child_pid=${child_pid} still live before test cleanup"
    failures=$((failures + 1))
  else
    proof4_contract_result PASS 'production owns descendant after leader exit' 'child reaped by production'
  fi
  proof4_finish_case_cleanup "${case_dir}"
  if (( proof4_remaining_live != 0 || proof4_remaining_zombie != 0 ||
        proof4_exact_pid_start_matches != 0 )); then return 2; fi

  case_dir="${TMP}/proof4-loader-reenumeration-timeout"
  proof4_run_verifier "${case_dir}" '' timeout || return 2
  if (( proof4_rc != 0 && proof4_watchdog_fired == 0 )) &&
     grep -Fq 'loader re-enumeration timed out' "${case_dir}/verify.log"; then
    proof4_contract_result PASS 'post-db same-Maskrom state reaches bounded re-enumeration timeout' \
      "rc=${proof4_rc} elapsed_ms=${proof4_elapsed_ms}"
  else
    proof4_contract_result FAIL 'post-db same-Maskrom state reaches bounded re-enumeration timeout' \
      "rc=${proof4_rc} outer_watchdog=${proof4_watchdog_fired}; diagnostic missing"
    failures=$((failures + 1))
  fi
  if grep -Eq '^rkdeveloptool (rfi|wl|rl|rd)' "${case_dir}/flash.log"; then
    proof4_contract_result FAIL 're-enumeration timeout makes zero downstream rfi|wl|rl|rd calls' \
      'downstream call observed'
    failures=$((failures + 1))
  else
    proof4_contract_result PASS 're-enumeration timeout makes zero downstream rfi|wl|rl|rd calls' 'count=0'
  fi
  proof4_finish_case_cleanup "${case_dir}"
  if (( proof4_remaining_live != 0 || proof4_remaining_zombie != 0 ||
        proof4_exact_pid_start_matches != 0 )); then return 2; fi

  for scenario in malformed multiple wrong-identity changed-location wrong-mode transient; do
    case_dir="${TMP}/proof4-reenumeration-${scenario}"
    proof4_run_verifier "${case_dir}" '' "${scenario}" || return 2
    case "${scenario}" in
      malformed) expected_pattern='malformed rkdeveloptool loader re-enumeration listing' ;;
      multiple) expected_pattern='expected exactly one rkdeveloptool loader target, found 2' ;;
      wrong-identity) expected_pattern='loader re-enumerated with the wrong RK3588 identity' ;;
      changed-location) expected_pattern='loader re-enumerated at a changed LocationID' ;;
      wrong-mode) expected_pattern='loader re-enumerated in an unknown mode' ;;
      transient) expected_pattern='' ;;
    esac
    if [[ "${scenario}" == transient ]]; then
      if (( proof4_rc == 0 )) && \
         grep -Fq 'ld:transient-zero-device' "${case_dir}/events.log" && \
         grep -Fq 'ld:transient-same-maskrom' "${case_dir}/events.log" && \
         grep -Fq 'ld:loader:same-identity' "${case_dir}/events.log"; then
        proof4_contract_result PASS 'zero-device and same-Maskrom are tolerated only until same-fixture Loader appears within budget' \
          "rc=0 elapsed_ms=${proof4_elapsed_ms}"
      else
        proof4_contract_result FAIL 'zero-device and same-Maskrom are tolerated only until same-fixture Loader appears within budget' \
          "rc=${proof4_rc}; transition events missing"
        failures=$((failures + 1))
      fi
      for downstream in rfi wl rl rd; do
        if [[ "$(grep -c "^rkdeveloptool ${downstream}\( \|$\)" "${case_dir}/flash.log")" -eq 1 ]]; then
          proof4_contract_result PASS "successful handoff does not retry ${downstream}" 'count=1'
        else
          proof4_contract_result FAIL "successful handoff does not retry ${downstream}" \
            "count=$(grep -c "^rkdeveloptool ${downstream}\( \|$\)" "${case_dir}/flash.log")"
          failures=$((failures + 1))
        fi
      done
    elif grep -Fq "${expected_pattern}" "${case_dir}/verify.log" && \
         ! grep -Eq '^rkdeveloptool (rfi|wl|rl|rd)' "${case_dir}/flash.log"; then
      proof4_contract_result PASS "${scenario} re-enumeration is rejected before downstream commands" \
        "rc=${proof4_rc} diagnostic=${expected_pattern}"
    else
      proof4_contract_result FAIL "${scenario} re-enumeration is rejected before downstream commands" \
        "rc=${proof4_rc}; expected diagnostic missing or rfi observed"
      failures=$((failures + 1))
    fi
    if [[ "$(grep -c '^rkdeveloptool db ' "${case_dir}/flash.log")" -eq 1 ]]; then
      proof4_contract_result PASS "${scenario} performs no db retry" 'db_count=1'
    else
      proof4_contract_result FAIL "${scenario} performs no db retry" \
        "db_count=$(grep -c '^rkdeveloptool db ' "${case_dir}/flash.log")"
      failures=$((failures + 1))
    fi
    proof4_finish_case_cleanup "${case_dir}"
    if (( proof4_remaining_live != 0 || proof4_remaining_zombie != 0 ||
          proof4_exact_pid_start_matches != 0 )); then return 2; fi
  done

  if (( failures == 0 )); then
    printf 'proof-4 bounded loader handoff desired contract: PASS\n'
    return 0
  fi
  printf 'EXPECTED_RED: unchanged production lacks bounded process-group loader handoff (contract_failures=%s)\n' \
    "${failures}" >&2
  return 1
}

case "${CERALIVE_PROOF4_CASE:-all}" in
  healthy)
    exit 0
    ;;
  red)
    run_proof4_red_contract
    exit $?
    ;;
  all)
    run_proof4_red_contract
    ;;
  *)
    printf 'unknown CERALIVE_PROOF4_CASE: %s (expected all, healthy, or red)\n' \
      "${CERALIVE_PROOF4_CASE}" >&2
    exit 2
    ;;
esac

assert_identity_name_rejected() {
  local label="$1" flag="$2" path="$3" output
  rm -f "${TMP}/identity.txt"
  if output="$(env "${base_env[@]}" MOCK_MEDIA="${TMP}/malformed-media.raw" \
      MOCK_SSH_COUNT_FILE="${TMP}/malformed-count" MOCK_FLASH_LOG="${TMP}/malformed.log" \
      MOCK_DEVICE_STATE_FILE="${TMP}/malformed-state" "${VERIFY}" "${common[@]}" \
      "${flag}" "${path}" 2>&1)"; then
    printf '%s identity name was accepted\n' "${label}" >&2
    exit 1
  fi
  [[ "${output}" == *"identity filename"* ]]
  [[ ! -e "${TMP}/identity.txt" ]]
  printf '%s identity name rejected: %s\n' "${label}" "${output}"
}

malformed_image="${TMP}/candidate=malformed.raw"
cp "${TMP}/candidate.raw" "${malformed_image}"
assert_identity_name_rejected "equals image" --image "${malformed_image}"
malformed_bundle="${TMP}/candidate
malformed.raucb"
printf 'bundle\n' >"${malformed_bundle}"
assert_identity_name_rejected "newline bundle" --bundle "${malformed_bundle}"

if env "${base_env[@]}" "${VERIFY}" "${common[@]}" \
    --image-sha256 "$(printf bad | sha256sum | cut -d' ' -f1)"; then
  printf 'candidate digest mismatch was accepted\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_FLASH_LOG="${TMP}/flash-loader-digest.log" \
    "${VERIFY}" "${common[@]}" \
    --loader-sha256 "$(printf bad | sha256sum | cut -d' ' -f1)"; then
  printf 'loader digest mismatch was accepted\n' >&2
  exit 1
fi
[[ ! -e "${TMP}/flash-loader-digest.log" ]]

if ! env "${base_env[@]}" MOCK_REPLACE_LOADER_AFTER_VALIDATION=1 \
    MOCK_LOADER_SOURCE="${TMP}/loader.bin" MOCK_RECONNECT_MODE=success \
    MOCK_MEDIA="${TMP}/media-loader-snapshot.raw" \
    MOCK_SSH_COUNT_FILE="${TMP}/count-loader-snapshot" \
    MOCK_FLASH_LOG="${TMP}/flash-loader-snapshot.log" \
    MOCK_DEVICE_STATE_FILE="${TMP}/state-loader-snapshot" \
    "${VERIFY}" "${common[@]}"; then
  printf 'verified private loader snapshot was not used after source replacement\n' >&2
  exit 1
fi
grep -Eq "^rkdeveloptool db ${TMP}/ceralive-verify\\.[^/]+/loader.bin$" \
  "${TMP}/flash-loader-snapshot.log"
printf 'loader\n' >"${TMP}/loader.bin"

if env "${base_env[@]}" MOCK_USB_MODE=multiple \
    MOCK_MEDIA="${TMP}/media-multi.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-multi" \
    MOCK_FLASH_LOG="${TMP}/flash-multi.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-multi" \
    "${VERIFY}" "${common[@]}"; then
  printf 'ambiguous Rockchip USB target selection was accepted\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_USB_MODE=loader \
    MOCK_MEDIA="${TMP}/media-loader.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-loader" \
    MOCK_FLASH_LOG="${TMP}/flash-loader.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-loader" \
    "${VERIFY}" "${common[@]}"; then
  printf 'loader-mode target was accepted as a Maskrom starting state\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_USB_MODE=wrong-soc \
    MOCK_MEDIA="${TMP}/media-wrong-soc.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-wrong-soc" \
    MOCK_FLASH_LOG="${TMP}/flash-wrong-soc.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-wrong-soc" \
    "${VERIFY}" "${common[@]}"; then
  printf 'wrong single Maskrom SoC was accepted\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool db' "${TMP}/flash-wrong-soc.log"; then
  printf 'wrong single Maskrom SoC advanced to loader download\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_FLASH_MODE=db-fail \
    MOCK_MEDIA="${TMP}/media-db-fail.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-db-fail" \
    MOCK_FLASH_LOG="${TMP}/flash-db-fail.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-db-fail" \
    "${VERIFY}" "${common[@]}"; then
  printf 'loader transfer failure was accepted\n' >&2
  exit 1
fi
if grep -Eq '^rkdeveloptool (rfi|wl|rl|rd)' "${TMP}/flash-db-fail.log"; then
  printf 'loader transfer failure advanced to capacity, write, readback, or reset\n' >&2
  exit 1
fi

if env "${base_env[@]}" \
    MOCK_MEDIA="${TMP}/media-unapproved.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-unapproved" \
    MOCK_FLASH_LOG="${TMP}/flash-unapproved.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-unapproved" \
    "${VERIFY}" "${common[@]}" \
    --expected-maskrom-id-sha256 "$(printf unapproved | sha256sum | cut -d' ' -f1)"; then
  printf 'unapproved Rock 5B+ fixture was accepted\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool wl' "${TMP}/flash-unapproved.log"; then
  printf 'unapproved Rock 5B+ fixture reached media write\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool db' "${TMP}/flash-loader.log"; then
  printf 'loader-mode target advanced to loader download\n' >&2
  exit 1
fi

if key_mismatch_output="$(env "${base_env[@]}" \
    CERALIVE_UART_PUBLIC_KEY_FILE="${TMP}/wrong-uart-public.pem" \
    MOCK_MEDIA="${TMP}/media-key-mismatch.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-key-mismatch" \
    MOCK_FLASH_LOG="${TMP}/flash-key-mismatch.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-key-mismatch" \
    "${VERIFY}" "${common[@]}" 2>&1)"; then
  printf 'mismatched UART signing key and baked public key were accepted\n' >&2
  exit 1
fi
[[ "${key_mismatch_output}" == *'does not match the public key baked into the candidate'* ]]
if [[ -e "${TMP}/flash-key-mismatch.log" ]] && \
   grep -q '^rkdeveloptool ' "${TMP}/flash-key-mismatch.log"; then
  printf 'mismatched UART signing key touched the Rockchip USB fixture\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_TARGET_SECTORS=7 \
    MOCK_MEDIA="${TMP}/media-small.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-small" \
    MOCK_FLASH_LOG="${TMP}/flash-small.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-small" \
    "${VERIFY}" "${common[@]}"; then
  printf 'undersized eMMC capacity was accepted\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool wl' "${TMP}/flash-small.log"; then
  printf 'undersized eMMC capacity reached media write\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool db' "${TMP}/flash-multi.log"; then
  printf 'ambiguous Rockchip USB targets advanced to loader download\n' >&2
  exit 1
fi

printf 'stale-identity\n' >"${TMP}/identity.txt"
if env "${base_env[@]}" MOCK_RECONNECT_MODE=never MOCK_MEDIA="${TMP}/media-never.raw" \
    MOCK_SSH_COUNT_FILE="${TMP}/count-never" MOCK_FLASH_LOG="${TMP}/flash-never.log" \
    MOCK_DEVICE_STATE_FILE="${TMP}/state-never" CERALIVE_RECONNECT_ATTEMPTS=2 \
    "${VERIFY}" "${common[@]}"; then
  printf 'reconnect exhaustion was accepted\n' >&2
  exit 1
fi
[[ ! -e "${TMP}/identity.txt" ]]

if env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_FLASH_MODE=wrong \
    MOCK_MEDIA="${TMP}/media-wrong.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-wrong" \
    MOCK_FLASH_LOG="${TMP}/flash-wrong.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-wrong" \
    "${VERIFY}" "${common[@]}"; then
  printf 'wrong flashed candidate was accepted\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool rd' "${TMP}/flash-wrong.log"; then
  printf 'wrong flashed candidate reached reset before readback rejection\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_FLASH_MODE=snapshot-grow \
    MOCK_MEDIA="${TMP}/media-grow.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-grow" \
    MOCK_FLASH_LOG="${TMP}/flash-grow.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-grow" \
    "${VERIFY}" "${common[@]}"; then
  printf 'candidate snapshot growth during flash was accepted\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool rl' "${TMP}/flash-grow.log"; then
  printf 'candidate snapshot growth reached media readback\n' >&2
  exit 1
fi
if grep -q '^rkdeveloptool rd' "${TMP}/flash-grow.log"; then
  printf 'candidate snapshot growth reached reset\n' >&2
  exit 1
fi

if env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_FLASH_MODE=readback-fail \
    MOCK_MEDIA="${TMP}/media-readfail.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-readfail" \
    MOCK_FLASH_LOG="${TMP}/flash-readfail.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-readfail" \
    MOCK_READBACK_PATH_FILE="${TMP}/readfail-path" "${VERIFY}" "${common[@]}"; then
  printf 'rkdeveloptool readback failure was accepted\n' >&2
  exit 1
fi
readfail_path="$(cat "${TMP}/readfail-path")"
[[ ! -e "${readfail_path}" ]]
if grep -q '^rkdeveloptool rd' "${TMP}/flash-readfail.log"; then
  printf 'failed media readback reached reset\n' >&2
  exit 1
fi

term_log="${TMP}/term.out"
env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_FLASH_MODE=readback-wait \
  MOCK_MEDIA="${TMP}/media-term.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-term" \
  MOCK_FLASH_LOG="${TMP}/flash-term.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-term" \
  MOCK_READBACK_PATH_FILE="${TMP}/term-path" MOCK_RK_PID_FILE="${TMP}/term-rk-pid" \
  "${VERIFY}" "${common[@]}" >"${term_log}" 2>&1 &
verify_pid=$!
for _ in $(seq 1 100); do
  [[ -s "${TMP}/term-path" && -s "${TMP}/term-rk-pid" ]] && break
  sleep 0.02
done
[[ -s "${TMP}/term-path" && -s "${TMP}/term-rk-pid" ]]
term_readback_path="$(cat "${TMP}/term-path")"
rk_pid="$(cat "${TMP}/term-rk-pid")"
kill -TERM "${verify_pid}"
set +e
wait "${verify_pid}"
term_rc=$?
set -e
[[ "${term_rc}" -eq 143 ]]
if kill -0 "${rk_pid}" 2>/dev/null; then
  printf 'interrupted verifier left rkdeveloptool running\n' >&2
  exit 1
fi
[[ ! -e "${term_readback_path}" ]]
[[ ! -e "${TMP}/identity.txt" ]]
if grep -q '^rkdeveloptool rd' "${TMP}/flash-term.log"; then
  printf 'interrupted media readback reached reset\n' >&2
  exit 1
fi

assert_interrupt_cleanup() {
  local mode="$1" label="$2" signal="$3" expected_rc="$4" repeated="${5:-0}" case_dir
  local verify_pid verify_starttime watchdog_pid watchdog_fd rk_pid rk_starttime current_starttime
  local rc started elapsed child_survived=0
  case_dir="${TMP}/interrupt-${signal,,}-${label}"
  mkdir -p "${case_dir}"
  mkfifo -- "${case_dir}/watchdog.cancel"
  exec {watchdog_fd}<>"${case_dir}/watchdog.cancel"
  rm -f "${TMP}/identity.txt"
  env "${base_env[@]}" MOCK_FLASH_MODE="${mode}" MOCK_RK_IGNORE_TERM="${repeated}" \
    MOCK_MEDIA="${case_dir}/media.raw" MOCK_SSH_COUNT_FILE="${case_dir}/count" \
    MOCK_FLASH_LOG="${case_dir}/flash.log" MOCK_DEVICE_STATE_FILE="${case_dir}/state" \
    MOCK_RK_PID_FILE="${case_dir}/rk.pid" "${VERIFY}" "${common[@]}" \
    >"${case_dir}/verify.log" 2>&1 &
  verify_pid=$!
  verify_starttime="$(awk '{print $22}' "/proc/${verify_pid}/stat")"
  for _ in $(seq 1 150); do
    [[ -s "${case_dir}/rk.pid" ]] && break
    sleep 0.02
  done
  [[ -s "${case_dir}/rk.pid" ]]
  rk_pid="$(cat "${case_dir}/rk.pid")"
  rk_starttime="$(awk '{print $22}' "/proc/${rk_pid}/stat")"
  started="${SECONDS}"
  (
    if IFS= read -r -t 3 _ <&"${watchdog_fd}"; then
      exit 0
    fi
    if [[ -r "/proc/${verify_pid}/stat" ]] &&
       [[ "$(awk '{print $22}' "/proc/${verify_pid}/stat")" == "${verify_starttime}" ]]; then
      kill -KILL "${verify_pid}" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!
  kill "-${signal}" "${verify_pid}"
  if (( repeated == 1 )); then
    sleep 0.1
    kill "-${signal}" "${verify_pid}" || {
      printf '%s %s verifier exited before repeated cleanup signal\n' "${signal}" "${label}" >&2
      printf 'cancel\n' >&"${watchdog_fd}" || true
      wait "${watchdog_pid}" 2>/dev/null || true
      exec {watchdog_fd}>&-
      return 1
    }
  fi
  set +e
  wait "${verify_pid}"
  rc=$?
  set -e
  elapsed=$((SECONDS - started))
  printf 'cancel\n' >&"${watchdog_fd}" || true
  wait "${watchdog_pid}" 2>/dev/null || true
  exec {watchdog_fd}>&-
  if kill -0 "${rk_pid}" 2>/dev/null; then
    child_survived=1
    current_starttime="$(awk '{print $22}' "/proc/${rk_pid}/stat")"
    [[ "${current_starttime}" != "${rk_starttime}" ]] || \
      kill -KILL "${rk_pid}" 2>/dev/null || true
    wait "${rk_pid}" 2>/dev/null || true
  fi
  if [[ "${rc}" -ne "${expected_rc}" ]]; then
    printf '%s %s cancellation returned %s, expected %s (elapsed=%ss)\n' \
      "${signal}" "${label}" "${rc}" "${expected_rc}" "${elapsed}" >&2
    exit 1
  fi
  if (( child_survived == 1 )); then
    printf '%s %s rkdeveloptool child survived cancellation\n' "${signal}" "${label}" >&2
    exit 1
  fi
  (( elapsed < 3 )) || {
    printf '%s %s cancellation reached the 3s watchdog\n' "${signal}" "${label}" >&2
    exit 1
  }
  grep -q "^rkdeveloptool ${label}" "${case_dir}/flash.log"
  [[ ! -e "${TMP}/identity.txt" ]]
  if find "${TMP}" -maxdepth 1 -type d -name 'ceralive-verify.*' -print -quit | grep -q .; then
    printf '%s %s cancellation leaked verifier scratch\n' "${signal}" "${label}" >&2
    exit 1
  fi
  printf '%s %s cancellation cleaned verifier, child, and scratch (rc=%s elapsed=%ss repeated_signal=%s)\n' \
    "${signal}" "${label}" "${rc}" "${elapsed}" "${repeated}"
}

for signal_case in TERM INT; do
  if [[ "${signal_case}" == TERM ]]; then
    expected_signal_rc=143
  else
    expected_signal_rc=130
  fi
  if [[ "${signal_case}" == TERM ]]; then
    assert_interrupt_cleanup db-wait db "${signal_case}" "${expected_signal_rc}" 1
  else
    assert_interrupt_cleanup db-wait db "${signal_case}" "${expected_signal_rc}"
  fi
  assert_interrupt_cleanup wl-wait wl "${signal_case}" "${expected_signal_rc}"
  assert_interrupt_cleanup rl-wait rl "${signal_case}" "${expected_signal_rc}"
  assert_interrupt_cleanup rd-wait rd "${signal_case}" "${expected_signal_rc}"
done

if env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_BOOT_ROOT_PARENT=mmcblk1 \
    MOCK_MEDIA="${TMP}/media-root-mismatch.raw" MOCK_SSH_COUNT_FILE="${TMP}/count-root-mismatch" \
    MOCK_FLASH_LOG="${TMP}/flash-root-mismatch.log" MOCK_DEVICE_STATE_FILE="${TMP}/state-root-mismatch" \
    "${VERIFY}" "${common[@]}"; then
  printf 'boot from a different media device was accepted\n' >&2
  exit 1
fi
[[ ! -e "${TMP}/identity.txt" ]]

if ! env "${base_env[@]}" MOCK_RECONNECT_MODE=success MOCK_MEDIA="${TMP}/media-ok.raw" \
  MOCK_SSH_COUNT_FILE="${TMP}/count-ok" MOCK_FLASH_LOG="${TMP}/flash-ok.log" \
  MOCK_DEVICE_STATE_FILE="${TMP}/state-ok" "${VERIFY}" "${common[@]}"; then
  printf 'healthy candidate was rejected after expected first-boot media mutation\n' >&2
  exit 1
fi
grep -qx "candidate_commit=1111111111111111111111111111111111111111" "${TMP}/identity.txt"
grep -qx 'raw_file=candidate.raw' "${TMP}/identity.txt"
grep -qx 'raw_size=4096' "${TMP}/identity.txt"
grep -qx "raw_sha256=${sha}" "${TMP}/identity.txt"
grep -qx 'bundle_file=candidate.raucb' "${TMP}/identity.txt"
grep -qx "keyring_sha256=$(sha256sum "${TMP}/keyring.pem" | cut -d' ' -f1)" \
  "${TMP}/identity.txt"
grep -qx 'loader_file=loader.bin' "${TMP}/identity.txt"
grep -qx "loader_sha256=${loader_sha}" "${TMP}/identity.txt"
grep -qx 'identity_contract=pre-boot-whole-media-sha256' "${TMP}/identity.txt"
grep -qx "pre_boot_media_sha256=${sha}" "${TMP}/identity.txt"
grep -qx 'pre_boot_media_identity=verified' "${TMP}/identity.txt"
grep -qx 'target_capacity_sectors=195312' "${TMP}/identity.txt"
grep -Eq '^flash_id_sha256=[0-9a-f]{64}$' "${TMP}/identity.txt"
grep -qx 'boot_root_parent=mmcblk0' "${TMP}/identity.txt"
usb_identity='Vid=0x2207,Pid=0x350b,LocationID=101 Maskrom'
grep -qx "usb_device_sha256=$(printf '%s' "${usb_identity}" | sha256sum | cut -d' ' -f1)" \
  "${TMP}/identity.txt"
grep -Eq '^bootstrap_challenge_sha256=[0-9a-f]{64}$' "${TMP}/identity.txt"
grep -Eq '^post_boot_known_hosts_sha256=[0-9a-f]{64}$' "${TMP}/identity.txt"
grep -qx 'post_boot_reconnect=verified' "${TMP}/identity.txt"
grep -Eq '^uart_log_sha256=[0-9a-f]{64}$' "${TMP}/identity.txt"
grep -qx 'ephemeral_ssh_access=gh-123-1' "${TMP}/identity.txt"
grep -qx 'flash_transport=maskrom-rkdeveloptool' "${TMP}/identity.txt"
grep -qx 'rkdeveloptool db .*loader.bin' "${TMP}/flash-ok.log"
grep -qx 'rkdeveloptool rfi' "${TMP}/flash-ok.log"
grep -qx 'rkdeveloptool rid' "${TMP}/flash-ok.log"
grep -q 'preflash .*--target-size-bytes 99999744' "${TMP}/flash-ok.log"
grep -Eq "^rkdeveloptool wl 0 ${TMP}/ceralive-verify\.[^/]+/candidate.raw$" "${TMP}/flash-ok.log"
grep -Eq "^rkdeveloptool rl 0 8 ${TMP}/ceralive-verify\.[^/]+/readback.raw$" "${TMP}/flash-ok.log"
grep -qx 'rkdeveloptool rd' "${TMP}/flash-ok.log"
if grep -q 'sha256sum' "${TMP}/flash-ok.log"; then
  printf 'candidate identity used mutable post-boot media bytes\n' >&2
  exit 1
fi
if find "${TMP}" -maxdepth 1 -type d -name 'ceralive-verify.*' -print -quit | grep -q .; then
  printf 'verifier scratch directory leaked\n' >&2
  exit 1
fi
if find "${TMP}" -maxdepth 1 -type f -name '.candidate-identity.*' -print -quit | grep -q .; then
  printf 'candidate identity temporary file leaked\n' >&2
  exit 1
fi

printf 'release candidate identity/flash contract: PASS\n'
