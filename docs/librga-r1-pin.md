# librga R1 platform pin [EXISTS]

The runtime pin now selects `librga2-ceralive 1.10.5+ceralive.1` by URL and
SHA-256 in `manifests/rk3588-userspace-deb-versions.txt`. The full R0 rename
already landed in [PR #166](https://github.com/CERALIVE/image-building-pipeline/pull/166),
merge `3853a0835dee1a92dcbf85499174e1f1ff17012e`: family declaration, both
production fixtures, virtual-package contract and platform parity list remain
correct without another rename.

R1 fixes the inherited YUV-destination blend rejection even when a valid RGB
pattern supplies the background. R0 cannot perform that composite pass. This
pin makes the released fix available to image construction; it is not a PiP
delivery or hardware-qualification receipt.

## Published and served bytes — 2026-09-16

[Release `1.10.5+ceralive.1`](https://github.com/CERALIVE/librga/releases/tag/1.10.5%2Bceralive.1)
was published at `2026-09-16T22:02:05Z`, targeting
`d57bc86e65b331948953442449618cadd3b0c7bc`.

Both arm64 stanzas resolve in
[`dists/stable/binary-arm64/Packages`](https://apt.ceralive.tv/dists/stable/binary-arm64/Packages).
Each `Filename: ./<asset>` resolves relative to that directory. Both APT downloads
were byte-compared with separate `gh release download` assets using `cmp`;
SHA-256 was computed independently on all four archives with `sha256sum`.
Both published sidecars also passed `sha256sum --check`; GitHub asset digests
and index SHA256 fields agreed.

| Package | Bytes | Computed SHA-256 (GitHub = APT) |
|---|---:|---|
| `librga2-ceralive` | 84552 | `5f8ea1f259b95d5bf6fbe68edf03bf08820ab7bc8d4d17bfc1fc4a00344c7bb3` |
| `librga-ceralive-dev` | 24684 | `8dd35334ed1022ff8e64a86b3ac426abb847bf36f3ccff2746a658ccc0d8577a` |

Release assets:

- [Runtime archive](https://github.com/CERALIVE/librga/releases/download/1.10.5%2Bceralive.1/librga2-ceralive_1.10.5%2Bceralive.1_arm64.deb)
- [Development archive](https://github.com/CERALIVE/librga/releases/download/1.10.5%2Bceralive.1/librga-ceralive-dev_1.10.5%2Bceralive.1_arm64.deb)

APT copies:

- [Runtime archive](https://apt.ceralive.tv/dists/stable/binary-arm64/librga2-ceralive_1.10.5+ceralive.1_arm64.deb)
- [Development archive](https://apt.ceralive.tv/dists/stable/binary-arm64/librga-ceralive-dev_1.10.5+ceralive.1_arm64.deb)

**These are not the local candidate archive hashes.** The supplied local-build
runtime was `724834d6e122ab17e6d338c356e6bf7a0849aedfc969683ca45374cbeb7bcb0f`;
dev was `77509b8b1bd52578c7cbf2f0ebbeaff720377fb9f33fb07d34790268ae2b4489`.
This receipt pins the published bytes and does not infer the cause of that
difference or transfer candidate hardware evidence across the archive boundary.

## Layer, paired development pin and rollback

The runtime stays platform-layer, never in `REPOS`, `FIRST_PARTY_APT_PKGS` or
the app-layer fetch path. The matching dev package remains a first-class
indexed/retained build dependency, with its URL+SHA coordinate in
`manifests/librga-dev-deb-versions.txt`. The runtime-contract suite checks both
pins against the independently verified release identities. The dev file is
not an image-fetch input; no family requests its headers, `librga.pc` or
unversioned link, so the installed-image package set is unchanged.

Both runtime predecessors survive above the active row: the original Radxa
coordinate, then published R0. R0 rollback replaces the active runtime row
with its preserved coordinate and selects the matching dev coordinate. Radxa
rollback additionally needs the coordinated package-name reversal documented
in the R0 receipt; uncommenting a pin while the family still requests the fork
is not sufficient. Intentional rollback must also satisfy the existing
[pin-currency exception policy](first-party-pin-currency.md), not bypass it.

## Qualification boundary

`dpkg-deb --info` confirms the runtime still provides `librga2 (= 2.2.0)` and
conflicts/replaces `librga2`; the dev package requires exactly
`librga2-ceralive (= 1.10.5+ceralive.1)`. Both archives contain only a `control`
file in their control archive: **no maintainer script or trigger runs
`ldconfig` on their behalf**. Package presence/version is therefore not proof
that normal loader resolution uses R1 rather than an older library.

This change permits hardware-free guards and `DRY_RUN=1` plans only. Real
image construction, flashing, board commands, normal-loader identity and
composition acceptance belong to the separate image/board lane. No engine,
plugin, kernel, first-party app pin, or `versions.yaml` entry changes here.

## Hardware-free validation

- Full registered `./run-tests` passed with Avahi, RAUC and privilege-drop
  contracts all `required`. The 813-case Bats set retained two existing host
  availability exclusions: no built runtime tree for the real-unit `Also=`
  premise, and host mkosi 27 rather than pinned 26. No exclusion was added.
- All tracked shell files passed CI-threshold ShellCheck; manifest schema
  validation passed. All four RK3588 board × `edge`/`edge-test` dry-runs
  selected the published R1 runtime URL and digest.
- The runtime contract passed 33 assertions. A deliberately wrong 64-hex
  runtime SHA produced exactly its intended failure (32 pass / 1 fail); the
  verified digest was restored before commit.
- The authenticated catalog refresh first exposed R0 as stale; the unchanged
  `ci/check-first-party-pins.py` currency guard then reported R1 current at the
  stricter 24-hour bound. Its 26 unit cases passed after historical R0 fixture
  inputs were frozen on both sides, like the existing engine/plugin fixtures.
  No assertion, production checker, rollback override or workflow was weakened.
