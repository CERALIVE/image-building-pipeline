# CeraLive Image Building - Quick Start Guide

This guide will help you build your first CeraLive streaming appliance image in under 10 minutes.

## Prerequisites

### For Docker builds (Recommended):
- Docker installed and running
- At least 8GB free disk space
- Internet connection for downloading Armbian base images

### For local builds:
- Linux system (Ubuntu/Debian preferred)
- `debootstrap`, `qemu-user-static`, `parted`, `kpartx` installed
- At least 8GB free disk space

## Step 1: Choose Your Device

Currently supported devices:

- **Orange Pi 5+** - RK3588S based board
- **Radxa Rock 5B+** - RK3588 based board

## Step 2: Build Your First Image

The build script **automatically detects** your environment (Docker vs local) and can help you **choose the right device** - no need to research specifications!

### Interactive Mode (Easiest):

```bash
# Just run the script from your terminal - it will guide you through device selection
./build.sh
```

**Important**: Interactive mode requires a proper terminal session. It won't work through:
- Pipes (e.g., `echo "1" | ./build.sh`)  
- Redirects (e.g., `./build.sh > output.log`)
- Background processes or automated environments
- Non-TTY environments (CI/CD, cron jobs, etc.)

For automated environments, always specify the device explicitly:
```bash
./build.sh --device orangepi5plus    # ✓ Works everywhere
./build.sh --all                     # ✓ Works everywhere
```

This will show you:
- Clean device selection interface
- Automatic environment detection
- One-command build process

### Interactive Mode Experience:

When you run `./build.sh` from your terminal, you get a clean device selection:

#### **Enhanced Menu (Modern Terminals):**
```
$ ./build.sh

[INFO] No device specified. Starting interactive selection...
[INFO] ✓ Docker detected and running  
[INFO] Auto-detected environment: docker

[INFO] Select target device:

Use ↑/↓ arrows or 1-3 to select, Enter to confirm

► [1] Orange Pi 5+
  [2] Radxa Rock 5B+
  [3] All devices

Current: Orange Pi 5+ (Enter to confirm)
```

#### **Simple Menu (Basic Terminals):**
```
$ ./build.sh

[INFO] Select target device:

[1] Orange Pi 5+
[2] Radxa Rock 5B+
[3] All devices

Device [1-3]: 1
```

#### **Navigation:**
- **↑/↓ Arrow Keys**: Navigate (enhanced mode)
- **1, 2, 3**: Direct selection
- **Enter**: Confirm
- **Q**: Quit

### Direct Commands:

```bash
# Build specific device (auto-detects best build method)
./build.sh --device orangepi5plus
./build.sh --device rock5bplus

# Build with development tools included
./build.sh --device orangepi5plus --variant development

# Build all supported devices
./build.sh --all
```

### What Happens Automatically:

1. **Docker detected and running** → Uses Docker (recommended)
2. **Docker not available** → Checks for local build tools
3. **Local tools available** → Uses local build
4. **Neither available** → Shows helpful installation instructions

### Manual Environment Override (if needed):

```bash
# Force Docker build
./build.sh --device orangepi5plus --environment docker

# Force local build
./build.sh --device orangepi5plus --environment local
```

### CI/CD and Automation:

The interactive mode automatically detects non-interactive environments (like CI/CD pipelines) and falls back to requiring explicit parameters:

```bash
# In CI/CD - must specify device explicitly
./build.sh --device orangepi5plus    # ✓ Works in CI/CD
./build.sh --all                     # ✓ Works in CI/CD  
./build.sh                           # ✗ Fails in CI/CD with helpful error
```

## Step 3: Flash the Image

The build process creates branded image files in `images/[device]/[variant]/`: 

```bash
# Example output file
images/orangepi5plus/standard/CERALIVE_orangepi5plus_bookworm_stable_20250922-120000.img
```

### Flash to SD Card:
```bash
# Extract and flash (replace /dev/sdX with your SD card)
sudo dd if="$(ls -1t images/orangepi5plus/standard/CERALIVE_*.img | head -n1)" of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

### Flash to eMMC (Recommended):
1. Flash the **installer** version to SD card
2. Insert both SD card and eMMC module
3. Boot from SD card (auto-installs to eMMC and shuts down)
4. Remove SD card and boot from eMMC

## Step 4: First Boot

1. **Insert the flashed SD card/eMMC** into your device
2. **Connect HDMI input** (if using HDMI capture)
3. **Connect Ethernet** (recommended for first setup)
4. **Power on** the device
5. **Wait 2-3 minutes** for first boot initialization

### Default Access
- Hostname: `ceralive` (first) or `ceralive-<n>` (subsequent); reachable via `ceralive.local`
- User: `ceraui` (internal app user)
- SSH: disabled by default (enable if needed)

Note: Set `/etc/ceralive/host_index` to `1` to force plain `ceralive` on a device; otherwise a deterministic index is derived from machine-id.

## Step 5: Verify Installation

### Check CeraLive Components:
```bash
# SSH into device or use console
ssh ceraui@ceralive.local # or use the device IP

# Check if CeraUI packages are installed
dpkg -l | grep ceraui

# Verify hardware acceleration
gst-inspect-1.0 rockchipmpp

# Test HDMI capture (if connected)
v4l2-ctl --list-devices
```

### Check Hardware Access:
```bash
# Verify user is in correct groups
groups ceraui

# Check audio devices
aplay -l

# Check video devices  
v4l2-ctl --list-devices

# Check USB modems (if connected)
lsusb | grep -i modem
```

## Step 6: Install Your Custom Software

Since your CeraUI components (ceraui, belacoder, srtla, srt) are distributed as .deb files:

```bash
# Update package lists (includes your custom repo)
sudo apt update

# Install CeraUI components
sudo apt install ceraui belacoder srtla srt

# Enable CeraUI service
sudo systemctl enable ceraui
sudo systemctl start ceraui
```

## Troubleshooting

### Environment Detection Issues:

**"No suitable build environment detected"**:
- Install Docker: `sudo apt install docker.io && sudo systemctl start docker`
- Or install local tools: `sudo apt install debootstrap qemu-user-static parted kpartx xz-utils`
- Add user to docker group: `sudo usermod -aG docker $USER` (logout/login required)

**Docker found but not running**:
- Start Docker: `sudo systemctl start docker`
- Enable on boot: `sudo systemctl enable docker`

### Build Issues:

**"Failed to download Armbian image"**:
- Check internet connection
- Verify Armbian version via `armbian-build/VERSION` if needed
- Check [Armbian releases](https://github.com/armbian/build/releases/) for latest versions

**"Permission denied" errors**:
- Ensure Docker has proper permissions
- For local builds, ensure user can sudo
- Check if user is in docker group: `groups $USER`

### Hardware Issues:

**HDMI capture not working**:
- Check `/dev/video0` exists: `ls -la /dev/video*`
- Verify rk_hdmirx driver: `dmesg | grep hdmi`
- Move cellular modems away from HDMI cable (EMI interference)

**USB modems not detected**:
- Check USB power limits in device config
- Verify modem compatibility with M.2 slot size (42mm vs 52mm)
- Check if modem needs switching from storage mode

**Audio/video permissions**:
- Verify user groups: `groups ceraui`
- Check udev rules: `cat /etc/udev/rules.d/99-ceraui-hardware.rules`
- Reload rules: `sudo udevadm control --reload && sudo udevadm trigger`

## Advanced Configuration

### Build Custom Variants:

```bash
# Minimal build (smallest size)
./build.sh --device orangepi5plus --variant minimal

# Development build (includes build tools, debuggers)
./build.sh --device rock5bplus --variant development

# Clean build (removes cached files)  
./build.sh --device orangepi5plus --clean

# Force specific environment if auto-detection doesn't work
./build.sh --device orangepi5plus --environment docker
./build.sh --device orangepi5plus --environment local
```

### Customize Before Building:

Edit configuration files in `configs/`:
- `configs/base/ceraui-base.conf` - Common settings
- `configs/devices/orangepi5plus.conf` - Device-specific settings
- `configs/devices/rock5bplus.conf` - Device-specific settings

### CI/CD Integration:

The pipeline is designed for automated builds:

```yaml
# Example GitHub Actions
name: Build CeraLive Images
on:
  schedule:
    - cron: '0 2 * * 0'  # Weekly builds
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Build all devices
        run: ./build.sh --all --environment docker
```

## Next Steps

1. **Customize the base configuration** in `configs/base/ceraui-base.conf`
2. **Set up your custom APT repository** for CeraUI components
3. **Test streaming functionality** with your hardware
4. **Configure automatic updates** for your deployed devices
5. **Set up CI/CD** for automated image builds

## Getting Help

- Check device-specific notes in `configs/devices/[device].conf`
- Review [BELABOX documentation](https://belabox.net/rk3588/) for hardware insights
- Monitor build logs in `images/[device]/[variant]/build.log`
- Test images in QEMU before flashing to hardware

You now have a complete, ready-to-use streaming appliance image built on the solid foundation of Armbian with your custom CeraUI software stack!

## Hostname and mDNS

- First boot sets a unique hostname: `ceralive` (first device) or `ceralive-<n>` for subsequent devices.
- Devices advertise on the LAN as `ceralive.local` (or `ceralive-<n>.local`) via mDNS (Avahi).
- Override index (to force a specific suffix) by setting:
```bash
echo 7 | sudo tee /etc/ceralive/host_index   # results in hostname: ceralive-7
```
- Setting `host_index` to `1` yields the plain `ceralive` hostname.
