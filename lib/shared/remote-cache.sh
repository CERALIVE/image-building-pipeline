#!/usr/bin/env bash
# shellcheck shell=bash

ceralive_remote_cache_mode() {
  case "${CERALIVE_REMOTE_CACHE:-auto}" in
    auto|0) printf '%s' "${CERALIVE_REMOTE_CACHE:-auto}" ;;
    *) die "CERALIVE_REMOTE_CACHE must be auto or 0 (got '${CERALIVE_REMOTE_CACHE}')"; return 1 ;;
  esac
}

ceralive_remote_cache_url() {
  local url="${CERALIVE_REMOTE_CACHE_URL:-https://build-cache.ceralive.tv}"
  if [[ "${url}" == 'https://build-cache.ceralive.tv' ]] ||
     [[ "${url}" =~ ^http://(127\.0\.0\.1|localhost):[0-9]{1,5}$ ]]; then
    printf '%s' "${url}"
    return 0
  fi
  die "CERALIVE_REMOTE_CACHE_URL must be the production endpoint or loopback HTTP test fixture"
  return 1
}
