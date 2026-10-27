#!/bin/bash
# Copy/verify only. The caller owns mounts, locks, receipts and slot eligibility.

dpkg_verify_filtered() {
  local root="$1" out line path keep prune
  out="$("${DPKG_BIN}" --root="${root}" --verify 2>&1)"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    path="${line##* }"
    keep=1
    if [[ -r "${PRUNE_PATHS_FILE}" ]]; then
      while IFS= read -r prune; do
        [[ -n "${prune}" ]] || continue
        case "${prune}" in \#*) continue ;; esac
        # shellcheck disable=SC2254 # the manifest entries are deliberately globs
        case "${path}" in ${prune}) keep=0; break ;; esac
      done <"${PRUNE_PATHS_FILE}"
    fi
    [[ "${keep}" -eq 1 ]] && printf '%s\n' "${line}"
  done <<<"${out}"
}

slot_mirror_copy_verify() {
  local rc source_verify target_verify
  set -m
  "${RSYNC_BIN}" "$@" "${SOURCE_MNT}/" "${TARGET_MNT}/" &
  WORKER_PID=$!
  set +m
  wait "${WORKER_PID}"
  rc=$?
  WORKER_PID=""
  [[ "${rc}" -eq 0 ]] || die "rsync mirror failed (rc=${rc})"
  "${SYNC_BIN}" || die "mirror sync failed"
  source_verify="$(dpkg_verify_filtered "${SOURCE_MNT}" | sort)"
  target_verify="$(dpkg_verify_filtered "${TARGET_MNT}" | sort)"
  [[ "${source_verify}" == "${target_verify}" ]] || die "dpkg --verify mismatch between source and target"
}
