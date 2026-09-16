#!/usr/bin/env bash
# The Python driver executes the real CLI, including the downgrade negative control.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "${ROOT}/tests/pin_currency_test.py" "$@"
