# Self-Hosted RK3588 Hardware Runner — Setup & Safety Guide

> **Task 37 (Stage 6).** A self-hosted GitHub Actions runner with a **physical
> RK3588 board attached** (USB flash + serial, starting in Maskrom) so the real-HW
> acceptance gates — [`v2/tests/realhw-smoke.sh`](../tests/realhw-smoke.sh) (LIVE
> mode) and [`v2/tests/rauc-rollback.sh`](../tests/rauc-rollback.sh) (LIVE mode)
> — runs only for a candidate-bound release, never on every PR.
>
> The reusable job that consumes this runner is
> [`.github/workflows/realhw-job.yml`](../../.github/workflows/realhw-job.yml). Regular offline CI stays on
> `ubuntu-latest` ([`.github/workflows/v2-ci.yml`](../../.github/workflows/v2-ci.yml));
> **only** the hardware jobs target this runner via
> `runs-on: [self-hosted, ceralive-rk3588, rock-5b-plus]`.

---

## 0. Why a self-hosted runner at all

The two LIVE gates need to **boot a real board and talk to it**:

| Harness | What LIVE mode needs from the runner |
|---|---|
| `realhw-smoke.sh` (LIVE) | `BOARD_IP` reachable over SSH (`root@…`, restricted run-local key auth); asserts login, `ceralive`/`ceraui.service` active, `cerastream`/`srtla_send`/`srtla_rec` present + `--version`, manifest-quirk HW (`/dev/video*`, modem, udev rule), and a full `parity-check.sh` over an rsync of the live rootfs. |
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
  candidate-bound release jobs.
- **x86_64** strongly preferred (mkosi/docker tooling, `rkdeveloptool` apt
  package, GH runner are all first-class on amd64).
- ≥ 4 GB RAM, ≥ 40 GB free disk (build artifacts + image staging + runner work
  dir). Candidate verification uses one private image-sized scratch object at a
  time: first the immutable flash snapshot, then the exact media readback. It
  never retains both scratch images simultaneously.
- Outbound HTTPS to `github.com` / `api.github.com` / `*.actions.githubusercontent.com`
  (the runner long-polls GitHub; **no inbound** port needs opening).

### 1.2 Attached Rock 5B+ fixture

- **Radxa Rock 5B+ only.** This release workflow builds a Rock 5B+ image and
  carries its pinned Radxa loader; other RK3588 boards use separate validation.
- **USB-OTG / Type-C** cable from the board's OTG port to a host USB port
  (used for maskrom-mode flashing — section 4).
- **USB-UART (serial)** adapter on the board's debug UART → host
  `/dev/ttyUSB0` or `/dev/ttyACM0` (section 5). RK3588 debug UART is **ttyS2 @
  1500000 baud** on-device (`family rk3588.yaml: serial_console: ttyS2:1500000`).
- **Network**: board on the same LAN as the host, with a **stable IP** (DHCP
  reservation by MAC, or static). This is the `BOARD_IP` the LIVE harnesses use.
- **Starting state**: the release job accepts the board only when it already
  enumerates as exactly one Rockchip target whose line ends in `Maskrom`. A relay is optional
  recovery equipment, not a workflow input.
- **eMMC** is the whole-media flash target. SD boot is not accepted by this gate.

### 1.3 Host packages

```bash
sudo apt-get update
sudo apt-get install -y \
  rkdeveloptool android-tools-adb minicom screen \
  openssh-client openssl rsync xz-utils gdisk util-linux \
  device-tree-compiler u-boot-tools
```

`device-tree-compiler` supplies `fdtget`/`fdtput`, and `u-boot-tools` supplies
`dumpimage`; the offline preflash gate and its blocking adversarial contract require
them to bound and hash-check U-Boot FIT payloads before any USB operation.

> `rkdeveloptool` ships in Ubuntu 22.04+ `universe`. If your distro lacks it,
> build that exact tool from source (`github.com/rockchip-linux/rkdeveloptool`).
> No alternate flasher is accepted by the production gate (section 4.3).

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
  --labels ceralive-rk3588,rock-5b-plus \
  --work _work \
  --unattended \
  --replace
```

- **Both labels are the contract.** Jobs select this runner with
  `runs-on: [self-hosted, ceralive-rk3588, rock-5b-plus]`. Anything else stays on
  `ubuntu-latest`.
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
  - Create the `image-hardware` environment with trusted required reviewers and
    deployment refs restricted to `release/**` and `v*`. The reusable job also
    rejects any caller other than this repository's first-attempt `release.yml`
    push before selecting the hardware runner.
  - In *Settings → Actions → General*, set **"Require approval for all outside
    collaborators"** (or "for all PRs") so fork PRs can't auto-run.
  - Prefer an **org-level** runner scoped to this one repo with
    `pull_request`-from-fork disabled.
- **No long-lived board credential on the box.** The workflow generates an
  Ed25519 identity under `RUNNER_TEMP`, provisions only its restricted and
  expiring public key over UART, revokes it after the suite, then removes the
  private key. The distinct host-local UART signing key authenticates that data
  envelope; only its public verification key is present in the image.
- **Ephemeral option:** add `--ephemeral` to `config.sh` so the runner
  de-registers after one job (re-register via a wrapper/systemd). Safer for
  public repos; costs a re-register per job.

---

## 3. Starting-state and reset contract

The workflow owns the transition from Maskrom to the candidate. Before assigning
the hardware label, place the Rock 5B+ in Maskrom and verify that
`rkdeveloptool ld` reports exactly one device with the trailing `Maskrom` mode token. The verifier fails
closed on zero, multiple, or loader-mode targets; it does not try to power-cycle
or recover an unexpected board state.

After exact write/readback verification, `rkdeveloptool rd` is the required
reset mechanism. Later A/B checks reboot through the authenticated OS. A relay or
smart PDU remains useful for lab recovery, but it is deliberately outside the
release workflow and no power-helper repository variable is defined.

---

## 4. Flash tooling

The **Maskrom/USB-OTG** path in sections 4.1–4.2 is the only production flash
path. It works even when the eMMC is empty or bricked and preserves the fixture
identity, cancellation, full-readback, and evidence contracts.

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

### 4.2 Verify the launch state

```bash
# 1. Confirm the SoC is in maskrom and the host sees it:
rkdeveloptool ld           # lists loader/maskrom devices; "Maskrom" = ready

# Do not issue db, wl, rl, or rd manually. Leave the fixture in Maskrom.
```

- `ld` is the only attended launch-state command. The protected `release.yml`
  workflow owns `db`, `rfi`, `rid`, `rci`, `wl`, `rl`, and `rd`, and records their
  candidate-bound evidence.
- `udev` rule so non-root can flash (file
  `/etc/udev/rules.d/99-rockchip-rk3588.rules`):
  ```
  # Rockchip RK3588 maskrom + loader (USB VID 2207)
  SUBSYSTEM=="usb", ATTR{idVendor}=="2207", MODE="0660", GROUP="plugdev"
  ```
  Then `sudo udevadm control --reload && sudo udevadm trigger`. `ghrunner` is in
  `plugdev`, so flashing needs no `sudo`.

### 4.3 No alternate production flasher

Do not use `upgrade_tool` or SSH-to-`dd` for a release candidate. Both bypass the
verifier's fixture identity, cancellation, full-readback, and evidence contracts.

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

### 5.2 Workflow-owned serial capture (non-interactive)

During a release hardware gate, `uart-provision-ssh.sh` is the **exclusive owner
of the serial device**. It locks the configured `CERALIVE_RK3588_SERIAL_DEV`,
interrupts U-Boot, performs the signed one-shot bootstrap, and records the full
session in `artifacts/first-boot-uart.log`. The workflow uploads that log even
when the board never reaches SSH.

Do not start `screen`, `minicom`, or a second background reader while the gate
is running. A competing reader can consume the boot nonce or prompt bytes and
make the signed bootstrap fail nondeterministically. Interactive access from
section 5.1 is permitted only when no hardware-gate process owns the port.

The runner service user reads the port through its `dialout` membership
(section 2.1), without `sudo`. Later RAUC reboot diagnostics use SSH and the
workflow artifacts; they do not open a second UART reader.

---

## 6. Ephemeral SSH access for the LIVE harnesses

No SSH private key or password is embedded in the image, stored as a GitHub
secret, or retained on the runner. `realhw-job.yml` generates one Ed25519 key in
`RUNNER_TEMP`. Before `rkdeveloptool rd`, `uart-provision-ssh.sh` interrupts
U-Boot and supplies the volatile kernel arguments
`ceralive.ci_uart=1 systemd.mask=serial-getty@ttyS2.service`. A non-restarting,
180-second UART oneshot emits a fresh 256-bit boot nonce, accepts one signed data
record bound to that nonce, verifies the candidate commit, and appends a root
public-key line constrained with `restrict` and an absolute `expiry-time`. It
records consumed nonces and a non-decreasing signed epoch floor on `/data`, so a
captured request cannot restore an expired key. It never exposes a shell.

Before loader transfer, the workflow normalizes the single Maskrom device's
VID/PID and stable `LocationID`, then requires its SHA-256 to match the approved
fixture repository variable. This identity is readable while the board remains
in Maskrom; `rci` is not. After the pinned loader starts, the workflow reads the
unique 16-byte SoC identity. The host signs the UART request with a mode-0600,
host-local Ed25519 key; before any USB operation, the verifier derives its public
key and requires it to equal the public key in the candidate source. The image
contains only that public verification key. The signed request includes the
device nonce, SoC identity, and a maximum one-hour expiry window, so the UART
service rejects a crossed cable or forged long-lived key before changing the
authorized-key store.
After SSH starts it requires those bytes to equal the output of
`/usr/local/sbin/ceralive-rockchip-chip-info`, which reads the first 16 bytes of
`/sys/bus/nvmem/devices/rockchip-otp0/nvmem`. The UART challenge therefore binds
the SSH endpoint, while the SoC identity binds that endpoint to the exact USB
device whose media was written and read back.

The key lives in `/data/ceralive/ssh/root_authorized_keys`, so it remains available
through each explicitly armed RAUC slot reboot in the same gate. Each arm is
one-use and consumed before sshd; an unarmed later boot revokes the CI key before
network access, independently of wall-clock expiry. After the suite,
`revoke-ephemeral-ssh.sh` removes the exact line and marker and emits a cleanup
receipt. An `always()` step deletes the local private key. If cleanup is
interrupted, OpenSSH enforces the expiry as a backstop.

---

## 7. Recovery from a bricked flash

A "brick" here means **the eMMC content won't boot** (bad image, interrupted
write, broken bootloader). Because **maskrom is ROM**, this is *always*
recoverable — there is no eMMC state that blocks maskrom entry. Runbook:

1. Use the board's physical Maskrom button and normal power input to return it
   to Maskrom; a relay is optional and is not part of the workflow contract.
2. Confirm exactly one approved fixture is detected:
   ```bash
   rkdeveloptool ld          # expect a "Maskrom" device line
   ```
3. Leave the board in Maskrom and push a newly named `release/**` branch at the
   exact approved commit. The workflow owns loader transfer, capacity preflight,
   fixture identity, write, full readback, UART-observed boot, and ephemeral SSH.
   Do not use a raw attended `wl`/`rd` sequence, because it bypasses candidate
   binding and leaves no cleanup receipt.

Recovery uses the same immutable path as release proof: approve an exact commit,
push a newly named `release/**` branch, and let the workflow build and verify a
fresh candidate before it touches the fixture. A retained raw image must not
bypass candidate binding, readback, UART identity, or cleanup evidence.

### Failure budget (don't thrash a board)

- **`timeout-minutes: 45`** per HW job (set in `realhw-job.yml`) — a hung board
  can't hold the runner forever.
- **Never rerun a hardware workflow run.** Both candidate jobs reject
  `github.run_attempt > 1` before touching the board. Diagnose the first run,
  land any repair, and use a newly named immutable proof branch.
- Always **capture serial + `rauc status` + `journalctl`** on failure as
  artifacts so the first failure is diagnosable.
- If a job leaves the board unbootable, return it to Maskrom deliberately before
  enabling the exact board label for the new proof run.

---

## 8. Wiring it to CI

The runner is consumed by [`.github/workflows/realhw-job.yml`](../../.github/workflows/realhw-job.yml),
a `workflow_call`-only workflow. The release caller must pass the immutable
artifact digest, raw SHA-256, bundle, keyring, loader filename/SHA-256, and
candidate commit. There is no
nightly, manual-current-image, or pull-request trigger.

Before adding the hardware labels, create the protected GitHub environment
`image-hardware`, require approval from trusted maintainers, and restrict its
deployment branches and tags to `release/**` and `v*`. The reusable job's
repository, event, caller-workflow, ref, and first-attempt condition is evaluated
before the self-hosted runner is selected; the environment protection is the
external authorization boundary.

Set these repository Actions variables only after the host checks below pass:

| Variable | Value |
|---|---|
| `CERALIVE_RK3588_BOARD_IP` | stable board address used after first boot |
| `CERALIVE_RK3588_SSH_PORT` | `22` |
| `CERALIVE_RK3588_SERIAL_DEV` | stable `/dev/serial/by-id/...` path, never a transient `ttyUSBN` |
| `CERALIVE_RK3588_MASKROM_ID_SHA256` | SHA-256 of `Vid=0x2207,Pid=0x350b,LocationID=<id> Maskrom` from the approved USB port |
| `CERALIVE_RK3588_UART_SIGNING_KEY` | absolute path to the mode-`0600` host-local Ed25519 private key |

SSH is fixed to `root`. The loader is candidate-bound, and there are no board
SSH-key, password, `RK3588_LOADER`, or power-helper variables.

Provision the already-approved signing private key through the host's secure
configuration channel as the runner service user; it is never stored in GitHub.
Its derived public key must be byte-equivalent to the verifier committed at
`v2/mkosi/runtime/ceralive-ci-uart-bootstrap-public.pem`:

```bash
chmod 0600 /absolute/host-local/key-directory/uart-bootstrap-ed25519.pem
cmp \
  <(openssl pkey -in /absolute/host-local/key-directory/uart-bootstrap-ed25519.pem -pubout -outform DER) \
  <(openssl pkey -pubin -in v2/mkosi/runtime/ceralive-ci-uart-bootstrap-public.pem -pubout -outform DER)
```

For rotation, remove the hardware labels, generate a new host-local private key,
commit only its derived public key in the path above, merge that change, then set
the runner variable to the new key and restore the labels after the comparison
passes. Never retain the old private key as a fallback.

### Trigger contract

| Trigger | Who | Runs on HW? |
|---|---|---|
| `pull_request` (normal) | everyone | **No** — offline `v2-ci.yml` on `ubuntu-latest` only |
| release branch or tag | `release.yml` builds and seals candidate | Yes |

Scarce, slow, physical hardware **must not** sit in the critical path of every
PR. Release validation proves real silicon against the exact candidate that can ship.

---

## 9. Quick verification checklist

Run these on the host as `ghrunner` before declaring the runner ready:

```bash
# runner is registered + Idle
sudo ~/actions-runner/svc.sh status

# maskrom path works and is the expected launch state
rkdeveloptool ld            # must print a Maskrom device

# stable UART is readable and writable; signing key is private to the runner user
test -r /dev/serial/by-id/<adapter-id> && test -w /dev/serial/by-id/<adapter-id>
test "$(stat -c %a /absolute/path/to/uart-bootstrap-ed25519.pem)" = 600
cmp \
  <(openssl pkey -in /absolute/path/to/uart-bootstrap-ed25519.pem -pubout -outform DER) \
  <(openssl pkey -pubin -in v2/mkosi/runtime/ceralive-ci-uart-bootstrap-public.pem -pubout -outform DER)
```

All green ⇒ the `ceralive-rk3588` runner is ready for `realhw-job.yml`.

---

## Appendix A — Bill of materials (cheap → optional)

| Item | Why | Cost | Required? |
|---|---|---|---|
| Rock 5B+ | the DUT | $$ | **yes** |
| USB-C/OTG cable | maskrom flashing | $ | **yes** |
| USB-UART adapter (CP210x/FTDI) | serial console | $ | **yes** |
| Linux host (NUC/mini-PC) | runs the GH runner | $$ | **yes** |
| **USB relay (1–2 ch)** | optional recovery power + recovery-button | ~$10 | optional |
| Smart PDU / local smart plug | rack-scale / high-draw power | $$ | optional (alt to relay) |
| eMMC module | flash target | $ | **yes** |

The **cheap** release path is USB-OTG flash + USB-UART serial; a relay and PDU
are optional recovery upgrades. (MUST-NOT:
don't require expensive flash hardware — maskrom over a plain USB cable is the
baseline.)
