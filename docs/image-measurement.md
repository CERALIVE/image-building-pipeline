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
| Host cgroup | MemoryMax 24 GiB, MemorySwapMax 0, CPUQuota at most 400%, CPUWeight at most 10 on the workload cgroup, IOWeight at most 10 |
| Host scheduling | Affinity to four selected logical CPUs, non-realtime CPU scheduling, nice 9–19 (launch at 10) |
| Host memory | At least 32 GiB actual MemAvailable |
| QEMU file size | 144 GiB, including qcow2 overhead; core dumps disabled |
| Input capsule | At most 32 GiB |
| Raw return | At most 16 GiB per board; at most 32 GiB retained for the pair |
| Console, diagnostics and receipts | At most 1 GiB per active attempt |
| Deadline | 21,600 s build, 1,800 s verifier, with up to 20 s from owned QEMU TERM to KILL |
| Disk reserve | At least 30 GiB beyond remaining bounded allocations on each affected filesystem |

Before fresh preparation the conservative complete budget is 287 GiB:
144 overlay + 32 base + 32 input + 32 pair outputs + 16 temporary duplication
+ 1 logs + 30 reserve. An already complete, verified base/capsule is not
charged again. Existing retained outputs reduce the remaining pair allocation.
The controller combines demands when overlay and output storage share a
filesystem and watches remaining headroom while QEMU runs. It stops its own
attempt if headroom disappears. It never deletes shared caches or foreign
artifacts and never automatically retries.

CPUWeight keeps the whole cgroup low priority when it competes for CPU.
The CPU and memory caps still apply independently. A host rule such as
ananicy-cpp's `Heavy_CPU` can change QEMU from nice 10 to 9 without changing
the cgroup. The launcher tolerates that adjustment, checks the running QEMU
process and its cgroup about every five seconds, and stops the attempt if the
priority floor or required limits are lost at a check. The exit receipt
includes the last QEMU observation of `nice`, `ionice` (via util-linux), and
`cpu_weight` when a live sample was available. Realtime CPU or I/O scheduling
is refused for the measurement guest.

The host-heavy lock is the existing `/tmp/host-heavy.lock` inode. Do not unlink
or replace it. If a governing plan lock also applies, acquire host lock first,
plan lock second; keep the innermost direct parent as literal
`flock --exclusive --close`. A cgroup/scheduling wrapper belongs above these
locks. Confirm that any preceding heavy unit has finished teardown or adopted
the same host lock before queueing a measurement.

For an independently prepared and approved base, capsule and public policy,
the example assumes a shell at nice 0. `nice -n 10` is a relative adjustment.
If the shell inherits another value, adjust the increment to start at nice 10.

```sh
systemd-run --user --scope \
  -p CPUQuota=400% -p CPUWeight=10 -p MemoryMax=24G -p MemorySwapMax=0 -p IOWeight=10 \
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

The probe emits `STAGE <monotonic-nanoseconds> <stage> <count>` to the guest
serial console and to `/run/ceralive-image-stages.log` in the disposable guest.
The guest log is capped at 16 KiB. Check and verdict counts are 1 for denial
and 0 for an unexpected result or error. Import completion counts objects.
Stream markers identify member order and separate preparation, header writes,
body writes, flush and close. Write completion counts are bytes reported by
the guest writer.

Probe `teardown.json` and `exit.json` include `last_stage`, `stream_bytes`
received by the host, and `console_stage_tail`, up to 64 KiB of complete
allowlisted stage lines. The receipt omits other console text. The independent
guest deadline error names the last observed stage. An external supervisor
that ends the probe with TERM still produces a cancellation receipt, with the
same diagnostics. Stage logging is best effort and does not affect acceptance.

The image base embeds the guest helper, stage logger and stream writer at
`build-base --profile image` time. A newer launcher or source bundle does not
update an earlier base. Prepare a new file from the reviewed helper revision,
and independently approve its digest before using it for an attended probe.

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
Optional `max_redirects` is an integer from 0 to 3, defaulting to 0 when absent.
Only `bsp` may approve a nonzero value, and the policy parser rejects a nonzero
allowance for any origin bound to a client identity in that invocation.
First-party and all other repositories remain at zero. Keep the Armbian BSP
logical `origin` as `https://apt.armbian.com`; do not replace it with a mirror.
The matching repository record repeats a nonzero allowance. Discovery omits
zero, preserving existing inventory bytes and schema 1.
An optional `codename` selects the exact `/dists/<codename>/` metadata path
instead of `/dists/<suite>/`. It must match exactly one signed `Codename`
field; `suite` must still match exactly one signed `Suite` field. For example,
Debian's trixie path uses `suite: "stable", codename: "trixie"`, updates uses
`suite: "stable-updates", codename: "trixie-updates"`, and security uses
`suite: "stable-security", codename: "trixie-security"`. Pin the component
token as signed, including `updates/main` when the security Release names it.
The two identities are independently approved, not interchangeable alternatives.
Omitting `codename` retains the existing suite path and strict Suite check.
First-party channels remain `stable` or `beta` and cannot set `codename`.
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

### Host metadata discovery [EXISTS: fixture-qualified]

`python3 ci/discover-image-metadata.py` fills the identity gap before capsule
preparation. It fetches only the original signed Release and compressed
Packages or Sources index for each selected archive. It never fetches a payload, solves
dependencies, signs metadata, or nominates a trust anchor from downloaded bytes.
An actual authenticated discovery run requires separate owner authorization.

Supply two reviewed JSON files. For binary packages, `--selection` contains a
`packages` array, with each row containing `repository`, `name`, `version`, and
exact `arch` (`arm64` or `all`). For example:

```json
{"packages":[{"repository":"firstparty","name":"linux-image-7.2.0-ceralive-rk3588","version":"7.2.0-ceralive8","arch":"arm64"}]}
```

Source selections use a `sources` array. Each row contains exactly `repository`
(`debian-source` only), exact source `name` and `version`, and a `files` mapping
from **every authenticated source filename** to its already staged, absolute
local path. Either array may be omitted; the combined selection must be nonempty.
For example, assuming these are the exact files in the authenticated stanza:

```json
{"sources":[{"repository":"debian-source","name":"rauc","version":"1.15.2-1","files":{"rauc_1.15.2-1.dsc":"/srv/public-sources/rauc_1.15.2-1.dsc","rauc_1.15.2.orig.tar.xz":"/srv/public-sources/rauc-1.15.2.tar.xz","rauc_1.15.2-1.debian.tar.xz":"/srv/public-sources/rauc_1.15.2-1.debian.tar.xz"}}]}
```

The local basename may differ from the signed filename. The source selection
must include the `.dsc` and every other file listed in `Checksums-Sha256`, even
when the build uses only a subset. Discovery neither obtains missing files nor
infers paths from staged filenames. Supply only staged public files, never
credentials or private signing material.

For the measurement closure, include all 16 exact pins from
`manifests/first-party-deb-versions.txt`, the released ceralive8 kernel, and the
board's BSP pins. Resolve and review companion architectures explicitly; there
is no architecture inference or version selection.

The discovery `--trust-policy` contains exactly `schema: 1` and `repositories`.
Its repository rows use the **same ArchivePolicy fields and parser** as the
complete image public policy above: `origin`, `keyring` (public file SHA-256),
`fingerprints`, `suite`, optional `codename`, `component`, `arch`, `index_path`,
`max_age_seconds`, and optional `max_redirects` under the restrictions above.
Include exactly the repositories used by the selection.
Image-root, builder and released-kernel object identities are unnecessary for
this earlier step. Copy these independently approved repository policies into
the eventual complete image public policy without changing them.

Pass one `--keyring REPOSITORY PUBLIC_KEYRING_PATH` per repository. The command
checks each bounded regular public-only export against its approved digest and
exact primary fingerprint set **before any network request**. Obtaining and
independently approving those public exports remains an owner prerequisite;
discovery never searches host PKI directories or downloads keys. Do not pass
client certificates, private keys or signing material as archive keyrings.

The command reuses the capsule producer's exact GET implementation, origin
binding, deadlines and distribution paths, and the importer's existing
signature, Release identity, validity, index and bounded decompression
validators. Default metadata names are `InRelease` and the policy's exact
`index_path`. `--release-name REPOSITORY Release` explicitly selects an original
signed `Release` accepted by the existing verifier. There is no fallback,
detached `Release.gpg` request or format probing. Redirects use only the explicit
BSP allowance and the shared manual transport described below. Only
gzip/xz `Packages` indexes and the approved `debian-source` repository's
`Sources.gz` or `Sources.xz` index are supported. Signature/primary signer,
Suite/Codename/component/architecture, Date/age, and any present Valid-Until
must pass before the index request. First-party/BSP may omit Valid-Until but
remain bounded by the approved age. Expired present Valid-Until always fails.
The same measurement-only Debian waiver described above applies when discovery
runs with `CERALIVE_BUILD_PURPOSE=rootfs-measurement`: an absent Valid-Until
records Date without checking freshness. It never waives an expired present
Valid-Until.

The shared checksum reader authenticates both the index SHA256 and Size;
duplicate checksum entries fail. The shared package lookup requires one
unambiguous stanza with the exact selected version and architecture,
Filename/Size/SHA256, and no duplicate fields. Missing versions, wrong
architectures, unsafe paths, invalid sizes/digests and duplicate stanzas fail.
No package URL is contacted, including a URL appearing in signed metadata.

Source discovery uses the shared RAUC Sources reader's `identity` output.
It requires one exact name/version stanza, unique fields and checksum entries,
matching `Files`/`Checksums-Sha256` file sets and sizes, and safe
`Directory`/filename paths. The shared URL validator also rejects encoded
traversal and separators. Each selected local file must be regular, without
symlinks in its path, and match the authenticated size and SHA-256. The producer's
bounded local copy supplies a private snapshot for hashing. Missing or extra
selected files, non-regular paths and any byte mismatch fail closed. The shared
complete-input gzip/xz decoder verifies every concatenated stream, including a
corrupt later xz stream, before any source lookup. No source payload is retained
or fetched.

**Real credentialed runs require `--client-identity-config FILE`** for both
discovery and preparation. Provision the mapping outside the checkout and
output directory. The file must be regular, owned by the invoking user, and
mode 0600. Its parent must be owned by that user or root and must not be
group- or other-writable. Only the `firstparty` repository at the exact origin
`https://apt.ceralive.tv` may receive a client identity. Debian, BSP, mirrors,
and other repositories use anonymous GETs. Both CLI forms reject an ineligible
binding before any network request. The transport checks the repository and
request origin again before attaching an identity. Use a real directory and file, not symlinks.
Put one `ORIGIN CERT_PATH KEY_PATH` record on each line:

```text
# One independently approved origin and two absolute paths
https://apt.ceralive.tv /private/example/client.pem /private/example/client.key
```

Blank lines and full-line `#` comments are allowed. Quote paths containing
spaces or backslashes with single quotes. The parser treats the fields as
data and performs no shell expansion. Never export credential paths in the
launch environment or pass them to a shell command to create the mapping.

```sh
umask 077
mkdir -m 700 private-metadata
python3 ci/discover-image-metadata.py \
  --selection "${IMAGE_REVIEWED_PACKAGE_SELECTION:?}" \
  --trust-policy "${IMAGE_APPROVED_ARCHIVE_POLICY:?}" \
  --keyring firstparty "${IMAGE_PUBLIC_FIRSTPARTY_KEYRING:?}" \
  --keyring bsp "${IMAGE_PUBLIC_BSP_KEYRING:?}" \
  --client-identity-config private-config/identities \
  --output private-metadata/discovered
```

The example assumes the selection contains firstparty and BSP packages. The
same `--client-identity-config FILE`, optional `--ca-file`
and `--object-timeout` transport rules documented below apply. Client identity
paths and bytes never enter the output. Output must be new, below an owned
private directory; failure removes temporary inputs and publishes no result.
The output directory is mode 0700 and its files are mode 0600:

- `inventory-fragment.json` contains exactly `packages`, `repositories`, and
  `objects` in the producer's unchanged reviewed-input schema. Package rows
  contain exactly `repository/name/version/arch/sha256`; their `deb` objects
  contain the signed size as `length` and the canonical original URL. Repository
  rows reference original Release/index digests. Public keyring objects have
  local `path` entries pointing at the retained public exports.
  Source files appear only as `pinned-source` objects with exactly
  `sha256/length/kind/urls/path`; they are not binary `packages` rows. Their
  `path` is the reviewed staged path and their URL joins the authenticated
  Directory/filename below the approved Debian origin. This is the existing
  producer contract in `ci/prepare-image-capsule.py`. Both host tools use
  `ci/kernel-runner/image_policy.py` for archive and credential eligibility
  and `ci/kernel-runner/image_transport.py` for the actual requests.
- `objects/<sha256>` preserves the original signed Release, compressed index,
  and approved public keyring bytes. There are no package payload objects.
- `discovery.json` records completion `fetched_at`, original signed Release and
  index digests, signed `release_date` and `valid_until` (null when absent), and
  each selected package's original `filename`, `length`, architecture, version,
  SHA-256, logical origin and signed-index digest.
  A repository with redirected metadata also records `transfers`: one row per
  redirected object with `sha256`, logical `url`, final `final_url`, and
  `redirects` in request order. Each redirect is `{status, from, to}`.
  Discovery requests no payloads, so package rows have no payload redirect chain.
  With source selections it also has a `sources` array recording one row per
  file, including source name/version, signed Directory/filename, staged path,
  length/SHA-256, original URL, origin and authenticated index digest. Only
  source selections add the `sources` field.

Requests and rows are sorted by repository/package identity and object digest;
JSON uses canonical key ordering. Reordering the selection changes neither the
selected identities nor request order. Actual fetch times, original signed bytes
and the chosen output path remain recorded facts, not normalized constants.
Success prints only the fragment's SHA-256. The receipt is provenance rather
than a new signature.

Review the fragment and original metadata before merging its three sections
into the complete reviewed inventory: match packages by
`repository/name/arch`, repositories by name, and objects by SHA-256. Reject
conflicting existing identities rather than keeping duplicate rows. Preserve
the retained keyring paths, all unrelated closure objects, and the complete
inventory's source/board/root fields. Keep `discovery.json` beside the review
evidence; its extra fields do not belong in the producer's inventory.
For a staged source already present under the same digest, require matching
length, kind and local path, then preserve its independently reviewed URLs
alongside the newly authenticated Debian URL in the single object row. For
example, the pinned GitHub RAUC tarball and Debian's orig tarball can be the
same bytes under different names; both original URLs are needed by their
respective guest consumers. The producer rechecks staged bytes at preparation;
discovery does not freeze or replace the caller's files.
The producer intentionally fetches metadata again from the exact approved URLs
and requires these reviewed hashes and sizes; upstream changes fail instead of
silently selecting newer bytes. Discovery does not authorize that payload-fetch
operation or prove that the submitted dependency closure is complete.

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
When an approved `codename` is present, it replaces only the distribution
path segment; the original Release must authenticate both identities.
Binary `Packages.gz` and `Packages.xz` indexes use the same bounded streaming
decoder in the producer and sealed package importer. Gzip uses Python's
standard `gzip` module and xz uses standard `lzma`; each decoded index is at
most 256 MiB, including concatenated streams. Truncated, corrupt, oversized
or unsupported formats fail closed and leave no partial decoded index.
Every xz stream must reach its verified end, including later concatenated
streams; only correctly aligned null-byte stream padding may follow a stream.
Trailing non-stream bytes are rejected instead of accepting a valid prefix.
There is no format probing, alternative URL fetch, recompression or re-signing.
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
  --client-identity-config private-config/identities \
  --output private-capsules/rock-5b-plus.tar
```

With the config form, only the mapping filename appears in the command line.
The certificate and key paths stay out of both the Python and curl argument
vectors and environments. For compatibility, `--client-identity ORIGIN
CERT_PATH KEY_PATH` still works and prints a warning because it exposes both
paths in Python's process arguments. Duplicate origins within or between
the two forms are rejected before any GET.
For each credentialed GET, the transport sends quoted `cert` and `key` config
lines through a fresh pipe to `curl -K -`. Curl opens the files in place.
Neither command writes a config file or includes the paths in logs, receipts
or capsule contents. A client identity
cannot authorize another origin. Normal system CA and hostname validation
apply; `--ca-file` selects an explicit public CA bundle when required.
Ambient curl configuration, proxies and credential environment are excluded.
Transfers have no terminal or interactive stdin for key-password prompts; a key requiring
interactive unlocking fails closed.
By default each transfer is one GET, without redirects or retries. With a
nonzero BSP policy allowance, the same transport follows 301/302/303/307/308
manually, one GET per hop, always using `curl --max-redirs 0`, never `curl -L`.
Each Location is resolved relative to the current URL and validated before
contact: HTTPS only, no userinfo (including empty userinfo), non-default port,
query, fragment, encoded separator or traversal. Its path must still end in
the logical object's path; a mirror may prepend `/armbian/apt/`, for example.
Missing or duplicate Location, loops, an excessive hop count and downgrades
fail closed. No client identity, credentials, cookies or authorization headers
are forwarded to any hop of an allowed redirected transfer.
Every BSP GET, including the initial request to `apt.armbian.com` with a zero
redirect allowance, requires a DNS hostname and port 443. IP literals are
rejected. The transport resolves the host once, checks every answer for public
unicast reachability, then pins the first vetted address with `curl --resolve`.
TLS still verifies the URL hostname. A failed lookup, a mixed public/private
answer, or any loopback, private, link-local, carrier-grade NAT, unique-local,
multicast, unspecified or reserved address rejects the hop before connection.
IPv4-mapped IPv6 answers undergo the same IPv4 checks.
The deprecated 6to4 anycast block `192.88.99.0/24`, including the 6a44 relay,
is excluded explicitly. Preparation also rejects metadata shared between BSP
and another repository because the two references have different transport requirements.
TLS failure, unexpected status, mismatched bytes or timeout reject the attempt.
A failed transfer names the object SHA-256 (or discovery's metadata object
name), its current validated URL, the HTTP status (000 when
no response arrived) and curl's exit code; credential paths are never printed.
The default
per-object deadline is 120 seconds (`--object-timeout` permits 1–600) across
the whole chain; each hop receives only the remaining time, with connect
time at most 10 seconds. Curl's size bound and process file-size limit apply
at every hop, including responses without Content-Length. Decompressed package
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
or a live guest fetch receipt. If any objects redirected, it also contains
`transfers` in fetch order, using the same object/URL/hop shape as discovery.
No transfer fields are added when there are no redirects.

Redirect targets never enter `objects[].urls`, repository origins or
authenticated package rows. Original Armbian signatures, exact signer and
Release identity/freshness checks, signed-index SHA-256/Size, and reviewed
object SHA-256/length still decide acceptance. Different networks may select
different mirrors: the authenticated inventory rows remain byte-identical
when those mirrors serve the same signed bytes. Receipts record the actual
chains and may differ, so complete capsule hashes may differ too. A stale or
different mirror snapshot fails the reviewed hashes; the operator must repeat
discovery and review, with no retry or automatic second mirror.
Source/builder content qualification and actual
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
Normal non-dry-run builds continue to call `rauc_pki_resolve` and sign/compress as
before. Separate `DRY_RUN=1` build plans skip RAUC PKI entirely, including for
`x86-minipc`; they do not enter this measurement purpose or validate public trust.

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
produces the host's candidate `acceptance.json`. The final marker makes it
eligible for use.
The mounts retain `noexec,nodev,nosuid`. Shared parity checks require regular
executable files with stored execute mode bits, rather than asking whether
the verifier's mount policy permits their execution.

The focused noexec regression uses path-scoped strace syscall injection to
deny X_OK while preserving the fixture's file metadata. It creates no mount,
executes no image binary and needs no sudo. Hosted CI and prepared test bases
declare strace as a test tool.

### Teardown and publication

The launcher sanitizes its process state before admission. It blocks signals
while disarming real, virtual and profiling timers and consuming pending
timer signals. It installs TERM, INT and HUP handlers, restores default
dispositions for child reaping and the other tracked signals, then clears
the inherited mask. A stop already pending is handled as cancellation.
It reserves standard descriptors, filling any missing stream with
`/dev/null`, closes all other inherited descriptors, and sets umask `077`.
If verification of this baseline fails, it reports a startup error and
exits 78 before starting a helper or guest.

Relative arguments are resolved from the caller's directory. QEMU and its
helpers use `/` as their working directory, an absolute tool search path,
and `LANG=C.UTF-8`. The separate host-only registration command retains its
GitHub configuration and uses the same fixed locale. At exec, QEMU and its
helpers have default dispositions for the tracked signals. The launcher
reaps only the owned PID with `waitpid` and rejects an unavailable exit
status. Child creation is forbidden after terminal finalization begins.

Send a single TERM, INT or HUP to the launcher to cancel the attempt. The
idle I/O loop checks for cancellation at least once per second. The launcher
stops draining pipes and sends TERM to the owned QEMU process, then sends KILL
if it has not exited after 20 seconds. Additional signals do not reset that
grace period. Allow up to 600 seconds for teardown and receipt I/O on a
responsive host.

The launcher holds the flock through all of these steps:

1. Create private directories and sync their parent entries. Journal the
   overlay in `active.json` before it can be inherited. Publish `started.json`
   and update `active.json` with the QEMU process identity when it starts.
2. Reap QEMU and close its pipes, the payload and the anonymous overlay.
   Closing the last overlay descriptor removes the overlay. Flush and sync
   the captured output before decoding. Validate and sync the decoded files
   and artifact directory before publishing their `transport-validation.json`.
   Discard the captured stream after transport validation.
3. Close the input capsule, console and any remaining output descriptors.
   Write each guest's `teardown.json` after cleanup. It records source, base
   and input identities, process start identities, timing, caps, reaping and
   descriptor closure. Retire and sync the ownership journal only after
   teardown has been recorded and closure is confirmed. On the measurement
   path, repeat these steps for the independent verifier, validate its result,
   remove its temporary capsule and write the candidate `acceptance.json`.
4. Commit exactly one final `exit.json` last. For a probe it is in `build/`.
   For a build and verifier pair it is in the attempt directory alongside
   `acceptance.json`. Only a marker with `launcher_exit` equal to 0 and
   `pair_complete` equal to true, with the matching identity and SHA-256 of
   `acceptance.json`, completes a pair. The host retention check and other
   consumers must reject an acceptance candidate without this marker, even
   when guest transport and teardown receipts already exist.

Every receipt is written to a mode-0600 temporary file in its own directory,
flushed and file-synced, atomically renamed into place, and followed by a
directory sync. The final marker's **rename is the commit point**. A
publication failure before that rename leaves the marker absent and exits
nonzero. Consumers treat a missing marker as failure. Cancellation before
the final rename transaction produces a marker with `stop_reason` set to
`cancelled` and `launcher_exit` set to 1 when storage permits. The launcher
blocks every catchable signal once, before the final cancellation checkpoint.
It checks for pending stop signals before the rename. The same mask remains
in force through the rename, directory sync, receipt read-back and direct
process exit. Pending signals after the checkpoint are discarded at exit.
The receipt step table independently attempts directory open, sync and close,
temporary-file cleanup when applicable, and diagnostics. A step failure
cannot skip the remaining cleanup or change the published result. A final
directory-sync failure leaves the file visible at runtime, but a crash may
lose the rename.

After teardown and publication, the CLI reads `launcher_exit` from the
published marker. A missing or unreadable marker, or an invalid status,
returns a nonzero exit. The CLI uses a direct process exit so Python
shutdown hooks cannot replace the result. The external flock releases its
lock when the launcher exits. The launcher has already reaped QEMU and
closed the guest descriptors and anonymous overlay before committing success.
SIGKILL, power loss and external termination of the flock are outside the
orderly exit contract.

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
