# Offline rootfs measurement [PARTIAL: execution qualification pending]

`ci/kernel-runner/vm.py image` reuses the kernel launcher's anonymous overlay,
parent-death containment, direct `flock --exclusive --close` parent and bounded
shutdown. It runs an unregistered image job with **no NIC**. The existing
kernel `run` and `check` defaults remain 16 vCPUs, 16 GiB and user networking.
This route is engineering measurement tooling; it does not publish an image,
refresh a baseline or qualify a board.

No host directory, socket, agent, physical disk or credential service is
attached. The only additional input is a typed read-only block capsule. An
output-only virtio-serial channel returns data over QEMU stdout; console and
diagnostics use separate bounded pipes. Stdin is `/dev/null`. Guest bytes are
never rendered on the host terminal. Nested Docker mounts and privileged image
operations belong entirely to the disposable guest.

## Preparation and admission

Base preparation, authenticated prefetch and every VM launch require separate
owner authorization. Never run the full test gate or privileged image tools on
the workstation to validate this implementation. PR CI owns that gate.

Prepare an independent base with `build-base --profile image --base FILE`.
The existing SHA-verified cloud image and create-only publication remain in
use. This **trusted preparation** has networking for public tools; it installs
no Actions runner. The image base is 128 GiB virtual, at most 32 GiB allocated,
and must be selected by its independently approved SHA-256. Kernel bases are
not resized or reused. `image` checks the base's digest, read-only permissions,
format, virtual size and absence of backing/data files before starting QEMU.

An image unit requires all these effective limits before admission:

| Resource | Limit or floor |
|---|---|
| Guest | 4 vCPUs, 20 GiB RAM, 128 GiB system disk |
| Host cgroup | MemoryMax 24 GiB, MemorySwapMax 0, CPUQuota at most 400%, IOWeight at most 10 |
| Host scheduling | Affinity to four selected logical CPUs, nice at least 10 |
| Host memory | At least 32 GiB actual MemAvailable |
| QEMU file size | 144 GiB, including qcow2 overhead; core dumps disabled |
| Input capsule | At most 32 GiB |
| Raw return | At most 16 GiB per board; at most 32 GiB retained for the pair |
| Console, diagnostics and receipts | At most 1 GiB per active attempt |
| Deadline | 21,600 s build, 1,800 s verifier; owned TERM/KILL teardown bounded by the launcher |
| Disk reserve | At least 30 GiB beyond remaining bounded allocations on each affected filesystem |

Before fresh preparation the conservative complete budget is 287 GiB:
144 overlay + 32 base + 32 input + 32 pair outputs + 16 temporary duplication
+ 1 logs + 30 reserve. An already complete, verified base/capsule is not
charged again. Existing retained outputs reduce the remaining pair allocation.
The controller combines demands when overlay and output storage share a
filesystem and watches remaining headroom while QEMU runs. It stops its own
attempt if headroom disappears. It never deletes shared caches or foreign
artifacts and never automatically retries.

The host-heavy lock is the existing `/tmp/host-heavy.lock` inode. Do not unlink
or replace it. If a governing plan lock also applies, acquire host lock first,
plan lock second; keep the innermost direct parent as literal
`flock --exclusive --close`. A cgroup/scheduling wrapper belongs above these
locks. Confirm that any preceding heavy unit has finished teardown or adopted
the same host lock before queueing a measurement.

For an independently prepared and approved base, capsule and public policy:

```sh
systemd-run --user --scope \
  -p CPUQuota=400% -p MemoryMax=24G -p MemorySwapMax=0 -p IOWeight=10 \
  nice -n 10 taskset -c "${IMAGE_CPUS:?select exactly four logical CPUs}" \
  flock --exclusive --close /tmp/host-heavy.lock \
  python3 ci/kernel-runner/vm.py image \
    --base "${IMAGE_BASE:?}" --base-sha256 "${IMAGE_BASE_SHA256:?}" \
    --input-capsule "${IMAGE_CAPSULE:?}" --input-sha256 "${IMAGE_INPUT_SHA256:?}" \
    --trust-policy "${IMAGE_PUBLIC_POLICY:?}" --output-dir "${IMAGE_PRIVATE_STORE:?}" \
    --attempt "${IMAGE_ATTEMPT:?}" --board "${IMAGE_BOARD:?}" \
    --source-commit "${IMAGE_SOURCE_COMMIT:?}" --source-epoch "${IMAGE_SOURCE_EPOCH:?}"
```

The output store must be launcher-owned and mode 0700. All returned files and
receipts are mode 0600 and created under a new attempt directory. Run Rock 5B+
first, including its independent verifier and teardown, then Orange Pi 5 Plus.
There is no image matrix or `--all` path. `--image-mode probe` performs a small
network-denial/artifact-return probe; an actual probe and attended cancellation
check remain prerequisites for admitting expensive measurements.

## Typed capsule and independent public policy

A capsule is an uncompressed regular tar containing exactly `inventory.json`
and unique regular `objects/<sha256>` members. No links, sparse members or
guest-selected destination paths are accepted. Inventory is at most 1 MiB;
each member's exact length and SHA-256 are checked during guest import.

The schema-1 inventory has these exact fields:

| Field | Meaning |
|---|---|
| `schema` | Integer 1 |
| `source_commit`, `epoch`, `board` | Must equal the host's predeclared commit, epoch and single board |
| `fetched_at` | Actual approved prefetch completion time in UTC `YYYY-MM-DDTHH:MM:SSZ`, never synthesized by the guest |
| `source_bundle` | Digest of a `source-bundle` object |
| `device_root` | Digest of a `public-trust` object containing only the approved public RAUC root |
| `objects` | Rows with `sha256`, integer `length`, `kind`, and exact original HTTPS `urls` |
| `repositories` | Repository delivery records described below |

Object kinds are `source-bundle`, `public-trust`, `apt-metadata`, `deb`,
`pinned-source`, `builder-image`, `kernel-metadata`, and verifier-only `artifact`.
The source object is a public Git bundle with sufficient history and refs.
The guest creates its own checkout and checks commit, non-shallow history and
commit epoch. A worktree `.git` pointer is never an input. Exclude host Git
configuration, credential helpers, environment files, private PKI, task state,
unselected caches and unrelated working changes.

The owner-reviewed public policy is **separate from the capsule**. It has
`schema: 1`, `root_der_sha256`, `repositories`, `kernel_metadata`, and
`builder_images`. Optional public-only fields are `addon_public_object`,
`paseto_public_object` and `os_version`. Private signer/client environment
fields are not accepted by this policy.

Each policy repository (`firstparty`, `bsp` and `debian-source` are required) declares exact
`origin`, `keyring` object digest, primary `fingerprints`, signed `suite`,
`component`, `arch`, `index_path`, and `max_age_seconds` (at most 30 days).
The matching capsule record repeats those identities and adds `inrelease`
and compressed `index` object digests. The import compares the independent
policy before invoking the existing gpgv, Release identity, signed-index digest,
unique package lookup, Debian control identity and package-lock validators.
Signed Date must be current within the approved age when freshness is checked.
Bootstrap repositories, including Debian source metadata, normally require
both signed Date and Valid-Until. **Only the `rootfs-measurement` purpose may
waive a missing Valid-Until for metadata whose authenticated Origin is Debian.**
For that case the signed Date is recorded without an age check: **freshness
was NOT checked**. A missing or malformed Date still fails. A present, expired
Valid-Until is rejected for every purpose, including measurement. Every
non-measurement purpose, including any future production candidate, rejects
Debian metadata missing Valid-Until. First-party/BSP validity remains bounded
by the approved age and any signed Valid-Until. No metadata is re-signed.
Before the mirror announces readiness, every declared repository passes the
existing signature, Release identity and signed-index checks against the
independent policy. Undeclared metadata is refused. The verified validity
windows are checked again before every delivery, including package bytes;
the explicit missing-Valid-Until waiver has no freshness window.
This supplies the freshness gate that pinned mkosi 26 disables in its APT
options; those downstream options do not bypass sealed-input validation.
The approved Debian source keyring is installed only inside the guest for the
existing RAUC source verifier, whose manifest-pinned signer checks remain.

`kernel_metadata` maps exactly `kernel-artifact.json`, `resolved.config`,
`built-modules.txt` and `SHA256SUMS` to independently selected object digests.
They populate the existing `CERALIVE_KERNEL_HISTORY_DIR/7.2.0-ceralive8/`
interface. The kernel `.deb` still comes from the original signed CeraLive
APT index, and its authenticated digest must equal the released metadata.
Missing ceralive8 fails; there is no source compile or pin change.

Each `builder_images` row has an archive `object` digest, exact local `tag`,
approved Docker `image_id`, and `arch`. Both RAUC architectures and the mkosi
builder must be present. Missing builders fail instead of starting a Docker
build. Include the complete solved Debian/BSP/first-party dependency closure,
bootstrap metadata, RAUC upstream/Debian source inputs and the recipe-pinned
MediaMTX payload. The latter uses the existing checksum-checked local-tarball
path inside the guest source mount.

### Host package capsule preparation [EXISTS: fixture-qualified]

`python3 ci/prepare-image-capsule.py` supplies the host-side producer. Running
authenticated prefetch still requires separate owner authorization. It takes
an **explicit reviewed complete closure**, not board-manifest seeds. The normal
image installation dependency solver remains in mkosi/APT; this producer does
not invoke it, discover dependencies or claim the submitted closure is complete.
Include every bootstrap, BSP and first-party dependency selected for this board,
plus the already prepared public source bundle, public trust, pinned sources,
released kernel metadata and builder archives described above. An omitted
dependency still fails closed in the offline guest.

The reviewed JSON input uses the capsule inventory fields `schema`,
`source_commit`, `epoch`, `board`, `source_bundle`, `device_root`, `objects` and
`repositories`, plus a `packages` array. Omit `fetched_at`: the producer records
its actual completion time. Repository records and the separate public policy
use the existing schema above. Every object has the existing exact `sha256`,
`length`, `kind` and `urls` fields. Local ingredients additionally have `path`,
absolute or relative to the reviewed input file, without `..` components.
They must be regular files matching the reviewed size and digest. Archive
keyrings use `apt-metadata` with no URLs. Never nominate client credentials or
private signing material as local ingredients.

Each package row has exactly `repository`, `name`, `version`, `arch` (`arm64`
or `all`), and `sha256`, referring to one `deb` object. Every `deb` object needs
one row and one exact original HTTPS URL; packages cannot use local paths.
For example, a reviewed package row has this shape:

```json
{"repository":"firstparty","name":"ceralive-device","version":"2026.11.2","arch":"arm64","sha256":"<reviewed package SHA-256>"}
```

The repository's `inrelease` and `index` objects likewise need one URL each
and cannot use local paths. First-party metadata lives below
`origin/dists/suite/binary-arm64/`; other repository metadata lives below
`origin/dists/suite/`. The signed `index_path` supplies the exact index URL.
Original signed `InRelease` (or a signed `Release` accepted by the existing
verifier) and compressed indexes are preserved byte for byte. Detached
`Release.gpg` support is not added. The original signature, Release identity,
validity and signed-index validators run before package requests. Each
reviewed package must match the existing unique signed-index lookup, original
URL, SHA-256 and Debian control identity. Nothing is installed, unpacked into
a rootfs, executed from packages or re-signed.

Create a private output directory and invoke one board at a time:

```sh
umask 077
mkdir -m 700 private-capsules
python3 ci/prepare-image-capsule.py \
  --inventory "${IMAGE_REVIEWED_INVENTORY:?}" \
  --trust-policy "${IMAGE_PUBLIC_POLICY:?}" \
  --client-identity https://apt.ceralive.tv \
    "${APT_CLIENT_CERT_PATH:?absolute certificate path}" \
    "${APT_CLIENT_KEY_PATH:?absolute key path}" \
  --output private-capsules/rock-5b-plus.tar
```

`--client-identity ORIGIN CERTIFICATE_PATH KEY_PATH` may repeat for distinct
exact approved policy origins. Only paths reach curl's arguments; credentials
are used in place and are never copied into the capsule. A client identity
cannot authorize another origin. Normal system CA and hostname validation
apply; `--ca-file` selects an explicit public CA bundle when required.
Ambient curl configuration, proxies and credential environment are excluded.
Transfers have no terminal or stdin for key-password prompts; a key requiring
interactive unlocking fails closed.
Each transfer is one GET with no redirect following or retry. Non-200 status,
TLS failure, mismatched bytes or timeout reject the attempt. The default
per-object deadline is 120 seconds (`--object-timeout` permits 1–600); connect
time is at most 10 seconds. Curl's size bound is backed by a process file-size
limit, including responses without Content-Length. Decompressed package
indexes and compressed metadata are limited to 256 MiB, signed Release files
to 16 MiB, and each validator invocation to 120 seconds.
The finite reviewed list bounds the number of requests; the unchanged capsule
limits are 32 GiB, 1 MiB inventory and 20,000 regular tar members.

The output is mode 0600, created only after the merged importer accepts its
transport digest, structure, sizes and hashes; existing outputs are never
overwritten. Temporary inputs, archive and importer check can require three
capsule lengths of disk space, in addition to retained inputs and the normal
reserve. Temporary storage is private and removed on success or failure.
The command prints only the capsule SHA-256 on success. Its capsule contains
an additional digest-named `apt-metadata` JSON object with `delivery:
offline-capsule`, completion time, the verified package identity/size/hash/URL
inventory, original logical repository origins and the existing metadata
validity receipt. This is transport provenance, not a new repository signature
or a live guest fetch receipt. Source/builder content qualification and actual
offline VM admission remain separate checks.

The guest-only mirror has a finite inventory, no CONNECT/upstream relay and no
host endpoint. Build-only Debian routing does not change shipped APT sources.
An absent dependency or source object fails; networking is never enabled.
Ordinary percent-encoded package names share one finite resource identity
(for example `+` and `%2B`); encoded separators and traversal are rejected.

Logical fetch origins remain `first-party`, `ceralive-kernel`, `bsp` and
`userspace-pin`. `sealed-delivery.json` separately records offline delivery,
the capsule digest and the declared prefetch completion time. That timestamp
is inventory provenance; repository authenticity still comes from the original
signatures. It is not a receipt for a new live authenticated fetch or
a first-party local override.

## Measurement and verification

The image job calls the existing single-board builder with
`--rootfs-measurement`. It requires production mode, the approved public device
root's exact DER digest, ceralive8, the shipping variant, both slots,
INSTALL_BOOT_BSP=1, strict BSP provenance and authenticated APT kernel reuse.
Debug, bench-label, dry-run, direct credential, private signer and local
first-party override inputs are refused.

All resolve/fetch/kernel reuse/target and native RAUC build/mkosi/tar/boot/size/
firmware closure/package-lock/parity stages still run. The raw assembly and
shared slot writer are reused. Only bundle signing and raw compression are
omitted. Actual populated rootfs_a/rootfs_b images are retained after compiled
boot-payload injection and the existing clean-ext4 reserve assertion.
Normal builds continue to call `rauc_pki_resolve` and sign/compress as before.

A successful content run emits a measurement-specific receipt. The host
receives `measurement.json` with a `metadata_validity` record generated by the
authenticated sealed importer before mirror readiness. Each repository row
records `release_date` (the signed Date as ISO 8601), `release_sha256` (the
original Release/InRelease object's SHA-256), `freshness_checked`, and
`freshness`. A waived Debian row has `freshness_checked: false` and
`freshness: "NOT checked"`; its enclosing purpose is `rootfs-measurement`.
This receipt preserves signature and byte identity evidence without claiming
freshness for the waiver.

The host decodes fixed artifact IDs, independently hashes every byte and checks the
terminal inventory, identities, sidecar and gate exits. Truncated, duplicate,
unknown, malformed, oversized or trailing records are quarantined. The host
does no mount, filesystem repair, chroot, package installation or tar extraction.

The same locked unit then starts a fresh no-network verifier overlay using
the approved source/base and public metadata. It rechecks tar size, boot,
firmware closure/inventory, package identities, kernel metadata and actual
clean ext4 reserves. Read-only guest mounts compare slot contents with the
emitted tar plus independently recompiled boot payload; ext4's empty
`lost+found` is filesystem housekeeping. Only a matching verifier result
produces the host `acceptance.json`. Transport and exit receipts are separate.
The mounts retain `noexec,nodev,nosuid`. Shared parity checks require regular
executable files with stored execute mode bits, rather than asking whether
the verifier's mount policy permits their execution.

The focused noexec regression uses path-scoped strace syscall injection to
deny X_OK while preserving the fixture's file metadata. It creates no mount,
executes no image binary and needs no sudo. Hosted CI and prepared test bases
declare strace as a test tool.

Receipts record source/base/input identities, launcher/QEMU process start
identities, times, caps, exit/stop reason, reaping and descriptor closure.
After forced death, the next admission reconciles the exact owned overlay
inode and process identities. A remaining holder blocks admission; no foreign
process is killed. Forced destruction never claims that guest cleanup ran.

The unchanged `ceralive-apt-credentials` package stays in the guest and returned
rootfs/slots. Its shared `client-cf` identity is owner-accepted. **There is no
claim that the host key is excluded through package contents.** Do not rotate,
split or strip that package. Capsules, rootfs, slots and full logs remain
private; public evidence is limited to identities, hashes, counts, sizes and
redacted logs. No baseline, signed candidate, publication or hardware proof is
created by this implementation.
