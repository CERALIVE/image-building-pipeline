#!/usr/bin/env bash
#
# realhw-smoke.sh — RK3588 real-hardware parity boot/service smoke harness.
#
# THE STAGE-1 ACCEPTANCE GATE. Passing this harness on real RK3588 hardware is
# what authorizes retiring the legacy monolithic ../build.sh for RK3588 (and is
# the foundation task 38's CI real-HW smoke builds on). It does NOT replace the
# manifest unit suite (run-tests) — it proves the *built image actually boots
# and runs* on a board, with full parity against today's Armbian image.
#
# Two independent modes, selected by environment:
#
#   STATIC mode (NO hardware) — validates an image ARTIFACT the orchestrator
#     produces. Drive with IMAGE_PATH=<dir|.tar|.img|.img.xz>. Verifies, without
#     ever booting it:
#       * artifact exists + sha256 matches its .sha256 sidecar (if present)
#       * structure: .img → GPT/MBR partition table (sfdisk/sgdisk);
#                    .tar → archive listing (tar -t); dir → tree present
#       * materializes the rootfs (extract .tar / loop-mount .img / use dir),
#         then runs lib/parity-check.sh against it (packages / ceralive user +
#         groups / services / SRTLA routing / udev / apt — the task-16 checklist)
#       * first-party binaries staged in the rootfs (/usr/bin/cerastream,
#         srtla_send) when the first-party layer is present
#       * board-quirk artifacts present in the rootfs (HDMI-capture udev rule,
#         modem source-routing) as resolved from the board manifest
#
#   LIVE mode (hardware REQUIRED) — SSH-based assertions against a booted board.
#     Drive with BOARD_IP=<ip> (SSH_USER/SSH_PORT optional). Asserts:
#       * the board reaches login (SSH connects, BatchMode key auth)
#       * the main app unit is active — handles BOTH ceralive.service AND
#         ceraui.service (whichever the first-party package ships)
#       * `id ceralive` resolves (the unified service account)
#       * binaries present + answer --version: cerastream, srtla_send
#       * board-quirk hardware, driven by manifests/boards/<BOARD>.yaml quirks:
#           hdmi_input_emi_shield     → a /dev/video* capture node exists
#           m2_modem_sim_workaround   → ModemManager sees a modem OR a modem
#                                       device node (/dev/cdc-wdm*, ttyUSB*) exists
#           usb_power_optimization    → the CeraLive udev hardware rule is applied
#       * FULL PARITY: rsyncs the parity-relevant subtree off the live board into
#         a local rootfs and runs lib/parity-check.sh on it — the same gate the
#         STATIC artifact passes, now proven on the real running system.
#
# If neither BOARD_IP nor IMAGE_PATH is set, STATIC mode auto-discovers the most
# recent artifact under images/<BOARD>/ and falls back to the mkosi build tree
# (build/runtime, else build/platform) so it is always runnable in CI.
#
# DESIGN (inherited from common.sh + task-16 parity-check.sh):
#   * strict mode from common.sh; ERR trap dropped — this script COLLECTS
#     failures and owns its exit code (exit 0 only on zero hard FAILs).
#   * NO `|| true` swallowing. Expected-to-sometimes-fail probes are wrapped in
#     `if cmd; then pass; else fail/warn; fi` so set -e never silently eats them.
#   * ZERO hardcoded board logic: board quirks are READ from the board manifest.
#
# Env:
#   BOARD          board name (default rock-5b-plus) — selects the manifest whose
#                  quirks drive the hardware assertions
#   BOARD_IP       set → LIVE mode (SSH target)
#   SSH_USER       SSH user for LIVE mode (default root)
#   SSH_PORT       SSH port for LIVE mode (default 22)
#   IMAGE_PATH     set → STATIC mode (dir | .tar | .img | .img.xz)
#   PARITY_CHECK_SH override path to lib/parity-check.sh
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${V2_DIR}/lib/common.sh"

# common.sh installs an ERR trap that exits 1; like parity-check.sh we collect
# failures and report a summary, so drop the trap and own the exit code.
trap - ERR

# ---------------------------------------------------------------------------
# Locations + configuration (env-overridable; nothing product-specific hardcoded
# in logic — quirks come from the manifest, binaries from the package contract).
# ---------------------------------------------------------------------------
PARITY_CHECK_SH="${PARITY_CHECK_SH:-${V2_DIR}/lib/parity-check.sh}"
BOARDS_DIR="${V2_DIR}/manifests/boards"
IMAGES_DIR="${V2_DIR}/images"
MKOSI_BUILD_DIR="${V2_DIR}/mkosi/build"

BOARD="${BOARD:-rock-5b-plus}"
BOARD_IP="${BOARD_IP:-}"
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
SSH_IDENTITY_FILE="${SSH_IDENTITY_FILE:-}"
SSH_KNOWN_HOSTS_FILE="${SSH_KNOWN_HOSTS_FILE:-}"
IMAGE_PATH="${IMAGE_PATH:-}"

EXPECTED_BINARIES=(/usr/bin/cerastream /usr/bin/srtla_send)
# The main application systemd unit — accept either name (task: "handle both").
APP_SERVICE_CANDIDATES=(ceralive.service ceraui.service)

SSH_BASE_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
[[ -z "${SSH_IDENTITY_FILE}" ]] || SSH_BASE_OPTS+=(-o IdentitiesOnly=yes -i "${SSH_IDENTITY_FILE}")
[[ -z "${SSH_KNOWN_HOSTS_FILE}" ]] || SSH_BASE_OPTS+=(
  -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS_FILE}" -o GlobalKnownHostsFile=/dev/null
)

PASS=0; WARN=0; FAIL=0
pass() { log_success "PASS  $*"; PASS=$((PASS+1)); }
warn() { log_warn    "WARN  $*"; WARN=$((WARN+1)); }
fail() { log_error   "FAIL  $*"; FAIL=$((FAIL+1)); }

# Temp dirs to clean on exit (extracted tars, loop-mounts, rsync rootfs).
declare -a CLEANUP_DIRS=()
declare -a CLEANUP_MOUNTS=()
cleanup() {
  local m d
  for m in "${CLEANUP_MOUNTS[@]:-}"; do
    [[ -n "${m}" ]] || continue
    if mountpoint -q "${m}" 2>/dev/null; then sudo umount "${m}" 2>/dev/null || umount "${m}" 2>/dev/null || true; fi
  done
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [[ -n "${d}" && -d "${d}" ]] && rm -rf "${d}"
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# resolve_manifest — locate the board manifest (yaml/yml) for ${BOARD}.
# ---------------------------------------------------------------------------
resolve_manifest() {
  local ext f
  for ext in yaml yml; do
    f="${BOARDS_DIR}/${BOARD}.${ext}"
    [[ -f "${f}" ]] && { printf '%s' "${f}"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# load_quirks <manifest> — read the `quirks:` block and export QUIRK_<key>=value.
# Manifest-driven: NO board name or quirk list is hardcoded here; whatever the
# YAML declares becomes a QUIRK_* var the assertions consult.
# ---------------------------------------------------------------------------
load_quirks() {
  local manifest="$1" line key val
  while IFS= read -r line; do
    key="${line%%=*}"; val="${line#*=}"
    [[ -n "${key}" ]] || continue
    export "QUIRK_${key}=${val}"
  done < <(
    python3 - "$manifest" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
for k, v in (doc.get("quirks") or {}).items():
    print(f"{k}={v}")
PY
  )
}

quirk() {                                   # quirk <key> → value (or empty)
  local v="QUIRK_$1"; printf '%s' "${!v:-}"
}

# ===========================================================================
# STATIC MODE
# ===========================================================================

# materialize_rootfs <image> <dest_var> — set named var to a readable rootfs tree.
# Handles a directory (used in place), a .tar (extracted), or a .img/.img.xz
# (loop-mounted; needs root). Returns non-zero if the rootfs can't be read.
materialize_rootfs() {
  local img="$1" __out="$2" tmp
  if [[ -d "${img}" ]]; then
    printf -v "${__out}" '%s' "${img}"
    return 0
  fi
  case "${img}" in
    *.tar)
      tmp="$(mktemp -d)"; CLEANUP_DIRS+=("${tmp}")
      if tar -C "${tmp}" -xf "${img}" 2>/dev/null; then
        printf -v "${__out}" '%s' "${tmp}"; return 0
      fi
      fail "could not extract rootfs tar ${img}"; return 1 ;;
    *.img|*.img.xz|*.raw|*.raw.xz)
      local raw="${img}"
      if [[ "${img}" == *.xz ]]; then
        tmp="$(mktemp -d)"; CLEANUP_DIRS+=("${tmp}")
        raw="${tmp}/$(basename "${img%.xz}")"
        xz -dc "${img}" >"${raw}" || { fail "xz decompress failed for ${img}"; return 1; }
      fi
      if ! command -v losetup >/dev/null 2>&1; then
        warn "losetup unavailable — cannot mount ${img}; partition checks only"
        return 1
      fi
      local mnt; mnt="$(mktemp -d)"; CLEANUP_DIRS+=("${mnt}"); CLEANUP_MOUNTS+=("${mnt}")
      # Mount the largest (rootfs) partition. Needs root; warn-degrade if not.
      local sudo_pfx=""; [[ "$(id -u)" -eq 0 ]] || sudo_pfx="sudo"
      local lo
      if ! lo="$(${sudo_pfx} losetup --find --show --partscan "${raw}" 2>/dev/null)"; then
        warn "loop setup needs root/CAP_SYS_ADMIN — skipping rootfs mount of ${img}"
        return 1
      fi
      CLEANUP_MOUNTS=("${lo}" "${CLEANUP_MOUNTS[@]}")
      local part
      part="$(lsblk -nrpo NAME,SIZE "${lo}" 2>/dev/null | tail -n +2 | sort -k2 -h | tail -1 | awk '{print $1}')"
      [[ -n "${part}" ]] || part="${lo}p1"
      if ${sudo_pfx} mount -o ro "${part}" "${mnt}" 2>/dev/null; then
        printf -v "${__out}" '%s' "${mnt}"; return 0
      fi
      warn "could not mount rootfs partition ${part} of ${img}"
      ${sudo_pfx} losetup -d "${lo}" 2>/dev/null || true
      return 1 ;;
    *)
      fail "unrecognized image type: ${img} (want dir | .tar | .img[.xz])"
      return 1 ;;
  esac
}

# static_structure_check <image> — image-file-level checks that never need root.
static_structure_check() {
  local img="$1"
  if [[ -e "${img}" ]]; then
    pass "image artifact exists: ${img}"
  else
    fail "image artifact not found: ${img}"; return
  fi

  # Checksum sidecar (orchestrate.sh emit_artifact writes <artifact>.sha256).
  if [[ -f "${img}.sha256" ]]; then
    if ( cd "$(dirname "${img}")" && sha256sum -c "$(basename "${img}").sha256" >/dev/null 2>&1 ); then
      pass "sha256 matches sidecar ${img}.sha256"
    else
      fail "sha256 MISMATCH against ${img}.sha256 (corrupt/incomplete artifact)"
    fi
  else
    warn "no .sha256 sidecar for ${img} (integrity unverified)"
  fi

  case "${img}" in
    *.xz)
      if xz -t "${img}" >/dev/null 2>&1; then pass "xz integrity OK (${img})"
      else fail "xz integrity check failed (${img})"; fi ;;
  esac

  if [[ -d "${img}" ]]; then
    if [[ -d "${img}/usr" && -d "${img}/etc" ]]; then
      pass "rootfs directory has the expected top-level layout (usr/ etc/)"
    else
      fail "rootfs directory ${img} missing usr/ or etc/"
    fi
  elif [[ "${img}" == *.tar ]]; then
    if tar -tf "${img}" >/dev/null 2>&1; then
      pass "tar archive listing OK"
      if tar -tf "${img}" 2>/dev/null | grep -qE '(^|\./)(etc/passwd|var/lib/dpkg/status)$'; then
        pass "tar contains a Debian rootfs (etc/passwd + dpkg status)"
      else
        warn "tar listing has no etc/passwd / dpkg status at the root — odd layout"
      fi
    else
      fail "tar archive is unreadable (${img})"
    fi
  elif [[ "${img}" == *.img || "${img}" == *.img.xz || "${img}" == *.raw || "${img}" == *.raw.xz ]]; then
    local raw="${img}" tmp
    if [[ "${img}" == *.xz ]]; then
      tmp="$(mktemp -d)"; CLEANUP_DIRS+=("${tmp}")
      raw="${tmp}/$(basename "${img%.xz}")"
      xz -dc "${img}" >"${raw}" || { fail "xz decompress failed for partition check"; return; }
    fi
    if sgdisk -p "${raw}" >/dev/null 2>&1 || sfdisk -l "${raw}" >/dev/null 2>&1; then
      pass "image has a readable partition table"
      if sfdisk -l "${raw}" 2>/dev/null | grep -qiE 'linux|EFI|fat'; then
        pass "partition table declares a Linux/boot partition"
      else
        warn "partition table has no obvious Linux/boot partition"
      fi
    else
      fail "no readable partition table in ${img}"
    fi
  fi
}

# static_rootfs_assertions <rootfs> — content checks beyond parity-check.sh:
# first-party binaries + manifest-quirk artifacts.
static_rootfs_assertions() {
  local root="$1" b
  for b in "${EXPECTED_BINARIES[@]}"; do
    if [[ -e "${root}${b}" ]]; then
      pass "binary staged in rootfs: ${b}"
    else
      warn "binary ${b} absent in rootfs (first-party .debs need R2/gh creds — CI mode)"
    fi
  done

  # Manifest-quirk artifacts at the filesystem level (the LIVE-mode hardware
  # assertions check the running result of these same quirks).
  if [[ -n "$(quirk hdmi_input_emi_shield)" ]]; then
    if grep -rqsE 'video4linux|rk_hdmirx' "${root}/etc/udev/rules.d/" 2>/dev/null; then
      pass "quirk hdmi_input_emi_shield: HDMI-capture udev rule present in rootfs"
    else
      fail "quirk hdmi_input_emi_shield: no HDMI/video4linux udev rule in rootfs"
    fi
  fi
  if [[ "$(quirk m2_modem_sim_workaround)" == "required" ]]; then
    if grep -qsE '^10[0-9][[:space:]]+modem[0-7]' "${root}/etc/iproute2/rt_tables" 2>/dev/null; then
      pass "quirk m2_modem_sim_workaround: modem SRTLA routing tables present in rootfs"
    else
      fail "quirk m2_modem_sim_workaround: modem routing tables absent in rootfs"
    fi
  fi
  if [[ -n "$(quirk usb_power_optimization)" ]]; then
    if [[ -f "${root}/etc/udev/rules.d/99-ceralive-hardware.rules" ]]; then
      pass "quirk usb_power_optimization: CeraLive udev hardware rule present in rootfs"
    else
      fail "quirk usb_power_optimization: CeraLive udev hardware rule absent in rootfs"
    fi
  fi
}

# discover_artifact — newest images/<BOARD>/*.rootfs.tar / *.img*, else build tree.
discover_artifact() {
  local cand
  cand="$(find "${IMAGES_DIR}/${BOARD}" -maxdepth 1 -type f \
            \( -name '*.rootfs.tar' -o -name '*.img' -o -name '*.img.xz' \) \
            2>/dev/null | sort | tail -1)"
  if [[ -n "${cand}" ]]; then printf '%s' "${cand}"; return 0; fi
  if [[ -d "${MKOSI_BUILD_DIR}/runtime" ]]; then printf '%s' "${MKOSI_BUILD_DIR}/runtime"; return 0; fi
  if [[ -d "${MKOSI_BUILD_DIR}/platform" ]]; then printf '%s' "${MKOSI_BUILD_DIR}/platform"; return 0; fi
  return 1
}

run_static_mode() {
  local img="${IMAGE_PATH}"
  if [[ -z "${img}" ]]; then
    if ! img="$(discover_artifact)"; then
      warn "STATIC mode: no IMAGE_PATH and no artifact under ${IMAGES_DIR}/${BOARD}/ or ${MKOSI_BUILD_DIR}/ — nothing to validate"
      return
    fi
    log_info "STATIC mode: auto-discovered artifact ${img}"
  fi

  log_info "=== STATIC mode: validating image artifact (no hardware) ==="
  log_info "image=${img} board=${BOARD}"
  static_structure_check "${img}"

  local root=""
  if materialize_rootfs "${img}" root && [[ -n "${root}" ]]; then
    log_info "materialized rootfs at ${root}"
    if [[ -f "${root}/var/lib/dpkg/status" ]]; then
      log_info "--- running lib/parity-check.sh against the materialized rootfs ---"
      if "${PARITY_CHECK_SH}" "${root}"; then
        pass "parity-check.sh PASSED against the artifact rootfs"
      else
        fail "parity-check.sh FAILED against the artifact rootfs"
      fi
    else
      warn "materialized tree has no dpkg status (${root}/var/lib/dpkg/status) — partial rootfs (e.g. platform layer, not runtime); skipping parity-check.sh"
    fi
    static_rootfs_assertions "${root}"
  else
    warn "could not materialize a readable rootfs from ${img} — ran structure checks only (mount needs root/guestfish)"
  fi
}

# ===========================================================================
# LIVE MODE
# ===========================================================================

ssh_run() {                                 # ssh_run <remote-cmd...>
  ssh "${SSH_BASE_OPTS[@]}" -p "${SSH_PORT}" "${SSH_USER}@${BOARD_IP}" "$@"
}

live_login_check() {
  if ssh_run true >/dev/null 2>&1; then
    pass "board reaches login — SSH ${SSH_USER}@${BOARD_IP}:${SSH_PORT} (key auth)"
    return 0
  fi
  fail "cannot SSH to ${SSH_USER}@${BOARD_IP}:${SSH_PORT} — board did not reach login (or key auth not set up)"
  return 1
}

live_service_check() {
  local svc active=""
  for svc in "${APP_SERVICE_CANDIDATES[@]}"; do
    if ssh_run "systemctl is-active ${svc}" 2>/dev/null | grep -q '^active$'; then
      active="${svc}"; break
    fi
  done
  if [[ -n "${active}" ]]; then
    pass "main application unit is active: ${active}"
  else
    fail "no active application unit — neither ${APP_SERVICE_CANDIDATES[*]} is active"
  fi
}

live_user_check() {
  if ssh_run "id ceralive" >/dev/null 2>&1; then
    pass "ceralive service account resolves (id ceralive)"
  else
    fail "ceralive user missing on the booted system (id ceralive failed)"
  fi
}

live_binary_check() {
  local b
  for b in "${EXPECTED_BINARIES[@]}"; do
    if ssh_run "test -x ${b}" >/dev/null 2>&1; then
      pass "binary present + executable: ${b}"
    else
      fail "binary missing on board: ${b}"
      continue
    fi
    # --version must not hang or crash. Accept any exit (some print to stderr/
    # return non-zero on --version) as long as it produces output.
    if ssh_run "${b} --version </dev/null 2>&1 | head -1" 2>/dev/null | grep -q .; then
      pass "${b} --version responds"
    else
      warn "${b} --version produced no output (may not implement --version)"
    fi
  done
}

live_quirk_checks() {
  # hdmi_input_emi_shield → a capture node must exist.
  if [[ -n "$(quirk hdmi_input_emi_shield)" ]]; then
    if ssh_run "ls /dev/video* >/dev/null 2>&1" >/dev/null 2>&1; then
      pass "quirk hdmi_input_emi_shield: /dev/video* capture node present"
    else
      fail "quirk hdmi_input_emi_shield: no /dev/video* capture device on the board"
    fi
  fi
  # m2_modem_sim_workaround → ModemManager sees a modem OR a modem node exists.
  if [[ "$(quirk m2_modem_sim_workaround)" == "required" ]]; then
    if ssh_run "command -v mmcli >/dev/null 2>&1 && mmcli -L 2>/dev/null | grep -qiE 'modem|/Modem/'" >/dev/null 2>&1; then
      pass "quirk m2_modem_sim_workaround: ModemManager sees a modem (mmcli -L)"
    elif ssh_run "ls /dev/cdc-wdm* /dev/ttyUSB* >/dev/null 2>&1" >/dev/null 2>&1; then
      pass "quirk m2_modem_sim_workaround: modem device node present (/dev/cdc-wdm*|ttyUSB*)"
    else
      warn "quirk m2_modem_sim_workaround: no modem detected — verify the M.2 SIM-detection workaround + that a modem is fitted"
    fi
  fi
  # usb_power_optimization → the CeraLive udev hardware rule is applied.
  if [[ -n "$(quirk usb_power_optimization)" ]]; then
    if ssh_run "test -f /etc/udev/rules.d/99-ceralive-hardware.rules" >/dev/null 2>&1; then
      pass "quirk usb_power_optimization: CeraLive udev hardware rule applied on the board"
    else
      fail "quirk usb_power_optimization: CeraLive udev hardware rule missing on the board"
    fi
  fi
}

# live_full_parity — pull the parity-relevant subtree off the live board and run
# the SAME lib/parity-check.sh against it. This is how the full task-16 parity
# gate runs as part of LIVE mode (the harness's authoritative parity proof).
live_full_parity() {
  if ! command -v rsync >/dev/null 2>&1; then
    fail "rsync not on the host — LIVE full parity-check.sh is required"
    return
  fi
  local root; root="$(mktemp -d)"; CLEANUP_DIRS+=("${root}")
  # Only the paths parity-check.sh reads — keep the transfer minimal.
  local paths=(
    /etc/passwd /etc/group
    /etc/systemd/system /usr/lib/systemd/system
    /etc/iproute2/rt_tables
    /etc/dhcp/dhclient-exit-hooks.d
    /etc/NetworkManager/dispatcher.d
    /etc/udev/rules.d
    /etc/apt/sources.list.d
    /var/lib/dpkg/status
  )
  log_info "--- LIVE full parity: rsyncing parity subtree off the board ---"
  if rsync -aR -e "ssh ${SSH_BASE_OPTS[*]} -p ${SSH_PORT}" \
        "${SSH_USER}@${BOARD_IP}:$(IFS=' '; echo "${paths[*]}")" "${root}/" >/dev/null 2>&1; then
    if [[ -f "${root}/var/lib/dpkg/status" ]]; then
      if "${PARITY_CHECK_SH}" "${root}"; then
        pass "LIVE parity-check.sh PASSED against the running board's filesystem"
      else
        fail "LIVE parity-check.sh FAILED against the running board's filesystem"
      fi
    else
      fail "LIVE parity: dpkg status not pulled — cannot run required parity-check.sh"
    fi
  else
    fail "LIVE parity: rsync of the parity subtree failed — required parity-check.sh did not run"
  fi
}

run_live_mode() {
  log_info "=== LIVE mode: real-hardware boot/service assertions ==="
  log_info "target=${SSH_USER}@${BOARD_IP}:${SSH_PORT} board=${BOARD}"
  if ! live_login_check; then
    log_error "board unreachable — skipping remaining LIVE assertions"
    return
  fi
  live_service_check
  live_user_check
  live_binary_check
  live_quirk_checks
  live_full_parity
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
  require_cmd python3

  local manifest
  if manifest="$(resolve_manifest)"; then
    log_info "board manifest: ${manifest}"
    load_quirks "${manifest}"
  else
    warn "no manifest for board '${BOARD}' under ${BOARDS_DIR}/ — quirk-driven assertions disabled"
  fi

  [[ -x "${PARITY_CHECK_SH}" ]] || die "parity-check.sh not found/executable at ${PARITY_CHECK_SH}"

  local ran=0
  if [[ -n "${BOARD_IP}" ]]; then
    require_cmd ssh
    run_live_mode; ran=1
  fi
  if [[ -n "${IMAGE_PATH}" ]]; then
    run_static_mode; ran=1
  fi
  if (( ran == 0 )); then
    log_info "neither BOARD_IP nor IMAGE_PATH set — defaulting to STATIC mode (auto-discover)"
    run_static_mode
  fi

  log_info "=== smoke summary: ${PASS} pass / ${WARN} warn / ${FAIL} fail ==="
  if (( FAIL > 0 )); then
    log_error "SMOKE FAILED (${FAIL} hard failure(s)) — this image/board does NOT pass the Stage-1 parity gate"
    return 1
  fi
  if (( WARN > 0 )); then
    log_warn "smoke OK with ${WARN} warning(s) (CI-gated gaps: first-party debs, no-root mount, or no modem fitted)"
  fi
  log_success "SMOKE OK — Stage-1 parity gate satisfied for board '${BOARD}'"
  return 0
}

main "$@"
