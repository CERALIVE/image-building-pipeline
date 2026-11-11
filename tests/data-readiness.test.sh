#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat >"$work/bin/findmnt" <<'SH'
#!/bin/bash
case "$*" in
  '-nro SOURCE /') echo /dev/test2 ;;
  '-nro SOURCE /data') echo /dev/test4 ;;
  '-nro TARGET /data') echo /data ;;
  '-nro FSTYPE /data') echo ext4 ;;
  '-nro OPTIONS /data') echo rw,noatime ;;
  *) exit 1 ;;
esac
SH
cat >"$work/bin/lsblk" <<'SH'
#!/bin/bash
case "$*" in
  '-bdnro SIZE /dev/test') echo "${MEDIA_BYTES:-8589934592}" ;;
  '-bdnro SIZE /dev/test2') echo "${ROOT_BYTES:-2684354560}" ;;
  '-bdnro SIZE /dev/test4') echo 1835008000 ;;
   '-dnro PKNAME /dev/test2') echo test ;;
  '-dnro PKNAME /dev/test4') echo "${DATA_PARENT:-test}" ;;
  '-dnro PARTLABEL /dev/test4') echo data ;;
  *) exit 1 ;;
esac
SH
cat >"$work/bin/systemctl" <<'SH'
#!/bin/bash
case "$*" in
  *ceralive-grow-data.service) [[ ${GROW_STATE:-success} == success ]] ;;
  *systemd-growfs@data.service) [[ ${FS_STATE:-success} == success ]] ;;
  *) exit 1 ;;
esac
SH
cat >"$work/bin/stat" <<'SH'
#!/bin/bash
if [[ ${SMALL_FS:-0} == 1 ]]; then echo '65536 4096 60000'
elif [[ ${LOW_FREE:-0} == 1 ]]; then echo '440000 4096 60000'
else echo '440000 4096 300000'; fi
SH
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
helper=mkosi/runtime/ceralive-data-ready.sh
for state in failure pending; do
  if GROW_STATE=$state bash "$helper" >"$work/out" 2>&1; then echo 'growth not complete but readiness passed'; exit 1; fi
  grep -q 'refusing health confirmation/updates' "$work/out"
done
if FS_STATE=failure bash "$helper"; then exit 1; fi
if SMALL_FS=1 bash "$helper"; then exit 1; fi
if ROOT_BYTES=unknown bash "$helper"; then exit 1; fi
if DATA_PARENT=foreign bash "$helper"; then exit 1; fi
if LOW_FREE=1 bash "$helper"; then exit 1; fi
bash "$helper"
# Legacy adequately-sized layouts are not tied to repart success.
ROOT_BYTES=4294967296 GROW_STATE=failure bash "$helper"
# Exercise the actual health consumer at mark_good, with no real RAUC effects.
sed '/^if \[\[ "${1:-}" == --partlabel-guard \]\]; then/,$d' mkosi/runtime/ceralive-healthcheck.sh >"$work/health"
(
  export CERALIVE_KERNEL_STATE_LIB="$PWD/mkosi/runtime/ceralive-kernel-state-lib.sh"
  source "$work/health"
  partlabel_guard_ok() { return 0; }
  dpkg_integrity_ok() { return 0; }
  drill_guard_ok() { return 0; }
  export CERALIVE_DATA_READY_BIN="$PWD/$helper"
  for state in failure pending; do
    export GROW_STATE=$state
    if mark_good; then echo 'health consumer ignored incomplete growth'; exit 1; fi
  done
)
# Mount/grow/consumer sequencing is exercised dynamically by
# systemd-ordering-cycle.test.sh using rendered installed units and drop-ins.
echo 'data readiness failure/pending/success and health refusal pass'

# Image-length media used to pass preflash but could never stage an update.
for media in 5923405824 7516192767; do
  if timeout 2s env MEDIA_BYTES="$media" bash "$helper" >"$work/capacity-error" 2>&1; then exit 1; else status=$?; fi
  [[ "$status" == 78 ]]
  grep -q 'no automatic retry or reboot' "$work/capacity-error"
done
MEDIA_BYTES=7516192768 bash "$helper"
if LOW_FREE=1 bash "$helper"; then exit 1; else [[ "$?" == 78 ]]; fi

# Repeated operator boots cannot refresh attempts or mark the undersized slot
# healthy. The existing selector spends A x3, B x3, then stays on last-resort A;
# neither readiness nor the selector schedules a reboot itself.
export CERALIVE_BOOT_STATE_FILE="$work/boot-state" CERALIVE_BOOT_ATTEMPTS=3
bs() { bash mkosi/platform/boot/ceralive-boot-state.sh "$@"; }
bs init
selected=""
for _ in {1..8}; do
  selected+="$(bs boot-select | cut -d' ' -f1)"
  if MEDIA_BYTES=5923405824 bash "$helper" >"$work/capacity-error" 2>&1; then exit 1; else [[ "$?" == 78 ]]; fi
done
[[ "$selected" == AAABBBAA ]]
grep -qx 'BOOT_A_LEFT=0' "$CERALIVE_BOOT_STATE_FILE"
grep -qx 'BOOT_B_LEFT=0' "$CERALIVE_BOOT_STATE_FILE"
echo 'capacity boundary, terminal refusal and finite boot-attempt regression pass'
