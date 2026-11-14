#!/bin/bash
# Preserve flat ramoops records before stock systemd-pstore replaces their names.
set -euo pipefail
export LC_ALL=C
store="${1:-/var/lib/systemd/pstore}"
cd "$store"
shopt -s nullglob

# The service serializes invocations. Resume a split collection after interruption;
# an empty allocation is not a generation. Time is metadata, never ordering.
last=0
archive=""
for dir in history/*; do
  [[ -d "$dir" ]] || continue
  name="${dir##*/}"
  [[ "$name" =~ ^[0-9]{10}$ ]] || continue
  parts=("$dir"/*ramoops*)
  if [[ -f "$dir/.incomplete" ]] && ((${#parts[@]} == 0)); then
    rm -- "$dir/.incomplete"
  fi
  if rmdir -- "$dir" 2>/dev/null; then continue; fi
  n=$((10#$name))
  ((n <= last)) || last=$n
  if [[ -f "$dir/.incomplete" ]]; then archive="$dir"; fi
done
records=(*ramoops*)
if ((${#records[@]})) || [[ -n "$archive" ]]; then
  if [[ -z "$archive" ]]; then
    mkdir -p history
    while :; do
      ((last < 9999999999)) || { echo 'pstore sequence exhausted' >&2; exit 1; }
      last=$((last + 1))
      printf -v archive 'history/%010d' "$last"
      if mkdir -- "$archive"; then break; fi
      # A competing allocation must never merge collections. Other errors fail
      # the pre-step, keeping stock pstore from clearing the kernel records.
      [[ -d "$archive" ]] || exit 1
    done
    touch "$archive/.incomplete"
  fi
  if ((${#records[@]})); then mv -- "${records[@]}" "$archive/"; fi
  date -u +%Y-%m-%dT%H:%M:%SZ > "$archive/collected-at"
  rm -- "$archive/.incomplete"
fi
# Keep 31 previous collections plus the current one. Compression can expand the
# configured 1 MiB reservation to about 1.4 MiB when read; allow 44 MiB of history,
# including directory metadata. Also trim inputs from larger reservations.
archives=(history/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
# Count only generations that this loop can prune, not unrelated entries.
numbered=()
for dir in "${archives[@]}"; do
  [[ ! -d "$dir" ]] || numbered+=("$dir")
done
archives=("${numbered[@]}")
while ((${#archives[@]})) && { ((${#archives[@]} > 31)) ||
  (( $(du -sbc -- "${archives[@]}" | tail -n 1 | cut -f1) > 44 * 1024 * 1024 )); }; do
  rm -rf -- "${archives[0]}"
  archives=("${archives[@]:1}")
done
