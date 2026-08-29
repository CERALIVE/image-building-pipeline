# Trixie package-list resolution report

The record of resolving `manifests/packages/**` against Debian **trixie**, done as
part of the bookworm → trixie migration. It answers one question per package —
*does this name still exist, and does it still do the same thing?* — and states
how each answer was obtained.

Companion to [`size-notes.md`](size-notes.md) §9 (the Mesa/LLVM ledger this
migration re-measured) and to `manifests/target-release.env`, which is the single
source of truth for the suite itself.

## How this was verified

Every name was resolved against a **real Debian trixie `arm64` package index**,
not from memory and not from `packages.debian.org` prose:

```bash
docker run -d --platform linux/arm64 debian:trixie-slim sleep 3600
# main + contrib + non-free + non-free-firmware all enabled
apt-cache policy <pkg>          # per-package candidate + Architecture
apt-get install --dry-run …     # the WHOLE list, as one transaction
```

`arm64` matters: it is the architecture the shipped RK3588 image is built for, and
an `amd64`-only check would have reported `Architecture: all` packages
(`ca-certificates`, `dnsmasq`, `ipcalc`, `mobile-broadband-provider-info`,
`wireless-regdb`, `nginx-light`, `rauc-service`) misleadingly.

**Scope limit, stated plainly:** this is index resolution plus a whole-set
dependency solve. It is **not** a rootfs build. A real CI-dispatched `./build`
is still required before release — see "What this does not prove" at the end.

## Result

**68 names checked. 66 unchanged. 2 diverged.** At the time of that audit no `t64`
rename touched a name in the lists. A later real image build exposed one additional
compatibility boundary in the pinned third-party Rockchip package, described below.

### `libv4l-0` → `libv4l-0t64`: apt compatibility is not dpkg compatibility

Trixie installs the real library from `libv4l-0t64` at
`/usr/lib/aarch64-linux-gnu/libv4l2.so.0.0.0`. The package declares
`Provides: libv4l-0`, so apt can satisfy `rockchip-multimedia-config`'s old-name
dependency. Its postinst does not stop at dependency resolution, however:

```sh
libv4l_filename=$(dpkg -L libv4l-0 | grep libv4l2.so.0.0.0)
cp ${libv4l_filename} /usr/lib64/libv4l2.so
```

`dpkg` records the installed provider as `libv4l-0t64`, so the exact-name listing
fails. A fileless transitional package also fails because the grep needs a payload
path. The pipeline therefore builds an arm64 package named `libv4l-0` at fetch time.
It depends on `libv4l-0t64` and contains one file: the collision-free symlink
`/usr/share/libv4l-0-compat/libv4l2.so.0.0.0` pointing at the real t64 library.
Plain `cp` dereferences that link. The package is explicitly named first in the same
platform-layer `mkosi-install` transaction as `rockchip-multimedia-config`; it owns
neither `/usr/lib/aarch64-linux-gnu/libv4l2.so.0.0.0` nor the adjacent soname link.
This preserves the SHA-256-pinned third-party `.deb` unchanged while giving its
legacy maintainer script a real dpkg package record and readable path.

### The two divergences

| Old name (bookworm) | Trixie verdict | Replacement | Consequence if unmigrated |
|---|---|---|---|
| `cpufrequtils` | **REMOVED from Debian** — left testing 2023-10-28, left unstable 2024-06-16. No candidate on trixie in any component. | `linux-cpupower` (6.12.105-1, arm64, main) **+ a new applier unit** | Hard build failure: `E: Unable to locate package cpufrequtils` |
| `rauc-hawkbit-updater` | **Not in trixie.** Debian now packages it (accepted to unstable 2026-03-16, migrated to testing 2026-03-21 as `1.4-1`) but testing is *forky*, so it reaches sid/forky and not trixie stable. | Stays a pre-staged **backport `.deb`**, rebuilt against trixie | None at build time (it was already a comment, not an apt line) — but the recipe's dependency names were stale |

### `cpufrequtils` → `linux-cpupower` is **not** a drop-in rename

This is the finding that mattered most, because the naive fix is silent.

`cpufrequtils` did not just provide a binary — it provided the *mechanism*. It
shipped `/etc/init.d/cpufrequtils` plus `S01cpufrequtils`/`S01loadcpufreq` sysv
links which read `GOVERNOR=` out of `/etc/default/cpufrequtils` at boot. The only
thing this repo ever wrote was that one config line.

`linux-cpupower` ships **exactly one file** — `/usr/bin/cpupower`. Verified with
`dpkg -L` in the trixie arm64 container: no unit, no init script, no
`/etc/default` hook. And nothing else in trixie reads `/etc/default/cpufrequtils`.

So swapping only the package name would have produced **no error at all**: the
postinst would keep writing a config file with no reader, the build would stay
green, the image would boot, and the `performance` governor pin would simply never
be applied again. That is the repo's documented dead-writer defect class.

The migration therefore also:

- deletes the `/etc/default/cpufrequtils` write from the **live** runtime postinst
  *and* from its canonical `customize/sysctl-tuning.sh` twin, and
- adds `ceralive-cpu-governor.service` (`mkosi/runtime/`, installed by
  `postinst.d/hardware.sh::setup_cpu_governor`) as the replacement applier. It
  runs `cpupower frequency-set -g performance` and then **verifies the kernel
  actually took it**, because `frequency-set` can report success while a policy
  silently keeps its old governor.

CLI mapping for anything else that referenced the old tools:
`cpufreq-set -g X` → `cpupower frequency-set -g X`;
`cpufreq-info` → `cpupower frequency-info`.

**It is not coupled to a Debian kernel** despite its `6.12.x` version string
(it is built from the Debian `linux` source package). Its arm64 `Depends:` is only
`libc6` + `libcpupower1` — no `linux-image-*`, no `linux-base` — and it drives the
running kernel through sysfs. That is what makes it valid on the Armbian vendor
6.1 BSP kernel the image actually ships.

### `rauc-hawkbit-updater` — the recipe's dependencies were the stale part

The package stays a pre-staged backport, so the verdict did not change; the
**recipe** did. The `t64` transition renamed two of the three libraries it links,
so a bookworm-era build-dependency list names packages that no longer exist:

| Bookworm spelling | Trixie spelling |
|---|---|
| `libcurl4` | **`libcurl4t64`** |
| `libglib2.0-0` | **`libglib2.0-0t64`** |
| `libjson-glib-1.0-0` | `libjson-glib-1.0-0` (unchanged) |

The fix is to build from the current Debian packaging
(`salsa.debian.org/debian/rauc-hawkbit-updater`, `1.4-1`) rather than hand-porting
the old list — that gets all three right automatically. Upstream's newest release
is still `v1.4` (2025-07-14), so the backport tracks current upstream.

## Same name, changed behaviour

These resolved unchanged but do **not** mean what the old comments said.

| Package | bookworm | trixie | Why it matters |
|---|---|---|---|
| `rauc` / `rauc-service` | 1.8-2 | **1.13-3+deb13u1** | Five-minor jump. `get-current` goes live (added 1.11), so the boot adapter's forward-compat arm is now a real code path. `check-purpose=` now exists (1.11) but is left UNSET, so verification still falls back to OpenSSL `smime_sign` exactly as on 1.8 — the existing dual-EKU leaf keeps verifying and **no PKI action is needed**. Tightening that is todo 12's call, not a side effect of a suite bump. |
| `squashfs-tools`, `e2fsprogs` | explicit entries | still explicit, still required | Confirmed both are only `Suggests:` of trixie's `rauc`, never `Depends:`. 1.13 still shells out to `unsquashfs` and `mkfs.ext4`. Dropping either still breaks OTA on-device only. |
| `pulseaudio` (debug delta) | user units only | user units **+ one system unit** | `pulseaudio-enable-autospawn.service` now exists. Conclusion unchanged (no user session ⇒ never autostarts) but the *reason* changed, and this image runs `preset-all` on first boot. Debug images only. |
| `conntrack` | 1:1.4.7-1+b2 | 1:1.4.8-2+b1 | Re-confirmed `conntrack-tools` is **still** only a source package with no binary on trixie — asking for it still fails. |
| `apt-transport-https` | `Section: oldlibs` dummy | still `oldlibs` (3.0.3) | Stays removed; the reasoning survives the suite bump. |
| `fonts-terminus` | one TTF, no PSF | still one TTF, no PSF (1.2.0+ds2-4) | Stays removed; the console-font gap is still a real PSF-provider gap. |

## The Mesa / LLVM prune — the highest-consequence change

Not a package *name* change, but a package *layout* change that silently
invalidated the file-level prune. Full ledger in
[`size-notes.md`](size-notes.md) §9.

| | bookworm (Mesa 22.3 / LLVM 15) | trixie (Mesa 25.0.7 / LLVM 19) |
|---|---|---|
| LLVM object | `libLLVM-15.so.1` | **`libLLVM.so.19.1`** (`libLLVM-19.so` is a 15 B symlink) |
| Gallium megadriver | inside `libgl1-mesa-dri`, as one inode hardlinked 43× under `dri/*_dri.so` | **moved to a new `mesa-libgallium` package** as `libgallium-25.0.7-2+deb13u1.so` at the library root |
| `dri/` contents | the megadriver itself (23.9 MB) | 55 symlinks + a 133 KB `libdril_dri.so` shim |
| total prunable | 157,637,616 B | **185,262,968 B** |

The old globs matched **0 bytes of LLVM** and **none of Gallium**, so the prune
would have recovered ~27 MB instead of ~185 MB — leaving ~158 MB of unreachable
payload and pushing both RK3588 boards (1,412,259,840 B / 1,418,792,960 B) through
the 1.5 GB `[6c/9]` size gate.

The replacement globs are **version-wildcarded on purpose**
(`libLLVM*.so*`, `libgallium-*.so`). Pinning is what broke them, and for
`libgallium` wildcarding is mandatory: its filename embeds the full Debian
revision, so any Mesa point release renames the file.

Unreachability is unchanged and was re-proven with `objdump -p` over every
installed ELF. The DT_NEEDED chain is still closed, with one new hop:

```
dri/libdril_dri.so, gbm/dri_gbm.so  ->  libgallium-25.0.7-2+deb13u1.so
libgallium-25.0.7-2+deb13u1.so      ->  libLLVM.so.19.1
libLLVM.so.19.1                     ->  libz3.so.4
```

## Full resolution table

All resolved on trixie `arm64`. `all` = `Architecture: all`.

| Package | Verdict | Trixie candidate |
|---|---|---|
| `ca-certificates` | OK (all) | 20250419 |
| `openssl` | OK | 3.5.7-1~deb13u2 |
| `nginx-light` | OK (all) | 1.26.3-3+deb13u7 |
| `network-manager` | OK | 1.52.1-1 |
| `systemd-resolved` | OK | 257.13-1~deb13u1 |
| `dnsmasq` | OK (all) | 2.91-1+deb13u1 |
| `iproute2` | OK | 6.15.0-1 |
| `net-tools` | OK | 2.10-1.3 |
| `ipcalc` | OK (all) | 0.51-1 |
| `usb-modeswitch` | OK | 2.6.1-4+b2 |
| `uhubctl` | OK | 2.6.0-1 |
| `gstreamer1.0-tools` | OK | 1.26.2-2 |
| `gstreamer1.0-alsa` | OK | 1.26.2-1+deb13u1 |
| `gstreamer1.0-nice` | OK | 0.1.22-1 |
| `gstreamer1.0-plugins-base` | OK | 1.26.2-1+deb13u1 |
| `gstreamer1.0-plugins-good` | OK | 1.26.2-1+deb13u2 |
| `gstreamer1.0-plugins-bad` | OK | 1.26.2-3+deb13u3 |
| `gstreamer1.0-plugins-ugly` | OK | 1.26.3-4+deb13u1 |
| `gstreamer1.0-libav` | OK | 1.26.2-1+deb13u1 |
| `v4l-utils` | OK | 1.30.1-1 |
| `ffmpeg` | OK | 7:7.1.5-0+deb13u1 |
| `modemmanager` | OK | 1.24.0-1+deb13u1 |
| `libqmi-utils` | OK | 1.36.0-1 |
| `libmbim-utils` | OK | 1.32.0-1 |
| `mobile-broadband-provider-info` | OK (all) | 20250613-2 |
| `iw` | OK | 6.9-1+b1 |
| `wpasupplicant` | OK | 2:2.10-24 |
| `wireless-regdb` | OK (all) | 2026.05.30-1~deb13u1 |
| `hostapd` | OK | 2:2.10-24 |
| `bluez` | OK | 5.82-1.1 |
| `bluez-alsa-utils` | **REMOVED at todo 28** (resolved fine at 4.3.1-3; retired for BT-manager exclusivity, not for availability) | — |
| `libasound2-plugin-bluez` | **REMOVED at todo 28** (same) | — |
| `pipewire` | **ADDED at todo 28** | 1.4.2-1 |
| `wireplumber` | **ADDED at todo 28** — note the version family | **0.5.8-2** |
| `pipewire-alsa` | **ADDED at todo 28** | 1.4.2-1 |
| `gstreamer1.0-pipewire` | **ADDED at todo 28** | 1.4.2-1 |
| `libspa-0.2-bluetooth` | **ADDED at todo 28** | 1.4.2-1 |
| `avahi-daemon` | OK | 0.8-16 |
| `avahi-utils` | OK | 0.8-16 |
| `libnss-mdns` | OK | 0.15.1-4+b1 |
| `chrony` | OK | 4.6.1-3+deb13u2 |
| `cpufrequtils` | **REPLACED → `linux-cpupower`** | 6.12.105-1 |
| `rsync` | OK | 3.4.1+ds1-5+deb13u4 |
| `curl` | OK | 8.14.1-2+deb13u4 |
| `sudo` | OK | 1.9.16p2-3+deb13u2 |
| `kbd` | OK | 2.7.1-2 |
| `nftables` | OK | 1.1.3-1 |
| `conntrack` | OK | 1:1.4.8-2+b1 |
| `rauc` | OK (1.8 → 1.13) | 1.13-3+deb13u1 |
| `rauc-service` | OK (all) | 1.13-3+deb13u1 |
| `squashfs-tools` | OK | 1:4.6.1-1+b1 |
| `e2fsprogs` | OK | 1.47.2-3+b11 |
| `zstd` | OK | 1.5.7+dfsg-1 |
| `u-boot-tools` | OK | 2025.01-3 |
| `rauc-hawkbit-updater` | **absent — backport retained** | (sid/forky only, 1.4-1) |

`development.delta.list` (debug images only) resolved clean in full: `python3`
3.13.5-1, `strace` 6.13+ds-1, `tcpdump` 4.99.5-2, `alsa-utils` 1.2.14-1,
`usbutils` 1:018-2, `pciutils` 1:3.13.0-2, `lsof`
4.99.4+dfsg-2, `i2c-tools` 4.4-2, `can-utils` 2023.03-1+b2, `htop` 3.4.1-5,
`iotop` 0.6-42-ga14256a-0.3+b1, `nethogs` 0.8.8-1, `vnstat` 2.13-1, `nano`
8.4-1+deb13u1, `iperf3` 3.18-2+deb13u2, `socat` 1.8.0.3-1, `netcat-openbsd`
1.229-1.

**`pulseaudio` 17.0+dfsg1-2+b1 was in that set and left at todo 28**, and the
reason is a *conflict*, not an availability problem — which is why it does not
appear as an `absent` row above. `pipewire-alsa` declares `Conflicts: pulseaudio`,
and the runtime layer installs `shared.list` plus this delta as ONE `apt-get
install`, so a debug build would have failed outright. Verified against the same
real index rather than reasoned about:

```
$ apt-get install -s --no-install-recommends pipewire-alsa pulseaudio
The following packages have unmet dependencies:
 pipewire-alsa : Conflicts: pulseaudio but 17.0+dfsg1-2+b1 is to be installed
E: Unable to correct problems, you have held broken packages.
E: ... Reached two conflicting decisions:
   1. pulseaudio:arm64=17.0+dfsg1-2+b1 is selected for install
   2. ... pipewire-alsa:arm64 Conflicts pulseaudio
```

This is the third distinct shape of package surprise this migration has produced,
after a rename (`libwpewebkit-1.1-0` → `libwpewebkit-2.0-1`) and a removal
(`cpufrequtils`): a package that resolves perfectly well and still cannot be
installed, because of a relation on a package added elsewhere in the same list.

**Two more findings from the todo-28 resolution worth not re-deriving.**
`wireplumber` is **0.5.8-2** and versions on its own schedule — the whole PipeWire
family being 1.4.2-1 makes `wireplumber=1.4.2-1` the natural guess and it names a
version that does not exist. And `libpipewire-0.3-0` is **absent**: the `t64`
transition renamed it `libpipewire-0.3-0t64`. Nothing in `shared.list` names it
directly (it arrives transitively through `pipewire-bin`), so a list written from
a bookworm-era memory would fail only if someone pinned the library explicitly.

`rk3588.delta.list` and `x86_64.delta.list` carry **no active package lines** (both
are documented-empty by design), so neither had anything to resolve.
`rk3588-vendor-kernel-extensions.list` used to name `ceralive-cls-fw`, which this
pipeline built rather than resolved, so it was correctly absent from this table.
That list, the package and the whole kernel-extension mechanism are retired
(2026-08-28) — the production kernel is source-built with `CONFIG_NET_CLS_FW=y`
in-tree — so there is nothing left to exclude.

## What this does not prove

Stated explicitly so the release chain does not over-read it:

- **No rootfs was built.** This is index resolution plus a whole-set dependency
  solve, executed in a `debian:trixie-slim` arm64 container. It proves every name
  exists and that the set co-installs without conflict; it does **not** prove the
  image builds, boots, or fits the size gate.
- **The size-gate consequence is computed, not measured.** The ~185 MB prune total
  is summed from real file sizes in that container, but no `[6c/9]` measurement was
  taken against a real emitted rootfs tar.
- **The governor unit has not run on hardware.** It is proven against synthetic
  policy trees (apply-and-verify, no-cpufreq no-op, and an unavailable-governor
  refusal), not on a board.

A real CI-dispatched `./build` on the trixie suite remains required before release.
