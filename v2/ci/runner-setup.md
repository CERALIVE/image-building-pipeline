# Self-Hosted RK3588 Hardware Runner — Setup & Safety Guide

> **Task 37 (Stage 6).** A self-hosted GitHub Actions runner with a **physical
> RK3588 board attached** (USB flash + serial + power control) so the real-HW
> acceptance gates — [`v2/tests/realhw-smoke.sh`](../tests/realhw-smoke.sh) (LIVE
> mode) and [`v2/tests/rauc-rollback.sh`](../tests/rauc-rollback.sh) (LIVE mode)
> — can run **on demand** (labeled / nightly), never on every PR.
>
> The reusable job that consumes this runner is
> [`v2/ci/realhw-job.yml`](realhw-job.yml). Regular offline CI stays on
> `ubuntu-latest` ([`.github/workflows/v2-ci.yml`](../../.github/workflows/v2-ci.yml));
> **only** the hardware jobs target this runner via
> `runs-on: [self-hosted, ceralive-rk3588]`.

---

## 0. Why a self-hosted runner at all

The two LIVE gates need to **boot a real board and talk to it**:

| Harness | What LIVE mode needs from the runner |
|---|---|
| `realhw-smoke.sh` (LIVE) | `BOARD_IP` reachable over SSH (`ceralive@…`, key auth); asserts login, `ceralive`/`ceraui.service` active, `cerastream`/`srtla_send`/`srtla_rec` present + `--version`, manifest-quirk HW (`/dev/video*`, modem, udev rule), and a full `parity-check.sh` over an rsync of the live rootfs. |
| `rauc-rollback.sh` (LIVE) | `BOARD_IP` + signed bundles in `BUNDLE_DIR` (`bad.raucb`, `good.raucb`); does `scp`+`rauc install`, `systemctl reboot`, **re-poll SSH after each reboot**, reads booted slot from `/proc/cmdline` (`root=PARTLABEL=rootfs_a\|b`). Proves a bad slot bleeds bootcount 3→2→1→0 and falls back to A; a good slot mark-goods and persists. |

GitHub-hosted runners are ephemeral VMs with no USB/serial/board. Only a
self-hosted runner physically wired to an RK3588 can satisfy these. **MUST-NOT
(task design): no qemu/mock result is accepted as the RK3588 proof** — the MOCK
mode of `rauc-rollback.sh` proves the engine, not the silicon.

---

## 1. Prerequisites

### 1.1 Host machine

- **Linux host**, Ubuntu **22.04 LTS or newer** (24.04 fine). A small always-on
  box (NUC/mini-PC/spare x86 desktop) is ideal — it must stay powered to service
  nightly + labeled jobs.
- **x86_64** strongly preferred (mkosi/docker tooling, `rkdeveloptool` apt
  package, GH runner are all first-class on amd64).
- ≥ 4 GB RAM, ≥ 40 GB free disk (build artifacts + image staging + runner work
  dir).
- Outbound HTTPS to `github.com` / `api.github.com` / `*.actions.githubusercontent.com`
  (the runner long-polls GitHub; **no inbound** port needs opening).

### 1.2 Attached RK3588 board

- **Orange Pi 5+** or **Radxa Rock 5B+** (the two RK3588 targets — see
  `manifests/boards/{orange-pi-5-plus,rock-5b-plus}.yaml`).
- **USB-OTG / Type-C** cable from the board's OTG port to a host USB port
  (used for maskrom-mode flashing — section 4).
- **USB-UART (serial)** adapter on the board's debug UART → host
  `/dev/ttyUSB0` or `/dev/ttyACM0` (section 5). RK3588 debug UART is **ttyS2 @
  1500000 baud** on-device (`family rk3588.yaml: serial_console: ttyS2:1500000`).
- **Network**: board on the same LAN as the host, with a **stable IP** (DHCP
  reservation by MAC, or static). This is the `BOARD_IP` the LIVE harnesses use.
- **Power control** (section 3) — required for unattended recovery.
- **eMMC** (or SD) the board boots from; this is the flash target.

### 1.3 Host packages

```bash
sudo apt-get update
sudo apt-get install -y \
  rkdeveloptool \      # RK3588 maskrom/loader flashing over USB-OTG
  android-tools-adb \  # optional: usb device probing
  minicom screen \     # serial console
  openssh-client \     # SSH/scp to the board (LIVE mode)
  rsync \              # realhw-smoke LIVE full-parity rsync
  xz-utils sgdisk gdisk util-linux  # image handling the harness expects
```

> `rkdeveloptool` ships in Ubuntu 22.04+ `universe`. If your distro lacks it,
> build from source (`github.com/rockchip-linux/rkdeveloptool`) or use
> Rockchip's `upgrade_tool` (section 4.3).

---

## 2. Install the GitHub Actions self-hosted runner

> **Credentials are PRIVATE.** The registration token below is **short-lived and
> repo/org-scoped**. Generate it from the repo's *Settings → Actions → Runners →
> New self-hosted runner* page (or `gh`), use it within its lifetime, and **never
> commit it, never echo it into logs, never expose it as a public-repo secret.**
> If this repo is public, register the runner at the **org** level with the
> runner restricted to this repo, so the token never lives in public CI config.

### 2.1 Create a dedicated, unprivileged service user

Do **not** run the runner as `root`. Flashing needs USB access via a `udev`
rule + group membership, not root.

```bash
sudo useradd -m -s /bin/bash ghrunner
sudo usermod -aG dialout,plugdev ghrunner   # dialout=serial, plugdev=USB
sudo -iu ghrunner
```

### 2.2 Download + configure the runner

```bash
# as ghrunner, in its home
mkdir actions-runner && cd actions-runner
RUNNER_VER="2.319.1"   # pin; check github.com/actions/runner/releases
curl -fsSL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VER}/actions-runner-linux-x64-${RUNNER_VER}.tar.gz"
tar xzf runner.tar.gz

# Register. <REPO_URL> e.g. https://github.com/<org>/image-building-pipeline
# <TOKEN> from Settings → Actions → Runners → New self-hosted runner (expires fast).
./config.sh \
  --url <REPO_URL> \
  --token <TOKEN> \
  --name ceralive-rk3588-rock5bplus-01 \
  --labels ceralive-rk3588 \
  --work _work \
  --unattended \
  --replace
```

- **`--labels ceralive-rk3588`** is the contract. Jobs select this runner with
  `runs-on: [self-hosted, ceralive-rk3588]`. Anything else stays on
  `ubuntu-latest`.
- Add a **board-specific** label too if you run more than one board, e.g.
  `--labels ceralive-rk3588,rock-5b-plus` — then a job can pin
  `runs-on: [self-hosted, ceralive-rk3588, rock-5b-plus]`.
- `--name` should be unique + identify the physical board.

### 2.3 Install as a service (auto-start, survives reboot)

```bash
# still in actions-runner, as ghrunner — but svc.sh needs sudo to install the unit
sudo ./svc.sh install ghrunner
sudo ./svc.sh start
sudo ./svc.sh status
```

The runner now appears **Idle** under *Settings → Actions → Runners*. The
service restarts on host reboot — important for an always-on HW lab.

### 2.4 Harden the runner

- **Run jobs from trusted refs only.** Self-hosted runners on a **public** repo
  are a supply-chain risk (a malicious PR can run arbitrary code on your lab
  box). Mitigations, in order of preference:
  - Keep the HW jobs **`workflow_dispatch` + `schedule` + label-gated** (see
    `realhw-job.yml`) so they never trigger from `pull_request`.
  - In *Settings → Actions → General*, set **"Require approval for all outside
    collaborators"** (or "for all PRs") so fork PRs can't auto-run.
  - Prefer an **org-level** runner scoped to this one repo with
    `pull_request`-from-fork disabled.
- **No long-lived secrets on the box.** The board's SSH key (section 6) is the
  only credential at rest; keep it `chmod 600`, owned by `ghrunner`, outside the
  runner's `_work` checkout dir so it's never inside a job's workspace.
- **Ephemeral option:** add `--ephemeral` to `config.sh` so the runner
  de-registers after one job (re-register via a wrapper/systemd). Safer for
  public repos; costs a re-register per job.

---

## 3. Power control (the safety backbone)

Unattended CI **must** be able to power-cycle the board — a wedged kernel, a
hung U-Boot, or a board that won't take a new flash all need a hard reset that no
SSH/serial command can deliver. Three options, cheapest-safe first:

### 3.1 USB relay (recommended, cheap, unattended-safe)

A USB-controlled relay (e.g. a 1–2 channel **HID/USB relay** ~ $5–15) inline on
the board's DC barrel/USB-C power. The runner drives it from userspace:

```bash
# example with `usbrelay` (apt: usbrelay) — one channel "BITFT_1"
usbrelay BITFT_1=0   # cut power
sleep 3
usbrelay BITFT_1=1   # restore power
```

- **Pros:** no extra network device, scriptable, ~$10, the host owns it
  directly. Add `ghrunner` to `plugdev` + a udev rule for the relay's VID:PID.
- **Cons:** the relay's current rating must exceed the board's peak draw
  (RK3588 + modem + capture can hit 3–4 A @ 5 V; size the relay/PSU accordingly,
  or switch the **mains side of the PSU** via a relay rated for AC).
- **Safest unattended pick** when the relay is sized correctly and the host is
  the single controller.

### 3.2 Smart PDU / smart plug (good for racks / multiple boards)

A networked PDU (APC/Eaton) or a flashed smart plug (Tasmota/`espnow`,
Shelly with local HTTP) exposes a power toggle over the LAN:

```bash
# Tasmota example (local HTTP, no cloud)
curl -s "http://<plug-ip>/cm?cmnd=Power%20Off" ; sleep 3
curl -s "http://<plug-ip>/cm?cmnd=Power%20On"
```

- **Pros:** handles full board power incl. high-draw peripherals; scales to a
  shelf of boards; physically isolates power.
- **Cons:** another networked device to secure (keep it on a **management
  VLAN**, local-only firmware, **no cloud account**); slower cycle (PSU
  inrush/boot).

### 3.3 Manual power switch (NOT for unattended CI)

A human flips power. **Acceptable only for an attended bring-up session**, never
for nightly/scheduled jobs — a bad flash at 02:00 with no remote power control
leaves the lab stuck until someone walks over. The `realhw-job.yml` nightly
schedule **requires** option 3.1 or 3.2.

> **Safety rule:** the runner must be able to (a) cut power, (b) put the board in
> maskrom (section 4.1 — manual button OR a second relay on the recovery pin),
> and (c) restore power — **without a human present**. If you can only do (a)+(c)
> automatically, gate flashing jobs to attended hours.

---

## 4. Flash tooling

Two paths. The **maskrom/USB-OTG** path (4.1–4.2) is the authoritative,
always-available one — it works even when the eMMC is empty or bricked. The
**SSH/`dd`** path (4.4) is faster but only works when the board already boots.

### 4.1 Enter maskrom mode (the key safety claim)

**Maskrom is ROM, not flash.** It lives in the SoC's mask ROM and is **always
reachable regardless of what is (or isn't) on the eMMC**. This is *why a bad
flash is always recoverable* — there is no flash content that can prevent
entering maskrom. To enter:

1. Power the board **off**.
2. Hold the **MASKROM / recovery button** (on RK3588 boards this is a small
   tactile switch; on some it is the "volume-down"-style recovery pad — check the
   board's silk/manual).
3. While holding it, connect the **USB-OTG/Type-C** cable to the host (or apply
   power via the relay).
4. Release the button. The host should now enumerate a **Rockchip USB device**
   in maskrom.

For **unattended** recovery, wire a **second USB-relay channel (or an optocoupler)
across the recovery button** so the runner can "press" it in software, then
power-cycle via the section-3 relay. Sequence: assert recovery → power on →
release recovery.

### 4.2 Flash with `rkdeveloptool` (open-source)

```bash
# 1. Confirm the SoC is in maskrom and the host sees it:
rkdeveloptool ld           # lists loader/maskrom devices; "Maskrom" = ready

# 2. Load the DDR init + U-Boot loader blob (the rkbin "loader"):
rkdeveloptool db rk3588_loader.bin     # download-boot the loader into SRAM
#    (rk3588_loader.bin = the rkbin RK3588 loader; matches uboot_packages: rkbin-rk3588)

# 3. Write the full image to the eMMC (offset 0 = whole-disk GPT image):
rkdeveloptool wl 0 ceralive-rock-5b-plus.img

# 4. Reset the board into the freshly-flashed system:
rkdeveloptool rd
```

- `ld` = list devices, `db` = download-boot loader, `wl <start_sector> <file>` =
  write at LBA, `rd` = reset. Sector 0 is correct for a **whole-disk** image with
  its own GPT (what `v2/lib/assemble-disk.sh` produces). For a **rootfs-only**
  partition image, write at that partition's start LBA instead — prefer
  whole-disk images for CI to keep this a single, dumb `wl 0`.
- `udev` rule so non-root can flash (file
  `/etc/udev/rules.d/99-rockchip-rk3588.rules`):
  ```
  # Rockchip RK3588 maskrom + loader (USB VID 2207)
  SUBSYSTEM=="usb", ATTR{idVendor}=="2207", MODE="0660", GROUP="plugdev"
  ```
  Then `sudo udevadm control --reload && sudo udevadm trigger`. `ghrunner` is in
  `plugdev`, so flashing needs no `sudo`.

### 4.3 Alternative: Rockchip `upgrade_tool`

Rockchip's closed `upgrade_tool` (a.k.a. `Linux_Upgrade_Tool`) does the same job
and some `.img`/firmware layouts only it handles cleanly:

```bash
upgrade_tool ul rk3588_loader.bin     # upgrade loader (= rkdeveloptool db)
upgrade_tool wl 0 ceralive-rock-5b-plus.img
upgrade_tool rd                       # reset
```

Use whichever the CI host has; `rkdeveloptool` is preferred because it is
open-source and apt-installable.

### 4.4 Alternative: flash over SSH (`dd`) — only if the board boots

When the board already runs a healthy system and you only need to *replace* the
whole image (faster than maskrom for the common case):

```bash
# stream the image to the eMMC; adjust mmcblk for your board (eMMC is usually mmcblk0)
xz -dc ceralive-rock-5b-plus.img.xz | \
  ssh -o BatchMode=yes ceralive@"$BOARD_IP" \
  'sudo dd of=/dev/mmcblk0 bs=4M conv=fsync status=progress'
ssh ceralive@"$BOARD_IP" 'sudo reboot'
```

- **Cheapest** (no flash hardware at all), but it **cannot recover a board that
  won't boot** — for that you always fall back to maskrom (4.1). CI should treat
  `dd`-over-SSH as the fast path and maskrom as the recovery path.

---

## 5. Serial access

The RK3588 debug UART is **`ttyS2` @ 1500000 baud on-device**
(`family rk3588.yaml: serial_console: ttyS2:1500000`). On the host it appears as
`/dev/ttyUSB0` (FTDI/CP210x adapter) or `/dev/ttyACM0` (CDC-ACM).

### 5.1 Interactive

```bash
# screen
screen /dev/ttyUSB0 1500000        # Ctrl-a k to quit

# or minicom (one-time: minicom -s to set 1500000 8N1, no flow control)
minicom -D /dev/ttyUSB0 -b 1500000
```

### 5.2 Capture serial from the runner (non-interactive)

Serial is the **only** window into early boot / U-Boot / a kernel that never
reaches SSH — capture it for every HW job so a failed boot is debuggable:

```bash
# log the full boot to a file the job uploads as an artifact
mkdir -p artifacts
stty -F /dev/ttyUSB0 1500000 raw -echo
timeout 300 cat /dev/ttyUSB0 | tee artifacts/serial-boot.log &
SERIAL_PID=$!
# ... trigger power-on / flash / reboot here ...
# at end of job:
kill "$SERIAL_PID" 2>/dev/null || true
```

`ghrunner` reads the port via its `dialout` group membership (section 2.1) — no
`sudo`. Capturing serial is what lets `rauc-rollback.sh`'s per-reboot loop be
diagnosed when SSH never returns.

---

## 6. SSH access for the LIVE harnesses

Both LIVE harnesses connect as **`ceralive`** (`SSH_USER` default) on
**port 22** (`SSH_PORT`) with `BatchMode=yes` (**key auth only — no password
prompts**, the harness will fail otherwise).

```bash
# as ghrunner: generate a dedicated CI key OUTSIDE the runner _work dir
ssh-keygen -t ed25519 -N '' -f ~/.ssh/ceralive_rk3588_ci -C 'ceralive-rk3588-ci'

# install the public key on the board's ceralive account (one-time, attended):
ssh-copy-id -i ~/.ssh/ceralive_rk3588_ci.pub ceralive@"$BOARD_IP"

# pin host + key so the harness's StrictHostKeyChecking=accept-new is happy:
cat >> ~/.ssh/config <<EOF
Host ceralive-board
  HostName ${BOARD_IP}
  User ceralive
  IdentityFile ~/.ssh/ceralive_rk3588_ci
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/ceralive_rk3588_ci ~/.ssh/config
```

- The key is the **only credential at rest**. Keep it `chmod 600`, owned by
  `ghrunner`, **outside** `_work/` so no job checkout can read it. Do **not** put
  it in repo secrets.
- `rauc-rollback.sh` LIVE also needs `ceralive` to `rauc install` and `reboot` —
  ensure passwordless `sudo` for exactly those (or run the unit as a privileged
  helper) on the board image, scoped tight.

---

## 7. Recovery from a bricked flash (the operational runbook)

A "brick" here means **the eMMC content won't boot** (bad image, interrupted
write, broken bootloader). Because **maskrom is ROM**, this is *always*
recoverable — there is no eMMC state that blocks maskrom entry. Runbook:

1. **Power off** the board (section 3 relay/PDU — `usbrelay …=0` / plug off).
2. **Assert recovery + power on into maskrom** (section 4.1): hold MASKROM
   button (or assert the recovery relay channel), power on, release.
3. **Confirm the loader is detected:**
   ```bash
   rkdeveloptool ld          # expect a "Maskrom" device line
   ```
4. **Re-download the loader + reflash a known-good image:**
   ```bash
   rkdeveloptool db rk3588_loader.bin
   rkdeveloptool wl 0 last-known-good.img
   rkdeveloptool rd          # reset into the reflashed system
   ```
5. **Watch serial** (section 5.2) to confirm U-Boot → kernel → login, then
   re-verify SSH (`ssh ceralive-board true`).

> **Keep a "last-known-good" image on the host** (a pinned release `.img` +
> `.sha256`) so recovery never depends on a fresh build. The nightly job (section
> 8) should refresh this only **after** a green smoke run.

### Failure-budget / retries (don't thrash a board)

- **`timeout-minutes: 30`** per HW job (set in `realhw-job.yml`) — a hung board
  can't hold the runner forever.
- **Max 1 retry** of a HW job on failure. A second failure means a **real**
  regression or a **physical** fault — escalate to a human, do **not** auto-loop
  (repeated failed flash/power cycles stress the eMMC + PSU).
- Always **capture serial + `rauc status` + `journalctl`** on failure as
  artifacts before any retry, so the first failure is diagnosable.
- If a job leaves the board unbootable, the **next** job's first step must run the
  section-7 maskrom recovery to reflash last-known-good before doing anything
  else (idempotent "ensure the board is alive" preflight).

---

## 8. Wiring it to CI

The runner is consumed by [`v2/ci/realhw-job.yml`](realhw-job.yml), a **reusable**
(`workflow_call`) workflow that also self-triggers on a **nightly schedule**
(`cron: '0 2 * * *'`) and `workflow_dispatch`. It is **never** triggered by
`pull_request`. A caller wires it behind a **label gate** so a maintainer can run
it on a specific PR on demand without burdening every PR:

```yaml
# in a caller workflow, e.g. .github/workflows/realhw.yml
on:
  pull_request:
    types: [labeled]          # only when someone adds the label
jobs:
  realhw:
    if: github.event.label.name == 'ci:real-hw'
    uses: ./.github/workflows/realhw-job.yml   # after copying realhw-job.yml there
    with:
      board: rock-5b-plus
```

> GitHub requires reusable workflows to live under `.github/workflows/`. This
> file is authored/version-controlled in `v2/ci/` (the pipeline's CI home, next
> to `validate-manifests.py`); copy/symlink it into `.github/workflows/` to
> activate it, or have the caller `uses:` a path there. Keeping the source in
> `v2/ci/` keeps the pipeline's CI definitions together and reviewable.

### Label / scheduling contract (MUST-NOT: never gate every PR)

| Trigger | Who | Runs on HW? |
|---|---|---|
| `pull_request` (normal) | everyone | **No** — offline `v2-ci.yml` on `ubuntu-latest` only |
| `pull_request` **labeled** `ci:real-hw` | maintainer adds label | Yes — on demand |
| `schedule` nightly 02:00 UTC | cron | Yes — catches drift |
| `workflow_dispatch` | maintainer | Yes — manual |

Scarce, slow, physical hardware **must not** sit in the critical path of every
PR. Labeled + nightly keeps fast feedback on `ubuntu-latest` while still proving
real silicon regularly.

---

## 9. Quick verification checklist

Run these on the host as `ghrunner` before declaring the runner ready:

```bash
# runner is registered + Idle
sudo ~/actions-runner/svc.sh status

# board reachable for LIVE smoke
ssh ceralive-board true && echo "SSH OK"

# maskrom path works (power off, enter maskrom, then:)
rkdeveloptool ld            # must print a Maskrom device

# serial captures
timeout 3 cat /dev/ttyUSB0 | head   # should show board chatter if powered

# power control
usbrelay <CH>=0 && sleep 2 && usbrelay <CH>=1   # board should reboot

# the harnesses themselves (LIVE):
BOARD=rock-5b-plus BOARD_IP=<ip> ./v2/tests/realhw-smoke.sh
BOARD_IP=<ip> BUNDLE_DIR=/path/to/bundles ./v2/tests/rauc-rollback.sh
```

All green ⇒ the `ceralive-rk3588` runner is ready for `realhw-job.yml`.

---

## Appendix A — Bill of materials (cheap → optional)

| Item | Why | Cost | Required? |
|---|---|---|---|
| RK3588 board (Rock 5B+ / OPi 5+) | the DUT | $$ | **yes** |
| USB-C/OTG cable | maskrom flashing | $ | **yes** |
| USB-UART adapter (CP210x/FTDI) | serial console | $ | **yes** |
| Linux host (NUC/mini-PC) | runs the GH runner | $$ | **yes** |
| **USB relay (1–2 ch)** | unattended power + recovery-button | ~$10 | **yes for unattended** |
| Smart PDU / local smart plug | rack-scale / high-draw power | $$ | optional (alt to relay) |
| eMMC module / SD card | flash target | $ | **yes** |

The **cheap** path is fully sufficient: USB-OTG flash + USB-UART serial + a ~$10
USB relay. The PDU is an **optional** upgrade for multi-board labs. (MUST-NOT:
don't require expensive flash hardware — maskrom over a plain USB cable is the
baseline.)
