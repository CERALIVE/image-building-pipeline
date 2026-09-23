#!/usr/bin/env bash

runtime_debian_apt_install() {
  local proxy="${CERALIVE_BUILD_APT_PROXY:-}" source_dir=''
  local -a scope=()
  if [[ -n "${proxy}" ]]; then
    [[ "${proxy}" =~ ^http://[a-zA-Z0-9.:-]+(:[0-9]+)?$ ]] || {
      log "FATAL: invalid build-only APT cache URL"; return 1;
    }
    source_dir="$(mktemp -d /tmp/ceralive-build-apt.XXXXXX)"
    sed "s|https://deb.debian.org/|${proxy}/HTTPS///deb.debian.org/|g" \
      /etc/apt/sources.list.d/debian.sources >"${source_dir}/debian.sources"
    scope=(-o 'Dir::Etc::sourcelist=/dev/null' -o "Dir::Etc::sourceparts=${source_dir}")
    log "runtime Debian downloads use build-only HTTPS/// cache remap (${proxy}); shipped debian.sources unchanged"
  fi
  if ! retry_apt "runtime apt-get update" apt-get "${scope[@]}" update \
    || ! retry_apt "runtime apt-get install" apt-get "${scope[@]}" install -y --no-install-recommends "$@"; then
    [[ -z "${source_dir}" ]] || rm -rf "${source_dir}"
    return 1
  fi
  [[ -z "${source_dir}" ]] || rm -rf "${source_dir}"
}
