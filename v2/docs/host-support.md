# CeraLive v2 — Build Host Support Matrix

Which developer/CI hosts can run the **containerized** image build, and what
each one needs. The focus is the Stage-4 **disk-assembly** path
([`v2/lib/assemble-disk.sh`](../lib/assemble-disk.sh)) — `systemd-repart`,
`mkfs.ext4 -d`, `mcopy`, `sgdisk`, `dd` — and the loop-device / mount / binfmt
support each host provides to a container.

> Evidence for every claim below — live container runs of the real assembly
> primitives, loop/binfmt probes, and the external citations — is in
> [`../../test-results/task-16-host-spikes.txt`](../../test-results/task-16-host-spikes.txt).

---

## TL;DR — the one fact that decides everything

**The disk-assembly stage is loop-free and rootless by design.** It never calls
`losetup`, never `mount(2)`s a partition, and never needs root. It operates on a
*flat* image file with offline tools and a single `dd`:

| Step | Tool | Loopback? | Root? | `assemble-disk.sh` |
|---|---|---|---|---|
| GPT pre-seed (16 MB gap) | `sgdisk` | no | no | `:302` |
| Partition + ext4 format | `systemd-repart --offline=yes` | no | no | `:311` |
| Populate `rootfs_a` | `mkfs.ext4 -d <dir>` | no | no | `:238` |
| Format boot region | `mkfs.vfat` | no | no | `:328` |
| Fill boot partition | `mcopy` (mtools) | no | no | `:166` |
| Land regions at offsets | `dd conv=notrunc` | no | no | `:244,330` |

This was proven on the live host by running steps [A]–[D] inside an
**unprivileged** `debian:trixie-slim` container with **no `/dev/loop*` present** —
all passed. So the famous *"Docker Desktop doesn't expose loop devices"*
limitation **does not block CeraLive assembly**: we never use loop devices.

Consequently, host portability reduces to a single question:

> **Can this host run a `--privileged` Linux container with working
> bind/overlay mounts and arm64 binfmt (or native arm64)?**

`--privileged` ([`orchestrate.sh:551`](../lib/orchestrate.sh)) is there for the
*other* stage — mkosi building the Debian rootfs (bind/overlay mounts, apt in a
chroot ⇒ `CAP_SYS_ADMIN`) — **not** for assembly.

---

## Host support matrix

| Host | Status | Build mode | Live-tested here | Notes |
|---|---|---|---|---|
| **Ubuntu/Debian (CI)** | ✅ Fully supported | container *(or native)* | by parity¹ | Canonical CI builder. |
| **Arch Linux** | ✅ Fully supported | container *(or native)* | ✅ yes | The host this spike ran on. |
| **Fedora/RHEL** | ✅ Supported, SELinux caveat | container *(Podman or Docker)* | no | Needs SELinux volume labels. |
| **macOS Apple Silicon** | ⚠️ Container-only, caveated | container only | no (no macOS in env) | arm64 is *native*; loop limit is moot; cannot run native mkosi. |
| **WSL2** | ⚠️ Container-only, caveated | container *(native possible)* | no (no Windows in env) | binfmt/WSLInterop collision needs handling. |

¹ The CI builder **is** the pinned `debian:trixie-slim` image
([`v2/ci/Dockerfile`](../ci/Dockerfile)) that every assembly step in
`task-16-host-spikes.txt` ran inside; the host kernel only needs to provide a
privileged container + arm64 binfmt, which any modern Linux CI runner does.

Legend: ✅ = run it as-is · ⚠️ = works for the **container** build with the noted
limitation + workaround; do **not** assume the **native** build works.

---

## Protected production-candidate runner

The developer matrix above describes functional portability. The protected
GitHub release candidate has a narrower, fail-closed resource contract: a native
Linux Docker daemon on the `default` context and socket, at least 16 GiB visible
to Docker, at least 16 GiB current `MemAvailable` + `SwapFree`, and at least
24 GiB free on both the checkout and Docker-root filesystems. Docker Desktop is
not accepted for this dedicated production job, even when it remains suitable
for caveated local development.

The workflow exports `DOCKER_CONTEXT=default`, so an interactive `docker context
use desktop-linux` cannot redirect the runner service. It then runs:

```bash
DOCKER_CONTEXT=default GITHUB_WORKSPACE="$PWD" ./v2/ci/check-builder-resources.sh
```

Run that command from the checkout before a manual production-path proof. A
failure is actionable resource/topology evidence; do not compensate by extending
workflow timeouts or skipping verification.

The runner workspace is persistent, but rootful mkosi output is not allowed to
survive as an obstacle to the next clean checkout. Before `actions/checkout` and
again in an `always()` step after cache save, the release workflow uses the
digest-pinned Debian cleanup image with networking disabled to remove only
`v2/mkosi/build` and `v2/mkosi/cache`. The pre-checkout pass recovers when a host
or runner interruption prevented the prior post-run pass. Do not broaden this
allowlist: `.staging`, `v2/images`, `candidate`, source, and trust inputs are not
runner-cleanup targets.

The same restrictive runner umask also makes checkout and `.staging` ancestors
mode `0700`. The containerized build therefore mounts the verified BSP and
first-party consumer directories directly at dedicated read-only paths. Do not
route mkosi package inputs back through `/work/mkosi/.staging`: its unprivileged
repository indexer cannot traverse those private ancestors and will produce an
empty local package index. The platform postinstall must remain non-chrooted so
mkosi exposes `mkosi-install`; raw `apt-get` uses the image's persistent APT state
and cannot resolve packages from mkosi's ephemeral `file:/repository`.

---

## Per-host detail

### Ubuntu/Debian (CI baseline) — ✅ fully supported

The reference platform. The canonical build runs `mkosi` inside the pinned
trixie builder; the host only provides the container runtime + kernel.

**Exact requirements**

| Requirement | Minimum | Why |
|---|---|---|
| Docker **or** Podman | Docker ≥ 20.10 / Podman ≥ 4.0 | runs the builder `--privileged` |
| Kernel | any maintained 5.x+ | overlayfs + binfmt_misc |
| `qemu-user-static` + `binfmt-support` | distro current | arm64 emulation (host-side, **F-flag**) |

```bash
sudo apt-get install -y qemu-user-static binfmt-support
# confirm the F (fix-binary) flag — required so emulation works inside containers:
grep -A2 '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64   # flags: ... F
./v2/build rock-5b-plus
```

Native build also works on Debian **trixie+** (needs mkosi ≥ 26 / Python ≥ 3.12
and `debian-archive-keyring`): `./v2/build rock-5b-plus --native`.

---

### Arch Linux — ✅ fully supported (live-tested)

The host this spike ran on. Docker 29.5.2, systemd 260, kernel 7.0.11. All four
assembly primitives passed inside the trixie builder, privileged **and**
unprivileged.

**Exact requirements**

```bash
sudo pacman -S docker            # or: podman
# arm64 binfmt with the F-flag (one of):
sudo pacman -S qemu-user-static qemu-user-static-binfmt   # extra/community
sudo systemctl restart systemd-binfmt        # register the handlers
grep flags /proc/sys/fs/binfmt_misc/qemu-aarch64    # must contain F
./v2/build rock-5b-plus
```

Caveat: ensure the binfmt handler carries the **F** flag (the
`qemu-user-static-binfmt` package / `systemd-binfmt` registers it as `PF`). A
handler registered *without* F will not fire inside the build container.

---

### Fedora/RHEL — ✅ supported, SELinux caveat

Linux-native; the same trixie builder runs under Podman (Fedora default) or
Docker. Not live-tested in this environment, but it is the same kernel-feature
surface as Arch/Ubuntu.

**Exact requirements**

```bash
sudo dnf install -y qemu-user-static podman   # qemu-user-static pulls binfmt
systemctl restart systemd-binfmt
```

**Caveat — SELinux relabels the bind mount.** The build bind-mounts the repo
into the container (`-v ${V2_DIR}:/work`). Under enforcing SELinux, Podman/Docker
must be told to relabel or the container gets `Permission denied` on `/work`.

*Workaround* (pick one):

```bash
# A) Podman handles this automatically for its own mounts, but the orchestrator
#    passes a plain -v. If you hit denials, run the builder by hand with :z, or:
sudo setsebool -P container_use_devices on        # for the --privileged devices
# B) last resort for a throwaway dev box:
#    add --security-opt label=disable to the run (edit run_mkosi_build locally).
```

Rootless Podman additionally needs `newuidmap`/`newgidmap` (the `shadow-utils`
package) for the user-namespace mapping.

---

### macOS Apple Silicon (Docker Desktop) — ⚠️ container-only, caveated

> **Not validated in this environment** (no macOS host reachable). The statements
> below are derived from documented Docker Desktop / LinuxKit behavior plus the
> loop-free proof from the live Linux run. Treat as "should work, container-only"
> until someone runs `./v2/build` on an M-series Mac.

Docker Desktop runs containers inside a Linux VM (Virtualization.Framework /
LinuxKit). There is **no native build path** — macOS is not Linux, so
`--native` mkosi is impossible. Use the container build only.

**What's actually fine**

- **arm64 is native.** The device target is `arm64`; Apple Silicon is arm64, so
  `--architecture=arm64` runs **natively in the VM — no qemu emulation at all.**
  The binfmt question simply doesn't arise for the default board builds.
- **Assembly is loop-free** (steps [A]–[D]), so the well-known Docker-Desktop
  loop limitation below never bites CeraLive.

**The precise limitation (and why it doesn't block us)**

In a `--privileged` container on Docker Desktop, `losetup -f -P <img>` creates
`/dev/loop0` but **does not populate the per-partition nodes** `/dev/loop0pX` —
the VM kernel doesn't propagate device-hotplug uevents into the container's
`/dev` (docker/for-mac#5967, moby/moby#27886). Builders that *mount partitioned
loop images* (pi-gen, `armbian/build`) break here. **CeraLive never does that** —
`assemble-disk.sh` writes a flat file with `mkfs.ext4 -d` + `mcopy` + `dd`, so
there is no `loop0pX` to miss.

*Workaround for the limitation itself* (only if a future step ever needs a
partitioned loop mount — today none do): scan + `mknod` the partition nodes by
hand, or run `losetup` in a throwaway side-container; see
`task-16-host-spikes.txt` references. **Not required for the current pipeline.**

**Required versions / settings**

| Requirement | Setting |
|---|---|
| Docker Desktop | ≥ 4.x with **VirtioFS** file sharing enabled (Settings → General) |
| File sharing | the checkout's parent dir must be in Docker Desktop's shared paths |
| Resources | ≥ 4 GB RAM / ≥ 20 GB disk to the VM (rootfs build + 8–16 GB image) |
| Runtime | Docker (Podman Machine on macOS works the same, same caveats) |

```bash
# macOS Apple Silicon — container build (native arm64, no qemu):
./v2/build rock-5b-plus
# If /work is denied: add the repo's parent to Docker Desktop shared folders.
```

**Bottom line:** container-only; expected to work because the target arch is
native and assembly is loop-free; flagged *caveated* solely because it is not
yet reproduced on hardware here.

---

### WSL2 — ⚠️ container-only (native possible), caveated

> **Not validated in this environment** (no Windows/WSL2 host reachable).
> Derived from the WSL2 kernel feature set + the loop-free proof.

WSL2 runs a **real Microsoft-built Linux kernel**, so it is much closer to a
native Linux host than macOS is. You can run the container build (Docker Desktop
WSL2 backend, or docker/podman inside a WSL distro) and, on a Debian/Ubuntu
trixie WSL distro with mkosi ≥ 26, even the `--native` path.

**What's fine**

- **Loop devices exist.** The WSL2 kernel ships `/dev/loop0..7` + `/dev/loop-control`
  built-in since ~5.x (e.g. `5.15.90.1-microsoft-standard-WSL2`). `modprobe loop`
  "fails" only because it is compiled-in, not a module — the nodes are present
  (microsoft/WSL#4980). Irrelevant to us anyway (assembly is loop-free), but it
  means even loop-dependent tooling works in WSL2, unlike macOS.
- **mount/overlay** in a privileged container works (real kernel).

**The precise caveat — binfmt arm64 vs WSLInterop**

arm64 builds on WSL2 (x86 Windows host) need `qemu-aarch64` registered with the
**F** flag. WSL2's `binfmt_misc` is shared/owned by `WSLInterop` (runs Windows
`.exe`) and `systemd-binfmt` will **wipe other handlers** when a systemd-enabled
distro starts/stops — so a freshly-registered `qemu-aarch64` can silently
disappear (systemd/systemd#28126, microsoft/WSL#8843, #12013, #14443). A handler
registered *without* F also won't fire inside the build container/chroot.

*Workarounds* (pick what fits):

```bash
# 1) Let qemu register with the F flag and keep it from being wiped:
sudo apt-get install -y qemu-user-static binfmt-support
# 2) If systemd-binfmt keeps clearing it, in /etc/wsl.conf:
#      [boot]
#      protectBinfmt=false
#    then: wsl --shutdown   (restart the distro)
# 3) Or pin qemu last so it survives:
#      /etc/binfmt.d/zz-qemu-aarch64.conf  with the :...:F registration string
grep flags /proc/sys/fs/binfmt_misc/qemu-aarch64   # confirm 'F' after restart
```

If you build on **Docker Desktop's WSL2 backend**, Docker Desktop ships its own
multi-arch binfmt (`tonistiigi/binfmt`) and usually registers `qemu-aarch64`
with F for you — verify with the `grep` above before a long build.

**Required versions / settings**

| Requirement | Setting |
|---|---|
| WSL | WSL 2 (`wsl --set-default-version 2`); kernel ≥ 5.15 |
| Distro | for `--native`: Debian/Ubuntu **trixie+** with mkosi ≥ 26, Python ≥ 3.12 |
| Runtime | Docker Desktop (WSL2 backend) or docker/podman inside the distro |
| binfmt | `qemu-user-static` **with F flag**, surviving `systemd-binfmt` (above) |

```bash
# WSL2 — container build (x86 host emulating arm64 via qemu F-flag):
./v2/build rock-5b-plus
```

**Bottom line:** closer to native Linux than macOS; loop + mount + overlay all
present; the one real gotcha is keeping the arm64 binfmt handler alive past
`systemd-binfmt`/WSLInterop. Flagged *caveated* because it is not yet reproduced
on hardware here and the binfmt collision is environment-specific.

---

## How to reproduce the spike on your host

The exact harness used for the evidence file lives in the spike log header; the
essence is:

```bash
# 1) Does the assembly run loop-free in an UNPRIVILEGED container? (the key test)
docker run --rm -v "$PWD":/repo:ro debian:trixie-slim bash -euo pipefail -c '
  apt-get update -qq && apt-get install -y --no-install-recommends \
    systemd-repart e2fsprogs dosfstools mtools gdisk coreutils >/dev/null
  cp -r /repo/v2 /tmp/v2
  bash /tmp/v2/lib/assemble-disk.sh verify            # sgdisk + repart geometry
  mkdir -p /tmp/t/etc && echo hi >/tmp/t/etc/hostname
  bash /tmp/v2/lib/assemble-disk.sh build --output /tmp/x.img \
    --total-mb 8192 --single-slot --rootfs-tree /tmp/t --bootloader-adapter efi
'
# All steps PASS with no /dev/loop* => your host can assemble CeraLive images.

# 2) Confirm arm64 binfmt has the F flag (needed on non-arm64 hosts):
grep flags /proc/sys/fs/binfmt_misc/qemu-aarch64    # must contain 'F'
```

A green run of (1) is the bar for calling a host "supported". (2) is only
required when the host CPU is **not** arm64 (it is unnecessary on Apple Silicon).

---

## See also

- [`dev-loop.md`](dev-loop.md) — the canonical containerized build path + native opt-in
- [`v2/ci/Dockerfile`](../ci/Dockerfile) — the pinned trixie builder (mkosi 26)
- [`v2/mkosi/mkosi.conf`](../mkosi/mkosi.conf) (§28-29) — binfmt/qemu-user-static cross-arch note
- [`v2/lib/assemble-disk.sh`](../lib/assemble-disk.sh) — the loop-free Stage-4 assembler
- [`../../test-results/task-16-host-spikes.txt`](../../test-results/task-16-host-spikes.txt) — full evidence + external refs
