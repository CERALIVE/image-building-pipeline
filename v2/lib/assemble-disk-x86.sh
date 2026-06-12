#!/usr/bin/env bash
#
# assemble-disk-x86.sh — Stage 4 disk assembly for the CeraLive v2 x86 (UEFI/GRUB)
# image. The x86 twin of lib/assemble-disk.sh (RK3588 custom-uboot). Task 12 —
# closes TODO(x86-disk).
#
# WHY A SEPARATE PRODUCER (and the RK3588 assemble-disk.sh stays byte-for-byte):
# x86 boots via UEFI -> GRUB from an EFI System Partition (GPT type EF00); it has
# NO 16 MB raw idbloader/U-Boot/ATF gap (UEFI lives in the platform's own flash).
# So the p1 partition TYPE (esp, not xbootldr) and the bootloader write (GRUB into
# the ESP, not a blob into a raw gap) differ fundamentally from the RK3588 path.
# The rootfs_a/rootfs_b/data SLOTS are IDENTICAL though, so this script reuses the
# FROZEN repart slot defs (../mkosi/repart/{20,30,40}-*.conf) verbatim and only
# swaps p1 for an ESP (../mkosi/platform/x86/10-esp.conf).
#
# VERIFY-FIRST FINDING (Task 12): mkosi's native `Bootloader=grub` is INCOMPATIBLE
# with this pipeline's Format=none + offline-assemble model — the production disk is
# laid by THIS script (systemd-repart --offline + sgdisk + mtools), not by mkosi
# (the mkosi `disk` image is Bootable=no, "the geometry reference; assemble-disk.sh
# is the producer"). mkosi Bootloader=grub would need Format=disk + Bootable=yes +
# mkosi-owned ESP/repart, fighting that model and touching partition geometry (G3).
# So GRUB is SCRIPT-INSTALLED offline here (grub-mkstandalone -> ESP removable path),
# mirroring how assemble-disk.sh writes the RK3588 bootloader. RAUC uses its NATIVE
# bootloader=grub backend (system.conf written by platform/mkosi.finalize ->
# install-x86-grub.sh rootfs).
#
#   (NO raw gap — x86 has none)
#   p1 boot      esp(vfat)  256 MB   PARTLABEL=boot   (ESP: GRUB + grub.cfg + grubenv)
#   p2 rootfs_a  ext4       4096 MB  PARTLABEL=rootfs_a   (RAUC slot A)
#   p3 rootfs_b  ext4       4096 MB  PARTLABEL=rootfs_b   (RAUC slot B)  *
#   p4 data      ext4       remainder >=2048 MB  PARTLABEL=data (shared, survives A/B)
#     * rootfs_b is OMITTED when SINGLE_SLOT_FALLBACK=true.
#
# Fully OFFLINE (systemd-repart --offline=yes): no root, no loopback. The ESP is
# pre-seeded with sgdisk at sector 2048 (1 MiB grain, no gap) so systemd-repart
# ADOPTS it (never re-formatting an adopted partition); we then format it FAT32 with
# mkfs.vfat, POPULATE it via install-x86-grub.sh esp + mtools (mcopy — no mount), and
# dd it into its offset. rootfs_a is built with mkfs.ext4 -d (no loop mount, no root)
# and dd'd into p2, exactly like the RK3588 producer.
#
# Usage:
#   assemble-disk-x86.sh build  --output <img> [--total-mb N] [--single-slot]
#                               [--no-format] [--board <id>] [--rootfs-tree <dir>]
#   assemble-disk-x86.sh verify [--out-dir DIR]
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

# Sourced (not exec'd) for part_field / sectors_to_mib / part_count on the build +
# verify paths. verify-disk.sh skips its standalone main() when sourced.
# shellcheck source=lib/verify-disk.sh
source "${HERE}/verify-disk.sh"

# ---------------------------------------------------------------------------
# Locations + contract constants. The x86 SLOT sizes come from the FROZEN repart
# defs (reused verbatim); the ESP def is x86-specific (platform/x86/10-esp.conf).
# ---------------------------------------------------------------------------
V2_DIR="$(cd "${HERE}/.." && pwd)"
REPART_DIR="${REPART_DIR:-${V2_DIR}/mkosi/repart}"
X86_PLATFORM_DIR="${X86_PLATFORM_DIR:-${V2_DIR}/mkosi/platform/x86}"
ESP_CONF="${ESP_CONF:-${X86_PLATFORM_DIR}/10-esp.conf}"
INSTALL_X86_GRUB_SH="${INSTALL_X86_GRUB_SH:-${X86_PLATFORM_DIR}/install-x86-grub.sh}"

# Reproducible builds (task 14): clamp ext4 superblock/inode times + use a stable
# filesystem UUID so the rootfs_a image is bit-identical across rebuilds. Inherited
# from the orchestrator; resolved here too for a standalone call.
SOURCE_DATE_EPOCH="$(resolve_source_date_epoch "${V2_DIR}")"
export SOURCE_DATE_EPOCH

SECTOR=512
ESP_MB=256               # p1 ESP (vfat) — same size as the RK3588 boot partition
DEFAULT_TOTAL_MB=16384   # 16 GiB reference medium for `build` / A/B verify
SINGLESLOT_TOTAL_MB=8192 #  8 GiB reference medium for single-slot verify
# x86 has NO raw gap: the ESP starts at the 1 MiB grain (sector 2048).
ESP_START_SECTOR=2048
ESP_TYPE_GUID="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"   # EFI System Partition (EF00)

# ---------------------------------------------------------------------------
# stage_repart_dir_x86 <dest> <single_slot> — assemble the x86 repart set: the
# x86 ESP def for p1 + the FROZEN slot defs (20/30/40) copied VERBATIM. rootfs_b is
# dropped for single-slot. repart/ itself is never modified (G3 / zero-diff).
# ---------------------------------------------------------------------------
stage_repart_dir_x86() {
  local dest="$1" single_slot="$2" f
  [[ -d "${REPART_DIR}" ]] || die "repart definitions dir not found: ${REPART_DIR}"
  [[ -f "${ESP_CONF}" ]]   || die "x86 ESP repart def not found: ${ESP_CONF}"
  mkdir -p "${dest}"
  rm -f "${dest}"/*.conf
  # p1: x86 ESP (replaces the RK3588 xbootldr 10-boot.conf).
  cp "${ESP_CONF}" "${dest}/10-esp.conf"
  # p2..p4: the FROZEN rootfs/data slot defs, reused as-is.
  shopt -s nullglob
  local copied=0
  for f in "${REPART_DIR}"/20-*.conf "${REPART_DIR}"/30-*.conf "${REPART_DIR}"/40-*.conf; do
    if [[ "${single_slot}" == "true" && "$(basename "${f}")" == *rootfs_b* ]]; then
      log_info "single-slot fallback: omitting $(basename "${f}") (no B slot)"
      continue
    fi
    cp "${f}" "${dest}/"
    copied=$(( copied + 1 ))
  done
  shopt -u nullglob
  (( copied > 0 )) || die "no frozen slot *.conf staged from ${REPART_DIR}"
}

# ---------------------------------------------------------------------------
# det_uuid <seed> — STABLE RFC-4122-shaped UUID derived from <seed> (reproducible
# rootfs_a). Same scheme as assemble-disk.sh.
# ---------------------------------------------------------------------------
det_uuid() {
  local h; h="$(printf '%s' "$1" | sha256sum | cut -c1-32)"
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

# ---------------------------------------------------------------------------
# populate_rootfs_a <img> <rootfs_tree> — write the mkosi rootfs tree into the
# rootfs_a slot (partition 2). systemd-repart --offline FORMATS the ext4 slot but
# never populates it; without this the flashed board loads GRUB + kernel then PANICS
# (empty root). Offline + rootless: mkfs.ext4 -d builds a pre-populated ext4 image
# FROM the directory, dd'd into the slot offset. Same technique as assemble-disk.sh.
# An empty rootfs_tree is a no-op (the static verify path). The ext4 FS LABEL is
# rootfs_a so GRUB's `search --label rootfs_a` (grub-ab.cfg) finds the kernel.
# ---------------------------------------------------------------------------
populate_rootfs_a() {
  local img="$1" rootfs_tree="$2"
  [[ -n "${rootfs_tree}" ]] || return 0
  [[ -d "${rootfs_tree}" ]] || die "rootfs tree not found: ${rootfs_tree}"

  local start_sector size_sectors
  start_sector="$(part_field "${img}" 2 'First sector')"
  size_sectors="$(part_field "${img}" 2 'Partition size')"
  [[ -n "${start_sector}" && -n "${size_sectors}" ]] \
    || die "could not read rootfs_a (p2) geometry from ${img}"
  local size_bytes=$(( size_sectors * SECTOR ))

  log_info "populating rootfs_a (p2) from ${rootfs_tree} via mkfs.ext4 -d (offline)"
  local rootfs_img; rootfs_img="$(mktemp)"
  truncate -s "${size_bytes}" "${rootfs_img}"
  local fs_uuid; fs_uuid="$(det_uuid "${COMPATIBLE_STRING:-ceralive}-rootfs_a")"
  if tar -C "${rootfs_tree}" -cf /dev/null . 2>/dev/null; then
    require_cmd mkfs.ext4
    mkfs.ext4 -q -L rootfs_a -U "${fs_uuid}" -E hash_seed="${fs_uuid}" \
      -d "${rootfs_tree}" "${rootfs_img}" \
      || die "mkfs.ext4 -d failed populating rootfs_a from ${rootfs_tree}"
  else
    log_info "rootfs tree is root-owned — running mkfs.ext4 -d inside the builder container (rootless host cannot traverse 0700 system dirs)"
    _populate_rootfs_a_in_container "${rootfs_tree}" "${rootfs_img}" "${fs_uuid}"
  fi
  # conv=sparse keeps the all-zero tail of the 4 GiB slot as a hole in the output
  # .raw (the slot is mostly empty; flashing/compression restore the zeros) so the
  # image does not balloon to its full nominal size on the build host.
  dd if="${rootfs_img}" of="${img}" bs="${SECTOR}" seek="${start_sector}" \
    conv=notrunc,sparse status=none
  rm -f "${rootfs_img}"
  log_success "rootfs_a populated (${size_bytes} byte slot <- partition 2)"
}

# _populate_rootfs_a_in_container <rootfs_tree> <out_img> <fs_uuid> — run mkfs.ext4
# -d as root in the builder container for a root-owned mkosi tree (0700 system dirs).
# Mirrors assemble-disk.sh's container fallback. e2fsprogs installed on demand.
_populate_rootfs_a_in_container() {
  local tree="$1" out_img="$2" fs_uuid="${3:-}"
  local runtime=""
  if command -v docker >/dev/null 2>&1; then runtime="docker"
  elif command -v podman >/dev/null 2>&1; then runtime="podman"
  else die "rootfs tree is root-owned and neither docker nor podman is available to populate it rootlessly — run the build as root or install a container runtime"; fi

  local image="${MKOSI_BUILDER_IMAGE:-debian:trixie-slim}"
  local img_dir img_base; img_dir="$(dirname "${out_img}")"; img_base="$(basename "${out_img}")"
  "${runtime}" run --rm \
    -e "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}" \
    -e "FS_UUID=${fs_uuid}" \
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
      mkfs.ext4 -q -L rootfs_a -U "${FS_UUID}" -E hash_seed="${FS_UUID}" \
        -d /rootfs-tree "/out/'"${img_base}"'"
    ' || die "containerized mkfs.ext4 -d failed populating rootfs_a from ${tree}"
}

# ---------------------------------------------------------------------------
# build_esp <img> <single_slot> <board> — format the ESP (FAT32) standalone,
# populate it with GRUB + grub.cfg + grubenv via install-x86-grub.sh esp + mtools
# (offline, no mount), and dd it into p1's offset. repart adopted (did not format)
# the pre-seeded ESP, so this is the only format of that region.
# ---------------------------------------------------------------------------
build_esp() {
  local img="$1" single_slot="$2" board="$3"
  require_cmd mkfs.vfat
  require_cmd mcopy
  [[ -x "${INSTALL_X86_GRUB_SH}" ]] || die "x86 grub installer not executable: ${INSTALL_X86_GRUB_SH}"

  local start_sector size_sectors
  start_sector="$(part_field "${img}" 1 'First sector')"
  size_sectors="$(part_field "${img}" 1 'Partition size')"
  [[ -n "${start_sector}" && -n "${size_sectors}" ]] \
    || die "could not read ESP (p1) geometry from ${img}"

  log_info "formatting ESP (FAT32, label ESP) at sector ${start_sector} (board=${board}, single_slot=${single_slot})"
  local espimg; espimg="$(mktemp)"
  truncate -s "${ESP_MB}M" "${espimg}"
  mkfs.vfat -F 32 -n ESP "${espimg}" >/dev/null

  local staging; staging="$(mktemp -d)"
  SINGLE_SLOT_FALLBACK="${single_slot}" \
    bash "${INSTALL_X86_GRUB_SH}" esp "${staging}"
  # -s recurse, -o overwrite without prompt (idempotent), -Q quit on error.
  mcopy -i "${espimg}" -s -o -Q "${staging}/EFI" ::
  rm -rf "${staging}"

  dd if="${espimg}" of="${img}" bs="${SECTOR}" seek="${start_sector}" \
    conv=notrunc status=none
  rm -f "${espimg}"
  log_success "ESP populated (GRUB removable-path + grub.cfg + grubenv) <- partition 1"
}

# ---------------------------------------------------------------------------
# build_disk_x86 <img> <total_mb> <single_slot> <do_format> <board> <rootfs_tree>
# Pre-seed the ESP at the 1 MiB grain (no gap), run systemd-repart (adopt ESP +
# create rootfs_a[/rootfs_b]/data ext4), populate rootfs_a, then (real image only)
# format + populate the ESP and dd it in.
# ---------------------------------------------------------------------------
build_disk_x86() {
  local img="$1" total_mb="$2" single_slot="$3" do_format="$4"
  local board="${5:-}" rootfs_tree_arg="${6:-}"
  require_cmd sgdisk
  require_cmd systemd-repart
  local defs; defs="$(mktemp -d)"
  stage_repart_dir_x86 "${defs}" "${single_slot}"

  log_info "creating ${total_mb} MiB x86 image: ${img} (single_slot=${single_slot})"
  rm -f "${img}"
  truncate -s "${total_mb}M" "${img}"

  # 1. Pre-seed the GPT: place p1 ESP at sector ${ESP_START_SECTOR} (1 MiB, NO gap).
  #    systemd-repart then ADOPTS this ESP and appends the rootfs/data slots.
  log_info "pre-seeding GPT: ESP (EF00) at sector ${ESP_START_SECTOR} (no raw gap on x86)"
  sgdisk --clear -a 2048 \
    -n "1:${ESP_START_SECTOR}:+${ESP_MB}M" -c 1:boot -t "1:${ESP_TYPE_GUID}" \
    "${img}" >/dev/null

  # 2. systemd-repart adopts the ESP and appends rootfs_a[/rootfs_b]/data, formatting
  #    the ext4 slots. Offline: no root, no loopback.
  local slot_desc="rootfs_a/rootfs_b/data"
  [[ "${single_slot}" == "true" ]] && slot_desc="rootfs_a/data (no B slot)"
  log_info "running systemd-repart (offline, x86-64) -> ESP + ${slot_desc}"
  systemd-repart --offline=yes --architecture=x86-64 --dry-run=no \
    --definitions="${defs}" "${img}" >/dev/null

  # 2b. Populate rootfs_a from the mkosi rootfs tree (no-op on the static verify path).
  populate_rootfs_a "${img}" "${rootfs_tree_arg}"

  # 3. Format + populate the ESP and dd it into p1. Skipped on the --no-format verify
  #    path (lays GPT geometry alone — needs no GRUB binary / mtools).
  if [[ "${do_format}" == "true" ]]; then
    build_esp "${img}" "${single_slot}" "${board}"
  fi

  rm -rf "${defs}"
  log_success "assembled ${img}"
}

# ---------------------------------------------------------------------------
# verify_x86 <img> — assert the produced GPT against the x86-ab layout: ESP p1 (256
# MiB, no leading gap), rootfs_a p2 (4096 MiB), rootfs_b p3 (A/B only), data tail.
# Reuses verify-disk.sh's part_field/sectors_to_mib; the gap/xbootldr assertions
# (do_verify) are RK3588-specific and intentionally NOT reused here.
# ---------------------------------------------------------------------------
verify_x86() {
  local img="$1" count
  [[ -f "${img}" ]] || die "verify_x86: image not found: ${img}"
  count="$(part_count "${img}")"
  echo "--- x86-ab contract assertions (${count} partitions) ---"

  local p1_start p1_label p1_mib
  p1_start="$(part_field "${img}" 1 'First sector')"
  p1_label="$(part_field "${img}" 1 'Partition name')"
  p1_mib="$(sectors_to_mib "$(part_field "${img}" 1 'Partition size')")"
  (( p1_start == ESP_START_SECTOR )) \
    || die "ESP (p1) starts at sector ${p1_start}, expected ${ESP_START_SECTOR} (1 MiB, no raw gap on x86)"
  [[ "${p1_label}" == "boot" ]] \
    || die "p1 label '${p1_label}' != 'boot' (x86 ESP PARTLABEL)"
  (( p1_mib == ESP_MB )) \
    || die "ESP (p1) size ${p1_mib} MiB != ${ESP_MB} MiB"
  printf '  p1 boot (ESP) %6s MiB  start sector %s (no gap) OK\n' "${p1_mib}" "${p1_start}"

  case "${count}" in
    4)
      echo "  partition count = 4 (esp + rootfs_a + rootfs_b + data) OK"
      assert_part "${img}" 2 rootfs_a 4096
      assert_part "${img}" 3 rootfs_b 4096
      assert_part "${img}" 4 data     "min:2048"
      ;;
    3)
      echo "  partition count = 3 (esp + rootfs_a + data) OK"
      assert_part "${img}" 2 rootfs_a 4096
      assert_part "${img}" 3 data     "min:2048"
      assert_no_label "${img}" rootfs_b
      echo "  rootfs_b ABSENT (single-slot fallback honored) OK"
      ;;
    *)
      die "unexpected x86 partition count ${count} (expected 4=A/B or 3=single-slot)"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# verify_contract — build an A/B + a single-slot test image (geometry only, no GRUB)
# and ASSERT both against the x86-ab layout.
# ---------------------------------------------------------------------------
verify_contract() {
  local tmp; tmp="$(mktemp -d)"
  local ab="${tmp}/ab.img" ss="${tmp}/singleslot.img"

  echo "=============================================================="
  echo " CeraLive Stage 4 — x86 ESP/GRUB A/B layout verification"
  echo " Slots reuse the FROZEN repart defs (20/30/40); p1 is an ESP."
  echo " Tooling: $(systemd-repart --version | head -1), $(sgdisk --version 2>&1 | head -1)"
  echo "=============================================================="
  echo

  echo "### A/B layout (SINGLE_SLOT_FALLBACK=false, ${DEFAULT_TOTAL_MB} MiB medium)"
  build_disk_x86 "${ab}" "${DEFAULT_TOTAL_MB}" "false" "false" 2>/dev/null
  echo
  echo "--- sgdisk --print ---"
  sgdisk --print "${ab}" 2>/dev/null | sed -n '/Disk /,$p'
  echo
  verify_x86 "${ab}"
  echo

  echo "### Single-slot fallback (SINGLE_SLOT_FALLBACK=true, ${SINGLESLOT_TOTAL_MB} MiB medium)"
  build_disk_x86 "${ss}" "${SINGLESLOT_TOTAL_MB}" "true" "false" 2>/dev/null
  echo
  echo "--- sgdisk --print ---"
  sgdisk --print "${ss}" 2>/dev/null | sed -n '/Disk /,$p'
  echo
  verify_x86 "${ss}"
  echo

  rm -rf "${tmp}"
  echo "=============================================================="
  log_success "ALL x86-ab contract assertions passed (A/B + single-slot)"
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
      local board="${BOARD_ID:-}" rootfs_tree="${ROOTFS_TREE:-}"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --output)       output="${2:-}"; shift 2 ;;
          --total-mb)     total_mb="${2:-}"; shift 2 ;;
          --single-slot)  single_slot="true"; shift ;;
          --no-format)    do_format="false"; shift ;;
          --board)        board="${2:-}"; shift 2 ;;
          --rootfs-tree)  rootfs_tree="${2:-}"; shift 2 ;;
          *) die "unknown build argument: $1" ;;
        esac
      done
      [[ -n "${output}" ]] || die "build: --output <img> is required"
      [[ "${single_slot}" == "true" || "${single_slot}" == "false" ]] \
        || die "SINGLE_SLOT_FALLBACK must be true|false (got '${single_slot}')"
      build_disk_x86 "${output}" "${total_mb}" "${single_slot}" "${do_format}" \
        "${board}" "${rootfs_tree}"
      if [[ "${do_format}" == "true" ]]; then verify_x86 "${output}"; fi
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
