<!-- Moved verbatim from AGENTS.md on 2026-10-05 by lean-rules-docs-landing-latam -->

## ADD-ON SUBSYSTEM [EXISTS]

Feature sysexts are optional, per-board/per-OS `.raw` artifacts delivered
out-of-band from the base image. They extend `/usr` and `/opt` only
(`SYSEXT_LEVEL=1`, `VERSION_ID=12`) and are managed at runtime by the CeraUI
add-on manager.

**Descriptor format** (`manifests/schema/addon.schema.json`)

Each add-on ships a JSON descriptor baked into the image at
`/usr/share/ceralive/addons/<id>.json`. Required fields:

| Field | Description |
|-------|-------------|
| `id` | Lowercase alphanumeric + hyphens; unique per image |
| `version` | Semver `MAJOR.MINOR.PATCH` |
| `category` | `debug` / `display` / `media` / `network` / `other` |
| `payload.type` | `sysext` (only implemented type; `appfs` reserved) |
| `artifact.urlTemplate` | HTTPS URL with `{os_version}` placeholder |
| `artifact.sha256` | Lowercase hex SHA-256 of the `.raw` |
| `artifact.gpgSigRef` | Reference to the detached GPG signature |
| `artifact.sizeDownload` | Compressed `.raw` size in bytes |
| `artifact.sizeInstalled` | Installed size in bytes |
| `sysext.paths` | List of `/usr/…` or `/opt/…` paths the sysext provides |
| `deps` / `conflicts` | Optional add-on id arrays (uniqueItems) |

**Signing contract** [EXISTS]

Every `.raw` artifact is signed with the add-on keyring GPG key from `cert-work/`.
The signature is a detached `.sig` file co-located with the `.raw` on R2. CeraUI
verifies the GPG signature and the `sha256` field before activating any add-on.
The keyring is baked into the image at build time via `build-feature-sysext.sh`.

**Build a feature sysext** [EXISTS]

```bash
# Build a signed per-board/per-OS sysext .raw:
lib/build-feature-sysext.sh \
  --descriptor manifests/addons/<id>.sysext.conf \
  --board rock-5b-plus \
  --out dist/
# Output: dist/<id>-<board>-<os_version>.raw + dist/<id>-<board>-<os_version>.raw.sig
```

The builder reuses `lib/app-layer/sysext.sh` (extract → prune Platform/Runtime
libs → assert required binaries → squashfs). The exclusion contract
(`SYSEXT_EXCLUDE_NAMES`) prevents GPU/BSP userspace from leaking into add-on
artifacts.

**R2 delivery path**

```
addons/{os_version}/{board}/{feature}.raw
addons/{os_version}/{board}/{feature}.raw.sha256
addons/{os_version}/{board}/{feature}.raw.sig
```

`os_version` is the Debian `VERSION_ID` (e.g. `12` for bookworm). The
`{os_version}` placeholder in `artifact.urlTemplate` is substituted at download
time by the CeraUI add-on manager. `apt-worker` serves these keys (404 on a
missing object, never a 200-empty); see `apt-worker/AGENTS.md`.

**Publishing** [EXISTS]

`lib/upload-addons.sh` publishes a signed add-on to R2, mapping
`build-feature-sysext.sh`'s `<feature>-<board>-<os_version>.raw{,.sha256,.sig}`
onto the delivery path above. It REFUSES to upload an unsigned (or
unchecksummed) artifact, and pins per-file content-type so R2 stores what the
worker serves. CI mode reuses the `fetch-debs.sh` R2 pattern (`aws s3 cp`
+ `R2_ENDPOINT`); the `v2-ci.yml` `addon-publish` job proves the plan +
unsigned-refusal gate under `DRY_RUN` without secrets.

**sysext refresh protocol** — see [`docs/addon-sysext-refresh.md`](../addon-sysext-refresh.md)

Services SURVIVE `systemd-sysext refresh` but keep running the old binary. The
add-on manager must:
- **Update:** `systemd-sysext refresh` → `systemctl restart <addon>.service`
- **Disable:** `systemctl stop <addon>.service` → `systemd-sysext refresh`

Never report an add-on "updated" or "disabled" on the strength of the sysext call
alone.

**First-boot SSH hardening** [EXISTS]

`ceralive-ssh-firstboot.service` runs before `ssh.service` and `ssh.socket` on
every boot, and both SSH activation paths require it to succeed. Standalone
artifacts under `mkosi/runtime/`
(`ceralive-ssh-firstboot.{sh,service}`), installed by
`postinst-lib.sh::setup_ssh_firstboot` — NOT inlined in `mkosi.postinst.chroot`
(the drift gate's 950-line ceiling). Scope is locked (SC4): regenerate the baked
shared host keys into a per-device identity (persisted on `/data`, stable across
A/B) and apply the once-only password hardening on initial boot; the per-boot guard
then enforces `PermitRootLogin prohibit-password` and CI-key retention policy.
Persistent authorized-key stores are linked from `/data`; run-local CI keys survive
only an explicitly armed, one-use reboot and are otherwise purged before sshd.
The `ceralive` user ships password-locked (no default password); root retains
key-based recovery access. Full behaviour: [`docs/ssh-hardening.md`](../ssh-hardening.md).
For bench-only access, `CERALIVE_DEBUG_IMAGE=1` requires an externally supplied
encrypted `CERALIVE_DEBUG_PASSWORD_HASH`; it is rejected for normal builds and
must never be used for fleet artifacts.

**`ssh.service` systemd enablement is gated on `CERALIVE_DEBUG_IMAGE`
(`postinst-lib.sh::configure_ssh_enablement`, called from `configure_services`).**
Production images (`=0`/default) ship `ssh.service` **NOT enabled** (operator turns
SSH on from the CeraUI UI); debug images (`=1`) keep the historical
enabled-by-default behavior. The base layer installs `openssh-server`, whose Debian
postinst preset already enables `ssh.service`, so the production branch **actively
disables** `ssh.service`/`ssh.socket` — merely skipping the enable would leave the
base-layer preset enablement in place. `ceralive-ssh-firstboot.service` still hardens
SSH whenever it is eventually started, on both image kinds. Guards: `mkosi-image-contract.bats`
"production image leaves ssh.service NOT enabled" + "lab debug image enables
ssh.service by default".

**Both halves of that contract were silently untrue on a real build, for two
independent reasons — a SIGPIPE race and a first-boot preset** [EXISTS — fixed
2026-08-12]

A `rock-5b-plus --variant edge` production build failed the `[7/9]` gate on
`ssh.service is enabled but MUST be disabled-by-default`, while the SAME commit
produced a clean prebuilt-kernel image. Both defects below are invisible to the PR
gate, which is `DRY_RUN=1` and never runs the layer that configures services.

- **The disable was a no-op ~8% of the time.** `disable_service` probed with
  `systemctl list-unit-files "$svc" | grep -q "$svc"`. `grep -q` exits at its FIRST
  match and closes the pipe while systemctl is still writing its `1 unit files
  listed.` trailer; systemctl takes SIGPIPE, and under the modules' `set -o
  pipefail` the pipeline reports **141** for a unit that WAS found. The guard then
  logged `service ssh.service not present — nothing to disable`, openssh-server's
  own postinst `enable` survived, and the image shipped
  `multi-user.target.wants/ssh.service` + the `sshd.service` alias. Measured
  **23/300** against a real built arm64 rootfs — which is why it fired on one
  board's build and not another's from one commit, and why a single offline replay
  always passes. **This is the fourth instance of this footgun in this repo**
  (`deb_lists_path`, `verify-boot-artifacts.sh`, and the two static harnesses that
  build a source SET into a FILE rather than piping it). `unit_file_present()`
  captures the output in a command substitution — no early reader, so nothing can
  SIGPIPE the writer — and `disable_service` probes through it. The production
  branch then **asserts** the disable landed (`assert_ssh_not_enabled`, mirroring
  the parity predicate exactly) and `die`s otherwise: a silent miss otherwise ships
  an SSH-reachable production image that passes every other gate.
- **`find … | grep -q .` in `lib/parity-check.sh` is the same defect with a worse
  failure mode**, and it sits in the gate that caught the first one. `find` keeps
  traversing after the match it printed, so a SECOND match SIGPIPEs it and the
  condition reads FALSE — which on the ssh leg means `ssh_enabled=0`, i.e. a false
  **PASS** certifying an SSH-reachable production image. It measured 0/400 today
  (with exactly one match, `find` never writes again and never sees EPIPE), so this
  is latent rather than active — fixed anyway, via `find_first`, which captures in
  a substitution and stops `find` itself with `-quit`.
- **Even a landed disable does not survive first boot.** `/etc/machine-id` ships
  holding `uninitialized`, so every freshly flashed board is a systemd FIRST BOOT
  and PID 1 runs `preset-all` — the same mechanism `suppress_unusable_boot_units`
  already documents. Debian's default verdict is `enable`, and mkosi additionally
  ships `/usr/lib/systemd/system-preset/80-mkosi-ssh.preset` holding `enable
  ssh.socket` (confirmed present in the built rootfs), so the operator's very first
  power-on re-enabled what the build had disabled. `write_ssh_preset` emits
  `00-ceralive-ssh.preset` — sorting AHEAD of mkosi's — restating the build-time
  verdict as the FIRST matching preset line, `disable`/`disable` on production and
  `enable ssh.service` + `disable ssh.socket` on debug. **A mask would also survive
  and is the WRONG tool here**: `systemctl enable` refuses to act on a masked unit,
  which would take away the operator's CeraUI SSH toggle — the entire reason SSH
  ships disabled rather than absent. (It would also fail the parity check, whose
  predicate is any `/etc/systemd/system` symlink named `ssh.service`, and a mask is
  exactly that symlink pointing at `/dev/null`.)

Guard: `tests/ssh-enablement-contract.test.sh` (23 checks) — the static no-pipe
contract on the real function bodies, the preset ordering against mkosi's filename,
and a runtime leg driving the REAL shipped `disable_service` 50× against a stub
systemctl whose oversized trailer makes the old form's SIGPIPE deterministic, with a
**non-vacuity leg proving the pre-fix piped probe silently skips the disable under
that identical stub**, plus the fail-closed leg (a planted surviving enable symlink
must abort the build).

**Still carrying the same pattern, deliberately out of scope here and worth a
follow-up:** `ceralive-healthcheck.sh` (`ip -o link show up | grep -v ' lo:' |
grep -q 'state UP'` — a false negative reports no link up, which feeds the RAUC
health verdict), `ceralive-provision.sh` (a false negative spuriously starts the
setup AP), `ceralive-hdmirx-edid.sh`, and `build-feature-sysext.sh`'s
`gpg --list-secret-keys | grep -q '^sec'`. Each is a producer that keeps writing
after the matched line, under `pipefail`, with the failure silently read as "no".

**`Before=ssh.socket` guards MUST be `DefaultDependencies=no` AND
`After=sysinit.target`.** Both `ceralive-ssh-firstboot.service` and
`ceralive-ci-uart-bootstrap.service` are `Before=ssh.socket`. `ssh.socket` is
ordered `Before=sockets.target` (early boot, before `basic.target`), so a guard
that inherits the implicit `After=basic.target` closes an `ssh.socket → guard →
basic.target → sockets.target → ssh.socket` ordering cycle — systemd deletes
`ssh.socket`'s start job and SSH never starts, on every boot (proof-10 UART boot
log, 2026-07-15). `DefaultDependencies=no` breaks that, but it ALSO drops the
implicit `After=sysinit.target`; proof-11 (2026-07-15) then showed
`ceralive-ssh-firstboot` racing ahead of `systemd-sysusers`/`systemd-tmpfiles`/
udev and FAILING under `set -euo pipefail` (host-key gen, authorized-key chowns,
`sshd -t`), taking ssh.service/ssh.socket down with "Dependency failed" — with
**zero** ordering cycles. So each guard must ALSO re-add `After=sysinit.target`
explicitly (the SAFE half of the default deps; `sysinit.target` is ordered before
`sockets.target`, so it never re-closes the ssh.socket loop). NEVER re-add
`After=basic.target`. The same cycle trap (but NOT the sysinit issue) hit
`ceralive-migrate-data.service`, which seeds the `/data` skeleton the
`/var/log`+`/opt/ceralive` bind mounts shadow: it must be `Before=local-fs.target`
(never `After=`) with `DefaultDependencies=no`, and must NOT gain
`After=sysinit.target` (sysinit.target is After=local-fs.target — that would
cycle); it runs as root against `/data`+rootfs only, so it needs no sysinit-phase
ordering. `ConditionKernelCommandLine`/`ConditionPathExists` do NOT remove a
unit's ordering edges — systemd wires them at transaction-build time regardless of
the condition. Offline guard: `tests/systemd-ordering-cycle.test.sh` — static
contract + `systemd-analyze verify` for zero cycles AND an ordering probe that
proves each guard is transitively after `systemd-sysusers`/`systemd-tmpfiles`
(a cycle-only check would miss the proof-11 gap). Wired into `run-tests`.

**RK3588 CI-UART bootstrap owns the LIVE console `/dev/ttyFIQ0`, NOT `/dev/ttyS2`.**
On RK3588 the Rockchip vendor kernel's FIQ debugger claims physical UART2 once Linux
boots and exposes it as `/dev/ttyFIQ0` — systemd spawns `serial-getty@ttyFIQ0.service`
and there is **no `/dev/ttyS2` device node at runtime**. So
`ceralive-ci-uart-bootstrap.service` sets `TTYPath=/dev/ttyFIQ0` (was `/dev/ttyS2`,
which made its `StandardInput=tty` setup fail instantly on real Rock 5B+ hardware — no
handshake, no run-local SSH key installed), and the CI harness
`ci/uart-provision-ssh.sh` masks `serial-getty@ttyFIQ0.service` over the transient
kernel cmdline (`systemd.mask=serial-getty@ttyFIQ0.service`) so the real getty cannot
contend for the port (masking `serial-getty@ttyS2.service` was a no-op — that unit
never exists). This is DISTINCT from the family `serial_console: ttyS2:1500000`, which
stays `ttyS2`: that is the raw UART2 U-Boot/early-kernel `console=ttyS2,1500000` arg,
correct because the bootloader/early kernel drive UART2 directly BEFORE the FIQ
debugger claims it (hence the UART helper's `=>` prompt interaction works). Do NOT
rename `serial_console` to `ttyFIQ0` — that would break the early/bootloader console.
The entire CI-UART path is RK3588-only by construction (`TTYPath` is a hardcoded
literal, not templated; x86 uses `ttyS0` and never runs this gate). Offline guard:
`tests/uart-console-path.test.sh` (bootstrap `TTYPath` + getty mask both target
`ttyFIQ0`, the two agree, and `serial_console` stays the raw-UART2 `ttyS2` early
console). Wired into `run-tests`.

**CI-UART bootstrap `stty` is tty-class-aware — the FIQ tty rejects the baud
ioctl.** Once the console fix above got the bootstrap to actually run on
`/dev/ttyFIQ0`, `ceralive-ci-uart-bootstrap.sh` aborted at `stty 1500000 sane -echo
<&0` under `set -euo pipefail`, BEFORE printing `CERALIVE_UART_BOOTSTRAP_READY`
(real Rock 5B+ regression, 2026-07-19; empirically reproduced — same-line-rate
`stty` on the FIQ tty returns `unable to perform all requested operations`). The FIQ
debugger is a **software** console over the debug UART whose line rate is FIXED by
the kernel `console=ttyS2,1500000` arg, so its baud is not settable and the channel
already works by default (every boot message reaches the host over it). The fix
(`configure_bootstrap_tty()`) is **tty-class-aware**: on a `ttyFIQ*` tty it drops
echo best-effort and NEVER fails (logs `CERALIVE_UART_BOOTSTRAP_INFO
fiq-tty-stty-skipped`); on a real UART (a future `ttyS` board, or x86 `ttyS0`) it
keeps the full `stty 1500000 sane -echo <&0 || fail` — deliberately NOT a blanket
`|| true`, so a genuine mis-provision on a settable-baud board is surfaced, not
masked. Host-side `ci/uart-provision-ssh.sh` still `stty`s the CI runner's USB
adapter at 1500000 (that adapter DOES honor it — unchanged). Offline guard:
`tests/uart-bootstrap-tty.test.sh` (exercises the shipped function against stubbed
FIQ + real-UART ttys: FIQ tolerant even when stty fully fails, real UART fatal on a
baud failure) + a co-located static signature in `uart-console-path.test.sh`. Wired
into `run-tests`.

**`ceralive-ssh-firstboot.sh` MUST create `/run/sshd` before its `sshd -t`.** The
guard's last step validates the sshd config with `sshd -t`, which refuses to run
without the privilege-separation dir `/run/sshd` (`Missing privilege separation
directory: /run/sshd`, exit 255). On a fresh boot that dir does not exist yet:
nothing ships a `tmpfiles.d` entry for it, and its only creator is `ssh.service`'s
`RuntimeDirectory=sshd` — which runs AFTER this `Before=ssh.service` guard. Without
pre-creating it, `sshd -t` exits 255, `set -euo pipefail` fails the unit, and both
`ssh.service` (LAN sshd on :22) and `ssh.socket` DEPEND-fail via `RequiredBy=`,
closing port 22 on EVERY boot with **zero** ordering cycles and an otherwise-healthy
system (proof-13 real-HW UART, 2026-07-16). This is a runtime script failure, NOT a
dependency-graph defect — `systemd-ordering-cycle.test.sh` cannot see it. The
dedicated offline guard is `tests/ssh-firstboot-privsep.test.sh` (static: the
`/run/sshd` creation precedes `sshd -t`; runtime: the real script survives an
empty-`/run` first boot in a rootless namespace). Wired into `run-tests`.

**Deterministic first-boot hostname** [EXISTS]

`ceralive-hostname.service` asks the running Avahi daemon to publish candidates
in the exact sequence `ceralive`, `ceralive2`, `ceralive3`, ... and accepts a
candidate only after Avahi repeatedly reports `RUNNING` with that exact name.
Avahi's automatic hyphenated collision name is treated only as a conflict signal;
it is never persisted. A real local `flock` serializes starts, while Avahi's mDNS
claim protocol arbitrates simultaneous devices. The selected index lives at
`/data/ceralive/host_index` through the `/etc/ceralive/host_index` symlink; the
local service lock is runtime-only state under `/run`.

The unit is ordered `After=`/`Wants=NetworkManager.service` and
`avahi-daemon.service`, never `network-online.target`. A link is not a boot
precondition. With no publishable LAN address — including when the setup AP's own
`192.168.42.1` is the only address — allocation commits the current deterministic
candidate to the runtime hostname, `/etc/hostname`, `/etc/hosts`, and the persisted
index, reports it as provisional, and exits successfully without asking Avahi to
claim it. A later reconciliation run reuses that exact index; only a proven live
owner advances it. This keeps the unit successful on a normal offline boot while
preserving deterministic collision arbitration after connectivity appears.

Offline guards: `tests/systemd-ordering-cycle.test.sh` statically and dynamically
proves the NetworkManager ordering without reintroducing a wait-online edge;
`runtime-services.bats` proves fresh offline persistence, setup-AP exclusion, later
same-index reconciliation, and absence of first-party `network-online.target`
dependencies.

Each service attempt has a 120-second global claim budget, 3-second command
timeouts, and a 10-second local-lock wait. systemd caps the attempt at 150 seconds
and retries a failed attempt after 5 seconds. Missing/malformed Avahi state,
missing tooling, and failure to establish exact ownership while a publishable
collision domain exists all fail closed; there is no random suffix or DNS-only
availability fallback. Absence of such a domain is a successful provisional state,
not an ownership failure. The isolated provisioning AP address is not a claimable
LAN identity; Ethernet IPv4 link-local remains eligible. A successful reconciliation
non-blockingly requeues identity consumers while the hostname unit remains active.
On every restart the service reapplies the persisted identity to
the runtime hostname, `/etc/hostname`, `/etc/hosts`, and Avahi before CeraUI, TLS
certificate creation, or hawkBit enrollment may run. A separate 30-second
reconciliation timer checks strict Avahi and local identity state. Aligned and
`REGISTERING` snapshots cause no allocation or service churn; explicit conflict
or divergence reruns the bounded deterministic claim and restarts identity
consumers only after a successful commit. TLS validates the actual certificate
SAN and key pair, replacing it if the committed hostname advances. CI exercises
the production script against two real Avahi daemons in private D-Bus/network
namespaces for simultaneous boot and late-LAN-merge races. Operator behavior and
diagnostics are documented in [`docs/FIRST-BOOT.md`](../FIRST-BOOT.md) §4.

**Baked-hostname `AVAHI_ERR_NO_CHANGE` fix + graceful degradation (2026-07-19).**
After the former `network-online.target` ordering fix, the claim STILL failed on
real Rock 5B+ hardware — for a different, empirically-confirmed reason. The image
bakes `/etc/hostname=ceralive` (`configure_networking`), so the running Avahi daemon
already publishes `ceralive` at boot. `ceralive-set-hostname` (allocate, index 1)
then calls `avahi-set-host-name ceralive`, which returns non-zero
(`AVAHI_ERR_NO_CHANGE`: a no-op set to the daemon's current name in a non-collision
state — reproduced live: same-name set → exit 1, different-name → exit 0). The old
`claim_candidate` treated that non-zero as a lost claim → `die` → and every hard
`Requires=` consumer cascaded to "Dependency failed", killing the whole appliance
(`ceralive.service`, `nginx`, TLS, hawkBit) on first boot. Three fixes, all in
`postinst-lib.sh::setup_hostname_service` unless noted:

- **Root cause** — `claim_candidate` now treats a failed `avahi-set-host-name`
  whose daemon is already `RUNNING` + publishing the exact candidate as SUCCESS
  ("we already own it"); any other set failure retries the SAME candidate within
  the deadline instead of aborting or wrongly advancing the deterministic index.
- **Avahi readiness** — a bounded, best-effort `wait_for_avahi_ready` polls
  `GetState` for a query-ready daemon (REGISTERING/RUNNING) before the first claim,
  since `After=avahi-daemon.service` only guarantees the process started.
- **Graceful degradation** — the appliance consumers now `Wants=` (NOT `Requires=`)
  `ceralive-hostname.service`: `ceralive.service` (drop-in `05-hostname-identity.conf`),
  `ceralive-tls-firstboot.service`, and `ceralive-hawkbit-provision.service`. A failed
  claim no longer cascades; the device boots on the baked default hostname
  (degraded-but-functional), `After=` keeps ordering, the unit's own
  `Restart=on-failure` + the 30s reconcile timer keep retrying, and `ExecStartPost`
  restarts consumers once a claim succeeds. Only `ceralive-hostname-reconcile.service`
  keeps a hard `Requires=` (its failure is harmless — the timer refires). This
  supersedes the "every `Requires=` consumer cascades" description above.

Guards: `runtime-services.bats` "hostname:" gains an `AVAHI_ERR_NO_CHANGE`-accepted test, a
readiness-wait test, and `Wants=` (not `Requires=`) graceful-degradation assertions;
`real-avahi-hostname-contract.sh` gains a real-avahi PREOWNED scenario (daemon seeded
`ceralive`) proving the fixed allocator claims it instead of dying — the exact CI
blind spot (prior seeds never equalled the first candidate).

**Build concurrency** [EXISTS]

The orchestrator holds a per-board `flock` under `mkosi/.staging/.locks/`
before touching staging, cache, or mkosi output. Different boards remain safe to
build in parallel. A second build of the same board waits for up to one hour by
default; set `CERALIVE_BUILD_LOCK_TIMEOUT=0` for fail-fast behavior or another
non-negative number of seconds for a bounded wait. This also prevents a CI
dry-run from deleting the staging tree of an active hardware image build.

**Verified `.deb` download cache — opt-out, bounded, and NOT protected by the
build lock above** [EXISTS]

`lib/fetch/debcache.sh` gives all three verified fetch families (BSP, RK3588
userspace, first-party) a persistent content-addressed cache at
`mkosi/.staging/.debcache/`, keyed on `<package>_<version>_<arch>.deb` plus
the artifact's expected SHA-256. A second real fetch of the same plan performs
**zero `.deb` payload downloads** — proven end to end on the userspace family
(6 pinned upstream packages, 6 downloads then 0, every one re-verified against
`rk3588-userspace-deb-versions.txt`).

- **Reuse can never weaken verification, and that is the whole safety argument.**
  Every family already holds the expected SHA-256 before it downloads — from the
  `gpgv`-verified Packages index (both BSP transports, both first-party
  transports) or from the committed pin file (userspace) — so a HIT is checked
  against exactly the hash the network path would have been checked against. An
  entry whose hash no longer matches is **deleted**, not skipped: it is either
  corrupt on disk or the archive replaced the bytes under the same filename, and
  keeping it would re-fail every future build.
- **Only final `.deb` payloads are cached.** `InRelease`, `Release`,
  `Packages.gz`, the apt lists and the GPG keyring are DELIBERATELY never cached
  — that is the rotating trust material whose entire job is to be fresh, and a
  stale index is how a cache becomes a downgrade surface. So the "0 downloads"
  claim is about payloads; apt/index metadata is still fetched every run.
- **Writes go through ONE chokepoint.** `publish_staged_deb` (`fetch/pool.sh`) is
  the single atomic-rename step all three families funnel through, and it is
  reached only after that family's SHA + Debian control identity checks. Storing
  there makes "cached bytes are verified bytes" a property of the call graph
  rather than a per-family promise. Do not add a second store site.
- **The per-board build lock does NOT protect this.** `acquire_board_lock` is
  keyed on one board and different boards are explicitly allowed to build in
  parallel, so two concurrent builds are two concurrent writers of the same
  entry. The cache therefore owns a **per-cache-key `flock`** under
  `.debcache/.locks/`, mirroring the `.staging/.locks/` idiom rather than reusing
  that lock.
- **The reader holds its key lock across the WHOLE hit sequence** — existence
  check, SHA re-verification, copy-out. Releasing after the hash check is the bug
  that looks like working code: eviction would then unlink the entry the reader
  had just verified and was about to read. **Eviction takes each victim's own key
  lock with `flock -n` BEFORE unlinking and SKIPS a locked victim.** Skipping
  rather than waiting is what keeps the ordering trivial — no path ever holds two
  key locks, so reader-vs-evictor cannot deadlock in either direction.
- **Bounded:** `CERALIVE_DEBCACHE_MAX_BYTES` (default 4 GiB), LRU by mtime, and a
  reuse refreshes that mtime so "least recently used" is genuinely that and not
  "oldest download". `CERALIVE_DEBCACHE=0` disables lookup, store and eviction
  and creates no directory at all. `CERALIVE_DEBCACHE_DIR` relocates it.
- **Every failure is non-fatal.** An unwritable directory, a lock timeout or a
  failed copy degrades to "download it" — the same behaviour as the disable flag.
- **`DRY_RUN` is byte-unchanged.** The gate excludes DRY_RUN centrally rather than
  at each call site, so a plan-only run downloads nothing, mutates nothing, and
  emits no cache line; the resolved plan is identical to the pre-cache one
  (paired capture, 44 lines).
- **It survives a per-board staging wipe** because it is a SIBLING of the
  per-board `.staging/<board>` dirs, and the existing `/.staging/` ignore rule
  already covers it. Do not move it under a board directory.

Guards: `tests/debcache.test.sh` (25 legs — static contract, unit
hit/miss/corrupt/stale/eviction/LRU-refresh, TWO real concurrent reader-vs-eviction
legs with a live second process holding a real `flock`, and integration legs
driving the shipped userspace fetcher over `file://` pins that count payload
downloads). Mutation-verified: dropping the victim lock, dropping the SHA
re-check, leaving a corrupt entry in place, unwiring a family, and releasing the
reader's lock early each fail the suite. Both concurrency legs are needed and
neither is duplicate coverage — the first slows the reader inside verification,
the second slows the step between verification and the copy, and only the second
detects an early unlock.

**The builder images' OWN apt traffic is cache-mounted, and TWO things silently
defeat that — one of them ships in every Debian base image** [EXISTS]

`ci/Dockerfile` and `ci/Dockerfile.kernel` mount BuildKit caches over
`/var/cache/apt` and `/var/lib/apt/lists`, `sharing=locked` because
`lib/build-all.sh` builds boards concurrently and two apt transactions writing one
archive directory is a corrupt partial download rather than a slow one. Measured
on this repo's own Dockerfiles, cold vs a rebuild whose apt layer genuinely
re-executed:

| | `ci/Dockerfile` | `ci/Dockerfile.kernel` |
|---|---|---|
| cold | `Need to get 129 MB of archives`, 114 package `Get:` | `Need to get 136 MB/184 MB`, 109 package `Get:` |
| warm | `Need to get 0 B/129 MB`, **0** package `Get:` | `Need to get 0 B/184 MB`, **0** package `Get:` |
| index | 3 × `Get:` -> 3 × `Hit:` | 3 × `Hit:` both runs |

Both files mount the SAME cache, so they share it: the kernel builder's first cold
build already found ~48 MB of its closure present from the mkosi builder's run.

- **`docker-clean` is the one that ships in every Debian image.**
  `/etc/apt/apt.conf.d/docker-clean` carries a `DPkg::Post-Invoke` that
  `rm -f`s `/var/cache/apt/archives/*.deb` at the end of the very `apt-get` that
  filled the mount. Left in place the cache is dutifully populated and then
  emptied on every single build: green, real mount, permanent zero hit rate. It is
  moved aside for the transaction and moved BACK, so the finished builder image's
  `/etc/apt` is byte-identical to its base's (verified by `ls` diff against the
  pinned base) and no `99ceralive-*` drop-in ever ships.
- **`rm -rf /var/lib/apt/lists/*` must not end an apt layer.** Under a cache mount
  that path IS the cache, so the cleanup deletes the index it exists to leave
  behind. The size argument does not survive either — a cache-mounted directory
  contributes nothing to the image layer at all.
- **`docker build --no-cache` is NOT how to test this.** It resets cache mounts
  along with the layer cache, so the second build re-downloads everything and the
  cache looks broken. That is what the first measurement of this change reported
  before the confound was isolated. Prune only the layer cache —
  `docker builder prune -af --filter=type=regular` — and the layer re-executes
  against a warm mount.

**`RUN --mount` and BuildKit are ONE change, not two.** The legacy `docker build`
builder does not ignore an unknown `--mount` flag, it refuses to PARSE the
Dockerfile, so a build site that forgets `DOCKER_BUILDKIT=1` fails inside a file
the operator did not write. `lib/common.sh::container_image_build` is therefore the
single entry point both builder-image build sites go through — it sets
`DOCKER_BUILDKIT=1` for docker, sets nothing for podman (buildah parses
`RUN --mount` natively), and refuses a runtime below the floor where the cache
mount TYPE exists (docker 23 / podman 4) rather than letting it fail obscurely. An
unparsable version string WARNS and proceeds: the build then fails on its own with
the Dockerfile line in hand, which beats a guess. A bare `"${runtime}" build` is
absence-guarded.

Guards: `tests/build-cache-overhaul.bats` (27 cases — the mounts and their
`sharing=locked`, the docker-clean round trip, the absent lists-cleanup, the
untouched digest pins, both build sites, the no-bare-build rule, and the version
floor's refusal).

**The pinned kernel source has a persistent bare mirror, and its flock is a
CORRECTNESS fix rather than a speedup** [EXISTS]

`mkosi/cache/kernel-src.git` (`CERALIVE_REL_KERNEL_SRC_MIRROR_DIR`) is an optional
bare mirror of `kernel_source.git_url`. When it already carries the pinned commit,
`fetch_pinned_tree_once` materialises `/src/linux` with a local
`git clone --shared` off the read-only mount — no network, and no object copy
either, because the clone records an alternates entry.

- **The flock prevents real corruption.** `lib/build-all.sh` builds boards
  CONCURRENTLY and every board resolves the same kernel pin, so two unlocked
  `git fetch`es write one object store — which git does not defend against and
  which leaves a mirror that fails every later build until someone deletes it by
  hand. The lock is per MIRROR (the resource), never per board or per caller: a
  lock name carrying the caller's identity excludes nothing, which is the exact
  bug `tests/manifest-helpers.bash::serialize` already shipped once.
- **Fetch under the lock, read afterwards.** The lock is released before the
  builder container starts and the mirror is mounted `:ro`, so a concurrent fetch
  can only ADD objects while this build reads. `gc.auto=0` is set at creation for
  the other half: an automatic gc is the one git operation that would DELETE
  objects a concurrent reader is using.
- **`auto` is the default and it never CREATES a mirror.** `mkosi/cache` is on the
  CI cleanup allowlist, so an ephemeral runner would pay a full mirror clone per
  job and never read it back — a guaranteed loss. `CERALIVE_KERNEL_SRC_MIRROR=1`
  opts a long-lived builder in, once; `0` disables it. Any other value is REFUSED,
  not read as "off".
- **A mirror that lacks the pin is a MISS, never a different build.** The checkout
  falls back to the network and the `HEAD == commit` assertion still runs, so the
  mirror can never change WHAT is built — only where the bytes came from. Only the
  KERNEL SOURCE gets one; the patch series and the config are small and stay fresh.
- **Every knob is read AT CALL TIME.** Latching `CERALIVE_KERNEL_SRC_MIRROR` into a
  file-scope variable at source time gives two spellings that agree only until
  something sets the env var after sourcing — which made three of this suite's own
  mode assertions pass vacuously before it was fixed.
- **The mirror needs `safe.directory`.** It is host-user-owned and git in the
  container runs as root, so it joins the bench patch clone in the generated
  `GIT_CONFIG_GLOBAL` gitconfig; git honours `safe.directory` only from system or
  global config, never from `-c`.

Guard: `tests/kernel-src-mirror.test.sh` (26 assertions). Its technique is what
makes the result unfakeable: every reuse leg builds the mirror, **destroys the
upstream**, and then requires the checkout to succeed — with a non-vacuity leg
requiring the identical checkout WITHOUT the mirror to fail. It also drives a real
`flock` holder (prepare blocks ~1.7 s behind a 2 s holder), a real concurrent
prepare pair left `git fsck`-clean, and the timeout/miss/mode paths.

**The mkosi package cache is split by PRIVILEGE DOMAIN, so a container and a
--native build stop invalidating each other** [EXISTS]

`--cache-directory` resolves to `cache/${BOARD_ID}/${domain}` where the domain is
`container` or `native` (`lib/paths.sh::ceralive_mkosi_cache_domain`). mkosi 26
refuses to reuse a cache tree whose owner uid is not its own and, with `--force`,
DELETES it — so one shared leaf meant alternating the two build modes threw away
the whole base layer every time, reported as nothing at all because "mkosi rebuilt
the base" looks identical to "the base was stale".

- **`MKOSI_NATIVE` alone is the discriminator.** docker and podman both run mkosi
  as uid 0 in a privileged container, so they are one domain, not two.
- **Both leaves sit under the SAME per-board root** `release.yml` saves and
  restores, so nothing about the CI cache changes and
  `ci/check-canonical-paths.sh --cache-dir` still compares against
  `board_mkosi_cache_dir`. `emit-canonical-paths.sh` gained
  `board_mkosi_cache_dir_{container,native}` beside it.
- **`assert_cache_privilege_domain` STAYS.** Separate leaves make a collision
  unlikely, not impossible: a `sudo ./build --native` owns the native leaf as root
  and the next unprivileged native build must still be told why, with the command
  that repairs it.

**An opt-in apt proxy (`CERALIVE_APT_PROXY`), http-only on purpose** [EXISTS]

Unset it is a NO-OP down to the token count — `apt_isolated_opts` emits the same
12 tokens it always did and the Dockerfiles' `APT_PROXY` build arg expands to
empty. Set, it adds exactly one `-o Acquire::http::Proxy=` pair and is threaded
into both builder images as `--build-arg APT_PROXY=`, written and removed inside
the single RUN that uses it so a host-local URL (which may carry credentials)
never survives into a shared layer.

- **https is never proxied.** `apt.ceralive.tv` is https WITH AN mTLS CLIENT
  CERTIFICATE: a cache can do nothing with that payload and the only thing a proxy
  adds is a handshake that can fail for reasons unrelated to apt. The win is the
  plain-http Debian/Armbian archive traffic, which is also the bulk of the bytes.
- **A proxy cannot weaken verification, and no proxy option may try.** Every family
  verifies AFTER acquisition — `gpgv` over `InRelease`, then the SHA-256 that
  signed plaintext declares, or a committed pin's hash — so proxied bytes are
  checked against exactly the expectations origin bytes would be.
  `tests/apt-lib.test.sh` asserts the emitted set contains no
  `AllowInsecureRepositories` / `AllowUnauthenticated` / `Check-Valid-Until=false`.
- Operator quickstart (apt-cacher-ng, local or LAN): [`README.md`](../../README.md) →
  "Builder-Image apt Cache, Kernel-Source Mirror and the Optional apt Proxy".

**First-boot WiFi provisioning portal** [PARTIAL]

`ceralive-provision.service` brings up a self-hosted WPA2 setup hotspot AND a
captive portal so a headless, never-configured device can be handed WiFi
credentials with no screen or keyboard. Standalone artifacts under
`mkosi/runtime/` (`ceralive-provision.{sh,service}` plus the captive portal
`ceralive-portal.{sh,socket,@.service}`), installed by
`postinst-lib.sh::setup_provisioning` — NOT inlined in `mkosi.postinst.chroot`
(drift-gate 950-line ceiling; `setup_provisioning` is in the gate's
`CONSOLIDATED_FUNCS`). Full end-to-end flow:
[`docs/wifi-provisioning.md`](../wifi-provisioning.md).

- **Trigger** (runtime decision, not a static unit Condition): the AP starts IFF
  there are **no stored (non-AP) NM WiFi profiles** on `/data` **AND** no link-up
  connectivity appears within a **60-90s boot grace window** (default 75s). Either
  a stored profile or any connectivity (NM `full`/`limited`/`portal`, or a default
  route) suppresses it. A `/data/ceralive/provision/force-portal` flag
  (factory-reset hook) re-triggers it even when profiles exist.
- **EC4 — OTA-safe:** a RAUC update that preserves `/data` keeps the WiFi profiles,
  so the portal correctly does **not** start after an update.
- **Conflict safety:** the AP only runs when there is zero connectivity, so srtla
  bonding is impossible anyway and nothing contends for the uplink. (Until this was
  retired, the SRTLA NM dispatcher was the other half of this argument; it no longer
  exists — see "SRTLA source-policy routing is RETIRED" below.)
- **AP mode:** NetworkManager-native (`802-11-wireless.mode ap` + `ipv4.method
  shared`) — no extra packages (NM drives wpa_supplicant + its internal dnsmasq;
  `network-manager`/`dnsmasq`/`wpasupplicant` already ship). `hostapd` stays in the
  image only as an evidence-gated fallback. SSID `CeraLive-Setup-<short-id>`
  (machine-id-derived setup identifier), passphrase `ceralive-setup`
  (documented default), gateway `192.168.42.1/24`. **HW caveat:** AP mode also
  requires the onboard wlan driver to support it (RK3588 chip dependent) — to be
  validated on hardware, hence `[PARTIAL]`.
- **Regulatory DB (`wireless-regdb`) is an EXPLICIT `shared.list` entry.** WiFi in
  ANY mode (client or the AP above) needs `/lib/firmware/regulatory.db` (+ `.p7s`),
  which the kernel `cfg80211` subsystem loads at boot to establish a usable
  regulatory domain. It ships in Debian's `wireless-regdb` package — the Linux
  wireless project's regulatory database, NOT chip firmware, so it is **not** part
  of the RK3588 `armbian-firmware` bundle (unlike `rtl8852be-firmware`; see
  `rk3588.delta.list`). It is only `wpasupplicant`'s `Recommends:`, so the runtime
  layer's `apt-get install --no-install-recommends` (runtime/mkosi.postinst.chroot)
  never pulls it transitively — it MUST be named in `shared.list` explicitly. Absent
  it, every boot logs `platform regulatory.0: Direct firmware load for regulatory.db
  failed with error -2` / `cfg80211: failed to load regulatory.db` and NetworkManager
  reports "No WiFi interfaces found" even with a working driver (real-HW UART,
  2026-07-16; the RTL8852BE `rtw89_8852be` chip enumerates + trains PCIe fine — the
  missing DB is a distinct gap). Guard: `mkosi-image-contract.bats` "wireless-regdb is installed
  so cfg80211 loads regulatory.db".
- **Captive portal (Task 14):** while the AP is up, `ceralive-provision` stops the
  CeraUI backend (`ceralive.service`) to free port 80 and starts
  `ceralive-portal.socket` — a systemd socket-activated (`Accept=yes`) **bash** HTTP
  handler on `192.168.42.1:80`. It is the lightest server already in the image (no
  busybox/python3/socat/nc ship — socat/netcat were moved to the debug add-on), and is
  a standalone plain-HTML page, NOT a CeraUI integration (SC2). A
  `address=/#/192.168.42.1` drop-in in `dnsmasq-shared.d` wildcard-captures DNS so any
  hostname pops the operator's captive-portal sign-in. The form's SSID list is the
  pre-AP scan cache (a single radio can't scan in AP mode) plus free-text entry.
- **Credential handoff:** the form POST writes the user's network via
  `nmcli connection add` (credentials land ONLY in NM's `/data`-backed store — never a
  file), answers the browser, then runs a DETACHED `ceralive-provision connect <con>`
  worker (via `systemd-run`, so it outlives the per-connection service that the AP
  teardown kills). The worker drops the AP, joins as a client under a bounded
  `nmcli --wait` + `timeout`, and on a wrong passphrase or hard timeout deletes the bad
  profile, writes a `last-error` marker the portal shows, and re-arms the AP for a
  retry — the device is never left headless-dead.
- **Port-80 coexistence:** the portal owns `192.168.42.1:80` only during provisioning;
  CeraUI's backend (binds `[80, 8080, 81]`, tries 80 first) is stopped for the window
  and restarted on teardown so it re-binds 80 on the new uplink IP. The Task-15 nginx
  TLS front on **443** is unaffected (its `127.0.0.1:80` upstream is just briefly down
  while there is no uplink — and thus no 443 client).
- **Teardown — MAC6 end-state (all four, sandbox-verified):** (a) AP profile deleted;
  (b) device joined the target network; (c) portal unreachable (`ceralive-portal.socket`
  stopped, port 80 freed); (d) CeraUI reachable on the new IP (`ceralive.service`
  restarted). A successful `connect` runs the teardown **keeping** the freshly-joined
  client link; the out-of-band `ceralive-provision teardown` verb (or a
  `/data/ceralive/provision/teardown-requested` flag) also releases `wlan0` and clears
  the portal-active + force flags. Plain `systemctl stop` (ExecStop) is link-down +
  portal-down only and RETAINS the AP profile + flags (shutdown must not disarm a
  pending factory reset). Offline proof harness:
  `tests/provision-portal.test.sh` (gated in `postinst-wiring.bats`).

**CeraUI TLS front — nginx on 443 (Task 15, SC3)** [EXISTS]

The device serves the CeraUI control plane over HTTPS on **443** via `nginx-light`,
which terminates TLS and reverse-proxies to the CeraUI backend on `127.0.0.1:80`.
Standalone artifacts under `mkosi/runtime/`
(`ceralive-tls.nginx.conf`, `ceralive-tls-firstboot.{sh,service}`,
`ceralive-tls-nginx.dropin.conf`), installed by
`postinst-lib.sh::setup_tls_proxy` — NOT inlined in `mkosi.postinst.chroot`
(drift-gate 950-line ceiling; `setup_tls_proxy` is wired into BOTH the postinst
executor and `services.sh`, like `setup_provisioning`).

- **SC3 — port 80 is KEPT.** nginx binds **443 only**; the backend keeps serving
  port 80 directly. `setup_tls_proxy` removes the stock nginx `sites-enabled/default`
  (which would otherwise grab :80). There is deliberately **no** 80→443 redirect —
  both ports are a real, supported entry point.
- **EC6 — WebSocket upgrade.** The proxy site sets
  `proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header
  Connection "upgrade";` so CeraUI's same-origin telemetry/RPC WebSocket survives the
  proxy (Task 1 already maps `https:`→`wss:` in the frontend; no UI change needed).
- **Self-signed cert (no ACME/mTLS).** `ceralive-tls-firstboot.service` keeps a
  per-device self-signed key+cert in `/data/ceralive/tls/` across reboots and A/B
  OTA slot swaps. It validates the real SAN and key pair on each run, remaining
  byte-stable while the hostname is unchanged and replacing the pair after a
  deterministic hostname advance. CN/SAN = `<hostname>.local` + the device IPv4.
  **Browser caveat (honest):** the first visit
  to `https://<device>.local` shows a "self-signed / not secure" warning — expected
  for a headless LAN appliance with no public DNS and no ACME path (SC3 forbids
  ACME/Let's Encrypt and mTLS). `openssl` is pinned in `shared.list` for the cert.
- **Ordering.** `ceralive-tls-firstboot.service` runs `Before=nginx.service` (and
  after the unique-hostname service); a `nginx.service.d/10-ceralive-tls.conf`
  drop-in adds `Requires=`/`After=` so nginx never starts without a cert.
- **Healthcheck.** `ceralive-healthcheck.sh` probes BOTH `http://127.0.0.1/status`
  (:80) and `https://127.0.0.1/status` (:443, `-k`); this is **non-fatal** (WARN
  only, like the mDNS probe) — a UI/TLS hiccup must not roll back a slot whose
  streaming stack is healthy and whose port 80 still serves.
- **Coexistence with provisioning (Task 11):** the AP-mode portal uses port 80;
  nginx only binds 443, so there is no conflict.
- **Size:** ~+3–4 MB; see [`docs/size-notes.md §5`](../size-notes.md).

