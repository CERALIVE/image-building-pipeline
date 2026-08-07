# Kernel Dual-Track Decision Record: edge 7.1 Promotion Go/No-Go

**Status: DOCUMENTATION ONLY. No kernel promotion. No image publish. No production
change of any kind.** Production continues to run vendor 6.1 exactly as before this
document was written. Nothing in this record changes `armbian_branch: vendor` (D3),
`REPOS`, `versions.yaml`, or any release artifact.

**Recorded:** 2026-08-07 (device-platform-wave4 todo 30).
**Inputs:** todo 28 (`task-28-hdmirx-uvc-bench.md`, `task-28-journal-diff-2026-08-06.md`),
todo 29 (`task-29-h265-probe-runbook.md`), todo 27 (`task-27-sd-boot-validation.md`,
`task-27-orangepi5plus-build-fixed-2.md`).

---

## 1. What this document is

The `edge` family variant (`v2/build <board> --variant edge`) builds a mainline
Armbian 7.1 kernel from pinned source with the `CERALIVE/rk3588-kernel-patches`
series applied, as an opt-in, bench-only alternative to the shipped vendor 6.1
BSP. This is the decision record for whether that track is ready to be promoted
to production. It is not itself a promotion, and per the plan's own text a
promotion is **out of scope for this document** — see §5.

---

## 2. Inputs, cited exactly

### 2.1 Todo 28 cell table (bench validation: HDMI-RX+audio, USB-C/F19, UVC, journal)

Source: `.omo/evidence/device-platform-wave4/task-28-hdmirx-uvc-bench.md`, §0
headline table (lines 14-20), plus the closing sections cited per cell below.

| Cell | Verdict | Citation |
|---|---|---|
| (a) HDMI-RX + audio | **FULL PASS**, 0 failures, 2 environment-condition SKIPs (only one source resolution on the bench) | `task-28-hdmirx-uvc-bench.md` §2, table lines 76-87 |
| (b) USB-C/F19 2h idle soak | **FULL PASS (unloaded)** — 0 raw CC transitions over 7201s = 0.0000 events/hour vs the 0.292 events/hour vendor-6.1 baseline (`task-1-device-quality-wave3.md:371`); loaded re-run with the Osmo attached remains open, explicitly recorded as the weaker of the two conditions | `task-28-hdmirx-uvc-bench.md` §4, table lines 389-407 |
| (c) UVC + wedge-recovery | **BLOCKED on the Osmo, all 3 steps** — conclusively, not merely unattempted. Steps 1-2 need the Osmo's UVC-H.264 extension unit, which no substitute device in inventory has. Step 3 was executed twice: once via `v4l2-ctl --list-formats-ext` (RØDE advertises only YUYV+MJPG, zero H.264/H.265), once again from inside the element's own negotiation-failure log (`uvc_error_t=-12`, "device exposes no H264/H265 format") — the second run is `RESULT: FAIL (3 failure(s))`, correctly read as `inconclusive-as-to-recovery` because zero cycles reached fault injection | `task-28-hdmirx-uvc-bench.md` §3.2 (lines 266-306), §5.1 (lines 492-604), esp. the verdict at lines 580-596 |
| (d) dmesg baseline | **PASS (justified)** — zero new error-level signatures vs a genuinely clean, same-duration (300s) vendor-6.1 idle baseline, except one benign, justified, non-recurring HID enumeration message on an unused RØDE sub-interface (quoted below) | `task-28-hdmirx-uvc-bench.md` §3.1, verdict at lines 256-262; deeper classified diff in `task-28-journal-diff-2026-08-06.md` |

**Quoted justification for cell (d)'s one new-vs-vendor61 signature** (per the
plan's own "no benign-waving without a recorded justification the decision doc
must quote"), from `task-28-hdmirx-uvc-bench.md` lines 244-254:

> The `hid-generic ... device has no listeners, quitting` line is a HID-subsystem
> message about the RØDE HDMI-to-USB-C adapter's unused HID sub-interface
> (`input4`...). It fires exactly once, at device enumeration, non-recurring, and
> does not correspond to any RØDE video/audio capture path or any subsequently
> observed functional failure...

**F19 comparative statement** (the plan's acceptance criterion for todo 28
explicitly names this as a required artifact: "F19 comparative statement (7.1 vs
6.1 event rates over the window, honest about window-length limits)"). No
separately-titled document with that exact heading exists; the comparative
statement is cell (b) itself, reproduced verbatim above: **0.0000 events/hour on
edge-7.1 (unloaded, 7201s window) vs 0.292 events/hour on vendor-6.1** (the wave3
recurrence baseline, a 24-hour window — `task-1-device-quality-wave3.md:371`).
Honest window-length limit, stated explicitly in the source evidence
(`task-28-hdmirx-uvc-bench.md` lines 404-407, 415-418): the edge-7.1 measurement
is **unloaded** (no Osmo attached) and is explicitly recorded as the weaker of
the two conditions the plan asked for; a loaded re-run remains open and should
supersede this result rather than being treated as interchangeable with it. This
is recorded here as CONTEXT for the encode-driven verdict in §4, not as an
independent blocker — see §4.

### 2.2 Todo 29 encode verdict (both codecs, all 4 H.265 gates)

Source: `.omo/evidence/device-platform-wave4/task-29-h265-probe-runbook.md` §9
(results) and §10 (FINAL THREE-WAY VERDICT).

**H.264 (`mpph264enc`): `encode-broken`.** Element never registers on the
edge-7.1 kernel — confirmed independently twice
(`task-29-encode-validation.md`, `task-29-encode-h265-update-2026-08-05.md`).
Quoted from `task-29-h265-probe-runbook.md` line 417-421:

> Element never registers on this kernel — confirmed independently, unchanged
> from the 2026-08-04/08-05 findings... No test matrix could run; not a quality
> shortfall, a missing driver capability. Per the plan's own decision matrix
> language: "hold, driver work required first."

**H.265 (`mpph265enc`) probe subset: `encode-degraded`**, all 4 gates measured
across all 6 declared cells (`task-29-h265-probe-runbook.md` §9, §10 table at
lines 426-431):

| Gate | Result | Citation |
|---|---|---|
| (i) VMAF/SSIM parity | **PASS, all 6 cells** — every ΔVMAF/ΔSSIM inside noise-floor distance of zero (largest \|ΔVMAF\| 0.058 against a ±3.0 gate) | §9 table, lines 341-349 |
| (ii) Motion-artifact blinded review | **PASS, both motion clips** — 0/40 hits vs a ≥2-hits FAIL threshold | §9, lines 368-382 |
| (iii) Bitrate accuracy | **FAIL 3/6 cells** (C1, C2, C5 — all low-complexity/synthetic content), **PASS 3/6** (C3, C4, C6 — both real-footage cells pass cleanly); symmetric across both kernel tracks, never >0.3 percentage-point difference edge vs vendor on any cell | §9, lines 296-350 |
| (iv) 30-min sustained soak | **PASS** — 0% fps degradation, 0 encoder errors, 0 kernel errors, thermal 48.1-51.8°C throughout | §9, lines 385-411 |

Quoted verdict, `task-29-h265-probe-runbook.md` lines 423-425:

> Per the plan's deterministic verdict rule ("any cell fails i-iv →
> `encode-degraded` [cell list + evidence]"), the correct verdict is
> **`encode-degraded`**, driven entirely by gate (iii) on 3 of 6 cells (C1, C2,
> C5)...

### 2.3 Remaining gaps (per the plan's own input list)

| Gap | State | Citation |
|---|---|---|
| orangepi5-plus hardware-pending | Image build+verified twice (component-manifest comparison passes, 545 package versions / 18,833 rootfs paths identical), `[7/9]` parity gate clears at 18/0/0. No physical Orange Pi 5+ unit was available this session, so no boot smoke was performed on it — `build-verified/hardware-pending` per todo 27's own disposition language, not a build failure | `task-27-orangepi5plus-build-fixed-2.md` (headline table, lines 1-25) |
| HDMI-RX audio state | Investigated and **resolved as not a defect** — an initial ~3-minute audio-recovery-latency concern was re-checked with a precisely-timestamped controlled unplug/replug cycle and found to be normal (audio re-enables within ~1-4s of the link actually restoring; the earlier reading simply reflected how long the cable had been left unplugged) | `task-28-hdmirx-uvc-bench.md` §2.3, "HDMI-RX audio-recovery-latency — investigated, resolved as not a defect" (lines 130-148) |
| Decode-side absence, issue #3 | `rcawston/rockchip-rk3588-mainline-patches` (the upstream this fork tracks) carries **no decode-side coverage at all** — the patch series is encode/capture-only. Recorded in the plan's own references and in the draft's provenance note: "no decode-side coverage (issue #3); no USB-C/UVC patches at all" | `.omo/plans/device-platform-wave4.md:343` (references the librarian lane `bg_e6b96974` "full patch inventory... issue #2 motion artifacts + #3 no-decoder"); `.omo/drafts/device-platform-wave4.md:120` |

Rock 5B+ boot smoke (the board this todo's other cells ran on) is closed, not a
gap: full boot to userspace, SSH reachable, eMMC intact — `task-27-sd-boot-validation.md`
§4 verdict table (lines 112-118).

---

## 3. The deterministic decision matrix, verbatim

Quoted from `.omo/plans/device-platform-wave4.md:395` (todo 30's own text), the
exact rule this document is required to apply mechanically, with no judgment call:

> `encode-parity` + all 28-cells pass → promote-when list (remaining gates only);
> `encode-degraded` or any 28-cell FAIL → hold-because naming each failed cell as
> a gate; `encode-broken` → hold, driver work required first;
> `image-nonbooting`/`blocked-by-boot` (from 27) → `hold-because: image does not
> boot` — the decision doc IS written in this case (the track closes cleanly;
> only partial/unverdicted cells block the doc).

---

## 4. RECOMMENDATION

**Applying the matrix:** todo 29 measured `encode-broken` for H.264
(`mpph264enc` never registers on edge-7.1 — §2.2) and `encode-degraded` for the
H.265 probe subset (§2.2). Per the matrix's own text, the `encode-broken` branch
fires: **"`encode-broken` → hold, driver work required first."**

This branch is unconditional on its own terms — it is a separate `if` arm from
`encode-degraded`/`any 28-cell FAIL`, not a refinement of it, and the matrix
gives no combination rule that would let a passing cell elsewhere soften it. The
correct read is therefore mechanical, not judged: **H.264's `encode-broken`
verdict alone determines the outcome**, full stop, regardless of what H.265's
gate-by-gate results or todo 28's Osmo-pending cells separately show.

### RECOMMENDATION: **HOLD, DRIVER WORK REQUIRED FIRST.**

**Hold-because**, in the matrix's own terms:

- `mpph264enc` (H.264, the product's primary encode path — the corpus explicitly
  scopes H.264 to run the FULL {1080p30, 1080p60, 4K30} × {4, 8, 12 Mbps}
  matrix, per `task-29-h265-probe-runbook.md` line 8-9 "Todo 29's H.264 axis is
  closed as `encode-broken` and needs nothing further") never initializes on
  the edge-7.1 kernel. This is a driver capability gap, not a quality shortfall
  — the element does not register at all, so no test matrix could even attempt
  to run.

**What the H.265 probe and todo 28's remaining gaps mean here — context, not
co-equal blockers, per the mandate above:**

- H.265's `encode-degraded` verdict is real, gate-precise, and encouraging on
  its own terms: quality/kernel parity is clean on every one of 6 cells
  (§2.2), the only failing gate is bitrate accuracy, and it fails only on
  low-complexity/synthetic content while both real-footage cells pass cleanly.
  This is meaningfully different from — and should not be conflated with —
  H.264's `encode-broken` state, per `task-29-h265-probe-runbook.md` line 444-450.
  It does not change the RECOMMENDATION; H.264 alone already forces `hold`.
- Todo 28's Osmo-pending cell (c) steps and cell (b)'s not-yet-loaded soak
  (§2.1, §2.3) are the "remaining gaps" the plan's own input list anticipates
  naming, not additional independent gates this recommendation is conditioned
  on. Even a clean loaded F19 result and a fully-passing UVC cell (c) would not
  change the RECOMMENDATION, because the matrix's `encode-broken` branch does
  not reference cell (c)/(b) at all.

**What would need to change before this is revisited:** a driver fix for
`mpph264enc` on the edge-7.1 kernel (or its `librockchip-mpp` userspace
counterpart) that gets H.264 encoding registering and producing output — not a
config change, since `verify-kernel-config.sh` has already ruled that class of
defect out for this specific failure (H.264's `encode-broken` finding is a
runtime element-registration failure, independent of the `CONFIG_DMABUF_HEAPS`
/`CONFIG_NF_TABLES`/etc. class of gaps documented in the pipeline's own KEY
FACTS). No such fix exists today, and none is scheduled by this document.

---

## 5. Explicit production statement

**Production remains vendor 6.1 NOW.** D3 (`armbian_branch: vendor`) is
unchanged by this document. No shipped image, no release artifact, and no
`versions.yaml`/`REPOS` entry is touched here.

**Promotion, if it is ever pursued, requires a separate, user-approved effort.**
This document does not schedule, propose a timeline for, or auto-trigger that
effort. Per the pipeline's own delivery model, the mechanism for a future
promotion (should H.264 driver work close the gap above and a user
independently approves moving forward) would be a fleet reflash delivered via
RAUC full-image — not an in-place kernel swap. Naming that mechanism here is
not scheduling it.

---

## 6. Citation index (for the QA-reproducibility bar)

Every claim in §2-§4 traces to one of: `task-28-hdmirx-uvc-bench.md`,
`task-28-journal-diff-2026-08-06.md`, `task-29-h265-probe-runbook.md`,
`task-27-sd-boot-validation.md`, `task-27-orangepi5plus-build-fixed-2.md`,
`.omo/plans/device-platform-wave4.md:378` (todo 28's exact thresholds),
`.omo/plans/device-platform-wave4.md:387` (todo 29's exact thresholds),
`.omo/plans/device-platform-wave4.md:395` (todo 30's exact matrix, quoted in
§3). No claim in this document is asserted without a source file+line/section
citation. The matrix outcome is reproducible from todo 28's and todo 29's
evidence alone, per the plan's own QA scenario for this todo.
