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

# `run !` (a self-asserting negated run) needs bats >= 1.5.0; without this line
# every such call emits a BW02 warning.
bats_require_minimum_version 1.5.0

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PIPELINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  VERIFY="$PIPELINE_DIR/lib/verify-kernel-config.sh"
  FRAGMENT="$PIPELINE_DIR/manifests/kernel/rk3588-edge.fragment"
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
  run ! grep -qx 'CONFIG_TYPEC_FUSB302=y' "$FRAGMENT"
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
  run ! grep -qx 'CONFIG_NF_TABLES=m' "$FRAGMENT"
}

@test "rk3588-edge.fragment: the system-uncached dma-heap declares its own symbol under its parent" {
  # Patch 0009's heap is what makes MPP hardware encode work on this track:
  # librockchip_mpp hard-codes the heap NAME `system-uncached` and does not fall
  # back to `system`. Riding on the parent would leave the gate asserting only
  # DMABUF_HEAPS_SYSTEM=y — still true with the heap switched off — so the
  # fragment declares the leaf and the gate proves it reached the kernel.
  grep -qx 'CONFIG_DMABUF_HEAPS_SYSTEM_UNCACHED=y' "$FRAGMENT"
  # Declare-the-parent, same rule as RTW89 and NF_TABLES: DMABUF_HEAPS_SYSTEM is
  # this leaf's `depends on`, and DMABUF_HEAPS gates that in turn.
  local heaps parent leaf
  heaps="$(grep -n '^CONFIG_DMABUF_HEAPS=y$' "$FRAGMENT" | cut -d: -f1)"
  parent="$(grep -n '^CONFIG_DMABUF_HEAPS_SYSTEM=y$' "$FRAGMENT" | cut -d: -f1)"
  leaf="$(grep -n '^CONFIG_DMABUF_HEAPS_SYSTEM_UNCACHED=y$' "$FRAGMENT" | cut -d: -f1)"
  [ "$heaps" -lt "$parent" ]
  [ "$parent" -lt "$leaf" ]
  # =m is not an option: the symbol is a bool, and a heap that registered late
  # would be missing exactly when MPP probes for it.
  run ! grep -qx 'CONFIG_DMABUF_HEAPS_SYSTEM_UNCACHED=m' "$FRAGMENT"
}

@test "rk3588-edge.fragment: the gate REJECTS a config that dropped the uncached heap" {
  # The silent no-op this declaration exists to catch: 0009's code compiles
  # either way and dma_heap_add() for `system-uncached` simply never runs, so
  # nothing anywhere reports an error — the board just has no such heap.
  cat >"$WORK/no-uncached" <<'EOF'
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_HEAPS_SYSTEM=y
CONFIG_DMABUF_HEAPS_CMA=y
EOF
  run "$VERIFY" "$FRAGMENT" "$WORK/no-uncached"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_DMABUF_HEAPS_SYSTEM_UNCACHED: DROPPED"* ]]
  # The heaps that DID survive must not be reported.
  [[ "$output" != *"CONFIG_DMABUF_HEAPS_CMA"* ]]
}

@test "rk3588-edge.fragment: NFT_COUNTER is NOT declared — v7.2 has no such symbol" {
  # The ruleset's `counter` statement is real, but net/netfilter/Makefile compiles
  # nft_counter.o unconditionally into nf_tables-objs. Declaring CONFIG_NFT_COUNTER
  # would resolve to nothing and the gate would fail the build over a symbol the
  # kernel does not have. Re-verified at the v7.2 base: a tree-wide search over
  # every Kconfig/Kconfig.*/Makefile returns zero hits, so the row stays and its
  # rationale is unchanged.
  run ! grep -q '^CONFIG_NFT_COUNTER=' "$FRAGMENT"
}

# --- the modem + Bluetooth protocol closure ----------------------------------
#
# Nine symbols, and they are NOT all the same kind of claim. Read against the
# pinned v7.2 tree's own resolved config, three measured `is not set` — a real
# capability gain — and six already resolved, so their lines are ASSERTIONS of
# the CONFIG_TYPEC_FUSB302 kind: pinned so that "defconfig happens to supply it"
# cannot stop being true in silence.
#
# All nine must be MODULES. None of them is on a boot-critical path the way
# CONFIG_NF_TABLES is (the ingest firewall runs before any autoload could), so
# there is no reason to build them in and every reason not to grow the image.

@test "rk3588-edge.fragment: the modem + Bluetooth protocol closure is declared, as MODULES" {
  local sym
  for sym in USB_ACM USB_SERIAL_QUALCOMM USB_SERIAL_WWAN \
             MHI_BUS MHI_WWAN_CTRL MHI_WWAN_MBIM \
             BT_RFCOMM BT_BNEP USB_NET_RNDIS_HOST; do
    grep -qx "CONFIG_${sym}=m" "$FRAGMENT" \
      || { echo "fragment does not declare CONFIG_${sym}=m"; false; }
    # Built-in is the wrong answer for every one of them, and =y is the value a
    # future edit is most likely to reach for.
    run ! grep -qx "CONFIG_${sym}=y" "$FRAGMENT"
  done
  # Exactly nine — a duplicate line would be a defect, not a belt-and-braces.
  [ "$(grep -cE '^CONFIG_(USB_ACM|USB_SERIAL_QUALCOMM|USB_SERIAL_WWAN|MHI_BUS|MHI_WWAN_CTRL|MHI_WWAN_MBIM|BT_RFCOMM|BT_BNEP|USB_NET_RNDIS_HOST)=m$' "$FRAGMENT")" -eq 9 ]
}

@test "rk3588-edge.fragment: MHI_BUS precedes the MHI_WWAN leaves that depend on it" {
  # Same declare-the-parent-first rule as RTW89 and NF_TABLES. MHI_BUS is
  # `select`ed by the ath11k/ath12k leaves, but MHI_WWAN_CTRL/MHI_WWAN_MBIM
  # `depends on` it and select NOTHING — so dropping both Wi-Fi leaves would
  # take the modem transport with them unless MHI_BUS is declared in its own
  # right, which is why the ath comment no longer claims it "gets no entry".
  local bus ctrl mbim
  bus="$(grep -n '^CONFIG_MHI_BUS=m$' "$FRAGMENT" | cut -d: -f1)"
  ctrl="$(grep -n '^CONFIG_MHI_WWAN_CTRL=m$' "$FRAGMENT" | cut -d: -f1)"
  mbim="$(grep -n '^CONFIG_MHI_WWAN_MBIM=m$' "$FRAGMENT" | cut -d: -f1)"
  [ "$bus" -lt "$ctrl" ]
  [ "$bus" -lt "$mbim" ]
  run ! grep -q 'MHI_BUS.*so they get no entry' "$FRAGMENT"
}

@test "rk3588-edge.fragment: the gate REJECTS the resolved .config v7.2 produced BEFORE this closure" {
  # Not synthetic: these are the measured values for exactly these symbols in
  # the v7.2 resolved config captured by the patches repo, which is what the
  # board would have carried. Three absences and six survivors — so this is a
  # red/green pair in ONE fixture, and it fails if the gate ever stops
  # distinguishing them.
  cat >"$WORK/pre-closure" <<'EOF'
CONFIG_BT=m
CONFIG_BT_BREDR=y
# CONFIG_BT_RFCOMM is not set
# CONFIG_BT_BNEP is not set
CONFIG_WWAN=m
CONFIG_MHI_BUS=m
CONFIG_MHI_WWAN_CTRL=m
CONFIG_MHI_WWAN_MBIM=m
CONFIG_USB_ACM=m
# CONFIG_USB_SERIAL_QUALCOMM is not set
CONFIG_USB_SERIAL_WWAN=m
CONFIG_USB_SERIAL_OPTION=m
# CONFIG_USB_NET_RNDIS_HOST is not set
EOF
  run "$VERIFY" "$FRAGMENT" "$WORK/pre-closure"
  [ "$status" -eq 1 ]
  # The three that were genuinely absent must be named.
  [[ "$output" == *"CONFIG_BT_RFCOMM: DROPPED"* ]]
  [[ "$output" == *"CONFIG_BT_BNEP: DROPPED"* ]]
  [[ "$output" == *"CONFIG_USB_SERIAL_QUALCOMM: DROPPED"* ]]
  [[ "$output" == *"CONFIG_USB_NET_RNDIS_HOST: DROPPED"* ]]
  # The six that already resolved must NOT be — an assertion that fires on a
  # config honouring it is a gate nobody can act on.
  [[ "$output" != *"CONFIG_USB_ACM"* ]]
  [[ "$output" != *"CONFIG_USB_SERIAL_WWAN"* ]]
  [[ "$output" != *"CONFIG_MHI_BUS"* ]]
  [[ "$output" != *"CONFIG_MHI_WWAN_CTRL"* ]]
  [[ "$output" != *"CONFIG_MHI_WWAN_MBIM"* ]]
}

@test "closure manifests: the modem + Bluetooth closure is MIRRORED, parents included" {
  # THE GAP THIS CLOSES, and it is not hypothetical. PR #144 added
  # CONFIG_USB_NET_RNDIS_HOST=m to the fragment and never mirrored it here, so
  # for four merged PRs the fragment line was the symbol's ONLY assertion —
  # exactly the asymmetry required-symbols.list exists to prevent, since a later
  # edit deleting that line would have removed the last thing checking it.
  local req="$PIPELINE_DIR/manifests/kernel/required-symbols.list"
  local sym
  for sym in USB_ACM USB_SERIAL_QUALCOMM USB_SERIAL_WWAN \
             MHI_BUS MHI_WWAN_CTRL MHI_WWAN_MBIM \
             BT_RFCOMM BT_BNEP USB_NET_RNDIS_HOST; do
    grep -qx "CONFIG_${sym}=m" "$req" \
      || { echo "fragment declares CONFIG_${sym}=m but required-symbols.list does not mirror it"; false; }
  done

  # The two menuconfig parents this closure added, in the two documented forms.
  # WWAN is a TRISTATE parent, so it is bare — its own m-vs-y is defconfig's
  # business and pinning it would fail the build over a difference the device
  # cannot observe. BT_BREDR is a BOOL, where there is no such ambiguity and n
  # is the one value that would silently take both protocol leaves with it.
  grep -qx 'CONFIG_WWAN' "$req"
  grep -qx 'CONFIG_BT_BREDR=y' "$req"
  # Bare means bare: a value on WWAN would be a different, stronger claim.
  run ! grep -q '^CONFIG_WWAN=' "$req"
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
  local src="$PIPELINE_DIR/lib/build-kernel.sh"
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
  local src="$PIPELINE_DIR/lib/build-kernel.sh"
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

# Two cases for the committed allow-absent list lived here — a shape check on it,
# and a guard that neither shipped board's WiFi driver had been excepted into it.
# Both are REMOVED because the file they read is deleted: it existed only for the
# retired vendor-BSP config-file build, whose
# fetched Armbian .config named 24 symbols for out-of-tree EXTRAWIFI drivers this
# pipeline never copies in. No shipped variant uses config-file mode any more, so
# no allow-absent list is named by any manifest. The MECHANISM is untouched and
# still gated above — see "an unreadable allow-absent list fails loudly" and the
# `--allow-absent` legs — so a future config-file track gets the same protection.
# The list and its two cases are recoverable at the `vendor-kernel-final` tag.

# --- the option interface, and its equivalence to the positional one ---------

@test "verify-kernel-config: the option form and the positional form agree, pass and fail alike" {
  # The in-builder invocation is positional and must never change; the closure
  # manifests have no positional slot. Both spellings therefore have to be the
  # same checker, or one of them drifts into being untested.
  printf 'CONFIG_A=y\nCONFIG_B=m\n' >"$WORK/frag"
  printf 'CONFIG_A=y\nCONFIG_B=m\n' >"$WORK/good"
  printf 'CONFIG_A=y\n' >"$WORK/bad"

  run "$VERIFY" "$WORK/frag" "$WORK/good"
  local pos_ok_status="$status" pos_ok_out="$output"
  run "$VERIFY" --declared "$WORK/frag" --config "$WORK/good"
  [ "$status" -eq "$pos_ok_status" ]
  [ "$output" = "$pos_ok_out" ]
  [ "$status" -eq 0 ]

  run "$VERIFY" "$WORK/frag" "$WORK/bad"
  local pos_bad_status="$status" pos_bad_out="$output"
  run "$VERIFY" --declared "$WORK/frag" --config "$WORK/bad"
  [ "$status" -eq "$pos_bad_status" ]
  [ "$output" = "$pos_bad_out" ]
  [ "$status" -eq 1 ]
}

@test "verify-kernel-config: the option form carries the allow-absent list too" {
  printf 'CONFIG_A=y\nCONFIG_OUT_OF_TREE=m\n' >"$WORK/decl"
  printf 'CONFIG_A=y\n' >"$WORK/res"
  printf 'CONFIG_OUT_OF_TREE\n' >"$WORK/allow"

  run "$VERIFY" "$WORK/decl" "$WORK/res" "$WORK/allow"
  local pos_out="$output"
  run "$VERIFY" --declared "$WORK/decl" --config "$WORK/res" --allow-absent "$WORK/allow"
  [ "$status" -eq 0 ]
  [ "$output" = "$pos_out" ]
}

@test "verify-kernel-config: --required accepts an exact value and a bare parent alike" {
  printf 'CONFIG_PARENT=y\nCONFIG_LEAF=m\n' >"$WORK/res"
  printf '# a comment\nCONFIG_PARENT\nCONFIG_LEAF=m\n' >"$WORK/req"

  run "$VERIFY" --config "$WORK/res" --required "$WORK/req"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 required and 0 forbidden"* ]]
}

@test "verify-kernel-config: --required fails on an absent symbol, an off symbol and a wrong value" {
  printf 'CONFIG_WRONG=m\n# CONFIG_OFF is not set\n' >"$WORK/res"
  printf 'CONFIG_WRONG=y\nCONFIG_OFF\nCONFIG_MISSING\n' >"$WORK/req"

  run "$VERIFY" --config "$WORK/res" --required "$WORK/req"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_WRONG: REQUIRED as CONFIG_WRONG=y, resolved config has CONFIG_WRONG=m"* ]]
  [[ "$output" == *"CONFIG_OFF: REQUIRED but the resolved config has '# CONFIG_OFF is not set'"* ]]
  [[ "$output" == *"CONFIG_MISSING: REQUIRED but the resolved config does not carry the symbol at all"* ]]
  [[ "$output" == *"menuconfig"* ]]
}

@test "verify-kernel-config: --forbidden is satisfied by not-set AND by absence" {
  printf '# CONFIG_OFF is not set\nCONFIG_KEPT=y\n' >"$WORK/res"
  printf 'CONFIG_OFF\nCONFIG_NEVER_EXISTED\n' >"$WORK/forb"

  run "$VERIFY" --config "$WORK/res" --forbidden "$WORK/forb"
  [ "$status" -eq 0 ]

  printf 'CONFIG_OFF=m\n' >>"$WORK/res"
  run "$VERIFY" --config "$WORK/res" --forbidden "$WORK/forb"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_OFF: FORBIDDEN but the resolved config has CONFIG_OFF=m"* ]]
}

@test "verify-kernel-config: a forbidden entry written as a value assignment is refused" {
  # `CONFIG_X=y` here would mean "this value is banned, another is fine" — a
  # weaker claim than the manifest makes, so it must not be silently accepted.
  printf 'CONFIG_A=y\n' >"$WORK/res"
  printf 'CONFIG_A=y\n' >"$WORK/forb"

  run "$VERIFY" --config "$WORK/res" --forbidden "$WORK/forb"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a bare symbol name"* ]]
}

@test "verify-kernel-config: an unknown option and a missing operand are usage errors, not silent passes" {
  printf 'CONFIG_A=y\n' >"$WORK/res"

  run "$VERIFY" --config "$WORK/res" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option: --bogus"* ]]

  run "$VERIFY" --config
  [ "$status" -eq 2 ]

  run "$VERIFY" --required "$WORK/res"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--config is required"* ]]

  run "$VERIFY" --config "$WORK/res"
  [ "$status" -eq 2 ]
  [[ "$output" == *"nothing to check"* ]]
}

@test "verify-kernel-config: a missing manifest fails loudly, never as an empty check" {
  printf 'CONFIG_A=y\n' >"$WORK/res"

  run "$VERIFY" --config "$WORK/res" --required "$WORK/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"required-symbols list not readable"* ]]

  run "$VERIFY" --config "$WORK/res" --forbidden "$WORK/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"forbidden-symbols list not readable"* ]]

  run "$VERIFY" --config "$WORK/absent" --forbidden "$WORK/res"
  [ "$status" -eq 1 ]
  [[ "$output" == *"resolved config not readable"* ]]
}

# --- the closure manifests themselves ----------------------------------------

@test "closure manifests: every entry is a CONFIG_ symbol, deduped, and forbidden entries are bare" {
  local req="$PIPELINE_DIR/manifests/kernel/required-symbols.list"
  local forb="$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
  [ -f "$req" ]
  [ -f "$forb" ]

  local list f
  for f in "$req" "$forb"; do
    list="$(sed -e 's/#.*//' "$f" | awk 'NF{print $1}')"
    [ -n "$list" ]
    while IFS= read -r s; do
      [[ "$s" == CONFIG_* ]] || { echo "not a CONFIG_ symbol in $f: $s"; false; }
    done <<<"$list"
    [ "$(wc -l <<<"$list")" -eq "$(sed 's/=.*//' <<<"$list" | sort -u | wc -l)" ]
  done

  list="$(sed -e 's/#.*//' "$forb" | awk 'NF{print $1}')"
  run ! grep -q '=' <<<"$list"
}

@test "closure manifests: required and forbidden never name the same symbol" {
  local req="$PIPELINE_DIR/manifests/kernel/required-symbols.list"
  local forb="$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
  local overlap
  overlap="$(comm -12 \
    <(sed -e 's/#.*//' "$req"  | awk 'NF{print $1}' | sed 's/=.*//' | sort -u) \
    <(sed -e 's/#.*//' "$forb" | awk 'NF{print $1}' | sort -u))"
  [ -z "$overlap" ] || { echo "symbol in BOTH manifests: $overlap"; false; }
}

@test "closure manifests: every menuconfig parent the four real defects taught us is REQUIRED" {
  # RTW89, DMABUF_HEAPS, TYPEC_FUSB302 and NF_TABLES each shipped broken because
  # a parent was missing. The parents that gate them are the ones a future
  # fragment edit is most likely to knock out without noticing.
  local req="$PIPELINE_DIR/manifests/kernel/required-symbols.list"
  local sym
  for sym in CONFIG_MMC CONFIG_PCI CONFIG_USB_SUPPORT CONFIG_USB_SERIAL \
             CONFIG_USB_NET_DRIVERS CONFIG_WLAN CONFIG_BT CONFIG_DRM \
             CONFIG_SOUND CONFIG_SND CONFIG_SND_SOC CONFIG_SND_USB \
             CONFIG_MEDIA_SUPPORT CONFIG_DMABUF_HEAPS=y CONFIG_IOMMU_SUPPORT \
             CONFIG_THERMAL CONFIG_HWMON CONFIG_TYPEC CONFIG_NF_TABLES=y; do
    grep -qx -- "$sym" "$req" || { echo "closure parent missing from required list: $sym"; false; }
  done
}

@test "closure manifests: the forbidden list holds every foreign platform the fragment disables" {
  # The two files are one statement written twice — the fragment turns the
  # platform off, the manifest asserts it stayed off. A row present in one and
  # absent from the other is how the trim silently reverts on a defconfig bump.
  local forb="$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
  local sym
  while IFS= read -r sym; do
    grep -qx -- "$sym" "$forb" \
      || { echo "fragment disables $sym but the forbidden manifest does not assert it"; false; }
  done < <(grep -oE '^# (CONFIG_ARCH_[A-Z0-9_]+) is not set$' "$FRAGMENT" | awk '{print $2}')
}

@test "rk3588-edge.fragment: the Rockchip-only block keeps ARCH_ROCKCHIP and drops the rest" {
  grep -qx 'CONFIG_ARCH_ROCKCHIP=y' "$FRAGMENT"
  run ! grep -qx '# CONFIG_ARCH_ROCKCHIP is not set' "$FRAGMENT"
  # A trim of one or two platforms would be cosmetic; the point is the whole set.
  [ "$(grep -cE '^# CONFIG_ARCH_[A-Z0-9_]+ is not set$' "$FRAGMENT")" -ge 40 ]
  # ARCH_REALTEK is the Realtek SoC PLATFORM, not the RTL8852BE Wi-Fi adapter.
  # Disabling it must never come with dropping the adapter's own driver.
  grep -qx '# CONFIG_ARCH_REALTEK is not set' "$FRAGMENT"
  grep -qx 'CONFIG_RTW89_8852BE=m' "$FRAGMENT"
}

@test "rk3588-edge.fragment: ARCH_ASPEED — the platform v7.2 ADDED is disabled and forbidden" {
  # ARCH_ASPEED is the counterexample to "a platform upstream adds later is simply
  # absent here rather than silently re-enabled": v7.2 added the prompt to
  # arch/arm64/Kconfig.platforms AND set it `=y` in arm64 defconfig in the same
  # release, so a fragment that was not re-enumerated at the base bump would have
  # shipped defconfig's own `=y` on an RK3588 kernel. Same shape as ARCH_REALTEK
  # above: named explicitly because the generic count/derivation checks pass
  # either way.
  grep -qx '# CONFIG_ARCH_ASPEED is not set' "$FRAGMENT"
  grep -qx 'CONFIG_ARCH_ASPEED' "$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
  # The forbidden manifest takes BARE names; a valued row is a usage error.
  run ! grep -q '^CONFIG_ARCH_ASPEED=' "$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
}

@test "rk3588-edge.fragment: the gate REJECTS a resolved .config where ARCH_ASPEED survived" {
  # The silent regression this row exists to catch: defconfig sets it, the
  # fragment is stale, and the resolved config carries a foreign SoC platform
  # with nothing anywhere reporting an error.
  printf 'CONFIG_ARCH_ASPEED=y\n' >"$WORK/aspeed-back"
  run "$VERIFY" --config "$WORK/aspeed-back" \
    --forbidden "$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_ARCH_ASPEED: FORBIDDEN"* ]]
}

@test "rk3588-edge.fragment: the gate REJECTS a config where a foreign platform came back" {
  local sample
  sample="$(grep -oE '^# (CONFIG_ARCH_[A-Z0-9_]+) is not set$' "$FRAGMENT" | awk '{print $2}' | head -1)"
  [ -n "$sample" ]
  printf '%s=y\n' "$sample" >"$WORK/regressed"
  run "$VERIFY" --config "$WORK/regressed" \
    --forbidden "$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
  [ "$status" -eq 1 ]
  [[ "$output" == *"${sample}: FORBIDDEN"* ]]
}

@test "closure manifests: production edge forbids the CeraLive test seam" {
  # The edge-test variant owns the fault-injection knobs. A production artifact
  # carrying one of them is not the kernel that was validated on hardware.
  local forb="$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
  grep -qx 'CONFIG_ROCKCHIP_MPP_CERALIVE_TEST' "$forb"
  # …and the fragment must not enable it either.
  run ! grep -qE '^CONFIG_ROCKCHIP_MPP_CERALIVE_TEST=[ym]' "$FRAGMENT"
  # The three symbols the island's seam replaced were ALL declared by the retired
  # 0013 member, so none of them exists at this patches_commit. A forbidden row for
  # one would be silently vacuous, and an edge-test row would be a DROPPED symbol.
  run ! grep -qE '^CONFIG_(VIDEO_ROCKCHIP_RKVENC_CERALIVE_TEST|VIDEO_ROCKCHIP_HDMIRX_CERALIVE_TEST|DMABUF_HEAPS_CERALIVE_TEST)$' "$forb"
}

@test "closure manifests: the island MPP closure is declared with its parents" {
  local req="$PIPELINE_DIR/manifests/kernel/required-symbols.list"
  local sym
  # The service module plus the three compiled clients, in the ONLY values kconfig
  # can give them: SERVICE is the tristate, the clients are bools inside its `if`.
  for sym in 'CONFIG_ROCKCHIP_MPP_SERVICE=m' \
             'CONFIG_ROCKCHIP_MPP_RKVENC2=y' \
             'CONFIG_ROCKCHIP_MPP_RKVDEC2=y' \
             'CONFIG_ROCKCHIP_MPP_JPGDEC=y'; do
    grep -qx "$sym" "$FRAGMENT"
    grep -qx "$sym" "$req"
  done
  # The two menuconfig parents this block used to ride undeclared. Neither may be
  # dropped: MEDIA_PLATFORM_DRIVERS gates every `source` in the media platform
  # Kconfig, V4L_MEM2MEM_DRIVERS is what RGA and Hantro `depends on`.
  for sym in 'CONFIG_MEDIA_PLATFORM_DRIVERS=y' 'CONFIG_V4L_MEM2MEM_DRIVERS=y'; do
    grep -qx "$sym" "$FRAGMENT"
    grep -qx "$sym" "$req"
  done
  # Promptless, so it may only be ASSERTED — a fragment cannot direct kconfig here.
  grep -qx 'CONFIG_ROCKCHIP_MPP_PROC_FS=y' "$req"
  run ! grep -q 'CONFIG_ROCKCHIP_MPP_PROC_FS' "$FRAGMENT"
}

@test "closure manifests: RGA ownership moves to multi_rga and forbids mainline rockchip-rga" {
  local req="$PIPELINE_DIR/manifests/kernel/required-symbols.list"
  # The three RGA nodes move together. multi_rga depends on ARCH_ROCKCHIP and
  # ROCKCHIP_IOMMU, so every member of that Kconfig closure must be explicit.
  local sym
  for sym in 'CONFIG_ARCH_ROCKCHIP=y' 'CONFIG_ROCKCHIP_IOMMU=y' 'CONFIG_ROCKCHIP_MULTI_RGA=m'; do
    grep -qx "$sym" "$FRAGMENT"
    grep -qx "$sym" "$req"
  done
  local forb="$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
  run ! grep -qx 'CONFIG_VIDEO_ROCKCHIP_RGA=m' "$FRAGMENT"
  run ! grep -qx 'CONFIG_VIDEO_ROCKCHIP_RGA=m' "$req"
  grep -qx 'CONFIG_VIDEO_ROCKCHIP_RGA' "$forb"
}

@test "closure manifests: VIDEO_ROCKCHIP_RGA forbidden gate is non-vacuous" {
  printf 'CONFIG_VIDEO_ROCKCHIP_RGA=m\n' >"$WORK/pre-rga-flip"
  run "$VERIFY" --config "$WORK/pre-rga-flip" \
    --forbidden "$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 dependency-closure violation"* ]]
  [[ "$output" == *"CONFIG_VIDEO_ROCKCHIP_RGA: FORBIDDEN"* ]]
}

@test "closure manifests: MNH-23 — only the three compiled MPP clients are permitted" {
  # The island compiles RKVENC2, RKVDEC2 and JPGDEC and no others; every remaining
  # client is source-only behind `depends on BROKEN`. These rows put that gate in
  # the image, so lifting a BROKEN upstream of us cannot add a fourth client to a
  # shipped kernel. The JPEG encoder's symbol is JPGENC — RKJPEGE is the block name
  # in its prompt text, and a row naming that would guard nothing.
  local forb="$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
  local sym
  for sym in RKVDEC RKVENC VDPU1 VEPU1 VDPU2 VEPU2 VEPU22 IEP2 JPGENC AV1DEC VDPP \
             RKVENC2_DEVFREQ RKVDEC2_DEVFREQ; do
    grep -qx "CONFIG_ROCKCHIP_MPP_${sym}" "$forb"
  done
  run ! grep -qx 'CONFIG_ROCKCHIP_MPP_RKJPEGE' "$forb"
  # …and none of the three compiled clients may appear in the forbidden manifest.
  run ! grep -qE '^CONFIG_ROCKCHIP_MPP_(RKVENC2|RKVDEC2|JPGDEC)$' "$forb"
}

@test "closure manifests: KMEMLEAK is forbidden for production edge" {
  # A bool arm64 defconfig leaves off, so nothing is broken today — but it adds a
  # metadata object per kernel allocation and would turn the encode path into a
  # scanner. It was in NEITHER manifest before, which is the gap this closes.
  grep -qx 'CONFIG_DEBUG_KMEMLEAK' "$PIPELINE_DIR/manifests/kernel/forbidden-symbols.list"
}

@test "verify-kernel-config.sh is executable and shipped beside the other build gates" {
  [ -x "$VERIFY" ]
  [ -x "$PIPELINE_DIR/lib/verify-boot-artifacts.sh" ]
}
