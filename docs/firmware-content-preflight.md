# Full-firmware artifact preflight [PARTIAL]

Reviewed 2026-09-05 at `07df945c2fe31343da2014b202fe84390e31185c`.
This records the pre-adoption review, not a full-image or hardware result.
The subsequent [full-firmware adoption](bluetooth-firmware-closure.md) selects
`armbian-firmware-full=26.8.3`, adds Bluetooth-aware retention and 3.5 GB RK3588
content ceilings plus actual slot-reserve gates. Both 4096M definitions remain
unchanged; the projections below remain historical, non-authoritative estimates.

## Authenticated identity

`manifests/armbian-firmware-content.json` binds `armbian-firmware-full`, version
`26.8.3`, architecture `all`, archive bytes `763716604`, Installed-Size
`2283248` KiB. Its `archive_sha256` is the SHA-256 of the **.deb ARCHIVE FILE**:
`13d10a85a1fa02a989eb2c3e9696f3c931bc9cf2b6059e435c4bd2c75ec53d19`.
It is never a digest of installed or post-prune files.

The existing BSP trust path accepted both pinned archive signatures over Trixie's
InRelease (signed 2026-09-05 13:15:51 UTC). The verified Release named
`ef4a9897246975899081e1508fedfe14cc05ef028517d277245f1c9f02fdd6b8`
as the SHA-256 of `main/binary-arm64/Packages.gz`; the downloaded index matched.
Its unique exact record names
`pool/main/a/armbian-firmware-full/armbian-firmware-full_26.8.3_all__1-SAf50a-SMeeed-B96c8-R448a.deb`.
The downloaded archive matched that record's SHA-256 and size; its own control
Package/Version/Architecture/Installed-Size matched all four fields above.
The staging basename was normalized to `armbian-firmware-full_26.8.3_all.deb`,
without changing bytes. No new apt source or trust root was installed.

`lib/shared/firmware-content.sh` exposes `firmware_content_read <pin>` and
`firmware_content_assert_index <pin> <verified-Packages>`. The reader refuses
missing/extra keys, malformed digest, foreign identity and incorrect sizes.
The comparison refuses missing, duplicate or disagreeing exact records, including
duplicate relevant fields. **Authenticate the index first:** comparison alone
does not establish trust. `tests/firmware-content.test.sh` is registered in the
default gate. Both BSP fetch transports now enforce this pin; see the adoption
contract linked above. The authentication record here predates that integration.

## Capacity ledger: planning estimates only

The two committed wet vendor-BSP baselines at `a575a9a`, measured 2026-08-08,
are Rock `1415188480` bytes and Orange `1422766080` bytes, identical in
`manifests/size-budget.json` and their respective `ci/size-baseline.*.json`.

Naive delta: `(2283248 - 444218) * 1024 = 1883166720` bytes.

| Board | Naive projection | Margin to prospective 3,500,000,000 B | Raw 4 GiB difference |
|---|---:|---:|---:|
| Rock 5B+ | 3,298,355,200 | 201,644,800 | 996,612,096 |
| Orange Pi 5+ | 3,305,932,800 | 194,067,200 | 989,034,496 |

These are NOT real-build measurements and authorize no image or budget change.
Four independent reasons make the arithmetic unreliable:

1. Both baselines used `armbian-firmware=26.8.1`, predate the current `26.8.3`
   pin, and explicitly require remeasurement in their own committed notes.
2. They are vendor-BSP builds. Mainline edge additionally materializes a raw
   `/boot/Image` beside the packaged gzip `vmlinuz`; that increment is unrecorded.
3. Module-driven pruning removes unconsumed candidate families while the proposed
   Bluetooth driver expansion retains more families. These are opposing,
   unquantified effects; the package delta is not additive in a finished rootfs.
4. Apparent bytes are not ext4 allocation. Small files round to 4 KiB blocks;
   directories, inodes, metadata and reserved blocks consume further capacity.

## Archive-derived conditional bounds (no build)

Both `26.8.3` packages were downloaded through the same authenticated index.
The slim archive's SHA-256 is
`3d916c0db4efbe3b7a18fb8b4ef06e61c42185b475a759d4fdb61140f23a0286`,
archive bytes `143643100`, Installed-Size `444218` KiB.
Sorted tar-member manifests were diffed and regular-file deltas grouped by
firmware family. Slim: **454,877,453 bytes / 926 regular files**; full:
**2,337,962,673 bytes / 5,306 regular files**. Net: **1,883,085,220 bytes /
4,380 files**, or **1,892,814,848 bytes** after per-regular-file 4 KiB rounding.
The observed archives have thousands, not tens of thousands, of regular files.
Symlinks are retained in the member-list diff, but not charged as regular files.

The hypothetical best-case model retains only the added wireless-family payload
in `ar3k`, `ath10k`, `ath11k`, `ath12k`, `brcm`, `cypress`, `intel`, `mediatek`,
`mrvl`, `nxp`, `qca`, `rtl_bt`, `rtw88`, `rtw89`, `ti-connectivity`, plus all
top-level blobs (including TI UART firmware and iwlwifi). This is a deliberately
coarse directory model, not a modinfo-derived closure or the current pruner's
behavior. It adds **723,368,114 bytes / 1,062 files**, rounded **725,684,224 B**.
The worst-case model retains every package delta. Neither bounds unrelated
kernel/userspace changes or resolves the stale-baseline/pruning confounds above.

| Board/model | Apparent projection | Margin to 3.5 GB | Difference from 4 GiB |
|---|---:|---:|---:|
| Rock/best | 2,138,556,594 | 1,361,443,406 | 2,156,410,702 |
| Orange/best | 2,146,134,194 | 1,353,865,806 | 2,148,833,102 |
| Rock/worst | 3,298,273,700 | 201,726,300 | 996,693,596 |
| Orange/worst | 3,305,851,300 | 194,148,700 | 989,115,996 |

Worst rounded projections: Rock **3,308,003,328 B**, Orange **3,315,580,928 B**.
No number in these tables is ext4 available space or an authoritative upper bound
on a future image. The later two-board image builds must measure real payloads,
available-to-non-root blocks and free inodes in all four populated slots.

## Read-only runtime headroom

Rock: strict-host-key SSH to the existing bench endpoint refused port 22;
**DEFERRED for all four headroom measurements**, without device mutation.

Orange: `/` ext4 `rw,relatime`; `df -B1 /` reported total `4143677440`, used
`2531442688`, available `1380712448`; `/data` total `6443171840`, used
`1248485376`, available `5177909248`. These are the installed board, not the
prospective full-firmware image. Unprivileged apt-directory reads encountered
permission-denied partial directories; their partial totals are not authoritative.
The privileged read-only retry succeeded: `/var/lib/apt/lists` **94116623 B**,
`/var/cache/apt` **139877938 B**.

## Verification status

The new contract was RED before the parser existed, then GREEN, including the
live authenticated-index comparison. ShellCheck and shell LSP diagnostics are
clean. The complete three-required gate stopped at the pre-existing package-index
privilege prerequisite: `FAIL unprivileged package-index probe requires root or
passwordless sudo`. No assertion was skipped or weakened. The owner authorized
committing the verified preflight with this environment gap explicitly pending;
that authorization is not a full-gate pass or permission to release an image.

The failing prerequisite is `sudo -n -u nobody true` at
`tests/mkosi-package-staging.test.sh:80`; lines 86–87 report the failure and
exit before the probes. Both that command and `sudo -n true` were checked directly
at UID 1000 and returned `sudo: a password is required`, exit 1. Prefixing the
test with sudo would not fix this: the test already invokes sudo itself.

The protected operation is `sudo -n -u nobody -- find "${dir}" -maxdepth 1
-type f -name '*.deb' -printf '%f\n'` (line 50), or `runuser -u nobody -- find …`
when already root (line 48). It proves a different UID cannot enumerate packages
inside private mode-0700 directories but can enumerate the normalized mode-0755
consumer directories holding mode-0644 archives. No package is installed and no
filesystem is mounted for these probes. Running as the directory owner or merely
remapping a UID in a user namespace does not prove that permission boundary.

Lines 54–90 document a local `CERALIVE_RUN_REAL_PRIVILEGE_DROP_CONTRACT=skip`
mode, but CI uses `required`; a local skip is not equivalent coverage. The
referenced BSP authentication and package-resolution suites need no such privilege
and both passed in the captured full-gate run. Todo 40's own acceptance criteria
name those artifact/contract checks, not a sudo workaround; the complete repository
gate remains pending. On a suitably privileged host, run:

```bash
DOCKER_CONTEXT=default \
CERALIVE_RUN_REAL_AVAHI_CONTRACT=required \
CERALIVE_RUN_REAL_RAUC_CONTRACT=required \
CERALIVE_RUN_REAL_PRIVILEGE_DROP_CONTRACT=required ./run-tests
```

The previous run stopped at its first unavailable prerequisite, so later suites
must also finish successfully; they are not implicitly passed by this diagnosis.
