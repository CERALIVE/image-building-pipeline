#!/usr/bin/env bash
#
# stages/bsp-gate.sh — orchestrator stage [4/9]: the missing-BSP gate.
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

bsp_package_source_hint() {
  local name="$1"
  local userspace_manifest="${RK3588_USERSPACE_DEB_VERSIONS_FILE:-${PIPELINE_DIR}/manifests/rk3588-userspace-deb-versions.txt}"
  if [[ -f "${userspace_manifest}" ]] && awk -v package="${name}" '$1 == package { found=1 } END { exit !found }' "${userspace_manifest}"; then
    printf 'no .deb staged from the pinned GitHub release manifest (%s) — check fetch_rk3588_userspace ran' "${userspace_manifest#"${PIPELINE_DIR}/"}"
  else
    printf 'no .deb staged from %s (%s/%s)' "${ARMBIAN_APT_URL}" "${ARMBIAN_SUITE}" "${ARCH}"
  fi
}

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
      local dry_run_hint=""
      if [[ -n "${DRY_RUN:-}" || -f "${staging}/.fetch-auto-dry-run" ]]; then
        dry_run_hint=" hint: if this was expected to be a real fetch, verify APT_GPG_PUBLIC_B64 / APT_CLIENT_CRT_B64 / APT_CLIENT_KEY_B64 / ARMBIAN_APT_KEYRING are set — a missing credential silently downgrades the fetch to a dry run instead of failing loudly at fetch time"
      fi
      for name in "${missing[@]}"; do
        log_error "cannot resolve package '${name}': $(bsp_package_source_hint "${name}")"
      done
      die "missing ${#missing[@]} required BSP package(s); aborting before mkosi — no half-image produced. (Set INSTALL_BOOT_BSP=0 for a config+package parity build, or provide R2/Armbian access.)${dry_run_hint}"
    fi
    log_success "all ${#boot_bsp_names[@]} boot BSP package(s) staged"
  else
    log_warn "[4/9] INSTALL_BOOT_BSP=0 — config+package parity build; boot BSP (kernel/DTB/U-Boot/firmware) deferred to the hardware build (task 17)"
  fi
}
