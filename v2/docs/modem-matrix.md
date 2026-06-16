# Supported-Modem Matrix

This document describes the **existing** cellular (LTE/5G) modem stack baked into
the CeraLive device image, and the build-time check that verifies the kernel
ships the WWAN modules that stack depends on. It is a description of what the
image does today — not a roadmap.

The modem runtime stack is complete and production-grade. Nothing here changes
it; this page documents it and pairs it with an **advisory** module-presence
check (`v2/lib/check-wwan-modules.sh`).

---

## 1. Userspace cellular stack

The image ships a standard ModemManager-based cellular stack. The relevant
packages come from `v2/manifests/packages/shared.list`:

| Package | Role | Source |
|---------|------|--------|
| `modemmanager` | Cellular modem management daemon (NetworkManager drives it) | `shared.list` §"Modems" |
| `libqmi-utils` | QMI modem control (Qualcomm `qmicli`) | `shared.list` §"Modems" |
| `libmbim-utils` | MBIM modem control (`mbimcli`) | `shared.list` §"Modems" |
| `usb-modeswitch` | Flips USB modems out of mass-storage mode into modem mode so they enumerate | `shared.list` §"USB modem bring-up" |
| `network-manager` | Primary connection manager (WiFi/Ethernet/modem); CeraUI drives it | `shared.list` §"Network management" |

`ModemManager` is enabled as a system service in
`v2/mkosi/customize/postinst-lib.sh` (`configure_services` enables `ModemManager`
alongside `NetworkManager`, `systemd-resolved`, etc.).

USB device access for modems is granted by udev in
`v2/mkosi/customize/udev.sh` ("USB Modem Devices (4G/5G)"): the common modem
vendor USB IDs are group-tagged `dialout` so the daemon can talk to the control
ports.

---

## 2. Known-good modems

The image group-tags these modem vendor USB IDs in `udev.sh` — they are the
validated vendor set the device enumerates and grants control-port access to.
Protocol is the control protocol ModemManager uses; the **Modules** column is the
kernel-driver path each protocol relies on (see §4).

| Vendor | USB ID | Typical protocol | Kernel modules used |
|--------|--------|------------------|---------------------|
| Quectel | `2c7c` | QMI (also MBIM on RM-series) | `qmi_wwan` + `cdc_wdm` (QMI); `cdc_mbim` + `cdc_wdm` (MBIM); `option` (AT/serial ports) |
| Sierra Wireless | `1199` | MBIM / QMI | `cdc_mbim` + `cdc_wdm`, or `qmi_wwan` + `cdc_wdm`; `option` |
| Huawei | `12d1` | NCM / MBIM | `cdc_ncm` or `cdc_mbim` + `cdc_wdm`; `option` |
| ZTE | `19d2` | QMI / NCM | `qmi_wwan` + `cdc_wdm`, or `cdc_ncm`; `option` |
| Telit | `1bc7` | QMI / ECM | `qmi_wwan` + `cdc_wdm`, or `cdc_ether`; `option` |

These are USB modems. M.2 B-key modems (Quectel `2c7c`, Sierra `1199`) enumerate
over USB internally and additionally need the SIM-detection quirk in §3.

---

## 3. M.2 SIM-detection quirk

M.2 B-key modems need ModemManager forced to probe and treat the port as a modem
candidate so SIM detection works. `v2/mkosi/customize/quirks.sh`
(`handle_m2_modem_sim_workaround`) adds `ENV{ID_MM_DEVICE_PROCESS}="1"` and
`ENV{ID_MM_CANDIDATE}="1"` udev properties for the Quectel (`2c7c`) and Sierra
(`1199`) vendor IDs already group-tagged in `udev.sh`. This is documented here
as-is and is not modified by the module check.

---

## 4. SRTLA modem source-routing

Bonded streaming requires each modem uplink to be source-routed into its own
routing table so SRTLA can bond multiple links. NetworkManager on Debian bookworm
defaults to `dhcp=internal` and never runs the `dhclient-exit-hooks.d/` scripts,
so the routing is installed by the NetworkManager dispatcher
`90-srtla-wifi-routing` (`v2/mkosi/customize/networking-srtla.sh`,
`install_nm_dispatcher`):

| Interface pattern | Routing table |
|-------------------|---------------|
| `usb0` / `enx*0` | 100 |
| `usb1` / `enx*1` | 101 |
| … | … |
| `usb7` / `enx*7` | 107 |
| `wlan0`..`wlan4` | 120..124 |

On interface `up`/`dhcp4-change` the dispatcher installs a `from <ip>` source
rule and a default route via the modem's gateway in tables 100–107, mirroring the
retained `dhclient-exit-hooks.d/srtla-source-routing` hook (which still covers
non-NM dhclient paths). This is documented as-is and is not modified by the
module check.

---

## 5. Required WWAN kernel modules

The userspace stack above is inert unless the kernel exposes the WWAN network and
serial drivers the modems bind to. The cellular datapath depends on six modules:

| Module | Purpose |
|--------|---------|
| `qmi_wwan` | QMI WWAN network device (Qualcomm modems) |
| `cdc_mbim` | MBIM WWAN network device (USB CDC MBIM) |
| `cdc_wdm` | USB CDC WDM character device — the QMI/MBIM control channel (`/dev/cdc-wdm*`); the on-disk file is `cdc-wdm.ko` |
| `option` | USB serial driver for modem AT/diagnostic ports |
| `cdc_ether` | USB CDC Ethernet (ECM) network device |
| `cdc_ncm` | USB CDC NCM network device |

A module may ship either way and both satisfy the stack:

- **Loadable (`=m`)** — a `<module>.ko` file (optionally `.ko.xz`/`.ko.gz`/`.ko.zst`)
  under `lib/modules/<kver>/kernel/…`, loaded on demand by modprobe.
- **Built-in (`=y`)** — compiled into the kernel image and listed in
  `lib/modules/<kver>/modules.builtin` (no `.ko` file ships).

On the current Armbian vendor BSP kernel (`linux-image-vendor-rk35xx`,
`v2/manifests/families/rk3588.yaml`), `qmi_wwan`, `cdc_mbim`, `cdc_wdm`, and
`option` ship loadable (`=m`), while `cdc_ether` and `cdc_ncm` are built-in
(`=y`). Both forms are accepted.

---

## 6. Build-time module-presence check

The kernel BSP floats — Decision D3 pins it by **name only**
(`linux-image-vendor-rk35xx`), with no version pin, so a silent Armbian re-spin
could drop one of the six modules with no signal. `v2/lib/check-wwan-modules.sh`
makes that observable.

```bash
v2/lib/check-wwan-modules.sh <kernel.deb | module-tree-dir>
```

What it does:

- Inspects a kernel `.deb` (extracted via `dpkg-deb`, or the `ar`+`tar` fallback)
  or an already-extracted module tree, and reports, per module, whether it ships
  as loadable (`=m`), built-in (`modules.builtin`, `=y`), or via a `modules.alias`
  entry.
- Hyphen/underscore aware: the `cdc_wdm` module ships on disk as `cdc-wdm.ko`;
  the check normalises `-`↔`_` (as modprobe does) so the file satisfies the
  module name.
- Matches the `option` module by an exact `option.ko` basename, a
  `…/option.ko` `modules.builtin` entry, or a `modules.alias` line whose module
  token is `option` — **never** a bare occurrence of the word "option" in some
  other filename or file body (a known false-positive trap).
- Asserts a `.deb` extractor (`dpkg-deb`, or `ar`+`tar`) is available before it
  tries to open a `.deb`.

It is **advisory only**, exactly like the BSP drift-guard: a missing module
prints a `WARNING` and the check **still exits 0**. It never fails the build and
never edits `shared.list` or the kernel config — reacting to a warning (sourcing
a kernel that ships the module, or adding it) is a human decision.

Proof: `v2/run-tests` section 17.
