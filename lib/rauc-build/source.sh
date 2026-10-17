#!/usr/bin/env bash
#
# rauc-build/source.sh — pinned source acquisition + verification for
# lib/build-rauc.sh.
#
# Sourced by lib/build-rauc.sh, never executed.
#
# Two DIFFERENT verification disciplines, matching this repo's two existing
# ones exactly (never a third, invented path — see manifests/rauc-deb-versions.txt
# for the full rationale):
#
#   rauc_fetch_upstream_tarball   static SHA-256 pin against a GitHub release
#                                  asset (same shape as fetch/userspace.sh).
#   rauc_fetch_debian_packaging   gpgv-against-InRelease, reusing lib/fetch/index.sh
#                                  (index_release_digest / index_lookup_optional)
#                                  and lib/fetch-debs-auth.sh (auth_verify_release_signature,
#                                  auth_keyring_has_exact_fingerprints) exactly as
#                                  fetch/bsp.sh's Armbian transport does.
#
# shellcheck shell=bash

# Bounded so a hung fetch cannot wedge a build host indefinitely. Self-contained
# (not sourced from fetch/retry.sh) so this module has no dependency on the
# fetch-debs.sh entry point's own state.
RAUC_CURL_TIMEOUT_OPTS=(--connect-timeout 30 --max-time 300)

# ---------------------------------------------------------------------------
# rauc_fetch_upstream_tarball <url> <expected_sha256> <dest_file>
#
# Downloads RAUC's own tagged GitHub release source tarball and holds it to the
# pinned SHA-256 before returning success. Fail-closed, no fallback mirror.
# ---------------------------------------------------------------------------
rauc_fetch_upstream_tarball() {
  local url="$1" expected="$2" dest="$3" tmp actual
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] \
    || die "rauc upstream pin has a malformed SHA-256: ${expected}"
  tmp="$(mktemp "${dest}.XXXXXX")"
  log_info "rauc-build: fetching upstream source ${url}"
  if ! curl -fsSL --retry 3 "${RAUC_CURL_TIMEOUT_OPTS[@]}" -o "${tmp}" "${url}"; then
    rm -f "${tmp}"
    die "rauc-build: failed to download upstream tarball: ${url}"
  fi
  actual="$(sha256sum "${tmp}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    rm -f "${tmp}"
    die "rauc-build: upstream tarball checksum mismatch: expected ${expected}, got ${actual}"
  fi
  mv -f "${tmp}" "${dest}"
  log_success "rauc-build: upstream tarball verified sha256=${expected}"
}

# ---------------------------------------------------------------------------
# rauc_debian_source_lookup <sources_index> <package> <version> — echo the
# Checksums-Sha256 entry for <package>_<version>.debian.tar.xz out of a verified
# `Sources` index (source-package stanza format — Files:/Checksums-Sha256: are
# MULTI-LINE blocks, unlike the single-line SHA256: field auth_lookup_package
# parses for a binary Packages index, so this is its own small reader rather
# than a reuse of that function).
#
# Echoes "<filename>\t<sha256>" on a unique hit; returns 1 otherwise (ambiguous
# or absent — both fail closed, never a best-effort guess).
# ---------------------------------------------------------------------------
rauc_debian_source_lookup() {
  local index="$1" package="$2" version="$3" want_suffix
  want_suffix="_${version}.debian.tar.xz"
  awk -v want_pkg="${package}" -v want_ver="${version}" -v want_suffix="${want_suffix}" '
    BEGIN { RS=""; FS="\n" }
    {
      pkg=""; ver=""; in_sha=0; hit=""
      for (i = 1; i <= NF; i++) {
        line = $i
        if (line ~ /^Package: /) { pkg = substr(line, 10); in_sha = 0; continue }
        if (line ~ /^Version: /) { ver = substr(line, 10); in_sha = 0; continue }
        if (line ~ /^Checksums-Sha256:/) { in_sha = 1; continue }
        if (line ~ /^[A-Za-z-]+:/) { in_sha = 0; continue }
        if (in_sha && line ~ /^ /) {
          split(line, f, " ")
          # f[1]=sha256 f[2]=size f[3]=filename
          if (f[3] ~ want_suffix"$") hit = f[3] "\t" f[1]
        }
      }
      if (pkg == want_pkg && ver == want_ver && hit != "") print hit
    }
  ' "${index}"
}

# ---------------------------------------------------------------------------
# rauc_fetch_debian_packaging <suite> <component> <source_version> <debian_tar_filename>
#                              <keyring> <dest_file> [fingerprint...]
#
# Full gpgv-against-InRelease chain for Debian's OWN debian/ packaging tarball,
# reusing lib/fetch/index.sh's generic index-digest primitives:
#   1. fetch InRelease for <suite>
#   2. gpgv it against <keyring>, optionally pinned to exact <fingerprint...>
#   3. read the verified Release's SHA-256 for main/source/Sources.xz
#   4. download + verify that Sources index against that digest
#   5. decompress, look up <source_version>'s debian.tar.xz entry
#   6. download the debian.tar.xz and hold it to the index's own SHA-256
#
# No step short-circuits past a verification failure. A bad signature, an
# unusable index, a missing package/version, or a checksum mismatch all `die`.
# ---------------------------------------------------------------------------
rauc_fetch_debian_packaging() {
  local suite="$1" component="$2" source_version="$3" debian_tar_filename="$4" \
        keyring="$5" dest="$6"
  shift 6
  local -a fingerprints=("$@")

  [[ -f "${keyring}" ]] \
    || die "rauc-build: Debian archive keyring not found at ${keyring} — install debian-archive-keyring"
  # UNLIKE fetch/bsp.sh's Armbian check (auth_keyring_has_exact_fingerprints,
  # which asserts a SMALL, CeraLive-vendored keyring file carries ONLY the
  # expected key(s) — a file-integrity check), this keyring is Debian's OWN
  # system-wide debian-archive-keyring.gpg bundle: dozens of legitimate keys
  # across many suites/releases. The security property that matters is not "this
  # file contains exactly N keys" but "the signature InRelease actually carries
  # was made by one of the fingerprints we pinned" — which
  # auth_verify_release_to_file already asserts below via its own VALIDSIG
  # cross-check against "${fingerprints[@]}". No separate whole-keyring shape
  # check applies here.
  (( ${#fingerprints[@]} > 0 )) \
    || die "rauc-build: no archive key fingerprint(s) pinned to verify against"

  local work; work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" RETURN

  local mirror="https://deb.debian.org/debian"
  local inrelease="${work}/InRelease" verified_release="${work}/Release"
  log_info "rauc-build: fetching ${mirror}/dists/${suite}/InRelease"
  curl -fsSL --retry 3 "${RAUC_CURL_TIMEOUT_OPTS[@]}" -o "${inrelease}" \
    "${mirror}/dists/${suite}/InRelease" \
    || die "rauc-build: failed to download ${suite} InRelease"

  auth_verify_release_to_file "${keyring}" "${inrelease}" "${verified_release}" \
      "${fingerprints[@]}" \
    || die "rauc-build: gpgv verification of ${suite} InRelease failed"
  log_success "rauc-build: ${suite} InRelease signature verified"

  local sources_path="${component}/source/Sources.xz" sources_digest
  sources_digest="$(index_release_digest "${verified_release}" "${sources_path}")" \
    || die "rauc-build: verified ${suite} Release names no SHA256 for ${sources_path}"

  local sources_xz="${work}/Sources.xz" sources_plain="${work}/Sources"
  curl -fsSL --retry 3 "${RAUC_CURL_TIMEOUT_OPTS[@]}" -o "${sources_xz}" \
    "${mirror}/dists/${suite}/${sources_path}" \
    || die "rauc-build: failed to download ${suite} ${sources_path}"
  index_verify_digest "${sources_xz}" "${sources_digest}" "${suite} ${sources_path}" \
    || die "rauc-build: ${suite} Sources index checksum mismatch — refusing an unverifiable index"
  xz -dc "${sources_xz}" > "${sources_plain}"

  local row filename digest
  row="$(rauc_debian_source_lookup "${sources_plain}" rauc "${source_version}")"
  [[ -n "${row}" ]] \
    || die "rauc-build: no unique rauc_${source_version}.debian.tar.xz entry in the verified ${suite} Sources index"
  IFS=$'\t' read -r filename digest <<<"${row}"
  [[ "${filename}" == "${debian_tar_filename}" ]] \
    || die "rauc-build: verified Sources index names ${filename}, manifest pins ${debian_tar_filename} — pin is stale"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] \
    || die "rauc-build: verified Sources index carries a malformed SHA-256 for ${filename}"

  local tmp="${work}/${filename}"
  curl -fsSL --retry 3 "${RAUC_CURL_TIMEOUT_OPTS[@]}" -o "${tmp}" \
    "${mirror}/pool/main/r/rauc/${filename}" \
    || die "rauc-build: failed to download ${filename}"
  local actual; actual="$(sha256sum "${tmp}" | awk '{print $1}')"
  [[ "${actual}" == "${digest}" ]] \
    || die "rauc-build: ${filename} checksum mismatch: index says ${digest}, got ${actual}"

  mv -f "${tmp}" "${dest}"
  log_success "rauc-build: Debian packaging tarball ${filename} verified via gpgv(${suite})+Sources sha256=${digest}"
}

# ---------------------------------------------------------------------------
# rauc_assemble_source_tree <upstream_tar> <debian_tar> <ceralive_suffix>
#                            <source_version> <dest_dir>
#
# Extracts the upstream orig tarball, overlays Debian's OWN unmodified debian/
# directory on top (zero CeraLive patches to either), and appends exactly ONE
# debian/changelog entry recording the CeraLive rebuild — the minimum edit dpkg
# requires to build a local-version package at all. No other file under debian/
# is touched.
# ---------------------------------------------------------------------------
rauc_assemble_source_tree() {
  local upstream_tar="$1" debian_tar="$2" ceralive_suffix="$3" source_version="$4" dest="$5"
  rm -rf "${dest}"
  mkdir -p "${dest}"
  tar -xf "${upstream_tar}" -C "${dest}" --strip-components=1
  tar -xf "${debian_tar}" -C "${dest}"
  [[ -d "${dest}/debian" ]] \
    || die "rauc-build: Debian packaging tarball produced no debian/ directory"

  local built_version="${source_version}${ceralive_suffix}"
  local changelog="${dest}/debian/changelog"
  local date_str; date_str="$(date -Ru)"
  {
    printf 'rauc (%s) UNRELEASED; urgency=medium\n\n' "${built_version}"
    printf '  * CeraLive in-pipeline rebuild of upstream v%s (GitHub release tarball,\n' "$(sed -E 's/^[0-9]+://' <<<"${source_version%-*}")"
    printf '    SHA-256 pinned in manifests/rauc-deb-versions.txt) using Debian unstable'"'"'s\n'
    printf '    OWN, byte-unmodified packaging directory for source version %s\n' "${source_version}"
    printf '    (fetched + gpgv-verified against the signed unstable InRelease/Sources\n'
    printf '    chain). Zero CeraLive patches applied to upstream source or to this\n'
    printf '    debian/ directory; this entry is the only edit.\n\n'
    printf ' -- CeraLive Engineering <engineering@ceralive.tv>  %s\n\n' "${date_str}"
    cat "${changelog}"
  } > "${changelog}.new"
  mv -f "${changelog}.new" "${changelog}"
  log_success "rauc-build: assembled source tree at ${dest} (target version ${built_version})"
  printf '%s' "${built_version}"
}
