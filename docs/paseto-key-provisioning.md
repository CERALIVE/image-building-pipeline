# PASETO device-token key provisioning runbook

**Scope:** how to generate and provision the Ed25519 keypair that signs and verifies
CeraLive **device-control** PASETO v4.public tokens (ADR-0006 D2). One keypair per
environment (prod / staging) yields **three distinct provisioning values** that land
in three different places. This runbook is the operator procedure; the build-side
contract it feeds is `customize/postinst-lib.sh::setup_paseto_public_key` (this repo)
and the platform signer `apps/api/lib/paseto.ts` (`ceralive-platform`).

> **One key, three encodings.** All three values below are the **same** Ed25519
> public/secret material in different wrappings. They are NOT copy-paste
> interchangeable — each consumer parses exactly one form.

| # | Value | Encoding | Consumer | Env var |
|---|-------|----------|----------|---------|
| (a) | **signing secret** | PASERK `k4.secret.<b64url>` | platform signer (`paseto-ts`) | `PASETO_SIGNING_KEY` |
| (b) | **public (platform)** | PASERK `k4.public.<b64url>` | platform verifier (`paseto-ts`) | `PASETO_PUBLIC_KEY` |
| (c) | **public (device build input)** | `base64(` raw-base64 32-byte `)` | this pipeline → device | `PASETO_PUBLIC_KEY_B64` |

(b) and (c) carry the **same** public key. (c) is the device-runtime
`PASETO_PUBLIC_KEY` (raw-base64 32-byte, parsed by CeraUI's `importEd25519PublicKey()`)
wrapped in one more `base64` layer so it survives env transport
(`orchestrate.sh` → mkosi `--environment` → `setup_paseto_public_key`, which
`base64 -d`s it once back to the raw-base64 form). The platform (b) and the device
(c) hold the same public key in PASERK vs raw-base64 — interop is at the PASETO wire
level, never at the string level.

---

## Key model (where each value lives)

```
                       cert-work/paseto/gen-keys.sh  (run once per environment)
                                     │
        ┌────────────────────────────┼────────────────────────────┐
        │ paseto.k4.secret           │ paseto.k4.public            │ paseto.public.raw.b64
        ▼ (a) PRIVATE                 ▼ (b) public                  ▼ (c) public, raw-base64
  PLATFORM secret store        PLATFORM secret store          IMAGE BUILD input
  PASETO_SIGNING_KEY           PASETO_PUBLIC_KEY               PASETO_PUBLIC_KEY_B64
  (signs device tokens)        (verifies its own tokens)      = base64(paseto.public.raw.b64)
        │                            │                              │ orchestrate.sh forwards
        └── both-or-neither ─────────┘                              ▼ setup_paseto_public_key
            (apps/api/lib/paseto.ts                       /etc/systemd/system/ceralive.service.d/
             loadPasetoKeysFromEnv)                         20-paseto-public-key.conf
                                                            Environment=PASETO_PUBLIC_KEY=<raw-base64>
                                                            (CeraUI verifies device-control tokens;
                                                             its PRESENCE gates real Ed25519 verify)
```

The platform **signs** with (a) and **verifies** with (b); the device only ever
**verifies**, with (c). Baking a private key onto the device would let a compromised
device FORGE tokens — so `setup_paseto_public_key` **fails the build** if (c) ever
carries a `k4.secret` or PEM `PRIVATE KEY`.

---

## Prerequisites

- `openssl` (Ed25519 support — any modern build).
- A checkout of `cert-work/` (has **no git remote** by design; the keygen subdir
  `cert-work/paseto/` ships a `.gitignore` that blocks every key shape from being
  staged). Key material is **never** committed anywhere.
- Access to the platform secret manager (Vault / Fly secrets / systemd env) for (a)+(b).
- The CI/build secret store that injects `PASETO_PUBLIC_KEY_B64` for (c).

---

## Step 1 — generate the keypair (once per environment)

From the `cert-work/paseto/` checkout:

```bash
./gen-keys.sh --out keys/prod    --kid prod-2026-06    --self-test
./gen-keys.sh --out keys/staging --kid staging-2026-06 --self-test
```

`--self-test` runs an Ed25519 sign/verify round-trip on the fresh keypair. `keys/` is
gitignored. Each run writes (mode `0600` for the secret, `0644` for the public files):

```
keys/<env>/paseto.k4.secret        (a)  PRIVATE — value NEVER printed by the tool
keys/<env>/paseto.k4.public        (b)  k4.public.<b64url>
keys/<env>/paseto.public.raw.b64   (c-source) raw-base64 32-byte Ed25519 public
keys/<env>/paseto.kid              key id label (e.g. prod-2026-06)
```

The provisioning summary the tool prints shows only the PUBLIC values — the
`k4.secret` is never echoed.

---

## Step 2 — provision the PLATFORM secret store with (a) + (b)

Set **both** keys, or neither — `loadPasetoKeysFromEnv` (`apps/api/lib/paseto.ts`)
throws on a half-configured signer:

```bash
# Load the PRIVATE key WITHOUT echoing it:
export PASETO_SIGNING_KEY="$(cat keys/prod/paseto.k4.secret)"     # (a) k4.secret.…
export PASETO_PUBLIC_KEY="$(cat keys/prod/paseto.k4.public)"      # (b) k4.public.…
```

In production these go into the platform's secret manager (never a committed file,
never a log line). The platform's fail-closed secrets loader (`apps/api/lib/secrets.ts`)
validates the PASERK prefixes at startup.

---

## Step 3 — provision the IMAGE BUILD with (c)

The build consumes the device public key as the base64-wrapped env
`PASETO_PUBLIC_KEY_B64` (GNU `base64 -w0`, as `orchestrate.sh` forwards it):

```bash
RAW_B64="$(tr -d '\r\n' < keys/prod/paseto.public.raw.b64)"
export PASETO_PUBLIC_KEY_B64="$(printf '%s' "$RAW_B64" | base64 -w0)"
./v2/build rock-5b-plus            # CI injects PASETO_PUBLIC_KEY_B64 from its secret store
```

`orchestrate.sh` forwards `PASETO_PUBLIC_KEY_B64` into mkosi (`env_names` +
`PassEnvironment`); the runtime `mkosi.postinst.chroot` calls
`setup_paseto_public_key`, which:

1. `base64 -d`s `PASETO_PUBLIC_KEY_B64` back to the raw-base64 device key,
2. REFUSES it if it carries `k4.secret` or `PRIVATE KEY` (public-only gate),
3. writes the additive drop-in
   `/etc/systemd/system/ceralive.service.d/20-paseto-public-key.conf` with
   `Environment=PASETO_PUBLIC_KEY=<raw-base64>`.

With **no** `PASETO_PUBLIC_KEY_B64` in the env the step is a graceful no-op — CeraUI
runs its MVP opaque-token path, so a key-less dev build still boots. There is **no
committed default**; CI injects it.

---

## Step 4 — verify the encodings agree and the build bakes clean

Run the verifier before trusting a provisioned keypair. It reads only the two PUBLIC
files (never the `k4.secret`) and proves (b) and (c) decode to the same 32-byte key,
then exercises the **shipped** `setup_paseto_public_key` to prove the build input
round-trips to the device key with zero drift and that a `k4.secret` is refused:

```bash
# Verify a real gen-keys.sh output dir (PUBLIC files only):
v2/lib/verify-paseto-key-encodings.sh --key-dir <path-to>/keys/prod

# CI / no-secrets self-check (ephemeral keypair, the v2/run-tests section-21 gate):
v2/lib/verify-paseto-key-encodings.sh --self-test
```

The verifier prints only sha256 fingerprints + PASS/FAIL — never key bytes. A
mismatched or private-bearing pair exits non-zero (fail loud). The same `--self-test`
runs as a bats case in `v2/tests/manifest.bats` (section 21), so the contract stays
green in CI without any secret.

---

## Provisioning record (redacted — public fingerprints only)

Record each environment's rollout here. **Never** write the `k4.secret` or any secret
bytes into this table — the public-key sha256 fingerprint (from the verifier output)
is the audit anchor.

| Env | kid | public-key sha256 (from verifier) | (a)+(b) in platform secret store | (c) baked in image build |
|-----|-----|-----------------------------------|----------------------------------|--------------------------|
| prod | `prod-2026-06` | `<sha256>` | ☐ set (both-or-neither) | ☐ `PASETO_PUBLIC_KEY_B64` injected |
| staging | `staging-2026-06` | `<sha256>` | ☐ set (both-or-neither) | ☐ `PASETO_PUBLIC_KEY_B64` injected |

---

## Rotation

Rotation is a fresh `gen-keys.sh` run + re-provision of all three values, plus the
platform's staged-key grace window:

1. `gen-keys.sh --out keys/<env>-<new-kid> --kid <new-kid> --self-test`.
2. Stage the new public key on the platform as `PASETO_NEXT_PUBLIC_KEY` and the new
   secret as `PASETO_NEXT_SIGNING_KEY` (both-or-neither) — `verifyControlToken`
   accepts CURRENT **and** NEXT during the grace window (`apps/api/lib/key-rotation.ts`).
3. Build + roll out a device image with the new (c) so devices verify the new key.
4. Promote NEXT → CURRENT (sign with the new key), then drop the old key.

Devices that have not taken the new image still verify the OLD key during the grace
window; complete rotation only after the fleet has the new (c).

---

## Invariants (do / don't)

- **DO** keep (a)+(b) both-or-neither on the platform — a half-set signer refuses to start.
- **DO** treat (b) and (c) as the same public key in two encodings — verify with
  `verify-paseto-key-encodings.sh` before trusting a keypair.
- **DON'T** ever put a `k4.secret` (or PEM `PRIVATE KEY`) into `PASETO_PUBLIC_KEY_B64`
  — the build FAILS by design (device verifies only; a baked private key = forgeable tokens).
- **DON'T** commit, log, or paste any `k4.secret`. `cert-work/paseto/.gitignore` blocks
  every key shape; the secret store is the only home for (a).
- **DON'T** hand the device the PASERK `k4.public` string — CeraUI parses raw-base64
  (c), not PASERK.
