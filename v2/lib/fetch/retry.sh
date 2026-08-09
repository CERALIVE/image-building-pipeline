#!/usr/bin/env bash
#
# fetch/retry.sh — execution plumbing shared by every fetch family:
# the DRY_RUN bridge, the trap-managed scratch dir, the curl transport bounds,
# and the bounded transient-failure retry.
#
# Sourced by lib/fetch-debs.sh; not standalone. It reads DRY_RUN and writes the
# CURL_* / FETCH_RETRY_* / FETCH_TMPDIR globals the family modules consume, and
# it INSTALLS THE EXIT/INT/TERM/HUP TRAPS at source time — so it must be sourced
# by the entry point, in the entry point's own shell, before any fetch runs.
#
# Bodies moved VERBATIM from fetch-debs.sh; no behaviour change.
#
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Dry-run plumbing. run_or_plan executes in normal mode, logs-only in dry-run.
# This is the SOLE bridge between "real fetch" and "offline evidence" — there is
# deliberately no `|| true`; a real command that fails still trips the ERR trap.
# ---------------------------------------------------------------------------
: "${DRY_RUN:=}"

run_or_plan() {
  if [[ -n "${DRY_RUN}" ]]; then
    log_info "DRY-RUN would run: $*"
    return 0
  fi
  log_info "exec: $*"
  "$@"
}

# ---------------------------------------------------------------------------
# Private scratch dir — ONE trap-managed directory for every transient artifact
# this script writes OUTSIDE the staging tree (today: the Armbian InRelease /
# Release / Packages triple, plus the retry classifier logs below).
#
# It is removed on EXIT and on INT/TERM/HUP, so a clean run, a die(), an
# ERR-trap abort and an operator Ctrl-C all clean up identically. The
# predecessor was a bare `mktemp` whose `rm -f` sat on the SUCCESS path only:
# any failure between creation and that line leaked three files into $TMPDIR
# permanently, and an interrupted build leaked them every single time.
#
# Staged .deb temporaries deliberately do NOT live here — they must share a
# filesystem with their final name so the publish step stays an atomic rename.
# ---------------------------------------------------------------------------
FETCH_TMPDIR=""

# fetch_scratch_init — idempotently create the scratch dir and publish its path
# in FETCH_TMPDIR. It deliberately PRINTS NOTHING: a getter would invite
# `dir="$(fetch_scratch_dir)"`, whose command-substitution subshell would create
# the directory somewhere the EXIT trap's shell can never see it — a leak that
# looks exactly like working code.
fetch_scratch_init() {
  if [[ -z "${FETCH_TMPDIR}" ]]; then
    FETCH_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/fetch-debs.XXXXXX")"
  fi
  return 0
}

fetch_scratch_cleanup() {
  if [[ -n "${FETCH_TMPDIR}" ]]; then
    rm -rf -- "${FETCH_TMPDIR}"
    FETCH_TMPDIR=""
  fi
  return 0
}

# Clean, then re-raise so the caller still observes death-by-signal (128+n)
# rather than a fabricated clean exit.
fetch_scratch_signal_cleanup() {
  local sig="$1"
  fetch_scratch_cleanup
  trap - "${sig}" EXIT
  kill -s "${sig}" -- "$$"
}

trap fetch_scratch_cleanup EXIT
trap 'fetch_scratch_signal_cleanup INT' INT
trap 'fetch_scratch_signal_cleanup TERM' TERM
trap 'fetch_scratch_signal_cleanup HUP' HUP

# ---------------------------------------------------------------------------
# Curl transport bounds. `--retry N` alone does NOT bound a connection that is
# accepted and then stalls: with no --max-time such a fetch hangs the build
# forever, which is the failure mode --retry looks like it covers and does not.
# Both flags therefore ride on EVERY curl invocation on this path, including the
# ones the DRY-RUN plan prints — the plan is a transcript of the real command,
# so hiding a flag from it would make the plan lie.
#
# --max-time is a whole-transfer cap, so it is the one bound a very large .deb
# on a very slow link can legitimately hit; CURL_MAX_TIME is the escape hatch.
# ---------------------------------------------------------------------------
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
[[ "${CURL_CONNECT_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIME="${CURL_MAX_TIME:-300}"
[[ "${CURL_MAX_TIME}" =~ ^[1-9][0-9]*$ ]] || CURL_MAX_TIME=300
# Consumed by the family modules, which shellcheck reads as separate files.
# shellcheck disable=SC2034
CURL_TIMEOUT_OPTS=(--connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}")

# ---------------------------------------------------------------------------
# Bounded transient-failure retry.
#
# WHAT IS RETRIED, and nothing else: the apt-get archive round trips (`update`,
# `download`). Those are the only steps on this path whose failure can be a
# transient property of the network rather than a fact about the artifact.
#
# WHAT IS NEVER RETRIED, deliberately: GPG/InRelease signature verification, a
# SHA-256 mismatch, a Debian control identity mismatch, a deterministic 404/403/
# 401, and the half-supplied-credential fatal. Each of those is a VERDICT on
# bytes already in hand — replaying it cannot change the answer, it only buys a
# slower failure with the real diagnostic buried under two more attempts. The
# curl fetchers keep their verification OUTSIDE any wrapper, so they are covered
# structurally; apt-get performs its own verification internally and reports
# every error as exit 100, so its output is classified against
# FETCH_NO_RETRY_REGEX and a matching failure returns on the FIRST attempt.
#
# Every bound is finite and env-tunable; there is no unbounded loop:
#   FETCH_RETRY_ATTEMPTS  total attempts, >= 1               (default 3)
#   FETCH_RETRY_BACKOFF   whitespace-separated retry sleeps  (default "2 4")
#   FETCH_RETRY_TIMEOUT   per-attempt wall clock, seconds    (default 600; 0=off)
#   FETCH_RETRY_DEADLINE  whole-operation wall clock, secs   (default 1800; 0=off)
#
# The command's own output is streamed through untouched and the FINAL attempt's
# exit status is returned verbatim, so the tool's diagnostic and the caller's
# die() message both survive.
# ---------------------------------------------------------------------------
FETCH_RETRY_ATTEMPTS="${FETCH_RETRY_ATTEMPTS:-3}"
[[ "${FETCH_RETRY_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]] || FETCH_RETRY_ATTEMPTS=3
FETCH_RETRY_BACKOFF="${FETCH_RETRY_BACKOFF:-2 4}"
[[ "${FETCH_RETRY_BACKOFF}" =~ ^[0-9[:space:]]+$ && -n "${FETCH_RETRY_BACKOFF//[[:space:]]/}" ]] \
  || FETCH_RETRY_BACKOFF="2 4"
FETCH_RETRY_TIMEOUT="${FETCH_RETRY_TIMEOUT:-600}"
[[ "${FETCH_RETRY_TIMEOUT}" =~ ^[0-9]+$ ]] || FETCH_RETRY_TIMEOUT=600
FETCH_RETRY_DEADLINE="${FETCH_RETRY_DEADLINE:-1800}"
[[ "${FETCH_RETRY_DEADLINE}" =~ ^[0-9]+$ ]] || FETCH_RETRY_DEADLINE=1800

# Deterministic-failure markers. apt-get collapses every error to exit 100, so
# the exit status cannot tell "the mirror timed out" from "the signature is
# bad". These patterns name the second kind: a trust, integrity, addressing or
# credential VERDICT that a second attempt cannot change.
FETCH_NO_RETRY_REGEX="${FETCH_NO_RETRY_REGEX:-GPG error|NO_PUBKEY|EXPKEYSIG|BADSIG|KEYEXPIRED|REVKEYSIG|NODATA|is not signed|signature (mismatch|verification)|signature[s]? could not be verified|Hash Sum mismatch|[Cc]hecksum mismatch|404 +Not Found|403 +Forbidden|401 +Unauthorized|does not have a Release file|[Cc]ould not load client certificate|certificate verification failed}"
FETCH_NO_RETRY_REGEX="${FETCH_NO_RETRY_REGEX%\}}"

# fetch_failure_is_deterministic <log> — true when the captured output carries a
# verdict marker, i.e. when a retry is provably pointless.
fetch_failure_is_deterministic() {
  local log="$1"
  [[ -s "${log}" ]] || return 1
  grep -Eqi -- "${FETCH_NO_RETRY_REGEX}" "${log}"
}

# retry_transient <label> <cmd...> — run <cmd> with the bounds above.
#
# <cmd> is invoked IN THIS SHELL, so a PATH binary, a shell function and a test
# stub all resolve identically. The per-attempt wall-clock cap is timeout(1),
# which can only wrap an executable, so it is applied as a prefix only when
# <cmd> actually resolves to one — never by re-launching the command through a
# nested `bash -c`, which would hide a function-shaped caller from itself.
retry_transient() {
  local label="$1"
  local -a backoff=()
  IFS=' ' read -r -a backoff <<<"${FETCH_RETRY_BACKOFF}"
  (( ${#backoff[@]} > 0 )) || backoff=(2)

  local attempts="${FETCH_RETRY_ATTEMPTS}"
  local started="${SECONDS}" attempt=1 rc=0 idx wait_s elapsed log
  fetch_scratch_init
  log="$(mktemp "${FETCH_TMPDIR}/retry.XXXXXX")"

  shift
  local -a runner=("$@")
  if (( FETCH_RETRY_TIMEOUT > 0 )) \
      && [[ "$(type -t -- "$1")" == "file" ]] \
      && command -v timeout >/dev/null 2>&1; then
    runner=(timeout --kill-after=10s "${FETCH_RETRY_TIMEOUT}" "$@")
  fi

  while :; do
    rc=0
    : >"${log}"
    "${runner[@]}" 2>&1 | tee -a "${log}" >&2 || rc=$?

    if (( rc == 0 )); then
      if (( attempt > 1 )); then
        log_info "${label}: succeeded on attempt ${attempt}/${attempts}"
      fi
      rm -f "${log}"
      return 0
    fi

    if fetch_failure_is_deterministic "${log}"; then
      log_error "${label}: deterministic failure (signature/checksum/404/credential) on attempt ${attempt}/${attempts} — NOT retrying; exit ${rc}"
      rm -f "${log}"
      return "${rc}"
    fi

    if (( attempt >= attempts )); then
      log_error "${label}: transient-failure retries exhausted after ${attempt}/${attempts} attempt(s); last exit ${rc}"
      rm -f "${log}"
      return "${rc}"
    fi

    idx=$(( attempt - 1 ))
    (( idx < ${#backoff[@]} )) || idx=$(( ${#backoff[@]} - 1 ))
    wait_s="${backoff[idx]}"
    [[ "${wait_s}" =~ ^[0-9]+$ ]] || wait_s=2

    elapsed=$(( SECONDS - started ))
    if (( FETCH_RETRY_DEADLINE > 0 )) && (( elapsed + wait_s >= FETCH_RETRY_DEADLINE )); then
      log_error "${label}: transient-failure retry deadline reached (${elapsed}s of ${FETCH_RETRY_DEADLINE}s) after ${attempt}/${attempts} attempt(s); last exit ${rc}"
      rm -f "${log}"
      return "${rc}"
    fi

    log_warn "${label}: attempt ${attempt}/${attempts} failed (exit ${rc}) — transient; retrying in ${wait_s}s"
    sleep "${wait_s}"
    attempt=$(( attempt + 1 ))
  done
}

# run_or_plan_retry <label> <cmd...> — run_or_plan with bounded transient retry.
# The DRY-RUN plan line is byte-identical to run_or_plan's, so whether a step is
# retryable never shows up as a difference in the resolved build plan.
run_or_plan_retry() {
  local label="$1"; shift
  if [[ -n "${DRY_RUN}" ]]; then
    log_info "DRY-RUN would run: $*"
    return 0
  fi
  log_info "exec: $*"
  retry_transient "${label}" "$@"
}
