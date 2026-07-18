#!/usr/bin/env bash
#
# resolv-conf-bind-mount.test.sh — regression guard for the mkosi-bind-mount EBUSY
# that broke `./v2/build` at configure_networking(), and — critically — for the
# broken-device state a naive "skip when busy" fix would silently ship.
#
# THE BUG (host-independent; proven empirically via a full containerized build AND
# faithful micro-tests). During a containerized mkosi build, mkosi ro-binds the
# host's /etc/resolv.conf over the image's placeholder for networked postinst
# scripts (mkosi run.py: `--ro-bind /etc/resolv.conf`; the placeholder is the empty
# 0-byte file mkosi __init__.py unlink+touch pre-creates). That makes the image's
# /etc/resolv.conf an un-replaceable MOUNTPOINT, so configure_networking()'s
# `ln -sf …/stub-resolv.conf /etc/resolv.conf` died with `Device or resource busy`.
#
# WHY THE NAIVE FIX IS A REGRESSION. `mountpoint -q || ln -sf` (skip when busy)
# makes the build succeed but leaves mkosi's EMPTY placeholder baked into the
# shipped image as the permanent /etc/resolv.conf — a fielded device then boots
# with zero working DNS (the exact total-DNS-failure resolv-conf-symlink.test.sh
# already guards against, reintroduced at ship time). The correct fix UNMOUNTS the
# overlay first, then symlinks, so the stub link persists into the built image.
#
# WHY THIS IS SEPARATE FROM resolv-conf-symlink.test.sh. That test only exercises
# the non-bind-mounted case (an empty REGULAR file), which `ln -sf` handles fine —
# it never mounts anything over the path, so it cannot catch the EBUSY-or-empty
# regression. This test reproduces the EXACT bind-mounted state the real build hits
# and asserts the END STATE is the correct stub symlink: not a leftover mount, not
# the empty placeholder.
#
# Part A — static contract: configure_networking() unmounts a bind-mounted
#          /etc/resolv.conf before it symlinks (guarded by mountpoint), and does so
#          BEFORE the `ln -sf`.
# Part B — runtime: in a rootless user+mount namespace, bind-mount a file onto the
#          synthetic /etc/resolv.conf (the real build's state), run the REAL
#          configure_networking(), and prove the result is the stub symlink.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
POSTINST_LIB="${V2}/mkosi/customize/postinst-lib.sh"
STUB="/run/systemd/resolve/stub-resolv.conf"

fail() { printf 'resolv-conf-bind-mount regression: %s\n' "$1" >&2; exit 1; }

[[ -f "${POSTINST_LIB}" ]] || fail "missing source file: ${POSTINST_LIB}"

fn_body="$(awk '
  /^configure_networking\(\) \{/ { f=1 }
  f { print }
  f && /^\}/ { exit }
' "${POSTINST_LIB}")"
[[ -n "${fn_body}" ]] || fail "could not extract configure_networking() from postinst-lib.sh"

# ---------------------------------------------------------------------------
# Part A — static contract (always enforced)
# ---------------------------------------------------------------------------
# The function must unmount /etc/resolv.conf when it is a mountpoint, guarded by a
# mountpoint test, and that unmount must come BEFORE the `ln -sf` that writes the
# symlink — otherwise the symlink can never replace the bind-mounted placeholder.
grep -Eq 'mountpoint[[:space:]]+-q[[:space:]]+/etc/resolv\.conf' <<<"${fn_body}" \
  || fail "configure_networking() no longer guards on 'mountpoint -q /etc/resolv.conf' — the build breaks (EBUSY) or, worse, bakes mkosi's empty placeholder as the shipped resolv.conf"

grep -Eq 'umount[[:space:]]+/etc/resolv\.conf' <<<"${fn_body}" \
  || fail "configure_networking() no longer runs 'umount /etc/resolv.conf' — a skip-when-busy fix would ship an empty /etc/resolv.conf (zero DNS on real hardware)"

umount_line="$(grep -nE 'umount[[:space:]]+/etc/resolv\.conf' <<<"${fn_body}" | head -1 | cut -d: -f1)"
ln_line="$(grep -nE "ln[[:space:]]+-sf[[:space:]]+${STUB}[[:space:]]+/etc/resolv\.conf" <<<"${fn_body}" | head -1 | cut -d: -f1)"
[[ -n "${umount_line}" && -n "${ln_line}" ]] \
  || fail "could not locate both the umount and the ln -sf lines in configure_networking()"
(( umount_line < ln_line )) \
  || fail "configure_networking() runs 'ln -sf' before unmounting the overlay — the symlink cannot replace a still-mounted /etc/resolv.conf"

# After unmounting the overlay, DNS is gone for the rest of the postinst; later steps
# still hit the network (e.g. setup_rtmp_gateway's MediaMTX fetch). The function must
# seed resolved's stub with the captured nameservers so those steps keep resolving.
grep -Eq 'stub-resolv\.conf' <<<"${fn_body}" \
  && grep -Eq 'mkdir[[:space:]].*-p[[:space:]].*/run/systemd/resolve' <<<"${fn_body}" \
  || fail "configure_networking() no longer seeds /run/systemd/resolve/stub-resolv.conf after unmounting — later network steps (e.g. MediaMTX fetch) lose DNS and the build fails"

echo "resolv-conf-bind-mount: Part A static contract OK (unmount before symlink; stub seeded for build-time DNS continuity)"

# ---------------------------------------------------------------------------
# Part B — runtime reproduction in a rootless user+mount namespace (best effort)
# ---------------------------------------------------------------------------
# Reproduce the EXACT build state: /etc/resolv.conf is a bind MOUNTPOINT over the
# empty placeholder. Run the real configure_networking() and assert it leaves the
# stub symlink — proving it unmounted the overlay and the change persists (it is
# NOT still a mount, and NOT the leftover empty file).

if ! unshare -rm --map-root-user true 2>/dev/null; then
  echo "resolv-conf-bind-mount: rootless user+mount namespaces unavailable — skipping Part B runtime reproduction (static contract enforced)"
  echo "resolv-conf-bind-mount regression: PASS (static only)"
  exit 0
fi

REPRO="$(mktemp)"
trap 'rm -f "${REPRO}"' EXIT
cat >"${REPRO}" <<REPRO_EOF
set -euo pipefail
mount -t tmpfs none /etc
mount -t tmpfs none /run

mkdir -p /etc/NetworkManager/conf.d
printf 'hosts: files dns\n'      >/etc/nsswitch.conf
printf '127.0.0.1\tlocalhost\n'  >/etc/hosts

# Reproduce mkosi's state: the empty 0-byte placeholder, then a bind mount OVER it
# (mkosi's --ro-bind of the host resolv.conf). A separate source file with distinct
# content lets us prove the end state is NOT the mounted overlay.
: >/etc/resolv.conf
printf 'nameserver 203.0.113.53\n' >/tmp/host-resolv.conf
mount --bind /tmp/host-resolv.conf /etc/resolv.conf

mountpoint -q /etc/resolv.conf || { echo "seed precondition failed: /etc/resolv.conf is not a mountpoint"; exit 1; }

# shellcheck source=/dev/null
source "${POSTINST_LIB}"
log() { :; }
install_interface_naming() { :; }

# --- the bind-mounted overlay must become the stub symlink -----------------------
configure_networking
if mountpoint -q /etc/resolv.conf; then echo "FAIL: /etc/resolv.conf is STILL a mountpoint after configure_networking (overlay not torn down)"; exit 1; fi
[ -L /etc/resolv.conf ] || { echo "FAIL: /etc/resolv.conf is not a symlink after configure_networking (skip-when-busy would leave the empty placeholder → zero DNS)"; exit 1; }
[ "\$(readlink /etc/resolv.conf)" = "${STUB}" ] || { echo "FAIL: resolv.conf points at '\$(readlink /etc/resolv.conf)', expected ${STUB}"; exit 1; }

# --- DNS continuity: the stub is seeded with the captured nameservers ------------
# The symlink resolves through to the seeded stub, so later postinst steps that hit
# the network (e.g. MediaMTX fetch) still resolve during the build.
[ "\$(readlink -f /etc/resolv.conf)" = "${STUB}" ] || { echo "FAIL: resolv.conf does not resolve through to ${STUB}"; exit 1; }
grep -q '203.0.113.53' "${STUB}" || { echo "FAIL: resolved stub not seeded with the captured nameservers — later build steps lose DNS"; exit 1; }

# --- idempotent: a second run over an already-correct symlink stays correct ------
configure_networking
[ -L /etc/resolv.conf ] || { echo "FAIL: resolv.conf stopped being a symlink after a re-run"; exit 1; }
[ "\$(readlink /etc/resolv.conf)" = "${STUB}" ] || { echo "FAIL: re-run changed the resolv.conf link target"; exit 1; }
REPRO_EOF

if unshare -rm --map-root-user bash "${REPRO}"; then
  echo "resolv-conf-bind-mount: Part B runtime reproduction OK (bind-mounted overlay → stub symlink, no leftover mount, no empty placeholder, idempotent)"
else
  fail "the real configure_networking() did not unmount the overlay and leave /etc/resolv.conf as the ${STUB} symlink"
fi

echo "resolv-conf-bind-mount regression: PASS"
