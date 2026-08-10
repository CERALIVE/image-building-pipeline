#!/usr/bin/env bats
#
# mkosi-contract.bats — the mkosi configuration surface must be CURRENT for the
# pinned mkosi, and must stay quiet.
#
# Every assertion here traces to a row of docs/build-log-census.md. A real
# rock-5b-plus edge build emitted, on a build that otherwise succeeded:
#
#   census 18  ‣ …/base|platform/mkosi.conf: Setting FinalizeScript is deprecated…   (x2)
#   census 19  ‣ …/disk/mkosi.conf: Setting RepartDirectories should be configured
#                 in [Output], not [Content].
#   census 26  Configured GrowFileSystem=<v> for partition type 'linux-generic'
#              that doesn't support it, ignoring.                                    (x3)
#   census 16  Ign:<N> file:/repository ./ Translation-en                            (x4)
#   census 17  Err:<N> file:/repository ./ Translation-en                            (x24)
#
# A deprecation notice is a countdown: the setting still parses today and is a
# hard error at the next mkosi bump, which would surface as a broken release
# build rather than a warning. The GrowFileSystem keys were worse than noise —
# systemd-repart IGNORED them, so /data's documented "grows on first boot"
# behaviour was actually coming from the fstab x-systemd.growfs option all along.
#
# The final case drives the PINNED mkosi over every config and requires zero
# diagnostic output, which is the only leg that would catch a NEW deprecation.
# It skips when the pinned mkosi is not on PATH (the canonical build is
# containerized, so a bats runner legitimately may not have it) — the static
# cases above still run, and each of them is individually non-vacuous.
#
# Run:  run-tests   (CI entrypoint)   or   bats tests/mkosi-contract.bats

bats_require_minimum_version 1.5.0

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PIPELINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  MKOSI_DIR="$PIPELINE_DIR/mkosi"
  REPART_DIR="$MKOSI_DIR/repart"
  SANDBOX_APT="$MKOSI_DIR/mkosi.sandbox/etc/apt/apt.conf.d"
  VERSION_PIN="$(tr -d '[:space:]' <"$PIPELINE_DIR/.mkosi-version")"
}

# Every tracked mkosi.conf, newline separated. `git ls-files` rather than a glob
# so an untracked scratch copy under mkosi/ can never be asserted on (or, worse,
# satisfy an assertion the tracked tree does not).
all_mkosi_configs() {
  git -C "$PIPELINE_DIR" ls-files 'mkosi/**/mkosi.conf' 'mkosi/mkosi.conf' 'mkosi/mkosi.profiles/*.conf'
}

# Emit "<file>:<section>:<key>" for every key=value line in a systemd-style
# config, so a test can assert WHICH section a setting lives in.
sectioned_keys() {
  local file="$1"
  awk -v f="$file" '
    /^[[:space:]]*[#;]/ { next }
    /^\[.*\]$/          { section = $0; next }
    /^[A-Za-z][A-Za-z0-9]*=/ {
      split($0, kv, "=")
      printf "%s:%s:%s\n", f, section, kv[1]
    }
  ' "$file"
}

@test "mkosi-contract: the config surface under guard exists" {
  [ -d "$MKOSI_DIR" ]
  [ -d "$REPART_DIR" ]
  [ -n "$VERSION_PIN" ]
  run all_mkosi_configs
  [ "$status" -eq 0 ]
  # base, platform, runtime, app, disk, plus the top-level orchestrator and the
  # amd64 profile. A shrinking set would make the absence guards below vacuous.
  [ "$(printf '%s\n' "$output" | grep -c 'mkosi.conf$\|amd64.conf$')" -ge 7 ]
}

@test "mkosi-contract: no mkosi.conf uses the deprecated singular FinalizeScript=" {
  local f hits=""
  while read -r f; do
    if grep -Eq '^FinalizeScript=' "$PIPELINE_DIR/$f"; then
      hits+="$f "
    fi
  done < <(all_mkosi_configs)
  [ -z "$hits" ] || {
    echo "deprecated FinalizeScript= (use FinalizeScripts=) in: $hits" >&2
    return 1
  }
}

@test "mkosi-contract: base and platform declare FinalizeScripts=mkosi.finalize" {
  grep -Fxq 'FinalizeScripts=mkosi.finalize' "$MKOSI_DIR/mkosi.images/base/mkosi.conf"
  grep -Fxq 'FinalizeScripts=mkosi.finalize' "$MKOSI_DIR/mkosi.images/platform/mkosi.conf"
  [ -x "$MKOSI_DIR/mkosi.images/base/mkosi.finalize" ] || [ -f "$MKOSI_DIR/mkosi.images/base/mkosi.finalize" ]
  [ -f "$MKOSI_DIR/mkosi.images/platform/mkosi.finalize" ]
}

@test "mkosi-contract: RepartDirectories is declared in [Output], never [Content]" {
  local f found=0
  while read -r f; do
    while IFS= read -r entry; do
      case "$entry" in
        *:'[Content]':RepartDirectories)
          echo "RepartDirectories must move to [Output]: $entry" >&2
          return 1
          ;;
        *:'[Output]':RepartDirectories) found=1 ;;
      esac
    done < <(sectioned_keys "$PIPELINE_DIR/$f")
  done < <(all_mkosi_configs)
  [ "$found" -eq 1 ]
}

@test "mkosi-contract: no mkosi.conf carries a GrowFileSystem= key" {
  local f hits=""
  while read -r f; do
    if grep -Eq '^GrowFileSystem=' "$PIPELINE_DIR/$f"; then
      hits+="$f "
    fi
  done < <(all_mkosi_configs)
  [ -z "$hits" ] || {
    echo "GrowFileSystem= belongs in a repart partition file, not a mkosi.conf: $hits" >&2
    return 1
  }
}

@test "mkosi-contract: no linux-generic repart partition sets GrowFileSystem=" {
  local f offenders=""
  for f in "$REPART_DIR"/*.conf "$MKOSI_DIR"/platform/x86/*.conf; do
    [ -f "$f" ] || continue
    grep -Eq '^Type=linux-generic$' "$f" || continue
    if grep -Eq '^GrowFileSystem=' "$f"; then
      offenders+="$(basename "$f") "
    fi
  done
  [ -z "$offenders" ] || {
    echo "systemd-repart ignores GrowFileSystem= on Type=linux-generic: $offenders" >&2
    return 1
  }
}

@test "mkosi-contract: the three formerly-warning partitions are still linux-generic" {
  # Non-vacuity for the case above: if these ever stopped being linux-generic the
  # absence assertion would pass for the wrong reason.
  grep -Fxq 'Type=linux-generic' "$REPART_DIR/20-rootfs_a.conf"
  grep -Fxq 'Type=linux-generic' "$REPART_DIR/30-rootfs_b.conf"
  grep -Fxq 'Type=linux-generic' "$REPART_DIR/40-data.conf"
}

@test "mkosi-contract: /data still grows on first boot via x-systemd.growfs" {
  # Removing GrowFileSystem= from 40-data.conf is only safe because repart never
  # honoured it there. This is the mechanism that actually does the growing.
  grep -Fq 'x-systemd.growfs' "$MKOSI_DIR/customize/postinst.d/persistence.sh"
}

@test "mkosi-contract: the boot ESP keeps GrowFileSystem= (its type supports it)" {
  # xbootldr/esp DO carry the growfs capability, so those keys are honoured and
  # must not be swept up by the linux-generic cleanup.
  grep -Fxq 'Type=xbootldr' "$REPART_DIR/10-boot.conf"
  grep -Eq '^GrowFileSystem=' "$REPART_DIR/10-boot.conf"
}

@test "mkosi-contract: the build sandbox disables apt translation probes" {
  local conf="$SANDBOX_APT/02-ceralive-no-translations"
  [ -f "$conf" ]
  grep -Fq 'Acquire::Languages "none";' "$conf"
}

@test "mkosi-contract: the translation setting is BUILD-only, not device apt config" {
  # E4 guardrail: the device's runtime apt configuration is written by the runtime
  # postinst and must not inherit a build-sandbox acquire policy.
  run grep -rn 'Acquire::Languages' "$MKOSI_DIR/mkosi.images" "$MKOSI_DIR/customize"
  [ "$status" -ne 0 ]
}

@test "mkosi-contract: the pinned mkosi parses every config with no diagnostics" {
  command -v mkosi >/dev/null 2>&1 || skip "mkosi not on PATH (canonical build is containerized)"
  local have
  have="$(mkosi --version 2>/dev/null | awk '{print $NF}')"
  [ "$have" = "$VERSION_PIN" ] || skip "host mkosi $have != pinned $VERSION_PIN"

  local out="$BATS_TEST_TMPDIR/cat-config.out"
  local err="$BATS_TEST_TMPDIR/cat-config.err"
  run env -u BOARD_ID bash -c \
    "cd '$MKOSI_DIR' && mkosi --architecture=arm64 cat-config >'$out' 2>'$err'"
  [ "$status" -eq 0 ]

  # Non-vacuity: the parse must actually have produced the sub-image chain. An
  # empty dump would make the grep below pass for the wrong reason.
  grep -q '### IMAGE: base' "$out"
  grep -q '### IMAGE: app' "$out"

  # mkosi prints deprecation and section-placement notices to stderr, prefixed
  # with its own '‣' marker, and exits 0 anyway — so the exit status alone proves
  # nothing. This is the leg that catches a NEW deprecation at the next bump.
  # It also covers `disk`, which is outside the default Dependencies=app chain:
  # mkosi validates every mkosi.images/ config even when it does not build it.
  run grep -nE 'deprecat|should be configured in' "$err"
  [ "$status" -ne 0 ]
}
