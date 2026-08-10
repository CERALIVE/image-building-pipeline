#!/usr/bin/env bash
#
# boot-state-core.test.sh — contract for the SHARED on-device A/B slot-state core
# (mkosi/platform/boot-state-core.sh) and the two thin persistence adapters.
#
# The platform suites (test-fallback.sh, test-x86-fallback.sh) already prove the
# happy rollback path on each backend. This suite covers what neither did before
# the extraction, and what the extraction itself now has to guarantee:
#
#   parity        — the shared core really is shared: every state verb is defined
#                   once, in the core, and each adapter supplies only persistence
#   equivalence   — the SAME command sequence yields the SAME slot decisions on
#                   BOTH backends, so a future edit cannot drift one platform
#   invalid slot  — every slot-taking verb refuses a slot that is not A or B
#   counters      — the budget boundaries: 0, the last attempt, exhaustion, the
#                   no-decrement last resort, and a counter above the budget
#   staging       — both adapters are installed together with their core

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
PLATFORM_DIR="${PIPELINE_DIR}/mkosi/platform"
CORE="${PLATFORM_DIR}/boot-state-core.sh"
RK_HELPER="${PLATFORM_DIR}/boot/ceralive-boot-state.sh"
X86_HELPER="${PLATFORM_DIR}/x86/x86-boot-state.sh"

PASS=0
fail() { printf 'boot-state-core: FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASS=$(( PASS + 1 )); printf 'boot-state-core: ok  %s\n' "$*"; }

for f in "${CORE}" "${RK_HELPER}" "${X86_HELPER}"; do
  [[ -f "${f}" ]] || fail "missing source file: ${f}"
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Both adapters are driven through the same wrapper so every leg below can be run
# against either backend without knowing which one it is talking to.
rk()  { CERALIVE_BOOT_STATE_FILE="${WORK}/rk/boot_state.txt" CERALIVE_BOOT_ATTEMPTS=3 \
          bash "${RK_HELPER}" "$@"; }
x86() { CERALIVE_GRUBENV="${WORK}/x86/grubenv" CERALIVE_BOOT_ATTEMPTS=3 \
          GRUB_EDITENV=/nonexistent-grub-editenv bash "${X86_HELPER}" "$@"; }
reset_backends() { rm -rf "${WORK}/rk" "${WORK}/x86"; mkdir -p "${WORK}/rk" "${WORK}/x86"; }

# ---------------------------------------------------------------------------
# Parity — one definition of every state verb, in the core
# ---------------------------------------------------------------------------
CORE_VERBS=(
  slot_partlabel is_valid_slot left_of set_left in_order
  cmd_init cmd_get_order cmd_get_left cmd_get_primary cmd_set_primary
  cmd_get_state cmd_set_state cmd_mark_good cmd_boot_select cmd_dump
  boot_state_main
)
for fn in "${CORE_VERBS[@]}"; do
  grep -q "^${fn}() {" "${CORE}" || fail "${fn} is not defined in the shared core"
  for adapter in "${RK_HELPER}" "${X86_HELPER}"; do
    if grep -q "^${fn}() {" "${adapter}"; then
      fail "${fn} is re-defined in $(basename "${adapter}") — the core is no longer shared"
    fi
  done
done
ok "parity: every slot-state verb is defined once, in the shared core"

# Each adapter must supply exactly the persistence seam the core declares, and
# nothing more — that is what keeps "platform-specific" honest.
ADAPTER_HOOKS=(load_state store_state boot_state_dump_backend boot_state_usage)
for adapter in "${RK_HELPER}" "${X86_HELPER}"; do
  for fn in "${ADAPTER_HOOKS[@]}"; do
    grep -q "^${fn}() {" "${adapter}" \
      || fail "$(basename "${adapter}") does not define the ${fn} persistence hook"
  done
  grep -q 'boot_state_main "\$@"' "${adapter}" \
    || fail "$(basename "${adapter}") does not dispatch through the shared core"
done
ok "parity: both adapters define the four persistence hooks and dispatch to the core"

# ---------------------------------------------------------------------------
# Cross-backend equivalence — the same script, the same decisions
# ---------------------------------------------------------------------------
run_sequence() {
  local backend="$1"
  "${backend}" init
  printf 'order=%s\n'   "$("${backend}" get-order)"
  printf 'primary=%s\n' "$("${backend}" get-primary)"
  printf 'select=%s\n'  "$("${backend}" boot-select)"
  printf 'leftA=%s\n'   "$("${backend}" get-left A)"
  "${backend}" mark-good A
  printf 'leftA-after-good=%s\n' "$("${backend}" get-left A)"
  "${backend}" set-primary B
  printf 'order-after-setprimary=%s\n' "$("${backend}" get-order)"
  printf 'select=%s\n' "$("${backend}" boot-select)"
  printf 'select=%s\n' "$("${backend}" boot-select)"
  printf 'select=%s\n' "$("${backend}" boot-select)"
  printf 'stateB=%s\n' "$("${backend}" get-state B)"
  printf 'rollover=%s\n' "$("${backend}" boot-select)"
  printf 'primary=%s\n'  "$("${backend}" get-primary)"
}
reset_backends
run_sequence rk  >"${WORK}/rk.seq"
run_sequence x86 >"${WORK}/x86.seq"
diff -u "${WORK}/rk.seq" "${WORK}/x86.seq" >"${WORK}/seq.diff" \
  || fail "the two backends disagree on the shared sequence:"$'\n'"$(cat "${WORK}/seq.diff")"
grep -q 'rollover=A rootfs_a' "${WORK}/rk.seq" \
  || fail "an exhausted B did not roll over to A (non-vacuity):"$'\n'"$(cat "${WORK}/rk.seq")"
ok "equivalence: RK3588 and x86 produce byte-identical decisions for one sequence"

# ---------------------------------------------------------------------------
# Invalid slot state
# ---------------------------------------------------------------------------
reset_backends
rk init >/dev/null; x86 init >/dev/null
for backend in rk x86; do
  for verb in "get-left" "get-state" "set-primary"; do
    if "${backend}" "${verb}" C >/dev/null 2>&1; then
      fail "${backend} ${verb} accepted slot 'C'"
    fi
    if "${backend}" "${verb}" a >/dev/null 2>&1; then
      fail "${backend} ${verb} accepted lowercase slot 'a' (slot names are exact)"
    fi
    if "${backend}" "${verb}" "" >/dev/null 2>&1; then
      fail "${backend} ${verb} accepted an empty slot"
    fi
  done
  if "${backend}" set-state A maybe >/dev/null 2>&1; then
    fail "${backend} set-state accepted a state that is neither good nor bad"
  fi
  if "${backend}" set-state Z bad >/dev/null 2>&1; then
    fail "${backend} set-state accepted an invalid slot"
  fi
  if "${backend}" mark-good Q >/dev/null 2>&1; then
    fail "${backend} mark-good accepted an invalid slot"
  fi
  if "${backend}" not-a-command >/dev/null 2>&1; then
    fail "${backend} accepted an unknown command"
  fi
  if "${backend}" init --attempts nope >/dev/null 2>&1; then
    fail "${backend} init accepted a non-numeric attempt budget"
  fi
  if "${backend}" init --bogus >/dev/null 2>&1; then
    fail "${backend} init accepted an unknown argument"
  fi
done
ok "invalid: every slot-taking verb refuses a slot outside {A,B}, on both backends"

# A slot name that is not A or B must never resolve to a rootfs PARTLABEL — this
# is the leg that stops a typo becoming a boot argument.
if bash -c '
  set -euo pipefail
  BOOT_STATE_TOOL=probe BOOT_ATTEMPTS=3 BOOT_STATE_KEEP_LAST_SLOT=1
  load_state() { :; }; store_state() { :; }
  boot_state_dump_backend() { :; }; boot_state_usage() { :; }
  # shellcheck disable=SC1090
  source "$1"
  slot_partlabel C
' _ "${CORE}" >/dev/null 2>&1; then
  fail "slot_partlabel resolved a PARTLABEL for an invalid slot"
fi
ok "invalid: slot_partlabel refuses to invent a PARTLABEL for an unknown slot"

# ---------------------------------------------------------------------------
# Counter boundaries
# ---------------------------------------------------------------------------
reset_backends
for backend in rk x86; do
  # A zero budget: the slot is bad from the start and boot-select must take the
  # last-resort branch WITHOUT decrementing below zero.
  "${backend}" init --attempts 0 >/dev/null
  [[ "$("${backend}" get-left A)" == "0" ]] \
    || fail "${backend}: --attempts 0 did not leave slot A at 0"
  [[ "$("${backend}" get-state A)" == "bad" ]] \
    || fail "${backend}: a zero-budget slot is not reported bad"
  [[ "$("${backend}" boot-select)" == "A rootfs_a" ]] \
    || fail "${backend}: an all-exhausted state did not last-resort boot the head of BOOT_ORDER"
  [[ "$("${backend}" get-left A)" == "0" ]] \
    || fail "${backend}: the last-resort boot decremented a counter that was already 0"
  [[ "$("${backend}" get-primary)" == "A" ]] \
    || fail "${backend}: get-primary disagreed with boot-select on the last-resort slot"
done
ok "counters: a zero budget is bad, last-resort boots the head, and never goes negative"

reset_backends
for backend in rk x86; do
  # A budget of exactly 1: one attempt, then the slot is bad and B takes over.
  "${backend}" init --attempts 1 >/dev/null
  [[ "$("${backend}" boot-select)" == "A rootfs_a" ]] || fail "${backend}: attempt 1 did not pick A"
  [[ "$("${backend}" get-left A)" == "0" ]] || fail "${backend}: the single attempt was not spent"
  [[ "$("${backend}" get-state A)" == "bad" ]] || fail "${backend}: a spent slot is not bad"
  [[ "$("${backend}" boot-select)" == "B rootfs_b" ]] \
    || fail "${backend}: the boot after A's last attempt did not fall through to B"
done
ok "counters: the last attempt is spent exactly once, then the other slot takes over"

reset_backends
for backend in rk x86; do
  # mark-good must restore the FULL budget from any point, including 0.
  "${backend}" init --attempts 3 >/dev/null
  "${backend}" boot-select >/dev/null
  "${backend}" boot-select >/dev/null
  "${backend}" boot-select >/dev/null
  [[ "$("${backend}" get-left A)" == "0" ]] || fail "${backend}: three boots did not exhaust a 3-attempt budget"
  "${backend}" mark-good A
  [[ "$("${backend}" get-left A)" == "3" ]] \
    || fail "${backend}: mark-good did not restore the full budget from 0"
  [[ "$("${backend}" get-state A)" == "good" ]] \
    || fail "${backend}: a re-marked slot is not good again"
done
ok "counters: 3->2->1->0 exhausts the budget and mark-good restores it from zero"

# An out-of-budget counter is stale/corrupt state. The RK backend's CRC-guarded
# reader must heal it back to the safe defaults rather than honour it.
reset_backends
rk init >/dev/null
printf 'BOOT_ORDER=A B\nBOOT_A_LEFT=99\nBOOT_B_LEFT=3\n' >"${WORK}/rk/boot_state.txt"
[[ "$(rk get-left A)" == "3" ]] \
  || fail "an above-budget counter was honoured instead of healed (got $(rk get-left A))"
printf 'BOOT_ORDER=A A\nBOOT_A_LEFT=3\nBOOT_B_LEFT=3\n' >"${WORK}/rk/boot_state.txt"
[[ "$(rk get-order)" == "A B" ]] \
  || fail "a duplicated slot in BOOT_ORDER was honoured instead of healed"
printf 'BOOT_ORDER=A B\nBOOT_A_LEFT=x\nBOOT_B_LEFT=3\n' >"${WORK}/rk/boot_state.txt"
[[ "$(rk get-left A)" == "3" ]] \
  || fail "a non-numeric counter was honoured instead of healed"
ok "counters: an above-budget, duplicated or non-numeric state heals to the safe defaults"

# ---------------------------------------------------------------------------
# Staging — the core must land in BOTH images beside its adapter
# ---------------------------------------------------------------------------
rkroot="${WORK}/rkroot"
env ROOT="${rkroot}" SERIAL_CONSOLE=ttyS2:1500000 DTB_NAME=rk3588-rock-5b-plus.dtb \
  BOARD_ID=rock-5b-plus COMPATIBLE_STRING=ceralive-rock-5b-plus SINGLE_SLOT_FALLBACK=false \
  bash "${PLATFORM_DIR}/boot/install-boot.sh" rootfs >/dev/null 2>&1 \
  || fail "install-boot.sh rootfs failed"
[[ -f "${rkroot}/usr/lib/ceralive/boot-state-core.sh" ]] \
  || fail "the RK3588 rootfs does not carry the shared boot-state core"
[[ -x "${rkroot}/usr/bin/ceralive-boot-state" ]] \
  || fail "the RK3588 rootfs does not carry the state helper"

x86root="${WORK}/x86root"
env ROOT="${x86root}" SERIAL_CONSOLE=ttyS0:115200 FAMILY=x86_64 \
  COMPATIBLE_STRING=ceralive-x86-minipc SINGLE_SLOT_FALLBACK=false \
  bash "${PLATFORM_DIR}/x86/install-x86-boot.sh" rootfs >/dev/null 2>&1 \
  || fail "install-x86-boot.sh rootfs failed"
[[ -f "${x86root}/usr/lib/ceralive/boot-state-core.sh" ]] \
  || fail "the x86 rootfs does not carry the shared boot-state core"
[[ -x "${x86root}/usr/bin/ceralive-boot-state" ]] \
  || fail "the x86 rootfs does not carry the state helper"

cmp -s "${rkroot}/usr/lib/ceralive/boot-state-core.sh" \
       "${x86root}/usr/lib/ceralive/boot-state-core.sh" \
  || fail "the two images staged DIFFERENT boot-state cores"
cmp -s "${CORE}" "${rkroot}/usr/lib/ceralive/boot-state-core.sh" \
  || fail "the staged core is not the repo's core"
ok "staging: both images carry the identical shared core beside their adapter"

# The installed helper must work from its DEVICE layout, resolving the core from
# /usr/lib/ceralive rather than from a repo-relative sibling path.
staged_state="${WORK}/staged-state.txt"
CERALIVE_BOOT_STATE_FILE="${staged_state}" CERALIVE_BOOT_ATTEMPTS=3 \
  CERALIVE_BOOT_STATE_CORE="${rkroot}/usr/lib/ceralive/boot-state-core.sh" \
  bash "${rkroot}/usr/bin/ceralive-boot-state" init >/dev/null \
  || fail "the staged RK3588 helper could not run against its staged core"
[[ "$(CERALIVE_BOOT_STATE_FILE="${staged_state}" CERALIVE_BOOT_ATTEMPTS=3 \
      CERALIVE_BOOT_STATE_CORE="${rkroot}/usr/lib/ceralive/boot-state-core.sh" \
      bash "${rkroot}/usr/bin/ceralive-boot-state" get-order)" == "A B" ]] \
  || fail "the staged RK3588 helper did not seed a fresh A/B order"
ok "staging: the installed helper runs against the installed core"

# A helper that cannot find its core must say so and exit non-zero — never run on
# a half-defined state machine.
if CERALIVE_BOOT_STATE_CORE="${WORK}/no-such-core.sh" \
   bash "${RK_HELPER}" get-order >"${WORK}/nocore.out" 2>&1; then
  fail "the helper ran with no shared core available"
fi
grep -q 'boot-state core not found' "${WORK}/nocore.out" \
  || fail "a missing core was not reported: $(cat "${WORK}/nocore.out")"
ok "staging: a missing core is a loud, non-zero refusal"

printf '\nboot-state-core: %d checks passed\n' "${PASS}"
