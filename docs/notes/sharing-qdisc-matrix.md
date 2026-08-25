# qdisc / netfilter availability matrix — BOTH kernel tracks

Sibling of [`sharing-kernel-capability.md`](sharing-kernel-capability.md). That note
measured the **mandatory symbol closure** for uplink sharing and recorded the
`NET_CLS_FW` remediation. This note answers the narrower question the shaper and
the steering layer actually ask at runtime: **which queueing disciplines and
netfilter objects exist on which kernel track, and how do they ship — builtin,
module, or not at all?**

It exists because the honest answer differs per track, and because "cake is
present" is a claim nobody should make from memory. The plan's acceptance
criterion is explicitly that this matrix **names the truth including fallbacks**,
not that any particular row is green.

- **Date:** 2026-08-24 (UTC)
- **Tracks covered:** (i) the SHIPPED vendor 6.1 BSP, (ii) the opt-in
  mainline/edge 7.1 fragment
- **Raw transcript:** `test-results/uplink-sharing/todo12-qdisc-matrix.log`
  (gitignored)

---

## 1. Track (i) — the SHIPPED vendor 6.1 kernel

Measured by package inspection, using the same provenance chain
`sharing-kernel-capability.md` §1 established — nothing was resolved by hand or
by "latest":

| Input | Value | Source of record |
|---|---|---|
| apt base / suite | `https://apt.armbian.com` / `bookworm` | `lib/fetch-debs.sh` (`ARMBIAN_APT_URL`, `ARMBIAN_SUITE`) |
| component / arch | `main` / `arm64` | `manifests/families/rk3588.yaml` (`arch: arm64`) |
| package | `linux-image-vendor-rk35xx` | `manifests/families/rk3588.yaml` (`kernel_packages`) |
| exact version | `26.5.1` | `manifests/armbian-bsp-deb-versions.txt:1` |
| kernel release | `6.1.115-vendor-rk35xx` | package payload |

Downloaded SHA-256 `7b70fb2d1148021275a648fb0a4c0177236c3f54bef69a02a771d6ae7d9055ed`
— byte-for-byte the value committed in `manifests/bsp-baseline.json`, so the
artifact read below is provably the bytes the production build stages.

Every row cites the exact file **inside the extracted package**
(`/boot/config-6.1.115-vendor-rk35xx`, `…/modules.builtin`, `…/modules.dep`).

### 1a. Queueing disciplines the shaper needs (todo 10)

| Symbol | `.config` | Ships as | Row |
|---|---|---|---|
| `NET_SCHED` | `=y` (line 1581) | `vmlinux` | **builtin** — the `menuconfig` parent every row below sits inside |
| `NET_SCH_PRIO` | `=m` (line 1588) | `kernel/net/sched/sch_prio.ko` | **module** |
| `NET_SCH_HTB` | `=m` (line 1586) | `kernel/net/sched/sch_htb.ko` | **module** |
| `NET_SCH_FQ_CODEL` | `=m` (line 1606) | `kernel/net/sched/sch_fq_codel.ko` | **module** |
| `NET_SCH_CAKE` | `=m` (line 1607) | `kernel/net/sched/sch_cake.ko` | **module — PRESENT** |

**`sch_cake` is PRESENT on the shipped vendor kernel.** That is the measured
fact, and it is recorded here precisely because the plan permitted the opposite
answer: cake absent would have been ACCEPTABLE (todo 10's design falls back to
`htb rate <cap> ceil <cap>` + an `fq_codel` leaf at RUNTIME), and this note would
have said so instead. **The HTB fallback is not retired by this row.** It stays,
for three reasons that are all still true with cake present:

1. It is a RUNTIME fallback, not a build-time switch. The engine cannot assume a
   kernel it did not build — the same image can be flashed onto a board whose
   kernel was replaced, and a source-built variant resolves its own config.
2. `sch_cake` is a **module**, so it is unavailable until something loads it (see
   §3). A `tc qdisc add … cake` autoloads it; a failed autoload is exactly the
   case the fallback covers.
3. Nothing in the image forces cake, so the fallback is the only thing that keeps
   the shaper honest rather than silently unshaped.

### 1b. Classifier — the one that is NOT in the base package

| Symbol | `.config` | Ships as | Row |
|---|---|---|---|
| `NET_CLS` | `=y` (line 1620) | `vmlinux` | **builtin** (promptless; selected by any classifier) |
| `NET_CLS_FW` | `# … is not set` (line 1623) | `updates/ceralive/cls_fw.ko`, from `ceralive-cls-fw` | **module (OUT-OF-TREE)** |

`cls_fw.ko` is absent from the base package on four independent reads (no `.ko`,
no `modules.dep`, no `modules.builtin`, no `modules.alias` entry). The image
supplies it as a separately built, ABI-matched package —
`sharing-kernel-capability.md` §2c is the record of record for that work, and
**this note does not restate or re-derive it**.

### 1c. Netfilter objects the steering layer needs (todo 9)

| Symbol | `.config` | Ships as | Row |
|---|---|---|---|
| `NETFILTER` | `=y` (1122) | `vmlinux` | **builtin** |
| `NETFILTER_ADVANCED` | `=y` (1123) | — | **builtin** (gates `NF_CONNTRACK_MARK`) |
| `NETFILTER_NETLINK` | `=m` (1132) | `nfnetlink.ko` | **module** |
| `NF_CONNTRACK` | `=m` (1140) | `nf_conntrack.ko` | **module** |
| `NF_CONNTRACK_MARK` | `=y` (1143) | rides inside `nf_conntrack.ko` | **module** (bool under a `=m` parent) |
| `NF_CT_NETLINK` | `=m` (1166) | `nf_conntrack_netlink.ko` | **module** — what `conntrack -D --mark` needs |
| `NF_NAT` | `=m` (1169) | `nf_nat.ko` | **module** |
| `NF_TABLES` | `=m` (1178) | `nf_tables.ko` | **module** |
| `NF_TABLES_INET` | `=y` (1179) | rides inside `nf_tables.ko` | **module** (bool under a `=m` parent) |
| `NFT_NUMGEN` | `=m` (1181) | `nft_numgen.ko` | **module** |
| `NFT_CT` | `=m` (1182) | `nft_ct.ko` | **module** |
| `NFT_MASQ` | `=m` (1187) | `nft_masq.ko` | **module** |
| `NFT_NAT` | `=m` (1189) | `nft_nat.ko` | **module** |
| `IP_MULTIPLE_TABLES` | `=y` (1031) | `vmlinux` | **builtin** |

A scan of the whole `modules.builtin` for `nf_*` / `nft_*` / `sch_*` / `cls_*`
returns **zero** matches, so every `=y` row above that is not `NET_SCHED`,
`NET_CLS`, `NETFILTER*` or `IP_MULTIPLE_TABLES` is a bool compiled INTO its
parent's `.ko`, not into `vmlinux`.

---

## 2. Track (ii) — the mainline/edge 7.1 fragment

`manifests/kernel/rk3588-edge.fragment` is the **opt-in `--variant edge` track
only**. It is NOT the production path (root `AGENTS.md` D3/D9): the shipped image
installs the prebuilt vendor kernel, and **this commit changes no kernel on that
path.**

Before this commit the fragment declared exactly two symbols from the sharing
closure — `CONFIG_NF_TABLES=y` and `CONFIG_NF_TABLES_INET=y`, both added for the
LAN-ingest firewall. Everything else in §1a/§1b/§1c was **undeclared**, which on
this repo's own evidence is not the same as "off but harmless": a leaf whose
`menuconfig` parent is undeclared is discarded by `make olddefconfig` in total
silence, and four shipped capabilities have already been lost that way
(`RTW89`, `DMABUF_HEAPS`, `TYPEC_FUSB302`, `NF_TABLES`).

**Added additively by this commit** (fragment + `required-symbols.list`; no
existing declaration changed, `forbidden-symbols.list` untouched, no gate
weakened):

| Symbol | Declared | Why it needs its own line |
|---|---|---|
| `NETFILTER_ADVANCED=y` | parent | gates `NF_CONNTRACK_MARK`; already `=y` on the board's own `/proc/config.gz`, declared so the child cannot be dropped for an undeclared parent |
| `NF_CONNTRACK=y` | tristate parent | `menuconfig`-class parent of the whole conntrack family |
| `NF_CONNTRACK_MARK=y` | leaf bool | the ct mark the steering layer saves/restores |
| `NF_NAT=y` | tristate parent | `NFT_NAT`/`NFT_MASQ` both `depends on` it |
| `NF_CT_NETLINK=y` | tristate | `conntrack -D --mark` (hard-down flush) |
| `NFT_CT=y` | tristate | `ct mark` / `ct state` expressions |
| `NFT_NAT=y` | tristate | per-uplink NAT |
| `NFT_MASQ=y` | tristate | the client-zone-scoped masquerade |
| `NFT_NUMGEN=y` | tristate | weighted bucket selection |
| `IP_MULTIPLE_TABLES=y` | bool | the per-uplink `ip rule` band |
| `NET_SCHED=y` | `menuconfig` parent | every qdisc and classifier below sits inside `if NET_SCHED` |
| `NET_SCH_PRIO=y` | tristate | the root 2-band hierarchy |
| `NET_SCH_HTB=y` | tristate | the client-band cap when cake is unavailable |
| `NET_SCH_FQ_CODEL=y` | tristate | the leaf on both bands |
| `NET_SCH_CAKE=y` | tristate | the preferred client-band shaper |
| `NET_CLS_FW=y` | tristate | the `tc filter … fw classid` bridge |

**Deliberately NOT declared**, for the same reason `CONFIG_NFT_COUNTER` is not:
`NET_CLS`, `NF_DEFRAG_IPV4`/`NF_DEFRAG_IPV6`, `NF_NAT_MASQUERADE` and
`NETFILTER_NETLINK` are promptless symbols that a declared symbol above
`select`s. Declaring a `select`ed helper adds nothing the gate can check and
invites a stale line the day upstream re-parents it — the same select/leaf rule
the fragment already applies to `RTW89_CORE` and `NF_TABLES_IPV4`.

**Why `=y` and not `=m` on this track.** The vendor kernel ships these as
modules and that is fine for a userspace-driven consumer (§3). The fragment
declares `=y` for the same reason it already declares `CONFIG_NF_TABLES=y` at
line 417: on a track this repo *builds*, there is no reason to reintroduce a load
-ordering question it can simply not have, and `verify-kernel-config.sh` matches
values EXACTLY — a `=m` declaration would additionally be at the mercy of any
future `select` that forces `=y`. Every dependency of every row above is declared
`=y` in the same fragment, so kconfig can honour all of them.

**This is a DIFFERENCE between the tracks, not a claim that either is wrong.**
The production board runs modules; the edge board would run builtins. Both
satisfy the closure.

---

## 3. The consequence that survives on both tracks

Every present row on the vendor track except `NET_SCHED`, `NET_CLS`, `NETFILTER`,
`NETFILTER_ADVANCED` and `IP_MULTIPLE_TABLES` is a **module, and a module is
unavailable until something loads it.** Ordinary use autoloads them — `nft`
triggers `nf_tables` through `nfnetlink`, `tc qdisc add … cake` triggers
`sch_cake`, `tc filter … fw` triggers `cls_fw` — which is exactly the shape
`ceralive-share.service` has: it is started, reloaded and stopped by CeraUI at
RUNTIME, long after modular autoload is available. It is deliberately **not** a
`DefaultDependencies=no` early-boot oneshot, because that is the one shape this
module posture would not support (`sharing-kernel-capability.md` §3, second
consequence).

`ceralive-cls-fw` is the one exception on the vendor track: it ships a
`modules-load.d` entry so `cls_fw` is requested at boot rather than left to an
autoload the `fw` classifier would have to trigger first.

---

## 4. Scope boundary — what this note is NOT

- It does **not** re-derive, restate or supersede the `ceralive-cls-fw`
  out-of-tree module work. That is `sharing-kernel-capability.md` §2c.
- It makes **no runtime claim**. Every row is package/text inspection. Actual
  `modprobe`, actual `tc qdisc add … cake`, and actual `tc filter … fw classid`
  classification remain the labelled hardware gate in `docs/DEFERRED.md`.
- It changes **no kernel on the production path**. Decision D3 is untouched: the
  shipped image still installs the prebuilt `linux-image-vendor-rk35xx` 26.5.1,
  byte-unchanged.
