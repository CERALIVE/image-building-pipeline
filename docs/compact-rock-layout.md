# Compact ROCK 5B+ fresh-install layout

Fresh ROCK 5B+ images use the existing 16 MiB loader gap, 256 MiB boot,
two 2560 MiB ext4 root slots and a 256 MiB initial data partition, plus 1 MiB
for GPT alignment/tail: 5649 MiB raw. This is a transport size, not a supported
physical media size. Compact installations require at least 7 GiB
(7,516,192,768 bytes) of measured media capacity; a marketed card label is not
proof of capacity. Other boards keep the v2 geometry.
Labels, partition types, boot selection and independent A/B rollback are unchanged.
The committed v2 repart definitions remain intact; the assembler stages the
ROCK size overrides. The shared layout helper sizes both factory and signed
verity/adaptive RAUC rootfs images at 2560 MiB so updates fit either slot.
The bundle inspector derives the exact required full-slot size from the
authenticated compatible using the same helper, independently of ambient build
board settings. Verity, adaptive-index, root-image filename and exact-size checks
remain strict for both compact ROCK and existing 4096 MiB board profiles.

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
explicit bench labels). Start offsets and sizes must also prove that physical
ranges follow that sequence without overlap; partition numbers alone do not
establish physical order. Unknown, missing, duplicate or reordered partitions are
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
before updating. Finite physical qualification is described below.

Compatibility: installed devices retain their current partition geometry; this
is not an in-place root repartitioning migration. They can receive the smaller
RAUC root image in their larger slots; only a fresh flash adopts smaller roots.
The runtime rule can extend existing data into unused card space, but never
shrinks or moves boot/root partitions. Old 4096 MiB full-slot bundles cannot fit
the new 2560 MiB slots: use compact bundles for updates and rollback on fresh
installs. Finite ROCK 5B+ qualification of the combined candidate passed automatic first
and repeat growth, signed compact A/B install, health confirmation, operator
rollback and persistent-data checks. This does not qualify interruption recovery,
legacy-layout OTA filesystem expansion, other boards or sustained operation.


## Data readiness and failure policy

Partition growth orders before `data.mount`; the fstab grows ext4 on mount.
The readiness service waits for the mount and `systemd-growfs@data.service`.
For compact 2560 MiB roots, health confirmation and application/RAUC update
consumers require successful partition and filesystem growth, writable ext4 data
on the boot disk, a filesystem extent filling the partition within 1 MiB (from ext4 superblock
geometry, not payload blocks excluding metadata), and at least
1 GiB available for staging. Preflash refuses targets below the shared 7 GiB
physical minimum even when the raw image fits; runtime readiness checks the same
boot-disk minimum. At 7 GiB, the unchanged gap/boot/two roots and a conservative
1 MiB GPT/alignment allowance leave at least 1775 MiB for the grown data
partition. The 256 MiB factory filesystem must grow to use it. This partition
floor is not an available-byte promise for pre-existing user data: the live
1 GiB availability check still applies. This accommodates the measured
837,814,917-byte signed bundle; future larger updates need their own space checks. Legacy root
partition sizes bypass this new gate rather than failing solely on repart.

Failure or pending growth refuses mark-good and update owners, with an actionable
journal error. Capacity refusal exits 78 with a local-rescue action: use larger
media or free data, then retry. The readiness service is a oneshot with no restart
and a 30-second execution timeout; it never schedules a reboot or marks good.
Undersized or full media stays unconfirmed until an operator repairs it.
On operator-initiated reboots the existing selector spends the finite A/B attempt
budgets (normally three each), then last-resort boots the head slot without
refreshing the counters. This is not an automatic readiness-driven reboot or
endless A/B alternation; last-resort boot can still remain unconfirmed and need
local recovery. The readiness gate adds no hard dependency from SSH or rescue,
but this does not guarantee remote recovery. Production images disable SSH by
default. SSH requires prior operator enablement and a successful identity/key
guard; that guard writes persistent key and authorization state on `/data`.
A read-only `/data` can therefore prevent SSH startup even when SSH was enabled.
Preserving an operator's enablement choice across slots does not remove these
identity and storage prerequisites.

Arrange verified local console or bootable rescue-media access before installation;
do not rely on SSH as the only recovery path. Use that access when SSH is disabled
or its guard cannot complete. Inspect the partition-growth and growfs journals,
repair the disk/filesystem cause, then reboot to retry the whole ordered sequence.
A successful partition operation alone cannot certify filesystem growth.
Failed-growth recovery and interrupted GPT/ext4 growth still require physical
hardware qualification.

## Payload prerequisites and remaining qualification

The measured build combines the ROCK firmware-policy reduction (586,989,568 bytes)
and the package archive cleanup in [#241](https://github.com/CERALIVE/image-building-pipeline/pull/241)
(193,695,744 bytes). A layout-only adoption is not the measured payload stack.
Actual availability was 616,079,360 bytes (587.54 MiB), only 79,208,448 bytes
(75.54 MiB) above the unchanged 512 MiB reserve floor. Gross headroom is not
available update reserve. Rebuild the exact proposed stack and budget dependency
growth; retain byte/inode gates. Interrupted GPT/ext4 expansion, power-cut recovery,
legacy-layout OTA filesystem growth/mirroring and the new refusal/recovery path
on physical hardware remain separate qualification steps.
