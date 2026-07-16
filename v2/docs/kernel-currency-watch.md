# Kernel Currency Watch: Vendor 6.1 Lock + Revisit Triggers

**Decision recorded:** vendor BSP 6.1 + Rockchip MPP — no migration.
**Selection mechanism:** exact BSP Debian versions ([`v2/manifests/armbian-bsp-deb-versions.txt`](../manifests/armbian-bsp-deb-versions.txt)); the MPP/GPU **userspace** (not in the Armbian feed) is pinned + SHA-256-verified in [`v2/manifests/rk3588-userspace-deb-versions.txt`](../manifests/rk3588-userspace-deb-versions.txt).
**Visibility mechanism:** BSP provenance/drift-guard ([`v2/manifests/bsp-baseline.json`](../manifests/bsp-baseline.json), Task 3).

---

## The Decision

The image runs `armbian_branch: vendor` (Linux 6.1 Rockchip vendor BSP). The
streaming engine (`cerastream`) encodes H.265 via **Rockchip MPP** — the mature,
hardware-accelerated path that the vendor BSP exposes. This is not changing.

The vendor kernel exposes the MPP hardware, but the MPP **userspace** that makes it
reachable from GStreamer is NOT in the Armbian feed: `librockchip-mpp1` 1.5.0-1
(tsukumijima) + `gstreamer1.0-rockchip1` 1.14-4 + `librga2` 2.2.0-1 (radxa) register
`mpph264enc`/`mpph265enc`/`mppjpegenc`/`mppvp8enc`, proven on real Rock 5B+ hardware
(ffprobe-verified). These are baked from exact pinned release assets, SHA-256-verified
in [`v2/manifests/rk3588-userspace-deb-versions.txt`](../manifests/rk3588-userspace-deb-versions.txt)
(staged by `fetch_rk3588_userspace`), not from the Armbian pool. The MPP encoder
**version** is now part of the userspace pin set — bump only after re-proving on hardware.

## Why (7-Way Evidence Summary)

Seven independent checks all point the same direction:

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

## Revisit Triggers

Do not re-evaluate the kernel choice unless one of these two conditions is met.
Neither is close to firing today.

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

1. **Baseline seeded** — `v2/manifests/bsp-baseline.json` carries the reviewed
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

## What This Doc Is Not

This is a decision record, not a roadmap. It records what was true at the time of
the decision and what would need to change to revisit it. There are no timelines,
no commitments, and no scheduled reviews — the triggers above are the only
criteria that matter.
