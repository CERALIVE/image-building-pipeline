#!/usr/bin/env bash
#
# realhw-typec-matrix.sh — decisive charged-camera Type-C role/charge matrix.
#
# Manual hardware drill only. It runs from the operator host, reads/writes the
# board through SSH, and stores one evidence directory per run. It never changes
# the installed ceralive-typec-policy service or any persistent board file.
#
# shellcheck shell=bash
# Remote script bodies are intentionally single-quoted so expansion occurs on the board.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: tests/realhw-typec-matrix.sh [--help]

Run the charged-camera Type-C matrix on a board reached over SSH. This is an
interactive, root-required, hardware-only drill. No live arm runs unless
CERALIVE_BOARD_TEST=1 is set; otherwise the script exits 77.

Arms (each uses CERALIVE_TYPEC_REPLICATES independent fresh-attach cycles):
  FORCE-SOURCE       Force port_type=source; test whether the camera presents Rd.
  DUAL-NATURAL       Set port_type=dual; record the naturally selected roles.
  DR_SWAP            From sink+device only, request data_role=host (at most 2 tries).
  PR_SWAP            From sink only, request power_role=source; never source->sink.
  VBUS-PROOF         Whenever power_role=source, require regulator enabled, a TCPM
                     source-ready/VBUS-source trace line, and operator charging proof.

Environment:
  CERALIVE_BOARD_TEST=1              required hardware-run gate
  CERALIVE_BOARD_UNATTENDED=1        skip every physical-prompt arm; never simulate it
  CERALIVE_TYPEC_REPLICATES=N         replicates per attach arm (default 3; minimum 3)
  CERALIVE_BOARD_PROMPT_TIMEOUT=SEC  prompt timeout (default 300)
  CERALIVE_TYPEC_SETTLE=SEC          attach/role-settle deadline (default 20)
  CERALIVE_TYPEC_POLL=SEC            sysfs polling interval (default 0.25)
  BOARD_IP=HOST                       required board SSH address
  SSH_USER=USER                       SSH user (default root; uses SSH_SUDO_PASS or sudo -n)
  SSH_SUDO_PASS=PASSWORD              optional non-root sudo password, sent only over SSH stdin
  SSH_PORT=PORT                       SSH port (default 22)
  SSH_IDENTITY_FILE=PATH              optional SSH private key
  SSH_KNOWN_HOSTS_FILE=PATH           optional dedicated known_hosts file
  EVIDENCE_DIR=PATH                   evidence root (default test-results/realhw-typec-matrix)
  CAMERA_BATTERY_PERCENT=N            optional typed-precondition value (required unattended)
  CAMERA_FIRMWARE_BCDDEVICE=TEXT      optional firmware/bcdDevice scope value

Machine output prefixes:
  TYPEC_ARM: <arm> SKIPPED|NOT_TESTED reason=<reason>
  TYPEC_PEER: RD_PRESENTED|RP_ONLY|MIXED
  TYPEC_DRSWAP: WORKS|FAILS|MIXED|NOT_NEEDED
  TYPEC_PRSWAP: ACCEPTED|REJECTED|MIXED|NOT_TESTED
  TYPEC_CHARGE: BOARD_SOURCES_OK|SOURCED_CHARGE_FAILED|NEVER_SOURCED|INCONCLUSIVE|NOT_TESTED
  RUN_COMPLETE

The tcpm-source-psy ONLINE field means the port is consuming VBUS (vbus_charge).
ONLINE=0/offline is expected while the board sources and is never sourcing proof.
The drill records advertised source PDOs (up to 5V/3A where exposed); it does not
measure or claim delivered current.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if (( $# != 0 )); then
  usage >&2
  printf 'realhw-typec-matrix: unknown argument: %s\n' "$1" >&2
  exit 2
fi

if [[ "${CERALIVE_BOARD_TEST:-0}" != "1" ]]; then
  printf 'SKIP: realhw-typec-matrix requires CERALIVE_BOARD_TEST=1\n'
  exit 77
fi

BOARD_IP="${BOARD_IP:-}"
SSH_USER="${SSH_USER:-root}"
SSH_SUDO_PASS="${SSH_SUDO_PASS:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_IDENTITY_FILE="${SSH_IDENTITY_FILE:-}"
SSH_KNOWN_HOSTS_FILE="${SSH_KNOWN_HOSTS_FILE:-}"
UNATTENDED="${CERALIVE_BOARD_UNATTENDED:-0}"
REPLICATES="${CERALIVE_TYPEC_REPLICATES:-3}"
PROMPT_TIMEOUT="${CERALIVE_BOARD_PROMPT_TIMEOUT:-300}"
SETTLE_SECONDS="${CERALIVE_TYPEC_SETTLE:-20}"
POLL_INTERVAL="${CERALIVE_TYPEC_POLL:-0.25}"
EVIDENCE_ROOT="${EVIDENCE_DIR:-${REPO_ROOT}/test-results/realhw-typec-matrix}"

die() { printf 'realhw-typec-matrix: ERROR: %s\n' "$*" >&2; exit 1; }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

[[ -n "${BOARD_IP}" ]] || die "BOARD_IP is required"
is_uint "${SSH_PORT}" || die "SSH_PORT must be an unsigned integer"
is_uint "${REPLICATES}" || die "CERALIVE_TYPEC_REPLICATES must be an unsigned integer"
(( REPLICATES >= 3 )) || die "CERALIVE_TYPEC_REPLICATES must be at least 3"
is_uint "${PROMPT_TIMEOUT}" || die "CERALIVE_BOARD_PROMPT_TIMEOUT must be an unsigned integer"
is_uint "${SETTLE_SECONDS}" || die "CERALIVE_TYPEC_SETTLE must be an unsigned integer"
[[ "${UNATTENDED}" == "0" || "${UNATTENDED}" == "1" ]] \
  || die "CERALIVE_BOARD_UNATTENDED must be 0 or 1"

for cmd in ssh date mkdir tee; do
  command -v "${cmd}" >/dev/null 2>&1 || die "required host command missing: ${cmd}"
done

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
[[ -z "${SSH_IDENTITY_FILE}" ]] || SSH_OPTS+=(-o IdentitiesOnly=yes -i "${SSH_IDENTITY_FILE}")
[[ -z "${SSH_KNOWN_HOSTS_FILE}" ]] || SSH_OPTS+=(
  -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS_FILE}" -o GlobalKnownHostsFile=/dev/null
)

# All arguments passed through this helper are script-controlled tokens or
# kernel-generated sysfs paths without whitespace.
ssh_run() { ssh "${SSH_OPTS[@]}" -p "${SSH_PORT}" "${SSH_USER}@${BOARD_IP}" "$@"; }
root_script() {
  local body="$1"
  shift
  if [[ "${SSH_USER}" == "root" ]]; then
    printf '%s\n' "${body}" | ssh_run bash -s -- "$@"
  elif [[ -n "${SSH_SUDO_PASS}" ]]; then
    # sudo -S consumes exactly the first stdin line; bash -s receives the untouched remainder.
    { printf '%s\n' "${SSH_SUDO_PASS}"; printf '%s\n' "${body}"; } \
      | ssh_run "sudo -S -p '' bash -s" -- "$@"
  else
    printf '%s\n' "${body}" | ssh_run sudo -n bash -s -- "$@"
  fi
}

if command -v uuidgen >/dev/null 2>&1; then
  RUN_UUID="$(uuidgen)"
else
  RUN_UUID="$(cat /proc/sys/kernel/random/uuid)"
fi
RUN_DIR="${EVIDENCE_ROOT}/${RUN_UUID}"
mkdir -p "${RUN_DIR}/snapshots"
RUN_LOG="${RUN_DIR}/run.log"
: >"${RUN_LOG}"

emit() { printf '%s\n' "$*" | tee -a "${RUN_LOG}"; }
note() { emit "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

active_role_text() {
  local raw="$1" token
  token="$(printf '%s\n' "${raw}" | sed -n 's/.*\[\([a-z_]\{1,\}\)\].*/\1/p')"
  if [[ -n "${token}" ]]; then printf '%s\n' "${token}"
  else printf '%s\n' "${raw//[[:space:]]/}"
  fi
}

remote_attr_raw() {
  root_script 'test -r "$1" && cat -- "$1"' "$1"
}

remote_attr_active() {
  local raw
  raw="$(remote_attr_raw "$1")" || return 1
  active_role_text "${raw}"
}

remote_write() {
  local path="$1" value="$2"
  root_script 'printf "%s\n" "$2" >"$1"' "${path}" "${value}"
}

TYPEC_PORT="/sys/class/typec/port0"
PORT_TYPE="${TYPEC_PORT}/port_type"
POWER_ROLE="${TYPEC_PORT}/power_role"
DATA_ROLE="${TYPEC_PORT}/data_role"
PARTNER="/sys/class/typec/port0-partner"

TCPM_LOG=""
REGULATOR_DIR=""
ORIGINAL_PORT_TYPE=""
ORIGINAL_POWER_ROLE=""
ORIGINAL_DATA_ROLE=""
WROTE_PORT_TYPE=0
WROTE_POWER_ROLE=0
WROTE_DATA_ROLE=0
RESTORE_DONE=0
CURRENT_TRACE_START=0
TCPM_TRACE_BUFFER=""
TCPM_TRACE_LINES=0

restore_sysfs() {
  local rc=0 now
  (( RESTORE_DONE == 0 )) || return 0
  RESTORE_DONE=1
  note "RESTORE_BEGIN port_type=${ORIGINAL_PORT_TYPE} power_role=${ORIGINAL_POWER_ROLE} data_role=${ORIGINAL_DATA_ROLE}"

  if (( WROTE_POWER_ROLE == 1 )); then
    now="$(remote_attr_active "${POWER_ROLE}" 2>/dev/null || printf unknown)"
    if [[ "${now}" == "${ORIGINAL_POWER_ROLE}" ]] \
      || remote_write "${POWER_ROLE}" "${ORIGINAL_POWER_ROLE}" 2>/dev/null; then
      note "RESTORE_OK power_role=${ORIGINAL_POWER_ROLE}"
    else
      note "RESTORE_FAIL power_role=${ORIGINAL_POWER_ROLE}"; rc=1
    fi
  fi
  if (( WROTE_DATA_ROLE == 1 )); then
    now="$(remote_attr_active "${DATA_ROLE}" 2>/dev/null || printf unknown)"
    if [[ "${now}" == "${ORIGINAL_DATA_ROLE}" ]] \
      || remote_write "${DATA_ROLE}" "${ORIGINAL_DATA_ROLE}" 2>/dev/null; then
      note "RESTORE_OK data_role=${ORIGINAL_DATA_ROLE}"
    else
      note "RESTORE_FAIL data_role=${ORIGINAL_DATA_ROLE}"; rc=1
    fi
  fi
  if (( WROTE_PORT_TYPE == 1 )); then
    now="$(remote_attr_active "${PORT_TYPE}" 2>/dev/null || printf unknown)"
    if [[ "${now}" == "${ORIGINAL_PORT_TYPE}" ]] \
      || remote_write "${PORT_TYPE}" "${ORIGINAL_PORT_TYPE}" 2>/dev/null; then
      note "RESTORE_OK port_type=${ORIGINAL_PORT_TYPE}"
    else
      note "RESTORE_FAIL port_type=${ORIGINAL_PORT_TYPE}"; rc=1
    fi
  fi
  note "RESTORE_END status=$([[ ${rc} -eq 0 ]] && printf OK || printf FAILED)"
  return "${rc}"
}

cleanup() {
  local prior="$?"
  if (( RESTORE_DONE == 0 )); then restore_sysfs || prior=1; fi
  return "${prior}"
}
on_signal() { note "INTERRUPTED signal=$1"; exit 130; }
trap cleanup EXIT
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal QUIT' QUIT
trap 'on_signal TERM' TERM

irq_count() {
  root_script '
    awk "/fsc_interrupt_int_n/ { sum=0; for (i=2; i<=NF; i++) { if (\$i ~ /^[0-9]+$/) sum += \$i; else break } found=1 } END { if (found) print sum; else print 0 }" /proc/interrupts
  '
}

# The TCPM debugfs log is DRAIN-ON-READ — tcpm_debug_show() advances logbuffer_tail on
# every read — so the second reader inside one detection window always sees an empty file.
# tcpm_drain is the ONLY reader; every check below consumes the accumulated buffer instead.
# It must never be called from a $( ) subshell: the appended lines would be discarded.
tcpm_drain() {
  local chunk n
  [[ -n "${TCPM_LOG}" ]] || return 0
  chunk="$(root_script 'test -r "$1" && cat -- "$1"' "${TCPM_LOG}" 2>/dev/null)" || return 0
  [[ -n "${chunk}" ]] || return 0
  TCPM_TRACE_BUFFER="${TCPM_TRACE_BUFFER}${chunk}"$'\n'
  n="$(printf '%s\n' "${chunk}" | wc -l)"
  TCPM_TRACE_LINES=$(( TCPM_TRACE_LINES + n ))
}

# Emits the buffer from line "$1"+1 onward. Never pipes into a short-circuiting reader:
# grep -q would SIGPIPE the writer and pipefail would report a correct read as a failure.
tcpm_trace_since() {
  local start="$1"
  [[ -n "${TCPM_TRACE_BUFFER}" ]] || return 0
  printf '%s' "${TCPM_TRACE_BUFFER}" | tail -n "+$((start + 1))"
}

capture_snapshot() {
  local label="$1" safe file
  safe="${label//[^a-zA-Z0-9_.-]/_}"
  file="${RUN_DIR}/snapshots/${safe}.txt"
  tcpm_drain
  root_script '
    set +e
    label=$1; port=$2; regulator=$3
    printf "SNAPSHOT: %s\nUTC: %s\n" "$label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for attr in port_type power_role data_role power_operation_mode preferred_role; do
      printf "ROLE %s: " "$attr"
      if test -r "$port/$attr"; then cat "$port/$attr"; else printf "UNAVAILABLE\n"; fi
    done
    if test -e "${port}-partner"; then printf "PARTNER: PRESENT\n"; else printf "PARTNER: ABSENT\n"; fi
    printf "IRQ fsc_interrupt_int_n: "
    awk "/fsc_interrupt_int_n/ { print; found=1 } END { if (!found) print \"UNAVAILABLE\" }" /proc/interrupts
    printf "REGULATOR vbus5v0_typec path: %s\n" "${regulator:-UNAVAILABLE}"
    if test -n "$regulator"; then
      for attr in name state status microvolts; do
        printf "REGULATOR %s: " "$attr"
        if test -r "$regulator/$attr"; then cat "$regulator/$attr"; else printf "UNAVAILABLE\n"; fi
      done
    fi
    found=0
    for psy in /sys/class/power_supply/tcpm-source-psy-*; do
      test -e "$psy" || continue
      found=1
      printf "PSY %s uevent BEGIN\n" "$psy"; cat "$psy/uevent"; printf "PSY uevent END\n"
    done
    test "$found" -eq 1 || printf "PSY tcpm-source-psy: UNAVAILABLE\n"
  ' "${label}" "${TYPEC_PORT}" "${REGULATOR_DIR}" >"${file}"
  {
    printf 'TCPM source PDO/source-ready excerpts BEGIN\n'
    if [[ -n "${TCPM_TRACE_BUFFER}" ]]; then
      grep -Ei "source.?pdo|src_ready|source.ready|vbus.*source|source.*vbus|attached_src" \
        <<<"${TCPM_TRACE_BUFFER}" | tail -80
    else
      printf 'UNAVAILABLE\n'
    fi
    printf 'TCPM source PDO/source-ready excerpts END\n'
    printf 'TCPM LOG SOURCE: run-cumulative drained buffer (debugfs log is drain-on-read)\n'
    printf 'TCPM LOG BEGIN\n'
    if [[ -n "${TCPM_TRACE_BUFFER}" ]]; then printf '%s' "${TCPM_TRACE_BUFFER}"; else printf 'UNAVAILABLE\n'; fi
    printf 'TCPM LOG END\n'
  } >>"${file}"
  note "SNAPSHOT ${label} file=${file}"
}

prompt_token() {
  local prompt="$1" wanted="$2" reply
  [[ "${UNATTENDED}" == "0" ]] || return 77
  if [[ ! -r /dev/tty ]]; then return 1; fi
  if ! IFS= read -r -t "${PROMPT_TIMEOUT}" -p "${prompt} Type ${wanted}: " reply </dev/tty; then
    return 1
  fi
  [[ "${reply}" == "${wanted}" ]]
}

wait_partner_state() {
  local wanted="$1" deadline=$((SECONDS + SETTLE_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ "${wanted}" == "present" ]] && root_script 'test -e "$1"' "${PARTNER}"; then return 0; fi
    if [[ "${wanted}" == "absent" ]] && ! root_script 'test -e "$1"' "${PARTNER}"; then return 0; fi
    sleep "${POLL_INTERVAL}"
  done
  return 1
}

camera_enumerated() {
  root_script '
    for d in /sys/bus/usb/devices/*; do
      test -r "$d/idVendor" || continue
      read -r vid <"$d/idVendor"
      test "$vid" = 2ca3 && exit 0
    done
    exit 1
  '
}

prepare_detach() {
  local arm="$1" rep="$2" before_irq after_irq before_lines since elapsed start trace_event=0
  capture_snapshot "${arm}.r${rep}.detach-before"
  before_irq="$(irq_count)"; before_lines="${TCPM_TRACE_LINES}"
  start="$(date +%s)"
  note "ACTION_REQUIRED arm=${arm} replicate=${rep} action=physical-unplug minimum_seconds=10"
  if ! prompt_token "Unplug the camera completely and keep it unplugged for at least 10 seconds." DETACHED; then
    note "DETACH_FAIL arm=${arm} replicate=${rep} reason=operator-confirmation"
    return 1
  fi
  elapsed=$(( $(date +%s) - start ))
  (( elapsed >= 10 )) || { note "DETACH_FAIL arm=${arm} replicate=${rep} reason=under-10-seconds"; return 1; }
  wait_partner_state absent || { note "DETACH_FAIL arm=${arm} replicate=${rep} reason=partner-still-present"; return 1; }
  tcpm_drain
  after_irq="$(irq_count)"
  if (( after_irq > before_irq )); then trace_event=1; fi
  since="$(tcpm_trace_since "${before_lines}")"
  if [[ -n "${since}" ]] \
    && grep -Eqi "unattached|detach|CC[12]:.*-> 0|PORT_RESET" <<<"${since}"; then trace_event=1; fi
  (( trace_event == 1 )) || {
    note "DETACH_FAIL arm=${arm} replicate=${rep} reason=no-irq-or-tcpm-detach-transition before_irq=${before_irq} after_irq=${after_irq}"
    return 1
  }
  capture_snapshot "${arm}.r${rep}.detach-after"
  note "DETACH_OK arm=${arm} replicate=${rep} elapsed=${elapsed}s irq_delta=$((after_irq-before_irq))"
}

prompt_replug() {
  local arm="$1" rep="$2"
  note "ACTION_REQUIRED arm=${arm} replicate=${rep} action=physical-replug"
  prompt_token "Reconnect the camera now; this confirmation covers this replug only." REPLUGGED
}

write_role() {
  local path="$1" value="$2" kind="$3" label="$4"
  capture_snapshot "${label}.before"
  case "${kind}" in
    port_type) WROTE_PORT_TYPE=1 ;;
    power_role) WROTE_POWER_ROLE=1 ;;
    data_role) WROTE_DATA_ROLE=1 ;;
  esac
  if remote_write "${path}" "${value}"; then
    note "WRITE_OK attribute=${kind} value=${value}"
    capture_snapshot "${label}.after"
    return 0
  fi
  note "WRITE_REJECTED attribute=${kind} value=${value}"
  capture_snapshot "${label}.rejected"
  return 1
}

regulator_enabled() {
  [[ -n "${REGULATOR_DIR}" ]] || return 1
  root_script 'test -r "$1/state" && grep -qx enabled "$1/state"' "${REGULATOR_DIR}"
}

trace_proves_source() {
  local since
  since="$(tcpm_trace_since "${CURRENT_TRACE_START}")"
  [[ -n "${since}" ]] || return 1
  grep -Eqi "SRC_READY|source.ready|vbus.*source|source.*vbus|attached_src" <<<"${since}"
}

SOURCE_OBS=0
CHARGE_OK=0
CHARGE_FAILED=0
CHARGE_INCONCLUSIVE=0

assess_source_charge() {
  local label="$1" regulator=0 trace=0 operator=0
  [[ "$(remote_attr_active "${POWER_ROLE}" 2>/dev/null || printf unknown)" == "source" ]] || return 0
  SOURCE_OBS=$((SOURCE_OBS + 1))
  capture_snapshot "${label}.vbus-proof"
  regulator_enabled && regulator=1
  trace_proves_source && trace=1
  if prompt_token "Board is sourcing. Confirm the camera screen currently shows charging." CHARGING; then operator=1; fi
  note "VBUS_PROOF label=${label} regulator_enabled=${regulator} tcpm_source_ready=${trace} operator_charging=${operator} psy_online_is_not_source_proof=true"
  if (( regulator == 1 && trace == 1 && operator == 1 )); then
    CHARGE_OK=$((CHARGE_OK + 1))
  elif (( regulator == 1 && (trace == 0 || operator == 0) )); then
    CHARGE_FAILED=$((CHARGE_FAILED + 1))
  else
    CHARGE_INCONCLUSIVE=$((CHARGE_INCONCLUSIVE + 1))
  fi
}

RD_PRESENT=0
RD_ABSENT=0
DR_WORKS=0
DR_FAILS=0
DR_NEEDED=0
PR_ACCEPT=0
PR_REJECT=0
PR_TESTED=0

run_force_source() {
  local rep power prev_attached=1
  # A function's ENTRY state is a contract too. collect_provenance writes nothing and
  # restore_sysfs never waits for a re-attach, so an aborted prior run hands this arm a
  # port with no partner and replicate 1's prepare_detach has nothing to transition out of.
  if ! root_script 'test -e "$1"' "${PARTNER}"; then
    note "FORCE_SOURCE_PRELOOP_RESTORE_DUAL reason=entry-no-attach"
    write_role "${PORT_TYPE}" dual port_type "force-source.preloop-restore-dual" || return 1
    prompt_replug FORCE_SOURCE pre || return 1
    if ! wait_partner_state present; then
      capture_snapshot "force-source.preloop-restore-dual.attach-timeout"
      note "FORCE_SOURCE_PRELOOP_RESTORE_DUAL_FAIL reason=partner-absent"
      return 1
    fi
    capture_snapshot "force-source.preloop-restore-dual.attach-confirmed"
    note "FORCE_SOURCE_PRELOOP_RESTORE_DUAL_OK"
  fi
  for ((rep=1; rep<=REPLICATES; rep++)); do
    # An Rp-only peer never attaches under port_type=source, so a cable pull from that
    # state emits no IRQ and no TCPM transition and prepare_detach fails closed on a
    # physically correct unplug. Restore dual so there is a real attach to leave.
    if (( rep > 1 && prev_attached == 0 )); then
      note "FORCE_SOURCE_RESTORE_DUAL replicate=${rep} reason=prior-replicate-no-attach"
      write_role "${PORT_TYPE}" dual port_type "force-source.r${rep}.pre-restore-dual" || return 1
      if ! wait_partner_state present; then
        capture_snapshot "force-source.r${rep}.pre-restore-dual.attach-timeout"
        note "FORCE_SOURCE_RESTORE_DUAL_FAIL replicate=${rep} reason=partner-absent"
        return 1
      fi
      capture_snapshot "force-source.r${rep}.pre-restore-dual.attach-confirmed"
      note "FORCE_SOURCE_RESTORE_DUAL_OK replicate=${rep}"
    fi
    prepare_detach FORCE_SOURCE "${rep}" || return 1
    write_role "${PORT_TYPE}" source port_type "force-source.r${rep}.set-source" || return 1
    tcpm_drain; CURRENT_TRACE_START="${TCPM_TRACE_LINES}"
    prompt_replug FORCE_SOURCE "${rep}" || return 1
    capture_snapshot "force-source.r${rep}.attach-before"
    if wait_partner_state present; then
      prev_attached=1
      capture_snapshot "force-source.r${rep}.attach-after"
      power="$(remote_attr_active "${POWER_ROLE}" 2>/dev/null || printf unknown)"
      if [[ "${power}" == "source" ]]; then RD_PRESENT=$((RD_PRESENT + 1))
      else RD_ABSENT=$((RD_ABSENT + 1)); fi
      assess_source_charge "force-source.r${rep}"
    else
      prev_attached=0
      RD_ABSENT=$((RD_ABSENT + 1))
      capture_snapshot "force-source.r${rep}.attach-timeout"
    fi
  done
  # Same unattached-under-source state at the ARM BOUNDARY: the last replicate has no
  # successor to restore for it, so the next arm's first prepare_detach would inherit it.
  (( prev_attached == 0 )) || return 0
  note "FORCE_SOURCE_POSTLOOP_RESTORE_DUAL replicates=${REPLICATES} reason=last-replicate-no-attach"
  write_role "${PORT_TYPE}" dual port_type "force-source.postloop-restore-dual" || return 1
  if ! wait_partner_state present; then
    capture_snapshot "force-source.postloop-restore-dual.attach-timeout"
    note "FORCE_SOURCE_POSTLOOP_RESTORE_DUAL_FAIL reason=partner-absent"
    return 1
  fi
  capture_snapshot "force-source.postloop-restore-dual.attach-confirmed"
  note "FORCE_SOURCE_POSTLOOP_RESTORE_DUAL_OK"
}

run_dr_swap() {
  local rep="$1" attempt
  DR_NEEDED=$((DR_NEEDED + 1))
  for attempt in 1 2; do
    if write_role "${DATA_ROLE}" host data_role "dual.r${rep}.dr-swap.a${attempt}"; then
      sleep 1
      if [[ "$(remote_attr_active "${DATA_ROLE}" 2>/dev/null || printf unknown)" == "host" ]] \
        && camera_enumerated; then
        DR_WORKS=$((DR_WORKS + 1))
        note "DR_SWAP_OK replicate=${rep} attempt=${attempt} camera_vid=2ca3"
        return 0
      fi
    fi
    sleep 1
  done
  DR_FAILS=$((DR_FAILS + 1))
  note "DR_SWAP_FAIL replicate=${rep} attempts=2"
  return 1
}

run_pr_swap() {
  local rep="$1"
  PR_TESTED=$((PR_TESTED + 1))
  tcpm_drain; CURRENT_TRACE_START="${TCPM_TRACE_LINES}"
  if write_role "${POWER_ROLE}" source power_role "dual.r${rep}.pr-swap"; then
    sleep 1
    if [[ "$(remote_attr_active "${POWER_ROLE}" 2>/dev/null || printf unknown)" == "source" ]] \
      && root_script 'test -e "$1"' "${PARTNER}"; then
      PR_ACCEPT=$((PR_ACCEPT + 1))
      note "PR_SWAP_ACCEPTED replicate=${rep} direction=sink-to-source"
      assess_source_charge "dual.r${rep}.pr-swap"
      return 0
    fi
  fi
  PR_REJECT=$((PR_REJECT + 1))
  note "PR_SWAP_REJECTED replicate=${rep} direction=sink-to-source"
  return 1
}

run_dual() {
  local rep power data
  for ((rep=1; rep<=REPLICATES; rep++)); do
    prepare_detach DUAL_NATURAL "${rep}" || return 1
    write_role "${PORT_TYPE}" dual port_type "dual.r${rep}.set-dual" || return 1
    tcpm_drain; CURRENT_TRACE_START="${TCPM_TRACE_LINES}"
    prompt_replug DUAL_NATURAL "${rep}" || return 1
    capture_snapshot "dual.r${rep}.attach-before"
    wait_partner_state present || {
      capture_snapshot "dual.r${rep}.attach-timeout"
      note "DUAL_ATTACH_FAIL replicate=${rep} reason=partner-absent"
      return 1
    }
    sleep 1
    capture_snapshot "dual.r${rep}.attach-after"
    power="$(remote_attr_active "${POWER_ROLE}" 2>/dev/null || printf unknown)"
    data="$(remote_attr_active "${DATA_ROLE}" 2>/dev/null || printf unknown)"
    note "DUAL_NATURAL_ROLE replicate=${rep} power_role=${power} data_role=${data}"
    if [[ "${power}" == "source" ]]; then
      RD_PRESENT=$((RD_PRESENT + 1))
      assess_source_charge "dual.r${rep}.natural-source"
    elif [[ "${power}" == "sink" ]]; then
      RD_ABSENT=$((RD_ABSENT + 1))
      if [[ "${data}" == "device" ]]; then run_dr_swap "${rep}" || true; fi
      # Only sink->source is evidence-bearing. Never issue source->sink.
      run_pr_swap "${rep}" || true
    else
      note "DUAL_ATTACH_FAIL replicate=${rep} reason=unknown-power-role"
      return 1
    fi
  done
}

collect_provenance() {
  local remote_host remote_uname battery firmware auto_scope
  remote_host="$(ssh_run hostname)" || die "cannot SSH to ${SSH_USER}@${BOARD_IP}:${SSH_PORT}"
  remote_uname="$(ssh_run uname -a)" || die "cannot read board uname"
  root_script 'test "$(id -u)" -eq 0' || die "root is required (use SSH_USER=root or passwordless sudo -n)"
  root_script 'test -r "$1" && test -w "$1" && test -r "$2" && test -w "$2" && test -r "$3" && test -w "$3"' \
    "${PORT_TYPE}" "${POWER_ROLE}" "${DATA_ROLE}" || die "port0 role attributes must be readable and writable"

  TCPM_LOG="$(root_script 'for f in /sys/kernel/debug/usb/tcpm-*/log; do test -r "$f" && { printf "%s\n" "$f"; exit 0; }; done; exit 1')" \
    || die "no readable /sys/kernel/debug/usb/tcpm-*/log (debugfs/root required)"
  REGULATOR_DIR="$(root_script '
    for d in /sys/class/regulator/regulator*; do
      test -r "$d/name" || continue
      read -r name <"$d/name"
      test "$name" = vbus5v0_typec && { printf "%s\n" "$d"; exit 0; }
    done
    exit 1
  ' 2>/dev/null || true)"

  ORIGINAL_PORT_TYPE="$(remote_attr_active "${PORT_TYPE}")" || die "cannot read port_type"
  ORIGINAL_POWER_ROLE="$(remote_attr_active "${POWER_ROLE}")" || die "cannot read power_role"
  ORIGINAL_DATA_ROLE="$(remote_attr_active "${DATA_ROLE}")" || die "cannot read data_role"

  battery="${CAMERA_BATTERY_PERCENT:-}"
  if [[ -z "${battery}" && "${UNATTENDED}" == "0" ]]; then
    if [[ -r /dev/tty ]]; then
      IFS= read -r -t "${PROMPT_TIMEOUT}" -p "Enter the exact Osmo on-screen battery percentage (integer, must be >=30): " battery </dev/tty || battery=""
    fi
  fi
  is_uint "${battery}" || die "camera battery percentage was not confirmed"
  (( battery >= 30 && battery <= 100 )) || die "camera battery must be confirmed at >=30% (reported ${battery}%)"

  auto_scope="$(root_script '
    for d in /sys/bus/usb/devices/*; do
      test -r "$d/idVendor" || continue
      read -r vid <"$d/idVendor"; test "$vid" = 2ca3 || continue
      product=unknown; bcd=unknown
      test -r "$d/product" && read -r product <"$d/product"
      test -r "$d/bcdDevice" && read -r bcd <"$d/bcdDevice"
      printf "%s bcdDevice=%s\n" "$product" "$bcd"; exit 0
    done
    exit 1
  ' 2>/dev/null || true)"
  firmware="${CAMERA_FIRMWARE_BCDDEVICE:-${auto_scope}}"
  if [[ -z "${firmware}" && "${UNATTENDED}" == "0" && -r /dev/tty ]]; then
    IFS= read -r -t "${PROMPT_TIMEOUT}" -p "Camera is not enumerated. Enter camera firmware and/or bcdDevice exactly as displayed/known: " firmware </dev/tty || firmware=""
  fi
  [[ -n "${firmware}" ]] || die "camera firmware/bcdDevice scope was not recorded"

  {
    printf 'PROVENANCE_BEGIN\n'
    printf 'run_uuid: %s\n' "${RUN_UUID}"
    printf 'started_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'operator_hostname: %s\n' "$(hostname)"
    printf 'board_hostname: %s\n' "${remote_host}"
    printf 'board_uname: %s\n' "${remote_uname}"
    printf 'board_target: %s@%s:%s\n' "${SSH_USER}" "${BOARD_IP}" "${SSH_PORT}"
    printf 'replicates: %s\n' "${REPLICATES}"
    printf 'camera_battery_percent: %s\n' "${battery}"
    printf 'camera_firmware_bcdDevice: %s\n' "${firmware}"
    printf 'tcpm_log: %s\n' "${TCPM_LOG}"
    printf 'vbus5v0_typec_regulator: %s\n' "${REGULATOR_DIR:-UNAVAILABLE}"
    printf 'original_port_type: %s\n' "${ORIGINAL_PORT_TYPE}"
    printf 'original_power_role: %s\n' "${ORIGINAL_POWER_ROLE}"
    printf 'original_data_role: %s\n' "${ORIGINAL_DATA_ROLE}"
    printf 'PROVENANCE_END\n'
  } | tee -a "${RUN_LOG}"
  capture_snapshot pre-run
}

emit_verdicts() {
  local peer dr pr charge
  if (( RD_PRESENT > 0 && RD_ABSENT == 0 )); then peer=RD_PRESENTED
  elif (( RD_ABSENT > 0 && RD_PRESENT == 0 )); then peer=RP_ONLY
  else peer=MIXED
  fi

  if (( DR_NEEDED == 0 )); then dr=NOT_NEEDED
  elif (( DR_WORKS > 0 && DR_FAILS == 0 )); then dr=WORKS
  elif (( DR_FAILS > 0 && DR_WORKS == 0 )); then dr=FAILS
  else dr=MIXED
  fi

  if (( PR_TESTED == 0 )); then pr=NOT_TESTED
  elif (( PR_ACCEPT == PR_TESTED && PR_REJECT == 0 )); then pr=ACCEPTED
  elif (( PR_REJECT == PR_TESTED && PR_ACCEPT == 0 )); then pr=REJECTED
  else pr=MIXED
  fi

  if (( SOURCE_OBS == 0 )); then charge=NEVER_SOURCED
  elif (( CHARGE_FAILED > 0 )); then charge=SOURCED_CHARGE_FAILED
  elif (( CHARGE_INCONCLUSIVE > 0 )); then charge=INCONCLUSIVE
  elif (( CHARGE_OK == SOURCE_OBS )); then charge=BOARD_SOURCES_OK
  else charge=INCONCLUSIVE
  fi

  # Any MIXED verdict routes todo 21 conservatively: treat the peer as RP_ONLY
  # and never attempt PR_SWAP. Variability is not permission to take the risky arm.
  emit "TYPEC_PEER: ${peer}"
  emit "TYPEC_DRSWAP: ${dr}"
  emit "TYPEC_PRSWAP: ${pr}"
  emit "TYPEC_CHARGE: ${charge}"
}

main() {
  collect_provenance

  if [[ "${UNATTENDED}" == "1" ]]; then
    emit "TYPEC_ARM: FORCE_SOURCE SKIPPED reason=unattended"
    emit "TYPEC_ARM: DUAL_NATURAL SKIPPED reason=unattended"
    emit "TYPEC_ARM: DR_SWAP NOT_TESTED reason=unattended"
    emit "TYPEC_ARM: PR_SWAP NOT_TESTED reason=unattended"
    restore_sysfs || return 1
    emit "TYPEC_PEER: MIXED"
    emit "TYPEC_DRSWAP: MIXED"
    emit "TYPEC_PRSWAP: NOT_TESTED"
    emit "TYPEC_CHARGE: NOT_TESTED"
    printf 'RUN_COMPLETE\n' | tee -a "${RUN_LOG}" "${RUN_DIR}/RUN_COMPLETE"
    return 0
  fi

  run_force_source || return 1
  run_dual || return 1
  capture_snapshot post-arms
  restore_sysfs || return 1
  emit_verdicts
  printf 'RUN_COMPLETE\n' | tee -a "${RUN_LOG}" "${RUN_DIR}/RUN_COMPLETE"
}

main "$@"
