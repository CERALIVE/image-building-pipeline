#!/usr/bin/env bash
#
# disk/boot.sh — boot-artifact installation into the vfat boot partition, for
# lib/assemble-disk.sh.
#
# Sourced by lib/assemble-disk.sh, never executed. Uses the entry's scratch
# registry (register_scratch/discard_scratch) and INSTALL_BOOT_SH location.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

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
  register_scratch "${staging}"
  SINGLE_SLOT_FALLBACK="${single_slot}" BOARD_ID="${board_id}" \
    DTB_NAME="${DTB_NAME}" SERIAL_CONSOLE="${SERIAL_CONSOLE}" \
    COMPATIBLE_STRING="${COMPATIBLE_STRING}" \
    bash "${INSTALL_BOOT_SH}" boot-partition "${staging}"
  # -s recurse, -o overwrite without prompt (idempotent), -Q quit on
  # error, -m keep mtimes. Lands the staged tree at the FAT image root.
  mcopy -i "${bootp}" -s -o -Q -m "${staging}"/* ::
  discard_scratch "${staging}"
  log_success "boot partition populated"
}
