# Supported-Modem Matrix

This document describes the **existing** cellular (LTE/5G) modem stack baked into
the CeraLive device image, and the build-time check that verifies the kernel
ships the WWAN modules that stack depends on. It is a description of what the
image does today — not a roadmap.

The modem runtime stack is complete and production-grade. Nothing here changes
it; this page documents it and pairs it with an **advisory** module-presence
check (`lib/check-wwan-modules.sh`).

---

## 1. Userspace cellular stack

The image ships a ModemManager-based cellular stack. The **core ModemManager
1.24 closure** — the nine ELF-shipping packages below — is a CeraLive fork
(`~ceralive.2`) published by modem-stack v1.3.0, staged as
first-party `.deb`s (`FIRST_PARTY_APT_PKGS` in `lib/fetch-debs.sh`, pinned in
`manifests/first-party-deb-versions.txt`) and installed by the **app layer**
(`RUNTIME_APP_PKGS`). It **upgrades** the Debian modem packages the runtime layer
pulls transitively via `shared.list`, in the same local dpkg transaction. The
`apt.ceralive.tv` origin pin (`Package: *`, Pin-Priority 990) keeps the fork
winning for on-device `apt-get upgrade`.

| Fork closure package | Role |
|----------------------|------|
| `modemmanager` | Cellular modem management daemon (NetworkManager drives it) |
| `libmm-glib0` | ModemManager GLib client library |
| `libqmi-glib5` / `libqmi-utils` / `libqmi-proxy` | QMI (Qualcomm) transport lib + `qmicli` + shared control-port proxy |
| `libmbim-glib4` / `libmbim-utils` / `libmbim-proxy` | MBIM transport lib + `mbimcli` + shared control-port proxy |
| `libqrtr-glib0` | QRTR (Qualcomm IPC router) GLib library |

These nine form a **self-contained dependency closure** (`modemmanager` →
`libmm-glib0`; the glib libs bind to the qmi/mbim/qrtr transports). External deps
(GLib, `libgudev`, `polkit`, systemd) come from Debian.

`ceralive-modem-support=1.3.0` is a separate, `Architecture: all` first-party
companion staged through that same app-layer route. It owns generic modem system
assets, including `60-ceralive-modem.rules`; the image-owned
`99-ceralive-hardware.rules` and generated `78-mm-ceralive-slot-uid.rules` have
distinct basenames, so udev cannot shadow the packaged companion rules.
The `[7/9]` parity gate enforces both that basename separation and exactly one
package owner for every path in `manifests/modem-support-ownership.txt`; the
offline negative suites inject a basename collision, an orphan, and duplicate
ownership so these checks cannot pass vacuously.

Supporting packages that stay **Debian** (`manifests/packages/shared.list`):

| Package | Role | Source |
|---------|------|--------|
| `mobile-broadband-provider-info` | Mobile-provider / APN database ModemManager reads to auto-resolve connection settings from the SIM's MCCMNC | `shared.list` §"Modems" (explicit — a `Recommends:` `--no-install-recommends` drops) |
| `usb-modeswitch` | Flips USB modems out of mass-storage mode into modem mode so they enumerate | `shared.list` §"USB modem bring-up" |
| `uhubctl` | Manual per-port power-cycle tool for a physically wedged USB modem; no service, timer, or udev rule invokes it automatically | `shared.list` §"USB modem bring-up" |
| `network-manager` | Primary connection manager (WiFi/Ethernet/modem); CeraUI drives it | `shared.list` §"Network management" |

`ModemManager` is enabled as a system service in
`mkosi/customize/postinst-lib.sh` (`configure_services` enables `ModemManager`
alongside `NetworkManager`, `systemd-resolved`, etc.).

USB device access for modems is granted by udev in
`mkosi/customize/udev.sh` ("USB Modem Devices (4G/5G)"): the common modem
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
candidate so SIM detection works. The live build resolves the board manifest's
`quirks.m2_modem_sim_workaround` value into `CERALIVE_BOARD_QUIRKS`, passes it
through the mkosi subimage environment, and
`mkosi/customize/postinst.d/hardware.sh::apply_board_quirks` adds
`ENV{ID_MM_DEVICE_PROCESS}="1"` and
`ENV{ID_MM_CANDIDATE}="1"` udev properties for the Quectel (`2c7c`) and Sierra
(`1199`) vendor IDs already group-tagged in `udev.sh`. Boards that do not declare
the quirk emit no rows. The older `customize/quirks.sh` handler remains covered
as a hermetic helper but is not the live image writer.

---

## 4. SRTLA modem source-routing — RETIRED

**There is no per-modem source-routing layer any more.** Bonded streaming pins
each uplink's egress in the socket instead: `srtla_send` binds every link with
`SO_BINDTODEVICE` plus a source-address bind, so the interface is named by the
socket rather than inferred from a routing rule.

The retired assets — the NM dispatcher `90-srtla-wifi-routing`, the dhclient hook
`dhclient-exit-hooks.d/srtla-source-routing`, the `rt_tables` reservations
(`100-107 modem0..7`, `120-124 wlan0..4`), and the `networking-srtla.sh` module —
are removed from the image, and both `ci/postinst-drift-check.sh` (CHECK 2) and
`lib/parity-check.sh` (§D) now fail if any of them reappears.

Why it was retired rather than guarded, in one line each, all measured on a live
`7.1.7-ceralive-rk3588` board: `ip rule` was unsupported there
(`# CONFIG_IP_ADVANCED_ROUTER is not set` — the current `v7.2` edge fragment
declares it `=y`, which changes the capability but not the retirement), an `ip route add … table N` silently
lands in the **MAIN** table on that kernel (so the dispatcher could install a
metric-0 default that outranks every DHCP route), it logged a success line after
both of its mutations had failed, and its dhclient half could never run because
`dhclient` is not installed. On the vendor kernel — where `ip rule` does work —
its `from <source-ip>` rules cannot tell this fleet's two HiLink twins apart,
because both lease `192.168.8.100`.

Full decision record with verbatim traces:
`.omo/notepads/modem-phase-c-quality/evidence/todo38.md`; summary in
[`../AGENTS.md`](../AGENTS.md) → "SRTLA source-policy routing is RETIRED".

`rp_filter` is a SEPARATE, RETAINED asset and is unaffected:
`/etc/sysctl.d/60-ceralive-rp-filter.conf` still sets
`net.ipv4.conf.{all,default}.rp_filter = 2` (loose reverse-path), written at image
build by `postinst.d/networking.sh::install_interface_naming`. Loose RPF is what
lets a multi-WAN board accept return traffic that arrives on a different interface
than the route table would pick; it is required by the device-bound bond, not by
policy routing. No runtime service writes it — CeraUI and `srtla_send` only READ
route/rp_filter health and report it.

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
`manifests/families/rk3588.yaml`), `qmi_wwan`, `cdc_mbim`, `cdc_wdm`, and
`option` ship loadable (`=m`), while `cdc_ether` and `cdc_ncm` are built-in
(`=y`). Both forms are accepted.

---

## 6. Build-time module-presence check

The kernel package is exact-versioned in
`manifests/armbian-bsp-deb-versions.txt`. An upstream repository can still
replace bytes under the same Debian version, so a same-version Armbian re-spin
could drop one of the six modules with no signal. `lib/check-wwan-modules.sh`
makes that observable.

```bash
lib/check-wwan-modules.sh <kernel.deb | module-tree-dir>
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
- On a `*-vendor-rk35xx` module tree, additionally reports whether the native
  FM350 PCIe driver `mtk_t7xx` is present. Mainline trees are explicitly out of
  scope, and the USB `0e8d:7127` bench personality is never treated as evidence
  for native PCIe `14c3:4d75` support.

It is **advisory only**, exactly like the BSP drift-guard: a missing module
prints a `WARNING` and the check **still exits 0**. It never fails the build and
never edits `shared.list` or the kernel config — reacting to a warning (sourcing
a kernel that ships the module, or adding it) is a human decision.

Proof: `run-tests` section 17.

---

## 7. Modem slot-UID naming (`modem_ports`) — fail-closed generator + discovery runbook

The board manifest carries an optional `modem_ports` block that drives
deterministic ModemManager slot-UID naming. It is **fail-closed**: while
`status: unverified` (the shipped default on every board) the udev generator
`mkosi/customize/udev.sh::generate_modem_slot_uid_rules` emits **NO** generated
`78-mm-ceralive-slot-uid.rules` — there is no permissive fallback. The permanent
generic modem rules (§"USB Modem Devices" in `setup_hardware_access`) always ship
and govern access on their own until a slot map is verified.

```yaml
# manifests/boards/rock-5b-plus.yaml — shipped default
modem_ports:
  status: unverified
```

### Why unverified until hardware

The slot map pins each physical modem slot to its `ID_PATH`, and `ID_PATH` can
only be read reliably from a modem plugged into that exact board model. Guessing
it would risk emitting a rule that binds the wrong device to a UID — worse than no
rule. So the generator refuses to emit anything until a human records the real
values and flips `status` to `verified`.

### Discovery runbook (run on the board with a modem attached)

```bash
# 1. Find the modem's USB device (control port or net device):
mmcli -L                                   # lists modems once ModemManager sees one
ip link show | grep -E 'wwan|usb[0-9]|enx' # the modem's net iface, if any

# 2. Read the stable ID_PATH of the physical slot (the USB device, not ttyUSBn):
udevadm info /sys/class/net/<modem-iface> | grep -E 'ID_PATH='
#   or, for the control-port USB device:
udevadm info /dev/<cdc-wdm-or-ttyUSB> | grep -E 'ID_PATH='
```

### Flip to verified (a separate, hardware-gated change)

Once you have the real `ID_PATH` for each slot, populate `slots` and set
`status: verified`:

```yaml
modem_ports:
  status: verified
  slots:
    modem0: platform-fc000000.usb-usb-0:1:1.0   # ← the ID_PATH you read
    # modem1: …                                  # add per additional slot
```

The generator then emits one rule per slot:

```
ACTION=="add|bind", SUBSYSTEM=="usb", ENV{ID_PATH}=="<id_path>", ENV{ID_MM_PHYSDEV_UID}="modem0"
```

`ID_MM_PHYSDEV_UID` gives ModemManager a stable per-slot identity regardless of
ttyUSB enumeration order. The flip is a distinct change from this integration —
it is the "verified" half of the two-state contract and is **not** performed here.

Proof: `run-tests` — the generator matrix (unverified ⇒ zero generated rules;
verified fixture ⇒ rules emitted) in `postinst-wiring.bats`.
