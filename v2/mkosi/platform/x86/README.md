# CeraLive v2 — `platform/x86/` (x86 encode + GRUB/EFI A/B bootloader · Stage 5)

The x86 (Intel N100/N200, AMD mini-PC) half of the platform layer: the **video
encode strategy** (decision D1) and the **RAUC A/B + automatic rollback** integration
on UEFI/GRUB. The x86 counterpart to `../boot/` (RK3588/U-Boot).

> **Why x86 is a separate adapter from RK3588.** Same A/B + bootcount *model*
> (`BOOT_ORDER` + per-slot `BOOT_<n>_LEFT` countdown), different *bootloader*:
> RK3588 uses a vendor U-Boot 2017.09 with **no working `fw_setenv`** (decision D3),
> so its state lives in a hand-rolled text file on a FAT partition. x86 boots via
> **UEFI → GRUB**, which has full persistent env (`grub-editenv` + `grubenv`), so the
> state lives in the **grubenv** on the EFI System Partition.

---

## 1. Encode strategy (decision D1)

`ceracoder` is **encoder-agnostic** — the encode element is runtime-selected from a
text pipeline file (`gst_parse_launch`), not compiled in. **No ceracoder source
change** for x86, **no MPP dependency**. x86 does **FULL bonded streaming** — it is
**NOT relay-only**.

| Path | Element | Pipelines | Provider |
|---|---|---|---|
| **Primary** (HW) | `qsvh265enc` / `qsvh264dec` / `vajpegdec` | `ceracoder/pipeline/n100/*` | `gstreamer1.0-plugins-bad` (shared.list) + `intel-media-va-driver-non-free` (iHD) |
| **Fallback** (SW) | `x264enc` | `ceracoder/pipeline/generic/*` | `gstreamer1.0-plugins-ugly` / core (any CPU) |

`x86-encode.sh` (1) ensures the Intel iHD VA driver + `gstreamer1.0-vaapi` are
present (and **fails loudly** if the driver is missing — never pretends VA-API works
without it), (2) writes `/etc/ceralive/conf.d/10-encode-x86.conf` (qsv primary, x264
fallback, families `n100` → `generic`, `CERALIVE_RELAY_ONLY=false`), and (3) points
`/etc/ceralive/pipeline` at the active `n100` family.

> **D1 caveat (runtime, documented in the config):** `ceracoder` always does
> `g_object_set("bps", …)`. Stock distro `qsvh265enc`/`x264enc` expose `bitrate`
> (kbps), **not** `bps` — only a **BELABOX/CERALIVE-patched GStreamer** adds `bps`.
> On unpatched distro GStreamer, encode works but **dynamic bitrate control silently
> no-ops**. Ship the patched gst encoders **or** accept static-bitrate x86. Validate
> on real N100 hardware (`gst-inspect-1.0 qsvh265enc | grep -i bps`).

---

## 2. A/B bootloader integration (GRUB on EFI)

### Why `bootloader=custom`, not RAUC's built-in `bootloader=grub`

RAUC ships a stock grub backend, but it uses a **single boolean retry** per slot
(`<slot>_OK` / `<slot>_TRY`). We keep the **RK3588 multi-attempt countdown** model
(`BOOT_<slot>_LEFT`: 3→2→1→0) so **both platforms share one model, one RAUC
custom-backend interface, and one offline-test shape**. The cost is a small amount of
grubenv glue; the gain is cross-platform symmetry and a richer N-attempt budget.

The manifest field `rauc_bootloader_adapter: efi` (`families/x86_64.yaml`) names the
**EFI/GRUB boot family**; the concrete RAUC wiring is `bootloader=custom` with the
backend below. (The device-side paths are **identical** to RK3588 —
`/usr/lib/rauc/ceralive-rauc-boot-adapter`, `/usr/bin/ceralive-boot-state` — so RAUC
`system.conf` is platform-uniform; only the *source implementation* differs.)

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

| File | Role |
|---|---|
| `x86-boot-state.sh` | grubenv A/B state engine + CLI; userspace twin of `grub.cfg` (→ `/usr/bin/ceralive-boot-state`) |
| `x86-rauc-boot-adapter.sh` | RAUC custom backend (→ `/usr/lib/rauc/ceralive-rauc-boot-adapter`) |
| `grub.cfg.tmpl` | GRUB A/B selector template (→ rendered `EFI/ceralive/grub.cfg`) |
| `install-x86-boot.sh` | build-time installer (`rootfs` + `esp` targets; generates the decrement ladder) |
| `x86-encode.sh` | x86 encode setup (VA driver + QSV/x264 selection + pipeline link) |
| `test-x86-fallback.sh` | offline proof of decrement→rollback + backend + render + encode (no GRUB/qemu/root) |
| `README.md` | this file |

## Test

```
v2/mkosi/platform/x86/test-x86-fallback.sh   # 72 assertions, no GRUB/qemu/root
```

Proves: fresh A/B; 3 failed boots of A → 3→2→1→0 → **fallback to B**; RAUC backend
roundtrip; `mark-good` reset; single-slot has no phantom B; grubenv is a valid
1024-byte block; `install-x86-boot.sh esp` renders board-specific `grub.cfg`
(console/ladder/PARTLABEL/`/vmlinuz`) + seeds grubenv; `rootfs` renders
`bootloader=custom` `system.conf`; `x86-encode.sh` writes the D1 encode config
(qsv primary, x264 fallback, NOT relay-only).

## Deferred / related (out of scope for task 33)

- **Build wiring (`lib/orchestrate.sh` x86 path, `platform/mkosi.finalize` x86 branch,
  `fetch-debs.sh` Debian-repo + `x86-64`→`amd64` map).** The shared orchestrator still
  gates on arm64 and dies on empty DTB/U-Boot (gaps **G1–G3**, `task-32-x86-manifest.txt`).
  `install-x86-boot.sh` + `x86-encode.sh` are the **ready hooks** a future `mkosi.finalize`
  x86 branch invokes (analogous to how `boot/install-boot.sh` is invoked for arm64).
- **`grub-install` of `grubx64.efi` into the ESP** → disk-assembly step (`esp --install-grub`).
- **`docs/partition-contract.md` `x86-ab` addendum** (ESP + grubenv vs the RK raw idbloader gap)
  → coordinated additive change to the FROZEN v1 contract.
- **RAUC keyring** (`/etc/rauc/keyring.pem`) → PKI tasks (`cert-work/rauc/`).
- **On-silicon validation** (real N100): qemu/HW A/B rollback boot, `vainfo` enc entrypoints,
  and the `bps`/patched-GStreamer dynamic-bitrate check.
