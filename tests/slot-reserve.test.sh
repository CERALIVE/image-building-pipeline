#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
source "${HERE}/lib/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
LIB="${REPO}/lib/shared/slot-reserve.sh"
[[ -f "${LIB}" ]] || { bad 'shared slot reserve assertion absent'; exit 1; }
source "${REPO}/lib/shared/slot-reserve.sh"
for slot in rootfs_a rootfs_b; do
  if slot_reserve_assert_values "${slot}" 536870912 200000 20000 >"${WORK}/exact" 2>&1; then ok "${slot} exact byte/inode boundary passes"; else bad 'exact boundary rejected'; fi
  if slot_reserve_assert_values "${slot}" 536870911 200000 20000 >"${WORK}/under" 2>&1; then bad 'one-byte-under accepted'; else ok "${slot} one-byte-under RED"; fi
  assert_contains 'diagnostic names slot' "${WORK}/under" "slot=${slot}"
  assert_contains 'diagnostic explicitly chooses bavail' "${WORK}/under" 'field=bavail'
  assert_contains 'diagnostic names measured free bytes' "${WORK}/under" 'free=536870911'
  assert_contains 'diagnostic names required bytes' "${WORK}/under" 'required=536870912'
  if slot_reserve_assert_values "${slot}" 536870912 200000 20000 >/dev/null 2>&1; then ok 'boundary restored GREEN'; else bad 'restored boundary rejected'; fi
done
for values in '536870912 200000 19999' '536870912 200001 20000' '536870912 300000 29999' 'invalid 200000 20000' '-1 200000 20000'; do
  read -r bytes total free <<<"${values}"
  if slot_reserve_assert_values rootfs_b "${bytes}" "${total}" "${free}" >"${WORK}/inodes" 2>&1; then bad "accepted ${values}"; else ok "refused ${values}"; fi
done
if slot_reserve_assert_values rootfs_a 536870912 200001 20001 >/dev/null 2>&1; then ok '10 percent rounds UP'; else bad 'ceil inode boundary rejected'; fi
# Given a populated ext4 image, use actual metadata, not its compressed length.
mkdir "${WORK}/tree"; printf 'payload\n' >"${WORK}/tree/file"
truncate -s 1G "${WORK}/slot"
mkfs.ext4 -q -F -d "${WORK}/tree" "${WORK}/slot" || exit 1
if slot_reserve_assert_ext4 "${WORK}/slot" rootfs_a >"${WORK}/metadata" 2>&1; then ok 'real populated ext4 reserve passes'; else bad "$(<"${WORK}/metadata")"; fi
if bash "${REPO}/lib/verify-disk.sh" check-slot "${WORK}/slot" rootfs_a >/dev/null 2>&1; then ok 'disk verifier runs shared slot assertion'; else bad 'disk verifier rejects valid slot'; fi
# When root-reserved blocks consume the reserve, bfree would falsely pass.
tune2fs -r 120000 "${WORK}/slot" >/dev/null 2>&1 || exit 1
if slot_reserve_assert_ext4 "${WORK}/slot" rootfs_b >"${WORK}/reserved" 2>&1; then bad 'reserved blocks counted available'; else ok 'reserved-block mutation RED'; fi
if bash "${REPO}/lib/verify-disk.sh" check-slot "${WORK}/slot" rootfs_b >/dev/null 2>&1; then bad 'disk verifier accepts low reserve'; else ok 'disk verifier rejects low reserve'; fi
assert_contains 'metadata diagnostic chooses bavail' "${WORK}/reserved" 'field=bavail'
tune2fs -m 5 "${WORK}/slot" >/dev/null 2>&1 || exit 1
if slot_reserve_assert_ext4 "${WORK}/slot" rootfs_b >/dev/null 2>&1; then ok 'real metadata mutation restored GREEN'; else bad 'restored metadata rejected'; fi
assert_contains 'producer gates both mkfs paths before dd' "${REPO}/lib/disk/slot.sh" "slot_reserve_assert_ext4 \"\${rootfs_img}\" \"\${slot_label}\""
assert_contains 'disk verifier exposes shared assertion' "${REPO}/lib/verify-disk.sh" 'shared/slot-reserve.sh'
assert_contains 'preflash checks sliced slot' "${REPO}/tests/preflash-verify.sh" "slot_reserve_assert_ext4 \"\${tmp}\" \"\${label}\""
printf '%s passed, %s failed\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
