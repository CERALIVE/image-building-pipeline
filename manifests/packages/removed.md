# Removed packages — explicit accounting (Task 18)

Every package mentioned across the three legacy sources that is **not** in
`shared.list` and **not** in `rk3588.delta.list` is listed here with a reason.
Nothing is silently dropped.

Sources reconciled:
1. `configs/base/ceraui-base.conf` — CERAUI/BASE/STREAMING/DEVELOPMENT/EXCLUDED/VARIANT arrays
2. `userpatches/customize-image.sh` — `STREAMING_PACKAGES` (lines 177–235) + service-enabled pkgs
3. `configs/devices/{rock5bplus,orangepi5plus}.conf` — `BOARD_PACKAGES`
   (+ supporting `userpatches/config-rock5bplus.conf` `EXTRA_BSP_PACKAGES`)

Removal categories: **(a)** already in the family manifest, **(b)** desktop/bloat,
**(c)** genuinely unnecessary / non-existent, **(d)** duplicate, **(e)** development
variant only, **(f)** first-party .deb, **(g)** already in the mkosi base layer,
**(h)** slimmed out of the mandatory set into the debug add-on (T17).

---

## (a) Already in the family manifest — `manifests/families/rk3588.yaml`

These must NOT be duplicated in the package lists (MUST-NOT honored).

| Package | Legacy source(s) | Canonical home (family field) |
|---|---|---|
| `gstreamer1.0-rockchip1` | ceraui-base STREAMING | `hw_accel_gstreamer_plugins` |
| `rockchip-multimedia-config` | ceraui-base STREAMING; both `BOARD_PACKAGES`; rock5bplus EXTRA_BSP | `gstreamer_runtime_packages` |
| `linux-image-current-rockchip64` | both `BOARD_PACKAGES` | `kernel_packages` (resolved to `vendor`, D3) |
| `linux-dtb-current-rockchip64` | both `BOARD_PACKAGES` | `dtb_packages` (resolved to `vendor`, D3) |
| `armbian-firmware` | both `BOARD_PACKAGES` | `firmware_packages` |
| `mali-g610-firmware` | rock5bplus EXTRA_BSP | `firmware_packages` |
| `rkbin-rk3588` | rock5bplus EXTRA_BSP | `uboot_packages` |

## (a′) Board-level BSP — derived/subsumed, not a static list entry

| Package | Source | Reason |
|---|---|---|
| `armbian-bsp-cli-rock-5b-plus` | rock5bplus `BOARD_PACKAGES` | Board BSP; **derived from `board_id`** by the orchestrator (`lib/fetch-debs.sh`), never stored in a package list. |
| `armbian-bsp-cli-orangepi5plus` | orangepi5plus `BOARD_PACKAGES` | Same — derived from `board_id`. |
| `rtl8852be-firmware` | rock5bplus `BOARD_PACKAGES` + EXTRA_BSP | **Subsumed by family `armbian-firmware`** (broad bundle ships Realtek WiFi blobs). Task 11 decision; no board-local firmware field by design. |
| `firmware-realtek` | rock5bplus EXTRA_BSP | Subsumed by `armbian-firmware`. |

## (c) Non-existent / provided-by-another package

| Package | Source | Reason |
|---|---|---|
| `media-ctl` | ceraui-base STREAMING | **No standalone Debian package.** The `media-ctl` binary ships inside `v4l-utils` (already in `shared.list`). Listing it would fail apt. |

## (b) Desktop bloat — `EXCLUDED_PACKAGES` (negative list, never installed)

These were exclusion globs in `ceraui-base.conf`, not install candidates. The
minimal mkosi base never pulls them; recorded for completeness.

`desktop-*`, `x11-*`, `gnome-*`, `kde-*`, `libreoffice-*`, `firefox*`,
`chromium*`, `games-*`, `documentation`, `man-db`, `info`,
`firmware-linux-nonfree` (VARIANT_MINIMAL_EXTRA_EXCLUDES),
`ffmpeg-minimal` (VARIANT_MINIMAL_EXTRA_EXCLUDES — superseded by `ffmpeg` in shared.list).

## (e) Development variant ONLY — not shipped in the standard image

Per task spec: build/debug tooling belongs to a development profile, not the
shared base.

**The forward reference here is now REAL: [`development.delta.list`](development.delta.list)
exists** (todo 32). It is a **variant-keyed** delta — resolved by
`lib/orchestrate.sh` **only** when `CERALIVE_DEBUG_IMAGE=1`, never by the
`${FAMILY}.delta.list` lookup — so a production build's package set is unchanged.
It carries `python3`, `strace`, `tcpdump` and the fifteen §(h) packages below.

The rest of the table is deliberately **still removed**: a toolchain
(`build-essential`, `cmake`, `pkg-config`, `gdb`, `valgrind`,
`linux-headers-*`, `device-tree-compiler`), a language runtime (`nodejs`, `npm`,
`python3-dev`), a VCS (`git`) and terminal multiplexers (`vim`, `screen`, `tmux`,
`rsync` — `rsync` is in `shared.list` anyway for dev-push) are for building
software ON the device. Nothing is compiled on a CeraLive board: every
first-party component arrives as a signed `.deb` and the whole OS arrives as a
RAUC bundle. Baking a compiler into an image whose ONLY differences from
production should be diagnostic would make the debug variant a materially
different system and undermine the point of debugging on it.

| Package | Source |
|---|---|
| `build-essential` | ceraui-base DEVELOPMENT; customize-image.sh dev branch; rock5bplus dev EXTRA_BSP |
| `git` | ceraui-base DEVELOPMENT; customize-image.sh dev branch |
| `cmake` | ceraui-base DEVELOPMENT |
| `pkg-config` | ceraui-base DEVELOPMENT |
| `gdb` | ceraui-base DEVELOPMENT; rock5bplus dev EXTRA_BSP |
| `strace` | ceraui-base DEVELOPMENT |
| `tcpdump` | ceraui-base DEVELOPMENT |
| `vim` | customize-image.sh dev branch |
| `screen` | customize-image.sh dev branch; ceraui-base VARIANT_DEVELOPMENT_EXTRAS |
| `tmux` | customize-image.sh dev branch; ceraui-base VARIANT_DEVELOPMENT_EXTRAS |
| `rsync` | ceraui-base VARIANT_DEVELOPMENT_EXTRAS |
| `python3-dev` | ceraui-base VARIANT_DEVELOPMENT_EXTRAS |
| `nodejs` | ceraui-base VARIANT_DEVELOPMENT_EXTRAS |
| `npm` | ceraui-base VARIANT_DEVELOPMENT_EXTRAS |
| `linux-headers-current-rockchip64` | rock5bplus dev EXTRA_BSP |
| `device-tree-compiler` | rock5bplus dev EXTRA_BSP |
| `valgrind` | rock5bplus dev EXTRA_BSP |

Note: `iperf3` also appears in `ceraui-base.conf` DEVELOPMENT_PACKAGES, but it is
in `customize-image.sh`'s **standard** (always-installed) set — so it is KEPT in
`shared.list` (bonded-link throughput diagnostics), not removed. Conflict resolved
toward the actually-shipped set.

## (g) Already in the mkosi base layer (Task 13) — not re-listed in runtime

| Package | Source | Reason |
|---|---|---|
| `openssh-server` | ceraui-base VARIANT_DEVELOPMENT_EXTRAS; ssh enabled in customize-image.sh:520 | Installed by the **base** layer (`mkosi.images/base`: `systemd udev openssh-server dbus`). The `ssh` service is enabled by the runtime postinst; the package itself is not a runtime-list entry. |

## (f) First-party .debs — fetched + dpkg-installed by the orchestrator

`CERAUI_PACKAGES` in `ceraui-base.conf` are NOT apt packages. They are built
in-tree and delivered as signed `.deb`s via `lib/fetch-debs.sh` (`REPOS`) then
`dpkg -i` in the runtime postinst — never an apt package-list line.

| Legacy name | Reality |
|---|---|
| `ceraui` | first-party → `REPOS` (`CeraUI`) |
| `belacoder` | **retired lineage** → `belacoder` was renamed `ceracoder`, which was itself retired 2026-06-11 (boot-parity generic PASS); `cerastream` in `REPOS` is the sole streaming engine |
| `srtla` | first-party → `REPOS` (`srtla`) |
| `srt` | first-party → `REPOS` (`srt`) |

## (h) Slimmed to the debug add-on (T17) — optional, not runtime-critical

Image-slimming pass (T17). These 15 packages were in the mandatory `shared.list`
but are **operator/field diagnostics or optional capabilities**, not part of the
streaming/bonding/modem/update datapath. They are removed from the always-installed
base and become the **seed set for the debug add-on** (T26) — installed on demand,
never baked into every image. Each was verified to have **no runtime consumer** in
CeraUI, the streaming engine (then ceracoder, now cerastream), srtla, or the mkosi runtime postinst before removal.

**They are now ALSO in [`development.delta.list`](development.delta.list), and that
is not a contradiction — it is two delivery routes for one toolbox.** The
`debug-toolset` sysext add-on stays the **field** route: installed at runtime, over
the network, on an ordinary production image, no reflash. The delta is the **bench**
route: baked into an explicitly-marked `CERALIVE_DEBUG_IMAGE=1` image so a developer
debugging the boot / first-boot window has the tools before any network or add-on
manager exists. Neither route puts them in a production image, which is what the
"Destination" column below has always meant. Keep the two sets equal: an operator
should not have to know which route they are on.

| Package | Reason for removal | Destination |
|---|---|---|
| `alsa-utils` | Low-level ALSA control; the streaming appliance encodes from the capture device, not a local mixer — audio tooling is monitor/diagnostic only. | debug add-on (T26) |
| `pulseaudio` | Sound server; no runtime consumer (no local-playback path). The old `ENABLED_SERVICES` entry was an Armbian-era carry-over. | debug add-on (T26) |
| `usbutils` | `lsusb` — manual USB enumeration for field debugging; ModemManager/udev drive device bring-up without it. | debug add-on (T26) |
| `pciutils` | `lspci` — manual PCI introspection, diagnostics only. | debug add-on (T26) |
| `lsof` | Open-fd inspection — operator debugging only. | debug add-on (T26) |
| `i2c-tools` | Manual I²C bus pokes (sensors/EEPROM) — board-bring-up diagnostics, not runtime. | debug add-on (T26) |
| `can-utils` | CAN-bus tooling — v1 carry-over; no CeraLive datapath uses CAN. | debug add-on (T26) |
| `htop` | Interactive process monitor — field diagnostics. | debug add-on (T26) |
| `iotop` | IO monitor — storage-bound encode/record diagnostics only. | debug add-on (T26) |
| `nethogs` | Per-process bandwidth monitor — link-saturation debugging only. | debug add-on (T26) |
| `vnstat` | Cumulative traffic accounting — data-cap awareness is a nice-to-have, not runtime-critical. | debug add-on (T26) |
| `nano` | On-box editor — operator convenience only; no automated config path edits files interactively. | debug add-on (T26) |
| `iperf3` | Bonded-link throughput testing — field diagnostics. | debug add-on (T26) |
| `socat` | Socket relay — the old "streaming/control glue" comment was aspirational; **no consumer** in CeraUI/encoder/srtla/mkosi. The chaos harness (`tools/chaos`) ships its own. | debug add-on (T26) |
| `netcat-openbsd` | `nc` connectivity probing — field diagnostics, no runtime consumer. | debug add-on (T26) |

**KEPT (verified runtime-critical, NOT moved):**

| Package | Why it stays mandatory |
|---|---|
| `curl` | CeraUI update flows **and** the on-device `curl localhost` health probe (`apps/backend/.../observability.ts`). Runtime-critical. |
| `rsync` | dev-push / dev-sync live-reload loop (`docs/dev-loop.md`). |
| `wget` | http downloader for update/fetch infra. |
| `usb-modeswitch` | Flips USB LTE/5G modems out of storage mode — without it USB modems never enumerate. Core to the bonded-modem datapath. |
| `kbd` | `setfont`/`loadkeys` — `systemd-vconsole-setup` shells out to these. Boot-console essential, not diagnostics. |

**`fonts-terminus` was REMOVED in todo 31** — it was listed here as a boot-console
essential on the strength of an annotation that does not survive contact with the
package. On bookworm it ships exactly one file, a **TrueType** face
(`/usr/share/fonts/truetype/terminus/TerminusTTF-4.46.0.ttf`), and no console PSF
font whatsoever; the PSF set is in `xfonts-terminus`/`console-setup`, neither of
which is installed. Board-confirmed on a live Orange Pi 5+: `/usr/share/consolefonts/`
does not exist, `dpkg -L fonts-terminus` lists only that TTF, and
`ceralive-console-font.service` nevertheless reports `active (exited)
status=0/SUCCESS` because its `setfont … || setfont … || true` swallows both
failures. The HDMI console-readability feature has therefore never worked, on any
image. Removing the package changes no behaviour; restoring the feature needs a real
PSF provider and is tracked separately in [`docs/size-notes.md`](../../docs/size-notes.md) §11.

## ESCALATION — Bluetooth stack (decision needed)

| Package | Source | Disposition |
|---|---|---|
| `bluetooth` | `userpatches/config-rock5bplus.conf` EXTRA_BSP | **Removed from shared base** |
| `bluez` | same | **Removed from shared base** |
| `bluez-tools` | same | **Removed from shared base** |

**Reasoning / decision:** Bluetooth appears ONLY in the Rock 5B+ userpatches (not
Orange Pi 5+, not `ceraui-base.conf`), and the `bluetooth` service is explicitly
**DISABLED by default** in BOTH `ceraui-base.conf` `DISABLED_SERVICES` and
`customize-image.sh` `DISABLE_SERVICES`. It is not part of the streaming / bonding
/ modem datapath. For the **minimal base** success metric it is excluded.

> ⚠️ **Escalate:** Task 11 forward-noted these as "shared runtime (task 18)". As
> task 18 I am overriding that guess: a disabled-by-default, single-board, non-datapath
> capability does not belong in the minimal shared base. If product wants BT audio
> monitoring, add a dedicated `bluetooth` profile/delta rather than polluting the
> shared list. **Owner sign-off requested before image release.**

---

# Todo 19 — evidence-gated `shared.list` audit (per-package verdicts)

Scope: **every active entry** of `manifests/packages/shared.list` as frozen at the
start of this audit — **48 packages**, captured with
`grep -vE '^\s*(#|$)' shared.list | sort`. Nothing was judged by "no grep hit":
every verdict below cites a *positive* artefact — a shipped unit or script that
invokes the binary, a reverse dependency read out of a real built rootfs's
`/var/lib/dpkg/status`, an AGENTS.md KEY FACT, or (for a REMOVE) an explicit
structural reason the package cannot be reached.

Explicitly **out of scope**: `development.delta.list` (the 18-package debug delta),
`rk3588.delta.list` and `x86_64.delta.list`.

**Outcome: 44 KEEP + 1 DEFER + 3 REMOVE = 48** — the REMOVEs are `apt-transport-https`, `wget`,
`wireless-tools`. Measured cost of the three: see §Measured size delta.

Evidence classes used in the table:

| Class | Meaning |
|---|---|
| `INVOKE` | a shipped unit/script/binary on the device executes it — file:line cited |
| `RDEP` | reverse dependency in a real built rootfs `/var/lib/dpkg/status` |
| `KEYFACT` | an `AGENTS.md` KEY FACT states the requirement (usually board-confirmed) |
| `PLUGIN` | GStreamer plugin reachability / element-factory dependency chain |
| `ROOTFS` | read directly out of the built rootfs (unit present, config written, rc.d link) |

## Verdict table (48 rows — one per frozen-snapshot package)

| # | Package | Verdict | Evidence | Affected variants |
|---:|---|---|---|---|
| 1 | `apt-transport-https` | **REMOVE** | ROOTFS: `Section: oldlibs` transitional dummy; its own Debian description says "https support has been moved into the apt package in 1.5. It can be safely removed." Its `.list` in a built rootfs is FOUR files, all under `/usr/share/doc/` — no apt method, no code. Installed apt is 2.6.1. The device's https+mTLS apt source (KEYFACT "Baked mTLS client key … arch-qualified apt.ceralive.tv URI") is served by apt's built-in https method. RDEP: none. | all (prod + debug, all boards) |
| 2 | `avahi-daemon` | KEEP | KEYFACT "Deterministic first-boot hostname" — `ceralive-hostname.service` drives `avahi-set-host-name` and polls Avahi `GetState`; operators reach the box by `<hostname>.local`. ROOTFS: enabled in `multi-user.target.wants/`, plus the `avahi-daemon.service.d/10-ceralive-restart.conf` drop-in. | all |
| 3 | `avahi-utils` | KEEP | INVOKE: `ceralive-hostname.service`'s claim loop shells out to `avahi-set-host-name` (KEYFACT "Baked-hostname `AVAHI_ERR_NO_CHANGE` fix"); the 30 s reconcile timer queries daemon state the same way. | all |
| 4 | `bluez` | KEEP | **Must-NOT-Have list.** KEYFACT "`bluez` in `shared.list` — the Bluetooth KERNEL half already worked": without it there is no `bluetoothd`, no `bluetooth.service`, no `bluetoothctl`, so a board-confirmed working RTL8852BE radio is unusable. | all |
| 5 | `ca-certificates` | KEEP | Root TLS store for the https apt sources (Debian + apt.ceralive.tv) and every outbound `curl`. RDEP: `openssl` `Depends: ca-certificates`. | all |
| 6 | `chrony` | KEEP | ROOTFS: `chrony.service` enabled in `multi-user.target.wants/`; `configure_services` enables `chronyd`, config at `customize/ceralive-ntp.conf` (`makestep 1 3`). RAUC bundle signature verification is time-sensitive. (Only its boot-blocking `chrony-wait` sibling is masked — KEYFACT "Six stock units must be MASKED".) | all |
| 7 | `cpufrequtils` | KEEP | INVOKE: `mkosi/customize/sysctl-tuning.sh:55-56` writes `GOVERNOR="performance"` to `/etc/default/cpufrequtils`; ROOTFS: the package's own `/etc/rc{2,3,4,5}.d/S01cpufrequtils` + `S01loadcpufreq` sysv links are present, so systemd-sysv-generator applies that governor at boot. Remove it and the config file is inert — the encode-performance governor pin silently disappears. | all |
| 8 | `curl` | KEEP | INVOKE: `lib/shared/health-gate-lib.sh:54` device-side health probe; CeraUI update flows; the guaranteed first arm of every `curl … || wget …` fallback in this repo. | all |
| 9 | `dnsmasq` | KEEP | **Must-NOT-Have list.** KEYFACT "Don't unmask `dnsmasq.service` believing it serves the WiFi hotspot": NetworkManager spawns its OWN dnsmasq **child process** for `ipv4.method shared`, and that child needs this package's binary. The standalone unit is masked; the package is not. | all |
| 10 | `e2fsprogs` | KEEP | **Must-NOT-Have list.** KEYFACT "RAUC 1.8 needs … `mkfs.ext4`": real Rock 5B+ OTA failed `failed to start mkfs.ext4` until this was added. | all |
| 11 | `ffmpeg` | KEEP | INVOKE (on-board): `cerastream/tests/hw-smoke.sh:35` (`FFPROBE="${FFPROBE:-ffprobe}"`) — Phase B asserts "a non-empty MPEG-TS whose codec ffprobe confirms", and the script is explicitly board-only ("this only ever validates on the actual board"). `cerastream/tests/boot-parity.sh:270` (`ffprobe -v error`) is CHECK 5, and the RK3588 hardware profiles of that gate are still OWED (root `AGENTS.md`). `manifests/families/rk3588.yaml:71` records the shipped MPP HW-encode claim as "ffprobe-verified … on real Rock 5B+ hardware". **The "engine is GStreamer-based so ffmpeg is dead" reading is wrong**: the libav *elements* (`avdec_*`/`avenc_*`) come from `gstreamer1.0-libav`→`libav*`, not from this package — but the on-board validation gate does need the CLI. | all |
| 12 | `gstreamer1.0-alsa` | KEEP | **Must-NOT-Have list.** PLUGIN: `alsasrc` — USB/RØDE audio capture + the always-on audio meter; KEYFACT "First-party .deb fetch" names it explicitly because `--no-install-recommends` will not pull it. | all |
| 13 | `gstreamer1.0-libav` | KEEP | PLUGIN: supplies `avdec_h264`/`avdec_h265`/`avdec_aac`/`avenc_aac`, which cerastream names as real element factories — `cerastream-hal/src/decoder_selection.rs:181-192` (software fallback rung of every platform ladder), `graph/builder.rs:129`, `graph/templates/{n100,jetson,rk3588}.rs`. | all |
| 14 | `gstreamer1.0-nice` | KEEP | **Must-NOT-Have list.** PLUGIN: `nicesrc` — the libnice ICE transport the cerastream WebRTC preview tier requires; root `AGENTS.md` calls libnice "a device-image dependency, not just a build flag". | all |
| 15 | `gstreamer1.0-plugins-bad` | KEEP | PLUGIN: `webrtcbin` (preview tier), `srtsink`/MPEG-TS muxing, `h265parse`. | all |
| 16 | `gstreamer1.0-plugins-base` | KEEP | PLUGIN: core `videoconvert`/`audioconvert`/`audioresample`/`queue` — every cerastream graph template. | all |
| 17 | `gstreamer1.0-plugins-good` | KEEP | PLUGIN: `v4l2src` (HDMI-RX / UVC capture), `rtp*`, `matroska`/`isomp4`. | all |
| 18 | `gstreamer1.0-plugins-ugly` | KEEP | PLUGIN: `x264enc` — the `generic` software-encode profile, which is the platform every non-hardware boot-parity run uses (`cerastream/tests/hw-smoke.sh` `generic/h264` → `x264enc`). | all |
| 19 | `gstreamer1.0-tools` | KEEP | INVOKE (on-board): `gst-inspect-1.0` / `gst-launch-1.0` are the whole of `cerastream/tests/hw-smoke.sh` Phase A + B, and `gst-inspect-1.0` is the board evidence cited throughout AGENTS.md (e.g. the Mesa prune's "264 plugins / 1548 features"). | all |
| 20 | `hostapd` | **DEFER** | Positive non-use today: ROOTFS shows `/etc/hostapd/` holds only the package's own `ifupdown.sh` — **no `hostapd.conf`**, and nothing under `mkosi/` ever writes one, so the enabled `hostapd.service`'s `ConditionFileNotEmpty=/etc/hostapd/hostapd.conf` skips it on every boot. `mkosi/runtime/ceralive-provision.sh:34-36` states AP mode is NM-native and "hostapd remains in the image only as an evidence-gated fallback". RDEP: none. The only invoker anywhere is CeraUI's host-side `test-harness/wifi-hwsim/` container. **BUT** the mechanism it backstops is `[PARTIAL]`: AGENTS.md "First-boot WiFi provisioning portal" carries "HW caveat: AP mode also requires the onboard wlan driver to support it (RK3588 chip dependent) — to be validated on hardware". Deleting the sanctioned fallback before the primary is board-proven would be size-driven, not evidence-driven. **Unblock condition:** NM-native AP mode board-confirmed on both RK3588 boards (the `[PARTIAL]` cleared) → then REMOVE (2,297 KB). | all |
| 21 | `ipcalc` | KEEP | INVOKE: `mkosi/customize/networking-srtla.sh:106-107` — the shipped SRTLA source-routing hook computes `NETWORK=$(ipcalc -n …)` / `PREFIX=$(ipcalc -p …)` for the per-link policy-routing tables. That is the bonded-uplink datapath, not a diagnostic. | all |
| 22 | `iproute2` | KEEP | INVOKE: `ip`/`rt_tables` for SRTLA source-policy routing (`networking-srtla.sh`, NM dispatcher `90-srtla-wifi-routing`); `ip` is in CeraUI's `run.ts` `ALLOWED` allowlist. | all |
| 23 | `iw` | KEEP | **Must-NOT-Have list.** INVOKE: `CeraUI/apps/backend/src/modules/wifi/regdomain.ts:423/435/447` — `iw reg set`, `iw reg get`, `iw phy`; `"iw"` is in the `run.ts` `ALLOWED` allowlist. KEYFACT "`iw` in `shared.list` — `wireless-tools` is NOT the same package". | all |
| 24 | `kbd` | KEEP | INVOKE: `mkosi/runtime/ceralive-console-font.service:9` calls `setfont` directly, and the unit is enabled in `multi-user.target.wants/`; `setfont` ships only here. **CORRECTION recorded in `shared.list`:** the old rationale also claimed `systemd-vconsole-setup` shells out to these — FALSE for this image (a built rootfs contains no `*vconsole*` file at all and no `/etc/vconsole.conf`). Kept because it is one half of a live shipped unit whose other half — a real PSF provider — is the tracked gap (`size-notes.md` §11); dropping it would turn a one-package fix into a two-package one and leave an enabled unit naming a missing binary. | all |
| 25 | `libmbim-utils` | KEEP | KEYFACT "ModemManager 1.24 closure": stays in `shared.list` to resolve the Debian modem dependency tree, then the app layer UPGRADES it with the `~ceralive0.2.0` fork. Removing it breaks that dependency resolution. | all |
| 26 | `libnss-mdns` | KEEP | NSS plugin so the device can RESOLVE other `.local` hosts (the reverse direction from `avahi-daemon`); referenced by `/etc/nsswitch.conf` in the built rootfs. | all |
| 27 | `libqmi-utils` | KEEP | Same KEYFACT as `libmbim-utils` — Qualcomm QMI half of the ModemManager closure. | all |
| 28 | `mobile-broadband-provider-info` | KEEP | **Must-NOT-Have list.** KEYFACT: ModemManager's APN/provider DB, only a `Recommends:` so `--no-install-recommends` never pulls it; absent it every SIM needs a hand-written connection profile. | all |
| 29 | `modemmanager` | KEEP | Cellular datapath daemon; KEYFACT "ModemManager 1.24 closure" — the Debian package resolves the tree the forked closure then upgrades. ROOTFS: `ModemManager.service` enabled. | all |
| 30 | `net-tools` | KEEP | **Must-NOT-Have list.** INVOKE: `CeraUI/apps/backend/src/modules/network/network-interfaces.ts:262` `run("ifconfig", [])` every ~5 s; `"ifconfig"` is in `run.ts:125` `ALLOWED`. KEYFACT "`net-tools` in `shared.list` — else the CeraUI Network destination is TOTALLY empty" (board-confirmed). | all |
| 31 | `network-manager` | KEEP | Primary connection manager; CeraUI drives it via `nmcli` (`run.ts` `ALLOWED`) and it is the AP-mode mechanism (`ceralive-provision.sh`). ROOTFS: `NetworkManager.service` enabled. | all |
| 32 | `nftables` | KEEP | INVOKE: `ceralive-ingest-firewall.service` runs `/usr/sbin/nft -f /etc/ceralive/ingest-firewall.nft`; ROOTFS: unit enabled + ruleset present. This is the WAN-side boundary on the UNAUTHENTICATED RTMP/SRT ingest — a security control. | all |
| 33 | `nginx-light` | KEEP | **Must-NOT-Have list.** KEYFACT "CeraUI TLS front — nginx on 443". ROOTFS: `nginx.service` enabled + `nginx.service.d/10-ceralive-tls.conf`. | all |
| 34 | `openssl` | KEEP | **Must-NOT-Have list.** INVOKE: `ceralive-tls-firstboot.sh` generates the per-device self-signed cert with `openssl req -x509`; `cert-rotation.service` re-validates SAN/key pair. | all |
| 35 | `rauc` | KEEP | **Must-NOT-Have list (RAUC pair).** The A/B OTA client `ceralive-update` and CeraUI `system.startUpdate()` drive. | all |
| 36 | `rauc-service` | KEEP | **Must-NOT-Have list (RAUC pair).** KEYFACT: bookworm SPLIT the D-Bus daemon out of `rauc`; the runtime postinst enables `rauc.service`, which ships here. | all |
| 37 | `rsync` | KEEP | INVOKE (device-side): `dev-push:310` rsyncs the sysext `.raw` to `${SSH_USER}@${BOARD_IP}:…` — rsync-over-SSH spawns `rsync --server` on the **remote**, so the device must ship the binary; and `tests/realhw-smoke.sh:451-480` makes the LIVE full parity check a hard requirement, rsyncing the parity subtree OFF the board. Both are on-device dependencies, not host-only. | all |
| 38 | `squashfs-tools` | KEEP | **Must-NOT-Have list.** KEYFACT "RAUC 1.8 needs … `unsquashfs`" — real Rock 5B+ install failed `Failed to start unsquashfs` until this was added. | all |
| 39 | `sudo` | KEEP | INVOKE: `CeraUI/apps/backend/src/helpers/addon-helper.ts:45,99` — `deps.exec(SUDO, [HELPER_BIN, …])` against the narrow `/etc/sudoers.d/ceralive-addon-helper` drop-in. Without it add-on enable/disable is dead code. | all |
| 40 | `systemd-resolved` | KEEP | KEYFACT "`/etc/resolv.conf` MUST be the systemd-resolved stub symlink — else DNS is totally dead": NetworkManager runs `dns=systemd-resolved`, so this package IS the resolver. Separate package on bookworm. | all |
| 41 | `u-boot-tools` | KEEP | `fw_setenv`/`fw_getenv` + `mkimage` for the RAUC bootloader environment / boot selector; generic (present on the x86 path too). | all |
| 42 | `usb-modeswitch` | KEEP | Flips USB LTE/5G modems out of storage mode; without it USB modems never enumerate — core to the bonded-modem datapath (already recorded as a verified KEEP in §(h) above). | all |
| 43 | `v4l-utils` | KEEP | Ships BOTH `v4l2-ctl` and `media-ctl` (the latter has no standalone Debian package — see §(c) and the `parity-check.sh` `PKG_ALIAS[media-ctl]=v4l-utils`). `v4l2-ctl -d /dev/video0 --info` is the board-evidence tool for the HDMI-RX symlink KEYFACT. | all |
| 44 | `wget` | **REMOVE** | The old "http downloader (update/fetch infra)" annotation named no consumer, and there is none. (i) The OS update path is RAUC (`ceralive-update` → `rauc install`) + `rauc-hawkbit-updater`, which downloads via **libcurl**; the app update path is `apt-get` from apt.ceralive.tv. (ii) CeraUI's backend structurally cannot spawn it — `wget` is absent from `apps/backend/src/helpers/run.ts` `ALLOWED`, which the file calls "the single source of truth … adding a binary here is a security decision". (iii) The ONLY device-side invoker in this repo is `lib/shared/health-gate-lib.sh:54`, the fallback arm of `command -v curl && curl … \|\| wget …` — and `curl` is a mandatory `shared.list` entry, so that arm is unreachable on any CeraLive image. (iv) `CeraUI/install.sh:261` (the legacy pre-`.deb` installer, superseded by `ceralive-device`) uses wget but self-provisions it (`install_if_missing_local wget`). (v) RDEP: none. | all |
| 45 | `wireless-regdb` | KEEP | **Must-NOT-Have list.** KEYFACT: only `wpasupplicant`'s `Recommends:`, so `--no-install-recommends` never pulls it; absent it cfg80211 logs "Direct firmware load for regulatory.db failed with error -2" and NM finds no usable WiFi interface (real-HW UART). | all |
| 46 | `wireless-tools` | **REMOVE** | Legacy WEXT only (`iwconfig`/`iwlist`/`iwgetid`/`iwpriv`/`iwspy`/`iwevent`). (i) CeraUI's backend may execute only the binaries in its security-reviewed `run.ts` `ALLOWED` allowlist, which carries `iw` and **no WEXT binary** — the WEXT path is *structurally unreachable*, not merely unused. (ii) Association is NetworkManager + `wpa_supplicant` over D-Bus; regulatory/channel work is `iw reg get/set` + `iw phy` (`modules/wifi/regdomain.ts:423-447`). (iii) The `iw` KEYFACT already states this package "does NOT provide it … ships only the legacy WEXT" binaries. (iv) cerastream never touches WiFi; no unit or script under `mkosi/` names a WEXT binary. (v) RDEP: none. (vi) Every remaining hit anywhere is prose or CeraUI's host-side `test-harness/wifi-hwsim/` container (mac80211_hwsim on a dev box). | all |
| 47 | `wpasupplicant` | KEEP | The WPA supplicant NetworkManager drives for both client and AP mode; ROOTFS: `wpa_supplicant.service` enabled + `dbus-fi.w1.wpa_supplicant1.service`. | all |
| 48 | `zstd` | KEEP | **PROTECTED KEEP (Must-NOT-Have list).** `initramfs-tools` uses it inside the target rootfs to compress initrds instead of falling back to gzip. RDEP: `initramfs-tools-core` `Recommends: zstd`. Load-bearing for the `/boot` artifact contract. | all |

## Migrated verdict — `fonts-terminus`

`fonts-terminus` was **already REMOVED in todo 31** and is therefore *not* in this
audit's 48-package population; its verdict is migrated here verbatim rather than
re-investigated. Reason of record: on bookworm it ships exactly one file, a
**TrueType** face (`/usr/share/fonts/truetype/terminus/TerminusTTF-4.46.0.ttf`,
440,944 B) and **no console PSF font at all**; `/usr/share/consolefonts/` is empty
on a built rootfs, so `ceralive-console-font.service`'s two `setfont …psf.gz` calls
can never succeed and silently no-op on every boot. Board-confirmed on a live
Orange Pi 5+. Full text: §"`fonts-terminus` was REMOVED in todo 31" above and
[`docs/size-notes.md`](../../docs/size-notes.md) §11. Measured: **-460,800 B**.

## Measured size delta

The three removals were measured **A/B against the real Debian bookworm/arm64 apt
closure** (a real `debian:bookworm-slim --platform linux/arm64` container, real
`apt-get update`, `apt-get install -s --no-install-recommends` over the exact 48-
and 45-package lists):

```
RESOLVED_BEFORE = 435 packages      (48-package shared.list)
RESOLVED_AFTER  = 431 packages      (45-package shared.list)
PACKAGES ADDED  = (none)            <- no substitution, no dependency regression

dropped:
  apt-transport-https        35 KB
  libiw30                    80 KB   <- orphaned with wireless-tools
  wget                     3529 KB
  wireless-tools            548 KB
                          -------
  TOTAL                    4192 KB = 4,292,608 B
```

Against the current measured baseline
`ci/size-baseline.rock-5b-plus.json` = **1,415,188,480 B** (commit `a575a9a`,
2026-08-08), that projects to **≈1,410,895,872 B** — ~89 MB under the
1,500,000,000 B `[6c/9]` ceiling. The realised tar delta will be slightly smaller
than 4,292,608 B because `WithDocs=no` and the locale strip already remove part of
those bytes (`apt-transport-https` is 100 % documentation, so its real contribution
is ≈0). **`rootfs_bytes_max` was not touched, and no verdict here was taken for
size reasons** — the size figure is a consequence, not a motive.

## Build evidence and its honest limit

A full real (non-`DRY_RUN`) `./build rock-5b-plus` **cannot complete on the
development workstation**, for two pre-existing reasons that are independent of
this change:

1. `fetch-debs.sh` auto-enables `DRY_RUN` when `APT_GPG_PUBLIC_B64` is unset
   ("no apt.ceralive.tv GPG key … auto dry-run"), which suppresses the BSP and the
   pinned RK3588-userspace fetches too. A real build therefore fails in the
   **platform** layer at `[platform] installing authenticated staged HW-accel
   GStreamer BSP` with `E: Unable to locate package gstreamer1.0-rockchip1 /
   librockchip-mpp1 / librockchip-mpp-dev`. **This is provably unrelated to this
   audit**: those packages are not in `shared.list` at all, and the failure occurs
   in the platform layer, *before* the runtime layer installs `shared.list`.
2. At the time of this audit the committed pin was `armbian-firmware=26.5.1`, a
   version the Armbian archive no longer served. That pin has since been promoted
   to `26.8.1` through the `docs/RELEASE-PROCESS.md` §4 signed-index review, so
   this particular obstacle no longer applies; reason 1 above still does.

Additionally, this workstation's default Docker context is **Docker Desktop**,
which cannot preserve file ownership on the bind-mounted build tree
(`cp: failed to preserve ownership … Operation not permitted`) and so cannot run
mkosi at all; `DOCKER_CONTEXT=default` (the native daemon, which the release
workflow pins for exactly this reason) is required and was used.

What WAS proven, really and non-`DRY_RUN`: the post-change 45-package set resolves
and installs cleanly under `--no-install-recommends` in real bookworm/arm64 apt
(431 packages, zero unresolved), with **zero packages added** relative to the
48-package set — i.e. no removal was silently substituted by a dependency.
`lib/parity-check.sh` derives its expected set from these same manifests, so the
`[7/9]` gate moves in lockstep and cannot fail on the reduced set.

## Guards

No `tests/manifest.bats` guard names `apt-transport-https`, `wget`, or
`wireless-tools` as required, so **no guard edit was needed**. The one mention of
`wireless-tools` (`manifest.bats:1988`) is explanatory prose inside the `iw` guard,
whose assertion is `grep -Ex 'iw[[:space:]]*(#.*)?'` — a whole-line match that never
matched the `wireless-tools` line. `tests/package-migration-coverage.sh` is
unaffected: `removed.md` is one of its accepted "v2 homes", and the legacy sources
it reconciles against were retired in T24 (it SKIPs).
