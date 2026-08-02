#!/usr/bin/env bats
#
# Kconfig-fragment survival — the contract that says what `rk3588-edge.fragment`
# ASKS FOR is what the built kernel actually CARRIES.
#
# WHY THIS FILE EXISTS. A real Rock 5B+ running the `edge` 7.1.5 kernel had its
# RTL8852BE WiFi enumerate at PCI level (vendor 0x10ec, device 0xb852, class
# 0x028000) with NO driver bound, no `wl*` interface, and `rtw89*` absent from
# `lsmod` — while `/lib/firmware/rtw89/rtw8852b_fw.bin` was present and
# `cfg80211` was loaded. `/proc/config.gz` on that board read
# `# CONFIG_RTW89 is not set`.
#
# The fragment DID name the adapter (`CONFIG_RTW89_8852BE=m`). It sits inside
# `if RTW89` under a `menuconfig RTW89` that is tristate and defaults off, so
# `make olddefconfig` discarded the leaf. Nothing warned:
# `scripts/kconfig/merge_config.sh -m` merges text and reports only REDEFINED
# values — its own post-merge validation pass is exactly what `-m` skips — so
# the build log, the four-axis .deb validation, the boot, and the image all
# stayed green with the driver simply absent.
#
# The same sweep caught a second, quieter instance: `CONFIG_TYPEC_FUSB302=y`
# resolved to `=m`, because FUSB302 carries `depends on DRM || DRM=n` and arm64
# defconfig builds DRM as a module.
#
# Hardware-free and root-free: the verifier is pure text over two files.

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  V2="$(cd "$TESTS_DIR/.." && pwd)"
  VERIFY="$V2/lib/verify-kernel-config.sh"
  FRAGMENT="$V2/manifests/kernel/rk3588-edge.fragment"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK"
}

# --- the verifier itself ----------------------------------------------------

@test "verify-kernel-config: a fragment fully honoured by the resolved config passes" {
  cat >"$WORK/frag" <<'EOF'
# a comment
CONFIG_A=y
CONFIG_B=m
CONFIG_C="a string"
CONFIG_D=n
# CONFIG_E is not set
EOF
  cat >"$WORK/resolved" <<'EOF'
CONFIG_A=y
CONFIG_B=m
CONFIG_C="a string"
# CONFIG_D is not set
# CONFIG_E is not set
EOF
  run "$VERIFY" "$WORK/frag" "$WORK/resolved"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all 5 fragment symbol(s) survived"* ]]
}

@test "verify-kernel-config: a symbol dropped entirely fails and names it" {
  printf 'CONFIG_KEPT=y\nCONFIG_GONE=m\n' >"$WORK/frag"
  printf 'CONFIG_KEPT=y\n' >"$WORK/resolved"
  run "$VERIFY" "$WORK/frag" "$WORK/resolved"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_GONE: DROPPED"* ]]
  [[ "$output" == *"does not carry the symbol at all"* ]]
  [[ "$output" != *"CONFIG_KEPT"* ]]
}

@test "verify-kernel-config: a symbol turned off by olddefconfig fails" {
  printf 'CONFIG_WANTED=m\n' >"$WORK/frag"
  printf '# CONFIG_WANTED is not set\n' >"$WORK/resolved"
  run "$VERIFY" "$WORK/frag" "$WORK/resolved"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_WANTED: DROPPED"* ]]
  [[ "$output" == *"is not set"* ]]
}

@test "verify-kernel-config: a =y downgraded to =m fails (built-in vs module is a real difference)" {
  printf 'CONFIG_THING=y\n' >"$WORK/frag"
  printf 'CONFIG_THING=m\n' >"$WORK/resolved"
  run "$VERIFY" "$WORK/frag" "$WORK/resolved"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fragment asks for CONFIG_THING=y, resolved config has CONFIG_THING=m"* ]]
}

@test "verify-kernel-config: an OFF request is satisfied by absence as well as by an explicit not-set" {
  printf 'CONFIG_OFF_A=n\n# CONFIG_OFF_B is not set\n' >"$WORK/frag"
  : >"$WORK/resolved"
  run "$VERIFY" "$WORK/frag" "$WORK/resolved"
  [ "$status" -eq 0 ]
}

@test "verify-kernel-config: an OFF request that came back ON fails" {
  printf 'CONFIG_OFF=n\n' >"$WORK/frag"
  printf 'CONFIG_OFF=y\n' >"$WORK/resolved"
  run "$VERIFY" "$WORK/frag" "$WORK/resolved"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fragment asks for OFF, resolved config has CONFIG_OFF=y"* ]]
}

@test "verify-kernel-config: the failure names the parent-menuconfig cause" {
  printf 'CONFIG_LEAF=m\n' >"$WORK/frag"
  : >"$WORK/resolved"
  run "$VERIFY" "$WORK/frag" "$WORK/resolved"
  [ "$status" -eq 1 ]
  [[ "$output" == *"menuconfig"* ]]
  [[ "$output" == *"depends on"* ]]
}

@test "verify-kernel-config: an unreadable input fails loudly rather than passing vacuously" {
  printf 'CONFIG_A=y\n' >"$WORK/resolved"
  run "$VERIFY" "$WORK/absent-fragment" "$WORK/resolved"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fragment not readable"* ]]

  run "$VERIFY" "$WORK/resolved" "$WORK/absent-resolved"
  [ "$status" -eq 1 ]
  [[ "$output" == *"resolved config not readable"* ]]
}

# --- the real fragment, against the real defect ------------------------------

@test "rk3588-edge.fragment: RTW89 declares the parent menuconfig, not just the 8852BE leaf" {
  grep -qx 'CONFIG_RTW89=m' "$FRAGMENT"
  grep -qx 'CONFIG_RTW89_8852BE=m' "$FRAGMENT"
  # The parent must come first so a reader meets the gate before the leaf.
  local parent leaf
  parent="$(grep -n '^CONFIG_RTW89=m$' "$FRAGMENT" | cut -d: -f1)"
  leaf="$(grep -n '^CONFIG_RTW89_8852BE=m$' "$FRAGMENT" | cut -d: -f1)"
  [ "$parent" -lt "$leaf" ]
}

@test "rk3588-edge.fragment: TYPEC_FUSB302 declares the value kconfig can actually give it" {
  grep -qx 'CONFIG_TYPEC_FUSB302=m' "$FRAGMENT"
  ! grep -qx 'CONFIG_TYPEC_FUSB302=y' "$FRAGMENT"
}

@test "rk3588-edge.fragment: the gate REJECTS the resolved .config the broken 7.1.5 build produced" {
  # A synthetic reproduction of the shipped build's answer for the three symbols
  # this defect turned on: the rtw89 family off, FUSB302 downgraded.
  cat >"$WORK/broken" <<'EOF'
CONFIG_WLAN=y
CONFIG_CFG80211=m
CONFIG_MAC80211=m
CONFIG_WLAN_VENDOR_REALTEK=y
# CONFIG_RTW88 is not set
# CONFIG_RTW89 is not set
CONFIG_TYPEC=y
CONFIG_TYPEC_TCPM=y
CONFIG_TYPEC_FUSB302=m
EOF
  run "$VERIFY" "$FRAGMENT" "$WORK/broken"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_RTW89: DROPPED"* ]]
  [[ "$output" == *"CONFIG_RTW89_8852BE: DROPPED"* ]]
  # FUSB302 is now declared =m, so the same broken config must NOT flag it.
  [[ "$output" != *"CONFIG_TYPEC_FUSB302"* ]]
}

@test "rk3588-edge.fragment: the gate ACCEPTS a resolved .config that honours every symbol" {
  # Derive the expected resolved config from the fragment itself: every declared
  # symbol echoed back verbatim. This is the green half of the red/green pair —
  # it proves the gate is satisfiable, not merely loud.
  : >"$WORK/honoured"
  while IFS= read -r line; do
    case "$line" in
      '# CONFIG_'*' is not set') printf '%s\n' "$line" >>"$WORK/honoured" ;;
      '#'*|'') continue ;;
      CONFIG_*=n) printf '# %s is not set\n' "${line%%=*}" >>"$WORK/honoured" ;;
      CONFIG_*=*) printf '%s\n' "$line" >>"$WORK/honoured" ;;
    esac
  done <"$FRAGMENT"

  run "$VERIFY" "$FRAGMENT" "$WORK/honoured"
  [ "$status" -eq 0 ]
}

# --- wiring ------------------------------------------------------------------

@test "build-kernel.sh runs the gate after olddefconfig and before bindeb-pkg" {
  local src="$V2/lib/build-kernel.sh"
  grep -q ':/in/verify-kernel-config.sh:ro' "$src"
  grep -q 'bash /in/verify-kernel-config.sh /in/fragment.config .config' "$src"

  local sync verify pkg
  sync="$(grep -n 'make syncconfig' "$src" | tail -1 | cut -d: -f1)"
  verify="$(grep -n 'bash /in/verify-kernel-config.sh' "$src" | cut -d: -f1)"
  pkg="$(grep -n 'bindeb-pkg$' "$src" | tail -1 | cut -d: -f1)"
  [ "$sync" -lt "$verify" ]
  [ "$verify" -lt "$pkg" ]
}

@test "verify-kernel-config.sh is executable and shipped beside the other build gates" {
  [ -x "$VERIFY" ]
  [ -x "$V2/lib/verify-boot-artifacts.sh" ]
}
