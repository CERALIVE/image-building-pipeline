# Kernel Currency Watch: Mainline 7.2 + MPP Userspace

**Decision recorded:** the planned Trixie/mainline 7.2 image can keep the existing
Rockchip MPP userspace pins unchanged.
**Kill-switch decision (2026-08-28): PROCEED with W3/W4.**
**Selection mechanism:** the MPP userspace (not in Debian or the Armbian feed) is
URL- and SHA-256-pinned in
[`manifests/rk3588-userspace-deb-versions.txt`](../manifests/rk3588-userspace-deb-versions.txt).
**Visibility mechanism:** BSP provenance/drift-guard ([`manifests/bsp-baseline.json`](../manifests/bsp-baseline.json), Task 3).

---

## The Decision

**ACTIONED 2026-08-28.** The kernel flip this document authorised has been made:
`manifests/families/rk3588.yaml` declares `default_variant: edge`, so a
variant-less build selects the source-built mainline 7.2 kernel and the prebuilt
vendor BSP is the opt-in `vendor` overlay. The MPP userspace pins below are
unchanged, which is exactly what this decision said would happen.

The flip selects the source-built mainline 7.2 kernel and
continues to drive VEPU580 through **Rockchip MPP**. The kernel implementation
changes; the MPP userspace ABI does not. No replacement build from
`tsukumijima/mpp-rockchip` is needed beyond the already-pinned
`librockchip-mpp1` release asset.

The exact retained set is `librockchip-mpp1` 1.5.0-1 (tsukumijima), plus
`gstreamer1.0-rockchip1` 1.14-4 and `librga2` 2.2.0-1 (Radxa). On both a Rock 5B+
and an Orange Pi 5 Plus running `7.2.0-ceralive-rk3588`, the installed packages
have exactly those versions; the plugin resolves `librockchip_mpp.so.1` and
`librga.so.2` with no missing dependency, `gst-inspect-1.0 mpph264enc` succeeds,
and todo 16's direct 60-second hardware encode exits cleanly. This is direct
kernel/userspace ABI evidence on both supported boards.

Debian 13's arm64 index does **not** publish any of the three package names. That
is expected: the pipeline has always staged them as local, hash-pinned `.deb`s.
The distinction that gates Trixie is whether those exact assets co-install with
the Trixie index. A real `debian:trixie-slim` arm64 solve and install accepted all
three unchanged against GStreamer 1.26.2 and the t64 transition; `ldd` on
`libgstrockchipmpp.so` resolved both required SONAMEs and every other dependency.
In the hardware-free container the plugin itself loads and exposes its decoder
features; encoder registration is hardware-probed and therefore remains a board
assertion, supplied by the two live systems above.

The release assets' downloaded SHA-256 values matched the committed pins exactly.
They remain staged by `fetch_rk3588_userspace`, not selected from Debian's index.
Bump any one only after re-running both the Trixie solve and the hardware encode.

## Historical vendor-lock evidence (superseded)

The following seven checks explain the former vendor-6.1 lock. They are retained
as history, not as the current image decision: CeraLive's pinned out-of-tree
VEPU580 series and its board evidence now supply the mainline path.

1. **Latest Armbian vendor IS 6.1.** There is no `current` or `edge` branch for
   rk3588 vendor; 6.1 is the only vendor track.
2. **Out-of-tree DKMS VEPU580 rejected.** The rcawston `rkvenc` patches are
   rc-pinned, unvalidated against our BSP, and would impose an ongoing fork burden
   with no upstream path.
3. **Rockchip 6.6 vendor BSP does not exist.** There is no Rockchip-published 6.6
   vendor tree for RK3588.
4. **Mainline lacks a frozen V4L2 stateless H.265 ENCODE uAPI.** The kernel ABI
   for stateless H.265 encode is not stable; building on it now means chasing a
   moving target.
5. **Mainline `rkvenc` is VEPU121 JPEG-only.** No VEPU580 driver exists in
   mainline, and no in-review series targets it.
6. **Kocialkowski's H.264 stateless work targets i.MX8MP / VC8000E, not RK3588.**
   The leading mainline stateless encode effort is for a different SoC family
   entirely; RK3588 VEPU580 is not in scope.
7. **The entire RK3588 IPKVM ecosystem runs MPP.** JetKVM, RustKVM, and One-KVM
   all depend on MPP — the integrator community has converged on this path.

## Historical Revisit Triggers

These were the conditions for revisiting the former vendor lock. The current
mainline migration does not claim either fired; it deliberately adopts the
pinned CeraLive out-of-tree VEPU580 path instead.

**Measured reality (2026-08-07, device-platform-wave4 todos 25-30) — neither
trigger is affected; the measurement is evidence, not a new trigger.** The
`edge` mainline-track variant was bench-validated on real Rock 5B+ hardware
**against the `v7.1.5` base it was pinned to at the time** (the track has since
moved to `v7.1.7` and then to `v7.2`; no board evidence travels with a base bump):
`mpph264enc` (H.264, the product's primary encode path) never registers at
all — `encode-broken` — while `mpph265enc`'s declared probe subset measured
`encode-degraded` (clean quality/kernel parity on all 6 cells; the only failing
gate is CBR bitrate accuracy, and only on low-complexity/synthetic content).
Full write-up, evidence citations, and the deterministic go/no-go verdict:
[`kernel-track-decision.md`](kernel-track-decision.md). This does not confirm,
refute, or newly justify either trigger below — Trigger 1 is about a Rockchip
6.12+ vendor BSP (unrelated to the mainline `edge` measurement) and Trigger 2 is
about a frozen mainline stateless H.265 *encode* uAPI (the `edge` variant uses
the out-of-tree rcawston `rkvenc` driver, which — per the existing "does NOT
fire either trigger" section below — is explicitly the opposite of Trigger 2's
condition). The measurement is recorded here only as citable evidence that the
`edge` option remains pinned-and-buildable but not production-ready, which was
already this doc's premise before the bench session.

**Current measurement (2026-08-28, todos 16-17):** both supported boards running
mainline `7.2.0-ceralive-rk3588` register `mpph264enc` and complete a direct
60-second hardware encode with the exact retained package set. The Trixie arm64
index independently resolves every dependency for those URL-pinned `.deb`s.
This clears the MPP-userspace kill switch, but it does not claim that the exact
pinned Trixie image was built or booted; that release qualification remains a
separate gate.

### Trigger 1 — Rockchip ships a 6.12+ vendor BSP with MPP support

**Condition:** Rockchip publishes a vendor BSP based on kernel **6.12 or later**
that retains full MPP support, AND integrators (Armbian, JetKVM, or equivalent)
adopt it in a stable track.

**Signal to watch:** current, dual-signed Armbian metadata contains a reviewed
`linux-image-vendor-rk35xx` version whose kernel jumps from 6.1.x to 6.12.x.
Promoting it requires an explicit change to
`armbian-bsp-deb-versions.txt` and `bsp-baseline.json`; an ordinary build never
silently adopts it. The provenance log confirms the concrete version and bytes.

## Drift-Guard Exit Policy + Strict-Gate Promotion Criterion

`bsp_drift_check` is **warn-only by default** and **strict on opt-in** (C6b):

- **Default** (`BSP_DRIFT_STRICT` unset or ≠ `1`) — drift prints the `BSP drift`
  banner and returns **exit 0**. The build continues with the exact selected
  version; this warns about a content replacement or a deliberate pin/baseline
  mismatch.
- **`BSP_DRIFT_STRICT=1`** — a real version/hash mismatch against a **seeded**
  baseline returns **non-zero**, failing the build. The seeding run (unseeded /
  first run) and a clean match are **always exit 0** regardless of the flag, so a
  fresh baseline can never fail a strict build. CI or an operator that wants the
  gate today opts in with this env var.

**Promotion criterion — when to flip the default to strict.** Flipping strict from
opt-in to the DEFAULT is a **future change, not this one**. Both conditions must
hold first:

1. **Baseline seeded** — `manifests/bsp-baseline.json` carries the reviewed
   known-good `version` + `sha256` (this condition is now satisfied).
2. **Fleet manifest clean** — a fleet manifest run confirms every board resolves to
   that same known-good BSP with no outstanding drift.

When both hold, a future change flips the default (and this section records the
flip).

### Trigger 2 — Mainline lands a frozen V4L2 stateless H.265 ENCODE uAPI + VEPU580 driver

**Condition:** The Linux kernel merges BOTH:
- a **frozen** (non-staging, ABI-stable) V4L2 stateless H.265 encode uAPI, AND
- a VEPU580 stateless encoder driver for RK3588.

**Leading indicator:** Kocialkowski's H.264 stateless / VC8000E work for i.MX8MP.
That series is the closest active effort to a frozen stateless encode uAPI. Watch
for it to merge, stabilize, and then extend to VEPU580 / RK3588. Note: stateless
H.265 **decode** already merged in mainline 7.0. **Encode is the holdout** — the
decode merge does not unblock this trigger.

**Upside when Trigger 2 fires:** the out-of-tree rcawston `rkvenc` driver exposes
slice-level output, dual-core VEPU580 utilization, and zero-copy buffer paths that
vendor MPP does not provide. Those are real latency advantages. If a stable
mainline path to VEPU580 opens, re-evaluating the encoder stack is worth the
effort.

## Why the mainline migration does not claim either historical trigger fired

The rk3588 family manifest carries an `edge` variant that builds a mainline-track
kernel from pinned source with the CeraLive RK3588 patch series applied
(`docs/kernel-build-from-source.md`). The userspace kill switch now clears it for
the next Trixie kernel-flip step; until that step lands it remains explicitly
selected with `--variant edge`. It still does not satisfy the old in-tree trigger:

- It carries the **out-of-tree** rcawston `rkvenc` driver as a patch. Trigger 2
  is about a **frozen, in-tree, mainline** stateless H.265 encode uAPI. Applying
  an out-of-tree driver is the opposite of that condition being met, not evidence
  of it.
- Mainline 7.2 kernels carrying the series have booted and encoded on both
  supported boards. The exact pipeline-produced Trixie image remains unqualified
  until the release build/boot gate runs (`docs/DEFERRED.md` item 9).

This is an explicit adoption of a maintained out-of-tree path, not a claim that
mainline gained a frozen stateless encode ABI.

## What This Doc Is Not

This is a decision record, not a release qualification. It clears the MPP
userspace kill switch using board ABI evidence plus a Trixie index solve; it does
not claim the exact Trixie image has been built, booted, or released.
