# FROZEN — DO NOT MODIFY WITHOUT REFLASHING ALL DEVICES

> **STATUS: FROZEN** (Stage 0h). This partition layout is baked in at first flash and is
> **near-irreversible in the field** — changing any size or slot role requires a full
> re-flash of every shipped device. Do not edit the MB numbers, slot roles, or the
> single-slot threshold without a coordinated fleet re-flash and a new contract version.
>
> Tasks 25, 26, and 30 depend on this contract being frozen before Stage 1 builds begin.
>
> Contract version: **v1** · Date frozen: 2025-06-02

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
4. **No appfs.** App components (`CeraUI`, `ceracoder`, `srtla`, `srt`) are `.deb`s inside
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
| p1 | `boot` | U-Boot env + `extlinux/extlinux.conf` slot selector | **256** | vfat (FAT32) | `/boot` (ro) |
| p2 | `rootfs_a` | RAUC rootfs **slot A** (incl. `/boot` kernel/DTB/initrd) | **4096** | ext4 | `/` (when A active) |
| p3 | `rootfs_b` | RAUC rootfs **slot B** | **4096** | ext4 | `/` (when B active) |
| p4 | `data` | Persistent mutable state (survives A/B) | **remainder** (≥ 2048 floor) | ext4 | `/data` |

**Fixed OS subtotal (p–reserved + p1 + p2 + p3) = 8464 MB.**
`data size = (usable capacity) − 8464 MB`.

RAUC slot model (for `system.conf`, defined downstream): symmetric A/B —
`[slot.rootfs.0] bootname=A` → `rootfs_a`, `[slot.rootfs.1] bootname=B` → `rootfs_b`.
`boot` and `data` are shared (not RAUC-managed slots). Reference partitions by
**PARTLABEL** in fstab/`system.conf` (never by FS-UUID — UUIDs change after a slot update,
and labels are not unique across A/B for the rootfs).

### 3.1 Capacity fit table (data margin ≥ 10 % required)

| Nominal | Usable (MiB) | Fixed (MB) | data (MB) | data % | Result |
|---------|--------------|-----------|-----------|--------|--------|
| 16 GB | 14,800 | 8,464 | 6,336 | 42.8 % | ✅ A/B |
| 32 GB | 29,600 | 8,464 | 21,136 | 71.4 % | ✅ A/B |
| 64 GB | 59,500 | 8,464 | 51,036 | 85.8 % | ✅ A/B |
| 128 GB | 120,000 | 8,464 | 111,536 | 92.9 % | ✅ A/B |
| 256 GB | 244,000 | 8,464 | 235,536 | 96.5 % | ✅ A/B |
| NVMe ≥ 240 GB | ≥ 228,000 | 8,464 | ≥ 219,536 | ≥ 96 % | ✅ A/B |

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

Fixed = 16 + 256 + 4096 = **4368 MB**.

| Nominal | Usable (MiB) | Fixed (MB) | data (MB) | data % | Result |
|---------|--------------|-----------|-----------|--------|--------|
| 8 GB SD/eMMC | 7,400 | 4,368 | 3,032 | 41.0 % | ✅ single-slot |

Single-slot has **no field A/B rollback**: updates apply in place (or via an external
re-flash / recovery image). Use only when the medium is below the threshold.

---

## 5. THRESHOLD — N = 16 GB

```
Nominal storage ≥ 16 GB   →  A/B layout (§3)
Nominal storage <  16 GB   →  single-slot fallback (§4)
```

Derivation (evidence §7): A/B needs the fixed 8464 MB **plus** a ≥ 2048 MB data floor
**and** ≥ 10 % data margin → **≥ 10,512 MB usable**. An 8 GB medium (7,400 usable) cannot
satisfy this; the smallest eMMC sold (16 GB → 14,800 usable) clears it by +4,288 MB. No
storage size exists between 8 GB and 16 GB, so **N = 16 GB** is the clean cut.

Detection at provisioning time: read the block device size; if total bytes ≥ 16e9 (allow a
small tolerance, e.g. ≥ 15.0 GiB to absorb vendor under-provisioning) use the A/B GPT,
otherwise use the single-slot GPT.

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
| `/data/ceralive/machine-id` | Stable machine identity (hostname derives from it) | `/etc/machine-id` (persist copy) |
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
| `<ts>.raw` | Flashable disk image (GPT + gap write + boot partition + rootfs_a) |
| `<ts>.raucb` | Signed RAUC OTA bundle (dev key by default; prod key via `CERALIVE_RAUC_PKI_DIR`) |
| `<ts>.raucb.sha256` | SHA-256 checksum of the bundle |

**Single-slot-first policy (current):** The first shipped image uses the §4 single-slot
layout (`single_slot_fallback: true` in the board manifest). `rootfs_b` is absent; the
`data` partition follows immediately after `rootfs_a`. This is the brick-loop mitigation
for the initial fleet bring-up — a failed health gate on a single-slot image does not
trigger a rollback to an empty B slot.

**A/B follow-up wave (T28):** Enabling full A/B (`single_slot_fallback: false`) is a
separate task that requires hardware validation of the rollback path. It is deferred until
the first single-slot image has been verified on real hardware. Switching from single-slot
to A/B requires a full re-flash (the GPT layout changes — `rootfs_b` is added and `data`
shifts). This is a contract-version bump event (v1 → v2).

---

## 8. CHANGE CONTROL

Any change to a size, label, slot role, the threshold N, or the `/data` contract is a
**breaking, fleet-wide re-flash** event. Such a change MUST:

1. bump the contract version (v1 → v2) at the top of this file, and
2. be coordinated with a mass re-flash — there is no in-place migration path for the GPT.
