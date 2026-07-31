# Kernel build from source (opt-in family variants)

The device image normally installs a **prebuilt Armbian vendor kernel** (`.deb`
fetched from the signed Armbian archive). That is decision **D3**, it is
unchanged, and it is the only path any shipped image has ever taken.

This document describes an **optional, explicitly opt-in** alternative: build the
kernel and its in-tree DTBs **from pinned source** with the CeraLive RK3588 patch
series applied, and use the resulting `.deb` instead of the Armbian one.

> **Nothing here is on the production path.** With no variant selected, the
> resolver strips the variant machinery entirely and the resolved build
> parameters are **byte-identical** to the manifest before variants existed.
> That is pinned by committed fixtures — see [§6](#6-how-the-vendor-path-is-proven-unmoved).

---

## 1. The variant model

`v2/manifests/schema/family.schema.json` gives a family an optional `variants:`
map. Its keys are variant names; each value is a **narrow** overlay that may set
only `armbian_branch`, `kernel_packages`, `dtb_packages` and `kernel_source`.

Resolver merge order becomes:

```
family defaults  ->  variant overlay  ->  board overrides      (board wins last)
```

A board fact can never be overridden by a family variant, which is what keeps
per-board data (DTB name, U-Boot package, interface map) authoritative.

`default` is a **reserved** name meaning "apply no overlay". The schema refuses a
variant literally called `default`, because a family that could override the
default path from inside its own variants map would make the production build
silently configurable.

### Selecting one

```bash
v2/build rock-5b-plus --variant edge
CERALIVE_KERNEL_VARIANT=edge v2/build rock-5b-plus     # same thing
v2/lib/resolve.sh rock-5b-plus --variant edge          # resolve only
```

Selection is **explicit only**. Nothing infers a variant from the board, the
host, the git branch or the environment beyond that one variable, and `--variant`
is refused for a multi-board selection (`--all` / `--only`): an rk3588 kernel
overlay applied to an x86 board is not a thing anyone means.

---

## 2. What `kernel_source:` pins

Every input is exact-pinned, and each pin is **verified after checkout** rather
than trusted:

| Field | What it pins |
|---|---|
| `git_url` + `tag` + **`commit`** | the kernel source. `commit` is the real pin; the build fails if `tag` does not resolve to it, so a moved tag is caught instead of silently building different source |
| `patches_git_url` + **`patches_commit`** + `patches_series` | the CeraLive patch series. `patches_commit` must be a 40-hex SHA — the schema and the build stage both refuse a branch name |
| `defconfig_base` + `defconfig_fragment` | the config. Repo-local fragment, merged onto the in-tree defconfig |
| `builder_image` | the toolchain, as a `repo:tag@sha256:<digest>` |
| `local_version` + `kernel_release` + `package_version` | the produced package's identity |
| `dtb_deb_dir` + `dtb_boot_dir` | the platform-layer DTB install mapping ([§4](#4-the-dtb-install-mapping)) |

**Why the patches repo is pinned like a BSP input.** It is one. It contributes
~4,900 lines to the kernel the device runs. A floating `main` there would leave
the build reproducible in appearance and not in fact. Today's pin is
`CERALIVE/rk3588-kernel-patches@4809354656a16443c0b69f1e72b77f3fea1cbdae` — the
merge of that repo's PR #1, which is CI-green applying against exactly `v7.1.5`.

**Why we pin a tag when Armbian tracks a branch.** Armbian maps rk3588
`BRANCH=edge` to `KERNEL_MAJOR_MINOR=7.1` and then follows the **rolling** branch
`linux-7.1.y`. "Verified against linux-7.1.y" is not a reproducible claim, so we
pin the tag that was its tip at import (`v7.1.5` = `155b42bec9cb`). That mapping
is re-derived from `armbian/build` by the patches repo's `scripts/preflight.sh`
and recorded in its `kernel-pin.env`.

---

## 3. The build backend — and what it is not

**Backend: plain kernel `make bindeb-pkg`.** `v2/lib/build-kernel.sh` clones the
pinned source, applies the series with `git am`, merges the defconfig fragment,
and runs `make bindeb-pkg` — all inside the digest-pinned builder container
(`v2/ci/Dockerfile.kernel`), cross-compiling with `aarch64-linux-gnu-` and a
persistent `ccache`.

**The Armbian build framework is NOT the build system here.** It is consulted for
exactly one thing — the `edge` → kernel-version mapping, upstream in the patches
repo's preflight — and is never invoked. Adopting Armbian's framework would bring
its own patch stack, kernel config, packaging and userspace assumptions, and
would make "what exactly is in this kernel" unanswerable from this repo. The
whole point of this stage is that the answer is three pinned SHAs and one
reviewed fragment.

**Output contract:** exactly **one** `linux-image-*` `.deb`, containing the
kernel and the in-tree DTBs. `bindeb-pkg` also emits `linux-headers-*` and
`linux-libc-dev`; both are **discarded before staging** (the device image
installs neither). The build fails if the expected `linux-image` deb is missing
or if more than one matches.

**Validated, not assumed.** Before staging, the built `.deb` is checked on four
axes against the manifest: control `Package:`, control `Version:`, control
`Architecture:`, and the presence of the board's own DTB at
`dtb_deb_dir/<dtb_name>`. A mismatch on any of them is fatal — the orchestrator's
package-name replacement and the boot script's `fdtfile` lookup both depend on
these being true, and a mismatch would otherwise surface as an unbootable board.

---

## 4. The DTB install mapping

An Armbian `linux-dtb-*` package lands the board DTBs exactly where the U-Boot
boot script looks them up. `make bindeb-pkg` does not — it ships in-tree arm64
DTBs **inside** the `linux-image` deb:

```
/usr/lib/linux-image-<KERNELRELEASE>/<vendor>/   (kernel_source.dtb_deb_dir)
        -> copied by mkosi.images/platform/mkosi.postinst to ->
/boot/dtb/<vendor>/                              (kernel_source.dtb_boot_dir)
```

`/boot/dtb/rockchip/${fdtfile}` is precisely what
`v2/mkosi/platform/boot/boot.scr.cmd` resolves, so a source-built kernel
satisfies the **same** board `dtb_name` expectation with no change to the boot
script, the board manifest or the disk assembler.

Both paths are empty on the vendor path, so the copy step is a strict no-op
there. When enabled it is fail-loud: a missing source directory, a half-specified
mapping, or a missing board DTB aborts the build rather than producing an image
that boots to a device-tree-less kernel.

---

## 5. Integration semantics

Three things change when a `kernel_source:` block resolves, and only then:

1. **Remote fetch is suppressed** for the kernel/DTB package names.
   `resolve.py` derives `KERNEL_SOURCE_SUPPRESSED_PACKAGES` as the union of the
   *pre-overlay* family names (still present in the family file, which
   `fetch-debs.sh` reads directly) and the *post-merge* built names (which no
   remote archive carries). The orchestrator forwards it as
   `CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS`, and `collect_declared_bsp_pkgs`
   filters it out — so a suppressed package is invisible to **every** remote path
   at once. **U-Boot and firmware are never in that set** and stay
   prebuilt-fetched.

   The list is *derived*, never authored: the schema rejects a manifest that
   tries to declare it, because a hand-written suppression list would drift from
   the replacement list the moment either changed.

2. **The built package names replace the family's** for resolver and orchestrator
   purposes. That falls out of the ordinary variant merge — the overlay's
   `kernel_packages` replaces the family array — and the names are validated
   against the real built control fields ([§3](#3-the-build-backend--and-what-it-is-not)).

3. **A staged-package uniqueness check** fails the build if any package name has
   **both** a fetched and a locally-built candidate. Suppression is what should
   make that impossible; this check is what proves it did. Without it, mkosi's
   local repository would silently pick one by version and the image would ship a
   kernel nobody chose — a plausible-looking image instead of an error, which is
   the worst failure mode available here.

Stage order in `v2/lib/orchestrate.sh` is `[2/9] fetch` → `[2b/9] kernel build` →
uniqueness check → `[3/9] partition`. The build sits after the fetch so the check
sees the complete fetched set, and before partitioning so the built `.deb` flows
through exactly the same classification and staging path as a fetched one.

---

## 6. How the vendor path is proven unmoved

`v2/tests/manifests/fixtures/vendor-baseline/<board>.params` holds the resolver's
full output for all three shipped boards, captured **before** any of this
existed. `manifest.bats` diffs the live resolver against those fixtures for
`rock-5b-plus`, `orange-pi-5-plus` and `x86-minipc`, with no variant, with an
explicit `--variant default`, and with `CERALIVE_KERNEL_VARIANT=default`.

The comparison carries an explicit **non-vacuity** leg: the same diff run against
the `edge` resolve must **fail**. A golden-file check that silently compares
nothing is worse than no check, so the suite proves the check can fail.

Alongside it: `VARIANTS_*` must never appear in any flattened param set, the
vendor `DRY_RUN` must still declare its 4-package Armbian BSP set (the
non-vacuity leg of suppression), and the x86 dry-run must be untouched by any of
this.

---

## 7. Known gaps — read before using this

Honest status: **nothing here has been compiled or booted.** This todo delivered
the pipeline, the schema, the pins and the gates. The experimental image build is
the next step.

1. **The kernel is not built in CI.** The PR gate runs `DRY_RUN=1`, which emits
   the plan and touches no network, container or compiler. A real kernel build is
   a multi-GB clone and a long cross-compile; wiring it into the PR gate would be
   a separate, deliberate decision about CI budget.
2. **The defconfig fragment is reviewed intent, not a validated result.** It
   starts from mainline `defconfig` and adds what the CeraLive stack needs. No
   symbol in it has been proven necessary *or* sufficient on hardware.
3. **Mainline and the Armbian vendor BSP do not always agree on RK3588 DTB
   filenames.** `orange-pi-5-plus.yaml` declares `rk3588s-orangepi-5-plus.dtb`
   (the vendor name); mainline v7.1 names that board's DTB
   `rk3588-orangepi-5-plus.dtb`. The build stage therefore **fails loudly** for
   that board with the available DTB names listed. This is deliberate — it
   surfaces a real divergence at build time instead of producing a board that
   does not boot. Resolving it (a per-board DTB name under the variant, or a
   rename) belongs with the experimental image build, on a board.
4. **No `.deb` produced by this stage may be published.** It is a local build
   input only; nothing here uploads to apt/R2.
5. **D3 is not reopened.** The shipped kernel is still the Armbian vendor BSP.
   See [`kernel-currency-watch.md`](kernel-currency-watch.md) for the two precise
   triggers that would revisit that decision; this variant existing is not one of
   them.

---

## 8. Files

| Path | Role |
|---|---|
| `v2/manifests/schema/family.schema.json` | `variants:` map + `kernel_source:` `$defs` |
| `v2/manifests/families/rk3588.yaml` | the `edge` variant declaration + every pin |
| `v2/manifests/kernel/rk3588-edge.fragment` | the Kconfig fragment |
| `v2/lib/resolve.py` | variant merge, `variants:` stripping, derived suppression set |
| `v2/lib/resolve.sh` | `--variant` / `CERALIVE_KERNEL_VARIANT` |
| `v2/lib/build-kernel.sh` | the build stage |
| `v2/ci/Dockerfile.kernel` | the builder image (base digest comes from the manifest) |
| `v2/lib/orchestrate.sh` | stage wiring, suppression export, uniqueness check |
| `v2/lib/fetch-debs.sh` | suppression filter in `collect_declared_bsp_pkgs` |
| `v2/mkosi/mkosi.images/platform/mkosi.postinst` | the DTB install mapping |
| `v2/tests/manifest.bats` §26 | 36 tests, incl. the byte-identity proof and its teeth |
| `v2/tests/manifests/fixtures/vendor-baseline/` | the pre-change golden resolver output |
