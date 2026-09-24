#!/usr/bin/env bash
set -euo pipefail

rauc_bundle_verify_and_compatible() {
  local bundle="$1" keyring="$2" info
  info="$(rauc info -C keyring:check-purpose=codesign \
    --output-format=json --keyring="${keyring}" "${bundle}")" || return 1
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
assert data["format"] == "verity", "OS bundle is not verity"
images = [image["rootfs"] for image in data["images"] if "rootfs" in image]
assert len(images) == 1, "bundle must have exactly one rootfs image"
assert images[0]["filename"] == "rootfs.ext4", "bundle has wrong rootfs image"
assert images[0]["size"] == 4096 * 1024 * 1024, "bundle rootfs is not a full slot"
assert "block-hash-index" in images[0]["adaptive"], "bundle lacks adaptive index"
assert data["compatible"], "bundle has no compatible"
print(data["compatible"])
' <<<"${info}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -eq 2 ]] || exit 2
  rauc_bundle_verify_and_compatible "$1" "$2"
fi
