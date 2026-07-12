#!/usr/bin/env bash
#
# preflash-verify.sh — consolidated PRE-FLASH GREEN gate for a CeraLive v2
# rock-5b-plus (RK3588) device image. This is the offline, hardware-free check
# that AUTHORIZES hardware bring-up: it inspects the produced `.raw` disk image
# and signed `.raucb` RAUC bundle and prints PASS or FAIL for each sub-check,
# exiting non-zero if ANY sub-check fails. A red gate means DO NOT flash.
#
# Eight sub-checks (all must PASS):
#   1. GPT geometry   — A/B: boot + rootfs_a + rootfs_b + data, unique labels.
#   2. Gap magic      — Rockchip idblock "RKNS" (52 4b 4e 53) at sector 64, i.e.
#                       the U-Boot bootloader is present in the 16 MB raw gap.
#   3. Boot partition — boot.scr, cera_board.env, boot_state.txt and
#                       extlinux/extlinux.conf are all present on the FAT boot
#                       partition (offset GAP_MB * 1 MiB).
#   4. Boot state     — boot_state.txt starts with BOOT_ORDER=A B and a positive
#                       attempt budget for both populated factory slots.
#   5. RAUC bundle    — `rauc info` parses the bundle and its Compatible string
#                       is ceralive-<board>. The dev/prod leaf carries
#                       EKU=codeSigning only, so verification MUST pass
#                       `-C keyring:check-purpose=codesign` (see T13 findings).
#   6. Factory A      — rootfs_a contains systemd/init and the shared p1 /boot mount.
#   7. Factory B      — rootfs_b contains systemd/init and the shared p1 /boot mount.
#                       An empty or state-isolated B blocks production flash.
#   8. Target media   — the operator-supplied capacity is at least the exact raw
#                       image size; an undersized eMMC/SD/NVMe is rejected.
#
# Everything is image inspection: no loop mount, no root, no hardware. The
# boot partition is read with mtools (mdir/mtype) at its raw byte offset; the
# GPT with sgdisk; the gap magic with dd + xxd (od fallback when xxd is absent).
#
# Usage:
#   preflash-verify.sh [--image <raw>] [--bundle <raucb>] [--board <id>]
#                      [--keyring <pem>] [--gap-mb N] --target-size-bytes N
#   preflash-verify.sh --self-test [--board <id>] ...   # built-in negative test
#
#   (no mode)   Run all sub-checks against the artifacts and exit non-zero
#               on any FAIL. --image/--bundle default to the newest files under
#               v2/images/<board>/ ; --board defaults to rock-5b-plus.
#   --self-test Prove the gate is NOT vacuous: copy the image, zero the gap
#               bytes, re-run the checks against the copy and assert the gap
#               magic sub-check FAILS. Exits 0 only when the corruption was
#               correctly detected.
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2_DIR="$(cd "${HERE}/.." && pwd)"
IMAGES_DIR="${IMAGES_DIR:-${V2_DIR}/images}"

# ---------------------------------------------------------------------------
# FROZEN contract constants (docs/partition-contract.md §3 + T1/T11 spike).
# ---------------------------------------------------------------------------
SECTOR=512
GAP_MB_DEFAULT=16            # raw idbloader+U-Boot+ATF gap before p1 (16 MiB)
RKNS_SECTOR=64               # Rockchip idblock lands at sector 64 (byte 32768)
RKNS_MAGIC="52 4b 4e 53"     # "RKNS" on media (NOT literal "RK35"; spike Div #3)
# RAUC leaf cert carries EKU=codeSigning only; default smimesign purpose rejects
# it ("unsuitable certificate purpose"). Tell rauc to check the codesign purpose.
RAUC_VERIFY_OPTS=(-C keyring:check-purpose=codesign)
DEFAULT_KEYRING="${V2_DIR}/.dev-keys/dev-root-ca.pem"

# ---------------------------------------------------------------------------
# Reporting — every sub-check prints exactly one PASS/FAIL line and feeds FAILS.
# ---------------------------------------------------------------------------
FAILS=0
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; FAILS=$(( FAILS + 1 )); }
info() { printf '       %s\n' "$*"; }

# ---------------------------------------------------------------------------
# newest_artifact <board> <glob> — newest file matching v2/images/<board>/<glob>.
# ---------------------------------------------------------------------------
newest_artifact() {
  local board="$1" glob="$2"
  # ls -t for mtime ordering; the glob MUST expand (build-timestamp filenames).
  # shellcheck disable=SC2012,SC2086
  ls -1t "${IMAGES_DIR}/${board}/"${glob} 2>/dev/null | head -1
}

check_gpt_geometry() {
  local img="$1"
  require_tool sgdisk || { fail "GPT geometry: A/B (boot + rootfs_a + rootfs_b + data)"; return; }
  local labels count
  # Partition rows in `sgdisk -p` start with whitespace + the partition number;
  # the PARTLABEL is the last column. Collect them in table order.
  labels="$(sgdisk -p "${img}" 2>/dev/null \
    | awk '/^[[:space:]]+[0-9]+[[:space:]]/{print $NF}')"
  count="$(printf '%s\n' "${labels}" | grep -c .)"
  local norm; norm="$(printf '%s\n' "${labels}" | tr '\n' ' ' | sed 's/ *$//')"
  if [[ "${norm}" == "boot rootfs_a rootfs_b data" ]] \
      && [[ "$(printf '%s\n' "${labels}" | sort -u | wc -l)" -eq 4 ]]; then
    pass "GPT geometry: A/B (boot + rootfs_a + rootfs_b + data)"
    info "partitions (${count}): ${norm}"
  else
    fail "GPT geometry: A/B (boot + rootfs_a + rootfs_b + data)"
    info "expected four unique labels 'boot rootfs_a rootfs_b data', got '${norm}' (${count} partitions)"
  fi
}

# ---------------------------------------------------------------------------
# Check 2 — Gap magic: RKNS idblock at sector 64 (U-Boot in the 16 MB gap).
# The reference command is `dd if=<raw> bs=512 skip=64 count=1 | xxd | head -1`;
# xxd is absent on the dev host so od renders byte-identical hex when needed.
# ---------------------------------------------------------------------------
check_gap_magic() {
  local img="$1" line got
  if command -v xxd >/dev/null 2>&1; then
    line="$(dd if="${img}" bs="${SECTOR}" skip="${RKNS_SECTOR}" count=1 status=none 2>/dev/null \
      | xxd | head -1)"
    # xxd column layout: "00000000: 524b 4e53 ...  RKNS...". Pull the first 4 bytes.
    got="$(printf '%s' "${line}" | sed -E 's/^[0-9a-f]+: ([0-9a-f]{2})([0-9a-f]{2}) ([0-9a-f]{2})([0-9a-f]{2}).*/\1 \2 \3 \4/')"
  else
    line="$(dd if="${img}" bs="${SECTOR}" skip="${RKNS_SECTOR}" count=1 status=none 2>/dev/null \
      | od -An -v -tx1 | head -1 | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')"
    got="$(printf '%s' "${line}" | cut -d' ' -f1-4)"
  fi
  if [[ "${got}" == "${RKNS_MAGIC}" ]]; then
    pass "Gap magic: RKNS (52 4b 4e 53) at sector ${RKNS_SECTOR}"
    info "sector ${RKNS_SECTOR} first bytes: ${got}"
  else
    fail "Gap magic: RKNS (52 4b 4e 53) at sector ${RKNS_SECTOR}"
    info "sector ${RKNS_SECTOR} first bytes: '${got}' (expected '${RKNS_MAGIC}') — bootloader not written"
  fi
}

# ---------------------------------------------------------------------------
# Check 3 — Boot partition holds the four U-Boot A/B selector artifacts.
# ---------------------------------------------------------------------------
check_boot_partition() {
  local img="$1" boot_off="$2"
  require_tool mdir || { fail "Boot partition: boot.scr + cera_board.env + boot_state.txt + extlinux/extlinux.conf"; return; }
  local f missing=""
  for f in boot.scr cera_board.env boot_state.txt extlinux/extlinux.conf; do
    mdir -i "${img}@@${boot_off}" "::/${f}" >/dev/null 2>&1 || missing="${missing} ${f}"
  done
  if [[ -z "${missing}" ]]; then
    pass "Boot partition: boot.scr + cera_board.env + boot_state.txt + extlinux/extlinux.conf"
    info "boot partition @ offset ${boot_off} — all 4 artifacts present"
  else
    fail "Boot partition: boot.scr + cera_board.env + boot_state.txt + extlinux/extlinux.conf"
    info "missing from boot partition @ offset ${boot_off}:${missing}"
  fi
}

check_boot_state() {
  local img="$1" boot_off="$2" state
  require_tool mtype || { fail "Boot state: BOOT_ORDER=A B with positive A/B attempts"; return; }
  state="$(mtype -i "${img}@@${boot_off}" ::/boot_state.txt 2>/dev/null)"
  if grep -qx 'BOOT_ORDER=A B' <<<"${state}" \
      && grep -qE '^BOOT_A_LEFT=[1-9][0-9]*$' <<<"${state}" \
      && grep -qE '^BOOT_B_LEFT=[1-9][0-9]*$' <<<"${state}"; then
    pass "Boot state: BOOT_ORDER=A B with positive A/B attempts"
    info "$(grep -E '^BOOT_ORDER=|^BOOT_[AB]_LEFT=' <<<"${state}" | tr '\n' ' ')"
  else
    fail "Boot state: BOOT_ORDER=A B with positive A/B attempts"
    info "boot_state.txt: $(grep -E '^BOOT_ORDER=|^BOOT_[AB]_LEFT=' <<<"${state}" | tr '\n' ' ' || true)"
  fi
}

# ---------------------------------------------------------------------------
# Check 5 — RAUC bundle parses and is Compatible with this board.
# ---------------------------------------------------------------------------
check_rauc_bundle() {
  local bundle="$1" board="$2" keyring="$3" out compatible expect
  expect="ceralive-${board}"
  require_tool rauc || { fail "RAUC bundle: parses + Compatible '${expect}'"; return; }
  [[ -s "${keyring}" ]] || { fail "RAUC bundle: parses + Compatible '${expect}'"; info "keyring not found: ${keyring}"; return; }
  if ! out="$(rauc info "${RAUC_VERIFY_OPTS[@]}" --keyring="${keyring}" "${bundle}" 2>&1)"; then
    fail "RAUC bundle: parses + Compatible '${expect}'"
    info "rauc info failed: $(printf '%s' "${out}" | grep -iE 'error|failed' | head -1)"
    return
  fi
  compatible="$(printf '%s\n' "${out}" | sed -n "s/^Compatible:[[:space:]]*'\\(.*\\)'.*/\\1/p" | head -1)"
  if [[ "${compatible}" == "${expect}" ]]; then
    pass "RAUC bundle: parses + Compatible '${expect}'"
    info "Compatible: '${compatible}'; signature verified (check-purpose=codesign)"
  else
    fail "RAUC bundle: parses + Compatible '${expect}'"
    info "Compatible: '${compatible}' (expected '${expect}')"
  fi
}

# debugfs has no byte-offset flag and cannot seek a pipe, so each rootfs slot
# is sliced into a sparse temp file at its raw offset and inspected offline — no
# loop mount, no root. The slot is GREEN
# when the systemd init binary OR /sbin/init exists inside it.
# ---------------------------------------------------------------------------
check_rootfs_populated() {
  local img="$1" part="$2" label="$3" start_sector size_sectors tmp
  local fstab boot_mount='PARTLABEL=boot /boot vfat rw,nodev,nosuid,noexec,umask=0077,shortname=mixed,errors=remount-ro 0 2'
  require_tool sgdisk  || { fail "${label} populated + shared /boot mount present"; return; }
  require_tool debugfs || { fail "${label} populated + shared /boot mount present"; return; }
  start_sector="$(sgdisk -i "${part}" "${img}" 2>/dev/null | sed -n 's/.*First sector: \([0-9]\+\).*/\1/p')"
  size_sectors="$(sgdisk -i "${part}" "${img}" 2>/dev/null | sed -n 's/.*Partition size: \([0-9]\+\).*/\1/p')"
  if [[ -z "${start_sector}" || -z "${size_sectors}" ]]; then
    fail "${label} populated + shared /boot mount present"
    info "could not read ${label} (partition ${part}) geometry from ${img}"
    return
  fi
  tmp="$(mktemp)"
  # conv=sparse keeps the slice ~rootfs-sized on disk despite the 4 GiB logical size.
  dd if="${img}" of="${tmp}" bs="${SECTOR}" skip="${start_sector}" count="${size_sectors}" \
    conv=sparse status=none 2>/dev/null
  local found=""
  local p
  for p in /usr/lib/systemd/systemd /sbin/init; do
    if debugfs -R "stat ${p}" "${tmp}" 2>/dev/null | grep -q 'Inode:'; then
      found="${p}"; break
    fi
  done
  fstab="$(debugfs -R 'cat /etc/fstab' "${tmp}" 2>/dev/null || true)"
  rm -f "${tmp}"
  if [[ -n "${found}" ]] && grep -Fxq "${boot_mount}" <<<"${fstab}"; then
    pass "${label} populated + shared /boot mount present"
    info "${label} (p${part} @ sector ${start_sector}): found ${found} and explicit shared p1 mount"
  else
    fail "${label} populated + shared /boot mount present"
    [[ -n "${found}" ]] || info "${label} (p${part} @ sector ${start_sector}) has no init"
    grep -Fxq "${boot_mount}" <<<"${fstab}" \
      || info "${label} lacks the explicit writable PARTLABEL=boot /boot mount"
  fi
}

check_target_capacity() {
  local img="$1" target_bytes="$2" image_bytes
  image_bytes="$(stat -c '%s' "${img}")"
  if (( target_bytes >= image_bytes )); then
    pass "Target media capacity: ${target_bytes} bytes >= image ${image_bytes} bytes"
  else
    fail "Target media capacity: ${target_bytes} bytes < image ${image_bytes} bytes"
  fi
}

# require_tool <name> — return non-zero (and report) if a needed tool is absent.
require_tool() {
  command -v "$1" >/dev/null 2>&1 && return 0
  info "required tool not found on PATH: $1"
  return 1
}

run_gate() {
  local raw="$1" bundle="$2" board="$3" keyring="$4" gap_mb="$5" target_bytes="$6"
  local boot_off=$(( gap_mb * 1024 * 1024 ))
  FAILS=0

  echo "=============================================================="
  echo " CeraLive pre-flash verification gate — board ${board}"
  echo " image:   ${raw}"
  echo " bundle:  ${bundle}"
  echo " keyring: ${keyring}"
  echo "=============================================================="

  [[ -f "${raw}" ]]    || { fail "image present: ${raw}"; }
  [[ -f "${bundle}" ]] || { fail "bundle present: ${bundle}"; }
  if [[ -f "${raw}" ]]; then
    check_gpt_geometry "${raw}"
    check_gap_magic    "${raw}"
    check_boot_partition "${raw}" "${boot_off}"
    check_boot_state     "${raw}" "${boot_off}"
    check_rootfs_populated "${raw}" 2 rootfs_a
    check_rootfs_populated "${raw}" 3 rootfs_b
    check_target_capacity "${raw}" "${target_bytes}"
  fi
  [[ -f "${bundle}" ]] && check_rauc_bundle "${bundle}" "${board}" "${keyring}"

  echo "--------------------------------------------------------------"
  if (( FAILS == 0 )); then
    echo "RESULT: PASS — pre-flash gate GREEN. Hardware bring-up AUTHORIZED."
  else
    echo "RESULT: FAIL — ${FAILS} sub-check(s) failed. DO NOT FLASH."
  fi
  echo "=============================================================="
  return "${FAILS}"
}

# ---------------------------------------------------------------------------
# self_test — negative / non-vacuity proof. Copy the image (sparse, cheap),
# zero the 16 MB gap, run the gate on the copy and assert the gap-magic
# sub-check FAILS. Exits 0 only when the corruption is correctly detected.
# ---------------------------------------------------------------------------
self_test() {
  local raw="$1" bundle="$2" board="$3" keyring="$4" gap_mb="$5" target_bytes="$6"
  [[ -f "${raw}" ]] || { echo "self-test: image not found: ${raw}" >&2; return 2; }
  local tmp corrupt
  tmp="$(mktemp -d)"
  corrupt="${tmp}/$(basename "${raw}").zeroed-gap"
  echo "### NEGATIVE TEST — zeroing the bootloader gap to prove the gate is not vacuous"
  echo "    source image : ${raw}"
  echo "    corrupt copy : ${corrupt}"
  cp --sparse=always "${raw}" "${corrupt}"
  # Wipe the RKNS idblock at sector 64 only — sectors 64..127 are inside the 16 MB
  # gap, so the GPT (sectors 0..33) and boot partition (sector 32768+) stay intact
  # and exactly ONE sub-check (gap magic) flips to FAIL.
  dd if=/dev/zero of="${corrupt}" bs="${SECTOR}" count=64 seek="${RKNS_SECTOR}" conv=notrunc status=none
  echo
  echo "--- gate output against the zeroed-gap image (expecting a gap-magic FAIL) ---"
  local out rc
  out="$(run_gate "${corrupt}" "${bundle}" "${board}" "${keyring}" "${gap_mb}" "${target_bytes}")"; rc=$?
  printf '%s\n' "${out}"
  rm -rf "${tmp}"
  echo
  if printf '%s\n' "${out}" | grep -q '^\[FAIL\] Gap magic:' && (( rc != 0 )); then
    echo "NEGATIVE TEST PASS — zeroed gap was correctly REJECTED on the gap-magic check (gate is non-vacuous)."
    return 0
  fi
  echo "NEGATIVE TEST FAIL — zeroed gap was NOT rejected (gate would let a bootloader-less image through!)." >&2
  return 1
}

usage() { sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local image="" bundle="" board="rock-5b-plus" keyring="" gap_mb="${GAP_MB_DEFAULT}" target_size_bytes=""
  local mode="gate"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)     image="${2:-}"; shift 2 ;;
      --bundle)    bundle="${2:-}"; shift 2 ;;
      --board)     board="${2:-}"; shift 2 ;;
      --keyring)   keyring="${2:-}"; shift 2 ;;
      --gap-mb)    gap_mb="${2:-}"; shift 2 ;;
      --target-size-bytes) target_size_bytes="${2:-}"; shift 2 ;;
      --self-test) mode="self-test"; shift ;;
      -h|--help)   usage; exit 0 ;;
      *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

  [[ -n "${keyring}" ]] || keyring="${DEFAULT_KEYRING}"
  [[ -n "${image}" ]]   || image="$(newest_artifact "${board}" '*.raw')"
  [[ -n "${bundle}" ]]  || bundle="$(newest_artifact "${board}" '*.raucb')"
  [[ "${target_size_bytes}" =~ ^[1-9][0-9]*$ ]] \
    || { echo "--target-size-bytes is required and must be a positive integer" >&2; exit 2; }
  [[ -n "${image}" ]]   || { echo "no .raw found under ${IMAGES_DIR}/${board}/ — pass --image" >&2; exit 2; }
  [[ -n "${bundle}" ]]  || { echo "no .raucb found under ${IMAGES_DIR}/${board}/ — pass --bundle" >&2; exit 2; }

  case "${mode}" in
    gate)      run_gate  "${image}" "${bundle}" "${board}" "${keyring}" "${gap_mb}" "${target_size_bytes}" ;;
    self-test) self_test "${image}" "${bundle}" "${board}" "${keyring}" "${gap_mb}" "${target_size_bytes}" ;;
  esac
}

main "$@"
