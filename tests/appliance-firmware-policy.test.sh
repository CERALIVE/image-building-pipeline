#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/shared/prune-paths-lib.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
removed=(nvidia mellanox netronome amdgpu mrvl/prestera intel/ipu i915 intel/vsc radeon xe)
kept=(intel/iwlwifi mrvl/sd8897 brcm mediatek rtw89 rtl_bt ath11k rockchip mpp modem regulatory.db)
for p in "${removed[@]}" "${kept[@]}"; do
  mkdir -p "$work/usr/lib/firmware/$p"
  touch "$work/usr/lib/firmware/$p/blob"
done
while IFS= read -r pattern; do
  # Match the installed reprune consumer's glob semantics in a synthetic root.
  rm -rf -- "${work}"${pattern}
done < <(prune_paths_read)
for p in "${removed[@]}"; do test ! -e "$work/usr/lib/firmware/$p"; done
for p in "${kept[@]}"; do test -f "$work/usr/lib/firmware/$p/blob"; done
echo 'firmware exclusion and retained-family controls pass'
