# Package lock and Debian snapshot probe [PARTIAL]

Every real image build now writes `images/<board>/<timestamp>.packages.lock.json`
at `[6d/9]`, after the normalized rootfs tar and before parity/disk assembly.
The final `/var/lib/dpkg/status` is the inventory: each installed package must
resolve to the **same name, version and architecture** in one of the receipts.
The lock records `built_at` (UTC wall time), the already-resolved
`SOURCE_DATE_EPOCH`, the `Date:` fields of the apt-verified Debian `InRelease`
files keyed by suite, and each package's provenance and SHA-256. An unknown
installed package is a fatal build error, not a null hash or a placeholder.

There are three package hash sources, and no general fourth one:

1. The base, platform, runtime and app layers capture newly configured Debian
   packages from each layer's own apt-verified Packages lists while those lists
   still exist. They use the shared `lib/fetch/index.sh::index_lookup_optional`
   reader and write layer-specific JSONL receipts inside the in-progress image.
   The app captures before its final apt-list cleanup. Base includes mkosi's own
   bootstrap transaction; platform includes Debian dependencies of the staged
   board packages; runtime includes its CA bootstrap, shared set and any later
   in-layer installs. App-layer local `.deb` installs are excluded from this
   Debian-index path.
2. The BSP, pinned RK3588 userspace and first-party local `.deb` installs read
   the *existing* expected digest from the fetcher's gpgv-verified Packages
   index or the committed URL+SHA pin. The index reader is the same one used by
   the verified download cache; the fetch receipt is emitted before the curl
   scratch index is removed. The final merge never re-hashes these downloads.
3. `libv4l-0` alone is generated locally by
   `lib/fetch/userspace.sh::build_libv4l0_compat_deb`. Its own generator hashes
   the completed package immediately and writes a separate receipt with
   `origin: generated-locally`. A future generator receives no automatic
   exemption: without a receipt its installed package fails the final merge.

The source-built `linux-image-*` package is separate from those three paths.
Its lock entry has `origin: source-built`, the immutable kernel and patch
commit pins, and `artifact.sha256` keyed by the generated `.deb` filename,
matching the kernel artifact cache's `manifest.json` hash-map vocabulary. It
is not a Debian snapshot package. The ordinary packages keep the five-field
`{name,version,arch,origin,sha256}` shape; the kernel's source/artifact fields
make the difference explicit. Neither a Debian snapshot nor a later Debian
point release affects which pinned kernel source and patch commits were built.

## Debian snapshot probe: APT passes; mkosi build path still blocks the override

The initial `debian:trixie-slim` probe was **confounded**: its container had no
CA trust store. Both the plain `deb.debian.org` and snapshot URLs failed with
the *same* certificate error. Quoting only the snapshot errors falsely made
that look like a snapshot-service fault. The corrected probe first installed
`ca-certificates` with a temporary **HTTP-only**, `Signed-By`-authenticated
Debian source, isolated through `Dir::Etc::sourcelist=/dev/null` and
`Dir::Etc::sourceparts=...` as in `bootstrap_ca_trust`. It then used HTTPS for
both normal and snapshot suites, `Snapshot: enable` in both deb822 stanzas,
`APT::Snapshot=20260920T000000Z`, and
`Acquire::Check-Valid-Until=true`. `APT::Update::Error-Mode=any` also made a
partial index fetch fatal instead of accepting apt's possible exit-0 warning.
The complete command and unedited output are at the main-workspace
`.omo/evidence/update-system-overhaul/task-20/snapshot-probe.txt`. Here is the
**complete output**, including the non-snapshot traffic and bootstrap:

```text
apt 3.0.3 (amd64)
Supported modules:
*Ver: Standard .deb
*Pkg:  Debian dpkg interface (Priority 30)
 Pkg:  Debian APT solver interface (Priority -1000)
 S.L: 'deb' Debian binary tree
 S.L: 'deb-src' Debian source tree
 Idx: Debian Source Index
 Idx: Debian Package Index
 Idx: Debian Translation Index
 Idx: Debian dpkg status file
 Idx: Debian deb file
 Idx: Debian dsc file
 Idx: Debian control file
 Idx: EDSP scenario file
 Idx: EIPP scenario file
CA before bootstrap: absent
Get:1 http://deb.debian.org/debian trixie InRelease [140 kB]
Get:2 http://deb.debian.org/debian trixie/main amd64 Packages [9678 kB]
Fetched 9819 kB in 1s (11.6 MB/s)
Reading package lists...
Reading package lists...
Building dependency tree...
Reading state information...
The following additional packages will be installed:
  openssl
The following NEW packages will be installed:
  ca-certificates openssl
0 upgraded, 2 newly installed, 0 to remove and 0 not upgraded.
Need to get 1669 kB of archives.
After this operation, 2970 kB of additional disk space will be used.
Get:1 http://deb.debian.org/debian trixie/main amd64 openssl amd64 3.5.7-1~deb13u2 [1507 kB]
Get:2 http://deb.debian.org/debian trixie/main amd64 ca-certificates all 20250419 [162 kB]
Preconfiguring packages ...
Fetched 1669 kB in 0s (19.5 MB/s)
Selecting previously unselected package openssl.
(Reading database ... 4951 files and directories currently installed.)
Preparing to unpack .../openssl_3.5.7-1~deb13u2_amd64.deb ...
Unpacking openssl (3.5.7-1~deb13u2) ...
Selecting previously unselected package ca-certificates.
Preparing to unpack .../ca-certificates_20250419_all.deb ...
Unpacking ca-certificates (20250419) ...
Setting up openssl (3.5.7-1~deb13u2) ...
Setting up ca-certificates (20250419) ...
Updating certificates in /etc/ssl/certs...
150 added, 0 removed; done.
Processing triggers for ca-certificates (20250419) ...
Updating certificates in /etc/ssl/certs...
0 added, 0 removed; done.
Running hooks in /etc/ca-certificates/update.d...
done.
CA after bootstrap: present
Hit:1 https://deb.debian.org/debian trixie InRelease
Get:3 https://deb.debian.org/debian trixie-updates InRelease [47.3 kB]
Get:4 https://deb.debian.org/debian-security trixie-security InRelease [43.4 kB]
Get:5 https://deb.debian.org/debian trixie-updates/main amd64 Packages [4412 B]
Get:6 https://deb.debian.org/debian-security trixie-security/main amd64 Packages [263 kB]
Get:2 https://snapshot.debian.org/archive/debian/20260920T000000Z trixie InRelease [140 kB]
Get:7 https://snapshot.debian.org/archive/debian/20260920T000000Z trixie-updates InRelease [47.3 kB]
Get:8 https://snapshot.debian.org/archive/debian-security/20260920T000000Z trixie-security InRelease [43.4 kB]
Get:9 https://snapshot.debian.org/archive/debian/20260920T000000Z trixie/main amd64 Packages [9678 kB]
Get:10 https://snapshot.debian.org/archive/debian/20260920T000000Z trixie-updates/main amd64 Packages [4412 B]
Get:11 https://snapshot.debian.org/archive/debian-security/20260920T000000Z trixie-security/main amd64 Packages [262 kB]
Fetched 10.5 MB in 3s (4101 kB/s)
Reading package lists...
Snapshot list files:
/var/lib/apt/lists/snapshot.debian.org_archive_debian-security_20260920T000000Z_dists_trixie-security_InRelease
/var/lib/apt/lists/snapshot.debian.org_archive_debian_20260920T000000Z_dists_trixie-updates_InRelease
/var/lib/apt/lists/snapshot.debian.org_archive_debian_20260920T000000Z_dists_trixie_InRelease
All three signed snapshot InRelease files present
```

This **proves apt 3.0.3 can fetch all three valid signed snapshot indexes** at
this timestamp with Valid-Until enforcement; it does *not* prove the image
builder can do so under that same policy. The pinned mkosi **v26** hardcodes
`-o Acquire::Check-Valid-Until=false` in `mkosi/installer/apt.py::Apt.cmd` for
its own package transactions (including the base bootstrap). Its `--snapshot`
option would therefore build through a disabled check even if a separate runtime
postinstall apt call retained the check. The canonical builder's Dockerfile only
patches mkosi's `policy-rc.d` mode; native mkosi is also supported. Simply
passing `--snapshot` would violate this task's explicit no-bypass condition.
`CERALIVE_DEBIAN_SNAPSHOT` has **not** been implemented: the blocker is the
mkosi build path, **not** Debian's snapshot service or the CA-trusted apt probe.
Resolving it requires a separately reviewed build-toolchain policy for both
container and native builders, not a device-source change. The package lock is
an exact record of installed bytes; floating Debian inputs are not pinned yet.
