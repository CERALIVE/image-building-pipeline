# Shipped vendor-kernel capability matrix — sharing / steering / shaping primitives

Measurement of the kernel the production image **actually installs**, against the
symbol closure the uplink-sharing work depends on. This note is the recorded
evidence for that measurement and the single verdict it produces.

- **Date:** 2026-08-24 (UTC)
- **Subject:** `linux-image-vendor-rk35xx` **26.5.1** — kernel release
  `6.1.115-vendor-rk35xx`, Armbian vendor 6.1 BSP, `armbian/linux-rockchip`
  git revision `95e85f6cb496c75807c5b16f158853578e7e7d1b`
- **Method:** package inspection of the fetched `.deb` (the REQUIRED path — no
  board needed). Every row below cites the exact file **inside the extracted
  package** it was read from.
- **Scope:** READ-ONLY measurement. Nothing in the vendor kernel, the edge
  fragment, `versions.yaml` or any pin was modified by this work.
- **Raw transcript:** `test-results/uplink-sharing/todo18-matrix.log` (gitignored)

---

## 1. Provenance — this IS the shipped kernel

The package was fetched through the pipeline's own BSP transport shape
(`lib/fetch/bsp.sh` `_fetch_bsp_curl`), using the pipeline's own constants and
pins — nothing was resolved by hand or by "latest":

| Input | Value | Source of record |
|---|---|---|
| apt base | `https://apt.armbian.com` | `lib/fetch-debs.sh:104` (`ARMBIAN_APT_URL`) |
| suite | `bookworm` | `lib/fetch-debs.sh:105` (`ARMBIAN_SUITE`) |
| component / arch | `main` / `arm64` | `manifests/families/rk3588.yaml` (`arch: arm64`) |
| package | `linux-image-vendor-rk35xx` | `manifests/families/rk3588.yaml:25` (`kernel_packages`) |
| exact version | `26.5.1` | `manifests/armbian-bsp-deb-versions.txt:1` |

Resolved out of the archive's own `dists/bookworm/main/binary-arm64/Packages.gz`
record for that exact `package=version`:

```
Filename: pool/main/l/linux-6.1.115/linux-image-vendor-rk35xx_26.5.1_arm64__6.1.115-S95e8-D05ae-P09c0-Cc9fc-H94f2-HK01ba-Vc222-B4497-R448a.deb
Size:     37867716
SHA256:   7b70fb2d1148021275a648fb0a4c0177236c3f54bef69a02a771d6ae7d9055ed
```

The downloaded file's SHA-256 is byte-for-byte the value committed in
`manifests/bsp-baseline.json` (`"sha256": "7b70fb2d…9055ed"`), which is the
repo's own known-good content reference for this kernel package and the subject
of the BSP drift-guard. **So the artifact measured below is provably the same
bytes the production build stages** — not a same-version re-spin and not a
neighbouring version.

Evidence files extracted from it (`dpkg-deb -x`):

| Path inside the `.deb` | Size |
|---|---|
| `/boot/config-6.1.115-vendor-rk35xx` | 251,074 B (9,851 lines) |
| `/lib/modules/6.1.115-vendor-rk35xx/modules.builtin` | 32,289 B (783 lines) |
| `/lib/modules/6.1.115-vendor-rk35xx/modules.dep` | 164,524 B (2,297 lines) |
| `/lib/modules/6.1.115-vendor-rk35xx/modules.alias` | 663,502 B |

---

## 2. Per-symbol matrix

`builtin` = resolves inside `vmlinux`, usable with no `modprobe`.
`module` = ships as a separate `.ko`, or is compiled into a `.ko` (see §2a),
and is **not loaded until something loads it**.
`ABSENT` = not built at all — no `.ko`, no `modules.dep` entry, no
`modules.builtin` entry, no `modules.alias` entry.

### Mandatory closure

| # | Symbol | `.config` value | Ships as | Row | Cited from |
|---|---|---|---|---|---|
| 1 | `NF_TABLES` | `=m` | `kernel/net/netfilter/nf_tables.ko` | **module** | `/boot/config-6.1.115-vendor-rk35xx:1178`; `/lib/modules/6.1.115-vendor-rk35xx/modules.dep` |
| 2 | `NF_TABLES_INET` | `=y` | compiled **into** `nf_tables.ko` (see §2a) | **module** | `/boot/config-6.1.115-vendor-rk35xx:1179` |
| 3 | `NFT_CT` | `=m` | `kernel/net/netfilter/nft_ct.ko` | **module** | `/boot/config-6.1.115-vendor-rk35xx:1182`; `…/modules.dep` |
| 4 | `NF_CONNTRACK_MARK` | `=y` | compiled **into** `nf_conntrack.ko` (see §2a) | **module** | `/boot/config-6.1.115-vendor-rk35xx:1143` |
| 5 | `NFT_NAT` | `=m` | `kernel/net/netfilter/nft_nat.ko` | **module** | `/boot/config-6.1.115-vendor-rk35xx:1189`; `…/modules.dep` |
| 6 | `NFT_MASQ` | `=m` | `kernel/net/netfilter/nft_masq.ko` | **module** | `/boot/config-6.1.115-vendor-rk35xx:1187`; `…/modules.dep` |
| 7 | `NFT_NUMGEN` | `=m` | `kernel/net/netfilter/nft_numgen.ko` | **module** | `/boot/config-6.1.115-vendor-rk35xx:1181`; `…/modules.dep` |
| 8 | `NF_CT_NETLINK` | `=m` | `kernel/net/netfilter/nf_conntrack_netlink.ko` | **module** | `/boot/config-6.1.115-vendor-rk35xx:1166`; `…/modules.dep` |
| 9 | `IP_MULTIPLE_TABLES` | `=y` | `vmlinux` (under `CONFIG_INET=y`) | **builtin** | `/boot/config-6.1.115-vendor-rk35xx:1031` |
| 10 | `NET_SCH_PRIO` | `=m` | `kernel/net/sched/sch_prio.ko` | **module** | `/boot/config-6.1.115-vendor-rk35xx:1588`; `…/modules.dep` |
| 11 | `NET_SCH_FQ_CODEL` | `=m` | `kernel/net/sched/sch_fq_codel.ko` | **module** | `/boot/config-6.1.115-vendor-rk35xx:1606`; `…/modules.dep` |
| 12 | `NET_SCH_HTB` | `=m` | `kernel/net/sched/sch_htb.ko` | **module** | `/boot/config-6.1.115-vendor-rk35xx:1586`; `…/modules.dep` |
| 13 | `NET_CLS_FW` | `# … is not set` | **nothing** | **ABSENT** | `/boot/config-6.1.115-vendor-rk35xx:1623` |

### Optional

| # | Symbol | `.config` value | Ships as | Row | Cited from |
|---|---|---|---|---|---|
| 14 | `NET_SCH_CAKE` | `=m` | `kernel/net/sched/sch_cake.ko` | **module** | `/boot/config-6.1.115-vendor-rk35xx:1607`; `…/modules.dep` |

### 2a. Why rows 2 and 4 read `=y` and are still scored `module`

Both are **bools nested under a tristate parent that is `=m`**, so `=y` here does
not mean "in `vmlinux`" — it means "compiled into the parent's `.ko`":

- `NF_TABLES_INET=y` sits inside the `if NF_TABLES` block, and `NF_TABLES=m`
  (`/boot/config-6.1.115-vendor-rk35xx:1178`). Its code therefore rides inside
  `nf_tables.ko` and is available exactly when that module is loaded.
- `NF_CONNTRACK_MARK=y` sits under `NF_CONNTRACK`, and `NF_CONNTRACK=m`. Its code
  rides inside `nf_conntrack.ko`.

This is confirmed empirically, not inferred: a scan of the whole
`modules.builtin` for `nf_tables`/`nf_conntrack`/`nft_*`/`nf_nat`/`sch_*`/`cls_*`
returns **zero** matches — none of the netfilter or traffic-control objects in
this closure is built into `vmlinux`. `IP_MULTIPLE_TABLES` is the one genuine
`builtin` in the table because its parent (`CONFIG_INET`) is itself `=y`.

### 2b. `NET_CLS_FW` — exhaustive absence proof

Four independent reads inside the package payload, all negative:

| Check | Result |
|---|---|
| `/boot/config-6.1.115-vendor-rk35xx:1623` | `# CONFIG_NET_CLS_FW is not set` |
| `cls_fw.ko` on disk under `/lib/modules/6.1.115-vendor-rk35xx/` | not present |
| `grep -c cls_fw …/modules.dep` | `0` |
| `grep -c cls_fw …/modules.builtin` / `…/modules.alias` | `0` / `0` |
| `find` for any `*cls_fw*` / `*cls-fw*` path in the payload | no hits |

There is no way to obtain this classifier on the shipped kernel at runtime — it
is not an unloaded module, it was never compiled.

---

## 3. VERDICT

> **RED — mandatory `NET_CLS_FW` is ABSENT from the shipped vendor kernel
> (`linux-image-vendor-rk35xx` 26.5.1 / `6.1.115-vendor-rk35xx`):
> `/boot/config-6.1.115-vendor-rk35xx:1623` reads `# CONFIG_NET_CLS_FW is not set`,
> and no `cls_fw.ko` exists anywhere in the package payload.**

Twelve of the thirteen mandatory symbols are present and the optional
`NET_SCH_CAKE` is present; the verdict is RED on the single ABSENT row, per the
gate's own rule that **any** missing mandatory symbol is RED regardless of how
many others pass.

### Named consequence of the ABSENT symbol

`NET_CLS_FW` is the `tc` classifier that maps an skb's **firewall mark**
(`skb->mark`, as set by nftables `meta mark set` / `ct mark`) onto a qdisc class:

```sh
tc filter add dev <if> parent 1: protocol all handle <fwmark> fw classid 1:10
```

On this kernel that command cannot succeed — the `fw` classifier cannot be
loaded, so the canonical **"nftables marks the packet → `tc` steers it into an
HTB/PRIO class"** bridge is unavailable in its standard form. Anything designed
around `handle … fw classid …` will fail at runtime on a booting, otherwise
healthy image.

### Second consequence, applying to the twelve PRESENT rows

Every present row except `IP_MULTIPLE_TABLES` is a **module, not builtin**, so it
is unavailable until something loads it. Ordinary use autoloads them (`nft`
triggers `nf_tables` via `nfnetlink`; `tc qdisc add` triggers `sch_*`), so this
is normal for a userspace-driven consumer. It is **not** safe for an early-boot
`DefaultDependencies=no` oneshot that must be in force before modular autoload
can have happened — which is exactly why the edge-track fragment deliberately
declares `CONFIG_NF_TABLES=y` rather than `=m`
(`manifests/kernel/rk3588-edge.fragment:417`, with the reasoning at lines
387-422). The shipped **vendor** kernel measured here has it as `=m`. Any
sharing/steering unit that must be established before the media path opens needs
to state its module dependencies explicitly rather than rely on autoload timing.

---

## 4. Adjacent capability actually present (input to the owner question, not the verdict)

Recorded so the RED can be acted on with facts rather than re-measured. These are
**not** substitutes that change the verdict — the gate is RED and stays RED — they
are the material the owner decision will be taken against.

Other `tc` classifiers/actions in the shipped kernel (all `=m`, from
`/boot/config-6.1.115-vendor-rk35xx`): `NET_CLS_BASIC`, `NET_CLS_ROUTE4`,
`NET_CLS_U32`, `NET_CLS_FLOW`, `NET_CLS_CGROUP`, `NET_CLS_BPF`,
`NET_CLS_FLOWER`, `NET_CLS_MATCHALL`; `NET_EMATCH=y` with `NET_EMATCH_META`,
`NET_EMATCH_U32`, `NET_EMATCH_CMP`, `NET_EMATCH_NBYTE`, `NET_EMATCH_IPSET`,
`NET_EMATCH_IPT`; `NET_CLS_ACT=y` with `NET_ACT_POLICE`, `NET_ACT_GACT`,
`NET_ACT_MIRRED`, `NET_ACT_SKBEDIT`, `NET_ACT_BPF`, `NET_ACT_PEDIT`,
`NET_ACT_IPT`, `NET_ACT_NAT`, `NET_ACT_CSUM`, `NET_ACT_SIMP`.

Explicitly **also** not set, so they cannot be assumed either: `NET_ACT_CT`,
`NET_ACT_CONNMARK`, `NET_ACT_CTINFO`, `NET_ACT_SKBMOD`, `NET_SCH_ETS`,
`NET_SCH_FQ_PIE`, `NET_SCH_SKBPRIO`.

Other qdiscs present beyond the closure (all `=m`): `HFSC`, `TBF`, `RED`, `SFQ`,
`SFB`, `GRED`, `CHOKE`, `QFQ`, `DRR`, `MQPRIO`, `MULTIQ`, `CODEL`, `FQ`, `HHF`,
`PIE`, `NETEM`, `PLUG`, `TEQL`, `INGRESS`; `NET_SCH_FIFO=y`.

---

## 5. Hardware corroboration — NOT PERFORMED

The `.deb` inspection above is the REQUIRED path and is complete. The optional
on-device `/boot/config-$(uname -r)` corroboration was **attempted and could not
be obtained**:

| Probe | Result |
|---|---|
| `ping ceralive.local` / `ceralive2.local` | both answer |
| `ping 192.168.78.131` (the bench Rock 5B+ of prior notes) | unreachable |
| `ssh ceralive.local` (`ceralive`, `root`) | `Connection refused` — sshd not listening |
| `ssh ceralive2.local` (`ceralive`, `root`) | `Permission denied (publickey,password)` |

That is the expected posture of a production image (`ssh.service` ships not
enabled and the `ceralive` account is password-locked), not a fault. **No board
reading is claimed here**, and none is needed: the measured artifact's SHA-256
matches the committed `bsp-baseline.json`, so the package inspection already
speaks for the shipped kernel.

---

## 6. Scope boundary — what this note is NOT about

The measurement subject is the **shipped vendor 6.1 BSP** kernel package, on the
production path. It is deliberately not a statement about either
kernel-from-source variant:

- `manifests/kernel/rk3588-edge.fragment` is the **mainline/edge 7.1** track and
  is cited above only as prior evidence and contrast. It was not read as the
  subject and was not modified.
- `--variant vendor-patched` rebuilds this same 6.1.115 BSP from source using
  Armbian's published `linux-rk35xx-vendor.config`; its config content is
  expected to track the measured one, but that was not measured here and must
  not be inferred from this note.

Decision D3 is untouched: the shipped image still installs the prebuilt
`linux-image-vendor-rk35xx`.
