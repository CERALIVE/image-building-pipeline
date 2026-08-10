#!/usr/bin/env bash
set -euo pipefail

auth_keyring_primary_fingerprints() {
  local keyring="$1"
  gpg --batch --show-keys --with-colons --fingerprint -- "${keyring}" 2>/dev/null \
    | awk -F: '
      $1=="pub" {
        primary_count++
        pending_primary=1
        if ($2 ~ /[deir]/ || $12 !~ /[sS]/ || $12 ~ /D/) invalid=1
        next
      }
      pending_primary && $1=="fpr" {
        print $10
        fingerprint_count++
        pending_primary=0
        next
      }
      $1=="sub" && ($2 ~ /[deir]/ || $12 ~ /D/) { invalid=1 }
      END {
        if (invalid || pending_primary || primary_count != fingerprint_count) exit 1
      }
    '
}

auth_keyring_has_exact_fingerprints() {
  local keyring="$1"
  shift
  (( $# > 0 )) || return 1

  local fingerprint actual expected
  for fingerprint in "$@"; do
    [[ "${fingerprint}" =~ ^[A-F0-9]{40}$ ]] || return 1
  done
  actual="$(auth_keyring_primary_fingerprints "${keyring}")" || return 1
  [[ -n "${actual}" ]] || return 1
  actual="$(LC_ALL=C sort -u <<<"${actual}")" || return 1
  expected="$(printf '%s\n' "$@" | LC_ALL=C sort -u)" || return 1
  [[ "${actual}" == "${expected}" ]]
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
      if (pkg==want_pkg && (a==want_arch || a=="all") && (want_version=="" || ver==want_version) && filename!="" && sha!="")
        printf "%s\t%s\t%s\n", filename, sha, ver
    }
  ' "${index}")"
  [[ "$(grep -c . <<<"${rows}")" -eq 1 ]] || return 1
  printf '%s\n' "${rows}"
}

auth_release_has_identity() {
  local release="$1" suite="$2" component="$3" arch="$4"
  awk -v want_suite="${suite}" -v want_component="${component}" -v want_arch="${arch}" '
    $1=="Suite:" { suite_count++; suite=$2 }
    $1=="Architectures:" {
      architectures_count++
      for (i=2; i<=NF; i++) if ($i==want_arch) has_arch=1
    }
    $1=="Components:" {
      components_count++
      for (i=2; i<=NF; i++) if ($i==want_component) has_component=1
    }
    END {
      exit !(suite_count==1 && architectures_count==1 && components_count==1 &&
             suite==want_suite && has_arch && has_component)
    }
  ' "${release}"
}

auth_verify_file() {
  local file="$1" expected="$2" actual
  actual="$(sha256sum "${file}" | cut -d' ' -f1)"
  [[ "${actual}" == "${expected}" ]]
}

auth_verify_release_to_file() {
  local keyring="$1" inrelease="$2" verified_release="$3"
  shift 3
  local work status plaintext actual expected fingerprint
  work="$(mktemp -d "$(dirname "${verified_release}")/.release-verify.XXXXXX")"
  status="${work}/status"
  plaintext="${work}/Release"

  if ! gpgv --status-fd 3 --keyring "${keyring}" --output "${plaintext}" \
      "${inrelease}" 3>"${status}"; then
    rm -rf "${work}"
    return 1
  fi
  if [[ ! -s "${plaintext}" ]]; then
    rm -rf "${work}"
    return 1
  fi

  if (( $# > 0 )); then
    for fingerprint in "$@"; do
      [[ "${fingerprint}" =~ ^[A-F0-9]{40}$ ]] || {
        rm -rf "${work}"
        return 1
      }
    done
    actual="$(awk '
      $2=="VALIDSIG" {
        fingerprint=$NF
        if (fingerprint !~ /^[A-Fa-f0-9]{40}$/) fingerprint=$3
        if (fingerprint ~ /^[A-Fa-f0-9]{40}$/) print toupper(fingerprint)
      }
    ' "${status}" | LC_ALL=C sort -u)" || {
      rm -rf "${work}"
      return 1
    }
    expected="$(printf '%s\n' "$@" | LC_ALL=C sort -u)" || {
      rm -rf "${work}"
      return 1
    }
    if [[ -z "${actual}" || "${actual}" != "${expected}" ]]; then
      rm -rf "${work}"
      return 1
    fi
  fi

  if ! mv -f "${plaintext}" "${verified_release}"; then
    rm -rf "${work}"
    return 1
  fi
  rm -rf "${work}"
}

auth_verify_release_signature() {
  local keyring="$1" inrelease="$2" verified_release
  shift 2
  verified_release="$(mktemp)"
  if ! auth_verify_release_to_file \
      "${keyring}" "${inrelease}" "${verified_release}" "$@"; then
    rm -f "${verified_release}"
    return 1
  fi
  rm -f "${verified_release}"
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
