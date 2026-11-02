#!/usr/bin/env bash
# Devices report the baked OS version, so a candidate that differs from the published one mislabels the release.
set -euo pipefail

dir="${1:?usage: check-candidate-os-version.sh CANDIDATE_DIR VERSION}"
want="${2:?usage: check-candidate-os-version.sh CANDIDATE_DIR VERSION}"
stamp="${dir}/os-release-version"

[[ -f "${stamp}" ]] || { echo "candidate OS version stamp absent: rebuild the candidate" >&2; exit 1; }
baked="$(<"${stamp}")"
[[ "${baked}" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || { echo "candidate OS version stamp is not CalVer: ${baked}" >&2; exit 1; }
[[ "${baked}" == "${want}" ]] || {
  echo "candidate bakes OS version ${baked} but ${want} was requested: set CERALIVE_OS_RELEASE_VERSION, rebuild, then publish ${baked} or the new version" >&2
  exit 1
}
