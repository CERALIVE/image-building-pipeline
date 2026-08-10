#!/usr/bin/env bash
#
# run-rk3588-hardware-drill.sh — the DRIVER Wave 8's hardware todos invoke
# against a board, and the producer of the append-only per-receipt command
# manifest those todos' receipts attest.
#
# Argument parsing, profile selection and evidence wiring are complete. The
# board-command EXECUTION path is dependency-injected: `drill_exec` is resolved
# from `CERALIVE_DRILL_EXEC`, defaulting to `drill_exec_ssh`. That is what makes
# the driver testable with a stubbed transport, exactly as the Wave 5 lore
# importer and the Wave 6 system-heap KUnit test injected their own effectful
# dependency — same pattern, different language.
#
# IT REFUSES TO TOUCH A REAL BOARD UNLESS EXPLICITLY ARMED. `--dry-run` (the
# default) records the exact command lines it WOULD run and executes nothing;
# a real run additionally requires `--host` and `CERALIVE_DRILL_ALLOW_REAL=1`,
# so an accidental invocation cannot reach hardware.
#
# Usage:
#   run-rk3588-hardware-drill.sh --profile candidate --board rock-5b-plus \
#                                --evidence <dir> [--target <label>] \
#                                [--host <ip>] [--dry-run|--execute] [--todo N]
#   run-rk3588-hardware-drill.sh --self-test
#
# Evidence layout (all A-local, Rule D):
#   <evidence>/<target>/t<NN>.commands.txt   append-only, one executed command
#                                            per line, in execution order
#   <evidence>/<target>/t<NN>.transcript.log per-command stdout/stderr + status
#   <evidence>/<target>/t<NN>.dmesg.log      the decisive kernel log
#
# Exit codes: 0 ok, 1 drill failure / refused, 2 usage.
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/board-identity.sh
source "${HERE}/board-identity.sh"
# shellcheck source=ci/destructive-target-guard.sh
source "${HERE}/destructive-target-guard.sh"

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'hardware-drill: %s\n' "$*" >&2; exit 1; }

DRILL_QA_DIR="/tmp/ceralive-qa"

# drill_profile_commands <profile> — the normative board command lines for a
# profile, in execution order. These are DATA: the receipt attests the manifest
# these produce, so an edit here changes what a later receipt claims was run.
drill_profile_commands() {
  case "$1" in
    candidate)
      printf '%s\n' \
        'set -Eeuo pipefail' \
        'uname -a' \
        'cat /proc/cmdline' \
        'cat /sys/firmware/devicetree/base/compatible | tr "\\0" "\\n"' \
        'rauc status --output-format=json' \
        "sudo ${DRILL_QA_DIR}/hw-smoke.sh --case encode" \
        "sudo ${DRILL_QA_DIR}/hw-smoke.sh --case wifi" \
        "sudo ${DRILL_QA_DIR}/hw-smoke.sh --case bluetooth" \
        "sudo ${DRILL_QA_DIR}/hw-smoke.sh --case mmc" \
        "sudo ${DRILL_QA_DIR}/hw-smoke.sh --case usb3" \
        'journalctl -k --no-pager -b 0'
      ;;
    debug)
      printf '%s\n' \
        'set -Eeuo pipefail' \
        'sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs debugfs /sys/kernel/debug' \
        "sudo ${DRILL_QA_DIR}/rkvenc-fault-qa.sh --case fail-service-attach --debugfs /sys/kernel/debug/rkvenc-test --device /dev/mpp_service" \
        "sudo ${DRILL_QA_DIR}/rkvenc-fault-qa.sh --case fail-ccu-attach --debugfs /sys/kernel/debug/rkvenc-test --device /dev/mpp_service" \
        "sudo ${DRILL_QA_DIR}/rkvenc-fault-qa.sh --case fail-irq-request --debugfs /sys/kernel/debug/rkvenc-test --device /dev/mpp_service" \
        "sudo ${DRILL_QA_DIR}/rkvenc-fault-qa.sh --case delayed-teardown --debugfs /sys/kernel/debug/rkvenc-test --device /dev/mpp_service" \
        "sudo ${DRILL_QA_DIR}/rkvenc-unbind.sh" \
        "sudo ${DRILL_QA_DIR}/hdmirx-audio-fault-qa.sh" \
        'journalctl -k --no-pager -b 0'
      ;;
    recovery)
      printf '%s\n' \
        'set -Eeuo pipefail' \
        'ceralive-boot-state dump' \
        'rauc status --output-format=json' \
        'journalctl -k --no-pager -b 0'
      ;;
    *) return 1 ;;
  esac
}

# drill_exec_ssh <host> <command> — the REAL transport. Never reached under
# --dry-run and never reached without CERALIVE_DRILL_ALLOW_REAL=1.
drill_exec_ssh() {
  local host="$1" command="$2"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${host}" "${command}"
}

# drill_exec_refuse — the DEFAULT under --dry-run. Executing nothing is what
# makes an un-armed invocation safe.
drill_exec_refuse() {
  printf 'DRY-RUN (not executed): %s\n' "$2"
  return 0
}

run_drill() {
  local profile="$1" board="$2" evidence="$3" target="$4" todo="$5" host="$6" execute="$7"
  local exec_fn commands=() command manifest transcript kernel_log status failures=0 out

  board_identity_load "${board}" || exit 1
  guard_assert_local_evidence_dir 'drill evidence directory' "${evidence}" || exit 1

  mapfile -t commands < <(drill_profile_commands "${profile}") \
    || die "unknown profile: ${profile}"
  (( ${#commands[@]} > 0 )) || die "unknown profile: ${profile}"

  exec_fn="${CERALIVE_DRILL_EXEC:-}"
  if [[ -z "${exec_fn}" ]]; then
    if (( execute == 1 )); then exec_fn=drill_exec_ssh; else exec_fn=drill_exec_refuse; fi
  fi
  declare -F "${exec_fn}" >/dev/null \
    || die "command executor '${exec_fn}' is not a defined function"

  if (( execute == 1 )); then
    [[ "${CERALIVE_DRILL_ALLOW_REAL:-0}" == 1 ]] \
      || die "--execute needs CERALIVE_DRILL_ALLOW_REAL=1; refusing to touch a board"
    [[ -n "${host}" ]] || die "--execute needs --host"
  fi

  mkdir -p "${evidence}/${target}" || die "could not create ${evidence}/${target}"
  manifest="${evidence}/${target}/t${todo}.commands.txt"
  transcript="${evidence}/${target}/t${todo}.transcript.log"
  kernel_log="${evidence}/${target}/t${todo}.dmesg.log"
  [[ ! -e "${manifest}" ]] \
    || die "command manifest already exists and is append-only: ${manifest}"
  : >"${manifest}"
  : >"${transcript}"
  : >"${kernel_log}"

  {
    printf 'drill profile=%s board=%s board_id=%s dtb=%s compatible=%s target=%s todo=%s execute=%s\n' \
      "${profile}" "${BOARD_IDENTITY_BOARD}" "${BOARD_IDENTITY_BOARD_ID}" \
      "${BOARD_IDENTITY_DTB}" "${BOARD_IDENTITY_COMPATIBLE}" "${target}" "${todo}" "${execute}"
  } >>"${transcript}"

  for command in "${commands[@]}"; do
    # The manifest line is written BEFORE execution, so a command that hangs or
    # bricks the board is still recorded as attempted. The receipt digests these
    # exact bytes.
    printf '%s\n' "${command}" >>"${manifest}"
    out="$("${exec_fn}" "${host}" "${command}" 2>&1)"; status=$?
    printf '=== %s\n%s\n--- status=%s\n' "${command}" "${out}" "${status}" >>"${transcript}"
    if [[ "${command}" == journalctl\ -k* ]]; then
      printf '%s\n' "${out}" >"${kernel_log}"
    fi
    (( status == 0 )) || failures=$((failures + 1))
  done

  printf 'DRILL %s profile=%s board=%s target=%s commands=%s failures=%s manifest=%s\n' \
    "$( ((failures == 0)) && printf ok || printf FAILED )" \
    "${profile}" "${board}" "${target}" "${#commands[@]}" "${failures}" "${manifest}"
  (( failures == 0 ))
}

# ---------------------------------------------------------------------------
# self-test — drives both shipped profiles through a stubbed transport and then
# every refusal path. No SSH, no board, no network.
# ---------------------------------------------------------------------------
drill_exec_stub() {
  local host="$1" command="$2"
  printf 'STUB(%s) %s\n' "${host:-none}" "${command}"
  case "${command}" in
    journalctl\ -k*) printf '[    0.000000] Linux version 6.1.115-ceralive-vendor-rk35xx #1\n' ;;
    *RESULT-FAIL*)   return 7 ;;
  esac
  return 0
}

drill_exec_stub_failing() {
  printf 'STUB-FAIL %s\n' "$2"
  return 3
}

self_test() {
  local root failures=0 out rc
  root="$(mktemp -d)"
  local evidence="${root}/wave8/hardware"

  ok()  { printf '  ok   %s\n' "$*"; }
  bad() { printf '  FAIL %s\n' "$*" >&2; failures=$((failures + 1)); }

  out="$(CERALIVE_DRILL_EXEC=drill_exec_stub run_drill candidate rock-5b-plus \
    "${evidence}" rock-candidate 46 '' 0 2>&1)"; rc=$?
  if (( rc == 0 )) && [[ -s "${evidence}/rock-candidate/t46.commands.txt" ]]; then
    ok "candidate profile writes an ordered command manifest ($(wc -l <"${evidence}/rock-candidate/t46.commands.txt") lines)"
  else
    bad "candidate profile drill failed (rc=${rc}): ${out}"
  fi
  if grep -q 'hw-smoke.sh --case encode' "${evidence}/rock-candidate/t46.commands.txt" \
     && grep -q 'hw-smoke.sh --case usb3' "${evidence}/rock-candidate/t46.commands.txt"; then
    ok 'candidate manifest carries the normative smoke cases in order'
  else
    bad 'candidate manifest is missing normative smoke cases'
  fi
  if [[ -s "${evidence}/rock-candidate/t46.dmesg.log" ]]; then
    ok 'the decisive kernel log is captured to its own evidence file'
  else
    bad 'no decisive kernel log was captured'
  fi
  if grep -q 'board_id=rock-5b-plus' "${evidence}/rock-candidate/t46.transcript.log" \
     && grep -q 'dtb=rk3588-rock-5b-plus.dtb' "${evidence}/rock-candidate/t46.transcript.log"; then
    ok 'the transcript records the board-derived identity tuple'
  else
    bad 'the transcript does not record the board-derived identity tuple'
  fi

  out="$(CERALIVE_DRILL_EXEC=drill_exec_stub run_drill debug rock-5b-plus \
    "${evidence}" rock-debug 33 '' 0 2>&1)"; rc=$?
  if (( rc == 0 )) && grep -q 'rkvenc-fault-qa.sh --case fail-ccu-attach' \
       "${evidence}/rock-debug/t33.commands.txt"; then
    ok 'debug profile writes the rkvenc/hdmirx fault-injection manifest'
  else
    bad "debug profile drill failed (rc=${rc}): ${out}"
  fi

  out="$(CERALIVE_DRILL_EXEC=drill_exec_stub run_drill candidate rock-5b-plus \
    "${evidence}" rock-candidate 46 '' 0 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q 'append-only' <<<"${out}"; then
    ok 'a second run REFUSES to overwrite an existing append-only manifest'
  else
    bad "an existing command manifest was overwritten (rc=${rc})"
  fi

  out="$(CERALIVE_DRILL_EXEC=drill_exec_stub_failing run_drill candidate rock-5b-plus \
    "${evidence}" rock-candidate 90 '' 0 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q 'DRILL FAILED' <<<"${out}"; then
    ok 'a failing board command fails the drill'
  else
    bad "a failing board command did not fail the drill (rc=${rc})"
  fi

  out="$(CERALIVE_DRILL_EXEC=drill_exec_stub run_drill bogus rock-5b-plus \
    "${evidence}" rock-candidate 91 '' 0 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q 'unknown profile' <<<"${out}"; then
    ok 'an unknown profile is refused'
  else
    bad "an unknown profile was accepted (rc=${rc})"
  fi

  out="$(CERALIVE_DRILL_EXEC=drill_exec_stub run_drill candidate not-a-board \
    "${evidence}" rock-candidate 92 '' 0 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q 'unknown board' <<<"${out}"; then
    ok 'an unknown board is refused before any command is recorded'
  else
    bad "an unknown board was accepted (rc=${rc})"
  fi

  out="$(CERALIVE_DRILL_EXEC=drill_exec_stub run_drill candidate rock-5b-plus \
    "${root}/repo-b/.omo/evidence/x" rock-candidate 93 '' 0 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q "another repository's .omo/evidence tree" <<<"${out}"; then
    ok "Rule D: writing into another repo's .omo/evidence tree is refused"
  else
    bad "an \$EB evidence path was accepted (rc=${rc})"
  fi

  out="$(CERALIVE_DRILL_EXEC=drill_exec_stub run_drill candidate rock-5b-plus \
    'root@192.0.2.10:/evidence' rock-candidate 94 '' 0 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q 'REFUSED' <<<"${out}"; then
    ok 'a remote evidence directory is refused'
  else
    bad "a remote evidence directory was accepted (rc=${rc})"
  fi

  out="$(run_drill candidate rock-5b-plus "${evidence}" rock-candidate 95 '' 1 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q 'CERALIVE_DRILL_ALLOW_REAL' <<<"${out}"; then
    ok '--execute without the explicit arming variable refuses to touch a board'
  else
    bad "--execute reached a board without arming (rc=${rc})"
  fi

  out="$(CERALIVE_DRILL_ALLOW_REAL=1 run_drill candidate rock-5b-plus \
    "${evidence}" rock-candidate 96 '' 1 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q -- '--execute needs --host' <<<"${out}"; then
    ok '--execute without --host refuses'
  else
    bad "--execute without --host was accepted (rc=${rc})"
  fi

  out="$(CERALIVE_DRILL_EXEC=no_such_function run_drill candidate rock-5b-plus \
    "${evidence}" rock-candidate 97 '' 0 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -q 'is not a defined function' <<<"${out}"; then
    ok 'an undefined injected executor is refused'
  else
    bad "an undefined injected executor was accepted (rc=${rc})"
  fi

  out="$(run_drill candidate rock-5b-plus "${evidence}" rock-candidate 98 '' 0 2>&1)"; rc=$?
  if (( rc == 0 )) && grep -q 'DRY-RUN (not executed)' \
       "${evidence}/rock-candidate/t98.transcript.log"; then
    ok 'the default un-injected dry run executes nothing'
  else
    bad "the default dry run did not refuse execution (rc=${rc})"
  fi

  rm -rf "${root}"
  if (( failures == 0 )); then
    printf 'run-rk3588-hardware-drill self-test: PASS\n'
    return 0
  fi
  printf 'run-rk3588-hardware-drill self-test: FAIL (%s leg(s))\n' "${failures}" >&2
  return 1
}

main() {
  local profile="" board="" evidence="" target="" todo="" host="" execute=0 mode=run
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)  profile="${2:-}"; shift 2 ;;
      --board)    board="${2:-}"; shift 2 ;;
      --evidence) evidence="${2:-}"; shift 2 ;;
      --target)   target="${2:-}"; shift 2 ;;
      --todo)     todo="${2:-}"; shift 2 ;;
      --host)     host="${2:-}"; shift 2 ;;
      --execute)  execute=1; shift ;;
      --dry-run)  execute=0; shift ;;
      --self-test) mode=self-test; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
  done

  if [[ "${mode}" == self-test ]]; then
    self_test
    exit $?
  fi

  [[ -n "${profile}" && -n "${board}" && -n "${evidence}" ]] \
    || { printf -- '--profile, --board and --evidence are required\n' >&2; usage >&2; exit 2; }
  [[ -n "${target}" ]] || target="${board}-${profile}"
  [[ -n "${todo}" ]] || todo=46
  [[ "${todo}" =~ ^[0-9]{1,3}$ ]] || { printf -- '--todo must be a number\n' >&2; exit 2; }
  [[ "${target}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { printf -- '--target must be a slug\n' >&2; exit 2; }

  run_drill "${profile}" "${board}" "${evidence}" "${target}" "${todo}" "${host}" "${execute}"
  exit $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
