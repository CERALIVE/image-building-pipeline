#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_SCRIPT="${HERE}/../mkosi/platform/boot/boot.scr.cmd"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck disable=SC1090,SC2034,SC2154
simulate() (
  local imported_order="$1" imported_a="$2" imported_b="$3" result="$4"
  devtype=mmc devnum=0 loadaddr=0x1000 kernel_addr_r=0x2000
  fdt_addr_r=0x3000 ramdisk_addr_r=0x4000 filesize=0
  loaded=""
  setenv() { local name="$1"; shift; printf -v "${name}" '%s' "$*"; }
  load() { loaded="${*: -1}"; filesize=128; return 0; }
  env() {
    if [[ "$1" == import && "${loaded}" == cera_board.env ]]; then
      fdtfile=rk3588-rock-5b-plus.dtb
    elif [[ "$1" == import && "${loaded}" == boot_state.txt ]]; then
      [[ "${imported_order}" == __missing__ ]] || BOOT_ORDER="${imported_order}"
      [[ "${imported_a}" == __missing__ ]] || BOOT_A_LEFT="${imported_a}"
      [[ "${imported_b}" == __missing__ ]] || BOOT_B_LEFT="${imported_b}"
    elif [[ "$1" == export ]]; then
      filesize=128
    fi
  }
  fatwrite() { printf '%s|%s|%s\n' "${BOOT_ORDER}" "${BOOT_A_LEFT}" "${BOOT_B_LEFT}" >>"${result}.writes"; }
  setexpr() {
    local name="$1" lhs="$2" op="$3" rhs="$4" value
    case "${op}" in
      -) value=$((lhs - rhs)) ;;
      +) value=$((lhs + rhs)) ;;
      *) return 1 ;;
    esac
    printf -v "${name}" '%d' "${value}"
  }
  ext4load() { filesize=1024; return 0; }
  booti() { printf '%s|%s|%s|%s|%s|%s\n' "${cera_slot}" "${cera_root}" "${cera_part}" "${BOOT_ORDER}" "${BOOT_A_LEFT}" "${BOOT_B_LEFT}" >"${result}"; }
  set +u
  source "${BOOT_SCRIPT}" >/dev/null
)

assert_case() {
  local name="$1" order="$2" a="$3" b="$4" expected="$5" result
  result="${TMP}/${name}"
  simulate "${order}" "${a}" "${b}" "${result}"
  [[ "$(<"${result}")" == "${expected}" ]] || {
    printf 'FAIL %s: got %s, expected %s\n' "${name}" "$(<"${result}")" "${expected}" >&2
    return 1
  }
}

assert_case unknown-order X 3 3 'A|rootfs_a|2|A B|2|3'
assert_case duplicate-order 'A A' 3 3 'A|rootfs_a|2|A B|2|3'
assert_case malformed-counter 'A B' nope 3 'A|rootfs_a|2|A B|2|3'
assert_case missing-state __missing__ __missing__ __missing__ 'A|rootfs_a|2|A B|2|3'
assert_case valid-b-primary 'B A' 3 1 'B|rootfs_b|3|B A|3|0'

printf 'boot.scr malformed-state sanitization: PASS\n'
