# Kernel Tracks — Index

This is a thin discoverability index, not a new source of truth. It exists so
that "which repo feeds which variant, and where do I read more" has one place
to start. Every substantive claim lives in the documents this page links to —
if you find a fact repeated here, that is a bug in this page, not a feature.

## Which patch repo feeds which track

| Variant | Track | Patch repository | Retire-on-merge status |
|---|---|---|---|
| `edge` | mainline Armbian `edge` (7.1) | [`CERALIVE/rk3588-kernel-patches`](https://github.com/CERALIVE/rk3588-kernel-patches) | see that repo's [`docs/UPSTREAM-STATUS.md`](https://github.com/CERALIVE/rk3588-kernel-patches/blob/main/docs/UPSTREAM-STATUS.md) |
| `vendor-patched` | Armbian `vendor` (6.1 BSP — the kernel the shipped image actually runs) | [`CERALIVE/rk3588-vendor-kernel-patches`](https://github.com/CERALIVE/rk3588-vendor-kernel-patches) | tracked in that repo's own docs (open upstream PR #487; retires when it merges) |

Both variants are declared under `rk3588`'s `variants:` map in
[`v2/manifests/families/rk3588.yaml`](../manifests/families/rk3588.yaml). Neither
repo's patches apply to the other's tree — they target different kernel majors
and different upstream trees.

## The pin chain

Each patch repo owns its own `kernel-pin.env`, which records the exact upstream
commit/tag its series is verified against. That pin flows forward, never
backward:

```
<patch repo>/kernel-pin.env
        -> v2/manifests/families/rk3588.yaml  (kernel_source: tag/commit + patches_commit)
        -> v2/docs/kernel-build-from-source.md  (the human-readable description of the pin)
```

`rk3588.yaml` is the single point where a pin becomes a build input. Nothing in
this repo re-derives a pin independently of that file.

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
  is the go/no-go decision record (currently: hold, D3 unchanged).
- **How does a variant actually build?** — [`kernel-build-from-source.md`](kernel-build-from-source.md)
  is the full mechanism: the `variants:` model, source-checkout shapes, config
  modes, and DTB install mapping.
- **Why is production still vendor 6.1, and when would that change?** —
  [`kernel-currency-watch.md`](kernel-currency-watch.md) is the locked decision
  plus the two precise revisit triggers.

## Discovering declared variants

`./v2/build --help` lists the variants each family currently declares (read
live from that family's manifest, so the help text can never drift from what
`--variant` actually accepts). At the time of writing, only `rk3588` declares
variants (`edge`, `vendor-patched`); `x86-minipc` has no kernel-track axis.
