#!/bin/bash
set -euo pipefail

# Returns the RK3588 SoC-FAMILY identity as a 32-hex canonical value: the OTP
# `cpu_code` cell (RK3588 OTP nvmem offset 0x02, length 2 = 0x3588; see the
# rk3588 OTP device-tree node `cpu_code: cpu-code@2 { reg = <0x02 0x2>; }`)
# followed by zero fill. This is the like-for-like counterpart to the Maskrom
# `rkdeveloptool rci` read, which reports the SAME family DIFFERENTLY — as the
# model number's ASCII digits byte-reversed (bytes 38 38 35 33 = "8853", the
# little-endian image of the BootROM chip_info DWORD 0x33353838 = ASCII "3588").
# The host normalizes its rci read to this same cpu_code form so both sides
# compare identically (`35880000000000000000000000000000` on RK3588).
#
# It is DELIBERATELY not the raw first-16-byte OTP dump. The earlier `od -N16`
# implementation returned bytes 0x00..0x0f verbatim, which includes the per-die
# unique serial (`cpu_id: id@7 { reg = <0x07 0x10>; }`, offset 0x07 onward): a
# PER-DEVICE value that varies board to board and can never equal a fixed
# host-derived family constant (real capture `524b358812fe21413337544600000000`
# — offset 2-3 = 35 88 = the cpu_code, offset 7+ = the serial). Emitting that raw
# dump made the family guard a guaranteed mismatch; the genuine per-device
# binding is the eMMC CID cross-check in ceralive-ci-uart-bootstrap.sh, not this.
nvmem="${CERALIVE_ROCKCHIP_NVMEM_FILE:-/sys/bus/nvmem/devices/rockchip-otp0/nvmem}"
[[ -f "${nvmem}" && -r "${nvmem}" ]] || {
    printf 'Rockchip OTP NVMEM is unavailable: %s\n' "${nvmem}" >&2
    exit 1
}

# cpu_code cell: OTP nvmem byte offset 0x02, length 2.
cpu_code="$(od -An -j2 -N2 -v -tx1 -- "${nvmem}" | tr -d '[:space:]')"
[[ "${cpu_code}" =~ ^[0-9a-f]{4}$ ]] || {
    printf 'Rockchip OTP NVMEM did not provide the 2-byte cpu_code family cell\n' >&2
    exit 1
}
printf '%s0000000000000000000000000000\n' "${cpu_code}"
