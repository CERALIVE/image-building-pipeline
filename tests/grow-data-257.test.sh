#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source mkosi/runtime/ceralive-grow-data.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Use the already provisioned pipeline builder, never build or pull an image.
image=${CERALIVE_REPART_TEST_IMAGE:?set an existing pipeline builder with systemd 257}
docker image inspect "$image" >/dev/null
version=$(docker run --rm "$image" systemd-repart --version)
[[ "$version" == 'systemd 257 '* ]] || { echo "target systemd 257 required, got $version"; exit 1; }
run_repart() {
  docker run --rm --user "$(id -u):$(id -g)" -v "$work:/test" -w /test "$image" \
    systemd-repart --offline=yes --definitions="/test/$1/defs" --empty=refuse --dry-run=no --discard=no "/test/$1/disk"
}
for scenario in compact-ab legacy-ab compact-single bench-ab; do
  dir="$work/$scenario"; mkdir -p "$dir/defs"
  board=rock-5b-plus; prefix=""; slots=2; extra=()
  case "$scenario" in
    legacy-ab) board=orange-pi-5-plus ;;
    compact-single) slots=1; extra=(--single-slot) ;;
    bench-ab) prefix=x ;;
  esac
  CERALIVE_BENCH_LABELS="${prefix:+1}" bash lib/assemble-disk.sh build --board "$board" \
    --output "$dir/disk" --no-format "${extra[@]}"
  count=$((slots + 2))
  : >"$dir/table"
  for ((n=1;n<=count;n++)); do
    info=$(sgdisk -i "$n" "$dir/disk")
    label=$(sed -n "s/Partition name: '\(.*\)'/\1/p" <<<"$info")
    type=$(sed -n 's/Partition GUID code: \([^ ]*\).*/\1/p' <<<"$info")
    sectors=$(awk '/Partition size:/{print $3}' <<<"$info")
    first=$(awk '/First sector:/{print $3}' <<<"$info")
    printf 'part %s %s %s %s %s\n' "$label" "$type" "$((sectors * 512))" "$n" "$first" >>"$dir/table"
    if (( n < count )); then printf '%s\n' "$info" >"$dir/before$n"; fi
  done
  grow_data_definitions "$dir/defs" "${prefix}data" <"$dir/table"
  # Every inventory permutation must generate the same ordered definitions.
  python3 - "$dir/table" "$dir" <<'PYORDER'
import itertools, pathlib, sys
rows = pathlib.Path(sys.argv[1]).read_text().splitlines()
for i, order in enumerate(itertools.permutations(rows)):
    pathlib.Path(sys.argv[2], f'order{i}').write_text('\n'.join(order)+'\n')
PYORDER
  for table in "$dir"/order*; do
    mkdir "$dir/permuted"
    grow_data_definitions "$dir/permuted" "${prefix}data" <"$table"
    diff -r "$dir/defs" "$dir/permuted"
    rm -r "$dir/permuted"
  done
  start=$(sgdisk -i "$count" "$dir/disk" | awk '/First sector:/{print $3}')
  before=$(sgdisk -i "$count" "$dir/disk" | awk '/Partition size:/{print $3}')
  truncate -s 20G "$dir/disk"
  run_repart "$scenario"
  for ((n=1;n<count;n++)); do sgdisk -i "$n" "$dir/disk" >"$dir/after$n"; cmp "$dir/before$n" "$dir/after$n"; done
  after=$(sgdisk -i "$count" "$dir/disk")
  [[ "$(awk '/First sector:/{print $3}' <<<"$after")" == "$start" ]]
  [[ "$(awk '/Partition size:/{print $3}' <<<"$after")" -gt "$before" ]]
  # The last data sector must consume the disk, not just grow by a small amount.
  last=$(awk '/Last sector:/{print $3}' <<<"$after")
  (( last > 20 * 1024 * 1024 * 1024 / 512 - 2048 ))
  sgdisk --backup="$dir/once.gpt" "$dir/disk"
  run_repart "$scenario"
  sgdisk --backup="$dir/twice.gpt" "$dir/disk"
  cmp "$dir/once.gpt" "$dir/twice.gpt"
  echo "$scenario: target257 data fills disk, boot/roots unchanged, repeat idempotent"
done
# Unknown, missing, duplicated or physically reordered partitions must not reach repart.
for bad in missing duplicate physical-reordered overlap type; do
  mkdir "$work/$bad"
  case "$bad" in
    missing) sed '/ data /d' "$work/compact-ab/table" ;;
    duplicate) cat "$work/compact-ab/table"; tail -1 "$work/compact-ab/table" ;;
    physical-reordered) awk '$5 == 3 {$6=11567104} $5 == 4 {$6=5799936} {print}' "$work/compact-ab/table" ;;
    overlap) awk '$5 == 4 {$6-=8} {print}' "$work/compact-ab/table" ;;
    type) sed 's/0FC63DAF-8483-4772-8E79-3D69D8477DE4/00000000-0000-0000-0000-000000000000/g' "$work/compact-ab/table" ;;
  esac >"$work/$bad/table"
  if grow_data_definitions "$work/$bad" data <"$work/$bad/table"; then echo "accepted invalid $bad table"; exit 1; fi
done
echo 'target257 growth and fail-closed layout controls pass'
