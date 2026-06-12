#!/usr/bin/env bash
#
# check-size-regression.sh — compare current image size against baseline.
#
# Detects relative image-size regressions on top of the existing 1.5 GB absolute gate.
# Warns on any growth; fails (exit 1) if growth exceeds 50 MB.
#
# Usage:  check-size-regression.sh <current-bytes> <baseline-file>
#   <current-bytes>   measured rootfs size in bytes (integer)
#   <baseline-file>   JSON file with {board, bytes, recorded_at}
#
# Exit:   0         size within baseline + 50 MB threshold
#         1         size exceeds baseline + 50 MB
#         2         bad args / missing baseline file / malformed JSON
#
# shellcheck shell=bash

set -euo pipefail

usage() {
  cat >&2 <<EOF
usage: check-size-regression.sh <current-bytes> <baseline-file>
  <current-bytes>   measured rootfs size in bytes (integer)
  <baseline-file>   JSON file with {board, bytes, recorded_at}
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage

current_bytes="$1"
baseline_file="$2"

# Validate current_bytes is a positive integer
if ! [[ "${current_bytes}" =~ ^[0-9]+$ ]] || (( current_bytes <= 0 )); then
  echo "ERROR: current-bytes must be a positive integer, got: ${current_bytes}" >&2
  exit 2
fi

# Validate baseline file exists
if [[ ! -f "${baseline_file}" ]]; then
  echo "ERROR: baseline file not found: ${baseline_file}" >&2
  exit 2
fi

# Parse baseline JSON
baseline_bytes=$(python3 - "${baseline_file}" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError) as exc:
    sys.stderr.write("ERROR: malformed baseline JSON: %s\n" % exc)
    sys.exit(2)

if not isinstance(data, dict):
    sys.stderr.write("ERROR: baseline JSON root must be an object\n")
    sys.exit(2)

if "bytes" not in data:
    sys.stderr.write("ERROR: baseline JSON must contain 'bytes' field\n")
    sys.exit(2)

baseline = data["bytes"]
if not isinstance(baseline, int) or baseline <= 0:
    sys.stderr.write("ERROR: baseline 'bytes' must be a positive integer\n")
    sys.exit(2)

print(baseline)
PY
) || exit 2

# Calculate delta
delta=$((current_bytes - baseline_bytes))
delta_mb=$((delta / 1048576))  # 1 MB = 1048576 bytes
threshold_mb=50
threshold_bytes=$((threshold_mb * 1048576))

# Format output
if (( delta >= 0 )); then
  delta_sign="+"
  delta_display="${delta_sign}${delta_mb} MB"
else
  delta_sign="-"
  delta_display="${delta_sign}$((delta_mb * -1)) MB"
fi

printf "size-regression: baseline=%d bytes, current=%d bytes, delta=%s\n" \
  "${baseline_bytes}" "${current_bytes}" "${delta_display}"

# Warn on any growth
if (( delta > 0 )); then
  echo "WARNING: image size increased by ${delta_mb} MB" >&2
fi

# Fail if delta exceeds threshold
if (( delta > threshold_bytes )); then
  echo "ERROR: image size growth (${delta_mb} MB) exceeds threshold (${threshold_mb} MB)" >&2
  exit 1
fi

exit 0
