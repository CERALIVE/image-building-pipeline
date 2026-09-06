# Full firmware, Bluetooth closure and populated-slot safety [PARTIAL]

RK3588 selects **only `armbian-firmware-full=26.8.3`**, replacing the trimmed
package. It remains a platform BSP input, never a first-party app package or
mutable sysext. The existing manifest-derived staging, `mkosi-install`, boot
freeze and RAUC slot-copy paths carry it without a second install/hold list.

This file is the contract. It is written WHY-first on purpose: every number below
was chosen against a measurement or a source read, and the number without its
reason is the thing a later change silently breaks.

---

## 1. Firmware provenance — why the FULL package, and what pins it

### Why the trimmed package had to go

`armbian-firmware` is a deliberately reduced blob set. That is fine for a board
whose radios are soldered on and known at build time, and it is exactly wrong for
a device an operator is expected to plug arbitrary USB Bluetooth and Wi-Fi
adapters into. The trimmed archive carries **926 regular files / 454,877,453 B**;
the full archive carries **5,306 / 2,337,962,673 B** — a net **+4,380 files /
+1,883,085,220 B** of blobs (2026-09-05 tar-member census of both authenticated
archives). Those 4,380 files are the difference between "this adapter works" and
"this adapter enumerates and never binds", and no amount of pruning can recover a
blob the archive never shipped.

The swap is a **package selection change only**: `firmware_packages` names the
full package, and full/trimmed coexistence is rejected outright rather than
resolved. Two packages both owning `/usr/lib/firmware` is not a bigger firmware
set, it is an undefined one.

### The double-check contract, and why one check is not enough

The pin is enforced twice, against two different classes of failure:

1. **Signed-index identity.** Both authenticated BSP transports (native apt and
   the curl fallback) verify `InRelease` with `gpgv` against the exact two-key
   Armbian rotation set, read the `Packages.gz` digest out of that *verified
   plaintext*, and require one unambiguous record for the exact
   `armbian-firmware-full=26.8.3` spec. This answers "did the archive we trust
   say this package exists at this version".
2. **Committed archive-content SHA.** `manifests/armbian-firmware-content.json`
   pins the SHA-256 of the **`.deb` archive file**, and the index record must
   match that pin *before the download pool starts* — regardless of whether the
   verified `.deb` cache is enabled. `fetch_bsp` then re-checks the staged bytes,
   the byte size, and the control `Package`/`Version`/`Architecture`/
   `Installed-Size`.

Check 1 alone is insufficient because **a same-version re-spin is a legal archive
operation**. Upstream may rebuild `26.8.3` and republish it under an unchanged
version string; the exact version pin cannot see that, the signature is still
valid, and the board silently gets a different firmware set than the one the
Bluetooth closure below was derived against. The content SHA is what makes that
substitution fail closed instead of shipping.

Check 2 alone is insufficient for the mirror-image reason: a hash with no
authenticated index behind it says the bytes are the bytes someone once wrote
down, not that the archive of record vouches for them. **Comparison is not trust.**

The pinned identity of record:

| Field | Value |
|---|---|
| Package / Version / Architecture | `armbian-firmware-full` / `26.8.3` / `all` |
| `.deb` archive SHA-256 | `13d10a85a1fa02a989eb2c3e9696f3c931bc9cf2b6059e435c4bd2c75ec53d19` |
| Archive bytes | `763716604` |
| `Installed-Size` (KiB) | `2283248` |

That SHA is the **archive file**, never installed content. Do not "improve" it
into an installed-tree digest: the prune below deliberately mutates the installed
tree, so an installed-content hash would be a moving target and could not be
checked before download — which is the one point where checking is still cheap.

Authentication record and the retired planning estimates:
[firmware preflight](firmware-content-preflight.md). Guards:
`tests/firmware-content.test.sh`, `tests/bsp-package-resolution.test.sh`,
`tests/kernel-freeze-guardrails.test.sh`.

---

## 2. Slot budget — why 3.5 GB, why 512 MiB, why those inode numbers

Three different limits govern one image, and conflating them is how a build
passes a gate and then fails on a board.

| Limit | Value (RK3588) | What it constrains |
|---|---|---|
| Slot geometry | `4096 MiB` (`SizeMinBytes` = `SizeMaxBytes` = `4294967296`) | **FROZEN.** The partition, per `docs/partition-contract.md` |
| Content ceiling | `3,500,000,000 B` | Apparent rootfs content size, checked at `[6c/9]` |
| Populated-slot reserve | `536,870,912 B` **bavail** + inode floor | Actual free space in the assembled ext4 |

### Why 3.5 GB and not 4 GiB

Before capacity inspection, each emitted image must carry the three intentional
device apt directives in `99ceralive`: `Acquire::Languages "none";`,
`Acquire::GzipIndexes "true";`, and `Acquire::CompressionTypes::Order "gz";`.
The build-sandbox translation policy remains separate. Guards:
`tests/apt-mtls-and-dedupe.test.sh` (executed twin outputs) and
`tests/mkosi-contract.bats` (both writers). Offline unit scans inspect image unit
files, not absolute aliases resolved against the host; the absolute-alias and
injected hard-dependency cases live in `tests/runtime-services.bats`.

Because apparent content bytes are not filesystem bytes, and the gap is not
small. Every file is rounded up to a 4 KiB block, and the full archive adds
~4,380 of them; the per-file rounding on the archive delta alone accounts for
~9.7 MB (`1,883,085,220 B` apparent → `1,892,814,848 B` rounded). On top of that
sit ext4's own metadata, the inode table, the journal and the root-reserved
block pool. A ceiling set at the partition size would therefore pass a build
whose slot cannot actually hold it.

3.5 GB leaves roughly 794 MiB of the 4 GiB slot for that overhead plus real
headroom — deliberately more than the 512 MiB reserve below, because the ceiling
is a *build-time estimate* and the reserve is the *measured truth*. The ceiling
exists to fail early and cheaply; it is not the safety property.

**x86 stays at 1,500,000,000 B.** It selects no Armbian firmware package at all,
so none of the reasoning above applies to it and raising it would be borrowing a
justification from a different board family.

The retired universal 1.5 GB placeholder and the pre-adoption per-board
measurements are preserved as history in [`size-notes.md`](size-notes.md). They
predate this adoption and are **not** measurements of it; no planning projection
in that file is a wet-build number.

### Why `bavail`, never `bfree`

`bfree` counts every free block, including the **root-reserved pool** that an
unprivileged writer can never touch, and including blocks ext4 has already
committed elsewhere. A gate on `bfree` therefore reports space that does not
exist for the process that needs it — it would pass a slot that is full in
practice. `bavail` is what a real writer can obtain, so it is what the gate
asserts, and the diagnostic prints `field=bavail` explicitly so a transcript can
never be misread as the weaker check.

For a clean, non-bigalloc ext4 image, the offline `dumpe2fs` equivalent of Linux
v7.2's `bavail` is:

```text
max(free_blocks - root_reserved_blocks - min(floor(total_blocks/50),4096),0)
  * block_size
```

The last subtraction is ext4's **internal extent reserve**, in addition to the
root-reserved pool (`ext4_init_reserved_space` / `ext4_statfs`,
`fs/ext4/super.c:4296-4320,6958-6982` at the v7.2 pin). Unclean or unsupported
filesystem metadata is refused, never guessed at. Compression ratios cannot
establish this reserve, and neither can the content ceiling.

### Why 512 MiB and why the inode floor is a `max()`

512 MiB is a **one-OTA-cycle working margin**, not a fudge factor. The slot has to
absorb, on a device already in the field: an apt transaction's downloaded
archives plus dpkg's transient unpack/backup peak (apt storage is *not* on
`/data` — every byte lands in the active rootfs slot), the journal before its
budget rotates it, and the log/config churn of a running appliance. A slot that
assembles with 40 MB free builds, boots, and then fails the first time an
operator presses Update.

The inode floor is `max(ceil(total_inodes / 10), 20000)` because the two terms
fail on opposite ends of the size range:

- **The 10% term** is what scales. On a large slot a fixed count would be
  proportionally trivial and would pass a filesystem that is nearly out of
  inodes while megabytes of blocks remain free — ENOSPC with free space is the
  confusing failure this term prevents.
- **The 20000 floor** is what holds on a small one, where 10% of a modest inode
  table is a number no real package transaction survives.

Neither term alone is sufficient, so the gate takes whichever is larger. The
boundaries are pinned in both directions by `tests/slot-reserve.test.sh`:
`536870911` RED / `536870912` GREEN; inode free `19999` fails the floor,
`total=200001 / free=20000` fails the ceiling-rounded 10%, `free=20001` passes.

### Where the reserve is enforced

One shared implementation, `lib/shared/slot-reserve.sh`, on every path that can
produce a slot:

- after either the host or the container `mkfs.ext4 -d` population step, **before**
  the slot is copied into the disk;
- again at preflash, against both sliced slots;
- standalone, exposed by the disk verifier:

```bash
lib/verify-disk.sh check-slot <populated.ext4> rootfs_a
```

Diagnostic shape (both slots reported independently):

```text
slot=rootfs_a field=bavail free=536870911 required=536870912
  inode_free=20000 inode_required=20000 inode_total=200000
```

**Production 4096M geometry is unchanged**, and the geometry-only verifier is
untouched. When a synthetic fixture could not satisfy the real reserve it was
GROWN (16M → 1024M), never exempted — a fixture small enough to dodge the
assertion proves the assertion does not run.

---

## 3. Prune and closure contract

### The Kconfig closure the prune exists to serve

`manifests/kernel/rk3588-edge.fragment` pins a **v7.2 maximum-stable Bluetooth
closure**: **37 positive symbols** (transports, protocols, per-vendor helpers,
`UHID`, and `SQUASHFS_ZLIB`) and **12 negative symbols plus
`BT_HCIBTUSB_AUTOSUSPEND`**, each declared explicitly rather than left to a
default. Every positive resolved to exactly its declared value and every negative
resolved off in the real production-toolchain solve; the unchanged verifier
reported `221 of 221 declared symbol(s) survived` and `206 required and 93
forbidden symbol(s) hold`.

"Maximum-stable" is the whole design: enable every transport and vendor family
the tree supports and that a shipped blob can serve, and explicitly disable the
test/debug surface (`BT_HCIVHCI`, the selftests, `BT_DEBUGFS`) plus USB
autosuspend, which is a real cause of adapters that work and then stop working.

Two entries look like they do not belong and do:

- **`SQUASHFS_ZLIB=y`** — the add-on `.raw` producer (`lib/app-layer/sysext.sh`)
  invokes `mksquashfs` with no `-comp`, so the artifact carries the built-in gzip
  default, and `systemd-sysext` merges it through the kernel. Only `SQUASHFS` and
  `SQUASHFS_ZSTD` were previously declared; gzip support merely *happened* to
  survive the base config. It is now pinned to the codec the producer actually
  emits. RAUC's plain-bundle path uses userspace `unsquashfs` and does not
  motivate a kernel decompressor.
- **`BT_HCIUART_SERDEV=y`** is promptless (`default y`). Its fragment line is a
  *survival assertion*, not a directive — the same discipline as
  `CONFIG_TYPEC_FUSB302=m`. Declare the honest resolved value or the gate is
  checking nothing.

Guard: `tests/kernel-config-fragment.bats` (55 cases). Each positive is
individually dropped and individually flipped `y`↔`m` in a checker fixture, and
each negative individually enabled at both `y` and `m` — so the manifest cannot
be edited without a named rejection.

### How the firmware roots are DERIVED, never authored

The retained set is the output of a real `modinfo` sweep over a real built module
tree, not a hand-written allowlist:

1. Build the production kernel through the documented `[2b/9]` entry and extract
   the resulting package (`dpkg-deb --extract`; no maintainer script runs).
2. Seed from that tree's own `kernel/drivers/bluetooth/*.ko`,
   `kernel/net/bluetooth/**/*.ko` and the `UHID` object.
3. Recursively follow each `modinfo -F depends` list, resolving every dependency
   **against that extracted package** (`modinfo -b <extracted> -k <release>`).
4. Take every static reference from `modinfo -F firmware` on the resulting
   closure.

That produced **26 modules** and **71 distinct module/reference rows** (the
scanner also discovered `btrsi`, which no guessed adapter allowlist would have
contained). Host modules are never substituted for a dependency — a host module
answers a question about the host.

A static source grep cannot replace this, and the reason is load-bearing:
`MODULE_FIRMWARE()` names are frequently macro-composed, so a literal grep of the
kernel tree finds nothing for drivers that demonstrably request firmware. Only
`modinfo` against **built** modules is truthful.

The shipped checker rederives all of this on whatever tree it is given:

```bash
lib/check-bluetooth-firmware.sh \
  <rootfs>/usr/lib/modules/<kernel-release> <rootfs>/usr/lib/firmware
```

Kernel package hashes recorded during derivation are **evidence bindings only**,
never reproducibility pins. A later image must be checked against **its own**
installed modules; a passing check on a previous kernel says nothing about this
one.

### The three manifest classifications

`manifests/rk3588-bluetooth-firmware-roots.txt` admits exactly three, and the
parser enforces the distinction rather than trusting the comment beside each row:

- **`static`** — an exact module/reference pair taken from real `modinfo` output.
- **`runtime-composed`** — a reviewed driver that builds its firmware name at
  runtime, recorded with its source rationale. Every declared root must contain
  real objects. This is a retention mechanism for a *family*, and it is
  explicitly **not** a waiver for an arbitrary missing static reference that
  happens to live in the same directory.
- **`reviewed-hardware-gap`** — see below. Exactly two rows, both module- and
  path-bound. A third row, or a wildcard, is rejected.

### The reviewed-hardware-gap exception, stated honestly

The pinned full archive supplies **69 of the 71** static references. Two are
absent, and this is measured before any prune runs — so retaining more files
cannot fix it:

```text
FAIL module=btmrvl_sdio missing_static_firmware=mrvl/sd8987_uapsta.bin
FAIL module=btmtk missing_static_firmware=mediatek/mt7927/BT_RAM_CODE_MT6639_2_1_hdr.bin
static_reference_missing_count=2
```

**Both are genuinely static, and neither was reclassified to make the gate pass.**
That distinction is the point of this section:

- `drivers/bluetooth/btmrvl_sdio.c:283-285` sets `.firmware` to the literal
  `mrvl/sd8987_uapsta.bin`, `:571` passes `card->firmware` straight to
  `request_firmware`, and `:1780` advertises the same `MODULE_FIRMWARE` string.
  There is no runtime composition anywhere on that path. `nxp/uartuart8987_bt.bin`
  is a different UART payload and is **not** a verified substitute for the SDIO
  image.
- `drivers/bluetooth/btmtk.c:115-117` *does* compose the MT6639 name at runtime,
  but the archive carries no Bluetooth object in `mediatek/mt7927/` at all — only
  the Wi-Fi payloads `WIFI_MT6639_PATCH_MCU_2_1_hdr.bin` and
  `WIFI_RAM_CODE_MT6639_2_1.bin`, neither of which is a Bluetooth substitute. Its
  static `MODULE_FIRMWARE` declaration is present at `:1586`. Recording its
  runtime naming would not make the missing payload exist, so it is **not**
  classified `runtime-composed`.

The exception is therefore an **owner-reviewed statement about hardware scope,
not about firmware completeness**: no currently shipped target uses Marvell
SD8987 SDIO Bluetooth or MT7927. Both modules are carried for future and
third-party hardware. The board basis is this repository's own root `AGENTS.md`
firmware-prune and wireless sections — the `brcm/`, `rtl_bt/` board paragraph
under "Firmware is pruned only where an installed-module sweep proves no
consumer" — together with `manifests/families/rk3588.yaml:98-110`, which names
the Rock's **RTL8852BE** and the Orange's **AP6275P/Broadcom** radios;
`docs/kernel-build-from-source.md:268-270` agrees. A fitted Orange **MT7925** is
separately recorded and is **not** an MT7927 qualification.

The consequence, stated plainly: an operator who attaches an SD8987 or an MT7927
Bluetooth adapter to a current board gets a driver and no firmware. That is a
known, bounded gap with a named unblock (ship the blob, or drop the module from
the closure), not a silent one.

The parser restricts hardware-gap rows to exactly those two module/path pairs.
Adding a third is a red test, which is what stops this category becoming the
place future missing blobs get filed.

### What the prune may and may not delete

The platform postinstall snapshots every declared object **before** pruning,
protects it from candidate deletion, and re-checks survival afterwards. Retained
by name with their blocking reference cited: TI's `ti-connectivity/TIInit_*.bts`,
Broadcom `.hcd` objects at the firmware root and under `brcm/`, `ap6210/`,
`ap6212/`, `ap6275p/`, NXP objects under `nxp/`, and every other enabled vendor
family. Only families a real `modinfo` sweep proves unconsumed are removed — on
the recorded run, `qcom`, `updates` and `microchip`, while referenced
Intel/Atheros/NVIDIA families were kept.

**Missing tooling can never authorize a deletion.** With `modinfo` unavailable the
full-image closure preflight FAILS and the legacy generic sweep declines without
deleting anything. An empty consumer set means "we could not prove", never
"nothing is consumed" — an inverted fail-safe here deletes the entire firmware
tree on a builder that is merely missing `kmod`.

Guards: registered `tests/full-firmware-bluetooth-closure.test.sh` (28 cases —
a synthetic third missing object, an unknown-but-present static reference, a
missing root or object, duplicate/traversal/broad globs, unapproved exceptions,
candidate deletion, absent `modinfo`, zero parsed modules, recursion outside the
Bluetooth directory, and production preflight ordering) plus the unchanged
`tests/firmware-prune.test.sh` (42 cases). The mutation legs are the evidence
that matters: deleting a real `rtl_bt/rtl8852bu_fw.bin` made the checker exit
non-zero naming `module=btrtl`, that exact path and `missing static object`, and
restoring it returned GREEN with only the two approved gap diagnostics.

---

## 4. Hardware-honesty contract

The single most useful sentence in this file is the one that says what has **not**
been proven, so it is stated separately from everything above.

### Proven, and by what

| Claim | How |
|---|---|
| The pinned archive is the archive of record | Both GPG signatures re-verified on the retained `InRelease`, its `Packages.gz` digest, the committed pin against that index, and the actual `.deb` archive SHA recomputed to `13d10a85…` |
| The 37/12+1 Kconfig closure resolves exactly | Real production-toolchain solve; `221/221` declared symbols survived, `206` required and `93` forbidden hold, `0` reviewed exceptions |
| The firmware closure is real, not guessed | `modinfo -F firmware` run independently over all 26 retained closure modules; 26 modules / 71 references, **69 present, exactly 2 absent** |
| The two absences are genuine and correctly classified | Direct reads of `btmrvl_sdio.c:285,571,1780` and `btmtk.c:1586` / `btmtk.h:11`; a fresh `dpkg-deb --fsys-tarfile \| tar -tf` confirms both exact paths absent |
| The prune retains what it claims | The real prune run on a reflink copy of the full archive plus the real module tree; every snapshotted entry survived; a deliberately deleted `rtl_bt` object produced the named RED and restoration returned GREEN |
| The reserve gate is real, not synthetic-only | A real populated 1 GiB ext4 fixture passes; mutating its root-reserved-block pool makes it fail while `bfree` would still overstate usable space; restoring 5% passes |
| The gates run in the default suite | Complete three-`required` gate exit 0; closure suite 28/28, slot reserve 29/29, legacy prune 42/42, Bats 803 cases / 801 passed / 0 failures (two pre-existing environment skips) |

### NOT proven, and not claimed anywhere

- **No production image has been built with this firmware pin.** Everything above
  is archive-level, module-level, and synthetic-assembled-filesystem evidence.
  Both RK3588 images still owe a real build and inspection, which is a separate
  gate; until it runs, the honest phrasing is "the pipeline pins it", never
  "devices ship it". In particular there is **no wet measurement** of either
  board's rootfs against the 3.5 GB ceiling, and **no measurement** of a real
  assembled slot's `bavail`/inode reserve at production geometry — the reserve
  evidence above is a 1 GiB fixture and a synthetic 1024M partition.
- **No board has been flashed with a full-firmware image**, so nothing here has
  booted on real hardware.
- **No new Bluetooth or Wi-Fi adapter has been physically attached** to a board
  running this firmware set. Blobs present plus drivers built is **not** an
  attachment result, and no sentence in this repository may say a listed adapter
  or dongle is "supported", "proven" or "validated" on the strength of it. The
  correct phrasing is *firmware and driver carried; hardware not yet validated*.
- **No Bluetooth microphone has been exercised** end to end on the new closure.
- The two `reviewed-hardware-gap` chips are **the opposite** of validated: their
  firmware is known absent and the modules exist for future and third-party
  hardware only.

Root-level truth for this boundary — the build-proven versus physically-unverified
row across the whole workspace — is owned by the workspace root documentation, not
by this file.
