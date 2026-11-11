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

Read-only inspection of the rebuilt combined candidate measured 756,473,856
firmware bytes per root, 586,989,568 bytes below the full-firmware baseline;
all 5,245 retained regular files/symlinks matched by hash/link target. Finite
ROCK 5B+ checks passed a small modem DNS/HTTPS probe and physical HDMI media
capture. These measurements do not qualify every peripheral, other boards,
interrupted growth or sustained operation.

## Restore excluded firmware

Before reinstalling firmware, remove the required family and descendant globs
from the installed `/usr/lib/ceralive/prune-paths.list` policy (or the policy file
selected by the maintenance command's override). Otherwise the installed
post-upgrade reprune hook removes the restored files again. Restore firmware
from the pinned package/archive, verify the files survive repruning and slot
comparison, and repeat peripheral qualification. Apply the same policy to both
slots; an image update can replace a local policy edit. For a durable rollback,
rebuild and install an image with the board supplement changed or disabled.
A build-time `CERALIVE_PRUNE_PATHS_MANIFEST` override replaces the entire policy;
retain the required common exclusions when using it.
