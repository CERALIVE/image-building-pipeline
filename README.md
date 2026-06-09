# CeraLive Image Building Pipeline

A comprehensive build pipeline for creating ready-to-use images for ARM-based streaming devices, initially targeting Rockchip RK3588 devices with future support for Intel N100/N200 and AMD platforms.

> Status: Alpha — interfaces and docs may evolve. Contributions welcome! See [CONTRIBUTING.md](./CONTRIBUTING.md).

## Supported Devices

### Current (RK3588-based)
- **Orange Pi 5+** - Primary target with HDMI input and good power delivery
- **Radxa Rock 5B+** - Best HDMI input EMI resistance, M.2 modem support

### Future Support
- Intel N100/N200 devices
- AMD-based microcomputers

## Key Features

- **Streaming-focused**: SRTLA bonding, WiFi management, HDMI capture
- **Hardware acceleration**: Rockchip MPP integration for encoding
- **Custom software stack**: `CeraUI`, `ceracoder`, `srtla`, `srt` via .deb packages
- **Minimal system**: Debian-based with minimal apt sources
- **Ready-to-use**: Images for eMMC/SD cards, no additional setup required
- **Device support**: Automatic USB audio/video device detection and access
- **Modem support**: M.2 and USB 4G/5G modems

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    CeraUI Application                       │
├─────────────────────────────────────────────────────────────┤
│  ceracoder  │    srtla    │     srt     │   WiFi Manager   │
├─────────────────────────────────────────────────────────────┤
│           GStreamer + Rockchip MPP (Hardware Encoding)      │
├─────────────────────────────────────────────────────────────┤
│            Armbian Minimal + CeraLive Customizations        │
├─────────────────────────────────────────────────────────────┤
│                    Hardware Layer                           │
│  Orange Pi 5+ │ Radxa Rock 5B+ │ Future Intel/AMD devices  │
└─────────────────────────────────────────────────────────────┘
```

### Why Armbian?

**Armbian provides the perfect foundation** for ARM-based streaming appliances:

- **Hardware acceleration ready**: Rockchip MPP and GStreamer integration included
- **Minimal server images**: No desktop bloat, perfect for appliances  
- **Device-specific optimization**: Kernels and drivers optimized per board
- **HDMI input support**: Video capture drivers pre-configured
- **Proven platform**: Used successfully by BELABOX and other streaming projects
- **Regular updates**: Security and hardware support maintained

## Build System

The current build path is `v2/` using mkosi. It produces reproducible `.raw` sysext
bundles and `.raucb` A/B RAUC OTA packages from a layered source. See
[`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) for the full dev loop.

## Directory Structure

```
├── v2/                    # Current build system (mkosi)
│   ├── build              # Entry point: ./v2/build <board>
│   ├── manifests/         # Board and family manifests
│   ├── lib/               # Orchestrator, assembler, bundle scripts
│   ├── docs/              # Dev loop, kiosk display, deferred items
│   └── tests/             # Manifest validation + preflash verify
├── scripts/
│   └── fetch-debs.sh      # Downloads .deb packages for REPOS array
└── CONTRIBUTING.md        # Contribution rules
```

## Quick Start

```bash
cd image-building-pipeline

# Build for a specific board
./v2/build rock-5b-plus
./v2/build orange-pi-5-plus

# Dry run (resolve + fetch plan only, no image written)
DRY_RUN=1 ./v2/build rock-5b-plus
```

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

## License

This project is dual-licensed under either:
- MIT (see LICENSE-MIT)
- Apache-2.0 (see LICENSE-APACHE)

You may choose either license.
