#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# hdmirx-edid-contract.bats — the HDMI-RX product EDID contract: which blobs
# postinst.d/hardware.sh::setup_hdmirx_edid installs, where, with which modes,
# how the unit is ordered, how the apply script picks ONE of the two profiles at
# runtime, and what a NON-conformant EDID must do to the conformance checker.
#
# WHY THIS IS ITS OWN SUITE. The artifacts have different owners: the apply
# script and its oneshot come from mkosi/runtime/, the 256-byte blobs come from
# tools/gen-hdmirx-edid.py (drift-gated in CI), and the install + enable wiring
# comes from postinst.d/hardware.sh. Only an installed-tree test can prove they
# agree with each other — the CI EDID job proves each blob is a conformant EDID
# and says nothing about whether it reaches the board, while the postinst suites
# prove wiring and say nothing about the bytes.
#
# THE PROFILE SET IS WRITTEN DOWN THREE TIMES and cannot be deduplicated: a
# subimage chroot can source neither the generator nor the runtime script. So one
# case here pins all three against `gen-hdmirx-edid.py --list-profiles`, which is
# what turns "added a profile in one place" into a red test instead of a blob
# nothing installs.
#
# NOTHING HERE ASSUMES A /dev/video NODE INDEX, and one case enforces that on the
# suite itself: the HDMI-RX node is reached through the driver-keyed udev symlink
# because a USB capture card can take the low index and renumber the receiver.
# The runtime harness below therefore names its fake node `hdmirx-capture`.
#
# UNIT scope: temp install dirs, a stubbed systemctl, a fake sysfs + stub
# v4l2-ctl, and raw byte reads. No image, no board, no systemd.
#
# Run:  run-tests              (CI entrypoint)
#   or: bats tests/hdmirx-edid-contract.bats

load manifest-helpers

# The committed blobs' SHA-256s, pinned here as a SECOND, independent statement
# of what this image ships. tools/gen-hdmirx-edid.py plus the CI drift gate
# decide what each blob IS; these values are what make a silent substitution on
# the way to /etc/ceralive fail a test rather than a shoot.
HDMIRX_EDID_SHA256_FULL=99ba7c54ef8ac3c3050eb6dff82812240ffd662aea2332cfc128150507fb7197
HDMIRX_EDID_SHA256_ROBUST=616e45639ce8491cb854c2540bfef092b97f5a4495fcb8a989edcbaf251ac083

# The on-device paths the unit's ExecStart and the script's own defaults name.
# They are a fixed interface: the installer, the unit and the script must all
# agree, so they are written down once and asserted three ways.
HDMIRX_SBIN_PATH=/usr/local/sbin/ceralive-hdmirx-edid
HDMIRX_BLOB_DIR=/etc/ceralive
HDMIRX_CONF_PATH=/data/ceralive/hdmirx.conf
HDMIRX_PROFILE_KEY=hdmirx.edid_profile

hdmirx_script() { printf '%s/mkosi/runtime/ceralive-hdmirx-edid.sh' "$PIPELINE_DIR"; }
hdmirx_unit() { printf '%s/mkosi/runtime/ceralive-hdmirx-edid.service' "$PIPELINE_DIR"; }
hdmirx_blob() { printf '%s/mkosi/runtime/edid/ceralive-hdmirx-%s.edid' "$PIPELINE_DIR" "$1"; }

edid_conformance() {
  python3 "$TESTS_DIR/lib/edid-conformance.py" "$@"
}

# install_hdmirx_edid <root> — run the SHIPPED setup function against a throwaway
# install root, with a systemctl stub that emulates `enable` the way systemd does
# it: read the unit's [Install] WantedBy= and create the .wants symlink. Without
# that emulation "enabled" could only ever be asserted as "the call was made",
# which is a weaker claim than the symlink actually existing.
install_hdmirx_edid() {
  local root="$1"
  local bin="$root/bin"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$HDMIRX_CALLS"
if [[ "${1:-}" == "enable" ]]; then
  unit="$2"
  unit_path="$HDMIRX_EDID_UNIT_DIR/$unit"
  # Real systemctl refuses to enable a unit it cannot find; keep that property so
  # an install-after-enable ordering regression cannot pass silently.
  [[ -f "$unit_path" ]] || exit 1
  while read -r target; do
    [[ -n "$target" ]] || continue
    mkdir -p "$HDMIRX_EDID_UNIT_DIR/$target.wants"
    ln -sf "$unit_path" "$HDMIRX_EDID_UNIT_DIR/$target.wants/$unit"
  done < <(sed -n 's/^WantedBy=//p' "$unit_path" | tr ' ' '\n')
fi
exit 0
SH
  chmod +x "$bin/systemctl"

  run env PATH="$bin:$PATH" \
    HDMIRX_CALLS="$root/calls" \
    CERALIVE_RUNTIME_SRC="$PIPELINE_DIR/mkosi/runtime" \
    HDMIRX_EDID_UNIT_DIR="$root/etc/systemd/system" \
    HDMIRX_EDID_SBIN_DIR="$root$(dirname "$HDMIRX_SBIN_PATH")" \
    HDMIRX_EDID_BLOB_DIR="$root$HDMIRX_BLOB_DIR" \
    bash -c "source '$POSTINST_ENTRY'; setup_hdmirx_edid"
}

# hdmirx_fake_board <root> — a sysfs tree the SHIPPED apply script accepts, plus
# a v4l2-ctl stub that records what was written. Deliberately NOT a /dev/videoN
# name: the receiver is reached through the driver-keyed symlink, and a fixture
# that hardcodes an index would quietly re-import the assumption this suite bans.
hdmirx_fake_board() {
  local root="$1"
  mkdir -p "$root/sys/class/video4linux/hdmirx-capture/device" \
           "$root/drivers/snps_hdmirx" "$root/dev" "$root/bin" \
           "$root$HDMIRX_BLOB_DIR" "$root$(dirname "$HDMIRX_CONF_PATH")"
  ln -sfn "$root/drivers/snps_hdmirx" \
    "$root/sys/class/video4linux/hdmirx-capture/device/driver"
  : >"$root/dev/hdmirx-capture"

  local profile
  while read -r profile; do
    cp "$(hdmirx_blob "$profile")" "$root$HDMIRX_BLOB_DIR/hdmirx-$profile.edid"
  done < <(hdmirx_generator_profiles)

  cat >"$root/bin/v4l2-ctl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    --set-edid=*)
      [[ -n "${HDMIRX_STUB_BUSY:-}" ]] && {
        echo "VIDIOC_S_EDID: failed: Device or resource busy" >&2; exit 1; }
      src="${arg#*file=}"; cp "${src%%,*}" "$HDMIRX_STUB_APPLIED"; exit 0 ;;
    --get-edid=*)
      dst="${arg#*file=}"; cp "$HDMIRX_STUB_APPLIED" "${dst%%,*}"; exit 0 ;;
  esac
done
exit 0
SH
  chmod +x "$root/bin/v4l2-ctl"
}

# run_hdmirx_apply <root> [env...] — drive the REAL shipped script at that board.
run_hdmirx_apply() {
  local root="$1"; shift
  run env PATH="$root/bin:$PATH" \
    HDMIRX_STUB_APPLIED="$root/applied.edid" \
    CERALIVE_HDMIRX_DEV="$root/dev/hdmirx-capture" \
    CERALIVE_HDMIRX_SYS_ROOT="$root/sys" \
    CERALIVE_HDMIRX_DT_ROOT="$root/absent-device-tree" \
    CERALIVE_HDMIRX_EDID_DIR="$root$HDMIRX_BLOB_DIR" \
    CERALIVE_HDMIRX_CONF="$root$HDMIRX_CONF_PATH" \
    CERALIVE_HDMIRX_EDID_DECODE="$root/absent-edid-decode" \
    "$@" bash "$(hdmirx_script)"
}

hdmirx_set_profile() {
  local root="$1" body="$2"
  mkdir -p "$root$(dirname "$HDMIRX_CONF_PATH")"
  printf '%s' "$body" >"$root$HDMIRX_CONF_PATH"
}

# hdmirx_generator_profiles — the AUTHORITATIVE profile set, straight out of the
# generator. Every other copy in the repo is checked against this one.
hdmirx_generator_profiles() {
  python3 "$PIPELINE_DIR/tools/gen-hdmirx-edid.py" --list-profiles
}

# ===========================================================================
# (i) The unit is installed AND enabled.
# ===========================================================================

@test "hdmirx edid: the unit is installed and its enabled symlink is present" {
  local root="$BATS_TEST_TMPDIR/install-enable"
  install_hdmirx_edid "$root"
  [ "$status" -eq 0 ]

  local unit="$root/etc/systemd/system/ceralive-hdmirx-edid.service"
  [ -f "$unit" ]

  run cat "$root/calls"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable ceralive-hdmirx-edid.service"* ]]

  # The [Install] section is WantedBy=multi-user.target, so an enable lands here.
  local link="$root/etc/systemd/system/multi-user.target.wants/ceralive-hdmirx-edid.service"
  [ -L "$link" ]
  [ "$(readlink -f "$link")" = "$(readlink -f "$unit")" ]
}

@test "hdmirx edid: the shipped unit declares WantedBy=multi-user.target (the enable has a target)" {
  # A unit with no [Install] is enable-able only by hand; the symlink assertion
  # above would then be proving the stub rather than the artifact.
  grep -Eq '^WantedBy=multi-user\.target$' "$(hdmirx_unit)"
}

# ===========================================================================
# (ii) The apply script is installed EXECUTABLE, at the path the unit names.
# ===========================================================================

@test "hdmirx edid: the apply script is installed 0755 at the path ExecStart names" {
  local root="$BATS_TEST_TMPDIR/install-modes"
  install_hdmirx_edid "$root"
  [ "$status" -eq 0 ]

  local script="$root$HDMIRX_SBIN_PATH"
  [ -f "$script" ]
  [ -x "$script" ]
  [ "$(stat -c '%a' "$script")" = "755" ]

  # The unit invokes an absolute path; a script installed anywhere else is a
  # unit that fails at ExecStart with "not executable" on a real board.
  grep -Fxq "ExecStart=$HDMIRX_SBIN_PATH" "$(hdmirx_unit)"
}

@test "hdmirx edid: the unit and both blobs are installed 0644 (data, never executable)" {
  local root="$BATS_TEST_TMPDIR/install-datamodes"
  install_hdmirx_edid "$root"
  [ "$status" -eq 0 ]

  [ "$(stat -c '%a' "$root/etc/systemd/system/ceralive-hdmirx-edid.service")" = "644" ]

  local profile
  while read -r profile; do
    [ "$(stat -c '%a' "$root$HDMIRX_BLOB_DIR/hdmirx-$profile.edid")" = "644" ]
  done < <(hdmirx_generator_profiles)
}

# ===========================================================================
# (iii) BOTH blobs reach their runtime paths, byte-intact.
# ===========================================================================

@test "hdmirx edid: both installed blobs are byte-identical to the committed ones and match their pinned SHA-256s" {
  local root="$BATS_TEST_TMPDIR/install-blob"
  install_hdmirx_edid "$root"
  [ "$status" -eq 0 ]

  local profile sum expected
  while read -r profile; do
    local installed="$root$HDMIRX_BLOB_DIR/hdmirx-$profile.edid"
    [ -s "$installed" ]
    cmp -s "$(hdmirx_blob "$profile")" "$installed"
    [ "$(stat -c '%s' "$installed")" -eq 256 ]

    case "$profile" in
      full) expected="$HDMIRX_EDID_SHA256_FULL" ;;
      robust-4k60) expected="$HDMIRX_EDID_SHA256_ROBUST" ;;
      *) fail "profile '$profile' has no pinned SHA-256 in this suite" ;;
    esac
    sum="$(sha256sum "$installed" | cut -d' ' -f1)"
    [ "$sum" = "$expected" ]
  done < <(hdmirx_generator_profiles)

  # The consumer half of the same interface: the script's own default directory
  # must be where the installer writes, or the unit programs nothing on the board.
  grep -Fq "CERALIVE_HDMIRX_EDID_DIR:-$HDMIRX_BLOB_DIR" "$(hdmirx_script)"
}

@test "hdmirx edid: the two profiles are DIFFERENT blobs (a copy would silently disable the choice)" {
  run cmp -s "$(hdmirx_blob full)" "$(hdmirx_blob robust-4k60)"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# (iv) The profile set is one list written three times, and they agree.
# ===========================================================================

@test "hdmirx edid: the generator, the installer and the apply script declare the SAME profiles" {
  local expected
  expected="$(hdmirx_generator_profiles | sort | tr '\n' ' ')"
  [ "$expected" = "full robust-4k60 " ]

  # The installer's copy (a subimage chroot can source neither of the others).
  local installer
  installer="$(sed -n 's/^HDMIRX_EDID_PROFILES=(\(.*\))$/\1/p' \
    "$PIPELINE_DIR/mkosi/customize/postinst.d/hardware.sh" | tr -d '"' | tr ' ' '\n' | sort | tr '\n' ' ')"
  [ "$installer" = "$expected" ]

  # The apply script's copy, which decides what an operator may select.
  local script_copy
  script_copy="$(sed -n 's/^KNOWN_PROFILES=(\(.*\))$/\1/p' "$(hdmirx_script)" \
    | tr -d '"' | tr ' ' '\n' | sort | tr '\n' ' ')"
  [ "$script_copy" = "$expected" ]
}

@test "hdmirx edid: every declared profile has a committed blob AND a decoded text file" {
  local profile
  while read -r profile; do
    [ -s "$(hdmirx_blob "$profile")" ]
    [ -s "$(hdmirx_blob "$profile").txt" ]
    # The decoded form is committed for human review, so it must be the CURRENT
    # decode — a stale one is worse than none, it reads as a reviewed artifact.
    grep -q '^EDID conformity: PASS$' "$(hdmirx_blob "$profile").txt"
  done < <(hdmirx_generator_profiles)
}

# ===========================================================================
# (v) Runtime profile resolution, driving the REAL shipped script.
# ===========================================================================

@test "hdmirx edid: with no persisted config the script applies the DEFAULT profile" {
  local root="$BATS_TEST_TMPDIR/resolve-absent"
  hdmirx_fake_board "$root"
  run_hdmirx_apply "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"active EDID profile: full"* ]]
  cmp -s "$root/applied.edid" "$(hdmirx_blob full)"
}

@test "hdmirx edid: a persisted robust-4k60 selection applies the robust blob" {
  local root="$BATS_TEST_TMPDIR/resolve-robust"
  hdmirx_fake_board "$root"
  # Comments, blank lines and surrounding whitespace are all tolerated — an
  # operator editing this file by hand must not be punished for formatting.
  hdmirx_set_profile "$root" "$(printf '# device profile\n\n  %s =  robust-4k60  \n' "$HDMIRX_PROFILE_KEY")"
  run_hdmirx_apply "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"active EDID profile: robust-4k60"* ]]
  cmp -s "$root/applied.edid" "$(hdmirx_blob robust-4k60)"

  # Non-vacuity: the robust blob must NOT be what the default case applies.
  run cmp -s "$root/applied.edid" "$(hdmirx_blob full)"
  [ "$status" -ne 0 ]
}

@test "hdmirx edid: a config that sets some OTHER key falls through to the default" {
  local root="$BATS_TEST_TMPDIR/resolve-otherkey"
  hdmirx_fake_board "$root"
  hdmirx_set_profile "$root" "$(printf 'some.other.key=robust-4k60\n')"
  run_hdmirx_apply "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sets no $HDMIRX_PROFILE_KEY"* ]]
  [[ "$output" == *"active EDID profile: full"* ]]
  cmp -s "$root/applied.edid" "$(hdmirx_blob full)"
}

@test "hdmirx edid: an UNKNOWN profile name falls back to the default and says so" {
  local root="$BATS_TEST_TMPDIR/resolve-unknown"
  hdmirx_fake_board "$root"
  hdmirx_set_profile "$root" "$(printf '%s=hyper-8k\n' "$HDMIRX_PROFILE_KEY")"
  run_hdmirx_apply "$root"
  [ "$status" -eq 0 ]
  # The rejected value must appear verbatim, or an operator cannot tell a typo
  # from a profile the image does not carry.
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"'hyper-8k'"* ]]
  [[ "$output" == *"active EDID profile: full"* ]]
  cmp -s "$root/applied.edid" "$(hdmirx_blob full)"
}

@test "hdmirx edid: a CORRUPT persisted config falls back to the default, never aborts" {
  local root="$BATS_TEST_TMPDIR/resolve-corrupt"
  hdmirx_fake_board "$root"
  # Random bytes with no newline structure: the shape a truncated or
  # partially-overwritten file on /data actually takes.
  head -c 4096 /dev/urandom >"$root$HDMIRX_CONF_PATH"
  run_hdmirx_apply "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"active EDID profile: full"* ]]
  cmp -s "$root/applied.edid" "$(hdmirx_blob full)"
}

@test "hdmirx edid: an OVERSIZED persisted config is refused rather than parsed" {
  local root="$BATS_TEST_TMPDIR/resolve-huge"
  hdmirx_fake_board "$root"
  head -c 70000 /dev/zero >"$root$HDMIRX_CONF_PATH"
  run_hdmirx_apply "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"active EDID profile: full"* ]]
}

@test "hdmirx edid: a persisted config that is not a regular file falls back to the default" {
  local root="$BATS_TEST_TMPDIR/resolve-dir"
  hdmirx_fake_board "$root"
  rm -f "$root$HDMIRX_CONF_PATH"
  mkdir -p "$root$HDMIRX_CONF_PATH"
  run_hdmirx_apply "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"active EDID profile: full"* ]]
}

@test "hdmirx edid: a selected profile whose blob is MISSING falls back to the default" {
  local root="$BATS_TEST_TMPDIR/resolve-noblob"
  hdmirx_fake_board "$root"
  hdmirx_set_profile "$root" "$(printf '%s=robust-4k60\n' "$HDMIRX_PROFILE_KEY")"
  rm -f "$root$HDMIRX_BLOB_DIR/hdmirx-robust-4k60.edid"
  run_hdmirx_apply "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"active EDID profile: full"* ]]
  cmp -s "$root/applied.edid" "$(hdmirx_blob full)"
}

@test "hdmirx edid: a missing DEFAULT blob is FATAL (there is nothing left to fall back to)" {
  local root="$BATS_TEST_TMPDIR/resolve-nodefault"
  hdmirx_fake_board "$root"
  rm -f "$root$HDMIRX_BLOB_DIR/hdmirx-full.edid"
  run_hdmirx_apply "$root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"EDID blob missing or empty"* ]]
  [ ! -e "$root/applied.edid" ]
}

@test "hdmirx edid: the persisted selector is PARSED, never sourced" {
  # The key contains a dot, so it is not a shell identifier — and a device-
  # writable file that gets sourced is arbitrary code execution as root at boot.
  local script; script="$(hdmirx_script)"
  grep -Fq "PROFILE_KEY=\"$HDMIRX_PROFILE_KEY\"" "$script"
  grep -Fq "CERALIVE_HDMIRX_CONF:-$HDMIRX_CONF_PATH" "$script"
  run grep -nE '^\s*(\.|source)\s+"?\$\{?CONF' "$script"
  [ "$status" -ne 0 ]
}

@test "hdmirx edid: the selector lives on /data so it survives an A/B OTA" {
  # A rootfs-slot path would lose the operator's choice on the next update, and
  # would do it silently — the board would simply come back on the default.
  [[ "$HDMIRX_CONF_PATH" == /data/* ]]
  grep -Fq "CERALIVE_HDMIRX_CONF:-$HDMIRX_CONF_PATH" "$(hdmirx_script)"
}

# ===========================================================================
# (vi) An EDID write is a live renegotiation: EBUSY is honoured, never forced.
# ===========================================================================

@test "hdmirx edid: an EBUSY from the driver is a clean, LOUD refusal with no retry" {
  local root="$BATS_TEST_TMPDIR/ebusy"
  hdmirx_fake_board "$root"
  run_hdmirx_apply "$root" HDMIRX_STUB_BUSY=1
  # Non-zero on purpose: Type=oneshot + RemainAfterExit=yes means an exit 0 here
  # would read as "active (exited)", i.e. as an EDID that was applied.
  [ "$status" -ne 0 ]
  [[ "$output" == *"EBUSY"* ]]
  [[ "$output" == *"STREAMING"* ]]
  [ ! -e "$root/applied.edid" ]
}

@test "hdmirx edid: nothing on the apply path unbinds, forces or stops a stream" {
  # The kernel's -EBUSY guard is the authority. A script that worked around it
  # would be renegotiating an operator's source mid-broadcast.
  #
  # EXECUTABLE lines only: the header legitimately DISCUSSES unbind/rebind as the
  # documented lifecycle limitation, and a grep that counted prose would fail on
  # the very comment that explains why the rule exists.
  local executable="$BATS_TEST_TMPDIR/apply-executable.sh"
  grep -vE '^[[:space:]]*#' "$(hdmirx_script)" >"$executable"
  [ -s "$executable" ]
  run grep -nE '(unbind|--force|systemctl (stop|kill)|fuser -k|pkill)' "$executable"
  [ "$status" -ne 0 ]

  # Non-vacuity: the same scan MUST fire on a planted workaround, or it is only
  # proving that the comment-stripping worked.
  printf 'systemctl stop cerastream.service\n' >>"$executable"
  run grep -nE '(unbind|--force|systemctl (stop|kill)|fuser -k|pkill)' "$executable"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# (vii) Ordering without a requirement, in BOTH directions.
# ===========================================================================

@test "hdmirx edid: the unit is ordered Before=cerastream.service and is NOT required by it" {
  local unit; unit="$(hdmirx_unit)"
  grep -Eq '^Before=.*\bcerastream\.service\b' "$unit"
  grep -Eq '^Before=.*\bceralive\.service\b' "$unit"

  # A dead HDMI-RX must still boot a fully usable USB-capture-only device, so
  # the failure has to be loud in `systemctl` and inert for cerastream. That
  # rules out a hard dependency in EITHER direction.
  run grep -Eq '^(Requires|Requisite|BindsTo|Wants|PartOf)=' "$unit"
  [ "$status" -ne 0 ]

  # Nothing this repo ships may pull the EDID unit in as a requirement of
  # cerastream either — a drop-in doing so would re-couple them out of sight.
  run grep -rEn '^(Requires|Requisite|BindsTo|PartOf)=.*ceralive-hdmirx-edid' \
    "$PIPELINE_DIR/mkosi"
  [ "$status" -ne 0 ]
}

@test "hdmirx edid: the unit is ordered After=data.mount but does NOT require /data" {
  local unit; unit="$(hdmirx_unit)"
  # Ordering is what stops a board that selected robust-4k60 being programmed
  # with full because the selector had not been mounted yet.
  grep -Eq '^After=.*\bdata\.mount\b' "$unit"

  # RequiresMountsFor= would add Requires= as well as After=, so a board whose
  # /data failed to mount would get NO EDID at all instead of the default one.
  run grep -Eq '^RequiresMountsFor=' "$unit"
  [ "$status" -ne 0 ]
}

@test "hdmirx edid: the unit is ordered After=systemd-udev-trigger and bounds its own start" {
  # Before= alone would let it run before the coldplug that binds the driver and
  # writes the udev symlink; the script then owns the async probe race itself,
  # and TimeoutStartSec must exceed that bounded poll or systemd turns a slow
  # probe into a unit failure that reads like a driver defect.
  local unit; unit="$(hdmirx_unit)"
  grep -Eq '^After=.*systemd-udev-trigger\.service' "$unit"
  grep -Eq '^Type=oneshot$' "$unit"
  local timeout
  timeout="$(sed -n 's/^TimeoutStartSec=//p' "$unit")"
  [ -n "$timeout" ]
  [ "$timeout" -gt 30 ]
}

# ===========================================================================
# (viii) Both blobs PASS their OWN profile check — and fail the other one.
# ===========================================================================

@test "hdmirx edid: the full blob PASSES the full profile check (non-vacuity)" {
  # Without this, the rejections below would be indistinguishable from a checker
  # that rejects everything.
  run edid_conformance check full "$(hdmirx_blob full)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok   VIC 97 is offered in the ordinary Video Data Block"* ]]
  [[ "$output" == *"ok   SCDC Present"* ]]
  [[ "$output" == *"ok   Y420CMDB (4:2:0 capability map) is present"* ]]
  [[ "$output" == *"ok   YCbCr 4:4:4 is NOT advertised"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "hdmirx edid: the robust-4k60 blob PASSES the robust profile check (non-vacuity)" {
  run edid_conformance check robust-4k60 "$(hdmirx_blob robust-4k60)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok   Y420VDB (4:2:0-only video) is present"* ]]
  [[ "$output" == *"ok   no HDMI Forum VSDB"* ]]
  [[ "$output" == *"ok   VIC 97 is ABSENT from the ordinary Video Data Block"* ]]
  [[ "$output" == *"ok   preferred DTD pixel clock is <= 297 MHz"* ]]
  [[ "$output" == *"ok   YCbCr 4:4:4 is NOT advertised"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "hdmirx edid: each blob FAILS the OTHER profile's check" {
  # The two profiles make opposite claims. A checker that accepted either blob
  # for either profile would pass an image that shipped the wrong one twice.
  run edid_conformance check robust-4k60 "$(hdmirx_blob full)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL no HDMI Forum VSDB"* ]]

  run edid_conformance check full "$(hdmirx_blob robust-4k60)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL HDMI Forum VSDB (OUI C4-5D-D8) is present"* ]]
}

# ===========================================================================
# (ix) Negative fixtures — each rejected for a DIFFERENT, named reason.
# ===========================================================================

@test "hdmirx edid: a 4K30-only EDID with no SCDC FAILS the full profile check" {
  local fixture="$BATS_TEST_TMPDIR/4k30-no-scdc.edid"
  run edid_conformance make-negative 4k30-no-scdc "$(hdmirx_blob full)" "$fixture"
  [ "$status" -eq 0 ]

  run edid_conformance check full "$fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL VIC 97 is offered in the ordinary Video Data Block"* ]]
  [[ "$output" == *"FAIL Maximum TMDS Character Rate is >= 600 MHz"* ]]
  [[ "$output" == *"FAIL SCDC Present"* ]]

  # It is rejected on CAPABILITY, not on structure: both block checksums are
  # still valid. A checksum-only gate would ship this and negotiate 4K30.
  [[ "$output" == *"ok   base block checksum is valid"* ]]
  [[ "$output" == *"ok   extension block checksum is valid"* ]]
}

@test "hdmirx edid: a bad-checksum EDID FAILS the conformance checker" {
  local fixture="$BATS_TEST_TMPDIR/bad-checksum.edid"
  run edid_conformance make-negative bad-checksum "$(hdmirx_blob full)" "$fixture"
  [ "$status" -eq 0 ]

  run edid_conformance check full "$fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL base block checksum is valid"* ]]

  # The orthogonal half of the pair: this one still claims every 4K60
  # capability, so a content-only gate would accept a corrupt blob.
  [[ "$output" == *"ok   VIC 97 is offered in the ordinary Video Data Block"* ]]
  [[ "$output" == *"ok   SCDC Present"* ]]
}

@test "hdmirx edid: swapping Y420VDB for Y420CMDB is caught in BOTH profiles" {
  # One byte turns "4:2:0-only" into "additionally 4:2:0" — opposite claims about
  # which pixel formats a source may send — and the result is a structurally
  # valid EDID. This is the exact confusion the two profiles are built around.
  local swapped_full="$BATS_TEST_TMPDIR/swap-full.edid"
  edid_conformance make-negative y420-block-swap "$(hdmirx_blob full)" "$swapped_full"
  run edid_conformance check full "$swapped_full"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL Y420CMDB (4:2:0 capability map) is present"* ]]
  [[ "$output" == *"FAIL no Y420VDB"* ]]
  [[ "$output" == *"ok   extension block checksum is valid"* ]]

  local swapped_robust="$BATS_TEST_TMPDIR/swap-robust.edid"
  edid_conformance make-negative y420-block-swap "$(hdmirx_blob robust-4k60)" "$swapped_robust"
  run edid_conformance check robust-4k60 "$swapped_robust"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL Y420VDB (4:2:0-only video) is present"* ]]
  [[ "$output" == *"FAIL no Y420CMDB"* ]]
  [[ "$output" == *"ok   extension block checksum is valid"* ]]
}

@test "hdmirx edid: a robust-4k60 blob that keeps an HF-VSDB FAILS on exactly that" {
  # The whole point of the profile is the ABSENCE of the block that advertises
  # SCDC and >300 MHz. Everything else about the fixture stays conformant, so a
  # single FAIL is the correct and sufficient verdict.
  local fixture="$BATS_TEST_TMPDIR/robust-hf.edid"
  run edid_conformance make-negative robust-with-hf-vsdb \
    "$(hdmirx_blob robust-4k60)" "$fixture"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%s' "$fixture")" -eq 256 ]

  run edid_conformance check robust-4k60 "$fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL no HDMI Forum VSDB"* ]]
  [ "$(grep -c 'FAIL' <<<"$output")" -eq 1 ]
  [[ "$output" == *"ok   Y420VDB (4:2:0-only video) is present"* ]]
  [[ "$output" == *"ok   extension block checksum is valid"* ]]
}

@test "hdmirx edid: the smallest negative fixtures differ from their blob in the smallest possible way" {
  # A fixture that shares no bytes with the real blob proves nothing about the
  # real blob's failure modes. Each is a targeted edit, not a random 256 bytes.
  # (robust-with-hf-vsdb is deliberately excluded: an INSERTION shifts the tail
  # of the block, so its minimality is expressed as "exactly one FAIL" above.)
  local good; good="$(hdmirx_blob full)"
  local bad="$BATS_TEST_TMPDIR/min-bad.edid"
  local weak="$BATS_TEST_TMPDIR/min-weak.edid"
  local swap="$BATS_TEST_TMPDIR/min-swap.edid"
  edid_conformance make-negative bad-checksum "$good" "$bad"
  edid_conformance make-negative 4k30-no-scdc "$good" "$weak"
  edid_conformance make-negative y420-block-swap "$good" "$swap"

  [ "$(cmp -l "$good" "$bad" | wc -l)" -eq 1 ]
  # two SVD bytes + the TMDS rate + the SCDC flags byte + the resealed checksum
  [ "$(cmp -l "$good" "$weak" | wc -l)" -eq 5 ]
  # the extended tag byte + the resealed checksum
  [ "$(cmp -l "$good" "$swap" | wc -l)" -eq 2 ]
}

# ===========================================================================
# (x) No node-index assumptions, in the tests or in what they test.
# ===========================================================================

@test "hdmirx edid: no test in this suite assumes a /dev/video node index" {
  # A USB capture card can take the low index and renumber the SoC receiver, so
  # every reference must go through the driver-keyed udev symlink. The pattern
  # below cannot match itself: the bracket expression is not a digit.
  run grep -nE '/dev/video[0-9]' "$BATS_TEST_FILENAME" "$TESTS_DIR/lib/edid-conformance.py"
  [ "$status" -ne 0 ]
}

@test "hdmirx edid: the shipped script and unit reach the receiver by symlink, never by node index" {
  local script; script="$(hdmirx_script)"
  grep -Fq 'CERALIVE_HDMIRX_DEV:-/dev/hdmirx' "$script"
  run grep -nE '/dev/video[0-9]' "$script" "$(hdmirx_unit)"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# Fail-closed install, and the wiring that makes any of it run at all.
# ===========================================================================

@test "hdmirx edid: a missing runtime source FAILS the build (fail-closed, nothing installed)" {
  local root="$BATS_TEST_TMPDIR/failclosed"
  mkdir -p "$root/empty-src"
  run env CERALIVE_RUNTIME_SRC="$root/empty-src" \
    HDMIRX_EDID_UNIT_DIR="$root/units" \
    HDMIRX_EDID_SBIN_DIR="$root/sbin" \
    HDMIRX_EDID_BLOB_DIR="$root/blob" \
    bash -c "source '$POSTINST_ENTRY'; setup_hdmirx_edid"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hdmirx-edid script not found"* ]]
  [ ! -e "$root/units/ceralive-hdmirx-edid.service" ]
  [ ! -e "$root/blob" ]
}

@test "hdmirx edid: a missing EDID blob FAILS the build, for EVERY profile" {
  # The script and the unit alone install cleanly and then program nothing —
  # exactly the silent outcome the loud-fail applicability table exists to avoid.
  # Each profile is dropped in turn, so a check that only ever looked at the
  # first one cannot pass.
  local profile
  while read -r profile; do
    local root="$BATS_TEST_TMPDIR/failclosed-blob-$profile"
    mkdir -p "$root/src/edid"
    cp "$PIPELINE_DIR/mkosi/runtime/ceralive-hdmirx-edid.sh" \
       "$PIPELINE_DIR/mkosi/runtime/ceralive-hdmirx-edid.service" "$root/src/"
    local other
    while read -r other; do
      [ "$other" = "$profile" ] && continue
      cp "$(hdmirx_blob "$other")" "$root/src/edid/ceralive-hdmirx-$other.edid"
    done < <(hdmirx_generator_profiles)

    run env CERALIVE_RUNTIME_SRC="$root/src" \
      HDMIRX_EDID_UNIT_DIR="$root/units" \
      HDMIRX_EDID_SBIN_DIR="$root/sbin" \
      HDMIRX_EDID_BLOB_DIR="$root/blob" \
      bash -c "source '$POSTINST_ENTRY'; setup_hdmirx_edid"
    [ "$status" -ne 0 ]
    [[ "$output" == *"hdmirx EDID blob not found"* ]]
    [[ "$output" == *"ceralive-hdmirx-$profile.edid"* ]]
    [ ! -e "$root/blob" ]
  done < <(hdmirx_generator_profiles)
}

@test "hdmirx edid: setup_hdmirx_edid is wired into configure_services" {
  # An unreferenced setup function is dead code — the receiver would ship unprogrammed.
  run grep -E '^\s*setup_hdmirx_edid$' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
}

@test "hdmirx edid: setup_hdmirx_edid is a single source of truth (drift gate registered)" {
  # The gate only checks the functions it is told about; an unregistered one
  # could be re-inlined into the runtime executor without anything noticing.
  serialize working-tree   # postinst-wiring.bats mutates the tree this gate reads
  grep -Fq 'setup_hdmirx_edid' "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  run bash "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup_hdmirx_edid: single source"* ]]
}
