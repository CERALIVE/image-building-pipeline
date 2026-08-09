#!/usr/bin/env bash
#
# stages/boot-verify.sh — orchestrator stage [6b/9]: /boot completeness gate.
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# stage_boot_verify — [6b/9]
#
# Reads from main()'s frame: board, artifact.
# ---------------------------------------------------------------------------
stage_boot_verify() {
  # Everything the U-Boot selector loads must actually be in that rootfs, on EVERY
  # kernel path. This is checked here, against the emitted tar, because it is the
  # earliest point where the real answer exists: DRY_RUN CI never runs the layers
  # that populate /boot, and preflash-verify.sh (which does check) only runs on a
  # production-labelled .raw an operator is about to flash — a bench image fails its
  # PARTLABEL assertions first and never reaches the artifact checks. That gap is
  # exactly how an `edge` image with no /boot/Image reached a board.
  if [[ "${ARCH}" == "arm64" && "${INSTALL_BOOT_BSP}" == "1" ]]; then
    log_info "[6b/9] verifying boot artifacts in ${artifact}"
    "${VERIFY_BOOT_ARTIFACTS_SH}" "${artifact}" --dtb-name "${DTB_NAME}" \
      || die "boot artifacts INCOMPLETE for board '${board}' — this image would not boot"
  fi
}
