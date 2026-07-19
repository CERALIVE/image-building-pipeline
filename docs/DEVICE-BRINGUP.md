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

### Host OS

Debian 12 (Bookworm) or Ubuntu 24.04 LTS recommended. Arch Linux works with
minor adjustments noted inline.

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
./v2/build rock-5b-plus

# Orange Pi 5+
./v2/build orange-pi-5-plus
```

The build entry point is `v2/build`, which calls `v2/lib/orchestrate.sh`. It
runs through nine stages: resolve manifest, fetch `.deb` packages, validate,
run mkosi, assemble disk, write bootloader gap, and emit a signed `.raucb`
bundle.

**Dry run** (resolve and fetch plan only, no image written):

```bash
INSTALL_BOOT_BSP=0 DRY_RUN=1 ./v2/build rock-5b-plus
```

### Artifacts

After a successful build, artifacts land in `v2/images/<board>/`:

```text
v2/images/rock-5b-plus/
  20260609T075534Z.raw      # flashable disk image (sparse, 14,800 MiB nominal)
  20260609T075534Z.raucb    # signed RAUC OTA bundle
  20260609T075534Z.raucb.sha256
```

The `.raw` is a sparse file. Actual on-disk size is much smaller than the
nominal 14,800 MiB. Use `du -sh` to see the allocated host-file size.

### Custom APT mirror

If you're running a local mirror or a fork of the package feed, set:

```bash
export CERALIVE_APT_MIRROR="https://<your-apt-mirror>/debian"
./v2/build rock-5b-plus
```

Replace `<your-apt-mirror>` with your mirror hostname.

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
bash v2/tests/preflash-verify.sh --target-size-bytes "${TARGET_SIZE_BYTES}"
```

Expected output (all nine checks green):

```text
==============================================================
 CeraLive pre-flash verification gate — board rock-5b-plus
 image:   v2/images/rock-5b-plus/<ts>.raw
 bundle:  v2/images/rock-5b-plus/<ts>.raucb
 keyring: v2/.dev-keys/dev-root-ca.pem
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
bash v2/tests/preflash-verify.sh --self-test \
  --target-size-bytes "${TARGET_SIZE_BYTES}"
```

---

## 4. Flashing

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
BOARD_DIR="v2/images/rock-5b-plus"
IMAGE="${BOARD_DIR}/$(ls -t "${BOARD_DIR}"/*.raw | head -1 | xargs basename)"

sudo dd if="${IMAGE}" of=/dev/sdX bs=4M status=progress conv=fsync
sudo sync
```

Eject the card and insert it into the board. The board boots from microSD
when no eMMC is present (or when the eMMC boot order is overridden).

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

**Write the image:** use the candidate-bound `release.yml` workflow described in
[`v2/ci/runner-setup.md`](../v2/ci/runner-setup.md). It downloads the pinned
loader, checks the approved Maskrom USB fixture and eMMC capacity, captures the
initial loader command under a pinned process-group leader, and limits it with a
monotonic 15-second budget.
After `db` exits, a separate 10-second phase must observe the same
VID/PID/`LocationID` in `Loader` mode before capacity or identity reads. A stuck
command receives whole-group TERM then KILL with bounded cleanup; a stale,
missing, malformed, multiple, changed, or wrong-mode re-enumeration fails before
`rfi` and every write/readback/reset. Neither phase retries. Logs name command
timeout and Loader re-enumeration timeout separately. The workflow then captures
the 16-byte SoC-family marker with `rkdeveloptool rci`, verifies the image,
writes it, reads the entire candidate range back, and only then resets. A direct
`rkdeveloptool wl` command is not an acceptable production or recovery path.
After boot, the gate reads the RK3588 OTP `cpu_code` cell (nvmem offset `0x02`)
via the image's committed helper and requires a like-for-like family match before
SSH checks. `rci` and the OTP encode the family differently, so the helper reads
that cpu_code cell — not a raw 16-byte dump — and both sides normalize to the same
cpu_code identity. `rci` is only the RK3588 family constant (Maskrom exposes no
per-device read), so the genuine per-device binding is the eMMC CID: the UART
bootstrap records it and the gate cross-checks it against the live post-boot media CID.

#### Manual bench flashing (development/debugging only — NOT for production releases)

The CI release gate above is the only acceptable path for production or
recovery flashes. The procedure below is for a developer or bench engineer who
needs to flash a board directly during development or debugging, outside the
full CI release pipeline. It has been validated on real Rock 5B+ hardware.

**The 3-command procedure:**

```bash
rkdeveloptool db  <loader.bin>      # download the loader (SPL) into device RAM
rkdeveloptool wl 0 <image.raw>      # write the full raw image, starting at LBA 0
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
`v2/mkosi/platform/boot/install-boot.sh`), uses **1500000 baud** on its debug
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
     Source: `v2/mkosi/runtime/ceralive-ssh-firstboot.sh`.
   - `ceralive-tls-firstboot.service` — keeps a per-device self-signed TLS cert
     in `/data/ceralive/tls/` (RSA 2048, 3650 days, CN/SAN =
     `<hostname>.local` + device IPv4). It validates the cert/key pair and
     replaces it if deterministic collision recovery changes the hostname.
     Runs `Before=nginx.service`.
     Source: `v2/mkosi/runtime/ceralive-tls-firstboot.sh`.
   - `ceralive-provision.service` — evaluates whether to start the WiFi
     provisioning portal. On a device with no stored WiFi profiles and no
     wired uplink, waits 75 s then brings up the `CeraLive-Setup-<short-id>`
     WPA2 hotspot. Source: `v2/mkosi/runtime/ceralive-provision.sh`.
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
# From the image-building-pipeline/v2/ directory:

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
available. The script exists under `v2/dev-sync`; consult
[`v2/docs/dev-loop.md`](../v2/docs/dev-loop.md) for the current reference.

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
`v2/.dev-keys/` (gitignored). This key is for local and CI builds only and
must never be used in production.

The canonical test entrypoint creates this ignored fixture automatically on a
clean checkout:

```bash
CERALIVE_RUN_REAL_AVAHI_CONTRACT=required \
  CERALIVE_RUN_REAL_RAUC_CONTRACT=required ./v2/run-tests
```

The generator validates the NON-PRODUCTION certificate chain and leaf key before
the RAUC assertions run. Production builds still require an explicit
`CERALIVE_RAUC_PKI_DIR`; the test fixture is never a production fallback.

The orchestrator sets this automatically:

```bash
# Default: uses v2/.dev-keys/ if CERALIVE_RAUC_PKI_DIR is not set
./v2/build rock-5b-plus
```

To verify a dev-signed bundle:

```bash
rauc info \
  -C keyring:check-purpose=codesign \
  --keyring=v2/.dev-keys/dev-root-ca.pem \
  v2/images/rock-5b-plus/<ts>.raucb
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
./v2/build rock-5b-plus
```

### Generating a dev key

If you need to regenerate the dev key (e.g. after expiry):

```bash
cd v2/.dev-keys

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

The dev key symlinks may be missing. From `v2/.dev-keys/`:

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

The sysext `.raw` carries `ID=debian VERSION_ID=12`. If the device runs a
different OS version, the merge is rejected. Check the device:

```bash
ssh root@<board-ip> 'grep -E "^(ID|VERSION_ID)" /etc/os-release'
```

Override the release fields if needed:

```bash
SYSEXT_OS_VERSION_ID=13 ./v2/dev-push <board-ip>
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

## Related docs

- [`v2/docs/dev-loop.md`](../v2/docs/dev-loop.md) — full dev-push reference
- [`docs/partition-contract.md`](partition-contract.md) — frozen GPT layout
- [`docs/cert-rotation-policy.md`](cert-rotation-policy.md) — key rotation
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — contribution rules and testing gate
