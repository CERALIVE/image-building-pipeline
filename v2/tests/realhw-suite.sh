#!/usr/bin/env bash
#
# realhw-suite.sh — Stage 6 CONSOLIDATED real-HW RK3588 smoke suite.
#
# THE single CI-invokable acceptance gate. It does NOT reimplement any check; it
# ORCHESTRATES the harnesses Stages 1–4 already built, runs them in sequence with
# clear section headers, aggregates PASS/FAIL/SKIP, and emits ONE pass/fail signal
# plus an evidence bundle. This is what the self-hosted `ceralive-rk3588` runner
# (task 37) invokes nightly and on release branches.
#
# FOUR SECTIONS (each a thin wrapper over an existing tool — no logic duplicated):
#
#   1. BOOT + SERVICE      → tests/realhw-smoke.sh
#        LIVE: BOARD_IP → SSH login, ceralive.service active, binaries + quirks,
#              full live parity-check against the running rootfs.
#        MOCK: STATIC mode (no BOARD_IP) against an IMAGE_PATH rootfs (a complete
#              fixture is synthesized when none is supplied) — runs the SAME
#              parity-check.sh path offline.
#
#   2. ENCODE-PATH INIT    → ceracoder --version + srtla_send --version
#        Confirms the encode-path binaries INITIALIZE (load + answer --version).
#        This is the streaming/encode-path init check — NOT a full encode (no
#        capture HW needed). LIVE: over SSH. MOCK: the shipped binaries locally.
#
#   3. DEV-LOOP SANITY     → v2/dev-push (OPTIONAL)
#        Confirms the <120 s code→device dev loop still delivers. LIVE: runs
#        dev-push against the board when DEV_DEB_DIR (an arm64 .deb dir) is given,
#        else SKIP (optional). MOCK: DRY_RUN dev-push proves the
#        build→rsync→refresh→restart loop + the budget gate offline.
#
#   4. RAUC A/B ROLLBACK   → tests/rauc-rollback.sh
#        LIVE: BOARD_IP + BUNDLE_DIR → bad bundle falls back, good bundle marks
#              good and persists. MOCK: rauc-rollback's own MOCK mode (drives the
#              REAL shipped boot-state/adapter/healthcheck scripts, no HW).
#
# ---------------------------------------------------------------------------
# MODES
# ---------------------------------------------------------------------------
#   LIVE  — BOARD_IP set (and MOCK!=1). Real silicon. The authoritative gate.
#   MOCK  — MOCK=1, or no BOARD_IP. Proves the suite + each sub-harness OFFLINE
#           path with the SAME structure + exit semantics as LIVE. MUST-NOT: a
#           MOCK pass is NOT accepted as the RK3588 rollback proof — the on-silicon
#           run on the self-hosted runner remains required.
#
# ---------------------------------------------------------------------------
# ENV
# ---------------------------------------------------------------------------
#   BOARD         board manifest name (default rock-5b-plus) — drives smoke quirks
#   BOARD_IP      LIVE SSH target (unset → MOCK)
#   SSH_USER      LIVE SSH user (default ceralive)
#   SSH_PORT      LIVE SSH port (default 22)
#   BUNDLE_DIR    dir with bad.raucb/good.raucb (LIVE rollback; optional in MOCK)
#   IMAGE_PATH    rootfs/image for the STATIC smoke (MOCK auto-synthesizes if unset)
#   DEV_DEB_DIR   LIVE dev-loop: dir with an arm64 ceracoder .deb (else section SKIPs)
#   EVIDENCE_DIR  evidence bundle dir (default <workspace>/test-results/realhw-task-38-smoke)
#   MOCK=1        force MOCK mode even if BOARD_IP is set
#
# Exit 0 iff zero sections FAILed (SKIP never fails the gate); 1 otherwise.
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2_DIR="$(cd "${HERE}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${V2_DIR}/../.." && pwd)"

# shellcheck source=../lib/common.sh
source "${V2_DIR}/lib/common.sh"

# We aggregate sub-harness results and OWN the exit code (exactly like the
# harnesses we call). Drop common.sh's ERR trap + set -e; keep nounset+pipefail.
set +e
trap - ERR
set -uo pipefail

# --- sub-harness + tool locations (env-overridable for testing) -------------
SMOKE_SH="${SMOKE_SH:-${HERE}/realhw-smoke.sh}"
ROLLBACK_SH="${ROLLBACK_SH:-${HERE}/rauc-rollback.sh}"
DEV_PUSH="${DEV_PUSH:-${V2_DIR}/dev-push}"
CERAUI_BASE_CONF="${CERAUI_BASE_CONF:-${V2_DIR}/../configs/base/ceraui-base.conf}"

# --- config -----------------------------------------------------------------
BOARD="${BOARD:-rock-5b-plus}"
BOARD_IP="${BOARD_IP:-}"
SSH_USER="${SSH_USER:-ceralive}"
SSH_PORT="${SSH_PORT:-22}"
BUNDLE_DIR="${BUNDLE_DIR:-}"
IMAGE_PATH="${IMAGE_PATH:-}"
DEV_DEB_DIR="${DEV_DEB_DIR:-}"
EVIDENCE_DIR="${EVIDENCE_DIR:-${WORKSPACE_ROOT}/test-results/realhw-task-38-smoke}"

# Mode: explicit MOCK=1 forces mock; else BOARD_IP→live; else mock (offline).
MODE="${CERALIVE_SUITE_MODE:-}"
if [[ -z "${MODE}" ]]; then
  if   [[ "${MOCK:-0}" == "1" ]]; then MODE="mock"
  elif [[ -n "${BOARD_IP}" ]];    then MODE="live"
  else                                 MODE="mock"
  fi
fi

SSH_BASE_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
ssh_run() { ssh "${SSH_BASE_OPTS[@]}" -p "${SSH_PORT}" "${SSH_USER}@${BOARD_IP}" "$@"; }

# Synthesized-fixture handles (MOCK mode only).
MOCK_TAR=""
MOCK_BIN=""
MOCK_DEB_DIR=""

# --- result bookkeeping -----------------------------------------------------
declare -a SEC_NAME=() SEC_RESULT=()
PASS=0; FAIL=0; SKIP=0
record() {                                   # record <name> <rc:0 pass|2 skip|* fail>
  local name="$1" rc="$2"
  SEC_NAME+=("${name}")
  if   [[ "${rc}" == "0" ]]; then SEC_RESULT+=("PASS"); PASS=$((PASS+1)); log_success "▣ PASS — ${name}"
  elif [[ "${rc}" == "2" ]]; then SEC_RESULT+=("SKIP"); SKIP=$((SKIP+1)); log_warn    "▣ SKIP — ${name}"
  else                            SEC_RESULT+=("FAIL"); FAIL=$((FAIL+1)); log_error   "▣ FAIL — ${name}"
  fi
}
header() { printf '\n========== %s ==========\n' "$*" >&2; }

CLEANUP_DIRS=()
cleanup() { local d; for d in "${CLEANUP_DIRS[@]:-}"; do [[ -n "${d}" && -d "${d}" ]] && rm -rf "${d}"; done; }
trap cleanup EXIT

# ===========================================================================
# MOCK FIXTURES — test INPUT only (NOT a reimplementation of any harness). A
# complete, parity-passing rootfs + a valid first-party .deb so the offline
# STATIC smoke + dev-loop genuinely exercise the real tools end-to-end.
# ===========================================================================

# extract_conf_array <conf> <NAME> — the SAME bash-array extraction parity-check.sh
# uses, so the synthesized dpkg status lists exactly the packages it asserts.
extract_conf_array() {
  awk -v name="$2" '
    $0 ~ "^"name"=\\(" { inarr=1; sub("^"name"=\\(", "") }
    inarr {
      line=$0; sub(/#.*/, "", line); n=split(line, t, /"/)
      for (i=2; i<=n; i+=2) if (t[i] != "") print t[i]
      if (line ~ /\)/) inarr=0
    }
  ' "$1"
}

emit_dpkg_status() {                         # emit_dpkg_status <out>
  local out="$1" arr p
  : > "${out}"
  if [[ -f "${CERAUI_BASE_CONF}" ]]; then
    for arr in BASE_PACKAGES STREAMING_PACKAGES CERAUI_PACKAGES; do
      while IFS= read -r p; do
        [[ -n "${p}" ]] || continue
        printf 'Package: %s\nStatus: install ok installed\nVersion: 0-mock\n\n' "${p}" >> "${out}"
      done < <(extract_conf_array "${CERAUI_BASE_CONF}" "${arr}")
    done
  fi
  # Alias TARGETS parity-check maps to (media-ctl→v4l-utils, belacoder→ceracoder,
  # ceraui→ceralive-device) + Armbian-BSP + first-party → list as installed, so the
  # synthetic rootfs is an all-PASS reference matching a REAL build's package names.
  for p in v4l-utils gstreamer1.0-rockchip1 rockchip-multimedia-config ceralive-device ceracoder srtla srt; do
    printf 'Package: %s\nStatus: install ok installed\nVersion: 0-mock\n\n' "${p}" >> "${out}"
  done
}

build_mock_deb() {                           # build_mock_deb <tmp> → sets MOCK_DEB_DIR
  local tmp="$1"
  local work="${tmp}/debwork" debs="${tmp}/debs"
  mkdir -p "${work}/data/usr/bin" "${work}/control" "${debs}"
  cat > "${work}/data/usr/bin/ceracoder" <<'EOF'
#!/usr/bin/env bash
echo "ceracoder 2026.06.0 (mock deb)"
EOF
  chmod +x "${work}/data/usr/bin/ceracoder"
  printf 'Package: ceracoder\nVersion: 0-mock\nArchitecture: arm64\nMaintainer: ceralive <ci@ceralive.tv>\nDescription: mock ceracoder for dev-loop sanity\n' \
    > "${work}/control/control"
  ( cd "${work}/data"    && tar -czf "${work}/data.tar.gz"    . )
  ( cd "${work}/control" && tar -czf "${work}/control.tar.gz" . )
  printf '2.0\n' > "${work}/debian-binary"
  ( cd "${work}" && ar rc "${debs}/ceracoder_0-mock_arm64.deb" debian-binary control.tar.gz data.tar.gz )
  MOCK_DEB_DIR="${debs}"
}

build_mock_fixtures() {
  local tmp; tmp="$(mktemp -d)"; CLEANUP_DIRS+=("${tmp}")
  local root="${tmp}/rootfs" b svc g
  mkdir -p \
    "${root}/usr/bin" "${root}/var/lib/dpkg" "${root}/etc/systemd/system" \
    "${root}/etc/iproute2" "${root}/etc/udev/rules.d" "${root}/etc/apt/sources.list.d" \
    "${root}/etc/dhcp/dhclient-exit-hooks.d" "${root}/etc/NetworkManager/dispatcher.d"

  # A. packages
  emit_dpkg_status "${root}/var/lib/dpkg/status"
  # B. ceralive user + hardware groups
  printf 'root:x:0:0:root:/root:/bin/bash\nceralive:x:1000:1000:CeraLive:/home/ceralive:/bin/bash\n' \
    > "${root}/etc/passwd"
  : > "${root}/etc/group"
  for g in sudo audio video dialout plugdev netdev gpio i2c spi; do
    printf '%s:x:0:ceralive\n' "${g}" >> "${root}/etc/group"
  done
  # C. enabled services
  for svc in NetworkManager ModemManager ssh chrony avahi-daemon systemd-resolved ceralive-hostname; do
    printf '[Unit]\nDescription=mock %s\n' "${svc}" > "${root}/etc/systemd/system/${svc}.service"
  done
  # D. SRTLA source-policy routing
  printf '100\tmodem0\n101\tmodem1\n110\twlan_bond\n' > "${root}/etc/iproute2/rt_tables"
  printf '#!/bin/sh\n# mock SRTLA dhclient source-routing hook\n' \
    > "${root}/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing"
  printf '#!/bin/sh\n# mock SRTLA NetworkManager wifi-routing dispatcher\n' \
    > "${root}/etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing"
  chmod +x "${root}/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing" \
           "${root}/etc/NetworkManager/dispatcher.d/90-srtla-wifi-routing"
  # E. udev (video4linux satisfies the hdmi quirk) + apt sources
  printf 'SUBSYSTEM=="video4linux", GROUP="video"\nSUBSYSTEM=="usb", TAG+="ceralive"\n' \
    > "${root}/etc/udev/rules.d/99-ceralive-hardware.rules"
  printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: bookworm\nComponents: main\n' \
    > "${root}/etc/apt/sources.list.d/debian.sources"
  printf 'Types: deb\nURIs: https://apt.ceralive.tv\nSuites: stable\nComponents: main\n' \
    > "${root}/etc/apt/sources.list.d/ceralive.sources"
  # first-party binaries: stubs that load + answer --version
  for b in ceracoder srtla_send srtla_rec; do
    cat > "${root}/usr/bin/${b}" <<EOF
#!/usr/bin/env bash
echo "${b} 2026.06.0 (mock)"
EOF
    chmod +x "${root}/usr/bin/${b}"
  done

  # Tar artifact + sha256 sidecar (the STATIC smoke materializes + checksums it).
  ( cd "${root}" && tar -cf "${tmp}/mock-rootfs.tar" . )
  ( cd "${tmp}"  && sha256sum "mock-rootfs.tar" > "mock-rootfs.tar.sha256" )

  MOCK_TAR="${tmp}/mock-rootfs.tar"
  MOCK_BIN="${root}/usr/bin"
  build_mock_deb "${tmp}"
  log_info "MOCK fixtures: rootfs=${MOCK_TAR} bins=${MOCK_BIN} deb=${MOCK_DEB_DIR}"
}

# ===========================================================================
# SECTIONS — each runs a real tool, tees to its evidence log, returns 0/1/2.
# ===========================================================================

sec_boot_service() {
  header "1/4  BOOT + SERVICE   (realhw-smoke.sh)"
  local log="${EVIDENCE_DIR}/01-boot-service.log" rc
  if [[ "${MODE}" == "live" ]]; then
    BOARD="${BOARD}" BOARD_IP="${BOARD_IP}" SSH_USER="${SSH_USER}" SSH_PORT="${SSH_PORT}" IMAGE_PATH="" \
      "${SMOKE_SH}" 2>&1 | tee "${log}"; rc="${PIPESTATUS[0]}"
  else
    BOARD="${BOARD}" BOARD_IP="" IMAGE_PATH="${IMAGE_PATH:-${MOCK_TAR}}" \
      "${SMOKE_SH}" 2>&1 | tee "${log}"; rc="${PIPESTATUS[0]}"
  fi
  return "${rc}"
}

sec_encode_init() {
  header "2/4  ENCODE-PATH INIT   (ceracoder + srtla_send --version)"
  local log="${EVIDENCE_DIR}/02-encode-init.log" rc=0 b out
  : > "${log}"
  for b in ceracoder srtla_send; do
    if [[ "${MODE}" == "live" ]]; then
      out="$(ssh_run "${b} --version </dev/null 2>&1 | head -1" 2>/dev/null)"
    elif [[ -x "${MOCK_BIN}/${b}" ]]; then
      out="$("${MOCK_BIN}/${b}" --version 2>&1 | head -1)"
    else
      out=""
    fi
    if [[ -n "${out}" ]]; then
      printf 'PASS  %s initializes — %s\n' "${b}" "${out}" | tee -a "${log}"
    else
      printf 'FAIL  %s did not initialize (no --version output)\n' "${b}" | tee -a "${log}"
      rc=1
    fi
  done
  return "${rc}"
}

sec_dev_loop() {
  header "3/4  DEV-LOOP SANITY   (dev-push delivers < 120s)"
  local log="${EVIDENCE_DIR}/03-dev-loop.log" rc
  if [[ "${MODE}" == "live" ]]; then
    if [[ -z "${DEV_DEB_DIR}" ]]; then
      echo "SKIP — dev-loop sanity is OPTIONAL; set DEV_DEB_DIR=<arm64 .deb dir> to exercise dev-push live." \
        | tee "${log}"
      return 2
    fi
    DEV_PUSH_BUDGET=120 SSH_USER="${SSH_USER}" \
      "${DEV_PUSH}" --from-deb "${DEV_DEB_DIR}" "${BOARD_IP}" ceracoder 2>&1 | tee "${log}"
    return "${PIPESTATUS[0]}"
  fi
  # MOCK: DRY_RUN dev-push exercises the real build→rsync→refresh→restart loop
  # (rsync/ssh are logged, not run) + the in-tool <120s budget gate.
  if ! command -v mksquashfs >/dev/null 2>&1 || ! command -v ar >/dev/null 2>&1; then
    echo "SKIP — dev-loop MOCK needs mksquashfs + ar (absent on this host); loop proven in task 24." \
      | tee "${log}"
    return 2
  fi
  DRY_RUN=1 DEV_PUSH_BUDGET=120 \
    "${DEV_PUSH}" --from-deb "${MOCK_DEB_DIR}" --dry-run 192.0.2.1 ceracoder 2>&1 | tee "${log}"
  rc="${PIPESTATUS[0]}"
  return "${rc}"
}

sec_rauc_rollback() {
  header "4/4  RAUC A/B ROLLBACK   (rauc-rollback.sh)"
  local log="${EVIDENCE_DIR}/04-rauc-rollback.log" rc
  if [[ "${MODE}" == "live" ]]; then
    if [[ -z "${BUNDLE_DIR}" || ! -s "${BUNDLE_DIR}/bad.raucb" || ! -s "${BUNDLE_DIR}/good.raucb" ]]; then
      echo "FAIL — LIVE rollback requires BUNDLE_DIR with signed bad.raucb + good.raucb." | tee "${log}"
      return 1
    fi
    BOARD_IP="${BOARD_IP}" SSH_USER="${SSH_USER}" SSH_PORT="${SSH_PORT}" BUNDLE_DIR="${BUNDLE_DIR}" \
      "${ROLLBACK_SH}" 2>&1 | tee "${log}"; rc="${PIPESTATUS[0]}"
  else
    BOARD_IP="" CERALIVE_ROLLBACK_MODE=mock BUNDLE_DIR="${BUNDLE_DIR}" \
      "${ROLLBACK_SH}" 2>&1 | tee "${log}"; rc="${PIPESTATUS[0]}"
  fi
  return "${rc}"
}

# ===========================================================================
# SUMMARY + EVIDENCE BUNDLE
# ===========================================================================
summarize() {
  local i n="${#SEC_NAME[@]}" total=$(( PASS + FAIL + SKIP )) exit_code=0
  (( FAIL > 0 )) && exit_code=1
  {
    printf '\n==============================================================\n'
    printf ' CeraLive Stage 6 — consolidated real-HW RK3588 smoke suite\n'
    printf ' mode=%s  board=%s\n' "${MODE}" "${BOARD}"
    printf '==============================================================\n'
    for (( i = 0; i < n; i++ )); do
      printf '  [ %-4s ]  %s\n' "${SEC_RESULT[$i]}" "${SEC_NAME[$i]}"
    done
    printf '  ----------------------------------------------------------\n'
    printf '  RESULT: %d PASS / %d FAIL / %d SKIP  (of %d sections)\n' \
      "${PASS}" "${FAIL}" "${SKIP}" "${total}"
    printf '  EXIT  : %d  (%s)\n' "${exit_code}" "$( ((exit_code==0)) && echo 'all gates satisfied' || echo 'one or more gates FAILED' )"
    printf '==============================================================\n'
  } | tee "${EVIDENCE_DIR}/suite-summary.txt"

  printf '{"mode":"%s","board":"%s","pass":%d,"fail":%d,"skip":%d,"exit":%d}\n' \
    "${MODE}" "${BOARD}" "${PASS}" "${FAIL}" "${SKIP}" "${exit_code}" \
    > "${EVIDENCE_DIR}/result.json"

  if [[ "${MODE}" == "mock" ]]; then
    log_warn "MOCK run — NOT the RK3588 acceptance proof. LIVE requires the self-hosted"
    log_warn "ceralive-rk3588 runner (task 37) with BOARD_IP + BUNDLE_DIR + a flashed image."
  fi
  return "${exit_code}"
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
  mkdir -p "${EVIDENCE_DIR}"
  log_info "=== Stage 6 real-HW suite | mode=${MODE} | board=${BOARD} | evidence=${EVIDENCE_DIR} ==="
  [[ -x "${SMOKE_SH}"    ]] || die "missing/!x sub-harness: ${SMOKE_SH}"
  [[ -x "${ROLLBACK_SH}" ]] || die "missing/!x sub-harness: ${ROLLBACK_SH}"
  [[ -x "${DEV_PUSH}"    ]] || die "missing/!x dev-loop tool: ${DEV_PUSH}"

  if [[ "${MODE}" == "live" ]]; then
    require_cmd ssh
    [[ -n "${BOARD_IP}" ]] || die "LIVE mode needs BOARD_IP (the ceralive-rk3588 runner sets it)"
    log_info "LIVE: real RK3588 ${SSH_USER}@${BOARD_IP}:${SSH_PORT}"
  else
    log_warn "MOCK mode: proving the suite + each sub-harness OFFLINE path (no board)."
    build_mock_fixtures
  fi

  local rc
  sec_boot_service;  rc=$?; record "boot + service (realhw-smoke.sh)"                      "${rc}"
  sec_encode_init;   rc=$?; record "encode-path init (ceracoder/srtla_send --version)"     "${rc}"
  sec_dev_loop;      rc=$?; record "dev-loop sanity (dev-push < 120s)"                      "${rc}"
  sec_rauc_rollback; rc=$?; record "rauc A/B rollback (rauc-rollback.sh)"                   "${rc}"

  summarize
}

main "$@"
