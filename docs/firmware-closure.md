# Final-rootfs firmware closure [EXISTS: artifact gate]

`stage_firmware_closure_gate` runs immediately after the size gate on the same
emitted rootfs tar, before package provenance, parity and disk assembly. It
requires host Python >= 3.11, GNU tar and `modinfo` from kmod. It mounts nothing
and executes no rootfs program. `INSTALL_BOOT_BSP=0` skips it for kernel-less
parity builds; the orchestrator's earlier `DRY_RUN` exit skips both gates.
Debug/non-shipping kernels still have to satisfy firmware closure.

Run the same check directly:

```bash
bash lib/check-firmware-closure.sh images/<board>/<timestamp>.rootfs.tar
bash lib/check-firmware-closure.sh <root-directory> <exceptions.txt>
bash tests/firmware-closure-gate.test.sh
```

The gate calls `firmware_sweep_module_refs` from the existing build sweep.
Installed `.ko*` files go through host `modinfo -F firmware`; built-in
`modules.builtin.modinfo` uses that collector's producer-format and inventory
correspondence checks. The released device stager and kernel inputs stay frozen.
A partial walk, failed module read, unusable metadata or missing kernel inventory
is fatal. An explicit empty inventory with no drivers is also fatal here.
Distinct `/lib/modules` and `/usr/lib/modules` trees and unterminated built-in
inventory lists are refused rather than accepting a partial scan.
Built-in-only kernels with usable driver metadata remain valid.
Development `build`/`source` links are outside the driver inventory.

Every rootfs `var/lib/dpkg/info/*.list` contributes to the shipped set, whatever
its package name. A metapackage with no payload cannot hide another package's
firmware. A shipped static reference must resolve to a regular rootfs file;
the same name with `.zst` or `.xz` is accepted. Missing objects report both
driver and path. Never-shipped references are counted and printed, then allowed.
The gate checks static package closure, not physical hardware compatibility.

`manifests/firmware-closure-exceptions.txt` is empty except for its header.
Each approved exception must be an exact relative reference followed by one tab
and a nonempty reason. Patterns, traversal and duplicate entries fail.
An exception applies only to that missing shipped reference; it cannot waive
an incomplete inventory. The log prints its reason.

Runtime absolute symlinks resolve relative to the supplied rootfs. Relative
links may use parent components within that root; escaping it, cycles and
dangling firmware links cannot satisfy closure. Archive member names must be
relative and cannot contain parent traversal. Hard links use archive-root
names. The reader indexes the archive and copies only module/metadata inputs
into private scratch, without extracting archive paths onto the host.
Tar enumeration and read errors remain fatal. The directory form also propagates
unreadable inventory and traversal errors.

Structural checks cannot detect every loss exactly at a valid producer record
boundary. Authentic pinned producer inputs and artifact integrity remain the
trust boundary; this gate does not invent cryptographic completeness.
Full image builds and hardware qualification are separate from synthetic QA.
Plan resolution allows EFI/GRUB's intentionally empty DTB/U-Boot package sets;
the other adapters retain their existing boot-package requirements.
