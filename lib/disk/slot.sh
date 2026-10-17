#!/usr/bin/env bash
#
# disk/slot.sh — factory A/B rootfs slot population for lib/assemble-disk.sh.
#
# Sourced by lib/assemble-disk.sh, never executed. Uses the entry's scratch
# registry, its assert_free_space preflight, the SECTOR contract constant, and
# part_field from lib/verify-disk.sh.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# shellcheck source=lib/disk/slot-image.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/slot-image.sh"

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
  [[ "${size_bytes}" -eq $((4096 * 1024 * 1024)) ]] \
    || die "${slot_label} geometry ${size_bytes} does not match the frozen 4096 MiB slot"

  log_info "populating ${slot_label} (p${part_num}) from ${rootfs_tree} via mkfs.ext4 -d (offline)"
  # Build the pre-sized slot image ALONGSIDE the output .raw, never in a bare
  # `mktemp` /tmp: on the self-hosted runner /tmp is a FIXED 16 GiB tmpfs (not
  # scaled to host RAM), and a 4096 MiB slot exhausts it → mkfs.ext4 EDQUOT
  # (proof-5). $(dirname img) is the persistent, quota-safe filesystem the .raw
  # itself lands on — the same convention fetch-debs.sh uses (temp next to its
  # destination artifact). register_scratch cleans it on success AND on `die`.
  local scratch_dir; scratch_dir="$(dirname "${img}")"
  assert_free_space "${scratch_dir}" "${size_bytes}" "${slot_label} slot image"
  local rootfs_img; rootfs_img="$(mktemp "${scratch_dir}/.rootfs-slot.XXXXXX")"
  register_scratch "${rootfs_img}"
  SLOT_IMAGE_LABEL="${slot_label}" make_slot_image "${rootfs_tree}" "${rootfs_img}" \
    || die "mkfs.ext4 -d failed populating ${slot_label} from ${rootfs_tree}"
  dd if="${rootfs_img}" of="${img}" bs="${SECTOR}" seek="${start_sector}" \
    conv=notrunc status=none
  discard_scratch "${rootfs_img}"
  log_success "${slot_label} populated (${size_bytes} byte slot ← partition ${part_num})"
}
