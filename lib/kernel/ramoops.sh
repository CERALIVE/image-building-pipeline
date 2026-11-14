#!/usr/bin/env bash
# Add the reservation to the kernel sources before dtbs and bindeb-pkg run.
set -euo pipefail
rockchip="$1/arch/arm64/boot/dts/rockchip"
include='/include/ "ceralive-ramoops.dtsi"'
# Validate both inputs before changing either board.
for board in rk3588-rock-5b rk3588-rock-5b-plus; do
  test -f "$rockchip/$board.dts"
done
install -m 0644 "$2" "$rockchip/ceralive-ramoops.dtsi"
for board in rk3588-rock-5b rk3588-rock-5b-plus; do
  grep -Fxq "$include" "$rockchip/$board.dts" || printf '\n%s\n' "$include" >> "$rockchip/$board.dts"
done
