#!/bin/bash
set -euo pipefail

# Returns the SoC-FAMILY identity: the first 16 OTP bytes are the RK3588 family
# marker ("8853" + zero fill), the same for every board of this SoC. This is a
# coarse family guard matched against the Maskrom `rci` read, NOT a per-device id
# (the per-device binding is the eMMC CID in ceralive-ci-uart-bootstrap.sh).
nvmem="${CERALIVE_ROCKCHIP_NVMEM_FILE:-/sys/bus/nvmem/devices/rockchip-otp0/nvmem}"
[[ -f "${nvmem}" && -r "${nvmem}" ]] || {
    printf 'Rockchip OTP NVMEM is unavailable: %s\n' "${nvmem}" >&2
    exit 1
}

chip_info="$(od -An -N16 -v -tx1 -- "${nvmem}" | tr -d '[:space:]')"
[[ "${chip_info}" =~ ^[0-9a-f]{32}$ ]] || {
    printf 'Rockchip OTP NVMEM did not provide exactly 16 identity bytes\n' >&2
    exit 1
}
printf '%s\n' "${chip_info}"
