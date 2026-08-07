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
# A later board run found the same class again, this time as a SECURITY gap:
# `CONFIG_NF_TABLES` was never named either, so the edge kernel had no nftables
# at all and `ceralive-ingest-firewall.service` failed every boot with
# `Unable to initialize Netlink socket: Protocol not supported` — leaving the
# WAN-side drop of the unauthenticated RTMP/SRT ingest ports silently unapplied.
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
  # All 5 declared symbols survived, and with no allow-absent list none of them
  # was waved through — the count of exceptions must be zero, not just absent
  # from the message.
  [[ "$output" == *"5 of 5 declared symbol(s) survived"* ]]
  [[ "$output" == *"(0 reviewed exception(s))"* ]]
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

@test "rk3588-edge.fragment: NF_TABLES declares the parent the whole nftables family sits inside" {
  grep -qx 'CONFIG_NF_TABLES=y' "$FRAGMENT"
  grep -qx 'CONFIG_NF_TABLES_INET=y' "$FRAGMENT"
  # NF_TABLES_INET lives inside `if NF_TABLES`, so — as with RTW89 — a reader must
  # meet the gate before the thing it gates.
  local parent inet
  parent="$(grep -n '^CONFIG_NF_TABLES=y$' "$FRAGMENT" | cut -d: -f1)"
  inet="$(grep -n '^CONFIG_NF_TABLES_INET=y$' "$FRAGMENT" | cut -d: -f1)"
  [ "$parent" -lt "$inet" ]
  # =m is NOT equivalent here: ceralive-ingest-firewall.service is a
  # DefaultDependencies=no oneshot that runs `nft -f` before the ingest gateway
  # opens its listeners, so the family must be built in.
  ! grep -qx 'CONFIG_NF_TABLES=m' "$FRAGMENT"
}

@test "rk3588-edge.fragment: NFT_COUNTER is NOT declared — v7.1.5 has no such symbol" {
  # The ruleset's `counter` statement is real, but net/netfilter/Makefile compiles
  # nft_counter.o unconditionally into nf_tables-objs. Declaring CONFIG_NFT_COUNTER
  # would resolve to nothing and the gate would fail the build over a symbol the
  # kernel does not have.
  ! grep -q '^CONFIG_NFT_COUNTER=' "$FRAGMENT"
}

@test "rk3588-edge.fragment: the gate REJECTS the resolved .config the broken 7.1.5 build produced" {
  # A synthetic reproduction of the shipped build's answer for the symbols this
  # defect turned on: the rtw89 family off, the nftables family off, FUSB302
  # downgraded. The NETFILTER/IPV6 lines are the board's real answer too — they
  # are what proves NF_TABLES was dropped for its own missing declaration and not
  # for an unmet dependency.
  cat >"$WORK/broken" <<'EOF'
CONFIG_WLAN=y
CONFIG_CFG80211=m
CONFIG_MAC80211=m
CONFIG_WLAN_VENDOR_REALTEK=y
# CONFIG_RTW88 is not set
# CONFIG_RTW89 is not set
CONFIG_NETFILTER=y
CONFIG_NETFILTER_ADVANCED=y
CONFIG_IPV6=y
# CONFIG_NF_TABLES is not set
CONFIG_TYPEC=y
CONFIG_TYPEC_TCPM=y
CONFIG_TYPEC_FUSB302=m
EOF
  run "$VERIFY" "$FRAGMENT" "$WORK/broken"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_RTW89: DROPPED"* ]]
  [[ "$output" == *"CONFIG_RTW89_8852BE: DROPPED"* ]]
  [[ "$output" == *"CONFIG_NF_TABLES: DROPPED"* ]]
  [[ "$output" == *"CONFIG_NF_TABLES_INET: DROPPED"* ]]
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
  # The invocation is mode-agnostic: `declared_config` is /in/fragment.config in
  # defconfig mode and the fetched full .config in config-file mode. Asserting a
  # literal /in/fragment.config here would forbid the config-file mode entirely.
  grep -q 'bash /in/verify-kernel-config.sh "${declared_config}" .config' "$src"
  grep -q 'declared_config=/in/fragment.config' "$src"

  local sync verify pkg
  sync="$(grep -n 'make syncconfig' "$src" | tail -1 | cut -d: -f1)"
  verify="$(grep -n 'bash /in/verify-kernel-config.sh' "$src" | cut -d: -f1)"
  pkg="$(grep -n 'bindeb-pkg$' "$src" | tail -1 | cut -d: -f1)"
  [ "$sync" -lt "$verify" ]
  [ "$verify" -lt "$pkg" ]
}

@test "build-kernel.sh gates BOTH config modes — there is exactly one verify call" {
  # The two modes differ only in how the starting .config is obtained. A second
  # verify invocation would mean one mode grew its own (and could lose it).
  local src="$V2/lib/build-kernel.sh"
  [ "$(grep -c 'bash /in/verify-kernel-config.sh' "$src")" -eq 1 ]
  grep -q 'declared_config=/src/declared.config' "$src"
}

# --- allow-absent exceptions (config-file mode) ------------------------------

@test "verify-kernel-config: an allow-absent symbol may be missing without failing" {
  printf 'CONFIG_A=y\nCONFIG_OUT_OF_TREE=m\n' >"$WORK/decl"
  printf 'CONFIG_A=y\n' >"$WORK/res"
  printf '# reviewed\nCONFIG_OUT_OF_TREE\n' >"$WORK/allow"

  run "$VERIFY" "$WORK/decl" "$WORK/res" "$WORK/allow"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 reviewed exception"* ]]
}

@test "verify-kernel-config: an allow-absent symbol that DID survive is a STALE exception and fails" {
  # Non-vacuity: without this the list could silently become a blanket opt-out.
  printf 'CONFIG_A=y\n' >"$WORK/decl"
  printf 'CONFIG_A=y\n' >"$WORK/res"
  printf 'CONFIG_A\n' >"$WORK/allow"

  run "$VERIFY" "$WORK/decl" "$WORK/res" "$WORK/allow"
  [ "$status" -ne 0 ]
  [[ "$output" == *"STALE EXCEPTION"* ]]
  [[ "$output" == *"CONFIG_A"* ]]
}

@test "verify-kernel-config: the allowlist does NOT weaken the gate for unlisted symbols" {
  printf 'CONFIG_A=y\nCONFIG_B=m\n' >"$WORK/decl"
  printf 'CONFIG_A=y\n' >"$WORK/res"
  printf 'CONFIG_SOMETHING_ELSE\n' >"$WORK/allow"

  run "$VERIFY" "$WORK/decl" "$WORK/res" "$WORK/allow"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIG_B: DROPPED"* ]]
}

@test "verify-kernel-config: a bare (non-CONFIG_) allow-absent entry is refused" {
  printf 'CONFIG_A=y\n' >"$WORK/decl"
  printf '\n' >"$WORK/res"
  printf 'A\n' >"$WORK/allow"

  run "$VERIFY" "$WORK/decl" "$WORK/res" "$WORK/allow"
  [ "$status" -ne 0 ]
  [[ "$output" == *"full CONFIG_ symbol name"* ]]
}

@test "verify-kernel-config: an unreadable allow-absent list fails loudly, never silently empty" {
  printf 'CONFIG_A=y\n' >"$WORK/decl"
  printf 'CONFIG_A=y\n' >"$WORK/res"

  run "$VERIFY" "$WORK/decl" "$WORK/res" "$WORK/does-not-exist"
  [ "$status" -ne 0 ]
  [[ "$output" == *"allow-absent list not readable"* ]]
}

@test "rk3588-vendor-patched.absent: every entry is a CONFIG_ symbol and the list is deduped" {
  local list="$V2/manifests/kernel/rk3588-vendor-patched.absent"
  [ -f "$list" ]
  local syms
  syms="$(sed -e 's/#.*//' "$list" | awk 'NF{print $1}')"
  [ -n "$syms" ]
  while IFS= read -r s; do
    [[ "$s" == CONFIG_* ]] || { echo "not a CONFIG_ symbol: $s"; false; }
  done <<<"$syms"
  [ "$(wc -l <<<"$syms")" -eq "$(sort -u <<<"$syms" | wc -l)" ]
}

@test "rk3588-vendor-patched.absent: neither shipped board's WiFi driver is excepted" {
  # Both RK3588 boards use IN-TREE drivers (RTL8852BE -> rtw89, AP6275P ->
  # brcmfmac). If either ever appears here it means the gate was silenced on a
  # symbol the fleet actually needs.
  local list="$V2/manifests/kernel/rk3588-vendor-patched.absent"
  ! grep -Eq '^CONFIG_(RTW89|RTW89_CORE|RTW89_PCI|RTW89_8852B|RTW89_8852BE|BRCMFMAC)\b' "$list"
}

@test "verify-kernel-config.sh is executable and shipped beside the other build gates" {
  [ -x "$VERIFY" ]
  [ -x "$V2/lib/verify-boot-artifacts.sh" ]
}
