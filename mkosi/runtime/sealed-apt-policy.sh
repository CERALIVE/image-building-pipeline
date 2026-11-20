#!/usr/bin/env bash
# Shared build-only source policy for the mkosi sandbox and runtime chroot.

sealed_apt_sources() {
  local archive scheme_base="$1" suite
  # APT 3.0.3's deb822 parser silently ignores InRelease-Path; the .list
  # parser passes inrelease-path through and actually forbids detached fallback.
  local opts='arch=arm64 arch-=all by-hash=no pdiffs=no target=Packages inrelease-path=InRelease signed-by=/usr/share/keyrings/debian-archive-keyring.gpg'
  for suite in "${APT_SUITE:?}" "${APT_SUITE_UPDATES:?}" "${APT_SUITE_SECURITY:?}"; do
    archive=debian
    [[ "${suite}" != "${APT_SUITE_SECURITY}" ]] || archive=debian-security
    printf 'deb [%s] %s/%s %s main\n' "${opts}" "${scheme_base}" "${archive}" "${suite}"
  done
}

sealed_apt_config() {
  cat <<'EOF'
Acquire::Languages "none";
Acquire::http::AllowRedirect "false";
// The signed Releases advertise gzip for the base suite, but only xz
// (of these two) for updates and security. The mirror fails on any miss.
Acquire::IndexTargets::deb::Packages::CompressionTypes "gz xz";
APT::Update::Error-Mode "any";
EOF
}

sealed_apt_sandbox() {
  local apt_dir="$1/etc/apt"
  # Presence of mkosi.sources tells mkosi not to generate deb-src/debug entries.
  mkdir -p "${apt_dir}/"{apt.conf.d,sources.list.d} &&
    printf '# Sealed Debian sources are in ceralive-sealed.list.\n' >"${apt_dir}/sources.list.d/mkosi.sources" &&
    sealed_apt_sources http://deb.debian.org >"${apt_dir}/sources.list.d/ceralive-sealed.list" &&
    sealed_apt_config >"${apt_dir}/apt.conf.d/99-ceralive-sealed"
}
