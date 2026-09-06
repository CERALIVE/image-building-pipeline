# Full firmware and populated-slot safety [EXISTS]

RK3588 selects **only `armbian-firmware-full=26.8.3`**, replacing the trimmed
package. It remains a platform BSP input, never a first-party app package or
mutable sysext. The existing manifest-derived staging, `mkosi-install`, boot
freeze and RAUC slot-copy paths carry it without a second install/hold list.

`manifests/armbian-firmware-content.json` pins the SHA-256 of the **`.deb` archive
file**, not installed content. Both authenticated BSP transports compare their
verified index to this pin before starting the download pool, regardless of cache
enablement; `fetch_bsp` rechecks staged archive bytes, size and control identity.
A same-version re-spin and mixed full/trimmed ownership fail closed. Provenance:
[firmware preflight](firmware-content-preflight.md). Guards:
`tests/firmware-content.test.sh`, `tests/bsp-package-resolution.test.sh` and
`tests/kernel-freeze-guardrails.test.sh`.

## Bluetooth closure

`manifests/rk3588-bluetooth-firmware-roots.txt` was derived after building the
production v7.2 kernel through the existing kernel-build stage. The extracted
Bluetooth/UHID recursive dependency closure contains 26 modules and 71 static
references. Kernel archive hashes are evidence bindings only, never reproducibility
pins. A later image must be checked against **its own** installed modules:

```bash
lib/check-bluetooth-firmware.sh \
  <rootfs>/usr/lib/modules/<kernel-release> <rootfs>/usr/lib/firmware
```

The checker discovers every installed Bluetooth/protocol/UHID module, follows
dependencies within that kernel tree, and fails on unreadable/missing closure
modules or unreviewed static references. It never consults host modules.
The manifest has exactly three classifications:

- `static`: an exact module/reference pair from real `modinfo`.
- `runtime-composed`: a reviewed driver naming family, with a source rationale.
  Every declared root must contain real objects. This is not an exemption for
  arbitrary missing static references that happen to share its directory.
- `reviewed-hardware-gap`: exactly two owner-reviewed static references absent
  from the frozen archive: `btmrvl_sdio` → `mrvl/sd8987_uapsta.bin`, and `btmtk` →
  `mediatek/mt7927/BT_RAM_CODE_MT6639_2_1_hdr.bin`. Neither chip is used by a
  currently shipped target; these modules are carried for future/third-party
  hardware only. They are **not runtime-composed exceptions**. The parser binds
  both the module and exact path; a third exception or a wildcard is rejected.

Board basis: the repository-root `AGENTS.md` firmware-prune and wireless sections,
and `manifests/families/rk3588.yaml`'s radio note (Rock RTL8852BE, Orange AP6275P).
The separate fitted Orange MT7925 observation is not an MT7927 qualification.
Driver basis at Linux v7.2: `btmrvl_sdio.c:285,571,1780` and
`btmtk.c:1586` / `btmtk.h:11`, under `drivers/bluetooth/`.

The platform postinstall snapshots all declared objects before pruning, protects
them from candidate deletion, and checks their survival afterwards. TI's
`ti-connectivity/TIInit_*.bts`, Broadcom upstream and Armbian locations, and the
other enabled vendor families are included. Only proven-unconsumed non-Bluetooth
candidates are removed. Missing tools cannot authorize deletion: the full-image
closure preflight fails; the legacy generic sweep still declines without deletion.

Guards: registered `tests/full-firmware-bluetooth-closure.test.sh` (third missing
object, missing root/object, unknown static reference, duplicate/traversal/broad
glob, candidate-deletion, no-modinfo and zero-parsed-module mutations) and the
unchanged assertions in `tests/firmware-prune.test.sh`.

## Content budgets versus actual slot reserve

The old universal 1.5 GB placeholder is retired for RK3588. Both boards have a
3,500,000,000-byte content ceiling; x86 stays at 1,500,000,000. Historical wet-build
measurements remain unchanged and explicitly predate this adoption. No planning
projection is a build measurement. Future budget review uses per-board wet
measurements and must remain below the frozen 4096 MiB slot minus its reserve.

`lib/shared/slot-reserve.sh` additionally checks each **populated** RK3588 factory
slot after either host or container `mkfs.ext4 -d`, before copying it into the
disk. Preflash reruns it against both sliced slots. Standalone:

```bash
lib/verify-disk.sh check-slot <populated.ext4> rootfs_a
```

Required: **536,870,912 available bytes** and free inodes of at least
`max(ceil(total_inodes / 10), 20000)`. The diagnostic explicitly reports
`field=bavail`, `slot`, `free`, `required`, and inode actual/required/total values.
For a clean, non-bigalloc ext4 image, offline `dumpe2fs` metadata gives Linux
v7.2's `bavail` equivalent as:

```text
max(free_blocks - root_reserved_blocks - min(floor(total_blocks/50),4096),0)
  * block_size
```

The last subtraction is ext4's internal extent reserve (`ext4_init_reserved_space`
and `ext4_statfs`, `fs/ext4/super.c`), in addition to the root-reserved pool.
Unclean/unsupported filesystem metadata is refused, never guessed. Compression
ratios cannot establish this reserve. Neither slot geometry nor the existing
geometry-only verifier changes. Guard: `tests/slot-reserve.test.sh`, including
exact-boundary GREEN, one-byte-under RED, inode rounding/floors, real populated
ext4 metadata and root-reserved-block mutations.

## Validation boundary [PARTIAL]

Kernel/module and archive checks plus synthetic assembled-filesystem checks are
not two full production-image builds. Both full images still require the separate
build/inspection gate. No full-firmware image has been flashed; new adapters and
a physical Bluetooth microphone are **not hardware-validated** by this change.
