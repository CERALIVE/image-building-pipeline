#!/usr/bin/env bash
# Execute the shipped main function in a fresh shell; mock only external I/O.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GROW_TEST_WORK="$work"
cat >"$work/harness" <<'HARNESS'
#!/bin/bash
set -euo pipefail
source mkosi/runtime/ceralive-grow-data.sh
scenario=$1
prefix=""; slot=a; root_bytes=2684354560
case "$scenario" in bench-*) prefix=x ;; legacy-*) root_bytes=4294967296 ;; esac
case "$scenario" in *-b) slot=b ;; esac
root_node="/dev/mockdisk0p2"; [[ "$slot" != b ]] || root_node="/dev/mockdisk0p3"
findmnt() { [[ "$*" == '-nro SOURCE /' ]]; [[ "$scenario" != findmnt-fail ]] || return 1; echo /dev/root; }
readlink() { [[ "$*" == '-f /dev/root' ]]; echo "$root_node"; }
# A block-device eligibility seam avoids creating nodes or touching real disks.
grow_data_is_block_device() {
  [[ "$scenario" != nonblock ]] || return 1
  [[ "$1" == "$root_node" || "$1" == /dev/mockdisk0 ]]
}
lsblk() {
  case "$*" in
    '-dnro PARTLABEL /dev/mockdisk0p'[23])
      if [[ "$scenario" == wrong-root ]]; then echo data; else echo "${prefix}rootfs_${slot}"; fi ;;
    '-dnro PKNAME /dev/mockdisk0p'[23])
      if [[ "$scenario" == wrong-parent ]]; then echo ../other-disk; else echo mockdisk0; fi ;;
    '--bytes --noheadings --raw --paths --sort PARTN --output TYPE,PARTLABEL,PARTTYPE,SIZE,PARTN /dev/mockdisk0')
      [[ "$scenario" != inventory-fail ]] || return 1
      echo 'disk    20000000000'
      echo "part ${prefix}boot bc13c2ff-59e6-4262-a352-b275fd6f7172 268435456 1"
      echo "part ${prefix}rootfs_a 0fc63daf-8483-4772-8e79-3d69d8477de4 $root_bytes 2"
      if [[ "$scenario" != single-a ]]; then
        echo "part ${prefix}rootfs_b 0fc63daf-8483-4772-8e79-3d69d8477de4 $root_bytes 3"
      fi
      [[ "$scenario" != missing-data ]] || return 0
      n=4; [[ "$scenario" != single-a ]] || n=3
      label="${prefix}data"; [[ "$scenario" != malformed ]] || label=unknown
      echo "part $label 0fc63daf-8483-4772-8e79-3d69d8477de4 268435456 $n"
      [[ "$scenario" != duplicate ]] || echo "part $label 0fc63daf-8483-4772-8e79-3d69d8477de4 268435456 5" ;;
    *) echo "unexpected lsblk invocation: $*" >&2; return 1 ;;
  esac
}
mktemp() { [[ "$*" == '-d /run/ceralive-grow-data.XXXXXX' ]]; command mktemp -d "$GROW_TEST_WORK/run.XXXXXX"; }
systemd-repart() {
  [[ $# -eq 4 && "$1" == --definitions=* && "$2" == --empty=refuse && "$3" == --dry-run=no && "$4" == /dev/mockdisk0 ]]
  printf '%s\n' "$@" >"$GROW_TEST_WORK/invoked"
  command cp -a "${1#--definitions=}" "$GROW_TEST_WORK/definitions"
  [[ "$scenario" != repart-fail ]] || return 1
}
grow_data_main "${prefix}data"
HARNESS
for scenario in root-a root-b bench-a bench-b legacy-a legacy-b single-a; do
  GROW_TEST_WORK="$work/$scenario"; export GROW_TEST_WORK; mkdir "$GROW_TEST_WORK"
  bash "$work/harness" "$scenario"
  [[ "$(tail -1 "$GROW_TEST_WORK/invoked")" == /dev/mockdisk0 ]]
  count=4; [[ "$scenario" != single-a ]] || count=3
  [[ "$(find "$GROW_TEST_WORK/definitions" -type f | wc -l)" -eq "$count" ]]
  [[ "$(grep -l '^SizeMaxBytes=' "$GROW_TEST_WORK/definitions"/*.conf | wc -l)" -eq "$((count - 1))" ]]
  [[ ! -e "$GROW_TEST_WORK/definitions/05.conf" ]]
  [[ -z "$(find "$GROW_TEST_WORK" -maxdepth 1 -name 'run.*' -print)" ]] # EXIT cleanup ran
  echo "$scenario entrypoint targets only its backing disk with ordered fixed-root definitions"
done
for scenario in nonblock wrong-root wrong-parent findmnt-fail inventory-fail missing-data malformed duplicate; do
  GROW_TEST_WORK="$work/$scenario"; export GROW_TEST_WORK; mkdir "$GROW_TEST_WORK"
  if bash "$work/harness" "$scenario"; then echo "accepted $scenario"; exit 1; fi
  [[ ! -e "$GROW_TEST_WORK/invoked" ]]
  [[ -z "$(find "$GROW_TEST_WORK" -maxdepth 1 -name 'run.*' -print)" ]]
  echo "$scenario rejected before repart"
done
GROW_TEST_WORK="$work/repart-fail"; export GROW_TEST_WORK; mkdir "$GROW_TEST_WORK"
if bash "$work/harness" repart-fail; then echo 'swallowed repart failure'; exit 1; fi
[[ -f "$GROW_TEST_WORK/invoked" && -z "$(find "$GROW_TEST_WORK" -maxdepth 1 -name 'run.*' -print)" ]]
# The real eligibility check must still reject ordinary files.
source mkosi/runtime/ceralive-grow-data.sh
if grow_data_is_block_device "$work/harness"; then echo 'accepted regular file'; exit 1; fi
echo 'growth entrypoint discovery, targeting, failures and cleanup pass'
