# CeraLive v2 — `platform/boot/` (A/B bootloader integration · Stage 4)

The RAUC `bootloader=custom` integration that gives the device **atomic A/B slot
switch + automatic rollback** on the RK3588 vendor U-Boot. Lives in the **platform**
layer because it is board-specific (console / DTB / board_id come from the manifest)
and the platform layer is the only arch-specific layer (see `../../LAYER-MAP.md`).

> **Why custom and not the stock RAUC `bootloader=uboot` adapter — decision D3.**
> The vendor U-Boot CeraLive actually builds is **Radxa/Xunlong U-Boot 2017.09**,
> compiled `ENV_IS_NOWHERE`: `fw_setenv` does **not** persist across reboot. RAUC's
> standard uboot adapter drives `BOOT_ORDER` + per-slot `BOOT_<name>_LEFT` bootcount
> via `fw_setenv`, so it **cannot work** on this branch. We keep RAUC's exact A/B +
> bootcount *model* but change the *storage*: the state is a plain text file on the
> FAT `boot` partition, read+written by both a U-Boot script and userspace.
> Evidence: `.omo/.../decisions.md` D3; `.omo/evidence/task-27-*`.

## The two halves

| Where | Files | Tooling | Installed by |
|---|---|---|---|
| **rootfs slot** (userspace) | `ceralive-boot-state` → `/usr/bin`, `ceralive-rauc-boot-adapter` → `/usr/lib/rauc`, `/etc/rauc/system.conf` | none | `mkosi.finalize` → `install-boot.sh rootfs` (chroot) |
| **FAT boot partition** (p1) | `boot.scr` (compiled), `cera_board.env`, `boot_state.txt`, `extlinux/extlinux.conf` | `mkimage` (u-boot-tools) | disk assembly → `install-boot.sh boot-partition <dir>` |

The split exists because `mkimage` (to compile `boot.scr`) is a **host/runtime** tool,
not present in the platform chroot — so the boot-partition artifacts are produced at
disk-assembly time (where u-boot-tools is available), while the RAUC backend + state
helper + `system.conf` are pure userspace and install straight into the rootfs.

## State file format (`boot_state.txt`)

Newline `KEY=VALUE`, importable by U-Boot `env import -t` **and** trivially parsed by
shell — the whole point of the format:

```
BOOT_ORDER=A B      # slot bootnames, priority order; head = primary
BOOT_A_LEFT=3       # remaining boot attempts for slot A (3->2->1->0)
BOOT_B_LEFT=3       # remaining boot attempts for slot B
```

A slot is **good** while it is in `BOOT_ORDER` and its `*_LEFT > 0`; **bad** once the
counter hits 0 (or it is dropped from `BOOT_ORDER`). This is exactly RAUC's u-boot
adapter semantics — only the backend storage differs.

## How rollback happens

1. U-Boot runs `boot.scr` (compiled from `boot.scr.cmd`).
2. It imports `cera_board.env` (console, fdtfile) and `boot_state.txt`.
3. It picks the first slot in `BOOT_ORDER` with `*_LEFT > 0` (the primary),
   **decrements** that slot's counter, and persists the file (`fatwrite`).
4. It boots the kernel/DTB/initrd from that slot's `/boot` (`root=PARTLABEL=rootfs_a|b`).
5. A healthy OS calls **`ceralive-boot-state mark-good <slot>`** (RAUC `set-state good`),
   which resets the counter to the full budget — so a good slot never counts down.
6. A slot that keeps failing never marks itself good: its counter bleeds 3→2→1→0 and
   the **next** boot's step 3 skips it and selects the other slot — **automatic rollback**.

## RAUC custom backend interface (`ceralive-rauc-boot-adapter`)

RAUC (`bootloader=custom`, `[handlers] bootloader-custom-backend=`) invokes the script
with the operation as `$1` and the slot `bootname` (A/B) as the trailing argument:

| RAUC op | CeraLive action |
|---|---|
| `get-primary` | first slot in `BOOT_ORDER` with attempts left (the one that boots next) |
| `set-primary <name>` | move `<name>` to the head of `BOOT_ORDER` + reset its attempts (activate a freshly-installed slot) |
| `get-state <name>` | `good` / `bad` |
| `set-state <name> good\|bad` | `good`: reset attempts; `bad`: zero attempts + drop from `BOOT_ORDER` |

All four delegate to `ceralive-boot-state`, so the bootloader (`boot.scr`), the RAUC
backend, and the offline test share **one** implementation.

## Board specifics come from the manifest — never hardcoded

`install-boot.sh` reads `SERIAL_CONSOLE`, `DTB_NAME`, `BOARD_ID`, `FAMILY`,
`SINGLE_SLOT_FALLBACK` from the environment (resolved from the board+family manifest by
`lib/resolve.sh`, forwarded by `lib/orchestrate.sh` via mkosi `--environment`). It
renders `cera_board.env` / `extlinux.conf` from the `*.tmpl` files (the manifest's
`ttyS2:1500000` becomes the kernel `console=ttyS2,1500000`) and derives the RAUC
`compatible=ceralive-<family>`. Adding a board never edits any file here.

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
| `extlinux.conf.tmpl` | manual A/B recovery menu (static; not the rollback path) |
| `boot_state.txt` | fresh-flash A/B state seed |
| `install-boot.sh` | build-time installer (`rootfs` + `boot-partition` targets) |
| `test-fallback.sh` | offline proof of decrement→rollback + backend + render (no HW/root) |

## Test

```
v2/mkosi/platform/boot/test-fallback.sh   # 53 assertions, no hardware/root
```

Proves: fresh A/B state; 3 failed boots of A → counter 3→2→1→0 → **fallback to B**;
RAUC backend roundtrip; `mark-good` reset; single-slot has no phantom B; board
specifics differ per board (not hardcoded); `system.conf` shape; and that
`boot.scr.cmd` statically matches the tested engine (decrement + fatwrite +
manifest console/fdtfile + PARTLABEL slot select).

## Deferred / related

- **dm-verity + the `*.raucb` bundle** (`format=verity`) → the RAUC bundle build (task 26).
- **Wiring the boot-partition artifacts into `lib/assemble-disk.sh`** (it currently lays
  an empty vfat `boot`) → disk-assembly follow-up; `install-boot.sh boot-partition` is the
  ready hook.
- **RAUC keyring** (`/etc/rauc/keyring.pem`, the immutable root CA) → PKI tasks
  (`cert-work/rauc/`, decisions.md Stage 0g).
