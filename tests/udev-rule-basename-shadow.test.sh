#!/usr/bin/env bash
#
# udev-rule-basename-shadow.test.sh — no image-owned /etc/udev/rules.d file may
# share a BASENAME with a packaged /usr/lib/udev/rules.d file.
#
# WHY THIS IS ITS OWN GATE. udev resolves rules by basename across its whole
# search path and the /etc tier wins outright, so a collision replaces the
# packaged rules completely — and it does so INVISIBLY to package tooling:
# `dpkg -S` on the packaged path still names ceralive-modem-support and
# `dpkg --verify` still passes, because the packaged file is present and
# byte-intact. It is simply never read. No dpkg check can catch this class, which
# is why the property is asserted structurally here and against a real emitted
# rootfs by lib/parity-check.sh §E.
#
# The negative leg is the point of the file: it injects a real collision into a
# fixture rootfs and requires the SHIPPED scan to reject it, so a check that
# stopped firing fails this suite instead of the fleet.
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

# Every tracked writer that can create a file under /etc/udev/rules.d. Listed
# EXPLICITLY rather than globbed, for the same reason postinst-lib.sh lists its
# modules explicitly: a writer that is renamed or dropped must fail loudly here
# instead of quietly leaving the scan with nothing to read.
UDEV_WRITERS=(
  "mkosi/customize/udev.sh"
  "mkosi/customize/quirks.sh"
  "mkosi/customize/postinst.d/hardware.sh"
  "mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/udev-shadow.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

echo "== udev rule basename shadow =="

# --- 1. every declared writer exists (non-vacuity of the scan below) ----------
writer_paths=()
for w in "${UDEV_WRITERS[@]}"; do
  if [[ -f "${PIPELINE_DIR}/${w}" ]]; then
    writer_paths+=("${PIPELINE_DIR}/${w}")
    ok "udev writer present: ${w}"
  else
    bad "declared udev writer is missing: ${w}"
  fi
done

# --- 2. image-owned basenames, read from the WRITERS (not from the ledger) ----
# Deriving these from the ledger would make the next assertion circular: a writer
# that started emitting an unledgered colliding basename has to be catchable.
#
# Matching a full `/etc/udev/rules.d/<name>.rules` literal is NOT enough — the
# slot-UID generator composes its path from a `${rules_dir}` variable so the
# directory and the basename never appear on one line, and a literal-path scan
# silently misses it. These four writers only ever write into the admin tier, so
# every `.rules` basename they name is image-owned. Comment lines are stripped
# first so prose naming the PACKAGED file cannot read as a collision.
image_basenames="$(sed -e 's/#.*//' "${writer_paths[@]}" 2>/dev/null \
  | grep -oE '[A-Za-z0-9._+-]+\.rules' | sort -u)"
if [[ -n "${image_basenames}" ]]; then
  ok "image-owned /etc/udev/rules.d basenames discovered: $(tr '\n' ' ' <<<"${image_basenames}")"
else
  bad "no /etc/udev/rules.d basename found in any writer — the scan would pass vacuously"
fi

# --- 3. packaged basenames, read from the ownership ledger --------------------
packaged_basenames="$(modem_support_ledger_rows "${LEDGER}" \
  | awk -F'\t' -v owner="${MODEM_SUPPORT_OWNER_PACKAGE}" \
      '$1 == owner && $2 ~ /^\/usr\/lib\/udev\/rules\.d\// { n = split($2, p, "/"); print p[n] }' \
  | sort -u)"
if [[ -n "${packaged_basenames}" ]]; then
  ok "packaged /usr/lib/udev/rules.d basenames declared: $(tr '\n' ' ' <<<"${packaged_basenames}")"
else
  bad "the ownership ledger declares no packaged udev rules file — nothing to shadow, check would be vacuous"
fi

# --- 4. THE PROPERTY: the two sets are disjoint -------------------------------
collisions="$(comm -12 <(printf '%s\n' "${image_basenames}") <(printf '%s\n' "${packaged_basenames}"))"
if [[ -z "${collisions}" ]]; then
  ok "no packaged udev basename is shadowed by an image-owned /etc/udev/rules.d file"
else
  bad "SHADOWED basename(s): $(tr '\n' ' ' <<<"${collisions}") — the packaged rules would never be read"
fi

# --- 5. every image basename a writer emits is declared in the ledger ---------
while IFS= read -r base; do
  [[ -n "${base}" ]] || continue
  if modem_support_ledger_rows "${LEDGER}" \
      | awk -F'\t' -v owner="${MODEM_SUPPORT_OWNER_IMAGE}" -v p="/etc/udev/rules.d/${base}" \
        '$1 == owner && $2 == p { found = 1 } END { exit found ? 0 : 1 }'; then
    ok "ledger declares image-owned ${base}"
  else
    bad "writer emits /etc/udev/rules.d/${base} but the ownership ledger does not declare it"
  fi
done <<<"${image_basenames}"

# --- 6. POSITIVE: the shipped scan clears a rootfs modelled on the real one ---
clean="${WORK}/clean"
mkdir -p "${clean}/etc/udev/rules.d" "${clean}/usr/lib/udev/rules.d"
while IFS= read -r base; do
  [[ -n "${base}" ]] && printf '# image-owned\n' >"${clean}/etc/udev/rules.d/${base}"
done <<<"${image_basenames}"
while IFS= read -r base; do
  [[ -n "${base}" ]] && printf '# packaged\n' >"${clean}/usr/lib/udev/rules.d/${base}"
done <<<"${packaged_basenames}"

if clean_out="$(udev_shadow_scan_rootfs "${clean}")"; then
  ok "shipped udev_shadow_scan_rootfs passes on the real basename set"
else
  bad "shipped scan reported a collision on the real basename set: ${clean_out}"
fi

# --- 7. NEGATIVE: inject a real collision; the SHIPPED scan must reject it -----
# This is what proves the check has teeth. The injected file is a byte-plausible
# generated override with the packaged basename — exactly the shape that makes the
# packaged rules unreadable while dpkg keeps reporting them as installed and intact.
victim="$(head -n1 <<<"${packaged_basenames}")"
dirty="${WORK}/dirty"
cp -a "${clean}" "${dirty}"
printf '# CERALIVE-GENERATED: modem-udev\n' >"${dirty}/etc/udev/rules.d/${victim}"

if dirty_out="$(udev_shadow_scan_rootfs "${dirty}")"; then
  bad "NON-VACUITY FAILED — the shipped scan accepted an injected /etc/udev/rules.d/${victim} shadowing the packaged file"
else
  ok "shipped scan REJECTS an injected collision on ${victim}"
  if grep -qF "${victim}" <<<"${dirty_out}"; then
    ok "the rejection names the shadowed basename (${victim})"
  else
    bad "the rejection did not name the shadowed basename: ${dirty_out}"
  fi
  if grep -qF "${dirty}/usr/lib/udev/rules.d/${victim}" <<<"${dirty_out}"; then
    ok "the rejection names the packaged file being shadowed"
  else
    bad "the rejection did not name the packaged path: ${dirty_out}"
  fi
fi

# --- 8. a deliberate SYMLINK from the admin tier is not a collision -----------
# Pointing /etc at the packaged file is how an operator pins precedence on
# purpose; treating it as a shadow would make the honest form unusable.
linked="${WORK}/linked"
cp -a "${clean}" "${linked}"
ln -sf "/usr/lib/udev/rules.d/${victim}" "${linked}/etc/udev/rules.d/${victim}"
if udev_shadow_scan_rootfs "${linked}" >/dev/null; then
  ok "an /etc symlink to the packaged rules file is not reported as a shadow"
else
  bad "an /etc symlink to the packaged rules file was wrongly reported as a shadow"
fi

# --- 9. the check reaches a real BUILD gate, not only this suite --------------
if grep -qF 'udev_shadow_scan_rootfs' "${PARITY}"; then
  ok "lib/parity-check.sh wires the shadow scan into the [7/9] parity gate"
else
  bad "lib/parity-check.sh does not call udev_shadow_scan_rootfs — the check would never run on a real image"
fi

printf '\n== udev rule basename shadow: %d passed, %d failed ==\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
