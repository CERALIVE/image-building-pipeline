#!/usr/bin/env bash
#
# customize/apt-ceralive-repo.sh — minimal Debian apt sources + the CeraLive
# apt.ceralive.tv repository (mTLS client cert + GPG keyring).
#
# DECOMPOSED FROM: userpatches/customize-image.sh:configure_minimal_apt()
# (L53-88) and setup_ceraui_repository() (L91-141).
#
# SECRETS: the mTLS client cert/key and the GPG public key arrive ONLY through
# the environment (APT_CLIENT_CRT_B64 / APT_CLIENT_KEY_B64 / APT_GPG_PUBLIC_B64),
# base64-encoded. They are NEVER hardcoded and NEVER committed. CI injects them;
# a local/dev build without them installs the source + an empty keyring
# placeholder exactly as v1 did (L113-128) — a loud, explicit branch, not a
# silent skip.
#
# CONTRACT: sourced by run-all.sh (chroot context). Strict; no `|| true`. A
# partially-supplied mTLS pair (one of cert/key set, the other not) is a
# misconfiguration and is fatal via die().
#
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "${CERALIVE_COMMON_SH:-"$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"}"

# Distro suite + CeraLive channel. Defaults match v1 (RELEASE→bookworm via the
# build env, CHANNEL→stable, L132). These are configuration, not secrets.
APT_RELEASE="${RELEASE:-bookworm}"
APT_CHANNEL="${CHANNEL:-stable}"

# Write the three deb822 Debian sources (v1 L63-81) + non-interactive apt config.
configure_minimal_apt() {
  log_info "writing minimal deb822 Debian apt sources (suite=${APT_RELEASE})"
  mkdir -p /etc/apt/sources.list.d

  # Remove any build-time Debian sources that leak into the rootfs — mkosi's own
  # release-named bootstrap source (${APT_RELEASE}.sources) and any Armbian pool —
  # so the device ships EXACTLY ONE Debian source (debian.sources, written below).
  # A second file configuring the same targets makes apt-get update warn
  # "Target Packages … is configured multiple times".
  rm -f "/etc/apt/sources.list.d/${APT_RELEASE}.sources" \
        /etc/apt/sources.list.d/armbian.sources \
        /etc/apt/sources.list

  cat >/etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${APT_RELEASE}
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: ${APT_RELEASE}-security
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: ${APT_RELEASE}-updates
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

  printf 'APT::Install-Recommends "false";\n' >/etc/apt/apt.conf.d/99ceralive
  printf 'DPkg::Options { "--force-confdef"; "--force-confold"; };\n' >>/etc/apt/apt.conf.d/99ceralive
}

# Install the mTLS client certificate (CI mode). v1 L100-115.
install_mtls_cert() {
  local crt="${APT_CLIENT_CRT_B64:-}" key="${APT_CLIENT_KEY_B64:-}"

  # Reject a half-configured pair loudly — a build that thinks it is in CI mode
  # but is missing half the credential would silently produce an unusable repo.
  if [[ -n "${crt}" && -z "${key}" ]] || [[ -z "${crt}" && -n "${key}" ]]; then
    die "incomplete mTLS pair: set BOTH APT_CLIENT_CRT_B64 and APT_CLIENT_KEY_B64, or neither"
  fi

  if [[ -z "${crt}" ]]; then
    log_warn "no mTLS secrets in env — skipping client-cert injection (CI provides them)"
    return 0
  fi

  log_info "CI mode: installing apt.ceralive.tv mTLS client certificate"
  printf '%s' "${crt}" | base64 -d >/etc/apt/certs/client.crt
  printf '%s' "${key}" | base64 -d >/etc/apt/certs/client.key
  # apt's https fetcher runs as sandbox user `_apt`; a root:root 0600 key is unreadable there ("Could not load client certificate"). Hand the key to `_apt`, owner-read only.
  chown _apt:root /etc/apt/certs/client.key
  chmod 400 /etc/apt/certs/client.key
  chmod 644 /etc/apt/certs/client.crt
  cat >/etc/apt/apt.conf.d/99ceralive-ssl <<'SSLEOF'
Acquire::https::apt.ceralive.tv::SslCert "/etc/apt/certs/client.crt";
Acquire::https::apt.ceralive.tv::SslKey  "/etc/apt/certs/client.key";
SSLEOF
}

# Install the GPG public keyring used to verify apt.ceralive.tv packages.
# v1 L117-129 (env → file → placeholder).
install_gpg_keyring() {
  local keyring="${APT_KEYRING_FILE:-/usr/share/keyrings/ceralive-archive-keyring.gpg}"
  if [[ -n "${APT_GPG_PUBLIC_B64:-}" ]]; then
    log_info "installing CeraLive apt GPG public key from env"
    printf '%s' "${APT_GPG_PUBLIC_B64}" | base64 -d >"${keyring}"
  else
    log_warn "no GPG public key in env — installing empty placeholder (CI provides the real key)"
    : >"${keyring}"
  fi
  chmod 644 "${keyring}"
}

# Write the apt.ceralive.tv source (deb822). v1 L131-138.
configure_ceralive_source() {
  local dir="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
  log_info "configuring apt.ceralive.tv source (channel=${APT_CHANNEL})"
  mkdir -p "${dir}"
  cat >"${dir}/ceralive.sources" <<EOF
Types: deb
URIs: https://apt.ceralive.tv/dists/${APT_CHANNEL}/binary-$(dpkg --print-architecture)/
Suites: ./
Signed-By: /usr/share/keyrings/ceralive-archive-keyring.gpg
EOF
}

# Pin the apt.ceralive.tv origin so the device installs OUR first-party updates
# for the packages IT carries. Priority 990 sits just below apt's "always"
# (1000) and above the archive default (500), so a package the CeraLive origin
# actually publishes wins over any Debian copy of the same name. Pin-Priority
# only affects packages the pinned origin ACTUALLY offers, so the rest of the
# Debian archive keeps its normal 500 default — no shadowing of packages we do
# not carry. The libsrt coinstall model stays Provides/Conflicts/Replaces
# (orthogonal to this origin pin; this must not disturb it). E4: baked at build,
# never edited on-device.
install_apt_preferences() {
  local dir="${APT_PREFERENCES_DIR:-/etc/apt/preferences.d}"
  log_info "pinning apt.ceralive.tv origin (Pin-Priority 990)"
  mkdir -p "${dir}"
  cat >"${dir}/ceralive" <<'EOF'
Package: *
Pin: origin apt.ceralive.tv
Pin-Priority: 990
EOF
}

configure_apt_ceralive_repo() {
  mkdir -p /etc/opt/ceralive /etc/apt/certs /usr/share/keyrings
  configure_minimal_apt
  install_mtls_cert
  install_gpg_keyring
  configure_ceralive_source
  install_apt_preferences
  log_success "apt sources configured (Debian + apt.ceralive.tv:${APT_CHANNEL}, origin pinned 990)"
}

# Auto-run when sourced by run-all.sh (the chroot dispatcher). Unit tests set
# APT_CERALIVE_REPO_NO_AUTORUN=1 to source this module and exercise individual
# functions against scratch dirs (APT_*_DIR / APT_KEYRING_FILE) without executing
# the full chroot flow against the host's /etc/apt.
if [[ -z "${APT_CERALIVE_REPO_NO_AUTORUN:-}" ]]; then
  configure_apt_ceralive_repo "$@"
fi
