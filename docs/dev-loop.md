# CeraLive v2 — Development Loop (`dev-push`)

Push a code change to a running device in **under 2 minutes**, without reflashing.

---

## Full image build (canonical containerized path)

A full device image is built with:

```bash
./build <board>            # e.g. ./build rock-5b-plus
DRY_RUN=1 ./build <board>  # resolve + fetch + builder plan only (no build)
```

**The build runs `mkosi` inside a pinned container by default — this is the
canonical path.** You do **not** need `mkosi`, a Debian host, or the
`debian-archive-keyring` installed: only a container runtime.

| Aspect | Behaviour |
|---|---|
| Default builder | Containerized — runs in a pinned **Debian trixie** image |
| Container runtime | Auto-detected: **Docker**, else **Podman** (either works, same plan) |
| Builder image | Baked from [`ci/Dockerfile`](../ci/Dockerfile): **mkosi 26** (the `.mkosi-version` pin) on trixie's **Python 3.13** (satisfies mkosi 26's ≥ 3.12 floor). Auto-built on first use when absent, under a CONTENT-ADDRESSED tag `ceralive-mkosi-builder:26-<12 hex of sha256(ci/Dockerfile)>` — so editing that Dockerfile produces a new tag and is actually rebuilt, instead of being masked forever by the "image already present" short-circuit. Pin your own with `MKOSI_BUILDER_IMAGE=` and it is honoured verbatim (never auto-built). |
| Cross-arch | arm64 builds ride the host kernel's `qemu-user-static` binfmt (F-flag); the image bakes `qemu-user-static` + `binfmt-support`. |
| No runtime present | Build stops with a clear, actionable error (install docker/podman, or use `--native`) — never a stack trace. |

### Native build (opt-in)

To build with the **host's** `mkosi` instead of the container (e.g. a Debian host
that already has mkosi ≥ 26 and the keyring):

```bash
./build <board> --native        # flag form
MKOSI_NATIVE=1 ./build <board>  # env form (equivalent)
```

Native requires `mkosi` (≥ the `.mkosi-version` pin, needs Python ≥ 3.12) and
`/usr/share/keyrings/debian-archive-keyring.gpg` on the host.

### Overriding the builder image

Pin your own builder image (registry or locally-built) — it is used verbatim and
never auto-built; it **must** bake `mkosi 26`:

```bash
MKOSI_BUILDER_IMAGE=myregistry/ceralive-mkosi:26 ./build <board>
```

Rebuild the canonical image by hand if needed:

```bash
docker build -t ceralive-mkosi-builder:26 -f ci/Dockerfile ci
# or: podman build -t ceralive-mkosi-builder:26 -f ci/Dockerfile ci
```

### Debug image (`CERALIVE_DEBUG_IMAGE=1`) — bench ONLY, adds the tooling delta

```bash
CERALIVE_DEBUG_IMAGE=1 \
CERALIVE_DEBUG_PASSWORD_HASH='<crypt(3) SHA-512 hash>' \
  ./build rock-5b-plus
```

This is the variant seam. It installs `manifests/packages/development.delta.list`
on top of the production package set — `python3`, `strace`, `tcpdump` and the
fifteen `debug-toolset` diagnostics — and keeps the access behaviour it has always
had: the injected hash unlocks `ceralive`, `ssh.service` is enabled by default, and
`/etc/ceralive/debug-image` is baked as the marker.

The flag is validated **before** the package set is resolved, so a value other than
`0`/`1`, a hash without the flag, or the flag without a hash all fail the build
rather than producing a mislabelled image. With the flag unset the resolved package
set is byte-identical to production.

Orthogonal to the PARTLABEL overlay below — combine them for a bench microSD that
also carries the tools:

```bash
CERALIVE_BENCH_LABELS=1 CERALIVE_DEBUG_IMAGE=1 \
CERALIVE_DEBUG_PASSWORD_HASH='<hash>' ./build rock-5b-plus
```

**Never on a release path.** A debug image carries an unlocked password, an enabled
sshd and a full diagnostic toolchain; no publish job sets the flag, and the build
logs a loud warning while it is active. For diagnostics on a *production* image use
the signed `debug-toolset` sysext add-on instead — same toolbox, installed at
runtime, no reflash. See the README's "Production vs Debug Image Variants".

### Bench PARTLABEL overlay (`CERALIVE_BENCH_LABELS=1`) — bench media ONLY

```bash
CERALIVE_BENCH_LABELS=1 ./build rock-5b-plus     # a bench-only microSD image
```

A bench microSD is booted on a board whose **eMMC is already flashed with a
production image**, and the frozen contract selects every slot and mount by
`PARTLABEL` ([`docs/partition-contract.md`](../../docs/partition-contract.md) §3).
Two media carrying the same `boot` / `rootfs_a` / `rootfs_b` / `data` labels make
`PARTLABEL=rootfs_a` genuinely ambiguous on the running kernel — which medium you
mounted becomes a race.

With the flag set the build lays `xboot` / `xrootfs_a` / `xrootfs_b` / `xdata`
instead, and the *same* names are written everywhere the running system looks
them up, so a collision is structurally impossible:

| Reference site | File |
|---|---|
| GPT partition labels | `lib/assemble-disk.sh` (p1 `sgdisk -c`, staged `repart/*.conf` `Label=`) |
| Contract verifier | `lib/verify-disk.sh` |
| `/boot` fstab entry + RAUC `system.conf` slot devices | `mkosi/platform/boot/install-boot.sh` |
| Compiled U-Boot selectors (`boot.scr`, `recovery.scr`) | same, via `setenv cera_root` |
| `/data` fstab entry | `mkosi/customize/postinst-lib.sh` |
| Fallback RAUC `system.conf` (x86 / parity builds) | `mkosi/customize/rauc-setup.sh` + its runtime-postinst twin |

It also seeds distinct ext4 filesystem UUIDs for the rootfs slots (those are
derived from the slot label), so `/dev/disk/by-uuid` cannot collide either.

Rules:

- **Bench only.** Never set it on a release path — no `release.yml` job, no apt/R2
  publish, no fleet artifact. The build logs a loud warning while it is active.
- **Sizes, roles and geometry are untouched.** This is additive tooling behaviour
  on top of the frozen contract, *not* a contract change. `partition-contract.md`
  is unchanged and stays frozen.
- **Unset is the default and is byte-identical to not having the flag at all** —
  pinned by the committed pre-overlay GPT fixtures in
  `tests/fixtures/gpt-baseline/` and the guard tests in
  `tests/bench-partlabels.bats`.
- A bench image deliberately **fails** `tests/preflash-verify.sh`, which asserts
  the production label set — so it can never be flashed to a board's eMMC by the
  release gate.
- **A hardware-qualification candidate must STATE the mode.**
  `ci/build-hardware-candidates.sh` refuses to run without an explicit
  `--bench-labels 0|1` and exports `CERALIVE_BENCH_LABELS` from it, so a candidate
  can never inherit the value from a dispatch shell. See the section below.

### `--bench-labels` is mandatory on every hardware candidate (2026-08-10 incident)

`CERALIVE_BENCH_LABELS=1 ./build …` above is the hand-run form, and its
default-to-off behaviour in `lib/orchestrate.sh` is correct — a direct build is a
production build unless you say otherwise. **That default is exactly what must
never apply to a candidate destined for a bench board**, and until this was fixed
it silently could:

```bash
# the ONLY supported form — the flag has no default and no ambient fallback
ci/build-hardware-candidates.sh --only rock-edge-test \
  --trust-verdict verdict.json --signing-env sign.env --debug-env debug.env \
  --evidence evidence/ --bench-labels 1
```

**What happened.** The candidate builder never threaded `CERALIVE_BENCH_LABELS`
through to its `./build` invocation, so the value came from whatever the invoking
shell happened to export. Orchestrator dispatches are stateless and fresh, so the
flag was present in some dispatches and absent in others. One `rock-edge-test`
debug candidate was consequently built with the **frozen production** PARTLABEL
set and written to the bench microSD of a Rock 5B+ that also carries an onboard
eMMC holding an unrelated, plain-labelled image.

**What it cost.** U-Boot resolved `root=PARTLABEL=xrootfs_a` off the microSD it
was booting from, so the board came up looking healthy — but the candidate's own
`/etc/fstab` asked for plain `boot` and `data`, which on that rig resolve to the
**eMMC**. Every `/boot` operation, including `rauc status mark-bad` and the
`boot_state.txt` it persists through, therefore landed on the wrong physical
device. The microSD's real A/B state was never updated, U-Boot correctly re-picked
the same slot on the next boot, and the board needed a careful manual recovery
(mounting the microSD's `xboot` by hand and rewriting the boot state).

**Why a required flag rather than a documented convention.** The wrong value here
produces a *plausible* artifact: it builds, boots, and passes every other gate.
The failure only appears as a recovery operation silently addressing another
medium. A value that lives in an ambient environment is also invisible to anyone
reviewing the dispatch afterwards, which is why the flag must appear in argv. The
script additionally logs `CERALIVE_BENCH_LABELS=<n> (bench PARTLABEL overlay: …)`
before each candidate build, and records `bench_labels` + `partlabel_set` in that
candidate's artifact tuple, so which mode built a given artifact is answerable
from the evidence trail alone rather than from memory of the dispatch.

Guard: `tests/hardware-candidate-bench-labels.test.sh` (refusal even with
`CERALIVE_BENCH_LABELS` already exported, both values observed in the environment
`./build` actually receives, and both tuple fields), plus the tool's own
`--self-test`.

---

## Cross-host build

The **container path is the canonical build** and is meant to run the same on
any host with a working container runtime + arm64 binfmt. The deep portability
analysis (loop-device reality, SELinux, binfmt survival) lives in
[`host-support.md`](host-support.md); this section is the **command crib** plus
the **sha256 parity check** you run to prove your host resolves the *same build*
CI does.

### What "parity" means here

CI (`v2-ci.yml` → `build-matrix`) can't run the real privileged `mkosi` build —
it runs `DRY_RUN=1`, which resolves the manifest and emits the **mkosi build
plan** without touching the network or a board. So the cross-host gate hashes the
**normalized build plan** (absolute checkout path stripped to `<REPO>`), not a
real image:

> Same normalized-plan sha256 on two hosts ⇒ identical `mkosi` invocation ⇒,
> combined with **T14's deterministic builds** (`SOURCE_DATE_EPOCH`-clamped,
> bit-identical `.raucb`), a **bit-identical image**.

CI proves the *plan* half on its one runner (Linux/x86_64) and asserts the digest
is reproducible across a rebuild; T14 proves the *determinism* half with a real
double-build. Neither half is claimed beyond what is actually reproduced.

Reproduce the CI sidecar on your host (run from `image-building-pipeline/`):

```bash
repo="$PWD"
DRY_RUN=1 ./build rock-5b-plus 2>&1 \
  | grep -F 'would build with:' \
  | sed -E 's/^.*would build with: //' \
  | sed "s#${repo}#<REPO>#g" \
  | sha256sum
# Compare this digest to the host-<uname>.sha256 artifact CI uploaded
# (job: build dry-run + host sha256). Equal ⇒ your host resolves CI's plan.
```

### Per-host commands

| Host | Build mode | CI-verified? | One-liner (after runtime + binfmt set up) |
|---|---|---|---|
| **Ubuntu/Debian** | container *(or `--native`)* | ✅ **yes** (CI runner) | `./build rock-5b-plus` |
| **Fedora/RHEL** | container (Podman/Docker) | ⚠️ documented, **not CI-verified** | `./build rock-5b-plus` |
| **Arch Linux** | container (Docker/Podman) | ⚠️ documented, **not CI-verified**¹ | `./build rock-5b-plus` |
| **macOS Apple Silicon** | container only | ⚠️ documented, **not CI-verified** | `./build rock-5b-plus` |
| **WSL2** | container *(native possible)* | ⚠️ documented, **not CI-verified** | `./build rock-5b-plus` |

¹ Arch was the **live spike host** for the loop-free assembly proof in T16
(`host-support.md`), so its assembly primitives are exercised — but no CI runner
re-runs them on every push, so it is marked *not CI-verified* for the build-plan
gate, like the other non-Ubuntu hosts.

**Ubuntu/Debian — full container build (CI-proven).**
```bash
sudo apt-get install -y qemu-user-static binfmt-support   # arm64 emulation, F-flag
grep -A2 '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64  # confirm 'F' (fix-binary)
./build rock-5b-plus
```

**Fedora/RHEL — Podman path.** SELinux relabels the repo bind-mount; if you hit
`Permission denied` on `/work`, see the SELinux workaround in the Fedora/RHEL
section of [`host-support.md`](host-support.md).
```bash
sudo dnf install -y qemu-user-static podman   # qemu-user-static pulls binfmt
sudo systemctl restart systemd-binfmt
./build rock-5b-plus
```
> *Documented, not CI-verified* — same kernel-feature surface as Ubuntu/Arch, but
> no Fedora runner exists. The SELinux caveat is the one thing to watch.

**Arch Linux — Docker/Podman path.**
```bash
sudo pacman -S docker                               # or: podman
sudo pacman -S qemu-user-static qemu-user-static-binfmt
sudo systemctl restart systemd-binfmt
grep flags /proc/sys/fs/binfmt_misc/qemu-aarch64    # must contain 'F'
./build rock-5b-plus
```
> *Documented, not CI-verified* — assembly primitives were live-tested here in T16
> (loop-free, privileged **and** unprivileged), but no Arch runner gates pushes.
> Ensure the binfmt handler carries the **F** flag or it won't fire in-container.

**macOS Apple Silicon — Docker Desktop required, container-only.** Per T16, the
Stage-4 disk-assembly is **loop-free and rootless** (`systemd-repart --offline`,
`mkfs.ext4 -d`, `mcopy`, `dd`), so the well-known *"Docker Desktop doesn't expose
`/dev/loopNpX`"* limitation **does not block CeraLive assembly**. arm64 is the
*native* VM arch, so the default board builds run with **no qemu emulation**.
```bash
# Docker Desktop ≥ 4.x, VirtioFS on, repo's parent in shared paths, ≥4 GB/≥20 GB VM.
./build rock-5b-plus
```
> *Documented, not CI-verified* — **no macOS host in the dev/CI environment.**
> Expected to work (native arm64 + loop-free assembly) but **not reproduced on
> hardware**; treat as container-only and verify the sidecar digest by hand.
> There is **no `--native` path** (macOS is not Linux). See the macOS section of
> [`host-support.md`](host-support.md).

**WSL2 — container path works; kernel requirement.** Per T16, the WSL2 kernel
ships `/dev/loop0..7` + overlay/mount built-in since **≥ 5.15** (e.g.
`5.15.90.1-microsoft-standard-WSL2`), so it is much closer to native Linux than
macOS. Use **WSL 2** (`wsl --set-default-version 2`), **kernel ≥ 5.15**.
```bash
# Container build (x86 Windows host emulating arm64 via the qemu F-flag handler):
sudo apt-get install -y qemu-user-static binfmt-support
grep flags /proc/sys/fs/binfmt_misc/qemu-aarch64   # confirm 'F'
./build rock-5b-plus
```
> *Documented, not CI-verified* — **no Windows/WSL2 host in the environment.** The
> one real gotcha is the arm64 binfmt handler being wiped by
> `systemd-binfmt`/WSLInterop; keep it alive (`protectBinfmt=false` in
> `/etc/wsl.conf`, or a `zz-qemu-aarch64.conf` pinned last). Full caveat: the
> WSL2 section of [`host-support.md`](host-support.md).

---

## Prerequisites

| Requirement | Notes |
|---|---|
| SSH access to the board | `root@<board-ip>` (passwordless key recommended) |
| `rsync` on the build host | `pacman -S rsync` / `apt install rsync` |
| `mksquashfs` on the build host | `squashfs-tools` package |
| Board running a v2 image | Must have `systemd-sysext` + `ceralive.service` |
| Sibling checkout layout | `ceralive/srtla/`, `ceralive/image-building-pipeline/` all siblings |

For **srtla** source builds, the build host arch must be **arm64** (aarch64). On an x86 host, use `--from-deb` with a pre-built arm64 `.deb` instead (see below).

---

## Quickstart

```bash
# From the image-building-pipeline/ directory:
./dev-push 192.168.1.42

# Push srtla explicitly:
./dev-push 192.168.1.42 srtla

# Push only srtla:
./dev-push 192.168.1.42 srtla

# Push both (default):
./dev-push 192.168.1.42 srtla
```

That's it. The script builds, rsyncs, refreshes, and restarts — then prints a timing breakdown.

---

## What it does (4 steps)

```
1. BUILD   compile srtla from source → package into <app>.raw (squashfs sysext)
2. RSYNC   copy <app>.raw to root@<board>:/var/lib/extensions/
3. REFRESH systemd-sysext refresh          (re-merge /usr+/opt overlay on-device)
4. RESTART systemctl restart ceralive.service
```

**Why restart `ceralive.service`?** CeraUI's backend is a single Bun binary with **in-process native FFI bindings** to srtla. A sysext refresh swaps the binaries on disk, but the running process keeps the old FFI handles until it restarts. Restarting only a hypothetical `srtla.service` would not reload those bindings. The full service restart is non-negotiable.

**What if the push fails?** The `&&` between `refresh` and `restart` is load-bearing. If `systemd-sysext refresh` rejects a corrupt or mismatched `.raw` (wrong `extension-release`, bad squashfs, arch mismatch), the restart **never runs**. The previously-merged extension stays active and `ceralive.service` keeps streaming on the old version. A bad push is a no-op + a loud error — never an outage.

---

## Using pre-built `.deb`s (cross-arch or CI artifacts)

If you're on an x86 host or have CI-produced arm64 `.deb`s:

```bash
# Point at a directory containing srtla_*.deb
./dev-push --from-deb /path/to/debs 192.168.1.42

# Example: use the debs staged by the orchestrator
./dev-push --from-deb mkosi/build/debs 192.168.1.42
```

The `--from-deb` path extracts the `.deb` payload and packages it into the sysext — identical to what the prod builder does.

---

## Environment knobs

All optional. Set in your shell or prefix the command.

| Variable | Default | Purpose |
|---|---|---|
| `DRY_RUN=1` | `0` | Print scp/ssh commands instead of running them |
| `SSH_USER` | `root` | Remote user |
| `SSH_IDENTITY_FILE` | _(none)_ | Explicit private key; also enables `IdentitiesOnly` |
| `SSH_PORT` | `22` | SSH port, mapped to `ssh -p` and `scp -P` |
| `SSH_KNOWN_HOSTS_FILE` | _(default OpenSSH path)_ | Explicit host-key file |
| `SSH_OPTS` | _(none)_ | Additional `ssh` flags |
| `RSYNC_OPTS` | _(none)_ | Additional `scp` flags (legacy variable name) |
| `DEV_PUSH_BUDGET` | `120` | Budget in seconds; `0` = don't enforce |
| `REMOTE_EXT_DIR` | `/var/lib/extensions` | Where extensions live on the device |
| `SRTLA_SRC` | required for srtla dev-push | Explicit source checkout path |
| `SRTLA_BUILD_CMD` | `cmake --build <src>/build ...` | Override srtla build command |
| `APP_BACKEND` | `sysext` | App-layer backend (`sysext` or `appfs`) |

Examples:

```bash
# Non-standard SSH port
SSH_PORT=2222 ./dev-push 192.168.1.42

# Dry run — see what would happen without touching the board
DRY_RUN=1 ./dev-push 192.168.1.42

# Relax the time budget for a slow network
DEV_PUSH_BUDGET=180 ./dev-push 192.168.1.42
```

---

## What is and isn't updated

| Updated by `dev-push` | NOT updated (requires RAUC OS update) |
|---|---|
| `srtla` binaries (`/usr/bin/srtla_{send,rec}`) | `libsrt` (lives in the OS runtime layer) |
| `srtla_send` / `srtla_rec` binaries | GStreamer plugins / Rockchip MPP |
| Any file under `/usr` or `/opt` in the sysext | Kernel / U-Boot / firmware |
| | System config (`/etc`), udev rules |
| | CeraUI (uses appfs backend, not sysext) |

**User config is never touched.** CeraUI's mutable state (`config.json`, auth tokens, WiFi credentials, etc.) lives on the separate `/data` partition and is never part of a sysext. Restarting `ceralive.service` re-reads it from `/data/ceralive/`.

**The kernel / U-Boot / firmware row in that table is ENFORCED, not just a
convention.** Every image `apt-mark hold`s its own kernel, DTB, board U-Boot and
firmware packages and ships a supplementary name+version apt pin, so an
`apt-get upgrade` on the device cannot replace them — the boot stack rides inside
the RAUC slot and changes only when a full-image bundle writes a new one. First-party
CeraLive packages (`cerastream`, `ceralive-device`, `srtla-send-rs`, …) are
deliberately **not** held and stay apt-updatable. RAUC itself does not consult dpkg
holds; each image bakes its own. Full contract, including the pin's documented
bypass limitation: [`kernel-freeze-contract.md`](kernel-freeze-contract.md).

---

## Updating CeraUI

CeraUI writes to `/etc` and `/var/www`, so it uses the **appfs** backend rather than sysext. The dev loop for CeraUI is different:

```bash
# CeraUI is installed as a .deb into the appfs slot — not via sysext.
# For now, CeraUI changes require a full image rebuild + reflash,
# or a manual dpkg install over SSH:
ssh root@<board> 'dpkg -i /tmp/ceraui_*.deb && systemctl restart ceralive.service'
```

A faster CeraUI dev loop (rsync of the Bun binary + assets) is possible once CeraUI is refactored to be sysext-ready — tracked in `docs/deferred-ceraui-sysext.md`.

---

## Typical session

```
$ ./dev-push 192.168.1.42
[12:34:01] INFO  === dev-push → root@192.168.1.42 | apps: srtla | budget: 120s ===
[12:34:18] INFO  stage(srtla): building (cmake --build /home/user/ceralive/srtla/build ...)
[12:34:32] INFO  sysext: building squashfs /tmp/tmp.XYZ/srtla.raw for 'srtla'
[12:34:32] SUCCESS  built srtla sysext: /tmp/tmp.XYZ/srtla.raw (420K)
[12:34:34] INFO  rsync srtla.raw → root@192.168.1.42:/var/lib/extensions/
[12:34:34] INFO  remote: systemd-sysext refresh && systemctl restart ceralive.service
[12:34:37] INFO  ---------------------------------------------
[12:34:37] INFO  TIMING  build=30.12s  rsync=2.01s  remote=3.44s
[12:34:37] INFO  TIMING  total=35.57s  (budget 120s)
[12:34:37] INFO  ---------------------------------------------
[12:34:37] SUCCESS  dev-push complete in 35.57s — srtla live on 192.168.1.42 (ceralive.service restarted, FFI reloaded)
```

---

## How it relates to production updates

The dev loop and the production OTA path use the **same artifact format**:

| Step | Dev loop | Production (RAUC + hawkBit) |
|---|---|---|
| Build | `dev-push` calls `build_app_layer` | CI calls `build_app_layer` |
| Artifact | `<app>.raw` squashfs sysext | Same `<app>.raw`, signed + bundled into `.raucb` |
| Deliver | `rsync` over SSH | hawkBit DDI → `rauc-hawkbit-updater` downloads from R2 |
| Activate | `systemd-sysext refresh && systemctl restart ceralive.service` | Same, triggered post-RAUC-install by `ceralive-healthcheck.service` |

There is no dev-only artifact format. What you test with `dev-push` is exactly what ships.

---

## Troubleshooting

**`extension-release mismatch` / sysext not merging**

The `.raw` carries `ID=debian` plus the `OS_VERSION_ID` from [`manifests/target-release.env`](../manifests/target-release.env) (`13`). If the device is running a different OS version, the merge is rejected. Check:
```bash
ssh root@<board> 'cat /etc/os-release | grep -E "^(ID|VERSION_ID)"'
```
Override the release fields if needed:
```bash
SYSEXT_OS_VERSION_ID=13 ./dev-push 192.168.1.42
```

**`ceralive.service` fails to restart after push**

The new binary has a runtime error. Check the journal:
```bash
ssh root@<board> 'journalctl -u ceralive.service -n 50'
```
The previous sysext is still merged (the restart failed, not the refresh). Fix the code and re-push.

**Push is over budget**

The 120s budget is enforced at the end. Common causes:
- Slow WiFi link → use Ethernet or `RSYNC_OPTS="-C"` for large binaries
- Cold build (no incremental make cache) → warm up with one build first
- Large binary → check for debug symbols (`strip` the binary before packaging)

**`mksquashfs: command not found`**

Install `squashfs-tools`:
```bash
# Debian/Ubuntu
apt install squashfs-tools
# Arch
pacman -S squashfs-tools
```

**`rsync: command not found`**

```bash
apt install rsync   # or: pacman -S rsync
```
