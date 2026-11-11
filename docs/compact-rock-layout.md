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

Before local mounts, ceralive-grow-data.service runs systemd-repart against the
booted root's backing disk. Its dedicated definition matches only the existing
linux-generic partition named data (or the explicit bench label), without Format,
CopyFiles or root-slot definitions. The default unbounded SizeMaxBytes extends
that final partition and relocates the backup GPT to the card end. The existing
/data fstab x-systemd.growfs then grows ext4 on mount. The operation is idempotent
and also works after cloning onto larger media. No filesystems are recreated.
The 256 MiB factory data is a transport minimum: OTA bundle staging/log capacity
comes from the expanded card, and a grow failure must be resolved before updating.

Compatibility: installed devices retain their current partition geometry; this
is not an in-place root repartitioning migration. They can receive the smaller
RAUC root image in their larger slots; only a fresh flash adopts smaller roots.
The runtime rule can extend existing data into unused card space, but never
shrinks or moves boot/root partitions. Old 4096 MiB full-slot bundles cannot fit
the new 2560 MiB slots: use compact bundles for updates and rollback on fresh
installs. Runtime growth, physical boot and RAUC update/reboot/rollback still
require board validation before release.
