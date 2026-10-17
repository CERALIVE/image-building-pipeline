#!/usr/bin/env bash
# Profile-neutral host-side APT cache selection. Never source this on a device.

apt_proxy_url() {
  if [[ ${CERALIVE_APT_PROXY+x} ]]; then
    [[ -n "${CERALIVE_APT_PROXY}" && "${CERALIVE_APT_PROXY}" != off ]] \
      && printf '%s\n' "${CERALIVE_APT_PROXY}"
    return 0
  fi
  if command -v curl >/dev/null 2>&1 \
    && curl --noproxy '*' -sf --connect-timeout 1 --max-time 1 \
      http://127.0.0.1:3142/acng-report.html >/dev/null 2>&1; then
    printf '%s\n' 'http://127.0.0.1:3142'
  fi
}

apt_proxy_container_url() {
  local url
  url="$(apt_proxy_url)"
  case "${url}" in
    http://127.0.0.1:3142|http://localhost:3142)
      printf '%s\n' 'http://host.docker.internal:3142' ;;
    *) [[ -z "${url}" ]] || printf '%s\n' "${url}" ;;
  esac
}

apt_proxy_container_host_args() {
  local url
  url="$(apt_proxy_url)"
  case "${url}" in
    http://127.0.0.1:3142|http://localhost:3142)
      printf '%s\n' --add-host 'host.docker.internal:host-gateway' ;;
  esac
}

# Docker's --add-host mapping lives in the builder container's /etc/hosts, not
# in the rootfs mkosi mounts over /etc for its postinstall chroot. Resolve it in
# the outer container (the network namespace the chroot uses) before mkosi starts.
apt_proxy_nested_chroot_url() {
  local url="${1:-}" records address
  if [[ "${url}" != 'http://host.docker.internal:3142' ]]; then
    printf '%s\n' "${url}"
    return 0
  fi
  records="$(getent ahostsv4 host.docker.internal)" || return 1
  read -r address _ <<<"${records}" || return 1
  [[ "${address}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  printf 'http://%s:3142\n' "${address}"
}
