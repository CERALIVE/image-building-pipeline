#!/usr/bin/env bash
set -euo pipefail

RAUC_BUNDLE_INSPECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${RAUC_BUNDLE_INSPECT_DIR}/shared/layout.sh"

rauc_bundle_verify_and_compatible() {
  local bundle="$1" keyring="$2" info compatible expected_size
  info="$(rauc info -C keyring:check-purpose=codesign \
    --output-format=json --keyring="${keyring}" "${bundle}")" || return 1
  compatible="$(python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d["compatible"],str) and d["compatible"]; print(d["compatible"])' <<<"${info}")" || return 1
  # Size follows the authenticated compatible, never an ambient build-board env.
  expected_size=$(( $(BOARD_ID="${compatible#ceralive-}" ceralive_rootfs_mb) * 1024 * 1024 ))
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
assert data["format"] == "verity", "OS bundle is not verity"
images = [image["rootfs"] for image in data["images"] if "rootfs" in image]
assert len(images) == 1, "bundle must have exactly one rootfs image"
assert images[0]["filename"] == "rootfs.ext4", "bundle has wrong rootfs image"
assert images[0]["size"] == int(sys.argv[1]), "bundle rootfs is not a full slot"
assert "block-hash-index" in images[0]["adaptive"], "bundle lacks adaptive index"
assert data["compatible"], "bundle has no compatible"
print(data["compatible"])
' "${expected_size}" <<<"${info}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -eq 2 ]] || exit 2
  rauc_bundle_verify_and_compatible "$1" "$2"
fi
