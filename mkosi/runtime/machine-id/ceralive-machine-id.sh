#!/bin/bash
#
# ceralive-machine-id — establish ONE valid machine-id for this physical board,
# keep it on /data so it survives an A/B slot swap, and make the running system
# actually use it.
#
# WHY (measured on a shipped Rock 5B+, 2026-08-30):
#
#     $ ls -d /var/log/journal/*/ | wc -l   -> 20
#     $ cat /etc/machine-id                 -> f2346da8af8f48fdb339d17e8c21a25e
#     $ cat /opt/ceralive/machine-id        -> 69eae157d96657b5f7af5a096a736fba
#
#   Twenty journal directories, because the id churns; and the two files
#   disagree, because the persistent copy was never actually consumed. journalctl
#   reads only the CURRENT id's directory, so nineteen boots of history were on
#   the disk and invisible — while the same directories were eating the /data
#   partition that was, by then, 98 % full.
#
# THE MECHANISM THIS REPLACES WAS ALREADY SHIPPED, AND FAILED IN TWO PLACES.
# `ceralive-migrate-data` carried:
#
#     if [ -s /etc/machine-id ] && [ ! -s "$DATA/ceralive/machine-id" ]; then
#         cp -a /etc/machine-id "$DATA/ceralive/machine-id"
#     fi
#     if [ -s "$DATA/ceralive/machine-id" ] && ! mountpoint -q /etc/machine-id; then
#         mount --bind "$DATA/ceralive/machine-id" /etc/machine-id 2>/dev/null || true
#     fi
#
#   1. `-s` is "non-empty", not "valid". The image ships /etc/machine-id holding
#      the literal string `uninitialized` (14 bytes — that is systemd's own
#      first-boot marker), which is non-empty, so the seeder would happily
#      promote it to the persistent identity of the board. Anything else
#      non-empty — a truncated write, an uppercase id, a stray newline — was
#      equally acceptable.
#   2. The bind is SKIPPED, silently, whenever /etc/machine-id is already a
#      mountpoint — which is exactly the state PID 1 leaves behind when it takes
#      the transient machine-id path. `2>/dev/null || true` then hides a failing
#      bind as well. Both outcomes look identical from the outside: a board that
#      keeps a stable-looking id which is not the persistent one.
#
# WHAT THIS DOES INSTEAD
#
#   * VALIDATES. The persistent id must be exactly 32 lowercase hex digits on a
#     single line. `uninitialized` is rejected BY NAME as well as by shape, so
#     the log says which defect was found rather than "malformed".
#   * REGENERATES ONLY THEN. A valid persistent id is never rewritten, never
#     re-derived, and never rotated — not on a slot swap, not on a re-run, not
#     when /etc/machine-id disagrees with it. The /data copy is the identity;
#     everything else is reconciled TO it.
#   * ADOPTS rather than invents on a genuinely fresh board. With no persistent
#     id at all, a VALID /etc/machine-id (the one PID 1 generated on the first
#     boot after a factory flash) is adopted, so the very first boot's journal
#     directory is already the permanent one and no stray is ever created.
#   * RECONCILES /etc/machine-id by WRITING THE FILE, not by bind-mounting it.
#     The file is on the rootfs slot, so writing it means PID 1 — and therefore
#     journald, and therefore every later reader — resolves the persistent id
#     from the next boot of this slot onward, with no mount to be skipped, hidden
#     or lost. A bind mount is visible only to the boot that made it.
#
# WHY A JOURNALD RESTART, AND WHY ONLY WHEN THE ID CHANGED
#
#   journald caches the machine-id once, at startup, and it starts long before
#   /data can possibly be mounted. On the FIRST boot of a freshly written slot it
#   therefore opens a directory named after the id PID 1 invented, and no later
#   correction moves it — that stray directory is where the twenty came from. A
#   restart is the supported way to make journald re-read it, and this unit is
#   ordered AFTER the /var/log bind mount specifically so the reopened journal
#   lands on /data under the correct id rather than on the rootfs slot.
#
#   It is gated on the id having ACTUALLY changed, which on a settled board is
#   never, so the steady-state cost is zero. It is non-fatal: a device that keeps
#   a stray directory for one boot is a smaller problem than a device whose boot
#   is blocked on a log daemon.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
#   * It does not bind-mount /etc/machine-id. See above; and the bind is what
#     made systemd-machine-id-commit.service satisfy its
#     ConditionPathIsMountPoint and then fail on every single boot.
#   * It does not touch /var/log/journal. Removing stale directories is a
#     separate, one-time, bounded migration (ceralive-journal-gc), because an
#     ongoing collector would make id churn survivable instead of fixed.
#   * It never fails the boot. Every failure path logs and exits 0: the worst
#     outcome of this script not running is the behaviour the board already had.
#
# Test seams (device-daemon profile — no `set -e`, self-contained log/die):
#   CERALIVE_MACHINE_ID_PERSISTENT  path of the /data copy
#   CERALIVE_MACHINE_ID_ETC         path of the runtime /etc/machine-id
#   CERALIVE_MACHINE_ID_RESTART_JOURNALD  1 (default) | 0 — skip the restart

set -uo pipefail

PERSISTENT="${CERALIVE_MACHINE_ID_PERSISTENT:-/data/ceralive/machine-id}"
ETC_ID="${CERALIVE_MACHINE_ID_ETC:-/etc/machine-id}"
RESTART_JOURNALD="${CERALIVE_MACHINE_ID_RESTART_JOURNALD:-1}"

log() { printf 'ceralive-machine-id: %s\n' "$*"; }

# read_id <file> — the file's first line, or empty when unreadable. A machine-id
# file is one line by definition, so anything after it is a defect and must not
# be silently joined onto the value.
read_id() {
  local f="$1" first
  [ -r "${f}" ] || return 1
  IFS= read -r first <"${f}" || true
  printf '%s' "${first}"
}

# id_defect <value> — empty when the value is a well-formed machine-id, else a
# human-readable reason. The `uninitialized` marker is named explicitly rather
# than folded into "malformed": it is the single most likely wrong value on this
# image, and an operator reading the journal should see that it was the
# first-boot marker and not a corrupted write.
id_defect() {
  local v="$1"
  [ -n "${v}" ] || { printf 'empty'; return; }
  if [ "${v}" = "uninitialized" ]; then
    printf "systemd's first-boot 'uninitialized' marker"
    return
  fi
  if [ "${#v}" -ne 32 ]; then
    printf 'wrong length (%d chars, expected 32)' "${#v}"
    return
  fi
  case "${v}" in
    *[!0-9a-f]*) printf 'not 32 lowercase hexadecimal digits' ;;
    *) : ;;
  esac
}

# file_is_valid_id <file> — true when the file holds one well-formed id and no
# second line of content. A missing or repeated trailing newline is NOT treated
# as a defect: the penalty for judging a good id malformed is rotating it, which
# is the one outcome this script exists to prevent.
file_is_valid_id() {
  local f="$1" content
  [ -r "${f}" ] || return 1
  content="$(cat -- "${f}" 2>/dev/null)" || return 1
  case "${content}" in
    *$'\n'*) return 1 ;;
  esac
  [ -z "$(id_defect "${content}")" ] || return 1
  return 0
}

# new_id — 32 lowercase hex digits from the kernel's own entropy. systemd-id128
# is preferred because it is the same generator systemd uses; the uuid node is
# the fallback that is present even in a minimal chroot.
new_id() {
  local v=""
  if command -v systemd-id128 >/dev/null 2>&1; then
    v="$(systemd-id128 new 2>/dev/null)"
  fi
  if [ -z "${v}" ] && [ -r /proc/sys/kernel/random/uuid ]; then
    v="$(tr -d '-' </proc/sys/kernel/random/uuid 2>/dev/null)"
  fi
  if [ -z "${v}" ]; then
    v="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  printf '%s' "${v}"
}

# write_id <file> <id> — atomic, 0444, systemd's own on-disk shape.
write_id() {
  local f="$1" v="$2" dir tmp
  dir="$(dirname -- "${f}")"
  mkdir -p -- "${dir}" || return 1
  tmp="$(mktemp -- "${dir}/.machine-id.XXXXXX")" || return 1
  if ! printf '%s\n' "${v}" >"${tmp}"; then
    rm -f -- "${tmp}"
    return 1
  fi
  chmod 0444 -- "${tmp}" 2>/dev/null || true
  if ! mv -f -- "${tmp}" "${f}"; then
    rm -f -- "${tmp}"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 1. Establish the persistent identity.
# ---------------------------------------------------------------------------
persistent_id=""
if [ -e "${PERSISTENT}" ]; then
  if file_is_valid_id "${PERSISTENT}"; then
    persistent_id="$(read_id "${PERSISTENT}")"
    log "persistent machine-id present and valid (${PERSISTENT}) — keeping it"
  else
    bad="$(read_id "${PERSISTENT}" 2>/dev/null)"
    log "WARNING: ${PERSISTENT} is not a valid machine-id ($(id_defect "${bad}")) — regenerating ONCE"
  fi
fi

if [ -z "${persistent_id}" ]; then
  # A fresh board: adopt what PID 1 generated on this boot rather than inventing
  # a second id, so the journal directory journald already opened IS the
  # permanent one and no stray is ever created.
  if file_is_valid_id "${ETC_ID}"; then
    persistent_id="$(read_id "${ETC_ID}")"
    log "adopting the running machine-id as this board's persistent identity"
  else
    persistent_id="$(new_id)"
    log "generating a new persistent machine-id (${ETC_ID} is unusable: $(id_defect "$(read_id "${ETC_ID}" 2>/dev/null)"))"
  fi
  if [ -n "$(id_defect "${persistent_id}")" ]; then
    log "ERROR: could not obtain a valid machine-id ($(id_defect "${persistent_id}")) — leaving the system untouched"
    exit 0
  fi
  if ! write_id "${PERSISTENT}" "${persistent_id}"; then
    log "ERROR: could not write ${PERSISTENT} — leaving the system untouched"
    exit 0
  fi
  log "persistent machine-id stored at ${PERSISTENT}"
fi

# ---------------------------------------------------------------------------
# 2. Reconcile the running /etc/machine-id to it.
# ---------------------------------------------------------------------------
changed=0
running_id="$(read_id "${ETC_ID}" 2>/dev/null)"
if [ "${running_id}" = "${persistent_id}" ] && file_is_valid_id "${ETC_ID}"; then
  log "running machine-id already matches the persistent one — nothing to do"
else
  if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "${ETC_ID}"; then
    # PID 1 mounts a transient machine-id over this path when it cannot commit
    # one. Unmounting is the same operation systemd-machine-id-commit performs
    # before it writes the real file, so the file below lands on the rootfs and
    # survives the reboot rather than disappearing with the tmpfs.
    log "${ETC_ID} is a mountpoint (transient machine-id) — unmounting so the persistent id can be committed"
    umount "${ETC_ID}" 2>/dev/null \
      || log "WARNING: could not unmount ${ETC_ID} — the persistent id cannot be committed on this boot"
  fi
  if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "${ETC_ID}"; then
    log "WARNING: ${ETC_ID} is still a mountpoint — skipping the write"
  elif write_id "${ETC_ID}" "${persistent_id}"; then
    changed=1
    log "committed the persistent machine-id to ${ETC_ID} (was: ${running_id:-<unreadable>})"
  else
    log "WARNING: could not write ${ETC_ID} — the board keeps the id PID 1 chose for this boot"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Make journald use it on THIS boot too.
# ---------------------------------------------------------------------------
if [ "${changed}" = "1" ] && [ "${RESTART_JOURNALD}" = "1" ]; then
  if command -v systemctl >/dev/null 2>&1; then
    log "machine-id changed this boot — restarting systemd-journald so the journal is written under the persistent id"
    systemctl try-restart systemd-journald.service \
      || log "WARNING: could not restart systemd-journald (this boot keeps a stray journal directory; the next boot will not)"
  fi
fi

exit 0
