# CeraLive Image Building Pipeline

A build pipeline for creating ready-to-use images for ARM-based streaming devices,
targeting Rockchip RK3588 devices (Orange Pi 5+, Radxa Rock 5B+) with future
support for Intel N100/N200 and AMD platforms.

> Status: Alpha — interfaces and docs may evolve. Contributions welcome! See [CONTRIBUTING.md](./CONTRIBUTING.md).

## Supported Devices

### Current (RK3588-based)
- **Orange Pi 5+** — HDMI input, good power delivery
- **Radxa Rock 5B+** — best HDMI input EMI resistance, M.2 modem support

### Future Support
- Intel N100/N200 devices
- AMD-based microcomputers

## Key Features

- **Streaming-focused**: SRTLA bonding, WiFi management, HDMI capture
- **Hardware acceleration**: Rockchip MPP integration for encoding
- **Custom software stack**: `CeraUI`, `cerastream`, `srtla-send-rs`, `srt` via .deb packages
- **Minimal system**: Debian bookworm-based with minimal apt sources
- **Ready-to-use**: Images for eMMC/SD cards, no additional setup required
- **Device support**: Automatic USB audio/video device detection and access
- **Modem support**: M.2 and USB 4G/5G modems
- **Feature add-ons**: Optional per-board/per-OS sysext `.raw` artifacts (display engine, debug tools, etc.)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    CeraUI Application                       │
├─────────────────────────────────────────────────────────────┤
│ cerastream  │ srtla-send-rs│     srt     │   WiFi Manager   │
├─────────────────────────────────────────────────────────────┤
│           GStreamer + Rockchip MPP (Hardware Encoding)      │
├─────────────────────────────────────────────────────────────┤
│            Debian bookworm + CeraLive Customizations        │
├─────────────────────────────────────────────────────────────┤
│                    Hardware Layer                           │
│  Orange Pi 5+ │ Radxa Rock 5B+ │ Future Intel/AMD devices  │
└─────────────────────────────────────────────────────────────┘
```

## Build System

The build path is `v2/` using mkosi v26 inside a pinned `debian:trixie-slim`
container (`v2/ci/Dockerfile`). It produces reproducible `.raw` sysext bundles and
`.raucb` A/B RAUC OTA packages from a layered source.

**The container build is canonical.** Native builds (`--native` /
`MKOSI_NATIVE=1`) are opt-in and require mkosi ≥ 26 + Python ≥ 3.12 on a Debian
trixie+ host. See [`v2/docs/host-support.md`](v2/docs/host-support.md) for the
full host matrix (Ubuntu/Debian, Arch, Fedora, macOS Apple Silicon, WSL2).

See [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) for the full dev loop.

Rock 5B+ production images use a populated A/B factory layout: both 4096 MiB
rootfs slots carry the baseline OS, slot A starts primary, and RAUC uses the
RK3588 custom bootcount backend with explicit `rauc.slot=A|B` kernel arguments.
Before flashing, run `v2/tests/preflash-verify.sh --target-size-bytes <bytes>`; it
requires exact GPT geometry, both RK3588 bootloader stages, a compiled selector,
complete kernel/DTB/initrd sets in both slots, and a real compatible signed bundle.
Legacy single-slot images require a full re-flash because their data partition
overlaps the new B-slot extent; they cannot be converted by OTA.

## Directory Structure

```
├── v2/                    # Current build system (mkosi v26)
│   ├── build              # Entry point: ./v2/build <board>
│   ├── ci/
│   │   └── Dockerfile     # Pinned trixie-slim builder (mkosi 26)
│   ├── manifests/         # Board and family manifests + add-on descriptors
│   ├── lib/               # Orchestrator, assembler, bundle scripts,
│   │   │                  #   build-all.sh (parallel runner),
│   │   │                  #   build-feature-sysext.sh (add-on builder)
│   │   └── app-layer/     # sysext.sh — extract → prune → squashfs
│   ├── docs/              # Dev loop, kiosk display, host support, size notes,
│   │   │                  #   Cog add-on recipe, sysext refresh protocol
│   │   └── fast-reload.md # Dev-sync live-reload loop
│   └── tests/             # Manifest + RK3588 A/B/preflash + x86 rollback
├── scripts/
│   └── fetch-debs.sh      # Downloads .deb packages for REPOS array
└── CONTRIBUTING.md        # Contribution rules
```

## Quick Start

```bash
cd image-building-pipeline

# Build for a specific board (container build — canonical)
./v2/build rock-5b-plus
./v2/build orange-pi-5-plus

# Build every board manifest, or a named subset
./v2/build --all
./v2/build --only rock-5b-plus,x86-minipc

# Dry run (resolve + fetch plan only, no image written)
DRY_RUN=1 ./v2/build rock-5b-plus
DRY_RUN=1 ./v2/build --all                 # preview the resolved board list

# Opt-in native build (Debian trixie+ host with mkosi ≥ 26 only)
./v2/build rock-5b-plus --native
```

A single resolved board execs the orchestrator directly. A multi-board selection
(`--all`, or `--only` with 2+ boards) is handed to the parallel runner
`v2/lib/build-all.sh`. An unknown board in `--only` fails loudly: it names the
offender and lists the available boards.

For the full developer bring-up guide (prerequisites, flashing, dev loop, E2E
smoke test, and signing), see
[`docs/DEVICE-BRINGUP.md`](docs/DEVICE-BRINGUP.md).

The hardware-free CI/test entrypoint is `CERALIVE_RUN_REAL_RAUC_CONTRACT=required
./v2/run-tests`. It creates the ignored, NON-PRODUCTION RAUC signing fixture on
demand; production builds must still provide `CERALIVE_RAUC_PKI_DIR` explicitly.
When GNU parallel is available, Bats files run in parallel but cases within each
file stay serial; tests that share the build staging tree also use file locks so
CI concurrency cannot alter their assertions. The real-RAUC harness uses RAUC's
supported boot-slot override for its synthetic file-backed slots, so CI does not
depend on the runner's boot device. The CI Bats job also installs Ubuntu's split
`rauc` + `rauc-service` packages and starts a system D-Bus before the required
real-RAUC contract, reloading the installed bus policy; it does not substitute
a session bus or skip the service check.

## Custom Components

All custom components are distributed via .deb packages from our repository:

- **CeraUI**: Main streaming application UI
- **cerastream**: The streaming engine (Rust) — sole engine since 2026-06-11, when the legacy
  ceracoder encoder was retired after the generic boot-parity profile passed; RK3588
  hardware-gated profiles now track as cerastream hardware-validation work, while
  Jetson profiles are DEFERRED — not currently planned
- **srtla**: SRT Link Aggregation implementation
- **srt**: Custom SRT implementation

Repository location: `/etc/opt/ceraui/`

## Feature Add-Ons

Optional capabilities are delivered as signed per-board/per-OS sysext `.raw`
artifacts, served from `apt.ceralive.tv/R2` at path
`addons/{os_version}/{board}/{feature}.raw`. Each add-on:

- Extends `/usr` and `/opt` only (`SYSEXT_LEVEL=1`, `VERSION_ID=12`)
- Is GPG-signed with the add-on keyring from `cert-work/`
- Has a sha256 checksum verified by CeraUI before activation
- Is managed at runtime by the CeraUI add-on manager (install, enable, disable)

Current validated add-ons:

| Add-on | Status | Notes |
|--------|--------|-------|
| `cog` (Cog + WPEWebKit display engine) | `[PARTIAL]` — packaging validated, hardware-gated | See [`v2/docs/cog-display-addon.md`](v2/docs/cog-display-addon.md) |

Build a feature sysext:

```bash
v2/lib/build-feature-sysext.sh \
  --descriptor v2/manifests/addons/<id>.sysext.conf \
  --board rock-5b-plus \
  --out dist/
```

## Image Size Gate

Every build runs `v2/lib/measure-size.sh`. If the rootfs content's apparent size exceeds
**1.5 GB** the build fails and no `.raucb` is produced. See
[`v2/docs/size-notes.md`](v2/docs/size-notes.md) for the levers applied (locale
strip, `WithDocs=no`, firmware audit).

## BSP Provenance + Advisory Drift-Guard

The kernel BSP floats (name-based `linux-image-vendor-rk35xx`, **no version pin**),
so every build records what it actually fetched. After the BSP fetch,
`v2/lib/fetch-debs.sh` writes the kernel package's resolved version + content
`sha256` to `bsp-provenance.json` in the image output dir (gitignored, never
committed), then runs an **advisory** drift-guard against the committed baseline
`v2/manifests/bsp-baseline.json`.

- A differing version **or** a same-version content-hash re-spin prints a
  `BSP drift` warning — but the guard is **never fatal** (`exit 0` always). The BSP
  stays floating; this is observability, not a pin.
- The baseline is seeded with the reviewed Armbian 26.5.1 kernel package version
  and SHA-256; promotion requires an explicit baseline update.
- The provenance artifact is deliberately **excluded** from the build-plan `sha256`
  determinism comparison (the float would otherwise break reproducibility).

## OTA-During-Stream Guard

`/usr/local/bin/ceralive-update` (the RAUC update entrypoint CeraUI invokes)
refuses to install a bundle while the device is actively streaming. It checks
all three live-media units with `systemctl is-active` and aborts if any is
running:

- `cerastream.service` — the encoder
- `srtla.service` — the bonding **receiver** role
- `srtla-send.service` — the bonding **sender** role

A stopped or not-installed unit reads `inactive`, so the guard is a no-op on a
device that isn't streaming. The sender unit (`srtla-send.service`) is the one
that actually carries the uplink on a bonding sender device, so it is now part
of the guard alongside the encoder and receiver. Proof: `v2/run-tests`
section 16.

## Supported-Modem Matrix + WWAN Module Check

The cellular modem stack (ModemManager + libqmi/libmbim + usb-modeswitch, SRTLA
modem source-routing, the M.2 SIM-detection quirk, and the known-good modem
table) is documented as-is in
[`v2/docs/modem-matrix.md`](v2/docs/modem-matrix.md).

Because the kernel BSP floats (name-only pin, no version pin), a silent Armbian
re-spin could drop one of the six WWAN kernel modules the modem stack binds to
(`qmi_wwan`, `cdc_mbim`, `cdc_wdm`, `option`, `cdc_ether`, `cdc_ncm`) with no
signal. `v2/lib/check-wwan-modules.sh` inspects a kernel `.deb` (or an extracted
module tree) and reports each module as loadable (`=m`), built-in (`=y`, in
`modules.builtin`), or present via `modules.alias`:

```bash
v2/lib/check-wwan-modules.sh <kernel.deb | module-tree-dir>
```

It is **advisory only**, like the BSP drift-guard: a missing module prints a
WARNING but the check **always exits 0** — it never fails the build and never
edits `shared.list` or the kernel config. It is hyphen/underscore aware (the
`cdc_wdm` module ships on disk as `cdc-wdm.ko`) and matches the `option` module
by an exact `option.ko` / `modules.builtin` / alias entry, never a bare `option`
substring. Proof: `v2/run-tests` section 17.

## Kernel Currency Watch

The image is locked to the **vendor 6.1 BSP + Rockchip MPP** for H.265 encoding.
This decision is recorded with a 7-way evidence summary and two precise revisit
triggers (a 6.12+ vendor BSP with MPP support, or mainline landing a frozen V4L2
stateless H.265 encode uAPI + VEPU580 driver) in
[`v2/docs/kernel-currency-watch.md`](v2/docs/kernel-currency-watch.md).

## License

This project is dual-licensed under either:
- MIT (see LICENSE-MIT)
- Apache-2.0 (see LICENSE-APACHE)

You may choose either license.
