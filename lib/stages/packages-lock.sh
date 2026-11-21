#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154

stage_packages_lock() {
  local output="${out_dir}/${ts}.packages.lock.json"
  local -a expected=()
  if [[ "${kernel_origin:-ceralive-kernel}" == measurement-candidate ]]; then
    expected=(--measurement-candidate)
  fi
  log_info "[6d/9] reconciling final dpkg status with verified package receipts -> ${output}"
  python3 "${HERE}/packages-lock.py" merge "${rootfs_tree}" "${staging}" "${output}" \
    "${SOURCE_DATE_EPOCH}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${KERNEL_SOURCE_COMMIT:-}" "${KERNEL_SOURCE_PATCHES_COMMIT:-}" "${expected[@]}" \
    || die "package lock INCOMPLETE for board '${board}' — no artifact may be assembled"
  log_success "[6d/9] package lock: ${output}"
}
