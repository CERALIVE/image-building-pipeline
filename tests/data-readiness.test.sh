#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export CERALIVE_DATA_STATUS_FILE="$work/status"
export CONTROL_CALLS="$work/control-calls"
: >"$CONTROL_CALLS"
cat >"$work/bin/findmnt" <<'SH'
#!/bin/bash
case "$*" in
  '-nro SOURCE /') echo /dev/test2 ;;
  '-nro SOURCE /data') echo /dev/test4 ;;
  '-nro TARGET /data') echo "${DATA_TARGET:-/data}" ;;
  '-nro FSTYPE /data') echo ext4 ;;
  '-nro OPTIONS /data') echo "${DATA_OPTIONS:-rw,noatime}" ;;
  *) exit 1 ;;
esac
SH
cat >"$work/bin/lsblk" <<'SH'
#!/bin/bash
case "$*" in
  '-dnro RO /dev/test') echo "${CARD_RO:-0}" ;;
  '-bdnro SIZE /dev/test') echo "${MEDIA_BYTES:-15000000000}" ;;
  '-bdnro SIZE /dev/test2') echo "${ROOT_BYTES:-4294967296}" ;;
  '-bdnro SIZE /dev/test4') echo 1835008000 ;;
   '-dnro PKNAME /dev/test2') echo test ;;
  '-dnro PKNAME /dev/test4') echo "${DATA_PARENT:-test}" ;;
  '-dnro PARTLABEL /dev/test4') echo data ;;
  *) exit 1 ;;
esac
SH
cat >"$work/bin/systemctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$CONTROL_CALLS"
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
cat >"$work/bin/dumpe2fs" <<'SH'
#!/bin/bash
[[ ${IO_FAIL:-0} != 1 ]] || exit 1
if [[ ${SMALL_FS:-0} == 1 ]]; then echo 'Block count: 65536'; else echo 'Block count: 448000'; fi
echo 'Block size: 4096'
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
for media in 8000000000 14999999999; do
  if timeout 2s env MEDIA_BYTES="$media" bash "$helper" >"$work/capacity-error" 2>&1; then exit 1; else status=$?; fi
  [[ "$status" == 78 ]]
  grep -q 'no automatic retry or reboot' "$work/capacity-error"
done
MEDIA_BYTES=15000000000 bash "$helper"
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
  if MEDIA_BYTES=8000000000 bash "$helper" >"$work/capacity-error" 2>&1; then exit 1; else [[ "$?" == 78 ]]; fi
done
[[ "$selected" == AAABBBAA ]]
grep -qx 'BOOT_A_LEFT=0' "$CERALIVE_BOOT_STATE_FILE"
grep -qx 'BOOT_B_LEFT=0' "$CERALIVE_BOOT_STATE_FILE"
! grep -Eq '^(reboot|restart|reset)( |$)' "$CONTROL_CALLS"
echo 'capacity boundary, terminal refusal and finite boot-attempt regression pass'

# Receipts distinguish every fatal readiness class without disclosing device paths.
for scenario in media growth filesystem incomplete full readonly inventory cardro io; do
  case "$scenario" in
    cardro) envs=(CARD_RO=1); expected='card-read-only' ;;
    io) envs=(IO_FAIL=1); expected='card-io-failed' ;;
    media) envs=(MEDIA_BYTES=8000000000); expected='media-too-small' ;;
    growth) envs=(GROW_STATE=failure); expected='partition-growth' ;;
    filesystem) envs=(FS_STATE=failure); expected='filesystem-growth' ;;
    incomplete) envs=(SMALL_FS=1); expected='filesystem-incomplete' ;;
    full) envs=(LOW_FREE=1); expected='data-full' ;;
    readonly) envs=(DATA_OPTIONS=ro); expected='card-read-only' ;;
    inventory) envs=(ROOT_BYTES=unknown); expected='readiness-failed' ;;
  esac
  if env "${envs[@]}" bash "$helper"; then exit 1; fi
  grep -q "^$expected " "$CERALIVE_DATA_STATUS_FILE"
  if [[ "$scenario" == io ]]; then
    python3 - "$CERALIVE_DATA_STATUS_FILE" "$work" <<'PY_MESSAGE'
import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('attention', 'mkosi/runtime/ceralive-attention.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
a.INPUT = Path(sys.argv[2]) / 'conditions'
a.INPUT.mkdir()
a.data_condition(Path(sys.argv[1]))
item = json.loads((a.INPUT / 'data-readiness.json').read_text())
assert item['line'] == "The box couldn't prepare its storage.", item
assert 'image' in item['fix'] and 'different card' in item['fix'], item
spanish = Path('docs/unsafe-storage.es-419.md').read_text()
assert 'La caja no pudo preparar su almacenamiento' in spanish
assert 'falsa o defectuosa' not in spanish
PY_MESSAGE
  fi
done
bash "$helper"
[[ ! -e $CERALIVE_DATA_STATUS_FILE ]]

# Retail 16 GB policy: the floor and published 16 GB card sizes pass.
for media in 15000000000 15480000000 15931539456; do
  ROOT_BYTES=4294967296 MEDIA_BYTES=$media bash "$helper"
done
for media in 8000000000 14999999999; do
  if ROOT_BYTES=4294967296 MEDIA_BYTES=$media bash "$helper"; then exit 1; else [[ $? == 78 ]]; fi
done
