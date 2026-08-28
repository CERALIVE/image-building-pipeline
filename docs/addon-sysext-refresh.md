# systemd-sysext refresh — live-service restart protocol

> **Status:** decided (spike complete). This gates the W3 add-on manager design
> (tasks 27/28/29). Evidence: [`test-results/task-1-sysext-refresh.txt`](../../test-results/task-1-sysext-refresh.txt).
> Precedent it validates: [`lib/app-layer/sysext.sh:124-125`](../lib/app-layer/sysext.sh).

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

On a runner without QEMU or a built x86 image, `tests/qemu-x86.sh` takes its
designed continue-on-error SKIP branch; it exercises boot plumbing, not this sysext
mechanic, which is why the spike drives `systemd-sysext` directly. See the evidence
file's Part A for the harness skip and the host-safety rationale.

## The OS-version axis, and the release step it creates

> **Status:** decided. Applies from the trixie migration onwards.

An extension's `VERSION_ID` is the kernel's own merge key — `systemd`'s
`extension_release_validate()` refuses an extension whose `extension-release`
`VERSION_ID` does not match the running host's `/etc/os-release`. That value is
declared once, in [`manifests/target-release.env`](../manifests/target-release.env)
as `OS_VERSION_ID`, and every producer derives it from there:

| Producer | Derivation |
|---|---|
| `lib/app-layer/sysext.sh` | `SYSEXT_OS_VERSION_ID` defaults to `OS_VERSION_ID` |
| `mkosi/app/*.sysext.conf` | `SYSEXT_OS_VERSION_ID="${OS_VERSION_ID:?…}"` |
| `lib/build-feature-sysext.sh` | `--os-version` defaults to `OS_VERSION_ID`; `assert_g1` reads the stamp back out of the produced squashfs |
| `lib/upload-addons.sh` | `--os-version` defaults to `OS_VERSION_ID` — the publisher addresses the stem the builder stamped |
| `ci/validate-manifests.py` | parses the mapping into `SYSEXT_VERSION_ID` (G1) |
| `manifests/schema/addon.schema.json`, `manifests/addons/*.json` | mirrored, lockstep-checked by `ci/check-suite-literals.sh` |

The same value is also the `{os_version}` axis of the R2 delivery path,
`addons/{os_version}/{board}/{feature}.raw`, and of every descriptor's
`artifact.urlTemplate`.

### ADD-ON ARTIFACTS MUST BE PUBLISHED FOR `13` BEFORE ANY TRIXIE DEVICE ENABLES AN ADD-ON

**This is a RELEASE step, not a build step, and nothing in this repository can
perform it or detect that it was skipped.** The build side is fully parameterized —
a `./build` on this branch stamps `13`, names its artifact `<feature>-<board>-13.raw`
and plans the `addons/13/…` key — but the objects under `addons/13/` do not exist in
R2 until someone publishes them.

Until they do, a trixie device that enables an add-on:

1. resolves `artifact.urlTemplate` with `{os_version}` → `13`;
2. fetches `https://apt.ceralive.tv/addons/13/<board>/<feature>.raw`;
3. gets a **404** (`apt-worker` 404s a missing object; it never serves a 200-empty);
4. lands in the reconciler's non-terminal `pending` phase with
   `lastError: addon_not_available_for_os_version`.

That is the honest degradation and it is exactly right — no crash, no boot impact,
no effect on the OTA healthcheck or rollback — but it is **indistinguishable from a
device that is simply offline**, and it persists until the artifacts appear. The
already-published `addons/12/…` objects do NOT satisfy it: their `.raw` files carry
`VERSION_ID=12` in their `extension-release`, so even if the URL were rewritten to
reach them the kernel would refuse the merge.

**Release-checklist item (owner: the release-chain task):**

- [ ] For every add-on in `manifests/addons/`, and for every board in its
      `boardVariants` / `conditions.boardAllowlist`, build the artifact set for
      `os_version = 13` and publish it with `lib/upload-addons.sh` (which now
      defaults to the mapping, so pass no `--os-version`).
- [ ] Verify each object is reachable at `addons/13/<board>/<feature>.raw` together
      with its `.raw.sha256` and `.raw.sig` — the device verifies BOTH before it
      activates anything, so a `.raw` published without its sidecars is a device-side
      verification failure rather than a partial success.
- [ ] Keep the `addons/12/…` objects in place for as long as any bookworm device is
      in the fleet. <!-- suite-literal-ok: names the retired OS line's existing R2 prefix, which is the point of the retention rule -->
      The two lines are separate key prefixes and do not
      collide; nothing about publishing `13` retires `12`.

**Cross-repo blocker, recorded here because it is invisible from this side.**
CeraUI's `AddonDescriptorSchema` pins the descriptor's merge identity as a literal
(`packages/rpc/src/schemas/addons.schema.ts`, `versionId: z.literal('12')`), <!-- suite-literal-ok: names the exact cross-repo literal this note exists to report -->
and its post-boot reconciler parses every image-baked descriptor through that schema
before it reaches the version-agnostic fetch path. A descriptor carrying `versionId:
"13"` therefore fails Zod validation and the add-on is parked in `error` with
`addon_descriptor_unavailable` — never reaching the URL substitution at all. The
reconciler itself needs no change (see below); that one literal does, and it is
CeraUI's to make.

### The CeraUI reconciler needs NO code change

Confirmed by reading `apps/backend/src/modules/addons/reconciler.ts` (read-only):

- `readOsVersionId()` parses `/^VERSION_ID=(.*)$/m` out of `/etc/os-release` at
  runtime — it has no baked-in version.
- `reconcileOne()`'s G1 gate is
  `descriptor.compatibleOsVersions && !descriptor.compatibleOsVersions.includes(osVersion)`,
  an **exact match against that runtime value**, and the already-materialised check
  is `prev.osVersionMaterialized === osVersion`.
- `substitutePlaceholders()` replaces `{os_version}` with the same runtime value.

Every one of those reads the live OS, so the reconciler is version-agnostic **by
design** and works on `13` unchanged. What it cannot do is invent an artifact that
was never published, which is why the checklist item above exists.
