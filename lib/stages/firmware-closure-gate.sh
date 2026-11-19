#!/usr/bin/env bash
# Sourced stage: inspect the same emitted artifact and parity boundary as size.
# shellcheck shell=bash
# shellcheck disable=SC2154
stage_firmware_closure_gate() {
  if [[ "${INSTALL_BOOT_BSP}" == "1" ]]; then
    log_info "[6c-firmware/9] enforcing firmware closure in ${artifact}"
    bash "${PIPELINE_DIR}/lib/check-firmware-closure.sh" "${artifact}" \
      || die "firmware closure failed for ${artifact}"
  else
    log_warn "[6c-firmware/9] INSTALL_BOOT_BSP=0 - kernel-less parity build; firmware closure skipped"
  fi
}
