# CeraLive v2 mkosi — LAYER MAP

The device image is built as an explicit, composable **four-layer** mkosi stack.
Each layer is a sub-image under `mkosi.images/<layer>/`; the top-level
`mkosi.conf` is a pure orchestrator (`Format=none`) whose global settings
(Distribution / Release / Architecture / Repositories) propagate to all layers.

```
base  ──▶ platform ──▶ runtime ──▶ app          (Dependencies= chain)
 │          │            │           │
 │          │            │           └─ first-party apps (Stage 3 — PLACEHOLDER today)
 │          │            └────────────── OS runtime + system libsrt + RAUC infra (arch-IDENTICAL)
 │          └─────────────────────────── board/SoC BSP + HW-accel (the ONLY arch-specific layer)
 └────────────────────────────────────── minimal Debian bookworm (systemd/udev/ssh/dbus)
```

`mkosi build` builds the whole chain in order (top-level `Dependencies=app`); the
orchestrator (`lib/orchestrate.sh`) ships `build/app` as the final rootfs tree.
Only the later **assembly** step (Stage 4) turns the merged tree into a
`Format=disk` image (D4 partition layout + dm-verity + A/B / RAUC).

---

## Layer 1 — BASE (`mkosi.images/base/`)

**What:** the irreducible minimal Debian bookworm rootfs tree.

| Contents | |
|---|---|
| Packages | `systemd`, `udev`, `openssh-server`, `dbus` — and ONLY these (+ transitive deps) |
| Output | `Format=directory`, `Bootable=no`, `WithDocs=no` |
| apt sources | none baked (mkosi keeps build sources in its sandbox, not the rootfs) |

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

**NOT here:** the SRT transport library (`libsrt`) — it is a stable, arch-neutral
OS package and lives in **runtime**, so a libsrt bump never forces a BSP rebuild.

---

## Layer 3 — RUNTIME (`mkosi.images/runtime/`)  ← arch-IDENTICAL

**What:** the CeraLive OS runtime + system configuration, on top of `platform`.
**Identical on every architecture** — zero board/SoC assumptions.

| Contents | Source |
|---|---|
| Canonical runtime package set (45 pkgs) | `manifests/packages/shared.list` (+ resolved `<family>.delta.list`, currently empty) |
| **System SRT transport library** `libsrt1.5-openssl` | shared.list (OS-update infra section) |
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

`libsrt` (the SRT transport library) is a stable shared library that **both**
`ceracoder` and `srtla` link at runtime. It lives in the **runtime OS slot**, NOT
the app layer, because:

1. The app sysext images for ceracoder+srtla stay small (no bundled libsrt).
2. A libsrt update flows through the **RAUC OS slot** (atomic), not through a sysext.
3. Both architectures (rk3588, x86) use the **same** package name.

The runtime layer installs the **system** `libsrt1.5-openssl` (Debian bookworm).
The first-party **CERALIVE/srt fork `.deb`** is a *separate* artifact and lands in
the **app** layer (Stage 3) — do not conflate the two.

**NOT here:** HW-accel GStreamer / kernel / BSP (→ platform); first-party apps
(→ app). Board capture/quirk udev rules (→ platform-specific module, task 20).

---

## Layer 4 — APP (`mkosi.images/app/`)  ← arch-IDENTICAL · **PLACEHOLDER in Stage 2**

**What:** the first-party CeraLive applications, on top of `runtime`.

| Will install (Stage 3, tasks 22-23) | Delivery |
|---|---|
| `ceracoder`, `srtla` | `/usr/bin` (sysext-friendly; link the runtime system libsrt) |
| `CeraUI` | `/opt/ceralive` + `/var` (appfs/`.deb`; heavy `/etc`+`/var/www` → not sysext, per redesign Task 0d) |
| CERALIVE/srt fork `.deb` | the first-party libsrt fork (distinct from the runtime system libsrt) |

**STATUS (Stage 2): PLACEHOLDER — installs nothing.** `mkosi.images/app/mkosi.conf`
+ `mkosi.postinst.chroot` establish the layer boundary so the four-layer model is
explicit and buildable now; the placeholder postinst only performs staging hygiene
(drops `/opt/ceralive-staging` so it never ships). The real install lands in
Stage 3. Consequently the parity gate reports `ceracoder/srtla/CeraUI` gaps until
Stage 3 — **intended**, matching the project's non-vacuity/deferral pattern.

**WHY a separate layer:** apps update independently of the OS (sysext / appfs),
while libsrt + the OS update atomically via RAUC. Keeping apps out of runtime keeps
app images small and the OS slot stable.

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
| First-party app install (ceracoder/srtla/CeraUI + CERALIVE/srt fork `.deb`) | **Stage 3 (tasks 22-23)** |
| `rauc-hawkbit-updater` active install (backport `.deb` + apt.ceralive.tv serving) | **Stage 4 OTA** |
| `Format=disk` assembly (partitions, dm-verity, A/B, RAUC bundle) | **Stage 4** |

## Cross-references

- `manifests/packages/shared.list` — canonical runtime package set (Task 18)
- `manifests/families/rk3588.yaml` — platform BSP + HW-accel package names (Task 11)
- `lib/orchestrate.sh` — reads shared.list → `$SHARED_PACKAGES`; builds the chain
- `.omo/notepads/image-platform-redesign/decisions.md` — D1 (x86 encode), D3 (vendor kernel), D4 (partitions), Task 5 (RAUC/hawkbit pins)
