#!/usr/bin/env bash
# Opt-in planned maintenance and recovery power entrypoint (root, systemd 257).
set -euo pipefail
uncertain() {
  echo 'The power request could not be confirmed. Please check the box before trying again.' >&2
  exit 70
}
trap uncertain HUP INT TERM
case "${1:-}" in
  reboot|poweroff) action="$1" ;;
  *) echo 'Usage: ceralive-power reboot|poweroff' >&2; exit 64 ;;
esac
[[ $# -eq 1 ]] || { echo 'Only one power action is accepted.' >&2; exit 64; }
if systemctl "$action"; then
  exit 0
else
  status=$?
fi
if (( status >= 128 )); then
  uncertain
fi
if (( status == 127 )); then
  echo 'Shutdown command unavailable. Check the system service before trying again.' >&2
  exit 75
fi
if [[ "$action" == reboot ]]; then
  echo 'The box was not restarted. It may be streaming or carrying traffic, or shutdown may be unavailable. Please try again when it is idle.' >&2
else
  echo 'The box was not powered off. It may be streaming or carrying traffic, or shutdown may be unavailable. Please try again when it is idle.' >&2
fi
exit 75
