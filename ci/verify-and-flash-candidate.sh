#!/usr/bin/env bash
set -euo pipefail

reset_ignored_cancellation_signals() {
  local ignored
  [[ -r "/proc/$$/status" ]] || return 0
  ignored="$(awk '$1 == "SigIgn:" { print $2 }' "/proc/$$/status")"
  [[ "${ignored}" =~ ^[0-9a-fA-F]{16}$ ]] || return 0
  if (( (16#${ignored} & 0x4002) != 0 )); then
    exec env --default-signal=INT --default-signal=TERM \
      "${BASH}" "${BASH_SOURCE[0]}" "$@"
  fi
}
reset_ignored_cancellation_signals "$@"

image="" bundle="" keyring="" loader="" board="" board_ip="" candidate_commit=""
expected_sha="" loader_sha="" serial_dev="" uart_log="" authorized_key=""
access_id="" access_expires="" host_epoch="" authorized_line_out="" identity_out=""
ssh_identity="" challenge=""
ssh_known_hosts=""
expected_maskrom_id_sha="" uart_signing_key=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) image="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --keyring) keyring="${2:-}"; shift 2 ;;
    --loader) loader="${2:-}"; shift 2 ;;
    --loader-sha256) loader_sha="${2:-}"; shift 2 ;;
    --board) board="${2:-}"; shift 2 ;;
    --board-ip) board_ip="${2:-}"; shift 2 ;;
    --candidate-commit) candidate_commit="${2:-}"; shift 2 ;;
    --image-sha256) expected_sha="${2:-}"; shift 2 ;;
    --serial-dev) serial_dev="${2:-}"; shift 2 ;;
    --uart-log) uart_log="${2:-}"; shift 2 ;;
    --authorized-key) authorized_key="${2:-}"; shift 2 ;;
    --access-id) access_id="${2:-}"; shift 2 ;;
    --access-expires) access_expires="${2:-}"; shift 2 ;;
    --host-epoch) host_epoch="${2:-}"; shift 2 ;;
    --ssh-identity) ssh_identity="${2:-}"; shift 2 ;;
    --challenge) challenge="${2:-}"; shift 2 ;;
    --expected-maskrom-id-sha256) expected_maskrom_id_sha="${2:-}"; shift 2 ;;
    --uart-signing-key) uart_signing_key="${2:-}"; shift 2 ;;
    --known-hosts) ssh_known_hosts="${2:-}"; shift 2 ;;
    --authorized-line-out) authorized_line_out="${2:-}"; shift 2 ;;
    --identity-out) identity_out="${2:-}"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for value in image bundle keyring loader board board_ip candidate_commit expected_sha \
  loader_sha serial_dev uart_log authorized_key access_id access_expires host_epoch \
  ssh_identity challenge expected_maskrom_id_sha uart_signing_key ssh_known_hosts \
  authorized_line_out identity_out; do
  [[ -n "${!value}" ]] || { printf '%s is required\n' "$value" >&2; exit 2; }
done
[[ -f "${image}" && -f "${bundle}" && -f "${keyring}" && -f "${loader}" ]]
[[ -e "${serial_dev}" && -r "${serial_dev}" && -w "${serial_dev}" && \
   -r "${authorized_key}" && -r "${ssh_identity}" ]]
[[ -f "${uart_signing_key}" && ! -L "${uart_signing_key}" && \
   "$(stat -c %a "${uart_signing_key}")" == 600 ]]
[[ "${expected_sha}" =~ ^[0-9a-f]{64}$ && "${loader_sha}" =~ ^[0-9a-f]{64}$ && \
   "${expected_maskrom_id_sha}" =~ ^[0-9a-f]{64}$ ]]
[[ "${candidate_commit}" =~ ^[0-9a-f]{40}$ && "${challenge}" =~ ^[0-9a-f]{64}$ ]]
[[ "${access_id}" =~ ^[A-Za-z0-9._-]{1,80}$ ]]
[[ "${access_expires}" =~ ^[0-9]{14}Z$ && "${host_epoch}" =~ ^[0-9]{10}$ ]]
[[ "${board}" == rock-5b-plus ]] || { printf 'hardware gate supports only rock-5b-plus\n' >&2; exit 1; }
[[ "${SSH_USER:-root}" == root ]] || { printf 'UART bootstrap provisions only root SSH access\n' >&2; exit 1; }

db_timeout_seconds="${CERALIVE_RKDEVELOPTOOL_DB_TIMEOUT_SECONDS:-15}"
loader_reenumeration_timeout_seconds="${CERALIVE_LOADER_REENUMERATION_TIMEOUT_SECONDS:-10}"
loader_reenumeration_poll_seconds="${CERALIVE_LOADER_REENUMERATION_POLL_SECONDS:-0.1}"
rkdeveloptool_term_grace_seconds="${CERALIVE_RKDEVELOPTOOL_TERM_GRACE_SECONDS:-1}"
rkdeveloptool_kill_reap_grace_seconds="${CERALIVE_RKDEVELOPTOOL_KILL_REAP_GRACE_SECONDS:-1}"

validate_bounded_positive_integer_override() {
  local name="$1" value="$2" maximum="$3"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ || ${#value} -gt ${#maximum} ]] ||
     (( 10#${value} > maximum )); then
    printf '%s must be a positive integer no greater than %s seconds\n' \
      "${name}" "${maximum}" >&2
    exit 2
  fi
}
validate_positive_decimal_override() {
  local name="$1" value="$2"
  if [[ ! "${value}" =~ ^([0-9]+)(\.[0-9]+)?$ ]] ||
     ! awk -v value="${value}" 'BEGIN { exit !(value > 0 && value <= 5) }'; then
    printf '%s must be a positive decimal no greater than 5 seconds\n' "${name}" >&2
    exit 2
  fi
}
validate_bounded_positive_integer_override CERALIVE_RKDEVELOPTOOL_DB_TIMEOUT_SECONDS \
  "${db_timeout_seconds}" 60
validate_bounded_positive_integer_override CERALIVE_LOADER_REENUMERATION_TIMEOUT_SECONDS \
  "${loader_reenumeration_timeout_seconds}" 60
validate_positive_decimal_override CERALIVE_LOADER_REENUMERATION_POLL_SECONDS \
  "${loader_reenumeration_poll_seconds}"
validate_bounded_positive_integer_override CERALIVE_RKDEVELOPTOOL_TERM_GRACE_SECONDS \
  "${rkdeveloptool_term_grace_seconds}" 10
validate_bounded_positive_integer_override CERALIVE_RKDEVELOPTOOL_KILL_REAP_GRACE_SECONDS \
  "${rkdeveloptool_kill_reap_grace_seconds}" 10

identity_dir="$(dirname -- "${identity_out}")"
[[ -d "${identity_dir}" && ! -L "${identity_out}" && \
   -d "$(dirname -- "${ssh_known_hosts}")" && ! -L "${ssh_known_hosts}" ]] || {
  printf 'identity output must be a non-symlink path in an existing directory: %s\n' "${identity_out}" >&2
  exit 1
}
rm -f -- "${identity_out}"

validate_identity_filename() {
  local field="$1" value="$2"
  [[ "${value}" =~ ^[A-Za-z0-9._+-]+$ ]] || {
    printf '%s identity filename contains unsupported characters\n' "${field}" >&2
    exit 1
  }
}

raw_file="$(basename -- "${image}")"
bundle_file="$(basename -- "${bundle}")"
loader_file="$(basename -- "${loader}")"
validate_identity_filename raw_file "${raw_file}"
validate_identity_filename bundle_file "${bundle_file}"
validate_identity_filename loader_file "${loader_file}"

scratch_root="${RUNNER_TEMP:-/tmp}"
[[ -d "${scratch_root}" && -w "${scratch_root}" && ! -L "${scratch_root}" ]] || {
  printf 'RUNNER_TEMP must be a writable non-symlink directory: %s\n' "${scratch_root}" >&2
  exit 1
}
verify_tmp="$(mktemp -d "${scratch_root}/ceralive-verify.XXXXXX")"
chmod 700 "${verify_tmp}"
flash_image="${verify_tmp}/candidate.raw"
flash_loader="${verify_tmp}/loader.bin"
readback_image="${verify_tmp}/readback.raw"
ld_output_file="${verify_tmp}/rkdeveloptool-ld.log"
rfi_output_file="${verify_tmp}/rkdeveloptool-rfi.log"
rid_output_file="${verify_tmp}/rkdeveloptool-rid.log"
uart_ready_file="${verify_tmp}/uart-ready"
uart_start_file="${verify_tmp}/uart-start"
identity_tmp=""
rkdeveloptool_pid=""
db_leader_pid=""
db_leader_pgid=""
db_leader_sid=""
db_leader_starttime=""
db_leader_reaped=0
db_session_owned=0
uart_pid=""
read_proc_identity() {
  local pid="$1" line rest fields
  [[ -r "/proc/${pid}/stat" ]] || return 1
  line="$(<"/proc/${pid}/stat")"
  rest="${line##*) }"
  read -r -a fields <<<"${rest}"
  (( ${#fields[@]} >= 20 )) || return 1
  proc_state="${fields[0]}"
  proc_ppid="${fields[1]}"
  proc_pgid="${fields[2]}"
  proc_sid="${fields[3]}"
  proc_starttime="${fields[19]}"
}
monotonic_nanoseconds() {
  local uptime whole fraction
  read -r uptime _ </proc/uptime || return 1
  [[ "${uptime}" =~ ^([0-9]+)\.([0-9]+)$ ]] || return 1
  whole="${BASH_REMATCH[1]}"
  fraction="${BASH_REMATCH[2]}000000000"
  fraction="${fraction:0:9}"
  printf '%s\n' "$((10#${whole} * 1000000000 + 10#${fraction}))"
}
db_group_members() {
  local pgid="$1"
  ps -eo pid=,pgid=,stat= | awk -v pgid="${pgid}" '$2 == pgid { print $1, $3 }'
}
db_group_has_live_member() {
  local pgid="$1" pid stat
  while read -r pid stat; do
    [[ -n "${pid}" ]] || continue
    [[ "${stat}" == Z* ]] || return 0
  done < <(db_group_members "${pgid}")
  return 1
}
db_group_has_nonleader_member() {
  local pgid="$1" pid
  while read -r pid _; do
    [[ -n "${pid}" ]] || continue
    [[ "${pid}" == "${db_leader_pid}" ]] || return 0
  done < <(db_group_members "${pgid}")
  return 1
}
validate_db_group_ownership() {
  local pid stat self_pgid members=0 leader_seen=0
  [[ -n "${db_leader_pgid}" && "${db_leader_pgid}" == "${db_leader_sid}" ]] || return 1
  self_pgid="$(ps -o pgid= -p "$$")"
  self_pgid="${self_pgid//[[:space:]]/}"
  [[ "${db_leader_pgid}" != "${self_pgid}" ]] || {
    printf 'refusing to signal the verifier process group\n' >&2
    return 1
  }
  while read -r pid stat; do
    [[ -n "${pid}" ]] || continue
    if ! read_proc_identity "${pid}"; then
      [[ ! -e "/proc/${pid}" ]] && continue
      return 1
    fi
    members=$((members + 1))
    [[ "${proc_pgid}" == "${db_leader_pgid}" && "${proc_sid}" == "${db_leader_sid}" ]] || return 1
    if [[ "${pid}" == "${db_leader_pid}" ]]; then
      [[ "${proc_starttime}" == "${db_leader_starttime}" &&
         "${proc_ppid}" == "$$" ]] || return 1
      leader_seen=1
    fi
  done < <(db_group_members "${db_leader_pgid}")
  (( members > 0 && leader_seen == 1 ))
}
reap_db_leader() {
  (( db_leader_reaped == 0 )) || return 0
  if read_proc_identity "${db_leader_pid}"; then
    if [[ "${proc_starttime}" == "${db_leader_starttime}" &&
          "${proc_ppid}" == "$$" && "${proc_state}" != Z* ]]; then
      printf 'refusing an unbounded wait for a live rkdeveloptool db leader\n' >&2
      return 1
    fi
  elif [[ -e "/proc/${db_leader_pid}" ]]; then
    printf 'could not prove rkdeveloptool db leader state before reap\n' >&2
    return 1
  fi
  if wait "${db_leader_pid}"; then
    db_leader_status=0
  else
    db_leader_status=$?
  fi
  db_leader_reaped=1
}
wait_for_db_group_state() {
  local mode="$1" seconds="$2" deadline now
  deadline=$(( $(monotonic_nanoseconds) + seconds * 1000000000 ))
  while :; do
    if [[ "${mode}" == live ]]; then
      db_group_has_live_member "${db_leader_pgid}" || return 0
    else
      [[ -z "$(db_group_members "${db_leader_pgid}")" ]] && return 0
    fi
    now="$(monotonic_nanoseconds)"
    (( now < deadline )) || return 1
    sleep 0.02
  done
}
terminate_db_group() {
  local cleanup_ok=0
  if [[ -n "${db_leader_pgid}" && -n "$(db_group_members "${db_leader_pgid}")" ]]; then
    validate_db_group_ownership || {
      printf 'refusing to signal an unowned rkdeveloptool db process group\n' >&2
      return 1
    }
    kill -TERM -- "-${db_leader_pgid}" 2>/dev/null || {
      printf 'could not TERM the owned rkdeveloptool db process group\n' >&2
      return 1
    }
    if ! wait_for_db_group_state live "${rkdeveloptool_term_grace_seconds}"; then
      validate_db_group_ownership || {
        printf 'refusing to KILL an unowned rkdeveloptool db process group\n' >&2
        return 1
      }
      kill -KILL -- "-${db_leader_pgid}" 2>/dev/null || {
        printf 'could not KILL the owned rkdeveloptool db process group\n' >&2
        return 1
      }
      wait_for_db_group_state live "${rkdeveloptool_kill_reap_grace_seconds}" || \
        cleanup_ok=1
    fi
  fi
  (( cleanup_ok == 0 )) || {
    printf 'rkdeveloptool db process group still has live members after KILL\n' >&2
    return 1
  }
  reap_db_leader || return 1
  wait_for_db_group_state empty "${rkdeveloptool_kill_reap_grace_seconds}" || cleanup_ok=1
  (( cleanup_ok == 0 )) || {
    printf 'rkdeveloptool db process group still has live or zombie members after cleanup\n' >&2
    return 1
  }
}
clear_db_identity() {
  db_leader_pid=""
  db_leader_pgid=""
  db_leader_sid=""
  db_leader_starttime=""
  db_leader_reaped=0
  db_session_owned=0
}
cleanup_owned_db() {
  terminate_db_group || return 1
  clear_db_identity
}
wait_for_unowned_db_leader_stop() {
  local seconds="$1" deadline now
  deadline=$(( $(monotonic_nanoseconds) + seconds * 1000000000 ))
  while :; do
    if ! read_proc_identity "${db_leader_pid}"; then
      [[ ! -e "/proc/${db_leader_pid}" ]] && return 0
      return 2
    fi
    [[ "${proc_starttime}" == "${db_leader_starttime}" ]] || return 0
    [[ "${proc_ppid}" == "$$" ]] || return 2
    [[ "${proc_state}" != Z* ]] || return 0
    now="$(monotonic_nanoseconds)"
    (( now < deadline )) || return 1
    sleep 0.02
  done
}
abort_unowned_db_startup() {
  local cleanup_status=0 wait_status=0
  if [[ -n "${db_leader_pid}" ]]; then
    if [[ -z "${db_leader_starttime}" ]]; then
      if [[ ! -e "/proc/${db_leader_pid}" ]]; then
        reap_db_leader || return 1
        clear_db_identity
        return 0
      fi
    fi
    if ! read_proc_identity "${db_leader_pid}"; then
      if [[ ! -e "/proc/${db_leader_pid}" ]]; then
        reap_db_leader
        clear_db_identity
        return 0
      fi
      printf 'could not prove rkdeveloptool db startup process identity\n' >&2
      return 1
    fi
    [[ -n "${db_leader_starttime}" ]] || db_leader_starttime="${proc_starttime}"
    [[ "${proc_starttime}" == "${db_leader_starttime}" && "${proc_ppid}" == "$$" ]] || {
      printf 'refusing to signal reused rkdeveloptool db startup pid\n' >&2
      return 1
    }
    kill -TERM "${db_leader_pid}" 2>/dev/null || true
    wait_for_unowned_db_leader_stop "${rkdeveloptool_term_grace_seconds}" || wait_status=$?
    if (( wait_status == 1 )); then
      if ! read_proc_identity "${db_leader_pid}" ||
         [[ "${proc_starttime}" != "${db_leader_starttime}" || "${proc_ppid}" != "$$" ]]; then
        printf 'refusing to KILL unverified rkdeveloptool db startup pid\n' >&2
        return 1
      fi
      kill -KILL "${db_leader_pid}" 2>/dev/null || {
        printf 'could not KILL verified rkdeveloptool db startup pid\n' >&2
        return 1
      }
      wait_status=0
      wait_for_unowned_db_leader_stop "${rkdeveloptool_kill_reap_grace_seconds}" || \
        wait_status=$?
      (( wait_status == 0 )) || cleanup_status=1
    elif (( wait_status != 0 )); then
      cleanup_status=1
    fi
    if (( cleanup_status == 0 )); then
      reap_db_leader || cleanup_status=1
    fi
  fi
  if (( cleanup_status == 0 )); then
    clear_db_identity
    return 0
  fi
  return 1
}
stop_rkdeveloptool() {
  local pid="${rkdeveloptool_pid}" cleanup_status=0
  rkdeveloptool_pid=""
  if [[ -n "${db_leader_pid}" ]]; then
    if (( db_session_owned == 1 )); then
      cleanup_owned_db || cleanup_status=1
    else
      abort_unowned_db_startup || cleanup_status=1
    fi
  fi
  if [[ -n "${pid}" ]]; then
    kill -TERM "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
  return "${cleanup_status}"
}
stop_uart() {
  local pid="${uart_pid}"
  uart_pid=""
  if [[ -n "${pid}" ]]; then
    kill -TERM "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
}
cleanup() {
  local cleanup_status=0
  stop_rkdeveloptool || cleanup_status=1
  stop_uart
  [[ -z "${identity_tmp}" ]] || rm -f -- "${identity_tmp}"
  rm -rf -- "${verify_tmp}"
  (( cleanup_status == 0 )) || {
    printf 'could not prove rkdeveloptool db process-group cleanup\n' >&2
    return 1
  }
  return 0
}
finish() {
  local exit_status="$1"
  trap ':' INT TERM
  trap - EXIT
  if cleanup; then
    exit "${exit_status}"
  fi
  exit 1
}
trap 'finish "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_rkdeveloptool() {
  local status
  "${rkdeveloptool}" "$@" &
  rkdeveloptool_pid=$!
  if wait "${rkdeveloptool_pid}"; then
    status=0
  else
    status=$?
  fi
  rkdeveloptool_pid=""
  return "${status}"
}

run_owned_db() {
  local gate="${verify_tmp}/rkdeveloptool-db.start"
  local release="${verify_tmp}/rkdeveloptool-db.release"
  local status_file="${verify_tmp}/rkdeveloptool-db.status"
  local gate_fd release_fd deadline now status db_startup_signal=0
  clear_db_identity
  mkfifo -- "${gate}" "${release}"
  exec {gate_fd}<>"${gate}"
  exec {release_fd}<>"${release}"
  trap '[[ "${db_startup_signal}" != 0 ]] || db_startup_signal=130' INT
  trap '[[ "${db_startup_signal}" != 0 ]] || db_startup_signal=143' TERM
  # shellcheck disable=SC2016 # Child shell expands $1..$5 from its own argv.
  setsid bash -c '
    trap ":" HUP INT TERM
    IFS= read -r _ <"$1" || exit 125
    (
      trap - HUP INT TERM
      exec "$2" db "$3"
    ) &
    command_pid=$!
    command_status=125
    while :; do
      wait "${command_pid}"
      command_status=$?
      jobs -pr | grep -qx -- "${command_pid}" || break
    done
    printf "%s\n" "${command_status}" >"$4.tmp" || exit 125
    mv -f -- "$4.tmp" "$4" || exit 125
    while ! IFS= read -r _ <"$5"; do :; done
    exit "${command_status}"
  ' bash "${gate}" "${rkdeveloptool}" "${flash_loader}" "${status_file}" "${release}" &
  db_leader_pid=$!
  db_leader_pgid="${db_leader_pid}"
  db_leader_sid="${db_leader_pid}"
  for _ in $(seq 1 100); do
    if read_proc_identity "${db_leader_pid}"; then
      [[ "${proc_ppid}" == "$$" ]] || break
      if [[ -z "${db_leader_starttime}" ]]; then
        db_leader_starttime="${proc_starttime}"
      elif [[ "${proc_starttime}" != "${db_leader_starttime}" ]]; then
        break
      fi
      if [[ "${proc_pgid}" == "${db_leader_pgid}" &&
            "${proc_sid}" == "${db_leader_sid}" ]]; then
        db_session_owned=1
        break
      fi
    fi
    sleep 0.01
  done
  trap 'exit 130' INT
  trap 'exit 143' TERM
  (( db_startup_signal == 0 )) || exit "${db_startup_signal}"
  (( db_session_owned == 1 )) || {
    printf 'could not establish owned rkdeveloptool db session\n' >&2
    abort_unowned_db_startup || \
      printf 'could not prove rkdeveloptool db startup cleanup\n' >&2
    exec {gate_fd}>&-
    exec {release_fd}>&-
    return 1
  }
  printf 'start\n' >&"${gate_fd}"
  exec {gate_fd}>&-
  deadline=$(( $(monotonic_nanoseconds) + db_timeout_seconds * 1000000000 ))
  while [[ ! -s "${status_file}" ]]; do
    if ! read_proc_identity "${db_leader_pid}" ||
       [[ "${proc_starttime}" != "${db_leader_starttime}" ||
          "${proc_ppid}" != "$$" || "${proc_state}" == Z* ]]; then
      printf 'rkdeveloptool db supervisor exited before reporting command status\n' >&2
      exec {release_fd}>&-
      cleanup_owned_db || \
        printf 'could not prove rkdeveloptool db process-group cleanup\n' >&2
      return 1
    fi
    now="$(monotonic_nanoseconds)"
    if (( now >= deadline )); then
      printf 'rkdeveloptool db command timed out after %ss\n' "${db_timeout_seconds}" >&2
      exec {release_fd}>&-
      cleanup_owned_db || {
        printf 'could not prove rkdeveloptool db process-group cleanup\n' >&2
        return 1
      }
      return 1
    fi
    sleep 0.02
  done
  read -r status <"${status_file}"
  [[ "${status}" =~ ^([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]] || {
    printf 'rkdeveloptool db supervisor reported malformed command status\n' >&2
    exec {release_fd}>&-
    cleanup_owned_db || \
      printf 'could not prove rkdeveloptool db process-group cleanup\n' >&2
    return 1
  }
  validate_db_group_ownership || {
    printf 'could not revalidate the pinned rkdeveloptool db process group\n' >&2
    exec {release_fd}>&-
    cleanup_owned_db || \
      printf 'could not prove rkdeveloptool db process-group cleanup\n' >&2
    return 1
  }
  if db_group_has_nonleader_member "${db_leader_pgid}"; then
    printf 'rkdeveloptool db leader exited while process-group descendants survived\n' >&2
    exec {release_fd}>&-
    cleanup_owned_db || {
      printf 'could not prove rkdeveloptool db process-group cleanup\n' >&2
      return 1
    }
    return 1
  fi
  printf 'release\n' >&"${release_fd}"
  exec {release_fd}>&-
  if ! wait_for_unowned_db_leader_stop "${rkdeveloptool_kill_reap_grace_seconds}"; then
    printf 'rkdeveloptool db supervisor did not stop after command completion\n' >&2
    cleanup_owned_db || \
      printf 'could not prove rkdeveloptool db process-group cleanup\n' >&2
    return 1
  fi
  reap_db_leader || {
    printf 'could not reap bounded rkdeveloptool db supervisor\n' >&2
    return 1
  }
  [[ "${db_leader_status}" == "${status}" ]] || {
    printf 'rkdeveloptool db supervisor status changed before reap\n' >&2
    return 1
  }
  wait_for_db_group_state empty "${rkdeveloptool_kill_reap_grace_seconds}" || {
    printf 'rkdeveloptool db process group was not empty after command completion\n' >&2
    return 1
  }
  clear_db_identity
  return "${status}"
}

run_loader_probe() {
  local remaining="$1" status
  timeout --signal=TERM --kill-after="${rkdeveloptool_kill_reap_grace_seconds}s" \
    "${remaining}s" "${rkdeveloptool}" ld &
  rkdeveloptool_pid=$!
  if wait "${rkdeveloptool_pid}"; then
    status=0
  else
    status=$?
  fi
  rkdeveloptool_pid=""
  return "${status}"
}

cp --reflink=auto --sparse=always -- "${image}" "${flash_image}"
chmod 400 "${flash_image}"
actual_sha="$(sha256sum "${flash_image}" | cut -d' ' -f1)"
[[ "${actual_sha}" == "${expected_sha}" ]] || {
  printf 'candidate raw digest mismatch: expected %s, got %s\n' "${expected_sha}" "${actual_sha}" >&2
  exit 1
}
image_bytes="$(stat -c %s "${flash_image}")"
(( image_bytes > 0 && image_bytes % 512 == 0 )) || {
  printf 'candidate raw size must be a positive multiple of 512 bytes: %s\n' "${image_bytes}" >&2
  exit 1
}
image_sectors=$((image_bytes / 512))
cp -- "${loader}" "${flash_loader}"
chmod 400 "${flash_loader}"
actual_loader_sha="$(sha256sum "${flash_loader}" | cut -d' ' -f1)"
[[ "${actual_loader_sha}" == "${loader_sha}" ]] || {
  printf 'RK3588 loader digest mismatch: expected %s, got %s\n' \
    "${loader_sha}" "${actual_loader_sha}" >&2
  exit 1
}
install -m 600 /dev/null "${ssh_known_hosts}"

ssh_bin="${CERALIVE_SSH_BIN:-ssh}"
preflash="${CERALIVE_PREFLASH_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/preflash-verify.sh}"
ssh_user="${SSH_USER:-root}"
ssh_port="${SSH_PORT:-22}"
flash_device="${CERALIVE_FLASH_DEVICE:-/dev/mmcblk0}"
rkdeveloptool="${CERALIVE_RKDEVELOPTOOL_BIN:-rkdeveloptool}"
uart_helper="${CERALIVE_UART_HELPER_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/uart-provision-ssh.sh}"
uart_public_key="${CERALIVE_UART_PUBLIC_KEY_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../mkosi/runtime" && pwd)/ceralive-ci-uart-bootstrap-public.pem}"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
  -o "UserKnownHostsFile=${ssh_known_hosts}" -o GlobalKnownHostsFile=/dev/null \
  -o IdentitiesOnly=yes -i "${ssh_identity}" -p "${ssh_port}")
remote="${ssh_user}@${board_ip}"
media_node="$(basename -- "${flash_device}")"

command -v "${rkdeveloptool}" >/dev/null 2>&1 \
  || { printf 'rkdeveloptool is required for safe whole-media flashing\n' >&2; exit 1; }
if ! command -v setsid >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
  printf 'setsid and timeout are required for bounded loader handoff\n' >&2
  exit 1
fi
[[ -x "${uart_helper}" ]] || { printf 'UART provisioning helper is not executable\n' >&2; exit 1; }
[[ -f "${uart_public_key}" && ! -L "${uart_public_key}" ]] || {
  printf 'baked UART bootstrap public key is unavailable\n' >&2
  exit 1
}
openssl pkey -in "${uart_signing_key}" -pubout -outform DER \
  -out "${verify_tmp}/runner-uart-public.der" >/dev/null 2>&1 || {
  printf 'runner UART signing key is not a usable Ed25519 private key\n' >&2
  exit 1
}
openssl pkey -pubin -in "${uart_public_key}" -pubout -outform DER \
  -out "${verify_tmp}/image-uart-public.der" >/dev/null 2>&1 || {
  printf 'image UART bootstrap public key is invalid\n' >&2
  exit 1
}
cmp -s "${verify_tmp}/runner-uart-public.der" "${verify_tmp}/image-uart-public.der" || {
  printf 'runner UART signing key does not match the public key baked into the candidate\n' >&2
  exit 1
}

if ! run_rkdeveloptool ld >"${ld_output_file}" 2>&1; then
  printf 'rkdeveloptool could not enumerate the maskrom target\n%s\n' "$(<"${ld_output_file}")" >&2
  exit 1
fi
ld_output="$(<"${ld_output_file}")"
printf '%s\n' "${ld_output}"
mapfile -t usb_devices < <(grep 'DevNo=' <<<"${ld_output}" || true)
(( ${#usb_devices[@]} == 1 )) || {
  printf 'expected exactly one rkdeveloptool target, found %s\n' "${#usb_devices[@]}" >&2
  exit 1
}
[[ "${usb_devices[0]}" =~ (^|[[:space:]])(Mode=)?Maskrom($|[[:space:]]) ]] || {
  printf 'Rockchip target is not in Maskrom mode\n' >&2
  exit 1
}
[[ "${usb_devices[0]}" =~ Vid=0x2207,Pid=0x350b ]] || {
  printf 'Maskrom target is not an RK3588 device\n' >&2
  exit 1
}
maskrom_identity="$(sed -E \
  's/^DevNo=[0-9]+[[:space:]]+//; s/[[:space:]]+/ /g; s/[[:space:]]+$//' \
  <<<"${usb_devices[0]}")"
[[ "${maskrom_identity}" =~ ^Vid=0x2207,Pid=0x350b,LocationID=([0-9]+)[[:space:]]+Maskrom$ ]]
maskrom_location_id="${BASH_REMATCH[1]}"
usb_device_sha256="$(printf '%s' "${maskrom_identity}" | sha256sum | cut -d' ' -f1)"
[[ "${usb_device_sha256}" == "${expected_maskrom_id_sha}" ]] || {
  printf 'Maskrom target is not the approved USB fixture\n' >&2
  exit 1
}
run_owned_db

loader_reenumeration_deadline=$((
  $(monotonic_nanoseconds) + loader_reenumeration_timeout_seconds * 1000000000
))
while :; do
  loader_probe_now="$(monotonic_nanoseconds)"
  loader_probe_remaining_ns=$((loader_reenumeration_deadline - loader_probe_now))
  if (( loader_probe_remaining_ns <= 0 )); then
    printf 'loader re-enumeration timed out after %ss\n' \
      "${loader_reenumeration_timeout_seconds}" >&2
    exit 1
  fi
  printf -v loader_probe_remaining '%d.%09d' \
    $((loader_probe_remaining_ns / 1000000000)) $((loader_probe_remaining_ns % 1000000000))
  set +e
  run_loader_probe "${loader_probe_remaining}" >"${ld_output_file}" 2>&1
  loader_probe_status=$?
  set -e
  if (( loader_probe_status != 0 )); then
    if (( loader_probe_status == 124 || loader_probe_status == 137 )); then
      printf 'loader re-enumeration timed out after %ss\n' \
        "${loader_reenumeration_timeout_seconds}" >&2
    else
      printf 'rkdeveloptool loader re-enumeration probe failed\n%s\n' \
        "$(<"${ld_output_file}")" >&2
    fi
    exit 1
  fi
  loader_ld_output="$(<"${ld_output_file}")"
  mapfile -t loader_usb_devices < <(grep 'DevNo=' <<<"${loader_ld_output}" || true)
  loader_non_device_output="$(sed '/DevNo=/d' <<<"${loader_ld_output}")"
  if [[ -n "${loader_non_device_output//[[:space:]]/}" ]]; then
    printf 'malformed rkdeveloptool loader re-enumeration listing\n' >&2
    exit 1
  fi
  if (( ${#loader_usb_devices[@]} > 1 )); then
    printf 'expected exactly one rkdeveloptool loader target, found %s\n' \
      "${#loader_usb_devices[@]}" >&2
    exit 1
  fi
  if (( ${#loader_usb_devices[@]} == 1 )); then
    loader_identity="$(sed -E \
      's/^DevNo=[0-9]+[[:space:]]+//; s/[[:space:]]+/ /g; s/[[:space:]]+$//' \
      <<<"${loader_usb_devices[0]}")"
    if [[ ! "${loader_identity}" =~ ^Vid=([^,]+),Pid=([^,]+),LocationID=([0-9]+)[[:space:]]+(Mode=)?([^[:space:]]+)$ ]]; then
      printf 'malformed rkdeveloptool loader re-enumeration listing\n' >&2
      exit 1
    fi
    loader_vid="${BASH_REMATCH[1]}"
    loader_pid="${BASH_REMATCH[2]}"
    loader_location_id="${BASH_REMATCH[3]}"
    loader_mode="${BASH_REMATCH[5]}"
    [[ "${loader_vid}" == 0x2207 && "${loader_pid}" == 0x350b ]] || {
      printf 'loader re-enumerated with the wrong RK3588 identity\n' >&2
      exit 1
    }
    [[ "${loader_location_id}" == "${maskrom_location_id}" ]] || {
      printf 'loader re-enumerated at a changed LocationID\n' >&2
      exit 1
    }
    if [[ "${loader_mode}" == Loader ]]; then
      printf '%s\n' "${loader_ld_output}"
      break
    fi
    [[ "${loader_mode}" == Maskrom ]] || {
      printf 'loader re-enumerated in an unknown mode\n' >&2
      exit 1
    }
  fi
  loader_probe_now="$(monotonic_nanoseconds)"
  loader_probe_remaining_ns=$((loader_reenumeration_deadline - loader_probe_now))
  (( loader_probe_remaining_ns > 0 )) || continue
  loader_poll_ns="$(awk -v seconds="${loader_reenumeration_poll_seconds}" \
    'BEGIN { printf "%.0f", seconds * 1000000000 }')"
  (( loader_poll_ns < loader_probe_remaining_ns )) || loader_poll_ns="${loader_probe_remaining_ns}"
  printf -v loader_poll_sleep '%d.%09d' \
    $((loader_poll_ns / 1000000000)) $((loader_poll_ns % 1000000000))
  sleep "${loader_poll_sleep}"
done
run_rkdeveloptool rfi >"${rfi_output_file}"
mapfile -t flash_sector_values < <(
  sed -nE 's/.*Flash Size:[[:space:]]*([0-9]+)[[:space:]]+Sectors.*/\1/p' "${rfi_output_file}"
)
(( ${#flash_sector_values[@]} == 1 )) || {
  printf 'rkdeveloptool did not report exactly one flash capacity\n' >&2
  exit 1
}
target_sectors="${flash_sector_values[0]}"
[[ "${target_sectors}" =~ ^[1-9][0-9]*$ ]]
(( image_sectors <= target_sectors )) || {
  printf 'candidate requires %s sectors but target reports %s\n' \
    "${image_sectors}" "${target_sectors}" >&2
  exit 1
}
target_bytes=$((target_sectors * 512))
run_rkdeveloptool rid >"${rid_output_file}"
flash_id_sha256="$(sha256sum "${rid_output_file}" | cut -d' ' -f1)"
"${preflash}" --image "${flash_image}" --bundle "${bundle}" --board "${board}" \
  --keyring "${keyring}" --target-size-bytes "${target_bytes}"
"${uart_helper}" --serial-dev "${serial_dev}" --authorized-key "${authorized_key}" \
  --access-id "${access_id}" --expires "${access_expires}" --host-epoch "${host_epoch}" \
  --challenge "${challenge}" --candidate-commit "${candidate_commit}" \
  --signing-key "${uart_signing_key}" \
  --start-signal "${uart_start_file}" \
  --uart-log "${uart_log}" --authorized-line-out "${authorized_line_out}" \
  --ready-out "${uart_ready_file}" &
uart_pid=$!
for _ in $(seq 1 250); do
  [[ -e "${uart_ready_file}" ]] && break
  kill -0 "${uart_pid}" 2>/dev/null || break
  sleep 0.02
done
[[ -e "${uart_ready_file}" ]] || {
  wait "${uart_pid}" 2>/dev/null || true
  uart_pid=""
  printf 'UART preflight could not obtain read/write access and an exclusive lock\n' >&2
  exit 1
}
run_rkdeveloptool wl 0 "${flash_image}"
[[ "$(stat -c %s "${flash_image}")" == "${image_bytes}" ]] || {
  printf 'private candidate snapshot changed size while flashing\n' >&2
  exit 1
}
chmod 600 "${flash_image}"
rm -f -- "${flash_image}"

if ! run_rkdeveloptool rl 0 "${image_sectors}" "${readback_image}"; then
  printf 'failed to read back flashed candidate before reset\n' >&2
  exit 1
fi
[[ "$(stat -c %s "${readback_image}")" == "${image_bytes}" ]] || {
  printf 'flashed candidate readback size mismatch\n' >&2
  exit 1
}
readback_sha="$(sha256sum "${readback_image}" | cut -d' ' -f1)"
[[ "${readback_sha}" == "${expected_sha}" ]] || {
  printf 'pre-boot media readback digest mismatch: expected %s, got %s\n' \
    "${expected_sha}" "${readback_sha}" >&2
  exit 1
}
rm -f -- "${readback_image}"
: >"${ssh_known_hosts}"
: >"${uart_start_file}"
run_rkdeveloptool rd
set +e
wait "${uart_pid}"
uart_status=$?
set -e
if (( uart_status != 0 )); then
  uart_pid=""
  printf 'UART first-boot provisioning failed with status %s\n' "${uart_status}" >&2
  exit 1
fi
uart_pid=""

attempts="${CERALIVE_RECONNECT_ATTEMPTS:-18}"
delay="${CERALIVE_RECONNECT_DELAY:-5}"
reconnected=0
for _ in $(seq 1 "${attempts}"); do
  sleep "${delay}"
  if "${ssh_bin}" "${ssh_opts[@]}" "${remote}" true >/dev/null 2>&1; then
    reconnected=1
    break
  fi
done
(( reconnected == 1 )) || { printf 'board did not reconnect after %s attempts\n' "${attempts}" >&2; exit 1; }
[[ -s "${ssh_known_hosts}" ]] || {
  printf 'SSH reconnect did not record the candidate host identity\n' >&2
  exit 1
}
boot_root_parent="$("${ssh_bin}" "${ssh_opts[@]}" "${remote}" \
  "root_source=\$(findmnt -n -o SOURCE /); root_device=\$(readlink -f -- \"\${root_source}\"); lsblk -ndo PKNAME \"\${root_device}\"" \
  | tr -d '[:space:]')"
[[ "${boot_root_parent}" == "${media_node}" ]] || {
  printf 'running root filesystem is not on the flashed eMMC device\n' >&2
  exit 1
}
marker="$("${ssh_bin}" "${ssh_opts[@]}" "${remote}" \
  "cat '/data/ceralive/ssh/ci-access/${access_id}'")"
[[ "${marker}" == $'challenge='"${challenge}"$'\ncandidate_commit='"${candidate_commit}" ]] || {
  printf 'post-boot endpoint did not present the UART-bound candidate challenge\n' >&2
  exit 1
}
post_boot_known_hosts_sha256="$(sha256sum "${ssh_known_hosts}" | cut -d' ' -f1)"
uart_log_sha256="$(sha256sum "${uart_log}" | cut -d' ' -f1)"

identity_tmp="$(mktemp "${identity_dir}/.candidate-identity.XXXXXX")"
chmod 600 "${identity_tmp}"
cat >"${identity_tmp}" <<EOF
candidate_commit=${candidate_commit}
raw_file=${raw_file}
raw_size=${image_bytes}
raw_sha256=${expected_sha}
bundle_file=${bundle_file}
keyring_sha256=$(sha256sum "${keyring}" | cut -d' ' -f1)
loader_file=${loader_file}
loader_sha256=${loader_sha}
identity_contract=pre-boot-whole-media-sha256
pre_boot_media_sha256=${readback_sha}
pre_boot_media_identity=verified
target_capacity_sectors=${target_sectors}
flash_id_sha256=${flash_id_sha256}
boot_root_parent=${boot_root_parent}
usb_device_sha256=${usb_device_sha256}
bootstrap_challenge_sha256=$(printf '%s' "${challenge}" | sha256sum | cut -d' ' -f1)
post_boot_known_hosts_sha256=${post_boot_known_hosts_sha256}
post_boot_reconnect=verified
uart_log_sha256=${uart_log_sha256}
ephemeral_ssh_access=${access_id}
flash_transport=maskrom-rkdeveloptool
EOF
mv -f -- "${identity_tmp}" "${identity_out}"
identity_tmp=""
