# CeraLive v2 — `platform/boot/` (A/B bootloader integration · Stage 4)

The RAUC `bootloader=custom` integration that gives the device **atomic A/B slot
switch + automatic rollback** on the RK3588 vendor U-Boot. Lives in the **platform**
layer because it is board-specific (console / DTB / board_id come from the manifest)
and the platform layer is the only arch-specific layer (see `../../LAYER-MAP.md`).

> **Why custom and not the stock RAUC `bootloader=uboot` adapter — decision D3.**
> The Rock 5B+ package currently staged by the pipeline reports **U-Boot 2026.04**.
> The contract is capability-based: this vendor build uses `ENV_IS_NOWHERE`, so
> `fw_setenv` does **not** persist across reboot. RAUC's
> standard uboot adapter drives `BOOT_ORDER` + per-slot `BOOT_<name>_LEFT` bootcount
> via `fw_setenv`, so it **cannot work** on this branch. We keep RAUC's exact A/B +
> bootcount *model* but change the *storage*: the state is a plain text file on the
> FAT `boot` partition, read+written by both a U-Boot script and userspace.

## The two halves

| Where | Files | Tooling | Installed by |
|---|---|---|---|
| **rootfs slot** (userspace) | `ceralive-boot-state` → `/usr/bin`, `ceralive-rauc-boot-adapter` → `/usr/lib/rauc`, `/etc/rauc/system.conf`, explicit p1 `/boot` fstab mount | none | `mkosi.finalize` → `install-boot.sh rootfs` (chroot) |
| **FAT boot partition** (p1) | `boot.scr`, `recovery.scr`, `cera_board.env`, `boot_state.txt` | `mkimage` (u-boot-tools) | disk assembly → `install-boot.sh boot-partition <dir>` |

The split exists because `mkimage` (to compile `boot.scr`) is a **host/runtime** tool,
not present in the platform chroot — so the boot-partition artifacts are produced at
disk-assembly time (where u-boot-tools is available), while the RAUC backend + state
helper + `system.conf` are pure userspace and install straight into the rootfs.

The p1 partition is GPT type XBOOTLDR, but every rootfs has a non-empty `/boot`
containing its kernel. The discoverable-partitions contract therefore suppresses the
automatic XBOOTLDR mount. `install-boot.sh rootfs` writes an explicit writable
`PARTLABEL=boot /boot` fstab entry so userspace and U-Boot share the same state file;
`nodev,nosuid,noexec` limit the shared FAT surface. Linux mounts it only after U-Boot
has already loaded the selected slot's kernel.

## State file format (`boot_state.txt`)

Newline `KEY=VALUE`, importable by U-Boot `env import -t` **and** trivially parsed by
shell — the whole point of the format:

```
BOOT_ORDER=A B      # slot bootnames, priority order; head = primary
BOOT_A_LEFT=3       # remaining boot attempts for slot A (3->2->1->0)
BOOT_B_LEFT=3       # remaining boot attempts for slot B
BOOT_CRC=697809624  # POSIX cksum of the three lines above (corruption guard)
```

A slot is **good** while it is in `BOOT_ORDER` and its `*_LEFT > 0`; **bad** once the
counter hits 0 (or it is dropped from `BOOT_ORDER`). This is exactly RAUC's u-boot
adapter semantics — only the backend storage differs.

### Atomic write + corruption safety

A power-loss mid-rewrite of this FAT file is the one failure that could brick the
device, so `ceralive-boot-state` writes it defensively:

- **Atomic replacement** — the full file is created beside `boot_state.txt`, flushed,
  and moved over the destination on the same filesystem. A tmpfs staging file is not
  used because cross-filesystem `mv` degrades into copy-then-unlink and is not atomic.
- **CRC guard** — `BOOT_CRC` is the POSIX `cksum` of the three data lines. On read,
  a truncated / empty / missing / byte-flipped (bad-CRC) file is detected and the
  helper falls back to the **safe defaults** (`BOOT_ORDER=A B`, both budgets full)
  **and rewrites a clean file**. It never aborts the boot path.
- **U-Boot interop** — the in-U-Boot selector rewrites `boot_state.txt` via
  `env export`, which cannot emit a checksum. A well-formed file **without** a
  `BOOT_CRC` line is therefore trusted (not reset) so the bootcount the bootloader
  just decremented survives the next userspace read. `env import -t` ignores the
  extra `BOOT_CRC` var, so the file stays readable by both halves.

## How rollback happens

1. U-Boot runs `boot.scr` (compiled from `boot.scr.cmd`).
2. It imports `cera_board.env` (console, fdtfile) and `boot_state.txt`.
3. It rejects missing, unknown, duplicate, non-numeric, or out-of-budget state and
   persists factory-safe `A B` / `3,3` defaults before slot resolution.
4. It picks the first slot in `BOOT_ORDER` with `*_LEFT > 0` (the primary),
   **decrements** that slot's counter, and persists the file (`fatwrite`).
5. It boots the kernel/DTB/initrd from that slot's `/boot` with
   `root=PARTLABEL=rootfs_a|b rauc.slot=A|B`, so RAUC identifies the booted slot
   explicitly rather than inferring it from the root device.
6. A healthy OS calls **`ceralive-boot-state mark-good <slot>`** (RAUC `set-state good`),
   which resets the counter to the full budget — so a good slot never counts down.
7. A slot that keeps failing never marks itself good: its counter bleeds 3→2→1→0 and
   the **next** boot's selection skips it and chooses the other slot — **automatic rollback**.

## RAUC custom backend interface (`ceralive-rauc-boot-adapter`)

RAUC (`bootloader=custom`, `[handlers] bootloader-custom-backend=`) invokes the script
with the operation as `$1` and the slot `bootname` (A/B) as the trailing argument:

| RAUC op | CeraLive action |
|---|---|
| `get-current` | read the running slot from the required kernel argument `rauc.slot=A|B`; fail closed if absent |
| `get-primary` | first slot in `BOOT_ORDER` with attempts left (the one that boots next) |
| `set-primary <name>` | move `<name>` to the head of `BOOT_ORDER` + reset its attempts (activate a freshly-installed slot) |
| `get-state <name>` | `good` / `bad` |
| `set-state <name> good\|bad` | `good`: reset attempts; `bad`: zero attempts + drop from `BOOT_ORDER` |

Debian bookworm's RAUC 1.8 reads `rauc.slot=` natively and invokes the four
state/primary operations. RAUC 1.11+ prefers the optional `get-current` operation,
which deliberately reads the same kernel argument because primary can change while
the old slot is still running. State mutations delegate to `ceralive-boot-state`.

## Board specifics come from the manifest — never hardcoded

`install-boot.sh` reads `SERIAL_CONSOLE`, `DTB_NAME`, `BOARD_ID`,
`SINGLE_SLOT_FALLBACK` and `COMPATIBLE_STRING` from the environment (resolved from the
board+family manifest by `lib/resolve.sh`, forwarded by `lib/orchestrate.sh` via mkosi
`--environment`). It renders `cera_board.env` and compiles the automatic and recovery scripts
(the manifest's `ttyS2:1500000` becomes the kernel `console=ttyS2,1500000`) and writes
the RAUC `compatible` **verbatim from `COMPATIBLE_STRING`** — `ceralive-<board-slug>`
(e.g. `ceralive-rock-5b-plus`), the **board-specific** string the orchestrator derives
once from `board_id` (T12). It is NOT family-wide (`ceralive-rk3588`): a family default
would let one board's signed bundle install on another. `install-boot.sh` keeps **no**
local default — an empty `COMPATIBLE_STRING` is a hard error, so the on-device
`system.conf` and the signed `.raucb` can never disagree. Adding a board never edits any
file here.

## Single-slot fallback (storage < 16 GB — contract §4)

When `SINGLE_SLOT_FALLBACK=true`: `boot_state.txt` is seeded `BOOT_ORDER=A` /
`BOOT_B_LEFT=0`, and `system.conf` omits `[slot.rootfs.1]` so RAUC never targets a
non-existent partition. There is no field rollback (only one slot), and the selector
last-resort boots A.

## Files

| File | Role |
|---|---|
| `ceralive-boot-state.sh` | state engine + CLI; the userspace twin of `boot.scr` (ships as `/usr/bin/ceralive-boot-state`) |
| `ceralive-rauc-boot-adapter.sh` | RAUC custom backend (`/usr/lib/rauc/ceralive-rauc-boot-adapter`) |
| `boot.scr.cmd` | U-Boot selector source (compiled to `boot.scr`) |
| `cera_board.env.tmpl` | board specifics template (`@CONSOLE@`/`@DTB_NAME@`/`@BOARD_ID@`) |
| `recovery.scr.cmd` | manual A/B recovery source; explicitly loads Image, DTB, and initrd from p2 or p3 |
| `boot_state.txt` | fresh-flash A/B state seed |
| `install-boot.sh` | build-time installer (`rootfs` + `boot-partition` targets) |
| `test-fallback.sh` | offline proof of decrement→rollback + backend + render (no HW/root) |
| `tests/boot-script-sanitize.test.sh` | faithful execution of the actual selector source with malformed imported state |

## Test

```
v2/mkosi/platform/boot/test-fallback.sh
v2/tests/boot-script-sanitize.test.sh
```

Proves: fresh A/B state; 3 failed boots of A → counter 3→2→1→0 → **fallback to B**;
RAUC backend roundtrip including fail-closed `get-current`; `mark-good` reset;
single-slot has no phantom B; board
specifics differ per board (not hardcoded); `system.conf` shape; that
`boot.scr.cmd` matches the tested engine (decrement + fatwrite + manifest
console/fdtfile + PARTLABEL slot select); the actual script is also executed through
U-Boot command stubs against missing and malformed imported state. Corruption resilience —
truncated / empty / missing / bad-CRC files yield the safe defaults + a clean
rewrite (never a crash), while a well-formed no-CRC file is trusted. It also rejects
duplicate/out-of-budget stale state, preserves a deterministic all-bad last resort,
and proves userspace state replacement stays on one filesystem.

## Related

- `lib/assemble-disk.sh` writes these artifacts into the factory image and populates
  both A/B rootfs filesystems.
- `lib/build-bundle.sh` emits the signed plain-format `.raucb`; the immutable root CA
  is installed as `/etc/rauc/keyring.pem`.
- dm-verity is future bundle hardening and is not part of the current slot contract.
