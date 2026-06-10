# CeraLive v2 — Development Loop (`dev-push`)

Push a code change to a running device in **under 2 minutes**, without reflashing.

---

## Full image build (canonical containerized path)

A full device image is built with:

```bash
./v2/build <board>            # e.g. ./v2/build rock-5b-plus
DRY_RUN=1 ./v2/build <board>  # resolve + fetch + builder plan only (no build)
```

**The build runs `mkosi` inside a pinned container by default — this is the
canonical path.** You do **not** need `mkosi`, a Debian host, or the
`debian-archive-keyring` installed: only a container runtime.

| Aspect | Behaviour |
|---|---|
| Default builder | Containerized — runs in a pinned **Debian trixie** image |
| Container runtime | Auto-detected: **Docker**, else **Podman** (either works, same plan) |
| Builder image | Baked from [`v2/ci/Dockerfile`](../ci/Dockerfile): **mkosi 26** (the `v2/.mkosi-version` pin) on trixie's **Python 3.13** (satisfies mkosi 26's ≥ 3.12 floor). Auto-built (`ceralive-mkosi-builder:26`) on first use when absent. |
| Cross-arch | arm64 builds ride the host kernel's `qemu-user-static` binfmt (F-flag); the image bakes `qemu-user-static` + `binfmt-support`. |
| No runtime present | Build stops with a clear, actionable error (install docker/podman, or use `--native`) — never a stack trace. |

### Native build (opt-in)

To build with the **host's** `mkosi` instead of the container (e.g. a Debian host
that already has mkosi ≥ 26 and the keyring):

```bash
./v2/build <board> --native        # flag form
MKOSI_NATIVE=1 ./v2/build <board>  # env form (equivalent)
```

Native requires `mkosi` (≥ the `.mkosi-version` pin, needs Python ≥ 3.12) and
`/usr/share/keyrings/debian-archive-keyring.gpg` on the host.

### Overriding the builder image

Pin your own builder image (registry or locally-built) — it is used verbatim and
never auto-built; it **must** bake `mkosi 26`:

```bash
MKOSI_BUILDER_IMAGE=myregistry/ceralive-mkosi:26 ./v2/build <board>
```

Rebuild the canonical image by hand if needed:

```bash
docker build -t ceralive-mkosi-builder:26 -f v2/ci/Dockerfile v2/ci
# or: podman build -t ceralive-mkosi-builder:26 -f v2/ci/Dockerfile v2/ci
```

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
DRY_RUN=1 ./v2/build rock-5b-plus 2>&1 \
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
| **Ubuntu/Debian** | container *(or `--native`)* | ✅ **yes** (CI runner) | `./v2/build rock-5b-plus` |
| **Fedora/RHEL** | container (Podman/Docker) | ⚠️ documented, **not CI-verified** | `./v2/build rock-5b-plus` |
| **Arch Linux** | container (Docker/Podman) | ⚠️ documented, **not CI-verified**¹ | `./v2/build rock-5b-plus` |
| **macOS Apple Silicon** | container only | ⚠️ documented, **not CI-verified** | `./v2/build rock-5b-plus` |
| **WSL2** | container *(native possible)* | ⚠️ documented, **not CI-verified** | `./v2/build rock-5b-plus` |

¹ Arch was the **live spike host** for the loop-free assembly proof in T16
(`host-support.md`), so its assembly primitives are exercised — but no CI runner
re-runs them on every push, so it is marked *not CI-verified* for the build-plan
gate, like the other non-Ubuntu hosts.

**Ubuntu/Debian — full container build (CI-proven).**
```bash
sudo apt-get install -y qemu-user-static binfmt-support   # arm64 emulation, F-flag
grep -A2 '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64  # confirm 'F' (fix-binary)
./v2/build rock-5b-plus
```

**Fedora/RHEL — Podman path.** SELinux relabels the repo bind-mount; if you hit
`Permission denied` on `/work`, see the SELinux workaround in the Fedora/RHEL
section of [`host-support.md`](host-support.md).
```bash
sudo dnf install -y qemu-user-static podman   # qemu-user-static pulls binfmt
sudo systemctl restart systemd-binfmt
./v2/build rock-5b-plus
```
> *Documented, not CI-verified* — same kernel-feature surface as Ubuntu/Arch, but
> no Fedora runner exists. The SELinux caveat is the one thing to watch.

**Arch Linux — Docker/Podman path.**
```bash
sudo pacman -S docker                               # or: podman
sudo pacman -S qemu-user-static qemu-user-static-binfmt
sudo systemctl restart systemd-binfmt
grep flags /proc/sys/fs/binfmt_misc/qemu-aarch64    # must contain 'F'
./v2/build rock-5b-plus
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
./v2/build rock-5b-plus
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
./v2/build rock-5b-plus
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
| Sibling checkout layout | `ceralive/ceracoder/`, `ceralive/srtla/`, `ceralive/image-building-pipeline/` all siblings |

For **ceracoder** and **srtla** source builds, the build host arch must be **arm64** (aarch64). On an x86 host, use `--from-deb` with a pre-built arm64 `.deb` instead (see below).

---

## Quickstart

```bash
# From the image-building-pipeline/v2/ directory:
./dev-push 192.168.1.42

# Push only ceracoder:
./dev-push 192.168.1.42 ceracoder

# Push only srtla:
./dev-push 192.168.1.42 srtla

# Push both (default):
./dev-push 192.168.1.42 ceracoder srtla
```

That's it. The script builds, rsyncs, refreshes, and restarts — then prints a timing breakdown.

---

## What it does (4 steps)

```
1. BUILD   compile ceracoder/srtla from source → package into <app>.raw (squashfs sysext)
2. RSYNC   copy <app>.raw to root@<board>:/var/lib/extensions/
3. REFRESH systemd-sysext refresh          (re-merge /usr+/opt overlay on-device)
4. RESTART systemctl restart ceralive.service
```

**Why restart `ceralive.service`?** CeraUI's backend is a single Bun binary with **in-process native FFI bindings** to ceracoder and srtla. A sysext refresh swaps the binaries on disk, but the running process keeps the old FFI handles until it restarts. Restarting only a hypothetical `ceracoder.service` would not reload those bindings. The full service restart is non-negotiable.

**What if the push fails?** The `&&` between `refresh` and `restart` is load-bearing. If `systemd-sysext refresh` rejects a corrupt or mismatched `.raw` (wrong `extension-release`, bad squashfs, arch mismatch), the restart **never runs**. The previously-merged extension stays active and `ceralive.service` keeps streaming on the old version. A bad push is a no-op + a loud error — never an outage.

---

## Using pre-built `.deb`s (cross-arch or CI artifacts)

If you're on an x86 host or have CI-produced arm64 `.deb`s:

```bash
# Point at a directory containing ceracoder_*.deb and/or srtla_*.deb
./dev-push --from-deb /path/to/debs 192.168.1.42

# Example: use the debs staged by the orchestrator
./dev-push --from-deb v2/mkosi/build/debs 192.168.1.42
```

The `--from-deb` path extracts the `.deb` payload and packages it into the sysext — identical to what the prod builder does.

---

## Environment knobs

All optional. Set in your shell or prefix the command.

| Variable | Default | Purpose |
|---|---|---|
| `DRY_RUN=1` | `0` | Print rsync/ssh commands instead of running them |
| `SSH_USER` | `root` | Remote user |
| `SSH_OPTS` | _(none)_ | Extra SSH flags, e.g. `SSH_OPTS="-p 2222"` |
| `RSYNC_OPTS` | _(none)_ | Extra rsync flags |
| `DEV_PUSH_BUDGET` | `120` | Budget in seconds; `0` = don't enforce |
| `REMOTE_EXT_DIR` | `/var/lib/extensions` | Where extensions live on the device |
| `CERACODER_SRC` | `../../ceracoder` | Override ceracoder source path |
| `SRTLA_SRC` | `../../srtla` | Override srtla source path |
| `CERACODER_BUILD_CMD` | `make -C <src> ceracoder` | Override ceracoder build command |
| `SRTLA_BUILD_CMD` | `cmake --build <src>/build ...` | Override srtla build command |
| `APP_BACKEND` | `sysext` | App-layer backend (`sysext` or `appfs`) |

Examples:

```bash
# Non-standard SSH port
SSH_OPTS="-p 2222" ./dev-push 192.168.1.42

# Dry run — see what would happen without touching the board
DRY_RUN=1 ./dev-push 192.168.1.42

# Relax the time budget for a slow network
DEV_PUSH_BUDGET=180 ./dev-push 192.168.1.42
```

---

## What is and isn't updated

| Updated by `dev-push` | NOT updated (requires RAUC OS update) |
|---|---|
| `ceracoder` binary (`/usr/bin/ceracoder`) | `libsrt` (lives in the OS runtime layer) |
| `srtla_send` / `srtla_rec` binaries | GStreamer plugins / Rockchip MPP |
| Any file under `/usr` or `/opt` in the sysext | Kernel / U-Boot / firmware |
| | System config (`/etc`), udev rules |
| | CeraUI (uses appfs backend, not sysext) |

**User config is never touched.** CeraUI's mutable state (`config.json`, auth tokens, WiFi credentials, etc.) lives on the separate `/data` partition and is never part of a sysext. Restarting `ceralive.service` re-reads it from `/data/ceralive/`.

---

## Updating CeraUI

CeraUI writes to `/etc` and `/var/www`, so it uses the **appfs** backend rather than sysext. The dev loop for CeraUI is different:

```bash
# CeraUI is installed as a .deb into the appfs slot — not via sysext.
# For now, CeraUI changes require a full image rebuild + reflash,
# or a manual dpkg install over SSH:
ssh root@<board> 'dpkg -i /tmp/ceraui_*.deb && systemctl restart ceralive.service'
```

A faster CeraUI dev loop (rsync of the Bun binary + assets) is possible once CeraUI is refactored to be sysext-ready — tracked in `v2/docs/deferred-ceraui-sysext.md`.

---

## Typical session

```
$ ./dev-push 192.168.1.42
[12:34:01] INFO  === dev-push → root@192.168.1.42 | apps: ceracoder srtla | budget: 120s ===
[12:34:01] INFO  stage(ceracoder): building (make -C /home/user/ceralive/ceracoder ceracoder)
[12:34:18] INFO  stage(srtla): building (cmake --build /home/user/ceralive/srtla/build ...)
[12:34:31] INFO  sysext: building squashfs /tmp/tmp.XYZ/ceracoder.raw for 'ceracoder'
[12:34:32] INFO  sysext: building squashfs /tmp/tmp.XYZ/srtla.raw for 'srtla'
[12:34:32] SUCCESS  built ceracoder sysext: /tmp/tmp.XYZ/ceracoder.raw (1.2M)
[12:34:32] SUCCESS  built srtla sysext: /tmp/tmp.XYZ/srtla.raw (420K)
[12:34:32] INFO  rsync ceracoder.raw → root@192.168.1.42:/var/lib/extensions/
[12:34:34] INFO  rsync srtla.raw → root@192.168.1.42:/var/lib/extensions/
[12:34:34] INFO  remote: systemd-sysext refresh && systemctl restart ceralive.service
[12:34:37] INFO  ---------------------------------------------
[12:34:37] INFO  TIMING  build=30.12s  rsync=2.01s  remote=3.44s
[12:34:37] INFO  TIMING  total=35.57s  (budget 120s)
[12:34:37] INFO  ---------------------------------------------
[12:34:37] SUCCESS  dev-push complete in 35.57s — ceracoder srtla live on 192.168.1.42 (ceralive.service restarted, FFI reloaded)
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

The `.raw` carries `ID=debian VERSION_ID=12`. If the device is running a different OS version, the merge is rejected. Check:
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
- Slow WiFi link → use Ethernet or `RSYNC_OPTS="--compress"` for large binaries
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
