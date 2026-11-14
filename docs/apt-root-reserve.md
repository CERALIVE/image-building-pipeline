# APT metadata and root reserve

The runtime's `81ceralive-cache` disables `Dir::Cache::pkgcache` and
`Dir::Cache::srcpkgcache` for every layout. APT can read package lists directly;
these binary accelerators need not consume space in each root slot. This policy
does not remove pre-existing caches from deployed systems or change geometry.
Downloaded archives continue to use `/data/ceralive/apt-archives/`.

`apt-get clean` removes archives, not `/var/lib/apt/lists`. Lists are needed from
refresh through discovery, admission and installation. Do not add an unconditional
DPkg hook deleting them: it would also disrupt multi-step update callers. A
manual maintenance workflow may remove lists after its entire transaction, then
must run `apt-get update` before the next discovery/install. The application
layer cleans lists and binary caches at image build completion. Check inherited
`/var/cache/apt/archives` separately when validating older build inputs: changing
the archive location does not clean the former directory.

APT package upgrades on the running slot are a product update path, driven by
CeraUI's orchestrator with origin/hold/boot-stack restrictions; arbitrary manual
package installation is not equivalent to that qualified flow. RAUC stages a
whole OS in the inactive slot. Kernel APT staging is a separate inactive-slot
operation. See [Update Paths](../README.md#update-paths--unified-orchestrator-image-qualification-partial).
Making every live-slot APT operation test-only would change the update contract.

The populated-slot gate requires 536870912 available bytes and at least 20000
free inodes or 10% of total inodes, whichever is larger. It measures each clean
ext4 filesystem after population, excluding root-reserved blocks and ext4 extent
reserve. This protects against shipping an already full slot and leaves growth
and operational headroom. It is not a guarantee of peak dpkg unpack/backup space,
a runtime quota, or proof that subsequent package additions retain the reserve.
Compressed bundle size and a tree's `du` output cannot prove available space.

Persistent journals use `/data/log` via the `/var/log` bind, with a 256 MiB cap
and 1 GiB keep-free limit. Early journals use `/run` with a 32 MiB cap. Neither is
intended to consume the normal mounted root slot. Investigate failed binds before
ascribing root growth to journald. Dpkg state, installed package growth and APT
lists remain slot-local; binary-cache suppression alone cannot budget them.

## Hardware-free measurement

`tests/apt-root-reserve.test.sh` uses isolated APT configuration, a synthetic
package index and real `apt-cache gencaches`. It proves queries still work when
both binary caches are disabled, including an `apt-get -s install` simulation.
The absence of both cache files after the queries is the regression proof.
It also compares actual available bytes in populated
1 GiB ext4 fixtures before/after removal using `slot_reserve_assert_ext4`. No
network, host APT state, mounts, device or full image build is involved. The
small synthetic saving illustrates the space occupied by the removed files;
it is not independent proof of cache suppression or an estimate of production
package-index size. Query latency and peak RAM with a real Debian index remain
unmeasured.

For release evidence, run the existing populated-slot gate on each actual clean
slot image (or `lib/verify-disk.sh check-slot <slot.ext4> rootfs_a`, then B).
Record available bytes and inodes from its output. For an assembled image, use
`tests/preflash-verify.sh` against the actual image and target capacity. Repeat
measurements after representative installs and list refreshes, including their
peak allocation, before choosing a smaller profile or promising an install budget.
