# Inactive-slot kernel staging [PARTIAL]

`/usr/lib/ceralive/ceralive-kernel-stage` is the root-only local transaction,
not an APT downloader or an activation service. CeraUI launches it as:

```sh
/usr/bin/flock -n -E 75 -x /run/lock/ceralive-update.lock \
  /usr/lib/ceralive/ceralive-kernel-stage \
  --attempt ATTEMPT --deb /absolute/candidate.deb \
  --package linux-image-7.2.0-ceralive-rk3588 \
  --version 7.2.0-ceralive2 --sha256 SHA256
```

The inherited descriptor must resolve to the update lock, with a matching
granted FLOCK WRITE row owned by the parent in `/proc/locks`. The stager never
acquires this lock. It acquires the booted dpkg frontend flock itself and reuses
slot-sync's six read-only gates. Booted and primary must agree; target resolution
uses the other RAUC rootfs slot's PARTLABEL. An armed activation, pending OS
install or nonterminal kernel transaction refuses staging.

Before any mirror write, the durable state is `staging`, OTHER is marked bad,
its mirror receipt and adaptive index are retired, and its overlay becomes
`invalid`. The shared `ceralive-slot-mirror-lib.sh` owns only copy and dpkg
verification; slot-sync retains its own locks, mounts, receipt and eligibility.
The non-recursive source bind exposes ext4 boot files, never the FAT submount.

Before installation the target must have twice the package's Installed-Size
plus 512 MiB available to non-root, and `max(ceil(total_inodes/10), 20000)` free
inodes plus the archive's file count. The cached copy is identity-checked again.
Chroot dpkg installs the candidate, purges older kernel package names, preserves
all non-kernel freeze stanzas, rewrites the kernel name/version pin at 1001 and
holds it, then reprunes and audits. Fresh `/run` and non-recursive
`/proc`, `/sys`, `/dev`, `/dev/pts` binds are unmounted in reverse order.

The shipped boot helper and verifier require the new kernel's initrd. The
firmware boundary is exactly:

```sh
ceralive-kernel-boot-staging firmware-check TARGET \
  --kernel-release RELEASE --firmware-root TARGET/lib/firmware
```

Exit 1 reports `missing: <relative-path-or-glob>`; exit 2 is an identity or
usage error. Either fails staging. The firmware provider owns all closure
semantics; staging never upgrades firmware.

After every mount is removed, `findmnt` must prove no target submount or device
mount remains. The shipped shared ext4 reserve assertion and `e2fsck -fn` precede
the durable pending overlay, OTHER mark-good, then durable `staged` state, in
that order. `staged` is the commit point, not proof of a healthy boot.

Startup calls the same guarded helper with `--recover` before admitting another
attempt. A leftover `staging` record is settled as `failed`/`kernel_interrupted`, OTHER
is bad, stale owned mounts are cleared, and the overlay remains `invalid`.
Acknowledgement must not delete these records. A later verified slot-sync
mirror replaces the target overlay with the booted slot's record or absence.
Activation/reconciliation and full RAUC overlay retirement are owned by their
respective helpers, not this transaction; see the
[activation and recovery contract](ota-activation.md). The capability remains
off until the owner releases a capable CeraUI and sets its minimum/pins.

Attempts are UUIDs. State slot fields and overlay filenames use bootnames `A`/`B`. Pending overlays
retain the actual booted RAUC identity as `base_bundle_identity`:
`slot` (the RAUC `rootfs.N` name), `bundleHash`, `checksum`, `installedAt` and
`installedCount`. Missing or invalid byte identity refuses before mutation;
build/version labels never substitute for it. Invalid overlays contain only
`status`, `attempt` and `reason`. State reasons are JSON null or a shared kernel
reason token, with command detail in the journal. UTC state-entry anchors such
as `timestamps.staging` and `timestamps.staged` are retained through recovery.

All refusals and operational failures exit 75. Worker commands have a 600-second
deadline (test seam `CERALIVE_KERNEL_STAGE_COMMAND_TIMEOUT`) and a ten-second
termination grace. Runtime path/command overrides follow slot-sync's offline
fixture convention; production callers use the installed defaults.

`tests/kernel-stage.test.sh` covers real flock, directory-backed slots, failure
ordering and synchronous SIGKILL checkpoints. The native Debian loop/chroot
contract is required in CI through
`CERALIVE_RUN_REAL_KERNEL_STAGE_CONTRACT=required` and consumes a pre-exported
native Debian rootfs from `CERALIVE_KERNEL_STAGE_ROOTFS`; tests perform no network
access. Neither harness establishes physical board qualification.

Generate real producer records for consumer contract copies with:

```sh
TMPDIR="${TMPDIR:?set a scratch directory}" \
  bash tests/kernel-stage-contract-fixtures.sh test-results/kernel-stage-contract
```

The output contains `staged-state.json`, `pending-overlay.json`,
`invalid-overlay.json` and `failed-state.json`, copied without reserialization
from real successful and failing stager paths. `rauc-status.json` is the matching
synthetic observation for reader tests. Committed copies of the four records
live in `tests/fixtures/kernel-stage-contract/`; consumer repositories copy these
bytes into their own fixtures rather than importing a sibling at runtime.
The native harness retains native executables but sets its fixture-only APT
architecture to arm64, so real hold/unhold identities match the deployed target.
