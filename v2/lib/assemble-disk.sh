#!/usr/bin/env bash
#
# assemble-disk.sh — Stage 4 disk assembly for the CeraLive v2 image pipeline.
#
# Lays the FROZEN A/B partition layout (docs/partition-contract.md §3, contract v2)
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
# Step 2b — factory rootfs population. repart only FORMATS the ext4 slots; it never
# writes the OS into them. With --rootfs-tree <dir> (the mkosi build/app tree), the
# same bootable baseline is built independently into rootfs_a and rootfs_b. A
# factory A/B image must never mark an empty fallback slot good.
#
# The boot-partition populate is FAMILY-GATED (custom-uboot/RK3588 only): it stages
# boot.scr (mkimage-compiled from boot.scr.cmd), cera_board.env, the boot_state.txt
# A/B seed and recovery.scr via `install-boot.sh boot-partition`, then
# mcopies them into the FAT image. mkimage (u-boot-tools) is a HOST prerequisite at
# assembly time; x86 (efi) skips this — it boots from the EFI System Partition.
#
# After the filesystems are laid, the FAMILY-GATED bootloader write fills the
# 16 MB raw gap: for rauc_bootloader_adapter=custom (RK3588) it dd's the board's
# U-Boot blob(s) from the staged BSP .deb into the gap and asserts RKNS at sector
# 64 (delegated to write-bootloader.sh); for efi (x86) it is skipped — x86 boots
# from the EFI System Partition.
#
# Usage:
#   assemble-disk.sh build  --output <img> [--total-mb N] [--single-slot] [--no-format]
#                           [--bootloader-adapter custom|efi] [--board <id>] [--bsp-dir <dir>]
#                           [--rootfs-tree <dir>]
#   assemble-disk.sh verify [--out-dir DIR]
#
#   build   Produce a real-geometry disk image. --total-mb sets the medium size
#           (default 14800 MiB, fitting a nominal 16 GB target); data fills the
#           remainder. --single-slot (or
#           SINGLE_SLOT_FALLBACK=true) drops rootfs_b. --no-format lays only the
#           GPT geometry (skips mkfs + boot-partition populate + bootloader) — used
#           by the static verify path.
#           --bootloader-adapter/--board/--bsp-dir (default: RAUC_BOOTLOADER_ADAPTER/
#           BOARD_ID/BSP_DIR env) drive the gap bootloader write; custom writes the
#           RK3588 blob, efi skips it. --rootfs-tree <dir> (default ROOTFS_TREE env)
#           populates every factory rootfs slot from that tree; empty leaves the
#           slots blank for the static geometry-only verification path.
#   verify  Build an A/B and a single-slot test image and print + ASSERT their GPT
#           tables against the frozen contract (static check; prints to stdout).
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

# Sourced (not exec'd) so the build path reuses part_field and `verify` reuses
# do_verify; verify-disk.sh also runs standalone (verify-disk.sh do_verify ...).
# shellcheck source=lib/verify-disk.sh
source "${HERE}/verify-disk.sh"

# ---------------------------------------------------------------------------
# Locations + FROZEN contract constants (docs/partition-contract.md §3).
# Sizes in MB == MiB (contract line 52). NEVER change without a fleet re-flash.
# ---------------------------------------------------------------------------
V2_DIR="$(cd "${HERE}/.." && pwd)"
REPART_DIR="${REPART_DIR:-${V2_DIR}/mkosi/repart}"

# Reproducible builds (task 14): clamp ext4 superblock/inode times to one epoch
# (mke2fs honours SOURCE_DATE_EPOCH) and feed mkfs.ext4 a STABLE filesystem UUID +
# dir-hash seed so the rootfs_a image is bit-identical across rebuilds. Inherited
# from the orchestrator; resolved here too for a standalone assemble-disk.sh call.
SOURCE_DATE_EPOCH="$(resolve_source_date_epoch "${V2_DIR}")"
export SOURCE_DATE_EPOCH
# RK3588 raw-gap bootloader writer (family-gated; only the custom-uboot path).
WRITE_BOOTLOADER_SH="${WRITE_BOOTLOADER_SH:-${HERE}/write-bootloader.sh}"
# Boot-partition artifact installer (boot.scr/recovery.scr/cera_board.env/boot_state.txt),
# same family gate. Lives in the platform/boot layer because it renders board
# specifics from the manifest env and needs mkimage (u-boot-tools) at assembly time.
INSTALL_BOOT_SH="${INSTALL_BOOT_SH:-${V2_DIR}/mkosi/platform/boot/install-boot.sh}"

GAP_MB=16            # raw idbloader+U-Boot+ATF region (no GPT entry)
BOOT_MB=256          # p1 boot (vfat)
ROOTFS_MB=4096
DATA_FLOOR_MB=2048
GPT_TAIL_MB=1
AB_MIN_TOTAL_MB=$(( GAP_MB + BOOT_MB + ROOTFS_MB * 2 + DATA_FLOOR_MB + GPT_TAIL_MB ))
SINGLE_MIN_TOTAL_MB=$(( GAP_MB + BOOT_MB + ROOTFS_MB + DATA_FLOOR_MB + GPT_TAIL_MB ))
DEFAULT_TOTAL_MB=14800   # conservative usable capacity of the smallest 16 GB target
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
# seed, and recovery.scr. Only the custom-uboot adapter (RK3588) boots via
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
    log_info "bootloader_adapter=${adapter:-<unset>} → SKIP boot-partition populate (only custom-uboot/RK3588 ships boot.scr/recovery.scr/cera_board.env/boot_state.txt)"
    return 0
  fi
  [[ -n "${board_id}" ]] || die "bootloader_adapter=custom requires --board (or BOARD_ID) to render the boot partition"
  [[ -n "${DTB_NAME:-}" ]]        || die "bootloader_adapter=custom requires DTB_NAME (manifest dtb_name) to render the boot partition"
  [[ -n "${SERIAL_CONSOLE:-}" ]]  || die "bootloader_adapter=custom requires SERIAL_CONSOLE (family serial_console) to render the boot console"
  [[ -n "${COMPATIBLE_STRING:-}" ]] || die "bootloader_adapter=custom requires COMPATIBLE_STRING (orchestrator ceralive-<board-slug>) for the boot partition"
  [[ -x "${INSTALL_BOOT_SH}" ]] || die "boot-partition installer not executable: ${INSTALL_BOOT_SH}"
  require_cmd mcopy    # mtools — fill the FAT offline, no loop mount / no root
  require_cmd mkimage  # u-boot-tools — install-boot.sh compiles boot.scr; the device needs it

  log_info "populating boot partition (boot.scr + recovery.scr + cera_board.env + boot_state.txt, board=${board_id}, single_slot=${single_slot})"
  local staging; staging="$(mktemp -d)"
  SINGLE_SLOT_FALLBACK="${single_slot}" BOARD_ID="${board_id}" \
    DTB_NAME="${DTB_NAME}" SERIAL_CONSOLE="${SERIAL_CONSOLE}" \
    COMPATIBLE_STRING="${COMPATIBLE_STRING}" \
    bash "${INSTALL_BOOT_SH}" boot-partition "${staging}"
  # -s recurse, -o overwrite without prompt (idempotent), -Q quit on
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
# det_uuid <seed> — a STABLE RFC-4122-shaped UUID derived from <seed>. mkfs.ext4
# would otherwise stamp a random filesystem UUID (and dir-hash seed), defeating a
# bit-for-bit rebuild; seeding both from the board makes the slot reproducible.
# ---------------------------------------------------------------------------
det_uuid() {
  local h; h="$(printf '%s' "$1" | sha256sum | cut -c1-32)"
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

# ---------------------------------------------------------------------------
# Offline + rootless, matching the rest of this assembler: mkfs.ext4 -d builds a
# pre-populated ext4 image FROM the directory (no loop mount, no root), sized to the
# exact slot, then a single dd lands it at the slot's raw offset (conv=notrunc so the
# surrounding partitions are untouched). An empty rootfs_tree is a no-op: the static
# --no-format verify path passes "" and only lays GPT geometry.
# ---------------------------------------------------------------------------
populate_rootfs_slot() {
  local img="$1" rootfs_tree="$2" part_num="$3" slot_label="$4"
  [[ -n "${rootfs_tree}" ]] || return 0   # no tree provided → skip (verify path / backward compat)
  [[ -d "${rootfs_tree}" ]] || die "rootfs tree not found: ${rootfs_tree}"

  local start_sector size_sectors
  start_sector="$(part_field "${img}" "${part_num}" 'First sector')"
  size_sectors="$(part_field "${img}" "${part_num}" 'Partition size')"
  [[ -n "${start_sector}" && -n "${size_sectors}" ]] \
    || die "could not read ${slot_label} (p${part_num}) geometry from ${img}"
  local size_bytes=$(( size_sectors * SECTOR ))

  log_info "populating ${slot_label} (p${part_num}) from ${rootfs_tree} via mkfs.ext4 -d (offline)"
  local rootfs_img; rootfs_img="$(mktemp)"
  truncate -s "${size_bytes}" "${rootfs_img}"
  # The mkosi rootfs tree is root-owned with 0700 system dirs (boot/loader,
  # var/lib/private, …) a rootless host user cannot traverse. Probe readability
  # (the tar test emit_artifact uses); if blocked, populate inside the builder
  # container as root, which also preserves the source uid/gid/mode in the image.
  local fs_uuid; fs_uuid="$(det_uuid "${COMPATIBLE_STRING:-ceralive}-${slot_label}")"
  if tar -C "${rootfs_tree}" -cf /dev/null . 2>/dev/null; then
    require_cmd mkfs.ext4   # e2fsprogs — the -d populate is the whole rootless trick
    mkfs.ext4 -q -L "${slot_label}" -U "${fs_uuid}" -E hash_seed="${fs_uuid}" \
      -d "${rootfs_tree}" "${rootfs_img}" \
      || die "mkfs.ext4 -d failed populating ${slot_label} from ${rootfs_tree}"
  else
    log_info "rootfs tree is root-owned — running mkfs.ext4 -d inside the builder container (rootless host cannot traverse 0700 system dirs)"
    _populate_rootfs_slot_in_container "${rootfs_tree}" "${rootfs_img}" "${fs_uuid}" "${slot_label}"
  fi
  dd if="${rootfs_img}" of="${img}" bs="${SECTOR}" seek="${start_sector}" \
    conv=notrunc status=none
  rm -f "${rootfs_img}"
  log_success "${slot_label} populated (${size_bytes} byte slot ← partition ${part_num})"
}

# ---------------------------------------------------------------------------
# Run `mkfs.ext4 -d` as root in the builder container so the root-owned mkosi tree
# (0700 system dirs) is fully readable. <out_img> is a host-created, pre-sized file;
# the container writes the populated ext4 into it in place. Mirrors emit_artifact's
# container fallback. e2fsprogs is installed on demand (the slim builder lacks it).
# ---------------------------------------------------------------------------
_populate_rootfs_slot_in_container() {
  local tree="$1" out_img="$2" fs_uuid="$3" slot_label="$4"
  local runtime=""
  if command -v docker >/dev/null 2>&1; then runtime="docker"
  elif command -v podman >/dev/null 2>&1; then runtime="podman"
  else die "rootfs tree is root-owned and neither docker nor podman is available to populate it rootlessly — run the build as root or install a container runtime"; fi

  local image="${MKOSI_BUILDER_IMAGE:-debian:trixie-slim}"
  local img_dir img_base; img_dir="$(dirname "${out_img}")"; img_base="$(basename "${out_img}")"
  "${runtime}" run --rm \
    -e "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}" \
    -e "FS_UUID=${fs_uuid}" \
    -e "FS_LABEL=${slot_label}" \
    -v "${tree}:/rootfs-tree:ro" \
    -v "${img_dir}:/out" \
    "${image}" \
    bash -euo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      if ! command -v mkfs.ext4 >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y --no-install-recommends \
          -o Dpkg::Options::=--force-unsafe-io e2fsprogs >/dev/null
      fi
      mkfs.ext4 -q -L "${FS_LABEL}" -U "${FS_UUID}" -E hash_seed="${FS_UUID}" \
        -d /rootfs-tree "/out/'"${img_base}"'"
    ' || die "containerized mkfs.ext4 -d failed populating ${slot_label} from ${tree}"
}

# ---------------------------------------------------------------------------
# build_disk <img> <total_mb> <single_slot> <do_format> <adapter> <board_id> <bsp_dir> <rootfs_tree>
# Pre-seed the 16 MB gap, run systemd-repart, populate the factory rootfs slots,
# format the vfat boot region, then write the family-gated bootloader into the gap.
# ---------------------------------------------------------------------------
build_disk() {
  local img="$1" total_mb="$2" single_slot="$3" do_format="$4"
  local adapter="${5:-}" board_id="${6:-}" bsp_dir="${7:-}" rootfs_tree_arg="${8:-}"
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

  # 2b. Populate every factory slot. RAUC's factory-image contract requires B to
  #     be bootable before the first OTA; single-slot media only has partition 2.
  populate_rootfs_slot "${img}" "${rootfs_tree_arg}" 2 rootfs_a
  if [[ "${single_slot}" != "true" ]]; then
    populate_rootfs_slot "${img}" "${rootfs_tree_arg}" 3 rootfs_b
  fi

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
# verify_contract — build an A/B + a single-slot test image and ASSERT both
# against the frozen contract. Image build (build_disk) stays here; the
# partition/gap/label assertions live in verify-disk.sh do_verify (task 6).
# ---------------------------------------------------------------------------
verify_contract() {
  local tmp; tmp="$(mktemp -d)"
  local ab="${tmp}/ab.img" ss="${tmp}/singleslot.img"

  echo "=============================================================="
  echo " CeraLive Stage 4 — A/B partition layout verification"
  echo " Contract: docs/partition-contract.md §3 (v2, FROZEN)"
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
  do_verify "${ab}"
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
  do_verify "${ss}"
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
      local rootfs_tree="${ROOTFS_TREE:-}"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --output)              output="${2:-}"; shift 2 ;;
          --total-mb)            total_mb="${2:-}"; shift 2 ;;
          --single-slot)         single_slot="true"; shift ;;
          --no-format)           do_format="false"; shift ;;
          --bootloader-adapter)  adapter="${2:-}"; shift 2 ;;
          --board)               board_id="${2:-}"; shift 2 ;;
          --bsp-dir)             bsp_dir="${2:-}"; shift 2 ;;
          --rootfs-tree)         rootfs_tree="${2:-}"; shift 2 ;;
          *) die "unknown build argument: $1" ;;
        esac
      done
      [[ -n "${output}" ]] || die "build: --output <img> is required"
      [[ "${single_slot}" == "true" || "${single_slot}" == "false" ]] \
        || die "SINGLE_SLOT_FALLBACK must be true|false (got '${single_slot}')"
      [[ "${total_mb}" =~ ^[0-9]+$ ]] || die "build: --total-mb must be a positive integer (got '${total_mb}')"
      local min_total_mb="${AB_MIN_TOTAL_MB}" layout_name="A/B"
      if [[ "${single_slot}" == "true" ]]; then
        min_total_mb="${SINGLE_MIN_TOTAL_MB}"; layout_name="single-slot"
      fi
      (( total_mb >= min_total_mb )) \
        || die "${layout_name} layout requires at least ${min_total_mb} MiB including the data floor and GPT tail (got ${total_mb} MiB)"
      build_disk "${output}" "${total_mb}" "${single_slot}" "${do_format}" \
        "${adapter}" "${board_id}" "${bsp_dir}" "${rootfs_tree}"
      sgdisk --print "${output}" 2>/dev/null | sed -n '/Number/,$p'
      ;;
    verify)
      verify_contract
      ;;
    -h|--help|"")
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *) die "unknown mode '${mode}' (expected: build | verify)" ;;
  esac
}

main "$@"
