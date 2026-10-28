#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
handler="${repo}/mkosi/runtime/rauc/ceralive-post-install"
# shellcheck source=tests/lib/assertions.sh
source "${repo}/tests/lib/assertions.sh"
check() { if "$@"; then ok "$*"; else bad "$*"; fi; }
work=''
finish() {
  local status=$?
  [[ "$status" -eq 0 || "$FAIL" -gt 0 ]] || bad "unexpected exit: $status"
  [[ -z "$work" ]] || rm -rf "$work"
  printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
trap 'finish; exit $?' EXIT
set -o errtrace
trap 'bad "fixture command failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR
work="$(mktemp -d "${TMPDIR:-/var/tmp}/post-install-label.XXXXXX")" || { bad 'fixture: mktemp'; exit 1; }
mkdir -p "${work}/bin"
mkdir -p "${work}/state"
cat >"${work}/bin/lsblk" <<'SH'
#!/bin/sh
case "$3" in
  */slot-a) printf '%s\n' "${LABEL_A:-}" ;;
  */slot-b) printf '%s\n' "${LABEL_B:-}" ;;
esac
SH
cat >"${work}/bin/blkid" <<'SH'
#!/bin/sh
case "$6" in
  */slot-a) printf '%s\n' "${BLKID_A:-}" ;;
  */slot-b) printf '%s\n' "${BLKID_B:-}" ;;
esac
SH
cat >"${work}/bin/e2label" <<'SH'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >>"${LABEL_CALLS}"
SH
chmod +x "${work}/bin/"*
: >"${work}/slot-a"; : >"${work}/slot-b"
run_handler() {
  env PATH="${work}/bin:${PATH}" LABEL_CALLS="${work}/calls" \
    CERALIVE_UPDATE_STATE_DIR="${work}/state" \
    RAUC_TARGET_SLOTS="$1" RAUC_SLOT_DEVICE_0="${work}/slot-a" \
    RAUC_SLOT_DEVICE_1="${work}/slot-b" RAUC_SLOT_CLASS_0=rootfs RAUC_SLOT_CLASS_1=rootfs \
    LABEL_A="${2:-}" LABEL_B="${3:-}" BLKID_A="${4:-}" BLKID_B="${5:-}" \
    bash "${handler}" post-install
}
check run_handler '1' '' rootfs_b
check grep -Fxq "${work}/slot-b rootfs_b" "${work}/calls"
: >"${work}/calls"
check run_handler '0' xrootfs_a
check grep -Fxq "${work}/slot-a xrootfs_a" "${work}/calls"
: >"${work}/calls"
check run_handler '0' '' '' xrootfs_a
check grep -Fxq "${work}/slot-a xrootfs_a" "${work}/calls"
: >"${work}/calls"
if run_handler '0' '' ''; then
  bad 'empty GPT PARTLABEL was accepted'
else
  ok 'empty GPT PARTLABEL refused'
fi
check test ! -s "${work}/calls"
: >"${work}/calls"
check run_handler '0 1' xrootfs_a rootfs_b
check grep -Fxq "${work}/slot-a xrootfs_a" "${work}/calls"
check grep -Fxq "${work}/slot-b rootfs_b" "${work}/calls"
assert_eq 'two independent GPT labels' 2 "$(wc -l <"${work}/calls")"
printf '{"status":"invalid"}\n' >"${work}/state/slot-overlay-A.json"
printf '{"status":"pending"}\n' >"${work}/state/slot-overlay-B.json"
check run_handler '1' '' rootfs_b
check test ! -e "${work}/state/slot-overlay-B.json"
check test -e "${work}/state/slot-overlay-A.json"
check run_handler '0' xrootfs_a
check test ! -e "${work}/state/slot-overlay-A.json"
trap - ERR
[[ "$FAIL" -eq 0 ]]
