#!/usr/bin/env bash
#
# stages/bsp-gate.sh — orchestrator stage [4/9]: the missing-BSP gate.
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# stage_bsp_gate — [4/9]
#
# For a full device build the kernel/DTB/U-Boot/firmware MUST be obtainable; if
# any is not staged, abort BEFORE mkosi — clean failure, no half-image.
#
# Reads from main()'s frame: bsp_dir.
# ---------------------------------------------------------------------------
stage_bsp_gate() {
  if [[ "${INSTALL_BOOT_BSP}" == "1" ]]; then
    log_info "[4/9] verifying boot BSP packages are obtainable"
    local boot_bsp_names name missing=()
    read -ra boot_bsp_names <<<"${KERNEL_PACKAGES} ${DTB_PACKAGES} ${UBOOT_PACKAGES} ${FIRMWARE_PACKAGES}"
    for name in "${boot_bsp_names[@]}"; do
      if ! compgen -G "${bsp_dir}/${name}_*.deb" >/dev/null \
         && ! compgen -G "${bsp_dir}/${name}-*.deb" >/dev/null; then
        missing+=("${name}")
      fi
    done
    if (( ${#missing[@]} > 0 )); then
      for name in "${missing[@]}"; do
        log_error "cannot resolve package '${name}': no .deb staged from ${ARMBIAN_APT_URL} (${ARMBIAN_SUITE}/${ARCH})"
      done
      die "missing ${#missing[@]} required BSP package(s); aborting before mkosi — no half-image produced. (Set INSTALL_BOOT_BSP=0 for a config+package parity build, or provide R2/Armbian access.)"
    fi
    log_success "all ${#boot_bsp_names[@]} boot BSP package(s) staged"
  else
    log_warn "[4/9] INSTALL_BOOT_BSP=0 — config+package parity build; boot BSP (kernel/DTB/U-Boot/firmware) deferred to the hardware build (task 17)"
  fi
}
