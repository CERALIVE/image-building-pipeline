#!/usr/bin/env bash
#
# rauc-rollback.sh — Stage 4 validation: REAL-HARDWARE RAUC A/B rollback + commit.
#
# THE LIVE COUNTERPART of platform/boot/test-fallback.sh. Where test-fallback.sh
# proves the boot-state ENGINE offline (71 assertions, no HW), this harness proves
# the SAME contract end-to-end against a RUNNING RK3588 board over SSH — the actual
# `rauc install` → reboot → bootcount → fallback / healthcheck → mark-good path.
#
# It runs TWO scripted, repeatable test cases:
#
#   BAD BUNDLE  → a bundle that boots but FAILS the healthcheck (ceracoder stripped).
#                 The slot is never confirmed; its bootcount bleeds 3→2→1→0 and the
#                 vendor U-Boot selector (boot.scr) falls back to the last-good slot
#                 A. PROVES: a can't-encode update can NEVER brick the device.
#
#   GOOD BUNDLE → a healthy bundle. It boots into the new slot, ceralive-healthcheck
#                 confirms real streaming health and calls `rauc mark-good`, and the
#                 switch is PERMANENT (a subsequent reboot does NOT revert).
#                 PROVES: a healthy update commits and survives.
#
# ---------------------------------------------------------------------------
# TWO MODES (auto-selected; the assertions and sequencing are IDENTICAL).
# ---------------------------------------------------------------------------
#
#   LIVE mode  — BOARD_IP set. Real SSH to a booted RK3588. `rauc install` the
#                pre-built bundles from BUNDLE_DIR, `systemctl reboot`, poll SSH
#                back, read the booted slot from /proc/cmdline (root=PARTLABEL=
#                rootfs_a|b) + rauc status, query `ceralive-boot-state get-state`,
#                and run the on-device `ceralive-healthcheck.service`. THIS is the
#                authoritative RK3588 acceptance gate (MUST-NOT: no qemu result is
#                accepted for RK3588 — this is real silicon).
#
#   MOCK mode  — no BOARD_IP (CI without a board). A LOCAL simulated "board" whose
#                `ssh` operations are replaced by a simulator that drives the REAL
#                shipped scripts:
#                  * ceralive-boot-state.sh        (the bootloader/state engine)
#                  * ceralive-rauc-boot-adapter.sh (the RAUC custom backend)
#                  * ceralive-healthcheck.sh       (the mark-good gate)
#                Only the LEAF system tools (systemctl/ceracoder/srtla_send/nc) are
#                stubbed — exactly the env seams those scripts already expose. A
#                "reboot" runs the real `boot-select` (decrement+persist); the
#                freshly-booted slot runs the real healthcheck, which calls the real
#                state engine via a recording `rauc` stub. So the MOCK exercises the
#                ACTUAL rollback logic (not a re-implementation) — it proves the
#                HARNESS + the engine are correct; it does NOT replace the on-silicon
#                run, which stays a board-required integration step.
#
# ---------------------------------------------------------------------------
# ENV
# ---------------------------------------------------------------------------
#   BOARD_IP            SSH target → LIVE mode (unset → MOCK mode)
#   SSH_USER            SSH user for LIVE mode                       (default ceralive)
#   SSH_PORT            SSH port for LIVE mode                       (default 22)
#   BUNDLE_DIR          dir holding the pre-built bundles (bad.raucb, good.raucb)
#   BAD_BUNDLE          override the bad bundle path  (default $BUNDLE_DIR/bad.raucb)
#   GOOD_BUNDLE         override the good bundle path (default $BUNDLE_DIR/good.raucb)
#   BOOT_ATTEMPTS       per-slot bootcount budget (system.conf boot-attempts) (def 3)
#   REBOOT_TIMEOUT      seconds to wait for SSH to return after a reboot      (def 90)
#   HEALTHCHECK_TIMEOUT seconds to wait for the slot to self-confirm good    (def 120)
#   SSH_POLL_INTERVAL   seconds between SSH reachability polls                 (def 5)
#   CERALIVE_ROLLBACK_MODE  force "live" or "mock" (default: auto from BOARD_IP)
#
# Exit 0 iff every assertion passed (both cases). Mirrors test-fallback.sh output.
#
# shellcheck shell=bash

HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
V2_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${V2_DIR}/lib/common.sh"

# common.sh sets `set -euo pipefail` + a loud ERR trap that exits 1. This harness
# COLLECTS failures and owns its exit code (like realhw-smoke.sh / test-fallback.sh),
# and it captures `$?` from probes that are EXPECTED to fail (a bad slot's
# healthcheck). So drop -e and the ERR trap; keep nounset+pipefail.
set +e
trap - ERR
set -uo pipefail

BOOT_DIR="${V2_DIR}/mkosi/platform/boot"
RUNTIME_DIR="${V2_DIR}/mkosi/runtime"
BOOT_STATE_SH="${BOOT_DIR}/ceralive-boot-state.sh"
ADAPTER_SH="${BOOT_DIR}/ceralive-rauc-boot-adapter.sh"
HEALTHCHECK_SH="${RUNTIME_DIR}/ceralive-healthcheck.sh"

# --- config ----------------------------------------------------------------
BOARD_IP="${BOARD_IP:-}"
SSH_USER="${SSH_USER:-ceralive}"
SSH_PORT="${SSH_PORT:-22}"
BUNDLE_DIR="${BUNDLE_DIR:-}"
BOOT_ATTEMPTS="${BOOT_ATTEMPTS:-3}"
REBOOT_TIMEOUT="${REBOOT_TIMEOUT:-90}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-120}"
SSH_POLL_INTERVAL="${SSH_POLL_INTERVAL:-5}"

BAD_BUNDLE="${BAD_BUNDLE:-${BUNDLE_DIR:+${BUNDLE_DIR}/bad.raucb}}"
GOOD_BUNDLE="${GOOD_BUNDLE:-${BUNDLE_DIR:+${BUNDLE_DIR}/good.raucb}}"

MODE="${CERALIVE_ROLLBACK_MODE:-}"
if [[ -z "${MODE}" ]]; then
  if [[ -n "${BOARD_IP}" ]]; then MODE="live"; else MODE="mock"; fi
fi

SSH_BASE_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

# --- result bookkeeping (mirrors test-fallback.sh) -------------------------
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }
assert_eq() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1 ($3)"; else bad "$1: expected '$2', got '$3'"; fi
}
section() { printf '\n### %s\n' "$*"; }
phase()   { PHASE_T0=$SECONDS; printf '  ▶ %s\n' "$*"; }
phase_done() { printf '    ⏱ %ds\n' "$(( SECONDS - PHASE_T0 ))"; }

CLEANUP_DIRS=()
cleanup() { local d; for d in "${CLEANUP_DIRS[@]:-}"; do [[ -n "${d}" && -d "${d}" ]] && rm -rf "${d}"; done; }
trap cleanup EXIT

# bundle_health <path> — derive the expected slot health from the bundle name.
# (On real HW the bundle's CONTENT decides; in MOCK the filename is the signal.)
bundle_health() {
  case "$(basename "${1:-}")" in
    *bad*|*broken*|*evil*) printf 'bad' ;;
    *) printf 'good' ;;
  esac
}

# ===========================================================================
# MOCK "board" — a local sandbox that drives the REAL shipped scripts.
# ===========================================================================
SIM=""

mock_bs()      { CERALIVE_BOOT_STATE_FILE="${SIM}/boot_state.txt" CERALIVE_BOOT_ATTEMPTS="${BOOT_ATTEMPTS}" bash "${BOOT_STATE_SH}" "$@"; }
mock_adapter() { CERALIVE_BOOT_STATE_FILE="${SIM}/boot_state.txt" CERALIVE_BOOT_ATTEMPTS="${BOOT_ATTEMPTS}" \
                 CERALIVE_BOOT_STATE_BIN="${BOOT_STATE_SH}" bash "${ADAPTER_SH}" "$@"; }

mock_write_stubs() {
  local bin="${SIM}/bin"
  mkdir -p "${bin}" "${SIM}/data/ceralive"

  # rauc: the only op that matters is `mark-good`, which (on device) confirms the
  # CURRENTLY-BOOTED slot. Map it to the REAL state engine so a healthy slot truly
  # resets its bootcount — the heart of "good bundle commits".
  cat >"${bin}/rauc" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "mark-good" ]; then
  CERALIVE_BOOT_STATE_FILE="${MOCK_BOOT_STATE_FILE}" \
  CERALIVE_BOOT_ATTEMPTS="${MOCK_BOOT_ATTEMPTS}" \
  bash "${MOCK_BOOT_STATE_SH}" set-state "$(cat "${MOCK_BOOTED_FILE}")" good
fi
exit 0
EOF

  # systemctl: ceralive.service is active even on a BAD bundle — the app boots, it
  # just can't ENCODE (ceracoder stripped). is-active → 0. This is the realistic
  # "boots but can't encode" trap the healthcheck must still catch via the binary
  # loader probe (so the differentiator is the encoder binary, not the service).
  cat >"${bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "is-active" ] && exit 0
exit 0
EOF

  # A healthy ceracoder (loads + prints a version). The BAD slot points CERACODER_BIN
  # at a non-existent path (the "stripped binary"), which the healthcheck reports as
  # missing/not-executable → no mark-good.
  cat >"${bin}/ceracoder.good" <<'EOF'
#!/usr/bin/env bash
echo "ceracoder 2026.06.0 (mock healthy slot)"
exit 0
EOF
  cat >"${bin}/srtla_send" <<'EOF'
#!/usr/bin/env bash
echo "usage: srtla_send PORT HOST PORT BINDFILE" >&2
exit 1
EOF
  chmod +x "${bin}"/*

  # Short healthcheck timeouts so the EXPECTED-to-fail (bad slot) run finishes fast.
  # IRL_SERVER_HOST empty → TCP reach SKIPPED (the on-silicon run exercises reach;
  # the rollback differentiator here is the encoder binary, per the task design).
  cat >"${SIM}/data/ceralive/update.conf" <<'EOF'
IRL_SERVER_HOST=
IRL_SERVER_SRT_PORT=9000
HEALTHCHECK_TIMEOUT=2
HEALTHCHECK_RETRY_INTERVAL=1
EOF
}

# mock_run_healthcheck — run the REAL ceralive-healthcheck.sh for the booted slot.
mock_run_healthcheck() {
  local slot bundle ceracoder
  slot="$(cat "${SIM}/booted")"
  bundle="$(cat "${SIM}/slot_${slot}.bundle")"
  if [[ "${bundle}" == "good" ]]; then
    ceracoder="${SIM}/bin/ceracoder.good"
  else
    ceracoder="${SIM}/bin/ceracoder.stripped"   # deliberately absent (stripped)
  fi
  MOCK_BOOT_STATE_FILE="${SIM}/boot_state.txt" \
  MOCK_BOOT_ATTEMPTS="${BOOT_ATTEMPTS}" \
  MOCK_BOOT_STATE_SH="${BOOT_STATE_SH}" \
  MOCK_BOOTED_FILE="${SIM}/booted" \
  PATH="${SIM}/bin:${PATH}" \
  CERALIVE_HEALTHCHECK_CONF="${SIM}/data/ceralive/update.conf" \
  CERALIVE_HEALTHCHECK_MARKER="${SIM}/data/ceralive/.slot-marked-good" \
  RAUC_BIN="${SIM}/bin/rauc" \
  SYSTEMCTL_BIN="${SIM}/bin/systemctl" \
  CERACODER_BIN="${ceracoder}" \
  SRTLA_SEND_BIN="${SIM}/bin/srtla_send" \
  BIN_PROBE_TIMEOUT=2 SRT_CONNECT_TIMEOUT=2 \
  bash "${HEALTHCHECK_SH}" >/dev/null 2>&1
}

# mock_init_board — establish a board freshly running healthy on slot A (the LIVE
# precondition). init A/B state, mark A good (a real first-boot confirmation).
mock_init_board() {
  SIM="$(mktemp -d)"; CLEANUP_DIRS+=("${SIM}")
  mock_write_stubs
  mock_bs init >/dev/null                 # BOOT_ORDER="A B", both *_LEFT=BOOT_ATTEMPTS
  printf 'good\n' >"${SIM}/slot_A.bundle"
  printf 'good\n' >"${SIM}/slot_B.bundle"
  printf 'A\n'    >"${SIM}/booted"
  mock_run_healthcheck >/dev/null 2>&1    # A confirms itself (writes the marker)
}

# ===========================================================================
# BOARD OPERATIONS — one interface, LIVE (ssh) + MOCK (simulator) impls.
# ===========================================================================
ssh_run() { ssh "${SSH_BASE_OPTS[@]}" -p "${SSH_PORT}" "${SSH_USER}@${BOARD_IP}" "$@"; }

# board_booted_slot — which slot is the running system? (A|B)
board_booted_slot() {
  if [[ "${MODE}" == "mock" ]]; then cat "${SIM}/booted"; return; fi
  local cl st
  cl="$(ssh_run 'cat /proc/cmdline' 2>/dev/null || true)"
  case "${cl}" in
    *rootfs_a*) printf 'A'; return ;;
    *rootfs_b*) printf 'B'; return ;;
  esac
  # Fallback: ask RAUC which slot it booted (rootfs.0=A, rootfs.1=B).
  st="$(ssh_run 'rauc status --output-format=shell' 2>/dev/null || true)"
  case "${st}" in
    *BOOTED_SLOT=*rootfs.0*|*booted=rootfs.0*) printf 'A' ;;
    *BOOTED_SLOT=*rootfs.1*|*booted=rootfs.1*) printf 'B' ;;
    *) printf '?' ;;
  esac
}

board_get_state()   { # <slot> → good|bad
  if [[ "${MODE}" == "mock" ]]; then mock_bs get-state "$1"; else ssh_run "ceralive-boot-state get-state $1" 2>/dev/null || printf '?'; fi
}
board_get_primary() {
  if [[ "${MODE}" == "mock" ]]; then mock_bs get-primary; else ssh_run "ceralive-boot-state get-primary" 2>/dev/null || printf '?'; fi
}
board_service_active() {
  if [[ "${MODE}" == "mock" ]]; then return 0; fi   # mock app is always up (see stub)
  [[ "$(ssh_run 'systemctl is-active ceralive.service' 2>/dev/null || true)" == "active" ]]
}

# board_rauc_install <bundle> <slot> <health> — install+activate a bundle to <slot>.
# <health> is the MOCK-only hint (live decides from the real bundle content).
board_rauc_install() {
  local bundle="$1" slot="$2" health="$3"
  if [[ "${MODE}" == "mock" ]]; then
    # RAUC install activates the target slot via the custom backend `set-primary`
    # (moves it to the head of BOOT_ORDER + resets its bootcount), then the OTA
    # wrapper (ceralive-update) clears the shared-/data marker so the new slot must
    # RE-PROVE health (CROSS-SLOT brick #2, task 29). Model both.
    mock_adapter set-primary "${slot}" >/dev/null
    printf '%s\n' "${health}" >"${SIM}/slot_${slot}.bundle"
    rm -f "${SIM}/data/ceralive/.slot-marked-good"
    return 0
  fi
  local base; base="$(basename "${bundle}")"
  scp "${SSH_BASE_OPTS[@]}" -P "${SSH_PORT}" "${bundle}" "${SSH_USER}@${BOARD_IP}:/tmp/${base}" >/dev/null \
    || { bad "scp ${base} to board failed"; return 1; }
  ssh_run "rauc install /tmp/${base}" \
    || { bad "rauc install ${base} failed on board"; return 1; }
  # Mimic ceralive-update: clear the shared marker so slot B re-confirms on boot.
  ssh_run "rm -f /data/ceralive/.slot-marked-good" || true
}

# board_reboot_and_wait — reboot and block until the system is reachable again.
board_reboot_and_wait() {
  if [[ "${MODE}" == "mock" ]]; then
    local out slot
    out="$(mock_bs boot-select)"           # the REAL U-Boot selection + decrement
    slot="${out%% *}"
    printf '%s\n' "${slot}" >"${SIM}/booted"
    return 0
  fi
  ssh_run "systemctl reboot" >/dev/null 2>&1 || true   # connection drop is expected
  sleep "${SSH_POLL_INTERVAL}"
  local deadline=$(( SECONDS + REBOOT_TIMEOUT ))
  while (( SECONDS < deadline )); do
    if ssh_run true >/dev/null 2>&1; then return 0; fi
    sleep "${SSH_POLL_INTERVAL}"
  done
  return 1
}

# board_run_healthcheck — run the post-boot confirmation (ceralive-healthcheck).
# Returns the healthcheck exit code: 0 = slot confirmed (mark-good), 1 = not.
board_run_healthcheck() {
  if [[ "${MODE}" == "mock" ]]; then mock_run_healthcheck; return $?; fi
  # On device the unit auto-runs on boot; trigger it explicitly for a deterministic
  # result and propagate the unit's success/failure.
  ssh_run "systemctl start ceralive-healthcheck.service" >/dev/null 2>&1
  return $?
}

# board_wait_good <slot> — poll until the slot is marked good (HEALTHCHECK_TIMEOUT).
board_wait_good() {
  local slot="$1" deadline=$(( SECONDS + HEALTHCHECK_TIMEOUT ))
  while (( SECONDS < deadline )); do
    [[ "$(board_get_state "${slot}")" == "good" ]] && return 0
    [[ "${MODE}" == "mock" ]] && break          # mock healthcheck already settled
    sleep "${SSH_POLL_INTERVAL}"
  done
  [[ "$(board_get_state "${slot}")" == "good" ]]
}

# ===========================================================================
# TEST CASE 1 — BAD BUNDLE → fallback to the last-good slot A.
# ===========================================================================
run_bad_bundle_test() {
  section "BAD BUNDLE — deliberately broken slot B must roll back to slot A"
  local t0=$SECONDS

  # 1. Precondition: running healthy on slot A.
  assert_eq "precondition: booted slot is A"        "A"    "$(board_booted_slot)"
  assert_eq "precondition: slot A state is good"    "good" "$(board_get_state A)"

  # 2-3. Install the deliberately-bad bundle to B and activate it.
  phase "install BAD bundle → slot B (rauc install ${BAD_BUNDLE:-<mock>})"
  board_rauc_install "${BAD_BUNDLE}" B bad
  phase_done
  assert_eq "post-install: B is primary (will boot next)" "B" "$(board_get_primary)"

  # 4-6. Reboot until the bootcount exhausts B and U-Boot falls back to A. The
  # per-slot budget is BOOT_ATTEMPTS, so a never-confirmed slot takes up to
  # BOOT_ATTEMPTS failed boots before the selector skips it (cap +1 for the
  # fallback boot itself).
  local reboots=0 cap=$(( BOOT_ATTEMPTS + 1 )) booted="" hc_rc=0
  while (( reboots < cap )); do
    reboots=$(( reboots + 1 ))
    phase "reboot #${reboots} (wait ≤${REBOOT_TIMEOUT}s for SSH)"
    if ! board_reboot_and_wait; then bad "board did not return after reboot #${reboots}"; break; fi
    booted="$(board_booted_slot)"
    board_run_healthcheck; hc_rc=$?
    phase_done
    printf '    reboot #%d: booted=%s healthcheck_rc=%d  state[A=%s B=%s] left[A=%s B=%s]\n' \
      "${reboots}" "${booted}" "${hc_rc}" \
      "$(board_get_state A)" "$(board_get_state B)" \
      "$( [[ ${MODE} == mock ]] && mock_bs get-left A || echo '?')" \
      "$( [[ ${MODE} == mock ]] && mock_bs get-left B || echo '?')"
    if [[ "${booted}" == "B" ]]; then
      # While still on the bad slot, it MUST NOT have confirmed itself.
      if (( hc_rc != 0 )); then ok "bad slot B failed healthcheck → NOT marked good (reboot #${reboots})";
      else bad "bad slot B unexpectedly PASSED healthcheck (would brick the device!)"; fi
    fi
    [[ "${booted}" == "A" ]] && break
  done

  assert_eq "ROLLBACK: device fell back to slot A"        "A"    "${booted}"
  assert_eq "slot B is now bad (bootcount exhausted)"     "bad"  "$(board_get_state B)"
  assert_eq "slot A still good (healthy last-known slot)" "good" "$(board_get_state A)"
  if board_service_active; then ok "ceralive.service active on slot A after rollback";
  else bad "ceralive.service NOT active on slot A after rollback"; fi
  printf '  → BAD bundle: rolled back to A after %d reboot(s) in %ds\n' "${reboots}" "$(( SECONDS - t0 ))"
}

# ===========================================================================
# TEST CASE 2 — GOOD BUNDLE → boot new slot, mark-good, permanent switch.
# ===========================================================================
run_good_bundle_test() {
  section "GOOD BUNDLE — slot B boots, self-confirms (mark-good), and persists"
  local t0=$SECONDS

  # 1-2. Install a healthy bundle to B and activate it.
  phase "install GOOD bundle → slot B (rauc install ${GOOD_BUNDLE:-<mock>})"
  board_rauc_install "${GOOD_BUNDLE}" B good
  phase_done
  assert_eq "post-install: B is primary (will boot next)" "B" "$(board_get_primary)"

  # 3-5. Reboot into the new slot.
  phase "reboot into the new slot (wait ≤${REBOOT_TIMEOUT}s for SSH)"
  board_reboot_and_wait || bad "board did not return after activating slot B"
  phase_done
  assert_eq "booted into the NEW slot B" "B" "$(board_booted_slot)"

  # 6-7. The ceralive-healthcheck logic confirms real streaming health and
  # mark-goods the slot (service active + ceracoder/srtla load + SRT reach).
  phase "healthcheck self-confirmation (wait ≤${HEALTHCHECK_TIMEOUT}s)"
  local hc_rc=0
  board_run_healthcheck; hc_rc=$?
  assert_eq "good slot healthcheck PASSED → rauc mark-good" "0" "${hc_rc}"
  if board_wait_good B; then ok "slot B confirmed good within ${HEALTHCHECK_TIMEOUT}s";
  else bad "slot B NOT marked good within ${HEALTHCHECK_TIMEOUT}s"; fi
  assert_eq "slot B state is good (permanent switch)" "good" "$(board_get_state B)"
  phase_done

  # 8. Reboot again — the confirmed slot must NOT revert.
  phase "reboot again — confirm NO revert"
  board_reboot_and_wait || bad "board did not return on the confirm-reboot"
  phase_done
  assert_eq "still on slot B (no rollback after confirmation)" "B" "$(board_booted_slot)"
  assert_eq "slot B still good after reconfirm reboot"         "good" "$(board_get_state B)"
  if board_service_active; then ok "ceralive.service active on the committed slot B";
  else bad "ceralive.service NOT active on slot B"; fi
  printf '  → GOOD bundle: permanent switch to B in %ds\n' "$(( SECONDS - t0 ))"
}

# ===========================================================================
# PRECONDITIONS
# ===========================================================================
preflight_live() {
  require_cmd ssh; require_cmd scp
  [[ -n "${BAD_BUNDLE}"  && -s "${BAD_BUNDLE}"  ]] || die "LIVE mode needs a bad bundle (set BUNDLE_DIR with bad.raucb, or BAD_BUNDLE)"
  [[ -n "${GOOD_BUNDLE}" && -s "${GOOD_BUNDLE}" ]] || die "LIVE mode needs a good bundle (set BUNDLE_DIR with good.raucb, or GOOD_BUNDLE)"
  if ! ssh_run true >/dev/null 2>&1; then
    die "cannot SSH to ${SSH_USER}@${BOARD_IP}:${SSH_PORT} — board unreachable / key auth not set up"
  fi
}

preflight_mock() {
  local f
  for f in "${BOOT_STATE_SH}" "${ADAPTER_SH}" "${HEALTHCHECK_SH}"; do
    [[ -r "${f}" ]] || die "MOCK mode needs the shipped script: ${f}"
  done
  # If no real bundles were supplied, synthesize named placeholders so the harness
  # still exercises the BUNDLE_DIR contract (paths flow through board_rauc_install).
  if [[ -z "${BAD_BUNDLE}" || ! -e "${BAD_BUNDLE}" || -z "${GOOD_BUNDLE}" || ! -e "${GOOD_BUNDLE}" ]]; then
    local tmp; tmp="$(mktemp -d)"; CLEANUP_DIRS+=("${tmp}")
    [[ -n "${BAD_BUNDLE}"  && -e "${BAD_BUNDLE}"  ]] || { BAD_BUNDLE="${tmp}/bad.raucb";  printf 'mock-bad-bundle\n'  >"${BAD_BUNDLE}"; }
    [[ -n "${GOOD_BUNDLE}" && -e "${GOOD_BUNDLE}" ]] || { GOOD_BUNDLE="${tmp}/good.raucb"; printf 'mock-good-bundle\n' >"${GOOD_BUNDLE}"; }
  fi
  # Sanity: the supplied/synthesized names must classify as we intend.
  [[ "$(bundle_health "${BAD_BUNDLE}")"  == "bad"  ]] || log_warn "bad bundle name '$(basename "${BAD_BUNDLE}")' does not look bad — MOCK forces health=bad regardless"
  [[ "$(bundle_health "${GOOD_BUNDLE}")" == "good" ]] || log_warn "good bundle name '$(basename "${GOOD_BUNDLE}")' does not look good — MOCK forces health=good regardless"
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
  echo "=============================================================="
  echo " CeraLive Stage 4 — REAL-HW RAUC A/B rollback + commit test"
  echo " Mode   : ${MODE^^}$( [[ ${MODE} == live ]] && echo " (${SSH_USER}@${BOARD_IP}:${SSH_PORT})" || echo " (simulated board; drives the REAL shipped scripts)")"
  echo " Engine : ceralive-boot-state.sh / ceralive-rauc-boot-adapter.sh"
  echo " Gate   : ceralive-healthcheck.sh (mark-good only on real streaming health)"
  echo " Budget : boot-attempts=${BOOT_ATTEMPTS}"
  echo "=============================================================="

  if [[ "${MODE}" == "live" ]]; then
    preflight_live
  else
    preflight_mock
    log_warn "MOCK mode: this proves the HARNESS + rollback ENGINE are correct without"
    log_warn "hardware. The on-silicon RK3588 run (set BOARD_IP) remains a REQUIRED"
    log_warn "integration step and is NOT satisfied by this run (MUST-NOT: no qemu/mock"
    log_warn "result is accepted as the RK3588 rollback proof)."
    mock_init_board
  fi

  run_bad_bundle_test
  run_good_bundle_test

  echo
  echo "=============================================================="
  printf ' RESULT: %d passed, %d failed  (mode=%s, %ds total)\n' "${PASS}" "${FAIL}" "${MODE}" "${SECONDS}"
  echo "=============================================================="
  [[ "${FAIL}" -eq 0 ]]
}

main "$@"
