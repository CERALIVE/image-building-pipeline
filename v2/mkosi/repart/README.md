# CeraLive v2 — `repart/` (Stage 4 disk partition layout)

systemd-repart partition definitions that implement the **FROZEN** A/B layout from
[`../../../docs/partition-contract.md`](../../../docs/partition-contract.md) §3 (contract
**v1**). One `*.conf` per GPT partition; files are applied in sort order.

> These numbers are FROZEN. Changing a size, label, FS, or the partition count is a
> breaking, fleet-wide **re-flash** event — see the contract's Change Control §7.

## Layout (A/B, storage ≥ 16 GB — the default for both current boards)

| sort key | file | PARTLABEL | role | FS | size |
|---|---|---|---|---|---|
| — | *(no file — see "16 MB gap")* | *(none)* | idbloader + U-Boot + ATF (raw) | raw | **16 MB** |
| 10 | `10-boot.conf` | `boot` | U-Boot env + extlinux selector | vfat | **256 MB** |
| 20 | `20-rootfs_a.conf` | `rootfs_a` | RAUC slot A | ext4 | **4096 MB** |
| 30 | `30-rootfs_b.conf` | `rootfs_b` | RAUC slot B | ext4 | **4096 MB** |
| 40 | `40-data.conf` | `data` | persistent mutable state | ext4 | **remainder ≥ 2048 MB** |

Fixed OS subtotal (16 + 256 + 4096 + 4096) = **8464 MB**; `data` = usable − 8464 MB.

## Reference by PARTLABEL, never FS-UUID

Every downstream consumer (fstab, RAUC `system.conf`, extlinux) references these
partitions by **`PARTLABEL=`** (the GPT partition *name*, set via repart `Label=`).
FS-UUIDs are forbidden: a RAUC slot update reformats a rootfs slot and changes its
FS-UUID, and the two rootfs slots are not uniquely identifiable by FS label. The GPT
PARTLABEL is stable across updates. `Label=` here == `PARTLABEL=` on the device.

## The 16 MB raw bootloader gap (no GPT entry)

The RK3588 boot ROM loads `idbloader` from sector 0x40 (32 KB) and the U-Boot + ATF
FIT from sector 0x4000 (8 MB); partition 1 must therefore start at **16 MB**. The gap
is **raw, with NO GPT partition entry** (contract §2).

systemd-repart has **no `Offset=`** key (verified on systemd 260) and places its first
partition at the 1 MB grain — it *cannot* express a 16 MB leading gap on its own.
`lib/assemble-disk.sh` therefore **pre-seeds** the GPT with `sgdisk`, creating the
`boot` partition at sector 32768 (16 MB), then runs systemd-repart with these defs:
repart **adopts** the existing `boot` partition (leaving the 16 MB gap intact) and
appends `rootfs_a [/rootfs_b] / data` after it. The `boot` def here is the size/label/
FS source of truth; the *offset* is enforced by the assembler. See that script and
`../../LAYER-MAP.md` (assembly layer).

## Single-slot fallback (storage < 16 GB — contract §4)

When the board manifest sets `single_slot_fallback: true`, the resolver surfaces
`$SINGLE_SLOT_FALLBACK=true` and `lib/assemble-disk.sh` **drops `30-rootfs_b.conf`**
from the active repart set: the disk then has `boot`, `rootfs_a`, `data` only (no B
slot, no field rollback). `data` still has a ≥ 2048 MB floor. Both current boards
(`orange-pi-5-plus`, `rock-5b-plus`) ship ≥ 16 GB media, so the flag is `false` and
`rootfs_b` is present.

## Why ext4, not squashfs, for the rootfs slots

The frozen contract pins **ext4** for `rootfs_a` / `rootfs_b` (and `data`). squashfs +
dm-verity is the **RAUC bundle** (`*.raucb`, `format=verity`) artifact produced in
task 26 (`Verity=` + `SplitArtifacts=partitions,roothash`), **not** the on-disk slot
filesystem. Do not "compress" the on-disk slots — that would deviate from the contract.

## NOT implemented here (deferred)

- **A/B flipping / slot activation** (RAUC `system.conf`, bootcount, `bootname`) → task 26.
- **dm-verity / `*.raucb`** bundle → task 26.
- **`/var` + WiFi bind-mounts onto `data`** → task 30.

This task lays down the GEOMETRY only.
