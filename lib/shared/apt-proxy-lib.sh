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
