# CeraLive cert-rotation policy

How the RAUC signing PKI is rotated across the fleet **without a reflash** — and the
one case (root) where a reflash is the only option, by design.

- PKI design & chain: [`cert-work/rauc/README.txt`](../../cert-work/rauc/README.txt)
- Locked decision: `.omo/notepads/image-platform-redesign/decisions.md` (Stage 0g)
- Device implementation: [`v2/mkosi/runtime/cert-rotation/README.md`](../v2/mkosi/runtime/cert-rotation/README.md)
- Builder: [`v2/lib/build-cert-rotation-bundle.sh`](../v2/lib/build-cert-rotation-bundle.sh)

---

## 1. The chain and what can rotate through the channel

```
ROOT CA          RSA 4096, 10y   IMMUTABLE — baked into the device RAUC keyring at
   │                             first flash. RAUC has NO through-channel root swap.
   │                             A new root = physical reflash of EVERY device.
   └── INTERMEDIATE RSA 4096, 5y ROTATABLE through the channel (same root).
          └── LEAF  RSA 2048, 2y ROTATABLE through the channel (cheapest, most often).
```

The device verifies everything against the **immutable root** in its keyring
(`/etc/rauc/ceralive-keyring.pem`). Any new intermediate/leaf that still chains to
that unchanged root is accepted; nothing else is. This is the entire security model.

| Tier | Validity | Rotation | Device change? | Mechanism |
|------|----------|----------|----------------|-----------|
| Leaf | ≤ 2y | reissue under current intermediate | none | bundles signed with new leaf are accepted as-is; a cert-rotation bundle also delivers the new leaf to `/data` for inventory/monitoring |
| Intermediate | ≤ 5y | reissue under the **same** root, issue a fresh leaf | none | a cert-rotation `.raucb` delivers the new intermediate+leaf; device re-verifies to the immutable root and activates |
| **Root** | 10y / compromise | **reflash every device** | **full reflash** | **NO through-channel path — by design** |

---

## 2. Why leaf/intermediate rotation needs no device change

RAUC verifies every bundle's CMS signature as `leaf → intermediate → root(keyring)`.
The leaf+intermediate travel **inside** each bundle (`chain.pem`); only the root is
on the device. So:

- **New leaf** under the current intermediate → bundles signed with it verify on any
  device that still has the root. Nothing to push for verification to keep working.
- **New intermediate** under the **same** root → ship a bundle whose embedded
  `chain.pem` is the new intermediate+leaf; it still terminates at the device's root.

A dedicated **cert-rotation bundle** additionally writes the new
`intermediate.pem`/`leaf.pem` to `/data/ceralive/certs/` so the device has the current
chain on disk for local tooling and for the **pre-expiry monitor** to watch.

---

## 3. Building and rolling out a rotation

On the release host (current leaf key still valid — this is **pre-expiry** rotation):

```bash
# new-intermediate.pem must chain to the SAME root-ca.pem; new-leaf signed by it.
v2/lib/build-cert-rotation-bundle.sh <board> new-intermediate.pem new-leaf.pem new-leaf.key
```

The builder **refuses** to produce a bundle whose new intermediate/leaf does not
verify to the immutable `cert-work/rauc/root-ca.pem`, or that is expired, or whose
new leaf.key does not match new leaf.pem. It signs with the **current** leaf
(`cert-work/rauc/leaf-signing.key`) + `chain.pem` — **never** the root key (the
no-root-sign guard from `build-bundle.sh` is enforced). No private key is shipped to
devices (a device only verifies; it never signs).

Output → `images/<board>/cert-bundles/<ts>.raucb` (+ `.sha256`). Upload to R2 and roll
out via hawkBit exactly like an OS bundle, `compatible`-filtered (task 40). On the
device, RAUC verifies the bundle to the keyring root, the install hook stages the new
certs, and `cert-rotation.service` re-verifies and atomically activates them.

---

## 4. Pre-expiry monitoring (device)

Each device runs `cert-rotation-expiry.timer` **weekly** (`cert-rotation.sh
check-expiry`). It logs a journald **WARNING** when an activated cert expires in
`< EXPIRY_WARN_DAYS` (default **90**, in `/etc/ceralive/cert-rotation.conf`):

```
cert-rotation: WARNING: leaf (/data/ceralive/certs/leaf.pem) expires in 73 days (< 90) — rotate before expiry
```

Because policy rotates leaf ≤2y and intermediate ≤5y, a healthy fleet rotates long
before the 90-day window ever fires; the warning is the safety net.

On device:

```bash
journalctl -u cert-rotation-expiry.service
/usr/local/bin/cert-rotation.sh status
```

---

## 5. Fleet expiry monitoring (operator)

The device emits the signal to journald; the operator aggregates it fleet-wide. Two
supported approaches:

1. **hawkBit target attribute (preferred).** The device reports its leaf/intermediate
   `notAfter` (or the integer days-to-expiry from `cert-rotation.sh status`) as a
   target attribute via the DDI `configData` channel that `rauc-hawkbit-updater`
   already speaks (task 41). The operator then queries the Management API:

   ```bash
   curl -u "$HAWKBIT_ADMIN_USER:<pass>" \
     "http://127.0.0.1:8080/rest/v1/targets?q=attribute.leaf_expiry_days=lt=90"
   ```

   A target filter like `attribute.leaf_expiry_days=lt=90` lists every device whose
   leaf is inside the warning window — the exact cohort to target with a rotation
   rollout. This mirrors the `compatible` target-filter pattern (task 40).

2. **Log shipping.** Forward journald (`cert-rotation-expiry.service`) to the central
   log stack and alert on the `WARNING:` line. No extra device dependency.

Operators should also watch the **PKI source of truth** (`cert-work/rauc/`): the
intermediate/leaf `notAfter` there is the upper bound for the whole fleet — schedule
the rotation rollout from it, not from individual device drift.

---

## 6. Recovery

| Situation | Recovery |
|-----------|----------|
| A rotation bundle is rejected on device (chain fails to verify / expired) | `cert-rotation.sh` refuses to activate it → the **current** certs stay in service. Fix the new certs and re-push. The previous activated pair is also kept as `*.prev`. |
| Wrong certs activated but they verify | Push a corrected cert-rotation bundle; activation is atomic and idempotent. |
| Leaf compromised | Issue + roll out a new leaf under the current intermediate (fastest, lowest blast radius). |
| Intermediate compromised | Bring the root key out of offline storage **once**, issue a new intermediate + leaf under the same root, roll out a cert-rotation bundle. |
| **Root expired or compromised** | **No through-channel fix.** Every fielded device must be **physically reflashed** with a new image carrying the new `root-ca.pem`. Plan root rollover well before the 10-year expiry. There is **no remote escape hatch** — this is deliberate (a remotely-swappable root would defeat the trust anchor). |

### Root rollover (reflash) checklist

1. Generate the new root (and a fresh intermediate+leaf under it) in `cert-work/rauc/`.
2. Build a new device image whose RAUC keyring is the new `root-ca.pem`
   (`setup_rauc_client` bakes `/etc/rauc/ceralive-keyring.pem`).
3. Reflash every device with the new image (eMMC/SD/NVMe — physical or factory).
4. From then on, sign bundles with the new chain; the old root is dead.

> A device that never shipped with the cert-rotation mechanism (this task) could only
> be fixed by reflashing too — which is why the mechanism is **baked into the FIRST
> image** and is non-retrofittable through the channel.
