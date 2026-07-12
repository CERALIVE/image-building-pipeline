# Hardware-Gated Completion Runbook

**Status:** `[GREENFIELD]` — preparation only. No item below is executed or
confirmed complete. This document is a fill-in-the-blank checklist for the person who
has physical hardware in hand.

**Scope:** image-building-pipeline (all items), with cross-links to
`cerastream/docs/notes/hardware-validation.md` for encoder validation.

**Source of truth for the deferred-item index:** `v2/docs/DEFERRED.md`.
This runbook is the execution companion — it adds exact commands, file:line
targets, and acceptance criteria. It does not replace DEFERRED.md.

**Honesty rule:** no item below is marked done, confirmed, or complete. Every
checkbox is open. Do not check a box without running the step on real hardware
and capturing evidence to `test-results/`.

---

## How to use this runbook

1. Work through items in order (1 → 6). Items 1 and 2 share the same board
   bring-up session; items 3 and 4 share the same RK3588 session.
2. For each item: run the listed commands, capture output to the named
   evidence file, fill in the placeholder values, then check the box.
3. After all boxes in an item are checked, satisfy its **Acceptance** criteria
   and its **Unblock condition** before moving on.
4. Cross-link back to DEFERRED.md and update the status label there once an
   item is fully cleared.

---

## Item 1 — OPi 5+ Interface ID_PATHs

**DEFERRED.md ref:** §1  
**File to edit:** `v2/manifests/boards/orange-pi-5-plus.yaml:45-47`  
**Blocked on:** physical Orange Pi 5+ board

### Background

The OPi 5+ has two onboard r8169 NICs on the same driver and bus. A generic
`Type=ether` udev match races between them. The board manifest ships three
`FIXME-…` placeholder values:

```yaml
# v2/manifests/boards/orange-pi-5-plus.yaml:45-47
interfaces:
  eth0: FIXME-read-from-udevadm-info-on-opi5plus-primary-port
  eth1: FIXME-read-from-udevadm-info-on-opi5plus-secondary-port
  wlan0: FIXME-read-from-udevadm-info-on-opi5plus-wifi
```

Until these are filled, `install_interface_naming()` skips the FIXME entries
and emits only the generic `Type=wlan → wlan0` rule. The dual NICs stay
non-deterministic across reboots.

### Commands (run on the booted OPi 5+)

```bash
# For each network interface, read its ID_PATH:
udevadm info /sys/class/net/eth0  | grep ID_PATH
udevadm info /sys/class/net/eth1  | grep ID_PATH
udevadm info /sys/class/net/wlan0 | grep ID_PATH
```

Expected output shape (example — actual values are board-specific):

```
E: ID_PATH=platform-fdf80000.pcie-pci-0001:01:00.0
E: ID_PATH=platform-fdf80000.pcie-pci-0002:01:00.0
E: ID_PATH=platform-fe1c0000.mmc-mmc-0:0001:1
```

### Fill-in targets

Replace each FIXME in `v2/manifests/boards/orange-pi-5-plus.yaml:45-47` with
the real value read above:

```yaml
interfaces:
  eth0:  <paste ID_PATH value for primary NIC here>
  eth1:  <paste ID_PATH value for secondary NIC here>
  wlan0: <paste ID_PATH value for wifi adapter here>
```

### Checklist

- [ ] Board booted and SSH accessible.
- [ ] `udevadm info /sys/class/net/eth0  | grep ID_PATH` — value recorded.
- [ ] `udevadm info /sys/class/net/eth1  | grep ID_PATH` — value recorded.
- [ ] `udevadm info /sys/class/net/wlan0 | grep ID_PATH` — value recorded.
- [ ] All three FIXME values replaced in `orange-pi-5-plus.yaml:45-47`.
- [ ] `v2/run-tests` passes (manifest validates with real ID_PATHs).
- [ ] Evidence saved to `test-results/opi5plus-id-paths-<date>.txt`.

### Acceptance

`v2/run-tests` exits 0 with no FIXME values remaining in
`v2/manifests/boards/orange-pi-5-plus.yaml`. The `install_interface_naming()`
function emits three per-role `Path=` `.link` rules (not just the generic wlan
rule) when the manifest is resolved for the OPi 5+ board.

### Unblock condition

Obtain a physical Orange Pi 5+. Run the three `udevadm info` commands above.
Replace each FIXME in `v2/manifests/boards/orange-pi-5-plus.yaml:45-47` with
the real value. Re-run `v2/run-tests` to confirm the manifest validates.

---

## Item 2 — Modem Interface Deterministic Naming (usb0..7)

**DEFERRED.md ref:** §2  
**File to edit:** `v2/manifests/boards/<board>.yaml` (or a shared family manifest)  
**Blocked on:** physical USB or M.2 modem attached to a running CeraLive device

### Background

Only `eth0`, `eth1`, and `wlan0` are pinned today. Modem interfaces (`usb0`..`usb7`
and `enx*`) keep their kernel-assigned names, which can shift across reboots or
when multiple modems are present.

Note: modem **source-routing** under NM `dhcp=internal` is already FIXED in
software (the NM dispatcher `90-srtla-wifi-routing` now matches `usb0..7` and
`enx*0..7`). This item is about deterministic **rename rules** only, which require
reading the real `ID_PATH` from a physical modem.

### Commands (run on the device with modem attached)

```bash
# List modem interfaces (names may vary):
ip link show | grep -E 'usb[0-9]|enx'

# For each modem interface found, read its ID_PATH:
udevadm info /sys/class/net/<modem-iface> | grep ID_PATH

# Confirm source-routing is working (already fixed in software):
journalctl -t srtla-routing --no-pager -n 50
ip rule show
```

### .link rule template

Once you have the real `ID_PATH`, add a deterministic rename rule to the board
manifest's `interfaces:` block (or a shared family manifest if the modem is
board-agnostic):

```yaml
# In v2/manifests/boards/<board>.yaml (or shared family manifest):
interfaces:
  # ... existing eth0/eth1/wlan0 entries ...
  usb0: <paste ID_PATH value for modem interface here>
  # Add usb1..usb7 entries if multiple modems are supported.
```

The `install_interface_naming()` function will then emit a `Path=`-based `.link`
rule for each modem interface, pinning it to a stable name.

### Twin-update requirement

Any change to the modem interface naming block **also touches** the drift-gated
SRTLA payloads. After editing the manifest, you must twin-update both:

1. `v2/lib/networking-srtla.sh` — update the interface name references.
2. The `§6` block in `v2/mkosi/mkosi.postinst.chroot` — keep byte-parity.
3. Run `v2/ci/postinst-drift-check.sh CHECK 2` to confirm parity.

### Checklist

- [ ] Modem attached and recognized by ModemManager (`mmcli -L`).
- [ ] Modem interface name(s) identified (`ip link show`).
- [ ] `udevadm info /sys/class/net/<modem-iface> | grep ID_PATH` — value(s) recorded.
- [ ] `.link` rule(s) added to the appropriate board or family manifest.
- [ ] `networking-srtla.sh` twin-updated.
- [ ] `mkosi.postinst.chroot §6` twin-updated.
- [ ] `v2/ci/postinst-drift-check.sh CHECK 2` passes (byte-parity confirmed).
- [ ] `v2/run-tests` passes.
- [ ] Evidence saved to `test-results/modem-naming-<date>.txt`.
- [ ] Verified on hardware: `journalctl -t srtla-routing` shows modem interface
      in tables 100–107 after modem connects.

### Acceptance

After a reboot with two modems attached, each modem interface resolves to its
pinned name (not a kernel-assigned `usb0`/`usb1` that could swap). `ip rule show`
shows source-routing rules in tables 100–107 for each modem interface.
`v2/ci/postinst-drift-check.sh CHECK 2` exits 0.

### Unblock condition

Attach a supported USB or M.2 modem to a running CeraLive device. Read
`udevadm info /sys/class/net/<iface> | grep ID_PATH` for each modem interface.
Add deterministic `.link` rules to the board manifest using the real `ID_PATH`
values. Twin-update `networking-srtla.sh` and the `§6` block in
`mkosi.postinst.chroot`; confirm `postinst-drift-check.sh CHECK 2` passes.

---

## Item 3 — Cog + WPEWebKit Render QA

**DEFERRED.md ref:** §4 (Cog render QA) and §5 (versions.yaml null pins)  
**Files to edit after QA passes:**
- `v2/manifests/addons/cog-display.json` — fill `artifact.sha256`
- `versions.yaml:163` (root repo) — set `pin: 0.16.1-1` (or trixie equivalent)
- `versions.yaml:170` (root repo) — set `pin: 2.38.6-1` (or trixie equivalent)
- `v2/docs/cog-display-addon.md` — flip status from `[PARTIAL]` to `[EXISTS]`
- `v2/docs/kiosk-display.md` — flip Cog status  
**Blocked on:** physical RK3588 board (Radxa Rock 5B+ or Orange Pi 5+) with display

### Background

The Cog + WPEWebKit display add-on packaging is fully proven in software
(apt index, layer contract, build+sign pipeline, descriptor schema). The
`cog.sysext.conf` descriptor and build wrapper exist as inert scaffolds. They
are not wired into the build or CI `addon-publish` path until a physical RK3588
board validates render.

The full step-by-step checklist lives in `v2/docs/cog-display-hw-checklist.md`.
This item is a summary with the key file:line targets. Run the full checklist
there; come back here to record the sign-off.

### Key commands (abbreviated — see cog-display-hw-checklist.md for full detail)

```bash
# Pre-flight: confirm Mali-G610 wayland-gbm userspace is present
ls -l /usr/lib/aarch64-linux-gnu/libmali*
# -> should show libmali-valhall-g610-g24p0-wayland-gbm

# Build the real Cog sysext (in an emulated-arm64 bookworm chroot):
v2/lib/build-feature-sysext.sh \
  --feature cog-display --board rock-5b-plus --os-version 12 \
  --deb-staging "$staging" --out dist/

# Confirm exclusion contract (no libmali/libEGL/libgbm/rockchip inside the .raw):
unsquashfs -l dist/cog-display-rock-5b-plus-12.raw \
  | grep -Ei 'libmali|libEGL|libgbm|rockchip'
# -> must be empty

# Activate on the board:
# (copy .raw + .sig to /data/extensions/cog-display.raw, then drive via CeraUI add-on manager)
systemd-sysext status   # -> cog-display listed as merged
command -v cog cage     # -> both resolve
cog --version           # -> 0.16.x

# Render test (choose platform per cog-display-addon.md §8):
cog --platform=drm http://127.0.0.1/
# OR: cage -- cog http://127.0.0.1/

# Capture screenshots as render evidence:
# -> save to test-results/cog-render-<date>-*.png
```

### versions.yaml pin procedure (root repo, after QA passes)

```yaml
# versions.yaml:159-164 — replace null with confirmed version:
cog:
  kind: debian-apt
  source: bookworm/main
  package: cog
  pin: 0.16.1-1   # <-- fill after render QA; use trixie/backport version if 2.38.6 proved insufficient
  channel: stable

# versions.yaml:166-171 — replace null with confirmed version:
wpewebkit:
  kind: debian-apt
  source: bookworm/main
  package: libwpewebkit-1.1-0
  pin: 2.38.6-1   # <-- fill after render QA; use trixie/backport version if 2.38.6 proved insufficient
  channel: stable
```

After editing, run `python3 v2/ci/validate-manifests.py` to confirm.

### Checklist

- [ ] Pre-flight complete (cog-display-hw-checklist.md §0).
- [ ] Real Cog sysext built and signed for each board variant (§1).
- [ ] Exclusion contract confirmed — no `libmali*`/`libEGL*`/`libgbm*`/`rockchip*`
      inside the `.raw` (§1).
- [ ] Measured `.raw` size recorded; `manifests/size-budget.json` updated if needed.
- [ ] Real `artifact.sha256` filled in `cog-display.json` (§1).
- [ ] Add-on activated on the board; `systemd-sysext status` shows merged (§2).
- [ ] Cog renders via libmali EGL/GBM — NOT llvmpipe fallback (§3).
- [ ] CeraUI loads end-to-end in Cog (§3).
- [ ] OKLCH + Tailwind v4 CSS correctness on WebKit 2.38.6 confirmed (§3).
- [ ] Screenshots captured to `test-results/` (§3).
- [ ] Touch input confirmed if panel fitted (§4).
- [ ] Disable + cleanup confirmed (§6).
- [ ] `versions.yaml:163` set to confirmed `cog` pin (root repo).
- [ ] `versions.yaml:170` set to confirmed `wpewebkit` pin (root repo).
- [ ] `python3 v2/ci/validate-manifests.py` passes.
- [ ] `cog-display-addon.md` and `kiosk-display.md` status flipped to `[EXISTS]`.
- [ ] TD-C1/TD-C3/TD-C4 resolved.
- [ ] `cog-display.sysext.conf` wired into build and CI `addon-publish` path.
- [ ] Evidence saved to `test-results/cog-render-<date>-*.{txt,png}`.

### Acceptance

Every REQUIRED item in `v2/docs/cog-display-hw-checklist.md` §1 through §4 and §6
is checked on a real RK3588 with evidence captured. `cog --version` prints `0.16.x`.
The EGL init log confirms Mali GBM platform (not llvmpipe). Screenshots show correct
OKLCH colors and Tailwind v4 layout. `python3 v2/ci/validate-manifests.py` exits 0
with real `artifact.sha256` and pinned versions.

### Unblock condition

Run the full checklist in `v2/docs/cog-display-hw-checklist.md` on a physical
Radxa Rock 5B+ or Orange Pi 5+ with a display attached. Every REQUIRED item in
§1 through §4 and §6 must pass with evidence captured to `test-results/`. On
sign-off: fill the real `artifact.sha256` in `cog-display.json`, set
`pin: 0.16.1-1` and `pin: 2.38.6-1` (or trixie/backport equivalents if the
bookworm versions proved insufficient) in `versions.yaml:163` and
`versions.yaml:170`. Re-run `python3 v2/ci/validate-manifests.py` to confirm.

---

## Item 4 — Rock 5B+ A/B Hardware Validation

**DEFERRED.md ref:** not a separate DEFERRED.md item — this is a build-system
gate tracked in `AGENTS.md` (KIOSK STACK / hardware-blocked) and in the OTA
validation path.  
**Software prerequisite:** `[EXISTS]` — the Rock manifest enables A/B, the factory
image populates both slots, and the custom backend/bootcount contract is covered
offline.
**Blocked on:** physical Rock 5B+ completing a full OTA A/B rollback cycle on hardware

### Background

The Rock 5B+ production image uses symmetric RAUC A/B slots. The manifest resolves
`single_slot_fallback: false`; `assemble-disk.sh` populates A and B from the same
factory tree; and kernel arguments carry `rauc.slot=A|B`. RK3588 uses RAUC
`bootloader=custom` because the vendor U-Boot has no persistent environment. Its
`boot.scr` selector and FAT-backed boot state implement the three-attempt rollback.
The remaining gate is a real arm64 bundle install, reboot, and rollback on silicon.

> **SAFETY GATE — DO NOT CLAIM PRODUCTION HARDWARE VALIDATION YET.**
>
> A/B must be enabled and both slots populated to run this validation, but no
> offline/mock result substitutes for the physical cycle. Do not ship the board
> as hardware-validated until every acceptance item below passes.

### Commands (run on the physical Rock 5B+)

```bash
# 1. Before flashing, verify the exact target capacity and all image contracts:
TARGET=/dev/<confirmed-rock5b-media>
TARGET_SIZE_BYTES="$(sudo blockdev --getsize64 "${TARGET}")"
bash v2/tests/preflash-verify.sh --target-size-bytes "${TARGET_SIZE_BYTES}"

# 2. Flash the known-good A/B factory image using DEVICE-BRINGUP.md §4.
#    A legacy single-slot image requires this full re-flash; it cannot migrate OTA.

# 3. Confirm RAUC sees both slots and identifies A as booted:
rauc status
# -> should show slot.rootfs.0 (A) and slot.rootfs.1 (B), one marked booted
findmnt -no SOURCE,FSTYPE,OPTIONS /boot
# -> PARTLABEL=boot-backed device, vfat, rw (shared boot_state.txt)

# 4. Install a signed arm64 test bundle into the inactive slot:
rauc install /path/to/ceralive-rock-5b-plus-<version>.raucb
# -> should complete without error

# 5. Reboot and confirm the board switched to the new slot:
reboot
rauc status
# -> booted slot should now be the previously inactive one

# 6. Mark the booted test slot bad and confirm rollback:
rauc status mark-bad booted
reboot
# -> after reboot, board should have rolled back to the previous good slot
rauc status
# -> booted slot should be the original good slot

# 7. Run the consolidated real-HW suite to confirm the full gate:
BOARD=rock-5b-plus BOARD_IP=<ip> \
EVIDENCE_DIR=test-results/task-38-smoke \
./v2/tests/realhw-suite.sh
```

### Checklist

- [ ] Board flashed with a CeraLive image and boots to login.
- [ ] Preflash gate passed with the exact destination capacity.
- [ ] `rauc status` shows both A and B slots.
- [ ] `/boot` is the shared `PARTLABEL=boot` vfat mounted read-write.
- [ ] Both slots contain the factory baseline before the first OTA.
- [ ] RAUC bundle installed into inactive slot without error.
- [ ] Board rebooted into the new slot (slot-switch confirmed).
- [ ] Bad-slot simulation: `rauc status mark-bad booted` + reboot → rolled back.
- [ ] `v2/tests/realhw-suite.sh` (LIVE mode) exits 0.
- [ ] Evidence saved to `test-results/task-38-smoke/` and
      `test-results/rock5b-ab-rollback-<date>.txt`.

### Acceptance

`rauc status` shows a successful slot-switch and rollback on the physical board.
`v2/tests/realhw-suite.sh` exits 0 with evidence in `test-results/task-38-smoke/`.
No brick-loop observed across at least two full A/B cycles.

### Unblock condition

Complete a physical A/B OTA cycle on a Radxa Rock 5B+ — install a bundle, reboot
into the new slot, simulate a bad boot, confirm rollback to the good slot. Capture
`rauc status` output and the realhw-suite evidence to `test-results/`. Only after
this gate passes is it safe to treat A/B as hardware-confirmed on this board. Do
not change the manifest back to single-slot; that would make the required test
impossible and would not provide a migration path for existing disks.

---

## Item 5 — DEVICE-BRINGUP.md Evidence Placeholders

**DEFERRED.md ref:** §6  
**File to edit:** `docs/DEVICE-BRINGUP.md` (lines 296, 328, 413, 669)  
**Blocked on:** physical RK3588 board completing a first bring-up run

### Background

Four "**Pending hardware run**" placeholders in the public device bring-up guide
await evidence from a real board. Each placeholder names
`test-results/boot-log-<date>.txt` as its evidence target.

| Line | Placeholder topic |
|------|-------------------|
| 296 | Maskrom mode entry for Rock 5B+: button location + `rkdeveloptool ld` output |
| 328 | First-boot sequence: U-Boot → kernel → health gate → CeraUI timestamps |
| 413 | `dev-sync --frontend` invocation and timing |
| 669 | First-boot network troubleshooting: board not appearing on network |

### Commands (run during the first bring-up session)

```bash
# Capture serial output from the start of the session:
stty -F /dev/ttyUSB0 1500000 raw -echo
cat /dev/ttyUSB0 | tee test-results/boot-log-$(date +%Y%m%d).txt &

# Line 296 — maskrom mode:
# 1. Power off the board.
# 2. Hold the maskrom button (record exact button location from the board's hardware manual).
# 3. Apply power while holding the button; release after 2-3 s.
sudo rkdeveloptool ld
# -> record the exact output (device ID, USB path)

# Line 328 — first boot:
# Flash the image, power on, and capture the serial log.
# Record the timestamps for each first-boot service:
#   ceralive-hostname.service
#   ceralive-ssh-firstboot.service
#   ceralive-tls-firstboot.service
#   ceralive-provision.service (if no WiFi profile)
#   ceralive.service (CeraUI)
# Record the exact console output for each stage.

# Line 413 — dev-sync --frontend:
BOARD_IP=<ip> ./v2/dev-sync --frontend
# -> record the invocation, timing, and any output

# Line 669 — network troubleshooting:
# If the board does not appear on the network after first boot:
# 1. Check HDMI output for U-Boot and kernel messages.
# 2. Look for CeraLive-Setup-<short-id> hotspot (WiFi provisioning portal).
# 3. Record the exact console output and timing.
```

### Fill-in targets

After the bring-up session, replace each "**Pending hardware run**" note in
`docs/DEVICE-BRINGUP.md` with the observed procedure and output:

- **Line 296:** Replace with the exact maskrom button location, the
  `rkdeveloptool ld` output, and any board-specific quirks observed.
- **Line 328:** Replace with the actual boot-log timestamps and exact console
  output for each first-boot service.
- **Line 413:** Replace with the confirmed `dev-sync --frontend` invocation,
  timing, and output.
- **Line 669:** Replace with the observed network troubleshooting steps and
  timing for the specific failure mode.

### Checklist

- [ ] Serial capture running before power-on; output saved to
      `test-results/boot-log-<date>.txt`.
- [ ] Maskrom mode entered; `rkdeveloptool ld` output recorded (line 296).
- [ ] Image flashed successfully.
- [ ] First-boot sequence observed; timestamps and console output recorded (line 328).
- [ ] `dev-sync --frontend` invoked and timing confirmed (line 413).
- [ ] Network troubleshooting scenario observed (or confirmed not triggered) (line 669).
- [ ] All four "**Pending hardware run**" notes in `docs/DEVICE-BRINGUP.md`
      replaced with real observed output.
- [ ] Evidence saved to `test-results/boot-log-<date>.txt`.

### Acceptance

No "**Pending hardware run**" text remains in `docs/DEVICE-BRINGUP.md`. Each
replaced section contains the actual observed procedure, timestamps, and console
output from a real board run. The evidence file `test-results/boot-log-<date>.txt`
exists and is referenced from the updated sections.

### Unblock condition

Complete a physical bring-up run on a Radxa Rock 5B+ or Orange Pi 5+. Capture
boot logs to `test-results/boot-log-<date>.txt` (the reference each placeholder
already names). Replace each "**Pending hardware run**" note with the observed
procedure and output.

---

## Item 6 — ceralive-rk3588 Self-Hosted Runner Provisioning

**DEFERRED.md ref:** not a separate DEFERRED.md item — this is the CI
infrastructure gate that enables `realhw-job.yml` to run.  
**File:** `.github/workflows/realhw-job.yml` (already authored; needs a runner)  
**Blocked on:** a Linux host with a physical RK3588 board attached, registered
as a GitHub Actions self-hosted runner with label `ceralive-rk3588`

### Background

`realhw-job.yml` is the consolidated real-hardware acceptance gate. It runs
`v2/tests/realhw-suite.sh` (LIVE mode) on a physical RK3588 board via a
self-hosted runner labeled `ceralive-rk3588`. The workflow is fully authored and
activated (copied to `.github/workflows/` from `v2/ci/realhw-job.yml`). It
cannot run until the runner is provisioned and the board is attached.

The workflow requires these GitHub Actions runner variables on the
`ceralive-rk3588` runner (set via the repo's Settings → Actions → Variables):

| Variable | Purpose |
|----------|---------|
| `CERALIVE_RK3588_BOARD_IP` | IP address of the attached RK3588 board |
| `CERALIVE_RK3588_SSH_USER` | SSH user on the board (default: `ceralive`) |
| `CERALIVE_RK3588_SSH_PORT` | SSH port (default: `22`) |
| `CERALIVE_RK3588_BUNDLE_DIR` | Path to RAUC bundle directory on the runner |
| `CERALIVE_RK3588_LAST_GOOD_IMAGE` | Path to last-known-good `.raw` for maskrom recovery |
| `CERALIVE_RK3588_SERIAL_DEV` | Serial device for boot log capture (default: `/dev/ttyUSB0`) |
| `CERALIVE_RK3588_FLASH_IMAGE` | (Optional) Path to image to flash before each run |
| `CERALIVE_RK3588_DEV_DEB_DIR` | (Optional) Path to dev `.deb` dir for dev-loop step |
| `CERALIVE_RK3588_POWER_HELPER` | (Optional) Script to power-cycle board into maskrom |

### Provisioning steps

```bash
# 1. On the runner host: install the GitHub Actions runner agent
#    (follow https://docs.github.com/en/actions/hosting-your-own-runners)
#    Label the runner: ceralive-rk3588

# 2. Install required tools on the runner host:
sudo apt-get install -y rkdeveloptool openssh-client

# 3. Attach the RK3588 board via USB (for rkdeveloptool / maskrom recovery)
#    and via network (for SSH access during test runs).

# 4. Set the runner variables in GitHub repo Settings → Actions → Variables
#    (see table above).

# 5. Verify the runner is online:
#    GitHub repo → Settings → Actions → Runners
#    -> ceralive-rk3588 should show as "Idle"

# 6. Trigger a manual run to verify the workflow executes:
gh workflow run realhw-job.yml \
  --field board=rock-5b-plus \
  --field board_ip=<ip>

# 7. Check the run result:
gh run list --workflow=realhw-job.yml --limit 5
gh run view <run-id> --log
```

### Verifying realhw-job.yml runs end-to-end

The workflow runs these steps in order:

1. **Preflight** — SSH to the board; if unreachable, attempt maskrom recovery
   using `CERALIVE_RK3588_LAST_GOOD_IMAGE`.
2. **Serial capture** — starts `cat /dev/ttyUSB0` in the background if the
   device is present.
3. **Flash** (optional) — `ssh dd` the image-under-test to eMMC if
   `CERALIVE_RK3588_FLASH_IMAGE` is set.
4. **realhw-suite.sh** — the consolidated gate: boot+service smoke, encode-path
   init, dev-loop sanity (optional), RAUC A/B rollback.
5. **Diagnostics** — always runs; collects `rauc status` + `journalctl` from the
   board.
6. **Upload artifacts** — uploads `artifacts/` (serial log, suite log, evidence
   bundle) with 14-day retention.

### Checklist

- [ ] Runner host provisioned (Linux, `rkdeveloptool` + `openssh-client` installed).
- [ ] RK3588 board attached to runner host (USB for maskrom, network for SSH).
- [ ] GitHub Actions runner agent installed and labeled `ceralive-rk3588`.
- [ ] Runner shows as "Idle" in GitHub repo Settings → Actions → Runners.
- [ ] All required runner variables set (see table above).
- [ ] `gh workflow run realhw-job.yml` triggered manually.
- [ ] Workflow completes without error; `realhw-suite.sh` exits 0.
- [ ] Artifacts uploaded: `artifacts/realhw-suite.log`,
      `artifacts/task-38-smoke/`, `artifacts/board-diagnostics.log`.
- [ ] Nightly schedule (`0 2 * * *`) confirmed active in GitHub Actions.
- [ ] Evidence saved to `test-results/ceralive-rk3588-runner-<date>.txt`.

### Acceptance

`gh run list --workflow=realhw-job.yml` shows at least one successful run
(conclusion: `success`). The uploaded artifacts include `realhw-suite.log` with
a passing exit code and an evidence bundle under `artifacts/task-38-smoke/`.
The nightly schedule is active and the runner is labeled `ceralive-rk3588`.

### Unblock condition

Provision a Linux host with a physical RK3588 board attached. Register it as a
GitHub Actions self-hosted runner with label `ceralive-rk3588`. Set the required
runner variables. Trigger `realhw-job.yml` manually and confirm it runs
`v2/tests/realhw-suite.sh` end-to-end with a passing exit code and uploaded
artifacts.

---

## Cross-links

| Document | Scope |
|----------|-------|
| `v2/docs/DEFERRED.md` | Authoritative deferred-item index with file:line anchors |
| `v2/docs/cog-display-hw-checklist.md` | Full step-by-step Cog render QA runbook (Item 3) |
| `v2/docs/cog-display-addon.md` | Cog packaging recipe, libmali strategy, §7 hardware caveats |
| `docs/DEVICE-BRINGUP.md` | Public bring-up guide with hardware-evidence placeholders (Item 5) |
| `v2/manifests/boards/orange-pi-5-plus.yaml` | OPi 5+ board manifest with FIXME ID_PATHs (Item 1) |
| `.github/workflows/realhw-job.yml` | Real-HW CI workflow (Item 6) |
| `v2/ci/realhw-job.yml` | Canonical source for the real-HW workflow (keep in sync) |
| `v2/tests/realhw-suite.sh` | Consolidated real-HW acceptance suite |
| `cerastream/docs/notes/hardware-validation.md` | cerastream per-platform encoder validation matrix |

The cerastream hardware-gated encoder validation (RK3588 now; x86/N100 when in hand;
Jetson DEFERRED — not currently planned) is tracked separately in
`cerastream/docs/notes/hardware-validation.md`. That runbook is the authoritative
checklist for encoder validation; this document does not duplicate it. The
`ceralive-rk3588` runner (Item 6) is the shared infrastructure that enables both
the image-pipeline real-HW gate and the cerastream encoder validation on the same
physical board.

---

## Evidence capture summary

| Item | Evidence file |
|------|--------------|
| 1 — OPi 5+ ID_PATHs | `test-results/opi5plus-id-paths-<date>.txt` |
| 2 — Modem naming | `test-results/modem-naming-<date>.txt` |
| 3 — Cog render QA | `test-results/cog-render-<date>-*.{txt,png}` |
| 4 — Rock 5B+ A/B | `test-results/rock5b-ab-rollback-<date>.txt` + `test-results/task-38-smoke/` |
| 5 — DEVICE-BRINGUP | `test-results/boot-log-<date>.txt` |
| 6 — Runner provisioning | `test-results/ceralive-rk3588-runner-<date>.txt` |

All evidence files go to `test-results/` inside the `image-building-pipeline`
repo (Rule D — never a `../`-escaping path, never a root-repo path).
