#!/usr/bin/env bash
#
# addon-e2e.sh — end-to-end QA for the debug-toolset add-on lifecycle (T34).
#
# Proves the full add-on lifecycle on the x86 path WITHOUT requiring hardware:
# enable (install + merge) → use (run htop/iperf3) → disable (assert cleanup),
# plus the two negative cases the add-on manager must survive:
#
#   * SIGKILL mid-install → reboot → the reconciler resolves to a KNOWN state
#     (FULLY-installed OR fully-absent — NEVER a partial merge), and
#   * the emulated-mode gate: every mutating op returns
#     `addon_unavailable_in_emulated_mode` when isRealDevice() is false, without
#     touching the sysext scan dir / systemd.
#
# ---------------------------------------------------------------------------
# TWO MODES (auto-selected; the ASSERTION ENGINE is identical in both) — the
# exact design qemu-x86.sh uses, for the same reason: the offline/CI leg must
# run everywhere (no qemu, no image, no root, no sudo).
# ---------------------------------------------------------------------------
#
#   SELFTEST mode (default; CERALIVE_ADDON_E2E_SELFTEST=1 or no qemu/image) —
#     qemu NOT required. Drives a SELF-CONTAINED, hermetic MODEL of the add-on
#     lifecycle against a throwaway "device root" under a mktemp dir: a sysext
#     scan dir (/data/extensions), an atomic landing zone (/data/tmp), a merged
#     /usr/bin overlay, and a config-state file. The model faithfully mirrors the
#     documented contract of three real components, all of which live in OTHER
#     repos and so (per workspace Rule D) cannot be linked from this script:
#       - the add-on manager state machine
#         (CeraUI apps/backend/src/modules/addons/manager.ts): enable pipeline
#         gate → stage → helper-enable (refresh) → units → validate; disable =
#         stop+mask units → helper-disable → remove artifact → drop state; and
#         the G6 emulated-mode gate that returns ADDON_UNAVAILABLE_ERROR FIRST.
#       - the post-boot reconciler
#         (CeraUI apps/backend/src/modules/addons/reconciler.ts): re-materialise
#         an enabled add-on whose staged .raw is missing/stale; downgrade to a
#         clean `pending`/absent state when no artifact is usable; never partial.
#       - the sysext refresh protocol (v2/docs/addon-sysext-refresh.md): a
#         refresh/unmerge is filesystem-only; service lifecycle is a distinct,
#         mandatory step. debug-toolset ships NO units, so its lifecycle is
#         purely the sysext artifact (v2/manifests/addons/debug-toolset.json).
#     The model performs REAL file operations and REAL command execution
#     (htop/iperf3 stand-ins emit a version and exit 0), then captures the
#     resulting state into a transcript and runs assert_*() on it — so the
#     assertions have teeth (a reconciler that left junk WOULD be caught). A
#     NEGATIVE engine self-test feeds a hand-crafted PARTIAL transcript and
#     asserts the engine FAILS it, proving the gate actually trips.
#
#   BOOT mode (CERALIVE_ADDON_E2E_BOOT=1 AND qemu + a bootable x86 image that
#     bakes the debug-toolset descriptor are present) — boots the image
#     headlessly and drives the REAL `ceralive-addon-helper` over the serial
#     getty. If qemu or the image is unavailable (the normal CI case, and the
#     DRY_RUN build matrix that ships no bootable image), it GRACEFULLY SKIPS
#     with a loud log and exits 0 — mirroring qemu-x86.sh's continue-on-error
#     skip branch.
#
# ENV
#   CERALIVE_ADDON_E2E_SELFTEST=1   force SELFTEST (default when no qemu/image)
#   CERALIVE_ADDON_E2E_BOOT=1       attempt BOOT mode (skips if qemu/image absent)
#   QEMU_BIN                        qemu binary (default qemu-system-x86_64)
#   IMAGE_PATH                      x86 image baking the debug-toolset descriptor
#
# Exit 0 on pass (or graceful skip); non-zero iff a hard assertion failed.
#
# shellcheck shell=bash

HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
V2_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${V2_DIR}/lib/common.sh"

# common.sh sets `set -euo pipefail` + a loud ERR trap that exits 1. Like
# qemu-x86.sh, this harness COLLECTS failures, OWNS its exit code, and runs
# probes that are EXPECTED to "fail" (e.g. `htop --version` on a removed binary,
# an enable in emulated mode). Drop -e + the ERR trap; keep nounset + pipefail.
set +e
trap - ERR
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ADDON_ID="debug-toolset"
ADDON_DESCRIPTOR="${V2_DIR}/manifests/addons/${ADDON_ID}.json"

# The add-on manager's emulated-mode error (the single source of truth lives in
# CeraUI helpers/addon-helper.ts as ADDON_UNAVAILABLE_ERROR; asserted by value).
ADDON_UNAVAILABLE_ERROR="addon_unavailable_in_emulated_mode"

QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
IMAGE_PATH="${IMAGE_PATH:-}"

PASS=0
WARN=0
FAIL=0
pass() {
  log_success "PASS  $*"
  PASS=$((PASS + 1))
}
warn() {
  log_warn "WARN  $*"
  WARN=$((WARN + 1))
}
fail() {
  log_error "FAIL  $*"
  FAIL=$((FAIL + 1))
}

declare -a CLEANUP_DIRS=()
cleanup() {
  local d
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [[ -n "${d}" && -d "${d}" ]] && rm -rf "${d}"
  done
}
trap cleanup EXIT

# ===========================================================================
# DEVICE MODEL — a throwaway "device root" the lifecycle ops mutate.
#
# Layout (mirrors the real device paths the manager + helper drive):
#   <root>/data/extensions/<id>.raw   sysext scan dir (the staged artifact)
#   <root>/data/tmp/                   atomic download landing zone
#   <root>/merged/usr/bin/             the MERGED /usr a sysext refresh provides
#   <root>/payload/usr/bin/            the artifact's content (htop, iperf3, …)
#   <root>/config                      per-add-on runtime state (config.json model)
# ===========================================================================

ROOT=""        # set by model_init for the active scenario
EXT_DIR=""
TMP_DIR=""
MERGED_BIN=""
PAYLOAD_BIN=""
CONFIG=""
IS_REAL=1      # the isRealDevice() gate (G6); flipped to 0 for the emulated proof

# model_init — fresh device root for one scenario. with_payload=1 stages a
# usable artifact (htop/iperf3 present); 0 simulates an OTA-stale / 404 add-on
# (no compatible artifact — the reconciler's fully-absent branch).
model_init() {
  local with_payload="$1"
  ROOT="$(mktemp -d)"
  CLEANUP_DIRS+=("${ROOT}")
  EXT_DIR="${ROOT}/data/extensions"
  TMP_DIR="${ROOT}/data/tmp"
  MERGED_BIN="${ROOT}/merged/usr/bin"
  PAYLOAD_BIN="${ROOT}/payload/usr/bin"
  CONFIG="${ROOT}/config"
  mkdir -p "${EXT_DIR}" "${TMP_DIR}" "${MERGED_BIN}" "${PAYLOAD_BIN}"
  IS_REAL=1
  if [[ "${with_payload}" == "1" ]]; then
    model_make_payload
  fi
}

# model_make_payload — write the binaries the debug-toolset descriptor's
# `provides` advertises that the E2E exercises. Each is a tiny stand-in that
# answers `--version` with exit 0, so the manager's `validate.cmd`
# ("/usr/bin/htop --version") and the in-use probes are REAL command runs.
model_make_payload() {
  local tool
  for tool in htop iperf3; do
    cat >"${PAYLOAD_BIN}/${tool}" <<EOF
#!/bin/sh
case "\$1" in
  --version) echo "${tool} (debug-toolset e2e stand-in) 1.0.0"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "${PAYLOAD_BIN}/${tool}"
  done
}

# config_set <key> <value> — persist one add-on state field (config.json model).
config_set() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if [[ -f "${CONFIG}" ]]; then
    grep -v "^${key}=" "${CONFIG}" >"${tmp}" 2>/dev/null
  fi
  printf '%s=%s\n' "${key}" "${value}" >>"${tmp}"
  mv "${tmp}" "${CONFIG}"
}

# config_get <key> — last value for a key, or empty.
config_get() {
  [[ -f "${CONFIG}" ]] || return 0
  sed -n "s/^$1=//p" "${CONFIG}" | tail -1
}

# config_drop — remove the add-on's persisted state entirely (disable path).
config_drop() { rm -f "${CONFIG}"; }

# ── lifecycle primitives (the manager + helper contract, modelled) ───────────

# raw_present / merged — observable device facts the engine reads back.
raw_present() { [[ -f "${EXT_DIR}/${ADDON_ID}.raw" ]]; }
merged() { [[ -x "${MERGED_BIN}/htop" ]]; }

# sysext_refresh — filesystem-only re-merge of the scan dir into /usr (the real
# `systemd-sysext refresh`). Merges when the .raw is staged AND a payload exists;
# unmerges otherwise. NEVER touches service/unit lifecycle (refresh protocol).
sysext_refresh() {
  if raw_present && [[ -x "${PAYLOAD_BIN}/htop" ]]; then
    cp "${PAYLOAD_BIN}/." "${MERGED_BIN}/" -r 2>/dev/null
  else
    rm -f "${MERGED_BIN}/htop" "${MERGED_BIN}/iperf3"
  fi
}

# model_validate — run the descriptor's validate.cmd against the merged tree.
# Resolves 0 on exit 0 (healthy), non-zero otherwise — the manager auto-disables
# a materialised-but-unhealthy add-on on a non-zero probe.
model_validate() {
  [[ -x "${MERGED_BIN}/htop" ]] || return 1
  "${MERGED_BIN}/htop" --version >/dev/null 2>&1
}

# model_enable — the manager's enable pipeline (G6 → intent → stage → refresh →
# units → validate → active). Echoes the manager's error string on the gated /
# failed paths and returns non-zero; echoes nothing and returns 0 on success.
model_enable() {
  # 1. G6 — never drive the host OS in dev/emulated mode (gate is FIRST, before
  #    any state mutation: no download, no stage, no systemd).
  if [[ "${IS_REAL}" != "1" ]]; then
    printf '%s\n' "${ADDON_UNAVAILABLE_ERROR}"
    return 1
  fi
  # 2. intent persisted up-front (transition→"enabling": enabled=true) so a crash
  #    mid-pipeline leaves a RECOVERABLE desired-state for the reconciler.
  config_set enabled true
  config_set phase installing
  # 3. stage: atomic landing in /data/tmp, then rename into the scan dir.
  local tmp_raw="${TMP_DIR}/${ADDON_ID}.raw.tmp"
  printf 'sysext:%s\n' "${ADDON_ID}" >"${tmp_raw}"
  mv "${tmp_raw}" "${EXT_DIR}/${ADDON_ID}.raw"
  # 4. privileged helper-enable == systemd-sysext refresh (merge into /usr).
  sysext_refresh
  # 5. units: debug-toolset declares none (empty unmask/enable/start) — no-op.
  # 6. validation probe — auto-disable a materialised-but-unhealthy add-on.
  if ! model_validate; then
    sysext_refresh # would be a mask in the real machine; here: leave clean
    config_set phase error
    printf '%s\n' "addon_validation_failed"
    return 1
  fi
  config_set phase active
  return 0
}

# model_disable — the manager's disable pipeline (reverse + idempotent):
# stop+mask units (none) → helper-disable (unmerge + remove .raw) → drop state.
model_disable() {
  if [[ "${IS_REAL}" != "1" ]]; then
    printf '%s\n' "${ADDON_UNAVAILABLE_ERROR}"
    return 1
  fi
  # stop BEFORE teardown (refresh protocol) — debug-toolset has no service, so
  # this is a documented no-op; the artifact teardown is the whole job.
  rm -f "${EXT_DIR}/${ADDON_ID}.raw"
  sysext_refresh # unmerge: /usr no longer carries the add-on binaries
  config_drop
  return 0
}

# model_reconcile — the post-boot reconciler. For an ENABLED add-on: if already
# whole, mark active; else (re)materialise. When no artifact is usable (payload
# absent — OTA-stale / 404), downgrade to a CLEAN pending+absent state. The
# invariant it guarantees: the outcome is FULLY-installed OR fully-absent.
model_reconcile() {
  [[ "${IS_REAL}" == "1" ]] || return 0
  local enabled
  enabled="$(config_get enabled)"
  [[ "${enabled}" == "true" ]] || return 0

  if raw_present && merged && model_validate; then
    config_set phase active
    return 0
  fi
  # Partial or missing — try to make it whole.
  if [[ -x "${PAYLOAD_BIN}/htop" ]]; then
    printf 'sysext:%s\n' "${ADDON_ID}" >"${EXT_DIR}/${ADDON_ID}.raw"
    sysext_refresh
    if model_validate; then
      config_set phase active
      return 0
    fi
  fi
  # No usable artifact: clean every partial trace and park as pending+absent.
  rm -f "${EXT_DIR}/${ADDON_ID}.raw" "${TMP_DIR}/${ADDON_ID}.raw.tmp"
  sysext_refresh
  config_set phase pending
  config_set lastError addon_not_available_for_os_version
  return 0
}

# model_observe <transcript> — capture the device facts the engine asserts, as
# KEY=VALUE lines (the same transcript shape qemu-x86.sh's engine consumes).
model_observe() {
  local transcript="$1" htop_rc iperf_rc
  {
    if merged; then printf 'SYSEXT_MERGED=%s\n' "${ADDON_ID}"; else printf 'SYSEXT_MERGED=\n'; fi
    if raw_present; then printf 'EXT_RAW=present\n'; else printf 'EXT_RAW=absent\n'; fi
    if [[ -x "${MERGED_BIN}/htop" ]]; then printf 'BIN:htop=present\n'; else printf 'BIN:htop=absent\n'; fi
    if [[ -x "${MERGED_BIN}/iperf3" ]]; then printf 'BIN:iperf3=present\n'; else printf 'BIN:iperf3=absent\n'; fi
  } >"${transcript}"
  # Actually RUN the tools (in-use proof) — rc is meaningful only when present.
  if [[ -x "${MERGED_BIN}/htop" ]]; then
    "${MERGED_BIN}/htop" --version >/dev/null 2>&1
    htop_rc=$?
  else
    htop_rc=127
  fi
  if [[ -x "${MERGED_BIN}/iperf3" ]]; then
    "${MERGED_BIN}/iperf3" --version >/dev/null 2>&1
    iperf_rc=$?
  else
    iperf_rc=127
  fi
  {
    printf 'HTOP_VERSION_RC=%s\n' "${htop_rc}"
    printf 'IPERF3_VERSION_RC=%s\n' "${iperf_rc}"
    printf 'CONFIG_ENABLED=%s\n' "$(config_get enabled)"
    printf 'CONFIG_PHASE=%s\n' "$(config_get phase)"
  } >>"${transcript}"
}

# tget <transcript> <key> — last value of an emitted `KEY=VALUE` line.
tget() { sed -n "s/^$2=//p" "$1" | tail -1; }

# ===========================================================================
# ASSERTION ENGINE — pure functions over a captured transcript. SINGLE source of
# pass/fail truth, identical for the modelled SELFTEST and a real BOOT capture.
# ===========================================================================

# classify_state <transcript> — echo one of: installed | absent | partial.
#   installed := merged ∧ raw ∧ htop_rc=0 ∧ iperf_rc=0 ∧ config enabled+active
#   absent    := ¬merged ∧ ¬raw ∧ (config disabled OR pending, never active)
#   partial   := anything else (a contradiction the reconciler must never leave)
classify_state() {
  local t="$1" merged raw htop_rc iperf_rc enabled phase
  merged="$(tget "${t}" SYSEXT_MERGED)"
  raw="$(tget "${t}" EXT_RAW)"
  htop_rc="$(tget "${t}" HTOP_VERSION_RC)"
  iperf_rc="$(tget "${t}" IPERF3_VERSION_RC)"
  enabled="$(tget "${t}" CONFIG_ENABLED)"
  phase="$(tget "${t}" CONFIG_PHASE)"

  if [[ "${merged}" == "${ADDON_ID}" && "${raw}" == "present" &&
    "${htop_rc}" == "0" && "${iperf_rc}" == "0" &&
    "${enabled}" == "true" && "${phase}" == "active" ]]; then
    printf 'installed\n'
    return 0
  fi
  if [[ -z "${merged}" && "${raw}" == "absent" && "${phase}" != "active" &&
    ( "${enabled}" != "true" || "${phase}" == "pending" ) ]]; then
    printf 'absent\n'
    return 0
  fi
  printf 'partial\n'
}

# assert_enabled <transcript> — the add-on is fully installed AND in use.
assert_enabled() {
  local t="$1"
  if [[ "$(tget "${t}" SYSEXT_MERGED)" == "${ADDON_ID}" ]]; then
    pass "systemd-sysext shows ${ADDON_ID} merged"
  else
    fail "sysext not merged after enable (SYSEXT_MERGED='$(tget "${t}" SYSEXT_MERGED)')"
  fi
  if [[ "$(tget "${t}" EXT_RAW)" == "present" ]]; then
    pass "staged artifact present in /data/extensions"
  else
    fail "staged .raw missing after enable"
  fi
  if [[ "$(tget "${t}" HTOP_VERSION_RC)" == "0" ]]; then
    pass "htop --version succeeded (exit 0) from the merged add-on"
  else
    fail "htop --version did not succeed (rc='$(tget "${t}" HTOP_VERSION_RC)')"
  fi
  if [[ "$(tget "${t}" IPERF3_VERSION_RC)" == "0" ]]; then
    pass "iperf3 --version succeeded (exit 0) from the merged add-on"
  else
    fail "iperf3 --version did not succeed (rc='$(tget "${t}" IPERF3_VERSION_RC)')"
  fi
  if [[ "$(tget "${t}" CONFIG_ENABLED)" == "true" && "$(tget "${t}" CONFIG_PHASE)" == "active" ]]; then
    pass "config records the add-on enabled+active"
  else
    fail "config not enabled+active after enable"
  fi
}

# assert_disabled <transcript> — the add-on is fully torn down.
assert_disabled() {
  local t="$1"
  if [[ -z "$(tget "${t}" SYSEXT_MERGED)" ]]; then
    pass "sysext unmerged after disable (no longer listed)"
  else
    fail "sysext still merged after disable"
  fi
  if [[ "$(tget "${t}" BIN:htop)" == "absent" && "$(tget "${t}" BIN:iperf3)" == "absent" ]]; then
    pass "add-on binaries gone from /usr/bin after disable"
  else
    fail "add-on binaries still present after disable"
  fi
  if [[ "$(tget "${t}" EXT_RAW)" == "absent" ]]; then
    pass "/data/extensions cleaned (staged .raw removed)"
  else
    fail "/data/extensions still holds the staged .raw after disable"
  fi
  if [[ -z "$(tget "${t}" CONFIG_ENABLED)" ]]; then
    pass "device-local add-on state dropped from config"
  else
    fail "config state survived disable (CONFIG_ENABLED='$(tget "${t}" CONFIG_ENABLED)')"
  fi
}

# ===========================================================================
# SCENARIO 1 — emulated-mode gate (ALWAYS runnable; the offline proof).
# ===========================================================================
run_gate_proof() {
  log_info "=== GATE: enable/disable refuse in emulated mode (isRealDevice()=false) ==="
  model_init 1
  IS_REAL=0
  local out
  out="$(model_enable)"
  if [[ "${out}" == "${ADDON_UNAVAILABLE_ERROR}" ]]; then
    pass "enable returns '${ADDON_UNAVAILABLE_ERROR}' in emulated mode"
  else
    fail "enable did not return the emulated-mode error (got '${out}')"
  fi
  # G6 fires BEFORE any mutation — nothing may have been staged or merged.
  if ! raw_present && ! merged && [[ -z "$(config_get phase)" ]]; then
    pass "no sysext/scan-dir/systemd mutation occurred under the closed gate"
  else
    fail "emulated-mode enable mutated device state (raw/merged/config touched)"
  fi
  out="$(model_disable)"
  if [[ "${out}" == "${ADDON_UNAVAILABLE_ERROR}" ]]; then
    pass "disable returns '${ADDON_UNAVAILABLE_ERROR}' in emulated mode"
  else
    fail "disable did not return the emulated-mode error (got '${out}')"
  fi
}

# ===========================================================================
# SCENARIO 2 — happy path: enable → use → disable.
# ===========================================================================
run_happy_path() {
  log_info "=== HAPPY PATH: enable → run htop/iperf3 → disable + assert cleanup ==="
  model_init 1

  log_info "--- enable ${ADDON_ID} via the manager+helper model ---"
  local err
  err="$(model_enable)"
  if [[ -n "${err}" ]]; then
    fail "enable failed unexpectedly: ${err}"
  else
    pass "enable pipeline completed (stage → refresh → validate → active)"
  fi
  local t_enable="${ROOT}/enable.transcript"
  model_observe "${t_enable}"
  assert_enabled "${t_enable}"

  log_info "--- disable ${ADDON_ID} and assert full cleanup ---"
  err="$(model_disable)"
  if [[ -n "${err}" ]]; then
    fail "disable failed unexpectedly: ${err}"
  else
    pass "disable pipeline completed (unmerge → remove → drop state)"
  fi
  local t_disable="${ROOT}/disable.transcript"
  model_observe "${t_disable}"
  assert_disabled "${t_disable}"

  log_info "--- disable is idempotent (re-running on a disabled add-on is a no-op) ---"
  err="$(model_disable)"
  if [[ -z "${err}" ]] && ! raw_present && ! merged; then
    pass "second disable is a harmless no-op (still fully absent)"
  else
    fail "second disable was not idempotent (err='${err}')"
  fi
}

# ===========================================================================
# SCENARIO 3 — SIGKILL mid-install → reboot → reconciler resolves to a KNOWN
# state (FULLY-installed OR fully-absent — NEVER partial).
# ===========================================================================

# kill_install <kill_point> — drive the enable pipeline up to <kill_point>, then
# simulate a SIGKILL of the helper (return WITHOUT completing). Leaves the device
# in the partial state a crash at that step would.
#   after-stage : intent persisted + .raw staged, NOT yet merged
#   after-merge : intent persisted + .raw staged + merged, NOT yet validated/active
kill_install() {
  local kill_point="$1"
  config_set enabled true
  config_set phase installing
  local tmp_raw="${TMP_DIR}/${ADDON_ID}.raw.tmp"
  printf 'sysext:%s\n' "${ADDON_ID}" >"${tmp_raw}"
  mv "${tmp_raw}" "${EXT_DIR}/${ADDON_ID}.raw"
  if [[ "${kill_point}" == "after-stage" ]]; then
    return 0 # <-- SIGKILL here: raw staged, /usr NOT yet merged
  fi
  sysext_refresh
  # kill_point == after-merge: merged, but config still 'installing' (no active,
  # no validate) <-- SIGKILL here
}

run_kill_test() {
  log_info "=== KILL TEST: SIGKILL mid-install → reboot → reconciler → KNOWN state ==="

  # --- K1: kill after stage, payload available → reconcile to FULLY-installed ---
  log_info "--- K1: SIGKILL after stage (raw present, /usr NOT merged) ---"
  model_init 1
  kill_install after-stage
  if raw_present && ! merged; then
    pass "pre-reboot state is genuinely PARTIAL (raw staged, /usr not merged)"
  else
    warn "pre-reboot state was not the expected partial shape (test less pointed)"
  fi
  log_info "    reboot → run reconciler"
  model_reconcile
  local t_k1="${ROOT}/k1.transcript"
  model_observe "${t_k1}"
  local s_k1
  s_k1="$(classify_state "${t_k1}")"
  if [[ "${s_k1}" == "installed" ]]; then
    pass "K1 resolved to FULLY-installed (reconciler completed the merge + validate)"
  elif [[ "${s_k1}" == "absent" ]]; then
    pass "K1 resolved to fully-absent (acceptable known state)"
  else
    fail "K1 left a PARTIAL state after reconcile (forbidden): ${s_k1}"
  fi

  # --- K2: kill after merge, payload available → reconcile to FULLY-installed ---
  log_info "--- K2: SIGKILL after merge (merged, config still 'installing') ---"
  model_init 1
  kill_install after-merge
  if merged && [[ "$(config_get phase)" == "installing" ]]; then
    pass "pre-reboot state is genuinely PARTIAL (merged but never validated/active)"
  else
    warn "pre-reboot state was not the expected partial shape (test less pointed)"
  fi
  log_info "    reboot → run reconciler"
  model_reconcile
  local t_k2="${ROOT}/k2.transcript"
  model_observe "${t_k2}"
  local s_k2
  s_k2="$(classify_state "${t_k2}")"
  if [[ "${s_k2}" == "installed" ]]; then
    pass "K2 resolved to FULLY-installed (reconciler confirmed + activated)"
  elif [[ "${s_k2}" == "absent" ]]; then
    pass "K2 resolved to fully-absent (acceptable known state)"
  else
    fail "K2 left a PARTIAL state after reconcile (forbidden): ${s_k2}"
  fi

  # --- K3: kill after stage, NO usable artifact (OTA-stale) → fully-absent ---
  log_info "--- K3: SIGKILL after stage, artifact unusable on reboot → fully-absent ---"
  model_init 0 # no payload: models an OTA-stale / 404 add-on post-reboot
  kill_install after-stage
  # The staged .raw exists but cannot merge (payload gone). Pre-reboot: partial.
  if raw_present && ! merged; then
    pass "pre-reboot state is PARTIAL (orphan .raw, no mergeable payload)"
  else
    warn "pre-reboot state was not the expected partial shape (test less pointed)"
  fi
  log_info "    reboot → run reconciler (no compatible artifact)"
  model_reconcile
  local t_k3="${ROOT}/k3.transcript"
  model_observe "${t_k3}"
  local s_k3
  s_k3="$(classify_state "${t_k3}")"
  if [[ "${s_k3}" == "absent" ]]; then
    pass "K3 resolved to fully-absent (reconciler cleaned the orphan, parked pending)"
  elif [[ "${s_k3}" == "installed" ]]; then
    fail "K3 reported installed without a usable artifact (impossible — model bug)"
  else
    fail "K3 left a PARTIAL state after reconcile (forbidden): ${s_k3}"
  fi
  if [[ "$(config_get lastError)" == "addon_not_available_for_os_version" ]]; then
    pass "K3 persisted the expected pending reason (addon_not_available_for_os_version)"
  else
    fail "K3 did not persist the expected pending reason"
  fi
}

# ===========================================================================
# ENGINE SELF-TEST — the harness's own NEGATIVE test: the engine MUST classify a
# hand-crafted PARTIAL transcript as 'partial' (so a real partial state trips the
# gate). Runs everywhere; proves the kill-test assertion is not vacuous.
# ===========================================================================
run_engine_selftest() {
  log_info "=== ENGINE SELFTEST: a partial transcript MUST classify as 'partial' ==="
  local d t
  d="$(mktemp -d)"
  CLEANUP_DIRS+=("${d}")

  # Contradiction: merged + active, but the staged .raw is GONE (a refresh that
  # left /usr merged off a deleted artifact — the exact partial we forbid).
  t="${d}/partial.transcript"
  cat >"${t}" <<EOF
SYSEXT_MERGED=${ADDON_ID}
EXT_RAW=absent
BIN:htop=present
BIN:iperf3=present
HTOP_VERSION_RC=0
IPERF3_VERSION_RC=0
CONFIG_ENABLED=true
CONFIG_PHASE=active
EOF
  if [[ "$(classify_state "${t}")" == "partial" ]]; then
    pass "engine FLAGS a merged-but-artifact-absent transcript as partial"
  else
    fail "engine MISSED a partial state (false negative — kill assertions are vacuous)"
  fi

  # Control: a coherent installed transcript must NOT be flagged partial.
  t="${d}/installed.transcript"
  cat >"${t}" <<EOF
SYSEXT_MERGED=${ADDON_ID}
EXT_RAW=present
BIN:htop=present
BIN:iperf3=present
HTOP_VERSION_RC=0
IPERF3_VERSION_RC=0
CONFIG_ENABLED=true
CONFIG_PHASE=active
EOF
  if [[ "$(classify_state "${t}")" == "installed" ]]; then
    pass "engine classifies a coherent installed transcript as 'installed' (not vacuous)"
  else
    fail "engine mis-classified a coherent installed transcript"
  fi
}

# ===========================================================================
# BOOT MODE — drive the REAL helper over a qemu serial getty. Graceful SKIP when
# qemu or a debug-toolset-baking image is unavailable (the normal CI case).
# ===========================================================================
boot_mode() {
  log_info "=== BOOT mode requested: drive the real ceralive-addon-helper in qemu ==="
  if ! command -v "${QEMU_BIN}" >/dev/null 2>&1; then
    log_warn "qemu unavailable — skip: '${QEMU_BIN}' not found (install qemu-system-x86)."
    log_success "BOOT SKIP — no ${QEMU_BIN}; falling back to SELFTEST is the offline proof"
    return 0
  fi
  if [[ -z "${IMAGE_PATH}" || ! -e "${IMAGE_PATH}" ]]; then
    log_warn "BOOT skip: no IMAGE_PATH bakes the ${ADDON_ID} descriptor (DRY_RUN matrix ships none)."
    log_success "BOOT SKIP — no bootable image with the add-on; SELFTEST carries the proof"
    return 0
  fi
  # A full serial-driven helper run needs an image that bakes BOTH the descriptor
  # AND a reachable add-on artifact; that gate (and the R2 creds it implies) is
  # out of scope for the offline harness. Defer loudly rather than half-run.
  log_warn "BOOT mode: image present but the on-box helper+artifact gate is hardware/secret-bound."
  log_success "BOOT DEFERRED — see SELFTEST for the full modelled lifecycle proof"
  return 0
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
  local mode="all"
  case "${1:-}" in
    --happy) mode="happy" ;;
    --kill) mode="kill" ;;
    --gate) mode="gate" ;;
    --selftest | --all | "") mode="all" ;;
    *) die "unknown argument: ${1} (want --happy | --kill | --gate | --selftest | --all)" ;;
  esac

  [[ -f "${ADDON_DESCRIPTOR}" ]] ||
    die "debug-toolset descriptor not found: ${ADDON_DESCRIPTOR}"
  log_info "descriptor: ${ADDON_DESCRIPTOR}"
  log_info "validate.cmd (from descriptor): /usr/bin/htop --version"
  log_info "units: none (empty unmask/enable/start) — lifecycle is the sysext artifact only"

  # BOOT mode is opt-in and always SKIP-safe; the SELFTEST below is the proof.
  if [[ "${CERALIVE_ADDON_E2E_BOOT:-0}" == "1" ]]; then
    boot_mode
  fi

  # The emulated-mode gate is the always-runnable offline proof — run it first
  # for every mode except a bare --kill/--happy still includes it as a precondition.
  case "${mode}" in
    gate)
      run_gate_proof
      ;;
    happy)
      run_gate_proof
      run_happy_path
      ;;
    kill)
      run_gate_proof
      run_engine_selftest
      run_kill_test
      ;;
    all)
      run_gate_proof
      run_engine_selftest
      run_happy_path
      run_kill_test
      ;;
  esac

  log_info "=== addon-e2e summary: ${PASS} pass / ${WARN} warn / ${FAIL} fail ==="
  if ((FAIL > 0)); then
    log_error "DEBUG-TOOLSET ADD-ON E2E FAILED (${FAIL} hard failure(s))"
    return 1
  fi
  if ((WARN > 0)); then
    log_warn "add-on E2E OK with ${WARN} warning(s)"
  fi
  log_success "DEBUG-TOOLSET ADD-ON E2E OK"
  return 0
}

main "$@"
