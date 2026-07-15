# x86-minipc Bring-Up & Validation Runbook

> ## ⚠️ NOT YET VALIDATED ON HARDWARE — runbook only, zero validation claims made by this document.
>
> No command below has been run against a physical x86 mini-PC (Intel N100/N200 or
> equivalent). Every step is a **stepwise-complete procedure** for the person or agent
> who first gets an x86-minipc board in hand — it is not evidence of a passing run.
> Do not check a box, and do not edit this document to say "validated", "passed", or
> "confirmed", until the step has actually been executed on real silicon with
> captured evidence.

**Status:** `[GREENFIELD]` — preparation only, mirroring the honesty rule and
checklist style of [`hardware-gated-completion.md`](hardware-gated-completion.md).

**Scope:** the x86-minipc (`board_id: x86-minipc`, family `x86_64` — Intel N100/N200
and similar off-the-shelf UEFI mini-PCs) bring-up and validation path, end to end:
device discovery/reachability preflight → image build → flash → first boot →
`cerastream` encoder validation (`hw-smoke.sh n100`) → x86 `.raucb` OTA install and
rollback via RAUC's native GRUB backend. It is the x86 twin of
[`../../docs/DEVICE-BRINGUP.md`](../../docs/DEVICE-BRINGUP.md) (the RK3588/Rock 5B+ /
Orange Pi 5+ guide) and of [`hardware-gated-completion.md`](hardware-gated-completion.md)
Item 4 (the RK3588 A/B OTA hardware-validation runbook), adapted step-for-step for the
x86 UEFI/GRUB boot chain instead of RK3588's vendor U-Boot.

**Out of scope (deliberately not touched here):** the UVC H.265 camera capture gate
(`cerastream/docs/notes/hardware-validation.md` §3.4) is a separate, already-resolved
todo item — this runbook does not re-open it and makes no claim about it either way.
This document is *encoder* validation for the `n100` HAL profile only (§3.3).

---

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Device discovery / reachability preflight](#2-device-discovery--reachability-preflight)
3. [Building the x86-minipc image](#3-building-the-x86-minipc-image)
4. [Pre-flash verification](#4-pre-flash-verification)
5. [Flashing](#5-flashing)
6. [First boot](#6-first-boot)
7. [Post-boot reachability + service checks](#7-post-boot-reachability--service-checks)
8. [Encoder validation — `cerastream/tests/hw-smoke.sh n100`](#8-encoder-validation--cerastreamtestshw-smokesh-n100)
9. [x86 `.raucb` OTA install + rollback (RAUC native GRUB backend)](#9-x86-raucb-ota-install--rollback-rauc-native-grub-backend)
10. [Troubleshooting](#10-troubleshooting)
11. [Evidence capture summary](#11-evidence-capture-summary)
12. [Cross-links](#12-cross-links)

---

## 1. Prerequisites

### Host OS (build host)

Debian 12 (Bookworm) or Ubuntu 24.04 LTS recommended — same host requirement as the
RK3588 path in [`../../docs/DEVICE-BRINGUP.md` §1](../../docs/DEVICE-BRINGUP.md#1-prerequisites).

### Required packages

x86 needs no `u-boot-tools` (there is no U-Boot on this platform — UEFI/GRUB only),
but it does need the GRUB EFI toolchain that the RK3588 path does not:

```bash
# Debian / Ubuntu
sudo apt install \
  mkosi \
  mtools \
  dosfstools \
  gdisk \
  squashfs-tools \
  rauc \
  ffmpeg \
  python3 \
  rsync \
  git \
  cmake \
  build-essential \
  libssl-dev \
  grub-efi-amd64-bin \
  grub-common \
  ovmf
```

`grub-efi-amd64-bin` + `grub-common` provide `grub-mkstandalone` and `grub-editenv`,
used by `v2/mkosi/platform/x86/install-x86-grub.sh` to stage the EFI System Partition
(see [`v2/mkosi/platform/x86/README.md`](../mkosi/platform/x86/README.md) §2.0). `ovmf`
provides the UEFI firmware `qemu-system-x86_64` needs to boot the image headlessly for
the offline pre-flash proof in §4 — real hardware does not need `ovmf` (it has its own
UEFI firmware in SPI flash), but the build host does, to run `v2/tests/qemu-x86.sh`
before committing to a physical flash.

**mkosi version requirement:** mkosi 26 or later, exactly as for the RK3588 path —
see [`../../docs/DEVICE-BRINGUP.md` §1](../../docs/DEVICE-BRINGUP.md#1-prerequisites).

### APT feed

Same as RK3588: CeraLive packages are distributed via the public Debian APT feed at
`apt.ceralive.tv`. No authentication token is required. See
[`../../docs/DEVICE-BRINGUP.md` §1](../../docs/DEVICE-BRINGUP.md#1-prerequisites)
("APT feed").

### Clone the repository

```bash
git clone https://github.com/ceralive/image-building-pipeline.git
cd image-building-pipeline
```

---

## 2. Device discovery / reachability preflight

Unlike the RK3588 boards (which are entered into **maskrom mode** over USB for the
initial flash), an x86 mini-PC is flashed by writing the `.raw` image directly to its
internal NVMe/SATA SSD or booting it from a USB installer — there is no maskrom
equivalent. Do this BEFORE building, so the target disk and its exact capacity are
known ahead of the pre-flash gate in §4.

### 2.1 Identify the target board and its storage

```bash
# On the x86 mini-PC itself (booted from any live USB, e.g. a Debian/Ubuntu
# live image), or via IPMI/serial console if headless:
lsblk -o NAME,SIZE,TYPE,MODEL

# Confirm it is a UEFI-capable board (required — this image has no legacy-BIOS path):
ls /sys/firmware/efi 2>/dev/null && echo "UEFI: yes" || echo "UEFI: NO — this board cannot boot this image"
```

- [ ] Target disk device identified (e.g. `/dev/nvme0n1` or `/dev/sda`).
- [ ] Target disk capacity recorded (must be **≥ 32 GB** — the manifest assumes a
      real NVMe/SSD; see `v2/manifests/boards/x86-minipc.yaml` line 22-23).
- [ ] `/sys/firmware/efi` present — the board boots UEFI, not legacy BIOS.

### 2.2 Network reachability preflight (pre-flash, from the build host)

If the board already has a network path (e.g. it is reachable for a live-USB SSH
session before the CeraLive image is even flashed), confirm connectivity from the
build host now so a post-flash "board not appearing on the network" failure (§10)
can be triaged against a known-good baseline:

```bash
# From the build host, before flashing (replace with the board's live-USB/
# provisioning IP):
BOARD_PREFLASH_IP="live-usb-or-provisioning-ip"
ping -c 3 "${BOARD_PREFLASH_IP}"
```

- [ ] Build host can reach the board over the network pre-flash (or: the board has
      no network path yet and will rely on the WiFi provisioning portal post-flash —
      record which case applies).

### 2.3 Serial console (recommended, for headless capture)

The x86 family manifest pins `serial_console: ttyS0:115200` (generic PC 16550 UART —
see `v2/manifests/families/x86_64.yaml`). If the mini-PC exposes a serial header or a
USB-serial adapter is wired to it, capture the console from power-on for the first-boot
evidence in §6:

```bash
# From the build host, with the serial adapter attached:
stty -F /dev/ttyUSB0 115200 raw -echo
mkdir -p test-results
cat /dev/ttyUSB0 | tee "test-results/x86-boot-log-$(date +%Y%m%d).txt" &
```

- [ ] Serial console identified (or: board has no exposed serial header — HDMI/DP
      output plus the on-screen GRUB menu will be used instead; record which).

---

## 3. Building the x86-minipc image

```bash
# From the image-building-pipeline/ repo root:
./v2/build x86-minipc
```

The build entry point is the same orchestrator as RK3588
(`v2/build` → `v2/lib/orchestrate.sh`), routed by `family: x86_64` /
`rauc_bootloader_adapter: efi` in `v2/manifests/boards/x86-minipc.yaml` to the x86
disk assembler (`v2/lib/assemble-disk-x86.sh`) instead of the RK3588 one. See
`AGENTS.md` "x86 disk assembly — full A/B GRUB (Task 12)" for the exact Stage-4
branch.

**Dry run** (resolve and fetch plan only, no image written):

```bash
DRY_RUN=1 ./v2/build x86-minipc
```

**Multi-board build** (x86-minipc alongside an RK3588 board, if both are in scope
for a release candidate):

```bash
./v2/build --only rock-5b-plus,x86-minipc
```

### Artifacts

```text
v2/images/x86-minipc/
  <timestamp>.raw            # flashable disk image (GPT: ESP + rootfs_a + rootfs_b + data)
  <timestamp>.raucb          # signed RAUC OTA bundle, Compatible 'ceralive-x86-minipc'
  <timestamp>.raucb.sha256
```

Unlike RK3588 (which has a 16 MB raw idbloader/U-Boot/ATF gap before p1), the x86
`.raw` has **no leading gap** — p1 is the EFI System Partition directly. See
[`../../docs/partition-contract.md` §9](../../docs/partition-contract.md) ("x86-ab
ADDENDUM") for the full partition table.

---

## 4. Pre-flash verification

**Honest gap:** RK3588 has a dedicated hardware-free gate,
`v2/tests/preflash-verify.sh`, that asserts exact GPT geometry, both bootloader
stages, and RAUC bundle validity before a single byte is written to a board. **No
x86-specific equivalent of `preflash-verify.sh` exists yet** — its checks
(`board_env`, `fdtfile=rk3588-rock-5b-plus.dtb`, the RK idbloader/FIT gap) are
hardcoded to the RK3588 boot chain and do not generalize to x86's ESP/GRUB layout.
Do not assume `preflash-verify.sh` covers x86-minipc; it does not.

Until an x86-specific preflash gate exists, use the following as the available
offline pre-flash proof:

### 4.1 Bundle signature + compatible check

```bash
BOARD_DIR="v2/images/x86-minipc"
BUNDLE="${BOARD_DIR}/$(ls -t "${BOARD_DIR}"/*.raucb | head -1 | xargs basename)"

rauc info \
  -C keyring:check-purpose=codesign \
  --keyring=v2/.dev-keys/dev-root-ca.pem \
  "${BOARD_DIR}/${BUNDLE}"
```

Expected: parses cleanly and reports `Compatible: 'ceralive-x86-minipc'`. This is the
same dev-keyring check as [`../../docs/DEVICE-BRINGUP.md` §8](../../docs/DEVICE-BRINGUP.md#8-signing-bundles);
production builds sign with `CERALIVE_RAUC_PKI_DIR` instead.

### 4.2 Checksum verification

```bash
BOARD_DIR="v2/images/x86-minipc"
cd "${BOARD_DIR}" && sha256sum -c "$(ls -t *.raucb.sha256 | head -1)"
cd - >/dev/null
```

### 4.3 Headless qemu boot smoke (the closest available offline proof of a bootable image)

```bash
IMAGE_PATH="$(ls -t v2/images/x86-minipc/*.raw | head -1)" \
  bash v2/tests/qemu-x86.sh
```

This boots the actual built `.raw` under `qemu-system-x86_64` + OVMF, headless, and
asserts systemd reaches `multi-user.target`, `ceralive.service` is at least loaded,
and the first-party binaries (`cerastream`, `srtla_send`) are present. It is
**explicitly not a substitute for real hardware** (see the header comment in
`v2/tests/qemu-x86.sh`) — no VA-API/QSV device exists in qemu, so it cannot validate
the encoder path (that is §8). It is offline evidence that the image *boots at all*
before spending a physical flash cycle on it.

### Checklist

- [ ] `rauc info` on the bundle parses and reports `Compatible: 'ceralive-x86-minipc'`.
- [ ] `sha256sum -c` on the `.raucb.sha256` passes.
- [ ] `v2/tests/qemu-x86.sh` reaches `multi-user.target` with `ceralive.service`
      at least `loaded`.
- [ ] Evidence saved to `test-results/x86-preflash-<date>.txt`.

### Acceptance

All three checks above pass before proceeding to §5. A failure here means: fix the
build, do not flash.

---

## 5. Flashing

### Partition layout

```text
p1  boot (ESP)   256 MB  vfat (FAT32)  EFI/BOOT/BOOTX64.EFI + grub.cfg + grubenv
p2  rootfs_a     4096 MB ext4          rootfs slot A (active)
p3  rootfs_b     4096 MB ext4          rootfs slot B (rollback baseline)
p4  data         remainder ext4        persistent mutable state
```

Full contract: [`../../docs/partition-contract.md` §9](../../docs/partition-contract.md).

### Option A: dd to the internal NVMe/SSD (direct)

Boot the mini-PC from a live USB (any Debian/Ubuntu live image with UEFI boot), then
write the image directly to its internal disk. Identify the disk device from §2.1
first — **dd to the wrong device is destructive**.

```bash
TARGET=/dev/nvme0n1   # from §2.1 — double-check before running
BOARD_DIR="v2/images/x86-minipc"
IMAGE="${BOARD_DIR}/$(ls -t "${BOARD_DIR}"/*.raw | head -1 | xargs basename)"

sudo dd if="${IMAGE}" of="${TARGET}" bs=4M status=progress conv=fsync
sudo sync
```

Reboot the mini-PC (removing the live USB) and let UEFI boot from the internal disk.

### Option B: dd to a USB drive, then image-copy on the target

If the build host cannot physically reach the target disk (e.g. the mini-PC has no
free SATA/NVMe bay to attach to the build host directly), write the `.raw` to a USB
drive first and use `dd` on the target board's live-USB session instead:

```bash
USB_DEVICE=/dev/sdX   # the USB drive, NOT the mini-PC's internal disk
BOARD_DIR="v2/images/x86-minipc"
IMAGE="${BOARD_DIR}/$(ls -t "${BOARD_DIR}"/*.raw | head -1 | xargs basename)"

sudo dd if="${IMAGE}" of="${USB_DEVICE}" bs=4M status=progress conv=fsync
sudo sync
```

Then, booted from a *separate* live-USB session on the target mini-PC, `dd` from the
image-carrying USB drive to the internal disk (same command shape as Option A, with
`if=` pointed at the USB drive block device instead of a local file).

### Checklist

- [ ] Target disk device confirmed correct (§2.1) before running `dd`.
- [ ] Image written; `sync` completed with no I/O errors.
- [ ] Live-USB removed; board configured to boot from internal disk in UEFI
      firmware settings (if the live USB was prioritized).

---

## 6. First boot

Expected first-boot sequence — the software side is IDENTICAL to RK3588 (the
first-boot `systemd` unit chain does not know or care which bootloader booted it);
only the bootloader stage above it differs:

1. UEFI firmware loads `\EFI\BOOT\BOOTX64.EFI` (GRUB, the removable path
   `grub-mkstandalone` staged — no NVRAM boot-entry registration required).
2. GRUB reads `grubenv` from the ESP (`ORDER`, `<slot>_OK`, `<slot>_TRY`) and selects
   `rootfs_a` or `rootfs_b` per [`v2/mkosi/platform/x86/README.md`](../mkosi/platform/x86/README.md)
   §2.0's RAUC-native grub backend (`grub-ab.cfg` selector).
3. Kernel boots from the selected slot (`linux-image-amd64`, generic Debian kernel —
   no Armbian BSP, no device tree; hardware is enumerated via ACPI). Console output
   goes to `ttyS0,115200` (family manifest `serial_console`) and/or HDMI/DP.
4. The same one-shot first-boot services run as on RK3588 — see
   [`../../docs/DEVICE-BRINGUP.md` §5](../../docs/DEVICE-BRINGUP.md#5-first-boot)
   for the full service list and ordering
   (`ceralive-hostname.service` → `ceralive-ssh-firstboot.service` →
   `ceralive-tls-firstboot.service` → `ceralive-provision.service` if no WiFi
   profile → `ceralive.service` → `nginx.service` → `ceralive-healthcheck.service`).
   This runbook does not repeat that description; it is bootloader-agnostic.

### Verify the services are running (once the device is on the network)

```bash
ssh ceralive@ceralive.local 'systemctl status ceralive.service'
ssh ceralive@ceralive.local 'journalctl -u ceralive.service -n 50'
```

If another device already owns `ceralive.local`, use the fallback hostname shown on
the console (e.g. `ceralive2.local`), same as RK3588.

### Check the boot slot

```bash
ssh ceralive@ceralive.local 'rauc status'
```

`rauc status` output shape is identical to RK3588's — RAUC's CLI is board-agnostic;
only the backend implementing slot-switch (`bootloader=grub` here vs
`bootloader=custom` on RK3588) differs, invisibly to the operator.

### Checklist

- [ ] UEFI shows GRUB loading (or: HDMI/serial console captured, per §2.3).
- [ ] Kernel boots; console output reaches a login prompt or the device is reachable
      over SSH.
- [ ] `rauc status` over SSH shows both `rootfs.0` (A) and `rootfs.1` (B) slots, one
      marked `booted`.
- [ ] Evidence (boot log / console capture) saved to
      `test-results/x86-boot-log-<date>.txt`.

---

## 7. Post-boot reachability + service checks

Mirrors [`../../docs/DEVICE-BRINGUP.md` §5](../../docs/DEVICE-BRINGUP.md#5-first-boot)
"Verify the services are running" and the WiFi-provisioning-portal flow in
[`../../docs/FIRST-BOOT.md`](../../docs/FIRST-BOOT.md) — both are bootloader-agnostic
and apply unchanged to x86-minipc.

```bash
# Confirm HTTP (port 80, direct backend) and HTTPS (port 443, nginx TLS front)
# both answer:
curl -fsS "http://ceralive.local/status" || echo "port 80 NOT reachable"
curl -fsSk "https://ceralive.local/status" || echo "port 443 NOT reachable"
```

### Checklist

- [ ] `ceralive.local` (or the fallback hostname) resolves via mDNS.
- [ ] Port 80 (`http://<host>/status`) reachable.
- [ ] Port 443 (`https://<host>/status`) reachable (self-signed cert warning is
      expected — see [`AGENTS.md`](../../AGENTS.md) "CeraUI TLS front").
- [ ] Evidence saved to `test-results/x86-first-boot-<date>.txt`.

---

## 8. Encoder validation — `cerastream/tests/hw-smoke.sh n100`

This is the **authoritative** per-platform encoder validation step. This runbook
does not re-derive its checklist or the HAL property-mapping detail — the canonical
checklist lives in the sibling `cerastream` repo at
`cerastream/docs/notes/hardware-validation.md` §3.3
("N100 / Intel (`qsv*` or VA-API, NV12, kilobits/second) — REQUIRED"). This is a
plain path reference, not a relative hyperlink — `cerastream` is a separate git
checkout (Rule D: no path reference above this repo's root). Read it before
running this step; it documents the exact HAL claims (`qsvh265enc`/`qsvh264enc`
properties, the kbps vs bps distinction, and the VA-API fallback path if the board
only ships `vah26xenc`).

### Pre-flight (per hardware-validation.md §3, "all boards")

```bash
# On the booted x86-minipc device:
cerastream --version
bash /path/to/cerastream/crates/cerastream-transport/tests/check-gst-plugins.sh
```

### Run the smoke test

```bash
# On the booted x86-minipc device, from a cerastream checkout:
bash tests/hw-smoke.sh n100
```

Per the header contract in `cerastream/docs/notes/hardware-validation.md` §3: this
auto-detects the `qsvh265enc`/`qsvh264enc` (or `vah26xenc`) element, runs Phase A
(property mapping) and Phase B (real encode), and either PASSes (exit 0), or prints
the exact commands and exits 77 if the encoder element is missing (report-only,
not a hard failure of this runbook).

```bash
# H.264 codec path:
bash tests/hw-smoke.sh n100 --codec h264
```

### Checklist (verbatim cross-reference — do not re-derive; check off against
hardware-validation.md §3.3 directly)

- [ ] Pre-flight complete (`cerastream --version` runs natively;
      `check-gst-plugins.sh` reports required-all-OK).
- [ ] The platform's encoder element is installed
      (`qsvh265enc`/`qsvh264enc` from `gstreamer1.0-plugins-bad`, or `vah26xenc` if
      the board only ships VA-API — record which, per hardware-validation.md §3.3's
      "Element family" bullet).
- [ ] `tests/hw-smoke.sh n100` → PASS (exit 0); output saved to
      `test-results/hw-smoke/` inside the `cerastream` checkout (repo-local, per
      Rule D — never a `../`-escaping path from either repo).
- [ ] H.264 path (`tests/hw-smoke.sh n100 --codec h264`) also PASS.
- [ ] If a property mapping in `profiles.rs::N100` proves wrong on hardware, that is
      fixed in the `cerastream` repo (its HAL + golden fixtures), not here.
- [ ] `cerastream/docs/notes/hardware-validation.md` §1 results matrix and the
      `n100` row are updated **in the `cerastream` repo** once this passes — this
      runbook does not duplicate or own that matrix.

### Acceptance

Per `hardware-validation.md` §5 ("Sign-off"): the `n100` row in that doc's §1 matrix
flips from **HW-GATED** to **VALIDATED** only when every REQUIRED item above is
checked on the real board with evidence captured to `cerastream`'s own
`test-results/`. This runbook's role ends at "ran the command and captured
evidence" — the sign-off itself is recorded in `cerastream`, not here.

---

## 9. x86 `.raucb` OTA install + rollback (RAUC native GRUB backend)

Mirrors [`hardware-gated-completion.md` Item 4](hardware-gated-completion.md#item-4--rock-5b-a-b-hardware-validation)
(the RK3588 A/B OTA hardware-validation runbook), adapted for the x86 GRUB boot
adapter. The RAUC **CLI** commands below are byte-identical to the RK3588 version —
only the underlying bootloader backend (`bootloader=grub` here vs
`bootloader=custom` on RK3588) differs, and that difference is invisible at the
`rauc` CLI. See
[`v2/mkosi/platform/x86/x86-rauc-boot-adapter.sh`](../mkosi/platform/x86/x86-rauc-boot-adapter.sh)
and
[`v2/mkosi/platform/x86/x86-boot-state.sh`](../mkosi/platform/x86/x86-boot-state.sh)
for the **retained offline-harness** implementation (§2.1 of that README) — those
scripts are NOT what runs on the shipped image; the shipped image uses RAUC's
built-in `bootloader=grub` backend (§2.0 of that README). Read
[`v2/mkosi/platform/x86/README.md`](../mkosi/platform/x86/README.md) before running
this section so the grubenv model (`ORDER`/`<slot>_OK`/`<slot>_TRY`) is understood.

> **SAFETY GATE — DO NOT CLAIM PRODUCTION HARDWARE VALIDATION YET.**
>
> No offline/mock/qemu result substitutes for a physical A/B install-reboot-rollback
> cycle. Do not ship x86-minipc as hardware-validated until every acceptance item
> below passes on real silicon.

### 9.1 Offline proof already available (run this first, no hardware required)

Before touching real hardware, confirm the offline proof still passes — it is the
same test the CI gate runs on every commit:

```bash
bash v2/run-tests
# or, to run only the x86 signed-bundle acceptance gate:
bats v2/tests/x86-raucb-bundle.bats
```

`v2/tests/x86-raucb-bundle.bats` asserts (see its header comment): (1) the
`efi`/`grub` Stage-4 branch of `orchestrate.sh` actually invokes the signed-bundle
producer; (2) a REAL `build-bundle.sh x86-minipc <rootfs>` run produces a `.raucb`
whose CMS chain verifies leaf → intermediate → root against the dev keyring; (3) a
one-byte tamper of the bundle payload makes verification FAIL; (4) the embedded
`manifest.raucm` carries `compatible=ceralive-x86-minipc` (not a leaked RK3588
string). This is real evidence of a well-formed signed bundle — it is **not**
evidence of a real install/reboot/rollback cycle on hardware, which is §9.2 below.

### 9.2 Commands (run on the physical x86-minipc)

```bash
# 1. Confirm RAUC sees both slots and identifies one as booted:
ssh ceralive@ceralive.local 'rauc status'
# -> should show slot.rootfs.0 (A) and slot.rootfs.1 (B), one marked booted

# 2. Confirm the ESP mount and grubenv are in place:
ssh ceralive@ceralive.local 'findmnt -no SOURCE,FSTYPE,OPTIONS /boot/efi'
# -> PARTLABEL=boot-backed device, vfat, rw

# 3. Copy a signed test bundle onto the device and install it into the
#    inactive slot:
BOARD_DIR="v2/images/x86-minipc"
BUNDLE="${BOARD_DIR}/$(ls -t "${BOARD_DIR}"/*.raucb | head -1 | xargs basename)"
scp "${BUNDLE}" ceralive@ceralive.local:/tmp/
ssh ceralive@ceralive.local "rauc install /tmp/$(basename "${BUNDLE}")"
# -> should complete without error

# 4. Reboot and confirm the board switched to the new slot:
ssh ceralive@ceralive.local 'reboot'
sleep 30
ssh ceralive@ceralive.local 'rauc status'
# -> booted slot should now be the previously inactive one

# 5. Mark the booted test slot bad and confirm rollback:
ssh ceralive@ceralive.local 'rauc status mark-bad booted'
ssh ceralive@ceralive.local 'reboot'
sleep 30
ssh ceralive@ceralive.local 'rauc status'
# -> booted slot should be the original good slot

# 6. Run the consolidated real-HW suite (board-parameterized; the suite's smoke
#    quirks are RK3588-flavored by default, so treat x86 results as informational
#    until the suite is confirmed x86-clean):
BOARD=x86-minipc BOARD_IP=<ip> \
EVIDENCE_DIR=test-results/x86-minipc-smoke \
bash v2/tests/realhw-suite.sh
```

### 9.3 grubenv inspection (x86-specific — no U-Boot equivalent)

Unlike RK3588's hand-rolled `boot_state.txt`, x86's boot-selection state is a real
`grub-editenv`-compatible block. To inspect it directly (useful when triaging a
rollback that did not behave as expected):

```bash
ssh ceralive@ceralive.local 'grub-editenv /boot/efi/EFI/BOOT/grubenv list'
# -> ORDER=A B  A_OK=1  A_TRY=0  B_OK=1  B_TRY=0  (or similar)
```

### Checklist

- [ ] `v2/tests/x86-raucb-bundle.bats` passes (offline, §9.1 — run this first).
- [ ] Board flashed with a CeraLive x86-minipc image and boots to login.
- [ ] `rauc status` shows both A and B slots.
- [ ] `/boot/efi` is the ESP, vfat, mounted read-write.
- [ ] Both slots contain the factory baseline before the first OTA.
- [ ] RAUC bundle installed into the inactive slot without error.
- [ ] Board rebooted into the new slot (slot-switch confirmed via `rauc status`).
- [ ] Bad-slot simulation: `rauc status mark-bad booted` + reboot → rolled back.
- [ ] `grubenv` inspection (§9.3) matches the expected `ORDER`/`_OK`/`_TRY` state at
      each step.
- [ ] `v2/tests/realhw-suite.sh` (LIVE mode, `BOARD=x86-minipc`) exits 0 — note any
      RK3588-specific quirk assertions that do not apply to x86 and record them as
      informational, not a hard fail, until the suite is x86-audited.
- [ ] Evidence saved to `test-results/x86-minipc-smoke/` and
      `test-results/x86-ab-rollback-<date>.txt`.

### Acceptance

`rauc status` shows a successful slot-switch and rollback on the physical board,
mirroring [`hardware-gated-completion.md` Item 4's Acceptance criterion](hardware-gated-completion.md#item-4--rock-5b-a-b-hardware-validation).
No brick-loop observed across at least two full A/B cycles.

### Unblock condition

Complete a physical A/B OTA cycle on an x86-minipc — install a bundle, reboot into
the new slot, simulate a bad boot, confirm rollback to the good slot. Capture
`rauc status` + `grubenv` output and the realhw-suite evidence to `test-results/`.
Only after this gate passes is it safe to treat x86 A/B as hardware-confirmed.

---

## 10. Troubleshooting

### Board does not appear in UEFI boot menu / does not boot the image

Confirm the board is genuinely UEFI-capable (§2.1) and that the BIOS/UEFI setup has
**not** disabled the removable-media boot path (`\EFI\BOOT\BOOTX64.EFI` is the
GRUB "removable path" — some UEFI firmwares require Secure Boot to be disabled to
load an unsigned `shim`-less GRUB binary; this image ships a plain unsigned
`grub-mkstandalone` binary, per
[`v2/mkosi/platform/x86/README.md`](../mkosi/platform/x86/README.md) §2.0).

```bash
# Confirm Secure Boot state from a live USB session on the target board:
mokutil --sb-state 2>/dev/null || echo "mokutil not available — check UEFI setup menu"
```

If Secure Boot is enabled, disable it in the UEFI setup menu — this image's GRUB
binary is not signed for Secure Boot.

### `rauc install` fails with a keyring/compatible mismatch

Confirm the bundle's `Compatible` string matches what the device's
`/etc/rauc/system.conf` expects:

```bash
ssh ceralive@ceralive.local 'cat /etc/rauc/system.conf | grep -A2 "\[system\]"'
BUNDLE_TO_CHECK="v2/images/x86-minipc/<ts>.raucb"   # replace with the actual bundle path
rauc info -C keyring:check-purpose=codesign --keyring=v2/.dev-keys/dev-root-ca.pem "${BUNDLE_TO_CHECK}"
```

Both should read `ceralive-x86-minipc`. See
[`../../docs/DEVICE-BRINGUP.md` §9](../../docs/DEVICE-BRINGUP.md#9-troubleshooting)
("`rauc info` fails with unsuitable certificate purpose") for the same
`-C keyring:check-purpose=codesign` flag requirement — identical on x86.

### Encoder element (`qsvh265enc`/`qsvh264enc`) not found

```bash
gst-inspect-1.0 qsvh265enc 2>&1 | head -5
gst-inspect-1.0 vah265enc  2>&1 | head -5   # VA-API fallback family
```

If neither is present, `gstreamer1.0-plugins-bad` and/or
`intel-media-va-driver-non-free` are missing from the running image — cross-check
`v2/manifests/families/x86_64.yaml` (`hw_accel_gstreamer_plugins`) against what is
actually installed. This is a build/manifest bug, not a hardware limitation, if the
board's Intel Gen12 graphics are genuinely present (`lspci | grep -i vga`).

### First boot: board does not appear on the network

Same triage as RK3588 — see
[`../../docs/DEVICE-BRINGUP.md` §9](../../docs/DEVICE-BRINGUP.md#9-troubleshooting)
("First boot: board does not appear on the network"). Look for the
`CeraLive-Setup-<short-id>` WiFi provisioning hotspot; the portal logic is
bootloader-agnostic and applies unchanged to x86.

---

## 11. Evidence capture summary

| Section | Evidence file |
|---------|--------------|
| §2 — Device discovery / reachability | `test-results/x86-preflight-<date>.txt` |
| §4 — Pre-flash verification | `test-results/x86-preflash-<date>.txt` |
| §6 — First boot | `test-results/x86-boot-log-<date>.txt` |
| §7 — Post-boot reachability | `test-results/x86-first-boot-<date>.txt` |
| §8 — Encoder validation | `cerastream`'s own `test-results/hw-smoke/` (see hardware-validation.md §5) |
| §9 — OTA install + rollback | `test-results/x86-minipc-smoke/` + `test-results/x86-ab-rollback-<date>.txt` |

All evidence files inside this repo go to `test-results/` (Rule D — never a
`../`-escaping path, never a root-repo path), exactly like
[`hardware-gated-completion.md`'s evidence table](hardware-gated-completion.md#evidence-capture-summary).

---

## 12. Cross-links

| Document | Scope |
|----------|-------|
| [`../../docs/DEVICE-BRINGUP.md`](../../docs/DEVICE-BRINGUP.md) | RK3588 (Rock 5B+ / Orange Pi 5+) bring-up guide — this document's structural twin |
| [`hardware-gated-completion.md`](hardware-gated-completion.md) | RK3588 hardware-gated completion checklist — Item 4 is this document's OTA-section twin |
| [`../../docs/partition-contract.md`](../../docs/partition-contract.md) | Frozen GPT layout; §9 is the x86-ab addendum |
| [`../../docs/FIRST-BOOT.md`](../../docs/FIRST-BOOT.md) | Operator-facing first-boot guide (WiFi portal, first login) — bootloader-agnostic |
| [`v2/mkosi/platform/x86/README.md`](../mkosi/platform/x86/README.md) | x86 encode strategy (D1) + full A/B GRUB bootloader design |
| [`v2/manifests/boards/x86-minipc.yaml`](../manifests/boards/x86-minipc.yaml) | x86-minipc board manifest |
| [`v2/manifests/families/x86_64.yaml`](../manifests/families/x86_64.yaml) | x86_64 family manifest (encode packages, bootloader adapter, partition template) |
| [`v2/tests/x86-raucb-bundle.bats`](../tests/x86-raucb-bundle.bats) | Offline signed-bundle acceptance gate for the x86 OTA path |
| [`v2/tests/qemu-x86.sh`](../tests/qemu-x86.sh) | Headless qemu boot smoke (offline proxy for "does it boot") |
| [`v2/docs/DEFERRED.md`](DEFERRED.md) | Deferred-item index (RK3588-focused; x86 items tracked inline where applicable) |
| `cerastream/docs/notes/hardware-validation.md` (sibling repo, path reference only — not a hyperlink, Rule D) | §3.3 (N100/Intel) is the authoritative encoder-validation checklist this runbook's §8 defers to |

The `n100` encoder validation (§8) is owned and tracked in `cerastream`, exactly as
`hardware-gated-completion.md` defers RK3588's encoder validation to the same
document's §3.2. This runbook does not duplicate that checklist or its property-
mapping detail — it only tells you which command to run and where the authoritative
sign-off criteria live.
