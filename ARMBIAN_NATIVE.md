# CeraLive Armbian Native Build System

This is the **recommended approach** for building CeraLive images using Armbian's official build framework.

## 🚀 Why Armbian Native?

✅ **Official Support** - Uses Armbian's tested build system  
✅ **Proper Cross-Compilation** - Native ARM64 builds from x86_64  
✅ **Board Optimizations** - RK3588-specific kernel configs  
✅ **Clean Minimal Images** - Optimized for streaming appliances  
✅ **Automated Customization** - userpatches system for CeraUI  
✅ **CI/CD Ready** - Built for automation pipelines  

## 🎯 Quick Start

```bash
# Interactive device selection with auto-environment detection
./build.sh

# Build specific device
./build.sh -d orangepi5plus

# Build all devices with clean build
./build.sh --all --clean

# Development variant with debugging tools
./build.sh -d rock5bplus -v development
```

## 📁 Directory Structure

```
userpatches/                      # Armbian customization directory
├── customize-image.sh            # Main CeraLive customization script
├── config-orangepi5plus.conf     # Orange Pi 5+ build configuration  
├── config-rock5bplus.conf        # Rock 5B+ build configuration
└── overlay/                      # Files to copy to image
    └── etc/motd.d/01-ceralive    # CeraLive welcome message
```

## 🛠 Customization System

### `customize-image.sh`
Main script that runs in chroot during image creation:
- Creates `ceraui` user with hardware permissions (CeraLive branding)
- Installs streaming packages (GStreamer, network tools)
- Configures minimal APT sources  
- Sets up hardware access (USB, HDMI, GPIO)
- Applies streaming optimizations
- Configures WiFi management

### Device Configurations
- **Orange Pi 5+**: Optimized for streaming with minimal footprint
- **Rock 5B+**: Full-featured appliance with additional connectivity

### Overlay Files
Files in `userpatches/overlay/` are copied to the image:
- Custom configurations
- Service files
- Scripts and tools
- Branding/MOTD

## 🎛 Build Options

### Devices
- `orangepi5plus` - Orange Pi 5+ (RK3588S) streaming optimized
- `rock5bplus` - Radxa Rock 5B+ (RK3588) full featured

### Variants  
- `minimal` - Basic streaming functionality only
- `standard` - Full CeraLive feature set (recommended)
- `development` - Development tools and debug symbols

### Environments
- `docker` - Containerized build (recommended)
- `local` - Native Linux build
- `auto` - Auto-detect best option

## 🔧 Advanced Configuration

### Custom Packages
Add to device config files:
```bash
EXTRA_BSP_PACKAGES+="your-package"
```

### Kernel Modifications
- Place patches in `userpatches/kernel/`
- Custom kernel config: `userpatches/linux-rockchip64-current.config`

### U-Boot Customization  
- Place patches in `userpatches/u-boot/`

## 📊 Build Process

1. **Setup** - Clone Armbian build framework
2. **Configure** - Copy userpatches and device configs
3. **Build** - Run Armbian compile.sh with CeraUI parameters
4. **Customize** - Execute customize-image.sh in chroot
5. **Finalize** - Create compressed image with checksums

## 🎯 Output

Built images are saved to:
```
images/
├── orangepi5plus/
│   └── standard/
│       ├── Armbian_*.img.xz
│       └── *.sha256
└── rock5bplus/
    └── standard/
        ├── Armbian_*.img.xz  
        └── *.sha256
```

## 🆚 vs Traditional Approach

| Feature | Armbian Native | Traditional |
|---------|----------------|-------------|
| Base System | Clean Armbian build | Downloaded image modification |
| Customization | Native userpatches | Post-download scripts |
| Optimization | Board-specific kernel | Generic configurations |
| Maintenance | Armbian updates | Manual image updates |
| CI/CD | Built-in support | Custom Docker setup |

## 🔄 Migration

To migrate from the traditional approach:

1. Use `build-armbian.sh` instead of `build.sh`
2. Move customizations to `userpatches/customize-image.sh`  
3. Copy overlay files to `userpatches/overlay/`
4. Update CI/CD to use new script

## 📚 Resources

- [Armbian Build Documentation](https://docs.armbian.com/Developer-Guide_Welcome/)
- [Userpatches Guide](https://docs.armbian.com/Developer-Guide_User-Configurations/)
- [CeraUI GitHub](https://github.com/CERALIVE/CeraUI)

This approach provides a more robust, maintainable, and official way to build CeraUI streaming appliances! 🚀
## Hostname and mDNS

The image customizer installs a first-boot service that sets a unique hostname before networking starts:
- First unit uses `ceralive`; additional units get `ceralive-<n>` (deterministic from machine-id)
- mDNS is enabled (Avahi), so `ceralive.local` / `ceralive-<n>.local` resolve on the LAN
- Override index by writing to `/etc/ceralive/host_index` (set to `1` for the plain `ceralive` name)
