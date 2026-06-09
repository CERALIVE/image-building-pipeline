#!/usr/bin/env bash
#
# package-migration-coverage.sh — assert the v2 manifests fully cover the legacy
# package source-of-truth (MIGRATE step of MIGRATE -> REWIRE -> GREEN -> DELETE).
#
# Every package named across the two legacy sources must resolve to a v2 home:
#   - an active install line in manifests/packages/shared.list or a
#     manifests/packages/<family>.delta.list,
#   - a typed BSP/HW-accel array in manifests/families/<family>.yaml,
#   - a first-party .deb in lib/fetch-debs.sh REPOS, or
#   - an explicit, justified non-migration in manifests/packages/removed.md.
#
# A "net omission" is a legacy package with NO such home. The migration is
# complete iff net omissions == 0; this script exits non-zero otherwise, so it
# guards REWIRE (task 22) and DELETE (task 24) against silent package loss.
#
# Legacy sources:
#   configs/base/ceraui-base.conf      (CERAUI/BASE/STREAMING/DEVELOPMENT/EXCLUDED
#                                       + VARIANT_MINIMAL_EXTRA_EXCLUDES
#                                       + VARIANT_DEVELOPMENT_EXTRAS arrays)
#   userpatches/customize-image.sh     (install_streaming_packages STREAMING_PACKAGES[]
#                                       incl. the VARIANT=development branch, the
#                                       standalone ipcalc install, and the
#                                       service-enabled chrony / ssh->openssh-server)
#
# Usage:  v2/tests/package-migration-coverage.sh [evidence-file]
#         (default evidence-file: <repo>/test-results/migrate-package-diff.txt)
#
# shellcheck shell=bash

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$(cd "${HERE}/.." && pwd)"
REPO="$(cd "${V2}/.." && pwd)"

BASECONF="${REPO}/configs/base/ceraui-base.conf"
CIMG="${REPO}/userpatches/customize-image.sh"
PKGDIR="${V2}/manifests/packages"
FAMDIR="${V2}/manifests/families"
FETCH_DEBS="${V2}/lib/fetch-debs.sh"

EVIDENCE="${1:-${REPO}/test-results/migrate-package-diff.txt}"

for f in "${BASECONF}" "${CIMG}" "${PKGDIR}/shared.list" "${PKGDIR}/removed.md"; do
  [[ -f "${f}" ]] || { echo "ERROR: missing source: ${f}" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Items of a bash array literal NAME=( ... ) or NAME+=( ... ), comments stripped.
extract_array() {
  local conf="$1" name="$2"
  awk -v name="${name}" '
    $0 ~ "^[[:space:]]*"name"\\+?=\\(" { inarr=1; sub("^[[:space:]]*"name"\\+?=\\(", "") }
    inarr {
      line=$0; sub(/#.*/, "", line)
      n=split(line, toks, /"/)
      for (i=2; i<=n; i+=2) if (toks[i] != "") print toks[i]
      if (line ~ /\)/) inarr=0
    }
  ' "${conf}"
}

build_legacy_set() {
  {
    local arr
    for arr in CERAUI_PACKAGES BASE_PACKAGES STREAMING_PACKAGES \
               DEVELOPMENT_PACKAGES EXCLUDED_PACKAGES \
               VARIANT_MINIMAL_EXTRA_EXCLUDES VARIANT_DEVELOPMENT_EXTRAS; do
      extract_array "${BASECONF}" "${arr}"
    done
    extract_array "${CIMG}" STREAMING_PACKAGES
    # Standalone `apt-get install -y <pkg>`; the token must start with a letter so
    # apt flags such as --no-install-recommends are not mistaken for packages.
    grep -oE 'apt-get install -y [a-z][a-z0-9._+-]*' "${CIMG}" | awk '{print $4}'
    # configure_services() enables these units; the backing package is installed
    # even though it is not an array literal.
    printf '%s\n' chrony openssh-server
  } | sed '/^$/d' | sort -u
}

build_v2_set() {
  {
    local f y
    for f in "${PKGDIR}/shared.list" "${PKGDIR}"/*.delta.list; do
      [[ -f "${f}" ]] && sed -e 's/#.*//' "${f}" | awk 'NF{print $1}'
    done
    for y in "${FAMDIR}"/*.yaml; do
      [[ -f "${y}" ]] || continue
      grep -E '^[[:space:]]*-[[:space:]]+[a-z0-9._+-]+' "${y}" \
        | sed -E 's/^[[:space:]]*-[[:space:]]+//' | awk '{print $1}'
    done
    # removed.md backticked tokens that are genuine Debian package names (incl.
    # EXCLUDED globs). Debian binary names are lowercase with no underscore; drop
    # the YAML field names / file paths / filenames / prose that also use backticks.
    # shellcheck disable=SC2016  # literal backticks in the regex are intentional
    grep -oE '`[^`]+`' "${PKGDIR}/removed.md" | tr -d '`' \
      | grep -E '^[a-z0-9][a-z0-9.+*-]*$' \
      | grep -vE '\.(conf|sh|list|yaml|yml|md|py)$'
    # First-party .deb names (lib/fetch-debs.sh REPOS) + their resolved/legacy aliases.
    if [[ -f "${FETCH_DEBS}" ]]; then
      sed -n 's/^REPOS=(\(.*\))/\1/p' "${FETCH_DEBS}" | tr -d '"' | tr ' ' '\n'
    fi
    printf '%s\n' srtla srt ceracoder CeraUI ceraui belacoder ceralive-device
  } | sed '/^$/d' | sort -u
}

build_legacy_set > "${WORK}/legacy.txt"
build_v2_set      > "${WORK}/v2.txt"
comm -23 "${WORK}/legacy.txt" "${WORK}/v2.txt" > "${WORK}/omissions.txt"

n_legacy="$(wc -l < "${WORK}/legacy.txt")"
n_v2="$(wc -l < "${WORK}/v2.txt")"
n_omit="$(wc -l < "${WORK}/omissions.txt")"

classify() {
  local p="$1"
  grep -qxF "$p" <<<"${SHARED}" && { echo "shared.list"; return; }
  grep -qxF "$p" <<<"${FIRSTPARTY}" && { echo "first-party .deb (REPOS / app layer)"; return; }
  grep -qxF "$p" <<<"${FAMILY}" && { echo "family manifest BSP/HW-accel"; return; }
  grep -qxF "$p" <<<"${REMOVED}" && { echo "removed.md (justified non-migration)"; return; }
  echo "*** UNACCOUNTED ***"
}
SHARED="$(sed -e 's/#.*//' "${PKGDIR}/shared.list" | awk 'NF{print $1}' | sort -u)"
FAMILY="$(for y in "${FAMDIR}"/*.yaml; do grep -E '^[[:space:]]*-[[:space:]]+[a-z0-9._+-]+' "${y}" | sed -E 's/^[[:space:]]*-[[:space:]]+//' | awk '{print $1}'; done | sort -u)"
# shellcheck disable=SC2016  # literal backticks in the regex are intentional
REMOVED="$(grep -oE '`[^`]+`' "${PKGDIR}/removed.md" | tr -d '`' | grep -E '^[a-z0-9][a-z0-9.+*-]*$' | grep -vE '\.(conf|sh|list|yaml|yml|md|py)$' | sort -u)"
FIRSTPARTY=$'srtla\nsrt\nceracoder\nCeraUI\nceraui\nbelacoder\nceralive-device'

mkdir -p "$(dirname "${EVIDENCE}")"
{
  echo "============================================================================="
  echo "T4 MIGRATE — package source-of-truth coverage: legacy configs -> v2 manifests"
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)   repo HEAD: $(git -C "${REPO}" rev-parse --short HEAD 2>/dev/null || echo n/a)"
  echo "============================================================================="
  echo
  echo "Net omission = a legacy package with NO v2 home. Migration is COMPLETE iff 0."
  echo
  echo "legacy universe : ${n_legacy} packages (ceraui-base.conf + customize-image.sh)"
  echo "v2 accounting   : ${n_v2} tokens (shared.list + family BSP + removed.md + first-party)"
  echo "NET OMISSIONS   : ${n_omit}"
  echo
  echo "--- PART 1: per-package home -------------------------------------------------"
  printf '%-34s %s\n' "LEGACY PACKAGE" "V2 HOME"
  while IFS= read -r p; do [[ -n "$p" ]] && printf '%-34s %s\n' "$p" "$(classify "$p")"; done < "${WORK}/legacy.txt"
  echo
  echo "--- PART 2: diff <(sort legacy) <(sort v2_accounted) -------------------------"
  echo "    '<' = legacy-only  => NET OMISSION (must be none)"
  echo "    '>' = v2-only      => addition / alias / BSP relocation / glob doc"
  echo
  diff "${WORK}/legacy.txt" "${WORK}/v2.txt" || true
  echo
  echo "--- PART 3: net omissions ----------------------------------------------------"
  if [[ "${n_omit}" -eq 0 ]]; then
    echo "  (none) — MIGRATION VERIFIED COMPLETE, zero unexplained drops."
  else
    sed 's/^/  MISSING: /' "${WORK}/omissions.txt"
  fi
  echo "============================================================================="
} > "${EVIDENCE}"

echo "legacy=${n_legacy} v2_accounted=${n_v2} net_omissions=${n_omit}"
echo "evidence -> ${EVIDENCE}"
if [[ "${n_omit}" -ne 0 ]]; then
  echo "FAIL: ${n_omit} legacy package(s) have no v2 home:" >&2
  sed 's/^/  - /' "${WORK}/omissions.txt" >&2
  exit 1
fi
echo "PASS: every legacy package has a v2 home (0 net omissions)."
