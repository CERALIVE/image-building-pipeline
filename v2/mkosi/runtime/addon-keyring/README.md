# Add-on signing keyring (baked, PUBLIC)

`addon-keyring.gpg` is the **public** OpenPGP keyring baked into the device image
at `/usr/share/ceralive/addon-keyring.gpg`. It is the trust anchor for **optional
add-on payloads**: every published add-on sysext `.raw` ships a detached GPG
signature (`.raw.sig`) and a `.raw.sha256`, and the device verifies them with

```sh
sha256sum -c <feature>.raw.sha256
gpgv --keyring /usr/share/ceralive/addon-keyring.gpg <feature>.raw.sig <feature>.raw
```

before merging the extension. Add-on descriptors point at the detached signature
via `artifact.gpgSigRef` (see `manifests/schema/addon.schema.json`).

## Separate trust domain — NOT the RAUC keyring

This key is **deliberately distinct** from the RAUC root CA at
`/etc/rauc/ceralive-keyring.pem` (committed dev copy: `../rauc/ceralive-keyring.pem`).

| Domain | Anchor | Signs |
|--------|--------|-------|
| OS A/B updates | RAUC root CA (`cert-work/rauc`, immutable) | `.raucb` OS slot + cert-rotation bundles |
| Optional add-ons | this add-on keyring | per-board/per-OS feature sysext `.raw` |

Compromise of one domain must not grant the other. A `.raw` is **never** signed
with the RAUC keys, and a `.raucb` is **never** signed with this key.

## DEV vs production

The committed `addon-keyring.gpg` is the **public half of the throwaway DEV
keypair** in `v2/.dev-addon-keys/` (gitignored), exactly mirroring how
`../rauc/ceralive-keyring.pem` is the dev RAUC root. It lets local/dev images
verify locally-built add-ons out of the box.

- **Local/dev**: `lib/build-feature-sysext.sh` signs with `v2/.dev-addon-keys/`
  (auto-generated on first use). Re-export this file after regenerating that
  keypair: `gpg --homedir v2/.dev-addon-keys/gnupg --export > addon-keyring.gpg`.
- **CI/production**: the orchestrator forwards the real public keyring as base64
  in `ADDON_KEYRING_B64`; the runtime postinst writes that instead of this dev
  copy. The matching **secret** key lives offline/HSM and is injected into
  `build-feature-sysext.sh` via `--keyring` — it is never committed.

This file contains **only public key material** (no secret-key packets).
