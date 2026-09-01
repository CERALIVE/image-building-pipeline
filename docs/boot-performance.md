# Boot-performance budget

**Status:** `[PARTIAL]` — the gate mechanism exists; RK3588 thresholds and
post-change measurements are hardware-gated and have not been populated.

Boot-speed changes are measurement-driven. A source-level optimization may not
land as a performance win until the exact candidate has completed matched cold
boots on both supported RK3588 boards.

## Board gate

Capture at least three cold boots in a TSV file:

```text
schema_version	board	artifact	slot	peripherals	uplink	kernel_ms	userspace_ms
1	rock-5b-plus	<image-or-bundle-sha256>	A	<fixture-id>	offline	<ms>	<ms>
```

Then run:

```bash
ci/check-boot-budget.sh \
  --samples cold-boots.tsv \
  --board rock-5b-plus \
  --max-userspace-ms <board-measured-threshold> \
  --basis '<candidate, date, cold-boot protocol, and threshold derivation>'
```

The checker refuses fewer than three samples and refuses a set whose artifact,
slot, peripheral fixture, or uplink state changes between boots. It reports the
kernel and userspace median plus range, then blocks when the userspace median is
over budget. The threshold has no default: it must be derived from real board
measurements and carry an explicit basis rather than being guessed in source.

## Auxiliary x86 check

`tests/qemu-x86.sh` records systemd's monotonic userspace duration in its serial
transcript. Its SELFTEST applies a synthetic 10-second threshold to a healthy
fixture and to an intentionally slowed fixture, proving the parser and failure
path. This is an **auxiliary x86 parser-level guard only**. It is not an RK3588
measurement and cannot establish either board's production threshold.

`tests/boot-budget.test.sh` runs both the board-gate fixtures and the QEMU
assertion-engine fixtures in the default pipeline suite.

## Hardware completion still required

For each supported board:

1. Use privileged `systemd-analyze blame`, `critical-chain`, and `plot`, plus the
   full monotonic journal, initrd inventory, and available U-Boot timing evidence.
2. Build and deliver the intermediate candidate from published producer pins and
   the pipeline changes only, after verifying the recovery preconditions.
3. Hold artifact, slot, peripherals, and uplink state constant; capture at least
   three cold boots before and after each proposed optimization.
4. Record median and range, select the blocking threshold from those measurements,
   and run `ci/check-boot-budget.sh` against the retained sample file.

Until this procedure runs on both boards, no boot-speed source change or numeric
RK3588 budget is justified by this mechanism alone.
