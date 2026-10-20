# RAUC build-from-source — Todo 22 RAUC-version-path follow-up

**Status: [EXISTS]** — new build stage, functional and tested (real privileged
container: version check, D-Bus service ownership via the existing real-RAUC
contract harness, `apt-mark` freeze proof), not yet exercised by a full board
image build. This document records the owner's binding 2026-09-24 decision to
build RAUC 1.15.2 from source rather than ship Trixie's 1.13 package.

## Why this exists

Debian trixie ships RAUC `1.13-3+deb13u1`. That version cannot mount a
dm-verity RAUC bundle on this repo's mainline/edge 7.2 kernel track: the status
format RAUC's `dm-verity` check expects changed upstream for Linux >= 6.19, and
the fix landed in RAUC `v1.15.1` (upstream PR #1846). This was found blocking
Todo 22's verity-bundle work — see the `learnings.md` entry "Todo 22 — BLOCKED:
RAUC 1.13 cannot mount verity on Linux 7.2 (2026-09-24)".

The owner's ruling selected upstream RAUC `v1.15.2`, packaged from source
inside this pipeline (no CeraLive-owned fork repo, no CeraLive patches to
either upstream or Debian's own packaging) over a narrow backport patch onto
1.13, since a hand-maintained patch series would be a more durable fork than
just building the real upstream release.

## What gets built

- **Upstream source**: `https://github.com/rauc/rauc/releases/download/v1.15.2/rauc-1.15.2.tar.xz`,
  pinned by static SHA-256 (`manifests/rauc-deb-versions.txt`). Independently
  cross-verified against Debian's own `rauc_1.15.2.orig.tar.xz` pool copy —
  byte-identical.
- **Debian packaging**: Debian **unstable**'s (`sid`) `debian/` directory for
  source version `1.15.2-1`, fetched and gpgv-verified against the signed
  unstable `InRelease` -> `Sources` index chain (same discipline
  `lib/fetch/index.sh`/`lib/fetch-debs-auth.sh` already use elsewhere in this
  pipeline — `index_release_digest`, `auth_verify_release_to_file`). **Not**
  trixie's own `1.13-3+deb13u1` packaging: empirically verified (via
  `patch --dry-run` against the extracted 1.15.2 tree) that four of trixie's
  six `debian/patches` entries are already incorporated upstream in 1.15.2
  (`Reversed (or previously applied) patch detected` / hunk `FAILED` for each),
  exactly matching what trixie's own `series` file labels them ("fixes from
  upstream", "CVE backports"). Debian's own unstable maintainer independently
  reached the same conclusion — unstable's series keeps only the two genuinely
  Debian-specific patches (`disable-network-tests.patch`,
  `install-wrapper-to-pkgdatadir.patch`), both of which apply CLEAN (zero fuzz)
  against 1.15.2. Reusing unstable's real, unmodified packaging directory is
  therefore MORE faithful to "reuse Debian's own recipe verbatim" than
  hand-patching trixie's onto the newer source would have been.
- **Zero CeraLive patches** to either source. The only edit
  `lib/rauc-build/source.sh::rauc_assemble_source_tree` makes to the fetched
  `debian/` tree is a single `debian/changelog` entry recording the CeraLive
  local-version build (`1.15.2-1+ceralive.1`) — the ordinary, unavoidable
  mechanism any downstream rebuild of a Debian source package needs.
- **Output**: `rauc_1.15.2-1+ceralive.1_<arch>.deb` (per-arch: `arm64` for
  rk3588, `amd64` for x86_64) + `rauc-service_1.15.2-1+ceralive.1_all.deb`
  (Architecture: all — confirmed against the real trixie/unstable source
  package: `Binary: rauc, rauc-service`, `Architecture: linux-any all`).

## Where it lives — ENTRY plus concern modules

Mirrors the "`build-kernel.sh` and `assemble-disk.sh` are ENTRIES plus concern
modules" shape this repo already uses everywhere (`AGENTS.md` KEY FACT), at
RAUC's own, much smaller scale (no ccache, no memory-derived `-j` clamp, no
multi-hour compile):

| File | Role |
|---|---|
| `lib/build-rauc.sh` | ENTRY — CLI (`--arch <arm64\|amd64> --out <dir>`), locations, `main()` |
| `lib/rauc-build/source.sh` | pinned fetch: upstream tarball (static SHA-256) + Debian packaging (gpgv-against-InRelease) + source-tree assembly |
| `lib/rauc-build/builder.sh` | container runtime selection, content-addressed **per-platform** builder tag, image build/reuse |
| `lib/rauc-build/package.sh` | built-`.deb` pair identity validation |
| `ci/Dockerfile.rauc` | dedicated builder image (separate from `ci/Dockerfile`/`ci/Dockerfile.kernel` — RAUC's build-dep closure shares almost nothing with either) |
| `manifests/rauc-deb-versions.txt` | pinned BUILD-INPUT coordinates (upstream URL+SHA-256, Debian suite/source-version/component, archive keyring fingerprints, the `+ceralive.N` local-version suffix) — a DIFFERENT shape from `rk3588-userspace-deb-versions.txt`'s package/filename/sha256/url rows, because this component has no CeraLive-owned fork repo and no prebuilt release asset to pin a row at (see the manifest's own header comment for the full contrast) |
| `lib/stages/rauc-build.sh` | orchestrator stage `[2c/9]` — **unconditional**, unlike `[2b/9]` (`kernel_source:`-gated): both shipped families ship RAUC |

`lib/orchestrate.sh` sequences it between `[2b/9]` kernel-build and `[3/9]`
partition, exactly like the kernel build's own placement, so the built `.deb`
pair flows through the SAME staged-`.deb` classification/uniqueness path as
anything fetched.

### Container platform handling

Unlike the kernel builder (one native-host container + a cross-compilation
toolchain), the RAUC builder is run under `docker run/build --platform` per
target architecture — native on an amd64 host for `amd64`, qemu-emulated
(binfmt, the SAME emulation `ci/Dockerfile`'s own mkosi container build already
depends on for arm64) for `arm64`. The builder image TAG is platform-qualified
(`ceralive-rauc-builder-linux-<arch>:<hash>`) — a single shared tag across two
platform-different image contents was found, empirically, to make
`docker run --platform linux/arm64` silently try to pull a nonexistent
registry image once an amd64-only image already existed under that tag.

### Test-suite handling

`DEB_BUILD_OPTIONS=nocheck` is passed to `dpkg-buildpackage`. Several of
upstream RAUC's own `meson test` cases (`test/dm.c`, `test/bundle.c`) need a
privileged loop/dm-verity device this ordinary (non-`--privileged`) builder
container does not grant — exactly the class of dependency Debian's own
`debian/control` already marks `<!nocheck>` (`dbus`, `e2fsprogs`, `fakeroot`,
`faketime`, `opensc*`, `softhsm2`, `squashfs-tools`). This is the documented,
standard `dpkg-buildpackage` mechanism those annotations exist for — not a
CeraLive-specific build-recipe edit.

## Delivery — platform-layer pin, runtime layer (not the arm64-only platform layer)

RAUC ships on **both** shipped families (rk3588 arm64 AND x86_64 amd64). The
existing "platform-layer URL+SHA swap" precedent (`gstreamer1.0-rockchip1` ->
`-ceralive`, `librga2` -> `-ceralive`) lives in `mkosi/mkosi.images/platform/`,
which `mkosi/LAYER-MAP.md` documents as **the ONLY arch-specific layer** — its
`mkosi.postinst` hard-exits for any non-`arm64` `ARCH`. RAUC therefore cannot
live there without breaking x86.

Instead, RAUC installs via a **new** `mkosi/mkosi.images/runtime/mkosi.postinst`
(non-chroot, auto-discovered by mkosi via filename convention — confirmed
empirically: `platform/mkosi.postinst` is discovered and runs with no
`PostInstallationScripts=` declaration in `platform/mkosi.conf` either). This
places RAUC in the layer `mkosi/LAYER-MAP.md` already documents as owning it
conceptually ("RAUC A/B client `rauc` + `u-boot-tools` | shared.list") and which
IS arch-identical, running `mkosi-install rauc rauc-service` from the SAME
`--package-directory` local repository the platform layer's own `mkosi-install`
already reads from (`lib/stages/partition.sh` now routes the `rauc`/
`rauc-service` package names into the BSP consumer directory alongside the
RK3588 platform-layer pins, since that's the local-repository mechanism, even
though the actual layer that installs them is runtime, not platform).

This non-chroot postinst runs BEFORE `mkosi.postinst.chroot`'s
`shared.list`-driven `apt-get install`, so `shared.list` simply no longer names
`rauc`/`rauc-service` at all — both rows are commented out there with a
rollback note, matching this repo's own established
gstreamer-rockchip/librga one-line-rollback convention (reinstate the two
plain lines, delete this stage's wiring, to revert to stock Debian RAUC).

## Freeze / hold

`rauc` and `rauc-service` are added to `freeze_boot_packages`'s held set
(`mkosi/customize/postinst.d/persistence.sh`), via a new `RAUC_PACKAGES`
variable with a fixed default (`"rauc rauc-service"`) — UNLIKE
`KERNEL_PACKAGES`/`DTB_PACKAGES`/`UBOOT_PACKAGES`/`FIRMWARE_PACKAGES`, this pair
is not board/family-manifest-resolved (the names are identical on every board),
so a fixed default matches the SAME pattern `CERALIVE_NEVER_FREEZE_PKGS`
already uses immediately above it. RAUC's own version can then only change via
a full, tested image OTA — never a stray `apt upgrade` — closing a pre-existing
gap (the plain `shared.list` rows were never held before this).

No collision with `CERALIVE_NEVER_FREEZE_PKGS`: RAUC is neither first-party nor
meant to be apt-updatable, so it belongs in the HELD set, and
`tests/kernel-freeze-guardrails.test.sh`'s Part A now statically asserts BOTH
directions (RAUC's default names both packages; `CERALIVE_NEVER_FREEZE_PKGS`
does NOT).

## Verification performed (this task's scope)

Both architectures built successfully via the real containerized pipeline
(`lib/build-rauc.sh --arch amd64|arm64 --out <dir>`), producing byte-real
`.deb` pairs with correct control identity
(`assert_deb_identity` in `lib/rauc-build/package.sh`).

A disposable privileged Debian trixie container (matching the technique
`tests/real-rauc-contract.sh` and the Todo 17/21/26 precedent already use)
proved, against the REAL built `rauc_1.15.2-1+ceralive.1_amd64.deb` +
`rauc-service_..._all.deb`:

1. `rauc --version` reports `rauc 1.15.2`.
2. `freeze_boot_packages()` — run for real, unstubbed — holds both packages via
   a real `apt-mark hold`, verified via a real `apt-mark showhold` readback and
   a real `apt-get install --only-upgrade` no-op against the held version.
3. **The EXISTING, pre-Todo-22 committed `tests/real-rauc-contract.sh`**
   (PLAIN-bundle-only — Todo 22's uncommitted verity-bundle work was
   deliberately NOT exercised; the real-rauc-contract test was run from a
   separate `git archive HEAD` checkout, not the dirty worktree, to guarantee
   this) — full `RESULT=PASS`: interruption/retry, explicit activation, signed
   cert-rotation, and three-attempt rollback, each phase starting `rauc.service`
   fresh and asserting `busctl --system status de.pengutronix.rauc` ownership as
   part of its own pass criteria.
4. `tests/kernel-freeze-guardrails.test.sh` — full PASS, Parts A through D,
   including the real `apt-get -s upgrade` simulation proving the hold+pin
   actually block an upgrade while `cerastream` stays upgradable.

**Out of scope for this task, deliberately**: building, installing, or
verifying a dm-verity RAUC bundle. That remains the next task's job, working
from this committed RAUC 1.15.2 package — this task's job ends at "a working,
pinned, tested RAUC 1.15.2 exists in the pipeline and the existing plain-bundle
contract still passes against it."

## Known follow-ups

- **A full board image has not been built against this pin.** The DRY_RUN
  build plan for `rock-5b-plus` was verified to include the new `[2c/9] rauc
  from pinned upstream source` stage correctly (arch-derived per family), but a
  real, non-DRY_RUN `./build` has not been run end-to-end with this stage —
  that is a substantially longer operation (the existing kernel-from-source
  stage alone takes tens of minutes) outside this task's practical scope.
- **`AGENTS.md`/`README.md` root-level cross-references were not added** in
  this task's commit. `AGENTS.md` and `README.md` are, at the time of this
  work, actively being edited by Todo 22's own uncommitted work in this same
  shared worktree (confirmed mid-task: `tests/preflash-verify.sh` — not
  present in this task's initial Todo-22 dirty-file snapshot — picked up new
  Todo-22 edits WHILE this task was in progress, proving Todo-22's editor is
  still live). Editing those two heavily-contested files risked either losing
  Todo-22's in-flight work or producing a corrupted merge of two concurrent
  writers' hunks. This document is the substitute technical write-up; a small,
  disentangled `AGENTS.md` "WHERE TO LOOK" row addition is a safe, low-risk
  follow-up once Todo 22's own edits land.
