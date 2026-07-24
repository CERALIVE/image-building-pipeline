# CeraLive v2 — `platform/x86/` (x86 encode + GRUB/EFI A/B bootloader · Stage 5)

The x86 (Intel N100/N200, AMD mini-PC) half of the platform layer: the **video
encode strategy** (decision D1) and the **RAUC A/B + automatic rollback** integration
on UEFI/GRUB. The x86 counterpart to `../boot/` (RK3588/U-Boot).

> **Why x86 is a separate adapter from RK3588.** Same A/B + bootcount *model*
> (`BOOT_ORDER` + per-slot `BOOT_<n>_LEFT` countdown), different *bootloader*:
> RK3588 uses its staged vendor U-Boot with **no persistent `fw_setenv`** (decision D3),
> so its state lives in a hand-rolled text file on a FAT partition. x86 boots via
> **UEFI → GRUB**, which has full persistent env (`grub-editenv` + `grubenv`), so the
> state lives in the **grubenv** on the EFI System Partition.

---

## 1. Encode strategy (decision D1)

`cerastream` is the sole engine and selects encode elements at runtime via its HAL
profiles. The engine is **encoder-agnostic** — the encode element is
runtime-selected, not compiled in. **No engine source
change** for x86, **no MPP dependency**. x86 does **FULL bonded streaming** — it is
**NOT relay-only**.

| Path | Element | Pipelines | Provider |
|---|---|---|---|
| **Primary** (HW) | `qsvh265enc` / `qsvh264dec` / `vajpegdec` | n100 profile | `gstreamer1.0-plugins-bad` (shared.list) + `intel-media-va-driver-non-free` (iHD) |
| **Fallback** (SW) | `x264enc` | generic profile | `gstreamer1.0-plugins-ugly` / core (any CPU) |

`x86-encode.sh` (1) ensures the Intel iHD VA driver + `gstreamer1.0-vaapi` are
present (and **fails loudly** if the driver is missing — never pretends VA-API works
without it), (2) writes `/etc/ceralive/conf.d/10-encode-x86.conf` (qsv primary, x264
fallback, families `n100` → `generic`, `CERALIVE_RELAY_ONLY=false`), and (3) points
`/etc/ceralive/pipeline` at the active `n100` family.

> **D1 caveat (runtime, documented in the config):** a BELABOX-lineage encoder always did
> `g_object_set("bps", …)`. Stock distro `qsvh265enc`/`x264enc` expose `bitrate`
> (kbps), **not** `bps` — only a **BELABOX/CERALIVE-patched GStreamer** adds `bps`.
> On unpatched distro GStreamer, encode works but **dynamic bitrate control silently
> no-ops**. Ship the patched gst encoders **or** accept static-bitrate x86. Validate
> on real N100 hardware (`gst-inspect-1.0 qsvh265enc | grep -i bps`).

---

## 2. A/B bootloader integration (GRUB on EFI)

### 2.0 SHIPPED PATH — RAUC-native `bootloader=grub` (Task 12)

> **The x86 image ships RAUC's BUILT-IN `bootloader=grub` backend.** Task 12 wired
> x86 disk assembly and, per its VERIFY-FIRST gate, chose RAUC-native grub over the
> custom countdown backend documented in §2.1 below. The custom files
> (`x86-boot-state.sh`, `x86-rauc-boot-adapter.sh`, `grub.cfg.tmpl`,
> `install-x86-boot.sh`) are **RETAINED unchanged** as the offline rollback-contract
> harness exercised by `test-x86-fallback.sh` and `qemu-x86.sh --fallback-selftest`
> — they are **NOT installed on the shipped RAUC-native x86 image**.

**VERIFY-FIRST finding (mkosi-native vs script-installed GRUB).** mkosi's native
`Bootloader=grub` directive is **INCOMPATIBLE** with this pipeline's `Format=none` +
offline-assemble model: the production disk is laid by `lib/assemble-disk-x86.sh`
(`systemd-repart --offline` + `sgdisk` + mtools), **not** by mkosi — the mkosi `disk`
image is `Bootable=no`, "the geometry reference; assemble-disk.sh is the producer".
mkosi `Bootloader=grub` would need `Format=disk` + `Bootable=yes` + a mkosi-owned
ESP/repart pass, which fights that model and **touches partition geometry (G3)**. So
GRUB is **script-installed offline** (`grub-mkstandalone` → ESP removable path
`/EFI/BOOT/BOOTX64.EFI`), mirroring how `assemble-disk.sh` writes the RK3588
bootloader — least custom glue, zero `repart/` diff, RK3588 path untouched.

**Shipped x86 boot files (RAUC-native grub):**

| Where | Files | Tooling | Installed by |
|---|---|---|---|
| **rootfs slot** | `/etc/rauc/system.conf` (`bootloader=grub`, `grubenv=` on ESP), `/etc/fstab` (ESP → `/boot/efi`) | none | `install-x86-grub.sh rootfs` (platform/mkosi.finalize, chroot) |
| **EFI System Partition** | `EFI/BOOT/BOOTX64.EFI` (removable-path GRUB), `EFI/BOOT/grub.cfg` (RAUC `ORDER`/`<slot>_OK`/`<slot>_TRY` selector), `EFI/BOOT/grubenv` (seed) | `grub-mkstandalone` / `grub-editenv` | `assemble-disk-x86.sh` → `install-x86-grub.sh esp` (disk assembly) |

The grubenv lives on the **ESP** (never a rootfs slot): a RAUC update rewrites the
inactive rootfs slot and would destroy the boot-selection state (EC5). RAUC's grub
backend rewrites `ORDER`/`<slot>_OK`/`<slot>_TRY` via `grub-editenv` on install +
`mark-good`; `grub-ab.cfg` is the boot-time selector twin. Build prereq on the host:
`grub-efi-amd64-bin` + `grub-common` (absent → a placeholder `BOOTX64.EFI` is staged
and the ESP layout is otherwise complete; a grub-equipped builder fills the binary).

### 2.1 RETAINED reference — `bootloader=custom` countdown engine (offline harness)

> The model below is **no longer the shipped x86 path** (§2.0). It is kept as the
> cross-platform offline rollback-contract harness only.

RAUC ships a stock grub backend, but it uses a **single boolean retry** per slot
(`<slot>_OK` / `<slot>_TRY`). The custom backend keeps the **RK3588 multi-attempt
countdown** model (`BOOT_<slot>_LEFT`: 3→2→1→0) so **both platforms share one model,
one RAUC custom-backend interface, and one offline-test shape**. The cost is a small
amount of grubenv glue; the gain is cross-platform symmetry and a richer N-attempt
budget.

The manifest field `rauc_bootloader_adapter: efi` (`families/x86_64.yaml`) names the
**EFI/GRUB boot family**. The retained custom wiring is `bootloader=custom` with the
backend below. (Its device-side paths are **identical** to RK3588 —
`/usr/lib/rauc/ceralive-rauc-boot-adapter`, `/usr/bin/ceralive-boot-state`.)

### GRUB has no arithmetic — the decrement is a ladder

U-Boot has `setexpr` (a real `LEFT = LEFT - 1`). **GRUB script has only integer
*comparison* (`-gt`) and string equality — no `$(( ))`, no `setexpr`.** So the
selection test (`LEFT > 0`) uses GRUB's `-gt`, but the **decrement** is a bounded
**string-comparison ladder** generated for `BOOT_ATTEMPTS` by `install-x86-boot.sh`:

```grub
if   [ "${BOOT_A_LEFT}" = "3" ]; then set BOOT_A_LEFT="2"
elif [ "${BOOT_A_LEFT}" = "2" ]; then set BOOT_A_LEFT="1"
elif [ "${BOOT_A_LEFT}" = "1" ]; then set BOOT_A_LEFT="0"
fi
save_env BOOT_A_LEFT
```

## The two halves

| Where | Files | Tooling | Installed by |
|---|---|---|---|
| **rootfs slot** (userspace) | `x86-boot-state` → `/usr/bin/ceralive-boot-state`, `x86-rauc-boot-adapter` → `/usr/lib/rauc/ceralive-rauc-boot-adapter`, `/etc/rauc/system.conf` | none | `install-x86-boot.sh rootfs` (chroot) |
| **EFI System Partition** | `EFI/ceralive/grub.cfg` (rendered), `EFI/ceralive/grubenv` (seed), `grubx64.efi` | `grub-install` / `grub-editenv` (host/runtime) | `install-x86-boot.sh esp <dir>` (disk assembly) |

## State (`grubenv`, read by GRUB `load_env` and by userspace)

```
BOOT_ORDER=A B      # slot bootnames, priority order; head = primary
BOOT_A_LEFT=3       # remaining boot attempts for slot A (3->2->1->0)
BOOT_B_LEFT=3       # remaining boot attempts for slot B
```

Stored as a grub-editenv-compatible **1024-byte environment block**. `x86-boot-state`
prefers the real `grub-editenv` (compat guarantee) and carries a self-contained bash
fallback that emits the identical block — so it (and the offline test) run on hosts
with **no GRUB tooling**.

## How rollback happens

1. UEFI loads `grubx64.efi`; GRUB runs `EFI/ceralive/grub.cfg`.
2. `load_env` reads `BOOT_ORDER` + counters from `grubenv`.
3. It picks the first slot in `BOOT_ORDER` with `*_LEFT > 0` (`-gt`), **decrements**
   it (the ladder), persists (`save_env`).
4. It boots `/vmlinuz` + `/initrd.img` from that slot, `root=PARTLABEL=rootfs_a|b`.
5. A healthy OS runs `ceralive-boot-state mark-good <slot>` (RAUC `set-state good`) →
   the counter resets, so a good slot never counts down.
6. A slot that keeps failing bleeds 3→2→1→0; the **next** boot's step 3 skips it and
   selects the other slot — **automatic rollback**.

## RAUC custom backend interface (`x86-rauc-boot-adapter`)

| RAUC op | CeraLive action |
|---|---|
| `get-primary` | first slot in `BOOT_ORDER` with attempts left |
| `set-primary <name>` | move `<name>` to head of `BOOT_ORDER` + reset attempts |
| `get-state <name>` | `good` / `bad` |
| `set-state <name> good\|bad` | `good`: reset attempts; `bad`: zero + drop from order |

All four delegate to `ceralive-boot-state` (the x86 grubenv engine), so the bootloader
(`grub.cfg`), the RAUC backend, and the offline test share **one** implementation.

## Board specifics come from the manifest — never hardcoded

`install-x86-boot.sh` reads `SERIAL_CONSOLE`, `FAMILY`, `SINGLE_SLOT_FALLBACK` from the
environment (resolved by `lib/resolve.sh`). The manifest's `ttyS0:115200` becomes the
kernel `console=ttyS0,115200`; the RAUC `compatible=ceralive-<family>`. x86 has **no
DTB / no U-Boot** (ACPI + UEFI) — those fields are intentionally unused here.

## Files

**Shipped path — RAUC-native `bootloader=grub` (Task 12):**

| File | Role |
|---|---|
| `grub-ab.cfg` | RAUC `ORDER`/`<slot>_OK`/`<slot>_TRY` GRUB selector template (→ rendered `EFI/BOOT/grub.cfg`) |
| `install-x86-grub.sh` | build-time installer (`rootfs` = `bootloader=grub` system.conf + ESP fstab; `esp` = grub.cfg + grubenv + `grub-mkstandalone` BOOTX64.EFI; `grubenv-set`) |
| `10-esp.conf` | x86 ESP repart def (`Type=esp`, 256 MB) — staged by `lib/assemble-disk-x86.sh` alongside the FROZEN slot defs; `repart/` stays zero-diff |
| `test-x86-grub.sh` | offline proof of `bootloader=grub` system.conf + grub.cfg selector + grubenv slot-switch (no GRUB/qemu/root) |
| `x86-encode.sh` | x86 encode setup (VA driver + QSV/x264 selection + pipeline link) |
| `README.md` | this file |

**Retained reference — `bootloader=custom` countdown engine (offline harness, §2.1):**

| File | Role |
|---|---|
| `x86-boot-state.sh` | grubenv A/B countdown engine + CLI; userspace twin of `grub.cfg.tmpl` (→ `/usr/bin/ceralive-boot-state`) |
| `x86-rauc-boot-adapter.sh` | RAUC custom backend (→ `/usr/lib/rauc/ceralive-rauc-boot-adapter`) |
| `grub.cfg.tmpl` | custom-countdown GRUB selector template (decrement ladder) |
| `install-x86-boot.sh` | custom-path installer (`rootfs` + `esp`; generates the decrement ladder) |
| `test-x86-fallback.sh` | offline proof of decrement→rollback + backend + render + encode (no GRUB/qemu/root) |

## Test

```
v2/mkosi/platform/x86/test-x86-fallback.sh   # 72 assertions, no GRUB/qemu/root
v2/tests/qemu-x86.sh --fallback-selftest     # forced-primary-failure rollback proof
```

`test-x86-fallback.sh` is the **engine** unit test. It proves: fresh A/B; 3 failed
boots of A → 3→2→1→0 → **fallback to B**; RAUC backend roundtrip; `mark-good` reset;
single-slot has no phantom B; grubenv is a valid 1024-byte block; `install-x86-boot.sh
esp` renders board-specific `grub.cfg` (console/ladder/PARTLABEL/`/vmlinuz`) + seeds
grubenv; `rootfs` renders `bootloader=custom` `system.conf`; `x86-encode.sh` writes the
D1 encode config (qsv primary, x264 fallback, NOT relay-only).

`qemu-x86.sh --fallback-selftest` is the **boot-harness** proof of the one scenario it
owns: a **forced primary-slot failure rolls back to the known-good slot**. It drives
this same shipped `x86-boot-state.sh` engine (no re-implementation, no qemu/GRUB/root),
asserts the rollback contract end-to-end, and is wired into the canonical unit suite
(`v2/tests/manifest.bats` → `v2/run-tests`) so CI gates on it.

## Done (Task 12) / still deferred

**Landed in Task 12 (x86 GRUB A/B disk assembly):**

- **Build wiring** — `lib/orchestrate.sh` routes the `efi`/`grub` adapter to
  `lib/assemble-disk-x86.sh`; `platform/mkosi.finalize` has an x86 branch invoking
  `install-x86-grub.sh rootfs`. (The earlier arm64-only orchestrator gates that died
  on empty DTB/U-Boot were already relaxed for x86 via `INSTALL_BOOT_BSP`.)
- **GRUB into the ESP** — `grub-mkstandalone` writes the removable-path
  `/EFI/BOOT/BOOTX64.EFI` at disk-assembly time (offline, no `grub-install` mount).
- **RAUC keyring** — the device root CA is installed by the runtime layer at
  `/etc/rauc/ceralive-keyring.pem`; the x86 `system.conf` `[keyring]` points at it.
- **Signed RAUC OTA `.raucb` for x86** — `lib/orchestrate.sh`'s `efi`/`grub`
  Stage-4 branch now calls `build-bundle.sh` after `assemble-disk-x86.sh`,
  emitting a signed `.raucb` (+ `.sha256`) ALONGSIDE the `.raw`, stamped with the
  board-specific `COMPATIBLE_STRING` (`ceralive-<board-id>`) and the shared build
  timestamp. `build-bundle.sh` is board-agnostic, so this mirrors the RK3588
  `custom` path verbatim — same rootfs.tar artifact, same `BUNDLE_*` env.

**Still deferred:**

- **`docs/partition-contract.md` `x86-ab` addendum** (ESP + grubenv vs the RK raw
  idbloader gap) → coordinated additive change to the FROZEN v1 contract. The x86
  layout reuses the FROZEN slot defs (`20`/`30`/`40`) and adds an ESP p1 (no gap).
- **On-silicon validation** (real N100): qemu/HW A/B rollback boot with OVMF, `vainfo`
  enc entrypoints, and the `bps`/patched-GStreamer dynamic-bitrate check.
