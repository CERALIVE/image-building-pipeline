#!/usr/bin/env bash
#
# apt-mtls-and-dedupe.test.sh — guard the two on-device apt regressions this fix
# repairs, against the functions the REAL build runs (not only the customize twin):
#
#   1. mTLS client-KEY readability. apt's https fetcher runs sandboxed as the `_apt`
#      user, so a `root:root` mode-0600 /etc/apt/certs/client.key is UNREADABLE and
#      `apt-get update` dies "Could not load client certificate … Error while reading
#      file" (confirmed live on a Rock 5B+). The key must be handed to `_apt`.
#   2. Duplicate Debian source. mkosi's release-named bootstrap source
#      (bookworm.sources) leaks into the rootfs alongside our debian.sources, so
#      apt warns "Target Packages … is configured multiple times". configure_minimal_apt
#      must leave EXACTLY ONE Debian source (debian.sources).
#   3. ceralive.sources repo URI. apt-worker serves the first-party repo at
#      dists/<channel>/binary-<arch>/ (confirmed 200); a bare dists/<channel>/ 404s the
#      Release file. The URI MUST be arch-qualified (…/binary-<arch>/), matching the
#      known-working fetch-debs.sh `fetch_first_party` and the customize module.
#
# THE GAP THIS CLOSES (same lesson as apt-preferences-baked.test.sh): `./v2/build`
# runs mkosi.images/runtime/mkosi.postinst.chroot, NOT customize/apt-ceralive-repo.sh.
# A guard that only exercises the customize twin can stay green while the shipped
# image regresses — so Part A targets BOTH tracks and Part B runs the REAL executor's
# configure_minimal_apt against a scratch chroot filesystem.
#
# NEVER prints key material: Part B seeds only a synthetic Debian source; the mTLS
# key path is asserted statically (Part A) and proven at runtime on the live device.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
POSTINST="${V2}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
MODULE="${V2}/mkosi/customize/apt-ceralive-repo.sh"

fail() { printf 'apt-mtls-and-dedupe regression: %s\n' "$1" >&2; exit 1; }

[[ -f "${POSTINST}" ]] || fail "missing runtime executor: ${POSTINST}"
[[ -f "${MODULE}" ]]   || fail "missing customize twin: ${MODULE}"

extract_fn() { # <name> <file>
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { f=1 }
    f { print }
    f && /^\}/ { exit }
  ' "$2"
}

post_repo="$(extract_fn setup_ceralive_repository "${POSTINST}")"
post_minapt="$(extract_fn configure_minimal_apt "${POSTINST}")"
mod_mtls="$(extract_fn install_mtls_cert "${MODULE}")"
mod_minapt="$(extract_fn configure_minimal_apt "${MODULE}")"
mod_src="$(extract_fn configure_ceralive_source "${MODULE}")"
[[ -n "${post_repo}" && -n "${post_minapt}" ]] || fail "could not extract runtime apt functions from ${POSTINST}"
[[ -n "${mod_mtls}"  && -n "${mod_minapt}" && -n "${mod_src}" ]] || fail "could not extract customize apt functions from ${MODULE}"

# ---------------------------------------------------------------------------
# Part A — static contract (always enforced)
# ---------------------------------------------------------------------------

# 1. mTLS key is handed to _apt, and the old root-owned 0600 key is GONE (both tracks).
grep -Eq 'chown[[:space:]]+_apt(:root)?[[:space:]]+/etc/apt/certs/client\.key' <<<"${post_repo}" \
  || fail "runtime setup_ceralive_repository() no longer chowns client.key to _apt — apt's _apt fetcher cannot read a root-owned key"
grep -Eq 'chmod[[:space:]]+600[[:space:]]+/etc/apt/certs/client\.key' <<<"${post_repo}" \
  && fail "runtime setup_ceralive_repository() still leaves client.key mode 600 (root-owned → unreadable by _apt)"
grep -Eq 'chown[[:space:]]+_apt(:root)?[[:space:]]+/etc/apt/certs/client\.key' <<<"${mod_mtls}" \
  || fail "customize install_mtls_cert() no longer chowns client.key to _apt"
grep -Eq 'chmod[[:space:]]+600[[:space:]]+/etc/apt/certs/client\.key' <<<"${mod_mtls}" \
  && fail "customize install_mtls_cert() still leaves client.key mode 600 (root-owned → unreadable by _apt)"

# 2. configure_minimal_apt removes the mkosi release-named dupe AND writes debian.sources (both tracks).
grep -Eq 'rm -f.*\$\{(RELEASE|APT_RELEASE)\}"?\.sources' <<<"${post_minapt}" \
  || fail "runtime configure_minimal_apt() no longer removes the mkosi release-named Debian source (\${RELEASE}.sources) — duplicate-source warnings ship"
grep -Eq 'sources\.list\.d/debian\.sources' <<<"${post_minapt}" \
  || fail "runtime configure_minimal_apt() no longer writes the canonical debian.sources"
grep -Eq 'rm -f.*\$\{(RELEASE|APT_RELEASE)\}"?\.sources' <<<"${mod_minapt}" \
  || fail "customize configure_minimal_apt() no longer removes the mkosi release-named Debian source"

# 3. ceralive.sources URI is arch-qualified (…/dists/<channel>/binary-<arch>/) in BOTH
#    tracks — a bare dists/<channel>/ 404s the Release file (apt-worker serves binary-<arch>/).
grep -Eq 'URIs:.*/dists/\$\{CHANNEL\}/binary-' <<<"${post_repo}" \
  || fail "runtime setup_ceralive_repository() ceralive.sources URI is not arch-qualified (…/binary-<arch>/) — apt.ceralive.tv/dists/<channel>/Release 404s"
grep -Eq 'URIs:[[:space:]]*https://[^[:space:]]*/dists/\$\{CHANNEL\}/[[:space:]]*$' <<<"${post_repo}" \
  && fail "runtime setup_ceralive_repository() still writes the bare dists/<channel>/ URI (404 on Release)"
grep -Eq 'URIs:.*/dists/\$\{APT_CHANNEL\}/binary-' <<<"${mod_src}" \
  || fail "customize configure_ceralive_source() URI is not arch-qualified (…/binary-<arch>/)"

echo "apt-mtls-and-dedupe: Part A static contract OK (both tracks: _apt-owned key + single Debian source + arch-qualified repo URI)"

# ---------------------------------------------------------------------------
# Part B — runtime dedupe reproduction in a rootless user+mount namespace
# ---------------------------------------------------------------------------
if ! unshare -rm --map-root-user true 2>/dev/null; then
  echo "apt-mtls-and-dedupe: rootless user+mount namespaces unavailable — skipping Part B (static contract enforced)"
  echo "apt-mtls-and-dedupe regression: PASS (static only)"
  exit 0
fi

REPRO="$(mktemp)"
trap 'rm -f "${REPRO}"' EXIT
cat >"${REPRO}" <<REPRO_EOF
set -euo pipefail
# Scratch chroot filesystem: tmpfs over /etc so the host is never touched.
mount -t tmpfs none /etc
mkdir -p /etc/apt/sources.list.d /etc/apt/apt.conf.d

# Seed the exact stray the fix must remove: mkosi's release-named bootstrap source,
# duplicating the Debian archive that debian.sources also configures.
cat >/etc/apt/sources.list.d/bookworm.sources <<'STRAY'
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: bookworm
Components: main main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
STRAY

log() { :; }
RELEASE="bookworm"
eval "\$(awk '/^configure_minimal_apt\(\) \{/,/^}/' "${POSTINST}")"
configure_minimal_apt

[ ! -e /etc/apt/sources.list.d/bookworm.sources ] || { echo "FAIL: configure_minimal_apt left the mkosi release-named dupe (bookworm.sources) behind"; exit 1; }
[ -f /etc/apt/sources.list.d/debian.sources ]     || { echo "FAIL: configure_minimal_apt did not write the canonical debian.sources"; exit 1; }
# Exactly one Debian-archive source file remains.
n="\$(grep -rl 'deb.debian.org/debian' /etc/apt/sources.list.d/ 2>/dev/null | wc -l)"
[ "\$n" -eq 1 ] || { echo "FAIL: expected exactly ONE Debian source, found \$n"; ls -1 /etc/apt/sources.list.d/; exit 1; }
REPRO_EOF

if unshare -rm --map-root-user bash "${REPRO}"; then
  echo "apt-mtls-and-dedupe: Part B runtime OK (build-path configure_minimal_apt leaves exactly one Debian source)"
else
  fail "the real configure_minimal_apt() did not dedupe to a single Debian source"
fi

echo "apt-mtls-and-dedupe regression: PASS"
