# Armbian Native Build (Superseded)

> **Status**: Superseded by the `v2/` mkosi build system. This document is retained as a
> historical reference. For the current build path, see [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md).

## What This Was

The Armbian native build used Armbian's official build framework (via the root-level `build.sh`)
to produce `.img` disk images for supported boards. It required a native Linux host with
Armbian's toolchain installed and produced monolithic images without A/B update support.

Board targets were Orange Pi 5+ (RK3588S) and Radxa Rock 5B+ (RK3588). Customization ran
through Armbian's `userpatches/` system: a `customize-image.sh` chroot script installed
CeraLive packages, configured hardware access, and set up the `ceraui` user. A first-boot
service handled unique hostname assignment and mDNS via Avahi.

## Why It Was Superseded

The `v2/` mkosi build system replaced this approach. mkosi produces reproducible `.raw` sysext
bundles and `.raucb` A/B RAUC OTA packages from a single layered source tree, enabling
over-the-air updates and a cleaner separation between the base OS and application layers.

## Current Build Path

See [`v2/docs/dev-loop.md`](v2/docs/dev-loop.md) for the active development and build workflow.
