# Crash logs across warm resets (draft)

A silent reset can leave no clue about the preceding failure. On ROCK 5B and
ROCK 5B+, the source kernel build adds a ramoops reserved-memory node to the
board device trees. Ramoops lets the kernel keep its last crash log in RAM.
Stock systemd-pstore saves and clears that log on the next boot.

## Kernel device tree

`manifests/kernel/rk3588-ramoops.dtsi` reserves 1 MiB at
`0x1f000000–0x1f0fffff`: 128 KiB crash records, 512 KiB console, and
`max-reason=2` (oops and panic). The rest holds four crash records.
`lib/kernel/ramoops.sh` includes this node in both Rock board sources before
`bindeb-pkg` compiles and packages the DTBs. The include and helper are kernel
fingerprint inputs. Package revisions advance to avoid reusing released bytes.
The boot script is unchanged. A device-tree build failure fails the build,
not a boot-time edit. Existing required symbols are PSTORE, PSTORE_RAM and
PSTORE_CONSOLE, built in.

This applies to newly built kernels, not existing released kernel packages.
Production image assembly requires the matching authenticated kernel release;
this draft does not publish one or alter the release admission checks.

## Stock archive and read-only access

`Storage=external` and `Unlink=yes` select systemd-pstore's own archive and
acknowledgement. Its service waits for the required `/data` mount and tmpfiles
setup. Tmpfiles is ordered after the `/data` mount attempt even when fstab
marks it `nofail`. A service-local bind maps `/data/ceralive/pstore` to
`/var/lib/systemd/pstore`; the original stock unit and binary remain in use.
The bind exists only in that service's mount namespace. Outside it, read the
persistent directory directly. Missing `/data` prevents service execution, so
pstore remains available for recovery. Tmpfiles creates the private 0700
archive. Before each stock collection, a small ordered pre-step moves existing
flat ramoops files into a unique history directory so a later warm reboot cannot
replace them. It retains at most 31 previous collections plus the current one,
pruning by zero-padded sequence number and limiting history to 44 MiB of apparent
size. Allocation uses exclusive directory creation and retries collisions. The
wall clock is saved only in `collected-at`: the time the previous flat files
were moved into history, or an interrupted move was resumed, rather than the
original stock collection time. Backward steps and repeated boot epochs do not
affect retention. Empty allocations are removed, and interrupted
moves resume in the same generation. With pstore decompression, the configured
1 MiB RAM reservation can yield about 1.4 MiB in the current collection;
filesystem metadata and block allocation add overhead. This is a rolling bound,
not a promise to keep every crash indefinitely. A larger reservation requires
reviewing this budget. Tmpfiles has no age-based cleanup rule: only sequence-based
count and size pruning removes saved generations. The size budget counts only
numbered generation directories.

For support export, use stock files (root permissions are required):

```sh
sudo find /data/ceralive/pstore -type f -name '*ramoops*' -exec tail -v -n +1 -- '{}' +
sudo journalctl -u systemd-pstore.service
```

The find command is read-only, supports both direct and nested archive files,
and prints nothing for an empty archive. systemd owns the filenames and layout;
there is no custom JSON schema, latest-boot reader, collector or clearing script.
The small pre-step only rotates saved files; stock pstore still reads and clears
the kernel store.
CeraUI currently has no consumer of the removed reader. Watchdog bootstatus and
U-Boot reset causes belong in a separate boot record; they are not collected here.
Persistent `/data` survives A/B rootfs replacement. Journal copies have independent
journald retention; use
`journalctl -u systemd-pstore.service -o verbose --all` to include the `FILE=`
contents rather than just the move messages. After a boot without an RTC, journal
files containing those `FILE=` copies can be vacuumed early because their first
entries predate clock synchronization. The archive on `/data` is the durable copy.

## Qualification still required

The proposed address is below 512 MiB, but it needs measured checks of the
firmware reservations, full loader relocation/load ranges, DT and `/proc/iomem`
for every RAM size and kernel/bootloader pair. In particular, the initrd loaded
at `0x0a200000` must end below `0x1f000000` (size below 334 MiB); a loader using
`0x12180000` has only 206.5 MiB available. Check actual load addresses and sizes.
ECC is currently disabled in the node; the Reed-Solomon Kconfig dependency does
not enable it. Qualify `ecc-size = <16>` and its reduced record capacity together
with warm-reset preservation before enabling it. Confirm registration, then repeat
panic and watchdog warm resets and verify the stock saved files and clearing.
DDR initialization can erase RAM. Power loss destroys RAM contents; a hang may
leave only console output. No hardware qualification is claimed by host tests.

TODO: other RK3588 boards (including Orange Pi 5 Plus), other ARM families and
x86 need their own address/backend and preservation checks. Do not copy this
reservation to them without qualification. No watchdog policy changes.
