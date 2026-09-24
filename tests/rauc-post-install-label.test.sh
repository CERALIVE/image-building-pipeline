#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
handler="${repo}/mkosi/runtime/rauc/ceralive-post-install"
work="$(mktemp -d "${TMPDIR:-/var/tmp}/post-install-label.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"
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
    RAUC_TARGET_SLOTS="$1" RAUC_SLOT_DEVICE_0="${work}/slot-a" \
    RAUC_SLOT_DEVICE_1="${work}/slot-b" RAUC_SLOT_CLASS_0=rootfs RAUC_SLOT_CLASS_1=rootfs \
    LABEL_A="${2:-}" LABEL_B="${3:-}" BLKID_A="${4:-}" BLKID_B="${5:-}" \
    bash "${handler}" post-install
}
run_handler '1' '' rootfs_b
grep -Fxq "${work}/slot-b rootfs_b" "${work}/calls"
printf 'PRODUCTION=PASS rootfs_b\n'
: >"${work}/calls"
run_handler '0' xrootfs_a
grep -Fxq "${work}/slot-a xrootfs_a" "${work}/calls"
printf 'BENCH=PASS xrootfs_a\n'
: >"${work}/calls"
run_handler '0' '' '' xrootfs_a
grep -Fxq "${work}/slot-a xrootfs_a" "${work}/calls"
printf 'BLKID_FALLBACK=PASS\n'
: >"${work}/calls"
if run_handler '0' '' ''; then
  printf 'empty GPT PARTLABEL was accepted\n' >&2; exit 1
fi
[[ ! -s "${work}/calls" ]]
printf 'MISSING_LABEL=PASS fail-closed without e2label\n'
: >"${work}/calls"
run_handler '0 1' xrootfs_a rootfs_b
grep -Fxq "${work}/slot-a xrootfs_a" "${work}/calls"
grep -Fxq "${work}/slot-b rootfs_b" "${work}/calls"
[[ "$(wc -l <"${work}/calls")" -eq 2 ]]
printf 'TWO_SLOTS=PASS independent GPT labels\n'
