# Cog Display Add-On — On-Hardware Render QA Checklist

**Status:** `[GREENFIELD]` — ready-to-run, blocked on a physical RK3588 board.
**Scope:** image-building-pipeline (chassis/packaging) + CeraUI (add-on manager runtime).
**Gate:** the SAME hardware gate as kiosk Tasks 26/27/28 (Task 1 spike: NO-GO — no
RK3588 reachable from the dev environment).

This is the concrete, step-by-step checklist an operator runs **once a physical
RK3588 board (Radxa Rock 5B+ or Orange Pi 5+) with an attached display is in
hand** to clear the Cog render-QA gate. Everything provable WITHOUT hardware is
already green and recorded in `test-results/task-39-cog-qa.txt`; this document
covers only what genuinely needs the board.

The packaging spec this validates is `v2/docs/cog-display-addon.md` (acquisition,
libmali exclusion contract, size estimate). The render items below are its §7
"hardware-gated caveats" turned into an executable runbook.

> **Why this is gated, stated plainly:** Cog rendering depends on the real
> Mali-G610 Valhall GPU userspace (`libmali-…-wayland-gbm`) providing EGL/GBM,
> plus the actual DSI/HDMI display and touch panel. None of that exists in an
> emulator. No claim that "Cog renders" is valid until every REQUIRED item below
> is checked on the board, with the evidence captured.

---

## 0. Pre-flight (host + board)

- [ ] Board: Radxa Rock 5B+ **or** Orange Pi 5+ (RK3588/RK3588S), display
      connected (HDMI out **or** DSI panel), touch panel wired if testing touch.
- [ ] A CeraLive image built for the target board boots to login and
      `ceralive`/`ceraui.service` is `active` (run `v2/tests/realhw-smoke.sh`
      LIVE mode first: `BOARD_IP=<ip> BOARD=<board> v2/tests/realhw-smoke.sh`).
- [ ] The Platform layer provides the Mali-G610 **wayland-gbm** userspace
      (`libmali-valhall-g610-g24p0-wayland-gbm`, TD-C2 in `cog-display-addon.md`).
      Confirm on the board: `ls -l /usr/lib/aarch64-linux-gnu/libmali*` and that
      `libEGL.so.1` / `libgbm.so.1` resolve to the Mali blob (GLVND ICD or
      `dpkg-divert`), NOT mesa.
- [ ] Add-on signing public keyring baked at
      `/usr/share/ceralive/addon-keyring.gpg`.
- [ ] Descriptor baked at `/usr/share/ceralive/addons/cog-display.json`
      (validate first: `python3 v2/ci/validate-manifests.py`).

---

## 1. Build + sign the real Cog sysext (REQUIRED — needs an arm64 build)

The software-path QA proved the build+sign pipeline against a STUB staging tree
(`test-results/task-36-cog-sysext.txt`). This step produces the REAL payload from
the bookworm `main`/arm64 apt closure.

- [ ] In the emulated-arm64 bookworm build chroot, download the closure per
      `cog-display-addon.md §4.1`:
      `apt-get install -y --no-install-recommends --download-only -o Dir::Cache::archives="$staging" cog`
- [ ] Extract the `.deb`s into a staging root, then build a signed per-board
      `.raw` for EACH board variant in `cog-display.sysext.conf`
      (`SYSEXT_BOARD_VARIANTS="rock-5b-plus orange-pi-5-plus"`):
      ```
      v2/lib/build-feature-sysext.sh \
        --feature cog-display --board rock-5b-plus --os-version 12 \
        --deb-staging "$staging" --out dist/
      ```
- [ ] Confirm the three artifacts per board exist and self-verify:
      `cog-display-<board>-12.raw`, `.raw.sha256`, `.raw.sig`
      (the builder runs `gpgv` against the exported public keyring before exit).
- [ ] **Exclusion contract has teeth:** the build FAILS LOUDLY if any
      `SYSEXT_EXCLUDE_NAMES` glob survived the prune. Confirm no `libmali*`,
      `libEGL*`, `libgbm*`, or `librockchip_mpp*` is inside the `.raw`
      (`unsquashfs -l dist/cog-display-rock-5b-plus-12.raw | grep -Ei 'libmali|libEGL|libgbm|rockchip'` → empty).
- [ ] **No Chromium leak:** `SYSEXT_FORBID_PACKAGES` (`chromium`, `chromium-common`,
      `libmali-valhall-g610`) never appears in the closure or the `.raw`.
- [ ] Record the MEASURED `.raw` size and compare to the `cog-display-addon.md §6`
      estimate (~45–65 MB squashed); update `manifests/size-budget.json` if it
      moves the budget.
- [ ] Fill the real `artifact.sha256` (and per-board `boardVariants[].sha256`) in
      `cog-display.json`, pin `cog`/`wpewebkit` in `versions.yaml` (TD-C1), then
      re-run `python3 v2/ci/validate-manifests.py`.

---

## 2. Stage + activate on the board (REQUIRED)

Publish to R2 (`v2/lib/upload-addons.sh`) or hand-stage for a first bring-up:

- [ ] Copy `cog-display-<board>-12.raw` (+ `.sig`) onto the board and place the
      `.raw` in the sysext store the add-on helper scans
      (`/data/extensions/cog-display.raw`).
- [ ] Drive enable via the CeraUI add-on manager on the REAL device (the same
      `enableAddon` path proven gated in emulated mode):
      gpgv + sha256 verify → `systemd-sysext refresh` → unmask/start units.
- [ ] `systemd-sysext status` lists the `cog-display` extension as merged.
- [ ] `/usr/bin/cog` and `/usr/bin/cage` resolve on the merged `/usr`
      (`command -v cog cage`), and `cog --version` prints `0.16.x`.

---

## 3. Render correctness (REQUIRED — the actual gate)

This is the core of the gate. None of it is provable off-hardware.

- [ ] **Cog starts and renders at all** via libmali EGL/GBM. Choose the platform
      per `cog-display-addon.md §8`:
      - direct-DRM/KMS: `WLR_… N/A`; run `cog --platform=drm http://127.0.0.1/`
        on the `card0` display node (NOT the `card1` render node — DRM node
        mapping is the Task 28 hardware item).
      - under cage: `cage -- cog http://127.0.0.1/`.
      Capture the EGL init log; confirm it binds the Mali GBM platform, not
      software (llvmpipe) fallback.
- [ ] **CeraUI loads** end-to-end: the on-device URL
      (`http://127.0.0.1:80/?mode=touch&display=lcd&kiosk_token=…`) renders the
      live UI, not a blank/`about:blank` page.
- [ ] **OKLCH + Tailwind v4 CSS correctness on WebKit 2.38.6** (TD-C3, the
      deciding item). bookworm WebKit 2.38 predates the Chromium ≥111 floor the
      `kiosk-display.md` Chromium path assumes — **verify pixels, not specs**:
      - [ ] Brand OKLCH colors render at the correct hue/lightness (side-by-side
            screenshot vs a Chromium ≥111 reference of the same page).
      - [ ] Tailwind v4 layout (container queries, `color-mix()`, nested CSS)
            matches the reference — no collapsed/unstyled regions.
      - [ ] If 2.38.6 is insufficient: the SAME Option-A recipe applies against a
            trixie/backport apt snapshot (only the pinned version changes —
            `cog-display-addon.md §2`). Re-run this section after re-pinning.
- [ ] **Capture screenshots** of the rendered UI (brand screen + a colored
      control surface) into `test-results/` as the render evidence.

---

## 4. Input + touch (REQUIRED if a touch panel is fitted)

- [ ] Touch events reach Cog through the WPE/Wayland seat: tapping a control in
      the UI actuates it (toggle a switch, open a dialog).
- [ ] **Touch calibration** (Task 28): touch coordinates map to display geometry
      — taps land on the element under the finger across all four corners +
      center. Record the calibration matrix / `libinput` config used.
- [ ] On-screen keyboard (if the kiosk OSK is in scope): a text input focus
      brings up the keyboard and typed characters reach the field.

---

## 5. Resource + stability (RECOMMENDED)

- [ ] Memory: Cog + (optional) cage RSS under load is within the OOM budget in
      `kiosk-display.md §4` — the engine (`cerastream`, oom_score_adj −500) must
      never be the first OOM victim; Cog is the expendable process.
- [ ] **No stream regression:** start a live SRTLA stream with Cog running and
      confirm bitrate/stability is unchanged vs Cog-off (the display engine must
      not steal GPU/CPU/mem from the encode path).
- [ ] Soak: leave Cog rendering the UI for ≥1 h; no crash-loop
      (`systemctl show cog.service -p NRestarts` stays < 3, the manager's
      auto-disable threshold), no GPU hang, no memory creep.

---

## 6. Disable + cleanup (REQUIRED)

- [ ] Disable via the add-on manager: `systemctl stop` → `systemd-sysext refresh`
      → artifact removed → config state dropped (the disable pipeline proven
      idempotent off-hardware).
- [ ] After disable the device returns to headless operation; `/usr/bin/cog` no
      longer resolves (the sysext unmerged), and a fresh boot does not
      re-materialise it unless still `enabled` in config.

---

## 7. Sign-off

The gate clears **only** when every REQUIRED item (§1–§4, §6) is checked on a real
RK3588 with evidence captured. On sign-off:

- [ ] Write the on-hardware evidence (logs + screenshots + measured size) to
      `test-results/` and reference it here.
- [ ] Flip `cog-display-addon.md` and `kiosk-display.md` Cog status from
      `[PARTIAL]`/hardware-gated to `[EXISTS]`; resolve TD-C1/TD-C3/TD-C4.
- [ ] Wire `cog-display.sysext.conf` from inert scaffold into the build/CI
      `addon-publish` path; pin the validated `cog`/`wpewebkit` versions in
      `versions.yaml`.
- [ ] Mirror the descriptor `conditions` + `boardVariants` into the CeraUI
      `AddonDescriptorSchema` and extend `ADDON_PHASES` with `unsupported` (T37
      follow-up, locked by a test in `CeraUI/apps/backend/src/tests/cog-addon-qa.test.ts`).

---

## 8. What is ALREADY proven (software path — no hardware)

For completeness, the gate does NOT block on any of these — they are green and
recorded in `test-results/task-39-cog-qa.txt`:

| Check | Result |
|---|---|
| `cog-display.json` validates against `addon.schema.json` (+ G1/G2/E6) | PASS |
| Reconciler skips gracefully in emulated mode (no fetch/refresh/write, never throws) | PASS |
| `enableAddon(cog-display)` returns `addon_unavailable_in_emulated_mode` (G6) | PASS |
| `disableAddon(cog-display)` gated symmetrically | PASS |
| Descriptor wire-path parses under the CeraUI `AddonDescriptorSchema` | PASS |
| Build+sign pipeline against a stub staging tree (`task-36-cog-sysext.txt`) | PASS |
| `v2/run-tests` bats suite | GREEN |

---

## 9. Related documents

(Plain references — no workspace-external relative links, per root Rule D.)

| Document | Scope |
|---|---|
| `v2/docs/cog-display-addon.md` | W4 packaging recipe, libmali exclusion, size estimate, §7 hardware caveats |
| `v2/docs/kiosk-display.md` | cage + Chromium kiosk chassis (units, OOM, DRM node notes), Phase-3 register |
| `v2/docs/addon-sysext-refresh.md` | sysext refresh → service restart protocol |
| `v2/mkosi/app/cog-display.sysext.conf` | inert build scaffold (apt closure, exclusions, board variants) |
| `v2/lib/build-feature-sysext.sh` | the signed per-board/per-OS sysext builder |
| `v2/tests/realhw-smoke.sh` | RK3588 LIVE-mode boot/service smoke harness (run before §1) |
| CeraUI repo — `apps/backend/src/modules/addons/{manager,reconciler}.ts` | runtime enable/disable + post-boot reconcile (G6-gated) |
