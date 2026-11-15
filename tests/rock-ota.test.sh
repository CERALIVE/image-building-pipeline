#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/shared/layout.sh
[[ "$(BOARD_ID=rock-5b-plus ceralive_min_media_bytes)" == 15000000000 ]]
grep -q 'Unsupported root partition geometry' mkosi/runtime/ceralive-layout-install-check.sh
! grep -q 'CERALIVE_LAYOUT_PROFILE' lib/shared/layout.sh
