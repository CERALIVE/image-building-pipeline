#!/bin/bash
# Preserve the operator's boot policy, independently of a temporary SSH session.
set -euo pipefail
STATE_DIR="${CERALIVE_SSH_POLICY_DIR:-/data/ceralive/ssh-policy}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
install -d -m 0700 "$STATE_DIR"
exec 9>"$STATE_DIR/policy.lock"
flock 9
policy="$STATE_DIR/boot-policy"
current_policy() {
  local state rc=0
  state="$("$SYSTEMCTL" is-enabled ssh.service)" || rc=$?
  case "$state:$rc" in
    enabled:0) printf 'enabled\n' ;;
    disabled:1|masked:1|masked-runtime:1|enabled-runtime:0) printf 'disabled\n' ;;
    *) echo 'Cannot read SSH boot policy' >&2; return 1 ;;
  esac
}
save_policy() {
  local state
  state="$(current_policy)" || return 1
  (umask 077; printf '%s\n' "$state" >"$policy.tmp")
  mv -f "$policy.tmp" "$policy"
}
case "${1:-}" in
  slot-pre-install)
    # Signed bundle hook runs on the old rootfs too, before the first upgrade
    # carrying this service. Never seed a disposable rootfs-local /data.
    mountpoint -q /data
    save_policy
    ;;
  save) save_policy ;;
  restore)
    # First deployment imports enablement only, never the active/running state.
    if [[ ! -e "$policy" ]]; then
      save_policy
      exit 0
    fi
    state="$(cat "$policy")"
    case "$state" in
      enabled)
        # A local mask is an explicit administrative refusal; never unmask it.
        local_state="$("$SYSTEMCTL" is-enabled ssh.service)" || true
        case "$local_state" in masked|masked-runtime) exit 0 ;; esac
        "$SYSTEMCTL" enable ssh.service
        "$SYSTEMCTL" --no-block start ssh.service
        ;;
      disabled)
        "$SYSTEMCTL" disable ssh.service ssh.socket
        "$SYSTEMCTL" --no-block stop ssh.service ssh.socket
        ;;
      *) echo 'Invalid saved SSH boot policy; refusing restore' >&2; exit 1 ;;
    esac
    ;;
  *) echo 'Usage: ceralive-ssh-policy restore|save' >&2; exit 2 ;;
esac
