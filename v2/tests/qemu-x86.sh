#!/usr/bin/env bash
#
# qemu-x86.sh — headless qemu boot/service/package validation for the x86 image.
#
# THE x86 (amd64) ANALOGUE OF realhw-smoke.sh's LIVE mode, but without real
# hardware: it BOOTS the built x86 disk image inside qemu-system-x86_64, fully
# headless (serial console only), and asserts the OS actually comes up:
#
#   1. systemd reaches multi-user.target          (parsed from the serial boot log)
#   2. `systemctl is-system-running` ∈ {running, degraded}
#         (degraded is accepted — a device image with no streaming config/HW will
#          have some inactive optional units; that is NOT a boot failure)
#   3. ceralive.service is `active` OR at least `loaded`
#         (it legitimately may not auto-start without on-box config / capture HW —
#          loaded-but-inactive is a PASS-with-note, not a hard fail; see task brief)
#   4. key packages/binaries present: systemd, udev (real .debs) + cerastream,
#      srtla_send/srtla_rec (first-party /usr/bin binaries — sysext or .deb)
#
# It is explicitly NOT a substitute for the RK3588 real-hardware gate (realhw-
# smoke.sh LIVE + task 38) and does NOT attempt a streaming encode (no VAAPI/QSV
# or capture HW exists in qemu — the engine selects its encode element at runtime, so we
# validate that the service LOADS, never that it encodes).
#
# ---------------------------------------------------------------------------
# TWO MODES (auto-selected; the ASSERTION ENGINE is identical in both).
# ---------------------------------------------------------------------------
#
#   BOOT mode (default) — qemu REQUIRED. Boots IMAGE_PATH headlessly, captures the
#     serial console to a transcript, drives `systemctl`/package probes over the
#     serial getty, then runs assert_transcript() on what the booted OS reported.
#     If qemu (or, for the EFI/GRUB x86 image, OVMF firmware) is unavailable, it
#     GRACEFULLY SKIPS with a loud "qemu unavailable — skip" log and exits 0 — the
#     CI leg is continue-on-error and the DRY_RUN build matrix ships no bootable
#     image, so a missing-qemu/missing-image runner must not be a hard failure.
#
#   SELFTEST mode (CERALIVE_QEMU_SELFTEST=1 or `--selftest`) — qemu NOT required.
#     Exercises the assertion ENGINE against two synthetic serial transcripts:
#       * a HEALTHY transcript  → the engine MUST pass (exit 0)
#       * a BROKEN transcript   (a critical package reported absent) → the engine
#         MUST FAIL (non-zero)
#     This is the harness's own negative test: it proves the gate actually trips
#     when the image is bad, and it runs everywhere (no qemu, no image, no root) —
#     which is how the committed task-36 evidence is produced.
#
# DESIGN (inherited from common.sh + realhw-smoke.sh + rauc-rollback.sh):
#   * common.sh installs `set -euo pipefail` + a loud ERR-trap-that-exits. Like the
#     sibling harnesses we COLLECT failures and OWN the exit code, and we probe
#     things that are EXPECTED to sometimes fail (qemu read timeouts, an inactive
#     ceralive.service). So we drop -e and the ERR trap; keep nounset + pipefail.
#   * NO `|| true` swallowing of meaningful errors. Expected-to-sometimes-fail
#     probes are wrapped in explicit `if … then pass else fail/warn fi`.
#   * The qemu invocation is the task-specified headless form:
#       qemu-system-x86_64 -nographic -m 1024 -drive file=<img>,format=raw \
#                          -serial mon:stdio   (+ OVMF for EFI, +kvm:tcg accel)
#     We drive it through a coprocess so the same stdio carries both the captured
#     boot log AND the commands we type at the serial getty.
#
# ---------------------------------------------------------------------------
# ENV
# ---------------------------------------------------------------------------
#   IMAGE_PATH                 x86 disk image to boot (.img / .raw / .img.xz / .raw.xz).
#                              Unset → auto-discover newest under images/<BOARD>/.
#   BOARD                      board name for artifact discovery (default x86-minipc)
#   QEMU_MEM_MB                guest RAM in MiB (default 1024 — task spec)
#   BOOT_TIMEOUT               seconds to wait for multi-user.target  (default 120)
#   LOGIN_TIMEOUT              seconds to wait for a serial login/shell (default 60)
#   SERIAL_USER                serial-getty login user   (default root)
#   SERIAL_PASSWORD            serial-getty password     (default empty → passwordless)
#   OVMF_PATH                  explicit OVMF firmware (.fd) for EFI boot (auto-detected)
#   QEMU_BIN                   qemu binary (default qemu-system-x86_64)
#   CERALIVE_QEMU_SELFTEST=1   force SELFTEST mode (negative test of the engine)
#   QEMU_TRANSCRIPT            assert an EXISTING transcript file instead of booting
#                              (engine-only; used by SELFTEST and for offline replay)
#
# Exit 0 on pass (or graceful skip); non-zero iff a hard assertion failed.
#
# shellcheck shell=bash

HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
V2_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${V2_DIR}/lib/common.sh"

# common.sh sets `set -euo pipefail` + a loud ERR trap that exits 1. This harness
# collects failures, owns its exit code, and captures `$?` from probes that are
# EXPECTED to fail (qemu read timeouts, an inactive optional unit). Drop -e + the
# ERR trap; keep nounset + pipefail (matches rauc-rollback.sh).
set +e
trap - ERR
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (env-overridable; nothing product-specific hardcoded in logic).
# ---------------------------------------------------------------------------
IMAGES_DIR="${V2_DIR}/images"

# x86 A/B boot-state engine (shipped). The forced-primary-failure ROLLBACK proof
# drives THIS real engine (the userspace twin of the on-device grub.cfg selector),
# never a re-implementation — mirroring how rauc-rollback.sh drives the RK3588
# shipped scripts. See mkosi/platform/x86/README.md ("How rollback happens").
X86_BOOT_STATE="${X86_BOOT_STATE:-${V2_DIR}/mkosi/platform/x86/x86-boot-state.sh}"
X86_BOOT_ATTEMPTS="${X86_BOOT_ATTEMPTS:-3}"

BOARD="${BOARD:-x86-minipc}"
IMAGE_PATH="${IMAGE_PATH:-}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_MEM_MB="${QEMU_MEM_MB:-1024}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-120}"
LOGIN_TIMEOUT="${LOGIN_TIMEOUT:-60}"
SERIAL_USER="${SERIAL_USER:-root}"
SERIAL_PASSWORD="${SERIAL_PASSWORD:-}"
OVMF_PATH="${OVMF_PATH:-}"
QEMU_TRANSCRIPT="${QEMU_TRANSCRIPT:-}"

# The main application unit. ceralive.service is what the CeraUI .deb ships
# (mkosi/app/build-ceraui-appfs.sh: /etc/systemd/system/ceralive.service). Accept
# ceraui.service too — realhw-smoke.sh handles both names (task: relay services
# per task 33 reuse the same unit name).
APP_SERVICE_CANDIDATES=(ceralive.service ceraui.service)

# Critical packages/binaries the booted x86 OS must show. systemd + udev are real
# Debian packages (queryable via dpkg-query); cerastream + srtla ship as first-party
# /usr/bin binaries (sysext on x86 per the board manifest's app_backend: sysext, or
# .deb) so they are probed by `command -v`, not dpkg.
EXPECTED_DPKG=(systemd udev)
EXPECTED_BINS=(cerastream srtla_send srtla_rec)

# Unique markers bracketing the in-guest probe block so the engine can locate the
# command output deterministically inside the noisy serial boot log.
MARK_BEGIN="===CERALIVE-QEMU-CHECK-BEGIN==="
MARK_END="===CERALIVE-QEMU-CHECK-END==="

PASS=0; WARN=0; FAIL=0
pass() { log_success "PASS  $*"; PASS=$((PASS + 1)); }
warn() { log_warn    "WARN  $*"; WARN=$((WARN + 1)); }
fail() { log_error   "FAIL  $*"; FAIL=$((FAIL + 1)); }

declare -a CLEANUP_FILES=()
declare -a CLEANUP_DIRS=()
QEMU_PID=""
cleanup() {
  local f d
  if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
    kill "${QEMU_PID}" 2>/dev/null
    # give it a moment, then make sure it is gone
    sleep 1
    kill -9 "${QEMU_PID}" 2>/dev/null
  fi
  for f in "${CLEANUP_FILES[@]:-}"; do [[ -n "${f}" && -f "${f}" ]] && rm -f "${f}"; done
  for d in "${CLEANUP_DIRS[@]:-}"; do [[ -n "${d}" && -d "${d}" ]] && rm -rf "${d}"; done
}
trap cleanup EXIT

# ===========================================================================
# IMAGE + FIRMWARE RESOLUTION
# ===========================================================================

# discover_image — newest images/<BOARD>/*.img[.xz] (the Stage-4 disk artifact).
discover_image() {
  local cand
  cand="$(find "${IMAGES_DIR}/${BOARD}" -maxdepth 1 -type f \
            \( -name '*.img' -o -name '*.img.xz' -o -name '*.raw' -o -name '*.raw.xz' \) \
            2>/dev/null | sort | tail -1)"
  [[ -n "${cand}" ]] && { printf '%s' "${cand}"; return 0; }
  return 1
}

# materialize_raw <image> <out_var> — yield a plain raw disk path qemu can -drive.
# Decompresses *.xz into a temp file (cleaned on exit); passes .img/.raw through.
materialize_raw() {
  local img="$1" __out="$2" tmp raw
  case "${img}" in
    *.xz)
      tmp="$(mktemp -d)"; CLEANUP_DIRS+=("${tmp}")
      raw="${tmp}/$(basename "${img%.xz}")"
      if ! xz -dc "${img}" >"${raw}"; then
        fail "xz decompress failed for ${img}"; return 1
      fi
      printf -v "${__out}" '%s' "${raw}"; return 0 ;;
    *.img|*.raw)
      printf -v "${__out}" '%s' "${img}"; return 0 ;;
    *)
      fail "unrecognized x86 image type: ${img} (want .img | .raw | .img.xz | .raw.xz)"
      return 1 ;;
  esac
}

# resolve_ovmf — locate a unified OVMF firmware image for EFI/GRUB boot (the x86
# image is UEFI → GRUB, task 33). Honors $OVMF_PATH, else probes the well-known
# Debian/Fedora/Arch locations. Empty result → caller falls back to legacy BIOS.
resolve_ovmf() {
  if [[ -n "${OVMF_PATH}" ]]; then
    [[ -f "${OVMF_PATH}" ]] && { printf '%s' "${OVMF_PATH}"; return 0; }
    return 1
  fi
  local c
  for c in \
    /usr/share/ovmf/OVMF.fd \
    /usr/share/OVMF/OVMF.fd \
    /usr/share/qemu/OVMF.fd \
    /usr/share/edk2-ovmf/x64/OVMF.fd \
    /usr/share/edk2/ovmf/OVMF.fd; do
    [[ -f "${c}" ]] && { printf '%s' "${c}"; return 0; }
  done
  return 1
}

# ===========================================================================
# BOOT + SERIAL CAPTURE (qemu via coprocess)
# ===========================================================================

# wait_for <fd> <transcript> <regex> <timeout_s> — read lines from the qemu
# coprocess output fd, append each to the transcript, return 0 the moment a line
# matches <regex>; return 1 on timeout. Wall-clock bounded via SECONDS.
wait_for() {
  local fd="$1" transcript="$2" regex="$3" timeout="$4"
  local line deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if IFS= read -r -t 2 -u "${fd}" line; then
      printf '%s\n' "${line}" >>"${transcript}"
      [[ "${line}" =~ ${regex} ]] && return 0
    fi
  done
  return 1
}

# drain <fd> <transcript> <seconds> — keep appending serial output for a fixed
# window (so the in-guest probe block fully lands in the transcript).
drain() {
  local fd="$1" transcript="$2" seconds="$3" line
  local deadline=$((SECONDS + seconds))
  while (( SECONDS < deadline )); do
    if IFS= read -r -t 2 -u "${fd}" line; then
      printf '%s\n' "${line}" >>"${transcript}"
      [[ "${line}" == *"${MARK_END}"* ]] && return 0
    fi
  done
  return 0
}

# send <fd> <text> — type a line at the guest serial console (CR-terminated).
send() { printf '%s\r' "$2" >&"$1"; }

# guest_probe_script — the command block we type at the serial shell. Each result
# is emitted on its own KEY=VALUE line between the markers so assert_transcript()
# can parse it out of the boot-log noise. dpkg-query for real .debs; command -v for
# first-party binaries (sysext/.deb-agnostic).
guest_probe_script() {
  printf 'echo %s\n' "${MARK_BEGIN}"
  printf 'echo "SYS_RUNNING=$(systemctl is-system-running 2>/dev/null || true)"\n'
  printf 'echo "SYS_FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)"\n'
  # ceralive.service (or ceraui.service): report both active-state and load-state.
  local svc
  for svc in "${APP_SERVICE_CANDIDATES[@]}"; do
    printf 'echo "ACTIVE:%s=$(systemctl is-active %s 2>/dev/null || true)"\n' "${svc}" "${svc}"
    printf 'echo "LOAD:%s=$(systemctl show -p LoadState --value %s 2>/dev/null || true)"\n' "${svc}" "${svc}"
  done
  local p
  for p in "${EXPECTED_DPKG[@]}"; do
    printf 'echo "DPKG:%s=$(dpkg-query -W -f=\\${Status} %s 2>/dev/null || echo absent)"\n' "${p}" "${p}"
  done
  for p in "${EXPECTED_BINS[@]}"; do
    printf 'echo "BIN:%s=$(command -v %s >/dev/null 2>&1 && echo present || echo absent)"\n' "${p}" "${p}"
  done
  printf 'echo %s\n' "${MARK_END}"
}

# boot_and_capture <raw_image> <transcript> — run qemu headless, wait for the
# multi-user.target reach signal, log in at the serial getty, run the probe block,
# and capture everything into <transcript>. Returns 0 if the boot reach signal was
# seen (the probe block is best-effort: a no-login appliance still passes the
# boot+passive checks). Returns 1 if the image never reached multi-user.target.
boot_and_capture() {
  local raw="$1" transcript="$2"
  : >"${transcript}"

  local -a qargs=(
    -nographic
    -no-reboot
    -m "${QEMU_MEM_MB}"
    -machine "q35,accel=kvm:tcg"
    -drive "file=${raw},format=raw,if=ide"
    -serial mon:stdio
  )
  # EFI/GRUB x86 image (task 33) needs OVMF; fall back to legacy BIOS with a warn.
  local ovmf
  if ovmf="$(resolve_ovmf)"; then
    qargs+=(-bios "${ovmf}")
    log_info "qemu firmware: OVMF EFI (${ovmf})"
  else
    warn "no OVMF firmware found — booting legacy BIOS (the x86 image is EFI/GRUB; boot may not reach userspace). Install 'ovmf' to enable EFI boot."
  fi

  log_info "launching: ${QEMU_BIN} ${qargs[*]}"
  # Coprocess: ${QEMU[0]} = serial+console output, ${QEMU[1]} = serial input.
  coproc QEMU { exec "${QEMU_BIN}" "${qargs[@]}" 2>&1; }
  QEMU_PID="${COPROC_PID}"

  # 1. Wait for systemd to reach multi-user.target. systemd prints either
  #    "Reached target multi-user.target" (unit id) or "Reached target
  #    Multi-User System." (description) depending on version — match both.
  local reach_re='Reached target ([Mm]ulti-[Uu]ser|multi-user\.target)'
  if ! wait_for "${QEMU[0]}" "${transcript}" "${reach_re}" "${BOOT_TIMEOUT}"; then
    fail "image did not reach multi-user.target within ${BOOT_TIMEOUT}s (see transcript)"
    return 1
  fi
  pass "systemd reached multi-user.target (serial boot signal)"

  # 2. Reach the serial getty and log in, then fire the probe block. This is
  #    best-effort: if the appliance has no serial getty / unknown credentials, we
  #    skip the active probes and rely on the passive boot-log assertions.
  local login_re='([Ll]ogin:|\$ |# )'
  if wait_for "${QEMU[0]}" "${transcript}" "${login_re}" "${LOGIN_TIMEOUT}"; then
    send "${QEMU[1]}" "${SERIAL_USER}"
    sleep 1
    if [[ -n "${SERIAL_PASSWORD}" ]]; then
      # Wait for the Password: prompt before sending it.
      wait_for "${QEMU[0]}" "${transcript}" '[Pp]assword:' 15
      send "${QEMU[1]}" "${SERIAL_PASSWORD}"
      sleep 1
    fi
    # Type the probe block; force a non-interactive, stable prompt first.
    send "${QEMU[1]}" "export PS1='qemu# '"
    local cmdline
    while IFS= read -r cmdline; do send "${QEMU[1]}" "${cmdline}"; done < <(guest_probe_script)
    # Let the probe output land (bounded by the END marker).
    drain "${QEMU[0]}" "${transcript}" 30
  else
    warn "no serial login/shell prompt within ${LOGIN_TIMEOUT}s — running PASSIVE boot-log checks only (set SERIAL_USER/SERIAL_PASSWORD if the image needs login)"
  fi
  return 0
}

# ===========================================================================
# ASSERTION ENGINE — operates purely on a captured serial transcript.
# This is the SINGLE source of pass/warn/fail truth, shared by BOOT and SELFTEST.
# ===========================================================================

# tget <transcript> <key> — last value of an emitted `KEY=VALUE` probe line.
tget() { sed -n "s/^$2=//p" "$1" | tail -1; }

assert_transcript() {
  local transcript="$1"

  # --- Boot reach signal (the passive, always-available assertion) -------------
  if grep -qE 'Reached target ([Mm]ulti-[Uu]ser|multi-user\.target)' "${transcript}"; then
    pass "transcript shows multi-user.target reached"
  else
    fail "transcript has NO multi-user.target reach signal — OS did not finish booting"
  fi

  # If the probe block never made it into the transcript (no serial login), the
  # active checks below are undecidable — warn-degrade rather than false-fail.
  if ! grep -qF "${MARK_BEGIN}" "${transcript}"; then
    warn "no in-guest probe block in transcript — skipping service/package assertions (passive boot check only)"
    return
  fi

  # --- systemctl is-system-running ∈ {running, degraded} -----------------------
  local sysrun; sysrun="$(tget "${transcript}" 'SYS_RUNNING')"
  case "${sysrun}" in
    running)  pass "systemctl is-system-running = running" ;;
    degraded) pass "systemctl is-system-running = degraded (accepted — optional units inactive without config/HW)" ;;
    starting|maintenance|stopping)
      fail "systemctl is-system-running = ${sysrun} (system not settled / in maintenance)" ;;
    "") fail "systemctl is-system-running produced no output (probe failed)" ;;
    *)  fail "systemctl is-system-running = '${sysrun}' (unexpected state)" ;;
  esac

  # --- ceralive.service (active preferred; loaded accepted) --------------------
  local svc active_state load_state decided=""
  for svc in "${APP_SERVICE_CANDIDATES[@]}"; do
    active_state="$(tget "${transcript}" "ACTIVE:${svc}")"
    load_state="$(tget "${transcript}" "LOAD:${svc}")"
    [[ -z "${active_state}${load_state}" ]] && continue
    if [[ "${active_state}" == "active" ]]; then
      pass "${svc} is active"; decided=1; break
    elif [[ "${load_state}" == "loaded" ]]; then
      pass "${svc} is loaded (inactive — acceptable: may not auto-start without on-box config/capture HW)"
      decided=1; break
    fi
  done
  if [[ -z "${decided}" ]]; then
    fail "no application unit active or loaded — neither ${APP_SERVICE_CANDIDATES[*]} present"
  fi

  # --- Critical packages (dpkg) ------------------------------------------------
  local p st
  for p in "${EXPECTED_DPKG[@]}"; do
    st="$(tget "${transcript}" "DPKG:${p}")"
    if [[ "${st}" == *"install ok installed"* ]]; then
      pass "package installed: ${p}"
    else
      fail "critical package MISSING: ${p} (dpkg status: '${st:-<no output>}')"
    fi
  done

  # --- Critical first-party binaries (command -v) ------------------------------
  for p in "${EXPECTED_BINS[@]}"; do
    st="$(tget "${transcript}" "BIN:${p}")"
    case "${st}" in
      present) pass "binary present: ${p}" ;;
      absent)  fail "critical binary MISSING: ${p} (not on PATH)" ;;
      "")      warn "binary ${p}: no probe output (first-party layer may be absent in CI without R2/gh creds)" ;;
      *)       fail "binary ${p}: unexpected probe value '${st}'" ;;
    esac
  done
}

# ===========================================================================
# SELFTEST — the harness's own NEGATIVE test (no qemu/image/root required).
# ===========================================================================

# synth_transcript <healthy|broken> — emit a synthetic serial transcript. The
# broken variant reports a critical package ABSENT so the engine MUST trip.
synth_transcript() {
  local kind="$1"
  cat <<EOF
[    1.234567] systemd[1]: Detected architecture x86-64.
[    9.876543] systemd[1]: Reached target multi-user.target.
Debian GNU/Linux 12 ceralive ttyS0
ceralive login: root
${MARK_BEGIN}
SYS_RUNNING=degraded
SYS_FAILED=0
ACTIVE:ceralive.service=inactive
LOAD:ceralive.service=loaded
ACTIVE:ceraui.service=inactive
LOAD:ceraui.service=not-found
EOF
  if [[ "${kind}" == "broken" ]]; then
    # Critical package udev reported absent → the gate must FAIL.
    cat <<EOF
DPKG:systemd=install ok installed
DPKG:udev=absent
BIN:cerastream=present
BIN:srtla_send=present
BIN:srtla_rec=absent
${MARK_END}
EOF
  else
    cat <<EOF
DPKG:systemd=install ok installed
DPKG:udev=install ok installed
BIN:cerastream=present
BIN:srtla_send=present
BIN:srtla_rec=present
${MARK_END}
EOF
  fi
}

# run_engine_on <transcript> — run assert_transcript in an isolated counter scope
# and return its hard-fail verdict (0 = engine passed, 1 = engine failed). Used by
# SELFTEST so the parent counters are not polluted by the synthetic runs.
run_engine_on() {
  local transcript="$1"
  ( PASS=0; WARN=0; FAIL=0
    assert_transcript "${transcript}"
    log_info "engine result: ${PASS} pass / ${WARN} warn / ${FAIL} fail"
    (( FAIL == 0 )) )
}

run_selftest() {
  log_info "=== SELFTEST: validating the assertion engine (no qemu/image) ==="
  local d; d="$(mktemp -d)"; CLEANUP_DIRS+=("${d}")
  local healthy="${d}/healthy.log" broken="${d}/broken.log"
  synth_transcript healthy >"${healthy}"
  synth_transcript broken  >"${broken}"

  log_info "--- positive case: HEALTHY transcript MUST pass ---"
  if run_engine_on "${healthy}"; then
    pass "engine PASSES a healthy x86 boot transcript"
  else
    fail "engine FAILED a healthy transcript (false negative — gate is broken)"
  fi

  log_info "--- negative case: BROKEN transcript (critical pkg absent) MUST fail ---"
  if run_engine_on "${broken}"; then
    fail "engine PASSED a broken transcript (false positive — gate does NOT trip on a missing package!)"
  else
    pass "engine correctly FAILS when a critical package/binary is absent"
  fi
}

# ===========================================================================
# FALLBACK SELFTEST — forced primary-slot failure MUST roll back to the known-good
# slot. Drives the SHIPPED x86 grubenv A/B engine (mkosi/platform/x86/x86-boot-
# state.sh) — the userspace twin of the on-device grub.cfg selector — with NO qemu,
# GRUB, root or image. The x86 analogue of rauc-rollback.sh's MOCK mode: it proves
# the rollback CONTRACT (a primary slot that never confirms itself bleeds its
# bootcount, then the selector skips it and boots the last-good slot) against the
# REAL engine, not a stand-in. The exhaustive engine coverage lives in the engine's
# own unit test (mkosi/platform/x86/test-x86-fallback.sh); this harness asserts the
# one scenario the boot harness owns: forced primary failure -> rollback.
# ===========================================================================
run_fallback_selftest() {
  log_info "=== FALLBACK SELFTEST: forced primary-slot failure → rollback to good slot ==="
  if [[ ! -r "${X86_BOOT_STATE}" ]]; then
    fail "x86 boot-state engine not found/readable: ${X86_BOOT_STATE}"
    return
  fi

  local d grubenv
  d="$(mktemp -d)"; CLEANUP_DIRS+=("${d}")
  grubenv="${d}/grubenv"

  # Drive the shipped engine against a throwaway grubenv, forcing its bash grubenv
  # fallback (GRUB_EDITENV → a nonexistent binary) so this runs on hosts with no GRUB
  # tooling. CERALIVE_BOOT_ATTEMPTS is the per-slot bootcount budget (3→2→1→0).
  bs() {
    CERALIVE_GRUBENV="${grubenv}" CERALIVE_BOOT_ATTEMPTS="${X86_BOOT_ATTEMPTS}" \
      GRUB_EDITENV=/nonexistent-grub-editenv bash "${X86_BOOT_STATE}" "$@"
  }

  bs init
  if [[ "$(bs get-primary)" == "A" ]]; then pass "fresh A/B: primary slot is A"
  else fail "fresh A/B: primary is not A (got '$(bs get-primary)')"; fi
  if [[ "$(bs get-state A)" == "good" && "$(bs get-state B)" == "good" ]]; then pass "fresh A/B: both slots good (B is the known-good fallback)"
  else fail "fresh A/B: a slot is not good (A=$(bs get-state A) B=$(bs get-state B))"; fi

  # Non-vacuity control: ONE failed boot of A must NOT roll back yet (A still has
  # budget). Proves the gate trips only on EXHAUSTION, not on any single failure.
  local sel; sel="$(bs boot-select)"
  if [[ "${sel%% *}" == "A" && "$(bs get-primary)" == "A" ]]; then
    pass "control: 1 failed boot does NOT roll back (A still primary with budget)"
  else
    fail "control: rolled back too early (sel='${sel}' primary='$(bs get-primary)')"
  fi

  # Forced primary failure: slot A never confirms itself (no mark-good). Keep booting
  # until A's bootcount exhausts; the selector MUST then fall back to slot B.
  local reboots=1 booted="${sel%% *}" cap=$(( X86_BOOT_ATTEMPTS + 2 ))
  while (( reboots < cap )); do
    reboots=$(( reboots + 1 ))
    sel="$(bs boot-select)"; booted="${sel%% *}"
    [[ "${booted}" == "B" ]] && break
  done

  if [[ "${booted}" == "B" ]]; then
    pass "ROLLBACK: forced A failure fell back to known-good slot B after ${reboots} boot(s)"
  else
    fail "NO ROLLBACK: still on slot '${booted}' after ${reboots} boot(s) — bad primary did not roll back"
  fi
  if [[ "${sel}" == "B rootfs_b" ]]; then pass "fallback selects B by its rootfs PARTLABEL (rootfs_b)"
  else fail "fallback target wrong: '${sel}' (want 'B rootfs_b')"; fi
  if [[ "$(bs get-state A)" == "bad" ]]; then pass "exhausted primary A is now 'bad' (bootcount drained to 0)"
  else fail "slot A not marked bad after exhaustion (got '$(bs get-state A)')"; fi
  if [[ "$(bs get-state B)" == "good" ]]; then pass "rollback target B remained 'good' (known-good preserved)"
  else fail "known-good slot B no longer good (got '$(bs get-state B)')"; fi

  # Recovery: a healthy slot that mark-good's itself stops counting down — a
  # confirmed slot is sticky and never silently reverts on the next boot.
  bs mark-good B
  bs boot-select >/dev/null
  if [[ "$(bs get-state B)" == "good" && "$(bs get-primary)" == "B" ]]; then
    pass "recovery: mark-good keeps B sticky (confirmed slot does not roll back)"
  else
    fail "recovery: confirmed slot B not sticky (primary=$(bs get-primary) state=$(bs get-state B))"
  fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
  # --selftest runs the boot-engine AND fallback proofs; --fallback-selftest runs
  # only the forced-primary-failure rollback proof (mirrors the env switches below).
  if [[ "${1:-}" == "--selftest" ]]; then CERALIVE_QEMU_SELFTEST=1; fi
  if [[ "${1:-}" == "--fallback-selftest" ]]; then CERALIVE_QEMU_FALLBACK_SELFTEST=1; fi

  if [[ "${CERALIVE_QEMU_FALLBACK_SELFTEST:-0}" == "1" ]]; then
    run_fallback_selftest
  elif [[ "${CERALIVE_QEMU_SELFTEST:-0}" == "1" ]]; then
    run_selftest
    run_fallback_selftest
  elif [[ -n "${QEMU_TRANSCRIPT}" ]]; then
    # Engine-only replay against an existing transcript (offline / debugging).
    [[ -f "${QEMU_TRANSCRIPT}" ]] || die "QEMU_TRANSCRIPT not found: ${QEMU_TRANSCRIPT}"
    log_info "=== ENGINE replay against ${QEMU_TRANSCRIPT} (no boot) ==="
    assert_transcript "${QEMU_TRANSCRIPT}"
  else
    # ---- BOOT mode: graceful skip if the runner cannot boot a qemu x86 image ----
    if ! command -v "${QEMU_BIN}" >/dev/null 2>&1; then
      log_warn "qemu unavailable — skip: '${QEMU_BIN}' not found. Install it with 'apt-get install qemu-system-x86'. (Treated as a SKIP, not a failure — CI leg is continue-on-error.)"
      log_success "QEMU SKIP — runner has no ${QEMU_BIN}; nothing booted"
      return 0
    fi

    local img="${IMAGE_PATH}"
    if [[ -z "${img}" ]]; then
      if ! img="$(discover_image)"; then
        log_warn "qemu boot skip: no IMAGE_PATH set and no x86 disk image under ${IMAGES_DIR}/${BOARD}/ (DRY_RUN build matrix ships none). Nothing to boot."
        log_success "QEMU SKIP — no bootable x86 image artifact present"
        return 0
      fi
      log_info "auto-discovered x86 image: ${img}"
    fi
    if [[ ! -e "${img}" ]]; then
      fail "IMAGE_PATH does not exist: ${img}"
    else
      require_cmd xz
      local raw=""
      if materialize_raw "${img}" raw && [[ -n "${raw}" ]]; then
        local transcript; transcript="$(mktemp)"; CLEANUP_FILES+=("${transcript}")
        log_info "=== BOOT mode: booting x86 image headlessly in qemu ==="
        log_info "image=${img} board=${BOARD} mem=${QEMU_MEM_MB}MiB boot_timeout=${BOOT_TIMEOUT}s"
        boot_and_capture "${raw}" "${transcript}"
        log_info "--- asserting captured serial transcript (${transcript}) ---"
        assert_transcript "${transcript}"
      else
        fail "could not materialize a raw disk from ${img}"
      fi
    fi
  fi

  # ---- Summary + exit code ----------------------------------------------------
  log_info "=== qemu-x86 summary: ${PASS} pass / ${WARN} warn / ${FAIL} fail ==="
  if (( FAIL > 0 )); then
    log_error "QEMU x86 VALIDATION FAILED (${FAIL} hard failure(s))"
    return 1
  fi
  if (( WARN > 0 )); then
    log_warn "qemu-x86 OK with ${WARN} warning(s) (CI-gated gaps: no OVMF, no serial login, or first-party debs absent)"
  fi
  log_success "QEMU x86 VALIDATION OK"
  return 0
}

main "$@"
