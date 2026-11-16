#!/usr/bin/env bash
# Check the emitted rootfs without mounting it or executing anything inside it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/common.sh"
[[ $# == 1 || $# == 2 ]] || die "usage: $0 <rootfs.tar|root-directory> [exceptions.txt]"
require_cmd python3
require_cmd modinfo
exec python3 "${HERE}/firmware-closure.py" "$1" \
  "${2:-${HERE}/../manifests/firmware-closure-exceptions.txt}"
