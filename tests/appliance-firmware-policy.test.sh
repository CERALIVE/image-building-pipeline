#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/shared/prune-paths-lib.sh
export BOARD_ID=rock-5b-plus
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
removed=(nvidia mellanox netronome amdgpu mrvl/prestera intel/ipu i915 intel/vsc radeon xe)
kept=(intel/iwlwifi mrvl/sd8897 brcm mediatek rtw89 rtl_bt ath11k rockchip mpp modem)
for p in "${removed[@]}" "${kept[@]}"; do
  mkdir -p "$work/usr/lib/firmware/$p"
  touch "$work/usr/lib/firmware/$p/blob"
done
touch "$work/usr/lib/firmware/iwlwifi-test.ucode" "$work/usr/lib/firmware/regulatory.db"
while IFS= read -r pattern; do
  # Match the installed reprune consumer's glob semantics in a synthetic root.
  rm -rf -- "${work}"${pattern}
done < <(prune_paths_read)
for p in "${removed[@]}"; do test ! -e "$work/usr/lib/firmware/$p"; done
for p in "${kept[@]}"; do test -f "$work/usr/lib/firmware/$p/blob"; done
test -f "$work/usr/lib/firmware/iwlwifi-test.ucode"
test -f "$work/usr/lib/firmware/regulatory.db"
# Other supported targets must retain integrated-GPU firmware.
for board in x86_64 x86-mini-pc orange-pi-5-plus ''; do
  test -z "$(BOARD_ID="$board" prune_paths_read | sed -n '/firmware/p')"
done
# Exercise the real slot-mirror per-file matcher, including nested descendants.
cat >"$work/dpkg" <<'DPKG'
#!/bin/sh
printf '%s\n' 'missing /usr/lib/firmware/nvidia/sub/file.bin' 'missing /usr/lib/firmware/iwlwifi-test.ucode'
DPKG
chmod +x "$work/dpkg"
prune_paths_content >"$work/policy"
export DPKG_BIN="$work/dpkg"
export PRUNE_PATHS_FILE="$work/policy"
source mkosi/runtime/ceralive-slot-mirror-lib.sh
[[ "$(dpkg_verify_filtered "$work")" == 'missing /usr/lib/firmware/iwlwifi-test.ucode' ]]
# CSV and installed policy select the same globs for this board.
[[ "$(prune_paths_csv)" == "$(prune_paths_read "$work/policy" | paste -sd,)" ]]
echo 'firmware exclusion and retained-family controls pass'

# Both consumers must refuse missing common/board policy, even in conditional
# callers where errexit cannot propagate a failed read for us.
mkdir -p "$work/reader/lib/shared" "$work/reader/manifests/boards"
cp lib/shared/prune-paths-lib.sh "$work/reader/lib/shared/"
(
  unset CERALIVE_PRUNE_PATHS_MANIFEST
  source "$work/reader/lib/shared/prune-paths-lib.sh"
  for state in common board; do
    if [[ "$state" == board ]]; then
      printf '/example/*\n' >"$work/reader/manifests/prune-paths.list"
    fi
    for consumer in prune_paths_csv prune_paths_content; do
      if "$consumer" >"$work/output" 2>"$work/error"; then
        echo "unexpected policy success: $state $consumer" >&2; exit 1
      fi
      test -s "$work/error"
    done
  done
  if CERALIVE_PRUNE_PATHS_MANIFEST="$work/missing" prune_paths_csv; then exit 1; fi
)
