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
  # DO NOT "fix" this into working arithmetic. The board's U-Boot ships
  # `# CONFIG_CMD_SETEXPR is not set` (u-boot-config-target-1 in
  # linux-u-boot-vendor-rock-5b-plus), so the real console refuses the command and
  # leaves the counter unchanged — an infinite crash-loop. This stub IS the guard.
  setexpr() { printf "Unknown command 'setexpr' - try 'help'\n" >&2; return 1; }
  ext4load() {
    local path="${*: -1}"
    [[ " ${CERA_ABSENT_PATHS:-} " == *" ${path} "* ]] && return 1
    filesize=1024
    return 0
  }
  exit() { printf 'ABORTED\n' >"${result}"; builtin exit 0; }
  booti() { printf '%s|%s|%s|%s|%s|%s\n' "${cera_slot}" "${cera_root}" "${cera_part}" "${BOOT_ORDER}" "${BOOT_A_LEFT}" "${BOOT_B_LEFT}" >"${result}"; }
  set +u
  source "${BOOT_SCRIPT}" >/dev/null
)

assert_case() {
  local name="$1" order="$2" a="$3" b="$4" expected="$5" result got
  result="${TMP}/${name}"
  simulate "${order}" "${a}" "${b}" "${result}" || true
  if [[ ! -f "${result}" ]]; then
    printf 'FAIL %s: selector aborted before booti (no boot decision reached)\n' "${name}" >&2
    return 1
  fi
  got="$(<"${result}")"
  [[ "${got}" == "${expected}" ]] || {
    printf 'FAIL %s: got %s, expected %s\n' "${name}" "${got}" "${expected}" >&2
    return 1
  }
}

assert_case unknown-order X 3 3 'A|rootfs_a|2|A B|2|3'
assert_case duplicate-order 'A A' 3 3 'A|rootfs_a|2|A B|2|3'
assert_case malformed-counter 'A B' nope 3 'A|rootfs_a|2|A B|2|3'
assert_case missing-state __missing__ __missing__ __missing__ 'A|rootfs_a|2|A B|2|3'
assert_case valid-b-primary 'B A' 3 1 'B|rootfs_b|3|B A|3|0'

# Every step of the budget must actually move. A decrement table that only handles
# the value the other cases happen to use would pass everything above.
assert_case countdown-3-to-2 'A B' 3 3 'A|rootfs_a|2|A B|2|3'
assert_case countdown-2-to-1 'A B' 2 3 'A|rootfs_a|2|A B|1|3'
assert_case countdown-1-to-0 'A B' 1 3 'A|rootfs_a|2|A B|0|3'

# A exhausted -> the NEXT boot must choose B, and B's own budget must then move.
assert_case rollover-to-b 'A B' 0 3 'B|rootfs_b|3|A B|0|2'

# All budgets spent -> last-resort boot the head of BOOT_ORDER, decrementing nothing.
assert_case exhausted-last-resort 'A B' 0 0 'A|rootfs_a|2|A B|0|0'

# THE CRASH LOOP. A slot whose kernel cannot be loaded must abandon the device so
# the bootflow scan reaches the next one, NOT `booti` into unloaded DRAM.
CERA_ABSENT_PATHS='/boot/Image' assert_case absent-kernel 'A B' 3 3 'ABORTED'
CERA_ABSENT_PATHS='/boot/dtb/rockchip/rk3588-rock-5b-plus.dtb' \
  assert_case absent-dtb 'A B' 3 3 'ABORTED'

# The initrd stays OPTIONAL — the vendor path ships only initrd.img-<ver>, so a
# failed bare-name load must still boot.
CERA_ABSENT_PATHS='/boot/initrd.img' assert_case absent-initrd 'A B' 3 3 'A|rootfs_a|2|A B|2|3'

# Non-vacuity: the harness must be able to FAIL. If `setexpr` were reachable the
# selector would be depending on a command this board does not have.
if grep -vE '^[[:space:]]*#' "${BOOT_SCRIPT}" | grep -q 'setexpr'; then
  printf 'FAIL: boot.scr.cmd still references setexpr (absent from this board U-Boot)\n' >&2
  exit 1
fi

printf 'boot.scr malformed-state sanitization + bootcount + load guards: PASS\n'
