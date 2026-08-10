#!/usr/bin/env bash
#
# disk/repart.sh — partition-table definition staging for lib/assemble-disk.sh.
#
# Sourced by lib/assemble-disk.sh, never executed. Uses the entry's scratch
# registry and FROZEN contract constants; see the entry for both.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# stage_repart_dir <dest> <single_slot:true|false>
# Copy the committed repart defs into <dest>, dropping rootfs_b for single-slot.
# ---------------------------------------------------------------------------
stage_repart_dir() {
  local dest="$1" single_slot="$2" f
  [[ -d "${REPART_DIR}" ]] || die "repart definitions dir not found: ${REPART_DIR}"
  mkdir -p "${dest}"
  rm -f "${dest}"/*.conf
  shopt -s nullglob
  # The committed defs always carry the FROZEN production Label=. The bench
  # overlay rewrites it on the STAGED COPY only, so mkosi/repart/*.conf — the
  # single source of truth for the frozen contract — is never edited, and the
  # unflagged path stays a plain cp.
  local prefix; prefix="$(partlabel_prefix)"
  local copied=0
  for f in "${REPART_DIR}"/*.conf; do
    if [[ "${single_slot}" == "true" && "$(basename "${f}")" == *rootfs_b* ]]; then
      log_info "single-slot fallback: omitting $(basename "${f}") (no B slot)"
      continue
    fi
    if [[ -n "${prefix}" ]]; then
      sed "s|^Label=|Label=${prefix}|" "${f}" >"${dest}/$(basename "${f}")"
    else
      cp "${f}" "${dest}/"
    fi
    copied=$(( copied + 1 ))
  done
  shopt -u nullglob
  (( copied > 0 )) || die "no repart *.conf staged from ${REPART_DIR}"
}
