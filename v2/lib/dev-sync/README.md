# dev-sync — Developer Guide

Live-reload loop for the CeraLive device. Save a file, see it on the device in under a second (frontend) or a few seconds (backend/native). No daemon, no systemd unit — just a foreground watcher you kill with Ctrl-C.

---

## Contents

1. [Quickstart](#quickstart)
2. [Prerequisites](#prerequisites)
3. [Config: `.dev-sync.yaml`](#config-dev-syncyaml)
4. [Component paths](#component-paths)
5. [Stream-active policy](#stream-active-policy)
6. [Vite-proxy power-user mode](#vite-proxy-power-user-mode)
7. [Troubleshooting](#troubleshooting)
8. [Full env-knob reference](#full-env-knob-reference)

---

## Quickstart

```bash
# From the workspace root (ceralive/):
image-building-pipeline/v2/dev-sync --all
```

That's it. The watcher starts, watches all three source trees, and routes every save to the right sync script. Press **Ctrl-C** to stop cleanly.

Preview the watch plan without starting anything:

```bash
DRY_RUN=1 image-building-pipeline/v2/dev-sync --all
```

Watch only what you're changing:

```bash
image-building-pipeline/v2/dev-sync --frontend          # UI changes only
image-building-pipeline/v2/dev-sync --backend           # backend binary only
image-building-pipeline/v2/dev-sync --frontend --backend  # both, not native
```

---

## Prerequisites

**SSH key on the device.** The scripts connect as `root` (default) via SSH. Either add your public key to `/root/.ssh/authorized_keys` on the device, or set `DEV_SYNC_SSH_KEY` / `ssh_key` in `.dev-sync.yaml` to point at the right identity file.

**A file watcher.** The orchestrator auto-detects the first available binary in preference order:

| Watcher | Install |
|---------|---------|
| `watchexec` (preferred) | `cargo install watchexec-cli` / `brew install watchexec` / `apt install watchexec` |
| `entr` | `apt install entr` / `brew install entr` |
| `inotifywait` | `apt install inotify-tools` |

Any one of the three is enough. `watchexec` gives the best experience (native debounce, `.gitignore` awareness, clean child-process teardown).

**`rsync` and `ssh`** must be on your `PATH`. They almost certainly already are.

**For backend syncs:** `bun` must be installed on the build host (the machine running dev-sync, not the device). The backend is compiled with `bun build --compile`.

**For native syncs:** a build input is required. Pass `--staging <dir>`, `--from-deb <dir>`, or `--raw <file>` via `DEV_SYNC_NATIVE_ARGS`. See [native path](#native-srtla-sysext) below.

**Device preflight (one-time).** Run `setup.sh` once on the device to create the static-path symlink the frontend sync depends on:

```bash
ssh root@<selected-hostname>.local bash < image-building-pipeline/v2/lib/dev-sync/setup.sh
```

This creates `/opt/ceralive/public -> /var/www/ceralive`. It's idempotent — safe to run again.

---

## Config: `.dev-sync.yaml`

Copy the example and edit it:

```bash
cp image-building-pipeline/v2/lib/dev-sync/.dev-sync.yaml.example .dev-sync.yaml
```

Set `target_host` to the device's selected deterministic name (for example,
`ceralive2.local`) or set `target_ip`. There is deliberately no default target:
silently choosing `ceralive.local` can update the wrong device on a multi-device
LAN.

The file is discovered (first hit wins) at:

1. `$DEV_SYNC_CONFIG` (explicit path)
2. `./.dev-sync.yaml` (current working directory)
3. `image-building-pipeline/v2/lib/dev-sync/.dev-sync.yaml` (alongside the scripts)
4. `<workspace-root>/.dev-sync.yaml`

**Precedence:** environment variable > `.dev-sync.yaml` > built-in default.

### All fields

```yaml
# --- Target device ---

# Selected mDNS .local name, tried first. Falls back to target_ip on failure.
# env: DEV_SYNC_TARGET_HOST
target_host: <selected-hostname>.local

# Fallback IP when mDNS can't resolve. Leave empty for mDNS-only.
# env: DEV_SYNC_TARGET_IP
target_ip: 192.168.1.50

# --- SSH ---

# Remote user.  env: SSH_USER
ssh_user: root

# Private key for ssh -i. Leading ~/ is expanded.
# Empty = ssh-agent / default identity.  env: DEV_SYNC_SSH_KEY
ssh_key: ~/.ssh/id_ed25519

# SSH port.  env: DEV_SYNC_SSH_PORT
ssh_port: 22

# --- Remote paths ---

# Where sysext .raw extensions land (matches dev-push).  env: REMOTE_EXT_DIR
remote_ext_dir: /var/lib/extensions

# Remote scratch dir for rsync --temp-dir.  env: DEV_SYNC_REMOTE_TMP
remote_tmp: /tmp

# Per-component remote destinations.
srtla_remote: /var/lib/extensions       # env: DEV_SYNC_SRTLA_REMOTE
ceraui_remote: /opt/ceralive            # env: DEV_SYNC_CERAUI_REMOTE

# --- Loop behaviour ---

# End-to-end budget hint in seconds.  env: DEV_SYNC_BUDGET
budget: 120

# rsync ignore globs.  env: DEV_SYNC_IGNORE (space/comma separated)
ignore:
  - ".git/"
  - "node_modules/"
  - "*.tmp"
  - "*.swp"
  - ".DS_Store"
```

Print the resolved config at any time:

```bash
bash image-building-pipeline/v2/lib/dev-sync/config.sh
```

---

## Component paths

### Frontend (CeraUI static bundle)

**Watch dir:** `CeraUI/apps/frontend/src`
**Script:** `lib/dev-sync/sync-frontend.sh`
**Timing budget:** < 600 ms

**What it does:**

1. Builds the Svelte frontend with `pnpm --filter frontend build` (output: `CeraUI/dist/public/`).
2. Rsyncs the bundle into a staging dir on the device (`/var/www/ceralive.dev-sync.tmp`).
3. Swaps it in atomically with two back-to-back renames in a single SSH round-trip.

**No `ceralive.service` restart, ever.** The Bun backend serves static files straight off disk per request. New files go live the instant they land. A restart would tear down the in-process srtla FFI bindings and interrupt any active stream — so this path deliberately contains zero `systemctl` calls.

Relevant env knobs:

| Knob | Default | Purpose |
|------|---------|---------|
| `DEV_SYNC_CERAUI_DIR` | required | Explicit CeraUI checkout path |
| `DEV_SYNC_FRONTEND_DIST` | `<CeraUI>/dist/public` | Local build output dir |
| `DEV_SYNC_FRONTEND_BUILD_CMD` | `pnpm --filter frontend build` | Build command |
| `DEV_SYNC_FRONTEND_SKIP_BUILD` | `0` | Set to `1` to sync existing dist without rebuilding |
| `DEV_SYNC_CERAUI_STATIC` | `/var/www/ceralive` | Remote served bundle dir |

---

### Backend (CeraUI binary)

**Watch dir:** `CeraUI/apps/backend/src`
**Script:** `lib/dev-sync/sync-backend.sh`
**Timing budget:** < 2.3 s

**What it does:**

1. Checks host arch == device arch (refuses cross-arch builds unless `DEV_SYNC_ALLOW_CROSS_BUILD=1`).
2. Builds the backend binary with `bun run build:backend-only` (output: `CeraUI/dist/ceralive`).
3. Verifies the artifact arch matches the device.
4. Backs up the current `/opt/ceralive/ceralive` as `ceralive-old`.
5. Atomically rsyncs the new binary into place.
6. Restarts `ceralive.service`.
7. Health-gates: polls `systemctl is-active` + `GET /` (returns the SPA index with 200) up to 15 times, 2 s apart.
8. On health failure: rolls back to `ceralive-old`, restarts, verifies active, exits non-zero.

**Why it needs a restart.** The backend is a compiled Bun binary. Replacing it on disk has no effect until the process is restarted. More importantly, the running process has srtla loaded as an in-process FFI binding (`@ceralive/srtla` via a `link:` path; cerastream is consumed as the `@ceralive/cerastream` npm tarball, IPC-driven). Those bindings are loaded once at startup and live in the Bun process's memory. A new binary means new binding code, so a restart is unavoidable.

Relevant env knobs:

| Knob | Default | Purpose |
|------|---------|---------|
| `DEV_SYNC_CERAUI_REMOTE` | `/opt/ceralive` | Remote dir holding the binary |
| `DEV_SYNC_BACKEND_BINARY` | `ceralive` | Binary basename on the device |
| `DEV_SYNC_HEALTH_PORT` | `80` | Device HTTP port to probe |
| `DEV_SYNC_HEALTH_PATH` | `/` | HTTP path to probe (no `/health` route exists) |
| `DEV_SYNC_HEALTH_RETRIES` | `15` | Health probe attempts |
| `DEV_SYNC_HEALTH_INTERVAL` | `2` | Seconds between attempts |
| `DEV_SYNC_ALLOW_CROSS_BUILD` | `0` | Set to `1` to cross-compile via `bun --target` |

---

### Native (srtla sysext)

> cerastream dev-sync is a follow-on (IPC-driven engine, different sync shape).

**Watch dirs:** `srtla/src`
**Script:** `lib/dev-sync/sync-native.sh`
**Timing budget:** < 4.1 s

**What it does (phase order):**

1. **arch-check** — refuses if the artifact arch doesn't match the device.
2. **build** — calls `build_app_layer` (the same verb dev-push uses) to produce `<app>.raw`.
3. **verify** — runs `systemd-dissect --verify` (or `--validate` on systemd ≥ 257) on the `.raw` before touching the device. Falls back to `unsquashfs -s` or `file` if systemd-dissect lacks the flag.
4. **push** — snapshots the live `<app>.raw` as `<app>-rollback.raw` (A/B), then atomically rsyncs the new `.raw` into place.
5. **refresh + restart** — runs `systemd-sysext refresh && systemctl restart ceralive.service` on the device. The `&&` is load-bearing: if `refresh` rejects a bad `.raw`, the restart never runs and the old extension stays merged.
6. **health** — waits `DEV_SYNC_HEALTH_WAIT` seconds, then checks `systemctl is-active ceralive.service`.
7. **rollback** (conditional) — on refresh/restart failure or health failure, restores `<app>-rollback.raw` and re-runs refresh+restart.

**Why it needs a restart.** Same reason as the backend: srtla is loaded as an in-process FFI binding inside the running Bun process. A sysext refresh merges the new `.raw` into the filesystem overlay, but the running process still has the old native code mapped into memory. Only a `ceralive.service` restart picks up the new bindings.

**Build input** (required for a real run; pass via `DEV_SYNC_NATIVE_ARGS`):

```bash
# From a .deb directory (prod-identical artifact):
DEV_SYNC_NATIVE_ARGS="--from-deb /path/to/debs" image-building-pipeline/v2/dev-sync --native

# From an extracted staging tree:
DEV_SYNC_NATIVE_ARGS="--staging /path/to/staging" image-building-pipeline/v2/dev-sync --native

# From a prebuilt .raw:
DEV_SYNC_NATIVE_ARGS="--raw /path/to/srtla.raw" image-building-pipeline/v2/dev-sync --native
```

Relevant env knobs:

| Knob | Default | Purpose |
|------|---------|---------|
| `DEV_SYNC_NATIVE_ARGS` | `` | Extra args forwarded to `sync-native.sh` |
| `REMOTE_EXT_DIR` | `/var/lib/extensions` | Where `.raw` extensions land on the device |
| `DEV_SYNC_HEALTH_WAIT` | `3` | Seconds to let the service settle before health probe |
| `DEV_SYNC_HEALTH_PROBE` | `` | Optional extra remote health command |
| `DEV_SYNC_DEVICE_ARCH` | `` | Offline/known-fleet arch override (skips SSH `uname -m`) |

---

## Stream-active policy

**Frontend** is always stream-safe. It never restarts anything, so the watcher syncs immediately regardless of stream state.

**Backend and native** restart `ceralive.service`, which tears down the in-process feed. Before routing a change, dev-sync probes the device's `GET /status` endpoint and checks `is_streaming`.

| Stream state | Default behaviour |
|---|---|
| `inactive` | Proceeds immediately |
| `active` | Prompts `[y/N]` on the terminal |
| `unknown` (device unreachable) | Treated as active, prompts `[y/N]` |

Two flags change this behaviour:

```bash
# Sync immediately, no prompt, even while streaming:
image-building-pipeline/v2/dev-sync --backend --force

# Queue the sync until the stream stops, then proceed automatically:
image-building-pipeline/v2/dev-sync --backend --defer
```

`--defer` polls every `DEV_SYNC_STREAM_POLL_INTERVAL` seconds (default 5). Set `DEV_SYNC_DEFER_TIMEOUT=<seconds>` to give up after a maximum wait (default 0 = wait forever).

The env equivalents are `DEV_SYNC_FORCE=1` and `DEV_SYNC_DEFER=1`, which are useful when running dev-sync non-interactively (e.g. from a script or CI).

---

## Vite-proxy power-user mode

This mode lets you run the Svelte frontend locally with full HMR while the backend runs on the actual device. Useful when you want instant UI iteration without deploying to the device on every save.

**How it works.** The frontend's RPC transport is a single WebSocket opened to the bare origin root (no `/rpc` or `/ws` path). When `VITE_DEVICE_HOST` is set, Vite proxies that root WebSocket to the device while serving the app and HMR locally. Plain HTTP requests stay local; only the `Upgrade: websocket` request is forwarded.

**Setup:**

```bash
# 1. Enable the device proxy in the frontend:
cp CeraUI/apps/frontend/.env.local.example CeraUI/apps/frontend/.env.local
# Edit .env.local — set VITE_DEVICE_HOST to your device's address.

# 2. Point the RPC socket at the local Vite server (monorepo root .env):
echo 'VITE_SOCKET_ENDPOINT=ws://localhost' >> CeraUI/.env
echo 'VITE_SOCKET_PORT=6173' >> CeraUI/.env

# 3. Start the frontend dev server:
cd CeraUI && pnpm --filter frontend dev
```

The three env vars in `apps/frontend/.env.local`:

| Var | Default | Purpose |
|-----|---------|---------|
| `VITE_DEVICE_HOST` | *(unset)* | Device hostname or IP. **This is the activation gate** — the proxy is entirely absent unless this is set. |
| `VITE_DEVICE_PORT` | `80` (ws) / `443` (wss) | Device backend port |
| `VITE_DEVICE_PROTOCOL` | `ws` | `ws` for plain, `wss` for TLS (self-signed certs accepted) |

**When to use this vs SSH rsync.** Use the Vite proxy when you're iterating on UI code and want HMR (sub-100 ms hot module replacement). Use `dev-sync --frontend` when you want to test the actual deployed bundle on the device, or when you need to verify the production build output.

**HMR isolation.** The proxy pins HMR to a dedicated local port (24678) so the root `/` WebSocket proxy never hijacks the HMR socket. You don't need to configure this manually.

---

## Troubleshooting

### mDNS resolution fails

**Symptom:** `dev-sync` can't reach the selected `.local` hostname even though the device is on the network.

**Cause.** `avahi-resolve` exits 0 even when resolution fails — it prints an error to stderr but returns success. The transport layer checks stdout content, not the exit code, to detect this.

**Fix:** Set the fallback IP in `.dev-sync.yaml`:

```yaml
target_ip: 192.168.1.50   # your device's actual IP
```

Or override at runtime:

```bash
DEV_SYNC_TARGET_IP=192.168.1.50 image-building-pipeline/v2/dev-sync --all
```

To skip mDNS entirely and always use the IP:

```bash
DEV_SYNC_TARGET_HOST="" DEV_SYNC_TARGET_IP=192.168.1.50 image-building-pipeline/v2/dev-sync --all
```

---

### sysext refresh fails, service keeps running

**Symptom:** `sync-native.sh` reports a refresh failure but `ceralive.service` is still active on the old version.

**This is correct behaviour, not a bug.** The on-device verb is:

```bash
systemd-sysext refresh && systemctl restart ceralive.service
```

The `&&` is load-bearing. If `systemd-sysext refresh` rejects the `.raw` (corrupt, wrong arch, bad signature), the restart never runs. The previously-merged extension stays active and the service keeps streaming on the old binary. A bad push degrades to a no-op with a loud error, never an outage.

Check the device logs for the rejection reason:

```bash
ssh root@<selected-hostname>.local journalctl -u systemd-sysext -n 50
```

---

### Arch mismatch

**Symptom:** `sync-backend.sh` or `sync-native.sh` refuses with "REFUSING build — host is amd64 but device is arm64".

**Cause.** The build host and device have different architectures. Building natively is the most reliable path.

**Options:**

1. Build on a host that matches the device (arm64 for Orange Pi/Radxa).
2. Cross-compile (backend only): `DEV_SYNC_ALLOW_CROSS_BUILD=1 image-building-pipeline/v2/dev-sync --backend`. This uses `bun --target=bun-linux-arm64`.
3. For native (sysext): build the `.deb` on the right arch and pass it via `DEV_SYNC_NATIVE_ARGS="--from-deb /path"`.

---

### Static-path symlink missing or wrong

**Symptom:** Frontend syncs succeed but the device serves a stale or empty bundle.

**Cause.** The symlink `/opt/ceralive/public -> /var/www/ceralive` is missing or points somewhere else. The backend's `WorkingDirectory` is `/opt/ceralive/` and it serves `./public`. The `.deb` stages the bundle to `/var/www/ceralive`. `setup.sh` bridges the gap.

**Fix:** Run setup on the device:

```bash
ssh root@<selected-hostname>.local bash < image-building-pipeline/v2/lib/dev-sync/setup.sh
```

To check the current state without changing anything:

```bash
ssh root@<selected-hostname>.local bash < image-building-pipeline/v2/lib/dev-sync/setup.sh --dry-run
```

If a real directory exists at `/opt/ceralive/public` (not a symlink), `setup.sh` will refuse to overwrite it. Remove or rename it manually first.

---

### No file watcher installed

**Symptom:** `dev-sync: no file watcher found.`

Install any one of the three supported watchers. `watchexec` is recommended:

```bash
# Debian/Ubuntu:
apt install watchexec
# or via cargo:
cargo install watchexec-cli
# macOS:
brew install watchexec
```

---

### Backend health gate keeps failing

**Symptom:** `sync-backend.sh` deploys the binary, restarts the service, but the health gate times out and rolls back.

**Check the service logs on the device:**

```bash
ssh root@<selected-hostname>.local journalctl -u ceralive.service -n 100
```

Common causes:

- **Arch mismatch in the binary** — the binary was cross-compiled but the device can't execute it. Check with `ssh root@<selected-hostname>.local file /opt/ceralive/ceralive`.
- **Port conflict** — something else is on port 80. The health probe hits `GET http://127.0.0.1:80/`. Override with `DEV_SYNC_HEALTH_PORT`.
- **Slow startup** — increase retries or interval: `DEV_SYNC_HEALTH_RETRIES=30 DEV_SYNC_HEALTH_INTERVAL=3`.

---

## Full env-knob reference

All knobs are optional except that one device target (`DEV_SYNC_TARGET_HOST` or
`DEV_SYNC_TARGET_IP`) must be selected. The matching `.dev-sync.yaml` field (if
any) is noted in parentheses.

### Orchestrator (`dev-sync`)

| Knob | Default | Purpose |
|------|---------|---------|
| `DRY_RUN` | `0` | Print the plan, start no watchers |
| `DEV_SYNC_DEBOUNCE_MS` | `500` | Coalesce window in milliseconds |
| `DEV_SYNC_CERAUI_DIR` | required | Explicit CeraUI checkout path |
| `SRTLA_SRC` | required for srtla dev-push | Explicit srtla source checkout path |
| `DEV_SYNC_NATIVE_ARGS` | `` | Extra args forwarded to `sync-native.sh` |
| `DEV_SYNC_FORCE` | `0` | Skip stream-active prompt for backend/native |
| `DEV_SYNC_DEFER` | `0` | Queue backend/native until stream stops |
| `DEV_SYNC_STREAM_STATUS_PORT` | `80` | Device port for `GET /status` probe |
| `DEV_SYNC_STREAM_STATUS_PATH` | `/status` | Path for stream-state probe |
| `DEV_SYNC_STREAM_POLL_INTERVAL` | `5` | `--defer` poll interval in seconds |
| `DEV_SYNC_DEFER_TIMEOUT` | `0` | `--defer` max wait in seconds (0 = forever) |
| `DEV_SYNC_STREAM_STATE` | `` | Override stream state offline: `active`/`inactive`/`unknown` |

### Device target (`config.sh` / `.dev-sync.yaml`)

| Knob | yaml field | Default | Purpose |
|------|-----------|---------|---------|
| `DEV_SYNC_TARGET_HOST` | `target_host` | `` | Explicit selected mDNS name such as `ceralive.local` or `ceralive2.local` |
| `DEV_SYNC_TARGET_IP` | `target_ip` | `` | Fallback IP |
| `SSH_USER` | `ssh_user` | `root` | Remote user |
| `DEV_SYNC_SSH_KEY` | `ssh_key` | `` | SSH identity file (`~/.ssh/id_ed25519`) |
| `DEV_SYNC_SSH_PORT` | `ssh_port` | `22` | SSH port |
| `REMOTE_EXT_DIR` | `remote_ext_dir` | `/var/lib/extensions` | sysext `.raw` destination |
| `DEV_SYNC_REMOTE_TMP` | `remote_tmp` | `/tmp` | Remote scratch dir for rsync |
| `DEV_SYNC_BUDGET` | `budget` | `120` | End-to-end budget hint (seconds) |
| `DEV_SYNC_SRTLA_REMOTE` | `srtla_remote` | `/var/lib/extensions` | srtla remote dest |
| `DEV_SYNC_CERAUI_REMOTE` | `ceraui_remote` | `/opt/ceralive` | CeraUI component root |
| `DEV_SYNC_IGNORE` | `ignore:` list | `.git/ node_modules/ *.tmp *.swp .DS_Store` | rsync exclude globs |

### Frontend (`sync-frontend.sh`)

| Knob | Default | Purpose |
|------|---------|---------|
| `DEV_SYNC_FRONTEND_DIST` | `<CeraUI>/dist/public` | Local build output |
| `DEV_SYNC_FRONTEND_BUILD_CMD` | `pnpm --filter frontend build` | Build command |
| `DEV_SYNC_FRONTEND_SKIP_BUILD` | `0` | Sync existing dist without rebuilding |
| `DEV_SYNC_CERAUI_STATIC` | `/var/www/ceralive` | Remote served bundle dir |

### Backend (`sync-backend.sh`)

| Knob | Default | Purpose |
|------|---------|---------|
| `DEV_SYNC_BACKEND_BINARY` | `ceralive` | Binary basename on the device |
| `DEV_SYNC_HEALTH_PORT` | `80` | Device HTTP port to probe |
| `DEV_SYNC_HEALTH_PATH` | `/` | HTTP path (no `/health` route exists; `/` returns 200) |
| `DEV_SYNC_HEALTH_RETRIES` | `15` | Health probe attempts |
| `DEV_SYNC_HEALTH_INTERVAL` | `2` | Seconds between attempts |
| `DEV_SYNC_ALLOW_CROSS_BUILD` | `0` | Allow cross-compilation via `bun --target` |
| `DEV_SYNC_FORCE_HEALTH_FAIL` | `0` | QA fault-injection: force health gate failure |

### Native (`sync-native.sh`)

| Knob | Default | Purpose |
|------|---------|---------|
| `DEV_SYNC_HEALTH_WAIT` | `3` | Seconds to settle before health probe |
| `DEV_SYNC_HEALTH_PROBE` | `` | Optional extra remote health command |
| `DEV_SYNC_DEVICE_ARCH` | `` | Offline arch override (skips SSH `uname -m`) |
| `SYNC_STAGING` | `` | Staging tree root (equivalent to `--staging`) |
| `<APP>_RAW` | `` | Prebuilt `.raw` path per app (e.g. `SRTLA_RAW`) |

### Vite proxy (`apps/frontend/.env.local`)

| Var | Default | Purpose |
|-----|---------|---------|
| `VITE_DEVICE_HOST` | *(unset)* | Device hostname or IP. Activation gate for the proxy. |
| `VITE_DEVICE_PORT` | `80` / `443` | Device backend port |
| `VITE_DEVICE_PROTOCOL` | `ws` | `ws` or `wss` |

Also set in the monorepo-root `.env` when using the Vite proxy:

| Var | Value | Purpose |
|-----|-------|---------|
| `VITE_SOCKET_ENDPOINT` | `ws://localhost` | Points RPC socket at local Vite server |
| `VITE_SOCKET_PORT` | `6173` | Vite dev server port |
