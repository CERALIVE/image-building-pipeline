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
- **Custom software stack**: `CeraUI`, `ceracoder`, `srtla`, `srt` via .deb packages
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
│  ceracoder  │    srtla    │     srt     │   WiFi Manager   │
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
│   └── tests/             # Manifest validation + preflash verify + QEMU x86
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

## Custom Components

All custom components are distributed via .deb packages from our repository:

- **CeraUI**: Main streaming application UI
- **ceracoder**: Hardware-accelerated encoding with GStreamer integration
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

Every build runs `v2/lib/measure-size.sh`. If the compressed rootfs exceeds
**1.5 GB** the build fails and no `.raucb` is produced. See
[`v2/docs/size-notes.md`](v2/docs/size-notes.md) for the levers applied (locale
strip, `WithDocs=no`, firmware audit).

## License

This project is dual-licensed under either:
- MIT (see LICENSE-MIT)
- Apache-2.0 (see LICENSE-APACHE)

You may choose either license.
