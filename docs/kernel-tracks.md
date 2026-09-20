# Kernel Tracks — Index

This is a thin discoverability index, not a new source of truth. It exists so
that "which repo feeds which variant, and where do I read more" has one place
to start. Every substantive claim lives in the documents this page links to —
if you find a fact repeated here, that is a bug in this page, not a feature.

## Which track is PRODUCTION

`rk3588` declares `default_variant: edge`, so a variant-less `./build <board>`
resolves the `edge` overlay — the mainline 7.2 kernel built from source — and
does so byte-identically to `./build <board> --variant edge`, the board's own
`variant_overrides.edge` included.

```
./build rock-5b-plus                       # mainline 7.2, built from source
./build rock-5b-plus --variant edge        # the same thing, named explicitly
./build rock-5b-plus --variant edge-test   # its never-released debug sibling
```

`default_variant` is a POINTER, not a copy of the pins. Copying `edge`'s block to
the family top level would force `edge-test` (which `extends: edge`) to restate
its parent's pins — the exact byte-for-byte drift `extends` exists to prevent.

## The retired Armbian vendor 6.1 BSP track

**It is retired from this pipeline, and nothing here consumes it.** Both overlays
that carried it — the prebuilt `vendor` one and the source-built `vendor-patched`
one — were removed on the mainline cutover along with their package pins,
bootloader rows, the `libmali` GPU blob, their fixtures and their tests; every
byte is recoverable at the annotated tag `vendor-kernel-final`
(`git show vendor-kernel-final:<path>`). Its patch series lives on in
[`CERALIVE/rk3588-vendor-kernel-patches`](https://github.com/CERALIVE/rk3588-vendor-kernel-patches),
which is **fully ACTIVE and open to contributions** — it is deliberately preserved
as a reference for anyone building a custom vendor-kernel image, and it still
tracks the open `armbian/linux-rockchip` PR #487 its series was written against.
Retired here does not mean archived there; do not read this section as a reason to
close, archive or delete that repository.

## Which patch repo feeds which track

| Variant | Track | Patch repository | Retire-on-merge status |
|---|---|---|---|
| `edge` (**the production default**) | mainline (currently pinned to `v7.2`; Armbian's own `edge` mapping still names 7.2-rc7) | [`CERALIVE/rk3588-kernel-patches`](https://github.com/CERALIVE/rk3588-kernel-patches) | see that repo's [`docs/UPSTREAM-STATUS.md`](https://github.com/CERALIVE/rk3588-kernel-patches/blob/main/docs/UPSTREAM-STATUS.md) |
| `edge-test` | `extends: edge` — the same source, plus KASAN/lockdep and the fault-injection symbols | (inherited) | never released; `ci/check-release-variant.sh` refuses it by property |

Both are declared under `rk3588`'s `variants:` map in
[`manifests/families/rk3588.yaml`](../manifests/families/rk3588.yaml). These two
rows are the whole table — the two Armbian 6.1 BSP rows that used to sit under
them went with the retirement above.

## What the flip took with it

`NET_CLS_FW` — the `tc filter … fw classid` classifier the uplink shaper needs to
map an nftables skb mark onto its client band — is in-tree and built-in on the
mainline track (`CONFIG_NET_CLS_FW=y` in
[`manifests/kernel/rk3588-edge.fragment`](../manifests/kernel/rk3588-edge.fragment),
pinned in `required-symbols.list`). The retired prebuilt kernel never built it, so
the image used to carry `ceralive-cls-fw`, a separately built vermagic-pinned
out-of-tree `cls_fw.ko`. That package, its pin file, its builder image and the
whole `kernel_extension_packages` mechanism are **retired**; an absence guard in
`tests/packaging-hygiene.bats` fails the build if any half comes back. Every
kernel this pipeline builds today carries `NET_CLS_FW` in-tree.

## The pin chain

Each patch repo owns its own `kernel-pin.env`, which records the exact upstream
commit/tag its series is verified against. That pin flows forward, never
backward:

```
<patch repo>/kernel-pin.env
        -> manifests/families/rk3588.yaml  (kernel_source: tag/commit + patches_commit)
        -> docs/kernel-build-from-source.md  (the human-readable description of the pin)
```

`rk3588.yaml` is the single point where a pin becomes a build input. Nothing in
this repo re-derives a pin independently of that file.

## The media-island handover: two reversibility points, both crossed

The island silicon handover was staged as two `patches_commit` bumps, each a
one-line revert, because the two flips carry different risk and folding them
would have erased the rollback point between them. Both have now been crossed
on `master`; the table records the pin that crossed each one and where the
current pin sits.

| Point | `patches_commit` | What moved | Status |
|---|---|---|---|
| 1 — the MPP flip | `cb491dc16fc1` (PR #148) | `mpp_srv` + RKVENC2/RKVDEC2/JPGDEC take the encoder, both decoder nodes and `jpegd` by DT `compatible`; the standalone VEPU580 driver and its nine rkvenc siblings retire. Mainline `rkvdec` stays BUILT and binds nothing. | crossed; superseded by later pins |
| 2 — the RGA flip | `365b24632940` (PR #150, island `v2026.9.2`) | RGA3 core0/core1 and RGA2 move from mainline `rockchip-rga` to the island's `multi_rga`; `CONFIG_ROCKCHIP_MULTI_RGA=m` declared, `CONFIG_VIDEO_ROCKCHIP_RGA` explicitly `not set` and on the forbidden list. | crossed; superseded by later pins |
| current | `6996f96bc883` (PR #179, island `v2026.9.5`) | RGA job-lifecycle race fix on top of `v2026.9.4`'s RGA ownership repairs (`9a8be32fe6b5`, PR #165). | **pinned on `master`**; Rock `edge-test` qualification PASS 2026-09-19 (PR #179 body); no production slot on either bench board has yet booted an image built from this pin |

Decoder truth at every pin from point 1 on: the island owns `vdec0`/`vdec1` and
`jpegd`; mainline `rkvdec` is compiled and idle by design so the handover can be
undone by a device-tree change instead of a kernel rebuild. RGA truth from point
2 on: `multi_rga` owns all three cores behind one `/dev/rga`; `rockchip-rga` binds
nothing. Rollback of the current pin is `patches_commit` back to the previous
lane commit (one line); the pre-bump image sits on the other RAUC slot until the
next deploy.

"The pipeline pins it" and "a board booted it" stay different sentences. Both
bench boards have booted images built from point-2-era pins (`365b2463`,
`b41a82a9`/`v2026.9.3`, `9a8be32f`/`v2026.9.4` on the Rock `edge-test` slot) —
the board rows in root `docs/COMPLETENESS-MATRIX.md` §2.2 name each run's pin.
The `v2026.9.5` pin is dry-run-proven and `edge-test`-qualified, not yet in a
production slot.

**A base bump does not carry hardware evidence with it.** Board results are scoped
to the base they were measured on; after a re-pin, treat the new base as
compile-proven until a board says otherwise. The `edge` track's current `v7.2` pin
has now passed that later release-image evidence: both RK3588 boards OTA-booted the
released Trixie/mainline/PipeWire stack. See
[`kernel-build-from-source.md`](kernel-build-from-source.md) §2 and §7 for the
mechanism and [`ota-bookworm-trixie-transition.md`](ota-bookworm-trixie-transition.md)
for the OTA/rollback record.

## Retire-on-merge lifecycle

Each patch repo tracks its own patches against upstream and retires a patch the
moment an equivalent lands upstream — that bookkeeping lives entirely in the
patch repo, not here:

- mainline (`edge`): [`rk3588-kernel-patches/docs/UPSTREAM-STATUS.md`](https://github.com/CERALIVE/rk3588-kernel-patches/blob/main/docs/UPSTREAM-STATUS.md)

That is the only ledger this pipeline has a stake in; the retired track's is its
own repository's business (see the retirement note above). This page does not
restate either. Read the linked file for current status; this index only says
where to look.

## Where the rest of the story lives

- **Should `edge` ever ship in production?** — [`kernel-track-decision.md`](kernel-track-decision.md)
  is the go/no-go decision record. It has been answered YES for the kernel half
  of decision D3: `default_variant: edge` is that answer expressed in the
  manifest. D3's bootloader-adapter half (`rauc_bootloader_adapter: custom`) is
  untouched.
- **How does a variant actually build?** — [`kernel-build-from-source.md`](kernel-build-from-source.md)
  is the full mechanism: the `variants:` model, source-checkout shapes, config
  modes, and DTB install mapping.
- **How the kernel-currency decision was reached, and what would revisit it** —
  [`kernel-currency-watch.md`](kernel-currency-watch.md). Its question ("should
  production leave vendor 6.1?") has been answered and executed; the page is the
  evidence record plus the revisit triggers.

## Discovering declared variants

`./build --help` lists the variants each family currently declares (read
live from that family's manifest, so the help text can never drift from what
`--variant` actually accepts). At the time of writing, only `rk3588` declares
variants (`edge`, `edge-test`); `x86-minipc` has no kernel-track axis.
