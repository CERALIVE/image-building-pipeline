# systemd-sysext refresh — live-service restart protocol

> **Status:** decided (spike complete). This gates the W3 add-on manager design
> (tasks 27/28/29). Evidence: [`test-results/task-1-sysext-refresh.txt`](../../test-results/task-1-sysext-refresh.txt).
> Precedent it validates: [`v2/lib/app-layer/sysext.sh:124-125`](../lib/app-layer/sysext.sh).

## The decision (deterministic)

**Services SURVIVE a `systemd-sysext refresh`/`unmerge` — but the running process
keeps executing the OLD code.** A sysext op is filesystem-level only; it never
hot-swaps the binary inside a running process. Therefore:

| Operation | Sysext call | Service lifecycle (MANDATORY) | Reboot? |
|-----------|-------------|------------------------------|---------|
| **Update** an add-on | `systemd-sysext refresh` (live-safe; no pre-stop needed) | **`systemctl restart <addon>.service` AFTER refresh** — this, not the refresh, is what activates the new binary | No |
| **Disable** an add-on | `systemd-sysext refresh` / `unmerge` | **`systemctl stop <addon>.service` BEFORE teardown** — otherwise the process lingers on a deleted inode | No |

This is not "it depends": refresh/unmerge **always** succeed live and **never**
crash the service, and the in-place process **never** picks up the new binary. The
restart (on update) / stop (on disable) is a separate, non-negotiable step the
add-on manager owns.

## Why — empirically, not by assumption

A live spike drove the **real** `systemd-sysext` (systemd 260) against the `/opt`
hierarchy while a daemon executed a sysext-provided binary. The daemon re-announces
its compiled-in version on `SIGUSR1`, so we can read exactly which code the
still-running process runs. Full transcript in the evidence file; the load-bearing
lines:

```
### 4. systemd-sysext refresh WHILE the daemon is running
Unmerged '/opt'. Merged extensions into '/opt'.
refresh exit=0                                   # live-safe: no EBUSY, no failure

### 5. observe after refresh
DAEMON_SURVIVED_REFRESH=yes                       # process not killed
LIVENESS PROBE -> daemon-alive VERSION=1          # running process STILL runs old code
NEW exec of on-disk binary now reports: VERSION=2 # disk has new code; only a re-exec sees it

### 6. systemd-sysext unmerge WHILE the daemon is running
unmerge exit=0                                    # live-safe
DAEMON_SURVIVED_UNMERGE=yes                        # still alive...
LIVENESS PROBE after unmerge -> daemon-alive VERSION=1   # ...still running the now-DELETED binary
on-disk path after unmerge: GONE
```

What this proves:

1. **`refresh`/`unmerge` are live-safe.** Both return `0` while the binary is mapped
   by a running process — systemd lazily detaches the busy overlay instead of
   failing with `EBUSY`. The caller does **not** have to stop the service to make
   the call succeed.
2. **The running process is not killed.** The kernel keeps the original executable
   inode alive for the process via its mapping, even after the overlay that provided
   it is torn down.
3. **The in-place process never hot-swaps.** After both refresh and unmerge the
   liveness probe still reports `VERSION=1`. The new binary (`VERSION=2`) is on disk
   and visible to any **new** exec, but the existing process keeps running the old
   (after unmerge: deleted) code until it re-execs.

## Consequences for the W3 add-on manager

- **Update path:** install `<name>.raw` → `systemd-sysext refresh` → `systemctl
  restart <addon>.service`. The restart is what makes the update take effect; a
  refresh without a restart silently leaves the old binary running. (Ordering note:
  `stop → refresh → start` is equally correct and marginally avoids a brief window
  where an old process runs against new on-disk peers; the evidence shows the
  simpler refresh-then-restart is safe and sufficient, matching the
  `sysext.sh:124-125` precedent.)
- **Disable path:** `systemctl stop <addon>.service` first, *then* refresh/unmerge,
  so the service shuts down cleanly via its still-present binary rather than
  lingering on a deleted inode.
- **No reboot anywhere.** Every transition above is achievable live.
- **Don't conflate the two layers.** Treat a sysext refresh/unmerge as
  filesystem-only; service lifecycle is a distinct, mandatory step. The manager must
  never report an add-on "updated" or "disabled" on the strength of the sysext call
  alone.

## Reproducing the spike

The throwaway artifacts (`food.c`, two squashfs `.raw`s, the runner) live outside
the repo under `/tmp/opencode` and are intentionally not committed. The runner
isolates everything in a private mount namespace so the host is never perturbed:

```bash
sudo unshare -m bash /tmp/opencode/spike.sh
```

On a runner without QEMU or a built x86 image, `v2/tests/qemu-x86.sh` takes its
designed continue-on-error SKIP branch; it exercises boot plumbing, not this sysext
mechanic, which is why the spike drives `systemd-sysext` directly. See the evidence
file's Part A for the harness skip and the host-safety rationale.
