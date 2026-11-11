#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/rauc-bundle-inspect.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
touch "$work/bundle"; echo trust-fixture >"$work/keyring"
fixture() {
  python3 - "$work/info.json" "$@" <<'PY'
import json,sys
path,compatible,size=sys.argv[1:4]
d={'format':'verity','compatible':compatible,'images':[{'rootfs':{'filename':'rootfs.ext4','size':int(size),'adaptive':['block-hash-index']}}]}
if len(sys.argv)>4:
 k=sys.argv[4]
 if k=='format':d['format']='plain'
 if k=='name':d['images'][0]['rootfs']['filename']='rootfs.tar'
 if k=='adaptive':d['images'][0]['rootfs']['adaptive']=[]
 if k=='duplicate':d['images']*=2
json.dump(d,open(path,'w'))
PY
}
rauc() {
  [[ "$*" == "info -C keyring:check-purpose=codesign --output-format=json --keyring=$work/keyring $work/bundle" ]] || return 2
  [[ "${BAD_SIGNATURE:-0}" == 0 ]] || return 1
  cat "$work/info.json"
}
for compatible in ceralive-rock-5b-plus ceralive-orangepi5-plus ceralive-x86-minipc; do
  size=4294967296; [[ "$compatible" != ceralive-rock-5b-plus ]] || size=2684354560
  fixture "$compatible" "$size"
  [[ "$(BOARD_ID=unrelated rauc_bundle_verify_and_compatible "$work/bundle" "$work/keyring")" == "$compatible" ]]
  wrong=2684354560; [[ "$size" != "$wrong" ]] || wrong=4294967296
  fixture "$compatible" "$wrong"
  if rauc_bundle_verify_and_compatible "$work/bundle" "$work/keyring" >/dev/null 2>&1; then echo "accepted wrong size for $compatible"; exit 1; fi
done
for mutation in format name adaptive duplicate; do
  fixture ceralive-rock-5b-plus 2684354560 "$mutation"
  if rauc_bundle_verify_and_compatible "$work/bundle" "$work/keyring" >/dev/null 2>&1; then echo "accepted $mutation"; exit 1; fi
done
fixture ceralive-rock-5b-plus 2684354560
if BAD_SIGNATURE=1 rauc_bundle_verify_and_compatible "$work/bundle" "$work/keyring"; then echo 'accepted bad signature'; exit 1; fi
fixture ceralive-rock-5b-plus 2684350464
if rauc_bundle_verify_and_compatible "$work/bundle" "$work/keyring" >/dev/null 2>&1; then echo 'accepted truncated image'; exit 1; fi
# Exercise the actual production preflash consumer with the same authenticated
# metadata boundary stub; cryptographic signing remains covered by real bundles.
source tests/preflash-verify.sh
fixture ceralive-rock-5b-plus 2684354560
export BOARD_IDENTITY_COMPATIBLE=ceralive-rock-5b-plus
FAILS=0
check_rauc_bundle "$work/bundle" rock-5b-plus "$work/keyring"
[[ "$FAILS" -eq 0 ]]
fixture ceralive-orangepi5-plus 4294967296
check_rauc_bundle "$work/bundle" rock-5b-plus "$work/keyring"
[[ "$FAILS" -eq 1 ]]
echo 'board-specific full-slot inspector and preflash acceptance/rejection pass'
