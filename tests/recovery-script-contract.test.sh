#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2154
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../mkosi/platform/boot/recovery.scr.cmd"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

[[ -f "${SCRIPT}" ]]

simulate() (
  cera_recovery_slot="$1"
  result="$2"
  devtype=mmc devnum=0 kernel_addr_r=0x1000 fdt_addr_r=0x2000 ramdisk_addr_r=0x3000 filesize=0
  fdtfile=rk3588-rock-5b-plus.dtb console=ttyS2,1500000
  setenv() { local name="$1"; shift; printf -v "${name}" '%s' "$*"; }
  ext4load() {
    printf '%s|%s\n' "$2" "${*: -1}" >>"${result}.loads"
    filesize=1024
  }
  booti() { printf '%s|%s|%s\n' "${cera_recovery_slot}" "${cera_part}" "${cera_root}" >"${result}"; }
  set +u
  source "${SCRIPT}" >/dev/null
)

simulate A "${TMP}/a"
[[ "$(<"${TMP}/a")" == 'A|2|rootfs_a' ]]
grep -q '^0:2|/boot/Image$' "${TMP}/a.loads"
simulate B "${TMP}/b"
[[ "$(<"${TMP}/b")" == 'B|3|rootfs_b' ]]
grep -q '^0:3|/boot/initrd.img$' "${TMP}/b.loads"
if simulate X "${TMP}/x"; then
  printf 'unknown recovery slot was accepted\n' >&2
  exit 1
fi

printf 'RK3588 cross-partition recovery contract: PASS\n'
