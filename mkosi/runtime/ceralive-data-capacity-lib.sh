#!/usr/bin/env bash
# shellcheck disable=SC2034 # Constants are consumed by build and runtime readers.
# Compact A/B transport size is independent of supported physical media size.
CERALIVE_COMPACT_MIN_MEDIA_BYTES=7516192768 # 7 GiB; media labels are not capacity proof.
CERALIVE_DATA_MIN_AVAILABLE_BYTES=1073741824 # 1 GiB actual filesystem availability.
