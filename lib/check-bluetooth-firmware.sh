#!/usr/bin/env bash
set -euo pipefail
command -v modinfo >/dev/null 2>&1 || { printf 'Bluetooth firmware: modinfo unavailable; cannot prove closure\n' >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../mkosi/customize/bluetooth-firmware.sh"
[[ $# == 2 || $# == 3 ]] || { printf 'usage: %s <one-kernel-module-tree> <firmware-dir> [roots-manifest]\n' "$0" >&2; exit 2; }
bluetooth_firmware_prepare "$1" "$2" "${3:-${HERE}/../manifests/rk3588-bluetooth-firmware-roots.txt}"
