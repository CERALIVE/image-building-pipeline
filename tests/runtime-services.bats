#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# runtime-services.bats — runtime service contracts — the deterministic hostname/mDNS
# identity allocator, the OTA-during-stream guard, USB-C source-role pinning,
# boot dead-weight masks, the fan curve, the fan kick-start, and status LEDs.
#
# Split out of the former tests/manifest.bats with the cases moved VERBATIM;
# the shared setup and every fixture helper live in manifest-helpers.bash.
#
# Run:  run-tests              (CI entrypoint)
#   or: bats tests/runtime-services.bats

load manifest-helpers

@test "hostname: no collision commits and publishes ceralive" {
  local root="$BATS_TEST_TMPDIR/no-collision"
  make_hostname_fixture "$root"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hostnamectl set-hostname ceralive"* ]]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"hostname-file=ceralive"* ]]
  [[ "$output" == *"hosts=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n' "$output"
}

# Real Rock 5B+ regression (2026-07-19, empirically reproduced against live
# avahi): the baked /etc/hostname=ceralive makes avahi already publish ceralive,
# so avahi-set-host-name ceralive returns AVAHI_ERR_NO_CHANGE (exit 1). The old
# claim treated that as a lost claim and died, cascading DEPEND failures across
# the whole appliance. The fix accepts "already own it" as success.
@test "hostname: avahi already owns the baked name (NO_CHANGE) is accepted as success" {
  local root="$BATS_TEST_TMPDIR/preowned"
  make_hostname_fixture "$root"
  printf 'ceralive\n' >"$root/avahi/published"
  run run_hostname_script "$root" "" preowned
  [ "$status" -eq 0 ]
  [[ "$output" == *"avahi-set-host-name ceralive"* ]]
  [[ "$output" == *"hostnamectl set-hostname ceralive"* ]]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"hosts=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  [[ "$output" != *"avahi-set-host-name ceralive2"* ]]
  printf '%s\n' "$output"
}

# wait_for_avahi_ready must poll GetState until the daemon is query-ready rather
# than issue the first claim into a cold daemon. slow-ready reports not-ready
# (state 0) for the first two GetState calls, then RUNNING.
@test "hostname: allocation waits for avahi to become query-ready" {
  local root="$BATS_TEST_TMPDIR/slow-ready"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "" slow-ready
  [ "$status" -eq 0 ]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  [ "$(cat "$root/avahi/state-poll-count")" -ge 3 ]
  printf '%s\n' "$output"
}

@test "hostname: occupied ceralive commits and publishes ceralive2" {
  local root="$BATS_TEST_TMPDIR/one-collision"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "ceralive"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hostnamectl set-hostname ceralive2"* ]]
  [[ "$output" == *"index=2"* ]]
  [[ "$output" == *"system-hostname=ceralive2"* ]]
  [[ "$output" == *"hostname-file=ceralive2"* ]]
  [[ "$output" == *"hosts=ceralive2"* ]]
  [[ "$output" == *"published=ceralive2"* ]]
  [[ "$output" != *"system-hostname=ceralive-2"* ]]
  printf '%s\n' "$output"
}

@test "hostname: occupied ceralive and ceralive2 commit and publish ceralive3" {
  local root="$BATS_TEST_TMPDIR/two-collisions"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "ceralive,ceralive2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hostnamectl set-hostname ceralive3"* ]]
  [[ "$output" == *"index=3"* ]]
  [[ "$output" == *"system-hostname=ceralive3"* ]]
  [[ "$output" == *"hostname-file=ceralive3"* ]]
  [[ "$output" == *"published=ceralive3"* ]]
  printf '%s\n' "$output"
}

@test "hostname: concurrent first boots establish distinct deterministic names" {
  local root_a="$BATS_TEST_TMPDIR/concurrent-a"
  local root_b="$BATS_TEST_TMPDIR/concurrent-b"
  local shared="$BATS_TEST_TMPDIR/concurrent-shared"
  run run_concurrent_hostname_scripts "$root_a" "$root_b" "$shared"
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlap-observed=1"* ]]
  local concurrent_output="$output"
  run bash -c "printf '%s\n' \"\$(cat '$root_a/system-hostname')\" \"\$(cat '$root_b/system-hostname')\" | sort | paste -sd,"
  [ "$status" -eq 0 ]
  [ "$output" = "ceralive,ceralive2" ]
  [ "$(cat "$root_a/system-hostname")" = "$(cat "$root_a/hostname")" ]
  [ "$(cat "$root_a/hostname")" = "$(cat "$root_a/avahi/published")" ]
  [ "$(cat "$root_b/system-hostname")" = "$(cat "$root_b/hostname")" ]
  [ "$(cat "$root_b/hostname")" = "$(cat "$root_b/avahi/published")" ]
  printf '%s\n' "$concurrent_output"
}

@test "hostname: symmetric Avahi renames retry the unowned lower candidate" {
  local root_a="$BATS_TEST_TMPDIR/symmetric-gap-a"
  local root_b="$BATS_TEST_TMPDIR/symmetric-gap-b"
  local shared="$BATS_TEST_TMPDIR/symmetric-gap-shared"
  run run_concurrent_hostname_scripts "$root_a" "$root_b" "$shared" symmetric-gap
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlap-observed=1"* ]]
  [[ "$output" == *"has no stable owner; retrying the same deterministic candidate"* ]]
  local race_output="$output"
  run bash -c "printf '%s\n' \"\$(cat '$root_a/system-hostname')\" \"\$(cat '$root_b/system-hostname')\" | sort | paste -sd,"
  [ "$status" -eq 0 ]
  [ "$output" = "ceralive,ceralive2" ]
  [ "$(cat "$root_a/system-hostname")" = "$(cat "$root_a/avahi/published")" ]
  [ "$(cat "$root_b/system-hostname")" = "$(cat "$root_b/avahi/published")" ]
  printf '%s\n' "$race_output"
}

@test "hostname: stale Avahi snapshot is retried without skipping ceralive" {
  local root="$BATS_TEST_TMPDIR/stale-probe"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "" stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"hostname-file=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  [[ "$output" == *"get-name-count=3"* ]]
  printf '%s\n' "$output"
}

@test "hostname: malformed Avahi snapshots fail closed without persisting identity" {
  local root="$BATS_TEST_TMPDIR/malformed-probe"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "" malformed
  [ "$status" -ne 0 ]
  [[ "$output" == *"index=<missing>"* ]]
  [[ "$output" == *"system-hostname=<missing>"* ]]
  [[ "$output" == *"hostname-file=<missing>"* ]]
  printf '%s\n' "$output"
}

@test "hostname: Avahi automatic hyphen rename advances to deterministic next candidate" {
  local root="$BATS_TEST_TMPDIR/avahi-rename"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "" rename
  [ "$status" -eq 0 ]
  [[ "$output" == *"avahi-set-host-name ceralive"* ]]
  [[ "$output" == *"avahi-set-host-name ceralive2"* ]]
  [[ "$output" == *"index=2"* ]]
  [[ "$output" == *"system-hostname=ceralive2"* ]]
  [[ "$output" == *"hostname-file=ceralive2"* ]]
  [[ "$output" == *"published=ceralive2"* ]]
  [[ "$output" != *"system-hostname=ceralive-2"* ]]
  printf '%s\n' "$output"
}

@test "hostname: restart reapplies persisted identity to system and Avahi" {
  local root="$BATS_TEST_TMPDIR/restart"
  make_hostname_fixture "$root"
  mkdir -p "$root/data"
  ln -s "$root/data/host_index" "$root/state/host_index"
  ln -s "$root/data/hostname.lock" "$root/state/hostname.lock"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [ -L "$root/state/host_index" ]
  [ -L "$root/state/hostname.lock" ]
  [ ! -e "$root/data/hostname.lock" ]
  [ -f "$root/run/hostname.lock" ]
  [ "$(cat "$root/data/host_index")" = 1 ]
  local first_boot_output="$output"

  printf 'factory-seed\n' >"$root/hostname"
  printf 'factory-seed\n' >"$root/system-hostname"
  rm -f "$root/avahi/published" "$root/avahi/get-name-count" "$root/calls"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hostnamectl set-hostname ceralive"* ]]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"hostname-file=ceralive"* ]]
  [[ "$output" == *"hosts=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n--- restart ---\n%s\n' "$first_boot_output" "$output"
}

@test "hostname: stale persisted lock symlink is ignored without clobbering its target" {
  local root="$BATS_TEST_TMPDIR/stale-lock-symlink"
  make_hostname_fixture "$root"
  printf 'do-not-clobber\n' >"$root/victim"
  ln -s "$root/victim" "$root/state/hostname.lock"

  run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [ "$(cat "$root/victim")" = do-not-clobber ]
  [ -L "$root/state/hostname.lock" ]
  [ -f "$root/run/hostname.lock" ]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n' "$output"
}

@test "hostname: identity files are synced before the persisted claim completes" {
  local root="$BATS_TEST_TMPDIR/durable-identity"
  make_hostname_fixture "$root"

  run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^sync -f ' "$root/calls")" -eq 9 ]
  grep -Fq "sync -f $root/hostname" "$root/calls"
  grep -Fq "sync -f $root/hosts" "$root/calls"
  grep -Fq "sync -f $root/state/host_index" "$root/calls"
  [ "$(tail -n 1 "$root/calls")" = "sync -f $root/state" ]
  printf '%s\n' "$output"
}

@test "hostname: interrupted commit leaves no identity and restart converges" {
  local root="$BATS_TEST_TMPDIR/interrupted-commit"
  make_hostname_fixture "$root"
  run run_hostname_script "$root" "" normal device "$root/shared" interrupt
  [ "$status" -ne 0 ]
  [[ "$output" == *"index=<missing>"* ]]
  [[ "$output" == *"system-hostname=<missing>"* ]]
  [[ "$output" == *"hostname-file=<missing>"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  [ -f "$root/run/hostname.lock" ]
  local interrupted_output="$output"

  run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"hostname-file=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n--- recovered ---\n%s\n' "$interrupted_output" "$output"
}

@test "hostname: claim tooling and identity consumer ordering ship together" {
  local hostname_unit
  run bash -c "sed 's/#.*//' '$PIPELINE_DIR/manifests/packages/shared.list' | awk 'NF { print \$1 }' | grep -Fx avahi-utils"
  [ "$status" -eq 0 ]
  hostname_unit="$(extract_hostname_unit)"
  grep -Fq 'Requires=ceralive-migrate-data.service' "$POSTINST_LIB"
  grep -Fq 'RequiresMountsFor=/data' "$POSTINST_LIB"
  [[ "$hostname_unit" == *'ExecStartPost=/usr/bin/systemctl --no-block start ceralive.service'* ]]
  [[ "$hostname_unit" == *'ExecStartPost=/usr/bin/systemctl --no-block restart ceralive-tls-firstboot.service nginx.service ceralive-hawkbit-provision.service ceralive-healthcheck.service'* ]]
  [[ "$hostname_unit" == *'RemainAfterExit=yes'* ]]
  [[ "$hostname_unit" != *'OnSuccess='* ]]
  grep -Fq 'ceralive-hostname-reconcile.service' "$POSTINST_LIB"
  grep -Fq 'ExecStart=/usr/local/sbin/ceralive-set-hostname reconcile' "$POSTINST_LIB"
  grep -Fq 'ceralive-hostname-reconcile.timer' "$POSTINST_LIB"
  grep -Fq 'OnUnitActiveSec=30s' "$POSTINST_LIB"
  grep -Fq 'Unit=ceralive-hostname-reconcile.service' "$POSTINST_LIB"
  grep -Fq 'RuntimeDirectory=ceralive-hostname' "$POSTINST_LIB"
  # ceralive-hostname.service MUST wait for network-online.target (link up), not
  # just NetworkManager.service (daemon up) — else the mDNS claim runs before eth0
  # links and every Requires= consumer cascades to "Dependency failed" on first boot
  # (real Rock 5B+ regression). After=/Wants= both carry network-online.target.
  grep -Fq 'After=systemd-machine-id-commit.service ceralive-migrate-data.service NetworkManager.service network-online.target avahi-daemon.service' "$POSTINST_LIB"
  grep -Fq 'Wants=NetworkManager.service network-online.target avahi-daemon.service' "$POSTINST_LIB"
  [[ "$hostname_unit" == *'After='*'network-online.target'*'avahi-daemon.service'* ]]
  [[ "$hostname_unit" == *'Wants=NetworkManager.service network-online.target avahi-daemon.service'* ]]
  # Graceful degradation: appliance consumers Wants= (not Requires=) the hostname
  # claim, so a failed claim boots on the baked default instead of cascading
  # DEPEND failures across ceralive.service/nginx/tls/hawkbit. Only the reconcile
  # retry service keeps a hard Requires= (its failure is harmless, timer refires).
  grep -Fq 'Wants=ceralive-hostname.service' "$POSTINST_LIB"
  grep -Fq 'Wants=ceralive-hostname.service' "$PIPELINE_DIR/mkosi/runtime/ceralive-tls-firstboot.service"
  run ! grep -Fq 'Requires=ceralive-hostname.service' "$PIPELINE_DIR/mkosi/runtime/ceralive-tls-firstboot.service"
  grep -Fq 'Requires=ceralive-hostname.service' "$POSTINST_LIB"
  grep -Fq 'x509 -in "$cert" -noout -checkhost "$FQDN"' "$PIPELINE_DIR/mkosi/runtime/ceralive-tls-firstboot.sh"
  run ! grep -Fq 'HOSTNAME_STAMP=' "$PIPELINE_DIR/mkosi/runtime/ceralive-tls-firstboot.sh"
  grep -Fq 'After=ceralive-migrate-data.service ceralive-hostname.service network-online.target' \
    "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  grep -Fq 'Wants=network-online.target ceralive-hostname.service' \
    "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  run ! grep -Fq 'Requires=ceralive-hostname.service' "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
}

@test "hostname: aligned reconciliation is a no-op" {
  local root="$BATS_TEST_TMPDIR/reconcile-aligned"
  make_hostname_fixture "$root"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]

  : >"$root/calls"
  run run_hostname_script "$root" "" normal device "$root/shared" normal reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"identity already aligned at ceralive.local"* ]]
  [[ "$output" != *"avahi-set-host-name"* ]]
  [[ "$output" != *"systemctl --no-block restart"* ]]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n' "$output"
}

@test "hostname: late Avahi rename advances identity and restarts every consumer" {
  local root="$BATS_TEST_TMPDIR/reconcile-conflict"
  make_hostname_fixture "$root"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]

  printf 'ceralive-2\n' >"$root/avahi/published"
  printf '2\n' >"$root/avahi/state"
  : >"$root/calls"
  run run_hostname_script "$root" "" rename device "$root/shared" normal reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"publication diverged"* ]]
  [[ "$output" == *"index=2"* ]]
  [[ "$output" == *"system-hostname=ceralive2"* ]]
  [[ "$output" == *"hostname-file=ceralive2"* ]]
  [[ "$output" == *"hosts=ceralive2"* ]]
  [[ "$output" == *"published=ceralive2"* ]]
  [[ "$output" == *"systemctl --no-block restart ceralive-tls-firstboot.service nginx.service ceralive.service ceralive-hawkbit-provision.service ceralive-healthcheck.service"* ]]
  [[ "$output" != *"system-hostname=ceralive-2"* ]]
  printf '%s\n' "$output"
}

@test "hostname: registering publication defers reconciliation without churn" {
  local root="$BATS_TEST_TMPDIR/reconcile-registering"
  make_hostname_fixture "$root"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]

  printf '1\n' >"$root/avahi/state"
  : >"$root/calls"
  run run_hostname_script "$root" "" normal device "$root/shared" normal reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *"publication is still registering; deferring"* ]]
  [[ "$output" != *"avahi-set-host-name"* ]]
  [[ "$output" != *"systemctl --no-block restart"* ]]
  [[ "$output" == *"index=1"* ]]
  printf '%s\n' "$output"
}

@test "hostname: malformed reconciliation probe fails closed without mutation" {
  local root="$BATS_TEST_TMPDIR/reconcile-malformed"
  make_hostname_fixture "$root"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]

  : >"$root/calls"
  run run_hostname_script "$root" "" malformed device "$root/shared" normal reconcile
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read a strict Avahi publication snapshot"* ]]
  [[ "$output" != *"avahi-set-host-name"* ]]
  [[ "$output" != *"systemctl --no-block restart"* ]]
  [[ "$output" == *"index=1"* ]]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"hostname-file=ceralive"* ]]
  printf '%s\n' "$output"
}

@test "hostname: interrupted consumer requeue is retried without reallocating" {
  local root="$BATS_TEST_TMPDIR/reconcile-requeue-interruption"
  make_hostname_fixture "$root"
  mkdir -p "$root/data"
  ln -s "$root/data/hostname_consumers_pending" "$root/state/hostname_consumers_pending"
  run run_hostname_script "$root"
  [ "$status" -eq 0 ]

  printf 'ceralive-2\n' >"$root/avahi/published"
  printf '2\n' >"$root/avahi/state"
  : >"$root/calls"
  HOSTNAME_SYSTEMCTL_SCENARIO=fail run run_hostname_script \
    "$root" "" rename device "$root/shared" normal reconcile
  [ "$status" -ne 0 ]
  [ -e "$root/state/hostname_consumers_pending" ]
  [ -L "$root/state/hostname_consumers_pending" ]
  [ -e "$root/data/hostname_consumers_pending" ]
  [[ "$output" == *"failed to requeue identity consumers"* ]]
  [[ "$output" == *"index=2"* ]]
  [[ "$output" == *"system-hostname=ceralive2"* ]]
  [[ "$output" == *"published=ceralive2"* ]]

  : >"$root/calls"
  run run_hostname_script "$root" "" normal device "$root/shared" normal reconcile
  [ "$status" -eq 0 ]
  [ ! -e "$root/state/hostname_consumers_pending" ]
  [ -L "$root/state/hostname_consumers_pending" ]
  [ ! -e "$root/data/hostname_consumers_pending" ]
  [[ "$output" == *"completed pending consumer restart for ceralive2.local"* ]]
  [[ "$output" == *"identity already aligned at ceralive2.local"* ]]
  [[ "$output" != *"avahi-set-host-name"* ]]
  [[ "$output" == *"systemctl --no-block restart ceralive-tls-firstboot.service nginx.service ceralive.service ceralive-hawkbit-provision.service ceralive-healthcheck.service"* ]]
  printf '%s\n' "$output"
}

@test "hostname: TLS certificate follows the committed identity and stays stable" {
  local tls_script="$PIPELINE_DIR/mkosi/runtime/ceralive-tls-firstboot.sh"
  local root="$BATS_TEST_TMPDIR/tls-hostname"
  local bin="$root/bin"
  local cert="$root/state/ceralive.crt"
  local key="$root/state/ceralive.key"
  mkdir -p "$bin"

  grep -Fq 'CERALIVE_TLS_STATE_DIR' "$tls_script"
  cat >"$bin/hostname" <<'SH'
#!/usr/bin/env bash
cat "$TLS_TEST_HOSTNAME_FILE"
SH
  cat >"$bin/ip" <<'SH'
#!/usr/bin/env bash
printf '2: eth0    inet 192.0.2.20/24 brd 192.0.2.255 scope global eth0\n'
SH
  chmod +x "$bin/hostname" "$bin/ip"

  printf 'ceralive\n' >"$root/runtime-hostname"
  TLS_TEST_HOSTNAME_FILE="$root/runtime-hostname" \
    CERALIVE_TLS_STATE_DIR="$root/state" HOSTNAME_BIN="$bin/hostname" IP_BIN="$bin/ip" \
    run bash "$tls_script"
  [ "$status" -eq 0 ]
  [ -s "$cert" ]
  [ -s "$key" ]
  local first_fingerprint
  first_fingerprint="$(openssl x509 -in "$cert" -noout -fingerprint -sha256)"
  [[ "$(openssl x509 -in "$cert" -noout -checkhost ceralive.local 2>/dev/null)" == *"does match certificate"* ]]

  TLS_TEST_HOSTNAME_FILE="$root/runtime-hostname" \
    CERALIVE_TLS_STATE_DIR="$root/state" HOSTNAME_BIN="$bin/hostname" IP_BIN="$bin/ip" \
    run bash "$tls_script"
  [ "$status" -eq 0 ]
  [ "$(openssl x509 -in "$cert" -noout -fingerprint -sha256)" = "$first_fingerprint" ]

  printf 'ceralive2\n' >"$root/runtime-hostname"
  TLS_TEST_HOSTNAME_FILE="$root/runtime-hostname" \
    CERALIVE_TLS_STATE_DIR="$root/state" HOSTNAME_BIN="$bin/hostname" IP_BIN="$bin/ip" \
    run bash "$tls_script"
  [ "$status" -eq 0 ]
  [ "$(openssl x509 -in "$cert" -noout -fingerprint -sha256)" != "$first_fingerprint" ]
  [[ "$(openssl x509 -in "$cert" -noout -checkhost ceralive2.local 2>/dev/null)" == *"does match certificate"* ]]
  [[ "$(openssl x509 -in "$cert" -noout -checkhost ceralive.local 2>/dev/null)" != *"does match certificate"* ]]
  [ "$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')" = \
    "$(openssl pkey -in "$key" -pubout -outform DER | sha256sum | awk '{print $1}')" ]
  printf 'first=%s\nsecond=%s\n' "$first_fingerprint" \
    "$(openssl x509 -in "$cert" -noout -fingerprint -sha256)"
}

@test "dev-sync: target selection is explicit when deterministic names can collide" {
  local missing="$BATS_TEST_TMPDIR/no-dev-sync-config.yaml"
  run env -u DEV_SYNC_TARGET_HOST -u DEV_SYNC_TARGET_IP \
    DEV_SYNC_CONFIG="$missing" DRY_RUN=1 bash "$PIPELINE_DIR/lib/dev-sync/transport.sh" resolve
  [ "$status" -ne 0 ]
  [[ "$output" == *"neither DEV_SYNC_TARGET_HOST nor DEV_SYNC_TARGET_IP is set"* ]]
  [[ "$output" != *"ceralive.local"* ]]
  printf '%s\n' "$output"
}

@test "hostname: valid-looking D-Bus output with trailing data fails closed" {
  local scenario root
  for scenario in misleading-state misleading-name; do
    root="$BATS_TEST_TMPDIR/$scenario"
    make_hostname_fixture "$root"
    run run_hostname_script "$root" "" "$scenario"
    [ "$status" -ne 0 ]
    [[ "$output" == *"index=<missing>"* ]]
    [[ "$output" == *"system-hostname=<missing>"* ]]
    [[ "$output" == *"hostname-file=<missing>"* ]]
    printf 'scenario=%s\n%s\n' "$scenario" "$output"
  done
}

@test "hostname: multiline D-Bus output fails closed without persisting identity" {
  local scenario root
  for scenario in multiline-state multiline-name; do
    root="$BATS_TEST_TMPDIR/$scenario"
    make_hostname_fixture "$root"
    run run_hostname_script "$root" "" "$scenario"
    [ "$status" -ne 0 ]
    [[ "$output" == *"index=<missing>"* ]]
    [[ "$output" == *"hostname-file=<missing>"* ]]
    printf 'scenario=%s\n%s\n' "$scenario" "$output"
  done
}

@test "hostname: setup AP address alone is not accepted as publishable identity" {
  local root="$BATS_TEST_TMPDIR/setup-ap-only"
  make_hostname_fixture "$root"
  HOSTNAME_LOCAL_IP=192.168.42.1 HOSTNAME_LOCAL_IFACE=wlan0 run run_hostname_script "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"index=<missing>"* ]]
  [[ "$output" == *"hostname-file=<missing>"* ]]
  printf '%s\n' "$output"
}

@test "hostname: same-subnet non-AP LAN address remains publishable" {
  local root="$BATS_TEST_TMPDIR/same-subnet-lan"
  make_hostname_fixture "$root"
  HOSTNAME_LOCAL_IP=192.168.42.50 HOSTNAME_LOCAL_IFACE=eth0 run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n' "$output"
}

@test "hostname: Ethernet IPv4 link-local remains a publishable collision domain" {
  local root="$BATS_TEST_TMPDIR/ethernet-link-local"
  make_hostname_fixture "$root"
  HOSTNAME_LOCAL_IP=169.254.50.2 HOSTNAME_LOCAL_IFACE=eth0 run run_hostname_script "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"system-hostname=ceralive"* ]]
  [[ "$output" == *"published=ceralive"* ]]
  printf '%s\n' "$output"
}

@test "hostname: malformed persisted index fails closed without reinterpretation" {
  local root="$BATS_TEST_TMPDIR/malformed-index"
  make_hostname_fixture "$root"
  printf '2stale\n' >"$root/state/host_index"
  run run_hostname_script "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid persisted hostname index"* ]]
  [[ "$output" == *"index=2stale"* ]]
  [[ "$output" == *"system-hostname=<missing>"* ]]
  [[ "$output" == *"hostname-file=<missing>"* ]]
  [[ "$output" == *"published=<missing>"* ]]
  printf '%s\n' "$output"
}

# ===========================================================================
# 16. OTA-during-stream guard (Task 4).
#     /usr/local/bin/ceralive-update (generated by postinst-lib.sh::
#     setup_data_persistence) refuses to install a RAUC bundle while a stream
#     is live. The guard MUST cover the bonding SENDER unit — srtla-send.service
#     — not just the cerastream encoder and the srtla RECEIVER. These tests
#     reconstruct the generated script and drive its guard loop with a stubbed
#     `systemctl is-active`, so they exercise the SHIPPED guard body verbatim
#     (extracted from postinst-lib.sh), with no image boot — UNIT scope.
# ===========================================================================

@test "ota guard: srtla-send.service active BLOCKS the update (bonding sender — Task 4 fix)" {
  run_ota_guard "srtla-send.service"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stream active (srtla-send.service)"* ]]
  [[ "$output" == *"refusing to update"* ]]
}

@test "ota guard: srtla-send.service inactive/absent ALLOWS the update (is-active=inactive for not-installed)" {
  run_ota_guard ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"installing RAUC bundle"* ]]
  [[ "$output" != *"stream active"* ]]
}

@test "ota guard: cerastream.service active STILL blocks (regression — pre-existing check preserved)" {
  run_ota_guard "cerastream.service"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stream active (cerastream.service)"* ]]
}

@test "ota guard: srtla.service (receiver) active STILL blocks (regression — pre-existing check preserved)" {
  run_ota_guard "srtla.service"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stream active (srtla.service)"* ]]
}

@test "ota guard: all three stream units inactive ALLOWS the update (regression)" {
  run_ota_guard ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed to inactive slot"* ]]
}

# ===========================================================================
# 18d. USB-C Type-C source role — the board's connector is a DRP (dual-role)
#      FUSB302/TCPM port, so every fresh boot reads `[dual] source sink` and the
#      Try.SRC/Try.SNK arbitration against the (also dual-role) camera decides
#      the role. When it lands on sink the SoC runs as a USB peripheral and the
#      camera's bus is absent entirely — the "camera sometimes isn't detected
#      over USB-C" complaint. setup_typec_source_role (postinst-lib.sh) installs
#      a oneshot that pins port_type to `source` before cerastream.service.
#      These drive the SHIPPED function and the SHIPPED script against temp
#      install dirs and a fake sysfs tree — no image boot, no hardware.
# ===========================================================================

@test "typec source: the pinning script + boot unit are installed and enabled" {
  local unit_dir="$BATS_TEST_TMPDIR/typec-units"
  local sbin_dir="$BATS_TEST_TMPDIR/typec-sbin"
  local bin="$BATS_TEST_TMPDIR/typec-bin"
  local calls="$BATS_TEST_TMPDIR/typec-calls"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$TYPEC_CALLS"
exit 0
SH
  chmod +x "$bin/systemctl"

  run env PATH="$bin:$PATH" TYPEC_CALLS="$calls" \
    CERALIVE_RUNTIME_SRC="$PIPELINE_DIR/mkosi/runtime" \
    TYPEC_UNIT_DIR="$unit_dir" TYPEC_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_typec_source_role"
  [ "$status" -eq 0 ]
  [ -x "$sbin_dir/ceralive-typec-source" ]
  [ -f "$unit_dir/ceralive-typec-source.service" ]

  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable ceralive-typec-source.service"* ]]
}

@test "typec source: the target is port_type -> source (never sink, never dual)" {
  # `dual` is the broken default and `sink` is the failure mode it resolves to;
  # only `source` removes the arbitration. Locked against a well-meaning "fix".
  local script="$PIPELINE_DIR/mkosi/runtime/ceralive-typec-source.sh"
  grep -Fq 'WANTED_ROLE="source"' "$script"
  grep -Fq '/port_type' "$script"

  run grep -E 'WANTED_ROLE="(sink|dual)"' "$script"
  [ "$status" -ne 0 ]
  run grep -E '^[[:space:]]*printf .*(sink|dual).*>"\$\{ATTR\}"' "$script"
  [ "$status" -ne 0 ]
}

@test "typec source: the unit is ordered before cerastream.service" {
  # cerastream is what actually opens the capture device; ceralive.service is
  # ordered after cerastream, so Before= on both covers the whole camera chain.
  local unit="$PIPELINE_DIR/mkosi/runtime/ceralive-typec-source.service"
  grep -Eq '^Before=.*\bcerastream\.service\b' "$unit"
  grep -Eq '^Before=.*\bceralive\.service\b' "$unit"

  # Ordering-ONLY: a hard dependency would make a board without cerastream fail.
  run grep -Eq '^(Requires|Requisite|BindsTo|Wants)=.*cerastream' "$unit"
  [ "$status" -ne 0 ]
}

@test "typec source: a DRP port reading [dual] is pinned to source" {
  local sysfs="$BATS_TEST_TMPDIR/typec-drp"
  typec_fake_sysfs "$sysfs" '[dual] source sink'

  run env CERALIVE_TYPEC_CLASS_DIR="$sysfs" \
    bash "$PIPELINE_DIR/mkosi/runtime/ceralive-typec-source.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinning port0 from 'dual' to 'source'"* ]]
  run cat "$sysfs/port0/port_type"
  [[ "$output" == "source" ]]
}

@test "typec source: pinning is idempotent — an already-source port is not rewritten" {
  # The kernel prints the whole menu with the ACTIVE entry bracketed, so a
  # pinned port reads `dual [source] sink`, NOT `source`. A naive literal
  # comparison would miss that and rewrite port_type on every boot.
  local sysfs="$BATS_TEST_TMPDIR/typec-idem"
  typec_fake_sysfs "$sysfs" 'dual [source] sink'

  run env CERALIVE_TYPEC_CLASS_DIR="$sysfs" \
    bash "$PIPELINE_DIR/mkosi/runtime/ceralive-typec-source.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already source"* ]]
  # Untouched: the menu string survives, proving no write happened.
  run cat "$sysfs/port0/port_type"
  [[ "$output" == "dual [source] sink" ]]
}

@test "typec source: a late/absent port_type is a bounded wait, never a hang or a failure" {
  # /sys/class/typec/port0 is created by an ASYNCHRONOUS fusb302/TCPM probe, so
  # the script must poll to a deadline — not sleep a fixed amount and hope.
  local sysfs="$BATS_TEST_TMPDIR/typec-empty"
  mkdir -p "$sysfs"

  run env CERALIVE_TYPEC_CLASS_DIR="$sysfs" CERALIVE_TYPEC_WAIT=1 \
    bash "$PIPELINE_DIR/mkosi/runtime/ceralive-typec-source.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not appear within 1s"* ]]

  # A board with no Type-C class at all is a clean no-op, not a boot failure.
  run env CERALIVE_TYPEC_CLASS_DIR="$BATS_TEST_TMPDIR/typec-absent" \
    bash "$PIPELINE_DIR/mkosi/runtime/ceralive-typec-source.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to pin"* ]]

  # The wait is a deadline-bounded poll, not a bare fixed settle constant.
  grep -Fq 'deadline=$((SECONDS + WAIT_SECONDS))' "$PIPELINE_DIR/mkosi/runtime/ceralive-typec-source.sh"
}

@test "typec source: a role change that does not take FAILS loudly (read-back verified)" {
  # /dev/null accepts the write and reads back empty — the same observable shape
  # as a TCPM that refuses the role change. It must not be reported as success.
  local sysfs="$BATS_TEST_TMPDIR/typec-nulled"
  mkdir -p "$sysfs/port0"
  printf '%s\n' '[dual] source sink' >"$sysfs/port0/real_port_type"
  ln -sf /dev/null "$sysfs/port0/port_type"

  run env CERALIVE_TYPEC_CLASS_DIR="$sysfs" \
    bash "$PIPELINE_DIR/mkosi/runtime/ceralive-typec-source.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"after writing 'source'"* ]]
}

@test "typec source: missing runtime source FAILS the build (fail-closed, nothing installed)" {
  local unit_dir="$BATS_TEST_TMPDIR/typec-failclosed-units"
  local sbin_dir="$BATS_TEST_TMPDIR/typec-failclosed-sbin"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/empty-src" \
    TYPEC_UNIT_DIR="$unit_dir" TYPEC_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_typec_source_role"
  [ "$status" -ne 0 ]
  [[ "$output" == *"typec-source script not found"* ]]
  [ ! -e "$unit_dir/ceralive-typec-source.service" ]
}

@test "typec source: pinning is wired into configure_services" {
  # An unreferenced setup function is dead code — the camera race would ship.
  run grep -E '^\s*setup_typec_source_role$' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# 18e. Boot dead-weight masks — six stock units that cost a shipped Rock 5B+
#      ~2 minutes of EVERY boot and left it permanently `degraded`.
#      systemd-networkd{,.socket,-wait-online} can never be satisfied (NM owns
#      every link; networkctl reports all `unmanaged`), yet wait-online burned a
#      flat 120s inside network-online.target and held ceralive.service — the
#      CeraUI web UI on :80 — unreachable for 2 minutes after power-on.
#      systemd-machine-id-commit fails forever because OUR OWN migrate-data bind
#      mount satisfies its ConditionPathIsMountPoint while the bind source is real
#      ext4. Standalone dnsmasq.service always loses port 53 to systemd-resolved.
#      chrony-wait blocks multi-user.target ~21s for NTP convergence nothing
#      orders itself after. These drive the SHIPPED function against a temp mask
#      dir (CERALIVE_MASK_UNIT_DIR) with a faithful `systemctl mask` stub — no
#      image boot, no hardware, UNIT scope.
# ===========================================================================

@test "boot unit masks: all six unusable/blocking units are masked to /dev/null" {
  local bin="$BATS_TEST_TMPDIR/mask-bin"
  local calls="$BATS_TEST_TMPDIR/mask-calls"
  local dir="$BATS_TEST_TMPDIR/mask-units"
  rm -rf "$bin" "$calls" "$dir"
  mask_stub_bin "$bin"

  run env PATH="$bin:$PATH" MASK_CALLS="$calls" CERALIVE_MASK_UNIT_DIR="$dir" \
    bash -c "source '$POSTINST_ENTRY'; suppress_unusable_boot_units"
  [ "$status" -eq 0 ]

  local unit
  for unit in systemd-networkd.service systemd-networkd.socket \
              systemd-networkd-wait-online.service \
              systemd-machine-id-commit.service dnsmasq.service \
              chrony-wait.service; do
    [ -L "$dir/$unit" ]
    [ "$(readlink "$dir/$unit")" = "/dev/null" ]
  done
}

@test "boot unit masks: masking systemd-networkd.service itself closes the Also= resurrection path" {
  # Debian's 90-systemd.preset says `enable systemd-networkd.service` AND
  # `disable systemd-networkd-wait-online.service` — and the disable LOSES, because
  # systemd-networkd.service's [Install] carries
  # `Also=systemd-networkd-wait-online.service`, applied unconditionally by enable.
  # Masking the parent is what makes that Also= unreachable, so both must be masked.
  grep -Fq 'Also=systemd-networkd-wait-online.service' \
    "$PIPELINE_DIR/mkosi/build/runtime/usr/lib/systemd/system/systemd-networkd.service" \
    || skip "built runtime tree not present — Also= premise checked on the real unit only"

  local bin="$BATS_TEST_TMPDIR/mask-also-bin"
  local calls="$BATS_TEST_TMPDIR/mask-also-calls"
  local dir="$BATS_TEST_TMPDIR/mask-also-units"
  rm -rf "$bin" "$calls" "$dir"
  mask_stub_bin "$bin"

  run env PATH="$bin:$PATH" MASK_CALLS="$calls" CERALIVE_MASK_UNIT_DIR="$dir" \
    bash -c "source '$POSTINST_ENTRY'; suppress_unusable_boot_units"
  [ "$status" -eq 0 ]
  [ -L "$dir/systemd-networkd.service" ]
  [ -L "$dir/systemd-networkd-wait-online.service" ]
}

@test "boot unit masks: mask, NOT disable — first-boot preset-all would undo a disable" {
  # /etc/machine-id ships as the literal string `uninitialized`, so every freshly
  # flashed board is a systemd FIRST BOOT and PID 1 runs `preset-all`, re-applying
  # the vendor presets over anything this build merely disabled. `systemctl enable`
  # refuses to act on a masked unit, so only a mask survives.
  run grep -E '^\s*mask_service "\$\{svc\}"' "$POSTINST_LIB"
  [ "$status" -eq 0 ]

  local unit
  for unit in systemd-networkd systemd-networkd-wait-online \
              systemd-machine-id-commit dnsmasq chrony-wait; do
    run grep -E "disable_service ${unit}" "$POSTINST_LIB"
    [ "$status" -ne 0 ]
  done
}

@test "boot unit masks: a mask that does not land FAILS the build (fail-closed, never silent)" {
  # A silently-ineffective mask ships the exact defect back to the fleet on an image
  # that otherwise builds, boots and passes every other gate — so the shipped
  # function VERIFIES the symlink instead of trusting the systemctl exit status.
  local bin="$BATS_TEST_TMPDIR/mask-noop-bin"
  local dir="$BATS_TEST_TMPDIR/mask-noop-units"
  rm -rf "$bin" "$dir"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$bin/systemctl"

  run env PATH="$bin:$PATH" CERALIVE_MASK_UNIT_DIR="$dir" \
    bash -c "source '$POSTINST_ENTRY'; suppress_unusable_boot_units"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mask did not land"* ]]
  [ ! -e "$dir/systemd-networkd.service" ]
}

@test "boot unit masks: NEVER widen to NetworkManager, resolved, udevd or chronyd" {
  # NM is the only network stack; systemd-resolved owns :53 and the resolv.conf stub;
  # systemd-udevd's BUILT-IN net_setup_link (not networkd) consumes the .link files
  # that produce eth0/wlan0 for SRTLA's bonding globs; chrony.service is the NTP
  # daemon itself — only its boot-blocking chrony-wait sibling may be masked.
  local bin="$BATS_TEST_TMPDIR/mask-scope-bin"
  local calls="$BATS_TEST_TMPDIR/mask-scope-calls"
  local dir="$BATS_TEST_TMPDIR/mask-scope-units"
  rm -rf "$bin" "$calls" "$dir"
  mask_stub_bin "$bin"

  run env PATH="$bin:$PATH" MASK_CALLS="$calls" CERALIVE_MASK_UNIT_DIR="$dir" \
    bash -c "source '$POSTINST_ENTRY'; suppress_unusable_boot_units"
  [ "$status" -eq 0 ]

  run grep -cE '^systemctl mask ' "$calls"
  [ "$output" -eq 6 ]

  run grep -E '^systemctl mask (NetworkManager|systemd-resolved|systemd-udevd|systemd-networkd-generator|chrony)\.(service|socket)$' "$calls"
  [ "$status" -ne 0 ]

  # The positive half: the units above are still ENABLED and the .link writer intact.
  run grep -E '^\s*for svc in systemd-resolved NetworkManager ModemManager chrony avahi-daemon' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
  run grep -F '/etc/systemd/network/10-ceralive-${role}.link' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
}

@test "boot unit masks: suppression is wired into configure_services" {
  # An unreferenced setup function is dead code — the 2-minute stall would ship.
  run grep -E '^\s*suppress_unusable_boot_units$' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
}

@test "BT policy: BlueALSA capture packages and the bluetooth enable state survive an A/B OTA" {
  local packages="$BATS_TEST_TMPDIR/bluetooth-runtime-packages"
  sed 's/#.*//' "$PIPELINE_DIR/manifests/packages/shared.list" | awk 'NF { print $1 }' >"$packages"

  local package
  for package in bluez bluez-alsa-utils libasound2-plugin-bluez; do
    run grep -Fx "$package" "$packages"
    [ "$status" -eq 0 ]
  done

  run grep -F 'disable_service cups.service' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
  run grep -F 'disable_service "bluetooth.service"' "$POSTINST_LIB"
  [ "$status" -ne 0 ]
  run grep -E '(enable_service|systemctl enable).*bluealsad' "$POSTINST_LIB"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# 18f. Fan curve — the RK3588 package thermal zone ships `active` trips at 55 C
#      and 65 C plus `critical` at 115 C, so the pwm-fan stays silent through
#      idle (measured 46-52 C at rest on a Rock 5B+) and then snaps on audibly.
#      setup_fan_curve (postinst-lib.sh) installs a oneshot that LOWERS exactly
#      one value: the temperature of the FIRST `active` trip in the zone bound to
#      the pwm-fan cooling device. The kernel step_wise governor (live-proven to
#      auto-step cur_state 0 -> 1 at a real trip crossing and revert cleanly)
#      keeps doing all the actual fan control.
#
#      The fixture below deliberately numbers everything DIFFERENTLY from the
#      reference board — pwm-fan is cooling_device7 (not 4), the zone is
#      thermal_zone3 (not 0), it is the zone's cdev1 (not cdev0), and the first
#      `active` trip is index 1 behind a `critical` at index 0. A hardcoded index
#      anywhere in the discovery therefore fails these tests. No image boot, no
#      hardware, UNIT scope.
# ===========================================================================

@test "fan curve: the lowering script + boot unit are installed and enabled" {
  local unit_dir="$BATS_TEST_TMPDIR/fan-units"
  local sbin_dir="$BATS_TEST_TMPDIR/fan-sbin"
  local bin="$BATS_TEST_TMPDIR/fan-bin"
  local calls="$BATS_TEST_TMPDIR/fan-calls"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$FAN_CALLS"
exit 0
SH
  chmod +x "$bin/systemctl"

  run env PATH="$bin:$PATH" FAN_CALLS="$calls" \
    CERALIVE_RUNTIME_SRC="$PIPELINE_DIR/mkosi/runtime" \
    FAN_CURVE_UNIT_DIR="$unit_dir" FAN_CURVE_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_fan_curve"
  [ "$status" -eq 0 ]
  [ -x "$sbin_dir/ceralive-fan-curve" ]
  [ -f "$unit_dir/ceralive-fan-curve.service" ]

  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable ceralive-fan-curve.service"* ]]
}

@test "fan curve: discovery is generic — pwm-fan is found at ANY cooling_device/zone/cdev/trip index" {
  # Reference hardware is cooling_device4 in thermal_zone0; this fixture is
  # cooling_device7 in thermal_zone3 at cdev1 with the first active trip at
  # index 1. Any hardcoded index fails here.
  local sysfs="$BATS_TEST_TMPDIR/fan-generic"
  fan_fake_thermal "$sysfs"

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cooling_device7"* ]]
  [[ "$output" == *"thermal_zone3"* ]]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "45000" ]

  # And no executable line in the shipped script may name a concrete index.
  run bash -c "grep -vE '^[[:space:]]*#' '$(FAN_SCRIPT)' | grep -E 'thermal_zone[0-9]|cooling_device[0-9]'"
  [ "$status" -ne 0 ]
}

@test "fan curve: ONLY the first active trip moves — critical and every other trip are untouched" {
  # This is the core safety property. `critical` at 115 C is the board's last
  # line of defence; the second `active` trip and the decoy zone's own active
  # trip are equally out of scope.
  local sysfs="$BATS_TEST_TMPDIR/fan-scope"
  fan_fake_thermal "$sysfs"

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]

  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_0_temp")" = "115000" ]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_2_temp")" = "65000" ]
  [ "$(fan_attr "$sysfs/thermal_zone0/trip_point_0_temp")" = "70000" ]
  [ "$(fan_attr "$sysfs/thermal_zone0/trip_point_1_temp")" = "115000" ]

  # Nothing else in the tree may have been written either.
  [ "$(fan_attr "$sysfs/thermal_zone3/mode")" = "enabled" ]
  [ "$(fan_attr "$sysfs/thermal_zone0/mode")" = "enabled" ]
  [ "$(fan_attr "$sysfs/cooling_device7/cur_state")" = "0" ]
}

@test "fan curve: the script never writes mode/cur_state/pwm and runs no polling loop" {
  # Disabling a zone would ALSO disable its critical trip; driving cur_state or
  # the hwmon pwm node means owning the fan forever. The kernel governor already
  # works — this unit only moves the threshold it acts on.
  local script unit
  script="$(FAN_SCRIPT)"
  unit="$(FAN_UNIT)"

  # No executable line may even MENTION the attributes that would take ownership
  # of the fan or switch the zone off (and with it the 115 C critical trip).
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -E '(cur_state|emul_temp|/mode|pwm1)'"
  [ "$status" -ne 0 ]

  # A oneshot that exits, never a resident monitor or a timer.
  grep -Eq '^Type=oneshot$' "$unit"
  run grep -E '^(Type=(simple|notify|exec)|Restart=(always|on-failure))' "$unit"
  [ "$status" -ne 0 ]
  run grep -E '^(OnCalendar|OnUnitActiveSec)=' "$unit"
  [ "$status" -ne 0 ]

  # Exactly ONE sysfs write exists in the whole script, and it is the trip temp.
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -cE '>\"\\\$\{temp_attr\}\"'"
  [ "$output" -eq 1 ]
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -cE '^[^#]*>[[:space:]]*\"?\\\$\{(THERMAL_DIR|zone|temp_attr)'"
  [ "$output" -eq 1 ]
}

@test "fan curve: a board with no pwm-fan cooling device is an informational no-op, not a failure" {
  # x86-minipc has a populated /sys/class/thermal (ACPI) and no pwm-fan at all.
  local sysfs="$BATS_TEST_TMPDIR/fan-nofan"
  rm -rf "$sysfs"
  mkdir -p "$sysfs/cooling_device0" "$sysfs/thermal_zone0"
  printf 'Processor\n' >"$sysfs/cooling_device0/type"
  printf 'acpitz\n' >"$sysfs/thermal_zone0/type"
  ln -s ../cooling_device0 "$sysfs/thermal_zone0/cdev0"
  printf 'active\n' >"$sysfs/thermal_zone0/trip_point_0_type"
  printf '80000\n' >"$sysfs/thermal_zone0/trip_point_0_temp"

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" CERALIVE_FAN_WAIT=1 bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no fan to re-curve"* ]]
  [ "$(fan_attr "$sysfs/thermal_zone0/trip_point_0_temp")" = "80000" ]

  # A board with no thermal class at all is equally a clean no-op.
  run env CERALIVE_FAN_THERMAL_DIR="$BATS_TEST_TMPDIR/fan-absent" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no thermal class"* ]]

  # The wait is a deadline-bounded poll, not a bare fixed settle constant.
  grep -Fq 'deadline=$((SECONDS + WAIT_SECONDS))' "$(FAN_SCRIPT)"
}

@test "fan curve: a pwm-fan zone with no active trip is skipped, never failed or force-written" {
  local sysfs="$BATS_TEST_TMPDIR/fan-noactive"
  fan_fake_thermal "$sysfs"
  printf 'passive\n' >"$sysfs/thermal_zone3/trip_point_1_type"
  printf 'passive\n' >"$sysfs/thermal_zone3/trip_point_2_type"

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"declares no 'active' trip"* ]]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_0_temp")" = "115000" ]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "55000" ]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_2_temp")" = "65000" ]
}

@test "fan curve: lowering is idempotent and can only ever LOWER, never raise" {
  local sysfs="$BATS_TEST_TMPDIR/fan-idem"
  fan_fake_thermal "$sysfs"

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "45000" ]

  # Second run: no error, no rewrite, and it says so.
  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"at or below"* ]]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "45000" ]

  # An operator (or a future DT) that already set a COOLER trip keeps it.
  printf '38000\n' >"$sysfs/thermal_zone3/trip_point_1_temp"
  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "38000" ]
}

@test "fan curve: the threshold is one named constant, defaulting to 45000 m°C and band-clamped" {
  # 45 C sits just under the 46-52 C idle band measured on a Rock 5B+, so the fan
  # idles gently instead of waiting for the stock 55 C. It is a named constant
  # precisely so it can be retuned without touching the discovery logic.
  grep -Eq '^FAN_TRIP_MILLICELSIUS="\$\{CERALIVE_FAN_TRIP_MILLIC:-45000\}"$' "$(FAN_SCRIPT)"

  local sysfs="$BATS_TEST_TMPDIR/fan-tunable"
  fan_fake_thermal "$sysfs"
  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" CERALIVE_FAN_TRIP_MILLIC=50000 bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "50000" ]

  # A value anywhere near the 115 C critical trip would defeat the whole point.
  fan_fake_thermal "$sysfs"
  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" CERALIVE_FAN_TRIP_MILLIC=110000 bash "$(FAN_SCRIPT)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside the accepted"* ]]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_1_temp")" = "55000" ]

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" CERALIVE_FAN_TRIP_MILLIC=forty bash "$(FAN_SCRIPT)"
  [ "$status" -ne 0 ]
}

@test "fan curve: a write the kernel ACCEPTS but ignores FAILS loudly (read-back verified)" {
  # The observable shape of a thermal core that takes the write and then clamps
  # or discards it: a `cat` double keeps answering the stale value, so the write
  # succeeds and the read-back disagrees. Silently reporting that as success is
  # exactly how a fan fix ships without ever having changed anything.
  local sysfs="$BATS_TEST_TMPDIR/fan-stale"
  local bin="$BATS_TEST_TMPDIR/fan-stale-bin"
  fan_fake_thermal "$sysfs"
  mkdir -p "$bin"
  cat >"$bin/cat" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */trip_point_1_temp) printf '55000\n'; exit 0 ;;
  esac
done
exec "$(PATH=/usr/bin:/bin command -v cat)" "$@"
SH
  chmod +x "$bin/cat"

  run env PATH="$bin:$PATH" CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"after accepting a write"* ]]
}

@test "fan curve: an unwritable or nonsensical trip WARNs and exits 0 (RO is a legal ABI configuration)" {
  # `trip_point_Y_temp` is documented "RO, Optional" in
  # Documentation/ABI/testing/sysfs-class-thermal, so a zone whose driver offers
  # no setter is a LEGAL configuration — the board keeps its stock curve and
  # nothing is broken. That must never become a failed unit on every boot.
  local sysfs="$BATS_TEST_TMPDIR/fan-nonnumeric"
  fan_fake_thermal "$sysfs"
  ln -sf /dev/null "$sysfs/thermal_zone3/trip_point_1_temp"

  run env CERALIVE_FAN_THERMAL_DIR="$sysfs" bash "$(FAN_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a temperature"* ]]
  [ "$(fan_attr "$sysfs/thermal_zone3/trip_point_0_temp")" = "115000" ]

  if [ "$(id -u)" -ne 0 ]; then
    local ro="$BATS_TEST_TMPDIR/fan-readonly"
    fan_fake_thermal "$ro"
    chmod 0444 "$ro/thermal_zone3/trip_point_1_temp"
    run env CERALIVE_FAN_THERMAL_DIR="$ro" bash "$(FAN_SCRIPT)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"refused the write"* ]]
    [ "$(fan_attr "$ro/thermal_zone3/trip_point_1_temp")" = "55000" ]
  fi
}

@test "fan curve: missing runtime source FAILS the build (fail-closed, nothing installed)" {
  local unit_dir="$BATS_TEST_TMPDIR/fan-failclosed-units"
  local sbin_dir="$BATS_TEST_TMPDIR/fan-failclosed-sbin"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/empty-src" \
    FAN_CURVE_UNIT_DIR="$unit_dir" FAN_CURVE_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_fan_curve"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fan-curve script not found"* ]]
  [ ! -e "$unit_dir/ceralive-fan-curve.service" ]
}

@test "fan curve: the fix is wired into configure_services and registered in the drift gate" {
  # An unreferenced setup function is dead code — the silent-until-55C fan ships.
  run grep -E '^\s*setup_fan_curve$' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
  # Standalone-artifact idiom: defined once in postinst-lib.sh, never inlined.
  grep -Fq 'setup_fan_curve' "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  run grep -cE '^setup_fan_curve\(\) \{' "$POSTINST_LIB"
  [ "$output" -eq 1 ]
}

# ===========================================================================
# 18g. Status LEDs — the board's indicator LEDs are registered by the kernel and
#      then left completely unconfigured (`trigger = [none]`, `brightness = 0`),
#      so a headless appliance gives its operator no visual feedback at all.
#      setup_led_status (postinst-lib.sh) installs a oneshot that assigns the
#      FIRST discovered indicator LED the `heartbeat` trigger and the SECOND the
#      `mmc1` trigger, and writes nothing else — never `brightness`, which would
#      fight the trigger it just installed.
#
#      The reference board (Orange Pi 5 Plus) names its LEDs `blue:indicator-1`
#      (gpio-leds), `green:indicator-2` (pwm-leds) and `mmc0::` (the MMC host's
#      own, already-working activity LED). The fixture below deliberately uses
#      DIFFERENT names — `amber:status-a`, `white:status-b`, `mmc2::` and a
#      `red:power` decoy — so any hardcoded LED name, and any `mmc0`-literal
#      exclusion, fails these tests. Note the fixture's sort order is also not
#      the discovery order of the names it stands in for. No image boot, no
#      hardware, UNIT scope.
# ===========================================================================

@test "led status: the trigger script + boot unit are installed and enabled" {
  local unit_dir="$BATS_TEST_TMPDIR/led-units"
  local sbin_dir="$BATS_TEST_TMPDIR/led-sbin"
  local bin="$BATS_TEST_TMPDIR/led-bin"
  local calls="$BATS_TEST_TMPDIR/led-calls"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$LED_CALLS"
exit 0
SH
  chmod +x "$bin/systemctl"

  run env PATH="$bin:$PATH" LED_CALLS="$calls" \
    CERALIVE_RUNTIME_SRC="$PIPELINE_DIR/mkosi/runtime" \
    LED_STATUS_UNIT_DIR="$unit_dir" LED_STATUS_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_led_status"
  [ "$status" -eq 0 ]
  [ -x "$sbin_dir/ceralive-led-status" ]
  [ -f "$unit_dir/ceralive-led-status.service" ]

  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable ceralive-led-status.service"* ]]
}

@test "led status: discovery is generic — indicator LEDs are found under ANY name" {
  # The reference board is blue:indicator-1 / green:indicator-2; this fixture is
  # amber:status-a / white:status-b. Any hardcoded name fails here.
  local sysfs="$BATS_TEST_TMPDIR/led-generic"
  led_fake_class "$sysfs"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]
  [ "$(led_attr "$sysfs/amber:status-a/trigger")" = "heartbeat" ]
  [ "$(led_attr "$sysfs/white:status-b/trigger")" = "mmc1" ]

  # And no executable line in the shipped script may name a concrete LED, a
  # concrete LED index, or the reference board's vendor DTS labels.
  run bash -c "grep -vE '^[[:space:]]*#' '$(LED_SCRIPT)' | grep -E 'indicator-[0-9]|blue:|green:|mmc0|led[0-9]'"
  [ "$status" -ne 0 ]
}

@test "led status: the kernel's own mmc* LED and a power indicator are never touched" {
  # mmc0::/mmc1:: are the MMC core's activity LEDs — already working, kernel
  # managed, and not indicator LEDs. A power-rail LED must keep meaning "powered".
  local sysfs="$BATS_TEST_TMPDIR/led-reserved"
  led_fake_class "$sysfs"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mmc2::"* ]]
  [[ "$output" == *"red:power"* ]]

  [ "$(led_attr "$sysfs/mmc2::/trigger")" = "nonerfkill-anyheartbeat[mmc2]mmc1" ]
  [ "$(led_attr "$sysfs/red:power/trigger")" = "[none]rfkill-anyheartbeatmmc0mmc1" ]
  [ "$(led_attr "$sysfs/mmc2::/brightness")" = "0" ]
  [ "$(led_attr "$sysfs/red:power/brightness")" = "1" ]
}

@test "led status: brightness is NEVER written and the unit runs no polling loop" {
  # Assigning a trigger hands the LED to the kernel; writing brightness
  # afterwards fights the very trigger just installed — the same
  # "kernel does 100% of the driving" rule ceralive-fan-curve follows.
  local script unit sysfs
  script="$(LED_SCRIPT)"
  unit="$(LED_UNIT)"
  sysfs="$BATS_TEST_TMPDIR/led-nobrightness"
  led_fake_class "$sysfs"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$script"
  [ "$status" -eq 0 ]
  [ "$(led_attr "$sysfs/amber:status-a/brightness")" = "0" ]
  [ "$(led_attr "$sysfs/white:status-b/brightness")" = "0" ]

  # The script never even constructs a brightness path.
  run grep -F '/brightness' "$script"
  [ "$status" -ne 0 ]

  # Exactly ONE sysfs write exists in the whole script, and it is the trigger.
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -cE '>\"\\\$\{trigger_attr\}\"'"
  [ "$output" -eq 1 ]
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -cE '^[^#]*>[[:space:]]*\"?\\\$\{(LED_CLASS_DIR|led|trigger_attr)'"
  [ "$output" -eq 1 ]

  # A oneshot that exits, never a resident monitor or a timer.
  grep -Eq '^Type=oneshot$' "$unit"
  run grep -E '^(Type=(simple|notify|exec)|Restart=(always|on-failure))' "$unit"
  [ "$status" -ne 0 ]
  run grep -E '^(OnCalendar|OnUnitActiveSec)=' "$unit"
  [ "$status" -ne 0 ]
  # Nothing consumes an LED trigger, so this must not sit on any unit's
  # critical path — a board with no LEDs would pay the bounded wait for nothing.
  run grep -E '^Before=' "$unit"
  [ "$status" -ne 0 ]
}

@test "led status: zero, one and more-than-two LED boards are all informational no-ops" {
  local script sysfs
  script="$(LED_SCRIPT)"

  # No LED class at all (a board or kernel without CONFIG_LEDS_CLASS).
  run env CERALIVE_LED_CLASS_DIR="$BATS_TEST_TMPDIR/led-absent" bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no LED class"* ]]

  # An empty LED class.
  sysfs="$BATS_TEST_TMPDIR/led-empty"
  rm -rf "$sysfs"; mkdir -p "$sysfs"
  run env CERALIVE_LED_CLASS_DIR="$sysfs" CERALIVE_LED_WAIT=1 bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no LEDs under"* ]]

  # Only kernel-managed/reserved LEDs — nothing free to configure.
  sysfs="$BATS_TEST_TMPDIR/led-onlymmc"
  rm -rf "$sysfs"; mkdir -p "$sysfs/mmc1::"
  printf 'none [mmc1] heartbeat\n' >"$sysfs/mmc1::/trigger"
  run env CERALIVE_LED_CLASS_DIR="$sysfs" CERALIVE_LED_WAIT=1 bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kernel-managed or reserved"* ]]
  [ "$(led_attr "$sysfs/mmc1::/trigger")" = "none[mmc1]heartbeat" ]

  # Exactly one free LED: it gets the heartbeat and the policy simply runs out.
  sysfs="$BATS_TEST_TMPDIR/led-one"
  rm -rf "$sysfs"; mkdir -p "$sysfs/violet:lonely"
  printf '[none] heartbeat mmc1\n' >"$sysfs/violet:lonely/trigger"
  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$script"
  [ "$status" -eq 0 ]
  [ "$(led_attr "$sysfs/violet:lonely/trigger")" = "heartbeat" ]

  # Three free LEDs: the first two are assigned, the surplus is logged and left
  # exactly as the kernel set it.
  sysfs="$BATS_TEST_TMPDIR/led-three"
  led_fake_class "$sysfs"
  mkdir -p "$sysfs/zzz:spare"
  printf '[none] heartbeat mmc1\n' >"$sysfs/zzz:spare/trigger"
  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no trigger left in the policy"* ]]
  [ "$(led_attr "$sysfs/amber:status-a/trigger")" = "heartbeat" ]
  [ "$(led_attr "$sysfs/white:status-b/trigger")" = "mmc1" ]
  [ "$(led_attr "$sysfs/zzz:spare/trigger")" = "[none]heartbeatmmc1" ]

  # The wait is a deadline-bounded poll, not a bare fixed settle constant.
  grep -Fq 'deadline=$((SECONDS + WAIT_SECONDS))' "$script"
}

@test "led status: an LED that already has a trigger is never re-pointed (idempotent)" {
  local sysfs="$BATS_TEST_TMPDIR/led-idem"
  led_fake_class "$sysfs"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]

  # Re-render the trigger files the way real sysfs does — the whole menu with
  # the active entry in brackets. A naive literal compare is never true here,
  # which is the bracket trap ceralive-typec-source documents for port_type.
  printf 'none rfkill-any [heartbeat] mmc0 mmc1\n' >"$sysfs/amber:status-a/trigger"
  printf 'none rfkill-any heartbeat mmc0 [mmc1]\n' >"$sysfs/white:status-b/trigger"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already driven by the 'heartbeat' trigger"* ]]
  [[ "$output" == *"already driven by the 'mmc1' trigger"* ]]
  [ "$(led_attr "$sysfs/amber:status-a/trigger")" = "nonerfkill-any[heartbeat]mmc0mmc1" ]

  # An operator (or a device tree default-trigger) that already claimed an LED
  # for something else keeps it.
  printf 'none [panic] heartbeat mmc1\n' >"$sysfs/amber:status-a/trigger"
  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]
  [ "$(led_attr "$sysfs/amber:status-a/trigger")" = "none[panic]heartbeatmmc1" ]
}

@test "led status: a trigger this kernel does not offer is skipped, never forced" {
  # The trigger menu is the kernel's own answer about what it supports; writing
  # a name that is not in it just yields EINVAL and a failed unit on every boot.
  local sysfs="$BATS_TEST_TMPDIR/led-notoffered"
  led_fake_class "$sysfs"
  printf '[none] rfkill-any usbport\n' >"$sysfs/amber:status-a/trigger"
  printf '[none] rfkill-any usbport heartbeat\n' >"$sysfs/white:status-b/trigger"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not offer a 'heartbeat' trigger"* ]]
  [[ "$output" == *"does not offer a 'mmc1' trigger"* ]]
  [ "$(led_attr "$sysfs/amber:status-a/trigger")" = "[none]rfkill-anyusbport" ]
  [ "$(led_attr "$sysfs/white:status-b/trigger")" = "[none]rfkill-anyusbportheartbeat" ]
}

@test "led status: a write the kernel ACCEPTS but ignores FAILS loudly (read-back verified)" {
  # The observable shape of an LED core that takes the write and then discards
  # it: `cat` keeps answering the stale menu, so the write succeeds and the
  # read-back disagrees. Reporting that as success is exactly how an LED fix
  # ships without ever having lit anything.
  local sysfs="$BATS_TEST_TMPDIR/led-stale"
  local bin="$BATS_TEST_TMPDIR/led-stale-bin"
  led_fake_class "$sysfs"
  mkdir -p "$bin"
  cat >"$bin/cat" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */amber:status-a/trigger) printf '[none] heartbeat mmc0 mmc1\n'; exit 0 ;;
  esac
done
exec "$(PATH=/usr/bin:/bin command -v cat)" "$@"
SH
  chmod +x "$bin/cat"

  run env PATH="$bin:$PATH" CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"after accepting a write"* ]]
}

@test "led status: an unwritable trigger WARNs and exits 0 (a dark LED is the state it shipped in)" {
  if [ "$(id -u)" -eq 0 ]; then skip "root ignores file permissions"; fi
  local sysfs="$BATS_TEST_TMPDIR/led-readonly"
  led_fake_class "$sysfs"
  chmod 0444 "$sysfs/amber:status-a/trigger"

  run env CERALIVE_LED_CLASS_DIR="$sysfs" bash "$(LED_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refused the write"* ]]
  [ "$(led_attr "$sysfs/amber:status-a/trigger")" = "[none]rfkill-anykbd-scrolllockheartbeatmmc0mmc1usbport" ]
  # The second LED is still configured — one bad node is not a reason to stop.
  [ "$(led_attr "$sysfs/white:status-b/trigger")" = "mmc1" ]
}

@test "led status: missing runtime source FAILS the build (fail-closed, nothing installed)" {
  local unit_dir="$BATS_TEST_TMPDIR/led-failclosed-units"
  local sbin_dir="$BATS_TEST_TMPDIR/led-failclosed-sbin"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/empty-src" \
    LED_STATUS_UNIT_DIR="$unit_dir" LED_STATUS_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_led_status"
  [ "$status" -ne 0 ]
  [[ "$output" == *"led-status script not found"* ]]
  [ ! -e "$unit_dir/ceralive-led-status.service" ]
}

@test "led status: the fix is wired into configure_services and registered in the drift gate" {
  # An unreferenced setup function is dead code — the dark LEDs ship.
  run grep -E '^\s*setup_led_status$' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
  # Standalone-artifact idiom: defined once in postinst-lib.sh, never inlined.
  grep -Fq 'setup_led_status' "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  run grep -cE '^setup_led_status\(\) \{' "$POSTINST_LIB"
  [ "$output" -eq 1 ]
}

# ===========================================================================
# 29. Fan kick-start — setup_fan_curve fixed WHEN the pwm-fan is asked to spin;
#     this covers the fact that the state it is asked INTO is too weak to start
#     it from a dead stop. Measured on a live Orange Pi 5 Plus, the first active
#     state is 70/255 (~27.5% duty): enough to sustain a turning rotor, not
#     enough to break stiction on a stopped one, so the fan sits energised and
#     stalled until someone nudges it by hand.
#
#     ceralive-fan-kickstart.service watches the pwm-fan cooling device's own
#     cur_state for a 0 -> nonzero transition and, on that edge only, drives it
#     to max_state for a bounded window before writing the governor's own
#     commanded state straight back.
#
#     THE RESTORE IS THE LOAD-BEARING PART AND THESE TESTS PIN IT. On this
#     kernel a userspace cur_state write is STICKY, not self-correcting:
#     cur_state_store never clears cdev->updated, thermal_cdev_update()
#     short-circuits while that flag is set, and step_wise clears it only when
#     its computed target CHANGES. "Write max_state and let the governor's next
#     poll fix it" would therefore leave the fan at full speed for as long as
#     the temperature stayed inside one trip band.
#
#     Unlike every other unit in this family this one is RESIDENT, not a boot
#     oneshot, because the fan returns to state 0 and re-enters an active state
#     many times over a device's uptime and every re-entry is a fresh dead start.
#
#     The reference board is cooling_device4 with max_state 4 and cooling-levels
#     `0 70 75 80 100`. The fixture below deliberately uses cooling_device6 with
#     max_state 6 behind a decoy CPUFreq cooling_device2, so any hardcoded index
#     and any hand-invented "100%" kick value fails these tests. No image boot,
#     no hardware, UNIT scope.
# ===========================================================================

@test "fan kickstart: the monitor script + unit are installed and enabled" {
  local unit_dir="$BATS_TEST_TMPDIR/fk-units"
  local sbin_dir="$BATS_TEST_TMPDIR/fk-sbin"
  local bin="$BATS_TEST_TMPDIR/fk-bin"
  local calls="$BATS_TEST_TMPDIR/fk-calls"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$FK_CALLS"
exit 0
SH
  chmod +x "$bin/systemctl"

  run env PATH="$bin:$PATH" FK_CALLS="$calls" \
    CERALIVE_RUNTIME_SRC="$PIPELINE_DIR/mkosi/runtime" \
    FAN_KICKSTART_UNIT_DIR="$unit_dir" FAN_KICKSTART_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_fan_kickstart"
  [ "$status" -eq 0 ]
  [ -x "$sbin_dir/ceralive-fan-kickstart" ]
  [ -f "$unit_dir/ceralive-fan-kickstart.service" ]

  run cat "$calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable ceralive-fan-kickstart.service"* ]]
}

@test "fan kickstart: a genuine 0 -> nonzero edge kicks to the REAL max_state, then restores" {
  # The reference board's max_state is 4; this fixture's is 6. A kick value that
  # is a hand-invented "100%", a hardcoded 4, or anything but this device's own
  # max_state fails here.
  local sysfs="$BATS_TEST_TMPDIR/fk-edge"
  local timeline="$BATS_TEST_TMPDIR/fk-edge-timeline"
  fankick_fake_thermal "$sysfs" 6 0

  # Governor moves it 0 -> 1 shortly after the monitor primes.
  ( sleep 0.35; fankick_set_state "$sysfs/cooling_device6/cur_state" 1 ) &
  # Sample cur_state independently so the kick is observed, not inferred.
  ( for _ in $(seq 1 24); do
      fankick_attr "$sysfs/cooling_device6/cur_state" >>"$timeline"
      printf '\n' >>"$timeline"
      sleep 0.1
    done ) &
  local sampler=$!

  run fankick_run "$sysfs" 800 16
  [ "$status" -eq 0 ]
  wait "$sampler"

  [[ "$output" == *"nudging to state 6"* ]]
  [[ "$output" == *"max_state"* ]]
  # It kicked: max_state was actually observed on the device mid-run.
  grep -qx '6' "$timeline"
  # It restored: the governor's own commanded state is what is left behind.
  [[ "$output" == *"state 1 handed back"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "1" ]
  # The decoy CPUFreq cooling device was never touched.
  [ "$(fankick_attr "$sysfs/cooling_device2/cur_state")" = "0" ]
}

@test "fan kickstart: the kick is BOUNDED — it ends on its own timer, not on a governor decision" {
  # The whole safety argument. A kick that outlived its window would sit at full
  # PWM until the temperature left the trip band, because a userspace cur_state
  # write is sticky against this kernel's governor.
  local sysfs="$BATS_TEST_TMPDIR/fk-bounded"
  local timeline="$BATS_TEST_TMPDIR/fk-bounded-timeline"
  fankick_fake_thermal "$sysfs" 6 0

  ( sleep 0.35; fankick_set_state "$sysfs/cooling_device6/cur_state" 2 ) &
  ( for _ in $(seq 1 30); do
      fankick_attr "$sysfs/cooling_device6/cur_state" >>"$timeline"
      printf '\n' >>"$timeline"
      sleep 0.1
    done ) &
  local sampler=$!

  run fankick_run "$sysfs" 500 20
  [ "$status" -eq 0 ]
  wait "$sampler"

  # Nothing external ever moved it off max_state, so if it is not at max_state
  # by the end, the monitor's own bounded window is what ended the kick.
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "2" ]
  # And the full-PWM period really was a period, not the whole run.
  local at_max total
  at_max="$(grep -cx '6' "$timeline" || true)"
  total="$(grep -cx '[0-9]*' "$timeline" || true)"
  [ "$at_max" -ge 1 ]
  [ "$at_max" -lt "$total" ]

  # Structurally: exactly ONE sleep spans the kick, and its length comes from a
  # validated, band-clamped constant rather than a literal.
  run bash -c "grep -vE '^[[:space:]]*#' '$(FANKICK_SCRIPT)' | grep -cE '^[[:space:]]*sleep \"\\\$\{KICK_SECONDS\}\"'"
  [ "$output" -eq 1 ]
  run fankick_run "$sysfs" 60000 4
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside the accepted"* ]]
}

@test "fan kickstart: nonzero -> nonzero NEVER fires — no re-kick while the fan is already turning" {
  # The governor climbing 1 -> 3 under its own control must not be interrupted,
  # and a poll tick that simply re-observes an active fan must not re-kick.
  local sysfs="$BATS_TEST_TMPDIR/fk-nonzero"
  fankick_fake_thermal "$sysfs" 6 1

  ( sleep 0.35; fankick_set_state "$sysfs/cooling_device6/cur_state" 3 ) &
  run fankick_run "$sysfs" 300 12
  [ "$status" -eq 0 ]
  [[ "$output" != *"nudging"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "3" ]
}

@test "fan kickstart: nonzero -> 0 NEVER fires — a fan being shut off is not a dead start" {
  local sysfs="$BATS_TEST_TMPDIR/fk-tozero"
  fankick_fake_thermal "$sysfs" 6 2

  ( sleep 0.35; fankick_set_state "$sysfs/cooling_device6/cur_state" 0 ) &
  run fankick_run "$sysfs" 300 12
  [ "$status" -eq 0 ]
  [[ "$output" != *"nudging"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "0" ]
}

@test "fan kickstart: 0 -> max_state NEVER fires — the governor already commands full PWM" {
  # There is no room to kick above the target, so a write would be pointless.
  # Same skip condition upstream's in-driver version uses (it boosts only when
  # the target duty is BELOW the from-stopped duty).
  local sysfs="$BATS_TEST_TMPDIR/fk-atmax"
  fankick_fake_thermal "$sysfs" 6 0

  ( sleep 0.35; fankick_set_state "$sysfs/cooling_device6/cur_state" 6 ) &
  run fankick_run "$sysfs" 300 12
  [ "$status" -eq 0 ]
  [[ "$output" != *"nudging"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "6" ]
}

@test "fan kickstart: priming means a monitor that STARTS on an already-spinning fan does not kick" {
  # Restart=on-failure and a mid-life restart must not produce a spurious nudge:
  # the previous state is seeded from the device, never assumed to be 0.
  local sysfs="$BATS_TEST_TMPDIR/fk-prime"
  fankick_fake_thermal "$sysfs" 6 2

  run fankick_run "$sysfs" 300 6
  [ "$status" -eq 0 ]
  [[ "$output" == *"currently state 2"* ]]
  [[ "$output" != *"nudging"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "2" ]
}

@test "fan kickstart: a governor decision made DURING the kick wins — it is not overwritten by the restore" {
  local sysfs="$BATS_TEST_TMPDIR/fk-race"
  fankick_fake_thermal "$sysfs" 6 0

  ( sleep 0.35; fankick_set_state "$sysfs/cooling_device6/cur_state" 1
    sleep 0.4;  fankick_set_state "$sysfs/cooling_device6/cur_state" 4 ) &
  run fankick_run "$sysfs" 900 18
  [ "$status" -eq 0 ]
  [[ "$output" == *"nudging to state 6"* ]]
  [[ "$output" == *"re-asserted state 4"* ]]
  [[ "$output" != *"state 1 handed back"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "4" ]
}

@test "fan kickstart: it re-kicks on EVERY cooldown/reheat cycle — this is why it is not a oneshot" {
  local sysfs="$BATS_TEST_TMPDIR/fk-cycles"
  fankick_fake_thermal "$sysfs" 6 0

  ( sleep 0.35; fankick_set_state "$sysfs/cooling_device6/cur_state" 1
    sleep 0.9;  fankick_set_state "$sysfs/cooling_device6/cur_state" 0
    sleep 0.4;  fankick_set_state "$sysfs/cooling_device6/cur_state" 1 ) &
  run fankick_run "$sysfs" 300 26
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'nudging to state 6')" -eq 2 ]
}

@test "fan kickstart: discovery is generic and the kick value is READ, never a literal" {
  local script
  script="$(FANKICK_SCRIPT)"

  # No executable line may name a concrete index, the hwmon node, or a trip point.
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -E 'thermal_zone[0-9]|cooling_device[0-9]|hwmon'"
  [ "$status" -ne 0 ]

  # It selects the device by the exact `pwm-fan` type string and reads max_state.
  grep -Fq 'readonly WANTED_CDEV_TYPE="pwm-fan"' "$script"
  grep -Fq 'read_attr "${cdev}/max_state"' "$script"

  # cur_state is written exactly twice — the kick and the restore — and BOTH
  # values are variable references, so no hand-invented "100%" can creep in.
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -cE 'write_attr \"\\\$\{cdev\}/cur_state\"'"
  [ "$output" -eq 2 ]
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -E 'write_attr \"\\\$\{cdev\}/cur_state\" \"[0-9]'"
  [ "$status" -ne 0 ]
}

@test "fan kickstart: the governor is nudged, never replaced — no pwm1, no mode, no trip writes" {
  # Writing the hwmon pwm nodes means owning the fan forever (including across
  # suspend and shutdown); writing thermal_zone*/mode would also disable that
  # zone's critical trip. Both are out of bounds, exactly as for the fan curve.
  local script
  script="$(FANKICK_SCRIPT)"
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -E '(pwm1|pwm1_enable|/mode|trip_point|emul_temp)'"
  [ "$status" -ne 0 ]

  # And it must not reach for the fan curve's own artifacts.
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -E 'ceralive-fan-curve'"
  [ "$status" -ne 0 ]
}

@test "fan kickstart: the restore write is present and is NOT deletable as redundant" {
  # A userspace cur_state write is sticky against this kernel's governor
  # (cur_state_store leaves cdev->updated set, thermal_cdev_update()
  # short-circuits on it, step_wise clears it only when its target changes), so
  # the restore is the only thing that ends the kick. Pin both the code and the
  # explanation, because the tempting "simplification" is to delete it.
  local script
  script="$(FANKICK_SCRIPT)"
  grep -Fq 'write_attr "${cdev}/cur_state" "${edge_states[i]}"' "$script"
  grep -q 'STICKY' "$script"
  grep -q 'cdev->updated' "$script"
}

@test "fan kickstart: a board with no pwm-fan cooling device is an informational no-op" {
  # x86-minipc has a populated ACPI thermal tree and no pwm-fan at all.
  local sysfs="$BATS_TEST_TMPDIR/fk-nofan"
  rm -rf "$sysfs"
  mkdir -p "$sysfs/cooling_device0"
  printf 'Processor\n' >"$sysfs/cooling_device0/type"
  printf '0\n' >"$sysfs/cooling_device0/max_state"

  run env CERALIVE_FAN_KICK_THERMAL_DIR="$sysfs" CERALIVE_FAN_KICK_WAIT=1 \
    bash "$(FANKICK_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no fan to kick-start"* ]]

  # A board with no thermal class at all is equally a clean no-op.
  run env CERALIVE_FAN_KICK_THERMAL_DIR="$BATS_TEST_TMPDIR/fk-absent" \
    bash "$(FANKICK_SCRIPT)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no thermal class"* ]]

  # The wait is a deadline-bounded poll, not a bare fixed settle constant.
  grep -Fq 'deadline=$(( SECONDS + WAIT_SECONDS ))' "$(FANKICK_SCRIPT)"
}

@test "fan kickstart: a single-active-state board is skipped — there is nothing to kick above" {
  # max_state == 1 means the only active state IS max_state, so entering it
  # already commands full PWM and a kick would be a pointless write.
  local sysfs="$BATS_TEST_TMPDIR/fk-single"
  fankick_fake_thermal "$sysfs" 1 0

  # MAX_CYCLES is a hang guard, not part of the contract: this run is supposed to
  # exit at discovery. Without it a regression that drops the skip would leave the
  # resident monitor looping forever and this test would hang instead of failing.
  run fankick_run "$sysfs" 300 6
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to kick above"* ]]
  [[ "$output" != *"nudging"* ]]
  [ "$(fankick_attr "$sysfs/cooling_device6/cur_state")" = "0" ]
}

@test "fan kickstart: the unit is RESIDENT (Type=exec + Restart=on-failure), not a oneshot" {
  # The fan re-enters an active state many times over a device's uptime, so a
  # boot oneshot would fix only the first dead start.
  local unit
  unit="$(FANKICK_UNIT)"
  grep -Eq '^Type=exec$' "$unit"
  grep -Eq '^Restart=on-failure$' "$unit"
  grep -Eq '^RestartSec=' "$unit"

  # NOT a oneshot, and NOT Restart=always: the script exits 0 on purpose on a
  # board with no fan, and `always` would respawn that in a hot loop forever.
  run grep -E '^Type=oneshot$' "$unit"
  [ "$status" -ne 0 ]
  run grep -E '^Restart=always$' "$unit"
  [ "$status" -ne 0 ]

  # Hardening must not remount /sys read-only — that would break the one write
  # this unit exists to make.
  run grep -E '^ProtectKernelTunables=yes$' "$unit"
  [ "$status" -ne 0 ]
}

@test "fan kickstart: missing runtime source FAILS the build (fail-closed, nothing installed)" {
  local unit_dir="$BATS_TEST_TMPDIR/fk-failclosed-units"
  local sbin_dir="$BATS_TEST_TMPDIR/fk-failclosed-sbin"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/fk-empty-src" \
    FAN_KICKSTART_UNIT_DIR="$unit_dir" FAN_KICKSTART_SBIN_DIR="$sbin_dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_fan_kickstart"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fan-kickstart script not found"* ]]
  [ ! -e "$unit_dir/ceralive-fan-kickstart.service" ]
}

@test "fan kickstart: the fix is wired into configure_services and registered in the drift gate" {
  # An unreferenced setup function is dead code — the stalling fan ships.
  run grep -E '^\s*setup_fan_kickstart$' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
  # Standalone-artifact idiom: defined once in postinst-lib.sh, never inlined.
  grep -Fq 'setup_fan_kickstart' "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  run grep -cE '^setup_fan_kickstart\(\) \{' "$POSTINST_LIB"
  [ "$output" -eq 1 ]

  # It is ADDITIVE to setup_fan_curve, which must remain untouched and separate.
  run grep -cE '^setup_fan_curve\(\) \{' "$POSTINST_LIB"
  [ "$output" -eq 1 ]
}
