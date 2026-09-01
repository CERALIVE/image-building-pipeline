#!/usr/bin/env bats
#
# journal-diagnosability.bats — the three defects that made a shipped board
# undiagnosable, and the contracts that keep them fixed.
#
# WHAT WAS MEASURED (Rock 5B+, 2026-08-30, evidence
# .omo/evidence/board-diag-20260830-netmodem-192.168.78.132.md §5.4):
#
#   journalctl --list-boots        -> ONE boot
#   journalctl -u NetworkManager   -> 6 lines, ~100 seconds of history
#   journalctl -u wpa_supplicant   -> EMPTY
#   /data                          -> 98 % full
#   ls -d /var/log/journal/*/      -> 20 directories
#   /etc/machine-id                -> f2346da8af8f48fdb339d17e8c21a25e
#   /opt/ceralive/machine-id       -> 69eae157d96657b5f7af5a096a736fba   (different!)
#
# THE AUDIT THAT PRECEDED THE FIX. A machine-id persistence mechanism was already
# shipped, so the first question was whether it was absent or broken. It was
# broken, in two specific ways, and both are pinned below as absence guards:
#
#   * `[ -s /etc/machine-id ]` accepts ANY non-empty content — including the
#     literal `uninitialized` this image ships as systemd's first-boot marker.
#   * `! mountpoint -q /etc/machine-id` silently SKIPS the bind whenever PID 1
#     already holds a transient machine-id mount, and `2>/dev/null || true` hides
#     a failing bind as well. Either way the persistent copy is never consumed —
#     which is exactly the two-different-values state measured above.
#
# WHY THE FIX IS A COMMIT AND NOT A BIND. The board boots with NO initramfs: the
# shipped selector loads the bare name `/boot/initrd.img`, the kernel package
# installs only `/boot/initrd.img-<REL>`, and the load is optional by design
# (mkosi/platform/boot/boot.scr.cmd). So there is no pre-PID-1 hook to provision
# the id from, and the earliest supply that survives is to WRITE the rootfs
# /etc/machine-id — PID 1 then reads the persistent value on every subsequent
# boot of that slot, with no mount to be skipped. The one boot PID 1 can still
# win (the first after a slot is written) is closed by restarting journald after
# the /var/log bind, which is why the unit is ordered where it is.
#
# UNIT scope: no image boot, no hardware. The installers are driven against
# scratch directories and the two device scripts are executed against synthetic
# trees.

load manifest-helpers

MACHINE_ID_SCRIPT() { printf '%s' "$PIPELINE_DIR/mkosi/runtime/machine-id/ceralive-machine-id.sh"; }
MACHINE_ID_UNIT()   { printf '%s' "$PIPELINE_DIR/mkosi/runtime/machine-id/ceralive-machine-id.service"; }
JOURNAL_GC_SCRIPT() { printf '%s' "$PIPELINE_DIR/mkosi/runtime/journald/ceralive-journal-gc.sh"; }
JOURNAL_GC_UNIT()   { printf '%s' "$PIPELINE_DIR/mkosi/runtime/journald/ceralive-journal-gc.service"; }
JOURNALD_DROPIN()   { printf '%s' "$PIPELINE_DIR/mkosi/runtime/journald/10-ceralive-journal.conf"; }
RUNTIME_EXECUTOR()  { printf '%s' "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"; }

# A board whose /data already holds a valid identity, seeded exactly as the
# device would have it: 32 lowercase hex plus the trailing newline systemd writes.
seed_persistent_id() { # $1=path $2=id
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
}

# Run the shipped machine-id script against a synthetic board. The journald
# restart is off unless a test explicitly asks for it, so the common path needs
# no systemctl at all.
run_machine_id() { # $1=persistent $2=etc  [extra env...]
  local persistent="$1" etc="$2"; shift 2
  run env "$@" \
    CERALIVE_MACHINE_ID_PERSISTENT="$persistent" \
    CERALIVE_MACHINE_ID_ETC="$etc" \
    CERALIVE_MACHINE_ID_RESTART_JOURNALD="${RESTART_JOURNALD:-0}" \
    bash "$(MACHINE_ID_SCRIPT)"
}

id_of() { tr -d '\n' <"$1"; }

# ===========================================================================
# A. The installers put real files in the rootfs.
# ===========================================================================

@test "journald retention: the drop-in is installed where journald reads it" {
  local dropin_dir="$BATS_TEST_TMPDIR/journald.conf.d"

  run env CERALIVE_RUNTIME_SRC="$PIPELINE_DIR/mkosi/runtime" \
    JOURNALD_DROPIN_DIR="$dropin_dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_journald_retention"
  [ "$status" -eq 0 ]
  [ -f "$dropin_dir/10-ceralive-journal.conf" ]

  # journald.conf.d files are read in lexical order; a 10- prefix is what keeps
  # this ahead of anything a package might drop in later.
  run bash -c "ls '$dropin_dir'"
  [[ "$output" == 10-* ]]
}

@test "journald retention: storage is explicit, the budget is stated, and rate limiting is per-unit" {
  local conf; conf="$(JOURNALD_DROPIN)"

  grep -Eq '^Storage=persistent$' "$conf"
  # An explicit ceiling is the whole point — `auto` sizing against a 98 %-full
  # /data is what produced 100 seconds of history.
  grep -Eq '^SystemMaxUse=[0-9]+[KMG]$' "$conf"
  grep -Eq '^SystemKeepFree=[0-9]+[KMG]$' "$conf"
  grep -Eq '^SystemMaxFiles=[0-9]+$' "$conf"
  # journald applies these PER SERVICE, so they are the per-unit limit that stops
  # one chatty unit evicting every other unit's history.
  grep -Eq '^RateLimitIntervalSec=' "$conf"
  grep -Eq '^RateLimitBurst=[0-9]+$' "$conf"
  # The kernel audit stream was 144 of the last ~350 records on the board.
  grep -Eq '^Audit=no$' "$conf"

  # The runtime journal lives in RAM; it must carry its own, separate cap.
  grep -Eq '^RuntimeMaxUse=[0-9]+[KMG]$' "$conf"

  # And the burst must be BELOW journald's own default of 10000, or the limit is
  # decorative.
  local burst; burst="$(sed -n 's/^RateLimitBurst=//p' "$conf")"
  [ "$burst" -lt 10000 ]
}

@test "machine-id + journal-gc: both scripts and units install, and both units are enabled" {
  local sbin="$BATS_TEST_TMPDIR/sbin" units="$BATS_TEST_TMPDIR/units"
  local bin="$BATS_TEST_TMPDIR/bin" calls="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MID_CALLS"
exit 0
SH
  chmod +x "$bin/systemctl"

  run env PATH="$bin:$PATH" MID_CALLS="$calls" \
    CERALIVE_RUNTIME_SRC="$PIPELINE_DIR/mkosi/runtime" \
    MACHINE_ID_SBIN_DIR="$sbin" MACHINE_ID_UNIT_DIR="$units" \
    JOURNAL_GC_SBIN_DIR="$sbin" JOURNAL_GC_UNIT_DIR="$units" \
    bash -c "source '$POSTINST_ENTRY'; setup_machine_id_persistence; setup_journal_dir_gc"
  [ "$status" -eq 0 ]

  [ -x "$sbin/ceralive-machine-id" ]
  [ -f "$units/ceralive-machine-id.service" ]
  [ -x "$sbin/ceralive-journal-gc" ]
  [ -f "$units/ceralive-journal-gc.service" ]

  run cat "$calls"
  [[ "$output" == *"enable ceralive-machine-id.service"* ]]
  [[ "$output" == *"enable ceralive-journal-gc.service"* ]]
}

@test "diagnosability installers: a missing runtime source FAILS the build and installs nothing" {
  local empty="$BATS_TEST_TMPDIR/empty-src"
  local dropin="$BATS_TEST_TMPDIR/fc-dropin" sbin="$BATS_TEST_TMPDIR/fc-sbin" units="$BATS_TEST_TMPDIR/fc-units"
  mkdir -p "$empty"

  local fn
  for fn in setup_journald_retention setup_machine_id_persistence setup_journal_dir_gc; do
    run env CERALIVE_RUNTIME_SRC="$empty" \
      JOURNALD_DROPIN_DIR="$dropin" \
      MACHINE_ID_SBIN_DIR="$sbin" MACHINE_ID_UNIT_DIR="$units" \
      JOURNAL_GC_SBIN_DIR="$sbin" JOURNAL_GC_UNIT_DIR="$units" \
      bash -c "source '$POSTINST_ENTRY'; ${fn}"
    [ "$status" -ne 0 ]
  done

  [ ! -e "$dropin" ]
  [ ! -e "$sbin" ]
  [ ! -e "$units" ]
}

@test "diagnosability installers: all three are wired into the runtime executor and the drift gate" {
  local executor drift
  executor="$(RUNTIME_EXECUTOR)"
  drift="$PIPELINE_DIR/ci/postinst-drift-check.sh"

  local fn
  for fn in setup_journald_retention setup_machine_id_persistence setup_journal_dir_gc; do
    grep -Eq "^ +${fn}\b" "$executor"
    grep -Fq "${fn}" "$drift"
    # Single-source rule: defined exactly once across the postinst.d/ set.
    [ "$(grep -cE "^${fn}\(\) \{" "$POSTINST_LIB")" -eq 1 ]
  done
}

# ===========================================================================
# B. The AUDITED defects — absence guards on the mechanism that shipped.
# ===========================================================================

@test "machine-id: the migrate-data script no longer seeds or binds the id (both audited defects)" {
  # `[ -s ]` promoted `uninitialized` to a board identity; the guarded bind was
  # skipped whenever PID 1 already held a transient mount, with its own failure
  # swallowed by `|| true`. Neither may return.
  run grep -F 'mount --bind "$DATA/ceralive/machine-id"' "$POSTINST_LIB"
  [ "$status" -ne 0 ]
  run grep -F 'cp -a /etc/machine-id "$DATA/ceralive/machine-id"' "$POSTINST_LIB"
  [ "$status" -ne 0 ]
  run grep -F '[ -s /etc/machine-id ]' "$POSTINST_LIB"
  [ "$status" -ne 0 ]
}

@test "machine-id: the shipped script rejects the 'uninitialized' marker BY NAME" {
  # It fails the hex shape too, but naming it is what makes the journal line
  # readable as "this was the first-boot marker" rather than "malformed".
  run grep -F 'uninitialized' "$(MACHINE_ID_SCRIPT)"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# C. Validation, generation and the never-rotate rule.
# ===========================================================================

@test "machine-id: 'uninitialized' on /data is rejected and regenerated exactly once" {
  local p="$BATS_TEST_TMPDIR/c1/data/ceralive/machine-id"
  local e="$BATS_TEST_TMPDIR/c1/etc/machine-id"
  seed_persistent_id "$p" "uninitialized"
  seed_persistent_id "$e" "uninitialized"

  run_machine_id "$p" "$e"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uninitialized"* ]]

  local new; new="$(id_of "$p")"
  [[ "$new" =~ ^[0-9a-f]{32}$ ]]
  [ "$(id_of "$e")" = "$new" ]

  # …and exactly once: a second run must not rotate what it just generated.
  run_machine_id "$p" "$e"
  [ "$status" -eq 0 ]
  [ "$(id_of "$p")" = "$new" ]
}

@test "machine-id: malformed content is rejected and regenerated — every shape" {
  local i=0 bad
  for bad in "" "ABCDEF0123456789ABCDEF0123456789" "deadbeef" \
             "f2346da8af8f48fdb339d17e8c21a25" "f2346da8af8f48fdb339d17e8c21a25ez" \
             "not-a-machine-id"; do
    i=$((i + 1))
    local p="$BATS_TEST_TMPDIR/c2-$i/data/machine-id"
    local e="$BATS_TEST_TMPDIR/c2-$i/etc/machine-id"
    seed_persistent_id "$p" "$bad"
    seed_persistent_id "$e" "uninitialized"

    run_machine_id "$p" "$e"
    [ "$status" -eq 0 ]
    local got; got="$(id_of "$p")"
    [[ "$got" =~ ^[0-9a-f]{32}$ ]]
    [ "$got" != "$bad" ]
    [ "$(id_of "$e")" = "$got" ]
  done
}

@test "machine-id: a two-line file is malformed even when its first line looks valid" {
  # A truncated or appended write is the one malformed shape that reads back
  # correctly with `head -1`, so it must be judged on the whole file.
  local p="$BATS_TEST_TMPDIR/c3/data/machine-id"
  local e="$BATS_TEST_TMPDIR/c3/etc/machine-id"
  mkdir -p "$(dirname "$p")" "$(dirname "$e")"
  printf 'f2346da8af8f48fdb339d17e8c21a25e\nstray\n' >"$p"
  seed_persistent_id "$e" "uninitialized"

  run_machine_id "$p" "$e"
  [ "$status" -eq 0 ]
  [[ "$(id_of "$p")" =~ ^[0-9a-f]{32}$ ]]
  [ "$(id_of "$p")" != "f2346da8af8f48fdb339d17e8c21a25estray" ]
}

@test "machine-id: a VALID existing id is byte-preserved across a simulated reboot" {
  local p="$BATS_TEST_TMPDIR/c4/data/machine-id"
  local e="$BATS_TEST_TMPDIR/c4/etc/machine-id"
  seed_persistent_id "$p" "69eae157d96657b5f7af5a096a736fba"
  seed_persistent_id "$e" "f2346da8af8f48fdb339d17e8c21a25e"   # the measured board's disagreement

  local before; before="$(sha256sum <"$p")"

  # Boot 1: /etc is reconciled TO /data, never the other way round.
  run_machine_id "$p" "$e"
  [ "$status" -eq 0 ]
  [ "$(id_of "$e")" = "69eae157d96657b5f7af5a096a736fba" ]

  # Boot 2 and 3: nothing moves.
  run_machine_id "$p" "$e"
  [ "$status" -eq 0 ]
  run_machine_id "$p" "$e"
  [ "$status" -eq 0 ]

  [ "$(sha256sum <"$p")" = "$before" ]
  [ "$(id_of "$e")" = "69eae157d96657b5f7af5a096a736fba" ]
}

@test "machine-id: a VALID existing id survives a simulated A/B slot flip" {
  # A RAUC slot swap replaces the whole rootfs, so the new slot's
  # /etc/machine-id is the image's `uninitialized` again and PID 1 invents a
  # fresh random one. /data is the only thing that carries over. This is the
  # exact event that produced twenty journal directories.
  local root="$BATS_TEST_TMPDIR/c5"
  local p="$root/data/ceralive/machine-id"
  seed_persistent_id "$p" "69eae157d96657b5f7af5a096a736fba"
  local before; before="$(sha256sum <"$p")"

  local slot
  for slot in a b a; do
    local e="$root/slot-$slot/etc/machine-id"
    rm -f "$e"
    seed_persistent_id "$e" "uninitialized"
    run_machine_id "$p" "$e"
    [ "$status" -eq 0 ]
    [ "$(id_of "$e")" = "69eae157d96657b5f7af5a096a736fba" ]
  done

  [ "$(sha256sum <"$p")" = "$before" ]
}

@test "machine-id: a fresh board ADOPTS the running id instead of inventing a second one" {
  # On the first boot after a factory flash /data is empty and PID 1 has already
  # generated a perfectly good id — which journald has already opened a directory
  # for. Adopting it means that directory IS the permanent one and no stray is
  # ever created.
  local p="$BATS_TEST_TMPDIR/c6/data/machine-id"
  local e="$BATS_TEST_TMPDIR/c6/etc/machine-id"
  mkdir -p "$(dirname "$p")"
  seed_persistent_id "$e" "0123456789abcdef0123456789abcdef"

  run_machine_id "$p" "$e"
  [ "$status" -eq 0 ]
  [ "$(id_of "$p")" = "0123456789abcdef0123456789abcdef" ]
  [ "$(id_of "$e")" = "0123456789abcdef0123456789abcdef" ]
}

@test "machine-id: journald is restarted ONLY when the id actually changed" {
  local bin="$BATS_TEST_TMPDIR/c7bin" calls="$BATS_TEST_TMPDIR/c7-calls"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MID_CALLS"
exit 0
SH
  chmod +x "$bin/systemctl"

  local p="$BATS_TEST_TMPDIR/c7/data/machine-id"
  local e="$BATS_TEST_TMPDIR/c7/etc/machine-id"
  seed_persistent_id "$p" "69eae157d96657b5f7af5a096a736fba"
  seed_persistent_id "$e" "uninitialized"

  RESTART_JOURNALD=1 run_machine_id "$p" "$e" PATH="$bin:$PATH" MID_CALLS="$calls"
  [ "$status" -eq 0 ]
  run cat "$calls"
  [[ "$output" == *"try-restart systemd-journald.service"* ]]

  # Steady state: no change, no restart. Restarting the log daemon on every boot
  # would be a cost with no benefit.
  : >"$calls"
  RESTART_JOURNALD=1 run_machine_id "$p" "$e" PATH="$bin:$PATH" MID_CALLS="$calls"
  [ "$status" -eq 0 ]
  run cat "$calls"
  [ -z "$output" ]
}

@test "machine-id: an unwritable persistent store leaves the board exactly as it was" {
  # Fail-soft is the contract: the worst outcome of this script not running must
  # be the behaviour the board already had, never a blocked boot.
  local dir="$BATS_TEST_TMPDIR/c8/data"
  local p="$dir/machine-id"
  local e="$BATS_TEST_TMPDIR/c8/etc/machine-id"
  mkdir -p "$dir"
  seed_persistent_id "$e" "0123456789abcdef0123456789abcdef"
  chmod 0500 "$dir"

  run_machine_id "$p" "$e"
  chmod 0700 "$dir"
  [ "$status" -eq 0 ]
  [ "$(id_of "$e")" = "0123456789abcdef0123456789abcdef" ]
}

# ===========================================================================
# D. The early-supply ordering — proven from the unit, not asserted in prose.
# ===========================================================================

@test "machine-id ordering: the unit runs in the local-fs phase, after the /var/log bind, before its consumers" {
  local unit; unit="$(MACHINE_ID_UNIT)"

  # A normal service inherits After=basic.target, and basic.target is after
  # local-fs.target — the exact cycle ceralive-migrate-data.service documents.
  grep -Eq '^DefaultDependencies=no$' "$unit"
  grep -Eq '^Before=.*\blocal-fs\.target\b' "$unit"
  run grep -E '^After=.*\blocal-fs\.target\b' "$unit"
  [ "$status" -ne 0 ]
  run grep -E '(After|Before)=.*sysinit\.target' "$unit"
  [ "$status" -ne 0 ]

  # /var/log is the bind from /data/log. Ordering after it is what puts a
  # reopened journal on /data instead of on the rootfs slot.
  grep -Eq '^RequiresMountsFor=.*\B/data\b' "$unit"
  grep -Eq '^RequiresMountsFor=.*\B/var/log\b' "$unit"
  grep -Eq '^After=.*ceralive-migrate-data\.service' "$unit"

  # Both consumers of the id read it as a committed 32-hex value and die
  # otherwise (postinst.d/hostname.sh), so both must be ordered after this.
  grep -Eq '^Before=.*ceralive-hostname\.service' "$unit"
  grep -Eq '^Before=.*ceralive\.service' "$unit"

  # No /data, no identity — and a board booting without its data partition must
  # not be blocked on one.
  grep -Eq '^ConditionPathIsMountPoint=/data$' "$unit"
  grep -Eq '^Type=oneshot$' "$unit"
  grep -Eq '^WantedBy=local-fs\.target$' "$unit"
}

@test "machine-id ordering: the fix is a COMMIT to /etc, never a bind mount" {
  local script; script="$(MACHINE_ID_SCRIPT)"
  # A bind is visible only to the boot that made it, and is precisely what the
  # audited mechanism skipped. No executable line may mount anything.
  run bash -c "grep -vE '^[[:space:]]*#' '$script' | grep -E '^[^#]*\bmount --bind\b'"
  [ "$status" -ne 0 ]
  # Unmounting a transient PID-1 machine-id IS allowed — it is what
  # systemd-machine-id-commit does before writing the real file.
  grep -Eq 'umount' "$script"
}

# ===========================================================================
# E. The one-time journal-directory migration.
# ===========================================================================

# A journal root holding the live directory plus stale ones, aged so that
# "most recently modified" is unambiguous.
gc_fake_journal() { # $1=root  $2=current-id
  local root="$1" current="$2"
  mkdir -p "$root/$current" \
           "$root/e4317e67e44f440d9d1c2e97958d4487" \
           "$root/ad9f8edc93a94c369d9dc5d41e533994" \
           "$root/c6b8f51f8e0745d397b37d93e13a3ef2"
  : >"$root/$current/system.journal"
  : >"$root/e4317e67e44f440d9d1c2e97958d4487/system.journal"
  : >"$root/ad9f8edc93a94c369d9dc5d41e533994/system.journal"
  : >"$root/c6b8f51f8e0745d397b37d93e13a3ef2/system.journal"
  touch -d '2020-01-01' "$root/c6b8f51f8e0745d397b37d93e13a3ef2"
  touch -d '2021-01-01' "$root/e4317e67e44f440d9d1c2e97958d4487"
  touch -d '2024-01-01' "$root/ad9f8edc93a94c369d9dc5d41e533994"
}

run_journal_gc() { # $1=journal-root $2=etc-machine-id $3=stamp [extra env...]
  local root="$1" etc="$2" stamp="$3"; shift 3
  run env "$@" \
    CERALIVE_JOURNAL_DIR="$root" \
    CERALIVE_MACHINE_ID_ETC="$etc" \
    CERALIVE_JOURNAL_GC_STAMP="$stamp" \
    bash "$(JOURNAL_GC_SCRIPT)"
}

@test "journal gc: retains the live directory and AT MOST one predecessor" {
  local root="$BATS_TEST_TMPDIR/e1/journal"
  local etc="$BATS_TEST_TMPDIR/e1/etc/machine-id"
  local stamp="$BATS_TEST_TMPDIR/e1/data/.journal-dir-gc-done"
  local current="69eae157d96657b5f7af5a096a736fba"
  gc_fake_journal "$root" "$current"
  seed_persistent_id "$etc" "$current"

  run_journal_gc "$root" "$etc" "$stamp"
  [ "$status" -eq 0 ]

  [ -d "$root/$current" ]
  # The predecessor is the most recently MODIFIED other directory — a machine-id
  # is random, so name order carries no chronology at all.
  [ -d "$root/ad9f8edc93a94c369d9dc5d41e533994" ]
  [ ! -e "$root/e4317e67e44f440d9d1c2e97958d4487" ]
  [ ! -e "$root/c6b8f51f8e0745d397b37d93e13a3ef2" ]

  run bash -c "ls '$root' | wc -l"
  [ "$output" -eq 2 ]
}

@test "journal gc: it is ONE-TIME — the stamp makes every later boot a no-op" {
  local root="$BATS_TEST_TMPDIR/e2/journal"
  local etc="$BATS_TEST_TMPDIR/e2/etc/machine-id"
  local stamp="$BATS_TEST_TMPDIR/e2/data/.journal-dir-gc-done"
  local current="69eae157d96657b5f7af5a096a736fba"
  gc_fake_journal "$root" "$current"
  seed_persistent_id "$etc" "$current"

  run_journal_gc "$root" "$etc" "$stamp"
  [ "$status" -eq 0 ]
  [ -e "$stamp" ]

  # A directory that appears AFTER the migration must survive: an ongoing
  # collector would make machine-id churn survivable instead of fixed.
  mkdir -p "$root/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  run_journal_gc "$root" "$etc" "$stamp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"one-time"* ]]
  [ -d "$root/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]
  [ -d "$root/ad9f8edc93a94c369d9dc5d41e533994" ]
}

@test "journal gc: only 32-hex DIRECTORIES are candidates — nothing else is touched" {
  local root="$BATS_TEST_TMPDIR/e3/journal"
  local etc="$BATS_TEST_TMPDIR/e3/etc/machine-id"
  local stamp="$BATS_TEST_TMPDIR/e3/data/.journal-dir-gc-done"
  local current="69eae157d96657b5f7af5a096a736fba"
  gc_fake_journal "$root" "$current"
  seed_persistent_id "$etc" "$current"

  : >"$root/remote-192.168.1.10.journal"
  mkdir -p "$root/remote-somehost"
  mkdir -p "$root/not-a-machine-id"
  ln -s "$root/$current" "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  run_journal_gc "$root" "$etc" "$stamp"
  [ "$status" -eq 0 ]

  [ -f "$root/remote-192.168.1.10.journal" ]
  [ -d "$root/remote-somehost" ]
  [ -d "$root/not-a-machine-id" ]
  [ -L "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]
  [ -d "$root/$current" ]
}

@test "journal gc: an invalid machine-id refuses to guess — nothing removed, nothing stamped" {
  local root="$BATS_TEST_TMPDIR/e4/journal"
  local etc="$BATS_TEST_TMPDIR/e4/etc/machine-id"
  local stamp="$BATS_TEST_TMPDIR/e4/data/.journal-dir-gc-done"
  gc_fake_journal "$root" "69eae157d96657b5f7af5a096a736fba"
  seed_persistent_id "$etc" "uninitialized"

  run_journal_gc "$root" "$etc" "$stamp"
  [ "$status" -eq 0 ]
  [ ! -e "$stamp" ]

  run bash -c "ls '$root' | wc -l"
  [ "$output" -eq 4 ]
}

@test "journal gc: the unit is a stamped one-time migration ordered after the journal flush" {
  local unit; unit="$(JOURNAL_GC_UNIT)"

  grep -Eq '^Type=oneshot$' "$unit"
  grep -Eq '^After=.*systemd-journal-flush\.service' "$unit"
  grep -Eq '^ConditionPathExists=!/data/ceralive/\.journal-dir-gc-done$' "$unit"
  grep -Eq '^RequiresMountsFor=.*\B/var/log\b' "$unit"

  # Not a timer, and not resident: an ongoing collector is the anti-pattern.
  run grep -E '^(OnCalendar|OnUnitActiveSec|Restart)=' "$unit"
  [ "$status" -ne 0 ]
  [ ! -e "${unit%.service}.timer" ]

  # The stamp path the unit conditions on must be the script's own default, or
  # the condition guards nothing.
  grep -Fq '/data/ceralive/.journal-dir-gc-done' "$(JOURNAL_GC_SCRIPT)"
}
