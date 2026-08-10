# Kernel build from source (opt-in family variants)

The device image normally installs a **prebuilt Armbian vendor kernel** (`.deb`
fetched from the signed Armbian archive). That is decision **D3**, it is
unchanged, and it is the only path any shipped image has ever taken.

This document describes an **optional, explicitly opt-in** alternative: build the
kernel and its in-tree DTBs **from pinned source** with a CeraLive RK3588 patch
series applied, and use the resulting `.deb` instead of the Armbian one.

Two variants exist, and they target **different kernel tracks with different
patch repositories** — neither repo's patches apply to the other's tree:

| Variant | Track | Source | Patch series | Why it exists |
|---|---|---|---|---|
| `edge` | mainline 7.1 | `linux-stable` `v7.1.7` | [`CERALIVE/rk3588-kernel-patches`](https://github.com/CERALIVE/rk3588-kernel-patches) | keeps the mainline option pinned and buildable (VEPU580 encoder + HDMI-RX) |
| `vendor-patched` | **vendor 6.1 BSP — the kernel the shipped image actually runs** | `armbian/linux-rockchip` `rk-6.1-rkr5.1` @ `95e85f6c` | [`CERALIVE/rk3588-vendor-kernel-patches`](https://github.com/CERALIVE/rk3588-vendor-kernel-patches) | restores **HDMI-RX audio capture**, which the stock vendor kernel lost |

`vendor-patched` is the same 6.1.115 BSP the production path installs prebuilt,
rebuilt from source with five patches applied — three that restore the capture
capability, one that is **diagnostic instrumentation, not a fix**, and one that
is the fix that diagnostic found (see
[§2d](#2d-the-vendor-patch-series-0004-instruments-0005-fixes)). The regression it fixes is
board-confirmed: `armbian/linux-rockchip` `78c67d98f221` (PR #430) unconditionally
zeroed `hdmi-audio-codec` capture channels for **every** instance to fix mono
audio on RK3576 HDMI-**TX**, and since `rk_hdmirx` registers HDMI-**RX** through
that same codec, `/proc/asound/pcm` shows the card with zero capture substreams
and nothing anywhere reports an error.

> **Nothing here is on the production path.** With no variant selected, the
> resolver strips the variant machinery entirely and the resolved build
> parameters are **byte-identical** to the manifest before variants existed.
> That is pinned by committed fixtures — see [§6](#6-how-the-vendor-path-is-proven-unmoved).

---

## 1. The variant model

`manifests/schema/family.schema.json` gives a family an optional `variants:`
map. Its keys are variant names; each value is a **narrow** overlay that may set
only `armbian_branch`, `kernel_packages`, `dtb_packages` and `kernel_source`.

Resolver merge order becomes:

```
family defaults  ->  variant overlay  ->  board overrides      (board wins last)
```

A board fact can never be overridden by a family variant, which is what keeps
per-board data (DTB name, U-Boot package, interface map) authoritative.

`default` is a **reserved** name meaning "apply no overlay". The schema refuses a
variant literally called `default`, because a family that could override the
default path from inside its own variants map would make the production build
silently configurable.

### Selecting one

```bash
build rock-5b-plus --variant edge
CERALIVE_KERNEL_VARIANT=edge build rock-5b-plus     # same thing
lib/resolve.sh rock-5b-plus --variant edge          # resolve only
```

Selection is **explicit only**. Nothing infers a variant from the board, the
host, the git branch or the environment beyond that one variable, and `--variant`
is refused for a multi-board selection (`--all` / `--only`): an rk3588 kernel
overlay applied to an x86 board is not a thing anyone means.

---

## 2. What `kernel_source:` pins

Every input is exact-pinned, and each pin is **verified after checkout** rather
than trusted:

| Field | What it pins |
|---|---|
| `git_url` + *(optional)* `tag` + **`commit`** | the kernel source. `commit` is always the real pin; when a `tag` is declared the build fails if it does not resolve to that commit, so a moved tag is caught instead of silently building different source. See [§2b](#2b-two-source-checkout-shapes) |
| `patches_git_url` + **`patches_commit`** + `patches_series` | the CeraLive patch series. `patches_commit` must be a 40-hex SHA — the schema and the build stage both refuse a branch name. `CERALIVE_KERNEL_PATCHES_LOCAL_REPO` can redirect the *fetch* to a local clone for bench work; it is a mirror override, never a pin override (see [§2e](#2e-bench-only-local-patch-clone)) |
| `defconfig_base` + `defconfig_fragment` | **defconfig mode.** Repo-local fragment, merged onto the in-tree defconfig |
| `config_git_url` + `config_commit` + `config_path` *(+ optional `config_absent_symbols`)* | **config-file mode.** A complete `.config` fetched as a plain file at a pinned revision. See [§2c](#2c-two-config-modes) |
| `builder_image` | the toolchain, as a `repo:tag@sha256:<digest>` |
| `local_version` + `kernel_release` + `package_version` | the produced package's identity |
| `dtb_deb_dir` + `dtb_boot_dir` | the platform-layer DTB install mapping ([§4](#4-the-dtb-install-mapping)) |

Exactly one config mode must be declared; the schema's `oneOf` refuses both and
refuses neither.

**Why the patches repo is pinned like a BSP input.** It is one. It contributes
~4,900 lines to the kernel the device runs. A floating `main` there would leave
the build reproducible in appearance and not in fact. Today's pin is
`CERALIVE/rk3588-kernel-patches@acb519c101fefa31f51300779f3a139bcabf6a1c` — the
commit that LANDED on that repo's `main` from its PR #4, CI-green applying
against exactly `v7.1.7`.

**Pin the landed SHA, never a PR-head SHA.** A squash-merge creates a new commit
and orphans the branch head: #4's pre-merge head `2e195f2d36db` is no longer
reachable from any ref, so a build pinned to it would fail its own fetch. Verify
with `git fetch --depth 1 <patches_git_url> <sha>` from a scratch clone before
committing the bump — the PR gate is `DRY_RUN=1` and never fetches the series.

PR #4 re-anchored the whole series on `v7.1.7` and grew it to nine patches. Two of
them are what make MPP hardware encode work on this track, and both were confirmed
on a real Rock 5B+: `0008` sets the rkvenc DMA max segment size (imported buffer
lengths were truncated to 64 KiB, so the IOVA guardrail rejected every encode) and
`0009` adds the mainline `system-uncached` dma-heap `librockchip_mpp` opens by
name. `0009` needs `CONFIG_DMABUF_HEAPS_SYSTEM_UNCACHED=y` in
`rk3588-edge.fragment` — without it the code compiles and `dma_heap_add()` for
that heap simply never runs, which is precisely the silent no-op §6b's gate exists
to catch.

The predecessor pin `9c1cb385098d` was the merge of PR #2, which added patch
`0006`, the **device-tree half of HDMI-RX audio capture**. Upstream's `0005` gives
`snps_hdmirx` its driver
half — it registers an ASoC `hdmi-audio-codec` child under
`hdmi_receiver@fdee0000` — but touches no device tree, and ALSA does not create a
card for a bare codec. Every image built on the previous pin therefore shipped a
**bound** codec device and no HDMI-IN capture card at all: `/proc/asound/cards`
listed the USB dongle, the onboard es8316, and `hdmi0`/`hdmi1` (the two HDMI
*transmitters*), and nothing errored. `0006` adds `#sound-dai-cells` to
`hdmi_receiver`, an `hdmirx-sound` `simple-audio-card`, and `&hdmirx_sound` +
`&i2s7_8ch` enabled on both CeraLive boards. No `rk3588-edge.fragment` change was
needed — `CONFIG_SND_SIMPLE_CARD`, `CONFIG_SND_SOC_ROCKCHIP_I2S_TDM` and
`CONFIG_SND_SOC_HDMI_CODEC` were already enabled and verified present in the
running board's config.

**Why we pin a tag when Armbian tracks a branch.** Armbian maps rk3588
`BRANCH=edge` to `KERNEL_MAJOR_MINOR=7.1` and then follows the **rolling** branch
`linux-7.1.y`. "Verified against linux-7.1.y" is not a reproducible claim, so we
pin the tag that was its tip at import (`v7.1.7` = `c7ba9d6de43e`). That mapping
is re-derived from `armbian/build` by the patches repo's `scripts/preflight.sh`
and recorded in its `kernel-pin.env`.

---

## 2b. Two source-checkout shapes

`commit` is always THE pin. `tag` is **optional**, and exists only so a tagged
upstream can be proven to still resolve to that commit.

| Shape | When | What `build-kernel.sh` runs |
|---|---|---|
| tagged | the source publishes a tag for the pin (`edge`, `v7.1.7`) | `git clone --depth 1 --branch <tag>`, then assert `HEAD == commit` |
| commit-only | the source publishes **no tag on the pinned branch** (`vendor-patched`, `rk-6.1-rkr5.1`) | `git init` + `git fetch --depth 1 <url> <commit>` + `git checkout FETCH_HEAD`, then assert `HEAD == commit` |

Both shapes end at the same assertion, so the guarantee is identical: the tree
that gets built is the pinned commit or the build dies.

**Do not fabricate a tag to make a commit-only source look tagged.** Armbian's
vendor BSP branch `rk-6.1-rkr5.1` genuinely has no tags — that is why
`rk3588-vendor-kernel-patches/scripts/apply.sh` fetches by SHA too. A synthetic
tag would be a false provenance claim, and cloning the branch **tip** instead
would silently build newer source under an unchanged pin. GitHub serves an
arbitrary reachable SHA to a shallow fetch, so the commit-only shape costs the
same single fetch as a tagged clone.

---

## 2c. Two config modes

The kernel config is as load-bearing as the source, and the two shipped variants
get theirs from structurally different places.

**defconfig mode** (`edge`) — `make <defconfig_base>`, then
`scripts/kconfig/merge_config.sh -m` the repo-local `defconfig_fragment` on top.
Correct for a mainline-track kernel, where no upstream publishes a board config
and the fragment is CeraLive's own reviewed statement of intent.

**config-file mode** (`vendor-patched`) — fetch a **complete `.config`** as a
plain file from `config_git_url` at `config_commit`, path `config_path`, and use
it verbatim as the starting `.config`. Armbian publishes
`config/kernel/linux-rk35xx-vendor.config`: the exact config
`linux-image-vendor-rk35xx` is built from, i.e. the config the fleet is running.

**Never substitute `make defconfig` for the vendor path.** A bare arm64
`defconfig` produces a materially different driver and feature set from the
2,753-symbol Armbian config, so a kernel built that way is not comparable to what
the board runs — which removes the entire point of a vendor-track source build
(the shipped kernel, plus the audio fix, and nothing else).

Both modes then converge on **one** sequence — `make olddefconfig` →
`make syncconfig` → `verify-kernel-config.sh` — so [§6b](#6b-the-fragment-survival-gate--what-the-fragment-asks-for-must-be-what-ships)'s
survival gate covers them identically. `build-kernel.sh` deliberately keeps a
single occurrence of each of those `make` calls; duplicating them per-branch
breaks the static ordering guard in `variant-contract.bats`.

### `config_absent_symbols` — the reviewed exception list

A published upstream config can name symbols the pinned source tree **cannot**
provide. Armbian's `EXTRAWIFI` step
(`lib/functions/compilation/patch/drivers_network.sh` — `driver_rtw88`,
`driver_rtl8852bs`, `driver_uwe5622`, …) copies whole **out-of-tree** WiFi/BT
driver trees into `drivers/net/wireless/` and appends their Kconfig entries at
build time, before configuring. This pipeline never invokes that framework
([§3](#3-the-build-backend--and-what-it-is-not)), so 24 of that config's symbols
have no Kconfig entry here and `olddefconfig` correctly discards them.

`config_absent_symbols` names a repo-local file listing exactly those symbols,
each justified in the file itself
(`manifests/kernel/rk3588-vendor-patched.absent`). It is **not** an escape
hatch:

- a symbol listed there that **did** survive fails the build as a `STALE
  EXCEPTION`, so the list cannot rot into a blanket opt-out;
- a dropped symbol **not** on the list still fails exactly as before;
- both boards' real WiFi adapters are in-tree (`CONFIG_RTW89=m` for the Rock 5B+
  RTL8852BE, `CONFIG_BRCMFMAC=m` for the OPi 5+ AP6275P) and survive the gate — a
  guard in `kernel-config-fragment.bats` forbids either from appearing on the
  list.

Real result on the first `vendor-patched` build:
`ok: 2729 of 2753 declared symbol(s) survived into the resolved kernel .config
(24 reviewed exception(s))`.

---

## 2d. The vendor patch series: `0004` instruments, `0005` fixes

`0001`-`0003` restored the HDMI-RX capture PCM and that half is board-confirmed:
`/dev/snd/pcmC3D0c` exists, opens, and negotiates `hw_params` at several
buffer/period geometries. It still did not produce audio. Every `read()`
returned `EIO` and `arecord` wrote a 44-byte header-only WAV, with a `dmesg`
cleared immediately beforehand staying completely empty — including against a
second, EDID-confirmed audio-capable source, which retired the earlier "the test
source carries no audio" explanation.

`0004` changes no behaviour whatsoever. It raises the severity of, and adds state
to, the failure reports that path already drops, because the silence is
structural: ALSA's only `-EIO` on the rw transfer path is `wait_for_avail()`'s
timeout at `pcm_dbg()` level, `snd_dmaengine_pcm_pointer()` discards its
`dmaengine_tx_status()` return and silently reports position 0, the i2s-tdm
interrupt that is the sole reporter of RX overrun is optional and its absence is
unlogged, and a PL330 channel fault is `dev_info()`.

`0005` is what that instrumentation led to, and it is a real fix: the PCM
lifecycle and the HDMI-RX **audio-domain** lifecycle were never connected. Both
gating bits — `GLOBAL_SWENABLE.AUDIO_ENABLE` and `AUDIO_PROC_CONFIG0.I2S_EN` —
are set only by `hdmirx_delayed_work_audio()`, whose sole triggers are a
one-shot deframer IRQ and an `rk_hdmirx` private V4L2 ioctl no ALSA client
issues. `snd_pcm_open()`, `hw_params` and `trigger START` therefore all left the
domain off, so nothing clocked into i2s7_8ch and `wait_for_avail()` timed out
into `-EIO`. `0005` starts the domain from the capture open and from the paths
that have just confirmed HDMI lock.

Consequences for this repo:

- **Tier 1 — CONFIRMED: `0005` is board-confirmed on one Radxa ROCK 5B+ test**
  (image `20260806T223730Z.raw` after a clean full `dd` reflash), including
  end-to-end CeraUI audio-meter validation through the production cerastream
  idle audio-meter sidecar — not a one-off manual `arecord`. Board-confirmation
  criteria: `hw_ptr` advances, the read-back line shows `RXS=1` with a
  **non-zero** `RXFIFOLR`, and a real capture logs **zero** `capture xfer
  failed` lines. All three held on that test.
- **Tier 2 — OPEN: the PIPELINE-BUILT `--variant vendor-patched` image itself
  has not been booted on hardware, and no Orange Pi 5+ evidence exists.** The
  Radxa ROCK 5B+ confirmation above validated the patch series on a hand-built
  kernel, not this repo's `make bindeb-pkg` output — do not conflate the two
  when deciding whether this variant is ready to build and flash.
- **`0004` is retained in full regardless of the `0005` confirmation above** —
  the instrumentation is how a future pipeline-built-image confirmation gets
  read. Dropping the series back to three patches is a follow-up, not a
  pending cleanup.
- **`0005` may never wait on the audio *work item*, only on its completion.**
  Its first version called `flush_delayed_work()` from `hdmirx_audio_startup()`,
  which ASoC invokes with hdmi-codec's `hcp->lock` held, while that work calls
  back into `plugged_cb()`, which takes the same lock — a hard deadlock that
  fires **only when the fix works** (the no-audio path never reaches
  `plugged_cb()`). The shipped pin waits on a `completion` the work signals
  *before* that callback; statement order there is load-bearing.
- **Do not respond to a fresh EIO with another burst/buffer guess.** `0003`
  already did that, its own commit message says so, and it was not sufficient.

---

## 2e. Bench-only local patch clone

`CERALIVE_KERNEL_PATCHES_LOCAL_REPO=/abs/path/to/clone` bind-mounts that clone
read-only into the builder and fetches the series from it over `file://` instead
of `patches_git_url`.

It exists for one situation: iterating on a patch series whose commit is not
pushed yet, which is exactly how `0004` above was first built. It is a **mirror**
override, not a pin override — the manifest keeps its real `https://` URL and its
real SHA, `patches_commit` still selects the content, and the post-checkout
`have_p != PATCHES_COMMIT` assertion still runs — so it cannot build different
patches, only obtain the same immutable SHA from somewhere the manifest URL
cannot serve it yet. The build logs two `WARN` lines whenever it is active.

It writes a generated gitconfig and points `GIT_CONFIG_GLOBAL` at it. That is not
decoration and must not be "simplified" into `-c safe.directory=...` or
`GIT_CONFIG_COUNT`: git deliberately honours `safe.directory` **only** from the
system or global config, and the mounted clone is owned by the invoking user
while git in the container runs as root. Doing it the other way fails the fetch
with `detected dubious ownership`.

**Never set it on a release path.** A published artifact must be reproducible
from the manifest alone.

---

## 3. The build backend — and what it is not

**Backend: plain kernel `make bindeb-pkg`.** `lib/build-kernel.sh` clones the
pinned source, applies the series with `git am`, merges the defconfig fragment,
and runs `make bindeb-pkg` — all inside the digest-pinned builder container
(`ci/Dockerfile.kernel`), cross-compiling with `aarch64-linux-gnu-` and a
persistent `ccache`.

**The Armbian build framework is NOT the build system here.** It is consulted for
exactly one thing — the `edge` → kernel-version mapping, upstream in the patches
repo's preflight — and is never invoked. Adopting Armbian's framework would bring
its own patch stack, kernel config, packaging and userspace assumptions, and
would make "what exactly is in this kernel" unanswerable from this repo. The
whole point of this stage is that the answer is three pinned SHAs and one
reviewed fragment.

**Output contract:** exactly **one** `linux-image-*` `.deb`, containing the
kernel and the in-tree DTBs. `bindeb-pkg` also emits `linux-headers-*` and
`linux-libc-dev`; both are **discarded before staging** (the device image
installs neither). The build fails if the expected `linux-image` deb is missing
or if more than one matches.

**Validated, not assumed.** Before staging, the built `.deb` is checked on four
axes against the manifest: control `Package:`, control `Version:`, control
`Architecture:`, and the presence of the board's own DTB at
`dtb_deb_dir/<dtb_name>`. A mismatch on any of them is fatal — the orchestrator's
package-name replacement and the boot script's `fdtfile` lookup both depend on
these being true, and a mismatch would otherwise surface as an unbootable board.

---

## 3b. Fetch resilience, and the build-job preflight

Two failure modes of this stage have nothing to do with the kernel, and both are
invisible to the PR gate (`DRY_RUN=1` never fetches and never runs `make`).

**All three pinned fetches go through `fetch_pinned_tree`.** The stage performs
three network fetches back to back — kernel source, patch series, kernel config
— and a blip on any of them used to abort a build that had already paid for the
builder image, the container and (for fetches 2 and 3) a multi-minute kernel
checkout. Each fetch now gets up to `CERALIVE_KERNEL_GIT_ATTEMPTS` (3) attempts,
each wrapped in `timeout(1)` (`CERALIVE_KERNEL_GIT_TIMEOUT`, 1800s — a git that
has stopped making progress does not exit on its own), with a linear backoff
(`CERALIVE_KERNEL_GIT_BACKOFF`, 5s × attempt).

**Every attempt runs in a private directory that is destroyed BEFORE it starts,
not merely after it fails.** This is the load-bearing half. A tree half-written
by a killed clone, left where the next attempt wants to write, turns attempt 2
into a deterministic `destination path already exists` (or a stale
`.git/index.lock` on the fetch shape) — so one transient blip presents as a
total outage, and the manual re-run fails the same way for the same reason.

**A PIN MISMATCH IS NEVER RETRIED.** The `HEAD == commit` assertion runs *after*
the retry loop and fails immediately. A moved tag or a SHA orphaned by a
squash-merge (see §7's pin-hygiene note) is a PERMANENT fact about the remote:
retrying it re-fetches the same wrong tree three times and then reports three
failed attempts, which reads as a network problem and sends the next person to
the wrong layer. Only a fully pin-verified tree is renamed into the path the
build reads, so no later stage can ever see a partial or wrong checkout.

The helper is defined host-side in `build-kernel.sh` and **injected** into the
container script with `declare -f`, so the loop the real build runs is the same
text the test suite drives against a stubbed `git`.

**Build jobs are derived, not assumed.** `make -j$(nproc)` is the obvious default
and it is the one that gets a builder OOM-killed: a kernel compile job peaks
around 1-2 GiB RSS, so a core-rich, memory-thin host dies deep inside
`bindeb-pkg`, after every pin has already verified. The width is
`min(nproc, MemAvailable / 2 GiB)`, floored at 1 (a serial build beats no build)
and ceilinged at `nproc` (spare memory buys no extra cores). The derivation is
logged on every run. `CERALIVE_KERNEL_BUILD_JOBS` overrides it
**unconditionally**, including upward — an operator who has measured their own
host outranks the heuristic. `CERALIVE_RESOURCE_MEMINFO_FILE` (the same knob
`ci/check-builder-resources.sh` uses) redirects the meminfo read.

Guards: `tests/kernel-build-resilience.bats` (30 tests — the three
job-derivation fixtures, floor/ceiling/override/fallback legs, transient-retry
and its non-vacuity twin, both partial-debris shapes, pre-attempt and
final-attempt cleanup, a real `timeout(1)` leg, the never-retried pin mismatch,
the nothing-is-published-unverified legs, and the wiring including a `bash -n`
of the assembled container script). Mutation-verified: removing the pre-attempt
`rm -rf`, folding the pin check into the retry condition, publishing before
verifying, dropping the final cleanup, and dropping the memory ceiling each
fail the suite.

---

## 4. The DTB install mapping

An Armbian `linux-dtb-*` package lands the board DTBs exactly where the U-Boot
boot script looks them up. `make bindeb-pkg` does not — it ships in-tree arm64
DTBs **inside** the `linux-image` deb:

```
/usr/lib/linux-image-<KERNELRELEASE>/<vendor>/   (kernel_source.dtb_deb_dir)
        -> copied by mkosi.images/platform/mkosi.postinst to ->
/boot/dtb/<vendor>/                              (kernel_source.dtb_boot_dir)
```

`/boot/dtb/rockchip/${fdtfile}` is precisely what
`mkosi/platform/boot/boot.scr.cmd` resolves, so a source-built kernel
satisfies the **same** board `dtb_name` expectation with no change to the boot
script, the board manifest or the disk assembler.

Both paths are empty on the vendor path, so the copy step is a strict no-op
there. When enabled it is fail-loud: a missing source directory, a half-specified
mapping, or a missing board DTB aborts the build rather than producing an image
that boots to a device-tree-less kernel.

Note the layouts differ and that is FINE: the vendor package ships
`/boot/dtb-<release>/<vendor>/` with a `/boot/dtb` symlink onto it, while this copy
makes `/boot/dtb` a real directory. The selector resolves
`/boot/dtb/<vendor>/${fdtfile}` either way — U-Boot's ext4 driver follows an
intermediate symlink — so no versioned directory is synthesised here. Proven on
hardware: the failing boot that motivated §4b still read the DTB correctly
(`106449 bytes read`) off exactly this layout.

---

## 4b. The rest of `/boot` — `Image` and the initrd

The DTB mapping above was not enough, and the gap put a board into an infinite
crash-reboot loop. **Read this before adding any other kernel packaging.**

The selector's first load is `/boot/Image`. On the vendor path that file exists
because Armbian's `linux-image-vendor-rk35xx` **postinst** creates it:

```sh
ln -sfv vmlinuz-6.1.115-vendor-rk35xx /boot/Image
touch /boot/.next
linux-update-symlinks install "6.1.115-vendor-rk35xx" "boot/vmlinuz-…"
```

and, because that package `Depends: initramfs-tools`, the `run-parts
/etc/kernel/postinst.d` at the top of the same postinst also emits
`/boot/initrd.img-<release>`. Neither is done by the kernel; both are done by
**Armbian's maintainer script and its dependency closure**.

`make bindeb-pkg` generates a postinst that does only the `run-parts`, creates no
`Image`, and declares no initramfs dependency. Replacing the vendor kernel package
with the built one therefore also removes `initramfs-tools` from the closure, so
`/etc/kernel/postinst.d` is EMPTY and the `run-parts` is a no-op. The resulting
`/boot` had `vmlinuz-<release>` and nothing else:

```
Failed to load '/boot/Image'
106449 bytes read in 21 ms          <- the DTB, correctly resolved
Failed to load '/boot/initrd.img'
Starting kernel ...
"Synchronous Abort" handler, esr 0x02000000
```

`install_kernel_source_boot_artifacts` in
`mkosi.images/platform/mkosi.postinst` replicates the vendor behaviour for this
path, and the platform layer installs `initramfs-tools` in its **own transaction
before** the kernel package so the hook is configured when the kernel postinst runs.
Ordering is the mechanism — in one apt invocation it is incidental, and the vendor
path only gets it for free because of that hard dependency.

Deliberately NOT replicated: the root-level `/vmlinuz` and `/initrd.img` symlinks
`linux-update-symlinks` (from `linux-base`) maintains. Nothing on the boot path
reads them, and `linux-base` is not in this closure.

The step is gated on `KERNEL_SOURCE_KERNEL_RELEASE`, which resolves empty unless a
`kernel_source:` variant was selected, so the vendor path is untouched. That
variable rides the `env_names` ↔ `PassEnvironment=` lockstep like every other
subimage input.

**The build now gates on the result.** `lib/verify-boot-artifacts.sh` asserts the
emitted rootfs tar carries a resolvable `Image`, board DTB and versioned initrd, and
the orchestrator runs it at `[6b/9]` on every arm64 build. It is layout-agnostic on
purpose — symlink or real file, versioned dtb dir or not — because it checks what
U-Boot can load, not which packaging mechanism produced it. This exists because
`DRY_RUN` CI never executes the layers that populate `/boot`, and
`tests/preflash-verify.sh` (which does check) asserts the production PARTLABEL set
first, so a bench image fails there and never reaches its artifact checks.

---

## 4c. `/boot/Image` must also be the RAW Image — `bindeb-pkg` ships `Image.gz`

§4b made `/boot/Image` **exist**. It did not make it **loadable**, and the same
path failed a second time on the other board — this time with every artifact
present, resolvable and the right size.

On a real Orange Pi 5 Plus the selector ran cleanly through the whole A/B
sequence, loaded 15,928,530 bytes of `/boot/Image` and 106,234 bytes of DTB, then:

```
15928530 bytes read in 1421 ms
106234 bytes read in 21 ms
Bad Linux ARM64 Image magic!
SCRIPT FAILED: continuing...
```

Re-loading the file by hand and dumping its first bytes named the cause outright:

```
=> ext4load mmc 1:2 0x00400000 /boot/Image
=> md.b 0x00400000 0x40
00400000: 1f 8b 08 00 00 00 00 00 02 03 ...
```

`1f 8b` is the gzip magic and `08` is deflate. `/boot/Image` was **gzip**, and
`booti` needs the raw, self-decompressing ARM64 Image — magic `0x644d5241`
(`"ARM\x64"`, little-endian) at **offset 56** of its 64-byte header
(`Documentation/arm64/booting.rst` §4). That document also states the constraint
explicitly: *"The AArch64 kernel does not currently provide a decompressor and
therefore requires decompression (gzip etc.) to be performed by the boot loader
if a compressed Image target (e.g. Image.gz) is used."*

**Where the gzip comes from.** `arch/arm64/Makefile` sets
`KBUILD_IMAGE := $(boot)/Image.gz`, and `scripts/package/builddeb` installs
`$(make -s image_name)` as `/boot/vmlinuz-<KERNELRELEASE>`. So on arm64 the
`bindeb-pkg` `vmlinuz` is `Image.gz` by default, for **both** variants — the
`edge` build log says so in one line: `GZIP arch/arm64/boot/Image.gz`. Armbian's
vendor package does not have the problem because its framework builds the
rockchip64 family with `KERNEL_IMAGE_TYPE="Image"`.

**Why it booted on one board and not the other — the ambiguity, resolved.** It
was not a per-build artifact difference: both boards' `edge` builds emit the same
`Image.gz`. It is a per-board **U-Boot capability** difference, read straight out
of each board's staged `u-boot-config-target-1` (both packages `26.5.1`, both
SHA-256-verified):

| Symbol | `rock-5b-plus` (U-Boot **2026.04**) | `orange-pi-5-plus` (U-Boot **2017.09**) |
|---|---|---|
| `CONFIG_GZIP` | `=y` | **symbol absent entirely** |
| `CONFIG_ZLIB` | `=y` | absent |
| `CONFIG_CMD_UNZIP` | `=y` | `# … is not set` |
| `CONFIG_CMD_BOOTI` | `=y` | `=y` |
| `CONFIG_IMAGE_GZIP` | — | `# … is not set` |

Modern U-Boot's `booti_start()` (`cmd/booti.c`) sniffs the compression type and
calls `image_decomp()` before `booti_setup()`, which is why the Rock 5B+ booted a
gzip Image all the way to userspace and hid this defect for a whole release. The
Orange Pi ships the Rockchip **2017.09** vendor fork, which predates that support
entirely and has no gzip anywhere — hence `unzip` answering `Unknown command`
on its console, with no interactive workaround available at all.

That is the third instance of the same lesson in this file's neighbourhood
(`setexpr`, `loadaddr`, now gzip): **an artifact contract may not be satisfied by
a board's U-Boot happening to be able to cope.** So the raw Image is produced at
staging time:

- `install_kernel_source_boot_artifacts` reads the first bytes of
  `vmlinuz-<REL>`. On gzip it `gzip -dc`s into `/boot/Image` as a **real file** —
  a symlink to the still-compressed vmlinuz is the bug, not the fix. On an
  already-raw Image it keeps the vendor-parity symlink. Any other recognised
  container (xz / zstd / bzip2 / lz4 / lzop / lzma) is **fatal and named**,
  because guessing there ships an unbootable slot on every board.
- It then asserts the ARM64 magic on whatever it just produced. A decompression
  that *succeeds* on the wrong payload is still an unbootable slot, so success of
  `gzip` is not the property checked — the resulting magic is.
- `verify-boot-artifacts.sh` re-asserts the same magic at `[6b/9]` against the
  real emitted rootfs tar, and names the compression when it finds one, so the
  failure reads as a packaging fact rather than a bootloader mystery.

The packaged `vmlinuz-<REL>` is deliberately left exactly as `dpkg` installed it
(compressed, dpkg-owned); only `/boot/Image` is materialised. The cost is one
extra decompressed kernel in `/boot`.

Guards: `tests/boot-artifacts.bats` — gzip/xz/no-magic rejections through the
verifier on both layouts, and the real shipped staging function driven against a
gzip vmlinuz (real decompressed file, byte-identical to the source Image, vmlinuz
untouched), a raw vmlinuz (symlink preserved), an xz vmlinuz (fatal), a gzip of a
non-Image payload (fatal), and a re-run (idempotent).

---

## 5. Integration semantics

Three things change when a `kernel_source:` block resolves, and only then:

1. **Remote fetch is suppressed** for the kernel/DTB package names.
   `resolve.py` derives `KERNEL_SOURCE_SUPPRESSED_PACKAGES` as the union of the
   *pre-overlay* family names (still present in the family file, which
   `fetch-debs.sh` reads directly) and the *post-merge* built names (which no
   remote archive carries). The orchestrator forwards it as
   `CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS`, and `collect_declared_bsp_pkgs`
   filters it out — so a suppressed package is invisible to **every** remote path
   at once. **U-Boot and firmware are never in that set** and stay
   prebuilt-fetched.

   The list is *derived*, never authored: the schema rejects a manifest that
   tries to declare it, because a hand-written suppression list would drift from
   the replacement list the moment either changed.

2. **The built package names replace the family's** for resolver and orchestrator
   purposes. That falls out of the ordinary variant merge — the overlay's
   `kernel_packages` replaces the family array — and the names are validated
   against the real built control fields ([§3](#3-the-build-backend--and-what-it-is-not)).

3. **A staged-package uniqueness check** fails the build if any package name has
   **both** a fetched and a locally-built candidate. Suppression is what should
   make that impossible; this check is what proves it did. Without it, mkosi's
   local repository would silently pick one by version and the image would ship a
   kernel nobody chose — a plausible-looking image instead of an error, which is
   the worst failure mode available here.

Stage order in `lib/orchestrate.sh` is `[2/9] fetch` → `[2b/9] kernel build` →
uniqueness check → `[3/9] partition`. The build sits after the fetch so the check
sees the complete fetched set, and before partitioning so the built `.deb` flows
through exactly the same classification and staging path as a fetched one.

---

## 6. How the vendor path is proven unmoved

`tests/manifests/fixtures/vendor-baseline/<board>.params` holds the resolver's
full output for all three shipped boards, captured **before** any of this
existed. `variant-contract.bats` diffs the live resolver against those fixtures for
`rock-5b-plus`, `orange-pi-5-plus` and `x86-minipc`, with no variant, with an
explicit `--variant default`, and with `CERALIVE_KERNEL_VARIANT=default`.

The comparison carries an explicit **non-vacuity** leg: the same diff run against
the `edge` resolve must **fail**. A golden-file check that silently compares
nothing is worse than no check, so the suite proves the check can fail.

Alongside it: `VARIANTS_*` must never appear in any flattened param set, the
vendor `DRY_RUN` must still declare its 4-package Armbian BSP set (the
non-vacuity leg of suppression), and the x86 dry-run must be untouched by any of
this.

---

## 6b. The fragment-survival gate — what the fragment ASKS FOR must be what ships

`scripts/kconfig/merge_config.sh -m` merges text and reports only symbols the
fragment *redefines*. It says nothing about a symbol that the following
`make olddefconfig` then **drops**, and `-m` is precisely the flag that skips
merge_config's own post-merge validation pass. So a fragment line can be
discarded in total silence: the build succeeds, the four-axis `.deb` validation
passes, `/boot` is complete, the image boots, and the driver is simply absent.

That is not hypothetical. `rk3588-edge.fragment` declared

```
CONFIG_RTW89_8852BE=m      # RTL8852BE WiFi (Rock 5B+)
```

without `CONFIG_RTW89`, the `menuconfig` that gates the whole rtw89 family
(`tristate`, `depends on MAC80211`, defaults off). `olddefconfig` discarded the
leaf. The shipped `7.1.5-ceralive-rk3588` carried `# CONFIG_RTW89 is not set`,
and a real Rock 5B+ enumerated the radio at PCI level (`10ec:b852`, class
`0x028000`) with **no driver bound, no `wl*` interface and no `rtw89*` in
`lsmod`** — while the firmware it needed (`/lib/firmware/rtw89/rtw8852b_fw.bin`,
from `armbian-firmware`) was present the whole time and `cfg80211` was loaded.
Nothing in three releases of build logs suggested anything had been lost.

`lib/verify-kernel-config.sh` closes it. It runs **inside the builder
container, immediately after `make syncconfig` and before `bindeb-pkg`** (so the
failure is fast, not one cross-compile later), mounted read-only at
`/in/verify-kernel-config.sh`, and asserts every symbol the fragment declares
against the resolved `.config`:

| Fragment line | Requirement |
|---|---|
| `CONFIG_X=y` / `=m` / `="str"` | must appear **verbatim** in the resolved config |
| `CONFIG_X=n` | must resolve to not-set (absent counts) |
| `# CONFIG_X is not set` | must resolve to not-set (absent counts) |

Exact value matching is deliberate, and it immediately found a second, quieter
instance of the same class: `CONFIG_TYPEC_FUSB302=y` had been resolving to `=m`
for three releases, because FUSB302 carries `depends on DRM || DRM=n` and arm64
`defconfig` builds DRM as a module — so kconfig caps it at `=m` however loudly
the fragment asks. Built-in versus loadable module is a real difference in what
ships, so the gate reports it rather than tolerating it; the fragment now
declares the honest `=m`.

The gate only sees symbols the fragment *names*, so the same class keeps
resurfacing wherever the fragment was silent. `CONFIG_DMABUF_HEAPS` was the third
instance (no `/dev/dma_heap`, so `mpph264enc` produced zero bytes), and
`CONFIG_NF_TABLES` the fourth — and that one is a security regression rather than
a missing feature. The `edge` kernel had **no nftables at all**, so
`ceralive-ingest-firewall.service` failed on every boot with

```
nft[182]: mnl.c:60: Unable to initialize Netlink socket: Protocol not supported
```

and the WAN-side drop of the unauthenticated RTMP `:1935` / SRT `:4001` ingest
ports was silently never applied. `CONFIG_NF_TABLES` is a tristate with a prompt
and no `default`, and the whole family (`NF_TABLES_INET`, every `nft_*`
expression, the v4/v6 halves) sits inside its `if NF_TABLES` block, so
`defconfig` never enabled it. The `NETLINK_NETFILTER` protocol `nft` opens comes
from `CONFIG_NETFILTER_NETLINK`, a promptless tristate nothing selects until
`NF_TABLES` is on — which is why the board reports a missing netlink *protocol*
and `modprobe nfnetlink` answers "module not found"; neither is the real subject.

**When the gate fires, do not silence it by deleting the line.** A dropped symbol
means its Kconfig visibility condition is unmet. Read the symbol's own Kconfig
entry, find the `menuconfig` block it sits inside and its `depends on` line, and
declare those too — a `select`ed helper symbol (`RTW89_CORE`, `RTW89_PCI`,
`RTW89_8852B`; `NF_TABLES_IPV4`, `NF_TABLES_IPV6`) needs no entry, but a
`menuconfig` parent always does.

**And read the Makefile as well as the Kconfig before you add a symbol.** The
ingest ruleset uses a `counter` statement, so `CONFIG_NFT_COUNTER` looks
obligatory — but no such symbol exists in `v7.1.7`: `net/netfilter/Makefile`
compiles `nft_counter.o` unconditionally into `nf_tables-objs`, next to
`nft_meta.o` (`iifname`) and `nft_chain_filter.o` (`type filter hook input`).
Declaring it would resolve to nothing and this gate would reject the build. The
rule is symmetric with the FUSB302 case: declare the value kconfig can actually
give, whether that is a downgrade or an omission.

Coverage: `tests/kernel-config-fragment.bats` (16 tests — the verifier's
drop/downgrade/off/absence table, the real fragment's repaired symbols (rtw89,
FUSB302, nftables) plus the `NFT_COUNTER` absence guard, a red/green pair driving
the real fragment against a reproduction of the broken 7.1.5 answer and against a
fully-honoured one, and the build-stage wiring order).

---

## 7. Known gaps — read before using this

Honest status: **`rock-5b-plus --variant edge` has been built end to end** — a real
cross-compile producing `linux-image-7.1.7-ceralive-rk3588` and a flashable `.raw` —
**and, at the `v7.1.7` pin, flashed and booted on a real Rock 5B+.** That run
cleared the MPP hardware-encode KNOWN ISSUE (see the pipeline `AGENTS.md`) and
confirmed the capture/encode symbols on silicon. It is ONE board: `orange-pi-5-plus`
has still never booted an edge image, so every per-board claim below stands.

**`vendor-patched` status:** the kernel `.deb` builds and validates on all four
axes; the series applies cleanly with `git am` against the pinned commit; the
config-survival gate passes with 24 reviewed exceptions. It has **not been booted
on hardware from this pipeline**. The underlying fix *was* separately board-proven
by a hand-built kernel (`.omo/evidence/device-platform-wave4/`
`vendor-kernel-hdmi-audio-bench-boot-proof-2.md`): the PL330 descriptor rejection
disappeared and the board stayed healthy. Two limits from that run carry over
verbatim and must not be overstated — `MAXBURST_PER_FIFO` was never proven
necessary in isolation (the `RX FIFO Overrun` it addresses never occurred), and
end-to-end HDMI audio remained blocked by the **test source**, which reported
`audio_present=0`. This variant makes that fix reproducible from a real build
instead of a manual patch; it does not re-prove the audio path.

1. **The kernel is not built in CI.** The PR gate runs `DRY_RUN=1`, which emits
   the plan and touches no network, container or compiler. A real kernel build is
   a multi-GB clone and a long cross-compile; wiring it into the PR gate would be
   a separate, deliberate decision about CI budget.

   That gap is not free, and it has been paid for once already: the first real
   build of this path hit **four** independent, board-independent defects, each
   invisible to a plan-only gate and each fatal — a stale `include/config/auto.conf`
   making the `kernelrelease` assertion unsatisfiable, two missing cross build
   dependencies in the builder image, a builder-image tag that could never be
   invalidated, and a `deb_lists_path` that reported every present DTB as absent
   (`grep -q` closing the pipe, `tar` dying of `SIGPIPE`, `set -o pipefail`
   turning that into "not found"). All four now carry static/executable guards in
   `variant-contract.bats` §26, because a static guard is the only thing a `DRY_RUN` gate
   can enforce. **Add a guard whenever you touch this path.**
2. **The defconfig fragment is reviewed intent, not a validated result.** It
   starts from mainline `defconfig` and adds what the CeraLive stack needs. The
   fragment is now known to *resolve and compile* — the built
   `/boot/config-7.1.7-ceralive-rk3588` carries it — but no symbol in it has been
   proven necessary *or* sufficient **on hardware**.

   Worse, until §6b's gate existed the built config did not even carry what the
   fragment ASKED for: two symbols were being silently dropped or downgraded. The
   gate now makes "the fragment is honoured" a build invariant, but that is a
   weaker claim than "the fragment is right for this board" — which still needs a
   bench run per symbol.
3. **eMMC HS400 negotiation is inconsistent under this kernel, and no fix is
   staged.** On a real Rock 5B+ one `edge` 7.1.5 run logged
   `sdhci-dwcmshc fe2e0000.mmc: Can't reduce the clock below 52MHz in HS200/HS400
   mode` (×3) → `mmc0: switch to hs400 failed, err:-110` → `mmc0: Failed to
   initialize a non-removable card`, and `/dev/mmcblk0` did not appear. A fresh
   2026-08-02 bench build from the same kernel/patch pins at commit `7c98213`
   printed the warning (×4) but then initialized successfully:
   `mmc0: new HS400 MMC card at address 0001`, `mmcblk0: mmc0:0001 HCG8e 58.3
   GiB`, and `mmcblk0: p1 p2 p3 p4`. The warning and upstream driver mechanics
   are real, but the outcome is not deterministic across these builds; the
   cause of the inconsistency is not established and needs a dedicated
   investigation. This is **not** a pipeline misconfiguration: the DT node is upstream-complete
   (`mmc-hs400-1_8v`, `mmc-hs400-enhanced-strobe`, all five clocks + resets,
   `supports-cqe`), the config carries `MMC_SDHCI_OF_DWCMSHC=y` / `MMC_CQHCI=y` /
   `ROCKCHIP_IODOMAIN=y`, and the driver's `rk3588_pdata.revision = 1` selection
   is correct. Linux **v7.0** added a guard to `dwcmshc_rk3568_set_clock()` that
   `goto enable_clk`s past the DLL bypass/reset block whenever the requested clock
   is ≤52 MHz while `ios.timing` still reads HS200/HS400; through v6.17 that block
   ran unconditionally. The guard is still present in mainline `master`, so this
   is current upstream behaviour, not a regression somebody has already fixed.
   Any repair is a real kernel change (a driver patch, or a board DT patch
   dropping `mmc-hs400-*` to settle the part at HS200) carried in
   `CERALIVE/rk3588-kernel-patches` and validated on a bench board — never
   guessed at against a production eMMC. Full analysis:
   `.omo/evidence/device-platform-wave4/task-28-wifi-emmc-findings.md`; the
   later successful enumeration is recorded in
   `.omo/evidence/device-platform-wave4/task-rauc-ota-validation.md` §8a.
4. **A board's DTB filename comes from whichever kernel tree built it — RESOLVED,
   via a board-declared per-variant override.** The vendor BSP and the mainline
   source this variant compiles are two different trees and need not agree on a
   given board's DTB name. Because the board always wins the merge, a family
   variant cannot restate that name — so the **board** declares it, scoped to the
   variant. See §9 below for the mechanism; the short version is
   `variant_overrides.edge.dtb_name` in `orange-pi-5-plus.yaml`.

   **Both trees happen to agree on the Orange Pi 5+ today** — it is
   `rk3588-orangepi-5-plus.dtb` in the vendor BSP and in mainline. The board was
   originally declared as `rk3588s-orangepi-5-plus.dtb`, inferred from the
   "5 Plus (RK3588S)" marketing name; the 5 Plus in fact carries the full RK3588,
   and no version of `linux-dtb-vendor-rk35xx` in the Armbian archive has ever
   shipped an `rk3588s-` spelling for it. That was corrected on the production
   path; the override is retained as an explicit assertion so a future divergence
   in either tree moves exactly one line.

   `rock-5b-plus` never needed it: it declares `rk3588-rock-5b-plus.dtb`,
   mainline v7.1.7 builds exactly that name, and the built `.deb` ships it (228
   `rockchip/*.dtb` entries in total). Note that until the `deb_lists_path` fix in
   item 1, this board *also* failed the DTB check — with the divergence wording
   above and an empty "DTBs actually present" list. **An empty list there means the
   listing is broken, not that the DTB is missing.**
5. **No `.deb` produced by this stage may be published.** It is a local build
   input only; nothing here uploads to apt/R2.
6. **D3 is not reopened.** The shipped kernel is still the Armbian vendor BSP.
   See [`kernel-currency-watch.md`](kernel-currency-watch.md) for the two precise
   triggers that would revisit that decision; this variant existing is not one of
   them.
7. **The `edge` `.deb` is not byte-reproducible.** `git am` stamps the committer
   date from the wall clock, so the post-`am` commit SHAs differ on every run.
   `SOURCE_DATE_EPOCH`/`KBUILD_BUILD_TIMESTAMP` are pinned and the *content* is
   stable — two consecutive builds produced identical package versions, identical
   `.deb` file lists and an identical `/boot/config-*` — but the archive bytes
   differ. This is exactly why `CONFIG_LOCALVERSION_AUTO=n` and the
   `kernelrelease` assertion matter: without them the package NAME would inherit
   that nondeterminism.

---

## 8. Board variant overrides — when a board fact differs per variant

The merge order is `family -> variant -> board`, and **the board wins last**. That
is intentional and tested: a variant must never be able to restate a
board-specific fact. It also means a variant cannot fix the one thing that
genuinely differs per variant *and* per board — the DTB filename, which follows
whichever kernel tree the DTB came from.

So the **board** (never the family) may declare a `variant_overrides:` map:

```yaml
# manifests/boards/orange-pi-5-plus.yaml
dtb_name: rk3588-orangepi-5-plus.dtb         # vendor BSP, the default path

variant_overrides:
  edge:
    dtb_name: rk3588-orangepi-5-plus.dtb     # mainline v7.1.7
```

The rules, all enforced:

* **It is applied AFTER the board**, so board-wins-last is strengthened, not
  weakened — the override is a board fact that happens to be scoped to a variant.
  A plain family-variant overlay still loses to the board exactly as before.
* **The key is stripped before flattening whether or not a variant is selected**,
  the same discipline as the family's `variants:`. A board that declares one
  resolves byte-identically on the default path to a board that never did — pinned
  by the same `vendor-baseline/*.params` golden fixtures.
* **It is deliberately narrow**: `dtb_name` is the only permitted field. This is a
  DTB-naming mechanism, not a general board-overrides-the-variant escape hatch.
  The schema rejects anything else, and `default` is reserved exactly as it is for
  `variants:`.
* **An override naming a variant the family does not declare is FATAL on every
  resolve**, including the default path. A typo'd name that silently never applied
  would be the worst possible outcome for a mechanism whose entire job is to
  change one filename.

Because `DTB_NAME` is a single resolved parameter, one override moves every
consumer together — the U-Boot `fdtfile`, the disk assembler, the platform DTB
install mapping, and `build-kernel.sh`'s validation of the built `.deb`. There is
no second place to keep in sync.

`rock-5b-plus` declares no override and needs none.

---

## 9. Files

| Path | Role |
|---|---|
| `manifests/schema/family.schema.json` | `variants:` map + `kernel_source:` `$defs` |
| `manifests/schema/board.schema.json` | `variant_overrides:` map + its `$defs` |
| `manifests/boards/orange-pi-5-plus.yaml` | the `edge` DTB-name override |
| `manifests/families/rk3588.yaml` | the `edge` + `vendor-patched` variant declarations + every pin |
| `manifests/kernel/rk3588-edge.fragment` | the `edge` Kconfig fragment (defconfig mode) |
| `manifests/kernel/rk3588-vendor-patched.absent` | the `vendor-patched` reviewed allow-absent list (config-file mode, §2c) |
| `lib/resolve.py` | variant merge, `variants:`/`variant_overrides:` stripping, derived suppression set |
| `lib/resolve.sh` | `--variant` / `CERALIVE_KERNEL_VARIANT` |
| `lib/build-kernel.sh` | the build stage, incl. `fetch_pinned_tree` + the build-job preflight (§3b) |
| `ci/Dockerfile.kernel` | the builder image (base digest comes from the manifest) |
| `lib/orchestrate.sh` | stage wiring, suppression export, uniqueness check |
| `lib/fetch-debs.sh` | suppression filter in `collect_declared_bsp_pkgs` |
| `mkosi/mkosi.images/platform/mkosi.postinst` | the DTB install mapping + the `/boot` artifact mapping (§4b) |
| `lib/verify-boot-artifacts.sh` | the `[6b/9]` build gate on `/boot` completeness |
| `lib/verify-kernel-config.sh` | the in-container config-survival gate, both modes (§2c, §6b) |
| `tests/boot-artifacts.bats` | the `/boot` contract for BOTH kernel paths |
| `tests/kernel-config-fragment.bats` | the fragment-survival contract (§6b) |
| `tests/kernel-build-resilience.bats` | fetch retry, never-retried pin mismatch, build-job preflight (§3b) |
| `tests/variant-contract.bats` §26 | 36 tests, incl. the byte-identity proof and its teeth |
| `tests/manifests/fixtures/vendor-baseline/` | the pre-change golden resolver output |
