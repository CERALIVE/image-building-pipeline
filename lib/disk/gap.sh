#!/usr/bin/env bash
#
# disk/gap.sh — the 16 MB raw bootloader gap, for lib/assemble-disk.sh.
#
# Sourced by lib/assemble-disk.sh, never executed. GAP_MB is the FROZEN contract
# constant declared in the entry; the board-specific blob layout and offsets live
# in write-bootloader.sh, never here.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# write_gap_bootloader <img> <adapter> <board_id> <bsp_dir> <variant>
# FAMILY GATE for the RK3588 raw-gap bootloader write. Only the custom-uboot
# adapter (rk3588, decision D3) has an idbloader+U-Boot+ATF gap to fill; x86
# (efi) boots from the EFI System Partition and MUST be skipped. The actual
# board-specific blob layout + offsets live in write-bootloader.sh, never here.
#
# <variant> is forwarded because the U-Boot package is a per-variant board fact
# (variant_overrides.<variant>.uboot_packages): the edge track fetches Armbian's
# mainline-TF-A `-edge` package while the production path keeps `-vendor`, and
# the writer keys its committed blob-identity map on the same tuple.
# ---------------------------------------------------------------------------
write_gap_bootloader() {
  local img="$1" adapter="$2" board_id="$3" bsp_dir="$4" variant="${5:-}"
  case "${adapter}" in
    custom)
      [[ -n "${board_id}" ]] || die "bootloader_adapter=custom requires --board (or BOARD_ID) to select the RK3588 blob set"
      [[ -n "${bsp_dir}" ]]  || die "bootloader_adapter=custom requires --bsp-dir (or BSP_DIR) — the staged Armbian U-Boot .deb lives there"
      require_cmd "${WRITE_BOOTLOADER_SH}" 2>/dev/null || [[ -x "${WRITE_BOOTLOADER_SH}" ]] \
        || die "bootloader writer not executable: ${WRITE_BOOTLOADER_SH}"
      log_info "bootloader_adapter=custom → writing RK3588 bootloader into the ${GAP_MB} MiB gap (board=${board_id} variant=${variant:-default})"
      "${WRITE_BOOTLOADER_SH}" write --image "${img}" --board "${board_id}" \
        --bsp-dir "${bsp_dir}" --gap-mb "${GAP_MB}" --variant "${variant:-default}"
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
