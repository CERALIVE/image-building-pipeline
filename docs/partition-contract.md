# FROZEN — DO NOT MODIFY WITHOUT REFLASHING ALL DEVICES

> **STATUS: FROZEN** (Stage 0h). This partition layout is baked in at first flash and is
> **near-irreversible in the field** — changing any size or slot role requires a full
> re-flash of every shipped device. Do not edit the MB numbers, slot roles, or the
> single-slot threshold without a coordinated fleet re-flash and a new contract version.
>
> Tasks 25, 26, and 30 depend on this contract being frozen before Stage 1 builds begin.
>
> Contract version: **v2** · A/B production activation: 2026-07-11

---

## 1. Scope & goals

Defines the RAUC A/B redundant partition layout for the CeraLive device image on RK3588
targets (**Orange Pi 5+**, **Radxa Rock 5B+**), plus the single-slot fallback for small
media and the shared `/data` partition that holds all mutable state.

Design rules locked by this contract:

1. **Image-identical OS region.** The boot + rootfs slot sizes are fixed and identical on
   every board and every storage medium, so a single built image flashes onto eMMC, NVMe,
   or microSD without resizing. Only the trailing `data` partition flexes to fill capacity.
2. **Mutable state never lives in a rootfs slot.** Config, logs, WiFi credentials, routing
   state, and host identity live on the shared `data` partition and survive A/B updates.
3. **Kernel rides with the rootfs.** Kernel/DTB/initrd are inside each slot's `/boot`, so an
   OS update swaps kernel + userland atomically. The `boot` partition holds only the
   bootloader environment + slot selector.
4. **No appfs.** App components (`CeraUI`, `cerastream`, `srtla`, `srt`) are `.deb`s inside
   the rootfs → already atomic with the rootfs slot. A separate RAUC appfs is omitted.

---

## 2. Target storage (researched — see evidence §2)

| Board | eMMC | NVMe | microSD | Notes |
|-------|------|------|---------|-------|
| Orange Pi 5+ | socketed module, **16/32/64/128/256 GB**, optional | M.2 2280 PCIe 3.0 **x4** | up to 128 GB | eMMC is a removable module; many units ship without it |
| Radxa Rock 5B+ | onboard, **16/32/64/128/256 GB**, optional | 2× M.2 2280 PCIe 3.0 **x2** | yes | **eMMC pad unpopulated on most shipping boards** → NVMe/SD primary |

- **Smallest eMMC variant offered by either board = 16 GB.** No 8 GB eMMC exists in this stack.
- NVMe targets are always ≥ 240 GB → trivially fit A/B.
- RK3588 idbloader + U-Boot + ATF live in **raw sectors before partition 1** (also mirrored
  in on-board SPI/QSPI NOR). They are **not** a GPT partition and are out of scope for the
  GPT table below, but the **16 MB reserved gap** at the start of the device is mandatory.

---

## 3. A/B LAYOUT — for storage ≥ 16 GB (DEFAULT)

GPT, 1 MiB alignment. Sizes in **MB (= MiB, 2^20 bytes)**.

| # | Partition label | Role | Size (MB) | FS | Mount |
|---|-----------------|------|-----------|----|----|
| — | *(reserved gap)* | RK3588 idbloader + U-Boot + ATF (raw, no GPT entry) | **16** | raw | — |
| p1 | `boot` | U-Boot env + `extlinux/extlinux.conf` slot selector | **256** | vfat (FAT32) | `/boot` (rw, explicit fstab) |
| p2 | `rootfs_a` | RAUC rootfs **slot A** (incl. `/boot` kernel/DTB/initrd) | **4096** | ext4 | `/` (when A active) |
| p3 | `rootfs_b` | RAUC rootfs **slot B** | **4096** | ext4 | `/` (when B active) |
| p4 | `data` | Persistent mutable state (survives A/B) | **remainder** (≥ 2048 floor) | ext4 | `/data` |

**Fixed OS subtotal (p–reserved + p1 + p2 + p3) = 8464 MB.** The raw image also
needs a 1 MiB aligned backup-GPT tail, so `data size = raw capacity − 8465 MiB`.

RAUC slot model (for `system.conf`, defined downstream): symmetric A/B —
`[slot.rootfs.0] bootname=A` → `rootfs_a`, `[slot.rootfs.1] bootname=B` → `rootfs_b`.
`boot` and `data` are shared (not RAUC-managed slots). Reference partitions by
**PARTLABEL** in fstab/`system.conf` (never by FS-UUID — a UUID is filesystem-instance
state rather than the frozen GPT slot identity and can change when a slot is recreated).

The factory image populates **both** rootfs slots from the same known-good rootfs tree.
Slot A is primary on first boot; slot B is an immediately bootable rollback baseline.
An empty B filesystem is not a valid A/B factory image.

Every rootfs carries
`PARTLABEL=boot /boot vfat rw,nodev,nosuid,noexec,umask=0077,shortname=mixed,errors=remount-ro 0 2`
in `/etc/fstab`. This explicit
mount is mandatory: each slot's `/boot` directory already contains its kernel, so
systemd's XBOOTLDR auto-generator intentionally will not mount p1 over that non-empty
directory. U-Boot loads the kernel before Linux starts; once userspace is running,
the shared writable p1 must cover `/boot` so RAUC and U-Boot read and write the same
`/boot/boot_state.txt`.

### 3.1 Capacity fit table (data margin ≥ 10 % required)

| Nominal | Usable (MiB) | Fixed (MB) | data (MB) | data % | Result |
|---------|--------------|-----------|-----------|--------|--------|
| 16 GB | 14,800 | 8,465 | 6,335 | 42.8 % | ✅ A/B |
| 32 GB | 29,600 | 8,465 | 21,135 | 71.4 % | ✅ A/B |
| 64 GB | 59,500 | 8,465 | 51,035 | 85.8 % | ✅ A/B |
| 128 GB | 120,000 | 8,465 | 111,535 | 92.9 % | ✅ A/B |
| 256 GB | 244,000 | 8,465 | 235,535 | 96.5 % | ✅ A/B |
| NVMe ≥ 240 GB | ≥ 228,000 | 8,465 | ≥ 219,535 | ≥ 96 % | ✅ A/B |

Worst case (16 GB) still leaves **42.8 %** for data — comfortably above the 10 % floor.
Usable-capacity model (conservative, rounds real silicon DOWN) is in evidence §3.

---

## 4. SINGLE-SLOT FALLBACK — for storage < 16 GB

For small microSD boots (and any hypothetical < 16 GB eMMC — none are sold). Same rootfs
**image** (4096 MB slot), one rootfs partition, no redundancy.

| # | Partition label | Role | Size (MB) | FS | Mount |
|---|-----------------|------|-----------|----|----|
| — | *(reserved gap)* | idbloader + U-Boot + ATF (raw) | **16** | raw | — |
| p1 | `boot` | U-Boot env + extlinux | **256** | vfat | `/boot` |
| p2 | `rootfs_a` | single rootfs (no B slot) | **4096** | ext4 | `/` |
| p3 | `data` | Persistent mutable state | **remainder** (≥ 2048 floor) | ext4 | `/data` |

Fixed partitions = 16 + 256 + 4096 = **4368 MB**; including the backup-GPT tail,
the minimum raw overhead is **4369 MiB**.

| Nominal | Usable (MiB) | Fixed (MB) | data (MB) | data % | Result |
|---------|--------------|-----------|-----------|--------|--------|
| 8 GB SD/eMMC | 7,400 | 4,369 | 3,031 | 41.0 % | ✅ single-slot |

Single-slot has **no field A/B rollback**: updates apply in place (or via an external
re-flash / recovery image). Use only when the medium is below the threshold.

---

## 5. THRESHOLD — N = 16 GB

```
Nominal storage ≥ 16 GB   →  A/B layout (§3)
Nominal storage <  16 GB   →  single-slot fallback (§4)
```

Derivation (evidence §7): A/B needs the fixed 8464 MB **plus** a ≥ 2048 MB data floor
**and** ≥ 10 % data margin → **≥ 10,512 MB usable**. The offline assembler requires
**10,513 MiB** because the raw image also needs the aligned backup-GPT tail. An 8 GB
medium (7,400 usable) cannot
satisfy this; the smallest eMMC sold (16 GB → 14,800 usable) clears the exact raw
floor by +4,287 MiB. No
storage size exists between 8 GB and 16 GB, so **N = 16 GB** is the clean cut.

The canonical RK3588 factory image is **14,800 MiB**, not 16 GiB: a 16 GiB raw file is
larger than a nominal 16 GB device. Provisioning must read the exact destination capacity
and require `target_size_bytes >= raw_image_size_bytes`; `preflash-verify.sh` enforces that
comparison. Media below the A/B floor must use the single-slot layout or be rejected.

---

## 6. DATA PARTITION CONTENTS (`/data` — the only mutable, update-surviving store)

`data` is shared across both rootfs slots and is the **single source of truth for all
user/runtime state**. Nothing here is touched by a RAUC slot update. Downstream
provisioning wires these via bind-mounts / symlinks (implementation, not contract):

| `/data` path | Holds | Replaces / linked from |
|--------------|-------|------------------------|
| `/data/ceralive/config.json` | CeraUI runtime config | `/opt/ceralive/config.json` (working dir) |
| `/data/ceralive/setup.json` | Setup state | `/opt/ceralive/setup.json` |
| `/data/ceralive/auth_tokens.json` | Auth tokens | `/opt/ceralive/auth_tokens.json` |
| `/data/ceralive/dns_cache.json` | DNS cache | `/opt/ceralive/dns_cache.json` |
| `/data/ceralive/gsm_operator_cache.json` | Modem operator cache | `/opt/ceralive/gsm_operator_cache.json` |
| `/data/ceralive/relays_cache.json` | Relay cache | `/opt/ceralive/relays_cache.json` |
| `/data/ceralive/revision` | Installed UI revision marker | `/opt/ceralive/revision` |
| `/data/ceralive/host_index`, `host.lock` | First-boot hostname index/lock | `/etc/ceralive/host_index`, `hostname.lock` |
| `/data/ceralive/machine-id` | Stable machine identity for host keys, TLS, and setup identifiers | `/etc/machine-id` (persist copy) |
| `/data/nm/system-connections/` | **WiFi credentials / NM profiles** | `/etc/NetworkManager/system-connections/` |
| `/data/log/` | System + app logs | bind-mounted to `/var/log` |
| `/data/srtla/` | Persisted SRTLA routing/bonding state (not the static `rt_tables` seed) | runtime SRTLA state |

Notes:
- The `.deb`-shipped `/etc/ceralive/config.json` (build-debian-package.sh:67) and the
  static `/etc/ceralive/conf.d/*.conf` defaults remain **read-only seeds in the rootfs**;
  the **live, writable** copies live under `/data`.
- `/etc/iproute2/rt_tables` entries and the dhclient/NetworkManager dispatcher hooks
  (customize-image.sh §configure_srtla_routing) are **static seeds in rootfs** — they are
  code, not state, and are reprovisioned by each slot. Only *runtime-derived* routing state
  that must persist goes under `/data/srtla/`.
- `/tmp/srtla_ips` stays on tmpfs (ephemeral by design). `/tmp` is tmpfs (1 GB) per
  `customize-image.sh:466`.

---

## 7. STAGE-4 BUILD OUTPUT

The v2 build pipeline (Stage-4, `v2/lib/assemble-disk.sh` + `v2/lib/build-bundle.sh`) now
emits three artifacts per board under `v2/images/<board>/`:

| Artifact | Description |
|----------|-------------|
| `<ts>.raw` | Flashable disk image (GPT + gap write + boot partition + populated rootfs A and B) |
| `<ts>.raucb` | Signed RAUC OTA bundle (dev key by default; prod key via `CERALIVE_RAUC_PKI_DIR`) |
| `<ts>.raucb.sha256` | SHA-256 checksum of the bundle |

**Production A/B policy (v2):** Rock 5B+ resolves `single_slot_fallback: false`. The
factory assembler writes the same bootable baseline to `rootfs_a` and `rootfs_b`, seeds
`BOOT_ORDER=A B`, and leaves slot A primary. OTA may then write only the inactive slot and
activate it after a successful install.

**Migration from the v1 single-slot image is reflash-only.** In v1, `data` is partition 3
and begins at the exact sector that v2 assigns to `rootfs_b`. Creating B in place would
overwrite live persistent data, while moving `data` is destructive and interruption-prone.
No `.raucb`, boot-state edit, or in-place repartition is an approved migration. Back up
required state, perform a full re-flash with the v2 A/B image, and restore/provision state.

---

## 8. CHANGE CONTROL

Any change to a size, label, slot role, the threshold N, or the `/data` contract is a
**breaking, fleet-wide re-flash** event. Such a change MUST:

1. bump the contract version (v2 → v3) at the top of this file, and
2. be coordinated with a mass re-flash — there is no in-place migration path for the GPT.

---

## 9. x86-ab ADDENDUM — ESP + grubenv layout (Intel N100/N200, AMD mini-PC)

> **Additive only — the RK3588 contract above (§§1–8) is unchanged.** This section
> documents the already-shipped x86 A/B layout produced by
> `v2/lib/assemble-disk-x86.sh` (Task 12). The slot sizes (`rootfs_a`, `rootfs_b`,
> `data`) are **identical** to the RK3588 layout; only p1 and the bootloader model
> differ.

### 9.1 What changes on x86

RK3588 needs a **16 MB raw gap** before p1 for the idbloader + U-Boot + ATF blobs
(written directly to sectors, no GPT entry). x86 boots via **UEFI**, so the platform
firmware lives in the board's own SPI flash — there is **no raw gap**. p1 is instead
an **EFI System Partition** (GPT type `EF00`, FAT32, PARTLABEL `boot`) that holds
GRUB and the `grubenv` boot-selection state.

The bootloader state model also differs. RK3588 uses the staged vendor U-Boot with no
working `fw_setenv`, so its A/B state lives in a hand-rolled text file on the FAT
`boot` partition. x86 GRUB has full persistent env via `grub-editenv`, so the state
lives in a **grubenv** block on the ESP — read by GRUB at boot time and rewritten by
RAUC's native `bootloader=grub` backend on install and `mark-good`.

### 9.2 x86-ab A/B layout

GPT, 1 MiB alignment. Sizes in **MB (= MiB, 2^20 bytes)**.

| # | Partition label | Role | Size (MB) | FS | Mount |
|---|-----------------|------|-----------|----|----|
| — | *(no gap)* | x86 has no raw idbloader/U-Boot/ATF gap — UEFI lives in platform SPI flash | **0** | — | — |
| p1 | `boot` | EFI System Partition: `EFI/BOOT/BOOTX64.EFI` (GRUB removable path), `EFI/BOOT/grub.cfg` (RAUC slot selector), `EFI/BOOT/grubenv` (boot-selection state) | **256** | vfat (FAT32) | `/boot/efi` |
| p2 | `rootfs_a` | RAUC rootfs **slot A** (incl. `/boot` kernel/initrd) | **4096** | ext4 | `/` (when A active) |
| p3 | `rootfs_b` | RAUC rootfs **slot B** | **4096** | ext4 | `/` (when B active) |
| p4 | `data` | Persistent mutable state (survives A/B) | **remainder** (≥ 2048 floor) | ext4 | `/data` |

**Fixed OS subtotal (p1 + p2 + p3) = 8448 MB** (8464 MB on RK3588 minus the 16 MB
raw gap that x86 does not have).

The ESP starts at sector 2048 (the 1 MiB grain) — no leading gap. `systemd-repart
--offline` adopts the pre-seeded ESP and appends the rootfs/data slots.

Single-slot fallback (storage < 16 GB) omits `rootfs_b`; the threshold and data-margin
rules from §§4–5 apply unchanged.

### 9.3 grubenv boot-selection state

RAUC's `bootloader=grub` backend manages two variables per slot in the grubenv block:

```
ORDER=A B          # slot bootnames, priority order; head = primary
A_OK=1             # slot A marked good (1) or not (0)
A_TRY=0            # slot A retry flag (set by RAUC on install; cleared on mark-good)
B_OK=1
B_TRY=0
```

The grubenv lives on the **ESP** (p1), never inside a rootfs slot. A RAUC update
rewrites the inactive rootfs slot — if the grubenv were there, the boot-selection
state would be destroyed on every update (EC5). RAUC rewrites `ORDER`/`<slot>_OK`/
`<slot>_TRY` via `grub-editenv` at install time and on `mark-good`; `grub-ab.cfg`
is the boot-time selector that reads these variables.

### 9.4 RAUC slot model (x86)

`system.conf` for x86 uses `bootloader=grub` with the grubenv path on the ESP:

```ini
[system]
compatible=ceralive-x86_64
bootloader=grub
grubenv=/boot/efi/EFI/BOOT/grubenv

[slot.rootfs.0]
bootname=A
device=/dev/disk/by-partlabel/rootfs_a
type=ext4

[slot.rootfs.1]
bootname=B
device=/dev/disk/by-partlabel/rootfs_b
type=ext4
```

Reference partitions by **PARTLABEL** (same rule as RK3588 — never by FS-UUID).

### 9.5 Build artifacts

`v2/lib/assemble-disk-x86.sh` is the offline producer (the x86 twin of
`lib/assemble-disk.sh`). It uses `sgdisk` to pre-seed the ESP at sector 2048, then
`systemd-repart --offline` to append the rootfs/data slots, then
`grub-mkstandalone` to write `EFI/BOOT/BOOTX64.EFI` into the ESP via `mtools`
(no loop mount, no root). The FROZEN repart slot defs (`20`/`30`/`40-*.conf`) are
reused verbatim; only `platform/x86/10-esp.conf` replaces the RK3588
`10-boot.conf` for p1.

Full rationale and VERIFY-FIRST finding (why mkosi-native `Bootloader=grub` is
incompatible with the offline-assemble model):
[`v2/mkosi/platform/x86/README.md §2`](../v2/mkosi/platform/x86/README.md).
