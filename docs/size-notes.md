# CeraLive v2 — Image Size Notes

Running record of size-reduction levers applied to the mkosi build and the
rationale behind each. Numbers marked *(estimate)* are derived from Debian
`Installed-Size` metadata and published Armbian package sizes, not from a wet
build on this host (no RK3588 board / full-build budget in the dev environment);
they are upper-bound guidance, not contractual figures.

---

## 1. Documentation strip — `WithDocs=no`

Already set on every layer (`base`, `platform`, `runtime`, `app`). mkosi drops
man pages, `/usr/share/doc`, info pages, and changelogs at install time. No
change needed in Task 19 — verified present.

---

## 2. Locale strip — single-locale C.UTF-8 appliance (Task 19)

### What changed

`mkosi/mkosi.images/{base,platform,runtime,app}/mkosi.conf`:

- `Locale=C.UTF-8` + `LocaleMessages=C.UTF-8` on `base` — pins `/etc/locale.conf`
  to `LANG=C.UTF-8`. glibc 2.36 (bookworm) ships **C.UTF-8 built into libc**, so
  no `locale-gen` run and no `/usr/lib/locale/locale-archive` are required for it
  to work.
- `RemoveFiles=/usr/share/locale/*,/usr/lib/locale/locale-archive` on **every**
  layer — purges gettext message catalogs (the per-language `.mo` files each
  package ships) and any compiled locale-archive a transitively-pulled `locales`
  package might leave behind. The glob is repeated per layer because mkosi runs
  `RemoveFiles` at the end of *each* image build, so each layer cleans the
  catalogs introduced by *its own* new packages.

### Why it is safe

C.UTF-8 carries **no** `.mo` catalog — programs fall back to their compiled-in
English `msgid` strings, which is exactly the behaviour an unattended appliance
wants. There is no interactive login user choosing a language, and CeraUI is a
self-contained web frontend that does its own i18n. Boot path (systemd / udev /
RAUC) is locale-agnostic and unaffected.

### Size impact *(estimate)*

`/usr/share/locale` is the dominant locale consumer in a server image; typical
Debian minimal + service stacks carry **~80–250 MB** of `.mo` catalogs across all
installed packages (systemd, apt, util-linux, gettext, NetworkManager, the
GStreamer/ffmpeg stack, first-party apps). The compiled `locale-archive`, if a
`locales` dependency ever generates one, adds up to a further **~200 MB** for a
default all-locales build (we never generate it, so this is purely defensive).

Net expected reduction: **~100–250 MB** off the rootfs, with **zero** functional
loss for a C.UTF-8-only device. Confirm the realised figure on the first full
RK3588 build with:

```sh
# inside the built app tree
du -sh usr/share/locale usr/lib/locale 2>/dev/null   # expect near-empty
```

---

## 3. `armbian-firmware` split audit (Task 19)

### Decision: KEEP `armbian-firmware` — do NOT swap to the Debian split

`manifests/families/rk3588.yaml` keeps `firmware_packages: [armbian-firmware]`.

### Context

`armbian-firmware` is the broad Armbian firmware bundle. Task 11 already chose it
to subsume the board WiFi/BT blobs (`rtl8852be-firmware`, `firmware-realtek`) so
boards declare no per-board firmware field. The Task 19 question: can we replace
the monolith with a narrower SoC-specific + board-WiFi-only set on bookworm arm64?

### Why the narrower swap is NOT feasible here

Both rk3588 boards run the Armbian **vendor** kernel (Decision D3), not mainline:

| Board | WiFi/BT part | Driver class |
|---|---|---|
| Radxa Rock 5B+ | Realtek **RTL8852BE** | Armbian out-of-tree vendor driver |
| Orange Pi 5+ | Broadcom **AP6275P** (`brcmfmac`) | vendor / out-of-tree |

Debian's split firmware packages (`firmware-realtek`, `firmware-brcm80211`) are
built for the **mainline in-tree** drivers and ship the generic blobs *without*
the Armbian per-board **NVRAM `.txt`** config files the vendor drivers load at
probe time. Dropping the Armbian bundle for the Debian split therefore risks the
WiFi/BT radio never associating on the vendor kernel — a board-breaking
regression that violates the "do not drop firmware the board needs" constraint.

`armbian-firmware` is also already the **trimmed** Armbian variant — it is *not*
`armbian-firmware-full`. The package still carries firmware for unrelated SoC
families. The RK3588 platform layer keeps the Armbian package installed for
provenance and board WiFi/BT coverage, but prunes firmware directories that are
irrelevant to this platform (`qcom`, `intel`, `ath10k`, `ath11k`, `ath12k`,
`updates`). The architecture-identical app layer prunes only desktop and
documentation payload, so it cannot delete architecture-specific firmware when
a non-Armbian platform path stages it.

### Size impact *(estimate)*

| Option | Approx installed size | WiFi works on vendor kernel? |
|---|---|---|
| `armbian-firmware` (current, trimmed + final RK3588 prune) | ~120–130 MB after prune | ✅ yes — board NVRAM retained |
| `armbian-firmware-full` | ~400–500 MB | ✅ yes (but much larger — rejected) |
| Debian split: `firmware-realtek` (6.7 MB) + `firmware-brcm80211` (17.7 MB) | ~24 MB | ⚠️ **at risk** — no Armbian NVRAM `.txt` |
| Debian split + `firmware-misc-nonfree` (50.5 MB) | ~75 MB | ⚠️ still missing board NVRAM |

(Debian sizes from bookworm `non-free-firmware/binary-arm64` `Installed-Size`.)

A Debian-split swap *could* save more on paper, but only by trading a
guaranteed-working vendor-kernel radio set for an unverified one. The current
compromise keeps the Armbian monolith at package level, then removes unrelated
firmware payload from the sealed appliance image.

### Re-evaluation trigger

Revisit when an RK3588 board is reachable: build a split-firmware image, confirm
`brcmfmac`/`rtw89` associate and that BT enumerates, then measure the real delta.
Until then `armbian-firmware` is the correct, safe choice.

---

## 4. Relative size regression tracking (Task 6)

### Baseline artifact and comparator

On top of the existing **1.5 GB absolute gate** (`measure-size.sh`), a relative
regression detector (`check-size-regression.sh`) warns on any growth and fails
(exit 1) if growth exceeds **50 MB** per build.

**Baseline file format** (`ci/size-baseline.json`):

```json
{
  "board": "x86-minipc",
  "bytes": 1234567890,
  "recorded_at": "2026-06-12"
}
```

| Field | Type | Purpose |
|-------|------|---------|
| `board` | string | Board identifier (e.g., `x86-minipc`, `rock-5b-plus`) |
| `bytes` | integer | Measured rootfs size in bytes (from `du --apparent-size -sb`) |
| `recorded_at` | ISO-8601 date | When the baseline was recorded (YYYY-MM-DD) |

**Comparator script** (`ci/check-size-regression.sh`):

```bash
./ci/check-size-regression.sh <current-bytes> <baseline-file>
```

- **Input:** current measured size (bytes) and baseline JSON file
- **Output:** human-readable delta line (e.g., `size-regression: baseline=1234567890 bytes, current=1245053650 bytes, delta=+10 MB`)
- **Behavior:**
  - Warns (stderr) on any growth (delta > 0)
  - Exits 0 if delta ≤ 50 MB
  - Exits 1 if delta > 50 MB (fails the CI gate)
  - Exits 2 on bad args / missing file / malformed JSON

### Updating the baseline

When intentional changes cause growth (e.g., adding a new package, enabling a feature):

1. **Measure the new size** via `measure-size.sh` or a full build
2. **Update `ci/size-baseline.json`** in the SAME PR:
   - Set `bytes` to the new measured value
   - Update `recorded_at` to the current date
   - Document the reason in the PR description (e.g., "Added cog display add-on: +15 MB")
3. **Justify the growth** in the PR description with:
   - What changed (package, feature, config)
   - Why it was necessary
   - The measured delta (e.g., "+15 MB for cog + WPEWebKit")
4. **CI will pass** once the baseline is updated to match the new size

### Integration with CI

The comparator is wired into CI jobs after `measure-size.sh` runs:

```bash
# After building the image and measuring its size:
./lib/measure-size.sh <board> <rootfs-artifact>  # emits measured=<N> bytes
./ci/check-size-regression.sh <measured-bytes> ci/size-baseline.json
```

Both gates must pass:
1. **Absolute gate:** measured size ≤ 1.5 GB (enforced by `measure-size.sh`)
2. **Relative gate:** growth ≤ 50 MB (enforced by `check-size-regression.sh`)

If either fails, the build is rejected and no `.raucb` is produced.

---

## 5. CeraUI TLS front — `nginx-light` + `openssl` (Task 15)

### What changed

`manifests/packages/shared.list` gains two packages so the device can serve the
CeraUI control plane over HTTPS on 443 (SC3):

- `nginx-light` — terminates TLS on 443 and reverse-proxies to the CeraUI backend
  on `127.0.0.1:80` (WebSocket-upgrade aware). Port 80 is left to the backend; no
  redirect. `nginx-light` is the **smallest** nginx flavour that still carries the
  `http_proxy` + `http_ssl` modules — `nginx-full`/`nginx-extras` add mail, stream,
  and a large extra-module set we do not use.
- `openssl` — the CLI used by `ceralive-tls-firstboot` to mint the per-device
  self-signed cert. On Debian it is `Priority: important` (almost always already
  present); pinned explicitly so cert generation never relies on a transitive pull.

### Size impact *(estimate)*

Figures from bookworm `arm64` `Installed-Size` metadata (not a wet build on this
host — upper-bound guidance, consistent with §1–§4).

| Package | Approx installed size | Notes |
|---|---|---|
| `nginx-light` | ~1.3 MB | binary + light module set |
| `nginx-common` (dep) | ~0.7 MB | shared config/init; pulled by nginx-light |
| `libnginx-mod-*` (deps) | ~0.5 MB | http modules nginx-light links |
| `openssl` | ~1.5 MB | usually already present (Priority: important) → often **0** net |

**Net expected delta: ~+3–4 MB** (≈ +2.5 MB if `openssl` is already in the base).
This is comfortably inside both the **1.5 GB absolute gate** and the **+50 MB
relative regression gate** (§4). The self-signed cert + key live on `/data`
(runtime artifact, not in the rootfs slot), so they add **nothing** to the image.

### Re-evaluation / baseline note

When the first full build measures the realised rootfs size, bump
`ci/size-baseline.json` by the observed delta in the same PR (per §4 procedure)
and note "Added nginx TLS front: +~N MB" in the description. Until a wet build runs
this is a paper estimate; the absolute gate remains the hard backstop.

---

## 6. SRT ingest gateway — served by MediaMTX (Todo 14 B2, no extra package)

### What changed

The LAN SRT ingest leg is served by MediaMTX's built-in SRT server, on the same
single MediaMTX process as the RTMP leg (`ceralive-rtmp-gateway.service`, Todo 14):
`srt: yes` + `srtAddress: :4001` in `mediamtx.yml` open the SRT listener on `:4001`,
and cerastream pulls the SRT read stream on loopback
(`srt://127.0.0.1:4001?streamid=read:publish/live`). No separate SRT gateway process
and no separate apt package are involved.

- The former `srt-tools` package (which shipped `/usr/bin/srt-live-transmit` for the
  now-retired standalone SRT gateway) is **removed from
  `manifests/packages/shared.list`** — nothing else in the image references it.

### Size impact *(estimate)*

The SRT leg now adds **0 bytes** beyond what Todo 14 already counts: it rides the same
pinned MediaMTX binary (recorded in `manifests/size-budget.json` /
`/usr/local/bin/mediamtx`). Removing `srt-tools` reclaims the space it previously
occupied.

| Package | Approx installed size | Direction |
|---|---|---|
| `srt-tools` | ~3.05 MB (3122 KiB) | **REMOVED** (reclaimed) |
| `libsrt1.5-gnutls` (was a `srt-tools` dep) | ~0.85 MB (875 KiB) | **REMOVED** (no longer pulled) |

**Net expected delta: ~−3.9 MB** vs the previous topology before the first-party SRT
runtime is added. The release image instead installs `libsrt1.5-ceralive` from the
CeraLive apt repository; it replaces both Debian TLS flavors and is accounted with
the App-layer first-party artifacts, not the shared runtime manifest.

### Re-evaluation / baseline note

When the first full build measures the realised rootfs size, fold this reclaim
together with §5 (nginx) and Todo 14 (MediaMTX, fetched to `/usr/local/bin`) when
bumping `ci/size-baseline.json`, and note "Removed srt-tools; MediaMTX now serves
SRT: −~4 MB" in the description. Until a wet build runs this is a paper estimate; the
absolute gate remains the hard backstop.

## 7. LAN-ingest ingress firewall — `nftables` (Todo 14/15 INGRESS BOUNDARY)

### What changed

`manifests/packages/shared.list` gains one package so the device can load the LAN
ingest ingress firewall (`ceralive-ingest-firewall.service`): the ruleset
`/etc/ceralive/ingest-firewall.nft` DROPs inbound `:1935` (RTMP) + `:4001` (SRT) —
both served by the single MediaMTX gateway (Todo 14 B2) — on the WAN/modem/WWAN/ppp
uplink classes so the UNAUTHENTICATED v1 ingest gateway is reachable from LAN/hotspot
ONLY (see `docs/DEFERRED.md` items 7 & 8).

- `nftables` — ships `/usr/sbin/nft` (the ruleset loader). The oneshot unit runs
  `nft -f /etc/ceralive/ingest-firewall.nft` at boot into a dedicated
  `inet ceralive_ingest_fw` table (policy-accept chain; only the two ingest ports on
  the WAN classes are dropped — no default-deny, so no other service is affected).

### Size impact *(estimate)*

Figures from bookworm `arm64` `Installed-Size` metadata (not a wet build on this host
— upper-bound guidance, consistent with §1–§6).

| Package | Approx installed size | Notes |
|---|---|---|
| `nftables` | ~0.9 MB (the `nft` binary) | the ruleset loader |
| `libnftnl11` / `libmnl0` (deps) | ~0.4 MB | netlink helpers |
| `libnftables1` (dep) | **0 net** | already present in the base layer (pulled by NetworkManager — confirmed in the built app tree `libnftables.so.1`) |

**Net expected delta: ~+1.3 MB** (`nft` + libnftnl/libmnl; `libnftables1` already
present). Comfortably inside both the **1.5 GB absolute gate** and the **+50 MB
relative regression gate** (§4). The firewall holds no state and writes nothing to the
rootfs beyond the ruleset + unit + apt payload.

### Re-evaluation / baseline note

Fold this delta together with §5 (nginx), §6 (srt-tools reclaim) and Todo 14 (MediaMTX)
when bumping `ci/size-baseline.json`, and note "Added nftables LAN-ingest firewall:
+~1.3 MB" in the description. Until a wet build runs this is a paper estimate; the
absolute gate remains the hard backstop.

---

## 8. First REAL measurement — the wet build (2026-08-02)

Every "*(estimate)*" above was a paper figure. This section records the first
committed measurement from actual wet vendor-BSP production builds, and it
supersedes those estimates as the reference for the absolute and relative gates.

### What was measured

Both RK3588 boards, built from `01975f6` on the **production path** — vendor BSP
kernel, no `--variant`, no `CERALIVE_BENCH_LABELS` — then measured with
`lib/measure-size.sh` against the emitted normalized `rootfs.tar`:

| board | measured (bytes) | vs the 1.5 GB ceiling |
|---|---:|---:|
| `rock-5b-plus` | 1,569,914,880 | **+69,914,880 over** |
| `orange-pi-5-plus` | 1,576,458,240 | **+76,458,240 over** |

The two boards differ by exactly 6,543,360 B, which is board-specific U-Boot and
firmware payload — the OS content is otherwise identical.

### The ceiling stays at 1.5 GB

`rootfs_bytes_max` is deliberately **NOT** raised to match. Raising it would
launder a real overage into a passing gate. The recorded `measured` value in
`manifests/size-budget.json` is the honest number; closing the ~70 MB gap is
package/file-level slimming work tracked separately.

At the time of this measurement nothing in `orchestrate.sh` invoked
`measure-size.sh`, so a real build did not fail on it. The only live caller was
the `v2-ci.yml` size job, which measures a synthetic 4 KB tree — which is exactly
how a 65-76 MB overage shipped while the docs claimed the gate ran after every
build. Wiring it in was held back deliberately: turning it on that day would have
failed every RK3588 build. §9 (the Mesa prune) removed that blocker and §10
records the wiring.

### Where the bytes are (rock-5b-plus, summed from `tar -tvf` by path prefix)

| prefix | bytes |
|---|---:|
| `/usr` | 1,380,532,159 |
| `/boot` | 156,107,754 |
| `/var` | 17,558,206 |
| `/etc` | 1,652,044 |
| everything else | 5,490 |

Measure shipped bytes this way — **never** dpkg `Installed-Size`, which is
unreliable here: `adwaita-icon-theme` reports ~20 MB to dpkg and ships **0 bytes**,
because the app layer already deletes `/usr/share/icons`.

### Growth since the previous (uncommitted) 2026-07-31 measurement

`rock-5b-plus` went 1,565,081,600 → 1,569,914,880, i.e. **+4,833,280 B**, and
`orange-pi-5-plus` moved by the same amount. That entire drift is one package:
`bluez` + `libbluetooth3` ship 4,829,217 B of files, added to `shared.list` in
PR #90. No other size-relevant change landed in between.

### Full methodology and the live-board delta attribution

The complete write-up — build environment, both artifact SHA-256s, the
`du`-vs-`du` comparison against a real board, and the category breakdown
explaining why a dev board's rootfs reads 3.77 GB when the image is 1.57 GB —
is in `.omo/evidence/device-platform-wave4/task-31-measurement.md` (workspace
evidence tree, outside this repo).

---

## 9. Mesa software-GL prune — the 157.6 MB the device cannot execute (2026-08-02)

The single largest item in §8's composition is not multimedia. It is LLVM.

### The dependency chain, and why `apt remove` is not the lever

`gstreamer1.0-plugins-bad` hard-`Depends:` its way to `libgl1-mesa-dri`, whose
Gallium software rasterizer links LLVM's JIT — and LLVM in turn links the Z3 SMT
solver. Three packages, 157.6 MB of shipped bytes:

| file | package | bytes |
|---|---|---:|
| `/usr/lib/aarch64-linux-gnu/libLLVM-15.so.1` | `libllvm15` | 111,631,520 |
| `/usr/lib/aarch64-linux-gnu/libz3.so.4` | `libz3-4` | 22,090,928 |
| `/usr/lib/aarch64-linux-gnu/dri/*_dri.so` | `libgl1-mesa-dri` | 23,915,168 |
| **total** | | **157,637,616** |

`apt remove libgl1-mesa-dri` cascades into the plugin set cerastream needs, so
the lever is file-level `RemoveFiles=` in the runtime layer — the same technique
as the §2 locale strip. The packages stay installed and their dpkg metadata stays
intact; only the payload files go.

**The DRI directory holds ONE file, hardlinked 43 ways.** `armada-drm_dri.so`,
`swrast_dri.so`, `rockchip_dri.so`, `panfrost_dri.so` and 39 more are all the
same inode — Mesa's megadriver under 43 names. Removing "just the software
rasterizer" recovers **zero** bytes; the 23.9 MB is only released when every link
goes. That is why the glob covers the whole `*_dri.so` set rather than one name.

### Why these files are unreachable on this device

Four independent checks, all run against a real built rootfs and a real board:

1. **Mali wins the loader path.** `libmali-valhall-g610-g24p0-wayland-gbm` ships
   `/etc/ld.so.conf.d/00-aarch64-mali.conf` (`/usr/lib/aarch64-linux-gnu/mali`).
   The `00-` prefix sorts before `aarch64-linux-gnu.conf`, so `ldconfig` records
   the Mali entry FIRST and `ld.so` takes it. On the board:

   ```
   libEGL.so.1    => /usr/lib/aarch64-linux-gnu/mali/libEGL.so.1
   libEGL.so.1    => /lib/aarch64-linux-gnu/libEGL.so.1
   libGLESv2.so.2 => /usr/lib/aarch64-linux-gnu/mali/libGLESv2.so.2
   libgbm.so.1    => /usr/lib/aarch64-linux-gnu/mali/libgbm.so.1
   ```

   Mesa's `libEGL_mesa` and `libgbm` — the two libraries that `dlopen` a DRI
   driver — are therefore never reached.
2. **The one un-overridden entry point needs an X server.** `libGL.so.1` has no
   Mali counterpart and still resolves to Mesa, but its DRI load happens inside
   `libGLX_mesa` at GLX context creation. The image ships no X server and no
   Xwayland, so there is no display for it to open. The kiosk stack
   (`kiosk-display.md`) is documented-but-unimplemented and, when it lands, is
   specced on cage/Wayland over **Mali** EGL/GBM — not Mesa.
3. **The DT_NEEDED graph is closed.** Scanning every ELF in the rootfs:
   `libLLVM-15.so.1` is needed by the 43 DRI links and by **nothing else**;
   `libz3.so.4` is needed by `libLLVM-15.so.1` and by **nothing else**. Deleting
   the DRI drivers orphans both libraries completely.
4. **Nothing GL-shaped runs.** cerastream's element vocabulary contains no
   `glimagesink` / `glupload` / `kmssink` / `waylandsink`; its WebRTC preview tier
   is `webrtcbin` + `nicesrc`, neither of which links `libgstgl`. The only shipped
   plugin that does is `libgstnvcodec.so` (NVIDIA, inert on RK3588), and
   `libgstopengl.so` is not installed at all.

### The glob is `dri/*_dri.so`, never `dri/*`

`libva` resolves VA-API drivers as `<name>_drv_video.so` out of that same
directory. A bare `dri/*` would delete a future hardware video driver — exactly
the `intel-media-va-driver-non-free` the x86 family notes in
`x86_64.delta.list`. The `aarch64-linux-gnu` path prefix additionally makes the
whole entry a no-op on non-arm64 families. Both properties are pinned by
`package-contract.bats` §28.

### Measured result

| board | before | after | delta |
|---|---:|---:|---:|
| `rock-5b-plus` | 1,569,914,880 | **1,412,259,840** | −157,655,040 |
| `orange-pi-5-plus` | 1,576,458,240 | **1,418,792,960** | −157,665,280 |

Both boards now pass the 1.5 GB gate — `rock-5b-plus` with 87,740,160 B of
headroom, `orange-pi-5-plus` with 81,207,040 B. The two deltas differ by 10,240 B,
which is one tar block; each is within ~28 KB of the 157,637,616 B file-content
total, the rest being the 46 tar headers that went with the files. An independent
third measurement agrees: on a real board, `df` on the rootfs dropped
157,634,560 B when exactly these paths were deleted.

**The ceiling is still 1,500,000,000.** It was not moved in either direction —
not raised while the image was over, and not lowered now that it is under.

### Board proof

Behaviour was verified on a Rock 5B+ booted from the bench microSD by removing
exactly these paths from the live rootfs, rebooting, and re-running the same
measurements. Every observable is unchanged: the board boots, CeraUI answers on
both :80 and :443, a stream starts and stops cleanly with the same bonded-link
count and the same uplink byte volume, the GStreamer registry still reports
264 plugins / 1548 features, and no process on the board maps `libLLVM`,
`libz3`, a DRI driver, or any GL/EGL/GBM library — during a **live stream**, not
just at idle. Full transcript:
`.omo/evidence/device-platform-wave4/task-31-slim-attempt1.md`.

---

## 10. The gate is now wired into the build — `[6c/9]` (2026-08-04)

§8 recorded the real defect behind the whole overage: the budget was documented as
blocking, and **nothing enforced it on a real artifact**. `orchestrate.sh` had no
measurement stage, and the sole live caller was `v2-ci.yml`'s "rootfs size gate
(blocking)" job, which measures a synthetic 4 KB tree. A CI job that can only ever
measure 4 KB cannot fail on a 1.57 GB image.

§9 removed the reason to keep it unwired. With both RK3588 boards under the ceiling
with real headroom (87.7 MB / 81.2 MB), the orchestrator now runs the gate on every
real build:

```
[6/9]  emitting normalized artifact images/<board>/<ts>.rootfs.tar
[6b/9] verifying boot artifacts in <artifact>          (arm64 boot-BSP builds)
[6c/9] enforcing the rootfs size budget for <artifact> ← this
[7/9]  verifying parity vs v2 package manifests
[8/9]  Stage-4 disk assembly → <ts>.raw   +  Stage-4 RAUC bundle → <ts>.raucb
```

Position is the contract. Measuring before `[6/9]` has nothing to measure;
measuring after `[8/9]` would already have cut a flashable `.raw` and a signed
`.raucb` from an over-budget image. Sitting between emit and parity, an overage
fails the build with **no disk artifact produced at all**.

| Property | Behaviour | Why |
|---|---|---|
| `DRY_RUN=1` | never reached | the orchestrator `exit 0`s at `[5/9]`; a plan-only run ships no rootfs |
| `INSTALL_BOOT_BSP=0` | skipped, with a `log_warn` naming the reason | a kernel-less parity rootfs is not the shipped image, so measuring it is a vacuous pass — but the skip is loud, never silent |
| architecture | **not** gated | every shipped board carries a non-null `rootfs_bytes_max`, including `x86-minipc`; gating on arm64 would exempt the one board whose size has never been measured |
| over budget | `die` → build aborts | the budget check itself is not reimplemented — `measure-size.sh` is invoked and its exit status propagates, so there is exactly one implementation of the rule |

The existing `v2-ci.yml` synthetic-fixture job is **retained unchanged**. It is a
fast, hardware-free proof that the gate's own pass and fail legs work at all
(including a sparse 2 GiB negative leg); `[6c/9]` is the second, complementary
check that the gate meets a real artifact. Neither replaces the other.

Guards: `mkosi-contract.bats` §10 — the shipped `[6c/9]` block is extracted from
`orchestrate.sh` and executed against synthetic KB-sized trees, proving the pass
leg, the abort leg, the loud `INSTALL_BOOT_BSP=0` skip (with a spy proving
`measure-size.sh` is not invoked), the stage ordering, DRY_RUN unreachability, and
that no board's ceiling has been raised above 1,500,000,000.

---

## 11. The RELATIVE gate now runs against the REAL baseline too (todo 31)

§10 wired the **absolute** ceiling into the build and left the **relative** one
where it was. That was half a fix, and the leftover half had exactly the defect
§10 describes: `check-size-regression.sh` was reachable only from the same
`v2-ci.yml` job, fed the same synthetic 4 KB tree, and therefore compared 4096
bytes against a ~1.4 GB baseline — it could only ever report an enormous shrink.
`ci/size-baseline.json` was, in practice, data no real build ever read.

### What changed

- `orchestrate.sh` gained `compare_size_against_baseline()`, invoked from
  `[6c/9]` immediately **after** the absolute gate passes, against the same
  emitted tar.
- Baselines are now resolved **per board** as `ci/size-baseline.<board>.json`.
  `ci/size-baseline.json` is retained as a **symlink** to the `rock-5b-plus`
  file so the existing `v2-ci.yml` step keeps working with no duplication and no
  second copy of the number to drift.
- `check-size-regression.sh` takes an optional third argument, the expected
  board, and exits 2 if the baseline's own `board` field disagrees. Baselines
  differ between boards by tens of MB, so an unchecked file argument produces a
  confident and meaningless delta.

### Exit policy (deliberately not the same as the absolute gate's)

| Comparator exit | `[6c/9]` behaviour | Why |
|---|---|---|
| 0 | `log_success` | within threshold |
| 1 (growth beyond threshold) | loud `log_warn` | the **blocking** size rule is the absolute ceiling in `size-budget.json`; an intentional feature addition must not fail a build that is still comfortably under it. This matches what `v2-ci.yml` already does with exit 1. |
| 2 (missing/malformed/**wrong board**) | `die` | a repository misconfiguration, not a size event |
| no baseline for this board | `log_warn`, pass | the same newly-added-board allowance `measure-size.sh` makes for a null ceiling. There is deliberately **no** un-suffixed fallback: `size-baseline.json` is `rock-5b-plus`'s file, so a fallback would hand it to every board that lacks one. |

Guards: `mkosi-contract.bats` §10 gains five cases — the `[6c/9]` block actually calls
the comparison and calls it *after* the absolute gate; every shipped RK3588 board
carries a real per-board baseline with full provenance (`artifact`,
`artifact_sha256`, `commit`, ISO `recorded_at`) that is under its own ceiling and
is not a placeholder; `size-budget.json`'s `measured*` fields agree byte-for-byte
with the baseline file; the comparator refuses a cross-board baseline; and the
shipped function skips a missing baseline but dies on a mismatched one.

### Console-font readability was never real — `fonts-terminus` removed

Auditing `shared.list` against the built rootfs (and then against a live board)
turned up an annotation that does not survive contact with the package.
`fonts-terminus` was carried as *"large bitmap fonts (ter-v32n etc.) readable at
4K on fbcon"*. On bookworm it ships **exactly one file**, a TrueType face
(`/usr/share/fonts/truetype/terminus/TerminusTTF-4.46.0.ttf`, 440,944 B), and no
console PSF font at all — the PSF set lives in `xfonts-terminus` /
`console-setup`, neither of which is installed. So:

```
# built rootfs:              /usr/share/consolefonts/  -> 0 entries
# live Orange Pi 5+:         ls /usr/share/consolefonts/ -> No such file or directory
# live Orange Pi 5+:         dpkg -L fonts-terminus      -> only the .ttf
# live Orange Pi 5+:         systemctl status ceralive-console-font.service
#                              Active: active (exited) ... status=0/SUCCESS
```

`ceralive-console-font.service` runs
`setfont …Lat15-TerminusBold32x16.psf.gz || setfont …Uni3-TerminusBold32x16.psf.gz || true`,
and the trailing `|| true` turns both misses into a clean success. The unit has
therefore reported SUCCESS while doing nothing, on every boot of every image.

`fonts-terminus` is removed (a TTF has no fbcon consumer and the production image
ships no X/Wayland; `fonts-dejavu-core` remains as the font any future GUI/kiosk
payload would resolve). **`kbd` is KEPT** — `systemd-vconsole-setup` shells out to
its `setfont`/`loadkeys`, which is independent of the dead path above.

This is a correctness fix, not a size lever: the recovered payload is ~441 KB.
**Restoring genuine HDMI console readability is a separate, still-open decision** —
it requires shipping a real PSF provider (which *adds* bytes) or retiring the unit.
Do not read this removal as having fixed the feature.

## 12. The debug variant costs 58.11 MiB — measured, and it does NOT move the baseline (todo 32)

`CERALIVE_DEBUG_IMAGE=1` now selects a package set as well as an access posture:
the orchestrator appends `manifests/packages/development.delta.list` to
`$SHARED_PACKAGES`. Both variants were built wet for `rock-5b-plus` on the same
tree, same day, same BSP pins:

| Variant | rootfs tar bytes | installed packages | sha256 |
|---|---|---|---|
| production (`CERALIVE_DEBUG_IMAGE` unset) | 1,416,232,960 | 553 | `63a7c0ff…8e8341` |
| debug (`=1`) | 1,477,160,960 | 595 | `862415a5…a650e3` |
| **delta** | **+60,928,000 (+58.11 MiB)** | **+42** | |

42 packages added — the 18 named in the delta plus 24 transitive dependencies
(`python3.11`/`-minimal`, `libpython3.11-stdlib`, `libpcap0.8`, `libpci3`,
`pci.ids`, `libasound2-plugins`, `pulseaudio-utils`, `libiperf0`, …) — and **zero
removed**: `comm -23 prod debug` is empty, which is the property that makes
"debug == production + exactly this delta" a fact rather than a claim.

Exactly two systemd units differ, and both are accounted for: `ssh.service` (the
seam's documented behaviour) and `vnstat.service` (Debian's preset for the
`vnstat` package — kept, because a traffic accumulator collects nothing without
its daemon). `pulseaudio` adds **no** system unit; bookworm ships only user units
and this appliance has no user session, so it never autostarts and never contends
with `alsasrc` for the capture device.

### Both gates, and why only one of them runs for a debug build

- **The absolute ceiling runs for BOTH variants.** The debug image measured
  1,477,160,960 B against the 1,500,000,000 B ceiling — it passes, with
  **22,839,040 B (21.78 MiB) of headroom**. That is tight on purpose being
  recorded here: the delta is not free to grow without re-measuring, and the
  answer to a future overflow is to shrink the delta, never to raise
  `rootfs_bytes_max`.
- **The relative baseline comparison is SKIPPED for a debug build.** §4/§11's
  comparator warns past 50 MB of growth, and a debug image clears that threshold
  *by construction*. The first debug build duly emitted
  `size baseline: … GREW beyond the regression threshold … justify the growth and
  update the baseline in the same PR` — advice that is actively harmful here,
  because the committed `ci/size-baseline.<board>.json` is a PRODUCTION artifact.
  Updating it from a debug build would record a number no production image can
  reproduce and desync it from `size-budget.json`, which §11's own agreement test
  fails on. `compare_size_against_baseline` therefore returns early under the
  flag with a log line saying so.

The committed production baselines are UNCHANGED by this work. The production
build above (1,416,232,960 B) is +1,044,480 B against the recorded 1,415,188,480 B
— ordinary upstream Debian churn, inside the comparator's threshold, and not a
reason to re-record.

Guards: `package-contract.bats` §30 — 16 tests, including the skip being scoped to the
relative check only (the absolute stage must not grow a debug branch).
