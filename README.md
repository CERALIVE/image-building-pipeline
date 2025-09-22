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
- **Custom software stack**: CeraUI, belacoder, srtla, srt via .deb packages
- **Minimal system**: Debian-based with minimal apt sources
- **Ready-to-use**: Images for eMMC/SD cards, no additional setup required
- **Device support**: Automatic USB audio/video device detection and access
- **Modem support**: M.2 and USB 4G/5G modems

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    CeraUI Application                       │
├─────────────────────────────────────────────────────────────┤
│  belacoder  │    srtla    │     srt     │   WiFi Manager   │
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

## Build Environments

- **Local**: Native Linux build with cross-compilation support
- **Docker**: Containerized build for consistent environments
- **CI/CD**: Automated builds with testing and distribution

## Directory Structure

```
├── build/                 # Build scripts and tools
├── configs/              # Device-specific configurations
│   ├── devices/         # Per-device settings
│   ├── base/           # Common base configurations
│   └── repos/          # Custom repository configurations
├── docker/              # Docker build environment
├── images/              # Generated image outputs
├── scripts/             # Utility and helper scripts
├── tests/               # Testing framework
└── ci/                  # CI/CD pipeline definitions
```

## Quick Start

```bash
# Interactive mode with beautiful arrow key navigation
./build.sh

# Build specific device (auto-detects Docker/local environment)
./build.sh --device orangepi5plus
./build.sh --device rock5bplus

# Build all supported devices
./build.sh --all

# Force specific environment if needed
./build.sh --device orangepi5plus --environment docker
./build.sh --device rock5bplus --environment local
```

### ✨ **Interactive Experience**

The build script provides a **clean interactive menu** with:
- 🎯 **Arrow key navigation** (↑/↓ to browse devices)
- 🎨 **Real-time highlighting** of selected device
- 🧠 **Smart terminal detection** (falls back to simple mode if needed)
- ⚡ **Multiple input methods** (arrows, numbers, or direct typing)

## Custom Components

All custom components are distributed via .deb packages from our repository:

- **CeraUI**: Main streaming application UI
- **belacoder**: Hardware-accelerated encoding with GStreamer integration  
- **srtla**: SRT Link Aggregation implementation
- **srt**: Custom SRT implementation

Repository location: `/etc/opt/ceraui/`

## License

This project is dual-licensed under either:
- MIT (see LICENSE-MIT)
- Apache-2.0 (see LICENSE-APACHE)

You may choose either license.
