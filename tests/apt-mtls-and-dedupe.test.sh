#!/usr/bin/env bash
#
# apt-mtls-and-dedupe.test.sh — guard the two on-device apt regressions this fix
# repairs, against the functions the REAL build runs (not only the customize twin):
#
#   1. Device mTLS key comes from the app-layer credentials package, not the
#      build-time APT_CLIENT_* secrets. Its postinst gives the key to `_apt`.
#   2. Duplicate Debian source. mkosi's release-named bootstrap source
#      (`${RELEASE}.sources`) leaks into the rootfs alongside our debian.sources, so
#      apt warns "Target Packages … is configured multiple times". configure_minimal_apt
#      must leave EXACTLY ONE Debian source (debian.sources).
#   3. ceralive.sources repo URI. apt-worker serves the first-party repo at
#      dists/<channel>/binary-<arch>/ (confirmed 200); a bare dists/<channel>/ 404s the
#      Release file. The URI MUST be arch-qualified (…/binary-<arch>/), matching the
#      known-working fetch-debs.sh `fetch_first_party` and the customize module.
#   4. Per-slot apt storage. The active rootfs slot is not an apt-cache bind, so its
#      generated config must suppress undisplayable translations and retain indexes
#      compressed. Both configure_minimal_apt twins must render the same payload.
#   5. Rock 2026-09-09: IPv6 HTTP returned a Tigo captive 302, then apt rejected
#      NOSPLIT/NODATA. Device sources require TLS as well as the existing Signed-By.
#
# THE GAP THIS CLOSES (same lesson as apt-preferences-baked.test.sh): `./build`
# runs mkosi.images/runtime/mkosi.postinst.chroot, NOT customize/apt-ceralive-repo.sh.
# A guard that only exercises the customize twin can stay green while the shipped
# image regresses — so Part A targets BOTH tracks and Part B runs the REAL executor's
# configure_minimal_apt against a scratch chroot filesystem.
#
# NEVER prints key material: Part B seeds only a synthetic Debian source; the mTLS
# key path is asserted statically (Part A); the synthetic payload tests only
# numeric ownership preservation and never reads a real credential.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
POSTINST="${PIPELINE_DIR}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
MODULE="${PIPELINE_DIR}/mkosi/customize/apt-ceralive-repo.sh"
TAR_EMIT="${PIPELINE_DIR}/lib/stages/tar-emit.sh"
BUNDLE_BUILDER="${PIPELINE_DIR}/lib/build-bundle.sh"
SLOT_IMAGE="${PIPELINE_DIR}/lib/disk/slot-image.sh"
FACTORY_SLOT="${PIPELINE_DIR}/lib/disk/slot.sh"

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
[[ -f "${SLOT_IMAGE}" ]] || fail "missing shared ext4 slot writer: ${SLOT_IMAGE}"
[[ -f "${FACTORY_SLOT}" ]] || fail "missing factory slot writer: ${FACTORY_SLOT}"

extract_fn() { # <name> <file>
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { f=1 }
    f { print }
    f && /^\}/ { exit }
  ' "$2"
}

post_repo="$(extract_fn setup_ceralive_repository "${POSTINST}")"
post_minapt="$(extract_fn configure_minimal_apt "${POSTINST}")"
mod_minapt="$(extract_fn configure_minimal_apt "${MODULE}")"
mod_src="$(extract_fn configure_ceralive_source "${MODULE}")"
[[ -n "${post_repo}" && -n "${post_minapt}" ]] || fail "could not extract runtime apt functions from ${POSTINST}"
[[ -n "${mod_minapt}" && -n "${mod_src}" ]] || fail "could not extract customize apt functions from ${MODULE}"

# ---------------------------------------------------------------------------
# Part A — static contract (always enforced)
# ---------------------------------------------------------------------------

# 1. Neither on-device writer decodes CI's build-only mTLS key. The packaged
# key still needs its numeric _apt ownership preserved across tar and ext4.
if grep -Eq 'APT_CLIENT_(CRT|KEY)_B64|/etc/apt/certs/client\.(crt|key)|install_mtls_cert' <<<"${post_repo}"; then
  fail 'runtime writer still bakes a CI client credential into the device'
fi
if grep -v '^[[:space:]]*#' "${MODULE}" | grep -Eq 'APT_CLIENT_(CRT|KEY)_B64|/etc/apt/certs/client\.(crt|key)|install_mtls_cert'; then
  fail 'customize writer still bakes a CI client credential into the device'
fi
grep -Fq 'ceralive-apt-credentials' "${PIPELINE_DIR}/mkosi/mkosi.images/app/mkosi.postinst.chroot" \
  || fail 'app layer does not install the credentials package'

# The normalized tar is the parity artifact. Factory and verity OTA both build
# ext4 from the tree through the shared writer; verify ownership in that image.
grep -Eq -- '--owner(=|[[:space:]])0|--group(=|[[:space:]])0' "${TAR_EMIT}" \
  && fail "rootfs tar emitter flattens ownership to root — client.key loses uid 42 in the RAUC payload"
grep -Eq -- '--numeric-owner' "${TAR_EMIT}" \
  || fail "rootfs tar emitter must preserve numeric uid/gid metadata without name remapping"
emit_artifact_fn="$(extract_fn emit_artifact "${TAR_EMIT}")"
[[ -n "${emit_artifact_fn}" ]] || fail "could not extract emit_artifact() from ${TAR_EMIT}"
grep -Fqx 'source "${HERE}/disk/slot-image.sh"' "${BUNDLE_BUILDER}" \
  || fail "verity bundle no longer sources the shared slot-image producer"
grep -Fqx 'source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/slot-image.sh"' "${FACTORY_SLOT}" \
  || fail "factory slot no longer sources the same slot-image producer"
bundle_build="$(extract_fn build-bundle "${BUNDLE_BUILDER}")"
factory_build="$(extract_fn populate_rootfs_slot "${FACTORY_SLOT}")"
[[ -n "${bundle_build}" && -n "${factory_build}" ]] || fail 'could not extract the two slot-image callers'
grep -Fq 'SLOT_IMAGE_LABEL=rootfs make_slot_image "${rootfs_tree}" "${content}/rootfs.ext4"' <<<"${bundle_build}" \
  || fail 'verity bundle no longer passes its rootfs tree to the shared slot-image producer'
grep -Fq 'SLOT_IMAGE_LABEL="${slot_label}" make_slot_image "${rootfs_tree}" "${rootfs_img}"' <<<"${factory_build}" \
  || fail 'factory no longer passes its rootfs tree to the shared slot-image producer'
slot_writer="$(extract_fn make_slot_image "${SLOT_IMAGE}")"
[[ -n "${slot_writer}" ]] || fail "could not extract make_slot_image() from ${SLOT_IMAGE}"
grep -Fq -- '-d "${tree}" "${out}"' <<<"${slot_writer}" \
  || fail 'shared producer no longer populates ext4 from the rootfs tree'

require_cmd() { command -v "$1" >/dev/null || fail "missing required command: $1"; }
# shellcheck source=../lib/disk/slot-image.sh
source "${SLOT_IMAGE}"
command -v debugfs >/dev/null || fail 'debugfs is required to inspect ext4 ownership'
ext4_owner_is() { # <image> <path> <mode> <uid> <gid>
  local metadata
  metadata="$(debugfs -R "stat $2" "$1" 2>/dev/null)" || return 1
  [[ "${metadata}" =~ Mode:[[:space:]]*"$3"([[:space:]]|$) ]] &&
    [[ "${metadata}" =~ User:[[:space:]]*"$4"[[:space:]]+Group:[[:space:]]*"$5"([[:space:]]|$) ]]
}

ownership_repro="$(mktemp -d)"
cleanup_ownership_repro() {
  if [[ -d "${ownership_repro}/exact-rootfs" && "${EUID}" != 0 ]]; then
    sudo -n rm -rf "${ownership_repro}"
  else
    rm -rf "${ownership_repro}"
  fi
}
trap cleanup_ownership_repro EXIT
mkdir -p "${ownership_repro}/rootfs/usr/share/ceralive/apt-credentials"
install -m 0400 /dev/null "${ownership_repro}/rootfs/usr/share/ceralive/apt-credentials/client.key"
chmod 0750 "${ownership_repro}/rootfs/usr/share/ceralive/apt-credentials"
(
  export SOURCE_DATE_EPOCH=0
  eval "${emit_artifact_fn}"
  emit_artifact "${ownership_repro}/rootfs" "${ownership_repro}/normalized.tar"
)
expected_owner="$(id -u)/$(id -g)"
normalized_key_meta="$(tar --numeric-owner -tvf "${ownership_repro}/normalized.tar" ./usr/share/ceralive/apt-credentials/client.key | awk '{print $1, $2}')"
normalized_dir_meta="$(tar --numeric-owner --no-recursion -tvf "${ownership_repro}/normalized.tar" ./usr/share/ceralive/apt-credentials/ | awk '{print $1, $2}')"
[[ "${normalized_key_meta}" == "-r-------- ${expected_owner}" ]] \
  || fail "normalized rootfs tar changed client.key metadata; expected '-r-------- ${expected_owner}', got '${normalized_key_meta}'"
[[ "${normalized_dir_meta}" == "drwxr-x--- ${expected_owner}" ]] \
  || fail "normalized rootfs tar changed certs directory metadata; expected 'drwxr-x--- ${expected_owner}', got '${normalized_dir_meta}'"
SLOT_IMAGE_LABEL=rootfs make_slot_image "${ownership_repro}/rootfs" "${ownership_repro}/rootfs.ext4" >/dev/null \
  || fail 'shared producer failed to populate the ext4 fixture'
ext4_owner_is "${ownership_repro}/rootfs.ext4" /usr/share/ceralive/apt-credentials/client.key 0400 "$(id -u)" "$(id -g)" \
  || fail 'verity/factory ext4 image changed client.key owner or mode'
ext4_owner_is "${ownership_repro}/rootfs.ext4" /usr/share/ceralive/apt-credentials 0750 "$(id -u)" "$(id -g)" \
  || fail 'verity/factory ext4 image changed certs directory owner or mode'
# Mutate the produced image itself: this check must reject a key restored as
# world-readable rather than certifying an image solely from its source tree.
debugfs -w -R 'set_inode_field /usr/share/ceralive/apt-credentials/client.key mode 0644' "${ownership_repro}/rootfs.ext4" >/dev/null 2>&1 \
  || fail 'could not inject ext4 key-mode mutation'
ext4_owner_is "${ownership_repro}/rootfs.ext4" /usr/share/ceralive/apt-credentials/client.key 0400 "$(id -u)" "$(id -g)" \
  && fail 'world-readable ext4 client.key mutation escaped the ownership assertion'
echo 'apt-mtls-and-dedupe: world-readable ext4 client.key mutation RED'

if [[ "${EUID}" == 0 ]] || sudo -n true 2>/dev/null; then
  ownership_helper="${ownership_repro}/exercise-ownership-producers.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    declare -f fail require_cmd
    printf '%s\n' "${emit_artifact_fn}"
    printf '%s\n' 'export SOURCE_DATE_EPOCH=0' 'emit_artifact "$1" "$2"'
    printf 'source %q\n' "${SLOT_IMAGE}"
    printf '%s\n' 'SLOT_IMAGE_LABEL=rootfs make_slot_image "$1" "$3" >/dev/null'
  } >"${ownership_helper}"
  chmod 0755 "${ownership_helper}"
  if [[ "${EUID}" == 0 ]]; then
    install -d -o 42 -g 0 -m 0750 "${ownership_repro}/exact-rootfs/usr/share/ceralive/apt-credentials"
    install -o 42 -g 0 -m 0400 /dev/null "${ownership_repro}/exact-rootfs/usr/share/ceralive/apt-credentials/client.key"
    "${ownership_helper}" "${ownership_repro}/exact-rootfs" "${ownership_repro}/exact-normalized.tar" "${ownership_repro}/exact-rootfs.ext4"
  else
    sudo -n install -d -o 42 -g 0 -m 0750 "${ownership_repro}/exact-rootfs/usr/share/ceralive/apt-credentials"
    sudo -n install -o 42 -g 0 -m 0400 /dev/null "${ownership_repro}/exact-rootfs/usr/share/ceralive/apt-credentials/client.key"
    sudo -n "${ownership_helper}" "${ownership_repro}/exact-rootfs" "${ownership_repro}/exact-normalized.tar" "${ownership_repro}/exact-rootfs.ext4"
  fi
  exact_key_meta="$(tar --numeric-owner -tvf "${ownership_repro}/exact-normalized.tar" ./usr/share/ceralive/apt-credentials/client.key | awk '{print $1, $2}')"
  exact_dir_meta="$(tar --numeric-owner --no-recursion -tvf "${ownership_repro}/exact-normalized.tar" ./usr/share/ceralive/apt-credentials/ | awk '{print $1, $2}')"
  [[ "${exact_key_meta}" == '-r-------- 42/0' ]] || fail 'normalized tar lost _apt key ownership'
  [[ "${exact_dir_meta}" == 'drwxr-x--- 42/0' ]] || fail 'normalized tar lost _apt certs directory ownership'
  ext4_owner_is "${ownership_repro}/exact-rootfs.ext4" /usr/share/ceralive/apt-credentials/client.key 0400 42 0 \
    || fail 'ext4 image lost _apt key ownership'
  ext4_owner_is "${ownership_repro}/exact-rootfs.ext4" /usr/share/ceralive/apt-credentials 0750 42 0 \
    || fail 'ext4 image lost _apt certs directory ownership'
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

for source_name in runtime customize; do
  case "${source_name}" in
    runtime) apt_writer="${post_minapt}" ;;
    customize) apt_writer="${mod_minapt}" ;;
  esac
  for directive in \
    'Acquire::Languages "none";' \
    'Acquire::GzipIndexes "true";' \
    'Acquire::CompressionTypes::Order "gz";'; do
    grep -Fqx "    printf '${directive}\\n'" <<<"${apt_writer}" \
      || fail "${source_name} configure_minimal_apt() no longer emits ${directive} into 99ceralive"
  done
done

echo "apt-mtls-and-dedupe: Part A static contract OK (no baked key; packaged key ownership preserved; single Debian source + arch-qualified repo URI + slot-safe apt config)"

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

mkdir -p /tmp/apt-runtime
cp /etc/apt/apt.conf.d/99ceralive /tmp/apt-runtime/99ceralive
cp /etc/apt/sources.list.d/debian.sources /tmp/apt-runtime/debian.sources

# The customize module has broader setup context, so compare only the generated
# payloads rather than function text. Its suite resolver is the production contract.
resolve_target_suites() {
  APT_RELEASE="\${RELEASE}"
  APT_SUITE_MAIN="\${APT_SUITE}"
  APT_SUITE_UPD="\${APT_SUITE_UPDATES}"
  APT_SUITE_SEC="\${APT_SUITE_SECURITY}"
}
log_info() { :; }
eval "\$(awk '/^configure_minimal_apt\(\) \{/,/^}/' "${MODULE}")"
configure_minimal_apt

cmp -s /tmp/apt-runtime/99ceralive /etc/apt/apt.conf.d/99ceralive \
  || { echo "FAIL: runtime and customize configure_minimal_apt payloads differ for 99ceralive"; exit 1; }
cmp -s /tmp/apt-runtime/debian.sources /etc/apt/sources.list.d/debian.sources \
  || { echo "FAIL: runtime and customize configure_minimal_apt payloads differ for debian.sources"; exit 1; }

cat >/tmp/expected-debian.sources <<EXPECTED_SOURCES
Types: deb
URIs: https://deb.debian.org/debian
Suites: \${APT_SUITE}
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://deb.debian.org/debian-security
Suites: \${APT_SUITE_SECURITY}
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://deb.debian.org/debian
Suites: \${APT_SUITE_UPDATES}
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EXPECTED_SOURCES
cmp -s /tmp/expected-debian.sources /etc/apt/sources.list.d/debian.sources \
  || { echo "FAIL: configure_minimal_apt changed one of the three Debian sources"; exit 1; }

grep -Fqx 'APT::Install-Recommends "false";' /etc/apt/apt.conf.d/99ceralive \
  || { echo "FAIL: configure_minimal_apt changed APT::Install-Recommends"; exit 1; }
grep -Fqx 'DPkg::Options { "--force-confdef"; "--force-confold"; };' /etc/apt/apt.conf.d/99ceralive \
  || { echo "FAIL: configure_minimal_apt changed DPkg::Options"; exit 1; }
REPRO_EOF

if unshare -rm --map-root-user bash "${REPRO}"; then
  echo "apt-mtls-and-dedupe: Part B runtime OK (both configure_minimal_apt twins agree on apt payloads and preserve the three Debian sources)"
else
  fail "the real configure_minimal_apt() did not dedupe to a single Debian source"
fi

echo "apt-mtls-and-dedupe regression: PASS"
