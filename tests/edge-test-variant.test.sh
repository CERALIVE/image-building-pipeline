#!/usr/bin/env bash
#
# edge-test variant — sibling-variant inheritance, ordered defconfig fragments,
# and the guarantee that the debug kernel can never be released.
#
# WHY THIS FILE EXISTS
#
# Wave 6 adds a kernel that deliberately carries KASAN, lockdep, KUnit and three
# CeraLive fault-injection symbols, so that the rkvenc/HDMI-RX negative paths can
# be forced on a real board and proven memory- and lock-correct. That kernel is
# strictly more dangerous than any artifact this repository has produced before,
# and the two ways it can hurt the fleet are both structural rather than
# behavioural:
#
#   1. It DRIFTS off production. A debug build is only evidence about production
#      if it compiles the same source. Copy-pasting `edge`'s pins into a sibling
#      variant looks identical on the day it is written and silently diverges on
#      the first `edge` re-pin, at which point the QA transcript is about a kernel
#      nobody ships. `extends: edge` is what makes that impossible, and the
#      pin-equality legs below are what prove `extends` actually did it.
#   2. It SHIPS. A debug kernel in a release artifact is a fleet with a sanitizer
#      in the media path. The release guard is a PROPERTY check (does this variant
#      enable a forbidden symbol?) rather than a name blocklist, so the legs here
#      drive both verdicts — a guard that can only answer "yes" is not a guard.
#
# It also pins the backward-compatibility half of the schema change. The singular
# `defconfig_fragment` key is the ORIGINAL spelling and every pre-existing
# single-fragment manifest must keep resolving byte-identically; the plural
# `defconfig_fragments` is additive. Both spellings are driven here, and so is the
# refusal to accept both at once.
#
# Hardware-free and network-free: everything is the real shipped resolver, the
# real shipped config-mode module and the real shipped release guard, driven
# against the real manifests plus synthetic fixtures.
#
# Profile: contract-test (docs/shell-profiles.md) — `set -uo pipefail`, collect
# every failure, own the exit code.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"

RESOLVE_SH="${PIPELINE_DIR}/lib/resolve.sh"
RESOLVE_PY="${PIPELINE_DIR}/lib/resolve.py"
FAMILY="${PIPELINE_DIR}/manifests/families/rk3588.yaml"
FAMILY_SCHEMA="${PIPELINE_DIR}/manifests/schema/family.schema.json"
BOARD="${PIPELINE_DIR}/manifests/boards/rock-5b-plus.yaml"
BOARD_SCHEMA="${PIPELINE_DIR}/manifests/schema/board.schema.json"
GUARD="${PIPELINE_DIR}/ci/check-release-variant.sh"
CONFIG_MOD="${PIPELINE_DIR}/lib/kernel/config.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

printf '== edge-test variant contract\n'

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# resolve <variant> -> the flat KEY='value' param set on stdout
resolve() {
  bash "${RESOLVE_SH}" rock-5b-plus --variant "$1" 2>/dev/null
}

param() {
  sed -n "s/^$2='\(.*\)'\$/\1/p" <<<"$1"
}

# merge_family <family.yaml> [--variant name] — the resolver's own merge step,
# schema-validated, so a malformed inheritance graph is reported the way a real
# build would report it.
merge_family() {
  local family="$1"; shift
  python3 "${RESOLVE_PY}" merge \
    --family "${family}" --board "${BOARD}" \
    --family-schema "${FAMILY_SCHEMA}" --board-schema "${BOARD_SCHEMA}" \
    "$@" 2>&1
}

# --------------------------------------------------------------------------
# 1. The exact declared contract
# --------------------------------------------------------------------------

EDGE_TEST="$(resolve edge-test)"
EDGE="$(resolve edge)"

if [[ -n "${EDGE_TEST}" ]]; then
  ok "edge-test resolves"
else
  bad "edge-test resolves"
fi

assert_param() {
  local want="$2" got
  got="$(param "${EDGE_TEST}" "$1")"
  if [[ "${got}" == "${want}" ]]; then
    ok "edge-test $1 = ${want}"
  else
    bad "edge-test $1 (want '${want}', got '${got}')"
  fi
}

assert_param KERNEL_VARIANT 'edge-test'
assert_param KERNEL_PACKAGES 'linux-image-7.2.0-ceralive-rk3588-test'
assert_param KERNEL_SOURCE_LOCAL_VERSION '-ceralive-rk3588-test'
assert_param KERNEL_SOURCE_KERNEL_RELEASE '7.2.0-ceralive-rk3588-test'
assert_param KERNEL_SOURCE_PACKAGE_VERSION '7.2.0-ceralive1+test1'
assert_param KERNEL_SOURCE_DEFCONFIG_FRAGMENTS \
  'manifests/kernel/rk3588-edge.fragment manifests/kernel/rk3588-edge-test.fragment'

# The ORDER is the contract, not merely the membership: the production fragment
# must be merged first so the test fragment's answers win on any shared symbol.
FRAGS="$(param "${EDGE_TEST}" KERNEL_SOURCE_DEFCONFIG_FRAGMENTS)"
if [[ "${FRAGS%% *}" == 'manifests/kernel/rk3588-edge.fragment' ]]; then
  ok "the PRODUCTION fragment is merged first"
else
  bad "the PRODUCTION fragment is merged first (got '${FRAGS%% *}')"
fi

# Inheritance must REPLACE the singular key, never sit beside it — the two keys
# are mutually exclusive and a resolved param set carrying both is ambiguous.
if [[ -z "$(param "${EDGE_TEST}" KERNEL_SOURCE_DEFCONFIG_FRAGMENT)" ]]; then
  ok "the inherited singular defconfig_fragment is cleared by the plural key"
else
  bad "the inherited singular defconfig_fragment is cleared by the plural key"
fi

for frag in ${FRAGS}; do
  if [[ -f "${PIPELINE_DIR}/${frag}" ]]; then
    ok "declared fragment exists: ${frag}"
  else
    bad "declared fragment exists: ${frag}"
  fi
done

# --------------------------------------------------------------------------
# 2. Pin equality — the reason `extends` exists
# --------------------------------------------------------------------------

for key in \
  KERNEL_SOURCE_GIT_URL \
  KERNEL_SOURCE_MIRROR_URL \
  KERNEL_SOURCE_TAG \
  KERNEL_SOURCE_COMMIT \
  KERNEL_SOURCE_PATCHES_GIT_URL \
  KERNEL_SOURCE_PATCHES_COMMIT \
  KERNEL_SOURCE_PATCHES_SERIES \
  KERNEL_SOURCE_BUILDER_IMAGE \
  KERNEL_SOURCE_DEFCONFIG_BASE \
  KERNEL_SOURCE_DTB_BOOT_DIR \
  DTB_NAME \
  ARMBIAN_BRANCH
do
  a="$(param "${EDGE}" "${key}")"
  b="$(param "${EDGE_TEST}" "${key}")"
  if [[ -n "${a}" && "${a}" == "${b}" ]]; then
    ok "inherited byte-for-byte from edge: ${key}"
  else
    bad "inherited byte-for-byte from edge: ${key} (edge='${a}', edge-test='${b}')"
  fi
done

# dtb_deb_dir is the ONE DTB coordinate that is NOT shared, and that is forced
# rather than chosen: `make bindeb-pkg` installs the in-tree DTBs under
# /usr/lib/<linux-image package>/, so it is a function of kernel_release. Left
# equal to edge's, validate_built_kernel_deb would look for the board DTB at a
# path this build never creates.
DEB_DIR="$(param "${EDGE_TEST}" KERNEL_SOURCE_DTB_DEB_DIR)"
if [[ "${DEB_DIR}" == "/usr/lib/linux-image-7.2.0-ceralive-rk3588-test/rockchip" ]]; then
  ok "dtb_deb_dir tracks the edge-test kernel release"
else
  bad "dtb_deb_dir tracks the edge-test kernel release (got '${DEB_DIR}')"
fi

# The two artifacts must be unmistakable for one another on every identity axis.
for key in KERNEL_PACKAGES KERNEL_SOURCE_LOCAL_VERSION \
           KERNEL_SOURCE_KERNEL_RELEASE KERNEL_SOURCE_PACKAGE_VERSION
do
  if [[ "$(param "${EDGE}" "${key}")" != "$(param "${EDGE_TEST}" "${key}")" ]]; then
    ok "identity differs from edge: ${key}"
  else
    bad "identity differs from edge: ${key} (they are the same)"
  fi
done

# --------------------------------------------------------------------------
# 3. Backward compatibility — the singular key still works, unchanged
# --------------------------------------------------------------------------

EDGE_FRAG="$(param "${EDGE}" KERNEL_SOURCE_DEFCONFIG_FRAGMENT)"
if [[ "${EDGE_FRAG}" == 'manifests/kernel/rk3588-edge.fragment' ]]; then
  ok "production edge still resolves the SINGULAR defconfig_fragment key"
else
  bad "production edge still resolves the SINGULAR defconfig_fragment key (got '${EDGE_FRAG}')"
fi

if [[ -z "$(param "${EDGE}" KERNEL_SOURCE_DEFCONFIG_FRAGMENTS)" ]]; then
  ok "production edge declares exactly ONE fragment (no plural key)"
else
  bad "production edge declares exactly ONE fragment (no plural key)"
fi

# The DEFAULT path is now the production `edge` overlay (`default_variant: edge`),
# so it legitimately carries a kernel_source block — and must carry EXACTLY the
# edge one, never the edge-test deltas. The property worth pinning is therefore
# no longer "no kernel_source at all" but "byte-identical to --variant edge",
# which is what proves default_variant is a pointer rather than a second copy.
DEFAULT_PARAMS="$(bash "${RESOLVE_SH}" rock-5b-plus 2>/dev/null)"
if [[ "${DEFAULT_PARAMS}" == "${EDGE}" ]]; then
  ok "the DEFAULT path resolves byte-identically to --variant edge"
else
  bad "the DEFAULT path diverged from --variant edge"$'\n'"$(diff <(printf '%s\n' "${EDGE}") <(printf '%s\n' "${DEFAULT_PARAMS}") || true)"
fi

# The retired prebuilt vendor overlay used to be checked here: it was the one
# variant that had to resolve NO kernel_source at all, because it installed an
# Armbian .deb rather than compiling anything. That overlay is gone, and the check
# had to be rewritten rather than deleted — left as it was it would have passed
# VACUOUSLY, because an unknown variant makes the resolver die, `2>/dev/null`
# swallows the message, and grepping empty output for KERNEL_SOURCE always
# "succeeds". Two real properties replace it.

# (a) The retired name is REFUSED, loudly, and the refusal lists what IS declared.
if VENDOR_ERR="$(bash "${RESOLVE_SH}" rock-5b-plus --variant vendor 2>&1)"; then
  bad "the retired --variant vendor still resolves instead of being refused"
elif grep -q 'edge' <<<"${VENDOR_ERR}"; then
  ok "the retired --variant vendor is refused, and the error names the declared variants"
else
  bad "--variant vendor is refused but the error does not list the available variants: ${VENDOR_ERR}"
fi

# (b) The "no kernel_source => no KERNEL_SOURCE_* params" property still has a
#     real subject: x86-minipc declares no variants and no kernel_source at all.
X86_PARAMS="$(bash "${RESOLVE_SH}" x86-minipc 2>/dev/null)"
if [[ -z "${X86_PARAMS}" ]]; then
  bad "x86-minipc failed to resolve — the kernel_source-absence check would be vacuous"
elif grep -q 'KERNEL_SOURCE' <<<"${X86_PARAMS}"; then
  bad "a family with no kernel_source leaked a KERNEL_SOURCE_* param"
else
  ok "a family declaring no kernel_source resolves no KERNEL_SOURCE_* param at all"
fi

# --------------------------------------------------------------------------
# 4. Resolver refusals: unknown parent, self-reference, cycle, both fragment keys
# --------------------------------------------------------------------------

mutate_family() {
  local out="$1"; shift
  python3 - "${FAMILY}" "${out}" "$@" <<'PY'
import json, sys
import yaml

src, dst = sys.argv[1], sys.argv[2]
mutation = json.loads(sys.argv[3])
with open(src, encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
variants = data["variants"]
for name, overlay in mutation.items():
    node = variants.setdefault(name, {})
    for key, value in overlay.items():
        if value is None:
            node.pop(key, None)
        elif isinstance(value, dict) and isinstance(node.get(key), dict):
            for inner, inner_value in value.items():
                if inner_value is None:
                    node[key].pop(inner, None)
                else:
                    node[key][inner] = inner_value
        else:
            node[key] = value
with open(dst, "w", encoding="utf-8") as handle:
    yaml.safe_dump(data, handle, sort_keys=False)
PY
}

expect_reject() {
  local label="$1" family="$2" variant="$3" needle="$4" out
  out="$(merge_family "${family}" --variant "${variant}")"
  local rc=$?
  if (( rc != 0 )) && grep -qF "${needle}" <<<"${out}"; then
    ok "${label}"
  else
    bad "${label} (rc=${rc}, output: ${out})"
  fi
}

mutate_family "${WORK}/unknown-parent.yaml" \
  '{"edge-test": {"extends": "does-not-exist"}}'
expect_reject "resolver REJECTS an unknown parent" \
  "${WORK}/unknown-parent.yaml" edge-test "extends unknown variant"

mutate_family "${WORK}/self-reference.yaml" \
  '{"edge-test": {"extends": "edge-test"}}'
expect_reject "resolver REJECTS a self-referencing variant" \
  "${WORK}/self-reference.yaml" edge-test "extends itself"

mutate_family "${WORK}/cycle.yaml" \
  '{"edge-test": {"extends": "edge"}, "edge": {"extends": "edge-test"}}'
expect_reject "resolver REJECTS an extends cycle" \
  "${WORK}/cycle.yaml" edge-test "cycle"

mutate_family "${WORK}/default-parent.yaml" \
  '{"edge-test": {"extends": "default"}}'
expect_reject "resolver REJECTS extending the reserved 'default' name" \
  "${WORK}/default-parent.yaml" edge-test "reserved no-overlay name"

mutate_family "${WORK}/both-keys.yaml" \
  '{"edge-test": {"kernel_source": {"defconfig_fragment": "manifests/kernel/rk3588-edge.fragment"}}}'
expect_reject "schema REJECTS a variant declaring BOTH fragment keys" \
  "${WORK}/both-keys.yaml" edge-test "schema invalid"

# An `extends` child is schema-validated as a PARTIAL, so the COMPLETE
# kernel_source contract can only be re-asserted after inheritance. Deleting an
# inherited required pin must therefore still fail — otherwise `extends` would be
# a hole in the pin discipline rather than an expression of it.
mutate_family "${WORK}/lost-pin.yaml" \
  '{"edge": {"kernel_source": {"patches_commit": null}}}'
expect_reject "resolved child still requires every inherited pin" \
  "${WORK}/lost-pin.yaml" edge-test "patches_commit"

# A chain deeper than one level must resolve, so `extends` is inheritance and not
# a one-off special case for this variant.
mutate_family "${WORK}/chain.yaml" \
  '{"edge-test-deep": {"extends": "edge-test", "kernel_source": {"package_version": "7.2.0-ceralive1+test2"}}}'
CHAIN_OUT="$(merge_family "${WORK}/chain.yaml" --variant edge-test-deep)"
if grep -q "^KERNEL_SOURCE_PACKAGE_VERSION.7.2.0-ceralive1+test2$" <<<"${CHAIN_OUT}" \
   && grep -q "rk3588-edge-test.fragment" <<<"${CHAIN_OUT}" \
   && grep -q "^KERNEL_SOURCE_COMMIT.8d3ae59288f1e7d58d76558a6ee96d533bc5019f$" <<<"${CHAIN_OUT}"; then
  ok "a two-deep extends chain resolves grandparent pins and parent fragments"
else
  bad "a two-deep extends chain resolves grandparent pins and parent fragments"
fi

# --------------------------------------------------------------------------
# 5. The builder merges EVERY fragment, in order, before ONE gate
# --------------------------------------------------------------------------

BUILD_KERNEL="${PIPELINE_DIR}/lib/build-kernel.sh"

if grep -qE 'for frag in \$\{FRAGMENT_LIST\}' "${BUILD_KERNEL}"; then
  ok "build-kernel.sh merges every fragment in FRAGMENT_LIST order"
else
  bad "build-kernel.sh merges every fragment in FRAGMENT_LIST order"
fi

for one in 'make olddefconfig' 'make syncconfig' 'bash /in/verify-kernel-config.sh'; do
  n="$(grep -cF "${one}" "${BUILD_KERNEL}")"
  if [[ "${n}" -eq 1 ]]; then
    ok "exactly one '${one}' (both config modes still converge)"
  else
    bad "exactly one '${one}' (found ${n})"
  fi
done

# The survival gate must see EVERY declared fragment. Running it against the
# first file only would let a symbol olddefconfig drops from the debug fragment
# pass silently, which is the precise failure this gate exists to catch.
if grep -q 'declared_config=/src/declared-fragments.config' "${BUILD_KERNEL}"; then
  ok "the survival gate runs against the concatenation of all fragments"
else
  bad "the survival gate runs against the concatenation of all fragments"
fi

# Drive the real shipped resolution function for both spellings and for the
# both-declared refusal, using the module exactly as build-kernel.sh sources it.
drive_config_mode() {
  local frag_one="$1" frag_many="$2"
  bash -c '
    set -uo pipefail
    PIPELINE_DIR="'"${PIPELINE_DIR}"'"
    die() { printf "die: %s\n" "$*"; exit 1; }
    config_git_url=""; config_commit=""; config_path=""; absent_rel=""
    defconfig_base="defconfig"
    fragment_rel="'"${frag_one}"'"
    fragments_rel="'"${frag_many}"'"
    config_mode=""; config_desc=""; absent_list=""
    declare -a fragments=() fragments_rel_list=()
    source "'"${CONFIG_MOD}"'"
    resolve_kernel_config_mode || exit 1
    printf "%s\n" "${fragments_rel_list[*]}"
  ' 2>&1
}

OUT="$(drive_config_mode 'manifests/kernel/rk3588-edge.fragment' '')"
if [[ "${OUT}" == 'manifests/kernel/rk3588-edge.fragment' ]]; then
  ok "config module resolves the SINGULAR key to a one-element list"
else
  bad "config module resolves the SINGULAR key to a one-element list (got '${OUT}')"
fi

OUT="$(drive_config_mode '' 'manifests/kernel/rk3588-edge.fragment manifests/kernel/rk3588-edge-test.fragment')"
if [[ "${OUT}" == 'manifests/kernel/rk3588-edge.fragment manifests/kernel/rk3588-edge-test.fragment' ]]; then
  ok "config module resolves the PLURAL key in declared order"
else
  bad "config module resolves the PLURAL key in declared order (got '${OUT}')"
fi

OUT="$(drive_config_mode 'manifests/kernel/rk3588-edge.fragment' 'manifests/kernel/rk3588-edge-test.fragment')"
if grep -q 'declares BOTH defconfig_fragment' <<<"${OUT}"; then
  ok "config module REFUSES both fragment keys at once"
else
  bad "config module REFUSES both fragment keys at once (got '${OUT}')"
fi

OUT="$(drive_config_mode '' 'manifests/kernel/does-not-exist.fragment')"
if grep -q 'defconfig fragment not found' <<<"${OUT}"; then
  ok "config module fails loudly on a missing fragment in the list"
else
  bad "config module fails loudly on a missing fragment in the list (got '${OUT}')"
fi

# --------------------------------------------------------------------------
# 6. Production resolves the CeraLive test seam OFF
# --------------------------------------------------------------------------

PROD_FRAG="${PIPELINE_DIR}/manifests/kernel/rk3588-edge.fragment"
TEST_FRAG="${PIPELINE_DIR}/manifests/kernel/rk3588-edge-test.fragment"
FORBIDDEN="${PIPELINE_DIR}/manifests/kernel/forbidden-symbols.list"

CERALIVE_TEST_SEAM=(CONFIG_ROCKCHIP_MPP_CERALIVE_TEST)

for sym in "${CERALIVE_TEST_SEAM[@]}"
do
  if grep -qx "${sym}" "${FORBIDDEN}"; then
    ok "production forbids ${sym}"
  else
    bad "production forbids ${sym}"
  fi
  if grep -q "^${sym}=" "${PROD_FRAG}"; then
    bad "the production fragment does NOT mention ${sym}"
  else
    ok "the production fragment does NOT mention ${sym}"
  fi
  if grep -q "^${sym}=y\$" "${TEST_FRAG}"; then
    ok "the test fragment enables ${sym}"
  else
    bad "the test fragment enables ${sym}"
  fi
done

# The verifier is the thing production is actually gated by, so run it: a config
# that resolved a test symbol ON must FAIL, and one that left it off must pass.
VERIFY="${PIPELINE_DIR}/lib/verify-kernel-config.sh"

printf 'CONFIG_ARCH_ROCKCHIP=y\n# CONFIG_KASAN is not set\n' >"${WORK}/config-clean"
if bash "${VERIFY}" --config "${WORK}/config-clean" --forbidden "${FORBIDDEN}" >/dev/null 2>&1; then
  ok "verify-kernel-config --forbidden ACCEPTS a config with the test symbols off"
else
  bad "verify-kernel-config --forbidden ACCEPTS a config with the test symbols off"
fi

for sym in "${CERALIVE_TEST_SEAM[@]}"
do
  printf 'CONFIG_ARCH_ROCKCHIP=y\n%s=y\n' "${sym}" >"${WORK}/config-leaked"
  if bash "${VERIFY}" --config "${WORK}/config-leaked" --forbidden "${FORBIDDEN}" >/dev/null 2>&1; then
    bad "verify-kernel-config --forbidden REJECTS a config leaking ${sym}"
  else
    ok "verify-kernel-config --forbidden REJECTS a config leaking ${sym}"
  fi
done

# --------------------------------------------------------------------------
# 7. The release guard, both verdicts
# --------------------------------------------------------------------------

if bash "${GUARD}" --self-test >/dev/null 2>&1; then
  ok "release guard --self-test passes (both verdicts exercised)"
else
  bad "release guard --self-test passes (both verdicts exercised)"
fi

if bash "${GUARD}" --variant edge >/dev/null 2>&1; then
  ok "release guard ACCEPTS the production edge variant"
else
  bad "release guard ACCEPTS the production edge variant"
fi

if bash "${GUARD}" --variant edge-test >/dev/null 2>&1; then
  bad "release guard REJECTS the edge-test variant"
else
  ok "release guard REJECTS the edge-test variant"
fi

if bash "${GUARD}" >/dev/null 2>&1; then
  ok "release guard ACCEPTS the default production path"
else
  bad "release guard ACCEPTS the default production path"
fi

if CERALIVE_KERNEL_VARIANT=edge-test bash "${GUARD}" >/dev/null 2>&1; then
  bad "release guard reads CERALIVE_KERNEL_VARIANT when no flag is given"
else
  ok "release guard reads CERALIVE_KERNEL_VARIANT when no flag is given"
fi

RELEASE_YML="${PIPELINE_DIR}/.github/workflows/release.yml"
if grep -q 'check-release-variant.sh' "${RELEASE_YML}"; then
  ok "the release workflow runs the guard"
else
  bad "the release workflow runs the guard"
fi
if grep -q 'check-release-variant.sh --self-test' "${RELEASE_YML}"; then
  ok "the release workflow proves the guard is non-vacuous first"
else
  bad "the release workflow proves the guard is non-vacuous first"
fi

# The guard must be a property check, not a name blocklist — otherwise the next
# debug variant is unguarded on the day it is added.
if grep -vE 'verdict_for|^#' "${GUARD}" | grep -qE '(==|=~|case).*edge-test'; then
  bad "the release guard matches edge-test by NAME instead of by property"
else
  ok "the release guard decides by property, never by matching the edge-test name"
fi

# ...and the property is genuinely the shared forbidden list, so a symbol added
# there is guarded everywhere at once.
if grep -q 'forbidden-symbols.list' "${GUARD}"; then
  ok "the release guard reads the SAME forbidden-symbol list production is gated on"
else
  bad "the release guard reads the SAME forbidden-symbol list production is gated on"
fi

printf '\n== %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
