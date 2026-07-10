# CeraLive v2 mkosi — LAYER MAP

The device image is built as an explicit, composable mkosi stack: four
`Format=directory` rootfs layers plus a Stage-4 `Format=disk` assembly. Each layer
is a sub-image under `mkosi.images/<layer>/`; the top-level `mkosi.conf` is a pure
orchestrator (`Format=none`) whose global settings (Distribution / Release /
Architecture / Repositories) propagate to all layers.

```
base  ──▶ platform ──▶ runtime ──▶ app  ──▶ disk     (Dependencies= chain)
 │          │            │           │        │
 │          │            │           │        └─ Format=disk: D4 partition layout (Stage 4)
 │          │            │           └─ first-party apps (Stage 3 — PLACEHOLDER today)
 │          │            └────────────── OS runtime + RAUC infra (arch-IDENTICAL)
 │          └─────────────────────────── board/SoC BSP + HW-accel (the ONLY arch-specific layer)
 └────────────────────────────────────── minimal Debian bookworm (systemd/udev/ssh/dbus)
```

`mkosi build` builds the rootfs chain in order (top-level `Dependencies=app`); the
orchestrator (`lib/orchestrate.sh`) ships `build/app` as the final rootfs tree. The
**assembly** step (Stage 4, `mkosi.images/disk/` + `lib/assemble-disk.sh`) turns
that tree into a `Format=disk` image (D4 partition layout). dm-verity + A/B / RAUC
slot activation are layered on later (task 26).

---

## Layer 1 — BASE (`mkosi.images/base/`)

**What:** the irreducible minimal Debian bookworm rootfs tree.

| Contents | |
|---|---|
| Packages | `systemd`, `udev`, `openssh-server`, `dbus` — and ONLY these (+ transitive deps) |
| Output | `Format=directory`, `Bootable=no`, `WithDocs=no` |
| apt sources | none baked (mkosi keeps build sources in its sandbox, not the rootfs). Build-time components are `main` only (Task 18) — the minimum to assemble; `non-free-firmware` is added back **only** on the device by the runtime postinst's `debian.sources` |

**WHY:** a tiny, stable, arch-parametric foundation that every platform family
shares. Distribution/Release/Architecture are inherited from the top-level config,
so the same base definition builds arm64 (RK3588) or x86-64 unchanged. Bootloader
concerns belong to platform/assembly, never here.

**NOT here:** kernel, board/BSP packages, GStreamer, libsrt, any first-party app.

---

## Layer 2 — PLATFORM (`mkosi.images/platform/`)  ← the ONLY arch-specific layer

**What:** the board/SoC Board Support Package, on top of `base`.

| Contents | Source |
|---|---|
| HW-accel GStreamer plugin (`gstreamer1.0-rockchip1`) + runtime multimedia config (`rockchip-multimedia-config`) | family manifest `hw_accel_gstreamer_plugins` / `gstreamer_runtime_packages` |
| Kernel / DTB / U-Boot blob / firmware (only when `INSTALL_BOOT_BSP=1`) | family manifest `kernel_packages` / `dtb_packages` / `uboot_packages` / `firmware_packages` |

**WHY:** these packages are kernel-coupled and SoC-specific. The HW-accel plugin
(Rockchip MPP) is bound to the vendor kernel (decision D3) and must NOT live in
the app layer. Every package **name** is resolved from the board+family manifest
by `lib/resolve.sh` and passed in via the environment — there is zero hardcoded
board logic in the layer config. Adding a new board never edits this layer.

**This is the only place arch/SoC tokens (`rk3588`, `rockchip`, `vendor`, `arm64`)
are allowed.** On an x86 build the platform postinst is a clean pass-through
(no RK3588 BSP to add).

**NOT here:** the SRT transport library (`libsrt`) — the first-party CeraLive
runtime package is installed in the App layer, never in the BSP.

---

## Layer 3 — RUNTIME (`mkosi.images/runtime/`)  ← arch-IDENTICAL

**What:** the CeraLive OS runtime + system configuration, on top of `platform`.
**Identical on every architecture** — zero board/SoC assumptions.

| Contents | Source |
|---|---|
| Canonical runtime package set (45 pkgs) | `manifests/packages/shared.list` (+ resolved `<family>.delta.list`, currently empty) |
| **CeraLive SRT transport library** `libsrt1.5-ceralive` | first-party staging, installed in App |
| RAUC A/B client `rauc` + `u-boot-tools` | shared.list (decisions.md Task 5) |
| `rauc-hawkbit-updater` | **commented PLACEHOLDER** in shared.list (Stage 4 OTA; backport `.deb`, not in bookworm) |
| System config (`mkosi.postinst.chroot`) | ceralive user+groups, deb822 apt sources, mTLS+GPG `apt.ceralive.tv` repo, udev hardware-access rules, streaming sysctl, NetworkManager, **SRTLA source-policy routing**, services, first-boot hostname |

**Package source of truth = `shared.list`.** There is no inline hardcoded package
list. `lib/orchestrate.sh` reads `shared.list` (+ family delta), forwards it as
`$SHARED_PACKAGES`, and `runtime/mkosi.postinst.chroot::install_runtime_packages`
installs exactly that set (after writing the Debian sources, mirroring how the
platform layer does its in-chroot apt install). `lib/parity-check.sh` still diffs
the built rootfs against `configs/base/ceraui-base.conf`.

### libsrt — the key placement decision

`libsrt` is installed as the first-party `libsrt1.5-ceralive` package in the App
layer. It provides both Debian TLS-flavor virtual package names and ships a
`libsrt-gnutls.so.1.5` alias to the same forked `libsrt.so.1.5`. GStreamer and
cerastream's direct FFI therefore load one CeraLive implementation, not two TLS
flavor builds in one process.

**NOT here:** HW-accel GStreamer / kernel / BSP (→ platform); first-party apps
(→ app). Board capture/quirk udev rules (→ platform-specific module, task 20).

---

## Layer 4 — APP (`mkosi.images/app/`)  ← arch-IDENTICAL · **Stage 3: REAL INSTALL**

**What:** the first-party CeraLive applications, on top of `runtime`.

| Installs (the `.deb`) | In-image path | OTA-delivery backend |
|---|---|---|
| `libsrt1.5-ceralive` | `/usr/lib/<triplet>` | first-party runtime ABI payload |
| `cerastream`, `srtla-send-rs` | `/usr/bin` | sysext/app binary payload |
| `CeraUI` (`ceralive-device` `.deb`) | `/usr/local/bin` + `/etc` + `/var/www` | appfs payload (`mkosi/app/build-ceraui-appfs.sh`) |

**STATUS (Stage 3): REAL INSTALL.** `mkosi.images/app/mkosi.postinst.chroot` installs
every staged first-party `.deb` from `/opt/ceralive-staging` with no downloads,
replaces any Debian SRT TLS flavor with `libsrt1.5-ceralive`, asserts the
`cerastream`/`srtla_send` binaries landed, prunes non-RK3588/headless payload, then
drops the staging tree so it never ships. **The base
image bakes each `.deb` into the rootfs** (`docs/partition-contract.md` §4 "No appfs":
atomic with the RAUC slot); the **sysext/appfs split is the OTA-delivery contract**, not
an in-image install difference (a later sysext refresh merely shadows the baked-in
binary). In CI (`.debs` fetched) the parity gate clears the first-party check via the
`ceraui→ceralive-device` alias in `lib/parity-check.sh`; an
**offline/dev build stages no `.debs`** → installs nothing → the gate WARNs on the
absent first-party packages, by design (non-vacuity/deferral pattern).

**WHY a separate layer:** apps update independently of the OS (sysext / appfs),
while the CeraLive SRT runtime and applications are installed together from the
first-party staging set. Keeping Debian libsrt out of runtime prevents a second
implementation from entering the process.

**OUT OF SCOPE here:** moving CeraUI from appfs to sysext — a CeraUI-REPO change
fully specified in `v2/docs/deferred-ceraui-sysext.md` (units/udev/config/www must
first relocate off `/etc`+`/var`). Do not implement it in this pipeline.

---

## Layer 5 — DISK ASSEMBLY (`mkosi.images/disk/`)  ← Stage 4 · `Format=disk`

**What:** the ONLY `Format=disk` image — turns the finished `app` rootfs tree into
the actual flashable, partitioned disk per the FROZEN
[`docs/partition-contract.md`](../../docs/partition-contract.md) §3 (v1).

```
(16 MB raw gap, no GPT entry) | boot vfat 256M | rootfs_a ext4 4096M
                              | rootfs_b ext4 4096M | data ext4 remainder >=2048M
```

| Contents | Source |
|---|---|
| Partition geometry (sizes/labels/FS) | `../../repart/*.conf` via `RepartDirectories=` — one systemd-repart def per partition; single source of truth, never duplicated |
| Root tree populating the slots | `BaseTrees=%O/app` |
| `Bootable=no` | bootloader (idbloader+U-Boot+ATF) is a Platform-layer artifact, dd'd into the 16 MB gap — not mkosi's job |

**References are by `PARTLABEL`, never FS-UUID** (a slot update changes FS-UUIDs;
the two rootfs labels are not unique across A/B). `Label=` in the repart def ==
`PARTLABEL=` on device.

### Two contract realities systemd-repart cannot express alone

`lib/assemble-disk.sh` is the board-faithful Stage-4 producer/verifier (offline:
no root, no loopback). It handles what plain `RepartDirectories=` cannot:

1. **The 16 MB raw bootloader gap (no GPT entry).** systemd-repart has no
   `Offset=` (verified on systemd 260) and starts p1 at the 1 MB grain. The
   assembler PRE-SEEDS the GPT with `sgdisk` so `boot` begins at sector 32768
   (16 MB); repart then ADOPTS that partition (gap preserved) and appends the
   rest. The growable trailing `data` partition packs p1–p4 contiguous.
2. **Single-slot fallback.** `RepartDirectories=` cannot conditionally drop a
   file, so when `$SINGLE_SLOT_FALLBACK=true` (from the board manifest
   `single_slot_fallback:`, surfaced by `lib/resolve.sh`, exported by
   `lib/orchestrate.sh`) the assembler stages the repart set WITHOUT
   `30-rootfs_b.conf` → a 3-partition disk (`boot`, `rootfs_a`, `data`), no B
   slot. Both current boards are ≥ 16 GB ⇒ flag `false` ⇒ `rootfs_b` present.

### Built explicitly (not in the default `Dependencies=app` chain)

The default `mkosi build` stops at the `app` rootfs tree (the parity gate runs on
`build/app`). The disk image is produced in a distinct Stage-4 step
(`lib/assemble-disk.sh build` offline, or `mkosi --image disk`).

**NOT here (deferred to task 26):** A/B slot **flipping** / RAUC `system.conf` +
bootcount + `bootname`, dm-verity, the `*.raucb` bundle. This layer lays down the
GEOMETRY + empty filesystems only. FS is **ext4** per the frozen contract;
squashfs+verity is the RAUC bundle format (task 26), not the on-disk slot.

---

## Arch-parametricity contract

| Layer | Arch-specific? | Enforcement |
|---|---|---|
| base | no (inherited Distribution/Arch) | — |
| platform | **YES** (the only one) | manifest-resolved package names; x86 build = pass-through |
| runtime | **no** | `grep -r 'rk3588\|rockchip\|vendor' mkosi.images/runtime/` ⇒ empty (evidence `task-19-parametric.txt`) |
| app | **no** | placeholder; apps are encoder-agnostic (decision D1) |

So x86 reuses the **same** runtime + app configs unchanged; only the platform
family manifest differs.

---

## Intentionally deferred

| Item | Deferred to |
|---|---|
| Chroot **customization modules** (board capture/quirk udev rules, per-board hooks driven by manifest `quirks:`) | **task 20** |
| First-party app install (cerastream / srtla / CeraUI `.deb`s) | **Stage 3 (tasks 22-23)** |
| `rauc-hawkbit-updater` active install (backport `.deb` + apt.ceralive.tv serving) | **Stage 4 OTA** |
| A/B slot **flipping** / RAUC `system.conf` + bootcount + `bootname`, dm-verity, `*.raucb` bundle | **task 26** |

`Format=disk` partition **layout** is DONE (task 25 — Layer 5 above): the frozen
D4 geometry (16 MB gap + boot + rootfs_a/b + data), single-slot fallback, and
PARTLABEL refs. Only slot *activation* (the A/B flip) + verity/RAUC remain.

## Cross-references

- `manifests/packages/shared.list` — canonical runtime package set (Task 18)
- `manifests/families/rk3588.yaml` — platform BSP + HW-accel package names (Task 11)
- `mkosi/repart/` + `mkosi/repart/README.md` — Stage-4 partition defs (Task 25)
- `lib/assemble-disk.sh` — Stage-4 disk assembler/verifier (Task 25)
- `../../docs/partition-contract.md` — FROZEN D4 layout (Task 8, v1)
- `lib/orchestrate.sh` — reads shared.list → `$SHARED_PACKAGES`; builds the chain
