# CeraLive First-Boot Guide

Getting from a freshly-flashed card to a live stream. Every step here is
verifiable against the merged runtime scripts under `v2/mkosi/runtime/`.

---

## Table of Contents

1. [Flash the image](#1-flash-the-image)
2. [Power on and wait](#2-power-on-and-wait)
3. [WiFi provisioning portal](#3-wifi-provisioning-portal)
4. [Finding the device on your network](#4-finding-the-device-on-your-network)
5. [First SSH login](#5-first-ssh-login)
6. [Accessing CeraUI](#6-accessing-ceraui)
7. [First stream](#7-first-stream)

---

## 1. Flash the image

Build the image first (see [`docs/DEVICE-BRINGUP.md`](DEVICE-BRINGUP.md) §2),
then write it to a microSD card or eMMC.

**microSD (dd):**

```bash
BOARD_DIR="v2/images/rock-5b-plus"
IMAGE="${BOARD_DIR}/$(ls -t "${BOARD_DIR}"/*.raw | head -1 | xargs basename)"

sudo dd if="${IMAGE}" of=/dev/sdX bs=4M status=progress conv=fsync
sudo sync
```

Replace `/dev/sdX` with your card's device node. Double-check with `lsblk`
before running — dd to the wrong device is destructive.

**eMMC (rkdeveloptool):** see [`docs/DEVICE-BRINGUP.md`](DEVICE-BRINGUP.md) §4
for the maskrom-mode procedure.

Insert the card and apply power. Do not hold the maskrom button during a normal
boot.

---

## 2. Power on and wait

The board boots U-Boot from the `boot` partition, selects slot A, and starts
the Debian kernel. Several one-shot first-boot services run before the device
is reachable:

| Service | What it does | Source |
|---------|-------------|--------|
| `ceralive-hostname.service` | Generates a unique hostname from the machine-id (`ceralive-<short-id>`) | `v2/mkosi/runtime/ceralive-set-hostname.sh` |
| `ceralive-ssh-firstboot.service` | Regenerates per-device SSH host keys, disables root password login, arms forced password change | `v2/mkosi/runtime/ceralive-ssh-firstboot.sh` |
| `ceralive-tls-firstboot.service` | Mints a per-device self-signed TLS cert into `/data/ceralive/tls/` | `v2/mkosi/runtime/ceralive-tls-firstboot.sh` |
| `ceralive-provision.service` | Evaluates whether to start the WiFi provisioning portal | `v2/mkosi/runtime/ceralive-provision.sh` |
| `ceralive.service` | Starts the CeraUI backend (binds port 80) | CeraUI `.deb` |
| `nginx.service` | Starts the TLS front (binds port 443) | `v2/mkosi/runtime/ceralive-tls.nginx.conf` |

**Timing:** the provisioning service waits up to 75 seconds for any network
connectivity before deciding whether to start the WiFi portal
(`ceralive-provision.sh` line 146: `GRACE_SECONDS=75`). On a device with no
stored WiFi profile and no wired uplink, expect roughly 75-90 seconds before
the setup hotspot appears.

---

## 3. WiFi provisioning portal

This section applies to a device with **no stored WiFi credentials and no
wired/modem uplink**. If the device already has a wired connection or a stored
WiFi profile (e.g. after an OTA update), the portal does not start — skip to
[§4](#4-finding-the-device-on-your-network).

### 3.1 Connect to the setup hotspot

The device broadcasts a WPA2 hotspot:

| Parameter | Value |
|-----------|-------|
| SSID | `CeraLive-Setup-<short-id>` (last 4 hex digits of the machine-id) |
| Passphrase | `ceralive-setup` |
| Gateway / portal address | `192.168.42.1` |

Source: `ceralive-provision.sh` lines 138, 155-160 (`AP_PASSPHRASE`,
`ap_ssid()`).

Connect your phone or laptop to this network. Most operating systems detect the
captive portal automatically and open a sign-in page. If yours does not, open a
browser and navigate to `http://192.168.42.1/`.

### 3.2 Submit your WiFi credentials

The portal page shows a network picker pre-populated with SSIDs the device
scanned before switching to AP mode (a single radio cannot scan while in AP
mode, so the list was cached beforehand). You can also type a network name
manually.

Fill in the network name and password, then tap **Connect**.

- SSID: 1-32 characters (required)
- Password: leave empty for an open network, or 8-63 characters for WPA2

Source: `ceralive-portal.sh` lines 242-249 (validation), lines 217-224
(profile write via `nmcli`).

### 3.3 What happens next

After you submit, the portal page says "Connecting…". The device then:

1. Answers your browser with the connecting page.
2. Drops the setup hotspot (the `CeraLive-Setup-*` network disappears from
   your WiFi list).
3. Switches `wlan0` to client mode and joins your network.
4. Restarts CeraUI so it re-binds port 80 on the new IP.

Source: `ceralive-provision.sh` `connect_target()` and `teardown_ap()`.

**If the hotspot reappears**, the password was wrong or the join timed out. The
device deletes the bad profile, shows an error banner on the portal page, and
re-arms the hotspot so you can retry. Reconnect to `CeraLive-Setup-*` and try
again.

Source: `ceralive-provision.sh` lines 379-385 (failure path).

### 3.4 OTA updates preserve your credentials

WiFi credentials are stored in NetworkManager's `/data`-backed profile store.
A RAUC A/B update preserves `/data`, so the portal does not start after an
update — the device rejoins your network automatically.

Source: `ceralive-provision.sh` lines 196-200 (`stored_wifi_profile_count`,
EC4 comment).

---

## 4. Finding the device on your network

The device registers itself as `ceralive-<short-id>.local` via mDNS (Avahi).
The short-id is the same four hex digits used in the setup hotspot SSID.

```bash
# Resolve the mDNS name (from any machine on the same LAN)
avahi-resolve-host-name ceralive-<short-id>.local

# Or ping it
ping ceralive-<short-id>.local
```

If mDNS is not working on your network (some enterprise or cellular networks
block multicast), find the device's IP from your router's DHCP lease table, or
check the device's HDMI/serial console output.

The boot healthcheck logs a warning with IP-fallback guidance if mDNS
self-resolution fails — it does not mark the boot unhealthy or trigger a RAUC
rollback.

Source: `ceralive-healthcheck.sh` `check_mdns_resolution()`.

---

## 5. First SSH login

### 5.1 Default user

The provisioned user is `ceralive`. It is a member of `sudo` and the streaming
hardware groups.

**There is no default password.** The account ships password-locked (`passwd
-l`). Root is also password-locked.

Source: `v2/mkosi/customize/users.sh` (password-lock); `v2/docs/ssh-hardening.md`.

### 5.2 Connecting

```bash
ssh ceralive@ceralive-<short-id>.local
```

Because the account is password-locked, password SSH login is not possible
until you set a password. The intended first-access paths are:

- **Console** (HDMI or serial getty): log in as `ceralive` and set a password
  with `passwd`.
- **Key-based SSH**: add your public key to `/home/ceralive/.ssh/authorized_keys`
  via the console, then SSH in normally.
- **Root key-based SSH**: root retains key-based access for recovery
  (`PermitRootLogin prohibit-password`).

Source: `ceralive-ssh-firstboot.sh` lines 56-64 (hardening drop-in).

### 5.3 Forced password change

On the very first boot, `ceralive-ssh-firstboot.service` runs `chage -d 0
ceralive` exactly once (flag-guarded at `/data/ceralive/ssh/ssh-firstboot.done`).
This marks the account's password as expired. The moment you set any password
via console or out-of-band provisioning, the system immediately prompts you to
choose a new one.

Source: `ceralive-ssh-firstboot.sh` lines 101-110.

### 5.4 SSH host key fingerprint

The image bakes shared host keys at build time. On first boot,
`ceralive-ssh-firstboot.service` regenerates unique per-device keys with
`ssh-keygen -A` and persists them under `/data/ceralive/ssh/host-keys/`. The
fingerprint is stable across reboots and A/B OTA slot swaps.

If your SSH client warns about a changed host key after an OTA update, that is
unexpected — the persisted keys should be restored onto the new slot. Check
`journalctl -u ceralive-ssh-firstboot` for details.

Source: `ceralive-ssh-firstboot.sh` `ensure_host_keys()`.

---

## 6. Accessing CeraUI

CeraUI is the on-device control plane. It is reachable on two ports:

| Port | URL | Notes |
|------|-----|-------|
| 80 | `http://ceralive-<short-id>.local/` | Direct from the CeraUI backend |
| 443 | `https://ceralive-<short-id>.local/` | nginx TLS front, reverse-proxies to port 80 |

Both ports are real, supported entry points. There is no redirect from 80 to
443.

Source: `ceralive-tls.nginx.conf` lines 21-22 (`listen 443 ssl`; no `listen
80`); `ceralive-provision.sh` header §PORT 80 HANDOFF.

### 6.1 The self-signed certificate warning

The first time you open `https://ceralive-<short-id>.local/`, your browser
shows a "self-signed / not secure" warning. This is expected.

The device mints a per-device self-signed certificate on first boot. It cannot
use a CA-signed certificate because it is a headless appliance on a private LAN
with no public DNS name and no inbound path for an ACME challenge.

To proceed: click through the browser's "Advanced" or "Proceed anyway" option.
You only need to do this once per browser per device — the cert is stable across
reboots and OTA updates.

The certificate's CN and SAN are set to `<hostname>.local` plus the device's
IPv4 at the time of generation.

Source: `ceralive-tls-firstboot.sh` lines 59-91; `ceralive-tls.nginx.conf`
lines 14-18 (honest comment about the warning).

### 6.2 WebSocket connections through the TLS proxy

CeraUI uses a same-origin WebSocket for telemetry and RPC. The nginx proxy
passes the WebSocket upgrade headers correctly, so `wss://` connections through
port 443 work without any frontend change.

Source: `ceralive-tls.nginx.conf` lines 37-39 (`proxy_http_version 1.1`,
`Upgrade`, `Connection "upgrade"`).

### 6.3 Verify the services are running

```bash
ssh ceralive@ceralive-<short-id>.local

# CeraUI backend
systemctl status ceralive.service

# nginx TLS front
systemctl status nginx.service

# TLS cert (generated on first boot)
ls -la /data/ceralive/tls/

# Boot healthcheck result
journalctl -u ceralive-healthcheck.service -n 30
```

---

## 7. First stream

Once CeraUI is reachable, open it in your browser and follow the in-app setup
to configure your stream destination, bitrate, and bonded links.

For the full CeraUI reference, see the CeraUI documentation in the `CeraUI/`
repository.

---

## Troubleshooting

### Setup hotspot does not appear

The portal only starts when there are no stored WiFi profiles on `/data` AND no
connectivity appears within 75 seconds. Check:

- Is a wired cable plugged in? The device may have found connectivity via
  Ethernet and skipped the portal.
- Did a previous provisioning attempt leave a stored profile? Check on the
  device console: `nmcli connection show`.
- To force the portal regardless: create the file
  `/data/ceralive/provision/force-portal` and reboot.

Source: `ceralive-provision.sh` `should_start_portal()`.

### Device does not appear on the network after provisioning

After the hotspot disappears, wait 10-15 seconds for the device to join your
network and for CeraUI to restart. Then try `ping ceralive-<short-id>.local`.

If it still does not appear, check the journal on the device console:

```bash
journalctl -t ceralive-provision -t ceralive-portal -n 50
```

### CeraUI is unreachable on port 80

During WiFi provisioning, `ceralive.service` is stopped so the portal can use
port 80. It restarts automatically when provisioning completes. If provisioning
failed partway through, restart it manually:

```bash
systemctl start ceralive.service
```

### nginx / HTTPS not working

Check that the TLS cert was generated:

```bash
ls /data/ceralive/tls/
# Should show ceralive.crt and ceralive.key

journalctl -u ceralive-tls-firstboot.service
journalctl -u nginx.service
```

If the cert is missing, run the firstboot service manually:

```bash
systemctl start ceralive-tls-firstboot.service
systemctl restart nginx.service
```
