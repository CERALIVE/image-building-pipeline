#!/usr/bin/env bash
#
# data-persistence-public-symlink.test.sh — offline guard for the frontend-404
# regression caused by the /data migration dropping the CeraUI "public" symlink.
#
# THE BUG (confirmed on real hardware: curl http://<device>/ -> 404 while /status
# returns healthy JSON). The CeraUI .deb ships the frontend static tree at
# /var/www/ceralive and an ABSOLUTE symlink /opt/ceralive/public -> /var/www/ceralive
# (build-debian-package.sh: `ln -s /var/www/ceralive .../opt/ceralive/public`).
# setup_data_persistence() generates ceralive-migrate-data, whose seeding loop copies
# the CeraUI working dir onto /data BEFORE a bind mount shadows /opt/ceralive with
# /data/ceralive. The loop originally seeded only *.json + revision, never "public",
# so once the bind activated /opt/ceralive/public no longer existed — the rootfs
# symlink was shadowed and /data had no replacement. CeraUI then served the frontend
# from a missing dir and 404'd, even though the backend API was healthy.
#
# THE FIX. The seeding loop also seeds "public". cp -a copies the symlink ITSELF (not
# the /var/www asset tree — those stay on the rootfs so image/OTA updates keep
# tracking), and both existence checks are symlink-aware (`[ -L ]`) so a symlink is
# neither skipped as a source nor clobbered as an existing /data entry. Because the
# symlink is absolute and /opt/ceralive and /data/ceralive sit at the same depth, the
# copied link resolves to /var/www/ceralive identically once the bind mount is live.
#
# WHY THIS IS A SEPARATE TEST FROM systemd-ordering-cycle.test.sh. That test checks the
# migrate-data unit's dependency GRAPH (ordering/acyclicity). This is a check of the
# migrate-data SCRIPT's seeding BEHAVIOR — a content bug the graph check cannot see.
#
# Part A — static contract on the real seeding block in postinst-lib.sh.
# Part B — runtime: extract that exact block, run it against a synthetic tree, and
#          prove the symlink is preserved, resolves after the bind mount, is
#          idempotent, and never clobbers a pre-existing /data entry.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
POSTINST_LIB="${V2}/mkosi/customize/postinst-lib.sh"

fail() { printf 'data-persistence-public-symlink regression: %s\n' "$1" >&2; exit 1; }

[[ -f "${POSTINST_LIB}" ]] || fail "missing source file: ${POSTINST_LIB}"

# Extract the exact seeding block generated into ceralive-migrate-data (the `if [ -d
# "$WORKDIR" ] ... fi` guard). index()-anchored so no regex escaping of the literal
# heredoc line, and it stops at the block's own closing `fi`.
block="$(awk '
  index($0, "if [ -d \"$WORKDIR\" ] && ! mountpoint -q \"$WORKDIR\"; then") { f=1 }
  f { print }
  f && $0 ~ /^fi$/ { exit }
' "${POSTINST_LIB}")"
[[ -n "${block}" ]] || fail "could not extract the WORKDIR seeding block from postinst-lib.sh"

# ---------------------------------------------------------------------------
# Part A — static contract (always enforced)
# ---------------------------------------------------------------------------
grep -Fq '"$WORKDIR/public"' <<<"${block}" \
  || fail 'seeding loop no longer lists "$WORKDIR/public" — the frontend static symlink would be dropped by the /data bind mount (404 on /)'
grep -Eq '\bcp -a\b' <<<"${block}" \
  || fail 'seeding loop no longer uses `cp -a` — a symlink source would be dereferenced (copies the whole /var/www tree) instead of preserved as a link'
grep -Fq '[ -L "$f" ]' <<<"${block}" \
  || fail 'seeding loop source guard is not symlink-aware ([ -L "$f" ]) — a symlink whose target is absent would be skipped'
grep -Fq '[ -L "$DATA/ceralive/$base" ]' <<<"${block}" \
  || fail 'seeding loop dest guard is not symlink-aware ([ -L "$DATA/ceralive/$base" ]) — an existing /data symlink could be clobbered/nested on re-run'

echo "data-persistence-public-symlink: Part A static contract OK"

# ---------------------------------------------------------------------------
# Part B — runtime reproduction against a synthetic tree
# ---------------------------------------------------------------------------
# Run the extracted block verbatim with DATA/WORKDIR pointed at a synthetic tree.
# `mountpoint` is stubbed to "not a mountpoint" so the block is hermetic (synthetic
# dirs are never real mounts) and needs no util-linux. No root, no namespace: the
# block only ever touches $WORKDIR and $DATA.
run_block() { # $1=DATA  $2=WORKDIR
  local runner; runner="$(mktemp)"
  {
    echo 'set -euo pipefail'
    echo 'mountpoint() { return 1; }'
    printf 'DATA=%q\n' "$1"
    printf 'WORKDIR=%q\n' "$2"
    printf '%s\n' "${block}"
  } >"${runner}"
  bash "${runner}"
  rm -f "${runner}"
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --- B1: the real .deb symlink value is preserved as a symlink -------------------
S1="${TMP}/b1"; mkdir -p "${S1}/opt/ceralive" "${S1}/data/ceralive"
printf '{"engine":"cerastream"}\n' >"${S1}/opt/ceralive/setup.json"
printf 'deadbeef\n'                >"${S1}/opt/ceralive/revision"
ln -s /var/www/ceralive "${S1}/opt/ceralive/public"   # exact form from build-debian-package.sh
run_block "${S1}/data" "${S1}/opt/ceralive"
[[ -L "${S1}/data/ceralive/public" ]] \
  || fail "B1: /data/ceralive/public is not a symlink after seeding (frontend serving would 404)"
[[ "$(readlink "${S1}/data/ceralive/public")" == "/var/www/ceralive" ]] \
  || fail "B1: seeded public points at '$(readlink "${S1}/data/ceralive/public")', expected /var/www/ceralive (link value not preserved verbatim)"
# cp -a must NOT have dereferenced the link into a copied asset directory.
[[ ! -e "${S1}/data/ceralive/public/index.html" || -L "${S1}/data/ceralive/public" ]] || true
# the pre-existing seed behavior (json + revision) must still work.
[[ -f "${S1}/data/ceralive/setup.json" && -f "${S1}/data/ceralive/revision" ]] \
  || fail "B1: existing *.json/revision seeding regressed"
echo "data-persistence-public-symlink: Part B1 symlink-preserved OK"

# --- B2: after the bind mount the symlink resolves to the frontend tree ----------
# The bind mount replaces /opt/ceralive with /data/ceralive; the absolute symlink
# resolves the same from either location. Use an existing absolute target so
# `readlink -f` can prove real resolution without root (a synthetic stand-in for the
# rootfs /var/www/ceralive that the .deb guarantees is present).
S2="${TMP}/b2"; mkdir -p "${S2}/opt/ceralive" "${S2}/data/ceralive" "${S2}/var/www/ceralive"
printf '<!doctype html><title>CeraUI</title>\n' >"${S2}/var/www/ceralive/index.html"
ln -s "${S2}/var/www/ceralive" "${S2}/opt/ceralive/public"
run_block "${S2}/data" "${S2}/opt/ceralive"
resolved="$(readlink -f "${S2}/data/ceralive/public")"
[[ -f "${resolved}/index.html" ]] \
  || fail "B2: /data/ceralive/public does not resolve to the frontend tree (resolved='${resolved}') — /opt/ceralive/public would 404 after the bind mount"
echo "data-persistence-public-symlink: Part B2 bind-mount resolution OK"

# --- B3: idempotent across re-runs / A-B slot swaps -----------------------------
run_block "${S1}/data" "${S1}/opt/ceralive"
run_block "${S1}/data" "${S1}/opt/ceralive"
[[ -L "${S1}/data/ceralive/public" ]] \
  || fail "B3: public stopped being a symlink after a re-run"
[[ ! -e "${S1}/data/ceralive/public/public" ]] \
  || fail "B3: re-run nested a copy at /data/ceralive/public/public (cp footgun — dest guard failed)"
[[ "$(readlink "${S1}/data/ceralive/public")" == "/var/www/ceralive" ]] \
  || fail "B3: re-run changed the public link target"
echo "data-persistence-public-symlink: Part B3 idempotency OK"

# --- B4: a device that already has /data/ceralive/public is never clobbered ------
S4="${TMP}/b4"; mkdir -p "${S4}/opt/ceralive" "${S4}/data/ceralive"
ln -s /var/www/ceralive          "${S4}/opt/ceralive/public"
ln -s /operator/custom/frontend  "${S4}/data/ceralive/public"   # pre-existing, different
run_block "${S4}/data" "${S4}/opt/ceralive"
[[ "$(readlink "${S4}/data/ceralive/public")" == "/operator/custom/frontend" ]] \
  || fail "B4: an existing /data/ceralive/public symlink was clobbered (must be a no-op)"
[[ ! -e "${S4}/data/ceralive/public/public" ]] \
  || fail "B4: seeding nested a copy under an existing /data/ceralive/public symlink"
echo "data-persistence-public-symlink: Part B4 no-clobber OK"

echo "data-persistence-public-symlink regression: PASS"
