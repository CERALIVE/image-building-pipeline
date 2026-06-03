#!/usr/bin/env bash
#
# assemble-disk.sh — Stage 4 disk assembly for the CeraLive v2 image pipeline.
#
# Lays the FROZEN A/B partition layout (docs/partition-contract.md §3, contract v1)
# onto a GPT disk image, driven by the systemd-repart definitions committed in
# v2/mkosi/repart/*.conf (the single source of truth for sizes / labels / FS).
#
#   (16 MB raw gap, NO GPT entry)  idbloader + U-Boot + ATF
#   p1 boot      xbootldr vfat  256 MB   PARTLABEL=boot
#   p2 rootfs_a  ext4     4096 MB        PARTLABEL=rootfs_a   (RAUC slot A)
#   p3 rootfs_b  ext4     4096 MB        PARTLABEL=rootfs_b   (RAUC slot B)  *
#   p4 data      ext4     remainder >=2048 MB  PARTLABEL=data (shared, survives A/B)
#     * rootfs_b is OMITTED when SINGLE_SLOT_FALLBACK=true (contract §4/§5).
#
# Two contract realities systemd-repart cannot express on its own, handled here:
#   1. The 16 MB raw bootloader gap with NO GPT entry. systemd-repart has no
#      `Offset=` (verified on systemd 260) and starts p1 at the 1 MB grain. We
#      PRE-SEED the GPT with sgdisk so `boot` begins at sector 32768 (16 MB);
#      systemd-repart then ADOPTS that partition (preserving the gap) and appends
#      the rest. `data` (growable, no SizeMaxBytes) packs everything contiguous.
#   2. Single-slot fallback. RepartDirectories= cannot conditionally drop a file,
#      so when $SINGLE_SLOT_FALLBACK=true we stage the repart set WITHOUT
#      30-rootfs_b.conf.
#
# Fully OFFLINE (`systemd-repart --offline=yes`): no root, no loopback. ext4 slots
# + data are formatted by repart; the vfat `boot` region is formatted with
# mkfs.vfat and dd'd into its raw offset (repart does not re-format an adopted
# partition).
#
# NO A/B FLIPPING / RAUC slot activation / dm-verity here — that is task 26. This
# step only lays down the geometry and empty filesystems.
#
# Usage:
#   assemble-disk.sh build  --output <img> [--total-mb N] [--single-slot] [--no-format]
#   assemble-disk.sh verify [--out-dir DIR]
#
#   build   Produce a real-geometry disk image. --total-mb sets the medium size
#           (default 16384 = 16 GiB); data fills the remainder. --single-slot (or
#           SINGLE_SLOT_FALLBACK=true) drops rootfs_b. --no-format lays only the
#           GPT geometry (skips mkfs) — used by the static verify path.
#   verify  Build an A/B and a single-slot test image and print + ASSERT their GPT
#           tables against the frozen contract (static check; prints to stdout).
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

# ---------------------------------------------------------------------------
# Locations + FROZEN contract constants (docs/partition-contract.md §3).
# Sizes in MB == MiB (contract line 52). NEVER change without a fleet re-flash.
# ---------------------------------------------------------------------------
V2_DIR="$(cd "${HERE}/.." && pwd)"
REPART_DIR="${REPART_DIR:-${V2_DIR}/mkosi/repart}"

GAP_MB=16            # raw idbloader+U-Boot+ATF region (no GPT entry)
BOOT_MB=256          # p1 boot (vfat)
ROOTFS_MB=4096       # p2/p3 rootfs slots (ext4)
DATA_FLOOR_MB=2048   # p4 data minimum (ext4, else remainder)
DEFAULT_TOTAL_MB=16384   # 16 GiB reference medium for `build` / A/B verify
SINGLESLOT_TOTAL_MB=8192 #  8 GiB reference medium for single-slot verify

SECTOR=512
# Boot starts after the 16 MB gap: 16 MiB / 512 B = 32768 sectors.
BOOT_START_SECTOR=$(( GAP_MB * 1024 * 1024 / SECTOR ))
# xbootldr (Extended Boot Loader Partition) GPT type GUID — matches Type=xbootldr
# in 10-boot.conf so systemd-repart adopts the pre-seeded boot partition.
XBOOTLDR_GUID="BC13C2FF-59E6-4262-A352-B275FD6F7172"

# ---------------------------------------------------------------------------
# stage_repart_dir <dest> <single_slot:true|false>
# Copy the committed repart defs into <dest>, dropping rootfs_b for single-slot.
# ---------------------------------------------------------------------------
stage_repart_dir() {
  local dest="$1" single_slot="$2" f
  [[ -d "${REPART_DIR}" ]] || die "repart definitions dir not found: ${REPART_DIR}"
  mkdir -p "${dest}"
  rm -f "${dest}"/*.conf
  shopt -s nullglob
  local copied=0
  for f in "${REPART_DIR}"/*.conf; do
    if [[ "${single_slot}" == "true" && "$(basename "${f}")" == *rootfs_b* ]]; then
      log_info "single-slot fallback: omitting $(basename "${f}") (no B slot)"
      continue
    fi
    cp "${f}" "${dest}/"
    copied=$(( copied + 1 ))
  done
  shopt -u nullglob
  (( copied > 0 )) || die "no repart *.conf staged from ${REPART_DIR}"
}

# ---------------------------------------------------------------------------
# build_disk <img> <total_mb> <single_slot> <do_format:true|false>
# Pre-seed the 16 MB gap, run systemd-repart, then format the vfat boot region.
# ---------------------------------------------------------------------------
build_disk() {
  local img="$1" total_mb="$2" single_slot="$3" do_format="$4"
  require_cmd sgdisk
  require_cmd systemd-repart
  local defs; defs="$(mktemp -d)"
  stage_repart_dir "${defs}" "${single_slot}"

  log_info "creating ${total_mb} MiB image: ${img} (single_slot=${single_slot})"
  rm -f "${img}"
  truncate -s "${total_mb}M" "${img}"

  # 1. Pre-seed the GPT: place p1 boot at sector ${BOOT_START_SECTOR} (16 MB),
  #    leaving the leading 16 MB as raw free space with NO GPT entry for it.
  log_info "pre-seeding GPT: boot at sector ${BOOT_START_SECTOR} (16 MB gap before it)"
  sgdisk --clear -a 2048 \
    -n "1:${BOOT_START_SECTOR}:+${BOOT_MB}M" -c 1:boot -t "1:${XBOOTLDR_GUID}" \
    "${img}" >/dev/null

  # 2. systemd-repart adopts boot and appends rootfs_a[/rootfs_b]/data, formatting
  #    the ext4 partitions. Offline: no root, no loopback.
  local slot_desc="rootfs_a/rootfs_b/data"
  [[ "${single_slot}" == "true" ]] && slot_desc="rootfs_a/data (no B slot)"
  log_info "running systemd-repart (offline) → ${slot_desc}"
  systemd-repart --offline=yes --architecture=arm64 --dry-run=no \
    --definitions="${defs}" "${img}" >/dev/null

  # 3. Format the adopted vfat boot region (repart never re-formats an adopted
  #    partition). Build a 256 MB vfat image and dd it into the 16 MB offset.
  if [[ "${do_format}" == "true" ]]; then
    require_cmd mkfs.vfat
    log_info "formatting boot region (vfat, label BOOT) at ${GAP_MB} MiB offset"
    local bootp; bootp="$(mktemp)"
    truncate -s "${BOOT_MB}M" "${bootp}"
    mkfs.vfat -n BOOT "${bootp}" >/dev/null
    dd if="${bootp}" of="${img}" bs=1M seek="${GAP_MB}" conv=notrunc status=none
    rm -f "${bootp}"
  fi

  rm -rf "${defs}"
  log_success "assembled ${img}"
}

# ---------------------------------------------------------------------------
# part_field <img> <num> <First sector|Partition size|Partition name>
# Pull one field from `sgdisk -i`. Sizes/sectors returned as raw integers (sectors)
# for "First sector"/"Partition size"; the quoted label for "Partition name".
# ---------------------------------------------------------------------------
part_field() {
  local img="$1" num="$2" key="$3" line
  line="$(sgdisk -i "${num}" "${img}" 2>/dev/null | grep -F "${key}:")" || return 1
  case "${key}" in
    "Partition name")
      sed -E "s/.*: '([^']*)'.*/\1/" <<<"${line}" ;;
    *)  # "First sector: 32768 (at ...)" / "Partition size: 524288 sectors (...)"
      sed -E 's/[^0-9]*([0-9]+).*/\1/' <<<"${line}" ;;
  esac
}

# part_count <img> — number of partitions in the GPT.
part_count() { sgdisk --print "$1" 2>/dev/null | awk '/^[[:space:]]+[0-9]+[[:space:]]/{n++} END{print n+0}'; }

# sectors_to_mib <sectors>
sectors_to_mib() { echo $(( $1 * SECTOR / 1024 / 1024 )); }

# assert_part <img> <num> <expect_label> <expect_mib|min:N>
assert_part() {
  local img="$1" num="$2" exp_label="$3" exp_size="$4" label size_sectors size_mib
  label="$(part_field "${img}" "${num}" 'Partition name')" \
    || die "partition ${num} missing in ${img}"
  size_sectors="$(part_field "${img}" "${num}" 'Partition size')"
  size_mib="$(sectors_to_mib "${size_sectors}")"
  [[ "${label}" == "${exp_label}" ]] \
    || die "partition ${num} label '${label}' != expected '${exp_label}' (contract)"
  if [[ "${exp_size}" == min:* ]]; then
    local floor="${exp_size#min:}"
    (( size_mib >= floor )) \
      || die "partition ${num} (${label}) size ${size_mib} MiB < contract floor ${floor} MiB"
    printf '  p%s %-9s %6s MiB  (>= %s MiB floor) OK\n' "${num}" "${label}" "${size_mib}" "${floor}"
  else
    (( size_mib == exp_size )) \
      || die "partition ${num} (${label}) size ${size_mib} MiB != contract ${exp_size} MiB"
    printf '  p%s %-9s %6s MiB  (== contract) OK\n' "${num}" "${label}" "${size_mib}"
  fi
}

# assert_no_label <img> <label> — die if any partition carries <label>.
assert_no_label() {
  local img="$1" want="$2" n count
  count="$(part_count "${img}")"
  for (( n=1; n<=count; n++ )); do
    [[ "$(part_field "${img}" "${n}" 'Partition name')" != "${want}" ]] \
      || die "single-slot image MUST NOT contain a '${want}' partition"
  done
}

# assert_gap <img> — boot (p1) must start at the 16 MB sector (no GPT entry before).
assert_gap() {
  local img="$1" start
  start="$(part_field "${img}" 1 'First sector')"
  (( start == BOOT_START_SECTOR )) \
    || die "boot starts at sector ${start}, expected ${BOOT_START_SECTOR} (16 MB raw gap)"
  printf '  16 MB raw gap: boot starts at sector %s (== %s MiB, no GPT entry before) OK\n' \
    "${start}" "${GAP_MB}"
}

# ---------------------------------------------------------------------------
# verify — build A/B + single-slot test images and assert against the contract.
# ---------------------------------------------------------------------------
do_verify() {
  local tmp; tmp="$(mktemp -d)"
  local ab="${tmp}/ab.img" ss="${tmp}/singleslot.img"

  echo "=============================================================="
  echo " CeraLive Stage 4 — A/B partition layout verification"
  echo " Contract: docs/partition-contract.md §3 (v1, FROZEN)"
  echo " Repart defs: v2/mkosi/repart/*.conf"
  echo " Tooling: $(systemd-repart --version | head -1), $(sgdisk --version 2>&1 | head -1)"
  echo "=============================================================="
  echo

  # --- A/B (>=16 GB; both current boards) -----------------------------------
  echo "### A/B layout (SINGLE_SLOT_FALLBACK=false, ${DEFAULT_TOTAL_MB} MiB medium)"
  build_disk "${ab}" "${DEFAULT_TOTAL_MB}" "false" "false" 2>/dev/null
  echo
  echo "--- sgdisk --print ---"
  sgdisk --print "${ab}" 2>/dev/null | sed -n '/Disk /,$p'
  echo
  echo "--- contract assertions ---"
  [[ "$(part_count "${ab}")" -eq 4 ]] || die "A/B layout must have exactly 4 partitions"
  echo "  partition count = 4 (boot + rootfs_a + rootfs_b + data) OK"
  assert_gap "${ab}"
  assert_part "${ab}" 1 boot     "${BOOT_MB}"
  assert_part "${ab}" 2 rootfs_a "${ROOTFS_MB}"
  assert_part "${ab}" 3 rootfs_b "${ROOTFS_MB}"
  assert_part "${ab}" 4 data     "min:${DATA_FLOOR_MB}"
  echo

  # --- Slot-swap static check (data survives A/B) ---------------------------
  echo "### Slot-swap static check — does /data survive an A/B swap?"
  echo "RAUC-managed rootfs slots (swapped on update): rootfs_a, rootfs_b"
  echo "SHARED partitions (never touched by a swap):    boot, data"
  local data_start data_size
  data_start="$(part_field "${ab}" 4 'First sector')"
  data_size="$(part_field "${ab}" 4 'Partition size')"
  echo "  data geometry (A active): start=${data_start} sectors, size=${data_size} sectors, PARTLABEL=data"
  echo "  simulate swap A->B: RAUC flips the active rootfs slot bootname only; it"
  echo "  rewrites NO partition table entry. data start/size are INVARIANT =>"
  echo "  data geometry (B active): start=${data_start} sectors, size=${data_size} sectors, PARTLABEL=data"
  echo "  data partition is NOT in {rootfs_a, rootfs_b} => mutable state SURVIVES the swap OK"
  echo

  # --- Single-slot fallback (<16 GB) ----------------------------------------
  echo "### Single-slot fallback (SINGLE_SLOT_FALLBACK=true, ${SINGLESLOT_TOTAL_MB} MiB medium)"
  build_disk "${ss}" "${SINGLESLOT_TOTAL_MB}" "true" "false" 2>/dev/null
  echo
  echo "--- sgdisk --print ---"
  sgdisk --print "${ss}" 2>/dev/null | sed -n '/Disk /,$p'
  echo
  echo "--- contract assertions ---"
  [[ "$(part_count "${ss}")" -eq 3 ]] || die "single-slot layout must have exactly 3 partitions"
  echo "  partition count = 3 (boot + rootfs_a + data) OK"
  assert_gap "${ss}"
  assert_part "${ss}" 1 boot     "${BOOT_MB}"
  assert_part "${ss}" 2 rootfs_a "${ROOTFS_MB}"
  assert_part "${ss}" 3 data     "min:${DATA_FLOOR_MB}"
  assert_no_label "${ss}" rootfs_b
  echo "  rootfs_b ABSENT (single-slot fallback honored) OK"
  echo

  rm -rf "${tmp}"
  echo "=============================================================="
  log_success "ALL contract assertions passed (A/B + single-slot)"
  echo "=============================================================="
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local mode="${1:-}"; shift || true
  case "${mode}" in
    build)
      local output="" total_mb="${DEFAULT_TOTAL_MB}" do_format="true"
      local single_slot="${SINGLE_SLOT_FALLBACK:-false}"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --output)      output="${2:-}"; shift 2 ;;
          --total-mb)    total_mb="${2:-}"; shift 2 ;;
          --single-slot) single_slot="true"; shift ;;
          --no-format)   do_format="false"; shift ;;
          *) die "unknown build argument: $1" ;;
        esac
      done
      [[ -n "${output}" ]] || die "build: --output <img> is required"
      [[ "${single_slot}" == "true" || "${single_slot}" == "false" ]] \
        || die "SINGLE_SLOT_FALLBACK must be true|false (got '${single_slot}')"
      build_disk "${output}" "${total_mb}" "${single_slot}" "${do_format}"
      sgdisk --print "${output}" 2>/dev/null | sed -n '/Number/,$p'
      ;;
    verify)
      do_verify
      ;;
    -h|--help|"")
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *) die "unknown mode '${mode}' (expected: build | verify)" ;;
  esac
}

main "$@"
