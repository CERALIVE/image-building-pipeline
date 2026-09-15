# librga R0 platform-layer swap

The RK3588 image selects `librga2-ceralive` **1.10.1+ceralive.1** through
`manifests/rk3588-userspace-deb-versions.txt`. This is R0 only: a compatibility
rebuild of the 1.10.1 API embedded in Radxa's `librga2 2.2.0-1`, whose 2.2.0
label is a packaging version, not the API version. R0's neutrality evidence is
bounded to ELF export-set containment, request-byte goldens on the CeraLive
call set, and the separate both-board gate. It is not a feature release.

## Verified release inputs

Resolved from `gh release view '1.10.1+ceralive.1' --repo CERALIVE/librga`:
[R0 release, published 2026-09-13](https://github.com/CERALIVE/librga/releases/tag/1.10.1%2Bceralive.1).
Both downloaded archives match their release checksum sidecars and GitHub asset
digests. Their exact public download URLs were also fetched and hash-checked.

| Package | Release asset | SHA-256 |
|---|---|---|
| Runtime | [librga2-ceralive_1.10.1+ceralive.1_arm64.deb](https://github.com/CERALIVE/librga/releases/download/1.10.1%2Bceralive.1/librga2-ceralive_1.10.1%2Bceralive.1_arm64.deb) | `7c59bade43e2f8bb4c31e0ae965bee480128aa128528fdc88e8bc082e98ec498` |
| Development | [librga-ceralive-dev_1.10.1+ceralive.1_arm64.deb](https://github.com/CERALIVE/librga/releases/download/1.10.1%2Bceralive.1/librga-ceralive-dev_1.10.1%2Bceralive.1_arm64.deb) | `b0eba393b056b68f6bca346c4d6e18edcd91cd44066e5a69630435752bed6e11` |

`dpkg-deb -f` on the runtime reports `Provides: librga2 (= 2.2.0)`,
`Conflicts: librga2`, and `Replaces: librga2`. `readelf -d` on its
`usr/lib/aarch64-linux-gnu/librga.so.2.1.0` reports SONAME `librga.so.2`;
the runtime owns the `librga.so.2` symlink. Its libc floor is `libc6 (>= 2.38)`,
compatible with the image's Trixie base, not a claim of Bookworm compatibility.

The dev package declares `Depends: librga2-ceralive (= 1.10.1+ceralive.1)`,
provides/conflicts/replaces `librga-dev`, and contains `/usr/include/rga/`,
`librga.pc`, and the unversioned `librga.so -> librga.so.2` development link.
It remains indexed, retained and protected alongside the runtime by the
distribution contract. That does not require installing build headers on a
device that compiles nothing; this image selects only the runtime. No publisher
or retention policy changes are part of this PR.

## Layer and rollback contract

The family declaration, both production-baseline fixtures, runtime-contract
test, and `lib/parity-check.sh` platform list all use `librga2-ceralive`.
GStreamer's dependency keeps the old virtual package name `librga2`; dpkg's
resolver is exercised by the contract test, including a missing-Provides
negative control. The MPP and GStreamer plugin pins are unchanged.

This is the same platform URL+SHA mechanism as the GStreamer fork, not a layer
move. Neither librga package is added to `REPOS`, `FIRST_PARTY_APT_PKGS`, or
`fetch-debs.sh`. The Radxa pin is preserved verbatim, commented directly above
the new runtime pin as the one-line artifact rollback reference. A complete
source rollback must also revert the coordinated package-name changes; merely
uncommenting the old pin while the family requests the fork is not a rollback.

## Verification boundary

Run the full hardware-free test gate from the README, then:

```sh
DRY_RUN=1 ./build rock-5b-plus
DRY_RUN=1 ./build orange-pi-5-plus
./build orange-pi-5-plus --variant edge
```

Real builds require the documented APT credentials and explicit RAUC signing
inputs. A dry run proves manifest selection only; a real image build proves
download, staging, dependency resolution and image assembly. Neither proves
boot or media behavior on a board. No flashing, OTA, slot mutation or board
commands are part of this change, and the separate island kernel-pin PR is
untouched. **R1 is unreleased, hardware-gated, and requires a separate later PR.**

### Local result — 2026-09-15

- ShellCheck at the CI warning threshold and manifest schema validation passed.
- The full registered `./run-tests` command passed with all three privileged
  hardware-free contracts set to `required`. The host retained two existing
  availability exclusions: the mkosi-26 parse probe (host mkosi is 27), and the
  native apt simulation in the kernel-freeze test (Arch host has no apt).
  No test was changed to skip or weaken an assertion.
- Both boards passed dry runs on **both `edge` and `edge-test`**, each selecting
  the R0 runtime filename, URL and digest above.
- One real Orange Pi `edge` build completed, with production signing mode,
  debug packages disabled and the frozen production partition labels. It fetched
  the runtime by URL, installed `librga2-ceralive 1.10.1+ceralive.1` in the
  platform layer, passed package parity and image assembly, and emitted
  `images/orange-pi-5-plus/20260915T061943Z.{rootfs.tar,raw,raw.xz,raucb}` with
  checksum sidecars. Local logs are in `test-results/librga-r0-swap/`.

These are local build artifacts, not a release or deployment. Neither board
was contacted, flashed or updated, and no RAUC slot was touched.
