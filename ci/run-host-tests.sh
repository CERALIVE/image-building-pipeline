#!/usr/bin/env bash
# Run the host gate with signalling confined to a PID namespace. Pass scratch
# explicitly after sudo, whose environment policy normally removes TMPDIR.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="${TMPDIR:-/var/tmp}"
[[ "$tmp" = /* && -d "$tmp" && -w "$tmp" ]] || {
  printf 'TMPDIR must be an absolute writable directory\n' >&2
  exit 2
}
[[ $# -gt 0 ]] || set -- "$here/run-tests"
sudo -n unshare --pid --fork --mount-proc \
  setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups \
  env HOME="$HOME" PATH="$PATH" TMPDIR="$tmp" LC_ALL=C \
    BATS_JOBS="${BATS_JOBS:-1}" \
    bash -c '"$@"; result=$?; exit "$result"' host-tests "$@"
