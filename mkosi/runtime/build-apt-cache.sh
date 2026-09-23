#!/usr/bin/env bash
# Build-only Debian cache remap for the runtime postinst. Nothing is written
# under /etc: the remapped source lives in a /tmp dir apt sees only through the
# exported APT_CONFIG, so the shipped debian.sources stays byte-identical.

runtime_build_apt_cleanup() {
  [[ -n "${CERALIVE_BUILD_APT_DIR:-}" ]] || return 0
  rm -rf "${CERALIVE_BUILD_APT_DIR}"
}

runtime_build_apt_signature_diagnostics() {
  log "Debian signature failure: inspecting the runtime chroot's archive keyring and verifier"
  date -u
  stat -Lc 'keyring: %a %u:%g %s %n' /usr/share/keyrings/debian-archive-keyring.gpg
  stat -c 'sqv: %a %u:%g %s %n' /usr/bin/sqv
  stat -c 'build-only source: %a %u:%g %s %n' "${CERALIVE_BUILD_APT_DIR}/sources/debian.sources"
  log "replaying apt update with signature-verifier debug (verification still enforced)"
  if apt-get -o Debug::Acquire::gpgv=true update 2>&1; then
    log "signature-verifier diagnostic replay succeeded"
  else
    log "signature-verifier diagnostic replay failed"
  fi
}

# The remap stays active for the REST of the layer, not only the shared.list
# transaction: apt reads only lists that match its configured sources, so
# switching back would leave later in-layer installs (the staged hawkbit .deb
# resolves its deps from them) with no Debian index at all when the cache is on.
runtime_build_apt_scope() {
  local proxy="${CERALIVE_BUILD_APT_PROXY:-}"
  local shipped="${CERALIVE_BUILD_APT_SHIPPED_SOURCES:-/etc/apt/sources.list.d/debian.sources}"
  [[ -n "${proxy}" && -z "${CERALIVE_BUILD_APT_DIR:-}" ]] || return 0
  [[ "${proxy}" =~ ^http://[a-zA-Z0-9.:-]+(:[0-9]+)?$ ]] || {
    log "FATAL: invalid build-only APT cache URL"; return 1;
  }
  CERALIVE_BUILD_APT_DIR="$(mktemp -d /tmp/ceralive-build-apt.XXXXXX)"
  trap runtime_build_apt_cleanup EXIT
  mkdir -p "${CERALIVE_BUILD_APT_DIR}/sources"
  sed "s|https://deb.debian.org/|${proxy}/HTTPS///deb.debian.org/|g" \
    "${shipped}" >"${CERALIVE_BUILD_APT_DIR}/sources/debian.sources"
  printf 'Dir::Etc::sourcelist "/dev/null";\nDir::Etc::sourceparts "%s";\n' \
    "${CERALIVE_BUILD_APT_DIR}/sources" >"${CERALIVE_BUILD_APT_DIR}/apt.conf"
  export APT_CONFIG="${CERALIVE_BUILD_APT_DIR}/apt.conf"
  log "runtime Debian downloads use build-only HTTPS/// cache remap (${proxy}); shipped debian.sources unchanged"
}

runtime_debian_apt_install() {
  runtime_build_apt_scope || return 1
  retry_apt "runtime apt-get update" apt-get update || return 1
  retry_apt "runtime apt-get install" apt-get install -y --no-install-recommends "$@"
}
