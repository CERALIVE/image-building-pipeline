# Build-log signature census

Frozen inventory of every warning/error signature a real device build emits, with
a disposition for each. This is the data file `ci/check-build-log.sh` enforces: a
build log may contain an `ACCEPTED` signature up to its recorded baseline count,
may contain a `POST-FIX` signature up to its recorded ceiling, and may contain
nothing else.

## Baseline

| field | value |
|---|---|
| Baseline log | real `rock-5b-plus --variant edge` build, `INSTALL_BOOT_BSP=1`, 2026-08-09 (`12:33:34`–`12:52:52`) |
| Evidence copy | `test-results/pipeline-restructure-kernel-backports/wave2/baseline-real-edge-build-f3.log` |
| Evidence SHA-256 | `615feb5e48c8b970cd2645033a8c95dbbe77cdceb5cdf220839642e8eb3c2bd5` |
| Lines | 26,404 |
| Outcome | build completed (`.raw` + signed `.raucb` emitted) |
| Signatures | 26 |

The evidence copy lives under the gitignored `test-results/` tree, so a fresh
checkout will not have it. It is reproduced by re-running the same board/variant
build; the SHA-256 above identifies the exact bytes this census was frozen from.

## Diagnostic surface

A log line is a *diagnostic* when, after the two normalization steps below, it
matches one of the anchors in `ci/check-build-log.sh`'s `DIAGNOSTIC_ANCHORS`. The
anchor set is deliberately tool-prefix based (`dpkg:`, `update-alternatives:`,
`invoke-rc.d:`, `W:`, `Ign:`/`Err:`, mkosi's `‣`, …) rather than a bare
`grep -i warn|error`, because the kernel build alone emits hundreds of
`CC drivers/.../error.o` object-file lines that are not diagnostics at all.

Normalization, in order:

1. Strip a trailing `\r` (the mkosi/dpkg legs of the log are CRLF) and the
   pipeline's own `[LEVEL] HH:MM:SS ` prefix.
2. Apply the ordered rule table in `ci/check-build-log.sh::normalize_log`, which
   replaces variable substrings with the placeholders `<PATH>`, `<N>`,
   `<DRIVER>`, `<ACTION>`, `<GROUP>`, `<VALUE>`, and collapses two multi-line
   diagnostics (dpkg's four-line merged-usr advisory, systemd-resolved's
   four-line `/etc/resolv.conf` block) onto one signature each by exact-line
   match.

Every rule is an exact string or an exact-line mapping. There are no wildcard
allowlist entries: a signature either normalizes to a string that appears
verbatim in the tables below, or it is novel and rejected.

## Dispositions

| disposition | meaning | lint behaviour |
|---|---|---|
| `FIXED` | this effort removed the cause; the signature must not reappear | any occurrence fails |
| `ACCEPTED` | caused by an external package or an inherent property of the build; recorded, not fixed | allowed up to `Baseline`; more fails |
| `BLOCKING` | must be fixed by the named todo before the effort closes | any occurrence fails |

`BLOCKING` count at freeze time: **0**. Every avoidable signature is dispositioned
`FIXED` against the todo that removes it, so the lint rejects a regression rather
than tolerating a known-bad state.

## Census (26 signatures)

| # | Signature | Baseline | Stage | Owner | Disposition | Note |
|---:|---|---:|---|---|---|---|
| 1 | `dpkg: warning: package architecture (arm64) does not match system (amd64)` | 145 | mkosi:base | external:dpkg | ACCEPTED | Inherent to the arm64-on-amd64 foreign build; mkosi passes `--force-architecture` on purpose. Removing it would mean dropping cross-arch builds. |
| 2 | `dpkg: warning: overriding problem because --force enabled:` | 145 | mkosi:base | external:dpkg | ACCEPTED | The companion line to signature 1 — dpkg announces each `--force-architecture` override. Same cause, same inherent scope. |
| 3 | `dpkg: warning: <merged-usr-via-aliased-dirs advisory>` | 4 | mkosi:base | external:dpkg | ACCEPTED | Debian bookworm ships merged-`/usr` via aliased dirs and dpkg advises about it on every bootstrap. Four consecutive lines of one advisory, collapsed to one signature. Not actionable from this repo. |
| 4 | `dpkg-statoverride: warning: --update given but /var/log/chrony does not exist` | 1 | mkosi:runtime | external:chrony | ACCEPTED | Emitted by chrony's own postinst, which statoverrides a log directory systemd-tmpfiles creates at boot. External maintainer script; harmless in a chroot. |
| 5 | `update-alternatives: warning: skip creation of <PATH> because associated file <PATH> (of link group <GROUP>) doesn't exist` | 13 | mkosi:base | ceralive:image | FIXED | todo9 — caused by `WithDocs=no` path-excluding `/usr/share/man/*` before alternatives registration ran. Manpages are now present through the postinst phase and pruned at the final app layer. |
| 6 | `update-alternatives: error: alternative path <PATH> doesn't exist` | 1 | mkosi:base | ceralive:image | FIXED | todo9 — same cause as signature 5, escalated to `error` for `/usr/share/man/man7/bash-builtins.7.gz`. Removed by the same manpage-ordering fix. |
| 7 | `update-rc.d: warning: start and stop actions are no longer supported; falling back to defaults` | 2 | mkosi:runtime | external:cpufrequtils | ACCEPTED | `cpufrequtils`' postinst calls `update-rc.d` with legacy start/stop arguments. Not suppressible by `policy-rc.d` (update-rc.d is the enable path, not the invoke path) and not our maintainer script. |
| 8 | `invoke-rc.d: WARNING: No init system and policy-rc.d missing! Defaulting to block.` | 2 | mkosi:base | ceralive:image | FIXED | todo10, completed 2026-08-10 — the build chroot has no `/sbin/init`, so invoke-rc.d complained about the absent policy file on every service-start attempt. An EXECUTABLE `policy-rc.d` returning 101 now covers the whole package-configuration phase; see "How rows 8/9/21 are actually fixed" below for the two halves that took. |
| 9 | `invoke-rc.d: initscript dbus, action "<ACTION>" failed.` | 3 | mkosi:runtime | ceralive:image | FIXED | todo10, completed 2026-08-10 — packages asked invoke-rc.d to `reload`/`force-reload` dbus inside the chroot. With `policy-rc.d` denying, the initscript is never run and cannot fail. |
| 10 | `invoke-rc.d: could not determine current runlevel` | 2 | mkosi:base | external:sysvinit | ACCEPTED | invoke-rc.d prints this from `get_runlevel` at line ~297, BEFORE `querypolicy` consults `policy-rc.d` at all — verified against the shipped `/usr/sbin/invoke-rc.d`. A policy file therefore cannot suppress it, and Debian's own comment marks the failure as expected in a chroot (`#823611`). |
| 11 | `start-stop-daemon: unable to stat /usr/libexec/polkitd (No such file or directory)` | 1 | mkosi:runtime | external:policykit-1 | ACCEPTED | polkit's postinst calls `start-stop-daemon` directly rather than through invoke-rc.d, so `policy-rc.d` does not apply. External maintainer script. |
| 12 | `W: No zstd in /usr/bin:/sbin:/bin, using gzip` | 1 | mkosi:platform | ceralive:image | FIXED | todo9 — `initramfs-tools` defaults to zstd compression but the `zstd` binary was not installed when the kernel postinst generated the initrd. `zstd` is now installed in the same transaction as `initramfs-tools`, before the kernel package. |
| 13 | `W: Possible missing firmware <PATH> for built-in driver <DRIVER>` | 16 | mkosi:platform | ceralive:kernel | ACCEPTED | `mkinitramfs` warning for foreign-platform drivers (tegra xhci, renesas xhci, microchip mscc, …) that arm64 `defconfig` builds in. Recorded here rather than fixed: the edge Kconfig trim that removes those drivers is todo13 (Wave 3), which will lower this count. A count INCREASE fails the lint. |
| 14 | `Ign:<N> file:/repository ./ InRelease` | 4 | mkosi:base | external:apt | ACCEPTED | mkosi's local package repository is a flat, unsigned directory, so apt probes for `InRelease` and correctly ignores its absence. Signing a build-time-only local repo would add a trust root for no gain. |
| 15 | `Ign:<N> file:/repository ./ Release` | 4 | mkosi:base | external:apt | ACCEPTED | Same cause as signature 14 — the second release-metadata probe of the same flat local repository. |
| 16 | `Ign:<N> file:/repository ./ Translation-en` | 4 | mkosi:base | ceralive:image | FIXED | todo8 — apt probed the local repository for translation catalogues. `Acquire::Languages "none"` in the build sandbox stops the probe; the appliance is single-locale C.UTF-8 and strips every catalogue anyway. |
| 17 | `Err:<N> file:/repository ./ Translation-en` | 24 | mkosi:base | ceralive:image | FIXED | todo8 — the `Err:` half of signature 16, emitted once per apt transaction. Same fix. |
| 18 | `‣ <PATH>: Setting FinalizeScript is deprecated, please use FinalizeScripts instead.` | 2 | mkosi:config | ceralive:image | FIXED | todo8 — `base/mkosi.conf` and `platform/mkosi.conf` used the singular key. Both now use `FinalizeScripts=`. |
| 19 | `‣ <PATH>: Setting RepartDirectories should be configured in [Output], not [Content].` | 1 | mkosi:config | ceralive:image | FIXED | todo8 — `disk/mkosi.conf` declared `RepartDirectories=` under `[Content]`. Moved to `[Output]`. |
| 20 | `‣ Could not rename <PATH> to <PATH> as they are located on different devices, falling back to copying` | 8 | mkosi:staging | ceralive:image | FIXED | todo11 — mkosi's workspace defaulted to `/var/tmp`, a different filesystem from the repo-local output tree, so every finished layer was copied instead of renamed. The workspace is now pinned beside the output. |
| 21 | `Reloading system message bus config...Failed to open connection to "system" message bus: Failed to connect to socket /run/dbus/system_bus_socket: No such file or directory` | 3 | mkosi:runtime | ceralive:image | FIXED | todo10, completed 2026-08-10 — printed by the dbus init script when invoke-rc.d ran it in a chroot with no running bus. With `policy-rc.d` denying, the init script is never invoked. |
| 22 | `/usr/lib/tmpfiles.d/dbus.conf:13: Failed to resolve user 'messagebus': No such process` | 1 | mkosi:base | external:dbus | ACCEPTED | dbus' tmpfiles snippet is evaluated before its own sysusers entry has been applied in the chroot. Emitted by the package's own tooling; the user exists in the finished image. |
| 23 | `<systemd-resolved postinst: /etc/resolv.conf busy (builder bind-mount)>` | 4 | mkosi:runtime | ceralive:image | ACCEPTED | Four consecutive lines (`mv: cannot move …`, `Cannot take a backup …`, `ln: failed to create symbolic link …`, `Cannot install symlink …`), collapsed to one signature. The builder bind-mounts `/etc/resolv.conf` so the chroot has DNS, which makes systemd-resolved's postinst unable to replace it. The image's own resolv.conf contract is applied later by `configure_networking` (see `tests/resolv-conf-symlink.test.sh`), so the postinst failing here is expected and inert. Unmounting during package configuration would break DNS for the rest of the layer. |
| 24 | `Cannot open netlink socket: Protocol not supported` | 1 | mkosi:runtime | external:nftables | ACCEPTED | `nftables`' postinst tries to talk to `NETLINK_NETFILTER` inside the build chroot, which has no netfilter netlink. External maintainer script; the ruleset is applied on the device by `ceralive-ingest-firewall.service`. |
| 25 | `dir not exist` | 1 | mkosi:platform | external:rockchip-multimedia-config | ACCEPTED | Diagnosed in todo11 and confirmed EXTERNAL. `rockchip-multimedia-config` 1.0.2-1's `DEBIAN/postinst` `configure` branch reads `else echo "dir not exist"; ln -s /lib /usr/lib64; …` when `/usr/lib64` is neither a symlink nor a directory. It is that package's own unconditional `echo`, not a diagnostic and not ours; the branch it announces does exactly what it should. The package is pinned by SHA-256 in `manifests/rk3588-userspace-deb-versions.txt`, so this string is immutable at that pin. |
| 26 | `Configured GrowFileSystem=<VALUE> for partition type 'linux-generic' that doesn't support it, ignoring.` | 3 | assemble:repart | ceralive:image | FIXED | todo8 — `repart/{20-rootfs_a,30-rootfs_b,40-data}.conf` set `GrowFileSystem=` on `Type=linux-generic` partitions, which systemd-repart does not support and ignores. The keys are removed; `/data` still grows on first boot via the `x-systemd.growfs` fstab option that was already doing the work. |

## Post-fix expected signatures

Enumerated exactly, like the census above, and introduced by this effort's own
fixes. These are NOT part of the frozen 26 — they have no baseline count because
they do not exist in the baseline log. `ci/check-build-log.sh` allows each up to
its recorded ceiling and rejects anything above it.

| Signature | Max | Stage | Introduced by | Rationale |
|---|---:|---|---|---|
| `invoke-rc.d: policy-rc.d denied execution of <ACTION>.` | 40 | mkosi:* | todo10 | invoke-rc.d prints this (`querypolicy`, the `101)` case) every time the build-time `policy-rc.d` correctly denies a service start inside the build chroot. It is the positive evidence that the suppression is working, and it replaces signatures 8, 9 and 21. A real `rock-5b-plus --variant edge` build emits **15** (11 `start`, 2 `force-reload`, 1 `reload`, 1 `restart`); the ceiling is set well above that so a package set that grows a few service-starting packages does not fail the lint, while a runaway still does. It was 16 before the fix actually took effect, which was a guess against a log in which the denial had never once fired — the number above is measured. |

## How rows 8/9/21 are actually fixed

Rows 8, 9 and 21 were dispositioned `FIXED` at census freeze on the strength of
the base layer's `policy-rc.d` skeleton tree, but Wave 8's real `--variant edge`
build was the **first log that ever tested that claim** and it emitted all three
at exactly their baseline counts. Two independent causes were found; both are
closed, and neither one alone is sufficient.

**1. Mode, not placement — and a umask cannot fix it.** Debian's `invoke-rc.d`
gates the helper on `test -x "${POLICYHELPER}"` (`/usr/sbin/invoke-rc.d` line
138), so a non-executable helper is reported as **missing** rather than as
denying. mkosi 26's `Apt.install()` writes its own `/usr/sbin/policy-rc.d` with
`Path.write_text()` inside `with umask(~0o644):`, producing mode 0644. The
obvious repair — widening that umask to `~0o755` — is a **complete no-op**, and
it shipped for a day looking plausible: a umask only ever CLEARS permission bits,
and Python's `open(..., "w")` requests base mode 0o666, which carries no execute
bit to keep. Both umasks land on 0644. `ci/Dockerfile` therefore inserts an
explicit `policyrcd.chmod(0o755)` after the write, with apply-or-fail drift
guards and a `py_compile` check.

**2. mkosi unlinks the helper, and only the base image declares `Packages=`.**
`Apt.install()` `unlink()`s the path when its transaction ends — including the
skeleton tree's copy, because the unlink does not care who put the file there.
`platform`, `runtime` and `app` set `BaseTrees=` with no `Packages=`, so mkosi's
`install_distribution()` returns early for them and never calls `Apt.install()`
at all. Every package transaction those layers run is one this repository drives
itself (`runtime`'s `shared.list` install, `platform`'s BSP via `mkosi-install`,
`app`'s first-party `dpkg -i` plus its `apt-get install -f`), and all of them ran
with the path absent. That is precisely where rows 9 and 21 came from — inside
the runtime layer's `‣ Running postinstall script …` step, not the base layer's
`‣ Installing Debian`. Those three layers now install the helper themselves
(`customize/postinst.d/services.sh::install_chroot_service_policy` plus two
self-contained twins), before their first package transaction. The app layer's
existing `remove_chroot_service_policy` still strips it, fail-loud, before the
rootfs is sealed.

**A skeleton tree cannot substitute for the postinst call.** `SkeletonTrees=` on
the upper images looks equivalent and is not: `install_skeleton_trees()` runs
inside mkosi's `if not cached:` branch while `run_postinst_scripts()` runs
unconditionally, and this repo builds with `Incremental=yes`. A cached layer
would silently drop the helper while still running the transactions that need it.

**Verification.** A real `rock-5b-plus --variant edge` build with a deliberately
purged base cache (so the base layer's own `‣ Installing Debian` really re-ran):
rows 8/9/21 go from 2/3/3 to **0/0/0**, replaced by 15 `policy-rc.d denied
execution` lines, and the final `app` tree carries no `/usr/sbin/policy-rc.d`.
The base half alone was independently confirmed first on a vendor-path build,
where the two `invoke-rc.d: WARNING` lines became two
`policy-rc.d denied execution of start.` denials.

**Faster reproduction, for the next investigation of this class.** These three
signatures do not need the `--variant edge` kernel-from-source build: a plain
`./build rock-5b-plus` exercises the same four layers in roughly half the time.
What it DOES need is a cold base layer — `mkosi/cache/<board>/*base.cache` and
`*base.manifest` must be deleted first (they are root-owned, so remove them from
a throwaway container), otherwise mkosi skips `install_distribution()` entirely
and row 8's window never opens. A build log with no `‣  Installing Debian` line
in it has not tested row 8, whatever the grep says.

## Provenance of each count

Counts are the output of `ci/check-build-log.sh --census-report <log>` against
the baseline evidence copy. Re-derive them with:

```bash
ci/check-build-log.sh --census-report \
  test-results/pipeline-restructure-kernel-backports/wave2/baseline-real-edge-build-f3.log
```

## Changing this file

- A new avoidable signature is `BLOCKING` and names the todo that will remove it.
- A new unavoidable signature is `ACCEPTED` and states WHY it cannot be removed
  from this repository, naming the external package where applicable.
- A count may be lowered freely. Raising an `ACCEPTED` count requires the same
  justification as adding a row.
- Never add a wildcard, a regex, or a prefix match to either table.
