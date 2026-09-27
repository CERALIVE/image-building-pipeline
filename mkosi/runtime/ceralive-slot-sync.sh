#!/bin/bash
#
# ceralive-slot-sync.sh — verified local mirror of the healthy running slot into
# the other (lagged) slot (task 26, Metis G3/G4/G14).
#
# WHY THIS EXISTS: RAUC's own A/B model only knows about slots it wrote through
# `rauc install`. Every OTHER way a slot's content can legitimately fall behind
# the booted one — an apt package update on the running slot, a manual package
# pin change, anything CeraUI's software-update path does — leaves the OTHER
# slot silently stale. If that stale slot is ever activated (rollback, a bench
# A/B flip, an operator mistake) it boots an OLD, unpatched image. This script
# closes that gap by RSYNC-MIRRORING the booted slot's verified content onto the
# other slot, entirely locally (no network, no RAUC bundle, no `rauc install`),
# gated on the booted slot's content having survived a reboot and a healthcheck
# (G3 "lagged mirror" — see the healthy-state.json gate below).
#
# THIS IS NOT A RAUC INSTALL. RAUC never writes an OS bundle here; we bypass its
# install path entirely and drive its slot bookkeeping directly (`rauc status
# mark-bad/mark-good other`) so the SAME state machine every other RAUC
# consumer already trusts also governs a slot this script wrote.
#
# TWO SUBCOMMANDS:
#   check   — print the current value of every gate input as JSON and exit 0.
#             Read-only: takes no locks, mounts nothing, changes nothing. This
#             is what an operator or CeraUI calls to see WHY a sync would (or
#             would not) be refused, without triggering one.
#   run     — take both locks, evaluate every gate, and on unanimous pass
#             perform the actual mirror. Refuses (exit 75, named reason) on the
#             first failing gate; performs full read-verified, fail-closed
#             mirror otherwise.
#
# REFUSAL GATES (run only, checked in this exact order — every one must pass):
#   1. /run/ceralive/partlabel-guard.failed exists (the boot healthcheck's own
#      partition-safety observation; the same file ceralive-healthcheck.sh
#      writes and reads).
#   2. `dpkg --audit` is non-empty (a half-configured package database must
#      never be mirrored onto the other slot).
#   3. RAUC `Operation` != idle (via busctl; a real install/streaming operation
#      is in progress and must never race a local mirror).
#   4. the OTHER (non-booted) rootfs-class slot is installed-but-not-activated
#      (from `rauc status --detailed --output-format=json`: it has an
#      `installed` timestamp but no `activated` one) — a genuine pending OTA is
#      staged there and must never be silently overwritten by a mirror.
#   5. rauc-hawkbit-updater.service is active (an automatic OTA install may be
#      staging into the very slot this script is about to overwrite).
#   6. healthy-state.json does not match the CURRENT boot_id + dpkg status
#      sha256 + build_id (the G3 lagged-mirror gate: only a state that has
#      already survived a reboot and the boot healthcheck may ever be mirrored
#      — an absent or stale healthy-state.json refuses closed).
#
# LOCK ORDER (run only, both `flock -n`, both held for the whole operation):
#   1. /run/lock/ceralive-update.lock  — the SAME lock /usr/local/bin/ceralive-
#      update takes, so a local mirror and a real bundle install can never race.
#   2. /var/lib/dpkg/lock-frontend      — so a concurrent apt/dpkg transaction on
#      the booted slot cannot mutate package state mid-mirror.
#
# THE NON-RECURSIVE BIND MOUNT (why `mount --bind`, never `--rbind`): the FAT
# `/boot` partition is mounted OVER an ext4 `/boot` directory that also exists
# on the root filesystem itself (mkosi/platform/boot/install-boot.sh:171-180).
# A recursive bind would carry that FAT submount into the source view, so a
# rsync of "/boot" would copy FAT content back onto the target's own ext4
# `/boot` — exactly backwards, and it would also shadow the ext4-level content
# a plain (non-recursive) bind exposes instead: `mount --bind <root>
# /run/ceralive/slot-sync/source` gives a NEW vfsmount over `<root>`'s dentry
# tree with NO submounts carried over, so `/run/ceralive/slot-sync/source/boot`
# resolves to the ROOT FILESYSTEM'S OWN (ext4) `/boot` directory — the same
# mechanism that also lets the ext4-level `/dev` be seen instead of whatever the
# running system's devtmpfs currently shows there.
#
# `--checksum` IS MANDATORY, not an optimisation flag: this image's build is
# `SOURCE_DATE_EPOCH`-normalized, so two files across a rebuild can legitimately
# share the exact same size AND mtime while differing in content. rsync's
# default "quick check" (size+mtime only) would silently SKIP such a file, and
# a slot-sync that can silently skip a changed file is not a mirror.
#
# `/dev/*` is excluded like `/proc/*`/`/sys/*`/`/run/*` EXCEPT the handful of
# conventional static device special files a minimal Debian rootfs may bake at
# the ext4 level (POSIX-required nodes, never devtmpfs's live population, which
# the non-recursive bind above never exposes in the first place). These are
# admitted via explicit `--include=` rules placed BEFORE `--exclude-from=` on
# the rsync command line, since a plain `--exclude-from` file cannot itself
# express an include-override.
#
# `dpkg --verify` comparison: "IDENTICAL", not "empty" — the image legitimately
# modifies some conffiles in normal operation, so a clean `dpkg --verify` on a
# healthy system is not necessarily empty. What must be identical is the
# post-mirror OUTPUT on both sides: if rsync faithfully mirrored the content,
# `dpkg --verify` run against each root reports the exact same findings. The
# comparison is filtered through /usr/lib/ceralive/prune-paths.list (todo 29)
# when that file exists; its absence is a safe no-op (compare raw output).
#
# SIGTERM: unmount whatever is mounted, leave the target slot marked BAD (it
# was marked bad at the very start, before anything destructive happened), and
# exit 143. `mark-good` is the LAST thing this script ever does — every other
# exit path, by construction, leaves the target un-confirmed.
#
# This is a standalone DEVICE script: `device-daemon` shell profile (see
# docs/shell-profiles.md) — no `set -e` (every check is evaluated explicitly so
# a single failing probe never aborts a decision the script needs to make about
# WHY it failed), self-contained log()/die(), no dependency on the repo's lib/.
#
# shellcheck shell=bash

set -uo pipefail

PROG="ceralive-slot-sync"

# --- config: overridable for the offline/loop-mounted test harness -----------
LOCK_UPDATE="${CERALIVE_UPDATE_LOCK_PATH:-/run/lock/ceralive-update.lock}"
LOCK_DPKG_FRONTEND="${CERALIVE_DPKG_LOCK_FRONTEND:-/var/lib/dpkg/lock-frontend}"
PARTLABEL_FAILURE="${CERALIVE_PARTLABEL_FAILURE:-/run/ceralive/partlabel-guard.failed}"
DATA_ROOT="${CERALIVE_SLOT_SYNC_DATA_ROOT:-/data}"
UPDATE_STATE_DIR="${CERALIVE_UPDATE_STATE_DIR:-${DATA_ROOT}/ceralive/update-state}"
HEALTHY_STATE_FILE="${CERALIVE_HEALTHY_STATE_FILE:-${UPDATE_STATE_DIR}/healthy-state.json}"
SYNC_RECEIPT_FILE="${CERALIVE_SYNC_RECEIPT_FILE:-${UPDATE_STATE_DIR}/sync-receipt.json}"
RAUC_DATA_DIR="${CERALIVE_RAUC_DATA_DIR:-${DATA_ROOT}/ceralive/rauc}"
SOURCE_MNT="${CERALIVE_SLOT_SYNC_SOURCE:-/run/ceralive/slot-sync/source}"
TARGET_MNT="${CERALIVE_SLOT_SYNC_TARGET:-/run/ceralive/slot-sync/target}"
# The bind-mount SOURCE ROOT — real device: the live "/". Overridable so the
# offline harness can bind a small fixture tree instead of the host's actual
# root filesystem.
BIND_SOURCE_ROOT="${CERALIVE_SLOT_SYNC_BIND_SOURCE:-/}"
EXCLUDE_FILE="${CERALIVE_SLOT_SYNC_EXCLUDE:-/usr/lib/ceralive/slot-sync.exclude}"
PRUNE_PATHS_FILE="${CERALIVE_PRUNE_PATHS_LIST:-/usr/lib/ceralive/prune-paths.list}"
BOOT_ID_FILE="${CERALIVE_HEALTHCHECK_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
DPKG_STATUS_FILE="${CERALIVE_DPKG_STATUS_FILE:-/var/lib/dpkg/status}"
HAWKBIT_SERVICE="${CERALIVE_HAWKBIT_SERVICE:-rauc-hawkbit-updater.service}"
OS_RELEASE_FILE="${CERALIVE_OS_RELEASE_FILE:-/etc/os-release}"
IMAGE_VERSION_FILE="${CERALIVE_IMAGE_VERSION_FILE:-/etc/ceralive/image-build-commit}"

# Test seams: stubbed in the offline proof harness; the real tools on device.
RAUC_BIN="${RAUC_BIN:-rauc}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
BUSCTL_BIN="${CERALIVE_BUSCTL:-busctl}"
DPKG_BIN="${DPKG_BIN:-dpkg}"
RSYNC_BIN="${RSYNC_BIN:-rsync}"
MOUNT_BIN="${MOUNT_BIN:-mount}"
UMOUNT_BIN="${UMOUNT_BIN:-umount}"
E2FSCK_BIN="${E2FSCK_BIN:-e2fsck}"
SYNC_BIN="${SYNC_BIN:-sync}"
SHA256SUM_BIN="${SHA256SUM_BIN:-sha256sum}"

readonly EX_REFUSE=75

ts()   { date -u +%H:%M:%SZ; }
log()  { printf '%s %s: %s\n' "$(ts)" "${PROG}" "$*"; }
fail() { printf '%s %s: FAIL: %s\n' "$(ts)" "${PROG}" "$*" >&2; }

# --- mount bookkeeping (globals so the SIGTERM trap can see them) ------------
TARGET_MOUNTED=0
SOURCE_MOUNTED=0
RSYNC_PID=""
OTHER_SLOT_NAME=""
OTHER_SLOT_DEVICE=""
OTHER_SLOT_OBJECT=""
RAUC_STATUS_JSON=""
RAUC_OPERATION=""
REFUSE_REASON=""
HEALTHY_STATE_BOOT_MATCH=0
HEALTHY_STATE_SHA_MATCH=0
HEALTHY_STATE_BUILD_MATCH=0

cleanup_mounts() {
  if [[ "${SOURCE_MOUNTED}" -eq 1 ]]; then
    "${UMOUNT_BIN}" "${SOURCE_MNT}" 2>/dev/null || true
    SOURCE_MOUNTED=0
  fi
  if [[ "${TARGET_MOUNTED}" -eq 1 ]]; then
    "${UMOUNT_BIN}" "${TARGET_MNT}" 2>/dev/null || true
    TARGET_MOUNTED=0
  fi
}

# die — an OPERATIONAL failure after the gates already passed (mid-rsync, a
# failed mount, a verify mismatch, ...). Always leaves the target slot bad: it
# was marked bad before anything destructive happened, and this path never
# reaches mark-good. Distinct from a pre-flight refusal (exit 75); this exits 1.
die() {
  fail "$*"
  cleanup_mounts
  exit 1
}

on_sigterm() {
  fail "SIGTERM received — aborting; target slot stays bad"
  if [[ -n "${RSYNC_PID}" ]] && kill -0 "${RSYNC_PID}" 2>/dev/null; then
    # `set -m` (below, before launching rsync) makes RSYNC_PID a PROCESS GROUP
    # LEADER, so `-RSYNC_PID` signals the whole group, not just that one PID.
    # This matters because rsync itself forks a generator/sender pair even for
    # a purely local copy: killing only the top-level PID can leave a
    # grandchild running — inheriting, and continuing to hold open, THIS
    # script's own flock'd fd 9/8 — for as long as that grandchild survives.
    kill -TERM -- "-${RSYNC_PID}" 2>/dev/null || kill -TERM "${RSYNC_PID}" 2>/dev/null || true
    wait "${RSYNC_PID}" 2>/dev/null || true
  fi
  cleanup_mounts
  exit 143
}

# --- minimal JSON helpers (no jq on a production image; see lib/fetch/verify.sh
# ::_bsp_json_field for the same flat-field precedent this mirrors) -----------

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
json_bool() { [[ "${1:-0}" -eq 1 ]] && printf 'true' || printf 'false'; }

# _json_flat_field <file> <field> — a flat "field":"value" string out of a
# small, non-nested JSON document (healthy-state.json). Absent/malformed -> "".
_json_flat_field() {
  local file="$1" field="$2"
  [[ -f "${file}" ]] || { printf ''; return 0; }
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "${file}" | head -n1
}

# RAUC emits compact JSON with a slots array of single-key objects. Recursion
# balances arbitrary object depth (including slot_status.bundle on RAUC 1.15);
# quoted strings are atomic so braces in values do not change the depth.
json_slots_array() {
  printf '%s' "$1" | grep -oP '(?(DEFINE)(?<obj>\{(?:[^{}"]|"(?:\\.|[^"\\])*"|(?&obj))*\}))"slots":\K\[(?:(?&obj),?)*\]' 2>/dev/null
}

# json_slot_names <json> — only immediate children of the slots array, not
# object keys nested within a slot (e.g. RAUC 1.15's slot_status.bundle).
json_slot_names() {
  json_slots_array "$1" | grep -oP '(?<=\[|\},)\{"\K[^"]+(?=":\{)' 2>/dev/null
}

# json_slot_object <json> <name> — the COMPLETE slot detail object, even when
# a field contains another nested object. Only search the slots array.
json_slot_object() {
  local json="$1" name="$2" esc
  esc="$(printf '%s' "${name}" | sed 's/[.[$*^\\]/\\&/g')"
  json_slots_array "${json}" | grep -oP "(?(DEFINE)(?<obj>\\{(?:[^{}\"]|\"(?:\\\\.|[^\"\\\\])*\"|(?&obj))*\\}))\\{\"${esc}\":\\K(?&obj)" 2>/dev/null | head -n1
}

# json_field <obj> <field> — a flat string field ANYWHERE inside a slot object
# (works for both top-level slot fields like "device" and
# nested ones like "bundle":{"version":...} — RAUC's field names never repeat
# across that boundary, so an unscoped search is unambiguous in practice).
json_field() {
  local obj="$1" field="$2"
  printf '%s' "${obj}" | grep -oP "\"${field}\":\"\\K[^\"]*" 2>/dev/null | head -n1
}

# json_has_object <obj> <field> — true iff <field> is present as a NESTED
# OBJECT (not merely a string). Used to distinguish "never installed" (no
# "installed" key at all) from "installed but never activated" (has
# "installed", lacks "activated") — exactly RAUC's own readable-formatter rule.
json_has_object() {
  local obj="$1" field="$2"
  printf '%s' "${obj}" | grep -qP "\"${field}\":\\{"
}

rauc_status_json() {
  if [[ -z "${RAUC_STATUS_JSON}" ]]; then
    RAUC_STATUS_JSON="$("${RAUC_BIN}" status --detailed --output-format=json 2>/dev/null)"
  fi
  printf '%s' "${RAUC_STATUS_JSON}"
}

# --- gate 3: RAUC Operation ---------------------------------------------------
rauc_operation_value() {
  local out
  out="$("${BUSCTL_BIN}" get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer Operation 2>/dev/null)" || {
    printf 'unknown'
    return 1
  }
  # busctl prints `s "idle"` for a string property.
  printf '%s' "${out}" | sed -n 's/^s "\(.*\)"$/\1/p'
}

# --- other-slot resolution (never hardcodes a PARTLABEL) ----------------------
# Walks every "rootfs"-class slot rauc status reports and returns the one whose
# state is NOT "booted" — a two-slot A/B setup has exactly one such slot.
resolve_other_rootfs_slot() {
  local json name obj state
  json="$(rauc_status_json)"
  if [[ -z "${json}" ]]; then
    REFUSE_REASON="rauc-status-unavailable"
    return 1
  fi
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    obj="$(json_slot_object "${json}" "${name}")"
    [[ -n "${obj}" ]] || continue
    [[ "$(json_field "${obj}" class)" == "rootfs" ]] || continue
    state="$(json_field "${obj}" state)"
    if [[ "${state}" != "booted" ]]; then
      OTHER_SLOT_NAME="${name}"
      OTHER_SLOT_OBJECT="${obj}"
      OTHER_SLOT_DEVICE="$(json_field "${obj}" device)"
      return 0
    fi
  done < <(json_slot_names "${json}")
  REFUSE_REASON="other-slot-not-found"
  return 1
}

booted_rootfs_slot_object() {
  local json name obj
  json="$(rauc_status_json)"
  [[ -n "${json}" ]] || return 1
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    obj="$(json_slot_object "${json}" "${name}")"
    [[ -n "${obj}" ]] || continue
    if [[ "$(json_field "${obj}" class)" == "rootfs" && "$(json_field "${obj}" state)" == "booted" ]]; then
      printf '%s' "${obj}"
      return 0
    fi
  done < <(json_slot_names "${json}")
  return 1
}

source_bundle_version() {
  local obj
  obj="$(booted_rootfs_slot_object)" || { printf ''; return 0; }
  json_field "${obj}" version
}

# --- gate functions: each sets REFUSE_REASON and returns 1 on refusal --------

gate_partlabel_guard() {
  if [[ -e "${PARTLABEL_FAILURE}" ]]; then
    REFUSE_REASON="partlabel-guard-failed"
    return 1
  fi
  return 0
}

DPKG_AUDIT_OUTPUT=""
gate_dpkg_audit() {
  DPKG_AUDIT_OUTPUT="$("${DPKG_BIN}" --audit 2>&1)"
  if [[ -n "${DPKG_AUDIT_OUTPUT}" ]]; then
    REFUSE_REASON="dpkg-audit-nonempty"
    return 1
  fi
  return 0
}

gate_rauc_idle() {
  RAUC_OPERATION="$(rauc_operation_value)"
  [[ -n "${RAUC_OPERATION}" ]] || RAUC_OPERATION="unknown"
  if [[ "${RAUC_OPERATION}" != "idle" ]]; then
    REFUSE_REASON="rauc-operation-busy"
    return 1
  fi
  return 0
}

gate_other_slot_pending() {
  resolve_other_rootfs_slot || return 1
  if json_has_object "${OTHER_SLOT_OBJECT}" installed && ! json_has_object "${OTHER_SLOT_OBJECT}" activated; then
    REFUSE_REASON="other-slot-pending-activation"
    return 1
  fi
  return 0
}

gate_hawkbit_idle() {
  if "${SYSTEMCTL_BIN}" is-active --quiet "${HAWKBIT_SERVICE}" 2>/dev/null; then
    REFUSE_REASON="hawkbit-updater-active"
    return 1
  fi
  return 0
}

current_boot_id() { cat "${BOOT_ID_FILE}" 2>/dev/null; }

current_dpkg_status_sha256() {
  [[ -r "${DPKG_STATUS_FILE}" ]] || { printf ''; return 0; }
  "${SHA256SUM_BIN}" "${DPKG_STATUS_FILE}" 2>/dev/null | awk '{print $1}'
}

current_build_id() {
  local id=""
  if [[ -r "${OS_RELEASE_FILE}" ]]; then
    id="$(sed -n 's/^BUILD_ID=//p' "${OS_RELEASE_FILE}" | head -n1 | tr -d '"')"
  fi
  if [[ -z "${id}" && -r "${IMAGE_VERSION_FILE}" ]]; then
    id="$(tr -d '\n' <"${IMAGE_VERSION_FILE}" 2>/dev/null)"
  fi
  printf '%s' "${id}"
}

gate_healthy_state() {
  if [[ ! -r "${HEALTHY_STATE_FILE}" ]]; then
    REFUSE_REASON="healthy-state-missing"
    return 1
  fi
  local hs_boot hs_sha hs_build cur_boot cur_sha cur_build
  hs_boot="$(_json_flat_field "${HEALTHY_STATE_FILE}" boot_id)"
  hs_sha="$(_json_flat_field "${HEALTHY_STATE_FILE}" dpkg_status_sha256)"
  hs_build="$(_json_flat_field "${HEALTHY_STATE_FILE}" build_id)"
  cur_boot="$(current_boot_id)"
  cur_sha="$(current_dpkg_status_sha256)"
  cur_build="$(current_build_id)"

  HEALTHY_STATE_BOOT_MATCH=0
  HEALTHY_STATE_SHA_MATCH=0
  HEALTHY_STATE_BUILD_MATCH=0
  [[ -n "${hs_boot}" && "${hs_boot}" == "${cur_boot}" ]] && HEALTHY_STATE_BOOT_MATCH=1
  [[ -n "${hs_sha}" && "${hs_sha}" == "${cur_sha}" ]] && HEALTHY_STATE_SHA_MATCH=1
  [[ -n "${hs_build}" && "${hs_build}" == "${cur_build}" ]] && HEALTHY_STATE_BUILD_MATCH=1

  if [[ "${HEALTHY_STATE_BOOT_MATCH}" -eq 1 && "${HEALTHY_STATE_SHA_MATCH}" -eq 1 && "${HEALTHY_STATE_BUILD_MATCH}" -eq 1 ]]; then
    return 0
  fi
  REFUSE_REASON="healthy-state-mismatch"
  return 1
}

# --- dpkg --verify comparison, filtered through prune-paths.list (todo 29) ---
# Absence of that file is a safe no-op: compare the raw --verify output.
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
        # shellcheck disable=SC2254 # deliberately unquoted: prune-paths.list entries are globs
        case "${path}" in
          ${prune}) keep=0; break ;;
        esac
      done <"${PRUNE_PATHS_FILE}"
    fi
    [[ "${keep}" -eq 1 ]] && printf '%s\n' "${line}"
  done <<<"${out}"
}

# --- adaptive index cleanup (RAUC 1.13 layout: <data-directory>/slot.<name>/
# hash-<digest>/block-hash-index — see r_slot_get_checksum_data_directory /
# hash_index.c upstream). We do not know (and must not guess) the digest a
# future `rauc install` will key its cache under, so every hash-* subdirectory
# for this slot is removed: a missing index is generated on-demand by RAUC,
# which is the documented, safe behaviour for "no cached index available".
delete_adaptive_index() {
  local slot_name="$1" dir hashdir
  dir="${RAUC_DATA_DIR}/slot.${slot_name}"
  if [[ ! -d "${dir}" ]]; then
    log "no adaptive-index directory for slot.${slot_name} (nothing to delete)"
    return 0
  fi
  local removed=0
  for hashdir in "${dir}"/hash-*; do
    [[ -e "${hashdir}" ]] || continue
    rm -rf -- "${hashdir}"
    removed=1
    log "removed stale adaptive index: ${hashdir}"
  done
  [[ "${removed}" -eq 1 ]] || log "no stale adaptive-index entries under ${dir}"
}

write_sync_receipt() {
  local state_sha="$1" target_slot="$2" build_id image_version completed_at tmp
  build_id="$(current_build_id)"
  image_version="$(source_bundle_version)"
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "${UPDATE_STATE_DIR}"
  tmp="${SYNC_RECEIPT_FILE}.tmp.$$"
  cat >"${tmp}" <<EOF
{
  "state_sha256": "$(json_str "${state_sha}")",
  "build_id": "$(json_str "${build_id}")",
  "image_version": "$(json_str "${image_version}")",
  "target_slot": "$(json_str "${target_slot}")",
  "completed_at": "$(json_str "${completed_at}")"
}
EOF
  mv -f "${tmp}" "${SYNC_RECEIPT_FILE}"
}

# ---------------------------------------------------------------------------
# check — print every gate INPUT as JSON. Read-only: no locks, no mounts.
# ---------------------------------------------------------------------------
cmd_check() {
  local partlabel_bad=0 dpkg_bad=0 rauc_bad=0 other_bad=0 hawkbit_bad=0 healthy_bad=0
  local other_installed=0 other_activated=0 first_reason=""

  gate_partlabel_guard || { partlabel_bad=1; [[ -z "${first_reason}" ]] && first_reason="${REFUSE_REASON}"; }
  gate_dpkg_audit || { dpkg_bad=1; [[ -z "${first_reason}" ]] && first_reason="${REFUSE_REASON}"; }
  gate_rauc_idle || { rauc_bad=1; [[ -z "${first_reason}" ]] && first_reason="${REFUSE_REASON}"; }

  if resolve_other_rootfs_slot; then
    json_has_object "${OTHER_SLOT_OBJECT}" installed && other_installed=1
    json_has_object "${OTHER_SLOT_OBJECT}" activated && other_activated=1
    if [[ "${other_installed}" -eq 1 && "${other_activated}" -eq 0 ]]; then
      other_bad=1
      [[ -z "${first_reason}" ]] && first_reason="other-slot-pending-activation"
    fi
  else
    other_bad=1
    [[ -z "${first_reason}" ]] && first_reason="${REFUSE_REASON}"
  fi

  gate_hawkbit_idle || { hawkbit_bad=1; [[ -z "${first_reason}" ]] && first_reason="${REFUSE_REASON}"; }
  gate_healthy_state || { healthy_bad=1; [[ -z "${first_reason}" ]] && first_reason="${REFUSE_REASON}"; }

  local would_refuse=0
  if [[ "${partlabel_bad}" -eq 1 || "${dpkg_bad}" -eq 1 || "${rauc_bad}" -eq 1 || "${other_bad}" -eq 1 || "${hawkbit_bad}" -eq 1 || "${healthy_bad}" -eq 1 ]]; then
    would_refuse=1
  fi

  printf '{'
  printf '"partlabel_guard_failed":%s,' "$(json_bool "${partlabel_bad}")"
  printf '"dpkg_audit_empty":%s,' "$(json_bool $(( dpkg_bad == 0 ? 1 : 0 )))"
  printf '"rauc_operation":"%s",' "$(json_str "${RAUC_OPERATION}")"
  printf '"other_slot":"%s",' "$(json_str "${OTHER_SLOT_NAME}")"
  printf '"other_slot_device":"%s",' "$(json_str "${OTHER_SLOT_DEVICE}")"
  printf '"other_slot_installed":%s,' "$(json_bool "${other_installed}")"
  printf '"other_slot_activated":%s,' "$(json_bool "${other_activated}")"
  printf '"hawkbit_updater_active":%s,' "$(json_bool "${hawkbit_bad}")"
  printf '"healthy_state_boot_id_match":%s,' "$(json_bool "${HEALTHY_STATE_BOOT_MATCH}")"
  printf '"healthy_state_dpkg_sha256_match":%s,' "$(json_bool "${HEALTHY_STATE_SHA_MATCH}")"
  printf '"healthy_state_build_id_match":%s,' "$(json_bool "${HEALTHY_STATE_BUILD_MATCH}")"
  printf '"would_refuse":%s,' "$(json_bool "${would_refuse}")"
  printf '"refuse_reason":"%s"' "$(json_str "${first_reason}")"
  printf '}\n'
  return 0
}

# ---------------------------------------------------------------------------
# run — take both locks, evaluate every gate, mirror on unanimous pass.
# ---------------------------------------------------------------------------
refuse_exit() {
  fail "refuse: ${REFUSE_REASON}"
  exit "${EX_REFUSE}"
}

cmd_run() {
  mkdir -p "$(dirname "${LOCK_UPDATE}")" "$(dirname "${LOCK_DPKG_FRONTEND}")" 2>/dev/null || true

  exec 9>"${LOCK_UPDATE}"
  if ! flock -n -x 9; then
    REFUSE_REASON="update-lock-busy"
    refuse_exit
  fi

  exec 8>"${LOCK_DPKG_FRONTEND}"
  if ! flock -n -x 8; then
    REFUSE_REASON="dpkg-lock-busy"
    refuse_exit
  fi

  log "locks acquired (${LOCK_UPDATE}, ${LOCK_DPKG_FRONTEND}) — evaluating gates"

  gate_partlabel_guard || refuse_exit
  gate_dpkg_audit || refuse_exit
  gate_rauc_idle || refuse_exit
  gate_other_slot_pending || refuse_exit
  gate_hawkbit_idle || refuse_exit
  gate_healthy_state || refuse_exit

  [[ -n "${OTHER_SLOT_DEVICE}" ]] || die "other slot device could not be resolved from rauc status"
  log "all gates passed — mirroring booted slot onto ${OTHER_SLOT_NAME} (${OTHER_SLOT_DEVICE})"

  "${RAUC_BIN}" status mark-bad other >/dev/null || die "rauc status mark-bad other failed"
  log "other slot (${OTHER_SLOT_NAME}) marked bad — beginning destructive mirror"

  # From here on, SIGTERM must unmount and leave the slot bad rather than the
  # shell's default (immediate, no-cleanup) termination.
  trap on_sigterm TERM

  # Stale mounts from a previously killed run are a best-effort clear, not a
  # hard requirement — a genuinely busy mountpoint still fails loudly below.
  "${UMOUNT_BIN}" "${SOURCE_MNT}" 2>/dev/null || true
  "${UMOUNT_BIN}" "${TARGET_MNT}" 2>/dev/null || true

  mkdir -p "${SOURCE_MNT}" "${TARGET_MNT}"

  "${MOUNT_BIN}" -t ext4 -o rw "${OTHER_SLOT_DEVICE}" "${TARGET_MNT}" || die "mount ${OTHER_SLOT_DEVICE} at ${TARGET_MNT} failed"
  TARGET_MOUNTED=1

  # Non-recursive: see the header comment for why this is load-bearing.
  "${MOUNT_BIN}" --bind "${BIND_SOURCE_ROOT}" "${SOURCE_MNT}" || die "bind mount ${BIND_SOURCE_ROOT} at ${SOURCE_MNT} failed"
  SOURCE_MOUNTED=1

  local -a rsync_args=(
    -aHAXS --checksum --numeric-ids --delete
    --include=/dev/ --include=/dev/null --include=/dev/zero
    --include=/dev/console --include=/dev/tty
    --include=/dev/random --include=/dev/urandom
    "--exclude-from=${EXCLUDE_FILE}"
  )
  # `set -m` (job control) makes this background job its OWN process group
  # (pgid == its own PID), so on_sigterm's `-RSYNC_PID` group-kill actually
  # reaches any child rsync itself forks, not just the one PID we captured.
  set -m
  "${RSYNC_BIN}" "${rsync_args[@]}" "${SOURCE_MNT}/" "${TARGET_MNT}/" &
  RSYNC_PID=$!
  set +m
  wait "${RSYNC_PID}"
  local rsync_rc=$?
  RSYNC_PID=""
  [[ "${rsync_rc}" -eq 0 ]] || die "rsync mirror failed (rc=${rsync_rc})"

  "${SYNC_BIN}"

  log "rsync complete — comparing dpkg --verify between source and target"
  local source_verify target_verify
  source_verify="$(dpkg_verify_filtered "${SOURCE_MNT}" | sort)"
  target_verify="$(dpkg_verify_filtered "${TARGET_MNT}" | sort)"
  if [[ "${source_verify}" != "${target_verify}" ]]; then
    fail "dpkg --verify mismatch between source and target after mirror:"
    diff <(printf '%s\n' "${source_verify}") <(printf '%s\n' "${target_verify}") >&2 || true
    die "aborting — target slot stays bad"
  fi
  log "dpkg --verify comparison identical"

  local state_sha256
  state_sha256="$(current_dpkg_status_sha256)"

  "${UMOUNT_BIN}" "${SOURCE_MNT}" || die "unmount ${SOURCE_MNT} failed"
  SOURCE_MOUNTED=0
  "${UMOUNT_BIN}" "${TARGET_MNT}" || die "unmount ${TARGET_MNT} failed"
  TARGET_MOUNTED=0

  "${E2FSCK_BIN}" -fn "${OTHER_SLOT_DEVICE}"
  local fsck_rc=$?
  [[ "${fsck_rc}" -eq 0 ]] || die "e2fsck -fn ${OTHER_SLOT_DEVICE} reported errors (rc=${fsck_rc})"
  log "e2fsck -fn clean"

  delete_adaptive_index "${OTHER_SLOT_NAME}"

  write_sync_receipt "${state_sha256}" "${OTHER_SLOT_NAME}"
  log "wrote sync receipt: ${SYNC_RECEIPT_FILE}"

  "${RAUC_BIN}" status mark-good other >/dev/null || die "rauc status mark-good other failed"
  log "slot-sync complete: ${OTHER_SLOT_NAME} mirrored and marked good"
  return 0
}

main() {
  case "${1:-}" in
    check) cmd_check ;;
    run) cmd_run ;;
    *)
      printf 'usage: %s check|run\n' "${PROG}" >&2
      exit 2
      ;;
  esac
}

main "$@"
