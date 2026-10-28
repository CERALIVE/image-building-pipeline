#!/bin/bash
# Command boundary stubs, not a second implementation of the transaction.
set -uo pipefail
tool="${0##*/}"
event() { printf '%s\n' "$*" >>"${FIXTURE}/events"; }
checkpoint() {
  if [[ "${KILL_AT:-}" == "$1" ]]; then
    kill -KILL "${STAGE_PID}"
    exit 0
  fi
}
field() { jq -r ".$2" "$1"; }
target_slot() {
  jq -r '.slots[] | to_entries[] | select(.value.class=="rootfs" and .value.state=="inactive") | .key' "${FIXTURE}/rauc.json"
}
target_overlay() {
  local bootname
  bootname="$(jq -r '.slots[] | to_entries[] | select(.value.class=="rootfs" and .value.state=="inactive") | .value.bootname' "${FIXTURE}/rauc.json")"
  printf '%s/state/slot-overlay-%s.json' "${FIXTURE}" "${bootname}"
}
if [[ "${HANG_TOOL:-}" == "${tool}" ]]; then
  event "hung ${tool}"
  IFS= read -r _ <"${HANG_FIFO}"
fi
case "${tool}" in
  id) printf '%s\n' "${UID_FIXTURE:-0}" ;;
  rauc)
    event "rauc $*"
    case "$*" in
      'status --detailed --output-format=json') cat "${FIXTURE}/rauc.json" ;;
      'status mark-bad other')
        [[ -f "${FIXTURE}/state/kernel-state.json" ]] || exit 9
        [[ "${FAIL_TOOL:-}" != mark-bad ]] || exit 1
        printf bad >"${FIXTURE}/eligibility" ;;
      'status mark-good other')
        [[ "$(field "${FIXTURE}/state/kernel-state.json" state)" == staging &&
           "$(field "$(target_overlay)" status)" == pending &&
           ! -s "${FIXTURE}/mounts" ]] || exit 9
        [[ "${FAIL_TOOL:-}" != mark-good ]] || exit 1
        printf good >"${FIXTURE}/eligibility"
        checkpoint after_mark_good ;;
      *) exit 2 ;;
    esac ;;
  busctl) printf 's "%s"\n' "${TEST_RAUC_OPERATION:-idle}" ;;
  systemctl) [[ "${HAWKBIT_ACTIVE:-0}" == 1 ]] && exit 0; exit 3 ;;
  dpkg)
    case "$*" in
      --audit) printf '%s' "${AUDIT_OUTPUT:-}" ;;
      *--verify*) [[ "${VERIFY_MISMATCH:-0}" != 1 || "$1" != *target* ]] || printf '??5 /etc/wrong\n' ;;
      *) exit 2 ;;
    esac ;;
  stat)
    if [[ "$1" == -f ]]; then
      [[ "$2" == -c ]] || exit 2
      # Reserved blocks belong to root-free (%f), never unprivileged bavail (%a).
      first=""
      for format in $3; do
        printf '%s' "${first}"; first=" "
        case "${format}" in
          %a) printf '%s' "${CAPACITY_AVAILABLE:-300000}" ;;
          %f) printf '%s' "${CAPACITY_ROOT_FREE:-400000}" ;;
          %S) printf 4096 ;;
          %c) printf '%s' "${CAPACITY_TOTAL:-300000}" ;;
          %d) printf '%s' "${CAPACITY_FREE:-100000}" ;;
          *) exit 2 ;;
        esac
      done
      printf '\n'
    else exec /usr/bin/stat "$@"; fi ;;
  cp)
    /usr/bin/cp "$@" || exit 1
    if [[ "${TAMPER_CACHED_DEB:-0}" == 1 &&
          "${!#}" == "${CERALIVE_KERNEL_STAGE_TARGET}/var/cache/ceralive-kernel-stage/candidate.deb" ]]; then
      printf 'damaged after source validation\n' >>"${!#}"
    fi ;;
  mount)
    event "mount $*"
    [[ "${FAIL_TOOL:-}" != mount ]] || exit 1
    destination="${!#}"
    printf '%s\n' "${destination}" >>"${FIXTURE}/mounts"
    if [[ "${destination}" == "${CERALIVE_KERNEL_STAGE_SOURCE}" ]]; then
      /usr/bin/rsync -a --delete "${FIXTURE}/booted/" "${destination}/"
    fi ;;
  umount)
    event "umount $*"
    [[ "${FAIL_TOOL:-}" != umount ]] || exit 1
    awk -v path="$1" '$0!=path' "${FIXTURE}/mounts" >"${FIXTURE}/mounts.new"
    mv "${FIXTURE}/mounts.new" "${FIXTURE}/mounts" ;;
  findmnt)
    event "findmnt $*"
    [[ "${MOUNT_TABLE_ERROR:-0}" != 1 ]] || exit 2
    if [[ "$*" == '-rn -o TARGET' ]]; then
      cat "${FIXTURE}/mounts"
      [[ "${FINAL_MOUNT_LEAK:-0}" != 1 || ! -e "${FIXTURE}/installed" ]] \
        || printf '%s/run\n' "${CERALIVE_KERNEL_STAGE_TARGET}"
    else [[ ! -s "${FIXTURE}/mounts" ]]; [[ ! -s "${FIXTURE}/mounts" ]] && exit 1; exit 0; fi ;;
  e2fsck)
    event "fsck $*"
    [[ ! -s "${FIXTURE}/mounts" ]] || exit 9
    [[ "${FAIL_TOOL:-}" != fsck && ( "$1" != -fn || "${FAIL_TOOL:-}" != final-fsck ) ]] || exit 4 ;;
  rsync)
    event mirror
    [[ "$(field "${FIXTURE}/state/kernel-state.json" state)" == staging &&
       "$(<"${FIXTURE}/eligibility")" == bad &&
       ! -e "${CERALIVE_SYNC_RECEIPT_FILE}" &&
       ! -d "${FIXTURE}/rauc-data/slot.$(target_slot)/hash-old" &&
       "$(field "$(target_overlay)" status)" == invalid ]] || exit 9
    checkpoint mirror
    [[ "${FAIL_TOOL:-}" != mirror ]] || exit 1
    exec /usr/bin/rsync "$@" ;;
  chroot)
    event dpkg
    cat >"${FIXTURE}/chroot-script"
    checkpoint dpkg
    [[ "${FAIL_TOOL:-}" != dpkg ]] || exit 1
    dpkg-deb -x "$1/var/cache/ceralive-kernel-stage/candidate.deb" "$1" || exit 1
    touch "${FIXTURE}/installed"
    rm -f "$1/var/cache/ceralive-kernel-stage/candidate.deb" ;;
  boot-staging)
    event "boot $*"
    if [[ "${1:-}" == firmware-check ]]; then
      [[ "$#" -eq 6 && "$3" == --kernel-release && "$5" == --firmware-root &&
         "$6" == "${CERALIVE_KERNEL_STAGE_TARGET}/lib/firmware" ]] || exit 2
      case "${FIRMWARE_RC:-0}" in 1) printf 'missing: vendor/blob.bin\n' >&2; exit 1 ;; 2) exit 2 ;; esac
    else [[ "${FAIL_TOOL:-}" != boot-staging ]] || exit 1; fi ;;
  boot-verify)
    event "verify $*"
    [[ "$#" -eq 4 && "$1" == --root-dir && "$3" == --dtb-name ]] || exit 2
    ! grep -qF "${CERALIVE_KERNEL_STAGE_TARGET}/" "${FIXTURE}/mounts" || exit 9
    [[ "${FAIL_TOOL:-}" != boot-verify ]] || exit 1 ;;
  dumpe2fs)
    event reserve
    [[ ! -s "${FIXTURE}/mounts" ]] || exit 9
    cat <<EOF
Filesystem magic number: 0xEF53
Filesystem state: clean
Filesystem features: extent
Block count: 1000000
Free blocks: 800000
Reserved block count: 10000
Block size: 4096
Inode count: 300000
Free inodes: ${CAPACITY_FINAL_FREE:-100000}
EOF
    ;;
  sync)
    event "sync $*"
    [[ -z "${FAIL_SYNC:-}" || "${FAIL_SYNC}" != "${1:-}" ]] || exit 1
    if [[ "${1:-}" == *slot-overlay-?.json.tmp.* ]] && grep -q '"status":"pending"' "$1"; then
      [[ "${FAIL_TOOL:-}" != pending-sync ]] || exit 1
    fi
    if [[ "${1:-}" == "${FIXTURE}/state" && -f "$(target_overlay)" ]] &&
      [[ "$(field "$(target_overlay)" status)" == pending ]]; then
      checkpoint after_overlay
    fi
    if [[ "${1:-}" == *kernel-state.json.tmp.* ]] && grep -q '"state":"staged"' "$1"; then
      checkpoint before_staged
      [[ "${FAIL_TOOL:-}" != staged-sync ]] || exit 1
    fi ;;
  *) exit 2 ;;
esac
