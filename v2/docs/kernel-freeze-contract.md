# Kernel freeze contract — the boot stack changes only via RAUC

**Status:** `[EXISTS]` — baked by every image built from this pipeline.

The kernel, device tree, U-Boot and firmware on a CeraLive device change **only**
when a full-image RAUC bundle writes a new rootfs slot. They are never changed by
`apt` on the running device. This document states that contract, the two
mechanisms that enforce it, exactly what each one does *not* cover, and how it
interacts with RAUC.

---

## 1. Why the boot stack cannot be an apt package like any other

[`docs/partition-contract.md`](../../docs/partition-contract.md) §1 rule 3 is the
root of it:

> 3. **Kernel rides with the rootfs.** Kernel/DTB/initrd are inside each slot's `/boot`, so an
>    OS update swaps kernel + userland atomically. The `boot` partition holds only the
>    bootloader environment + slot selector.

So the kernel is not a free-floating package — it is *part of a slot*. The A/B
selector (`v2/mkosi/platform/boot/boot.scr.cmd`) loads `/boot/Image`,
`/boot/dtb/rockchip/${fdtfile}` and `/boot/initrd.img-<REL>` out of whichever slot
it selected, and RAUC's rollback budget is the promise that a slot which fails to
boot is abandoned for the other one.

An `apt-get upgrade` that replaced `linux-image-vendor-rk35xx` in place would
break both halves of that:

- It rewrites `/boot` **inside the running slot**, so the slot no longer matches
  the image that was verified, installed and marked good. The rollback target is
  now a slot whose kernel nobody tested.
- It is not atomic with the userland. A vendor BSP kernel bump changes the module
  ABI (`/lib/modules/<REL>`), the DTB set, and — in the vendor package's case —
  the `initramfs-tools` hook output. Half-updating that mid-uptime is how a board
  reboots into a slot with modules for a kernel that is no longer there.

The sanctioned path for a kernel change is therefore: rebuild the image, publish
a signed `.raucb`, let RAUC write the **inactive** slot, and reboot into it under
the bootcount budget with a healthcheck-gated mark-good.

---

## 2. What is frozen

The freeze set is **resolved from the manifest**, never hardcoded — the per-board
U-Boot package name differs, so a literal list would freeze one board only:

| Manifest field | rock-5b-plus | orange-pi-5-plus |
|---|---|---|
| `kernel_packages` | `linux-image-vendor-rk35xx` | `linux-image-vendor-rk35xx` |
| `dtb_packages` | `linux-dtb-vendor-rk35xx` | `linux-dtb-vendor-rk35xx` |
| `uboot_packages` | `linux-u-boot-rock-5b-plus-vendor` | `linux-u-boot-orangepi5-plus-vendor` |
| `firmware_packages` | `armbian-firmware`, `libmali-valhall-g610-g24p0-wayland-gbm` | same |

`libmali` is in `firmware_packages` and is therefore frozen with the rest. That is
correct rather than incidental: it is kernel-coupled GPU userspace installed from
the same local, build-time-only package directory, and it is not an app-layer
package.

Under an opt-in `--variant` the same fields resolve to the source-built kernel
package (`linux-image-7.1.5-ceralive-rk3588`, or
`linux-image-6.1.115-ceralive-vendor-rk35xx`) and the freeze follows them
automatically.

## 3. What is explicitly NOT frozen

Every first-party CeraLive package stays **apt-updatable**, because
`apt.ceralive.tv` is the ordinary software-update channel CeraUI's
`system.startUpdate()` drives:

```
cerastream            ceralive-device (CeraUI)   srtla-send-rs
libsrt1.5-ceralive    gstreamer1.0-libuvch264src rauc-hawkbit-updater
modemmanager  libmm-glib0  libmbim-glib4  libmbim-proxy  libmbim-utils
libqmi-glib5  libqmi-proxy libqmi-utils   libqrtr-glib0
```

This is enforced, not merely intended: `freeze_boot_packages` **refuses by name**
and fails the build if any of them ever reaches the freeze set (for example
because a manifest routed one into a boot-BSP field), and it re-checks after
holding that none of them is on dpkg's hold list. `v2/tests/manifest.bats` §31
carries the negative assertion, and
`v2/tests/kernel-freeze-guardrails.test.sh` proves with a real
`apt-get -s install cerastream` that the package still installs with the whole
freeze in place.

**There is no `unattended-upgrades` on this image**, and there must not be. The
device's update path is RAUC for the OS and an operator-driven apt transaction for
the app layer; an automatic upgrade daemon would be answering a question this
appliance does not ask.

---

## 4. The two mechanisms

Baked by `v2/mkosi/customize/postinst-lib.sh::freeze_boot_packages`, called last
in the runtime layer's `main()` — after every apt transaction that layer performs,
so the pinned versions are the final ones.

### 4a. dpkg holds — the PRIMARY mechanism

```
apt-mark hold linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx …
```

A hold is recorded in `/var/lib/dpkg/status` as `Status: hold ok installed`. Apt
refuses to upgrade or remove a held package, and — the part the pin cannot do — it
also refuses the **explicit** `apt-get install <pkg>` form, reporting the package
as held back and changing nothing.

Undoing it takes a deliberate `apt-mark unhold` or an explicit
`--allow-change-held-packages`.

Inspect it on a device with:

```bash
apt-mark showhold
```

The build **verifies** the holds landed and fails if any did not — a hold that
silently did not apply would ship an apt-upgradable kernel on an image that passes
every other gate.

### 4b. The apt preferences pin — supplementary

`/etc/apt/preferences.d/ceralive-kernel-freeze`, one stanza per package:

```
Package: linux-image-vendor-rk35xx
Pin: version 26.5.1
Pin-Priority: 1001
```

**It pins by name + version, not by origin, and that is forced rather than
chosen.** The boot BSP is installed from a LOCAL package directory that exists
only during the build (mkosi's ephemeral `file:/repository`). Those packages carry
no apt-origin identity on the shipped device at all, so there is no
`Pin: origin …` or `Pin: release …` expression that can designate "the staged
local set". The only expressible pin is the literal package name plus the literal
installed version, and the version is read from `dpkg-query` at build time so the
file always states what is actually installed.

**LIMITATION — the pin is bypassable, by design of apt.** Apt preferences rank
*candidate* versions; they do not forbid an operator from naming a different one.
All of these ignore the pin:

- `apt-get install <pkg>=<other-version>`
- `apt-get install --allow-downgrades …`
- `apt-get -o Dir::Etc::Preferences=/dev/null …` (or `Dir::Etc::PreferencesParts`)
- `dpkg -i <some>.deb` — dpkg does not read apt preferences at all

That is precisely why the hold is primary and the pin is the second layer. Neither
mechanism claims to stop a root operator who has decided to override the freeze;
both stop the accident. The limitation is repeated in a comment header inside the
generated file, so it travels to the device with the pin.

---

## 5. RAUC does NOT consult dpkg holds — and must not be expected to

This is the semantic that is easiest to get wrong in either direction, so state it
plainly:

- **RAUC never runs dpkg or apt.** It writes the whole **inactive** slot —
  `mkfs.ext4` on the target slot, then the rootfs image is copied in. The running
  slot's `/var/lib/dpkg/status`, and therefore its holds, are simply not on that
  code path. A held kernel does **not** block, filter or alter a RAUC install.
- **The new slot brings its own holds.** Because the kernel rides inside the
  rootfs (`partition-contract.md` rule 3), the freshly written slot arrives with
  its own `/var/lib/dpkg/status`, carrying the holds that *its own build* baked.
  Those govern that slot's apt from its first boot.
- **Therefore each image freezes itself.** The freeze is not fleet state that an
  update has to preserve, migrate or re-apply. Every image is self-consistent:
  the kernel it ships is the kernel its holds pin, with no coupling between
  consecutive releases.

The practical consequence for an operator: a RAUC update is the *only* thing that
moves the kernel, and it moves it wholesale. There is no state to unhold first and
nothing to re-hold afterwards.

---

## 6. Verifying it on a device

```bash
# The holds (primary mechanism)
apt-mark showhold

# The supplementary pin, and the effective apt policy for the kernel
cat /etc/apt/preferences.d/ceralive-kernel-freeze
apt-cache policy linux-image-vendor-rk35xx

# The freeze must not touch the app layer
apt-mark showhold | grep -E '^(cerastream|ceralive-device|srtla-send-rs)$'   # expect: no match

# A dry run must not offer the kernel
apt-get -s upgrade
```

`apt-get -s upgrade` reports a frozen package under *"The following packages have
been kept back"* and emits no `Inst linux-image-…` line.

---

## 7. Changing the frozen kernel deliberately

The supported route is a new image:

1. Update the exact pin in `v2/manifests/armbian-bsp-deb-versions.txt` following
   [`docs/RELEASE-PROCESS.md`](../../docs/RELEASE-PROCESS.md) §4 (signed-index
   review, hardware implications) and the kernel baseline in
   `v2/manifests/bsp-baseline.json`.
2. Build, publish the signed `.raucb`, roll it out. RAUC writes the inactive slot;
   the new slot's own holds pin the new kernel.

For **bench** work only, a hold can be lifted by hand on a device:

```bash
sudo apt-mark unhold linux-image-vendor-rk35xx
```

Doing that produces a slot whose `/boot` no longer matches any released image.
Treat it as live-patch drift, ledger it, and reflash before drawing any conclusion
from that board about a released image.

---

## 8. Where the code and the proofs live

| Piece | Path |
|---|---|
| The freeze function | `v2/mkosi/customize/postinst-lib.sh::freeze_boot_packages` |
| Wiring (the executor `./v2/build` actually runs) | `v2/mkosi/mkosi.images/runtime/mkosi.postinst.chroot` `main()`, last call |
| Drift gate registration | `v2/ci/postinst-drift-check.sh` `CONSOLIDATED_FUNCS` |
| Behavioural suite (hold set, pin file, fail-closed legs, real `apt-get -s upgrade`) | `v2/tests/kernel-freeze-guardrails.test.sh` |
| Structural guards | `v2/tests/manifest.bats` §31 |
| Partition rule this enforces | [`docs/partition-contract.md`](../../docs/partition-contract.md) §1 rule 3 |
| What a dev-push may and may not replace | [`dev-loop.md`](dev-loop.md) → "What is and isn't updated" |
