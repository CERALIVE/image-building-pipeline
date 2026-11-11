# Compact ROCK 5B+ fresh-install layout

Fresh ROCK 5B+ images use the existing 16 MiB loader gap, 256 MiB boot,
two 2560 MiB ext4 root slots and a 256 MiB initial data partition, plus 1 MiB
for GPT alignment/tail: 5649 MiB raw. Other boards keep the v2 geometry.
Labels, partition types, boot selection and independent A/B rollback are unchanged.
The committed v2 repart definitions remain intact; the assembler stages the
ROCK size overrides. The shared layout helper sizes both factory and signed
verity/adaptive RAUC rootfs images at 2560 MiB so updates fit either slot.

Sizing basis: measured original used bytes 2,580,779,008 minus 193,695,744
package archives minus 586,989,568 excluded firmware = 1,800,093,696 bytes
(1716.7 MiB). A 2560 MiB slot leaves 843.3 MiB gross headroom for ext4
metadata/reservations and future dependencies. The populated filesystem must
still pass the existing >=512 MiB actual available-byte and inode reserve gates;
future bundle builds that exceed that reserve fail rather than emitting an
oversized update. This policy assumes the firmware and package-cache reductions
are applied; a layout-only build may correctly fail the reserve gate.

Before local mounts, ceralive-grow-data.service runs the installed growth helper
on the booted root's backing disk. It validates the entire existing partition
sequence and types: boot, root A, optional root B, final data (also allowing the
explicit bench labels). Unknown, missing, duplicate or reordered partitions are
refused before invoking repart. Definitions are generated in /run in the same
order, with boot/root minimum and maximum equal to their actual current sizes.
Only data has no maximum. No Format, CopyFiles or Label is emitted: existing
contents, labels and UUIDs are preserved. Both compact and legacy root sizes
are accepted, and a single-slot disk never receives an invented B definition.

This ordering matters on the target systemd 257: Label does not select existing
partitions; matching is by type UUID and order, as documented in
[repart.d v257](https://github.com/systemd/systemd/blob/v257/man/repart.d.xml).
A sole linux-generic data definition would select root A. The opt-in regression
`CERALIVE_REPART_TEST_IMAGE=<existing-pipeline-builder> tests/grow-data-257.test.sh`
requires systemd 257 and tests compact A/B, legacy A/B, single-slot and bench
images, unchanged boot/root GPT records, data filling the enlarged disk, repeat
idempotence and fail-closed malformed tables. It never builds/pulls a Docker image.

After partition growth, the existing /data fstab x-systemd.growfs option grows
ext4 on mount. The 256 MiB factory data is a transport minimum: OTA staging/log
capacity comes from the expanded card, and growth failure must be resolved
before updating. Physical first-boot and A/B qualification remain separate.

Compatibility: installed devices retain their current partition geometry; this
is not an in-place root repartitioning migration. They can receive the smaller
RAUC root image in their larger slots; only a fresh flash adopts smaller roots.
The runtime rule can extend existing data into unused card space, but never
shrinks or moves boot/root partitions. Old 4096 MiB full-slot bundles cannot fit
the new 2560 MiB slots: use compact bundles for updates and rollback on fresh
installs. Runtime growth, physical boot and RAUC update/reboot/rollback still
require board validation before release.
