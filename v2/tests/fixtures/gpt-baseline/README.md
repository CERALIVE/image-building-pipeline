# `gpt-baseline/` — pre-overlay RK3588 GPT golden fixtures

Captured from `v2/lib/assemble-disk.sh` **before** the `CERALIVE_BENCH_LABELS`
bench-PARTLABEL overlay existed, at commit `1af9116`:

```bash
v2/lib/assemble-disk.sh build --output ab.img --total-mb 10513 --no-format
v2/lib/assemble-disk.sh build --output ss.img --total-mb  8192 --no-format --single-slot
```

Each line is `p<N> <PARTLABEL> start=<sector> size=<sectors>` — the deterministic
part of the produced GPT (the partition/disk GUIDs are random per run, so a whole
image `sha256` cannot be a fixture).

They exist for ONE reason: to prove the **unflagged** build still lays exactly the
frozen contract (`docs/partition-contract.md` §3) after the overlay landed. Same
role as `v2/tests/manifests/fixtures/vendor-baseline/*.params` for the `--variant`
mechanism.

**Do NOT regenerate these to make a test pass.** A diff here means the production
partition layout moved — which is a fleet re-flash, not a test fix.

Consumed by `v2/tests/bench-partlabels.bats`.
