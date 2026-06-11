# Cog + WPEWebKit Display Add-On — Packaging & libmali Strategy (W4)

**Status:** `[PARTIAL]` — packaging path validated (A1) and libmali strategy fixed
(A2) against the real bookworm arm64 apt index; on-hardware **render QA is
gated** on a physical RK3588 (Task 1 spike verdict: NO-GO).
**Scope:** image-building-pipeline only (chassis/packaging ownership per DC-1).
**Evidence:** [`test-results/task-25-cog-packaging.txt`](../../test-results/task-25-cog-packaging.txt).

This is the concrete **W4 build recipe** for shipping **Cog** (the single-window
WPE WebKit kiosk browser) as a **feature sysext add-on** — i.e. an optional
display engine delivered through the same sysext class as `srtla`
and managed by the W3 add-on manager. It is a lighter alternative to the
cage + Chromium kiosk stack specified in [`kiosk-display.md`](kiosk-display.md);
choosing Cog-vs-Chromium as the *default* engine is a separate decision — this
doc only fixes **how Cog is acquired and packaged**, and **where the Mali GPU
userspace comes from**.

---

## 0. TL;DR — the one fact that changes the plan

The carried-forward assumption was *"Cog is not in Debian bookworm — we must
backport or build from source."* **That is stale.** The entire Cog + WPE WebKit
stack ships in **bookworm `main` for `arm64`**, maintained by Igalia (Cog's own
author) and the Debian WebKit team:

| Package | Version (bookworm/arm64) | Role |
|---|---|---|
| `cog` | **0.16.1-1** | Single-window WPE WebKit kiosk browser |
| `libwpewebkit-1.1-0` | **2.38.6-1** | WebKit content engine (the renderer) |
| `libwpe-1.0-1` | **1.14.0-1** | Base WPE platform library |
| `libwpebackend-fdo-1.0-1` | **1.14.2-1** | FreeDesktop.org (Wayland/EGL) backend |

So the acquisition path is **plain `apt` from the apt source the container build
already uses** — no backport, no third-party repo, no from-source toolchain.
This is the most reproducible path available and is the chosen one (§2).

The Mali-G610 **GPU userspace** (`libmali-valhall-g610-*`) is the opposite story:
it is **not** in bookworm and **not** in Armbian's main feed — it comes from the
Rockchip/Radxa BSP and is a **Platform-layer** artifact. The Cog feature sysext
therefore **excludes** it and relies on the Platform-layer merge, exactly the way
the first-party app sysexts exclude `librockchip_mpp.so*` (§5).

---

## 1. Availability finding (verified against the real apt index)

Verified by grepping the **exact** `Packages` index the containerized build
resolves against
(`v2/mkosi/build/app/var/lib/apt/lists/deb.debian.org_debian_dists_bookworm_main_binary-arm64_Packages`),
not a web lookup. Full transcript in the evidence file.

```
Package: cog
Version: 0.16.1-1
Architecture: arm64
Maintainer: Alberto Garcia <berto@igalia.com>
Depends: ... libwpe-1.0-1 (>= 1.14.0), libwpebackend-fdo-1.0-1 (>= 1.10.0),
         libwpewebkit-1.1-0 (>= 2.34.0) ...
Description: Single-window web browser based on WPE WebKit

Package: libwpewebkit-1.1-0
Source: wpewebkit
Version: 2.38.6-1
Architecture: arm64
Description: Web content engine for embedded devices
```

Newer releases exist downstream (`cog` 0.18.x / `wpewebkit` 2.44.x in **trixie**,
2.52.x in **sid**) but are **not** required: bookworm's `cog` 0.16.1 + WPEWebKit
2.38.6 satisfy each other's version floors and are security-tracked by the Debian
WebKit team for the bookworm lifetime.

**No Mali-G610 Valhall `libmali` in bookworm `main`.** The only `libmali*` matches
in the index are the unrelated `libmaliit-*` (Maliit on-screen keyboard); the
`valhall`/`g610` string matches are a Debian *maintainer* named "valhalla", not a
GPU package. Confirmed in the evidence file.

---

## 2. Chosen acquisition path — **Option A: apt from bookworm `main`**

| Option | What | Verdict |
|---|---|---|
| **A. apt from bookworm `main`** | `apt-get` the `cog` + WPE closure from the apt source the build already trusts | ✅ **CHOSEN** |
| B. first-party backport / custom `.deb` | rebuild trixie's 0.18.x for bookworm, sign, serve via `apt.ceralive.tv` | ❌ unnecessary — pure maintenance burden for no functional gain |
| C. build-from-source in the container | meson build of Cog + WPEWebKit | ❌ heaviest path; WPEWebKit is a multi-hour C++ build; reproducibility + toolchain cost for zero benefit |
| D. third-party repo (Igalia/wpewebkit.org) | add an external apt source | ❌ adds a new trust root; no upstream bookworm/arm64 `.deb` repo exists anyway |

**Why A wins on every axis that matters here:**

- **Trust:** signed by the Debian archive key already pinned in the builder
  (`v2/ci/Dockerfile` bakes `debian-archive-keyring`). No new trust root, unlike D.
- **Reproducibility:** the exact versions are pinnable; the same apt snapshot
  yields byte-identical inputs, fitting the repo's reproducible-build contract.
- **Cost:** zero build toolchain, zero serving infrastructure (vs B/C).
- **Security:** rides Debian's WebKit security updates for bookworm — no private
  CVE-tracking burden.

**Trade-off (documented honestly):** bookworm pins WebKit **2.38.6**, older than
trixie's 2.44. CSS feature currency (OKLCH, Tailwind v4 — see kiosk-display.md's
Chromium ≥111 constraint) MUST be confirmed during render QA (§7). If 2.38 proves
insufficient, the *same* Option-A mechanism applies against a trixie/backport apt
snapshot — the recipe does not change, only the pinned version does.

### Version pinning

Pin `cog` and `wpewebkit` in `versions.yaml` **after** render QA passes on
hardware. Until then they float at the bookworm `main` versions above; the recipe
records the validated versions so a drift is visible.

---

## 3. Dependency closure (what the sysext actually carries)

`cog`'s runtime closure, minus everything the Runtime OS layer already ships
(GStreamer core, glib, cairo, fontconfig, freetype, etc. — see
`manifests/packages/shared.list`), minus the Platform-owned GPU userspace (§5):

| Carried in the sysext | Installed size | Note |
|---|---|---|
| `libwpewebkit-1.1-0` | **81 398 KB** (~80 MB) | the renderer — dominant term |
| `libicu72` | **36 266 KB** (~35 MB) | WebKit's Unicode dep; large, likely *new* |
| `cog` | 622 KB | the launcher binary |
| `libwpebackend-fdo-1.0-1` | 158 KB | Wayland/EGL backend |
| `libwpe-1.0-1` | 88 KB | base WPE lib |
| `libsoup-3.0-0` | 740 KB | HTTP stack |
| `libepoxy0` | 1 452 KB | GL dispatch |
| `libharfbuzz-icu0` | 1 619 KB | text shaping ↔ ICU |
| `libwebp7` / `libwoff1` / `libopenjp2-7` / `liblcms2-2` | ~1.5 MB total | image/font codecs |
| `libmanette-0.2-0` | 215 KB | gamepad (optional; a `cog` hard-dep in bookworm) |

| Merge-provided (NOT bundled) | Source layer |
|---|---|
| `libgstreamer1.0-0`, `-plugins-base`, `-gl` and the GStreamer plugin set | **Runtime** (`shared.list` already lists the GStreamer stack) |
| `libglib2.0-0`, `libcairo2`, `libfontconfig1`, `libfreetype6`, … | **Runtime** (base/runtime closure) |
| `bubblewrap` (0.8.0), `xdg-dbus-proxy` (0.1.4) — WebKit sandbox | **Runtime** if present, else add to the add-on closure |
| `libmali-valhall-g610-*` (libEGL/libGLESv2/libgbm) | **Platform** (§5) — **excluded** from the sysext |

> Building the sysext from the **full** `apt` download closure and then **pruning**
> the Platform/Runtime-owned libs (the existing `sysext-build.lib.sh` model) is
> safe: the prune step is what guarantees the boundary, regardless of what apt
> dragged in.

---

## 4. Reproducible build recipe (container build)

The recipe mirrors the existing first-party sysext builder
(`v2/mkosi/app/sysext-build.lib.sh`): **resolve+download the closure → extract
`/usr` → prune Platform/Runtime-owned libs → assert the launcher survived →
squashfs via the one app-layer contract**. The only difference from
`srtla` is the *source* of the `.deb`s: a Debian apt closure instead
of a first-party staging `.deb`.

### 4.1 Acquire the closure (inside the arm64 build chroot)

Run inside the build's emulated-arm64 Debian bookworm chroot (same apt context
the app layer's `mkosi.postinst.chroot` already uses), so dependency resolution
matches the device exactly:

```bash
# Download cog + its full runtime closure as .debs into a staging dir.
# --no-install-recommends keeps it to the hard dependency set.
staging="$(mktemp -d)"
apt-get update
apt-get install -y --no-install-recommends --download-only \
    -o Dir::Cache::archives="${staging}" \
    cog
# The .debs (cog + libwpewebkit-1.1-0 + libwpe + libwpebackend-fdo + WPE deps)
# now sit in ${staging}; nothing was installed into the chroot.
ls "${staging}"/*.deb
```

> Host-portable variant (Arch/macOS builder, no arm64 chroot): use
> `apt-get download cog libwpewebkit-1.1-0 libwpe-1.0-1 libwpebackend-fdo-1.0-1
> libsoup-3.0-0 libicu72 libepoxy0 libharfbuzz-icu0 libmanette-0.2-0 libwebp7
> libwoff1 libopenjp2-7 liblcms2-2` against an `arch=arm64` apt config — the same
> closure, just enumerated explicitly. The chroot path above is preferred because
> apt computes the closure for you and stays in lockstep with the device.

### 4.2 Descriptor (mirrors `*.sysext.conf`)

The Cog add-on declares its identity and **exclusion contract** the same way the
first-party sysexts do. The load-bearing line is `SYSEXT_EXCLUDE_NAMES` — it adds
`libmali*` to the existing Platform/Runtime exclusion globs:

```bash
# v2/mkosi/app/cog.sysext.conf   (scaffold — wire up only after the HW gate clears)
SYSEXT_NAME=cog
# Built from a Debian apt closure (bookworm main), not a first-party .deb.
SYSEXT_REQUIRED_BINARIES="usr/bin/cog"
# Platform/Runtime-owned shared objects that must NEVER ship in this sysext.
#   libmali*            -> Mali-G610 Valhall GPU userspace (Platform BSP, §5)
#   libEGL*/libGLESv2*/libgbm*/libwayland-egl*  -> the GLVND/GPU vendor impl that
#                          libmali provides on-device; a bundled mesa/GLVND copy
#                          would shadow the Mali stack
#   librockchip_mpp.so* / libgstrockchip*  -> Platform HW-accel (defensive, same
#                          contract as the srtla sysext)
SYSEXT_EXCLUDE_NAMES="libmali.so* libmali-*.so* libEGL.so* libGLESv2.so* libgbm.so* libwayland-egl.so* librockchip_mpp.so* librockchip_vpu.so* libgstrockchip*.so* gstreamer1.0-rockchip*"
SYSEXT_OS_ID=debian
SYSEXT_OS_VERSION_ID=12
SYSEXT_LEVEL=1
```

### 4.3 Build the `.raw` (reuses the existing contract)

```bash
# Extract → prune the excluded libs → assert /usr/bin/cog survived → squashfs.
# This is exactly build_sysext_main(); a 3-line wrapper analogous to
# build-srtla-sysext.sh drives it:
#
#   source v2/mkosi/app/sysext-build.lib.sh
#   build_sysext_main v2/mkosi/app/cog.sysext.conf "${staging}" "${OUT_DIR}"
#
# Output: ${OUT_DIR}/cog.raw  (systemd-sysext squashfs, /usr-only, extension-release
# stamped ID=debian VERSION_ID=12 SYSEXT_LEVEL=1 — merge-eligible on the device).
```

The resulting `cog.raw` is delivered and activated identically to any other
add-on: drop into `/var/lib/extensions/`, `systemd-sysext refresh`, then start the
display unit (see `addon-sysext-refresh.md` for the refresh→restart protocol).

> **Hardware gate:** committing the `cog.sysext.conf` descriptor and the wrapper
> into the build is **deferred until a physical RK3588 validates render** (§7),
> consistent with the kiosk Tasks 26/27/28 gate. This doc + recipe is the
> authoritative spec; the scaffold above is inert until that gate clears.

---

## 5. libmali strategy — Platform-owned, excluded from the sysext (A2)

### Where libmali comes from

The RK3588 GPU is a **Mali-G610 MC4 (Valhall)**. Its **userspace** driver
(`libmali-valhall-g610-*`, which provides `libEGL`, `libGLESv2`/`libGLESv1`,
and `libgbm`) is a **proprietary Rockchip blob**:

- **Not** in Debian bookworm (verified — §1).
- **Not** in Armbian's `apt.armbian.com` `main` feed for bookworm (Armbian's
  RK3588 bookworm images default to the open Panfrost/Panthor mainline driver
  instead of the blob).
- **Sourced from the Rockchip/Radxa BSP** — package pattern
  `libmali-valhall-g610-g24p0-wayland-gbm` (the **Wayland-GBM** variant is the one
  a Wayland compositor / direct-DRM `cog` needs; the `g24p0` revision targets
  RK3588's G610, distinct from the `g13p0` RK3576/68/66 revision).

This is the same class as the GPU **firmware** blob `mali-g610-firmware` already
tracked as technical debt in `manifests/families/rk3588.yaml` (firmware vs
userspace are two distinct artifacts; both are Platform/BSP-owned). Integrating
the Radxa BSP `libmali` into the Platform layer (Layer 2) is its own task; this
doc only fixes the **boundary contract** the Cog add-on must honour.

### Why it must NOT be in the Cog sysext

Per `LAYER-MAP.md`, the GPU/BSP/HW-accel userspace is **Platform-layer (Layer 2)**
— kernel-coupled and SoC-specific. The add-on sysext (Layer 4, arch-neutral) must
not carry it, for the identical reasons the first-party app sysexts exclude
`librockchip_mpp.so*`:

1. **No shadowing.** A bundled `libmali`/mesa-`libEGL` copy in the sysext would
   overlay-shadow the Platform GPU stack and likely break EGL/GBM init.
2. **Atomic GPU updates.** libmali moves with the **Platform layer via the RAUC OS
   slot**, atomically — never through an app sysext refresh.
3. **Arch-neutrality.** The Cog sysext stays the *same artifact* regardless of
   SoC; the Mali blob is the SoC-specific piece and stays in Platform.

The contract is enforced by the prune+assert step in `sysext-build.lib.sh`: the
`SYSEXT_EXCLUDE_NAMES` globs (§4.2) delete any matching basename anywhere in the
extracted tree, then the build **fails loudly** if an excluded lib survived. So
even if a future apt closure dragged in a GPU userspace lib, it can never reach
`cog.raw`.

### EGL/GBM provisioning note (Platform-layer responsibility)

Debian's `cog` pulls GLVND `libegl1` / `libgbm1` as *dependencies*. On a Mali
device the **Platform layer owns** making libmali win — typically by providing the
GLVND vendor ICD (or `dpkg-divert` of `libEGL.so.1`/`libgbm.so.1`) so the Mali
blob, not a generic/mesa copy, services EGL/GBM. The Cog sysext must therefore
ship **neither** the GPU vendor implementation **nor** a conflicting generic
`libEGL`/`libgbm` — hence those names are in the exclusion list. Whether the
GLVND-dispatcher stubs (`libegl1`) may remain is a render-QA detail to settle on
hardware (§7).

---

## 6. Estimated sysext size

Dominated by two packages: the WebKit engine (~80 MB installed) and ICU (~35 MB
installed). The full WPE-specific closure that is **not** already in the merged
Runtime/base layers is roughly **~120 MB installed**.

| Term | Installed | After squashfs (zstd, ~0.4–0.55×) |
|---|---|---|
| `libwpewebkit-1.1-0` | ~80 MB | ~32–44 MB |
| `libicu72` | ~35 MB | ~14–19 MB |
| `cog` + WPE backends + codecs | ~7 MB | ~3–4 MB |
| **`cog.raw` total (estimate)** | **~120 MB** | **≈ 45–65 MB** |

This is an **estimate from the apt index**, not a measured artifact: the exact
`.raw` size depends on how much of the closure (ICU, GStreamer, glib) the merged
Runtime layer already provides and thus gets excluded, and on the squashfs
compressor settings. Measure on a real arm64 build before pinning a size budget.

> For comparison, the existing first-party sysexts are tiny (`srtla.raw` ~420 KB,
> `srtla.raw` ~1.2 MB historically). Cog is two orders of magnitude larger because it
> carries a full browser engine — a real consideration against the partition/size
> budget (`manifests/size-budget.json`) when this add-on is enabled.

---

## 7. Hardware-gated caveats (render QA)

Everything above is **packaging validation** — provable from the apt index and the
layer contract without a board. What **cannot** be validated without a physical
**RK3588** (Task 1 spike: NO-GO, no board reachable) and is therefore deferred:

| QA item | Why it needs hardware |
|---|---|
| Cog renders at all via libmali EGL/GBM | needs the real Mali-G610 + Platform libmali merge |
| **OKLCH / Tailwind v4 CSS correctness on WebKit 2.38.6** | the bookworm WebKit may predate full OKLCH; verify pixels, not specs (§2 trade-off) |
| `cog` platform choice: direct-DRM/KMS vs under `cage` | DRM node mapping (`card0` vs `card1`) is itself a Task 28 hardware item |
| Touch input through the WPE/Wayland seat | needs the DSI touchscreen + calibration (Task 28) |
| GLVND vs `dpkg-divert` libmali wiring (§5) | depends on the actual on-device EGL resolution |
| Measured `cog.raw` size + size-budget impact (§6) | needs a real arm64 build |

These are the **same gate** as kiosk Tasks 26/27/28. The recipe and contracts here
are the authoritative spec; the inert scaffold (§4.2) is wired into the build only
**after** the gate clears.

The ready-to-run runbook for clearing this gate on a real board is
`v2/docs/cog-display-hw-checklist.md` (build+sign the real closure → stage →
render correctness → touch → disable → sign-off). Everything provable WITHOUT
hardware is already green and recorded in `test-results/task-39-cog-qa.txt`.

---

## 8. Relationship to the cage + Chromium kiosk stack

`kiosk-display.md` specs the default kiosk as **cage (Wayland compositor) +
Chromium**. Cog is positioned as an **optional, lighter display engine** add-on,
not a replacement decision made here:

- Cog can run **directly on DRM/KMS** (its `drm` platform — no compositor) **or**
  under `cage` (its `wl` platform). The direct-DRM mode drops the cage process
  entirely — attractive for a constrained appliance.
- WPE WebKit is purpose-built for embedded single-view rendering; its footprint
  and memory profile are smaller than Chromium's (relevant to the OOM ordering in
  `kiosk-display.md §4`).
- The **open question** is CSS feature parity (OKLCH/Tailwind v4) on WebKit 2.38
  vs Chromium ≥111 — the deciding render-QA item (§7). Until that is settled on
  hardware, Chromium remains the documented default and Cog is the validated
  *packaging path* kept ready behind the add-on manager.

---

## 9. Known technical debt

| ID | Item | Resolution |
|---|---|---|
| **TD-C1** | `cog`/`wpewebkit` not yet pinned in `versions.yaml` | pin after render QA passes (§2) |
| **TD-C2** | Radxa BSP `libmali-valhall-g610-g24p0-wayland-gbm` not yet integrated into the Platform layer (`rk3588.yaml`) | separate Platform-layer task; the Cog add-on already excludes it by contract (§5) |
| **TD-C3** | OKLCH / Tailwind v4 support on WebKit 2.38.6 unverified | hardware render QA (§7); fall back to a trixie/backport apt snapshot via the *same* recipe if insufficient |
| **TD-C4** | `cog.sysext.conf` + build wrapper are inert scaffolds | wire into the orchestrator only after the RK3588 gate clears |

---

## 10. Related documents

(Plain references — no workspace-external relative links, per Rule D.)

| Document | Scope |
|---|---|
| `v2/docs/cog-display-hw-checklist.md` | ready-to-run on-hardware render-QA runbook (clears the §7 gate) |
| `v2/docs/kiosk-display.md` | default cage + Chromium kiosk chassis (units, packages, OOM, DRM notes) |
| `v2/docs/addon-sysext-refresh.md` | sysext refresh → service restart protocol for add-ons |
| `v2/mkosi/LAYER-MAP.md` | layer boundaries — why GPU userspace is Platform, apps are Layer 4 |
| `v2/mkosi/app/sysext-build.lib.sh` | the extract → prune → squashfs builder this recipe reuses |
| `v2/manifests/families/rk3588.yaml` | RK3588 BSP/firmware sources (`mali-g610-firmware` TD) |
| `CeraUI` repo — `docs/ON_DEVICE_DISPLAY.md` | cross-repo kiosk architecture (DC-1..DC-4) |
