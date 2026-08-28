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

The packaging spec this validates is `docs/cog-display-addon.md` (acquisition,
GPU strategy, measured size). The render items below are its §7 "hardware-gated
caveats" turned into an executable runbook.

> **Why this is gated, stated plainly:** Cog rendering depends on the real
> Mali-G610 being bound by the `panthor` kernel driver and driven by Mesa's
> `panthor_dri.so`, plus the actual DSI/HDMI display and touch panel. None of
> that exists in an emulator. No claim that "Cog renders" is valid until every
> REQUIRED item below is checked on the board, with the evidence captured.

> **What moved at the trixie/mainline migration** (read this before running the
> list — several steps target different files than they used to):
>
> | | Was (bookworm + vendor BSP) | Now (trixie + mainline `edge`) |
> |---|---|---|
> | Kiosk closure | `cog` 0.16.1, `libwpewebkit-1.1-0` 2.38.6 | `cog` **0.18.4-1+b1**, `libwpewebkit-2.0-1` **2.48.3-1** |
> | GPU kernel driver | Rockchip out-of-tree Mali, `/dev/mali0` | **`panthor`**, `/dev/dri/renderD*` |
> | GPU userspace | `libmali-…-wayland-gbm` from the Platform layer | **Mesa**, carried inside this add-on's own `.raw` |
> | Where to look for it on the board | `/usr/lib/aarch64-linux-gnu/libmali*` | `/usr/lib/aarch64-linux-gnu/dri/panthor_dri.so` |
>
> The software half of §1 is no longer only "proven against a stub": the real
> trixie closure has been downloaded, pruned and squashed, with the transcript in
> `.omo/evidence/cerastream-glibc-pipewire-network-ui/todo14-cog-closure.txt`.
> What is still entirely unproven is everything from §2 onward.

---

## 0. Pre-flight (host + board)

- [ ] Board: Radxa Rock 5B+ **or** Orange Pi 5+ (RK3588/RK3588S), display
      connected (HDMI out **or** DSI panel), touch panel wired if testing touch.
- [ ] A CeraLive image built for the target board boots to login and
      `ceralive`/`ceraui.service` is `active` (run `tests/realhw-smoke.sh`
      LIVE mode first: `BOARD_IP=<ip> BOARD=<board> tests/realhw-smoke.sh`).
- [ ] The board is running the **mainline `edge`** image (this runbook no longer
      targets the vendor track). Confirm `uname -r` reports the `-ceralive-rk3588`
      release, and that the `panthor` driver bound the GPU:
      `ls -l /sys/class/drm/` shows a `renderD*` node whose
      `device/driver` symlink resolves to `panthor`.
- [ ] **`libmali` is ABSENT.** `ls /usr/lib/aarch64-linux-gnu/libmali*` must find
      nothing and `ls /etc/ld.so.conf.d/` must contain no `*-mali.conf`. A
      surviving blob captures `libEGL.so.1`/`libGLESv2.so.2`/`libgbm.so.1`
      image-wide for a driver the mainline kernel cannot serve, so this check is
      a prerequisite, not hygiene — if it fails, stop and fix the image.
- [ ] The Runtime layer provides the GLVND/Mesa front half and it is intact:
      `libEGL.so.1`, `libEGL_mesa.so.0`, `libgbm.so.1` and `gbm/dri_gbm.so` all
      present under `/usr/lib/aarch64-linux-gnu/`. (These are NOT pruned; only
      the four Gallium/LLVM globs are — see `cog-display-addon.md` §5.)
- [ ] Confirm the base image really is missing the pruned half BEFORE merging the
      sysext, so §2's overlay claim is falsifiable:
      `ls /usr/lib/aarch64-linux-gnu/libgallium-*.so
      /usr/lib/aarch64-linux-gnu/dri/panthor_dri.so` → both absent.
- [ ] Add-on signing public keyring baked at
      `/usr/share/ceralive/addon-keyring.gpg`.
- [ ] Descriptor baked at `/usr/share/ceralive/addons/cog-display.json`
      (validate first: `python3 ci/validate-manifests.py`).

---

## 1. Build + sign the real Cog sysext (REQUIRED — needs an arm64 build)

The software-path QA proved the build+sign pipeline against a STUB staging tree
(`test-results/task-36-cog-sysext.txt`), and the trixie closure itself has since
been downloaded, pruned and squashed for real (`todo14-cog-closure.txt`). What is
still owed here is the SIGNED per-board artifact, which needs the add-on signing
key.

- [ ] In the emulated-arm64 **trixie** build chroot, download the closure per
      `cog-display-addon.md §4.1`:
      `apt-get install -y --no-install-recommends --download-only -o Dir::Cache::archives="$staging" cog cage mesa-libgallium libgl1-mesa-dri`
- [ ] Extract the `.deb`s into a staging root, then build a signed per-board
      `.raw` for EACH board variant in `cog-display.sysext.conf`
      (`SYSEXT_BOARD_VARIANTS="rock-5b-plus orange-pi-5-plus"`). Do NOT pass a
      literal `--os-version` — it defaults from `manifests/target-release.env`:
      ```
      lib/build-feature-sysext.sh \
        --feature cog-display --board rock-5b-plus \
        --deb-staging "$staging" --out dist/
      ```
- [ ] Confirm the three artifacts per board exist and self-verify:
      `cog-display-<board>-<os_version>.raw`, `.raw.sha256`, `.raw.sig`
      (the builder runs `gpgv` against the exported public keyring before exit).
- [ ] **Exclusion contract has teeth:** the build FAILS LOUDLY if any
      `SYSEXT_EXCLUDE_NAMES` glob survived the prune. Confirm no `libmali*`,
      `libEGL*`, `libgbm*`, or `librockchip_mpp*` is inside the `.raw`
      (`unsquashfs -l dist/cog-display-rock-5b-plus-13.raw | grep -Ei 'libmali|libEGL\.|libgbm\.|rockchip'` → empty).
- [ ] **The GPU half IS present** (the inverse check, and the one that is new):
      `unsquashfs -l dist/cog-display-rock-5b-plus-13.raw | grep -E 'panthor_dri|libgallium-|libLLVM|libz3'` → all four.
      An empty result here means the add-on will merge and then render nothing.
- [ ] **No Chromium leak:** `SYSEXT_FORBID_PACKAGES` (`chromium`, `chromium-common`,
      `libmali-valhall-g610`) never appears in the closure or the `.raw`.
- [ ] Record the MEASURED `.raw` size and compare to the `cog-display-addon.md §6`
      figures (**353 172 379 B installed / 111 521 792 B squashed**, measured
      off-hardware). A large deviation means the closure resolved differently
      from the recorded index — investigate before proceeding.
- [ ] Fill the real `artifact.sha256` (and per-board `boardVariants[].sha256`) in
      `cog-display.json`, pin `cog` `0.18.4-1+b1` / `wpewebkit` `2.48.3-1` in
      `versions.yaml` (TD-C1), then re-run `python3 ci/validate-manifests.py`.

---

## 2. Stage + activate on the board (REQUIRED)

Publish to R2 (`lib/upload-addons.sh`) or hand-stage for a first bring-up:

- [ ] Copy `cog-display-<board>-<os_version>.raw` (+ `.sig`) onto the board and place the
      `.raw` in the sysext store the add-on helper scans
      (`/data/extensions/cog-display.raw`).
- [ ] Drive enable via the CeraUI add-on manager on the REAL device (the same
      `enableAddon` path proven gated in emulated mode):
      gpgv + sha256 verify → `systemd-sysext refresh` → unmask/start units.
- [ ] `systemd-sysext status` lists the `cog-display` extension as merged.
- [ ] `/usr/bin/cog` and `/usr/bin/cage` resolve on the merged `/usr`
      (`command -v cog cage`), and `cog --version` prints `0.18.x`.
- [ ] **The overlay supplied the GPU half.** The four paths that were absent in
      §0 must now resolve on the merged `/usr`:
      `ls -l /usr/lib/aarch64-linux-gnu/{libgallium-*.so,libLLVM.so.*,libz3.so.4,dri/panthor_dri.so}`.
      This is the single check that distinguishes "the sysext merged" from "the
      sysext merged and the GPU stack is actually complete".

---

## 3. Render correctness (REQUIRED — the actual gate)

This is the core of the gate. None of it is provable off-hardware.

- [ ] **Cog starts and renders at all** via **Panthor + Mesa** EGL/GBM. Choose
      the platform per `cog-display-addon.md §8`:
      - direct-DRM/KMS: run `cog --platform=drm http://127.0.0.1/`
        on the `card0` display node (NOT the render node — DRM node
        mapping is the Task 28 hardware item).
      - under cage: `cage -- cog http://127.0.0.1/`.
      Capture the EGL init log. **The pass condition is that it binds the
      `panthor` Gallium driver, NOT `llvmpipe`** — with the megadriver present,
      a Mesa that cannot reach the GPU falls back to the software rasterizer and
      renders *correctly but slowly*, which is the failure mode most likely to be
      mistaken for success. Check it explicitly rather than inferring it from a
      picture appearing: `MESA_LOADER_DRIVER_OVERRIDE` unset, and
      `EGL_LOG_LEVEL=debug` (or `eglinfo`, if present) naming `panthor`.
      A `renderD*` node the kiosk user cannot open produces exactly the same
      llvmpipe fallback, so check node permissions before blaming the driver.
- [ ] **CeraUI loads** end-to-end: the on-device URL
      (`http://127.0.0.1:80/?mode=touch&display=lcd&kiosk_token=…`) renders the
      live UI, not a blank/`about:blank` page.
- [ ] **OKLCH + Tailwind v4 CSS correctness on WebKit 2.48.3** (TD-C3). The
      trixie engine is far newer than the 2.38.6 that made this the *deciding*
      item, so this is now expected to pass on specification grounds — which is
      precisely why it must still be checked on pixels rather than assumed:
      - [ ] Brand OKLCH colors render at the correct hue/lightness (side-by-side
            screenshot vs a Chromium ≥111 reference of the same page).
      - [ ] Tailwind v4 layout (container queries, `color-mix()`, nested CSS)
            matches the reference — no collapsed/unstyled regions.
      - [ ] If 2.48.3 still proves insufficient: the SAME Option-A recipe applies
            against a newer apt snapshot (only the pinned version changes —
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
- [ ] **The GPU half goes with it.** `/usr/lib/aarch64-linux-gnu/libgallium-*.so`
      and `dri/panthor_dri.so` are absent again, i.e. back to the pruned base
      state observed in §0. This is what proves the add-on is genuinely additive
      and inert-by-default rather than having mutated the base image.

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
| `run-tests` bats suite | GREEN |
| Trixie closure resolves + downloads (`cog` 0.18.4-1+b1, `libwpewebkit-2.0-1` 2.48.3-1) | PASS — `todo14-cog-closure.txt` |
| The RETIRED bookworm pins fail to resolve on trixie (apt exit 100, 0 debs) | PASS — `todo14-old-pins-negative.txt` |
| Real extract → prune → squashfs: both required binaries resolve, every exclusion glob clean, `libmali` absent | PASS — `todo14-cog-closure.txt` |
| Payload carries the Panthor userspace (`dri/panthor_dri.so` → `libdril_dri.so` → `libgallium` → `libLLVM`) | PASS — `todo14-cog-closure.txt` |
| `CONFIG_DRM_PANTHOR=m` survives in the real resolved v7.2 `edge` config | PASS — `rk3588-kernel-patches` v72-rebase evidence |

---

## 9. Related documents

(Plain references — no workspace-external relative links, per root Rule D.)

| Document | Scope |
|---|---|
| `docs/cog-display-addon.md` | W4 packaging recipe, libmali exclusion, size estimate, §7 hardware caveats |
| `docs/kiosk-display.md` | cage + Chromium kiosk chassis (units, OOM, DRM node notes), Phase-3 register |
| `docs/addon-sysext-refresh.md` | sysext refresh → service restart protocol |
| `mkosi/app/cog-display.sysext.conf` | inert build scaffold (apt closure, exclusions, board variants) |
| `lib/build-feature-sysext.sh` | the signed per-board/per-OS sysext builder |
| `tests/realhw-smoke.sh` | RK3588 LIVE-mode boot/service smoke harness (run before §1) |
| CeraUI repo — `apps/backend/src/modules/addons/{manager,reconciler}.ts` | runtime enable/disable + post-boot reconcile (G6-gated) |
