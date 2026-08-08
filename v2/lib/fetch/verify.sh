#!/usr/bin/env bash
#
# fetch/verify.sh — the verdicts. Signed-metadata verification, signed-index
# preflight, and the kernel-BSP content provenance/drift-guard.
#
# Everything here answers a question about bytes already in hand, which is
# exactly why NONE of it may ever be wrapped in fetch/retry.sh's retry loop:
# replaying a signature, identity or hash verdict cannot change the answer, it
# only buries the real diagnostic under more attempts.
#
# Sourced by lib/fetch-debs.sh; not standalone. It reads ${HERE} (the entry
# point's own lib dir) for the committed baseline path.
#
# Bodies moved VERBATIM from fetch-debs.sh; no behaviour change.
#
# shellcheck shell=bash
# BSP provenance + advisory kernel drift-guard.
#
# The kernel BSP is exact-versioned. Armbian can still replace package bytes under
# the same version, so provenance records the downloaded hash and makes a silent
# same-version re-spin observable against the reviewed baseline.
#
# HARD CONTRACTS:
#   * WARN by default; BSP_DRIFT_STRICT=1 makes a seeded mismatch fatal.
#   * Content hash, not just version — a same-version re-spin is still caught.
#   * The provenance artifact is gitignored build output, deliberately EXCLUDED
#     from the normalized build-plan comparison.

BSP_BASELINE="${BSP_BASELINE:-${HERE}/../manifests/bsp-baseline.json}"

# _bsp_json_field <file> <field> — read a flat JSON string field (no jq dep; the
# baseline is a small flat object). A null/absent/empty value yields empty output,
# which the drift-guard reads as "unseeded" (first run).
_bsp_json_field() {
  local file="$1" field="$2"
  [[ -f "${file}" ]] || { printf ''; return 0; }
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${file}" | head -n1
}

# bsp_write_json <path> <pkg> <version> <sha256> — emit the flat provenance/baseline
# document (schema_version 1). Used for BOTH the gitignored provenance artifact and
# the committed baseline seed, so the two files share one shape.
bsp_write_json() {
  local out="$1" pkg="$2" version="$3" sha="$4"
  mkdir -p "$(dirname "${out}")"
  cat >"${out}" <<EOF
{
  "schema_version": 1,
  "package": "${pkg}",
  "version": "${version}",
  "sha256": "${sha}"
}
EOF
}

# bsp_drift_check <baseline> <pkg> <version> <sha256> — drift-guard.
# First run (no/unseeded baseline) seeds it and notes that. A match is silent-ok.
# A mismatch prints a "BSP drift" banner to stdout (the user-facing advisory signal)
# plus structured detail on stderr.
#
# Exit policy is opt-in (C6b):
#   * DEFAULT (BSP_DRIFT_STRICT unset/≠1) — WARN-ONLY: drift prints the banner and
#     still returns 0. The package version remains exact; this reports a content
#     replacement or an intentional version/baseline mismatch.
#   * BSP_DRIFT_STRICT=1 — STRICT: a real version/hash mismatch against a SEEDED
#     baseline returns non-zero, failing the build. The seeding run (unseeded/first
#     run) and a clean match are ALWAYS exit 0 regardless of this flag — a fresh
#     baseline can never fail a strict build.
#
# Promotion criterion (why default is still warn): flipping the default to strict
# (blocking) remains gated on a fleet manifest run confirming that every board
# resolves to the seeded known-good BSP with no outstanding drift. Operators/CI
# that want the gate today opt in with BSP_DRIFT_STRICT=1.
bsp_drift_check() {
  local baseline="$1" pkg="$2" version="$3" sha="$4"
  local base_ver base_sha
  base_ver="$(_bsp_json_field "${baseline}" version)"
  base_sha="$(_bsp_json_field "${baseline}" sha256)"

  if [[ ! -f "${baseline}" || -z "${base_ver}" || -z "${base_sha}" ]]; then
    printf 'BSP baseline: no known-good baseline for %s — seeding it (first run, advisory)\n' "${pkg}"
    bsp_write_json "${baseline}" "${pkg}" "${version}" "${sha}"
    log_info "BSP baseline seeded -> ${baseline} (version=${version} sha256=${sha})"
    return 0
  fi

  if [[ "${base_ver}" == "${version}" && "${base_sha}" == "${sha}" ]]; then
    log_info "BSP provenance: ${pkg} matches known-good baseline (version=${version})"
    return 0
  fi

  local strict=0
  [[ "${BSP_DRIFT_STRICT:-}" == "1" ]] && strict=1

  if [[ "${strict}" -eq 1 ]]; then
    printf 'BSP drift: %s differs from the known-good baseline (BSP_DRIFT_STRICT=1 — failing the build)\n' "${pkg}"
  else
    printf 'BSP drift: %s differs from the known-good baseline (advisory — build continues)\n' "${pkg}"
  fi
  log_warn "BSP drift detail — baseline: version=${base_ver} sha256=${base_sha}"
  log_warn "BSP drift detail — current : version=${version} sha256=${sha}"
  if [[ "${base_ver}" == "${version}" ]]; then
    log_warn "BSP drift: SAME version, DIFFERENT content hash — kernel BSP re-spin detected"
  fi

  if [[ "${strict}" -eq 1 ]]; then
    log_warn "BSP drift: strict mode (BSP_DRIFT_STRICT=1) — returning non-zero to fail the build"
    return 1
  fi
  return 0
}

# bsp_capture_provenance <out_dir> <debs_dir> <kernel_pkg> — locate the fetched
# kernel .deb, record its resolved version + content sha256 to <out_dir>/
# bsp-provenance.json, then run the advisory drift-guard. Scope is the kernel BSP
# package ONLY (provenance is intentionally not widened to the rest of the BSP set).
bsp_capture_provenance() {
  local out_dir="$1" debs_dir="$2" kpkg="$3"
  local deb="" f name
  shopt -s nullglob
  for f in "${debs_dir}"/*.deb; do
    name="$(deb_pkg_name "${f}")"
    if [[ "${name}" == "${kpkg}" ]]; then deb="${f}"; break; fi
  done
  shopt -u nullglob

  if [[ -z "${deb}" ]]; then
    log_warn "BSP provenance: kernel package '${kpkg}' .deb not staged in ${debs_dir} — skipping capture"
    return 0
  fi

  local version sha
  version="$(deb_pkg_version "${deb}")"
  sha="$(sha256sum "${deb}" | awk '{print $1}')"
  bsp_write_json "${out_dir}/bsp-provenance.json" "${kpkg}" "${version}" "${sha}"
  log_info "BSP provenance: ${kpkg} version=${version} sha256=${sha} -> ${out_dir}/bsp-provenance.json"

  bsp_drift_check "${BSP_BASELINE}" "${kpkg}" "${version}" "${sha}"
}
bsp_verify_native_release() {
  local apt_state="$1" keyring="$2" suite="$3" component="$4" arch="$5"
  shift 5
  local verified_release="${apt_state}/verified-Release"
  local -a inreleases=()
  shopt -s nullglob
  inreleases=("${apt_state}/lists/"*_dists_"${suite}"_InRelease)
  shopt -u nullglob
  if (( ${#inreleases[@]} != 1 )); then
    log_error "native BSP apt state contains ${#inreleases[@]} InRelease files for suite ${suite}; expected exactly one"
    return 1
  fi
  if ! auth_verify_release_to_file \
      "${keyring}" "${inreleases[0]}" "${verified_release}" "$@"; then
    log_error "native BSP InRelease does not carry every required signature"
    return 1
  fi
  if ! auth_release_has_identity \
      "${verified_release}" "${suite}" "${component}" "${arch}"; then
    log_error "native BSP InRelease identity mismatch: expected suite=${suite} component=${component} arch=${arch}"
    return 1
  fi
}
bsp_assert_index_specs() {
  local index="$1" arch="$2" spec pkg version
  shift 2
  for spec in "$@"; do
    [[ "${spec}" == *=* ]] || {
      log_error "BSP package lacks exact version: ${spec}"
      return 1
    }
    pkg="${spec%%=*}"
    version="${spec#*=}"
    if ! auth_lookup_package "${index}" "${pkg}" "${version}" "${arch}" >/dev/null; then
      log_error "exact BSP package '${spec}' unavailable for architecture ${arch}"
      return 1
    fi
  done
}
