# CeraLive fleet ↔ `ceralive-platform` integration contract

> **Stage 7, task 43 — CONTRACT ONLY.** This document defines the *server-to-server* seam
> through which `ceralive-platform` will (later) drive the private hawkBit fleet engine
> (task 40) — trigger rollouts, read fleet/device status, surface an operator dashboard.
> **No `ceralive-platform` feature or UI code is built by this task.** This is the stable
> interface description + a thin bridge script (`hawkbit/platform-bridge.sh`) the platform
> can call or replicate. The operator UI is deferred; this contract is what lets it plug in
> with **zero device-side changes**.
>
> Contract version: **v1** · hawkBit Management API: **`/rest/v1`** · hawkBit server pin: **0.4.1**
> · DDI device contract: **v1 (frozen)** · Companion: [`hawkbit/README.md`](hawkbit/README.md),
> [`hawkbit/platform-bridge.sh`](hawkbit/platform-bridge.sh)

---

## 0. Reading guide / what changes where

| If `ceralive-platform` wants to … | It calls … | §  |
|-----------------------------------|------------|----|
| List the fleet | `GET /rest/v1/targets` | §3.1 |
| Inspect one device | `GET /rest/v1/targets/{id}` (+ `/attributes`) | §3.2, §7 |
| List available OS bundles | `GET /rest/v1/distributionsets` | §3.3 |
| Push an update to a board family | create rollout → start (§6) | §3.4, §6 |
| Watch an update progress | `GET /rest/v1/rollouts/{id}` + per-target action status | §5 |
| Read per-device update history | `GET /rest/v1/targets/{id}/actions` | §3.5, §5 |

Everything `ceralive-platform` does is an HTTP call to **hawkBit's Management API**. It never
talks to a device, and a device never talks to it. The two halves only meet inside hawkBit.

---

## 1. Architecture overview — the two API planes

hawkBit exposes **two independent API planes** on the single `127.0.0.1:8080` port. The seam
is *only* the Management plane.

```
                    ┌──────────────────────── PRIVATE HOST (loopback / behind proxy) ───────────────┐
                    │                                                                                │
  ceralive-platform │   Management API plane                   DDI API plane (v1, FROZEN)            │
  (operator UI,     │   /rest/v1/{targets,                      /{tenant}/controller/v1/{controllerId}│
   server-side)     │           distributionsets,                                                    │
        │           │           rollouts,                                                            │
        │ Mgmt API   │           softwaremodules,                                                     │
        └───────────▶│           targetfilters}                                                       │
   server-to-server  │            │                                  ▲                                │
   (this seam)       │            ▼                                  │ poll + report (target token)   │
                    │      ┌───────────────┐                         │                                │
                    │      │    hawkBit    │◀────── JDBC ──── PostgreSQL                               │
                    │      │   0.4.1       │                         ▲                                │
                    │      └───────┬───────┘                         │                                │
                    └──────────────┼─────────────────────────────────┼────────────────────────────────┘
                                   │ DDI download link = R2 URL       │ DDI (HTTPS, via proxy/tunnel)
                                   ▼                                  │
                             apt.ceralive.tv/bundles/…          ┌───────────────────────┐
                             (R2, apt-worker task 39)           │ device fleet           │
                                   ▲                            │ rauc-hawkbit-updater 1.4│
                                   └──── GET .raucb ────────────┤ (RK3588, x86 …)        │
                                                                └───────────────────────┘
```

**Invariants (do not break):**

1. **Devices ↔ hawkBit DDI is a direct, frozen `v1` contract.** `ceralive-platform` is **NOT**
   in the device→hawkBit path. Adding the platform never changes a single byte a device sees.
2. **`ceralive-platform` ↔ hawkBit is server-to-server**, Management API only, over loopback or
   a private network — never the public internet directly (§2).
3. **hawkBit stores metadata only.** The `.raucb` payload lives in R2 and is fetched by the
   device straight from `apt.ceralive.tv` (task 39). The platform never proxies bundle bytes.
4. **The seam is additive.** Everything in this contract already works today via `curl`
   (the README smoke test + `provision.sh` exercise the same endpoints). `ceralive-platform`
   is just another Management-API client.

---

## 2. Authentication & network placement

### 2.1 How `ceralive-platform` authenticates to hawkBit (Management API)

hawkBit's Management API uses **HTTP Basic auth** against the built-in user store that
`docker-compose.yml` drives entirely from env (`HAWKBIT_SERVER_IM_USERS_0_*`). There is **no
`admin:admin`** — the stock demo user is removed (task 40).

| Field | Value | Source |
|-------|-------|--------|
| Scheme | HTTP Basic (`Authorization: Basic base64(user:pass)`) | hawkBit built-in IM |
| Username | `$HAWKBIT_ADMIN_USER` (a non-`admin` name, e.g. `ceralive-ops`) | `.env` (task 40) |
| Password (wire) | the **plaintext** the operator chose | passed to `curl -u` / `Authorization` |
| Password (at rest) | the **`{bcrypt}`** encoding of that plaintext | `HAWKBIT_ADMIN_PASSWORD` in `.env` |
| Role | `ADMIN` (`HAWKBIT_SERVER_IM_USERS_0_ROLES=ADMIN`) | compose |

> The bcrypt value in `.env` is what hawkBit *verifies against*; the plaintext is what a client
> *sends*. `ceralive-platform` stores the plaintext as a secret (env / vault), never the bcrypt.

**Recommended hardening for the platform integration (config, not new hawkBit code):**

- Provision a **dedicated service user** for `ceralive-platform` (a second
  `HAWKBIT_SERVER_IM_USERS_1_*` entry) rather than reusing the human operator's `ADMIN`
  login — so the platform's credential can be rotated/revoked independently.
- Keep the credential server-side only. The browser/operator UI of `ceralive-platform` must
  **never** receive hawkBit Basic creds; the platform's own backend (`apps/api`) is the
  Management-API client and presents its own session/JWT auth to the operator.

> **Auth boundary:** Management auth (Basic, operator/platform) is **separate** from DDI auth
> (target-token / gateway-token, device — `HAWKBIT_SERVER_DDI_SECURITY_AUTHENTICATION_*`). The
> seam touches Management auth only; device tokens are out of scope here.

### 2.2 Network placement — never public, no device coupling

hawkBit binds `127.0.0.1:8080` (compose `ports:`), so:

- **Same host:** `ceralive-platform`'s backend reaches it at `http://127.0.0.1:8080/rest/v1/`.
- **Different host:** front hawkBit with a private channel the platform terminates —
  reverse proxy with mTLS / IP allowlist, a VPN, or a Cloudflare Tunnel (task 40 README).
  **Never** rebind to `0.0.0.0`.

The bridge (`platform-bridge.sh`) defaults `HAWKBIT_URL=http://127.0.0.1:8080`; override it
with the private base URL when the platform runs off-host.

---

## 3. Endpoints — hawkBit Management API `v1`

Base: `${HAWKBIT_URL}/rest/v1` (default `http://127.0.0.1:8080/rest/v1`).
All calls carry `-u "$HAWKBIT_ADMIN_USER:$pass"` and `Accept: application/json`.
Mutating calls add `Content-Type: application/json`.

Paged collections return `{ "content": [...], "total": N, "size": S, ... }`. Filter with the
RSQL-ish `q=` param (e.g. `q=controllerId==dev-001`), page with `offset` / `limit`, sort with
`sort=field:ASC|DESC`.

### 3.1 List targets (the fleet)

```
GET /rest/v1/targets?offset=0&limit=50
```

```json
{
  "content": [
    {
      "controllerId": "rock5b-aabbccddeeff",
      "name": "rock5b-aabbccddeeff",
      "updateStatus": "in_sync",
      "createdAt": 1717420000000,
      "lastControllerRequestAt": 1717423600000,
      "pollStatus": { "lastRequestAt": 1717423600000, "nextExpectedRequestAt": 1717427200000, "overdue": false },
      "_links": { "self": { "href": ".../targets/rock5b-aabbccddeeff" } }
    }
  ],
  "total": 1, "size": 1
}
```

`controllerId` is the stable device key (the device sets it at DDI registration — see §7).
`updateStatus` ∈ `unknown | in_sync | pending | error | registered`.

### 3.2 Get one target

```
GET /rest/v1/targets/{controllerId}
GET /rest/v1/targets/{controllerId}/attributes      # device-reported key/value attrs (§7)
GET /rest/v1/targets/{controllerId}/installedDS      # currently-installed distribution set
GET /rest/v1/targets/{controllerId}/assignedDS       # assigned (in-flight) distribution set
```

### 3.3 List / get distribution sets (available OS bundles)

```
GET /rest/v1/distributionsets
GET /rest/v1/distributionsets/{dsId}
GET /rest/v1/distributionsets/{dsId}/assignedTargets
```

A distribution set is the assignable unit (`type=os-rauc`, one RAUC software module — §4).
`provision.sh` creates `ceralive-os` `<version>` as `DS_ID`.

```json
{
  "content": [
    { "id": 12, "name": "ceralive-os", "version": "2026.06.03", "type": "os-rauc",
      "complete": true, "deleted": false, "requiredMigrationStep": false }
  ], "total": 1, "size": 1
}
```

### 3.4 Create / start a rollout (push an update)

```
POST   /rest/v1/rollouts                 # create (PAUSED until started)
POST   /rest/v1/rollouts/{id}/start      # begin execution
GET    /rest/v1/rollouts/{id}            # status / per-group progress
GET    /rest/v1/rollouts/{id}/deploygroups
```

Body (the `compatible`-scoped, grouped rollout — see §6):

```json
{
  "name": "ceralive-rk3588-2026.06.03",
  "distributionSetId": 12,
  "targetFilterQuery": "attribute.compatible==ceralive-rk3588",
  "amountGroups": 3,
  "successCondition":  { "condition": "THRESHOLD", "expression": "80" },
  "successAction":     { "action": "NEXTGROUP", "expression": "" },
  "errorCondition":    { "condition": "THRESHOLD", "expression": "20" },
  "errorAction":       { "action": "PAUSEROLLOUT", "expression": "" }
}
```

> A freshly-created rollout is **not running** — it is `READY`/paused until
> `POST /rollouts/{id}/start`. This two-step (create → review → start) is the safe operator
> gesture the future UI exposes; the platform must call **both**.

### 3.5 Per-target action history (device update history)

```
GET /rest/v1/targets/{controllerId}/actions?sort=id:DESC
GET /rest/v1/targets/{controllerId}/actions/{actionId}
GET /rest/v1/targets/{controllerId}/actions/{actionId}/status   # status-entry timeline
```

```json
{
  "content": [
    { "id": 501, "type": "update", "status": "finished",
      "distributionSet": { "id": 12, "name": "ceralive-os", "version": "2026.06.03" },
      "rollout": { "id": 9, "name": "ceralive-rk3588-2026.06.03" } }
  ], "total": 1, "size": 1
}
```

`status` ∈ `running | finished | error | canceling | canceled | warning | scheduled`.

---

## 4. RAUC slot ↔ distribution set mapping

This is the bridge between the **device-side RAUC model** (frozen partition contract +
`system.conf`) and the **hawkBit deployment model**. `ceralive-platform` reads this mapping to
present human-meaningful update state.

### 4.1 Object mapping

| Device / RAUC concept | Source of truth | hawkBit object | hawkBit type/key |
|-----------------------|-----------------|----------------|------------------|
| `rootfs.0` (`rootfs_a`) / `rootfs.1` (`rootfs_b`) symmetric A/B slots | `mkosi/runtime/rauc/system.conf` `[slot.rootfs.0/1]`; sizes FROZEN in `docs/partition-contract.md §3` | *(not modelled per-slot)* — see §4.2 | — |
| One signed `.raucb` bundle | task 28 build → R2 | one **artifact** (metadata only) | — |
| The OS rootfs update unit | the bundle | one **software module** | SM type `rauc` |
| The assignable/rollout unit | — | one **distribution set** | DS type `os-rauc` (mandatory module = `rauc`) |
| `compatible=ceralive-${FAMILY}` in `system.conf` / `manifest.raucm` | `system.conf [system] compatible` (default `ceralive-unknown`; set to `ceralive-rk3588`, `ceralive-x86`, …) | rollout **target filter** | `attribute.compatible==ceralive-${FAMILY}` |

### 4.2 Why hawkBit has no per-slot (A/B) object — and how the platform reads slot state

**hawkBit does not model RAUC's A/B slots, and must not.** The A/B swap is entirely a
*device-local* RAUC concern: `rauc-hawkbit-updater` receives **one** distribution set (one
bundle), hands it to RAUC over D-Bus (`InstallBundle`), and RAUC writes the *inactive* slot,
flips `BOOT_ORDER`, and reboots — all invisible to hawkBit. hawkBit only sees *"install this DS
→ action RUNNING → FINISHED/ERROR"*.

Consequences for `ceralive-platform`:

- **"Which slot is active (A/B)?"** is **NOT** available over the Management API by default. It
  is device-local RAUC state (`rauc status`). If the platform needs it, the device must *report*
  it as a **target attribute** (e.g. `rauc.booted=A`) via its DDI config-data push (§7) — an
  optional device-side enhancement, **out of scope for this contract** (would be a future
  device task, not a platform task).
- **What the platform CAN read today** maps cleanly without slot visibility:
  - *installed version* → `GET /targets/{id}/installedDS` → `version` (the running OS).
  - *in-flight version* → `GET /targets/{id}/assignedDS` → `version` (what's being installed).
  - *update outcome* → latest action `status` (§3.5, §5). A `finished` action ⇒ the new slot
    booted and RAUC marked it good; an `error` action ⇒ RAUC rejected/rolled back (the device
    is still on the previous slot — the A/B safety net did its job, transparently to hawkBit).
- **`compatible` is the slot-safety guarantor, surfaced as a filter.** The same string that RAUC
  uses to *reject a foreign bundle at install* (`system.conf [system] compatible`) is what the
  rollout `targetFilterQuery` uses to *never offer* the wrong bundle. Defense in depth: hawkBit
  won't offer it; RAUC won't install it. The platform builds its "which boards can take this
  bundle" view from `attribute.compatible` (§7) — **not** from any slot concept.

> **Net:** the RAUC slot model collapses, on the seam, to *(installed DS version, assigned DS
> version, last action status, compatible filter)*. That quadruple is the platform's read model
> for OS state. Per-slot A/B detail stays on the device unless a future device task chooses to
> publish it as an attribute.

---

## 5. Fleet-status read model

How `ceralive-platform` turns raw hawkBit fields into operator-facing device state. Two layers:
**per-device** and **per-rollout**.

### 5.1 Per-device state (derive from target + latest action)

| Platform state | Derived from | Rule |
|----------------|--------------|------|
| **Up to date** | `target.updateStatus == in_sync` | installed DS == newest assigned DS, no pending action |
| **Updating** | latest action `status == running` | a rollout/assignment is in flight |
| **Update failed** | latest action `status == error` | RAUC rejected/rolled back; device safe on prior slot |
| **Pending** | `target.updateStatus == pending` OR action `scheduled` | assigned, not yet acted (e.g. group not started) |
| **Offline / overdue** | `target.pollStatus.overdue == true` | missed its expected DDI poll window |
| **Unknown / new** | `updateStatus ∈ {unknown, registered}` | registered, never updated via hawkBit |

DDI action-status → platform mapping (the canonical three the task calls out):

```
RUNNING   →  "Updating"        (action.status == running)
FINISHED  →  "Up to date"      (action.status == finished; installedDS advanced)
ERROR     →  "Update failed"   (action.status == error;  device rolled back, prior slot active)
```

Liveness is **independent** of update state: `pollStatus.overdue` / `lastControllerRequestAt`
tell the platform whether the device is *reachable*, regardless of whether an update is running.

### 5.2 Per-rollout state (derive from rollout + deploy groups)

```
GET /rest/v1/rollouts/{id}            → { status, totalTargets, totalTargetsPerStatus{...} }
GET /rest/v1/rollouts/{id}/deploygroups
```

`rollout.status` ∈ `creating | ready | starting | running | paused | finished`.
`totalTargetsPerStatus` gives the histogram `{ running, scheduled, finished, error, … }` the
operator dashboard renders as a progress bar. `paused` after an `errorCondition` THRESHOLD trip
(§6) is the operator's "investigate before continuing" signal.

---

## 6. Rollout trigger — the operator gesture

The full create→start sequence `ceralive-platform` performs (and `platform-bridge.sh
trigger_rollout` wraps):

1. **Resolve the distribution set** for the target OS version
   (`GET /distributionsets?q=name==ceralive-os;version==<v>` → `DS_ID`). `provision.sh`
   already created it.
2. **Create the rollout** scoped by `compatible` (§3.4) — board family filter
   `attribute.compatible==ceralive-${FAMILY}`, grouped (`amountGroups`, canary-style), with
   success/error thresholds. Returns `{ id }`, state `READY`/paused.
3. **(optional) Review** group composition (`GET /rollouts/{id}/deploygroups`) — the human gate
   the future UI renders.
4. **Start** it: `POST /rollouts/{id}/start`. hawkBit now assigns the DS to group 1's targets;
   their `rauc-hawkbit-updater` picks it up on next DDI poll.
5. **Monitor** (§5.2) until `finished`, or `paused` on an error-threshold trip.

> **Why grouped + thresholded by default:** a bad OS bundle is fleet-fatal. Groups (canary →
> wider) + `errorAction=PAUSEROLLOUT` mean a regression halts after the first group instead of
> bricking everyone. The A/B + bootcount rollback (device-side) is the *second* safety net; the
> rollout grouping is the *first*. The platform should default to ≥2 groups and a low error
> threshold, never a single ungrouped blast.

The device-facing half is untouched: the device still just polls DDI and installs whatever DS it
is offered. The rollout machinery is entirely Management-side.

### 6.1 Launch rollout rings and holds

Production rollout policy is ring-staged even though the hawkBit primitive is a grouped rollout:

| Ring | Target | Gate |
|------|--------|------|
| Internal device | 1 lab-owned device | update success + boot success + stream-capable smoke |
| 1 device | 1 customer-like device | no update error + reconnect + stream start |
| 5% | 5% of eligible devices | success >= 80%, error < 10% |
| 25% | 25% of eligible devices | success >= 80%, error < 10% |
| 100% | all remaining eligible devices | rollout finishes without `paused` or `error` |

`ceralive-platform` defaults its wizard to `amountGroups=5` to match these launch rings. The
Management-API body still carries the same safety actions: `successAction=NEXTGROUP` and
`errorAction=PAUSEROLLOUT`. A `paused` rollout is an emergency stop: investigate before any
new rollout for that distribution set.

Do-not-update holds are operator-owned hawkBit target classifications. A held target must be
excluded from the target set before the platform starts a rollout. The device DDI contract is not
changed by this hold; the platform/hawkBit Management plane owns it.

---

## 7. Custom data fields — device metadata the platform can read

Devices push **attributes** (key/value) to hawkBit via DDI config-data
(`PUT /{tenant}/controller/v1/{controllerId}/configData`); the platform reads them over
Management API:

```
GET /rest/v1/targets/{controllerId}/attributes
```

```json
{ "controllerId": "rock5b-aabbccddeeff",
  "attributes": {
    "compatible": "ceralive-rk3588",
    "board": "rock-5b-plus",
    "family": "rk3588",
    "firmware.version": "2026.06.03",
    "rauc.compatible": "ceralive-rk3588"
  } }
```

| Attribute | Meaning | Used by platform for | Source |
|-----------|---------|----------------------|--------|
| `compatible` | RAUC `compatible` string `ceralive-${FAMILY}` | rollout target filter (§6); bundle-eligibility view | `system.conf [system] compatible` |
| `board` | board id (`rock-5b-plus`, `orange-pi-5-plus`) | per-board grouping/labels | manifest `board_id` |
| `family` | SoC family (`rk3588`, `x86`) | per-family grouping | manifest `family` |
| `firmware.version` | installed OS bundle version | "installed version" column (cross-check `installedDS`) | bundle manifest |

**Contract stance on attributes:** `compatible` is **required** (the rollout filter depends on
it; `rauc-hawkbit-updater` reports it). `board` / `family` / `firmware.version` are
**recommended** and **cert expiry** is **optional/future**:

- **cert expiry** (mTLS / RAUC-signing leaf expiry, e.g. `cert.mtls.notAfter`) is a *desirable*
  field for the platform to surface (proactive cert-rotation alerts, ties to `cert-work/` PKI),
  but publishing it is a **device-side** enhancement (the device would add it to its DDI
  config-data push). It is **NOT** implemented by this task and requires no platform code now —
  documented here only so the read model has a defined slot for it when a future device task
  adds it.

The platform must treat any non-required attribute as **possibly absent** and degrade
gracefully (the contract guarantees presence only for `compatible`).

---

## 8. Future UI seam — where the operator dashboard plugs in

The operator dashboard is **deferred to `ceralive-platform`** and **not built by this task**.
This contract defines exactly where it attaches so it can be added with zero device changes and
zero new hawkBit code:

```
┌─────────────────── ceralive-platform (FUTURE — not this task) ───────────────────┐
│  apps/web (SvelteKit)         apps/api (Fastify + tRPC)                            │
│   operator dashboard  ──tRPC──▶  fleet router  ──HTTP Basic──▶  hawkBit Mgmt API   │
│   (fleet list, device          (server-side; holds the         (this contract,    │
│    detail, rollout wizard,      hawkBit service credential)      §3–§7)            │
│    progress bars)                      │                                           │
│                                        └── may shell out to / replicate ───────────┼─▶ platform-bridge.sh
└───────────────────────────────────────────────────────────────────────────────────┘
```

**Plug-in points (all already specified above):**

- **Fleet list view** ← §3.1 + §5.1 (target list + derived per-device state).
- **Device detail view** ← §3.2 + §3.5 + §7 (target + action history + attributes).
- **"Available updates" view** ← §3.3 (distribution sets).
- **Rollout wizard** ← §6 (create → review groups → start), scoped by §4 `compatible`.
- **Rollout progress** ← §5.2 (rollout status + group histogram).

**Hard boundaries the future UI inherits from this contract:**

1. The hawkBit Basic credential lives **only** in the platform's server-side (`apps/api`); the
   browser/operator never holds it. The platform presents its own auth (JWT/session) to the
   operator and proxies to hawkBit server-side.
2. The UI never reaches a device and never touches the DDI plane — all data flows through the
   Management API described here.
3. Adding the UI requires **no** change to the device image, RAUC config, `system.conf`,
   partition layout, or hawkBit deployment objects. The seam is frozen at this contract's v1.

> **Today (task 43) deliverable** = this document + `hawkbit/platform-bridge.sh` (a thin,
> stable bash wrapper over §3 endpoints). `ceralive-platform` can call the bridge directly or
> replicate its `curl`/`jq` calls in TypeScript — either way it codes against *this contract*,
> not against hawkBit internals.

---

## 9. Verifying the contract (consumable check)

hawkBit need not be running to validate the *shape*; when it is (task 40 `docker-compose up`),
these exercise every documented endpoint. `$U` = `$HAWKBIT_ADMIN_USER:<plaintext>`,
`$H` = `http://127.0.0.1:8080`.

```bash
# auth enforced — anonymous is 401
curl -s -o /dev/null -w '%{http_code}\n'            "$H/rest/v1/targets"                 # 401

# §3.1 list fleet
curl -s -u "$U" "$H/rest/v1/targets?limit=50"            | jq '.content[] | {controllerId, updateStatus}'
# §3.2 one device + attributes (§7)
curl -s -u "$U" "$H/rest/v1/targets/$CID"                | jq '{controllerId, updateStatus}'
curl -s -u "$U" "$H/rest/v1/targets/$CID/attributes"     | jq '.attributes'
curl -s -u "$U" "$H/rest/v1/targets/$CID/installedDS"    | jq '{name, version}'
# §3.3 distribution sets
curl -s -u "$U" "$H/rest/v1/distributionsets"            | jq '.content[] | {id, name, version, type}'
# §3.5 action history → §5.1 state
curl -s -u "$U" "$H/rest/v1/targets/$CID/actions?sort=id:DESC" | jq '.content[0] | {id, type, status}'
# §6 rollout create → start → monitor
DS=$(curl -s -u "$U" "$H/rest/v1/distributionsets?q=name==ceralive-os" | jq -r '.content[0].id')
RID=$(curl -s -u "$U" -H 'Content-Type: application/json' -X POST "$H/rest/v1/rollouts" \
       -d "{\"name\":\"rk3588-$(date +%Y%m%d)\",\"distributionSetId\":$DS,\
            \"targetFilterQuery\":\"attribute.compatible==ceralive-rk3588\",\"amountGroups\":3}" | jq -r '.id')
curl -s -u "$U" -X POST "$H/rest/v1/rollouts/$RID/start"
curl -s -u "$U" "$H/rest/v1/rollouts/$RID" | jq '{status, totalTargets, totalTargetsPerStatus}'
```

The thin bridge wraps the read+trigger subset:
`./platform-bridge.sh list_targets | jq .`, `… get_target_status <cid>`,
`… list_distribution_sets`, `… trigger_rollout <dsId> <compatible> <amountGroups>`.

---

## 10. Scope statement (what this task did and did NOT do)

- **DID:** define the server-to-server Management-API contract (§1–§8); ship a thin, stable bash
  bridge (`hawkbit/platform-bridge.sh`) over the read+trigger endpoints; document consumable
  `curl`/`jq` exercises (§9).
- **DID NOT:** add any `ceralive-platform` feature, route, tRPC procedure, schema, or UI; modify
  any file under `ceralive-platform/`; couple devices to the seam (devices stay on DDI v1);
  change hawkBit deployment objects, RAUC config, `system.conf`, or the partition layout; expose
  hawkBit publicly (still loopback-bound).

The operator UI is deferred; this contract is the stable interface it will be built against.
