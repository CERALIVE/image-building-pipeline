#!/usr/bin/env bash
# shellcheck disable=SC2034
# Measured floor for a retail 16 GB card. Published 16 GB cards measure about
# 15.48-15.93 GB; this floor stays about 3% below the smallest of them.
CERALIVE_MIN_MEDIA_BYTES=15000000000
CERALIVE_DATA_MIN_AVAILABLE_BYTES=1073741824 # 1 GiB available for update staging.
