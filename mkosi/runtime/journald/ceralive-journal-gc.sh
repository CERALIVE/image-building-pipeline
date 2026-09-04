#!/bin/bash
#
# ceralive-journal-gc — ONE-TIME cleanup of the journal directories left behind
# by the machine-id churn that ceralive-machine-id now prevents.
#
# THIS IS A MIGRATION, NOT A STRATEGY, and the distinction is the whole design.
# journalctl reads only the CURRENT machine-id's directory, so a board whose id
# churned accumulates directories that are simultaneously unreadable and
# expensive: the measured Rock 5B+ had TWENTY of them, the largest 176 MB, on a
# /data partition that was 98 % full. Deleting them is worth doing exactly once,
# on the boot that first carries the fix. Doing it on every boot would make id
# churn survivable — and a fault that quietly cleans up after itself is a fault
# nobody fixes. The stamp file below is what makes this run once, ever, and it
# lives on /data so an A/B slot swap does not re-arm it.
#
# THE RETENTION RULE IS `current + at most one predecessor`. The current id's
# directory is the live journal and is never a candidate. One predecessor is
# kept because the single most valuable thing in a churned journal is the boot
# BEFORE the one that is running now — the boot an operator is usually asking
# about. Everything older is history that no tool on the device will read.
# "Predecessor" is the most recently MODIFIED other directory, because mtime is
# the only ordering the filesystem actually carries here (a machine-id is random,
# so the name sorts arbitrarily).
#
# SAFETY. It only ever removes DIRECTORIES that are direct children of the
# journal root AND whose names are 32 lowercase hex digits — the exact shape
# systemd gives a persistent journal directory. A file, a symlink, a `remote-*`
# directory or anything else is left untouched, so this cannot be turned into a
# general-purpose deleter by pointing it at the wrong path. It never removes the
# journal root itself, and it refuses to do anything at all when the current
# machine-id is not a valid id, because "which directory is live" would then be
# a guess.
#
# Test seams (device-daemon profile — no `set -e`, self-contained log):
#   CERALIVE_JOURNAL_DIR        journal root (default /var/log/journal)
#   CERALIVE_MACHINE_ID_ETC     current machine-id file (default /etc/machine-id)
#   CERALIVE_JOURNAL_GC_STAMP   one-time stamp (default /data/ceralive/.journal-dir-gc-done)
#   CERALIVE_JOURNAL_GC_FORCE   1 = ignore the stamp (bench diagnosis only)

set -uo pipefail

JOURNAL_DIR="${CERALIVE_JOURNAL_DIR:-/var/log/journal}"
ETC_ID="${CERALIVE_MACHINE_ID_ETC:-/etc/machine-id}"
STAMP="${CERALIVE_JOURNAL_GC_STAMP:-/data/ceralive/.journal-dir-gc-done}"
FORCE="${CERALIVE_JOURNAL_GC_FORCE:-0}"

log() { printf 'ceralive-journal-gc: %s\n' "$*"; }

if [ "${FORCE}" != "1" ] && [ -e "${STAMP}" ]; then
  log "already run (${STAMP} exists) — this is a one-time migration, not an ongoing collector"
  exit 0
fi

if [ ! -d "${JOURNAL_DIR}" ]; then
  log "no journal directory at ${JOURNAL_DIR} — nothing to migrate"
  exit 0
fi

current=""
if [ -r "${ETC_ID}" ]; then
  IFS= read -r current <"${ETC_ID}" || true
fi
case "${current}" in
  '' | *[!0-9a-f]*)
    log "ERROR: ${ETC_ID} does not hold a valid machine-id — refusing to guess which journal directory is live"
    exit 0
    ;;
esac
if [ "${#current}" -ne 32 ]; then
  log "ERROR: ${ETC_ID} is not 32 hexadecimal digits — refusing to guess which journal directory is live"
  exit 0
fi

candidates=()
for d in "${JOURNAL_DIR}"/*; do
  [ -d "${d}" ] || continue
  [ -L "${d}" ] && continue
  name="$(basename -- "${d}")"
  [ "${#name}" -eq 32 ] || continue
  case "${name}" in
    *[!0-9a-f]*) continue ;;
  esac
  [ "${name}" = "${current}" ] && continue
  candidates+=("${d}")
done

if [ "${#candidates[@]}" -eq 0 ]; then
  log "no stale machine-id journal directories under ${JOURNAL_DIR} (current: ${current})"
else
  keep=""
  keep_mtime=-1
  for d in "${candidates[@]}"; do
    m="$(stat -c %Y -- "${d}" 2>/dev/null)" || m=0
    if [ "${m}" -gt "${keep_mtime}" ]; then
      keep_mtime="${m}"
      keep="${d}"
    fi
  done
  log "retaining the live directory (${current}) and one predecessor ($(basename -- "${keep}"))"

  removed=0
  for d in "${candidates[@]}"; do
    [ "${d}" = "${keep}" ] && continue
    if rm -rf -- "${d}"; then
      removed=$((removed + 1))
      log "removed stale journal directory $(basename -- "${d}")"
    else
      log "WARNING: could not remove ${d}"
    fi
  done
  log "migration complete — removed ${removed} stale journal director$([ "${removed}" = "1" ] && printf 'y' || printf 'ies')"
fi

if mkdir -p -- "$(dirname -- "${STAMP}")" 2>/dev/null && : >"${STAMP}" 2>/dev/null; then
  log "stamped ${STAMP} — this cleanup will not run again"
else
  log "WARNING: could not write ${STAMP}; the cleanup would run again on the next boot"
fi

exit 0
