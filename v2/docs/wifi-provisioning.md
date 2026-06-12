# First-boot WiFi provisioning portal

How a headless, never-configured CeraLive device is handed WiFi credentials with no
screen or keyboard. This is the end-to-end reference for Task 17 (and for anyone
debugging the portal on hardware).

- **Trigger + AP bring-up** — Task 11 (`ceralive-provision.sh` part 1)
- **Captive page + credential handoff + teardown** — Task 14 (`ceralive-provision.sh`
  part 2 + `ceralive-portal.sh`)
- Subsystem summary: [`../../AGENTS.md`](../../AGENTS.md) → *First-boot WiFi provisioning portal*

## Artifacts

| File (committed under `v2/mkosi/runtime/`) | Installed to | Role |
|--------------------------------------------|--------------|------|
| `ceralive-provision.sh` | `/usr/local/sbin/ceralive-provision` | Trigger, AP bring-up, portal lifecycle, `connect` handoff worker, teardown |
| `ceralive-provision.service` | `/etc/systemd/system/` | Runs `ceralive-provision start` once at boot |
| `ceralive-portal.sh` | `/usr/local/sbin/ceralive-portal` | inetd-style bash HTTP handler (the captive page) |
| `ceralive-portal.socket` | `/etc/systemd/system/` | Socket-activated listener on `192.168.42.1:80` (`Accept=yes`) |
| `ceralive-portal@.service` | `/etc/systemd/system/` | Per-connection handler instance |

All five are installed by `customize/postinst-lib.sh::setup_provisioning` (single
source of truth — no inline twin in `mkosi.postinst.chroot`). Only
`ceralive-provision.service` is enabled at boot; the portal socket + template are
started/stopped imperatively by `ceralive-provision`.

## State on `/data` (survives reboots and A/B OTA slot swaps)

All under `/data/ceralive/provision/`:

| File | Meaning |
|------|---------|
| `force-portal` | Factory-reset re-trigger flag — start the portal even when profiles exist |
| `portal-active` | Written while the AP is up; `key=value` (`ssid`, `gateway`, `iface`, `con`, `user_con`) |
| `teardown-requested` | Out-of-band teardown request honored at next service start |
| `scan.txt` | Cached visible SSIDs (one per line), scanned **before** the AP came up |
| `last-error` | After a failed join: `ssid=<name>` + `reason=auth_or_timeout` — shown by the portal |

The WiFi credentials themselves are **never** written here — they go only into
NetworkManager's own `system-connections` store (`/etc/NetworkManager/system-connections`,
bind-mounted from `/data/nm/system-connections`, mode `0700`).

## Trigger (does the portal start this boot?)

Evaluated at runtime by `ceralive-provision start` (the unit cannot express it as a
static `Condition`):

1. `force-portal` flag present → **start** (factory-reset hook).
2. Else if there is **any** stored non-AP NM WiFi profile on `/data` → **do not start**
   (the device can rejoin an uplink). This is the **EC4 OTA-safe** property: a RAUC
   update that preserves `/data` keeps the profiles, so the portal stays down.
3. Else wait a **60–90 s grace window** (default 75 s): if NM reports connectivity
   (`full`/`limited`/`portal`) or a default route appears, an uplink exists → **do not
   start**. Otherwise → **start**.

The device's own `ceralive-ap` profile is excluded from the stored-profile count.

## Bring-up (`bring_up_ap`)

1. **Scan + cache** visible SSIDs to `scan.txt`. A single radio cannot scan while in AP
   mode, so this must happen *before* the AP is up.
2. **DNS capture**: write `address=/#/192.168.42.1` to
   `/etc/NetworkManager/dnsmasq-shared.d/ceralive-portal.conf`. NM's shared-mode dnsmasq
   reads it at activation, so every hostname resolves to the gateway → the operator's OS
   pops its captive-portal sign-in.
3. **AP up**: NM-native AP (`802-11-wireless.mode ap` + `ipv4.method shared`), SSID
   `CeraLive-Setup-<short-id>`, passphrase `ceralive-setup`, gateway `192.168.42.1/24`.
4. **Port-80 handoff**: `systemctl stop ceralive.service` (frees `0.0.0.0:80`) →
   `systemctl start ceralive-portal.socket` (binds `192.168.42.1:80`).

## The captive page (`ceralive-portal.sh`)

Served by systemd socket activation: `ceralive-portal.socket` (`Accept=yes`) accepts
each TCP connection and hands the socket to a fresh `ceralive-portal@<peer>.service`
instance as **stdin + stdout** (the classic inetd model). The bash handler reads one
HTTP request from stdin and writes the response to stdout.

**Why bash + socket activation:** the image ships no `busybox httpd` / `python3` /
`socat` / `nc` (socat and netcat were moved to the debug add-on — see
`v2/manifests/packages/removed.md`). systemd + bash is the lightest HTTP server already
present — zero extra packages. The page is standalone plain HTML/CSS with no JS
framework and no build step (SC2).

- **`GET` (any path)** → the provisioning form. The SSID field is an `<input list>` +
  `<datalist>` populated from `scan.txt`, so the operator can pick a scanned network or
  type a hidden/new one. If `last-error` exists, an error banner is shown.
- **`POST /`** → validate `ssid` (1–32 chars) and `psk` (empty for open, else 8–63 for
  WPA2); write the profile; answer with a "connecting…" page; trigger the handoff.

## Credential handoff (the captive-portal handoff problem)

Joining the target network means switching `wlan0` from AP to client mode, which drops
the operator's connection to the portal. So the join must be **detached** from the HTTP
request:

1. The `POST` handler writes the user's profile: `nmcli connection add … con-name
   ceralive-wifi … wifi-sec.psk <psk>` (credentials → NM storage only). The PSK is passed
   as quoted argv, never via a shell string or a file.
2. It answers the browser, then fires a detached worker in its own transient unit:
   `systemd-run --no-block --collect --unit=ceralive-provision-connect
   --property=RuntimeMaxSec=120 ceralive-provision connect ceralive-wifi`. The transient
   unit outlives the per-connection portal service (which dies when the AP is torn down).
3. The worker (`ceralive-provision connect <con>`):
   - sleeps briefly so the HTTP response flushes,
   - stops the portal socket and brings the AP connection down (freeing the radio — it
     does **not** `device disconnect`, which would block the client activation),
   - joins with a bounded `timeout <hard> nmcli --wait <soft> connection up <con>` and
     verifies connectivity,
   - **success** → run the four-condition teardown keeping the new client link,
   - **failure / timeout** → delete the bad profile, write `last-error`, and re-arm the
     AP (`bring_up_ap`) so the operator reconnects and retries.

## Teardown — MAC6 end-state (all four)

| # | Condition | How |
|---|-----------|-----|
| a | AP mode disabled | `nmcli connection down` + `delete ceralive-ap` |
| b | Device joined target | `nmcli connection up <con>` activated + connectivity verified |
| c | Portal no longer reachable | `systemctl stop ceralive-portal.socket` → port 80 freed |
| d | CeraUI reachable on new IP | `systemctl start ceralive.service` → re-binds port 80 |

Two teardown entry points:

- **`connect` success** → `teardown_ap` with **keep-link** (does *not* `device disconnect
  wlan0`; it is carrying the freshly-joined client connection).
- **`ceralive-provision teardown`** (verb) or a `teardown-requested` flag → `teardown_ap`
  also releases `wlan0` (no client connection in this path) and clears the
  portal-active + force flags.

`systemctl stop ceralive-provision` runs `ExecStop=ceralive-provision stop` — a
link-down + portal-down clean stop that **retains** the AP profile and the factory-reset
flags so the next boot re-evaluates the trigger and a pending factory reset is not
silently disarmed. It restores CeraUI to port 80.

## Port-80 / 443 coexistence

Three actors want HTTP ports in production:

- **CeraUI backend** (`ceralive.service`) binds `[80, 8080, 81]`, trying 80 first.
- **nginx TLS front** (Task 15) binds **443** and reverse-proxies to the backend on
  `127.0.0.1:80`.
- **The captive portal** needs `192.168.42.1:80` for captive UX.

`0.0.0.0:80` (the backend) conflicts with `192.168.42.1:80` (the portal), so provisioning
stops the backend for the AP window and restarts it on teardown — `Restart=always` does
**not** re-fire on an explicit `systemctl stop`, so the backend stays down until teardown.
nginx on 443 is unaffected; while there is no uplink there is no 443 client, and its
`127.0.0.1:80` upstream simply returns 502 until the backend restarts. After teardown the
backend re-binds 80, nginx's upstream recovers, and the device is reachable at
`https://ceralive.local` on the new network.

## Hardware caveat (`[PARTIAL]`)

NM-native AP mode also requires the onboard wlan driver to support it (RK3588 chip
dependent). The portal, credential handoff, and four-condition teardown are implemented
and verified offline, but **on-hardware AP-mode validation is still pending** — hence the
subsystem is `[PARTIAL]` in `AGENTS.md`.

## Verification

`v2/tests/provision-portal.test.sh` is a pure-offline proof harness (no radio, no
systemd): it stubs `nmcli` / `ip` / `systemctl` / `systemd-run` / `timeout` and drives the
real scripts through bring-up, the `GET`/`POST` page, the credential handoff, all four
MAC6 conditions, the wrong-passphrase retry, the hard-timeout return-to-AP, and the
out-of-band teardown verb. It is gated in `v2/tests/manifest.bats`
(*"provision portal: offline harness proves the 4-condition teardown + handoff"*).

On hardware, after submitting credentials, confirm: the `CeraLive-Setup-*` hotspot
disappears, `journalctl -t ceralive-provision -t ceralive-portal` shows the join +
teardown, and CeraUI answers on the device's new IP (`ceralive.local`).
