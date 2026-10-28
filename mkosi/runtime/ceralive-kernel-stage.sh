#!/bin/bash
# Device transaction: the caller owns the update flock; this script proves it.
# No -e: every failure must reach fail-closed slot/state bookkeeping.
# shellcheck shell=bash
# allow: SIZE_OK - one device transaction owns the write-ahead and mount lifetime.
set -uo pipefail

# Reuse slot-sync's exact six gates, identity readers and COPY/VERIFY library.
# Sourcing does not run its CLI or acquire either lock.
# shellcheck source=mkosi/runtime/ceralive-slot-sync.sh
source "${CERALIVE_SLOT_SYNC_LIB:-/usr/libexec/ceralive/ceralive-slot-sync}"
# shellcheck source=mkosi/runtime/ceralive-kernel-state-lib.sh
source "${CERALIVE_KERNEL_STATE_LIB:-/usr/lib/ceralive/ceralive-kernel-state-lib.sh}"
# shellcheck source=lib/shared/slot-reserve.sh
source "${CERALIVE_SLOT_RESERVE_LIB:-/usr/lib/ceralive/slot-reserve.sh}"

PROG=ceralive-kernel-stage
SOURCE_MNT="${CERALIVE_KERNEL_STAGE_SOURCE:-/run/ceralive/kernel-stage/source}"
TARGET_MNT="${CERALIVE_KERNEL_STAGE_TARGET:-/run/ceralive/kernel-stage/target}"
CAPABILITIES="${CERALIVE_UPDATE_CAPABILITIES:-/usr/lib/ceralive/update-capabilities.json}"
BOARD_BOOT="${CERALIVE_BOARD_BOOT:-/usr/lib/ceralive/board-boot.json}"
STATE="${UPDATE_STATE_DIR}/kernel-state.json"
ARMED="${CERALIVE_ACTIVATION_STATE_DIR:-${UPDATE_STATE_DIR}}/activation-armed"
BOOT_STAGING="${CERALIVE_KERNEL_BOOT_STAGING:-/usr/lib/ceralive/ceralive-kernel-boot-staging}"
BOOT_VERIFY="${CERALIVE_KERNEL_BOOT_VERIFY:-/usr/lib/ceralive/verify-boot-artifacts.sh}"
CHROOT_BIN="${CHROOT_BIN:-chroot}"
COMMAND_TIMEOUT="${CERALIVE_KERNEL_STAGE_COMMAND_TIMEOUT:-600}"
ATTEMPT="" DEB="" PACKAGE="" VERSION="" DEB_SHA="" RELEASE=""
BOOTED_SLOT="" BOOTED_NAME="" BOOTED_SLOT_OBJECT="" TARGET_NAME="" OVERLAY="" BASE_IDENTITY=""
declare -A STATE_TIMESTAMPS=()
TRANSACTION=0 COMMITTED=0
CHILD_MOUNTS=()

log() { printf '%s: %s\n' "${PROG}" "$*" >&2; }

write_state() {
  local state="$1" reason="$2" now reason_json fields="" phase
  case "${state}" in staging|staged|armed|activating|activated|succeeded|rolled_back|failed) ;; *) return 1 ;; esac
  reason_json="$(kernel_reason_json "${reason}")" || return 1
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  STATE_TIMESTAMPS["${state}"]="${now}"
  for phase in staging staged armed activating activated succeeded rolled_back failed; do
    [[ -n "${STATE_TIMESTAMPS[${phase}]:-}" ]] || continue
    fields+="${fields:+,}\"${phase}\":\"${STATE_TIMESTAMPS[${phase}]}\""
  done
  kernel_atomic_write "${STATE}" "$(printf '{"schema":1,"attempt":"%s","package":"%s","version":"%s","deb_sha256":"%s","target_slot":"%s","booted_slot_at_stage":"%s","boot_id_at_activation":null,"state":"%s","reason":%s,"timestamps":{%s}}' \
    "${ATTEMPT}" "${PACKAGE}" "${VERSION}" "${DEB_SHA}" "${TARGET_NAME}" "${BOOTED_NAME}" \
    "${state}" "${reason_json}" "${fields}")"
}

write_invalid_overlay() {
  kernel_atomic_write "${OVERLAY}" "$(printf '{"status":"invalid","attempt":"%s","reason":"kernel_staging"}' \
    "${ATTEMPT}")"
}

load_state_timestamps() {
  local object member pattern compact entry phase stamp
  local -a entries=()
  object="$(kernel_json_object "$(<"${STATE}")" timestamps)" || return 1
  member='"(staging|staged|armed|activating|activated|succeeded|rolled_back|failed)"[[:space:]]*:[[:space:]]*"[0-9TZ:.+-]+"'
  pattern="^\\{[[:space:]]*(${member}([[:space:]]*,[[:space:]]*${member})*)?[[:space:]]*\\}$"
  [[ "${object}" =~ ${pattern} ]] || return 1
  compact="${object//[[:space:]]/}"
  compact="${compact#\{}"; compact="${compact%\}}"
  STATE_TIMESTAMPS=()
  [[ -n "${compact}" ]] || return 0
  IFS=, read -r -a entries <<<"${compact}"
  for entry in "${entries[@]}"; do
    entry="${entry//\"/}"
    phase="${entry%%:*}"; stamp="${entry#*:}"
    kernel_utc_timestamp_valid "${stamp}" || return 1
    [[ -z "${STATE_TIMESTAMPS[${phase}]:-}" ]] || return 1
    STATE_TIMESTAMPS["${phase}"]="${stamp}"
  done
}

capture_base_identity() {
  local status bundle checksum installed hash digest stamp count
  [[ "${BOOTED_SLOT}" =~ ^rootfs[.][0-9]+$ ]] || return 1
  status="$(kernel_json_object "${BOOTED_SLOT_OBJECT}" slot_status)" || return 1
  bundle="$(kernel_json_object "${status}" bundle)" || return 1
  checksum="$(kernel_json_object "${status}" checksum)" || return 1
  installed="$(kernel_json_object "${status}" installed)" || return 1
  hash="$(kernel_json_string "${bundle}" hash)"
  digest="$(kernel_json_string "${checksum}" sha256)"
  stamp="$(kernel_json_string "${installed}" timestamp)"
  count="$(printf '%s' "${installed}" | grep -oP '"count"[[:space:]]*:[[:space:]]*\K[0-9]+(?=[[:space:]]*[,}])')" || return 1
  [[ "${hash}" =~ ^[a-f0-9]{64}$ && "${digest}" =~ ^[a-f0-9]{64}$ &&
     "${count}" =~ ^[1-9][0-9]{0,14}$ ]] || return 1
  kernel_utc_timestamp_valid "${stamp}" || return 1
  BASE_IDENTITY="$(printf '{"slot":"%s","bundleHash":"%s","checksum":"%s","installedAt":"%s","installedCount":%s}' \
    "${BOOTED_SLOT}" "${hash}" "${digest}" "${stamp}" "${count}")"
}

stage_cleanup_children() {
  local i rc=0
  for ((i=${#CHILD_MOUNTS[@]}-1; i>=0; i--)); do
    stage_worker "${UMOUNT_BIN}" "${CHILD_MOUNTS[i]}" || rc=1
  done
  CHILD_MOUNTS=()
  return "${rc}"
}

stage_cleanup_mounts() {
  local rc=0
  stage_cleanup_children || rc=1
  if [[ "${SOURCE_MOUNTED}" -eq 1 ]]; then
    stage_worker "${UMOUNT_BIN}" "${SOURCE_MNT}" || rc=1
    SOURCE_MOUNTED=0
  fi
  if [[ "${TARGET_MOUNTED}" -eq 1 ]]; then
    stage_worker "${UMOUNT_BIN}" "${TARGET_MNT}" || rc=1
    TARGET_MOUNTED=0
  fi
  return "${rc}"
}

stage_exit() {
  local rc=$?
  trap - EXIT TERM INT
  if [[ -n "${WORKER_PID}" ]]; then
    kill -TERM -- "-${WORKER_PID}" 2>/dev/null || true
    wait "${WORKER_PID}" 2>/dev/null || true
  fi
  stage_cleanup_mounts || rc=75
  if [[ "${TRANSACTION}" -eq 1 && "${COMMITTED}" -eq 0 ]]; then
    "${RAUC_BIN}" status mark-bad other >/dev/null || log "mark-bad failed"
    write_invalid_overlay || log "invalid overlay persistence failed"
    write_state failed "${REFUSE_REASON:-kernel_staging_failed}" || log "failed-state persistence failed"
    rc=75
  fi
  exit "${rc}"
}

die() {
  log "$*"
  REFUSE_REASON="$*"
  kernel_reason_json "${REFUSE_REASON}" >/dev/null || REFUSE_REASON=kernel_staging_failed
  exit 75
}

# A bounded worker group makes TERM reach dpkg/mount/fsck children as well.
stage_worker() {
  local rc
  set -m
  timeout --kill-after=10 "${COMMAND_TIMEOUT}" "$@" &
  WORKER_PID=$!
  set +m
  wait "${WORKER_PID}"
  rc=$?
  WORKER_PID=""
  return "${rc}"
}

prove_update_lock() {
  local fd major minor ino identity found=0
  [[ -f "${LOCK_UPDATE}" ]] || return 1
  read -r major minor ino < <(stat -Lc '%Hd %Ld %i' "${LOCK_UPDATE}") || return 1
  printf -v identity '%02x:%02x:%s' "${major}" "${minor}" "${ino}"
  for fd in /proc/$$/fd/*; do
    [[ "$(readlink -f "${fd}")" == "$(readlink -f "${LOCK_UPDATE}")" ]] || continue
    [[ "$(stat -Lc '%d:%i' "${fd}")" == "$(stat -Lc '%d:%i' "${LOCK_UPDATE}")" ]] || continue
    found=1
    break
  done
  [[ "${found}" -eq 1 ]] || return 1
  awk -v pid="${PPID}" -v inode="${identity}" '
    $2=="FLOCK" && $3=="ADVISORY" && $4=="WRITE" && $5==pid && $6==inode && $7=="0" && $8=="EOF" {owned=1}
    END {exit !owned}
  ' /proc/locks
}

validate_deb() {
  local deb="$1" control
  [[ -f "${deb}" && ! -L "${deb}" ]] || return 1
  [[ "$("${SHA256SUM_BIN}" "${deb}" | awk '{print $1}')" == "${DEB_SHA}" ]] || return 1
  control="$(dpkg-deb -f "${deb}" Package Version Architecture)" || return 1
  [[ "${control}" == "$(printf 'Package: %s\nVersion: %s\nArchitecture: arm64' "${PACKAGE}" "${VERSION}")" ]]
}

resolve_stage_slots() {
  local json name obj primary count=0
  json="$(rauc_status_json)"
  primary="$(json_field "${json}" boot_primary)"
  resolve_other_rootfs_slot || die "${REFUSE_REASON}"
  while IFS= read -r name; do
    obj="$(json_slot_object "${json}" "${name}")"
    [[ "$(json_field "${obj}" class)" == rootfs ]] || continue
    count=$((count+1))
    if [[ "$(json_field "${obj}" state)" == booted ]]; then
      BOOTED_SLOT="${name}"
      BOOTED_NAME="$(json_field "${obj}" bootname)"
      BOOTED_SLOT_OBJECT="${obj}"
    fi
  done < <(json_slot_names "${json}")
  TARGET_NAME="$(json_field "${OTHER_SLOT_OBJECT}" bootname)"
  [[ "${count}" -eq 2 && "${BOOTED_NAME}" =~ ^[AB]$ && "${TARGET_NAME}" =~ ^[AB]$ &&
     "${TARGET_NAME}" != "${BOOTED_NAME}" && "${BOOTED_SLOT}" == "${primary}" ]] || die boot_primary_mismatch
  [[ "$(json_field "${OTHER_SLOT_OBJECT}" state)" == inactive ]] || die target_not_inactive
  # Resolve through RAUC's configured PARTLABEL, not a guessed block partition.
  [[ "${OTHER_SLOT_DEVICE}" == "${CERALIVE_PARTLABEL_DIR:-/dev/disk/by-partlabel}/${OTHER_SLOT_DEVICE##*/}" &&
     "${OTHER_SLOT_DEVICE##*/}" =~ ^[a-zA-Z0-9_-]+$ ]] || die target_partlabel_invalid
  [[ "$(readlink -f "${OTHER_SLOT_DEVICE}")" != "$(readlink -f "$(json_field "$(booted_rootfs_slot_object)" device)")" ]] \
    || die target_is_booted
  OVERLAY="${UPDATE_STATE_DIR}/slot-overlay-${TARGET_NAME}.json"
}

recover_staging() {
  [[ "$(kernel_json_field "${STATE}" state)" == staging ]] || return 0
  # Do not let a new request replace the old interrupted attempt's identity.
  [[ "$(kernel_json_field "${STATE}" target_slot)" == "${TARGET_NAME}" &&
     "$(kernel_json_field "${STATE}" booted_slot_at_stage)" == "${BOOTED_NAME}" ]] || {
    log interrupted_target_mismatch
    die kernel_identity_mismatch
  }
  ATTEMPT="$(kernel_json_field "${STATE}" attempt)"
  PACKAGE="$(kernel_json_field "${STATE}" package)"
  VERSION="$(kernel_json_field "${STATE}" version)"
  DEB_SHA="$(kernel_json_field "${STATE}" deb_sha256)"
  kernel_uuid_valid "${ATTEMPT}" || die interrupted_state_invalid
  [[ "${PACKAGE}" =~ ^linux-image-[0-9]+[.][0-9]+[.][0-9]+-ceralive-rk3588$ &&
     "${VERSION}" =~ ^[0-9]+[.][0-9]+[.][0-9]+-ceralive[0-9]+$ && "${DEB_SHA}" =~ ^[0-9a-f]{64}$ ]] \
    || die interrupted_state_invalid
  load_state_timestamps || { log interrupted_timestamps_invalid; die kernel_identity_mismatch; }
  TRANSACTION=1
  clear_stale_mounts
  die kernel_interrupted
}

clear_stale_mounts() {
  local path
  for path in /run /dev/pts /dev /sys /proc; do
    stage_worker "${UMOUNT_BIN}" "${TARGET_MNT}${path}" 2>/dev/null || true
  done
  stage_worker "${UMOUNT_BIN}" "${SOURCE_MNT}" 2>/dev/null || true
  stage_worker "${UMOUNT_BIN}" "${TARGET_MNT}" 2>/dev/null || true
}

assert_unmounted() {
  local mounts rc
  mounts="$("${FINDMNT_BIN}" -rn -o TARGET)" || die mount_table_unavailable
  while IFS= read -r path; do
    [[ "${path}" != "${TARGET_MNT}" && "${path}" != "${TARGET_MNT}/"* &&
       "${path}" != "${SOURCE_MNT}" && "${path}" != "${SOURCE_MNT}/"* ]] || die target_still_mounted
  done <<<"${mounts}"
  "${FINDMNT_BIN}" -rn -S "${OTHER_SLOT_DEVICE}" >/dev/null
  rc=$?
  [[ "${rc}" -eq 1 ]] || die target_device_mounted
}

mount_child() {
  local path="$1"; shift
  stage_worker "${MOUNT_BIN}" "$@" "${TARGET_MNT}${path}" || die child_mount_failed
  CHILD_MOUNTS+=("${TARGET_MNT}${path}")
}

stage_main() {
  [[ "$(id -u)" -eq 0 ]] || die root_required
  prove_update_lock || die update_lock_not_owned
  [[ "${COMMAND_TIMEOUT}" =~ ^[1-9][0-9]{0,3}$ ]] || die invalid_timeout
  exec 8>"${LOCK_DPKG_FRONTEND}" || die dpkg_lock_unavailable
  flock -n -x 8 || die dpkg_lock_busy
  resolve_stage_slots
  recover_staging
  [[ "${1:-}" != --recover ]] || return 0
  while (($#)); do
    [[ $# -ge 2 ]] || die invalid_arguments
    case "$1" in
      --attempt) ATTEMPT="$2" ;; --deb) DEB="$2" ;; --package) PACKAGE="$2" ;;
      --version) VERSION="$2" ;; --sha256) DEB_SHA="$2" ;; *) die invalid_arguments ;;
    esac
    shift 2
  done
  kernel_uuid_valid "${ATTEMPT}" || die invalid_arguments
  [[ "${PACKAGE}" =~ ^linux-image-[0-9]+[.][0-9]+[.][0-9]+-ceralive-rk3588$ &&
     "${DEB_SHA}" =~ ^[0-9a-f]{64}$ ]] || die invalid_arguments
  RELEASE="${PACKAGE#linux-image-}"
  [[ "${VERSION}" =~ ^[0-9]+[.][0-9]+[.][0-9]+-ceralive[1-9][0-9]*$ &&
     "${VERSION%-ceralive*}" == "${RELEASE%-ceralive-rk3588}" ]] || die invalid_version
  local board_regex dtb size count listing available total free block_size required
  board_regex="$(kernel_json_field "${BOARD_BOOT}" kernel_package_regex)"
  dtb="$(kernel_json_field "${BOARD_BOOT}" dtb_name)"
  [[ "${board_regex}" == ^*\$ && "${PACKAGE}" =~ ${board_regex} &&
     "${dtb}" =~ ^[a-zA-Z0-9_-]+[.]dtb$ ]] || die board_identity_invalid
  validate_deb "${DEB}" || die kernel_origin_mismatch
  size="$(dpkg-deb -f "${DEB}" Installed-Size)" || die invalid_deb
  [[ "${size}" =~ ^[1-9][0-9]{0,8}$ ]] || die invalid_installed_size
  listing="$(dpkg-deb --fsys-tarfile "${DEB}" | tar -tf -)" || die invalid_deb
  count="$(printf '%s\n' "${listing}" | wc -l)"
  [[ -r "${CAPABILITIES}" ]] && grep -q '"kernel-apt-stage"' "${CAPABILITIES}" || die capability_missing
  [[ ! -e "${ARMED}" ]] || die activation_armed
  case "$(kernel_json_field "${STATE}" state)" in
    staging|staged|armed|activating|activated) die kernel_staged_pending ;;
  esac
  gate_partlabel_guard || die "${REFUSE_REASON}"
  gate_dpkg_audit || die "${REFUSE_REASON}"
  gate_rauc_idle || die "${REFUSE_REASON}"
  gate_other_slot_pending || die "${REFUSE_REASON}"
  gate_hawkbit_idle || die "${REFUSE_REASON}"
  gate_healthy_state || die "${REFUSE_REASON}"
  [[ "$(kernel_json_field "${HEALTHY_STATE_FILE}" slot)" == "${BOOTED_NAME}" ||
     "$(kernel_json_field "${HEALTHY_STATE_FILE}" slot)" == "${BOOTED_SLOT}" ]] || die healthy_slot_mismatch
  capture_base_identity || { log booted_rauc_byte_identity_unavailable; die kernel_identity_mismatch; }

  mkdir -p "${UPDATE_STATE_DIR}" || die state_directory_failed
  STATE_TIMESTAMPS=()
  TRANSACTION=1
  write_state staging "" || die staging_state_failed
  "${RAUC_BIN}" status mark-bad other >/dev/null || die mark_bad_failed
  rm -f -- "${SYNC_RECEIPT_FILE}" || die receipt_retirement_failed
  delete_adaptive_index "${OTHER_SLOT_NAME}" || die index_retirement_failed
  if [[ -d "${RAUC_DATA_DIR}/slot.${OTHER_SLOT_NAME}" ]]; then
    "${SYNC_BIN}" "${RAUC_DATA_DIR}/slot.${OTHER_SLOT_NAME}" || die index_retirement_sync_failed
  fi
  write_invalid_overlay || die overlay_invalidation_failed
  "${SYNC_BIN}" "${UPDATE_STATE_DIR}" || die retirement_sync_failed

  # Clear every owned mount from a killed attempt before repairing the target.
  clear_stale_mounts
  assert_unmounted
  stage_worker "${E2FSCK_BIN}" -fy "${OTHER_SLOT_DEVICE}"
  local repair_rc=$?
  [[ "${repair_rc}" -le 1 ]] || die target_repair_failed
  mkdir -p "${SOURCE_MNT}" "${TARGET_MNT}" || die mount_directory_failed
  stage_worker "${MOUNT_BIN}" -t ext4 -o rw "${OTHER_SLOT_DEVICE}" "${TARGET_MNT}" || die target_mount_failed
  TARGET_MOUNTED=1
  stage_worker "${MOUNT_BIN}" --bind "${BIND_SOURCE_ROOT}" "${SOURCE_MNT}" || die source_mount_failed
  SOURCE_MOUNTED=1
  slot_mirror_copy_verify -aHAXS --checksum --numeric-ids --delete \
    --include=/dev/ --include=/dev/null --include=/dev/zero --include=/dev/console \
    --include=/dev/tty --include=/dev/random --include=/dev/urandom "--exclude-from=${EXCLUDE_FILE}"
  read -r available block_size total free < <(stat -f -c '%a %S %c %d' "${TARGET_MNT}")
  for required in "${available}" "${block_size}" "${total}" "${free}"; do
    [[ "${required}" =~ ^[0-9]{1,15}$ ]] || die capacity_unknown
  done
  required=$(( (total+9)/10 )); (( required >= 20000 )) || required=20000
  (( available*block_size >= size*1024*2+536870912 )) || die insufficient_bavail
  (( free >= required+count )) || die insufficient_inodes
  local cache=/var/cache/ceralive-kernel-stage/candidate.deb
  mkdir -p "${TARGET_MNT}${cache%/*}" || die cache_directory_failed
  cp -- "${DEB}" "${TARGET_MNT}${cache}" || die package_copy_failed
  validate_deb "${TARGET_MNT}${cache}" || die kernel_origin_mismatch
  mount_child /proc --bind /proc
  mount_child /sys --bind /sys
  mount_child /dev --bind /dev
  mount_child /dev/pts --bind /dev/pts
  mount_child /run -t tmpfs -o mode=0755,nosuid,nodev tmpfs
  stage_worker "${CHROOT_BIN}" "${TARGET_MNT}" /bin/bash -s -- "${PACKAGE}" "${VERSION}" "${cache}" <<'CHROOT' || die dpkg_install_failed
set -euo pipefail
package="$1" version="$2" cache="$3"
export DEBIAN_FRONTEND=noninteractive SYSTEMD_OFFLINE=1
dpkg -i "${cache}"
installed="$(dpkg-query -W -f='${Package} ${db:Status-Status}\n')"
while read -r old status; do
  [[ "${old}" =~ ^linux-image-[0-9]+[.][0-9]+[.][0-9]+-ceralive-rk3588$ ]] || continue
  [[ "${old}" != "${package}" && "${status}" == installed ]] || continue
  apt-mark unhold "${old}"
  dpkg --purge "${old}"
done <<<"${installed}"
pref=/etc/apt/preferences.d/ceralive-kernel-freeze
[[ -f "${pref}" && ! -L "${pref}" ]]
awk 'BEGIN {RS=""; ORS="\n\n"} !/Package: linux-image-[0-9]+[.][0-9]+[.][0-9]+-ceralive-rk3588([ \n]|$)/ {print}' "${pref}" >"${pref}.new"
printf 'Package: %s\nPin: version %s\nPin-Priority: 1001\n' "${package}" "${version}" >>"${pref}.new"
chmod 0644 "${pref}.new"
mv -f "${pref}.new" "${pref}"
apt-mark hold "${package}"
holds="$(apt-mark showhold)"
grep -qxF "${package}" <<<"${holds}"
[[ "$(dpkg-query -W -f='${Version}' "${package}")" == "${version}" ]]
/usr/libexec/ceralive/ceralive-reprune
audit="$(dpkg --audit)"
[[ -z "${audit}" ]]
rm -f -- "${cache}"
CHROOT
  # The root-directory verifier indexes the tree: never let it walk live /proc.
  stage_cleanup_children || die unmount_failed
  stage_worker "${BOOT_STAGING}" "${TARGET_MNT}" --kernel-release "${RELEASE}" || die boot_staging_failed
  stage_worker "${BOOT_VERIFY}" --root-dir "${TARGET_MNT}" --dtb-name "${dtb}" || die boot_verification_failed
  stage_worker "${BOOT_STAGING}" firmware-check "${TARGET_MNT}" --kernel-release "${RELEASE}" \
    --firmware-root "${TARGET_MNT}/lib/firmware" || die firmware_missing
  stage_cleanup_mounts || die unmount_failed
  assert_unmounted
  slot_reserve_assert_ext4 "${OTHER_SLOT_DEVICE}" "${OTHER_SLOT_NAME}" || die slot_reserve_failed
  stage_worker "${E2FSCK_BIN}" -fn "${OTHER_SLOT_DEVICE}" || die final_fsck_failed

  # Eligibility is ordered: overlay, mark-good, staged (the commit point).
  kernel_atomic_write "${OVERLAY}" "$(printf '{"base_bundle_identity":%s,"kernel":{"package":"%s","version":"%s","deb_sha256":"%s"},"attempt":"%s","status":"pending","reason":null}' \
    "${BASE_IDENTITY}" \
    "${PACKAGE}" "${VERSION}" "${DEB_SHA}" "${ATTEMPT}")" || die pending_overlay_failed
  "${RAUC_BIN}" status mark-good other >/dev/null || die mark_good_failed
  write_state staged "" || die staged_state_failed
  COMMITTED=1
}

trap stage_exit EXIT
trap 'die kernel_interrupted' TERM INT
stage_main "$@"
