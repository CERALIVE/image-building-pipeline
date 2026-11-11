#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export CERALIVE_SSH_POLICY_DIR="$T/data"
export SLOT="$T/A" CALLS="$T/calls"
mkdir "$T/A" "$T/B"
cat >"$T/systemctl" <<'STUB'
#!/bin/bash
set -e
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  'is-enabled ssh.service')
    state="$(cat "$SLOT/state")"
    echo "$state"
    [[ "$state" == enabled || "$state" == enabled-runtime ]] ;;
  'enable ssh.service') echo enabled >"$SLOT/state" ;;
  'disable ssh.service ssh.socket') echo disabled >"$SLOT/state" ;;
esac
STUB
chmod +x "$T/systemctl"
export SYSTEMCTL="$T/systemctl"
policy() { bash "$ROOT/mkosi/runtime/ceralive-ssh-policy.sh" "$1"; }
# Production default and a temporary running session must not become boot-enabled.
echo disabled >"$SLOT/state"
policy restore
grep -qx disabled "$T/data/boot-policy"
! grep -q start "$CALLS"
# A signed bundle captures old-slot enablement even before policy services exist.
mkdir "$T/bin"
printf '#!/bin/sh\nexit "${MOUNT_RC:-0}"\n' >"$T/bin/mountpoint"
chmod +x "$T/bin/mountpoint"
export PATH="$T/bin:$PATH"
echo enabled >"$SLOT/state"
MOUNT_RC=1 policy slot-pre-install && exit 1
grep -qx disabled "$T/data/boot-policy"
policy slot-pre-install
grep -qx enabled "$T/data/boot-policy"
grep -q 'hooks=pre-install' "$ROOT/lib/build-bundle.sh"
grep -q 'install -m 0755.*ssh-policy.sh.*ssh-policy-hook' "$ROOT/lib/build-bundle.sh"
# Operator opt-in is captured, then applied to a fresh slot with SSH off.
echo enabled >"$SLOT/state"
policy save
export SLOT="$T/B"
echo disabled >"$SLOT/state"
policy restore
grep -qx enabled "$SLOT/state"
grep -qx -- '--no-block start ssh.service' "$CALLS"
# Opt-out persists through rollback to an enabled old slot.
echo disabled >"$SLOT/state"
policy save
export SLOT="$T/A"
policy restore
grep -qx disabled "$SLOT/state"
# A runtime-only enable does not arm boot persistence.
echo enabled-runtime >"$SLOT/state"
policy save
grep -qx disabled "$T/data/boot-policy"
# A local administrative mask is never lifted by shared opt-in.
printf 'enabled\n' >"$T/data/boot-policy"
echo masked >"$SLOT/state"
policy restore
grep -qx masked "$SLOT/state"
# Neither unknown read results nor corrupt policy can enable access.
echo unknown >"$SLOT/state"
if policy save; then exit 1; fi
grep -qx enabled "$T/data/boot-policy"
echo corrupt >"$T/data/boot-policy"
: >"$CALLS"
if policy restore; then exit 1; fi
[[ ! -s "$CALLS" ]]
grep -q 'ExecStop=.* save' "$ROOT/mkosi/runtime/ceralive-ssh-policy.service"
grep -q 'PathChanged=/etc/systemd/system/multi-user.target.wants' "$ROOT/mkosi/runtime/ceralive-ssh-policy.path"
grep -q 'enable_service ceralive-ssh-policy.path' "$ROOT/mkosi/customize/postinst.d/tls-ssh.sh"
echo 'PASS: shared SSH policy, slot switch, opt-out, defaults and read failures'
