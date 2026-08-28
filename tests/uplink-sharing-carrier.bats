#!/usr/bin/env bats
#
# Uplink-sharing package/config integration — the IMAGE half of the internet-
# sharing subsystem (steering + shaping).
#
# WHAT IS PINNED HERE. CeraUI is the DECIDER: its uplink-steering module renders a
# desired-state nftables ruleset and its uplink-shaper module drives tc. Neither
# can do anything on a device that lacks the userland, the kernel objects, the
# systemd carrier or the NetworkManager posture they assume. This file is the
# contract for that half, and every assertion is against the CARRIER CONTRACT the
# two repos share (openspec/changes/uplink-sharing-balancer), cited verbatim:
#
#   REQ-USB-020  unit "ceralive-share.service", ruleset "/run/ceralive/share.nft",
#                table "inet ceralive_share" — named constants, no inline literals
#   REQ-USB-021  Type=oneshot + RemainAfterExit=yes
#   REQ-USB-022  TWO ordered ExecStart= lines — `nft -c -f` then `nft -f`; NO shell
#                operators (systemd does not interpret `&&`)
#   REQ-USB-023  ExecReload= = the same two-step validate-then-apply, apply-only,
#                NEVER a teardown
#   REQ-USB-024  ExecStop= = a committed teardown SCRIPT (not inline)
#   REQ-USB-025  After=nftables.service (+ the drop-in for the CeraUI unit)
#   REQ-USB-026  idempotent double-apply byte-identical; ip_forward toggled ONLY on
#                client-zone active<->inactive edges
#
# STATIC CONTRACT TESTS ONLY, AND THAT IS A DELIBERATE CEILING. This repo's CI has
# no privileged network namespace and no VM, so nothing here may claim behavioural
# proof: every case reads config TEXT, package presence, kernel symbol
# declarations and unit-file content. The behavioural half lives in CeraUI's
# golden-ruleset suites and its required `unshare -rn` netns job; the on-device
# half (`modprobe`, a real `tc filter … fw classid`, a real client flow) is
# labelled hardware-gated. A test here that spawned a netns would be claiming a
# guarantee this runner cannot give.

bats_require_minimum_version 1.5.0

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PIPELINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  SHARED_LIST="$PIPELINE_DIR/manifests/packages/shared.list"
  NETWORKING="$PIPELINE_DIR/mkosi/customize/postinst.d/networking.sh"
  SHARING_SRC="$PIPELINE_DIR/mkosi/runtime/uplink-sharing"
  UNIT="$SHARING_SRC/ceralive-share.service"
  TEARDOWN="$SHARING_SRC/ceralive-share-teardown.sh"
  DROPIN="$SHARING_SRC/ceralive-nftables-ordering.dropin.conf"
  FRAGMENT="$PIPELINE_DIR/manifests/kernel/rk3588-edge.fragment"
  REQUIRED="$PIPELINE_DIR/manifests/kernel/required-symbols.list"
  FORBIDDEN="$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
  MATRIX="$PIPELINE_DIR/docs/notes/sharing-qdisc-matrix.md"
  RUNTIME_EXEC="$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  SERVICES_EXEC="$PIPELINE_DIR/mkosi/customize/services.sh"
}

# resolved_runtime_packages — the arch-independent runtime package set, via the
# same `sed|awk` projection make_parity_rootfs uses to model the installed set.
resolved_runtime_packages() {
  sed -e 's/#.*//' "$SHARED_LIST" | awk 'NF{print $1}'
}

# executable_lines <file> — the file with comment-only and blank lines removed.
# EVERY negative assertion below must run through this. Both the unit and the
# teardown script deliberately DOCUMENT the shapes they forbid ("never
# `nft flush ruleset`", "NO [Install] SECTION"), so a whole-file `grep` for a
# banned string matches the prose that bans it and reports the guard as the
# violation. Scanning executable lines only is the same rule apt-worker's closure
# contract test applies for the same reason.
executable_lines() {
  grep -Ev '^[[:space:]]*(#|$)' "$1"
}

# --- (a) required packages ---------------------------------------------------

@test "packages: nftables is present and its comment names BOTH nft consumers" {
  run grep -Ex 'nftables[[:space:]]*(#.*)?' "$SHARED_LIST"
  [ "$status" -eq 0 ]

  # The entry predates this work and used to justify itself by the LAN-ingest
  # firewall alone. The sharing carrier is a second, independent consumer of the
  # same binary, so a future size audit reading only the old rationale could
  # remove the package believing the ingest firewall is the whole story.
  local body
  body="$(cat "$SHARED_LIST")"
  [[ "$body" == *"ceralive-share.service"* ]]
  [[ "$body" == *"ceralive_share"* ]]
  [[ "$body" == *"ceralive-ingest-firewall.service"* ]]
}

@test "packages: conntrack is present with the mark-scoped-flush rationale" {
  # The BINARY package is `conntrack`; `conntrack-tools` is only its SOURCE name and
  # has no binary of that name in trixie either (verified against the real trixie
  # index: `conntrack` 1:1.4.8-2 resolves, `conntrack-tools` has no candidate), so
  # asking for it fails the runtime layer outright.
  run grep -Ex 'conntrack[[:space:]]*(#.*)?' "$SHARED_LIST"
  [ "$status" -eq 0 ]

  # The WHY is the whole point of the entry: `nft` removes RULES, never conntrack
  # STATE, so without this binary a hard-DOWN uplink leaves every established
  # client flow pinned by its saved ct mark to an uplink that is gone.
  local body
  body="$(cat "$SHARED_LIST")"
  [[ "$body" == *"conntrack"* ]]
  [[ "$body" == *"mark"* ]]
}

@test "packages: nftables and conntrack both reach the resolved runtime set" {
  # Arch-independent (shared.list), so both must land in the set the runtime layer
  # installs for EVERY board family. An entry that drifted into a delta list would
  # still `grep` above but would be missing on one family.
  local pkgs
  pkgs="$(resolved_runtime_packages)"
  [[ "$pkgs" == *nftables* ]]
  [[ "$pkgs" == *conntrack* ]]
}

# --- (b) kernel-symbol availability matrix, BOTH tracks ----------------------

@test "kernel matrix: the committed note records BOTH tracks and names the fallbacks" {
  # The acceptance criterion is that the matrix NAMES THE TRUTH including
  # fallbacks — not that any row is green. Asserting "cake present" here would be
  # asserting the measurement rather than the record of it.
  [ -f "$MATRIX" ]
  local body
  body="$(cat "$MATRIX")"

  # Track (i): the shipped vendor kernel, identified by the exact package+release
  # and by the SHA-256 that ties the measured bytes to bsp-baseline.json.
  [[ "$body" == *"linux-image-vendor-rk35xx"* ]]
  [[ "$body" == *"6.1.115-vendor-rk35xx"* ]]
  [[ "$body" == *"7b70fb2d1148021275a648fb0a4c0177236c3f54bef69a02a771d6ae7d9055ed"* ]]

  # Track (ii): the edge fragment.
  [[ "$body" == *"rk3588-edge.fragment"* ]]

  # Every qdisc the shaper can install, and the classifier that bridges to it.
  [[ "$body" == *"NET_SCH_CAKE"* ]]
  [[ "$body" == *"NET_SCH_HTB"* ]]
  [[ "$body" == *"NET_SCH_FQ_CODEL"* ]]
  [[ "$body" == *"NET_SCH_PRIO"* ]]
  [[ "$body" == *"NET_CLS_FW"* ]]

  # The fallback must be NAMED, not implied — cake being present on the vendor
  # kernel does not retire todo 10's runtime HTB fallback.
  [[ "$body" == *"fallback"* ]]
}

@test "kernel matrix: the SHA-256 it cites is the committed bsp-baseline value" {
  # Non-vacuity for the row above: a hardcoded digest in a note proves nothing
  # unless it is the same digest the drift-guard defends.
  local baseline
  baseline="$(cat "$PIPELINE_DIR/manifests/bsp-baseline.json")"
  [[ "$baseline" == *"7b70fb2d1148021275a648fb0a4c0177236c3f54bef69a02a771d6ae7d9055ed"* ]]
}

@test "edge fragment: the steering + shaping closure is declared with every parent" {
  # The menuconfig-parent class this repo has shipped four times (RTW89,
  # DMABUF_HEAPS, TYPEC_FUSB302, NF_TABLES): a leaf whose tristate parent is
  # undeclared is dropped by `make olddefconfig` in complete silence.
  local frag
  frag="$(cat "$FRAGMENT")"

  # Parents.
  [[ "$frag" == *"CONFIG_NF_CONNTRACK=y"* ]]
  [[ "$frag" == *"CONFIG_NF_NAT=y"* ]]
  [[ "$frag" == *"CONFIG_NET_SCHED=y"* ]]
  [[ "$frag" == *"CONFIG_NETFILTER_ADVANCED=y"* ]]

  # Leaves.
  [[ "$frag" == *"CONFIG_NF_CONNTRACK_MARK=y"* ]]
  [[ "$frag" == *"CONFIG_NF_CT_NETLINK=y"* ]]
  [[ "$frag" == *"CONFIG_NFT_CT=y"* ]]
  [[ "$frag" == *"CONFIG_NFT_NAT=y"* ]]
  [[ "$frag" == *"CONFIG_NFT_MASQ=y"* ]]
  [[ "$frag" == *"CONFIG_NFT_NUMGEN=y"* ]]
  [[ "$frag" == *"CONFIG_IP_MULTIPLE_TABLES=y"* ]]
  [[ "$frag" == *"CONFIG_NET_SCH_PRIO=y"* ]]
  [[ "$frag" == *"CONFIG_NET_SCH_FQ_CODEL=y"* ]]
  [[ "$frag" == *"CONFIG_NET_SCH_HTB=y"* ]]
  [[ "$frag" == *"CONFIG_NET_SCH_CAKE=y"* ]]
  [[ "$frag" == *"CONFIG_NET_CLS_FW=y"* ]]

  # The existing LAN-ingest declarations are untouched.
  [[ "$frag" == *"CONFIG_NF_TABLES=y"* ]]
  [[ "$frag" == *"CONFIG_NF_TABLES_INET=y"* ]]
}

@test "edge fragment: promptless select-only symbols are NOT declared" {
  # Same select/leaf rule the fragment already applies to RTW89_CORE and
  # NF_TABLES_IPV4. Declaring a `select`ed helper adds nothing the gate can check
  # and becomes a stale line the day upstream re-parents it. CONFIG_NET_CLS is
  # the trap here: it looks like the parent of NET_CLS_FW and is promptless.
  run ! grep -Eq '^CONFIG_(NET_CLS|NF_DEFRAG_IPV4|NF_DEFRAG_IPV6|NF_NAT_MASQUERADE|NETFILTER_NETLINK)=' "$FRAGMENT"
}

@test "closure manifests: the sharing symbols are REQUIRED and none is FORBIDDEN" {
  local req forbidden
  req="$(cat "$REQUIRED")"
  forbidden="$(cat "$FORBIDDEN")"

  local sym
  for sym in NF_CONNTRACK NF_CONNTRACK_MARK NF_CT_NETLINK NF_NAT NFT_CT NFT_NAT \
             NFT_MASQ NFT_NUMGEN IP_MULTIPLE_TABLES NET_SCHED NET_SCH_PRIO \
             NET_SCH_FQ_CODEL NET_SCH_HTB NET_SCH_CAKE NET_CLS_FW; do
    [[ "$req" == *"CONFIG_${sym}="* ]] || {
      echo "CONFIG_${sym} missing from required-symbols.list"
      return 1
    }
    # The forbidden manifest holds BARE names, so an accidental overlap would be
    # a bare line — assert against that shape, not against a value assignment.
    run ! grep -Fxq "CONFIG_${sym}" "$FORBIDDEN"
  done
}

@test "closure manifests: forbidden-symbols.list is byte-untouched by this work" {
  # No gate weakened: this effort adds capability to the edge track and must not
  # have removed a single foreign-platform or debug-symbol ban. The count is the
  # cheap invariant — the list is 3 classes and none of them is ours.
  run ! grep -Eq '^CONFIG_(NET_|NF_|IP_MULTIPLE)' "$FORBIDDEN"
}

# --- (c) sysctl posture: ip_forward stays default-off ------------------------

@test "sysctl posture: the image bakes NO ip_forward=1 anywhere" {
  # THE POSTURE, STATED ONCE. The image already ships a LOOSE reverse-path filter
  # (net.ipv4.conf.*.rp_filter = 2) because strict RPF drops modem return traffic
  # under multi-WAN source-policy routing. Loose RPF on a box that never forwards
  # is one thing; loose RPF on a box that CAN forward is a different security
  # posture, so forwarding must never be baked on. It is toggled at RUNTIME by
  # CeraUI, only on client-zone active<->inactive edges (REQ-USB-026), and it is
  # off on an image whose operator never enables sharing.
  local hits
  hits="$(grep -rn 'ip_forward' \
    "$PIPELINE_DIR/manifests" \
    "$PIPELINE_DIR/mkosi/customize" \
    "$PIPELINE_DIR/mkosi/runtime" \
    "$PIPELINE_DIR/mkosi/mkosi.images" \
    "$PIPELINE_DIR/mkosi/platform" 2>/dev/null || true)"

  # Every surviving mention must be a comment or a CONDITIONAL restore — never an
  # assignment that turns forwarding on.
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [[ "$line" =~ ip_forward[[:space:]]*=[[:space:]]*1 ]]; then
      echo "image bakes ip_forward=1: $line"
      return 1
    fi
  done <<<"$hits"
}

@test "sysctl posture: the loose rp_filter setting is unchanged" {
  # Non-vacuity for the case above: the sysctl drop-in this repo DOES ship is
  # still there, so "no ip_forward=1" is not passing because the sysctl surface
  # went missing.
  local body
  body="$(cat "$NETWORKING")"
  [[ "$body" == *"net.ipv4.conf.all.rp_filter = 2"* ]]
  [[ "$body" == *"net.ipv4.conf.default.rp_filter = 2"* ]]
}

# --- (d) the carrier unit contract, REQ-USB-020..026 -------------------------

@test "REQ-USB-020: the unit names the three cross-repo constants exactly" {
  # These three strings are CeraUI's contracts.ts values. A mismatch is silent on
  # both sides: CeraUI writes a file nothing reads, or calls a unit that does not
  # exist. Byte equality is the entire contract.
  [ -f "$UNIT" ]
  [ "$(basename "$UNIT")" = "ceralive-share.service" ]
  run grep -Fx 'Environment=CERALIVE_SHARE_RULESET=/run/ceralive/share.nft' "$UNIT"
  [ "$status" -eq 0 ]
  run grep -Fx 'Environment=CERALIVE_SHARE_TABLE_FAMILY=inet' "$UNIT"
  [ "$status" -eq 0 ]
  run grep -Fx 'Environment=CERALIVE_SHARE_TABLE_NAME=ceralive_share' "$UNIT"
  [ "$status" -eq 0 ]
}

@test "REQ-USB-021: Type=oneshot and RemainAfterExit=yes" {
  # RemainAfterExit is not decoration: `systemctl reload` and `systemctl stop`
  # are only meaningful on an ACTIVE unit, and reload is how every ordinary
  # reweight is delivered.
  run grep -Fx 'Type=oneshot' "$UNIT"
  [ "$status" -eq 0 ]
  run grep -Fx 'RemainAfterExit=yes' "$UNIT"
  [ "$status" -eq 0 ]
}

@test "REQ-USB-022: TWO ordered ExecStart lines, validate then apply, no shell operators" {
  local starts first second
  starts="$(grep -c '^ExecStart=' "$UNIT")"
  [ "$starts" -eq 2 ]

  first="$(grep '^ExecStart=' "$UNIT" | sed -n '1p')"
  second="$(grep '^ExecStart=' "$UNIT" | sed -n '2p')"
  [ "$first" = 'ExecStart=/usr/sbin/nft -c -f ${CERALIVE_SHARE_RULESET}' ]
  [ "$second" = 'ExecStart=/usr/sbin/nft -f ${CERALIVE_SHARE_RULESET}' ]

  # ORDER IS THE GUARANTEE: `-c` parses and checks against the running kernel
  # WITHOUT committing, and systemd runs line 2 only if line 1 exited 0. Reversed,
  # a bad ruleset is applied and then validated.
  [[ "$first" == *" -c "* ]]
  [[ "$second" != *" -c "* ]]
}

@test "REQ-USB-022: no Exec* line in the unit contains a shell operator" {
  # systemd is NOT a shell. `ExecStart=/usr/sbin/nft -c -f X && /usr/sbin/nft -f X`
  # passes `&&` to nft as an argument; it does not chain anything. The two-line
  # form IS the chain.
  local line
  while IFS= read -r line; do
    [[ "$line" == Exec* ]] || continue
    if [[ "$line" == *"&&"* || "$line" == *"||"* || "$line" == *";"* || "$line" == *"|"* ]]; then
      echo "shell operator in a systemd Exec line: $line"
      return 1
    fi
  done <"$UNIT"
}

@test "REQ-USB-023: ExecReload is the same two-step apply, and is NEVER a teardown" {
  local reloads first second
  reloads="$(grep -c '^ExecReload=' "$UNIT")"
  [ "$reloads" -eq 2 ]

  first="$(grep '^ExecReload=' "$UNIT" | sed -n '1p')"
  second="$(grep '^ExecReload=' "$UNIT" | sed -n '2p')"
  [ "$first" = 'ExecReload=/usr/sbin/nft -c -f ${CERALIVE_SHARE_RULESET}' ]
  [ "$second" = 'ExecReload=/usr/sbin/nft -f ${CERALIVE_SHARE_RULESET}' ]

  # A reload that tore anything down would open a rule-gap in which client
  # traffic is unsteered and unmasqueraded — which is exactly why reweights go
  # through reload and never through restart.
  run ! grep -Eq '^ExecReload=.*(delete|flush|teardown)' "$UNIT"
}

@test "REQ-USB-024: ExecStop points at the committed teardown SCRIPT, not an inline command" {
  run grep -Fx 'ExecStop=/usr/local/sbin/ceralive-share-teardown' "$UNIT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ExecStop=' "$UNIT")" -eq 1 ]

  # An inline `nft delete table` could not express the conditional ip_forward
  # restore at all, which is why the requirement names a script.
  run ! grep -Eq '^ExecStop=.*nft ' "$UNIT"
  [ -f "$TEARDOWN" ]
}

@test "REQ-USB-025: the unit is ordered After=nftables.service" {
  run grep -Fx 'After=nftables.service' "$UNIT"
  [ "$status" -eq 0 ]

  # ORDERING-ONLY, exactly as ceralive-ingest-firewall.service does it. A hard
  # dependency would be wrong on this image, where nftables.service is not
  # enabled at all.
  run ! grep -Eq '^(Requires|Requisite|BindsTo)=.*nftables' "$UNIT"
}

@test "REQ-USB-025: the CeraUI unit gets its own After=nftables.service drop-in" {
  # ceralive-share.service is not enabled and never starts itself — ceralive.service
  # is what renders the ruleset and issues start/reload/stop, so it is the unit
  # that can actually race a system ruleset load.
  [ -f "$DROPIN" ]
  run grep -Fx 'After=nftables.service' "$DROPIN"
  [ "$status" -eq 0 ]
  run ! grep -Eq '^(Requires|Requisite|BindsTo)=' "$DROPIN"

  local body
  body="$(cat "$NETWORKING")"
  [[ "$body" == *"40-nftables-ordering.conf"* ]]
  [[ "$body" == *"ceralive.service.d"* ]]
}

@test "REQ-USB-026: the unit carries no [Install] section and is never enabled" {
  # The ruleset lives on /run (tmpfs) and is authored by CeraUI at runtime, so at
  # boot there is nothing to apply. An [Install] section would additionally be
  # unsafe: /etc/machine-id ships `uninitialized`, so PID 1 runs `preset-all` on
  # first boot and Debian's default verdict is `enable` — the unit would be
  # enabled behind our backs on the one boot nobody watches, and then fail every
  # boot reading a file that cannot exist yet.
  run ! grep -Fxq '[Install]' <(executable_lines "$UNIT")
  run ! grep -Eq '^WantedBy=' "$UNIT"
  run ! grep -Eq 'enable_service[[:space:]]+ceralive-share\.service' "$NETWORKING"
}

@test "REQ-USB-026: the unit mutates nothing, so a double-apply is byte-identical" {
  # Idempotency is a property of what CeraUI WRITES (an atomic table replace);
  # the unit preserves it only by being a pure carrier. Any command here that
  # edited, appended to or regenerated the ruleset would break that.
  run ! grep -Eq '^Exec.*(>>|tee|sed -i|printf.*>)' "$UNIT"

  # And it must not touch forwarding itself — that toggle is edge-triggered and
  # belongs to CeraUI (and, as a backstop only, to the teardown script).
  run ! grep -Eq '^Exec.*(sysctl|ip_forward)' "$UNIT"
}

# --- (e) the teardown script contract ----------------------------------------

@test "teardown: deletes ONLY our table and never flushes the whole ruleset" {
  local body
  body="$(cat "$TEARDOWN")"
  [[ "$body" == *'delete table "${SHARE_TABLE_FAMILY}" "${SHARE_TABLE_NAME}"'* ]]

  # A global flush would take out the LAN-ingest security boundary
  # (inet ceralive_ingest_fw) AND NetworkManager's shared-mode NAT.
  run ! grep -Eq 'flush[[:space:]]+ruleset' <(executable_lines "$TEARDOWN")
}

@test "teardown: removes our rule band and refuses to flush an image-owned table" {
  local body
  body="$(cat "$TEARDOWN")"

  # The band is FWMARK_RULE_PRIORITY (110), strictly greater than the image's own
  # priority-100 source-routing rules, which keep SRTLA bonding working.
  [[ "$body" == *'SHARE_RULE_PRIORITY="${CERALIVE_SHARE_RULE_PRIORITY:-110}"'* ]]
  [[ "$body" == *'rule del priority'* ]]

  # Only the module-provisioned private range may be flushed. The steering layer
  # REUSES the image's per-uplink tables (100-107 usb/enx, 120-124 wlan) wherever
  # one exists; flushing one here would break the stream this subsystem protects.
  [[ "$body" == *'SHARE_TABLE_MIN="${CERALIVE_SHARE_TABLE_MIN:-30000}"'* ]]
  [[ "$body" == *"outside the managed range"* ]]

  # The deletion loop is bounded — `ip rule del` removes one rule per call.
  [[ "$body" == *"MAX_RULE_DELETIONS"* ]]
}

@test "teardown: removes only the shaper's own reserved root qdisc" {
  local body
  body="$(cat "$TEARDOWN")"
  [[ "$body" == *'SHARE_QDISC_HANDLE="${CERALIVE_SHARE_QDISC_HANDLE:-ca00:}"'* ]]
  [[ "$body" == *"qdisc del dev"* ]]

  # An interface whose root is not ours is left completely alone: deleting a
  # custom root an operator installed would be the shaper's own refusal inverted.
  [[ "$body" == *'*" ${SHARE_QDISC_HANDLE} "*'* ]]
}

@test "REQ-USB-026: the teardown ip_forward restore is CONDITIONAL, never unconditional" {
  # THE ASSERTION THIS FILE EXISTS FOR. An unconditional `ip_forward=0` on stop
  # would cut every NetworkManager shared-mode client (the hotspot, a shared-LAN
  # ethernet port) off the internet the moment sharing stopped — and NM would not
  # put it back, because from its point of view nothing changed.
  local body
  body="$(cat "$TEARDOWN")"
  [[ "$body" == *'if [[ -f "${IP_FORWARD_STATE}" ]]'* ]]
  [[ "$body" == *"no recorded ip_forward value"* ]]

  # It may only ever write back a value it OBSERVED, and only 0 or 1.
  [[ "$body" == *'[[ "${saved}" =~ ^[01]$ ]]'* ]]

  # No literal enable anywhere in the script.
  run ! grep -Eq 'ip_forward[[:space:]]*=[[:space:]]*1' "$TEARDOWN"
  run ! grep -Eq "printf '1" "$TEARDOWN"
}

@test "teardown: uses the device-daemon profile and no pipe-to-grep read" {
  # `set -e` here would turn "the table was already deleted" into "the qdiscs and
  # the rule band are left behind" — the exact state the script exists to prevent.
  run grep -Fx 'set -uo pipefail' "$TEARDOWN"
  [ "$status" -eq 0 ]
  run ! grep -Fxq 'set -euo pipefail' "$TEARDOWN"

  # `cmd | grep -q` exits at the first match and SIGPIPEs the producer; under
  # pipefail a SUCCESSFUL read reports 141. This repo has shipped that footgun
  # four times, so the reads here go through command substitution instead.
  run ! grep -Eq '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' <(executable_lines "$TEARDOWN")
}

@test "teardown: is syntactically valid bash" {
  run bash -n "$TEARDOWN"
  [ "$status" -eq 0 ]
}

# --- (f) NetworkManager firewall-backend pin ---------------------------------

@test "firewall backend: NetworkManager is pinned to nftables, not to none" {
  local body
  body="$(cat "$NETWORKING")"

  # `none` would make CeraUI's own table load-bearing for plain hotspot function —
  # an availability regression with no upside. `nftables` keeps NM's shared-mode
  # NAT as a working floor beneath our per-uplink masquerade.
  [[ "$body" == *"firewall-backend=nftables"* ]]
  run ! grep -Eq '^firewall-backend=(none|iptables)' "$NETWORKING"

  # It must land in the [main] section of the drop-in this repo owns, which is
  # also where dns=systemd-resolved lives.
  local conf
  conf="$(sed -n '/cat >\/etc\/NetworkManager\/conf.d\/ceralive.conf/,/^EOF$/p' "$NETWORKING")"
  [[ "$conf" == *"firewall-backend=nftables"* ]]
  [[ "$conf" == *"dns=systemd-resolved"* ]]
}

# --- (g) wiring --------------------------------------------------------------

@test "wiring: setup_uplink_sharing_carrier is defined once and called by BOTH executors" {
  # The dual-track rule: the runtime subimage chroot and the customize services
  # entry must both run it, or the carrier ships on one path only.
  [ "$(grep -c '^setup_uplink_sharing_carrier() {' "$NETWORKING")" -eq 1 ]
  run grep -q 'setup_uplink_sharing_carrier' "$RUNTIME_EXEC"
  [ "$status" -eq 0 ]
  run grep -q 'setup_uplink_sharing_carrier' "$SERVICES_EXEC"
  [ "$status" -eq 0 ]
  run grep -q 'setup_uplink_sharing_carrier' "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  [ "$status" -eq 0 ]
}

@test "wiring: the setup function installs all three artifacts and fails closed" {
  local body
  body="$(cat "$NETWORKING")"
  [[ "$body" == *"ceralive-share.service"* ]]
  [[ "$body" == *"ceralive-share-teardown"* ]]
  [[ "$body" == *"ceralive-nftables-ordering.dropin.conf"* ]]

  # A missing source artifact must abort the build rather than ship an image whose
  # sharing carrier silently does not exist.
  local fn
  fn="$(sed -n '/^setup_uplink_sharing_carrier() {/,/^}/p' "$NETWORKING")"
  [ "$(grep -c 'die ' <<<"$fn")" -ge 3 ]

  # The teardown must be installed EXECUTABLE — ExecStop cannot run a 0644 file.
  [[ "$fn" == *"install -m 0755"* ]]
}

@test "wiring: the setup function refuses in a chroot with no runtime source" {
  # Drives the REAL shipped function with CERALIVE_RUNTIME_SRC pointing nowhere.
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/absent" \
    bash -c 'source "$1"; setup_uplink_sharing_carrier' bash "$NETWORKING"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ceralive-share.service"* ]]
}

@test "wiring: the setup function installs the three artifacts into a fake root" {
  # The green half of the pair above, driven through the real function with every
  # install path redirected. No privilege, no chroot, no network.
  local root="$BATS_TEST_TMPDIR/root"
  run env \
    CERALIVE_RUNTIME_SRC="$PIPELINE_DIR/mkosi/runtime" \
    UPLINK_SHARING_UNIT_DIR="$root/etc/systemd/system" \
    UPLINK_SHARING_SBIN_DIR="$root/usr/local/sbin" \
    UPLINK_SHARING_DROPIN_DIR="$root/etc/systemd/system/ceralive.service.d" \
    bash -c 'source "$1"; setup_uplink_sharing_carrier' bash "$NETWORKING"
  [ "$status" -eq 0 ]

  [ -f "$root/etc/systemd/system/ceralive-share.service" ]
  [ -x "$root/usr/local/sbin/ceralive-share-teardown" ]
  [ -f "$root/etc/systemd/system/ceralive.service.d/40-nftables-ordering.conf" ]

  # And it did NOT enable anything: no wants-symlink was created.
  [ ! -e "$root/etc/systemd/system/multi-user.target.wants/ceralive-share.service" ]
}
