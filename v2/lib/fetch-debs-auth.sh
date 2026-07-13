#!/usr/bin/env bash
set -euo pipefail

auth_keyring_has_fingerprint() {
  local keyring="$1" expected="$2"
  gpg --show-keys --with-colons "${keyring}" 2>/dev/null \
    | awk -F: '$1=="fpr"{print $10}' | grep -Fqx "${expected}"
}

auth_lookup_package() {
  local index="$1" package="$2" version="$3" arch="$4" rows
  rows="$(awk -v want_pkg="${package}" -v want_version="${version}" -v want_arch="${arch}" '
    BEGIN { RS=""; FS="\n" }
    {
      pkg=""; ver=""; a=""; filename=""; sha="";
      for (i=1; i<=NF; i++) {
        if ($i ~ /^Package: /) pkg=substr($i,10)
        else if ($i ~ /^Version: /) ver=substr($i,10)
        else if ($i ~ /^Architecture: /) a=substr($i,15)
        else if ($i ~ /^Filename: /) filename=substr($i,11)
        else if ($i ~ /^SHA256: /) sha=substr($i,9)
      }
      if (pkg==want_pkg && a==want_arch && (want_version=="" || ver==want_version) && filename!="" && sha!="")
        printf "%s\t%s\t%s\n", filename, sha, ver
    }
  ' "${index}")"
  [[ "$(grep -c . <<<"${rows}")" -eq 1 ]] || return 1
  printf '%s\n' "${rows}"
}

auth_verify_file() {
  local file="$1" expected="$2" actual
  actual="$(sha256sum "${file}" | cut -d' ' -f1)"
  [[ "${actual}" == "${expected}" ]]
}

auth_verify_release_signature() {
  local keyring="$1" inrelease="$2"
  gpgv --keyring "${keyring}" "${inrelease}" >/dev/null
}

main() {
  local command="${1:-}"; shift || true
  case "${command}" in
    lookup)
      local index="" package="" version="" arch=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --index) index="$2"; shift 2 ;;
          --package) package="$2"; shift 2 ;;
          --version) version="$2"; shift 2 ;;
          --arch) arch="$2"; shift 2 ;;
          *) exit 2 ;;
        esac
      done
      auth_lookup_package "${index}" "${package}" "${version}" "${arch}"
      ;;
    verify-file)
      local file="" sha=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --file) file="$2"; shift 2 ;;
          --sha256) sha="$2"; shift 2 ;;
          *) exit 2 ;;
        esac
      done
      auth_verify_file "${file}" "${sha}"
      ;;
    verify-signature)
      local keyring="" inrelease=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --keyring) keyring="$2"; shift 2 ;;
          --inrelease) inrelease="$2"; shift 2 ;;
          *) exit 2 ;;
        esac
      done
      auth_verify_release_signature "${keyring}" "${inrelease}"
      ;;
    *) exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
