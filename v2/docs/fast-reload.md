# Fast-Reload Development Loop

The canonical fast-reload test suite for CeraLive v2. Save a file, watch it land
on a running device — frontend in **under a second**, backend/native in **a few
seconds** — with a health gate and automatic rollback so a bad change degrades to
a no-op, never an outage.

This page ties together the two tools that make up the loop:

- **`dev-push <ip>`** — one-shot, full-component push (build → rsync → refresh →
  restart). Canonical reference: [`dev-loop.md`](dev-loop.md).
- **`dev-sync --all`** — opt-in watch mode that routes every save to the right
  per-component sync script. Developer guide: [`../lib/dev-sync/README.md`](../lib/dev-sync/README.md).

`dev-push` is the building block; `dev-sync` is the watcher that fires it (or its
per-component equivalents) on change.

---

## 1. Overview — the watch → build → verify → health-gate → rollback contract

The fast-reload loop is a single, uniform contract regardless of which component
changed:

```
 watch ──▶ build ──▶ verify ──▶ health-gate ──▶  (pass) live
   ▲          │         │            │
   │          │         │            └─(fail)─▶ rollback ──▶ old version restored
   └──────────┴─────────┴── a failed step short-circuits the rest ──┘
```

| Stage | What happens | Where it lives |
|-------|--------------|----------------|
| **watch** | A file watcher (watchexec → entr → inotifywait, first available) detects a save under a source tree and debounces a burst into one sync. | `dev-sync` orchestrator |
| **build** | The changed component is compiled into its deploy artifact (static bundle, Bun binary, or `<app>.raw` sysext). | per-component `sync-*.sh` |
| **verify** | The artifact is validated *before* it touches the device: arch check, and for native `systemd-dissect --verify` on the `.raw`. | `sync-backend.sh` / `sync-native.sh` |
| **health-gate** | After the device-side `systemd-sysext refresh && systemctl restart ceralive.service`, the loop polls `systemctl is-active` + an HTTP probe. | `sync-backend.sh` / `sync-native.sh` |
| **rollback** | On a failed refresh, restart, or health probe, the previous artifact (A/B snapshot) is restored and the service re-started on the known-good version. | `sync-backend.sh` / `sync-native.sh` |

The load-bearing detail is the **`&&` between `refresh` and `restart`**: if
`systemd-sysext refresh` rejects a corrupt/mismatched `.raw`, the restart never
runs, the previously-merged extension stays active, and the service keeps
streaming on the old version. A bad push is a loud no-op, not an outage.

Frontend is the exception that proves the rule: it is **disk-served** (the Bun
backend serves static files straight off disk per request), so its loop is
watch → build → atomic publish with **no restart, no health-gate, no rollback**
— it is always stream-safe.

---

## 2. Prerequisites

Everything runs on the **build host** (the machine you edit on), not the device.

| Tool | Why | Install |
|------|-----|---------|
| **A file watcher** (one of) | Detects saves and debounces bursts | see below |
| `watchexec` (preferred) | Native debounce + `.gitignore` awareness + clean child teardown | `cargo install watchexec-cli` · `brew install watchexec` · `apt install watchexec` · `pacman -S watchexec` |
| `entr` (fallback) | Lightweight, file-list driven | `apt install entr` · `brew install entr` · `pacman -S entr` |
| `inotifywait` (fallback) | From `inotify-tools`; manual debounce drain | `apt install inotify-tools` · `pacman -S inotify-tools` |
| `rsync` | Transport for every artifact | `apt install rsync` · `pacman -S rsync` |
| `ssh` | Remote refresh/restart + status probe | almost certainly already present |
| `bun` | Compiles the backend (`bun build --compile`) | `curl -fsSL https://bun.sh/install \| bash` |
| `mksquashfs` (`squashfs-tools`) | Packs native `<app>.raw` sysext (used by `dev-push`) | `apt install squashfs-tools` · `pacman -S squashfs-tools` |
| `pnpm` | Builds the frontend bundle (`pnpm --filter frontend build`) | `corepack enable` (ships with Node) |

Any **one** of the three watchers is enough; `watchexec` gives the best
experience. If none is installed a real `dev-sync` run aborts with per-distro
install guidance, and `DRY_RUN=1` warns about the gap while still printing the
plan (see §5).

**Device preflight (one-time)** — create the static-path symlink the frontend
sync depends on:

```bash
ssh root@ceralive.local bash < image-building-pipeline/v2/lib/dev-sync/setup.sh
```

Idempotent; creates `/opt/ceralive/public -> /var/www/ceralive`.

---

## 3. Usage

### Full one-shot push — `dev-push`

Build, rsync, refresh, and restart a component in **~35 s** (120 s budget):

```bash
# From image-building-pipeline/v2/ :
./dev-push 192.168.1.42                  # ceracoder + srtla (default)
./dev-push 192.168.1.42 ceracoder        # just ceracoder
./dev-push --from-deb /path/to/debs 192.168.1.42   # cross-arch / CI artifacts
```

Full reference, env knobs, and troubleshooting: [`dev-loop.md`](dev-loop.md).

### Watch mode — `dev-sync`

Watch the first-party source trees and route each save to its sync script:

```bash
# From the workspace root (ceralive/):
image-building-pipeline/v2/dev-sync --all          # frontend + backend + native
image-building-pipeline/v2/dev-sync --frontend     # UI only (no restart)
image-building-pipeline/v2/dev-sync --backend      # backend binary only
image-building-pipeline/v2/dev-sync --native       # ceracoder/srtla sysext
```

Preview the plan without starting anything (host-only, no SSH):

```bash
DRY_RUN=1 image-building-pipeline/v2/dev-sync --all
```

Ctrl-C stops every watcher cleanly. Full developer guide:
[`../lib/dev-sync/README.md`](../lib/dev-sync/README.md).

---

## 4. Health-gate semantics — what happens on failure

Only the **restart-bearing** components (backend, native) have a health gate;
frontend is disk-served and skips it entirely.

**Backend** (`sync-backend.sh`):

1. Back up the live `/opt/ceralive/ceralive` as `ceralive-old`.
2. Atomically rsync the new binary into place; restart `ceralive.service`.
3. **Health-gate:** poll `systemctl is-active` + `GET /` (200 = SPA index),
   up to `DEV_SYNC_HEALTH_RETRIES` (15) times, `DEV_SYNC_HEALTH_INTERVAL` (2 s)
   apart.
4. **On failure → rollback:** restore `ceralive-old`, restart, verify active,
   exit non-zero.

**Native** (`sync-native.sh`):

1. **verify** the `<app>.raw` with `systemd-dissect --verify` before deploy.
2. **push:** snapshot the live `<app>.raw` as `<app>-rollback.raw` (A/B), then
   atomically rsync the new `.raw` into place.
3. **refresh + restart:** `systemd-sysext refresh && systemctl restart
   ceralive.service` — the `&&` is load-bearing.
4. **health:** wait `DEV_SYNC_HEALTH_WAIT` (3 s), check `systemctl is-active`.
5. **On refresh/restart/health failure → rollback:** restore
   `<app>-rollback.raw` and re-run refresh+restart on the old version.

**Safe by default.** Two independent safety nets mean a broken change cannot take
the device down:

- The `&&` gate: a rejected `refresh` never reaches the `restart` — the old
  extension stays merged and live.
- The A/B snapshot + health gate: if the new version *does* merge but fails to
  come up healthy, the previous artifact is restored automatically.

Fault injection for QA: `DEV_SYNC_FORCE_HEALTH_FAIL=1` forces the backend health
gate to fail so you can exercise the rollback path without breaking real code.

---

## 5. Emulated QA mapping — host-only testing without a device

The fast-reload loop is device-facing, but most of the contract can be exercised
**entirely on the build host**, no board required. This is the sanctioned QA path
when hardware is unavailable.

| Goal | Host-only command | What it emulates |
|------|-------------------|------------------|
| Validate the sync **plan** (routing, watch dirs, watcher cmd) | `DRY_RUN=1 image-building-pipeline/v2/dev-sync --all` | watch + routing layer, with **no SSH and no watcher spawn** |
| Exercise the CeraUI **frontend + backend** behaviour | `cd CeraUI && pnpm dev:multi-modem` | the device backend with mock modems (`MOCK_SCENARIO=multi-modem-wifi`), via `mprocs` — the build/serve half of the loop |
| Exercise the **cloud platform** | `cd ceralive-platform && pnpm dev` | `turbo run dev` across `api` / `web` / `ingest-proxy` — the receive/cloud edge |

**`DRY_RUN=1` is the contract for plan validation.** It prints the full watch
plan — watcher, debounce, selected components, and the exact per-component
watcher command line — then exits 0 **without starting any watcher and without a
single SSH attempt**. If no watcher binary is installed it additionally warns that
a real run would abort, so the gap is visible in CI even on a host with no
watcher. This makes `DRY_RUN=1 dev-sync` safe to run in a hermetic CI job as a
smoke test of the routing layer.

The local emulated stacks (`pnpm dev:multi-modem` for CeraUI, `pnpm dev` for the
platform) cover the **build + behaviour** half of the loop. The **deploy half**
(rsync → refresh → restart → health-gate → rollback) is device-only and is
validated against real hardware via `dev-push` / `dev-sync` once a board is
reachable.

---

## 6. Per-component timings

Reference numbers (from [`dev-loop.md`](dev-loop.md) and the per-component budgets
in [`../lib/dev-sync/README.md`](../lib/dev-sync/README.md)):

| Path | Watch dir(s) | Restart? | Health-gate? | Timing budget |
|------|--------------|----------|--------------|---------------|
| **frontend** | `CeraUI/apps/frontend/src` | no (disk-served) | no | **< 600 ms** |
| **backend** | `CeraUI/apps/backend/src` | yes | yes (`GET /`) | **< 2.3 s** |
| **native** | `ceracoder/src`, `srtla/src` | yes | yes (`is-active`) | **< 4.1 s** |
| **`dev-push`** (full ceracoder + srtla) | n/a (one-shot) | yes | yes | **~35 s** total (120 s budget: build ≈ 30 s, rsync ≈ 2 s, remote ≈ 3.5 s) |

Debounce defaults to 500 ms (`DEV_SYNC_DEBOUNCE_MS`) so an editor's
write+rename+chmod burst coalesces into a single sync.

---

## See also

- [`dev-loop.md`](dev-loop.md) — `dev-push` 4-step contract, env knobs, prod-OTA parity.
- [`../lib/dev-sync/README.md`](../lib/dev-sync/README.md) — full dev-sync developer guide and env-knob reference.
- [`../lib/dev-sync/setup.sh`](../lib/dev-sync/setup.sh) — one-time device preflight.
