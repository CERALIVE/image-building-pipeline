#!/usr/bin/env bash
# Exercise production population paths without disks or a container daemon.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/tree"
export FORMAT_LOG="$scratch/format.log" VERSION_LOG="$scratch/version.log"
cat > "$scratch/bin/mkfs.ext4" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == -V ]]; then
  echo probe >> "$VERSION_LOG"
  echo "mke2fs ${FORMAT_VERSION}" >&2
  exit 0
fi
printf '%s|%s|%s\n' "${SOURCE_DATE_EPOCH:-missing}" "${E2FSPROGS_FAKE_TIME:-missing}" "$*" >> "$FORMAT_LOG"
STUB
chmod +x "$scratch/bin/mkfs.ext4"
host_path="$PATH"
export PATH="$scratch/bin:$PATH"
# shellcheck source=lib/assemble-disk-x86.sh
source "$ROOT/lib/assemble-disk-x86.sh" '' >/dev/null
# shellcheck source=lib/disk/slot-image.sh
source "$ROOT/lib/disk/slot-image.sh"
part_field() { if [[ "$3" == 'First sector' ]]; then echo 2048; else echo 8192; fi; }
truncate() { :; }
dd() { :; }
tar() { [[ "$POPULATION_PATH" == native ]]; }
# Execute the actual container command with its environment, without mounting anything.
docker() {
  shift 2 # run --rm
  local -a assignments=()
  while [[ "$1" == -* ]]; do
    case "$1" in
      -e) assignments+=("$2"); shift 2 ;;
      -v) shift 2 ;;
      *) return 2 ;;
    esac
  done
  shift # image
  env "${assignments[@]}" "$@"
}
slot_reserve_assert_ext4() { :; }
stat() { echo 4294967296; }
failed=0
for producer in x86 shared; do
  for POPULATION_PATH in native container; do
    for FORMAT_VERSION in 1.47.0 1.47.1 1.48.0; do
      export FORMAT_VERSION
      rm -f "$FORMAT_LOG" "$VERSION_LOG"
      # Shell-local epoch must be explicitly exported to the formatter by the helper.
      export -n SOURCE_DATE_EPOCH
      SOURCE_DATE_EPOCH=1700000000
      export E2FSPROGS_FAKE_TIME=1900000000
      status=0
      (
        if [[ "$producer" == x86 ]]; then
          populate_rootfs_a "$scratch/disk" "$scratch/tree"
        else
          SLOT_IMAGE_LABEL=rootfs_a make_slot_image "$scratch/tree" "$scratch/disk"
        fi
      ) >"$scratch/output" 2>&1 || status=$?
      if [[ "$FORMAT_VERSION" == 1.47.0 ]]; then
        if (( status == 0 )) || [[ -f "$FORMAT_LOG" ]] || ! grep -q '1.47.1' "$scratch/output"; then
          echo "FAIL $producer $POPULATION_PATH: old formatter was not rejected before population"
          failed=1
        else
          echo "PASS $producer $POPULATION_PATH rejects $FORMAT_VERSION"
        fi
      elif (( status != 0 )) || [[ ! -f "$VERSION_LOG" ]] ||
        ! grep -q '^1700000000|1700000000|-q -L rootfs_a -U .* -E hash_seed=.* -d ' "$FORMAT_LOG"; then
        echo "FAIL $producer $POPULATION_PATH: supported formatter did not receive the gate, epoch, clock and identity"
        cat "$scratch/output"
        failed=1
      else
        echo "PASS $producer $POPULATION_PATH $FORMAT_VERSION"
      fi
    done
  done
done
# Verify the native x86 wrapper with real ext4 bytes as well as the command seam.
if (
  export PATH="$host_path"
  slot_require_timestamp_clamping >/dev/null 2>&1
); then
  (
    export PATH="$host_path"
    unset -f truncate dd tar stat
    part_field() { if [[ "$3" == 'First sector' ]]; then echo 2048; else echo 65536; fi; }
    export SOURCE_DATE_EPOCH=1700000000
    printf 'sample\n' > "$scratch/tree/hostname" || exit 1
    for build in first second; do
      if [[ "$build" == first ]]; then atime=1800000000; else atime=1900000000; fi
      touch -a -d "@$atime" "$scratch/tree/hostname" || exit 1
      truncate -s 34603008 "$scratch/$build.img" || exit 1
      E2FSPROGS_FAKE_TIME="$atime" populate_rootfs_a "$scratch/$build.img" "$scratch/tree"
    done
    [[ "$(stat -c %s "$scratch/first.img")" == 34603008 ]] || exit 1
    [[ "$(stat -c %s "$scratch/second.img")" == 34603008 ]] || exit 1
    cmp "$scratch/first.img" "$scratch/second.img" || exit 1
    echo 'PASS real x86 population: complete images match across access times and clocks'
  ) || failed=1
else
  echo 'SKIP real x86 comparison: supported ext4 formatter unavailable'
fi
exit "$failed"
