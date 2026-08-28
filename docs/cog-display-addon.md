# Cog + WPEWebKit Display Add-On — Packaging & GPU Strategy (W4)

**Status:** `[PARTIAL]` — packaging path validated (A1) and the GPU strategy fixed
(A2) against the real **trixie** arm64 apt index; on-hardware **render QA is
gated** on a physical RK3588 (Task 1 spike verdict: NO-GO).
**Scope:** image-building-pipeline only (chassis/packaging ownership per DC-1).
**Evidence:** the original bookworm-era transcript is
[`test-results/task-25-cog-packaging.txt`](../../test-results/task-25-cog-packaging.txt);
the trixie/mainline flip is measured in
`.omo/evidence/cerastream-glibc-pipewire-network-ui/todo14-cog-closure.txt` and
`…/todo14-old-pins-negative.txt`.

This is the concrete **W4 build recipe** for shipping **Cog** (the single-window
WPE WebKit kiosk browser) as a **feature sysext add-on** — i.e. an optional
display engine delivered through the same sysext class as `srtla`
and managed by the W3 add-on manager. It is a lighter alternative to the
cage + Chromium kiosk stack specified in [`kiosk-display.md`](kiosk-display.md);
choosing Cog-vs-Chromium as the *default* engine is a separate decision — this
doc only fixes **how Cog is acquired and packaged**, and **where the GPU
userspace comes from**.

**The add-on is OPTIONAL and INERT BY DEFAULT, and nothing below changes that.**
It ships no `.raw` in the image, its descriptor's `units.enable`/`.start` lists
are acted on only by an explicit operator `enableAddon(cog-display)` through the
CeraUI add-on manager, and the base image is byte-unchanged whether or not this
recipe exists.

---

## 0. TL;DR — the two facts that changed at the trixie/mainline migration

**(1) The renderer package was RENAMED, not merely bumped.** A version-only edit
of the previous pins resolves to *nothing* on trixie:

| Retired (bookworm) | Trixie | Note |
|---|---|---|
| `cog` 0.16.1-1 | **`cog` 0.18.4-1+b1** | same source package, new upstream series |
| `libwpewebkit-1.1-0` 2.38.6-1 | **`libwpewebkit-2.0-1` 2.48.3-1** | **package renamed** — WPE API 1.1 is gone from the archive |
| `libicu72` | **`libicu76`** 76.1-4 | ICU soname bump; `libicu72` is absent |
| `libopenjp2-7` | **dropped** | WPE 2.48's image codecs are `libjxl0.11` + `libavif16` + the `libwebp` demux/mux pair |
| — | `cage` **0.2.0-2** | unchanged name |

Note **2.48.3**, not the "2.44.x" the bookworm-era draft of this document
forecast: trixie shipped a newer WebKit than that forecast, and the forecast was
never re-checked against the archive. Every version above was read out of a real
`debian:trixie-slim` **arm64** container, not a web lookup — that is the todo-10
rule (*verify names and versions empirically; bookworm-era naming does not carry
over*) applied to this surface.

**(2) The GPU userspace is Mesa now, not the Mali blob.** On the mainline kernel
the Mali-G610 is bound by the in-tree open **`panthor`** DRM driver, whose
userspace is **Mesa**'s Gallium `panthor`/`panfrost` driver. The proprietary
`libmali-valhall-g610-*` blob retires with the vendor kernel era — it is
ABI-bound to Rockchip's out-of-tree vendor module and is incompatible with
trixie's stack (armbian/build#10320). See §5, which replaces the former "libmali
strategy" wholesale.

The acquisition path is otherwise unchanged and still the best one available:
plain `apt` from the suite the container build already trusts — no backport, no
third-party repo, no from-source toolchain (§2).

---

## 1. Availability finding (verified against the real trixie arm64 index)

Read inside a real `debian:trixie-slim` **arm64** container against
`deb.debian.org/debian trixie/main arm64`:

```
Package: cog
Source: cog (0.18.4-1)
Version: 0.18.4-1+b1
Architecture: arm64
Depends: libc6 (>= 2.34), libcairo2, libdrm2, libegl1, libepoxy0,
         libglib2.0-0t64, libinput10, libmanette-0.2-0, libsoup-3.0-0,
         libudev1, libwayland-client0, libwayland-cursor0,
         libwpe-1.0-1 (>= 1.14.0), libwpebackend-fdo-1.0-1 (>= 1.10.0),
         libwpewebkit-2.0-1 (>= 2.42.0)

Package: libwpewebkit-2.0-1
Source: wpewebkit
Version: 2.48.3-1
Architecture: arm64
Installed-Size: 117488
```

`apt-cache search --names-only wpewebkit` in trixie returns
`libwpewebkit-2.0-1`, `libwpewebkit-2.0-dev`, `wpewebkit-webdriver` and two
transitional dummies. **There is no `libwpewebkit-1.1-0` at all**, and
`apt-cache policy libicu72` likewise answers with no candidate. That is the
negative control for the flip and is captured verbatim in
`todo14-old-pins-negative.txt`.

The supporting closure resolves as:

| Package | Trixie version |
|---|---|
| `libwpe-1.0-1` | 1.16.2-1 |
| `libwpebackend-fdo-1.0-1` | 1.16.0-1 |
| `libsoup-3.0-0` | 3.6.5-3 |
| `libicu76` | 76.1-4 |
| `libepoxy0` | 1.5.10-2 |
| `libharfbuzz-icu0` | 10.2.0-1+deb13u1 |
| `libmanette-0.2-0` | 0.2.12-1 |
| `libwebp7` / `libwebpdemux2` / `libwebpmux3` | 1.5.0-0.1 |
| `libwoff1` | 1.0.2-2+b2 |
| `libjxl0.11` | 0.11.2-0.1~deb13u2 |
| `libavif16` | 1.2.1-1.2 |
| `liblcms2-2` | 2.16-2+deb13u2 |
| `libwayland-client0` / `-server0` / `-egl1` | 1.23.1-3 |
| `libgles2` | 1.7.0-1+b2 |
| `cage` | 0.2.0-2 |

**No Mali `libmali` in trixie `main` either** — and unlike the bookworm finding,
that is no longer a gap to work around. It is the answer: §5.

---

## 2. Chosen acquisition path — **Option A: apt from trixie `main`**

| Option | What | Verdict |
|---|---|---|
| **A. apt from trixie `main`** | `apt-get` the `cog` + WPE closure from the apt source the build already trusts | ✅ **CHOSEN** |
| B. first-party backport / custom `.deb` | rebuild a newer WPE for the target suite, sign, serve via `apt.ceralive.tv` | ❌ unnecessary — pure maintenance burden for no functional gain |
| C. build-from-source in the container | meson build of Cog + WPEWebKit | ❌ heaviest path; WPEWebKit is a multi-hour C++ build; reproducibility + toolchain cost for zero benefit |
| D. third-party repo (Igalia/wpewebkit.org) | add an external apt source | ❌ adds a new trust root; no upstream trixie/arm64 `.deb` repo exists anyway |

**Why A wins on every axis that matters here:**

- **Trust:** signed by the Debian archive key already pinned in the builder
  (`ci/Dockerfile` bakes `debian-archive-keyring`). No new trust root, unlike D.
- **Reproducibility:** the exact versions are pinnable; the same apt snapshot
  yields byte-identical inputs, fitting the repo's reproducible-build contract.
- **Cost:** zero build toolchain, zero serving infrastructure (vs B/C).
- **Security:** rides Debian's WebKit security updates for trixie — no private
  CVE-tracking burden.

**The trade-off that motivated B/C is now largely gone.** The bookworm pin sat at
WebKit **2.38.6**, well behind the Chromium ≥111 CSS floor the cage + Chromium
kiosk path assumes, and that gap was the single strongest argument for a
backport. Trixie's **2.48.3** is a materially newer engine and almost certainly
clears OKLCH / `color-mix()` / container queries / nested CSS on specification
grounds. **That is a reason to expect success, not a result** — the render QA
item (§7, TD-C3) still verifies *pixels*, because "the spec says the engine
supports it" has never been this project's acceptance bar.

### Version pinning

Pin `cog` and `wpewebkit` in `versions.yaml` **after** render QA passes on
hardware. Until then they float at the trixie `main` versions above; the recipe
records the validated versions so a drift is visible.

---

## 3. Dependency closure (what the sysext actually carries)

Two groups, and the second is new at this migration.

**(a) The WPE/Cog closure**, minus everything the Runtime OS layer already ships
(GStreamer core, glib, cairo, fontconfig, freetype — see
`manifests/packages/shared.list`). Sizes are the real on-disk bytes measured in
the extracted staging tree, not `Installed-Size` estimates:

| Carried in the sysext | Measured | Note |
|---|---|---|
| `libwpewebkit-2.0-1` | **115 849 336 B** | the renderer — dominant term |
| `libicu76` | ~37 951 000 B | WebKit's Unicode dep (`libicudata` is 31 917 696 B of it) |
| `libjxl0.11` | 2 951 176 B | JPEG-XL, a WPE 2.48 codec dep |
| `libepoxy0` | 1 406 568 B | GL dispatch |
| `libsoup-3.0-0` | 723 496 B | HTTP stack |
| `cog` / `cage` | 69 208 B / 67 672 B | the launcher and the compositor |
| `libwpe-1.0-1`, `libwpebackend-fdo-1.0-1`, `libharfbuzz-icu0`, `libmanette-0.2-0`, `libwebp*`, `libwoff1`, `libavif16`, `liblcms2-2`, `libwayland-*`, `libgles2` | ~5 MB total | backends, codecs, dispatchers |

**(b) The Panthor GPU userspace half** — exactly the four globs the Runtime layer
prunes, and nothing else. Full rationale in §5:

| Carried in the sysext | Measured |
|---|---|
| `libLLVM.so.19.1` (`libllvm19`) | 123 242 120 B |
| `libgallium-25.0.7-2+deb13u1.so` (`mesa-libgallium`) | 35 012 296 B |
| `libz3.so.4` (`libz3-4`) | 26 875 248 B |
| `dri/libdril_dri.so` + `dri/panthor_dri.so` + `dri/panfrost_dri.so` + the sibling symlinks (`libgl1-mesa-dri`) | 133 304 B |

| Merge-provided (NOT bundled) | Source layer |
|---|---|
| `libgstreamer1.0-0`, `-plugins-base`, `-gl` and the GStreamer plugin set | **Runtime** (`shared.list` already lists the GStreamer stack) |
| `libglib2.0-0t64`, `libcairo2`, `libfontconfig1`, `libfreetype6`, … | **Runtime** (base/runtime closure) |
| `bubblewrap` (0.12.0), `xdg-dbus-proxy` (0.1.6) — WebKit sandbox | **Runtime** if present, else add to the add-on closure |
| `libEGL.so.1` (`libegl1`), `libEGL_mesa.so.0` (`libegl-mesa0`), `libgbm.so.1` + `gbm/dri_gbm.so` (`libgbm1`) | **Runtime** — all three arrive with `gstreamer1.0-plugins-bad` and are **not** touched by the prune. Verified by resolving the real `shared.list` set against the trixie arm64 index |

> Building the sysext from the **full** `apt` download closure and then **pruning**
> the Platform/Runtime-owned libs (the existing `sysext-build.lib.sh` model) is
> safe: the prune step is what guarantees the boundary, regardless of what apt
> dragged in.

---

## 4. Reproducible build recipe (container build)

The recipe mirrors the existing first-party sysext builder
(`mkosi/app/sysext-build.lib.sh`): **resolve+download the closure → extract
`/usr` → prune Platform/Runtime-owned libs → assert the launcher survived →
squashfs via the one app-layer contract**. The only difference from
`srtla` is the *source* of the `.deb`s: a Debian apt closure instead
of a first-party staging `.deb`.

### 4.1 Acquire the closure (inside the arm64 build chroot)

Run inside the build's emulated-arm64 Debian **trixie** chroot (same apt context
the app layer's `mkosi.postinst.chroot` already uses), so dependency resolution
matches the device exactly:

```bash
# Download cog + its full runtime closure as .debs into a staging dir.
# --no-install-recommends keeps it to the hard dependency set.
staging="$(mktemp -d)"
apt-get update
apt-get install -y --no-install-recommends --download-only \
    -o Dir::Cache::archives="${staging}" \
    cog cage mesa-libgallium libgl1-mesa-dri
# The .debs now sit in ${staging}; nothing was installed into the chroot.
ls "${staging}"/*.deb
```

> Host-portable variant (Arch/macOS builder, no arm64 chroot): `apt-get download`
> the enumerated `SYSEXT_APT_PACKAGES` list from `mkosi/app/cog-display.sysext.conf`
> against an `arch=arm64` apt config — the same closure, just spelled out. The
> chroot path above is preferred because apt computes the closure for you and
> stays in lockstep with the device.

### 4.2 Descriptor (`mkosi/app/cog-display.sysext.conf`)

The committed descriptor is the source of truth; the load-bearing keys are
`SYSEXT_APT_PACKAGES` (the trixie closure from §1) and `SYSEXT_EXCLUDE_NAMES`
(the boundary contract from §5). Read it there rather than from a copy here — a
duplicated package list in prose is exactly what went stale at the last suite
bump.

### 4.3 Build the `.raw` (reuses the existing contract)

```bash
# Extract → prune the excluded libs → assert /usr/bin/cog survived → squashfs.
#
#   lib/build-feature-sysext.sh \
#     --feature cog-display --board rock-5b-plus \
#     --deb-staging "${staging}" --out dist/
#
# Output: dist/cog-display-<board>-<os_version>.raw (+ .raw.sha256 + .raw.sig),
# a systemd-sysext squashfs, /usr-only, extension-release stamped
# ID=debian VERSION_ID=<OS_VERSION_ID> SYSEXT_LEVEL=1 — merge-eligible on the device.
# --os-version defaults from manifests/target-release.env; do not pass a literal.
```

The resulting `.raw` is delivered and activated identically to any other add-on:
drop into the sysext store, `systemd-sysext refresh`, then start the display unit
(see `addon-sysext-refresh.md` for the refresh→restart protocol).

> **Hardware gate:** committing the descriptor and the wrapper into the *build*
> is **deferred until a physical RK3588 validates render** (§7), consistent with
> the kiosk Tasks 26/27/28 gate. This doc + recipe is the authoritative spec; the
> descriptor remains inert until that gate clears.

---

## 5. GPU strategy — **Panthor (kernel) + Mesa (userspace)** (A2)

### What changed, and why it is not optional

The RK3588 GPU is a **Mali-G610 MC4 (Valhall, CSF generation)**. Two mutually
exclusive stacks can drive it:

| | Vendor era (bookworm + Armbian 6.1 BSP) | **Mainline era (trixie + `edge` 7.2)** |
|---|---|---|
| Kernel driver | Rockchip out-of-tree Mali module, `/dev/mali0` | **`panthor`**, in-tree, `/dev/dri/renderD*` |
| Userspace | `libmali-valhall-g610-g24p0-wayland-gbm` (proprietary blob) | **Mesa** Gallium `panthor` driver |
| Provides | its own `libEGL.so.1`, `libGLESv2.so.2`, `libgbm.so.1` | Debian GLVND + Mesa `libEGL_mesa` / `libgbm` |

Both halves are verified, not assumed:

- **Kernel.** `CONFIG_DRM_PANTHOR=m` survives in the **real resolved v7.2 config**
  for the `edge` variant (`rk3588-kernel-patches`
  `.omo/evidence/v72-rebase/05-compile/resolved.config`, alongside
  `CONFIG_DRM=m` and `CONFIG_DRM_PANFROST=m`). It is now pinned in
  `manifests/kernel/required-symbols.list` so it can never be dropped in silence
  — the discipline `CONFIG_RTW89`, `CONFIG_DMABUF_HEAPS`, `CONFIG_TYPEC_FUSB302`
  and `CONFIG_NF_TABLES` each earned the hard way. `panthor`, not `panfrost`, is
  the right driver for a G610: panfrost's own Kconfig help says the non-CSF
  Valhall parts (G68/G78) stay on panfrost, and the G610 is CSF.
- **Userspace.** Trixie arm64 ships **`dri/panthor_dri.so`** and
  `dri/panfrost_dri.so`, both symlinks onto `libdril_dri.so`, whose driver code
  lives in `mesa-libgallium`'s `libgallium-<version>.so`. Confirmed by listing
  the directory in a real trixie arm64 container.

**`libmali` is REMOVED from the mainline manifest path**
(`manifests/families/rk3588.yaml`, `variants.edge.firmware_packages`, which now
lists `armbian-firmware` only). That removal is load-bearing rather than tidy:
the blob ships `/etc/ld.so.conf.d/00-aarch64-mali.conf`, whose `00-` prefix sorts
first, so it captures `libEGL.so.1` / `libGLESv2.so.2` / `libgbm.so.1` for the
whole image and points them at a driver that talks to a `/dev/mali0` the mainline
kernel never creates. Installed on a mainline board it does not degrade GL — it
removes it, with no fallback. The vendor default keeps the blob and is unchanged;
retiring the pin outright belongs to the vendor-kernel retirement.

The add-on additionally keeps `libmali*` in **both** `SYSEXT_EXCLUDE_NAMES` (the
prune fails the build loudly if a copy survives) and `SYSEXT_FORBID_PACKAGES`, so
a future closure edit cannot drag it back in.

### Why the Mesa half rides IN this sysext

This is the one place the old Platform-layer rule genuinely inverts, and the
reason is a size prune the base image already performs.

The Runtime layer **installs** `mesa-libgallium`, `libgl1-mesa-dri`, `libllvm19`
and `libz3-4` (they arrive with `gstreamer1.0-plugins-bad`) and then
`RemoveFiles=`-prunes exactly four globs out of them —
`libgallium-*.so`, `libLLVM*.so*`, `libz3.so*`, `dri/*_dri.so` — for
**185 262 968 B**. That prune is what keeps both RK3588 boards under the 1.5 GB
`[6c/9]` gate, and its stated justification was that libmali shadowed Mesa so
none of it was reachable. **That justification does not survive libmali's
removal** — and `dri/panthor_dri.so` is one of the files it deletes.

Three options, and only one holds every invariant:

| | Effect |
|---|---|
| Leave the prune, ship no Mesa driver | "Panthor + Mesa" would be a claim with no working userspace behind it. ❌ |
| Un-prune on the mainline path | +185 MB on the base image → the `edge` image lands near **1.62 GB** against a 1.5 GB ceiling no board may raise. ❌ |
| **Add-on carries exactly the four pruned globs** | Base image byte-unchanged, size gate untouched, cost borne only by operators who enable the kiosk. ✅ |

Nothing is shadowed by this, which is what makes it safe: the base has **no file
at those paths**, so the sysext's overlay introduces the driver rather than
competing with one. Disable the add-on and the paths vanish again.

`libLLVM` and `libz3` are not padding and cannot be dropped to save 150 MB:
`objdump -p libgallium-*.so` shows a hard `NEEDED libLLVM.so.19.1` (llvmpipe is
compiled into the same megadriver), so a `libgallium` without it cannot be
`dlopen()`ed at all — the driver would fail to load exactly as if it were absent.

### What the sysext must still NOT carry

`SYSEXT_EXCLUDE_NAMES` keeps `libEGL.so*` and `libgbm.so*`: those come from
`libegl1` / `libegl-mesa0` / `libgbm1`, which the Runtime layer installs and the
prune does not touch. A bundled copy would shadow a working base library for no
gain, and the prune's fail-loud assertion is what stops one arriving by accident.

Three globs were **deliberately dropped** — `libGLESv2.so*`, `libGLESv1*.so*`
and `libwayland-egl.so*`. They existed for exactly one reason: libmali supplied
those sonames on-device. With libmali gone the premise inverts — the Runtime
layer supplies neither `libgles2` nor `libwayland-egl1` — so keeping the globs
would silently delete libraries nothing else provides and leave the kiosk with no
GLES at all. This is the same class of error as the stale Mesa prune globs
todo 10 found: a glob whose *reason* expired keeps matching, and matching is not
the same as being right.

`librockchip_mpp.so*` / `librockchip_vpu.so*` / `libgstrockchip*` stay excluded on
both paths — that HW-accel userspace is Platform-owned and is the identical
contract the `srtla` sysext enforces.

---

## 6. Measured sysext size

Not an estimate any more. A real `apt-get download` of the descriptor's
`SYSEXT_APT_PACKAGES` inside a `debian:trixie-slim` **arm64** container, extracted,
pruned with the real `SYSEXT_EXCLUDE_NAMES` contract and squashed exactly as
`sysext-build.lib.sh` does (`mksquashfs -comp zstd -Xcompression-level 19`):

| | Bytes |
|---|---|
| installed (apparent, post-prune) | **353 172 379** |
| squashed `.raw` | **111 521 792** |

The four dominant terms are `libLLVM.so.19.1` (123 MB), `libWPEWebKit-2.0.so.1.5.8`
(116 MB), `libgallium-*.so` (35 MB) and `libicudata.so.76.1` (32 MB). Roughly
**185 MB of the 353 MB is the GPU half** (§5) and would disappear if the base
image ever stopped pruning it.

These are the numbers now recorded in `manifests/addons/cog-display.json`
(`sizeInstalled` / `sizeDownload`), replacing the previous bookworm-era estimate
of ~120 MB installed / ~55 MB squashed.

> Two cheap reductions exist and are deliberately NOT taken here, because both
> want a render-QA measurement first: `wpe-webkit-2.0/MiniBrowser` (2.5 MB) is a
> demo binary the kiosk never launches, and `libicudata` can be rebuilt with a
> trimmed locale set. Neither is worth a divergence from stock Debian packages
> before anything has rendered on a board.

> For comparison, the first-party sysexts are tiny (`srtla.raw` ~420 KB). Cog is
> three orders of magnitude larger because it carries a full browser engine *and*
> a full GPU driver stack — a real consideration against the `/data` budget when
> this add-on is enabled.

---

## 7. Hardware-gated caveats (render QA)

Everything above is **packaging validation** — provable from the apt index, the
layer contract and a real closure build, without a board. What **cannot** be
validated without a physical **RK3588** (Task 1 spike: NO-GO, no board reachable)
and is therefore deferred:

| QA item | Why it needs hardware | Change at this migration |
|---|---|---|
| Cog renders at all through **Panthor + Mesa** EGL/GBM | needs the real Mali-G610 bound by `panthor` | **rewritten** — the target is now `panthor_dri.so`, not libmali |
| The merged sysext's Mesa half actually resolves at runtime | the base image has those four paths pruned; only a merged board proves the overlay supplies them | **new** |
| `renderD*` node mapping and permissions for the kiosk user | Panthor exposes a render node where libmali exposed `/dev/mali0` | **new** |
| **OKLCH / Tailwind v4 CSS correctness on WebKit 2.48.3** | verify pixels, not specs | **risk materially reduced** — 2.48 is far past the 2.38 engine that motivated TD-C3, but unverified is unverified |
| `cog` platform choice: direct-DRM/KMS vs under `cage` | DRM node mapping is itself a Task 28 hardware item | unchanged |
| Touch input through the WPE/Wayland seat | needs the DSI touchscreen + calibration (Task 28) | unchanged |
| Measured `.raw` **size on the device** and `/data` impact | §6 measures the artifact; the free-space effect is a board fact | narrowed |

These are the **same gate** as kiosk Tasks 26/27/28. The recipe and contracts here
are the authoritative spec; the inert descriptor is wired into the build only
**after** the gate clears. The ready-to-run runbook is
`docs/cog-display-hw-checklist.md`; everything provable WITHOUT hardware is green
and recorded in `test-results/task-39-cog-qa.txt` plus the two todo-14 evidence
files named at the head of this document.

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
- The **open question was CSS feature parity**, and trixie narrows it sharply:
  WebKit 2.48.3 is a far newer engine than the 2.38.6 the comparison was written
  against. It is now expected to clear the Chromium ≥111 floor, and the deciding
  render-QA item (§7) is there to confirm that on pixels rather than assume it.

---

## 9. Known technical debt

| ID | Item | Resolution |
|---|---|---|
| **TD-C1** | `cog`/`wpewebkit` not yet pinned in `versions.yaml` — and the recorded comment values there are the **retired bookworm** ones | pin `0.18.4-1+b1` / `2.48.3-1` after render QA passes (§2) |
| ~~TD-C2~~ **SUPERSEDED** | was: "source the Mali blob for the Platform layer" | the blob is off the mainline path entirely; the GPU stack is Panthor + Mesa (§5). The vendor-path pin survives until the vendor kernel retires |
| **TD-C3** | OKLCH / Tailwind v4 support unverified on the shipping engine | risk materially reduced by the jump to WebKit 2.48.3, but still a hardware render-QA item (§7) |
| **TD-C4** | `cog-display.sysext.conf` + build wrapper are inert scaffolds | wire into the orchestrator only after the RK3588 gate clears |
| **TD-C5** (new) | The add-on carries 185 MB of GPU userspace only because the base image prunes it (§5) | revisit if the size budget ever gains headroom, or if Debian ships a panfrost-only Mesa that does not link LLVM |

---

## 10. Related documents

(Plain references — no workspace-external relative links, per Rule D.)

| Document | Scope |
|---|---|
| `docs/cog-display-hw-checklist.md` | ready-to-run on-hardware render-QA runbook (clears the §7 gate) |
| `docs/kiosk-display.md` | default cage + Chromium kiosk chassis (units, packages, OOM, DRM notes) |
| `docs/addon-sysext-refresh.md` | sysext refresh → service restart protocol for add-ons |
| `docs/trixie-package-resolution.md` | the todo-10 package-name migration report this section's method follows |
| `docs/size-notes.md` §9 | the Mesa software-GL prune ledger §5 depends on |
| `mkosi/LAYER-MAP.md` | layer boundaries — why GPU userspace was Platform-owned, and where §5 departs |
| `mkosi/app/sysext-build.lib.sh` | the extract → prune → squashfs builder this recipe reuses |
| `manifests/families/rk3588.yaml` | RK3588 BSP/firmware sources; `variants.edge.firmware_packages` is where libmali is dropped |
| `manifests/kernel/required-symbols.list` | where `CONFIG_DRM_PANTHOR=m` is pinned |
| `manifests/rk3588-userspace-deb-versions.txt` | pinned + SHA-256-verified RK3588 GPU/MPP/RGA userspace .debs (the libmali record is vendor-path only) |
| `CeraUI` repo — `docs/ON_DEVICE_DISPLAY.md` | cross-repo kiosk architecture (DC-1..DC-4) |
