# Kernel Tracks — Index

This is a thin discoverability index, not a new source of truth. It exists so
that "which repo feeds which variant, and where do I read more" has one place
to start. Every substantive claim lives in the documents this page links to —
if you find a fact repeated here, that is a bug in this page, not a feature.

## Which track is PRODUCTION

`rk3588` declares `default_variant: edge`, so a variant-less `./build <board>`
resolves the `edge` overlay — the mainline 7.2 kernel built from source — and
does so byte-identically to `./build <board> --variant edge`, the board's own
`variant_overrides.edge` included. The prebuilt Armbian vendor 6.1 BSP that
shipped every earlier image is now the opt-in `vendor` overlay.

```
./build rock-5b-plus                       # mainline 7.2, built from source
./build rock-5b-plus --variant vendor      # prebuilt Armbian vendor 6.1 BSP
```

`default_variant` is a POINTER, not a copy of the pins. Copying `edge`'s block
to the family top level was the alternative and it breaks two things: `edge-test`
`extends: edge`, so it would have to restate its parent's pins (the byte-for-byte
drift `extends` exists to prevent), and `vendor-patched` uses config-FILE mode,
which would deep-merge onto the family's defconfig mode and produce the
half-specified config the schema's `oneOf` forbids.

## Which patch repo feeds which track

| Variant | Track | Patch repository | Retire-on-merge status |
|---|---|---|---|
| `edge` (**the production default**) | mainline (currently pinned to `v7.2`; Armbian's own `edge` mapping still names 7.2-rc7) | [`CERALIVE/rk3588-kernel-patches`](https://github.com/CERALIVE/rk3588-kernel-patches) | see that repo's [`docs/UPSTREAM-STATUS.md`](https://github.com/CERALIVE/rk3588-kernel-patches/blob/main/docs/UPSTREAM-STATUS.md) |
| `edge-test` | `extends: edge` — the same source, plus KASAN/lockdep and the fault-injection symbols | (inherited) | never released; `ci/check-release-variant.sh` refuses it by property |
| `vendor` | Armbian `vendor` 6.1 BSP, PREBUILT — no patches, no source build | — | retires with the vendor machinery |
| `vendor-patched` | Armbian `vendor` 6.1 BSP, built from source | [`CERALIVE/rk3588-vendor-kernel-patches`](https://github.com/CERALIVE/rk3588-vendor-kernel-patches) | tracked in that repo's own docs (open upstream PR #487; retires when it merges) |

All four are declared under `rk3588`'s `variants:` map in
[`manifests/families/rk3588.yaml`](../manifests/families/rk3588.yaml). Neither
patch repo's series applies to the other's tree — they target different kernel
majors and different upstream trees.

## What the flip took with it

`NET_CLS_FW` — the `tc filter … fw classid` classifier the uplink shaper needs to
map an nftables skb mark onto its client band — is in-tree and built-in on the
mainline track (`CONFIG_NET_CLS_FW=y` in
[`manifests/kernel/rk3588-edge.fragment`](../manifests/kernel/rk3588-edge.fragment),
pinned in `required-symbols.list`). The prebuilt vendor kernel never built it, so
the image used to carry `ceralive-cls-fw`, a separately built vermagic-pinned
out-of-tree `cls_fw.ko`. That package, its pin file, its builder image and the
whole `kernel_extension_packages` mechanism are **retired**; an absence guard in
`tests/packaging-hygiene.bats` fails the build if any half comes back. The
consequence for the opt-in `vendor` overlay is stated plainly: it has no
`NET_CLS_FW` at all.

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

**A base bump does not carry hardware evidence with it.** Board results are scoped
to the base they were measured on; after a re-pin, treat the new base as
compile-proven until a board says otherwise. The `edge` track's current `v7.2`
pin is in exactly that state — see
[`kernel-build-from-source.md`](kernel-build-from-source.md) §2 and §7.

## Retire-on-merge lifecycle

Each patch repo tracks its own patches against upstream and retires a patch the
moment an equivalent lands upstream — that bookkeeping lives entirely in the
patch repo, not here:

- mainline (`edge`): [`rk3588-kernel-patches/docs/UPSTREAM-STATUS.md`](https://github.com/CERALIVE/rk3588-kernel-patches/blob/main/docs/UPSTREAM-STATUS.md)
- vendor (`vendor-patched`): see the vendor repo's own docs for the open
  `armbian/linux-rockchip` PR #487 this series tracks.

This page does not restate either ledger. Read the linked file for current
status; this index only says where to look.

## Where the rest of the story lives

- **Should `edge` ever ship in production?** — [`kernel-track-decision.md`](kernel-track-decision.md)
  is the go/no-go decision record. It has been answered YES for the kernel half
  of decision D3: `default_variant: edge` is that answer expressed in the
  manifest. D3's bootloader-adapter half (`rauc_bootloader_adapter: custom`) is
  untouched.
- **How does a variant actually build?** — [`kernel-build-from-source.md`](kernel-build-from-source.md)
  is the full mechanism: the `variants:` model, source-checkout shapes, config
  modes, and DTB install mapping.
- **Why is production still vendor 6.1, and when would that change?** —
  [`kernel-currency-watch.md`](kernel-currency-watch.md) is the locked decision
  plus the two precise revisit triggers.

## Discovering declared variants

`./build --help` lists the variants each family currently declares (read
live from that family's manifest, so the help text can never drift from what
`--variant` actually accepts). At the time of writing, only `rk3588` declares
variants (`edge`, `vendor-patched`); `x86-minipc` has no kernel-track axis.
