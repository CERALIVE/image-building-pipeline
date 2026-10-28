#!/usr/bin/env bash
# Public trust inputs match docs/RELEASE-PROCESS.md's host keyring procedure.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
destination="${1:?keyring output path required}"
(
  cd "${HERE}"
  sha256sum --check --strict <<'SHA'
45eea660732932370088652b214b85acb426c022529284211d76c12dcb5c9ec3  armbian-old.asc
c86db754ae38d13aa254e59672d8bb6c0ed9a0eeee9b5440cde69afef995da7a  armbian-new.asc
SHA
)
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
export GNUPGHOME="${work}"
gpg --no-options --batch --no-autostart --quiet --import \
  "${HERE}/armbian-old.asc" "${HERE}/armbian-new.asc"
gpg --no-options --batch --no-autostart --export \
  DF00FAF1C577104B50BF1D0093D6889F9F0E78D5 \
  8CFA83D13EB2181EEF5843E41EB30FAF236099FE >"${work}/armbian.gpg"
test -s "${work}/armbian.gpg"
install -m 0644 "${work}/armbian.gpg" "${destination}"
