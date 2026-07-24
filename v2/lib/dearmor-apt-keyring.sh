#!/usr/bin/env bash
#
# dearmor-apt-keyring.sh — convert the CI-provided armored CeraLive archive key
# into the binary keyring payload consumed by the runtime image postinstall.
#
# This runs in the build environment, never on the device: the final runtime
# image intentionally contains apt/gpgv but not the full gpg or file utilities.

set -euo pipefail

die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

[[ -n "${APT_GPG_PUBLIC_B64:-}" ]] \
  || die 'APT_GPG_PUBLIC_B64 is required to dearmor the CeraLive apt keyring'
command -v gpg >/dev/null 2>&1 || die 'gpg is required in the build environment to dearmor the CeraLive apt keyring'
command -v file >/dev/null 2>&1 || die 'file(1) is required in the build environment to verify the CeraLive apt keyring'

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
raw="${workdir}/ceralive-archive-keyring.asc"
keyring="${workdir}/ceralive-archive-keyring.gpg"

printf '%s' "${APT_GPG_PUBLIC_B64}" | base64 -d >"${raw}" \
  || die 'could not decode APT_GPG_PUBLIC_B64'
raw_magic="$(file -b "${raw}")" || die 'could not identify the supplied CeraLive apt keyring'
case "${raw_magic}" in
  OpenPGP\ Public\ Key\ Version*) cp "${raw}" "${keyring}" ;;
  PGP\ public\ key\ block*)
    gpg --batch --yes --dearmor --output "${keyring}" "${raw}" \
      || die 'could not dearmor the CeraLive apt public key'
    ;;
  *) die "CeraLive apt keyring input is neither armored nor binary OpenPGP (${raw_magic})" ;;
esac

magic="$(file -b "${keyring}")" || die 'could not identify the dearmored CeraLive apt keyring'
case "${magic}" in
  OpenPGP\ Public\ Key\ Version*) ;;
  *) die "CeraLive apt keyring is not a binary OpenPGP public key (${magic})" ;;
esac

base64 -w0 "${keyring}"
