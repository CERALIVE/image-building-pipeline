# Staged OS and kernel slot activation [PARTIAL]

`activate-installed=false` leaves a successful RAUC OS installation in the other
rootfs without selecting it for the next boot. This image branch installs
`ceralive-rauc-activate.service` at build time and enables it for
`multi-user.target`. Its `Type=oneshot`, `RemainAfterExit=yes` and successful
`ExecStart=/bin/true` leave it active; **its `ExecStop` runs on shutdown**, not
after install. The unit retains systemd's default dependencies, including the
implicit `Conflicts=shutdown.target`. It orders after and wants `rauc.service`,
orders after D-Bus, and requires the boot-state mount (`/boot` on RK3588,
`/boot/efi` on x86) and `/data` for the armed marker. Reverse stop ordering keeps RAUC and those mounts available
until activation completes. It neither starts shutdown nor reboots the device.

The capability-gated CeraUI orchestrator uses the root-run template interface
after its own `rauc install` succeeds and it records `os-staged.json`:

```sh
systemctl start ceralive-rauc-arm@arm.service     # after a successful OS install
systemctl start ceralive-rauc-arm@disarm.service  # cancel activation
systemctl start ceralive-rauc-arm@now.service     # 7-day escalation, at idle
```

The template is not enabled at boot, and the helper accepts only `--arm`,
`--disarm`, and `--now` (plus its no-argument shutdown mode). Calling the helper
directly requires root. `--arm` checks RAUC's detailed slot status before writing
`/data/ceralive/update-state/activation-armed`; a stale/no-pending slot cannot be
armed. Both `--now` and the shutdown hook require that marker, the absence of
`/run/ceralive/streaming`, a two-slot system still booted from its current primary,
and an other-slot installation newer than its last activation. Only then do they
run **`rauc status mark-active other`** and remove the marker on success. If RAUC
fails, the marker remains for another attempt; if streaming is present, shutdown
skips activation and `--now` refuses. `--now` changes only the next boot target;
it does **not** request a reboot. The seven-day timer and notification policy
belong to CeraUI, not this image helper.

An install by the dormant hawkBit updater or the manual `ceralive-update` script
does not create CeraUI's `os-staged.json` receipt or enter its `os-staged` phase.
The orchestrator does not adopt or arm it. Without an `activation-armed` marker,
the shutdown helper exits immediately; with `activate-installed=false`, an
ordinary reboot keeps the written slot inactive. A separate, explicit operator
arm of that installed slot can use the template above, after which the same
RAUC status and streaming checks govern selection. No external install is
implicitly activated by CeraUI.

The pinned RAUC 1.15.2 retains `activate-installed=false`, which requires manual activation,
and `rauc status mark-active other` as selecting the other slot for the next boot:
[RAUC configuration](https://rauc.readthedocs.io/en/latest/reference.html#activate-installed),
[RAUC activation](https://rauc.readthedocs.io/en/latest/using.html#manually-switch-to-a-different-slot).
The helper parses RAUC's `--detailed --output-format=shell` key/value output
without sourcing it; per-slot installation and activation timestamps establish
whether an inactive rootfs has a newer staged installation. A shared activation
flock prevents two helper calls from racing. The marker directory is on `/data`
so an armed installation survives an ordinary boot; the streaming sentinel and
flock are on `/run` and do not.

The registered `tests/systemd-ordering-cycle.test.sh` gate invokes
`mkosi/runtime/rauc-activation.test.sh`, which stubs RAUC for each
decision path, renders both platform units through the real installer, runs
`systemd-analyze verify`, probes RAUC ordering by closing a deliberate test-only
cycle, and inspects a test systemd manager dump for the implicit shutdown conflict.
No image containing this work has been built or booted yet. The RAUC 1.15.2
source pin resolves the former kernel compatibility decision; this test is not
a hardware shutdown receipt.

## Local kernel activation and recovery [PARTIAL]

The kernel lane uses the same arm, disarm, immediate and shutdown interfaces.
Retained RAUC bundle timestamps do not describe a locally replaced kernel.
Instead, `staged` or `armed` kernel state and a `pending` target overlay must
agree on the attempt UUID, package, version and SHA-256. Target and booted-at-stage
bootnames must match the current other and booted slots. Partial, corrupt or
inconsistent records refuse activation rather than falling back to bundle
timestamps. The streaming sentinel still prevents selection; no helper requests
a reboot.

`--arm` durably writes `armed` before creating the shared activation marker.
`--disarm` returns an armed kernel to `staged` and removes the marker, preserving
its overlay. Before `mark-active other`, the helper writes `activating` with the
current boot ID; after selector success it writes `activated`. A crash before
selection is reconciled to `armed` when the same boot still sees another primary.
Once the target is primary, recovery never re-arms it or resets its attempt
budget.

The healthcheck reconciles before its already-confirmed fast exit and before
mark-good. On a new target boot, `uname -r` must equal the release encoded in
the package name and `dpkg-query` must report that exact package installed at the
expected version. A wrong release, missing package or wrong version never
marks the target good or publishes healthy-state. The ordinary service,
binary-load, dpkg and PARTLABEL checks must also pass.

After mark-good and the boot-scoped marker/healthy-state writes, state becomes
`succeeded`, then the matching overlay becomes `confirmed`. If confirmation
was interrupted, a later invocation completes these writes even through the
already-confirmed fast path. If the system boots elsewhere while the target
remains primary and has attempts, reconciliation leaves it pending. When the
target is bad or no longer primary after a different boot, state becomes
`rolled_back` and its package/version/digest enters quarantine. Reconciliation
does not write the target filesystem or change its selector counters.

## Durable identity records [EXISTS: host contract]

All kernel JSON writes share `ceralive-kernel-state-lib.sh`: create a mode-0600
temporary file beside the destination, fsync it, rename it, then fsync the
directory. The records live in `/data/ceralive/update-state`:

- `kernel-state.json`: schema 1, `attempt`, `package`, `version`, `deb_sha256`,
  `target_slot`, `booted_slot_at_stage`, `boot_id_at_activation` (null until
  activation), `state`, nullable shared-token `reason`, and `timestamps`.
  States are `staging`, `staged`, `armed`, `activating`, `activated`, `succeeded`,
  `rolled_back`, `failed`. Timestamps map these state names to UTC-Z entry times;
  the original `timestamps.staged` remains the escalation anchor.
- `kernel-quarantine.json`: a list of `{package, version, deb_sha256}` identities.
- `slot-overlay-A.json` / `slot-overlay-B.json`: `base_bundle_identity`,
  `kernel: {package, version, deb_sha256}`, `attempt`, `status` and nullable
  `reason`. The base identity retains RAUC's `slot`, `bundleHash`, `checksum`,
  `installedAt` and `installedCount`. A write-ahead invalid record contains only
  `status: "invalid"`, `attempt` and `reason`.

CeraUI acknowledgement adds only `acknowledged: true`; it must not remove the
state, timestamps, identity or slot fields. Terminal reconciliation is
idempotent: a crash after `succeeded` but before confirming the overlay, or
after `rolled_back` but before quarantine, is completed on the next healthcheck,
including after acknowledgement. A later verified mirror or full RAUC install
may legitimately have retired the old overlay.

Slot-sync refuses `kernel_staged_pending` for every nonterminal staging or
activation state. After a verified mirror it durably copies the booted overlay
or removes the target overlay when the booted slot has none. A full RAUC
post-install hook clears only the installed rootfs slot's overlay after restoring
its own GPT label. Cert-only installs do not retire rootfs overlays.

## Capability release gate [PARTIAL: owner release pending]

`install-update-capabilities.sh` emits `kernel-apt-stage` only with the stager,
state/mirror libraries, slot-sync and boot staging/verifier installed, and the
architecture-specific pinned `ceralive-device` payload version at or above
`KERNEL_STAGE_MIN_CERAUI`. The build carries a fresh snapshot of
`manifests/first-party-deb-versions.txt` into the runtime source mount. Comparison
uses full Debian versions, including timestamp/hash suffixes.

The minimum defaults to empty, so the feature is currently never advertised.
The owner must first release the CeraUI containing the kernel lane, then update
the minimum, CeraUI pin and authenticated pin catalog in the same release. No
version has been invented for this gate. The base eight capabilities remain
unchanged.

`tests/kernel-state-machine.bats` drives the real activation and healthcheck
CLIs against real state files and the real selector core, with only device
command boundaries stubbed. Named SIGKILL checkpoints cover selection,
mark-good and terminal-side-effect interruption. The slot-sync and post-install
tests cover overlay replacement and retirement. These host tests do not replace
the two-board kernel drill or privileged loop/chroot acceptance.
