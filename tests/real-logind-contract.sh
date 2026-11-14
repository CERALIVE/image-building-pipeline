#!/usr/bin/env bash
# Opt-in, destructive only inside an explicitly disposable systemd 257 container.
# Provision systemd, dbus, python3 and no polkit; no host mounts/device passthrough.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
container="${CERALIVE_LOGIND_TEST_CONTAINER:?Set the disposable container name}"
docker exec "$container" test -f /run/logind-contract-disposable
docker exec "$container" sh -c '/lib/systemd/systemd --version | head -1' | grep -Eq '^systemd 257 '
for target in reboot.target poweroff.target; do
  [[ "$(docker exec "$container" systemctl is-enabled "$target" 2>/dev/null || true)" == masked ]]
done
docker exec "$container" test ! -x /usr/lib/polkit-1/polkitd
# Never run these fixtures in a shared container or with a real device mounted.
[[ "$(docker inspect "$container" --format '{{len .HostConfig.Devices}}')" == 0 ]]
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc -shared -fPIC -Wall -Wextra -o "$tmp/input-ioctl.so" "$root/tests/fixtures/logind/input-ioctl.c" -ldl
docker exec "$container" mkdir -p /var/tmp/logind-contract /etc/systemd/logind.conf.d /etc/systemd/system/systemd-logind.service.d
docker exec -i "$container" tee /var/tmp/logind-contract/input-ioctl.so < "$tmp/input-ioctl.so" >/dev/null
for file in mock-logind.sh key.py; do docker exec -i "$container" tee "/var/tmp/logind-contract/$file" < "$root/tests/fixtures/logind/$file" >/dev/null; done
docker exec -i "$container" tee /etc/systemd/logind.conf.d/60-ceralive-power-key.conf < "$root/mkosi/runtime/60-ceralive-power-key.conf" >/dev/null
docker exec -i "$container" bash -s <<'INNER'
set -euo pipefail
cat > /etc/systemd/system/systemd-logind.service.d/contract.conf <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/bin/unshare --mount -- /bin/bash /var/tmp/logind-contract/mock-logind.sh
NotifyAccess=all
MemoryDenyWriteExecute=no
PrivateDevices=no
PrivateTmp=no
ProtectSystem=no
ProtectHome=no
ProtectKernelTunables=no
ProtectControlGroups=no
RestrictNamespaces=no
SystemCallFilter=
UNIT
cat > /etc/systemd/system/ceralive.service <<'UNIT'
[Service]
ExecStart=/usr/bin/systemd-inhibit --what=shutdown --who=contract --why=stream --mode=block sleep infinity
UNIT
systemctl stop ceralive systemd-logind
systemctl daemon-reload
systemctl reset-failed systemd-logind
systemctl restart systemd-logind
systemctl start ceralive
# Wait for the actual fd-owning inhibitor, not just its launcher.
wait_lock() {
  for ((i=0; i<50; i++)); do
    systemd-inhibit --list --no-pager | grep -q contract && return 0
    sleep .1
  done
  return 1
}
wait_lock
cursor() { journalctl -u systemd-logind -n 0 --show-cursor --no-pager | sed -n 's/^-- cursor: //p'; }
logs() { journalctl -u systemd-logind --after-cursor="$1" --no-pager; }
mark="$(cursor)"
systemctl reboot >/var/tmp/logind-contract/reboot.log 2>&1 && exit 1
! logs "$mark" | grep -q 'The system will reboot now'
echo 'ok 1 strong inhibitor refuses root reboot without polkit'
mark="$(cursor)"
python3 /var/tmp/logind-contract/key.py
logs "$mark" | grep -q 'Powering off'
logs "$mark" | grep -q 'poweroff.target is masked'
echo 'ok 2 short power key passes the held shutdown lock'
# Equal short/long poweroff executes immediately on key down. Exercise the
# duration-specific branch too, with short press ignored in the test only.
echo HandlePowerKey=ignore >> /etc/systemd/logind.conf.d/60-ceralive-power-key.conf
systemctl stop ceralive
systemctl reset-failed systemd-logind
systemctl restart systemd-logind
systemctl start ceralive
wait_lock
mark="$(cursor)"
python3 /var/tmp/logind-contract/key.py long
logs "$mark" | grep -q 'Power key pressed long'
logs "$mark" | grep -q 'Powering off'
echo 'ok 3 long power key uses the same ignore-inhibited policy'
sed -i 's/PowerKeyIgnoreInhibited=yes/PowerKeyIgnoreInhibited=no/; /HandlePowerKey=ignore/d' /etc/systemd/logind.conf.d/60-ceralive-power-key.conf
systemctl stop ceralive
systemctl reset-failed systemd-logind
systemctl restart systemd-logind
systemctl start ceralive
wait_lock
mark="$(cursor)"
python3 /var/tmp/logind-contract/key.py
logs "$mark" | grep -q 'shutdown is inhibited'
! logs "$mark" | grep -q 'Powering off'
echo 'ok 4 negative policy mutation refuses poweroff while the lock is held'
mark="$(cursor)"
systemctl stop ceralive
systemctl reboot >/var/tmp/logind-contract/override.log 2>&1 || true
logs "$mark" | grep -q 'The system will reboot now'
logs "$mark" | grep -q 'reboot.target is masked'
echo 'ok 5 stop service then checked reboot reaches the masked target'
INNER
