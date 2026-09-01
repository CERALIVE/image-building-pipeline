#!/usr/bin/env bash
#
# assemble-disk.sh — Stage 4 disk assembly for the CeraLive v2 image pipeline.
#
# Lays the FROZEN A/B partition layout (docs/partition-contract.md §3, contract v2)
# onto a GPT disk image, driven by the systemd-repart definitions committed in
# mkosi/repart/*.conf (the single source of truth for sizes / labels / FS).
#
#   (16 MB raw gap, NO GPT entry)  idbloader + U-Boot + ATF
#   p1 boot      xbootldr vfat  256 MB   PARTLABEL=boot
#   p2 rootfs_a  ext4     4096 MB        PARTLABEL=rootfs_a   (RAUC slot A)
#   p3 rootfs_b  ext4     4096 MB        PARTLABEL=rootfs_b   (RAUC slot B)  *
#   p4 data      ext4     remainder >=2048 MB  PARTLABEL=data (shared, survives A/B)
#     * rootfs_b is OMITTED when SINGLE_SLOT_FALLBACK=true (contract §4/§5).
#
# CERALIVE_BENCH_LABELS=1 (opt-in, bench media only) renames that label set to
# xboot/xrootfs_a/xrootfs_b/xdata so a bench microSD cannot collide with the
# production labels on the eMMC of the board it is booted on. Sizes, roles and
# geometry are untouched — see common.sh::resolve_partlabel.
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
#                           [--rootfs-tree <dir>] [--variant <name>]
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
#           RK3588 blob, efi skips it. --variant <name> (default KERNEL_VARIANT env,
#           empty == a prebuilt-BSP resolve) selects WHICH U-Boot blob set the
#           gap write may use, keyed on the same board×variant tuple the resolver
#           uses for variant_overrides.<variant>.uboot_packages.
#           --rootfs-tree <dir> (default ROOTFS_TREE env)
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
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
REPART_DIR="${REPART_DIR:-${PIPELINE_DIR}/mkosi/repart}"

# Reproducible builds (task 14): clamp ext4 superblock/inode times to one epoch
# (mke2fs honours SOURCE_DATE_EPOCH) and feed mkfs.ext4 a STABLE filesystem UUID +
# dir-hash seed so the rootfs_a image is bit-identical across rebuilds. Inherited
# from the orchestrator; resolved here too for a standalone assemble-disk.sh call.
SOURCE_DATE_EPOCH="$(resolve_source_date_epoch "${PIPELINE_DIR}")"
export SOURCE_DATE_EPOCH
# RK3588 raw-gap bootloader writer (family-gated; only the custom-uboot path).
WRITE_BOOTLOADER_SH="${WRITE_BOOTLOADER_SH:-${HERE}/write-bootloader.sh}"
# Boot-partition artifact installer (boot.scr/recovery.scr/cera_board.env/boot_state.txt),
# same family gate. Lives in the platform/boot layer because it renders board
# specifics from the manifest env and needs mkimage (u-boot-tools) at assembly time.
INSTALL_BOOT_SH="${INSTALL_BOOT_SH:-${PIPELINE_DIR}/mkosi/platform/boot/install-boot.sh}"

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
# Transient-scratch cleanup registry.
#
# WHY a registry and not a per-function `trap … RETURN`: every fatal path in this
# assembler runs through `die`/the common.sh ERR trap, and BOTH `exit 1` — which
# fires an EXIT trap, NEVER a RETURN trap. A RETURN trap would therefore silently
# skip exactly the failure paths that leak (proof-5, 2026-07-15: a `mkfs.ext4 -d`
# `die` left a ~4 GiB slot image behind, and five such leaks congested the
# runner's fixed 16 GiB /tmp tmpfs until the next build hit EDQUOT mid-populate).
# A single process-level EXIT trap drains this registry, so every path registered
# here is removed on a successful return AND on any `die`/error — no second
# `rm -f` sprinkled at each `die` call site (that pattern already proved fragile:
# it was missed twice). assemble-disk.sh is only ever executed, never sourced, so
# owning the process EXIT trap here clobbers no caller.
# ---------------------------------------------------------------------------
_SCRATCH_PATHS=()
_cleanup_scratch() {
  local p
  for p in ${_SCRATCH_PATHS[@]+"${_SCRATCH_PATHS[@]}"}; do
    [[ -n "${p}" ]] && rm -rf "${p}"
  done
}
trap _cleanup_scratch EXIT

# register_scratch <path> — track <path> for removal on ANY exit (success or die).
register_scratch() { _SCRATCH_PATHS+=("$1"); }

# discard_scratch <path> — remove <path> NOW and drop it from the registry, for the
# success path where the scratch has served its purpose (e.g. after the dd lands it).
discard_scratch() {
  local target="$1" keep=() p
  rm -rf "${target}"
  for p in ${_SCRATCH_PATHS[@]+"${_SCRATCH_PATHS[@]}"}; do
    [[ "${p}" == "${target}" ]] || keep+=("${p}")
  done
  _SCRATCH_PATHS=(${keep[@]+"${keep[@]}"})
}

# ---------------------------------------------------------------------------
# CONCERN MODULES (lib/disk/) — this file stays the SEQUENCER: the CLI, the
# locations, the FROZEN contract constants, the process-level scratch registry
# above, build_disk() and main(). Each assembly concern lives in its own module:
#
#   repart.sh  partition-table definition staging (single-slot drop, bench Label=)
#   slot.sh    factory A/B rootfs slot population (offline mkfs.ext4 -d + dd)
#   boot.sh    boot-artifact installation into the vfat boot partition
#   gap.sh     the 16 MB raw bootloader gap write (family-gated)
#   verify.sh  the `verify` mode's frozen-contract check
#
# EXPLICIT and ORDERED, never a glob (the customize/postinst-lib.sh rule): a
# module lost or never wired up must fail HERE, at source time, not halfway
# through an assembly as `command not found`. The order is ASSEMBLY order.
#
# THREE things deliberately did NOT move. The scratch registry, `_cleanup_scratch`
# and its process-level `trap … EXIT` stay in this file because owning that trap
# is only safe for a file that is exclusively EXECUTED (see the WHY above); a
# module could be sourced elsewhere and would then clobber its caller's trap.
# The FROZEN contract constants stay because they are the contract. And the
# header block stays lines 2-40 verbatim — `main`'s `-h` prints it by line range.
# ---------------------------------------------------------------------------
DISK_LIB_DIR="${HERE}/disk"
# shellcheck source=disk/repart.sh
source "${DISK_LIB_DIR}/repart.sh"
# shellcheck source=disk/slot.sh
source "${DISK_LIB_DIR}/slot.sh"
# shellcheck source=disk/boot.sh
source "${DISK_LIB_DIR}/boot.sh"
# shellcheck source=disk/gap.sh
source "${DISK_LIB_DIR}/gap.sh"
# shellcheck source=disk/verify.sh
source "${DISK_LIB_DIR}/verify.sh"

# ---------------------------------------------------------------------------
# assert_free_space <dir> <need_bytes> <what>
# Pre-flight guard: fail EARLY and legibly when <dir>'s filesystem cannot hold
# <need_bytes>, instead of letting `truncate`/`mkfs.ext4 -d` surface a raw
# EDQUOT/ENOSPC deep inside a container (proof-5). Names the exact directory and
# the byte deficit so the failure is diagnosable without a mkfs stack trace.
# ---------------------------------------------------------------------------
assert_free_space() {
  local dir="$1" need_bytes="$2" what="$3" avail_bytes
  # df -PB1: POSIX single-line output, available space reported in 1-byte blocks.
  avail_bytes="$(df -PB1 "${dir}" | awk 'NR==2 {print $4}')"
  [[ "${avail_bytes}" =~ ^[0-9]+$ ]] \
    || die "could not read free space on ${dir} (df returned '${avail_bytes}')"
  (( avail_bytes >= need_bytes )) \
    || die "insufficient free space for ${what}: ${dir} has ${avail_bytes} bytes free, needs ${need_bytes} (short by $(( need_bytes - avail_bytes )) bytes) — this scratch area must be persistent, quota-safe storage, not a size-capped tmpfs like /tmp"
}

# ---------------------------------------------------------------------------
# build_disk <img> <total_mb> <single_slot> <do_format> <adapter> <board_id> <bsp_dir> <rootfs_tree>
# Pre-seed the 16 MB gap, run systemd-repart, populate the factory rootfs slots,
# format the vfat boot region, then write the family-gated bootloader into the gap.
# ---------------------------------------------------------------------------
build_disk() {
  local img="$1" total_mb="$2" single_slot="$3" do_format="$4"
  local adapter="${5:-}" board_id="${6:-}" bsp_dir="${7:-}" rootfs_tree_arg="${8:-}"
  local variant="${9:-}"
  require_cmd sgdisk
  require_cmd systemd-repart
  local defs; defs="$(mktemp -d)"
  register_scratch "${defs}"
  stage_repart_dir "${defs}" "${single_slot}"

  log_info "creating ${total_mb} MiB image: ${img} (single_slot=${single_slot})"
  rm -f "${img}"
  truncate -s "${total_mb}M" "${img}"

  # 1. Pre-seed the GPT: place p1 boot at sector ${BOOT_START_SECTOR} (16 MB),
  #    leaving the leading 16 MB as raw free space with NO GPT entry for it.
  local boot_label; boot_label="$(resolve_partlabel boot)"
  log_info "pre-seeding GPT: ${boot_label} at sector ${BOOT_START_SECTOR} (16 MB gap before it)"
  sgdisk --clear -a 2048 \
    -n "1:${BOOT_START_SECTOR}:+${BOOT_MB}M" -c "1:${boot_label}" -t "1:${XBOOTLDR_GUID}" \
    "${img}" >/dev/null

  # 2. systemd-repart adopts boot and appends rootfs_a[/rootfs_b]/data, formatting
  #    the ext4 partitions. Offline: no root, no loopback.
  local slot_a slot_b
  slot_a="$(resolve_partlabel rootfs_a)"; slot_b="$(resolve_partlabel rootfs_b)"
  local slot_desc
  slot_desc="${slot_a}/${slot_b}/$(resolve_partlabel data)"
  [[ "${single_slot}" == "true" ]] && slot_desc="${slot_a}/$(resolve_partlabel data) (no B slot)"
  log_info "running systemd-repart (offline) → ${slot_desc}"
  systemd-repart --offline=yes --architecture=arm64 --dry-run=no \
    --definitions="${defs}" "${img}" >/dev/null

  # 2b. Populate every factory slot. RAUC's factory-image contract requires B to
  #     be bootable before the first OTA; single-slot media only has partition 2.
  #     The slot label also seeds det_uuid, so the bench overlay additionally
  #     keeps the ext4 filesystem UUIDs off the production values — otherwise a
  #     bench card would carry byte-identical UUIDs to the eMMC it boots beside.
  populate_rootfs_slot "${img}" "${rootfs_tree_arg}" 2 "${slot_a}"
  if [[ "${single_slot}" != "true" ]]; then
    populate_rootfs_slot "${img}" "${rootfs_tree_arg}" 3 "${slot_b}"
  fi

  # 3. Format the adopted vfat boot region (repart never re-formats an adopted
  #    partition), POPULATE it with the boot artifacts, then dd it into the 16 MB
  #    offset. Building + filling the 256 MB vfat image standalone keeps the whole
  #    step offline (mkfs.vfat + mcopy, no loop mount) before the single raw write.
  if [[ "${do_format}" == "true" ]]; then
    require_cmd mkfs.vfat
    log_info "formatting boot region (vfat, label BOOT) at ${GAP_MB} MiB offset"
    # Same rule as the rootfs slots: the pre-sized boot image goes on the
    # persistent output filesystem (not a bare `mktemp` tmpfs) and is registered
    # for cleanup on every exit path (the old `rm -f` ran only after the dd).
    local bootp_dir; bootp_dir="$(dirname "${img}")"
    assert_free_space "${bootp_dir}" "$(( BOOT_MB * 1024 * 1024 ))" "boot partition image"
    local bootp; bootp="$(mktemp "${bootp_dir}/.bootp.XXXXXX")"
    register_scratch "${bootp}"
    truncate -s "${BOOT_MB}M" "${bootp}"
    mkfs.vfat -n BOOT "${bootp}" >/dev/null
    populate_boot_partition "${bootp}" "${adapter}" "${board_id}" "${single_slot}"
    dd if="${bootp}" of="${img}" bs=1M seek="${GAP_MB}" conv=notrunc status=none
    discard_scratch "${bootp}"
  fi

  # 4. Write the family-gated bootloader into the 16 MB raw gap (real image only;
  #    the static --no-format verify path lays geometry alone and needs no blob).
  if [[ "${do_format}" == "true" ]]; then
    write_gap_bootloader "${img}" "${adapter}" "${board_id}" "${bsp_dir}" "${variant}"
  fi

  discard_scratch "${defs}"
  log_success "assembled ${img}"
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
      # KERNEL_VARIANT is emitted by the resolver ONLY for a kernel-from-source
      # variant, so an empty value IS the production path; the writer normalises
      # it to 'default' rather than treating the absence as an error.
      local variant="${KERNEL_VARIANT:-}"
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
          --variant)             variant="${2:-}"; shift 2 ;;
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
        "${adapter}" "${board_id}" "${bsp_dir}" "${rootfs_tree}" "${variant}"
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
