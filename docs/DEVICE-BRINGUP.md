# CeraLive Device Bring-Up Guide

Public developer guide for building, flashing, and iterating on CeraLive devices
(Radxa Rock 5B+, Orange Pi 5+). No private repository access required.

> **Status:** Alpha. The build system is functional. Software-side first-boot
> services (SSH hardening, WiFi provisioning portal, TLS cert generation) are
> implemented and offline-verified. Sections marked **pending hardware run**
> require evidence from a physical board and will be filled when hardware is
> available.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Building the image](#2-building-the-image)
3. [Pre-flash verification](#3-pre-flash-verification)
4. [Flashing](#4-flashing)
5. [First boot](#5-first-boot)
6. [Dev loop](#6-dev-loop)
7. [Tier-1 E2E smoke test](#7-tier-1-e2e-smoke-test)
8. [Signing bundles](#8-signing-bundles)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Prerequisites

**The container build is canonical.** `./build <board>` builds inside a
pinned `debian:trixie-slim` container (`ci/Dockerfile`, mkosi 26) via Docker
or Podman. Everything below the "Required packages" heading is needed only if
you opt into `--native` / `MKOSI_NATIVE=1` on a Debian trixie+ host — a plain
container build needs nothing from your host beyond a working Docker or Podman
install. See [`docs/host-support.md`](../docs/host-support.md) for the
full per-distro matrix (Ubuntu/Debian, Arch, Fedora, macOS Apple Silicon,
WSL2).

**Verified on the machine that wrote this doc** (2026-08-08, Arch Linux host,
container build path):

```console
$ mkosi --version
mkosi 26
$ python3 --version
Python 3.14.6
$ docker --version
Docker version 29.7.2, build a7dcaa6fdb
$ podman --version
podman version 6.0.2
$ which ccache
/usr/bin/ccache
$ df -h .
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  1.3T  984G  214G  83% /mnt/development
```

Both Docker and Podman are usable container runtimes for the canonical build.
`ccache` is not a hard requirement for the container path (the builder image
carries its own persistent ccache volume across runs, see the CI/build cache
notes in the root `AGENTS.md`), but installing it locally speeds up a
`--native` kernel-from-source build materially — and EVERY build is one now, so
this matters on the default path rather than only on an opt-in variant. A full
kernel `make bindeb-pkg` is the single most compile-heavy stage in this
pipeline.

**Disk.** The protected CI production-candidate job requires at least 24 GiB
free on both the workspace and Docker-root filesystems (checked by
`ci/check-builder-resources.sh` before any BuildKit work starts). A local
dev box does not enforce that check, but budget similarly: the mkosi build
cache (`mkosi/cache/<board>`, capped at 2 GiB in CI), the `.staging/<board>`
tree holding fetched `.deb`s, and each board's output `.raw` (nominal 14,800
MiB, sparse — see §2 "Artifacts" below) all live under `image-building-pipeline/`
during a real build.

### Required packages

```bash
# Debian / Ubuntu
sudo apt install \
  mkosi \
  u-boot-tools \
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
  libssl-dev

# Arch
sudo pacman -S \
  mkosi \
  uboot-tools \
  mtools \
  dosfstools \
  gptfdisk \
  squashfs-tools \
  rauc \
  ffmpeg \
  python \
  rsync \
  git \
  cmake \
  base-devel \
  openssl
```

**mkosi version requirement:** mkosi 26 or later. Check with `mkosi --version`.
Earlier versions have incompatible syntax. Install from source if your distro
ships an older version:

```bash
pip install --user git+https://github.com/systemd/mkosi.git@v26
```

### CeraLive libsrt (required for the E2E smoke test)

The system `libsrt` package lacks the `SRTO_SRTLAPATCHES` socket option that
CeraLive's bonding layer requires. Build the pinned CERALIVE fork instead:

```bash
# Clone the CeraLive fork at the device runtime release
git clone --branch srt-v1.5.5+ceralive.1 https://github.com/CERALIVE/srt.git ceralive-srt
cd ceralive-srt

# Build with cmake directly (the ./configure script requires tclsh; cmake does not)
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_APPS=OFF
cmake --build build -j"$(nproc)"
sudo cmake --install build
```

After installing, make the loader find `/usr/local/lib` first:

```bash
echo /usr/local/lib | sudo tee /etc/ld.so.conf.d/usr-local-lib.conf
sudo ldconfig
```

Verify the right library is active:

```bash
ldconfig -p | grep libsrt
# Should show /usr/local/lib/libsrt.so.1.5 BEFORE any /usr/lib entry
```

### irl-srt-server (required for Tier-B video in the E2E smoke test)

```bash
git clone https://github.com/irlserver/irl-srt-server.git
cd irl-srt-server
git submodule update --init
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
# Binary: build/bin/srt_server
```

The smoke harness auto-detects this binary at `../irl-srt-server/build/bin/srt_server`
relative to the workspace root.

### srtla (required for the E2E smoke test)

```bash
git clone https://github.com/irlserver/srtla.git
cd srtla
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
# Binary: build/srtla_rec
```

The smoke harness looks for `srtla_rec` at `../srtla/build/srtla_rec`.

### APT feed

CeraLive packages are distributed via the public Debian APT feed at
`apt.ceralive.tv`. No authentication token is required to install packages
from this feed. The build system fetches `.deb` packages automatically during
the build step.

---

## 2. Building the image

### Clone the repository

```bash
git clone https://github.com/ceralive/image-building-pipeline.git
cd image-building-pipeline
```

### Run the build

```bash
# Rock 5B+ (primary target)
./build rock-5b-plus

# Orange Pi 5+
./build orange-pi-5-plus
```

The build entry point is `build`, which calls `lib/orchestrate.sh`. It
runs through nine stages: resolve manifest, fetch `.deb` packages, validate,
run mkosi, assemble disk, write bootloader gap, and emit a signed `.raucb`
bundle.

**Dry run** (resolve and fetch plan only, no image written):

```bash
INSTALL_BOOT_BSP=0 DRY_RUN=1 ./build rock-5b-plus
```

### Artifacts

After a successful build, artifacts land in `images/<board>/`:

```text
images/rock-5b-plus/
  20260609T075534Z.raw      # flashable disk image (sparse, 14,800 MiB nominal)
  20260609T075534Z.raw.sha256
  20260609T075534Z.raw.xz   # verified compressed transport for the same raw bytes
  20260609T075534Z.raw.xz.sha256
  20260609T075534Z.raucb    # signed RAUC OTA bundle
  20260609T075534Z.raucb.sha256
```

The `.raw` is a sparse file. Actual on-disk size is much smaller than the
nominal 14,800 MiB. Use `du -sh` to see the allocated host-file size. Every local
full build also seals that exact raw through the same multithreaded `xz -T0 -6`
path as releases, verifies the decompressed SHA-256 round trip, and writes the
artifact-specific `.raw.sha256` and `.raw.xz.sha256` sidecars. The raw remains for
direct flashing; the `.raucb` path is unaffected. A sealed release candidate runs
the same sealing only after its uncompressed preflash gate and places its raw digest
at `raw.sha256` in the candidate directory.

### Custom APT mirror

If you're running a local mirror or a fork of the package feed, set:

```bash
export CERALIVE_APT_MIRROR="https://<your-apt-mirror>/debian"
./build rock-5b-plus
```

Replace `<your-apt-mirror>` with your mirror hostname.

### Opt-in kernel-build-from-source variants

The `rk3588` family manifest declares two variants, and BOTH compile the kernel
and in-tree DTBs from pinned source — there is no prebuilt-kernel path left:

```bash
./build rock-5b-plus                            # the PRODUCTION default (= edge)
./build rock-5b-plus --variant edge             # the same thing, named explicitly
./build rock-5b-plus --variant edge-test        # debug sibling; NEVER released
```

`edge` is the production track (`default_variant: edge`) and is compile-and-boot
proven on real hardware for both `rock-5b-plus` and `orange-pi-5-plus` at the
v7.1.7 base; the current `v7.2` pin is compile-proven with partial board
evidence. `edge-test` is a KASAN/lockdep + fault-injection build that
`ci/check-release-variant.sh` refuses to release by property.

The Armbian vendor 6.1 BSP track — both the prebuilt overlay and the source-built
one that carried the HDMI-RX audio fix — is RETIRED, and is preserved at the
annotated tag `vendor-kernel-final`. Full detail, including the honest MPP
hardware-encode and v7.2 qualification boundaries:
[`docs/kernel-build-from-source.md`](../docs/kernel-build-from-source.md).

### Production vs debug image variants (`CERALIVE_DEBUG_IMAGE`)

```bash
./build rock-5b-plus                                    # PRODUCTION (default)

CERALIVE_DEBUG_IMAGE=1 \
CERALIVE_DEBUG_PASSWORD_HASH='<crypt(3) hash>' \
  ./build rock-5b-plus                                  # DEBUG (bench only)
```

Production ships `shared.list` + the resolved `<family>.delta.list` only,
`ssh.service` not enabled, and a password-locked `ceralive` account. Debug
adds `manifests/packages/development.delta.list` (18 diagnostic packages),
enables `ssh.service` by default, and unlocks `ceralive` with the supplied
password hash. **The debug image is bench-only and is never published to apt
or R2** — no release/publish path ever sets this flag. Full contract, including
why the flag must be resolved before package-set resolution and the
directory-glob trap this variant had to be shielded from: root
[`AGENTS.md`](../AGENTS.md) → "The debug package delta is VARIANT-keyed" KEY
FACT.

### Image size gate

Every real (non-`DRY_RUN`) build runs `lib/measure-size.sh` between the
rootfs-tar emit and the parity check. A rootfs whose apparent content exceeds
**1.5 GB** fails the build there — no `.raw`, no `.raucb`. Both shipped RK3588
boards currently sit under the ceiling (`rock-5b-plus` 1,412,259,840 B,
`orange-pi-5-plus` 1,418,792,960 B, measured on real production builds). The
gate is invisible to the `DRY_RUN=1` PR-gate path — it only runs on a real
build — so any doc claim about it is worth re-verifying against a real build,
not a dry run. See [`docs/size-notes.md`](../docs/size-notes.md) §10 for
the exact wiring and the levers that keep both boards under the line (locale
strip, firmware audit, the Mesa software-GL prune).

### Kernel freeze contract

The kernel, DTB, U-Boot, and firmware packages in every image are frozen
against on-device `apt`: `apt-mark hold` (primary — also blocks an explicit
`apt-get install <pkg>`) plus a supplementary name+version apt-preferences pin.
RAUC does not consult either — it writes the whole inactive slot directly, and
each new slot bakes its own holds. First-party CeraLive packages
(`cerastream`, `ceralive-device`, `srtla-send-rs`, the forked `libsrt`, the
ModemManager closure) are deliberately excluded from the freeze so
`system.startUpdate()` keeps working. Verify on a booted device with
`apt-mark showhold`, `apt-cache policy linux-image-7.2.0-ceralive-rk3588`, and
`apt-get -s upgrade`. Full contract: [`docs/kernel-freeze-contract.md`](../docs/kernel-freeze-contract.md).

---

## 3. Pre-flash verification

Before flashing, identify the destination block device and run the offline gate.
Reading its size is non-destructive. The gate checks exact A/B geometry and GPT
integrity, idblock plus parsed second-stage FIT, the compiled selector and board
metadata, boot state, kernel/DTB/initrd in both factory slots, exact media capacity,
and the RAUC bundle signature/compatible contract.

```bash
TARGET=/dev/sdX
TARGET_SIZE_BYTES="$(sudo blockdev --getsize64 "${TARGET}")"
bash tests/preflash-verify.sh --target-size-bytes "${TARGET_SIZE_BYTES}"
```

Expected output (all nine checks green):

```text
==============================================================
 CeraLive pre-flash verification gate — board rock-5b-plus
 image:   images/rock-5b-plus/<ts>.raw
 bundle:  images/rock-5b-plus/<ts>.raucb
 keyring: .dev-keys/dev-root-ca.pem
==============================================================
[PASS] GPT geometry: exact A/B starts/sizes and unique labels
[PASS] Gap magic: RKNS (52 4b 4e 53) at sector 64
[PASS] Bootloader second-stage FIT: valid FDT header and extent at sector 16384
[PASS] Boot partition: compiled AArch64 selector + Rock board metadata + recovery files
[PASS] Boot state: BOOT_ORDER=A B with positive A/B attempts
[PASS] rootfs_a populated + kernel + board DTB + initrd + shared /boot mount
[PASS] rootfs_b populated + kernel + board DTB + initrd + shared /boot mount
[PASS] Target media capacity: <target-bytes> bytes >= image <image-bytes> bytes
[PASS] RAUC bundle: parses + Compatible 'ceralive-rock-5b-plus'
--------------------------------------------------------------
RESULT: PASS — pre-flash gate GREEN. Hardware bring-up AUTHORIZED.
==============================================================
```

Do not flash if any check shows `[FAIL]`. Fix the build first.

The `rootfs_a`/`rootfs_b` checks resolve the real Armbian kernel-package `/boot`
layout: `/boot/Image` is a symlink to the versioned `vmlinuz-<ver>` and the
initrd exists only as `/boot/initrd.img-<ver>` (no bare `/boot/initrd.img`). The
gate dereferences the kernel symlink and falls back to the versioned initrd name,
so a genuinely complete Armbian slot passes; plain-file `/boot/Image` and
`/boot/initrd.img` layouts still pass unchanged.

You can also run the built-in negative self-test to confirm the gate is
non-vacuous:

```bash
bash tests/preflash-verify.sh --self-test \
  --target-size-bytes "${TARGET_SIZE_BYTES}"
```

---

## 4. Flashing

**Three flash paths exist; this section is the index, not the duplicate.**
Full step-by-step detail for each lives at the location cited — do not copy
that detail here on a future edit, link it:

| Path | Where | Destructive? | Verified-via |
|---|---|---|---|
| microSD `dd` (Option A below) | §4 "Option A" in this doc | Yes — writes the target block device | `verified-via: .omo/notepads/device-platform-wave4/*` + `docs/kernel-currency-watch.md` real-board history; NOT re-executed for this doc pass (see command-classification note below) |
| `rkdeveloptool` maskrom → eMMC, CI-verified path | §4 "Option B" in this doc; tool source `ci/verify-and-flash-candidate.sh` | Yes | `verified-via: .omo/evidence/device-platform-wave4/task-27-orangepi5plus-build.md`, `task-27-sd-boot-validation.md`, `task-31-measurement.md` — real board flash+boot transcripts from todos 27/31; NOT re-executed here |
| `rkdeveloptool` manual bench 3-command path (`db`/`wl`/`rd`) | §4 "Manual bench flashing" in this doc | Yes | same citations as above — validated on real Rock 5B+ hardware in prior sessions, not re-run for this doc pass |

**Command classification for this doc pass.** Per this task's constraints, no
`dd`, `rkdeveloptool wl`, or `rkdeveloptool rd` was executed while writing this
section — those are destructive and are cited via the transcripts above
instead. The one **non-destructive** preflight step was actually run, on the
machine writing this doc, to confirm the detection command itself still
behaves as documented (no board attached, so it correctly reports none found):

```console
$ which rkdeveloptool
/usr/bin/rkdeveloptool
$ rkdeveloptool ld
not found any devices!
$ echo "exit=$?"
exit=1
```

This is the same `rkdeveloptool ld` device-detection command all three flash
paths use before proceeding — a non-zero exit / "not found any devices!" means
no board is currently in Maskrom mode, which is expected when nothing is
attached. Do not read a clean `ld` failure as a tooling problem; it means "no
device present," not "device present but broken."

### Partition layout

The image uses a GPT layout with a 16 MB reserved gap at the start for the
RK3588 bootloader blobs (idbloader + U-Boot + ATF). The gap is written by the
build system; you do not need to write it separately.

```text
[16 MB raw gap]  idbloader + U-Boot + ATF (no GPT entry)
p1  boot         256 MB  vfat   automatic selector + manual recovery script + state
p2  rootfs_a     4096 MB ext4   rootfs slot A (active)
p3  rootfs_b     4096 MB ext4   rootfs slot B (factory rollback baseline)
p4  data         remainder ext4  persistent mutable state
```

An older single-slot image cannot be upgraded to this layout with a `.raucb`:
its `data` partition occupies the future `rootfs_b` extent. Back up required state
and perform a full re-flash; do not attempt in-place repartitioning.

### Option A: dd to microSD card

Identify your SD card device first (`lsblk`, `dmesg`). Replace `/dev/sdX`
with the correct device. **Double-check before running** — dd to the wrong
device is destructive.

```bash
BOARD_DIR="images/rock-5b-plus"
IMAGE="${BOARD_DIR}/$(ls -t "${BOARD_DIR}"/*.raw | head -1 | xargs basename)"

sudo dd if="${IMAGE}" of=/dev/sdX bs=4M status=progress conv=fsync
sudo sync
```

For a downloaded release candidate, verify and decompress it before `dd`:

```bash
sha256sum -c <timestamp>.raw.xz.sha256
xz -dk <timestamp>.raw.xz
sudo dd if=<timestamp>.raw of=/dev/sdX bs=4M status=progress conv=fsync
sudo sync
```

Eject the card and insert it into the board. **Do not assume this is enough,
verify it.** A previous version of this doc claimed the Rock 5B+ boots microSD
before eMMC by default, citing Radxa forum guidance for the Rock 5B and the
shared `rk3588-rock-5b-u-boot.dtsi` SPL boot order. That claim has not held up
under direct testing. On a real Rock 5B+ with a byte-verified bootable card
inserted, a warm `sudo reboot` (no power cycle) came back up still running the
eMMC OS: `uname -a` showed the old kernel and `/` was mounted from
`mmcblk0p2`, not the card's `mmcblk1`. This board's own `boot.scr.cmd` (in this
repo, `mkosi/platform/boot/boot.scr.cmd`) has no cross-device chain-load
logic of its own. It only acts on `${devtype}`/`${devnum}`, values U-Boot's
generic `distro_bootcmd` framework resolves before this script ever runs. So
the SD-vs-eMMC decision happens entirely inside this board's shipped U-Boot
binary (reports **U-Boot 2026.04** per `mkosi/platform/boot/README.md`),
which this pipeline does not control and which may simply behave differently
from whatever build the Rock 5B forum posts were describing. A full cold power
cycle (power fully removed, not a warm reboot) has not been tested and may
behave differently. Treat that as open, not settled. **Practical takeaway:**
don't trust card insertion alone. After rebooting, confirm the board actually
came up from the card. Watch the U-Boot boot-device probe messages on the
UART console, or check over SSH/network with `uname -a` and `lsblk` (rootfs on
`mmcblk1`, not `mmcblk0`), before relying on a microSD-based bench or recovery
flow.

### Option B: rkdeveloptool to eMMC (maskrom mode)

This path writes directly to eMMC over USB while the board is in maskrom mode.
It requires `rkdeveloptool` from Rockchip.

**Install rkdeveloptool:**

```bash
# From source (recommended — distro packages are often outdated)
git clone https://github.com/rockchip-linux/rkdeveloptool.git
cd rkdeveloptool
autoreconf -i
./configure
make
sudo make install
```

**Enter maskrom mode on Rock 5B+:**

**Pending hardware run** — the exact button location and USB detection output
for the Rock 5B+ will be filled from `test-results/boot-log-<date>.txt` once a
physical board is available.

The general procedure for RK3588 boards:

1. Power off the board completely.
2. Hold the maskrom button (board-specific location — consult the board's
   hardware manual).
3. Apply power while holding the button.
4. Release the button after 2-3 seconds.
5. Confirm the board is detected: `sudo rkdeveloptool ld` should list a
   `Maskrom` device.

**Write the image:** the release-candidate build workflow (`release.yml`) produces
the immutable candidate artifact (compressed `.raw.xz` + both raw/transport
SHA-256 records + signed `.raucb` + pinned loader); an
operator downloads it and flashes it with the bench flash-and-verify tool
(`ci/verify-and-flash-candidate.sh`, described in
[`ci/runner-setup.md`](../ci/runner-setup.md)). The tool downloads the pinned
loader, verifies and decompresses the raw into a private sparse snapshot, checks
the approved Maskrom USB fixture and eMMC capacity, captures the
initial loader command under a pinned process-group leader, and limits it with a
monotonic 15-second budget.
After `db` exits, a separate 10-second phase must observe the same
VID/PID/`LocationID` in `Loader` mode before capacity or identity reads. A stuck
command receives whole-group TERM then KILL with bounded cleanup; a stale,
missing, malformed, multiple, changed, or wrong-mode re-enumeration fails before
`rfi` and every write/readback/reset. Neither phase retries. Logs name command
timeout and Loader re-enumeration timeout separately. The tool then verifies the
image, writes it, reads the entire candidate range back, and only then resets. A
direct `rkdeveloptool wl` command is not an acceptable production or recovery path.
After boot, the tool requires `/` on the booted board to resolve to the flashed
eMMC before its SSH checks. Images are hand-tested on real hardware before a manual
release; there is no automated CI job that flashes or tests real hardware.

#### Manual bench flashing (development/debugging only — NOT the verified release path)

The bench flash-and-verify tool above is the safe path for a release candidate.
The procedure below is for a developer or bench engineer who needs to flash a
board directly during development or debugging, outside that verified pipeline. It
has been validated on real Rock 5B+ hardware.

**The 3-command procedure:**

```bash
rkdeveloptool db  <loader.bin>      # download the loader (SPL) into device RAM
rkdeveloptool wl 0 <image.raw>      # write a decompressed raw image, starting at LBA 0
rkdeveloptool rd                    # reset the device
```

No intermediate "wait for Loader mode" gate is required between `db` and `wl`
for this manual path — go straight from a successful `db` to `wl`. That gate
exists inside the automated CI script above for its own safety-timeout
bookkeeping, not because `rkdeveloptool` itself requires it; polling
`rkdeveloptool ld` for a "Loader" mode string proved unreliable for at least
one loader/`rkdeveloptool` build combination during hardware validation. After
`db`, give the loader a brief moment (roughly one second) to re-enumerate as a
USB-MSC device before issuing `wl` — running the two back-to-back with zero
delay can race the USB re-enumeration and report "Did not find any rockusb
device," though the loader itself stays alive; retrying `wl` against the same
still-live session then succeeds with no fresh `db` needed.

**Timeout discipline — the single most important rule here.** A full `wl 0`
write of the ~14.8 GB Rock 5B+ image over USB takes roughly **900-930 seconds
(~15 minutes)**. Do not run it under a timeout or wrapper with less than about
**1800 seconds (30 minutes)** of headroom above that baseline. Killing `wl`
mid-write leaves the on-chip loader session wedged — a subsequent
`rkdeveloptool rfi` fails with `Read Flash Info failed!` — and there is no
resume. Recovering requires a full fresh Maskrom re-entry: power the board
off, re-enter Maskrom, and run `db` again from scratch. Prefer running `wl` as
a detached/background process with periodic progress polling (e.g. checking
the process is still alive and tailing its log every few minutes) rather than
a blocking foreground call wrapped in an aggressive timeout.

**UART console baud rate.** The Rock 5B+, and the RK3588 board family
generally (per the `serial_console:` value in the family manifest and
`mkosi/platform/boot/install-boot.sh`), uses **1500000 baud** on its debug
UART — not the 115200 baud that is correct for the x86 family. Capture the
console with:

```bash
stty -F /dev/ttyUSBx 1500000 cs8 -cstopb -parenb raw -echo -crtscts clocal
cat /dev/ttyUSBx
```

**UART log parsing caveat.** The boot log on this UART is a genuinely
multi-writer stream: kernel `dmesg` output and systemd's status printer both
write to the same tty, using `\r` and ANSI cursor-movement/clear codes
(`ESC[nA`, `ESC[K`) to redraw status lines in place. A naive strip of `\r` and
ANSI codes can concatenate before/after redraw content into garbled,
misleading merged text. To check a specific claim (e.g. "did unit X fail?"),
strip only color codes and search the raw log for the literal substring,
cross-checking the surrounding byte context, rather than trusting a fully
reconstructed log. Better still, verify empirically over the network (ping,
port probe, `curl`) once the board is reachable — that's faster and
unambiguous compared to log archaeology.

Entering Maskrom mode is board-specific — consult the board's hardware
documentation for the exact button location and timing.

For full rkdeveloptool documentation, see the
[Rockchip Linux wiki](https://opensource.rock-chips.com/wiki_Rkdeveloptool).

### Experimental-image bench workflow (microSD discipline)

When bench-testing an experimental build (a `--variant edge-test` kernel, or any
image you don't want to risk on a board's production eMMC), use
`CERALIVE_BENCH_LABELS=1` to relabel the GPT partitions
(`xboot`/`xrootfs_a`/`xrootfs_b`/`xdata` instead of the frozen
`boot`/`rootfs_a`/`rootfs_b`/`data`) and flash the image to a **microSD card**,
not eMMC:

```bash
CERALIVE_BENCH_LABELS=1 ./build rock-5b-plus --variant edge
```

This exists specifically because a bench microSD is booted on a board whose
**eMMC already carries a production image** — the frozen contract selects
every slot and mount by `PARTLABEL`
([`docs/partition-contract.md`](partition-contract.md) §3), and duplicate
labels across the two media would make `PARTLABEL=rootfs_a` ambiguous to the
running kernel. It is bench-only tooling layered on top of the frozen
contract, not a contract change — a bench-labelled image deliberately FAILS
`tests/preflash-verify.sh` (which asserts the production label set), so the
eMMC flash gate refuses it by construction. No release/publish path ever sets
this flag.

**Building a hardware-qualification CANDIDATE? The mode is a required flag, not
an environment variable.** `ci/build-hardware-candidates.sh` refuses to run
without an explicit `--bench-labels 0|1` and exports `CERALIVE_BENCH_LABELS`
from it, so a candidate can never inherit the value from your shell:

```bash
ci/build-hardware-candidates.sh --only rock-edge-test \
  --trust-verdict verdict.json --signing-env sign.env --debug-env debug.env \
  --evidence evidence/ --bench-labels 1      # 1 = bench microSD, 0 = production
```

This is the direct outcome of a 2026-08-10 incident on this exact bench rig. A
debug candidate was built without the overlay while every other candidate that
day had it; its `/etc/fstab` then mounted `/boot` and `/data` from the board's
onboard eMMC (which carries an unrelated image using the plain labels) rather
than the microSD's `xboot`/`xdata`, because U-Boot resolves the ROOT filesystem
off the medium it booted from while fstab resolves everything else by label
alone. The board therefore looked healthy, and a RAUC recovery transition
silently wrote its A/B state to the wrong physical device — recoverable only by
hand. If a board has both a bench microSD and an eMMC image, `--bench-labels 1`
is not optional. Full write-up: `AGENTS.md`, "Bench PARTLABEL overlay" and the
candidate-builder KEY FACT; also [`dev-loop.md`](dev-loop.md).

**Microsd boot discipline, board-verified.** A real Rock 5B+ microSD boot
smoke test (todo 27) confirmed a full boot to userspace with no crash loop
under this discipline — that transcript is cited here rather than re-run,
per the command-classification rule above (`dd`-writing a card is
destructive). See `.omo/evidence/device-platform-wave4/task-27-sd-boot-validation.md`
and `task-27-orangepi5plus-build.md` for the full board-proof transcripts.
Section 2 above ("Opt-in kernel-build-from-source variants") covers building
the experimental image itself; this section only covers the microSD-vs-eMMC
media discipline for testing it.

---

## 5. First boot

**Pending hardware run** — boot log timestamps and exact console output will be
filled from `test-results/boot-log-<date>.txt` once a physical board is
available. The software-side first-boot sequence is described below based on
the merged service implementations.

Expected first-boot sequence:

1. U-Boot loads `boot.scr` from the shared boot partition and selects slot A.
   At the console, `recovery.scr` can explicitly load slot A from p2 or slot B
   from p3 without relying on extlinux path resolution.
2. Kernel boots from `rootfs_a`. One-shot first-boot services run in order:
   - `ceralive-hostname.service` — asks Avahi to establish `ceralive.local`, then
     `ceralive2.local`, `ceralive3.local`, ... under collision. It never accepts
     Avahi's hyphenated alternative or a random suffix. Runtime hostname,
     `/etc/hostname`, persistent index, and published name are committed only
     after exact ownership is stable. Each claim attempt is bounded to 120 s;
     malformed/unavailable state fails closed and systemd retries after 5 s. A
     separate 30-second timer repairs explicit publication divergence after
     isolated networks are joined without rerunning allocation when aligned.
   - `ceralive-ssh-firstboot.service` — regenerates per-device SSH host keys,
     writes `PermitRootLogin prohibit-password`, and arms a forced password
     change for the `ceralive` user (`chage -d 0`). Runs `Before=ssh.service`
     so sshd never accepts a connection before hardening is in place.
     Source: `mkosi/runtime/ceralive-ssh-firstboot.sh`.
   - `ceralive-tls-firstboot.service` — keeps a per-device self-signed TLS cert
     in `/data/ceralive/tls/` (RSA 2048, 3650 days, CN/SAN =
     `<hostname>.local` + device IPv4). It validates the cert/key pair and
     replaces it if deterministic collision recovery changes the hostname.
     Runs `Before=nginx.service`.
     Source: `mkosi/runtime/ceralive-tls-firstboot.sh`.
   - `ceralive-provision.service` — evaluates whether to start the WiFi
     provisioning portal. On a device with no stored WiFi profiles and no
     wired uplink, waits 75 s then brings up the `CeraLive-Setup-<short-id>`
     WPA2 hotspot. Source: `mkosi/runtime/ceralive-provision.sh`.
3. `ceralive.service` starts and binds port 80 (HTTP). If the provisioning
   portal is active, `ceralive.service` is stopped first so the portal can
   use port 80; it restarts automatically after provisioning completes.
4. `nginx.service` starts and binds port 443 (HTTPS), reverse-proxying to
   the CeraUI backend on `127.0.0.1:80`.
5. The health gate (`ceralive-healthcheck.service`) runs after
   `ceralive.service` starts. On a fresh offline device the SRT reachability
   check is skipped; the mDNS probe logs a warning if mDNS is not yet
   resolvable (non-fatal).

For the operator-facing walkthrough of the WiFi portal and first login, see
[`docs/FIRST-BOOT.md`](FIRST-BOOT.md).

**Verify the services are running** (once the device is on the network):

```bash
ssh ceralive@<selected-hostname>.local 'systemctl status ceralive.service'
ssh ceralive@<selected-hostname>.local 'journalctl -u ceralive.service -n 50'
ssh ceralive@<selected-hostname>.local \
  'hostname; cat /etc/hostname; cat /data/ceralive/host_index; busctl --system call org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetHostName'
```

The default user is `ceralive` (password-locked; see `docs/FIRST-BOOT.md` §5
for first-login instructions). If another device already owns `ceralive.local`,
replace it with the selected fallback hostname shown on the HDMI/serial console,
for example `ceralive2.local`.

### First-time credential bootstrap (board-verified)

A freshly-flashed, never-before-booted CeraUI image has **no usable
credentials at all** — not SSH, not the web UI. Don't waste time guessing at an
SSH password on a fresh board; there isn't one yet, by design (see
[`docs/ssh-hardening.md`](../docs/ssh-hardening.md) for why the account
ships password-locked). This is the practical two-stage flow to get in, verified
live on a Rock 5B+ running a vendor-6.1 control image.

**Step 1 — set the UI password.** Point a browser at `http://<board-ip>/`
(HTTPS also works, but it's a self-signed cert — expect a browser warning; see
the TLS front section above). On a genuine first boot, CeraUI immediately shows
"You'll need to create a secure password to protect your account" with a New
Password / Confirm Password form. This is also the fastest way to tell a
first-boot state apart from an already-configured device — if you see that
form, the board has never been through setup. Submitting it logs you straight
into the CeraUI dashboard.

**This password is web-UI-only.** It does not set, sync, or unlock an SSH
password — SSH is a separate, independently-gated credential.

**Step 2 — enable and read the SSH password.** In the logged-in UI, go to
Settings → Developer → "SSH Access". The panel shows SSH Server: Active/Inactive;
once active it displays an auto-generated plaintext SSH password (username is
always `ceralive`) with Copy-to-clipboard and Reset buttons. That's what you
hand to `ssh ceralive@<board-ip>` — confirmed working end-to-end on real
hardware this way.

**Don't assume credentials carry over between flashes.** Each fresh image is
its own independent first-boot state and needs this same two-step bootstrap
(UI password, then enable + read the SSH password from Settings → Developer)
every time. A password that worked for a previous image build on the same
board and IP will not work on a new flash.

For the underlying mechanism — why the account is password-locked by default,
and what the `CERALIVE_DEBUG_IMAGE` / `CERALIVE_DEBUG_PASSWORD_HASH` build-time
knobs do — see [`docs/ssh-hardening.md`](../docs/ssh-hardening.md).

**Check the boot slot:**

```bash
ssh ceralive@<selected-hostname>.local 'rauc status'
```

---

## 6. Dev loop

The dev loop pushes a code change to a running device in under two minutes,
without reflashing. It builds a squashfs sysext, rsyncs it to the board, and
restarts `ceralive.service`.

### Push srtla

```bash
# From the image-building-pipeline/ directory:

# Push srtla (default)
./dev-push <board-ip> srtla
```

> cerastream dev-sync is a follow-on (IPC-driven engine, different sync shape).

The script runs four steps: build, rsync, `systemd-sysext refresh`, and
`systemctl restart ceralive.service`. The restart is required because CeraUI's
backend holds in-process FFI handles to srtla; a sysext refresh
alone does not reload them.

### Sync the frontend

```bash
./dev-sync --frontend
```

**Pending hardware run** — the `dev-sync --frontend` invocation and timing will
be confirmed from `test-results/boot-log-<date>.txt` once a physical board is
available. The script exists under `dev-sync`; consult
[`docs/dev-loop.md`](../docs/dev-loop.md) for the current reference.

### Environment knobs

| Variable | Default | Purpose |
| --- | --- | --- |
| `DRY_RUN=1` | `0` | Print commands without running them |
| `SSH_USER` | `root` | Remote user |
| `SSH_OPTS` | _(none)_ | Extra SSH flags, e.g. `SSH_OPTS="-p 2222"` |
| `DEV_PUSH_BUDGET` | `120` | Time budget in seconds; `0` = no limit |

### What dev-push does NOT update

Changes to the following require a full image rebuild and reflash (or a RAUC
OTA bundle install):

- `libsrt` (lives in the OS runtime layer)
- GStreamer plugins / Rockchip MPP
- Kernel, U-Boot, firmware
- System config (`/etc`), udev rules

CeraUI itself uses the appfs backend rather than sysext. For now, CeraUI
changes require a manual `dpkg -i` over SSH or a full reflash:

```bash
scp ceraui_*.deb root@<board-ip>:/tmp/
ssh root@<board-ip> 'dpkg -i /tmp/ceraui_*.deb && systemctl restart ceralive.service'
```

---

## 7. Tier-1 E2E smoke test

This test runs entirely on your build host with no hardware. It wires the full
CeraLive receive path over loopback (`127.0.0.x`) and asserts a bonded stream
is delivered end-to-end.

```text
synthetic 2-link SRTLA sender -> srtla_rec -> irl-srt-server -> ffprobe
```

### Run the test

From the workspace root (the parent of `image-building-pipeline/`):

```bash
bash tools/e2e/loopback-smoke.sh
```

### What it tests

**Tier-A (always runs):** Two synthetic SRTLA links register with `srtla_rec`,
which forwards to a UDP probe. The test asserts the bond registered two
connections, delivered data, and kept flowing after one link was killed.

**Tier-B (runs when `irl-srt-server` is built):** `ffmpeg` publishes a real
SRT/MPEG-TS stream through the bonding tunnel into `irl-srt-server`. `ffprobe`
pulls it back and asserts a decodable video stream. Single-link drop resilience
is tested again at the video level.

### Expected output

```text
[e2e HH:MM:SS] TIER-A: bonded transport (2-link sender -> srtla_rec -> UDP probe)
[e2e HH:MM:SS]   group_registered=true connections=2
[e2e HH:MM:SS]   bonded received: <N> pkts / <B> bytes
[e2e HH:MM:SS]   single-link drop: killing secondary link 127.0.0.2 ...
[e2e HH:MM:SS]   after drop: ... continued=true
[e2e HH:MM:SS]   TIER-A verdict: pass
[e2e HH:MM:SS] TIER-B: bonded video
[e2e HH:MM:SS]     (ffmpeg -> tunnel -> srtla_rec -> irl-srt-server -> ffprobe)
[e2e HH:MM:SS]   ffprobe saw a video stream; testing single-link drop
[e2e HH:MM:SS]   TIER-B verdict: pass (link_drop_continued=true)
[e2e HH:MM:SS] VERDICT=pass (transport=pass video=pass)
```

If `irl-srt-server` is not yet built, Tier-B reports `pending-t2` and the
harness still exits 0 on a green Tier-A.

### Evidence JSON

Results are written to `test-results/e2e-loopback-<YYYYMMDD>.json` (gitignored).

### Environment overrides

```bash
# Point at a custom srtla_rec binary
SRTLA_REC=/path/to/srtla_rec bash tools/e2e/loopback-smoke.sh

# Point at a custom srt_server binary
SRT_SERVER=/path/to/srt_server bash tools/e2e/loopback-smoke.sh

# Keep the temp workdir after the run (for debugging)
E2E_KEEP=1 bash tools/e2e/loopback-smoke.sh
```

---

## 8. Signing bundles

### Dev builds (local and CI)

The build system defaults to a throwaway dev signing key stored in
`.dev-keys/` (gitignored). This key is for local and CI builds only and
must never be used in production.

The canonical test entrypoint creates this ignored fixture automatically on a
clean checkout:

```bash
CERALIVE_RUN_REAL_AVAHI_CONTRACT=required \
  CERALIVE_RUN_REAL_RAUC_CONTRACT=required \
  CERALIVE_RUN_REAL_PRIVILEGE_DROP_CONTRACT=required ./run-tests
```

All three default to `skip`, so a plain `./run-tests` on a machine without root
or passwordless sudo still completes: the privilege-drop gate reports `SKIP` for
the three package-index probes that need a real UID drop, and every other
assertion runs normally.

The generator validates the NON-PRODUCTION certificate chain and leaf key before
the RAUC assertions run. Production builds still require an explicit
`CERALIVE_RAUC_PKI_DIR`; the test fixture is never a production fallback.

The orchestrator sets this automatically:

```bash
# Default: uses .dev-keys/ if CERALIVE_RAUC_PKI_DIR is not set
./build rock-5b-plus
```

To verify a dev-signed bundle:

```bash
rauc info \
  -C keyring:check-purpose=codesign \
  --keyring=.dev-keys/dev-root-ca.pem \
  images/rock-5b-plus/<ts>.raucb
```

The `-C keyring:check-purpose=codesign` flag is required. The leaf certificate
carries `extendedKeyUsage = codeSigning`; RAUC's default verify purpose
(`smimesign`) rejects it without this flag.

### Production builds

For production, point `CERALIVE_RAUC_PKI_DIR` at your own PKI directory
containing the following files:

```text
<your-signing-key>/
  root-ca.pem        # root CA cert (baked into device keyring)
  chain.pem          # intermediate chain; leaf certificate is passed separately
  leaf-signing.pem   # leaf code-signing cert
  leaf-signing.key   # leaf private key
```

Replace `<your-signing-key>` with the path to your PKI directory:

```bash
export CERALIVE_RAUC_PKI_DIR="<your-signing-key>"
./build rock-5b-plus
```

### Generating a dev key

If you need to regenerate the dev key (e.g. after expiry):

```bash
cd .dev-keys

# Root CA
openssl genrsa -out dev-root-ca.key 2048
openssl req -new -x509 -key dev-root-ca.key -out dev-root-ca.pem -days 3650 \
  -subj '/CN=CeraLive Dev Root CA (NON-PRODUCTION)'

# Intermediate CA
openssl genrsa -out dev-intermediate-ca.key 2048
openssl req -new -key dev-intermediate-ca.key -out dev-intermediate-ca.csr \
  -subj '/CN=CeraLive Dev Intermediate CA (NON-PRODUCTION)'
openssl x509 -req -in dev-intermediate-ca.csr \
  -CA dev-root-ca.pem -CAkey dev-root-ca.key -CAcreateserial \
  -out dev-intermediate-ca.pem -days 1825 \
  -extfile <(printf \
    'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign')
rm dev-intermediate-ca.csr

# Leaf signing cert
openssl genrsa -out dev-leaf-signing.key 2048
openssl req -new -key dev-leaf-signing.key -out dev-leaf-signing.csr \
  -subj '/CN=CeraLive Dev Leaf Signing (NON-PRODUCTION)'
openssl x509 -req -in dev-leaf-signing.csr \
  -CA dev-intermediate-ca.pem -CAkey dev-intermediate-ca.key -CAcreateserial \
  -out dev-leaf-signing.pem -days 730 \
  -extfile <(printf \
    'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning')
rm dev-leaf-signing.csr

# Chain (the leaf is passed separately as the signer)
cp dev-intermediate-ca.pem dev-chain.pem

# Symlinks expected by build-bundle.sh
ln -sf dev-root-ca.pem root-ca.pem
ln -sf dev-chain.pem chain.pem
ln -sf dev-leaf-signing.pem leaf-signing.pem
ln -sf dev-leaf-signing.key leaf-signing.key
```

---

## 9. Troubleshooting

### Pre-flash gate fails on RAUC check

The dev key symlinks may be missing. From `.dev-keys/`:

```bash
ln -sf dev-root-ca.pem root-ca.pem
ln -sf dev-chain.pem chain.pem
ln -sf dev-leaf-signing.pem leaf-signing.pem
ln -sf dev-leaf-signing.key leaf-signing.key
```

Then re-run the gate.

### `rauc info` fails with "unsuitable certificate purpose"

Always pass `-C keyring:check-purpose=codesign` when verifying bundles signed
with a `codeSigning` leaf:

```bash
rauc info -C keyring:check-purpose=codesign --keyring=<keyring.pem> <bundle.raucb>
```

### `ldconfig -p` shows system libsrt before BELABOX libsrt

The `/etc/ld.so.conf.d/usr-local-lib.conf` file is missing or `ldconfig` has
not been re-run:

```bash
echo /usr/local/lib | sudo tee /etc/ld.so.conf.d/usr-local-lib.conf
sudo ldconfig
ldconfig -p | grep libsrt
```

### E2E smoke test: `srtla_rec not found`

Build srtla first (see [Prerequisites](#1-prerequisites)), or set the
`SRTLA_REC` env var to point at your binary:

```bash
SRTLA_REC=/path/to/srtla_rec bash tools/e2e/loopback-smoke.sh
```

### dev-push: `extension-release mismatch`

The sysext `.raw` carries `ID=debian` plus the `OS_VERSION_ID` from
[`manifests/target-release.env`](../manifests/target-release.env) (`13`). If the device runs a
different OS version, the merge is rejected. Check the device:

```bash
ssh root@<board-ip> 'grep -E "^(ID|VERSION_ID)" /etc/os-release'
```

Override the release fields if needed:

```bash
SYSEXT_OS_VERSION_ID=13 ./dev-push <board-ip>
```

### First boot: board does not appear on the network

**Pending hardware run** — specific console output and timing for this failure
mode will be filled from `test-results/boot-log-<date>.txt` once a physical
board is available.

Check that the board's HDMI output shows U-Boot and kernel messages. If the
board is stuck in maskrom mode, power-cycle without holding the maskrom button.

If the board boots but does not appear on the network, the WiFi provisioning
portal may be active. Look for a `CeraLive-Setup-<short-id>` hotspot and
follow the provisioning steps in [`docs/FIRST-BOOT.md`](FIRST-BOOT.md) §3.

---

## Fresh-eyes checklist

Starting from zero (no prior context, no board in hand), this is the path to a
working build:

- [ ] Install Docker or Podman. That is the only host requirement for the
      canonical container build (§1).
- [ ] `git clone https://github.com/ceralive/image-building-pipeline.git && cd image-building-pipeline`
- [ ] `INSTALL_BOOT_BSP=0 DRY_RUN=1 ./build rock-5b-plus` — confirms manifest
      resolution, package pin listing, and the docker builder plan with **no**
      network or hardware touched (§2; this is the same command executed,
      transcript captured, while writing this doc).
- [ ] `./build rock-5b-plus` for a real build (needs `apt.ceralive.tv`
      credentials — see "APT feed" in §1; ~15-30 min on a modern host).
- [ ] Before touching real hardware, read §3 "Pre-flash verification" and run
      `tests/preflash-verify.sh` against your build's uncompressed `.raw` — it is
      non-destructive (only reads block-device size) and catches most build
      defects before you commit to a flash.
- [ ] Pick ONE flash path from the table at the top of §4, matching your
      hardware access (microSD-only bench setup vs. maskrom-capable eMMC
      flash) — do not mix `dd`/`rkdeveloptool` guidance from memory; follow
      the linked section exactly, since the destructive steps are not
      re-verified per doc edit (see the command-classification note in §4).
- [ ] After first boot, follow §5 "First-time credential bootstrap" — a fresh
      image has NO usable credentials of any kind; do not guess at an SSH
      password.
- [ ] For iterative development without reflashing, switch to §6 "Dev loop".

If any step here fails in a way this doc doesn't already describe, that is a
real doc gap — file it rather than silently working around it.

## Related docs

- [`docs/dev-loop.md`](../docs/dev-loop.md) — full dev-push reference
- [`docs/partition-contract.md`](partition-contract.md) — frozen GPT layout
- [`docs/cert-rotation-policy.md`](cert-rotation-policy.md) — key rotation
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — contribution rules and testing gate
