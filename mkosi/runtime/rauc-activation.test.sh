#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${ROOT}/mkosi/runtime/ceralive-rauc-activate.sh"
UNIT="${ROOT}/mkosi/runtime/ceralive-rauc-activate.service"
ARM_UNIT="${ROOT}/mkosi/runtime/ceralive-rauc-arm@.service"
INSTALLER="${ROOT}/mkosi/customize/postinst.d/services.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'rauc activation: FAIL %s\n' "$*" >&2; exit 1; }
ok() { printf 'rauc activation: PASS %s\n' "$*"; }

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/run" "$TMP/root/etc/systemd/system" "$TMP/root/usr/lib/systemd/system"
mkdir -p "$TMP/root/bin"
cp /bin/true "$TMP/root/bin/true"
cp -a /usr/lib/systemd/system/. "$TMP/root/usr/lib/systemd/system/"
cat >"$TMP/root/etc/systemd/system/rauc.service" <<'EOF'
[Unit]
Description=RAUC fixture
[Service]
ExecStart=/bin/true
EOF
cat >"$TMP/bin/id" <<'EOF'
#!/bin/sh
printf '0\n'
EOF
cat >"$TMP/bin/dpkg" <<'EOF'
#!/bin/sh
[ "$*" = '--print-architecture' ] || exit 9
printf '%s\n' "$FIXTURE_ARCH"
EOF
cat >"$TMP/bin/rauc" <<'EOF'
#!/bin/sh
case "$*" in
  'status --detailed --output-format=shell') cat "$FIXTURE_STATUS" ;;
  'status mark-active other')
    [ "${RAUC_REFUSE_MARK:-0}" != 1 ] || exit 9
    printf '%s\n' "$*" >>"$RAUC_CALLS" ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$TMP/bin/id" "$TMP/bin/rauc" "$TMP/bin/dpkg"
export PATH="$TMP/bin:$PATH" RAUC_CALLS="$TMP/calls" FIXTURE_STATUS="$TMP/status"
export CERALIVE_ACTIVATION_STATE_DIR="$TMP/state" CERALIVE_STREAMING_MARKER="$TMP/run/streaming"
export CERALIVE_ACTIVATION_LOCK="$TMP/activation.lock"
: >"$RAUC_CALLS"
pending_status() {
  cat >"$FIXTURE_STATUS" <<'EOF'
RAUC_SYSTEM_BOOTED_BOOTNAME='A'
RAUC_BOOT_PRIMARY='rootfs.0'
RAUC_SYSTEM_SLOTS='rootfs.0 rootfs.1'
RAUC_SLOTS='1 2'
RAUC_SLOT_BOOTNAME_1='A'
RAUC_SLOT_STATE_1='booted'
RAUC_SLOT_BOOTNAME_2='B'
RAUC_SLOT_STATE_2='inactive'
RAUC_SLOT_STATUS_INSTALLED_TIMESTAMP_2='2026-09-23T12:00:00Z'
RAUC_SLOT_STATUS_ACTIVATED_TIMESTAMP_2='2026-09-22T12:00:00Z'
RAUC_SLOT_STATUS_BUNDLE_DESCRIPTION_2='A quoted '\''bundle'\'' label'
EOF
}
count_calls() { [[ "$(wc -l <"$RAUC_CALLS")" -eq "$1" ]] || fail "expected $1 mark-active calls"; }

pending_status
"$SCRIPT" --arm
[[ -f "$TMP/state/activation-armed" ]] || fail 'arm did not persist'
"$SCRIPT"
count_calls 1
[[ ! -e "$TMP/state/activation-armed" ]] || fail 'successful activation did not disarm'
ok 'armed and pending: one activation, consumed marker'

"$SCRIPT"
count_calls 1
ok 'unarmed: no-op'

"$SCRIPT" --arm
touch "$TMP/run/streaming"
"$SCRIPT"
count_calls 1
[[ -e "$TMP/state/activation-armed" ]] || fail 'streaming lost the armed marker'
if "$SCRIPT" --now; then fail '--now activated during streaming'; fi
count_calls 1
rm "$TMP/run/streaming"
"$SCRIPT" --disarm
ok 'streaming: no activation, marker retained, explicit disarm'

pending_status
printf '%s\n' "RAUC_SLOT_STATUS_ACTIVATED_TIMESTAMP_2='2026-09-24T12:00:00Z'" >>"$FIXTURE_STATUS"
touch "$TMP/state/activation-armed"
"$SCRIPT"
count_calls 1
[[ -e "$TMP/state/activation-armed" ]] || fail 'nothing pending consumed marker'
ok 'no pending installation: no-op'

pending_status
"$SCRIPT" --now
count_calls 2
[[ ! -e "$TMP/state/activation-armed" ]] || fail '--now left armed marker'
ok '--now: immediate guarded activation without reboot'

pending_status
touch "$TMP/state/activation-armed"
export RAUC_REFUSE_MARK=1
if "$SCRIPT" --now; then fail 'RAUC failure reported as success'; fi
count_calls 2
[[ -e "$TMP/state/activation-armed" ]] || fail 'RAUC failure discarded armed marker'
unset RAUC_REFUSE_MARK
"$SCRIPT" --disarm
ok 'RAUC failure retains marker for a future clean shutdown'

[[ -f "$UNIT" && -f "$ARM_UNIT" && -f "$INSTALLER" ]] || fail 'missing unit or installer'
! grep -Eq '^DefaultDependencies=no$' "$UNIT" || fail 'shutdown service has no default dependencies'
grep -Fxq 'Wants=rauc.service' "$UNIT" || fail 'Wants=rauc.service missing'
grep -Fxq 'After=rauc.service dbus.service' "$UNIT" || fail 'RAUC/DBus ordering missing'
grep -Fxq 'RequiresMountsFor=/boot' "$UNIT" || fail 'RK3588 boot mount dependency missing'
grep -Fxq 'RequiresMountsFor=/data' "$UNIT" || fail 'armed state might unmount before shutdown hook'
grep -Fxq 'ExecStop=/usr/libexec/ceralive/ceralive-rauc-activate' "$UNIT" || fail 'shutdown hook missing'
grep -Fxq 'RemainAfterExit=yes' "$UNIT" || fail 'unit would not remain active at shutdown'
grep -Fq 'RequiresMountsFor=/boot/efi' "$INSTALLER" || fail 'x86 ESP mount substitution missing'
grep -Fxq 'ExecStart=/usr/libexec/ceralive/ceralive-rauc-activate --%i' "$ARM_UNIT" || fail 'template action is not narrowed'
ok 'unit properties and both boot mounts'

export CERALIVE_RUNTIME_SRC="$ROOT/mkosi/runtime"
export CERALIVE_RAUC_ACTIVATE_UNIT_DIR="$TMP/root/etc/systemd/system"
export CERALIVE_RAUC_ACTIVATE_HELPER_DIR="$TMP/root/usr/libexec/ceralive"
# shellcheck source=/dev/null
source "$INSTALLER"
enable_service() { [[ "$1" == ceralive-rauc-activate.service ]] || fail 'wrong unit enabled'; }
for fixture_arch in arm64 amd64; do
  export FIXTURE_ARCH="$fixture_arch"
  setup_rauc_activation
  if [[ "$fixture_arch" == amd64 ]]; then boot_mount=/boot/efi; else boot_mount=/boot; fi
  grep -Fxq "RequiresMountsFor=$boot_mount" "$CERALIVE_RAUC_ACTIVATE_UNIT_DIR/ceralive-rauc-activate.service" \
    || fail "$fixture_arch rendered wrong boot mount"
  grep -Fxq "RequiresMountsFor=/data $boot_mount" "$CERALIVE_RAUC_ACTIVATE_UNIT_DIR/ceralive-rauc-arm@.service" \
    || fail "$fixture_arch arm template rendered wrong boot mount"
  systemd-analyze verify --root "$TMP/root" ceralive-rauc-activate.service ceralive-rauc-arm@arm.service \
    >"$TMP/rendered-verify" 2>&1 || { command cat "$TMP/rendered-verify"; fail "$fixture_arch rendered verify"; }
done
ok 'actual installer renders and verifies arm64 /boot and amd64 /boot/efi'

cp "$UNIT" "$TMP/root/etc/systemd/system/ceralive-rauc-activate.service"
cp "$ARM_UNIT" "$TMP/root/etc/systemd/system/ceralive-rauc-arm@.service"
systemd-analyze verify --root "$TMP/root" ceralive-rauc-activate.service ceralive-rauc-arm@arm.service \
  >"$TMP/verify" 2>&1 || { command cat "$TMP/verify"; fail 'systemd-analyze verify'; }
if grep -Eq 'Found ordering cycle|deleted to break' "$TMP/verify"; then fail 'ordering cycle'; fi
ok 'systemd-analyze verify: both real units, no cycle'

if ! SYSTEMD_UNIT_PATH="$TMP/root/etc/systemd/system:$TMP/root/usr/lib/systemd/system" \
  /usr/lib/systemd/systemd --test --system --unit=ceralive-rauc-activate.service \
  --log-target=console >"$TMP/manager-dump" 2>&1; then
  command cat "$TMP/manager-dump"
  fail 'offline systemd manager dump'
fi
if ! grep -A 65 'ceralive-rauc-activate.service:' "$TMP/manager-dump" | grep -Fq 'Conflicts: shutdown.target'; then
  fail 'implicit Conflicts=shutdown.target not observed in offline manager dump'
fi
ok 'offline systemd manager: implicit Conflicts=shutdown.target'

# Match systemd-ordering-cycle.test.sh: a probe After=activate Before=rauc
# closes a cycle iff the shutdown unit is actually ordered after RAUC.
cat >"$TMP/root/etc/systemd/system/zz-activate-probe.service" <<'EOF'
[Unit]
Description=RAUC activation ordering probe
DefaultDependencies=no
After=ceralive-rauc-activate.service
Before=rauc.service
[Service]
Type=oneshot
ExecStart=/bin/true
[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$TMP/root/etc/systemd/system/multi-user.target.wants"
ln -s ../ceralive-rauc-activate.service "$TMP/root/etc/systemd/system/multi-user.target.wants/ceralive-rauc-activate.service"
ln -s ../zz-activate-probe.service "$TMP/root/etc/systemd/system/multi-user.target.wants/zz-activate-probe.service"
if ! systemd-analyze verify --root "$TMP/root" multi-user.target 2>&1 | grep -Fq 'Found ordering cycle'; then
  fail 'ordering probe did not observe activation After=rauc.service'
fi
ok 'dynamic ordering probe: activation is after RAUC'

printf 'rauc activation contract: PASS\n'
