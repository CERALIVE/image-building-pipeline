# CeraLive v2 — Image Size Notes

Running record of size-reduction levers applied to the mkosi build and the
rationale behind each. Numbers marked *(estimate)* are derived from Debian
`Installed-Size` metadata and published Armbian package sizes, not from a wet
build on this host (no RK3588 board / full-build budget in the dev environment);
they are upper-bound guidance, not contractual figures.

---

## 1. Documentation strip — `WithDocs=no`

Already set on every layer (`base`, `platform`, `runtime`, `app`). mkosi drops
man pages, `/usr/share/doc`, info pages, and changelogs at install time. No
change needed in Task 19 — verified present.

---

## 2. Locale strip — single-locale C.UTF-8 appliance (Task 19)

### What changed

`v2/mkosi/mkosi.images/{base,platform,runtime,app}/mkosi.conf`:

- `Locale=C.UTF-8` + `LocaleMessages=C.UTF-8` on `base` — pins `/etc/locale.conf`
  to `LANG=C.UTF-8`. glibc 2.36 (bookworm) ships **C.UTF-8 built into libc**, so
  no `locale-gen` run and no `/usr/lib/locale/locale-archive` are required for it
  to work.
- `RemoveFiles=/usr/share/locale/*,/usr/lib/locale/locale-archive` on **every**
  layer — purges gettext message catalogs (the per-language `.mo` files each
  package ships) and any compiled locale-archive a transitively-pulled `locales`
  package might leave behind. The glob is repeated per layer because mkosi runs
  `RemoveFiles` at the end of *each* image build, so each layer cleans the
  catalogs introduced by *its own* new packages.

### Why it is safe

C.UTF-8 carries **no** `.mo` catalog — programs fall back to their compiled-in
English `msgid` strings, which is exactly the behaviour an unattended appliance
wants. There is no interactive login user choosing a language, and CeraUI is a
self-contained web frontend that does its own i18n. Boot path (systemd / udev /
RAUC) is locale-agnostic and unaffected.

### Size impact *(estimate)*

`/usr/share/locale` is the dominant locale consumer in a server image; typical
Debian minimal + service stacks carry **~80–250 MB** of `.mo` catalogs across all
installed packages (systemd, apt, util-linux, gettext, NetworkManager, the
GStreamer/ffmpeg stack, first-party apps). The compiled `locale-archive`, if a
`locales` dependency ever generates one, adds up to a further **~200 MB** for a
default all-locales build (we never generate it, so this is purely defensive).

Net expected reduction: **~100–250 MB** off the rootfs, with **zero** functional
loss for a C.UTF-8-only device. Confirm the realised figure on the first full
RK3588 build with:

```sh
# inside the built app tree
du -sh usr/share/locale usr/lib/locale 2>/dev/null   # expect near-empty
```

---

## 3. `armbian-firmware` split audit (Task 19)

### Decision: KEEP `armbian-firmware` — do NOT swap to the Debian split

`v2/manifests/families/rk3588.yaml` keeps `firmware_packages: [armbian-firmware]`.

### Context

`armbian-firmware` is the broad Armbian firmware bundle. Task 11 already chose it
to subsume the board WiFi/BT blobs (`rtl8852be-firmware`, `firmware-realtek`) so
boards declare no per-board firmware field. The Task 19 question: can we replace
the monolith with a narrower SoC-specific + board-WiFi-only set on bookworm arm64?

### Why the narrower swap is NOT feasible here

Both rk3588 boards run the Armbian **vendor** kernel (Decision D3), not mainline:

| Board | WiFi/BT part | Driver class |
|---|---|---|
| Radxa Rock 5B+ | Realtek **RTL8852BE** | Armbian out-of-tree vendor driver |
| Orange Pi 5+ | Broadcom **AP6275P** (`brcmfmac`) | vendor / out-of-tree |

Debian's split firmware packages (`firmware-realtek`, `firmware-brcm80211`) are
built for the **mainline in-tree** drivers and ship the generic blobs *without*
the Armbian per-board **NVRAM `.txt`** config files the vendor drivers load at
probe time. Dropping the Armbian bundle for the Debian split therefore risks the
WiFi/BT radio never associating on the vendor kernel — a board-breaking
regression that violates the "do not drop firmware the board needs" constraint.

`armbian-firmware` is also already the **trimmed** Armbian variant — it is *not*
`armbian-firmware-full`. That is the narrowest safe lever the Armbian feed
offers; there is no finer split that keeps the vendor-kernel WiFi/BT path intact.

### Size impact *(estimate)*

| Option | Approx installed size | WiFi works on vendor kernel? |
|---|---|---|
| `armbian-firmware` (current, trimmed) | ~100–150 MB | ✅ yes — board NVRAM included |
| `armbian-firmware-full` | ~400–500 MB | ✅ yes (but much larger — rejected) |
| Debian split: `firmware-realtek` (6.7 MB) + `firmware-brcm80211` (17.7 MB) | ~24 MB | ⚠️ **at risk** — no Armbian NVRAM `.txt` |
| Debian split + `firmware-misc-nonfree` (50.5 MB) | ~75 MB | ⚠️ still missing board NVRAM |

(Debian sizes from bookworm `non-free-firmware/binary-arm64` `Installed-Size`.)

A Debian-split swap *could* save **~75–125 MB** on paper, but only by trading a
guaranteed-working radio for an unverified one on hardware we cannot currently
test. The size win is not worth a potential WiFi-down field regression, so the
monolith stays until a board is in hand to validate a split empirically.

### Re-evaluation trigger

Revisit when an RK3588 board is reachable: build a split-firmware image, confirm
`brcmfmac`/`rtw89` associate and that BT enumerates, then measure the real delta.
Until then `armbian-firmware` is the correct, safe choice.
