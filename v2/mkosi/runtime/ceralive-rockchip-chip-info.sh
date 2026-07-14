#!/bin/bash
set -euo pipefail

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
