# Deferred and Hardware-Gated Work

**Status:** `[EXISTS]`

This index consolidates every item that is explicitly deferred or blocked on
physical hardware access. Each entry records what the item is, why it is
deferred, where the relevant code or spec lives, and what must happen before
work can resume.

Items are documentation-only. None are resolved here.

---

## 1. OPi 5+ Interface ID_PATH Placeholders

**Status:** Deferred (hardware-gated)
**Location:** `v2/manifests/boards/orange-pi-5-plus.yaml:45-47`
**Also referenced:** `AGENTS.md:245-252`

**What it is:** The `interfaces:` block in the Orange Pi 5+ board manifest
carries `FIXME-…` placeholder values for all three network interfaces
(`eth0`, `eth1`, `wlan0`). The OPi 5+ has two onboard r8169 NICs on the same
driver and bus, so a generic `Type=ether` udev match races between them.
Deterministic renaming requires the real `ID_PATH` values read from the
physical board.

**Why deferred:** The board is not in hand. `ID_PATH` values are
hardware-specific and cannot be fabricated from specs or emulation. Until they
are filled in, `install_interface_naming()` skips the FIXME entries and emits
only the generic `Type=wlan → wlan0` rule; the dual NICs stay non-deterministic.

**Unblock condition:** Obtain a physical Orange Pi 5+. Run
`udevadm info /sys/class/net/<iface> | grep ID_PATH` for each onboard NIC and
the wifi adapter, then replace each FIXME in
`v2/manifests/boards/orange-pi-5-plus.yaml:45-47` with the real value.
Re-run `v2/run-tests` to confirm the manifest validates.

---

## 2. Modem Interface Naming (usb0..7)

**Status:** Deferred (hardware-gated)
**Location:** `AGENTS.md:268-270`

**What it is:** Deterministic udev rename rules for USB modem interfaces
(`usb0`..`usb7`) are not implemented. Only `eth0`, `eth1`, and `wlan0` are
pinned today. Modem interfaces keep their kernel-assigned names, which can
shift across reboots or when multiple modems are present.

**Why deferred:** Deterministic modem renames require reading the `ID_PATH` of
a physical modem from a live device. The naming uncertainty is distinct from
the source-routing issue (the NM `dhcp=internal` hook problem described in
`AGENTS.md:254-266`): routing can be addressed in software, but the rename
rules need hardware evidence.

**Unblock condition:** Attach a supported USB or M.2 modem to a running
CeraLive device. Read `udevadm info /sys/class/net/<iface> | grep ID_PATH` for
each modem interface. Add deterministic `.link` rules to
`v2/manifests/boards/<board>.yaml` (or a shared family manifest) using the
real `ID_PATH` values. Note: any change to the modem interface naming block
also touches the drift-gated SRTLA payloads (`v2/ci/postinst-drift-check.sh`
CHECK 2) and requires a twin-update of both `networking-srtla.sh` and the `§6`
block in `mkosi.postinst.chroot`.

---

## 3. x86 ESP + GRUB A/B Disk Assembly (TODO(x86-disk))

**Status:** Deferred — being addressed this round by Task 12
**Location:** `v2/lib/orchestrate.sh:396`

**What it is:** When `RAUC_BOOTLOADER_ADAPTER` is `efi` or `grub`, the
orchestrator's Stage-4 disk assembly step is explicitly skipped. The x86 build
produces a `rootfs.tar` only; no flashable `.raw` is emitted. The TODO comment
at line 396 marks the gap: wiring an EFI System Partition, `grub-install`
layout, `grubenv` A/B slot selection, and the RAUC `efi` adapter behind this
branch.

**Why deferred:** The RK3588 `custom` bootloader path (idbloader gap +
`assemble-disk.sh`) is not reusable for x86 EFI. Routing x86 through the
`custom` path would produce a non-bootable image. The x86 QEMU fallback
self-test (`v2/tests/qemu-x86.sh --fallback-selftest`) exercises the GRUB A/B
grubenv engine and proves the boot logic, but the full disk assembly path was
not wired in the initial implementation.

**Unblock condition:** Task 12 (x86 GRUB A/B disk assembly) in this round
implements the ESP layout, `grub-install` invocation, and `grubenv` A/B slot
wiring behind the `efi`/`grub` branch in `v2/lib/orchestrate.sh:389-398`.
Once Task 12 lands, this TODO is resolved and the x86 build produces a
flashable `.raw`.

---

## 4. Cog + WPEWebKit Render QA (Hardware-Gated)

**Status:** Hardware-gated
**Location:** `v2/docs/cog-display-addon.md:312-334` (§7), `v2/docs/cog-display-hw-checklist.md` (full runbook), `AGENTS.md:225-228`, `AGENTS.md:272-274`

**What it is:** The Cog + WPEWebKit display add-on packaging is fully
validated in software (apt index, layer contract, build+sign pipeline). The
`cog.sysext.conf` descriptor and build wrapper exist as inert scaffolds. They
are not wired into the build or CI `addon-publish` path until a physical RK3588
board validates render.

The hardware-gated items are:

- Cog renders at all via the real Mali-G610 Valhall GPU userspace
  (`libmali-valhall-g610-g24p0-wayland-gbm`) providing EGL/GBM
- OKLCH and Tailwind v4 CSS correctness on WebKit 2.38.6 (the bookworm version
  may predate the Chromium ≥111 floor assumed by the cage + Chromium kiosk path)
- `cog` platform choice: direct-DRM/KMS vs under `cage` (DRM node mapping is
  itself a Task 28 hardware item)
- Touch input through the WPE/Wayland seat (requires DSI touchscreen + calibration)
- GLVND vs `dpkg-divert` libmali wiring
- Measured `cog.raw` size and size-budget impact

**Why deferred:** No RK3588 board is reachable from the dev environment (Task 1
spike verdict: NO-GO). The Mali-G610 GPU userspace is a proprietary Rockchip
blob not present in Debian bookworm or Armbian's main feed; it cannot be
emulated. Everything provable without hardware is already green and recorded in
`test-results/task-39-cog-qa.txt`.

**Unblock condition:** Run the full checklist in
`v2/docs/cog-display-hw-checklist.md` on a physical Radxa Rock 5B+ or Orange
Pi 5+ with a display attached. Every REQUIRED item in §1 through §4 and §6
must pass with evidence captured to `test-results/`. On sign-off: flip
`cog-display-addon.md` and `kiosk-display.md` Cog status from `[PARTIAL]` to
`[EXISTS]`; resolve TD-C1/TD-C3/TD-C4; wire `cog-display.sysext.conf` into
the build and CI `addon-publish` path; pin `cog`/`wpewebkit` versions in
`versions.yaml` (see item 5 below).

---

## 5. versions.yaml Null Pins for cog and wpewebkit

**Status:** Deferred (hardware-gated, same gate as item 4)
**Location:** `versions.yaml:81-93` (workspace root, consumed by `scripts/fetch-debs.sh`)

**What it is:** The `cog` and `wpewebkit` entries in `versions.yaml` carry
`pin: null`. The apt-index-validated versions (cog `0.16.1-1`,
`libwpewebkit-1.1-0` `2.38.6-1`) are recorded in comments but not pinned,
because pinning before render QA passes would lock a version that may need to
change (e.g. if WebKit 2.38.6 proves insufficient for OKLCH/Tailwind v4 and a
trixie/backport snapshot is needed instead).

```yaml
# versions.yaml:81-93
cog:
  kind: debian-apt
  source: bookworm/main
  package: cog
  pin: null  # 0.16.1-1 validated from apt index; pin after hardware render QA

wpewebkit:
  kind: debian-apt
  source: bookworm/main
  package: libwpewebkit-1.1-0
  pin: null  # 2.38.6-1 validated from apt index; pin after hardware render QA
```

**Why deferred:** Pinning is intentionally deferred until render QA confirms
the bookworm versions are sufficient. The technical debt is tracked as TD-C1 in
`v2/docs/cog-display-addon.md:361`.

**Unblock condition:** Same gate as item 4. After the Cog render QA checklist
passes on hardware, fill the real `artifact.sha256` in `cog-display.json`, then
set `pin: 0.16.1-1` and `pin: 2.38.6-1` (or the trixie/backport equivalents if
the bookworm versions proved insufficient) in `versions.yaml:85` and
`versions.yaml:92`. Re-run `python3 v2/ci/validate-manifests.py` to confirm.

---

## 6. DEVICE-BRINGUP.md Hardware-Evidence TODOs

**Status:** Deferred (hardware-gated)
**Location:** `docs/DEVICE-BRINGUP.md:293`, `docs/DEVICE-BRINGUP.md:323`, `docs/DEVICE-BRINGUP.md:380`, `docs/DEVICE-BRINGUP.md:634`

**What it is:** Four `[TODO]` placeholders in the public device bring-up guide
await evidence from physical board runs:

- **Line 293** — maskrom mode entry procedure for Rock 5B+: the general
  RK3588 steps are documented but the board-specific button location and
  confirmed `rkdeveloptool ld` output are placeholders pending a real bring-up
  run.
- **Line 323** — first-boot sequence: the expected U-Boot → kernel → health
  gate → CeraUI sequence is described but marked as "hardware evidence pending"
  because no board has been booted with a CeraLive image yet.
- **Line 380** — `dev-sync --frontend` invocation and behavior: the dev-sync
  frontend path is specced but the confirmed invocation and output are
  placeholders pending T17-T21 hardware evidence.
- **Line 634** — first-boot network troubleshooting: the "board does not appear
  on the network" section is a placeholder pending T17-T18 hardware evidence.

**Why deferred:** All four items require a physical RK3588 board running a
CeraLive image. The build system is functional; the hardware-specific evidence
(boot logs, maskrom confirmation, network bring-up) cannot be fabricated.

**Unblock condition:** Complete a physical bring-up run on a Radxa Rock 5B+ or
Orange Pi 5+. Capture boot logs to `test-results/boot-log-<date>.txt` (the
placeholder reference already used in the guide). Fill each `[TODO]` section
with the observed procedure and output. The guide's own placeholder text
references `test-results/boot-log-<date>.txt` as the evidence target.

---

## Related Documents

| Document | Scope |
|----------|-------|
| `v2/docs/cog-display-addon.md` | Cog packaging recipe, libmali strategy, §7 hardware caveats |
| `v2/docs/cog-display-hw-checklist.md` | Ready-to-run RK3588 render QA runbook (clears item 4) |
| `v2/docs/kiosk-display.md` | Kiosk chassis, Phase-3 deferral register (e-ink, dual-display, live-video preview, battery telemetry) |
| `docs/DEVICE-BRINGUP.md` | Public bring-up guide with hardware-evidence TODOs (item 6) |
| `v2/manifests/boards/orange-pi-5-plus.yaml` | OPi 5+ board manifest with FIXME ID_PATHs (item 1) |
| `v2/lib/orchestrate.sh` | x86 disk assembly TODO(x86-disk) at line 396 (item 3) |
| `AGENTS.md §KNOWN ISSUES / DEFERRED` | Prose summary of items 1, 2, and 4 |
