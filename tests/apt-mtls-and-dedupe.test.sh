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
#      (`${RELEASE}.sources`) leaks into the rootfs alongside our debian.sources, so
#      apt warns "Target Packages … is configured multiple times". configure_minimal_apt
#      must leave EXACTLY ONE Debian source (debian.sources).
#   3. ceralive.sources repo URI. apt-worker serves the first-party repo at
#      dists/<channel>/binary-<arch>/ (confirmed 200); a bare dists/<channel>/ 404s the
#      Release file. The URI MUST be arch-qualified (…/binary-<arch>/), matching the
#      known-working fetch-debs.sh `fetch_first_party` and the customize module.
#
# THE GAP THIS CLOSES (same lesson as apt-preferences-baked.test.sh): `./build`
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
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
POSTINST="${PIPELINE_DIR}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
MODULE="${PIPELINE_DIR}/mkosi/customize/apt-ceralive-repo.sh"
TAR_EMIT="${PIPELINE_DIR}/lib/stages/tar-emit.sh"
BUNDLE_BUILDER="${PIPELINE_DIR}/lib/build-bundle.sh"

# The suite Part B drives the shipped writer with. Read from the ONE mapping so
# this harness follows a release bump instead of silently testing the old suite.
# shellcheck source=../lib/shared/target-release-lib.sh
source "${PIPELINE_DIR}/lib/shared/target-release-lib.sh"
target_release_load

fail() { printf 'apt-mtls-and-dedupe regression: %s\n' "$1" >&2; exit 1; }

[[ -f "${POSTINST}" ]] || fail "missing runtime executor: ${POSTINST}"
[[ -f "${MODULE}" ]]   || fail "missing customize twin: ${MODULE}"
[[ -f "${TAR_EMIT}" ]] || fail "missing rootfs tar emitter: ${TAR_EMIT}"
[[ -f "${BUNDLE_BUILDER}" ]] || fail "missing RAUC bundle builder: ${BUNDLE_BUILDER}"

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

# The RAUC payload is the normalized rootfs tar, not the mkosi tree. Flattening
# every tar member to uid/gid 0 silently undoes the `_apt` handoff above before
# the bundle reaches a device.
grep -Eq -- '--owner(=|[[:space:]])0|--group(=|[[:space:]])0' "${TAR_EMIT}" \
  && fail "rootfs tar emitter flattens ownership to root — client.key loses uid 42 in the RAUC payload"
grep -Eq -- '--numeric-owner' "${TAR_EMIT}" \
  || fail "rootfs tar emitter must preserve numeric uid/gid metadata without name remapping"
emit_artifact_fn="$(extract_fn emit_artifact "${TAR_EMIT}")"
[[ -n "${emit_artifact_fn}" ]] || fail "could not extract emit_artifact() from ${TAR_EMIT}"
bundle_stage="$(extract_fn stage_rootfs "${BUNDLE_BUILDER}")"
[[ -n "${bundle_stage}" ]] || fail "could not extract stage_rootfs() from ${BUNDLE_BUILDER}"
grep -Eq -- '--owner(=|[[:space:]])0|--group(=|[[:space:]])0' <<<"${bundle_stage}" \
  && fail "RAUC directory-input tar path flattens ownership to root"
grep -Eq -- '--numeric-owner' <<<"${bundle_stage}" \
  || fail "RAUC directory-input tar path must preserve numeric uid/gid metadata"

ownership_repro="$(mktemp -d)"
cleanup_ownership_repro() {
  if [[ -d "${ownership_repro}/exact-rootfs" && "${EUID}" != 0 ]]; then
    sudo -n rm -rf "${ownership_repro}"
  else
    rm -rf "${ownership_repro}"
  fi
}
trap cleanup_ownership_repro EXIT
mkdir -p "${ownership_repro}/rootfs/etc/apt/certs" "${ownership_repro}/content"
install -m 0400 /dev/null "${ownership_repro}/rootfs/etc/apt/certs/client.key"
chmod 0750 "${ownership_repro}/rootfs/etc/apt/certs"
(
  export SOURCE_DATE_EPOCH=0
  eval "${emit_artifact_fn}"
  emit_artifact "${ownership_repro}/rootfs" "${ownership_repro}/normalized.tar"
)
expected_owner="$(id -u)/$(id -g)"
normalized_key_meta="$(tar --numeric-owner -tvf "${ownership_repro}/normalized.tar" ./etc/apt/certs/client.key | awk '{print $1, $2}')"
normalized_dir_meta="$(tar --numeric-owner --no-recursion -tvf "${ownership_repro}/normalized.tar" ./etc/apt/certs/ | awk '{print $1, $2}')"
[[ "${normalized_key_meta}" == "-r-------- ${expected_owner}" ]] \
  || fail "normalized rootfs tar changed client.key metadata; expected '-r-------- ${expected_owner}', got '${normalized_key_meta}'"
[[ "${normalized_dir_meta}" == "drwxr-x--- ${expected_owner}" ]] \
  || fail "normalized rootfs tar changed certs directory metadata; expected 'drwxr-x--- ${expected_owner}', got '${normalized_dir_meta}'"
(
  export SOURCE_DATE_EPOCH=0
  eval "${bundle_stage}"
  stage_rootfs "${ownership_repro}/rootfs" "${ownership_repro}/content" >/dev/null
)
bundle_key_meta="$(tar --numeric-owner -tvf "${ownership_repro}/content/rootfs.tar" ./etc/apt/certs/client.key | awk '{print $1, $2}')"
bundle_dir_meta="$(tar --numeric-owner --no-recursion -tvf "${ownership_repro}/content/rootfs.tar" ./etc/apt/certs/ | awk '{print $1, $2}')"
[[ "${bundle_key_meta}" == "-r-------- ${expected_owner}" ]] \
  || fail "RAUC directory-input tar changed client.key metadata; expected '-r-------- ${expected_owner}', got '${bundle_key_meta}'"
[[ "${bundle_dir_meta}" == "drwxr-x--- ${expected_owner}" ]] \
  || fail "RAUC directory-input tar changed certs directory metadata; expected 'drwxr-x--- ${expected_owner}', got '${bundle_dir_meta}'"

if [[ "${EUID}" == 0 ]] || sudo -n true 2>/dev/null; then
  mkdir -p "${ownership_repro}/exact-content"
  ownership_helper="${ownership_repro}/exercise-ownership-producers.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '%s\n' "${emit_artifact_fn}" "${bundle_stage}"
    printf '%s\n' 'export SOURCE_DATE_EPOCH=0' 'emit_artifact "$1" "$2"' 'stage_rootfs "$1" "$3" >/dev/null'
  } >"${ownership_helper}"
  chmod 0755 "${ownership_helper}"
  if [[ "${EUID}" == 0 ]]; then
    install -d -o 42 -g 0 -m 0750 "${ownership_repro}/exact-rootfs/etc/apt/certs"
    install -o 42 -g 0 -m 0400 /dev/null "${ownership_repro}/exact-rootfs/etc/apt/certs/client.key"
    "${ownership_helper}" "${ownership_repro}/exact-rootfs" "${ownership_repro}/exact-normalized.tar" "${ownership_repro}/exact-content"
  else
    sudo -n install -d -o 42 -g 0 -m 0750 "${ownership_repro}/exact-rootfs/etc/apt/certs"
    sudo -n install -o 42 -g 0 -m 0400 /dev/null "${ownership_repro}/exact-rootfs/etc/apt/certs/client.key"
    sudo -n "${ownership_helper}" "${ownership_repro}/exact-rootfs" "${ownership_repro}/exact-normalized.tar" "${ownership_repro}/exact-content"
  fi
  for exact_tar in "${ownership_repro}/exact-normalized.tar" "${ownership_repro}/exact-content/rootfs.tar"; do
    exact_key_meta="$(tar --numeric-owner -tvf "${exact_tar}" ./etc/apt/certs/client.key | awk '{print $1, $2}')"
    exact_dir_meta="$(tar --numeric-owner --no-recursion -tvf "${exact_tar}" ./etc/apt/certs/ | awk '{print $1, $2}')"
    [[ "${exact_key_meta}" == '-r-------- 42/0' ]] \
      || fail "privileged ownership fixture changed client.key metadata; expected '-r-------- 42/0', got '${exact_key_meta}'"
    [[ "${exact_dir_meta}" == 'drwxr-x--- 42/0' ]] \
      || fail "privileged ownership fixture changed certs directory metadata; expected 'drwxr-x--- 42/0', got '${exact_dir_meta}'"
  done
else
  echo "apt-mtls-and-dedupe: exact _apt uid 42 fixture skipped (root or passwordless sudo unavailable)"
fi

fallback_argv="$(printf '%s\n' "${emit_artifact_fn}" | awk '/"\$\{runtime\}" run --rm/,/tar -C/ { print }')"
grep -Fq -- '"${tar_repro[@]}"' <<<"${fallback_argv}" \
  || fail "root-owned container fallback does not reuse the ownership-preserving tar argument array"
grep -Eq -- '--owner(=|[[:space:]])0|--group(=|[[:space:]])0' <<<"${fallback_argv}" \
  && fail "root-owned container fallback flattens numeric ownership"

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

# The suite under test comes from the ONE mapping, never a literal: a frozen
# suite here would keep passing after a release bump while the shipped writer
# emitted a different one.
RELEASE="${RELEASE}"
APT_SUITE="${APT_SUITE}"
APT_SUITE_UPDATES="${APT_SUITE_UPDATES}"
APT_SUITE_SECURITY="${APT_SUITE_SECURITY}"

# Seed the exact stray the fix must remove: mkosi's release-named bootstrap source,
# duplicating the Debian archive that debian.sources also configures.
cat >"/etc/apt/sources.list.d/\${RELEASE}.sources" <<STRAY
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: \${RELEASE}
Components: main main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
STRAY

log() { :; }
eval "\$(awk '/^configure_minimal_apt\(\) \{/,/^}/' "${POSTINST}")"
configure_minimal_apt

[ ! -e "/etc/apt/sources.list.d/\${RELEASE}.sources" ] || { echo "FAIL: configure_minimal_apt left the mkosi release-named dupe (\${RELEASE}.sources) behind"; exit 1; }
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
