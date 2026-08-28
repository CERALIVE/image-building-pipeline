#!/usr/bin/env bats
#
# packaging-hygiene.bats — absence guards for retired build artifacts.
#
# An audit (device-quality-wave2 Todo 32b) found the first three are dead and
# removed them. These guards fail if any is ever reintroduced:
#   * structure.sh    : the 5 unread /etc/ceralive/conf.d/*.conf default seeds
#                       (srtla/streaming/network/hardware/modems) — no consumer.
#   * udev.sh         : the dangling SYSTEMD_WANTS=ceralive-optimize@%k want —
#                       points at a template unit the image never ships.
#   * x86-encode.sh   : retired-ceracoder references (cerastream is the sole engine).
#
# The fourth is the whole KERNEL-EXTENSION mechanism. It existed for exactly one
# package — `ceralive-cls-fw`, an ABI-matched out-of-tree cls_fw.ko built because
# the prebuilt vendor kernel omits CONFIG_NET_CLS_FW. The production kernel is now
# built from source with `CONFIG_NET_CLS_FW=y` in-tree, so the package has no
# reason to exist and the plumbing that carried it has no consumer. Reintroducing
# either half would put an out-of-tree module tied to one kernel release back on
# an image whose kernel release it does not match.
#
# Scope note: this suite guards ONLY the files the dispatches above own. The
# parallel conf.d generation in mkosi.postinst.chroot is a separate concern
# tracked elsewhere and is deliberately NOT asserted here.
#
# Run:  run-tests   (CI entrypoint)   or   bats tests/packaging-hygiene.bats

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PIPELINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  STRUCTURE_SH="$PIPELINE_DIR/mkosi/customize/structure.sh"
  UDEV_SH="$PIPELINE_DIR/mkosi/customize/udev.sh"
  X86_ENCODE_SH="$PIPELINE_DIR/mkosi/platform/x86/x86-encode.sh"
  FAMILY_SCHEMA="$PIPELINE_DIR/manifests/schema/family.schema.json"
  RK3588_FAMILY="$PIPELINE_DIR/manifests/families/rk3588.yaml"
}

# --- retired kernel-extension mechanism (ceralive-cls-fw) --------------------

@test "cls-fw: every file of the retired kernel-extension mechanism is gone" {
  local path
  for path in manifests/kernel/vendor-cls-fw.env \
              manifests/packages/rk3588-vendor-kernel-extensions.list \
              lib/build-kernel-extension.sh \
              lib/kernel/build-cls-fw-container.sh \
              ci/Dockerfile.kernel-module \
              tests/vendor-cls-fw-contract.bats; do
    [ ! -e "$PIPELINE_DIR/$path" ]
  done
}

@test "cls-fw: no live code path still carries KERNEL_EXTENSION_PACKAGES" {
  # The env name was on the orchestrator's env_names <-> mkosi PassEnvironment=
  # lockstep, so a survivor on either side is a half-removed mechanism rather
  # than a stale string.
  local path
  for path in lib/orchestrate.sh lib/stages/kernel-build.sh lib/stages/fetch.sh \
              lib/stages/partition.sh mkosi/mkosi.conf \
              mkosi/mkosi.images/platform/mkosi.postinst; do
    run grep -Fq 'KERNEL_EXTENSION_PACKAGES' "$PIPELINE_DIR/$path"
    [ "$status" -ne 0 ]
  done
}

@test "cls-fw: the family schema no longer admits kernel_extension_packages" {
  run grep -Fq 'kernel_extension_packages' "$FAMILY_SCHEMA"
  [ "$status" -ne 0 ]
  run grep -Fq 'kernel_extension_packages' "$RK3588_FAMILY"
  [ "$status" -ne 0 ]
  # Non-comment lines only, the same rule this suite already applies to udev.sh:
  # the manifest is allowed — and expected — to say in prose why the package is
  # gone; a live YAML row naming it is what must never come back.
  run grep -Eq '^[[:space:]]*[^#[:space:]].*ceralive-cls-fw' "$RK3588_FAMILY"
  [ "$status" -ne 0 ]
}

@test "GUARD BITES: a restored kernel-extension install site is detected" {
  local scratch="$BATS_TEST_TMPDIR/platform.restored.postinst"
  cp "$PIPELINE_DIR/mkosi/mkosi.images/platform/mkosi.postinst" "$scratch"
  printf 'read -r -a kernel_extensions <<<"${KERNEL_EXTENSION_PACKAGES:-}"\n' >> "$scratch"
  run grep -Fq 'KERNEL_EXTENSION_PACKAGES' "$scratch"
  [ "$status" -eq 0 ]
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
