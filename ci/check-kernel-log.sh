#!/usr/bin/env bash
#
# check-kernel-log.sh — screen a captured kernel log against the versioned
# reject-signature set (`ci/kernel-log-reject.signatures`).
#
# It answers exactly one question for the Wave 8 hardware-evidence tuple: did
# this board's kernel start a genuine report during the drill? A `reject` hit is
# a FAIL; a `allow` line is a debug-kernel banner and is exempt, so the same
# screen can run over a KASAN+lockdep debug boot and a production boot.
#
# Usage:
#   check-kernel-log.sh [--signatures <file>] <log> [<log> ...]
#   check-kernel-log.sh --self-test [--signatures <file>]
#
# Exit codes:
#   0  every log clean
#   1  at least one reject signature matched (or a self-test leg failed)
#   2  usage / unreadable input
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNATURES="${HERE}/kernel-log-reject.signatures"
FIXTURES="${HERE}/fixtures/kernel-log"

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

ALLOW_IDS=() ALLOW_PATTERNS=() REJECT_IDS=() REJECT_PATTERNS=()
SIGNATURE_SET_VERSION=""

load_signatures() {
  local file="$1" verdict id pattern
  [[ -r "${file}" ]] || { printf 'signature set not readable: %s\n' "${file}" >&2; return 2; }
  ALLOW_IDS=() ALLOW_PATTERNS=() REJECT_IDS=() REJECT_PATTERNS=()
  SIGNATURE_SET_VERSION="$(sed -nE 's/^# signature-set-version:[[:space:]]*([0-9]+)$/\1/p' "${file}" | head -1)"
  [[ -n "${SIGNATURE_SET_VERSION}" ]] || {
    printf 'signature set carries no `# signature-set-version:` header: %s\n' "${file}" >&2
    return 2
  }
  while IFS=$'\t' read -r verdict id pattern; do
    [[ -n "${verdict}" ]] || continue
    [[ "${verdict}" != \#* ]] || continue
    [[ -n "${id}" && -n "${pattern}" ]] || {
      printf 'malformed signature row (need verdict<TAB>id<TAB>pattern): %s\n' "${verdict}" >&2
      return 2
    }
    case "${verdict}" in
      allow)  ALLOW_IDS+=("${id}");  ALLOW_PATTERNS+=("${pattern}") ;;
      reject) REJECT_IDS+=("${id}"); REJECT_PATTERNS+=("${pattern}") ;;
      *) printf 'unknown signature verdict %q in %s\n' "${verdict}" "${file}" >&2; return 2 ;;
    esac
  done < <(grep -v '^[[:space:]]*$' "${file}")
  (( ${#REJECT_PATTERNS[@]} > 0 )) || {
    printf 'signature set declares no reject patterns: %s\n' "${file}" >&2
    return 2
  }
  return 0
}

line_is_allowed() {
  local line="$1" index
  for index in "${!ALLOW_PATTERNS[@]}"; do
    if grep -Eq -- "${ALLOW_PATTERNS[$index]}" <<<"${line}"; then
      return 0
    fi
  done
  return 1
}

# screen_log <file> — print one `REJECT <id> <file>:<lineno> <line>` per hit.
screen_log() {
  local file="$1" line lineno=0 index hits=0
  [[ -r "${file}" ]] || { printf 'log not readable: %s\n' "${file}" >&2; return 2; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    [[ -n "${line//[[:space:]]/}" ]] || continue
    line_is_allowed "${line}" && continue
    for index in "${!REJECT_PATTERNS[@]}"; do
      if grep -Eq -- "${REJECT_PATTERNS[$index]}" <<<"${line}"; then
        printf 'REJECT %s %s:%s %s\n' "${REJECT_IDS[$index]}" "${file}" "${lineno}" "${line}"
        hits=$((hits + 1))
        break
      fi
    done
  done <"${file}"
  if (( hits == 0 )); then
    printf 'CLEAN %s (signature-set v%s)\n' "${file}" "${SIGNATURE_SET_VERSION}"
    return 0
  fi
  printf 'FAIL %s: %s reject signature hit(s)\n' "${file}" "${hits}" >&2
  return 1
}

# ---------------------------------------------------------------------------
# self-test — both directions. A screen that only proves clean logs pass proves
# nothing; a screen that only proves reports fail would happily fail every debug
# boot. Each reject fixture must be rejected BY ITS NAMED SIGNATURE, each accept
# fixture must pass, and the final leg proves the accept fixtures are not merely
# unmatchable text.
# ---------------------------------------------------------------------------
self_test() {
  local failures=0 fixture expect_id out rc scratch

  local -a reject_cases=(
    "reject-kasan-report.log:kasan-report"
    "reject-lockdep-circular.log:lockdep-circular"
    "reject-lockdep-recursive.log:lockdep-recursive"
    "reject-hung-task.log:hung-task"
    "reject-iommu-fault.log:iommu-fault"
    "reject-kernel-panic.log:panic"
    "reject-tainted-warn.log:tainted"
    "reject-novel-driver-error.log:driver-probe-failed"
  )
  local -a accept_cases=(
    accept-debug-boot-banners.log
    accept-clean-production-boot.log
  )

  for fixture in "${reject_cases[@]}"; do
    expect_id="${fixture##*:}"
    fixture="${FIXTURES}/${fixture%%:*}"
    out="$(screen_log "${fixture}" 2>&1)"; rc=$?
    if (( rc == 1 )) && grep -q "^REJECT ${expect_id} " <<<"${out}"; then
      printf '  ok   reject %s via signature %s\n' "$(basename "${fixture}")" "${expect_id}"
    else
      printf '  FAIL reject %s via signature %s (rc=%s)\n%s\n' \
        "$(basename "${fixture}")" "${expect_id}" "${rc}" "${out}" >&2
      failures=$((failures + 1))
    fi
  done

  for fixture in "${accept_cases[@]}"; do
    out="$(screen_log "${FIXTURES}/${fixture}" 2>&1)"; rc=$?
    if (( rc == 0 )); then
      printf '  ok   accept %s\n' "${fixture}"
    else
      printf '  FAIL accept %s (rc=%s)\n%s\n' "${fixture}" "${rc}" "${out}" >&2
      failures=$((failures + 1))
    fi
  done

  scratch="$(mktemp -d)"
  cat "${FIXTURES}/accept-debug-boot-banners.log" >"${scratch}/injected.log"
  printf '[  412.998811] BUG: KASAN: use-after-free in rkvenc_dma_import_fd+0x1c/0x2f0\n' \
    >>"${scratch}/injected.log"
  out="$(screen_log "${scratch}/injected.log" 2>&1)"; rc=$?
  if (( rc == 1 )) && grep -q '^REJECT ' <<<"${out}"; then
    printf '  ok   non-vacuity: a report injected after the debug banners is still rejected\n'
  else
    printf '  FAIL non-vacuity: injected report was not rejected (rc=%s)\n' "${rc}" >&2
    failures=$((failures + 1))
  fi

  printf '[  0.000000] Lockdep is turned on.\n' >"${scratch}/allow-only.log"
  out="$(screen_log "${scratch}/allow-only.log" 2>&1)"; rc=$?
  if (( rc == 0 )); then
    printf '  ok   allow rules win over reject rules on the same line\n'
  else
    printf '  FAIL allow rules did not exempt a debug banner (rc=%s)\n' "${rc}" >&2
    failures=$((failures + 1))
  fi
  rm -rf "${scratch}"

  if (( failures == 0 )); then
    printf 'check-kernel-log self-test: PASS (signature-set v%s, %s reject + %s allow rules)\n' \
      "${SIGNATURE_SET_VERSION}" "${#REJECT_PATTERNS[@]}" "${#ALLOW_PATTERNS[@]}"
    return 0
  fi
  printf 'check-kernel-log self-test: FAIL (%s leg(s))\n' "${failures}" >&2
  return 1
}

main() {
  local mode="screen" logs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --signatures) SIGNATURES="${2:-}"; shift 2 ;;
      --self-test)  mode="self-test"; shift ;;
      -h|--help)    usage; exit 0 ;;
      -*) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
      *) logs+=("$1"); shift ;;
    esac
  done
  load_signatures "${SIGNATURES}" || exit 2

  if [[ "${mode}" == self-test ]]; then
    self_test
    exit $?
  fi
  (( ${#logs[@]} > 0 )) || { printf 'at least one log file is required\n' >&2; usage >&2; exit 2; }

  local status=0 log rc
  for log in "${logs[@]}"; do
    screen_log "${log}"; rc=$?
    (( rc == 0 )) || status=1
    (( rc != 2 )) || exit 2
  done
  exit "${status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
