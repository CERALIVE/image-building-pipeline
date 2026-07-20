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
| `ceralive-ci-uart-bootstrap.sh` | `/usr/local/sbin/ceralive-ci-uart-bootstrap` | data-only release-gate key bootstrap |
| `ceralive-ci-uart-bootstrap.service` | `/etc/systemd/system/` | opt-in 180-second UART oneshot |
| `ceralive-ci-uart-bootstrap-public.pem` | `/etc/ceralive/uart-bootstrap-public.pem` | public verifier for host-signed bootstrap requests |

Canonical sources live under `v2/mkosi/runtime/`; they are installed (not
inlined) by `postinst-lib.sh::setup_ssh_firstboot`, enabled through the
services-enablement path. The unit is ordered **before** sshd so the first
inbound connection already sees a per-device host key and root-password login
already disabled.

Both SSH-gate units carry **`DefaultDependencies=no`** paired with an explicit
**`After=sysinit.target`**. `ssh.socket` is ordered `Before=sockets.target`
(early boot, before `basic.target`), so a unit that is `Before=ssh.socket` must
not inherit the implicit `After=basic.target` — that closes an `ssh.socket →
guard → basic.target → sockets.target → ssh.socket` ordering cycle and systemd
deletes `ssh.socket`'s start job, so SSH never comes up on any boot. But
`DefaultDependencies=no` also drops the implicit `After=sysinit.target`, and this
script does sysinit-phase-dependent work (`ssh-keygen -A` needs the seeded RNG;
the authorized-key store resolves the `ceralive` user/group and chowns to it;
`sshd -t` needs runtime paths). proof-11 proved that without `After=sysinit.target`
the unit races ahead of `systemd-sysusers`/`systemd-tmpfiles`/udev and fails under
`set -euo pipefail` — SSH down with **zero** ordering cycles. So each guard
re-adds `After=sysinit.target` by hand (the safe half of the default deps;
`sysinit.target` is ordered before `sockets.target`, so it never re-closes the
loop) but NEVER `After=basic.target`. The offline regression guard,
`v2/tests/systemd-ordering-cycle.test.sh`, asserts BOTH zero cycles AND that each
guard is transitively ordered after `systemd-sysusers`/`systemd-tmpfiles`.

The script also **creates `/run/sshd` (mode `0755`) before its final `sshd -t`**.
`sshd -t` refuses to run without the privilege-separation directory `/run/sshd`,
exiting 255 with `Missing privilege separation directory: /run/sshd`. On a fresh
boot that directory does not exist yet — nothing in the image ships a `tmpfiles.d`
entry for it, so its only creator is `ssh.service`'s `RuntimeDirectory=sshd`, which
runs **after** this `Before=ssh.service` guard. Without pre-creating it, `sshd -t`
exits 255, `set -euo pipefail` fails the unit, and both `ssh.service` (the LAN sshd
on :22) and `ssh.socket` DEPEND-fail through their `RequiredBy=`, closing port 22 on
every boot — with **zero** ordering cycles and a healthy rest-of-system (proof-13
real-HW UART, 2026-07-16). This is a runtime failure inside the guard's script, not
a dependency-graph defect, so `systemd-ordering-cycle.test.sh` cannot see it; the
dedicated guard is `v2/tests/ssh-firstboot-privsep.test.sh`, which asserts the
`/run/sshd` creation precedes `sshd -t` in the script (static) and reproduces the
empty-`/run` first boot end-to-end in a rootless namespace (runtime).

## The four scoped actions (SC4 — nothing more)

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
4. **Persistent authorized-key paths.** The script creates empty ceralive and
   root stores at `/data/ceralive/ssh/{authorized_keys,root_authorized_keys}` with
   mode `0600`, then links each account's slot-local `authorized_keys` path to its
   store. Operator keys therefore survive an A/B slot change. The factory image
   contains no authorized key.

The release gate adds `ceralive.ci_uart=1` for one boot. That condition starts a
non-restarting UART service with a device-enforced 180-second timeout. It accepts
one strict signed data record and verifies it with the baked public key, then
requires its fresh device-generated nonce, the candidate commit from
`/etc/ceralive/image-build-commit`, and an expiry no more than one hour after the
signed host epoch. Consumed nonces and a non-decreasing epoch floor persist under
`/data/ceralive/ssh`, preventing replay and clock rollback from restoring an
expired key. Only then does it write a restricted root key plus a fresh challenge
marker recording the challenge and candidate commit. It accepts no shell command.
The signing private key stays mode `0600` on the dedicated runner, is
preflight-matched to the baked public key, and is not an SSH credential. The
provisioning helper selects that key explicitly for SSH, verifies the same
challenge and commit over the network, then removes the exact key and marker
after the gate. Before every
planned RAUC reboot, the authenticated harness arms a one-use retention marker;
first-boot hardening consumes it before sshd starts. Any later boot without that
marker removes the CI key and access marker before sshd, so interrupted cleanup
and wall-clock rollback cannot revive expired access.

After applying the drop-in the script runs `sshd -t` to validate the resulting
config, so a malformed drop-in can never wedge sshd's startup.

## Default credentials operators must know

- **`ssh.service` is DISABLED by default on production images.** The systemd
  enablement of SSH is gated on `CERALIVE_DEBUG_IMAGE`
  (`postinst-lib.sh::configure_ssh_enablement`, called from `configure_services`).
  A production build (`CERALIVE_DEBUG_IMAGE=0`, the default) ships `ssh.service`
  **not enabled** — sshd does not start at boot. The operator turns SSH on from the
  CeraUI UI (`systemctl start ssh`), which reveals its boot-generated password. The
  base OS layer installs `openssh-server`, and Debian's postinst preset would enable
  `ssh.service`, so the production branch **actively disables** `ssh.service`/
  `ssh.socket` rather than merely skipping the enable — otherwise the base-layer
  preset would leave SSH enabled. A **debug** image (`CERALIVE_DEBUG_IMAGE=1`) keeps
  the historical **enabled-by-default** behavior, alongside its predefined debug
  password (below). `ceralive-ssh-firstboot.service` still runs its one-shot
  hardening pass whenever SSH is eventually started, on both image kinds.
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
  `ceralive`, retains that injected password across the first-boot service, **and
  enables `ssh.service` by default** (per the enablement gate above). The build
  rejects a hash without the lab flag, and production builds never receive either
  input. Do not use this mode for fleet artifacts.
- **On production, SSH is off until the operator enables it.** The device is still
  reachable on the LAN — CeraUI serves the control plane over HTTP/HTTPS and the
  appliance answers at its selected mDNS hostname after it joins a shared LAN:
  `ceralive.local`, then `ceralive2.local`, `ceralive3.local`, and so on when
  collisions exist. Once the operator enables SSH from the UI, root retains
  key-based access for recovery. The isolated setup AP address is not accepted as
  proof of LAN-visible mDNS ownership. **Debug images** leave SSH reachable from
  first boot.

## Idempotency

- Action (2) is deterministic and re-applied every boot (cheap, keeps every slot
  hardened).
- Actions (1) and (3) are once-only: the persisted host-key store and the
  `ssh-firstboot.done` flag make every subsequent boot a clean no-op.
- Action (4) is idempotent and keeps the same `/data` file across both slots.

## Out of scope (deliberately)

No `fail2ban`, no UFW, no auditd, no key-only enforcement for the `ceralive`
user. SC4 locks the scope to exactly the four actions above.
