#!/usr/bin/env bash
# Build-only Debian cache remap for the runtime postinst. Nothing is written
# under /etc: the remapped source lives in a /tmp dir apt sees only through the
# exported APT_CONFIG, so the shipped debian.sources stays byte-identical.

runtime_build_apt_cleanup() {
  [[ -n "${CERALIVE_BUILD_APT_DIR:-}" ]] || return 0
  rm -rf "${CERALIVE_BUILD_APT_DIR}"
}

runtime_build_apt_prepare_usr() {
  local mode
  mode="$(stat -c %a /usr)" || return 1
  if [[ "${mode}" != 755 ]]; then
    log "restoring /usr traversal (mode ${mode} -> 0755) before sandboxed apt verification"
    chmod 0755 /usr || return 1
  fi
  if ! runuser -u _apt -- /usr/bin/true; then
    log "FATAL: _apt still cannot execute through /usr after restoring its mode"
    return 1
  fi
}

runtime_build_apt_signature_diagnostics() {
  log "Debian signature failure: inspecting the runtime chroot's archive keyring and verifier"
  date -u
  umask
  stat -Lc 'keyring: %a %u:%g %s %n' /usr/share/keyrings/debian-archive-keyring.gpg
  stat -c 'sqv: %a %u:%g %s %n' /usr/bin/sqv
  stat -c 'build-only source: %a %u:%g %s %n' "${CERALIVE_BUILD_APT_DIR}/sources/debian.sources"
  stat -Lc 'executable ancestor: %a %u:%g %n' / /usr /usr/bin /lib /usr/lib /usr/lib/aarch64-linux-gnu
  if stat -Lc 'apt lists: %a %u:%g %n' /var/lib/apt /var/lib/apt/lists /var/lib/apt/lists/partial; then
    :
  else
    log "apt lists path unavailable at signature failure"
  fi
  if runuser -u _apt -- /usr/bin/true; then
    log "_apt /usr/bin/true: exit 0"
  else
    log "_apt /usr/bin/true: exit $?"
  fi
  local index="/tmp/ceralive-sqv-probe.$$.InRelease" rc=0
  log "probing sqv directly as root and _apt in the failing runtime sandbox"
  if /usr/bin/sqv --version 2>&1; then
    log "root sqv --version: exit 0"
  else
    rc=$?; log "root sqv --version: exit ${rc}"
  fi
  if runuser -u _apt -- /usr/bin/sqv --version 2>&1; then
    log "_apt sqv --version: exit 0"
  else
    rc=$?; log "_apt sqv --version: exit ${rc}"
  fi
  if /usr/lib/apt/apt-helper download-file \
    "${CERALIVE_BUILD_APT_PROXY}/HTTPS///deb.debian.org/debian/dists/${APT_SUITE}/InRelease" \
    "${index}" 2>&1; then
    chmod 0644 "${index}"
    stat -c 'acquired InRelease: %a %u:%g %s %n' "${index}"
    local user output
    for user in root _apt; do
      output="/tmp/ceralive-sqv-probe.$$.${user}.verified"
      if [[ "${user}" == root ]]; then
        if /usr/bin/sqv --keyring /usr/share/keyrings/debian-archive-keyring.gpg \
          --cleartext --output "${output}" --verbose "${index}" 2>&1; then
          log "root direct sqv verification: exit 0"
        else
          rc=$?; log "root direct sqv verification: exit ${rc}"
        fi
      elif runuser -u _apt -- /usr/bin/sqv \
        --keyring /usr/share/keyrings/debian-archive-keyring.gpg \
        --cleartext --output "${output}" --verbose "${index}" 2>&1; then
        log "_apt direct sqv verification: exit 0"
      else
        rc=$?; log "_apt direct sqv verification: exit ${rc}"
      fi
      rm -f -- "${output}"
    done
    rm -f -- "${index}"
  else
    rc=$?; log "apt-helper could not acquire diagnostic InRelease: exit ${rc}"
    rm -f -- "${index}"
  fi
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
