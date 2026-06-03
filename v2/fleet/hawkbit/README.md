# CeraLive private fleet-update engine — Eclipse hawkBit

Stage 7 (task 40). A **private, self-hosted** Eclipse hawkBit + PostgreSQL stack that
drives RAUC over-the-air updates to the device fleet. It is the *engine only* — there is
**no operator dashboard here**. The operator UI is deferred to `ceralive-platform`, which
will call hawkBit's Management API (task 43 seam).

```
ceralive-platform (operator UI, later) ──Mgmt API──┐
                                                   ▼
                          ┌──────────────────────────────────┐
                          │  hawkBit  (127.0.0.1:8080, private)│
                          │  • Management API  (operators)     │
                          │  • DDI API v1      (devices)       │
                          │  • metadata only — NO artifact blob│
                          └───────┬───────────────────┬────────┘
                                  │ JDBC              │ DDI download link
                                  ▼                   ▼  = R2 URL (not local)
                            PostgreSQL          device: rauc-hawkbit-updater 1.4
                                                       └─▶ GET https://apt.ceralive.tv/bundles/...
                                                            (apt-worker → R2, task 39)
```

---

## What this is (and is NOT)

| | |
|---|---|
| **IS** | Private hawkBit engine + dedicated Postgres, env-driven auth, loopback-only bind. |
| **IS** | Configured so the artifact store is **R2** — hawkBit hands devices an R2 URL, keeps only metadata. |
| **IS** | A `provision.sh` that defines the RAUC software-module type + an example `compatible`-filtered distribution set. |
| **IS NOT** | A public service. Binding is `127.0.0.1`; you front it with a reverse proxy / VPN / Cloudflare Tunnel. |
| **IS NOT** | A bundle host. RAUC `.raucb` files live in R2 (task 28 emits them, task 39 serves them). |
| **IS NOT** | The operator dashboard. That is `ceralive-platform` (task 43). |

---

## Hosting requirements

| Resource | Minimum | Notes |
|----------|---------|-------|
| **JVM heap** | 512 MB (`-Xmx512m`, set in compose) | hawkBit is Spring Boot; 1 GB heap is comfortable for larger fleets — raise `JAVA_OPTS`. |
| **Container RAM** | ~768 MB–1.25 GB | JVM heap + non-heap + metaspace. Give the hawkBit container ≥ 1 GB. |
| **PostgreSQL** | ~1 GB RAM, persistent volume | Stores targets, distribution sets, rollouts, artifact **metadata** (not blobs → small). |
| **Disk** | A few GB for Postgres | No artifact blobs are stored locally (R2 holds them), so disk stays small. |
| **Network** | Outbound HTTPS to R2 not required by hawkBit | Devices fetch from R2 directly; hawkBit only emits the URL. |
| **Host** | Any Docker host (a small cloud VM or an on-prem box) | Runs alongside `ceralive-platform` infra later, or standalone. |

hawkBit server image is pinned to `0.4.1` (server is 0.x; the **device-facing DDI API is the
frozen `v1` contract** — see `decisions.md` task 5). `rauc-hawkbit-updater 1.4` on the device
speaks DDI v1.

---

## Startup

```bash
cd image-building-pipeline/v2/fleet/hawkbit
cp hawkbit.env.example .env
$EDITOR .env            # set DB + admin creds + R2_BUNDLE_BASE_URL (see "Auth" below)
docker-compose up -d
docker-compose ps       # postgres healthy, then hawkbit healthy (~60–90s cold start)
```

Compose **fails closed**: every required secret uses `${VAR:?...}`, so `up` aborts with a
clear error if `HAWKBIT_DB_PASSWORD`, `HAWKBIT_ADMIN_PASSWORD`, `R2_BUNDLE_BASE_URL`, etc.
are unset. There is no path to a blank/default boot.

Smoke check (loopback only):

```bash
# 401 without creds — auth is enforced
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/rest/v1/distributionsets   # 401

# 200 with provisioned creds
curl -s -u "$HAWKBIT_ADMIN_USER:<your-plaintext-pass>" \
  http://127.0.0.1:8080/rest/v1/distributionsets | jq .                                    # 200 + JSON

# default creds are dead
curl -s -o /dev/null -w '%{http_code}\n' -u admin:admin http://127.0.0.1:8080/rest/v1/targets # 401
```

> The `-u` username/password you pass to `curl` is the **plaintext** password. What you store
> in `.env` (`HAWKBIT_ADMIN_PASSWORD`) is its **`{bcrypt}` encoding**. hawkBit matches them.

---

## Auth setup — NO `admin:admin`

hawkBit's stock demo ships `admin:admin`. This stack **removes that entirely** and drives the
built-in user store from env:

- `HAWKBIT_ADMIN_USER` → `hawkbit.server.im.users[0].username` (pick a non-`admin` name).
- `HAWKBIT_ADMIN_PASSWORD` → `hawkbit.server.im.users[0].password`, a **Spring-encoded** secret.
- `HAWKBIT_SERVER_UI_DEMO_MODE=false` and the DOS filter is on.

Generate the encoded admin password (bcrypt — never store plaintext at rest):

```bash
# requires apache2-utils (Debian/Ubuntu) or httpd-tools (RHEL)
htpasswd -bnBC 10 "" 'your-real-password' | tr -d ':\n' | sed 's/^/{bcrypt}/'
# → {bcrypt}$2a$10$....   paste into HAWKBIT_ADMIN_PASSWORD in .env
```

Accepted prefixes: `{bcrypt}$2a$...` (preferred) or `{noop}plain` (throwaway local only).

**Device (DDI) auth** is separate from operator auth and uses hawkBit's target-token /
gateway-token model (enabled in compose; consumed by `rauc-hawkbit-updater`, task 41).
Anonymous DDI download is **disabled** — every device call is authenticated.

**Public exposure** is out of scope for this compose file by design. Front hawkBit with a
reverse proxy (TLS + IP allowlist / mTLS), a VPN, or a Cloudflare Tunnel. Never change the
port binding to `0.0.0.0`.

---

## External artifacts — R2, not hawkBit's local store

hawkBit can store artifact binaries itself, but CeraLive does **not** use that. Bundles are
large (500 MB–2 GB) and already live in R2 (`apt-worker` `/bundles/{channel}/{board}/…`,
task 39). hawkBit keeps only **metadata** (filename, sha1/sha256, size); the download link it
sends to a device over DDI is rewritten to an R2 URL by the **artifact URL handler**:

```
HAWKBIT_ARTIFACT_URL_PROTOCOLS_DOWNLOAD_HTTP_REF = ${R2_BUNDLE_BASE_URL}/{artifactFileName}
HAWKBIT_ARTIFACT_URL_PROTOCOLS_DOWNLOAD_ENABLED  = false   # kill hawkBit-local download protocol
HAWKBIT_ARTIFACT_URL_PROTOCOLS_MD5SUM_ENABLED    = false   # kill md5 protocol
```

- `{artifactFileName}` is the only placeholder relied on. The channel/board path is the
  `R2_BUNDLE_BASE_URL` prefix (e.g. `https://apt.ceralive.tv/bundles/stable/rock-5b-plus`).
- Run **one engine per channel/board**, or encode the channel/board into the artifact
  filename if a single engine serves multiple boards.
- Result: the device's `rauc-hawkbit-updater` receives an R2 URL and pulls the `.raucb`
  straight from R2 (range-capable, immutable-cached). hawkBit never serves a byte of payload.

`provision.sh` registers the artifact **metadata** (filename + hashes) and never uploads the
blob, keeping hawkBit's local store empty.

---

## Distribution sets — mapping RAUC bundles + `compatible` targeting

The mapping from a RAUC bundle to a hawkBit deployment:

| RAUC concept | hawkBit concept |
|--------------|-----------------|
| A signed `.raucb` bundle | one **artifact** (metadata only) inside … |
| The OS rootfs update unit | … one **software module** (type `os`) inside … |
| The thing you assign/roll out | … one **distribution set** (`type=os`) |
| `compatible=ceralive-<family>` in `system.conf` / `manifest.raucm` | the **target filter** of a rollout: targets whose `compatible` attribute matches |

A device reports its `compatible` (e.g. `ceralive-rk3588`) as a target attribute when
`rauc-hawkbit-updater` registers. A rollout uses a **target filter query** like
`attribute.compatible==ceralive-rk3588` so a bundle is only ever offered to matching boards —
mirroring RAUC's own foreign-bundle guard (`rauc install` rejects a mismatched `compatible`).
Defense in depth: hawkBit won't *offer* the wrong bundle, and RAUC won't *install* it either.

Run the one-time setup:

```bash
set -a; source .env; set +a
./provision.sh
```

It (idempotently):
1. creates the **RAUC software-module type** (`rauc` / key `rauc`),
2. creates a **distribution set type** (`os-rauc`) using that SM type,
3. creates a **software module** + registers the bundle **artifact metadata** (R2 filename + hashes),
4. creates a **distribution set** pointing at that module,
5. creates a **`compatible`-aware target filter** (`attribute.compatible==$RAUC_COMPATIBLE`)
   you can attach to a rollout.

Equivalent raw `curl` calls (for reference / ceralive-platform later) are documented inside
`provision.sh`.

### Driving a rollout (operator / ceralive-platform, later)

Creating the actual rollout is an **operator action** (task 43 seam). Example Management-API
call once a distribution set `DS_ID` and the target filter exist:

```bash
curl -u "$HAWKBIT_ADMIN_USER:<pass>" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:8080/rest/v1/rollouts -d '{
    "name": "rk3588-stable-2026.06.03",
    "distributionSetId": '"$DS_ID"',
    "targetFilterQuery": "attribute.compatible=='"$RAUC_COMPATIBLE"'",
    "amountGroups": 3
  }'
```

---

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | hawkBit + Postgres; loopback bind; env-driven auth; R2 artifact URL handler. |
| `hawkbit.env.example` | Documented env template (placeholders, **no real secrets**). Copy to `.env`. |
| `provision.sh` | One-time REST setup: RAUC SM type, distribution set, `compatible` target filter. |
| `README.md` | This file. |

## Related tasks

- **Task 28** — emits signed `.raucb` bundles (`compatible`, version) into the R2 layout.
- **Task 39** — `apt-worker` serves `/bundles/...` from R2 (content-type, HTTP range).
- **Task 41** — device-side `rauc-hawkbit-updater` polls this engine's DDI API.
- **Task 43** — `ceralive-platform` operator UI calls the Management API (the deferred seam).
