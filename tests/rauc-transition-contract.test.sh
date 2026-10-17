#!/usr/bin/env bash
#
# rauc-transition-contract.test.sh — preserve board identity, PKI, and all six
# config writers while moving the OS and rotation producers to RAUC verity.
#
# PROFILE: contract-test (docs/shell-profiles.md).
# shellcheck shell=bash
# shellcheck disable=SC2016 # needles intentionally match unexpanded source text

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"

BUNDLE="${PIPELINE_DIR}/lib/build-bundle.sh"
INSTALL_BOOT="${PIPELINE_DIR}/mkosi/platform/boot/install-boot.sh"
SYSTEM_CONF="${PIPELINE_DIR}/mkosi/runtime/rauc/system.conf"
RAUC_SETUP="${PIPELINE_DIR}/mkosi/customize/rauc-setup.sh"

has() {
  local desc="$1" file="$2" needle="$3"
  if grep -qF -- "${needle}" "${file}"; then ok "${desc}"
  else bad "${desc}: '${needle}' not found in ${file#"${PIPELINE_DIR}"/}"; fi
}

lacks_active_key() {
  local desc="$1" file="$2" key="$3"
  if awk -v key="${key}" \
    '$0 !~ /^[[:space:]]*(#|$)/ && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { found=1; exit } END { exit !found }' \
    "${file}"; then
    bad "${desc}: active ${key}= found in ${file#"${PIPELINE_DIR}"/}"
  else
    ok "${desc}"
  fi
}

check_system_conf_writers() {
  local -a writers=()
  local file name key
  mapfile -t writers < <(GIT_MASTER=1 git -C "${PIPELINE_DIR}" grep -lE \
    '^[[:space:]]*bootloader=(custom|grub)[[:space:]]*$' -- mkosi lib |
    awk -v root="${PIPELINE_DIR}" '/\.(sh|conf|chroot)$/ {print root "/" $0}' | sort)
  if (( ${#writers[@]} >= 5 )); then
    ok "discovered ${#writers[@]} system.conf writers (minimum 5)"
  else
    bad "discovered only ${#writers[@]} system.conf writers (minimum 5)"
  fi
  for file in "${writers[@]}"; do
    name="${file#"${PIPELINE_DIR}"/}"
    for key in 'data-directory=/data/ceralive/rauc' 'activate-installed=false' \
      '[streaming]' 'sandbox-user=ceralive-ota' 'send-headers=boot-id;transaction-id' \
      'post-install=/usr/lib/rauc/ceralive-post-install'; do
      has "${name} configures ${key}" "${file}" "${key}"
    done
    lacks_active_key "${name} does not retroactively reject installed legacy bundles" "${file}" 'bundle-formats'
    if grep -Eq '^[[:space:]]*sandbox-user[[:space:]]*=[[:space:]]*nobody[[:space:]]*$' "${file}"; then
      bad "${name} uses nobody for streaming"
    else
      ok "${name} never uses nobody for streaming"
    fi
    for key in '[slot.rootfs.0]' '[slot.rootfs.1]' '[slot.certs.0]' \
      'device=/data/ceralive/certs/.rauc-certs-slot' 'type=raw'; do
      has "${name} declares ${key}" "${file}" "${key}"
    done
    if grep -Eq '^[[:space:]]*bootloader=custom[[:space:]]*$' "${file}"; then
      lacks_active_key "${name} custom backend owns boot attempts" "${file}" 'boot-attempts'
    fi
    lacks_active_key "${name} does not persist ForceIPv4" "${file}" 'Acquire::ForceIPv4'
  done
}

transition_contract_check() {
  local bundle="$1" install_boot="$2" system_conf="$3" rauc_setup="$4"
  local failures_before="${FAIL}"

  has "bundle manifest explicitly pins the verity format" \
    "${bundle}" 'format=verity'
  has "bundle manifest requires adaptive blocks" "${bundle}" 'adaptive=block-hash-index'
  has "bundle manifest carries full-slot ext4" "${bundle}" 'filename=rootfs.ext4'
  has "bundle manifest copies the resolved compatible byte-for-byte" \
    "${bundle}" 'compatible=${compatible}'
  has "bundle compatible comes from COMPATIBLE_STRING with no guessed value" \
    "${bundle}" 'compatible="${COMPATIBLE_STRING:-}"'
  has "on-device arm64 system.conf copies that same resolved compatible" \
    "${install_boot}" 'compatible=${COMPATIBLE}'
  has "arm64 installer reads COMPATIBLE_STRING verbatim" \
    "${install_boot}" 'COMPATIBLE="${COMPATIBLE_STRING:-}"'
  has "fallback system.conf retains the compatible substitution token" \
    "${system_conf}" 'compatible=@COMPATIBLE_STRING@'
  lacks_active_key "fleet system.conf does not retroactively exclude plain bundles" \
    "${system_conf}" 'bundle-formats'
  lacks_active_key "verification purpose stays unchanged across the transition" \
    "${system_conf}" 'check-purpose'
  lacks_active_key "RK3588 custom generator leaves attempt counting to its backend" \
    "${install_boot}" 'boot-attempts'
  lacks_active_key "committed custom fallback leaves attempt counting to its backend" \
    "${system_conf}" 'boot-attempts'
  lacks_active_key "self-contained custom fallback leaves attempt counting to its backend" \
    "${rauc_setup}" 'boot-attempts'
  has "bundle signer remains the leaf key" "${bundle}" '--key="${RAUC_LEAF_KEY}"'
  has "bundle embeds the existing intermediate chain" "${bundle}" '--intermediate="${RAUC_CHAIN}"'
  has "bundle verifies to the existing baked root" "${bundle}" 'RAUC_ROOT_CA="${RAUC_PKI_DIR}/root-ca.pem"'

  (( FAIL == failures_before ))
}

echo "== first-Trixie bundle contract =="
transition_contract_check "${BUNDLE}" "${INSTALL_BOOT}" "${SYSTEM_CONF}" "${RAUC_SETUP}"
echo "== all system.conf writers =="
check_system_conf_writers

if bash -s "${PIPELINE_DIR}/tests/real-rauc-contract.sh" <<'SH'
set -euo pipefail
harness="$1"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
WORK="$work"
priority_dir="$work/dev/disk/by-partlabel"
priority_link="$priority_dir/ceralive-rauc-fixture"
priority_parent_created=0
priority_dir_created=0
priority_link_owned=0
priority_cmdline_mounted=0
sudo() { [[ "$1" == -n ]] && shift; "$@"; }
source <(awk '
  /^(create_priority_partlabel|remove_priority_fixture)\(\) \{/ { copying=1 }
  copying { print }
  copying && /^}$/ { copying=0 }
' "$harness")
test -s "$harness"
touch "$work/slot-b.ext4"

create_priority_partlabel
test "$(readlink -e "$priority_link")" = "$work/slot-b.ext4"
remove_priority_fixture
test ! -e "$priority_dir" && test ! -e "${priority_dir%/*}"

mkdir -p "$priority_dir"
ln -s "$work/slot-b.ext4" "$priority_dir/rootfs_b"
create_priority_partlabel
remove_priority_fixture
test -d "$priority_dir" && test -L "$priority_dir/rootfs_b"

ln -s "$work/slot-b.ext4" "$priority_link"
if create_priority_partlabel; then
  exit 1
fi
test "$(readlink "$priority_link")" = "$work/slot-b.ext4"
SH
then
  ok 'real RAUC priority fixture creates only a unique link and cleans only owned paths'
else
  bad 'real RAUC priority fixture clobbered a pre-existing link or left created directories'
fi

if python3 - "${PIPELINE_DIR}" <<'PY'
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

import yaml

repo = Path(sys.argv[1])
workflow = yaml.safe_load((repo / '.github/workflows/v2-ci.yml').read_text())
steps = workflow['jobs']['bats']['steps']
step = next(item['run'] for item in steps if item.get('id') == 'rauc-pin')
pin = (repo / 'manifests/rauc-deb-versions.txt').read_text()

with tempfile.TemporaryDirectory() as scratch:
    root = Path(scratch)
    (root / 'manifests').mkdir()
    output = root / 'github-output'

    def invoke(text):
        (root / 'manifests/rauc-deb-versions.txt').write_text(text)
        output.write_text('')
        result = subprocess.run(['bash', '-c', step], cwd=root, text=True,
                                capture_output=True, env={**os.environ, 'GITHUB_OUTPUT': str(output)},
                                check=False)
        return result, output.read_text()

    good, actual = invoke(pin)
    assert good.returncode == 0 and 'version=' in actual and 'sha256=' in actual and 'url=' in actual, (good, actual)
    for field, replacement in (
        ('UPSTREAM_VERSION', 'not-a-version'),
        ('UPSTREAM_SHA256', 'abcdef'),
        ('UPSTREAM_URL', 'https://example.invalid/rauc.tar.xz'),
    ):
        altered, count = re.subn(rf'^{field}=.*$', f'{field}={replacement}', pin, count=1, flags=re.M)
        assert count == 1, field
        bad_run, contents = invoke(altered)
        assert bad_run.returncode != 0 and contents == '' and '::error::' in bad_run.stdout + bad_run.stderr, (
            f'{field} failed without a diagnostic', bad_run, contents)
print('RAUC CI pin step: valid pin emits outputs; malformed version, digest and URL fail with ::error::')
PY
then
  ok 'RAUC CI pin step rejects malformed inputs with actionable errors'
else
  bad 'RAUC CI pin step failed its good/malformed fixture matrix'
fi

echo
echo "== mutation controls =="
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
cp "${BUNDLE}" "${scratch}/build-bundle.sh"
cp "${INSTALL_BOOT}" "${scratch}/install-boot.sh"
cp "${SYSTEM_CONF}" "${scratch}/system.conf"
cp "${RAUC_SETUP}" "${scratch}/rauc-setup.sh"

sed -i 's/format=verity/format=plain/' "${scratch}/build-bundle.sh"
saved_fail="${FAIL}"
transition_contract_check "${scratch}/build-bundle.sh" "${scratch}/install-boot.sh" "${scratch}/system.conf" "${scratch}/rauc-setup.sh" >/dev/null 2>&1
if (( FAIL > saved_fail )); then
  ok "mutation: a plain-format OS bundle is rejected"
  FAIL="${saved_fail}"
else
  bad "mutation: format=plain escaped the verity gate"
fi

cp "${BUNDLE}" "${scratch}/build-bundle.sh"
sed -i 's/compatible=${compatible}/compatible=ceralive-wrong-board/' "${scratch}/build-bundle.sh"
saved_fail="${FAIL}"
transition_contract_check "${scratch}/build-bundle.sh" "${scratch}/install-boot.sh" "${scratch}/system.conf" "${scratch}/rauc-setup.sh" >/dev/null 2>&1
if (( FAIL > saved_fail )); then
  ok "mutation: a hardcoded incompatible board identity is rejected"
  FAIL="${saved_fail}"
else
  bad "mutation: a hardcoded compatible escaped the transition gate"
fi

cp "${BUNDLE}" "${scratch}/build-bundle.sh"
cp "${INSTALL_BOOT}" "${scratch}/install-boot.sh"
sed -i '/bootloader=custom/a boot-attempts=3' "${scratch}/install-boot.sh"
saved_fail="${FAIL}"
transition_contract_check "${scratch}/build-bundle.sh" "${scratch}/install-boot.sh" "${scratch}/system.conf" "${scratch}/rauc-setup.sh" >/dev/null 2>&1
if (( FAIL > saved_fail )); then
  ok "mutation: RAUC-native boot attempts cannot return to the custom generator"
  FAIL="${saved_fail}"
else
  bad "mutation: boot-attempts escaped the custom-backend gate"
fi

large_conf="${scratch}/large-system.conf"
awk 'BEGIN { print "[system]\nbootloader=custom\nboot-attempts=3"; for (i=0; i<20000; i++) print "filler_" i "=value" }' >"${large_conf}"
saved_fail="${FAIL}"
lacks_active_key "expanded custom config leaves attempt counting to its backend" \
  "${large_conf}" 'boot-attempts' >/dev/null 2>&1
if (( FAIL > saved_fail )); then
  ok "mutation: boot-attempts is rejected under producer backpressure"
  FAIL="${saved_fail}"
else
  bad "mutation: boot-attempts escaped under producer backpressure"
fi

cp "${SYSTEM_CONF}" "${scratch}/nobody.conf"
sed -i 's/^sandbox-user=ceralive-ota$/sandbox-user=nobody/' "${scratch}/nobody.conf"
saved_fail="${FAIL}"
if grep -Eq '^sandbox-user=nobody$' "${scratch}/nobody.conf"; then
  bad "sandbox-user=nobody is forbidden"
fi
if (( FAIL > saved_fail )); then
  ok "mutation: sandbox-user=nobody rejected by policy"
  FAIL="${saved_fail}"
else
  bad "mutation: sandbox-user=nobody escaped policy"
fi

echo
if (( FAIL == 0 )); then
  echo "rauc transition contract: PASS (${PASS} assertions)"
  exit 0
fi
echo "rauc transition contract: FAIL (${FAIL} failure(s), ${PASS} pass(es))" >&2
exit 1
