#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# hdmirx-edid-contract.bats — the HDMI-RX product EDID contract: what
# postinst.d/hardware.sh::setup_hdmirx_edid installs, where, with which modes,
# how the unit is ordered, and what a NON-conformant EDID must do to the
# conformance checker.
#
# WHY THIS IS ITS OWN SUITE. The three artifacts have three different owners:
# the apply script and its oneshot come from mkosi/runtime/, the 256-byte blob
# comes from tools/gen-hdmirx-edid.py (drift-gated in CI), and the install +
# enable wiring comes from postinst.d/hardware.sh. Only an installed-tree test
# can prove they agree with each other — the CI EDID job proves the blob is a
# conformant EDID and says nothing about whether it reaches the board, while the
# postinst suites prove wiring and say nothing about the bytes.
#
# NOTHING HERE ASSUMES A /dev/video NODE INDEX, and one case enforces that on the
# suite itself: the HDMI-RX node is reached through the driver-keyed udev symlink
# because a USB capture card can take the low index and renumber the receiver.
#
# UNIT scope: temp install dirs, a stubbed systemctl, and raw byte reads. No
# image, no board, no systemd.
#
# Run:  run-tests              (CI entrypoint)
#   or: bats tests/hdmirx-edid-contract.bats

load manifest-helpers

# The committed blob's SHA-256, pinned here as a SECOND, independent statement of
# what this image ships. tools/gen-hdmirx-edid.py plus the CI drift gate decide
# what the blob IS; this value is what makes a silent substitution on the way to
# /etc/ceralive/hdmirx.edid fail a test rather than a shoot.
HDMIRX_EDID_SHA256=9e4a0f227357e5b9025231446d4da40c4094fb9905b64f4a4dea84bbbdb71f9c

# The two on-device paths the unit's ExecStart and the script's own default
# already name. They are a fixed interface: the installer, the unit and the
# script must all agree, so they are written down once and asserted three ways.
HDMIRX_SBIN_PATH=/usr/local/sbin/ceralive-hdmirx-edid
HDMIRX_BLOB_PATH=/etc/ceralive/hdmirx.edid

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
    HDMIRX_EDID_BLOB_DIR="$root$(dirname "$HDMIRX_BLOB_PATH")" \
    bash -c "source '$POSTINST_ENTRY'; setup_hdmirx_edid"
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
  grep -Eq '^WantedBy=multi-user\.target$' \
    "$PIPELINE_DIR/mkosi/runtime/ceralive-hdmirx-edid.service"
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
  grep -Fxq "ExecStart=$HDMIRX_SBIN_PATH" \
    "$PIPELINE_DIR/mkosi/runtime/ceralive-hdmirx-edid.service"
}

@test "hdmirx edid: the unit and the blob are installed 0644 (data, never executable)" {
  local root="$BATS_TEST_TMPDIR/install-datamodes"
  install_hdmirx_edid "$root"
  [ "$status" -eq 0 ]

  [ "$(stat -c '%a' "$root/etc/systemd/system/ceralive-hdmirx-edid.service")" = "644" ]
  [ "$(stat -c '%a' "$root$HDMIRX_BLOB_PATH")" = "644" ]
}

# ===========================================================================
# (iii) The blob reaches its runtime path, byte-intact.
# ===========================================================================

@test "hdmirx edid: the installed blob is byte-identical to the committed one and matches its pinned SHA-256" {
  local root="$BATS_TEST_TMPDIR/install-blob"
  install_hdmirx_edid "$root"
  [ "$status" -eq 0 ]

  local committed="$PIPELINE_DIR/mkosi/runtime/edid/ceralive-hdmirx.edid"
  local installed="$root$HDMIRX_BLOB_PATH"
  [ -s "$installed" ]
  cmp -s "$committed" "$installed"
  [ "$(stat -c '%s' "$installed")" -eq 256 ]

  local sum
  sum="$(sha256sum "$installed" | cut -d' ' -f1)"
  [ "$sum" = "$HDMIRX_EDID_SHA256" ]

  # The consumer half of the same interface: the script's own default must be
  # the path the installer writes, or the unit programs nothing on the board.
  grep -Fq "CERALIVE_HDMIRX_EDID:-$HDMIRX_BLOB_PATH" \
    "$PIPELINE_DIR/mkosi/runtime/ceralive-hdmirx-edid.sh"
}

# ===========================================================================
# (iv) Ordering without a requirement, in BOTH directions.
# ===========================================================================

@test "hdmirx edid: the unit is ordered Before=cerastream.service and is NOT required by it" {
  local unit="$PIPELINE_DIR/mkosi/runtime/ceralive-hdmirx-edid.service"
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

@test "hdmirx edid: the unit is ordered After=systemd-udev-trigger and bounds its own start" {
  # Before= alone would let it run before the coldplug that binds the driver and
  # writes the udev symlink; the script then owns the async probe race itself,
  # and TimeoutStartSec must exceed that bounded poll or systemd turns a slow
  # probe into a unit failure that reads like a driver defect.
  local unit="$PIPELINE_DIR/mkosi/runtime/ceralive-hdmirx-edid.service"
  grep -Eq '^After=.*systemd-udev-trigger\.service' "$unit"
  grep -Eq '^Type=oneshot$' "$unit"
  local timeout
  timeout="$(sed -n 's/^TimeoutStartSec=//p' "$unit")"
  [ -n "$timeout" ]
  [ "$timeout" -gt 30 ]
}

# ===========================================================================
# (v) Negative fixtures — both are REJECTED by the conformance checker, and the
#     two rejections are for different reasons.
# ===========================================================================

@test "hdmirx edid: the committed blob PASSES the conformance checker (non-vacuity)" {
  # Without this, the two rejections below would be indistinguishable from a
  # checker that rejects everything.
  run edid_conformance check "$PIPELINE_DIR/mkosi/runtime/edid/ceralive-hdmirx.edid"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VIC 97 (3840x2160p60) is offered"* ]]
  [[ "$output" == *"SCDC Present"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "hdmirx edid: a 4K30-only EDID with no SCDC FAILS the conformance checker" {
  local fixture="$BATS_TEST_TMPDIR/4k30-no-scdc.edid"
  run edid_conformance make-negative 4k30-no-scdc \
    "$PIPELINE_DIR/mkosi/runtime/edid/ceralive-hdmirx.edid" "$fixture"
  [ "$status" -eq 0 ]

  run edid_conformance check "$fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL VIC 97 (3840x2160p60) is offered"* ]]
  [[ "$output" == *"FAIL Maximum TMDS Character Rate is >= 600 MHz"* ]]
  [[ "$output" == *"FAIL SCDC Present"* ]]

  # It is rejected on CAPABILITY, not on structure: both block checksums are
  # still valid. A checksum-only gate would ship this and negotiate 4K30.
  [[ "$output" == *"ok   base block checksum is valid"* ]]
  [[ "$output" == *"ok   extension block checksum is valid"* ]]
}

@test "hdmirx edid: a bad-checksum EDID FAILS the conformance checker" {
  local fixture="$BATS_TEST_TMPDIR/bad-checksum.edid"
  run edid_conformance make-negative bad-checksum \
    "$PIPELINE_DIR/mkosi/runtime/edid/ceralive-hdmirx.edid" "$fixture"
  [ "$status" -eq 0 ]

  run edid_conformance check "$fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL base block checksum is valid"* ]]

  # The orthogonal half of the pair: this one still claims every 4K60
  # capability, so a content-only gate would accept a corrupt blob.
  [[ "$output" == *"ok   VIC 97 (3840x2160p60) is offered"* ]]
  [[ "$output" == *"ok   SCDC Present"* ]]
}

@test "hdmirx edid: the negative fixtures differ from the committed blob in the smallest possible way" {
  # A fixture that shares no bytes with the real blob proves nothing about the
  # real blob's failure modes. Each is a targeted edit, not a random 256 bytes.
  local good="$PIPELINE_DIR/mkosi/runtime/edid/ceralive-hdmirx.edid"
  local bad="$BATS_TEST_TMPDIR/min-bad.edid"
  local weak="$BATS_TEST_TMPDIR/min-weak.edid"
  edid_conformance make-negative bad-checksum "$good" "$bad"
  edid_conformance make-negative 4k30-no-scdc "$good" "$weak"

  [ "$(cmp -l "$good" "$bad" | wc -l)" -eq 1 ]
  # two SVD bytes + the TMDS rate + the SCDC flags byte + the resealed checksum
  [ "$(cmp -l "$good" "$weak" | wc -l)" -eq 5 ]
}

# ===========================================================================
# (vi) No node-index assumptions, in the tests or in what they test.
# ===========================================================================

@test "hdmirx edid: no test in this suite assumes a /dev/video node index" {
  # A USB capture card can take the low index and renumber the SoC receiver, so
  # every reference must go through the driver-keyed udev symlink. The pattern
  # below cannot match itself: the bracket expression is not a digit.
  run grep -nE '/dev/video[0-9]' "$BATS_TEST_FILENAME" "$TESTS_DIR/lib/edid-conformance.py"
  [ "$status" -ne 0 ]
}

@test "hdmirx edid: the shipped script and unit reach the receiver by symlink, never by node index" {
  local script="$PIPELINE_DIR/mkosi/runtime/ceralive-hdmirx-edid.sh"
  local unit="$PIPELINE_DIR/mkosi/runtime/ceralive-hdmirx-edid.service"
  grep -Fq 'CERALIVE_HDMIRX_DEV:-/dev/hdmirx' "$script"
  run grep -nE '/dev/video[0-9]' "$script" "$unit"
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
  [ ! -e "$root/blob/hdmirx.edid" ]
}

@test "hdmirx edid: a missing EDID blob FAILS the build (the third artifact is not optional)" {
  # The script and the unit alone install cleanly and then program nothing —
  # exactly the silent outcome the loud-fail applicability table exists to avoid.
  local root="$BATS_TEST_TMPDIR/failclosed-blob"
  mkdir -p "$root/src"
  cp "$PIPELINE_DIR/mkosi/runtime/ceralive-hdmirx-edid.sh" \
     "$PIPELINE_DIR/mkosi/runtime/ceralive-hdmirx-edid.service" "$root/src/"
  run env CERALIVE_RUNTIME_SRC="$root/src" \
    HDMIRX_EDID_UNIT_DIR="$root/units" \
    HDMIRX_EDID_SBIN_DIR="$root/sbin" \
    HDMIRX_EDID_BLOB_DIR="$root/blob" \
    bash -c "source '$POSTINST_ENTRY'; setup_hdmirx_edid"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hdmirx EDID blob not found"* ]]
  [ ! -e "$root/blob/hdmirx.edid" ]
}

@test "hdmirx edid: setup_hdmirx_edid is wired into configure_services" {
  # An unreferenced setup function is dead code — the receiver would ship unprogrammed.
  run grep -E '^\s*setup_hdmirx_edid$' "$POSTINST_LIB"
  [ "$status" -eq 0 ]
}

@test "hdmirx edid: setup_hdmirx_edid is a single source of truth (drift gate registered)" {
  # The gate only checks the functions it is told about; an unregistered one
  # could be re-inlined into the runtime executor without anything noticing.
  grep -Fq 'setup_hdmirx_edid' "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  run bash "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup_hdmirx_edid: single source"* ]]
}
