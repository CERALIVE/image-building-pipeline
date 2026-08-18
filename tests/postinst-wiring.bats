#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# postinst-wiring.bats — postinst wiring contracts — the dual-track drift gate, the
# first-boot captive portal, PASETO device-token provisioning and key encodings,
# avahi restart hardening, service boot ordering, and the ModemManager closure
# with its fail-closed modem_ports udev generator.
#
# Split out of the former tests/manifest.bats with the cases moved VERBATIM;
# the shared setup and every fixture helper live in manifest-helpers.bash.
#
# Run:  run-tests              (CI entrypoint)
#   or: bats tests/postinst-wiring.bats

load manifest-helpers

# ===========================================================================
# 8. postinst dual-track drift gate (Task 6) — the consolidated runtime-config
#    logic lives ONCE in customize/postinst-lib.sh, sourced by both the runtime
#    executor (mkosi.postinst.chroot) and the customize modules. The gate fails if
#    that single-source property breaks (a function re-inlined, a track no longer
#    sourcing the lib, the §6 SRTLA payloads diverging, or postinst regrowing past
#    its ceiling). Pure static analysis — no chroot/build — so it fits this suite.
# ===========================================================================

@test "postinst drift: clean tree has no dual-track drift (single source of truth)" {
  serialize working-tree   # never read the tree while a sibling test mutates it
  run bash "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: no drift"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "postinst drift: gate CATCHES a re-inlined consolidated function (non-vacuity)" {
  serialize working-tree   # mutates a tracked file then restores; exclusive
  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  local backup="$BATS_TEST_TMPDIR/postinst.bak"
  cp "$postinst" "$backup"
  # Re-introduce the exact dual-track hazard the consolidation removed: an inline
  # twin of a consolidated function in the runtime executor.
  printf '\nsetup_data_persistence() { log "re-inlined twin (drift)"; }\n' >> "$postinst"
  run bash "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  cp "$backup" "$postinst"          # ALWAYS restore, pass or fail
  [ "$status" -ne 0 ]
  [[ "$output" == *"RE-INLINED"* ]]
  [[ "$output" == *"setup_data_persistence"* ]]
}

@test "postinst drift: retired SRTLA source-policy routing is absent" {
  run bash "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"90-srtla-wifi-routing: absent"* ]]
  [[ "$output" == *"srtla-source-routing: absent"* ]]
  [[ "$output" == *"configure_srtla_routing: absent"* ]]
}

@test "postinst drift: gate CATCHES a resurrected SRTLA dispatcher (non-vacuity)" {
  serialize working-tree   # plants a file under mkosi/ then removes it; exclusive
  local planted="$PIPELINE_DIR/mkosi/customize/.todo38-residue-probe.sh"
  printf '#!/bin/sh\n# 90-srtla-wifi-routing\n' >"$planted"
  run bash "$PIPELINE_DIR/ci/postinst-drift-check.sh"
  rm -f "$planted"                  # ALWAYS remove, pass or fail
  [ "$status" -ne 0 ]
  [[ "$output" == *"RESURRECTED"* ]]
}

# ===========================================================================
# 8b. First-boot WiFi provisioning captive portal (Task 14).
#     The offline proof harness stubs nmcli/ip/systemctl/systemd-run and drives the
#     real ceralive-provision.sh + ceralive-portal.sh through bring-up, the GET/POST
#     captive page, the credential handoff, and the four-condition MAC6 teardown
#     (incl. wrong-passphrase retry + hard-timeout return-to-AP). No radio/systemd
#     needed, so it fits this static suite.
# ===========================================================================

@test "provision portal: offline harness proves the 4-condition teardown + handoff" {
  run bash "$TESTS_DIR/provision-portal.test.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS"* ]]
  # The fail() marker is "  FAIL  " (two-space framed); match that, not the word
  # "FAILURE" that legitimately appears in a scenario header.
  [[ "$output" != *"  FAIL  "* ]]
}

# ===========================================================================
# 18. PASETO device-token PUBLIC key provisioning (ADR-0006 D2 / Phase-A Task 3).
#     postinst-lib.sh::setup_paseto_public_key decodes the base64-forwarded
#     $PASETO_PUBLIC_KEY_B64 and bakes it into the CeraUI backend runtime env as an
#     ADDITIVE ceralive.service drop-in (Environment=PASETO_PUBLIC_KEY=...). CeraUI
#     reads PASETO_PUBLIC_KEY at startup (apps/backend device-token.ts
#     DEVICE_TOKEN_PUBLIC_KEY_ENV) — its PRESENCE gates real Ed25519 verification.
#     Provisioning is PUBLIC ONLY: a k4.secret / PEM private key FAILS the build and
#     no private material may appear in the baked artifact. These tests drive the
#     SHIPPED function (sourced from postinst-lib.sh) against a temp drop-in dir
#     (PASETO_DROPIN_DIR) — no image boot, UNIT scope; the offline DRY_RUN proof.
# ===========================================================================

@test "paseto provision: a PUBLIC key is baked into the ceralive.service env drop-in" {
  run_paseto_provision "$PASETO_RAW_PUB"
  [ "$status" -eq 0 ]
  [ -f "$PASETO_DROPIN" ]
  grep -q '^\[Service\]' "$PASETO_DROPIN"
  grep -q "^Environment=PASETO_PUBLIC_KEY=$PASETO_RAW_PUB\$" "$PASETO_DROPIN"
}

@test "paseto provision: NO private material in the baked drop-in (no k4.secret / PRIVATE KEY)" {
  run_paseto_provision "$PASETO_RAW_PUB"
  [ "$status" -eq 0 ]
  run grep -aq 'k4.secret' "$PASETO_DROPIN"
  [ "$status" -ne 0 ]
  run grep -aq 'PRIVATE KEY' "$PASETO_DROPIN"
  [ "$status" -ne 0 ]
}

@test "paseto provision: a k4.secret PRIVATE key is REFUSED (build fails, no drop-in)" {
  run_paseto_provision "k4.secret.ZZZZ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"k4.secret"* ]]
  [ ! -f "$PASETO_DROPIN" ]
}

@test "paseto provision: PEM PRIVATE KEY material is REFUSED (build fails, no drop-in)" {
  run_paseto_provision "-----BEGIN PRIVATE KEY-----"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PRIVATE KEY"* ]]
  [ ! -f "$PASETO_DROPIN" ]
}

@test "paseto provision: no key in env SKIPS provisioning (CeraUI MVP opaque-token path)" {
  run_paseto_provision ""
  [ "$status" -eq 0 ]
  [ ! -f "$PASETO_DROPIN" ]
  [[ "$output" == *"MVP opaque-token path"* ]]
}

@test "paseto provision: image contract uses the canonical public-key environment name" {
  grep -q 'PASETO_PUBLIC_KEY' "$REPO_ROOT/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
}

# ===========================================================================
# 18b. avahi-daemon restart hardening (defense-in-depth mDNS reliability) —
#      stock Debian's avahi-daemon.service ships NO Restart= directive, so ANY
#      signal/crash leaves mDNS (<hostname>.local) dead until reboot. Confirmed
#      live on real hardware: killed by SIGUSR2 (status=12/USR2), NRestarts=0.
#      setup_avahi_restart (postinst-lib.sh) bakes an ADDITIVE drop-in installed
#      from the committed standalone artifact under CERALIVE_RUNTIME_SRC (like the
#      TLS nginx drop-in). These drive the SHIPPED function against a temp drop-in
#      dir (AVAHI_DROPIN_DIR) — no image boot, UNIT scope.
# ===========================================================================

@test "avahi restart: an additive Restart=on-failure drop-in is baked for avahi-daemon.service" {
  local dir="$BATS_TEST_TMPDIR/avahi-daemon.service.d"
  rm -rf "$dir"
  run env CERALIVE_RUNTIME_SRC="$PIPELINE_DIR/mkosi/runtime" AVAHI_DROPIN_DIR="$dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_avahi_restart"
  [ "$status" -eq 0 ]
  [ -f "$dir/10-ceralive-restart.conf" ]
  grep -q '^\[Service\]' "$dir/10-ceralive-restart.conf"
  grep -q '^Restart=on-failure$' "$dir/10-ceralive-restart.conf"
  grep -q '^RestartSec=2$' "$dir/10-ceralive-restart.conf"
}

@test "avahi restart: missing runtime source FAILS the build (fail-closed, no drop-in)" {
  local dir="$BATS_TEST_TMPDIR/avahi-fail.d"
  rm -rf "$dir"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/empty-src" AVAHI_DROPIN_DIR="$dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_avahi_restart"
  [ "$status" -ne 0 ]
  [[ "$output" == *"avahi-restart source not found"* ]]
  [ ! -f "$dir/10-ceralive-restart.conf" ]
}

@test "avahi restart: image contract wires setup_avahi_restart into the runtime executor" {
  grep -q 'setup_avahi_restart' "$REPO_ROOT/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
}

# ===========================================================================
# 18c. ceralive.service -> cerastream.service boot ordering — ceralive.service's
#      initPipelines() connects to cerastream's control socket exactly once, so a
#      cerastream that starts LATE (confirmed live: ~2 min after ceralive.service)
#      permanently fails that boot's connect. setup_cerastream_ordering
#      (postinst-lib.sh) bakes an ADDITIVE After=cerastream.service drop-in from the
#      committed standalone artifact under CERALIVE_RUNTIME_SRC (like the avahi/TLS
#      drop-ins). ORDERING-ONLY: it must NEVER carry Requires= — ceralive.service has
#      to boot into its "engine unavailable" degraded state if cerastream is
#      absent/masked. These drive the SHIPPED function against a temp drop-in dir
#      (CERASTREAM_ORDERING_DROPIN_DIR) — no image boot, UNIT scope.
# ===========================================================================

@test "cerastream ordering: an additive After=cerastream.service drop-in is baked for ceralive.service" {
  local dir="$BATS_TEST_TMPDIR/ceralive.service.d"
  rm -rf "$dir"
  run env CERALIVE_RUNTIME_SRC="$PIPELINE_DIR/mkosi/runtime" CERASTREAM_ORDERING_DROPIN_DIR="$dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_cerastream_ordering"
  [ "$status" -eq 0 ]
  [ -f "$dir/30-cerastream-ordering.conf" ]
  grep -q '^\[Unit\]' "$dir/30-cerastream-ordering.conf"
  grep -q '^After=cerastream.service$' "$dir/30-cerastream-ordering.conf"
}

@test "cerastream ordering: the drop-in is ordering-ONLY (no Requires=/Requisite=/BindsTo= hard dependency)" {
  # ceralive.service MUST still boot and serve its "engine unavailable" degraded
  # state (CeraUI helpers/boot-guard.ts::guardNonCritical) if cerastream is ever
  # genuinely absent or masked. A hard dependency (Requires=/Requisite=/BindsTo=)
  # would break that fail-soft design — this asserts the drop-in never introduces one.
  local dir="$BATS_TEST_TMPDIR/ceralive-ordering-only.d"
  rm -rf "$dir"
  run env CERALIVE_RUNTIME_SRC="$PIPELINE_DIR/mkosi/runtime" CERASTREAM_ORDERING_DROPIN_DIR="$dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_cerastream_ordering"
  [ "$status" -eq 0 ]
  run grep -Eq '^(Requires|Requisite|BindsTo|Wants)=cerastream\.service' "$dir/30-cerastream-ordering.conf"
  [ "$status" -ne 0 ]
  # Same guard against the committed source artifact so a future edit can't smuggle
  # a hard dependency in past the runtime-src indirection.
  run grep -Eq '^(Requires|Requisite|BindsTo|Wants)=cerastream\.service' \
    "$PIPELINE_DIR/mkosi/runtime/ceralive-cerastream-ordering.dropin.conf"
  [ "$status" -ne 0 ]
}

@test "cerastream ordering: missing runtime source FAILS the build (fail-closed, no drop-in)" {
  local dir="$BATS_TEST_TMPDIR/ceralive-ordering-fail.d"
  rm -rf "$dir"
  run env CERALIVE_RUNTIME_SRC="$BATS_TEST_TMPDIR/empty-src" CERASTREAM_ORDERING_DROPIN_DIR="$dir" \
    bash -c "source '$POSTINST_ENTRY'; setup_cerastream_ordering"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cerastream-ordering source not found"* ]]
  [ ! -f "$dir/30-cerastream-ordering.conf" ]
}

@test "cerastream ordering: image contract wires setup_cerastream_ordering into the runtime executor" {
  grep -q 'setup_cerastream_ordering' "$REPO_ROOT/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
}

# ===========================================================================
# 21. PASETO key-encoding cross-check (Task 19 / ADR-0006 D2) — the provisioning
#     verifier verify-paseto-key-encodings.sh proves the platform PASERK
#     k4.public and the device raw-base64 are the SAME 32-byte Ed25519 public
#     key, AND that the shipped setup_paseto_public_key bakes the build input
#     (PASETO_PUBLIC_KEY_B64) into Environment=PASETO_PUBLIC_KEY with zero drift,
#     AND that a k4.secret is refused. --self-test mints an EPHEMERAL keypair, so
#     the check is self-contained (no cert-work, no secrets) and CI-safe. Runbook:
#     docs/paseto-key-provisioning.md.
# ===========================================================================

@test "paseto verify: --self-test proves k4.public == raw-base64 and a clean build-bake (ephemeral keypair)" {
  run "$VERIFY_PASETO" --self-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"byte-equal 32-byte public keys"* ]]
  [[ "$output" == *"round-trips to the same 32-byte public key"* ]]
  [[ "$output" == *"k4.secret fed as the build input is REFUSED"* ]]
  [[ "$output" == *"self-test OK"* ]]
}

@test "paseto verify: a mismatched k4.public / raw-base64 pair is caught (fail loud)" {
  # Two DIFFERENT Ed25519 keys' encodings must not validate as a pair. Minted
  # inline with openssl so the fixture is self-contained (no cert-work, Rule D).
  local d="$BATS_TEST_TMPDIR/paseto-mismatch"
  mkdir -p "$d/mix"
  openssl genpkey -algorithm ed25519 -out "$d/a.pem" 2>/dev/null
  openssl genpkey -algorithm ed25519 -out "$d/b.pem" 2>/dev/null
  # k4.public from keypair A (base64url-nopad), raw-base64 from keypair B (standard).
  local a_url b_std
  a_url="$(openssl pkey -in "$d/a.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  b_std="$(openssl pkey -in "$d/b.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A)"
  printf 'k4.public.%s\n' "$a_url" > "$d/mix/paseto.k4.public"
  printf '%s\n' "$b_std" > "$d/mix/paseto.public.raw.b64"
  run "$VERIFY_PASETO" --key-dir "$d/mix"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISMATCH"* ]]
}

# ===========================================================================
# 23. ModemManager 1.24 closure image integration + fail-closed modem_ports udev.
#     The nine-package modem-stack fork (modemmanager + libmm-glib0 +
#     libmbim/libqmi/libqrtr) plus its Architecture: all support companion are
#     staged first-party (FIRST_PARTY_APT_PKGS), exact-pinned in
#     first-party-deb-versions.txt, classified RUNTIME_APP_PKGS by the app postinst,
#     and covered by the Package:* origin-990 pin. The board
#     modem_ports block drives a FAIL-CLOSED udev generator: unverified ⇒ zero
#     generated slot-uid rules, verified fixture ⇒ rules emitted. All static /
#     sourced-function checks — UNIT scope, no image.
# ===========================================================================

@test "modem closure: all nine packages are in FIRST_PARTY_APT_PKGS" {
  local staged pkg
  staged="$(bash -c 'source "$1"; printf "%s\n" "${FIRST_PARTY_APT_PKGS[@]}"' bash "$FETCH_DEBS")"
  for pkg in $MODEM_CLOSURE_PKGS; do
    grep -Fxq "$pkg" <<<"$staged" || { echo "missing from FIRST_PARTY_APT_PKGS: $pkg"; false; }
  done
  # The set is five core packages + nine closure packages + one support companion.
  [ "$(bash -c 'source "$1"; printf "%s" "${#FIRST_PARTY_APT_PKGS[@]}"' bash "$FETCH_DEBS")" -eq 15 ]
}

@test "modem support companion: is staged once at its exact Architecture-all version" {
  local staged pins arch_all_ok
  staged="$(bash -c 'source "$1"; printf "%s\n" "${FIRST_PARTY_APT_PKGS[@]}"' bash "$FETCH_DEBS")"
  [ "$(grep -Fxc 'ceralive-modem-support' <<<"$staged")" -eq 1 ]
  pins="$PIPELINE_DIR/manifests/first-party-deb-versions.txt"
  [ "$(awk -F= '$1=="ceralive-modem-support"{print $2}' "$pins")" = "1.3.0" ]
  arch_all_ok="$(bash -c 'source "$1"; printf "%s\n" "${FIRST_PARTY_ARCH_ALL_OK_PKGS[@]}"' bash "$PIPELINE_DIR/lib/fetch/firstparty.sh")"
  [ "$arch_all_ok" = "ceralive-modem-support" ]
}

@test "modem closure: each package has an exact live-verified Version pin in the txt" {
  local pins="$PIPELINE_DIR/manifests/first-party-deb-versions.txt"
  local pkg version
  for pkg in $MODEM_CLOSURE_PKGS; do
    version="$(awk -F= -v p="$pkg" '$1==p{print $2; exit}' "$pins")"
    [ -n "$version" ] || { echo "no pin for $pkg"; false; }
    # every closure pin carries the ~ceralive0.2.0 fork suffix (published live)
    [[ "$version" == *"~ceralive0.2.0" ]] || { echo "$pkg pin lacks ~ceralive0.2.0: $version"; false; }
  done
  # spot-check the two anchor versions confirmed live on apt.ceralive.tv
  [ "$(awk -F= '$1=="modemmanager"{print $2}' "$pins")" = "1.24.2-2~ceralive0.2.0" ]
  [ "$(awk -F= '$1=="libqrtr-glib0"{print $2}' "$pins")" = "1.4.0-1~ceralive0.2.0" ]
}

@test "modem closure: the app postinst classifies all nine as RUNTIME_APP_PKGS (never sysext/appfs)" {
  local app="$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  local runtime_line sysext_line appfs_line pkg
  # RUNTIME_APP_PKGS spans a line continuation; collapse the assignment to one line.
  runtime_line="$(awk '/^RUNTIME_APP_PKGS=/{f=1} f{printf "%s ", $0} f&&!/\\$/{exit}' "$app")"
  sysext_line="$(grep -E '^SYSEXT_APP_PKGS=' "$app")"
  appfs_line="$(grep -E '^APPFS_APP_PKGS=' "$app")"
  for pkg in $MODEM_CLOSURE_PKGS; do
    [[ "$runtime_line" == *" $pkg"* || "$runtime_line" == *"\"$pkg"* ]] \
      || { echo "$pkg not in RUNTIME_APP_PKGS"; false; }
    [[ "$sysext_line" != *"$pkg"* ]] || { echo "$pkg leaked into SYSEXT_APP_PKGS"; false; }
    [[ "$appfs_line" != *"$pkg"* ]] || { echo "$pkg leaked into APPFS_APP_PKGS"; false; }
  done
}

@test "modem support companion: is classified RUNTIME_APP_PKGS and has no image-owned udev basename collision" {
  local app="$PIPELINE_DIR/mkosi/mkosi.images/app/mkosi.postinst.chroot"
  local runtime_line sysext_line appfs_line companion_rule image_rules
  runtime_line="$(awk '/^RUNTIME_APP_PKGS=/{f=1} f{printf "%s ", $0} f&&!/\\$/{exit}' "$app")"
  sysext_line="$(grep -E '^SYSEXT_APP_PKGS=' "$app")"
  appfs_line="$(grep -E '^APPFS_APP_PKGS=' "$app")"
  [[ "$runtime_line" == *" ceralive-modem-support"* || "$runtime_line" == *'"ceralive-modem-support'* ]]
  [[ "$sysext_line" != *"ceralive-modem-support"* ]]
  [[ "$appfs_line" != *"ceralive-modem-support"* ]]

  companion_rule="60-ceralive-modem.rules"
  image_rules="99-ceralive-hardware.rules 78-mm-ceralive-slot-uid.rules"
  for rule in $image_rules; do
    [ "$companion_rule" != "$rule" ] || { echo "udev basename collision: $companion_rule"; false; }
  done
}

@test "modem closure: mobile-broadband-provider-info is in shared.list (Recommends not auto-pulled)" {
  run grep -Ex 'mobile-broadband-provider-info[[:space:]]*(#.*)?' "$PIPELINE_DIR/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "modem closure: the Package:* origin-990 pin covers the closure (wildcard, not per-package)" {
  # The closure debs are served from the apt.ceralive.tv origin. The pin is
  # `Package: *` at Pin-Priority 990, so it covers EVERY package that origin
  # carries — including all nine — with no per-package enumeration needed.
  local dir="$BATS_TEST_TMPDIR/modem-prefs/preferences.d"
  run env APT_CERALIVE_REPO_NO_AUTORUN=1 APT_PREFERENCES_DIR="$dir" \
    bash -c "source '$APT_CERALIVE_REPO'; install_apt_preferences"
  [ "$status" -eq 0 ]
  grep -qxF 'Package: *' "$dir/ceralive"
  grep -qxF 'Pin: origin apt.ceralive.tv' "$dir/ceralive"
  grep -qxF 'Pin-Priority: 990' "$dir/ceralive"
}

@test "modem closure: DRY_RUN fetch_first_party resolves every closure package" {
  local debs="$BATS_TEST_TMPDIR/modem-debs"
  mkdir -p "$debs"
  run bash -c "{ export DRY_RUN=1 VERSIONS_YAML='$VERSIONS_YAML'; source '$FETCH_DEBS'; fetch_first_party '$debs'; } 2>&1"
  [ "$status" -eq 0 ]
  local pkg
  for pkg in $MODEM_CLOSURE_PKGS; do
    [[ "$output" == *"$pkg"* ]] || { echo "DRY_RUN plan missing $pkg"; false; }
  done
  [[ "$output" == *"ceralive-modem-support=1.3.0"* ]] \
    || { echo "DRY_RUN plan missing ceralive-modem-support=1.3.0"; false; }
  # plan-only: nothing staged
  run bash -c "shopt -s nullglob; f=('$debs'/*.deb); echo \${#f[@]}"
  [ "$output" -eq 0 ]
}

@test "modem closure: executable app-layer install test passes (classification + install)" {
  run bash "$TESTS_DIR/app-layer-modem-closure.test.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS positive"* ]]
  [[ "$output" == *"PASS negative"* ]]
  [[ "$output" == *"regression: PASS"* ]]
  printf '%s\n' "$output"
}

@test "modem_ports schema: rock-5b-plus ships status: unverified and validates" {
  run validate_manifest "$PIPELINE_DIR/manifests/boards/rock-5b-plus.yaml" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
  run python3 -c "import yaml; d=yaml.safe_load(open('$PIPELINE_DIR/manifests/boards/rock-5b-plus.yaml')); print(d['modem_ports']['status'])"
  [ "$status" -eq 0 ]
  [[ "$output" == "unverified" ]]
}

@test "modem_ports schema: a verified board with slot ID_PATHs validates" {
  local brd="$BATS_TEST_TMPDIR/verified-board.yaml"
  cat > "$brd" <<'YAML'
family: rk3588
board_id: modem-verified
dtb_name: none
description: verified modem slots fixture
modem_ports:
  status: verified
  slots:
    modem0: platform-fc000000.usb-usb-0:1:1.0
    modem1: platform-fc400000.usb-usb-0:1:1.0
YAML
  run validate_manifest "$brd" "$BOARD_SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VALID"* ]]
}

@test "modem_ports schema: an out-of-enum status is REJECTED and names modem_ports" {
  local brd="$BATS_TEST_TMPDIR/bad-status-board.yaml"
  cat > "$brd" <<'YAML'
family: rk3588
board_id: modem-bad
dtb_name: none
description: bad modem status fixture
modem_ports:
  status: maybe
YAML
  run validate_manifest "$brd" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"modem_ports"* ]]
}

@test "modem_ports schema: a slot key that is not modemN is REJECTED" {
  local brd="$BATS_TEST_TMPDIR/bad-slot-board.yaml"
  cat > "$brd" <<'YAML'
family: rk3588
board_id: modem-badslot
dtb_name: none
description: bad modem slot key fixture
modem_ports:
  status: verified
  slots:
    wlan0: platform-xyz
YAML
  run validate_manifest "$brd" "$BOARD_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"modem_ports"* ]]
}

@test "modem generator MATRIX: unverified fixture emits ZERO generated slot-uid rules (fail-closed)" {
  run_modem_generator unverified ""
  [ "$MODEM_GEN_STATUS" -eq 0 ]
  [ ! -f "$MODEM_GEN_RULES" ]
  grep -q "emitting NO generated slot-uid rules" "$BATS_TEST_TMPDIR/gen.out"
}

@test "modem generator MATRIX: an unset status is treated as unverified (no permissive fallback)" {
  local rules_dir="$BATS_TEST_TMPDIR/udev-unset"
  rm -rf "$rules_dir"; mkdir -p "$rules_dir"
  run env -u CERALIVE_MODEM_PORTS_STATUS -u CERALIVE_MODEM_PORTS_SLOTS \
      MODEM_SLOT_RULES_DIR="$rules_dir" \
      bash -c "source '$PIPELINE_DIR/lib/common.sh'; source '$PIPELINE_DIR/mkosi/customize/udev.sh' 2>/dev/null || true; generate_modem_slot_uid_rules"
  [ "$status" -eq 0 ]
  [ ! -f "$rules_dir/78-mm-ceralive-slot-uid.rules" ]
}

@test "modem generator MATRIX: a verified fixture EMITS one ID_MM_PHYSDEV_UID rule per slot" {
  run_modem_generator verified "modem0=platform-fc000000.usb-usb-0:1:1.0 modem1=platform-fc400000.usb-usb-0:1:1.0"
  [ "$MODEM_GEN_STATUS" -eq 0 ]
  [ -f "$MODEM_GEN_RULES" ]
  grep -q 'ENV{ID_PATH}=="platform-fc000000.usb-usb-0:1:1.0", ENV{ID_MM_PHYSDEV_UID}="modem0"' "$MODEM_GEN_RULES"
  grep -q 'ENV{ID_PATH}=="platform-fc400000.usb-usb-0:1:1.0", ENV{ID_MM_PHYSDEV_UID}="modem1"' "$MODEM_GEN_RULES"
  # exactly two emitted RULE lines (count ACTION== rules, not the header comment
  # line that also mentions ID_MM_PHYSDEV_UID)
  [ "$(grep -c '^ACTION==.*ID_MM_PHYSDEV_UID' "$MODEM_GEN_RULES")" -eq 2 ]
}

@test "modem generator MATRIX: a stale verified rule file is removed when status reverts to unverified" {
  local rules_dir="$BATS_TEST_TMPDIR/udev-revert"
  rm -rf "$rules_dir"; mkdir -p "$rules_dir"
  # seed a prior generated file, then run unverified — it must be cleaned up
  printf 'stale\n' > "$rules_dir/78-mm-ceralive-slot-uid.rules"
  run env CERALIVE_MODEM_PORTS_STATUS=unverified CERALIVE_MODEM_PORTS_SLOTS="" \
      MODEM_SLOT_RULES_DIR="$rules_dir" \
      bash -c "source '$PIPELINE_DIR/lib/common.sh'; source '$PIPELINE_DIR/mkosi/customize/udev.sh' 2>/dev/null || true; generate_modem_slot_uid_rules"
  [ "$status" -eq 0 ]
  [ ! -f "$rules_dir/78-mm-ceralive-slot-uid.rules" ]
}

@test "modem generator MATRIX: verified with NO slots FAILS closed (refuses an empty verified set)" {
  local rules_dir="$BATS_TEST_TMPDIR/udev-empty-verified"
  rm -rf "$rules_dir"; mkdir -p "$rules_dir"
  run env CERALIVE_MODEM_PORTS_STATUS=verified CERALIVE_MODEM_PORTS_SLOTS="" \
      MODEM_SLOT_RULES_DIR="$rules_dir" \
      bash -c "source '$PIPELINE_DIR/lib/common.sh'; source '$PIPELINE_DIR/mkosi/customize/udev.sh' 2>/dev/null || true; generate_modem_slot_uid_rules"
  [ "$status" -ne 0 ]
  [ ! -f "$rules_dir/78-mm-ceralive-slot-uid.rules" ]
}

@test "modem generator: the permanent generic modem rules (udev.sh 'USB Modem Devices') are untouched" {
  # The fail-closed generator must NOT remove or alter the always-shipped generic
  # dialout group-tag rules in setup_hardware_access.
  local udev="$PIPELINE_DIR/mkosi/customize/udev.sh"
  grep -Fq 'USB Modem Devices (4G/5G)' "$udev"
  grep -Fq 'KERNEL=="cdc-wdm[0-9]*", GROUP="dialout"' "$udev"
  grep -Fq 'ATTRS{idVendor}=="2c7c", GROUP="dialout"' "$udev"
  # and the generator is a SEPARATE function, invoked after setup_hardware_access
  grep -Fq 'generate_modem_slot_uid_rules "$@"' "$udev"
}

@test "hdmi-in: a driver-keyed SYMLINK rule gives the SoC HDMI-RX a stable /dev/hdmi-in node" {
  # The SoC HDMI-IN capture node must get a persistent, collision-proof name that
  # does not depend on its /dev/videoN enumeration index (a USB capture card can
  # grab video0 and renumber the HDMI-RX). The symlink rule keys on the stable
  # HDMI-RX DRIVER name, never on KERNEL=="video0" or the node's name attr.
  local udev="$PIPELINE_DIR/mkosi/customize/udev.sh"
  local rule
  rule="$(grep -F 'SYMLINK+="hdmi-in"' "$udev")"
  [ -n "$rule" ]
  # keyed on the driver name, not a fixed node index
  [[ "$rule" == *'DRIVERS=="rk_hdmirx|snps_hdmirx"'* ]]
  [[ "$rule" != *'ATTRS{name}=="rk_hdmirx"'* ]]
  [[ "$rule" != *'KERNEL=="video0"'* ]]
  # also provides /dev/hdmirx (cerastream's canonical default HDMI device string)
  [[ "$rule" == *'SYMLINK+="hdmirx"'* ]]
  # additive: the original name-matched HDMI permission rules are still present
  grep -Fq 'ATTRS{name}=="rk_hdmirx", GROUP="video", MODE="0664"' "$udev"
  grep -Fq 'ATTRS{name}=="*hdmi*", GROUP="video", MODE="0664"' "$udev"
}

@test "hdmi-in: the symlink rule is in the LIVE writer (runtime postinst), not only the customize module" {
  # `./build` runs mkosi.images/runtime/mkosi.postinst.chroot; run-all.sh's
  # RUNTIME modules (customize/udev.sh) are NOT executed by it — only
  # `run-all.sh base`. So a rule that exists ONLY in customize/udev.sh never
  # ships. That is exactly what happened: a live Rock 5B+ had neither
  # /dev/hdmi-in nor /dev/hdmirx, and its /etc/udev/rules.d/99-ceralive-hardware.rules
  # was the postinst twin with no symlink rule at all (board-confirmed 2026-08-02).
  local postinst="$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
  local rule
  rule="$(grep -F 'SYMLINK+="hdmi-in"' "$postinst")"
  [ -n "$rule" ]
  [[ "$rule" == *'DRIVERS=="rk_hdmirx|snps_hdmirx"'* ]]
  [[ "$rule" == *'SYMLINK+="hdmirx"'* ]]
  [[ "$rule" != *'KERNEL=="video0"'* ]]
}

@test "hdmi-in: BOTH kernel tracks' driver names are matched (rk_hdmirx AND snps_hdmirx)" {
  # The vendor BSP ships an out-of-tree driver named rk_hdmirx; mainline (the
  # `edge` variant) ships the upstream Synopsys driver, whose platform driver
  # name is snps_hdmirx. Board-confirmed on 7.1.5:
  #   readlink /sys/devices/platform/fdee0000.hdmi_receiver/driver
  #     -> /sys/bus/platform/drivers/snps_hdmirx
  # An rk_hdmirx-only rule therefore produces NO symlink on an edge image.
  local f
  for f in "$PIPELINE_DIR/mkosi/customize/udev.sh" \
           "$PIPELINE_DIR/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"; do
    local rule
    rule="$(grep -F 'SYMLINK+="hdmi-in"' "$f")"
    [[ "$rule" == *rk_hdmirx* ]]
    [[ "$rule" == *snps_hdmirx* ]]
  done
}

@test "runtime packages: bluez is installed so the Bluetooth adapter is usable" {
  # The kernel half already works: on a Rock 5B+ the RTL8852BE's Bluetooth radio
  # enumerates as USB 13d3:3572, btusb+btrtl bind it, and /sys/class/bluetooth/hci0
  # exists. Without bluez there is no bluetoothd, no bluetooth.service and no
  # bluetoothctl, so the adapter can never be powered up or paired. libbluetooth3
  # ships only as an unrelated transitive dependency and provides no daemon.
  run grep -Ex 'bluez[[:space:]]*(#.*)?' "$PIPELINE_DIR/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}

@test "modem_ports wiring: CERALIVE_MODEM_PORTS_* is forwarded env_names -> PassEnvironment lockstep" {
  # Mirrors the interface-naming lockstep guard: the status/slots vars must be in
  # BOTH orchestrate.sh env_names AND mkosi.conf PassEnvironment, or they read
  # EMPTY in the runtime subimage chroot (the generator would then see no status).
  local orchestrate="$LIB_DIR/orchestrate.sh"
  local mkosi_conf="$PIPELINE_DIR/mkosi/mkosi.conf"
  local var
  for var in CERALIVE_MODEM_PORTS_STATUS CERALIVE_MODEM_PORTS_SLOTS; do
    grep -Fq "$var" "$orchestrate" || { echo "$var missing from orchestrate.sh"; false; }
    grep -Eq "^PassEnvironment=.*$var" "$mkosi_conf" || { echo "$var missing from PassEnvironment"; false; }
  done
}
