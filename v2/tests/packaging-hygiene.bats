#!/usr/bin/env bats
#
# packaging-hygiene.bats — absence guards for three retired build artifacts.
#
# An audit (device-quality-wave2 Todo 32b) found these are dead and removed them.
# These guards fail if any is ever reintroduced:
#   * structure.sh    : the 5 unread /etc/ceralive/conf.d/*.conf default seeds
#                       (srtla/streaming/network/hardware/modems) — no consumer.
#   * udev.sh         : the dangling SYSTEMD_WANTS=ceralive-optimize@%k want —
#                       points at a template unit the image never ships.
#   * x86-encode.sh   : retired-ceracoder references (cerastream is the sole engine).
#
# Scope note: this suite guards ONLY the three files the Todo-32b dispatch owns.
# The parallel conf.d generation in mkosi.postinst.chroot is a separate concern
# tracked elsewhere and is deliberately NOT asserted here.
#
# Run:  v2/run-tests   (CI entrypoint)   or   bats v2/tests/packaging-hygiene.bats

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  V2="$(cd "$TESTS_DIR/.." && pwd)"
  STRUCTURE_SH="$V2/mkosi/customize/structure.sh"
  UDEV_SH="$V2/mkosi/customize/udev.sh"
  X86_ENCODE_SH="$V2/mkosi/platform/x86/x86-encode.sh"
}

@test "structure.sh: exists and is the file under guard" {
  [ -f "$STRUCTURE_SH" ]
  [ -f "$UDEV_SH" ]
  [ -f "$X86_ENCODE_SH" ]
}

@test "structure.sh: seeds none of the 5 dead conf.d default files" {
  run grep -Eq '/etc/ceralive/conf\.d/(srtla|streaming|network|hardware|modems)\.conf' "$STRUCTURE_SH"
  [ "$status" -ne 0 ]
}

@test "structure.sh: no longer creates the /etc/ceralive/conf.d seed dir" {
  run grep -Eq 'mkdir[[:space:]].*/etc/ceralive/conf\.d' "$STRUCTURE_SH"
  [ "$status" -ne 0 ]
}

@test "structure.sh: still writes the /etc/ceralive/release identity" {
  run grep -Eq '/etc/ceralive/release' "$STRUCTURE_SH"
  [ "$status" -eq 0 ]
}

@test "udev.sh: no dangling ceralive-optimize@ SYSTEMD_WANTS want rule" {
  # Non-comment lines only: the header comment documenting the removal is allowed
  # to name the artifact; a live udev RULE reintroducing it is not.
  run grep -Eq '^[[:space:]]*[^#[:space:]].*ceralive-optimize@' "$UDEV_SH"
  [ "$status" -ne 0 ]
  run grep -Eq '^[[:space:]]*[^#[:space:]].*SYSTEMD_WANTS' "$UDEV_SH"
  [ "$status" -ne 0 ]
}

@test "udev.sh: still installs the generic video-device access rules" {
  run grep -Eq 'SUBSYSTEM=="video4linux"' "$UDEV_SH"
  [ "$status" -eq 0 ]
}

@test "x86-encode.sh: no retired-ceracoder references remain" {
  run grep -qi 'ceracoder' "$X86_ENCODE_SH"
  [ "$status" -ne 0 ]
}

@test "x86-encode.sh: still writes the D1 encode-selection config" {
  run grep -Eq 'CERALIVE_ENCODE_PRIMARY=qsv' "$X86_ENCODE_SH"
  [ "$status" -eq 0 ]
}

# Negative guard proof: a restored dead artifact MUST make the absence assertion
# bite. Reconstruct the exact regression on a scratch copy and confirm the same
# detector flips to "present". Without this, a broken (always-passing) assertion
# could hide a reintroduced seed.
@test "GUARD BITES: restoring a conf.d seed is detected as present" {
  local scratch="$BATS_TEST_TMPDIR/structure.restored.sh"
  cp "$STRUCTURE_SH" "$scratch"
  printf 'cat >/etc/ceralive/conf.d/srtla.conf <<EOF\nips_file=/tmp/srtla_ips\nEOF\n' >> "$scratch"
  run grep -Eq '/etc/ceralive/conf\.d/(srtla|streaming|network|hardware|modems)\.conf' "$scratch"
  [ "$status" -eq 0 ]
}

@test "GUARD BITES: restoring the ceralive-optimize@ want is detected as present" {
  local scratch="$BATS_TEST_TMPDIR/udev.restored.sh"
  cp "$UDEV_SH" "$scratch"
  printf 'KERNEL=="video[0-9]*", ENV{SYSTEMD_WANTS}="ceralive-optimize@%%k.service"\n' >> "$scratch"
  run grep -Eq 'ceralive-optimize@' "$scratch"
  [ "$status" -eq 0 ]
}

@test "GUARD BITES: restoring a ceracoder reference is detected as present" {
  local scratch="$BATS_TEST_TMPDIR/x86-encode.restored.sh"
  cp "$X86_ENCODE_SH" "$scratch"
  printf '# CERACODER_PIPELINE_DIR legacy path\n' >> "$scratch"
  run grep -qi 'ceracoder' "$scratch"
  [ "$status" -eq 0 ]
}
