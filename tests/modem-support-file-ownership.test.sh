#!/usr/bin/env bash
#
# modem-support-file-ownership.test.sh — every modem-support file in an emitted
# rootfs is owned by EXACTLY ONE producer.
#
# Two failure modes, both of which produce a rootfs that boots and passes every
# other gate:
#
#   ORPHAN            a path that looks packaged but no installed .deb claims it.
#                     dpkg will not upgrade, verify or remove it, so it survives
#                     forever at whatever content the build happened to leave.
#   DOUBLE OWNERSHIP  two producers claim one path. On dpkg that is last-unpack-
#                     wins; between the image and a package it is whichever ran
#                     last in the layer chain, which is a build-order accident.
#
# The subject is the emitted rootfs when one is available (CERALIVE_ROOTFS_DIR,
# or the default mkosi/build/app), and otherwise the manifest-level equivalent:
# the ledger's own structure plus fixture rootfs trees carrying real dpkg file
# lists. Both directions drive the SHIPPED functions in
# lib/shared/modem-support-lib.sh, which is what lib/parity-check.sh §E runs on a
# real build — so this suite and the build gate can never disagree.
#
# Profile: contract-test (docs/shell-profiles.md) — collect, then own the exit code.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"

# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"
# shellcheck source=lib/shared/modem-support-lib.sh
source "${PIPELINE_DIR}/lib/shared/modem-support-lib.sh"

LEDGER="${PIPELINE_DIR}/manifests/modem-support-ownership.txt"
PARITY="${PIPELINE_DIR}/lib/parity-check.sh"
FETCH_DEBS="${PIPELINE_DIR}/lib/fetch-debs.sh"
APP_POSTINST="${PIPELINE_DIR}/mkosi/mkosi.images/app/mkosi.postinst.chroot"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/modem-support-ownership.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# seed_rootfs <dir> — a rootfs carrying every ledger path plus the dpkg file list
# that claims the packaged ones, i.e. the shape a correct build emits.
seed_rootfs() {
  local root="$1" owner path
  mkdir -p "${root}/var/lib/dpkg/info"
  : >"${root}/var/lib/dpkg/info/${MODEM_SUPPORT_OWNER_PACKAGE}.list"
  while IFS=$'\t' read -r owner path; do
    [[ -n "${owner}" && -n "${path}" ]] || continue
    mkdir -p "${root}$(dirname "${path}")"
    printf '# fixture\n' >"${root}${path}"
    if [[ "${owner}" == "${MODEM_SUPPORT_OWNER_PACKAGE}" ]]; then
      printf '%s\n' "${path}" >>"${root}/var/lib/dpkg/info/${MODEM_SUPPORT_OWNER_PACKAGE}.list"
    fi
  done < <(modem_support_ledger_rows "${LEDGER}")
}

echo "== modem-support file ownership =="

# --- 1. the ledger itself is structurally sound ------------------------------
if ledger_out="$(modem_support_ledger_violations "${LEDGER}")"; then
  ok "ownership ledger is structurally valid (unique paths, closed owner vocabulary, correct tiers)"
else
  bad "ownership ledger violations: ${ledger_out}"
fi

declared_rows="$(modem_support_ledger_rows "${LEDGER}" | grep -c .)"
if [[ "${declared_rows}" -ge 2 ]]; then
  ok "ownership ledger declares ${declared_rows} paths"
else
  bad "ownership ledger declares ${declared_rows} paths — too few for the checks to mean anything"
fi

# --- 2. the companion is actually consumed, or the ledger describes nothing ---
# An ownership ledger for a package the image never fetches or installs is a
# document, not a gate. Both surfaces are asserted so this file fails if either
# one is reverted.
if bash -c 'source "$1" >/dev/null 2>&1 || true; printf "%s\n" "${FIRST_PARTY_APT_PKGS[@]}"' _ "${FETCH_DEBS}" \
    | grep -qxF "${MODEM_SUPPORT_OWNER_PACKAGE}"; then
  ok "${MODEM_SUPPORT_OWNER_PACKAGE} is fetched (FIRST_PARTY_APT_PKGS)"
else
  bad "${MODEM_SUPPORT_OWNER_PACKAGE} is absent from FIRST_PARTY_APT_PKGS — nothing would stage it"
fi
if grep -qF "${MODEM_SUPPORT_OWNER_PACKAGE}" "${APP_POSTINST}"; then
  ok "${MODEM_SUPPORT_OWNER_PACKAGE} is classified by the app layer (RUNTIME_APP_PKGS)"
else
  bad "${MODEM_SUPPORT_OWNER_PACKAGE} is unclassified in the app postinst — it would be fetched and never installed"
fi

# --- 3. POSITIVE: a correctly built rootfs has unique ownership throughout ----
good="${WORK}/good"
seed_rootfs "${good}"
if good_out="$(modem_support_ownership_violations "${good}" "${LEDGER}")"; then
  ok "a correctly-owned rootfs passes the shipped ownership check"
else
  bad "the shipped ownership check rejected a correct rootfs: ${good_out}"
fi

# --- 4. NEGATIVE: an orphan packaged file ------------------------------------
orphan="${WORK}/orphan"
seed_rootfs "${orphan}"
orphan_path="/usr/lib/udev/rules.d/60-ceralive-modem.rules"
sed -i "\#^${orphan_path}\$#d" "${orphan}/var/lib/dpkg/info/${MODEM_SUPPORT_OWNER_PACKAGE}.list"
if orphan_out="$(modem_support_ownership_violations "${orphan}" "${LEDGER}")"; then
  bad "NON-VACUITY FAILED — an orphaned ${orphan_path} was accepted"
else
  ok "an orphaned packaged file is rejected"
  if grep -qF 'ORPHAN' <<<"${orphan_out}" && grep -qF "${orphan_path}" <<<"${orphan_out}"; then
    ok "the orphan rejection names the path and the defect class"
  else
    bad "the orphan rejection was not diagnostic: ${orphan_out}"
  fi
fi

# --- 5. NEGATIVE: two packages claiming one path -----------------------------
double="${WORK}/double"
seed_rootfs "${double}"
printf '%s\n' "${orphan_path}" >"${double}/var/lib/dpkg/info/some-other-package.list"
if double_out="$(modem_support_ownership_violations "${double}" "${LEDGER}")"; then
  bad "NON-VACUITY FAILED — a path claimed by two packages was accepted"
else
  ok "a path claimed by two packages is rejected"
  if grep -qF 'DOUBLE OWNERSHIP' <<<"${double_out}" && grep -qF 'some-other-package' <<<"${double_out}"; then
    ok "the double-ownership rejection names both claimants"
  else
    bad "the double-ownership rejection was not diagnostic: ${double_out}"
  fi
fi

# --- 6. NEGATIVE: a package claiming an image-generated /etc file -------------
# This is the ownership-shaped twin of the basename shadow: a .deb that starts
# shipping /etc/udev/rules.d/99-ceralive-hardware.rules would take the image's own
# generated policy under package management and overwrite it on every upgrade.
claimed="${WORK}/claimed"
seed_rootfs "${claimed}"
image_path="/etc/udev/rules.d/99-ceralive-hardware.rules"
printf '%s\n' "${image_path}" >>"${claimed}/var/lib/dpkg/info/${MODEM_SUPPORT_OWNER_PACKAGE}.list"
if claimed_out="$(modem_support_ownership_violations "${claimed}" "${LEDGER}")"; then
  bad "NON-VACUITY FAILED — a package claiming the image-generated ${image_path} was accepted"
else
  ok "a package claiming an image-generated file is rejected"
  if grep -qF "${image_path}" <<<"${claimed_out}"; then
    ok "the rejection names the image-generated path"
  else
    bad "the rejection did not name the image-generated path: ${claimed_out}"
  fi
fi

# --- 7. NEGATIVE: a duplicated ledger row ------------------------------------
dup_ledger="${WORK}/duplicate-ledger.txt"
cp "${LEDGER}" "${dup_ledger}"
printf '%s\t%s\n' "${MODEM_SUPPORT_OWNER_IMAGE}" "${orphan_path}" >>"${dup_ledger}"
if dup_out="$(modem_support_ledger_violations "${dup_ledger}")"; then
  bad "NON-VACUITY FAILED — a ledger claiming one path for two owners was accepted"
else
  ok "a ledger claiming one path for two owners is rejected"
  if grep -qF 'DOUBLE OWNERSHIP' <<<"${dup_out}"; then
    ok "the duplicate-row rejection names the defect class"
  else
    bad "the duplicate-row rejection was not diagnostic: ${dup_out}"
  fi
fi

# --- 8. NEGATIVE: a packaged path placed in the admin tier -------------------
tier_ledger="${WORK}/bad-tier-ledger.txt"
cp "${LEDGER}" "${tier_ledger}"
printf '%s\t%s\n' "${MODEM_SUPPORT_OWNER_PACKAGE}" '/etc/udev/rules.d/60-ceralive-modem.rules' >>"${tier_ledger}"
if modem_support_ledger_violations "${tier_ledger}" >/dev/null; then
  bad "NON-VACUITY FAILED — a packaged path in /etc was accepted by the ledger check"
else
  ok "a packaged path declared in the /etc admin tier is rejected"
fi

# --- 9. REAL emitted rootfs, when this machine has one -----------------------
ROOTFS_DIR="${CERALIVE_ROOTFS_DIR:-${PIPELINE_DIR}/mkosi/build/app}"
if [[ -d "${ROOTFS_DIR}/var/lib/dpkg/info" && -r "${ROOTFS_DIR}/var/lib/dpkg/info" ]]; then
  if real_out="$(modem_support_ownership_violations "${ROOTFS_DIR}" "${LEDGER}")"; then
    ok "emitted rootfs ${ROOTFS_DIR}: unique ownership for every present modem-support path"
  else
    bad "emitted rootfs ${ROOTFS_DIR} ownership violations: ${real_out}"
  fi
  if real_shadow="$(udev_shadow_scan_rootfs "${ROOTFS_DIR}")"; then
    ok "emitted rootfs ${ROOTFS_DIR}: no shadowed udev rule basename"
  else
    bad "emitted rootfs ${ROOTFS_DIR} shadowed udev basename(s): ${real_shadow}"
  fi
else
  ok "no readable emitted rootfs at ${ROOTFS_DIR} — manifest-level equivalent asserted above (set CERALIVE_ROOTFS_DIR to point at one)"
fi

# --- 10. the checks reach the real BUILD gate --------------------------------
if grep -qF 'modem_support_ownership_violations' "${PARITY}"; then
  ok "lib/parity-check.sh wires the ownership check into the [7/9] parity gate"
else
  bad "lib/parity-check.sh does not call modem_support_ownership_violations — it would never run on a real image"
fi

printf '\n== modem-support file ownership: %d passed, %d failed ==\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
