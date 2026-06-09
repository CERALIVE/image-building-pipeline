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
# mkfs.vfat, POPULATED with the boot artifacts via mtools (mcopy — still no mount),
# and dd'd into its raw offset (repart does not re-format an adopted partition).
#
# The boot-partition populate is FAMILY-GATED (custom-uboot/RK3588 only): it stages
# boot.scr (mkimage-compiled from boot.scr.cmd), cera_board.env, the boot_state.txt
# A/B seed and extlinux/extlinux.conf via `install-boot.sh boot-partition`, then
# mcopies them into the FAT image. mkimage (u-boot-tools) is a HOST prerequisite at
# assembly time; x86 (efi) skips this — it boots from the EFI System Partition.
#
# After the filesystems are laid, the FAMILY-GATED bootloader write fills the
# 16 MB raw gap: for rauc_bootloader_adapter=custom (RK3588) it dd's the board's
# U-Boot blob(s) from the staged BSP .deb into the gap and asserts RKNS at sector
# 64 (delegated to write-bootloader.sh); for efi (x86) it is skipped — x86 boots
# from the EFI System Partition. NO A/B FLIPPING / RAUC slot activation / dm-verity
# here — that is task 26.
#
# Usage:
#   assemble-disk.sh build  --output <img> [--total-mb N] [--single-slot] [--no-format]
#                           [--bootloader-adapter custom|efi] [--board <id>] [--bsp-dir <dir>]
#   assemble-disk.sh verify [--out-dir DIR]
#
#   build   Produce a real-geometry disk image. --total-mb sets the medium size
#           (default 16384 = 16 GiB); data fills the remainder. --single-slot (or
#           SINGLE_SLOT_FALLBACK=true) drops rootfs_b. --no-format lays only the
#           GPT geometry (skips mkfs + boot-partition populate + bootloader) — used
#           by the static verify path.
#           --bootloader-adapter/--board/--bsp-dir (default: RAUC_BOOTLOADER_ADAPTER/
#           BOARD_ID/BSP_DIR env) drive the gap bootloader write; custom writes the
#           RK3588 blob, efi skips it.
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
# RK3588 raw-gap bootloader writer (family-gated; only the custom-uboot path).
WRITE_BOOTLOADER_SH="${WRITE_BOOTLOADER_SH:-${HERE}/write-bootloader.sh}"
# Boot-partition artifact installer (boot.scr/cera_board.env/boot_state.txt/extlinux),
# same family gate. Lives in the platform/boot layer because it renders board
# specifics from the manifest env and needs mkimage (u-boot-tools) at assembly time.
INSTALL_BOOT_SH="${INSTALL_BOOT_SH:-${V2_DIR}/mkosi/platform/boot/install-boot.sh}"

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
# populate_boot_partition <bootp_img> <adapter> <board_id> <single_slot>
# FAMILY GATE for filling the vfat boot partition with the U-Boot A/B selector
# artifacts: boot.scr (compiled by mkimage), cera_board.env, the boot_state.txt A/B
# seed, and extlinux/extlinux.conf. Only the custom-uboot adapter (RK3588) boots via
# boot.scr; x86 (efi) populates its EFI System Partition elsewhere and is skipped.
# install-boot.sh renders every board specific from the manifest-resolved env —
# DTB_NAME/SERIAL_CONSOLE/COMPATIBLE_STRING are EXPLICITLY forwarded from this
# assembler's environment (orchestrate.sh resolves+exports them from the manifest);
# we never rely on transitive process inheritance, so a standalone assemble-disk.sh
# call fails loudly instead of silently rendering a half-board boot partition.
# BOARD_ID + SINGLE_SLOT_FALLBACK are forced to the values THIS assembly used so the
# boot_state seed can never drift from the GPT actually laid. Offline + rootless: the
# tree is mcopy'd straight into the FAT image (never loop-mounted), so a re-run only
# overwrites (idempotent) and there is no mount to leak on error.
# ---------------------------------------------------------------------------
populate_boot_partition() {
  local bootp="$1" adapter="$2" board_id="$3" single_slot="$4"
  if [[ "${adapter}" != "custom" ]]; then
    log_info "bootloader_adapter=${adapter:-<unset>} → SKIP boot-partition populate (only custom-uboot/RK3588 ships boot.scr/cera_board.env/boot_state.txt/extlinux)"
    return 0
  fi
  [[ -n "${board_id}" ]] || die "bootloader_adapter=custom requires --board (or BOARD_ID) to render the boot partition"
  [[ -n "${DTB_NAME:-}" ]]        || die "bootloader_adapter=custom requires DTB_NAME (manifest dtb_name) to render the boot partition"
  [[ -n "${SERIAL_CONSOLE:-}" ]]  || die "bootloader_adapter=custom requires SERIAL_CONSOLE (family serial_console) to render the boot console"
  [[ -n "${COMPATIBLE_STRING:-}" ]] || die "bootloader_adapter=custom requires COMPATIBLE_STRING (orchestrator ceralive-<board-slug>) for the boot partition"
  [[ -x "${INSTALL_BOOT_SH}" ]] || die "boot-partition installer not executable: ${INSTALL_BOOT_SH}"
  require_cmd mcopy    # mtools — fill the FAT offline, no loop mount / no root
  require_cmd mkimage  # u-boot-tools — install-boot.sh compiles boot.scr; the device needs it

  log_info "populating boot partition (boot.scr + cera_board.env + boot_state.txt + extlinux, board=${board_id}, single_slot=${single_slot})"
  local staging; staging="$(mktemp -d)"
  SINGLE_SLOT_FALLBACK="${single_slot}" BOARD_ID="${board_id}" \
    DTB_NAME="${DTB_NAME}" SERIAL_CONSOLE="${SERIAL_CONSOLE}" \
    COMPATIBLE_STRING="${COMPATIBLE_STRING}" \
    bash "${INSTALL_BOOT_SH}" boot-partition "${staging}"
  # -s recurse (extlinux/), -o overwrite without prompt (idempotent), -Q quit on
  # error, -m keep mtimes. Lands the staged tree at the FAT image root.
  mcopy -i "${bootp}" -s -o -Q -m "${staging}"/* ::
  rm -rf "${staging}"
  log_success "boot partition populated"
}

# ---------------------------------------------------------------------------
# write_gap_bootloader <img> <adapter> <board_id> <bsp_dir>
# FAMILY GATE for the RK3588 raw-gap bootloader write. Only the custom-uboot
# adapter (rk3588, decision D3) has an idbloader+U-Boot+ATF gap to fill; x86
# (efi) boots from the EFI System Partition and MUST be skipped. The actual
# board-specific blob layout + offsets live in write-bootloader.sh, never here.
# ---------------------------------------------------------------------------
write_gap_bootloader() {
  local img="$1" adapter="$2" board_id="$3" bsp_dir="$4"
  case "${adapter}" in
    custom)
      [[ -n "${board_id}" ]] || die "bootloader_adapter=custom requires --board (or BOARD_ID) to select the RK3588 blob set"
      [[ -n "${bsp_dir}" ]]  || die "bootloader_adapter=custom requires --bsp-dir (or BSP_DIR) — the staged Armbian U-Boot .deb lives there"
      require_cmd "${WRITE_BOOTLOADER_SH}" 2>/dev/null || [[ -x "${WRITE_BOOTLOADER_SH}" ]] \
        || die "bootloader writer not executable: ${WRITE_BOOTLOADER_SH}"
      log_info "bootloader_adapter=custom → writing RK3588 bootloader into the ${GAP_MB} MiB gap (board=${board_id})"
      "${WRITE_BOOTLOADER_SH}" write --image "${img}" --board "${board_id}" \
        --bsp-dir "${bsp_dir}" --gap-mb "${GAP_MB}"
      ;;
    efi)
      log_info "bootloader_adapter=efi → SKIP RK3588 raw-gap write (x86 boots from the EFI System Partition; no idbloader gap)"
      ;;
    ""|none)
      log_warn "bootloader_adapter unset → SKIP raw-gap bootloader write (set RAUC_BOOTLOADER_ADAPTER/--bootloader-adapter for a bootable image)"
      ;;
    *)
      die "unknown bootloader_adapter '${adapter}' (expected: custom | efi)"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# build_disk <img> <total_mb> <single_slot> <do_format> <adapter> <board_id> <bsp_dir>
# Pre-seed the 16 MB gap, run systemd-repart, format the vfat boot region, then
# (real image only) write the family-gated bootloader into the raw gap.
# ---------------------------------------------------------------------------
build_disk() {
  local img="$1" total_mb="$2" single_slot="$3" do_format="$4"
  local adapter="${5:-}" board_id="${6:-}" bsp_dir="${7:-}"
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
  #    partition), POPULATE it with the boot artifacts, then dd it into the 16 MB
  #    offset. Building + filling the 256 MB vfat image standalone keeps the whole
  #    step offline (mkfs.vfat + mcopy, no loop mount) before the single raw write.
  if [[ "${do_format}" == "true" ]]; then
    require_cmd mkfs.vfat
    log_info "formatting boot region (vfat, label BOOT) at ${GAP_MB} MiB offset"
    local bootp; bootp="$(mktemp)"
    truncate -s "${BOOT_MB}M" "${bootp}"
    mkfs.vfat -n BOOT "${bootp}" >/dev/null
    populate_boot_partition "${bootp}" "${adapter}" "${board_id}" "${single_slot}"
    dd if="${bootp}" of="${img}" bs=1M seek="${GAP_MB}" conv=notrunc status=none
    rm -f "${bootp}"
  fi

  # 4. Write the family-gated bootloader into the 16 MB raw gap (real image only;
  #    the static --no-format verify path lays geometry alone and needs no blob).
  if [[ "${do_format}" == "true" ]]; then
    write_gap_bootloader "${img}" "${adapter}" "${board_id}" "${bsp_dir}"
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
      # Bootloader gap-write inputs default to the orchestrator-forwarded env
      # (resolve.sh → manifest): adapter family-gates the write, board selects the
      # blob set, bsp-dir is where fetch-debs staged the Armbian U-Boot .deb.
      local adapter="${RAUC_BOOTLOADER_ADAPTER:-}" board_id="${BOARD_ID:-}" bsp_dir="${BSP_DIR:-}"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --output)              output="${2:-}"; shift 2 ;;
          --total-mb)            total_mb="${2:-}"; shift 2 ;;
          --single-slot)         single_slot="true"; shift ;;
          --no-format)           do_format="false"; shift ;;
          --bootloader-adapter)  adapter="${2:-}"; shift 2 ;;
          --board)               board_id="${2:-}"; shift 2 ;;
          --bsp-dir)             bsp_dir="${2:-}"; shift 2 ;;
          *) die "unknown build argument: $1" ;;
        esac
      done
      [[ -n "${output}" ]] || die "build: --output <img> is required"
      [[ "${single_slot}" == "true" || "${single_slot}" == "false" ]] \
        || die "SINGLE_SLOT_FALLBACK must be true|false (got '${single_slot}')"
      build_disk "${output}" "${total_mb}" "${single_slot}" "${do_format}" \
        "${adapter}" "${board_id}" "${bsp_dir}"
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
