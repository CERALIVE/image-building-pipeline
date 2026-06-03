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
variant only, **(f)** first-party .deb, **(g)** already in the mkosi base layer.

---

## (a) Already in the family manifest — `v2/manifests/families/rk3588.yaml`

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
shared base. (A future `packages/development.delta.list` may formalize this.)

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
| `belacoder` | **stale name** → now `ceracoder` in `REPOS` |
| `srtla` | first-party → `REPOS` (`srtla`) |
| `srt` | first-party → `REPOS` (`srt`) |

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
