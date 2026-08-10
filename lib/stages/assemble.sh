#!/usr/bin/env bash
#
# stages/assemble.sh — orchestrator stage [8/9]: Stage-4 disk + RAUC bundle.
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034

# ---------------------------------------------------------------------------
# stage_assemble — [8/9]
#
# Reads from main()'s frame: board, ts, out_dir, artifact, build_version,
# bsp_dir, rootfs_tree.
# ---------------------------------------------------------------------------
stage_assemble() {
  # -------------------------------------------------------------------------
  # 9. Stage-4 disk assembly. Lay the rootfs onto the FROZEN A/B GPT geometry and
  #    (RK3588) write the U-Boot blob into the 16 MB raw gap, emitting a flashable
  #    .raw ALONGSIDE the rootfs.tar above. FAMILY-GATED on the resolved
  #    rauc_bootloader_adapter: only `custom` (RK3588 vendor U-Boot, decision D3 —
  #    the "custom-uboot" adapter) has a raw bootloader gap to fill. x86 resolves
  #    `efi` and boots from the EFI System Partition; its disk path is task 14, so
  #    it is skipped here. The gap write needs the staged U-Boot .deb, so a
  #    config+package parity build (INSTALL_BOOT_BSP=0, no BSP staged) defers disk
  #    assembly to the full device build — exactly like the boot-BSP gate above.
  # -------------------------------------------------------------------------
  if [[ "${RAUC_BOOTLOADER_ADAPTER:-}" == "custom" ]]; then
    if [[ "${INSTALL_BOOT_BSP}" == "1" ]]; then
      local raw_artifact="${out_dir}/${ts}.raw" single_slot_flag=()
      [[ "${SINGLE_SLOT_FALLBACK:-false}" == "true" ]] && single_slot_flag+=(--single-slot)
      log_info "[8/9] Stage-4 disk assembly → ${raw_artifact} (bootloader_adapter=custom single_slot=${SINGLE_SLOT_FALLBACK:-false})"
      "${ASSEMBLE_DISK_SH}" build \
        --output "${raw_artifact}" \
        "${single_slot_flag[@]}" \
        --board "${BOARD_ID}" \
        --bootloader-adapter "${RAUC_BOOTLOADER_ADAPTER}" \
        --bsp-dir "${bsp_dir}" \
        --rootfs-tree "${rootfs_tree}" \
        || die "Stage-4 disk assembly failed for board '${board}'"
      log_success "flashable image: ${raw_artifact} ($(du -h "${raw_artifact}" | cut -f1))"

      # Stage-4 FINAL artifact: a signed RAUC OTA bundle (.raucb + .sha256),
      # stamped with the same board-specific COMPATIBLE_STRING and timestamp as
      # the .raw, emitted ALONGSIDE it. format=plain (no dm-verity, G4 deferred).
      local bundle_artifact="${out_dir}/${ts}.raucb"
      log_info "[8/9] Stage-4 RAUC bundle → ${bundle_artifact} (signed, compatible=${COMPATIBLE_STRING:-unset}, pki=${CERALIVE_RAUC_PKI_DIR})"
      BUNDLE_VERSION="${build_version}" BUNDLE_OUT_DIR="${out_dir}" BUNDLE_TS="${ts}" \
        "${BUILD_BUNDLE_SH}" "${BOARD_ID}" "${artifact}" \
        || die "Stage-4 RAUC bundle build failed for board '${board}'"
      log_success "signed bundle: ${bundle_artifact} ($(du -h "${bundle_artifact}" | cut -f1)), sha256 in ${bundle_artifact}.sha256"
    else
      log_warn "[8/9] INSTALL_BOOT_BSP=0 — config+package parity build; Stage-4 disk assembly (flashable .raw) deferred to the full device build"
    fi
  elif [[ "${RAUC_BOOTLOADER_ADAPTER:-}" == "efi" || "${RAUC_BOOTLOADER_ADAPTER:-}" == "grub" ]]; then
    # x86 (UEFI/GRUB) Stage-4 disk assembly (Task 12 — x86-disk wiring landed).
    # x86 boots from an EFI System Partition with RAUC's NATIVE bootloader=grub backend
    # (GRUB at the removable path /EFI/BOOT/BOOTX64.EFI + grubenv on the ESP), NOT the
    # RK3588 raw idbloader gap, so it has its OWN offline producer lib/assemble-disk-x86.sh
    # (ESP + the FROZEN rootfs_a/rootfs_b/data slots; repart/ untouched). Same
    # INSTALL_BOOT_BSP gate as the custom path — the x86 .raw needs the Debian kernel
    # inside rootfs_a, so a config+package parity build (BSP=0) defers disk assembly.
    if [[ "${INSTALL_BOOT_BSP}" == "1" ]]; then
      local raw_artifact="${out_dir}/${ts}.raw" single_slot_flag=()
      [[ "${SINGLE_SLOT_FALLBACK:-false}" == "true" ]] && single_slot_flag+=(--single-slot)
      log_info "[8/9] Stage-4 x86 ESP+GRUB disk assembly → ${raw_artifact} (bootloader_adapter=${RAUC_BOOTLOADER_ADAPTER} single_slot=${SINGLE_SLOT_FALLBACK:-false})"
      # BOARD_ID/COMPATIBLE_STRING/SERIAL_CONSOLE/SINGLE_SLOT_FALLBACK are already
      # exported by run_mkosi_build (step 6) and read from the env by the assembler
      # and install-x86-grub.sh esp; the flags below pin the per-run artifact + tree.
      "${ASSEMBLE_DISK_X86_SH}" build \
        --output "${raw_artifact}" \
        "${single_slot_flag[@]}" \
        --board "${BOARD_ID}" \
        --rootfs-tree "${rootfs_tree}" \
        || die "Stage-4 x86 disk assembly failed for board '${board}'"
      log_success "flashable image: ${raw_artifact} ($(du -h "${raw_artifact}" | cut -f1))"

      # Stage-4 FINAL artifact: a signed RAUC OTA bundle (.raucb + .sha256),
      # stamped with the same board-specific COMPATIBLE_STRING and timestamp as
      # the .raw, emitted ALONGSIDE it. build-bundle.sh is board-agnostic (it reads
      # COMPATIBLE_STRING from the env), so the x86 path mirrors the custom path
      # verbatim — same rootfs.tar artifact, same BUNDLE_* env. format=plain.
      local bundle_artifact="${out_dir}/${ts}.raucb"
      log_info "[8/9] Stage-4 RAUC bundle → ${bundle_artifact} (signed, compatible=${COMPATIBLE_STRING:-unset}, pki=${CERALIVE_RAUC_PKI_DIR})"
      BUNDLE_VERSION="${build_version}" BUNDLE_OUT_DIR="${out_dir}" BUNDLE_TS="${ts}" \
        "${BUILD_BUNDLE_SH}" "${BOARD_ID}" "${artifact}" \
        || die "Stage-4 RAUC bundle build failed for board '${board}'"
      log_success "signed bundle: ${bundle_artifact} ($(du -h "${bundle_artifact}" | cut -f1)), sha256 in ${bundle_artifact}.sha256"
    else
      log_warn "[8/9] INSTALL_BOOT_BSP=0 — config+package parity build; Stage-4 x86 disk assembly (flashable .raw) deferred to the full device build"
    fi
  else
    die "[8/9] unsupported bootloader_adapter '${RAUC_BOOTLOADER_ADAPTER:-unset}' for board '${board}' — no Stage-4 disk-assembly path is wired (expected 'custom' for RK3588 or 'efi'/'grub' for x86); refusing to emit a partial image"
  fi
}
