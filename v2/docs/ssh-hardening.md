# First-boot SSH hardening

CeraLive images ship with a one-shot first-boot hardening service that brings SSH
to a safe baseline before sshd accepts its first connection. This page is the
source of truth for the **default-credentials and forced-password-change
behaviour** that the device-facing FIRST-BOOT guide (Task 17) presents to
operators.

## What runs, and when

| Artifact | Installed to | Role |
|----------|--------------|------|
| `ceralive-ssh-firstboot.sh` | `/usr/local/sbin/ceralive-ssh-firstboot` | the hardening script |
| `ceralive-ssh-firstboot.service` | `/etc/systemd/system/` | one-shot unit, `Before=ssh.service ssh.socket` |

Canonical sources live under `v2/mkosi/runtime/`; they are installed (not
inlined) by `postinst-lib.sh::setup_ssh_firstboot`, enabled through the
services-enablement path. The unit is ordered **before** sshd so the first
inbound connection already sees a per-device host key and root-password login
already disabled.

## The three scoped actions (SC4 — nothing more)

1. **Per-device SSH host keys.** The image bakes shared host keys, so every
   flashed unit would otherwise present an identical fingerprint (a MITM hazard).
   On the device's first boot the script regenerates the keys with `ssh-keygen -A`
   and persists them under `/data/ceralive/ssh/host-keys/` (falling back to
   `/etc/ceralive` on an image with no `/data`). Persisting on `/data` keeps the
   identity stable across reboots **and** A/B OTA slot swaps: a freshly-activated
   slot still carrying the baked shared keys has its real identity restored from
   the store.
2. **Root password login disabled.** The script writes
   `/etc/ssh/sshd_config.d/99-ceralive-hardening.conf` containing
   `PermitRootLogin prohibit-password`. Key-based root is retained for recovery;
   only password authentication for root is refused. This file is rewritten on
   every boot so a fresh OTA slot is always hardened.
3. **Forced password change for the default user.** On the first boot only
   (guarded by a flag at `<state>/ssh-firstboot.done`), the script runs
   `chage -d 0 ceralive`, so the next time a password is set/used it must be
   changed immediately.

After applying the drop-in the script runs `sshd -t` to validate the resulting
config, so a malformed drop-in can never wedge sshd's startup.

## Default credentials operators must know

- **Default user:** `ceralive` (member of `sudo` and the streaming hardware
  groups). The image ships it **password-locked** (`passwd -l`, set in
  `customize/users.sh`) — there is **no shipped default password**. `root` is
  password-locked too.
- Because the account is locked, password SSH login is impossible until a
  password is provisioned (console login on the attached HDMI/serial getty, or
  out-of-band/OTA provisioning). The `chage -d 0` above guarantees that the
  moment a password is established it is treated as expired and the operator is
  forced to choose a new one on first interactive use.
- **Lab-only debug images:** `CERALIVE_DEBUG_IMAGE=1` plus an encrypted
  `CERALIVE_DEBUG_PASSWORD_HASH` creates `/etc/ceralive/debug-image`, unlocks
  `ceralive`, and retains that injected password across the first-boot service.
  The build rejects a hash without the lab flag, and production builds never
  receive either input. Do not use this mode for fleet artifacts.
- **The device is never locked out of the network on first boot.** SSH remains
  reachable; root retains key-based access for recovery. The appliance is
  reachable at `ceralive.local` (mDNS) on any network out of the box.

## Idempotency

- Action (2) is deterministic and re-applied every boot (cheap, keeps every slot
  hardened).
- Actions (1) and (3) are once-only: the persisted host-key store and the
  `ssh-firstboot.done` flag make every subsequent boot a clean no-op.

## Out of scope (deliberately)

No `fail2ban`, no UFW, no auditd, no key-only enforcement for the `ceralive`
user. SC4 locks the scope to exactly the three actions above.
