#!/usr/bin/env bash
#
# resolv-conf-symlink.test.sh — offline guard for the total-DNS-failure regression
# caused by /etc/resolv.conf never being symlinked to systemd-resolved's stub
# (confirmed live on real hardware: `getent hosts www.google.com` exits 2 and
# `curl https://…` reports "Could not resolve host", while the device holds a
# valid IP, gateway, and DHCP-received DNS server).
#
# THE BUG. configure_networking() writes /etc/NetworkManager/conf.d/ceralive.conf
# with dns=systemd-resolved, so NetworkManager DELEGATES DNS to systemd-resolved:
# it forwards the DHCP-received servers to resolved over D-Bus and does NOT write
# /etc/resolv.conf itself. systemd-resolved will only manage /etc/resolv.conf when
# that path IS the symlink to its stub (/run/systemd/resolve/stub-resolv.conf); on
# a plain regular file it reports `resolv.conf mode: foreign` and refuses to touch
# it (its designed safety behavior). This minimal mkosi rootfs never ran resolved's
# postinst trigger / dpkg-reconfigure, so it ships /etc/resolv.conf as an empty
# 0-byte REGULAR file. With delegation on and resolved standing down on a foreign
# file, NOTHING ever populates /etc/resolv.conf — every glibc/getent/curl lookup
# fails with zero working DNS (CeraUI's health checks then log constant
# "DNS timeout for wellknown.belabox.net" / "Failed to resolve www.gstatic.com").
#
# THE FIX. configure_networking() now runs
#   ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
# right after the dns=systemd-resolved NetworkManager drop-in (same delegation
# contract). `-sf` is force + idempotent: it fixes the empty file, a stale link,
# or an already-correct link, so it is safe on every build and A/B slot swap.
#
# WHY THIS IS A SEPARATE TEST. systemd-ordering-cycle.test.sh checks the systemd
# dependency GRAPH; this is a check of configure_networking()'s file-side BEHAVIOR
# — a content bug the graph check cannot see (the same reasoning as
# data-persistence-public-symlink.test.sh).
#
# Part A — static contract on the real configure_networking() body in postinst-lib.sh.
# Part B — runtime: source postinst-lib.sh in a rootless user+mount namespace, run
#          configure_networking() against a synthetic /etc that starts in the exact
#          bug state (0-byte regular resolv.conf), and prove the result is the
#          correct stub symlink — resolves to the stub, is idempotent, and force-
#          replaces a stale link.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
POSTINST_LIB="${V2}/mkosi/customize/postinst-lib.sh"
STUB="/run/systemd/resolve/stub-resolv.conf"

fail() { printf 'resolv-conf-symlink regression: %s\n' "$1" >&2; exit 1; }

[[ -f "${POSTINST_LIB}" ]] || fail "missing source file: ${POSTINST_LIB}"

# Extract the configure_networking() body (from its `func() {` to the top-level
# closing `}` at column 0) so the static checks are scoped to that one function.
fn_body="$(awk '
  /^configure_networking\(\) \{/ { f=1 }
  f { print }
  f && /^\}/ { exit }
' "${POSTINST_LIB}")"
[[ -n "${fn_body}" ]] || fail "could not extract configure_networking() from postinst-lib.sh"

# ---------------------------------------------------------------------------
# Part A — static contract (always enforced)
# ---------------------------------------------------------------------------
# The symlink must be created with `ln -sf` (force → idempotent) and point exactly
# from /etc/resolv.conf to systemd-resolved's stub. Whitespace-tolerant match.
grep -Eq "ln[[:space:]]+-sf[[:space:]]+${STUB}[[:space:]]+/etc/resolv\.conf" <<<"${fn_body}" \
  || fail "configure_networking() no longer runs 'ln -sf ${STUB} /etc/resolv.conf' — DNS breaks completely (resolved reports 'resolv.conf mode: foreign' and stands down on the empty regular file)"

# It must be inside the same function that sets the delegation mode — a symlink
# without dns=systemd-resolved, or delegation without the symlink, is the broken
# half-configuration this fix closes.
grep -Fq 'dns=systemd-resolved' <<<"${fn_body}" \
  || fail "configure_networking() no longer sets dns=systemd-resolved — the resolv.conf symlink and the delegation mode are one contract and must live together"

echo "resolv-conf-symlink: Part A static contract OK"

# ---------------------------------------------------------------------------
# Part B — runtime reproduction in a rootless user+mount namespace (best effort)
# ---------------------------------------------------------------------------
# Run the REAL configure_networking() against a synthetic /etc that begins in the
# exact proof state (empty 0-byte regular /etc/resolv.conf). tmpfs on /etc and /run
# keeps the host untouched; install_interface_naming and log are stubbed so the run
# only exercises the hostname/hosts/nsswitch/NetworkManager/resolv.conf half.

if ! unshare -rm --map-root-user true 2>/dev/null; then
  echo "resolv-conf-symlink: rootless user+mount namespaces unavailable — skipping Part B runtime reproduction (static contract enforced)"
  echo "resolv-conf-symlink regression: PASS (static only)"
  exit 0
fi

REPRO="$(mktemp)"
trap 'rm -f "${REPRO}"' EXIT
cat >"${REPRO}" <<REPRO_EOF
set -euo pipefail
mount -t tmpfs none /etc
mount -t tmpfs none /run

# Minimal /etc the function reads. Seed nsswitch.conf + hosts so their sed/grep
# branches run; seed resolv.conf as the exact bug: an empty 0-byte REGULAR file.
mkdir -p /etc/NetworkManager/conf.d
printf 'hosts: files dns\n'      >/etc/nsswitch.conf
printf '127.0.0.1\tlocalhost\n'  >/etc/hosts
: >/etc/resolv.conf
[ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ] || { echo "seed precondition failed"; exit 1; }

# shellcheck source=/dev/null
source "${POSTINST_LIB}"
log() { :; }
install_interface_naming() { :; }

# --- B1: the empty regular file becomes the stub symlink -------------------------
configure_networking
[ -L /etc/resolv.conf ] || { echo "B1: /etc/resolv.conf is not a symlink after configure_networking (DNS stays broken)"; exit 1; }
[ "\$(readlink /etc/resolv.conf)" = "${STUB}" ] || { echo "B1: resolv.conf points at '\$(readlink /etc/resolv.conf)', expected ${STUB}"; exit 1; }
# sanity: the function ran fully (delegation drop-in written).
grep -q '^dns=systemd-resolved' /etc/NetworkManager/conf.d/ceralive.conf || { echo "B1: NetworkManager delegation drop-in missing"; exit 1; }

# --- B2: client tools read resolved's stub through the link ----------------------
mkdir -p /run/systemd/resolve
printf 'nameserver 127.0.0.53\n' >"${STUB}"
grep -q '127.0.0.53' "\$(readlink -f /etc/resolv.conf)" || { echo "B2: /etc/resolv.conf does not resolve to the stub (getent/curl would still fail)"; exit 1; }

# --- B3: idempotent across re-runs / A-B slot swaps ------------------------------
configure_networking
[ -L /etc/resolv.conf ] || { echo "B3: resolv.conf stopped being a symlink after a re-run"; exit 1; }
[ "\$(readlink /etc/resolv.conf)" = "${STUB}" ] || { echo "B3: re-run changed the resolv.conf link target"; exit 1; }

# --- B4: a stale link (e.g. NM's own file) is force-replaced ---------------------
ln -sf /run/NetworkManager/resolv.conf /etc/resolv.conf
configure_networking
[ "\$(readlink /etc/resolv.conf)" = "${STUB}" ] || { echo "B4: a stale resolv.conf symlink was not force-replaced with the stub"; exit 1; }
REPRO_EOF

if unshare -rm --map-root-user bash "${REPRO}"; then
  echo "resolv-conf-symlink: Part B runtime reproduction OK (bug-state → stub symlink, resolves, idempotent, force-replaces stale link)"
else
  fail "the real configure_networking() did not leave /etc/resolv.conf as the ${STUB} symlink"
fi

echo "resolv-conf-symlink regression: PASS"
