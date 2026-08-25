#!/bin/bash
#
# ceralive-share-teardown — the ExecStop half of ceralive-share.service.
#
# REQ-USB-024: `ExecStop=` is a committed teardown SCRIPT, not an inline command,
# doing a scoped delete of the `ceralive_share` table + rule-band removal +
# qdisc/`ip_forward` restore. This file IS that script.
#
# REQ-USB-020: unit name "ceralive-share.service", ruleset path
# "/run/ceralive/share.nft", table "inet ceralive_share" — named constants, no
# inline literals in the unit or its scripts. Every value this script acts on is
# a named constant below, overridable from the environment (the unit exports the
# three cross-repo ones; the rest are test seams).
#
# REQ-USB-026: idempotent double-apply must be byte-identical, and `ip_forward` is
# toggled ONLY on client-zone active<->inactive edges. That second half is why
# the ip_forward step here is CONDITIONAL and can write nothing at all — see
# "STEP 4" below, which is the most important comment in this file.
#
# THIS IS A BACKSTOP, NOT THE PRIMARY PATH. In normal operation CeraUI's
# uplink-steering module tears its own state down in a specific order (transition
# ruleset -> mark-scoped `conntrack -D` -> route-support removal -> final
# ruleset) and only then stops the unit. This script exists for the cases nothing
# else covers: shutdown, a `systemctl stop` issued by hand, and a backend that
# died holding kernel state. So every step is INDEPENDENT and TOLERANT — a step
# whose object is already gone is a no-op, never a failure, and one failing step
# must never prevent the next from running.
#
# SHELL PROFILE: device-daemon (docs/shell-profiles.md) — `set -uo pipefail`, NO
# `-e`, no ERR trap, self-contained log/die. `-e` here would turn "the table was
# already deleted" into "the qdiscs and the rule band are left behind", which is
# exactly the state this script exists to prevent.
#
# NO `cmd | grep -q` ANYWHERE IN THIS FILE, DELIBERATELY. `grep -q` exits at its
# first match and closes the pipe; the producer takes SIGPIPE, and under
# `pipefail` a SUCCESSFUL read reports 141. This repo has shipped that footgun
# four times (deb_lists_path, verify-boot-artifacts.sh, and two static
# harnesses). Every read below goes through a command substitution and is matched
# with a `case`/`[[ ]]` on the captured text.
#
# Test seams (production uses every default):
#   CERALIVE_SHARE_TABLE_FAMILY   — nft family                (default inet)
#   CERALIVE_SHARE_TABLE_NAME     — nft table                 (default ceralive_share)
#   CERALIVE_SHARE_RULE_PRIORITY  — our `ip rule` band        (default 110)
#   CERALIVE_SHARE_QDISC_HANDLE   — shaper's reserved root    (default ca00:)
#   CERALIVE_SHARE_IP_FORWARD     — ip_forward procfs path
#   CERALIVE_SHARE_IP_FORWARD_STATE — recorded prior ip_forward value
#   CERALIVE_SHARE_NET_DIR        — netdev class dir          (default /sys/class/net)
#   CERALIVE_SHARE_NFT / _IP / _TC — binaries, for offline harnesses

set -uo pipefail

# --- named constants (REQ-USB-020) ------------------------------------------
# The three the unit exports are the CROSS-REPO contract, declared in CeraUI's
# apps/backend/src/modules/network/uplink-steering/contracts.ts. Changing one on
# either side without the other breaks sharing silently.
SHARE_TABLE_FAMILY="${CERALIVE_SHARE_TABLE_FAMILY:-inet}"
SHARE_TABLE_NAME="${CERALIVE_SHARE_TABLE_NAME:-ceralive_share}"
# FWMARK_RULE_PRIORITY in contracts.ts. Strictly greater than the image's own
# priority-100 source-routing rules, which this script must never touch.
SHARE_RULE_PRIORITY="${CERALIVE_SHARE_RULE_PRIORITY:-110}"
# MANAGED_TABLE_BASE / MANAGED_TABLE_BASE + 0xffff in route-planner.ts. Only a
# routing table inside this private range may be flushed here (see STEP 2).
SHARE_TABLE_MIN="${CERALIVE_SHARE_TABLE_MIN:-30000}"
SHARE_TABLE_MAX="${CERALIVE_SHARE_TABLE_MAX:-95535}"
# UPLINK_SHAPER_QDISC.rootHandle in uplink-shaper/contracts.ts.
SHARE_QDISC_HANDLE="${CERALIVE_SHARE_QDISC_HANDLE:-ca00:}"
IP_FORWARD_PATH="${CERALIVE_SHARE_IP_FORWARD:-/proc/sys/net/ipv4/ip_forward}"
IP_FORWARD_STATE="${CERALIVE_SHARE_IP_FORWARD_STATE:-/run/ceralive/share-ip-forward.saved}"
NET_DIR="${CERALIVE_SHARE_NET_DIR:-/sys/class/net}"
NFT_BIN="${CERALIVE_SHARE_NFT:-/usr/sbin/nft}"
IP_BIN="${CERALIVE_SHARE_IP:-ip}"
TC_BIN="${CERALIVE_SHARE_TC:-tc}"
# A hard ceiling on the rule-deletion loop. `ip rule del` removes ONE rule per
# call, so the loop is genuinely needed; the bound is what stops a kernel that
# keeps reporting a rule it will not delete from spinning forever.
MAX_RULE_DELETIONS="${CERALIVE_SHARE_MAX_RULE_DELETIONS:-64}"

log() { printf 'ceralive-share-teardown: %s\n' "$*"; }

# --- STEP 1: scoped table delete --------------------------------------------
# `delete table <family> <name>` and NOTHING else. Never `nft flush ruleset`:
# the image's own `inet ceralive_ingest_fw` is the LAN-ingest security boundary
# and NetworkManager's shared-mode NAT lives in its own table too — a global
# flush would take both out and leave the unauthenticated RTMP/SRT ingest
# reachable from a WAN uplink. A table that is already absent is the expected
# state on a second stop, so its failure is logged and ignored.
if "${NFT_BIN}" delete table "${SHARE_TABLE_FAMILY}" "${SHARE_TABLE_NAME}" 2>/dev/null; then
  log "deleted nft table ${SHARE_TABLE_FAMILY} ${SHARE_TABLE_NAME}"
else
  log "nft table ${SHARE_TABLE_FAMILY} ${SHARE_TABLE_NAME} already absent"
fi

# --- STEP 2: rule-band removal ----------------------------------------------
# Collect the routing tables our own priority band points at BEFORE deleting the
# rules, because once the rules are gone the association is unrecoverable.
share_tables=""
rules_before="$("${IP_BIN}" rule show 2>/dev/null)"
while IFS= read -r line; do
  [[ "${line}" == "${SHARE_RULE_PRIORITY}:"* ]] || continue
  # `110:\tfrom all fwmark 0xca000100/0xffffff00 lookup 30001`
  if [[ "${line}" =~ (lookup|table)[[:space:]]+([A-Za-z0-9_.-]+) ]]; then
    share_tables="${share_tables} ${BASH_REMATCH[2]}"
  fi
done <<<"${rules_before}"

deleted=0
while [[ "${deleted}" -lt "${MAX_RULE_DELETIONS}" ]]; do
  current="$("${IP_BIN}" rule show 2>/dev/null)"
  still_there=0
  while IFS= read -r line; do
    if [[ "${line}" == "${SHARE_RULE_PRIORITY}:"* ]]; then
      still_there=1
      break
    fi
  done <<<"${current}"
  [[ "${still_there}" -eq 1 ]] || break
  "${IP_BIN}" rule del priority "${SHARE_RULE_PRIORITY}" 2>/dev/null || break
  deleted=$((deleted + 1))
done
if [[ "${deleted}" -gt 0 ]]; then
  log "removed ${deleted} ip rule(s) at priority ${SHARE_RULE_PRIORITY}"
fi

# Flush ONLY the private, module-provisioned routing tables. The steering layer
# REUSES the image's own per-uplink tables (100-107 for usb*/enx*, 120-124 for
# wlan*) wherever one already exists, and those belong to the SRTLA source-policy
# routing that keeps bonding working — flushing one here would break the stream
# this whole subsystem exists to protect. Anything that is not an all-digit token
# inside the managed range is skipped with its name logged.
for table in ${share_tables}; do
  if [[ ! "${table}" =~ ^[0-9]+$ ]]; then
    log "leaving named routing table ${table} alone (not module-provisioned)"
    continue
  fi
  if [[ "${table}" -lt "${SHARE_TABLE_MIN}" || "${table}" -gt "${SHARE_TABLE_MAX}" ]]; then
    log "leaving routing table ${table} alone (outside the managed range ${SHARE_TABLE_MIN}-${SHARE_TABLE_MAX})"
    continue
  fi
  if "${IP_BIN}" route flush table "${table}" 2>/dev/null; then
    log "flushed module-provisioned routing table ${table}"
  fi
done

# --- STEP 3: qdisc restore --------------------------------------------------
# The shaper installs its root under a RESERVED handle so its own work is
# distinguishable from whatever the interface had before. Deleting that root is
# the restore: the kernel immediately re-establishes the interface's default root
# qdisc, which is precisely the mq/fq_codel/noqueue/pfifo_fast the shaper is only
# ever allowed to take over in the first place. An interface whose root is NOT
# ours is left completely untouched — a custom root the operator installed is
# none of our business, and the shaper itself refuses to touch one.
if [[ -d "${NET_DIR}" ]]; then
  for ifpath in "${NET_DIR}"/*; do
    [[ -e "${ifpath}" ]] || continue
    ifname="${ifpath##*/}"
    root_desc="$("${TC_BIN}" qdisc show dev "${ifname}" root 2>/dev/null)"
    case " ${root_desc} " in
      *" ${SHARE_QDISC_HANDLE} "*)
        if "${TC_BIN}" qdisc del dev "${ifname}" root 2>/dev/null; then
          log "removed module-owned root qdisc ${SHARE_QDISC_HANDLE} from ${ifname}"
        fi
        ;;
    esac
  done
fi

# --- STEP 4: ip_forward restore — CONDITIONAL, and that is the whole point ---
# REQ-USB-026 says `ip_forward` is toggled ONLY on client-zone active<->inactive
# edges. A teardown that unconditionally wrote 0 would violate that in the way
# that actually hurts: NetworkManager's shared mode (the hotspot, and a
# shared-LAN ethernet port) needs forwarding too, so zeroing it here would cut
# every hotspot client off the internet the moment the sharing layer stopped —
# and NM would not put it back, because from its point of view nothing changed.
#
# So this restores a RECORDED PRIOR VALUE and writes NOTHING when there is none.
# The record is the writer's to make on the inactive->active edge: whoever raises
# ip_forward for a client zone leaves the value it replaced in
# CERALIVE_SHARE_IP_FORWARD_STATE, and this backstop hands that exact value back
# and clears the record.
#
# TODAY THAT FILE IS NORMALLY ABSENT, and that is correct rather than broken:
# CeraUI toggles ip_forward with `sysctl -w` on its own client-zone edges and
# keeps no record, so the edge-triggered release in the backend remains the live
# path and this step is inert. Being inert is the honest behaviour — the one
# thing this script must never do is invent a prior value it did not observe.
if [[ -f "${IP_FORWARD_STATE}" ]]; then
  saved="$(cat -- "${IP_FORWARD_STATE}" 2>/dev/null)"
  saved="${saved//[[:space:]]/}"
  if [[ "${saved}" =~ ^[01]$ ]]; then
    if printf '%s\n' "${saved}" >"${IP_FORWARD_PATH}" 2>/dev/null; then
      log "restored ip_forward to the recorded prior value ${saved}"
    else
      log "could not write ${IP_FORWARD_PATH} — leaving forwarding as it is"
    fi
    rm -f -- "${IP_FORWARD_STATE}"
  else
    log "recorded ip_forward value was not 0 or 1 — refusing to guess, leaving forwarding as it is"
  fi
else
  log "no recorded ip_forward value — leaving forwarding to its edge-triggered owner"
fi

log "teardown complete"
exit 0
