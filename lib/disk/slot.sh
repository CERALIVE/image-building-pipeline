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
  discard_scratch "${rootfs_img}"
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
