# CeraLive cert-rotation (device side)

Baked-in, non-retrofittable field rotation of the **intermediate + leaf** RAUC
signing certs. Ships in the FIRST image so every device can accept a rotation from
first flash. The **root CA is immutable** — it can only change by reflashing.

Full operator policy (fleet monitoring, recovery, root rollover):
[`../../../docs/cert-rotation-policy.md`](../../../docs/cert-rotation-policy.md).
PKI design is owned by the externally managed release-PKI runbook (`rauc/README.txt`).

---

## Files (canonical track)

| File | Installed to | Role |
|------|--------------|------|
| `cert-rotation.sh` | `/usr/local/bin/cert-rotation.sh` | verify + activate staged certs; pre-expiry check |
| `cert-rotation.conf` | `/etc/ceralive/cert-rotation.conf` | cert paths + `EXPIRY_WARN_DAYS` |
| `cert-rotation.service` | `/etc/systemd/system/` | oneshot, triggered POST-RAUC-install (install mode) |
| `cert-rotation-expiry.service` | `/etc/systemd/system/` | oneshot, `check-expiry` mode |
| `cert-rotation-expiry.timer` | `/etc/systemd/system/` | weekly pre-expiry monitor → journald |

Installed on the canonical track by `customize/services.sh`; an inline twin lives
in `mkosi.images/runtime/mkosi.postinst.chroot` (`setup_cert_rotation`). **Keep the
two in sync** (same dual-track rule as `ceralive-healthcheck`).

---

## The trust model (one sentence)

The device verifies everything against the **immutable root CA** in its RAUC
keyring (`/etc/rauc/ceralive-keyring.pem`); a rotation only ever delivers a NEW
**intermediate + leaf** that still chain to that unchanged root.

```
root CA (IMMUTABLE, in keyring)         ← reflash-only; never rotates through channel
   └── intermediate (<=5y, ROTATABLE)   ← delivered by a cert-rotation .raucb
          └── leaf   (<=2y, ROTATABLE)   ← delivered by a cert-rotation .raucb
```

## How a rotation reaches the device

1. Release host builds a signed bundle with
   `lib/build-cert-rotation-bundle.sh <board> new-intermediate.pem new-leaf.pem new-leaf.key`.
   It is signed with the **current** leaf (never the root) and is gated: the new
   chain must verify to the **same** immutable root or the build is refused.
2. The bundle is uploaded to R2 and rolled out via hawkBit exactly like an OS
   bundle (`compatible`-filtered).
3. On the device, **RAUC verifies the bundle's CMS signature to the keyring root**,
   then the bundle's `install` hook extracts the new certs into
   `/data/ceralive/certs/incoming/` and starts `cert-rotation.service`.
4. `cert-rotation.sh install` **re-verifies** `leaf -> intermediate -> root`
   (`openssl verify` against the immutable keyring root) and refuses anything that
   does not chain or is expired. Only then does it **atomically activate** them at
   `/data/ceralive/certs/{intermediate.pem,leaf.pem}` (previous kept as `*.prev`).

Everything is on `/data` (PARTLABEL=data) so it **survives A/B OS updates** — the
rootfs slots are wiped on every OS install; `/data` is not (partition-contract §6).

## Pre-expiry monitoring

`cert-rotation-expiry.timer` runs `cert-rotation.sh check-expiry` weekly and logs a
journald **WARNING** when an activated cert expires in `< EXPIRY_WARN_DAYS` (90 by
default). Inspect on device:

```bash
journalctl -u cert-rotation-expiry.service
/usr/local/bin/cert-rotation.sh status
```

Fleet-wide collection of that signal is documented in
[`cert-rotation-policy.md`](../../../docs/cert-rotation-policy.md).

## Recovery

- **Bad / rejected rotation:** `cert-rotation.sh` refuses to activate a chain that
  fails verification, so the **previous certs stay in service**. Re-push a correct
  bundle. The previous activated pair is also kept as `intermediate.pem.prev` /
  `leaf.pem.prev`.
- **Root CA expired or compromised:** there is **no through-channel fix** — every
  device must be **physically reflashed** with a new image carrying the new
  `root-ca.pem`. This is by design (no remote escape hatch). See the policy doc.
