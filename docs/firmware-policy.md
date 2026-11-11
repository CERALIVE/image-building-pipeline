# Appliance firmware policy

The ROCK 5B+ board supplement to the common prune manifest excludes only `nvidia`, `mellanox`, `netronome`, `amdgpu`,
`mrvl/prestera`, `intel/ipu`, `i915`, `intel/vsc`, `radeon` and `xe` under
`/usr/lib/firmware`. These discrete GPU, server network/switch and Intel camera
platforms are outside the appliance peripheral contract. Attaching those devices
will require a different firmware policy. This downstream policy applies only to ROCK 5B+ images. Other boards, including
Intel N100/N200 and AMD x86 targets, retain their integrated-GPU firmware.

Keep every other path unchanged: Intel wireless (including iwlwifi), Marvell
wireless, Atheros, Broadcom, MediaTek, Realtek, Bluetooth and regulatory data
preserve adapter support. Keep modem firmware and all Rockchip assets, including
HDMI-RX, MPP/VPU and encoder assets. Do not remove whole `intel` or `mrvl` trees.
Directory and descendant globs cover both recursive deletion and the slot-mirror
per-file comparison. The same selected policy drives build-time RemoveFiles and
the installed reprune/mirror manifest. Package selection, firmware archive identity, module closure gates and kernel
configuration remain unchanged. The existing prune manifest is also installed
for repruning after package upgrades and expected slot comparison differences.

Measured candidate exclusions total 586,989,568 bytes per root tree; actual image
savings require a rebuild. Cold-plug radio/modem and physical media qualification
remain required before release.
