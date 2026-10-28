#!/usr/bin/env bash
#
# stages/kernel-build.sh — orchestrator stage [2b/9]: kernel from pinned source.
#
# Sourced by lib/orchestrate.sh. See stages/resolve.sh for the dynamic-scoping
# contract every stage module relies on.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

# ---------------------------------------------------------------------------
# stage_kernel_build — [2b/9]
#
# Inert unless the resolved manifest carried a kernel_source: block, i.e. only
# under an explicitly selected variant. Runs AFTER [2/9] so the uniqueness check
# sees the complete fetched set, and BEFORE [3/9] so the built .deb flows through
# exactly the same classification and staging path as a fetched one.
#
# Reads from main()'s frame: board, variant, kernel_from_source, staging,
# kernel_build_dir.
# ---------------------------------------------------------------------------
stage_kernel_build() {
  local -a reuse=()
  if [[ "${DRY_RUN:-0}" != 1 && "${kernel_from_source}" == 1 ]]; then
    local selected="" params
    if [[ -f "${staging}/packages-lock/fetch.jsonl" ]]; then
      selected="$(python3 - "${staging}/packages-lock/fetch.jsonl" "${KERNEL_PACKAGES}" "${KERNEL_SOURCE_PACKAGE_VERSION}" "${staging}/debs" <<'PY'
import hashlib, json, pathlib, sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
matches = [r for r in rows if r['name'] == sys.argv[2]]
if matches:
    if len(matches) != 1:
        sys.exit('ambiguous kernel fetch receipt')
    r = matches[0]
    if (r['version'], r['arch'], r['origin']) != (sys.argv[3], 'arm64', 'ceralive-kernel'):
        sys.exit('kernel APT receipt identity mismatch')
    deb = pathlib.Path(sys.argv[4]) / f"{r['name']}_{r['version']}_arm64.deb"
    if hashlib.sha256(deb.read_bytes()).hexdigest() != r['sha256']:
        sys.exit('staged kernel differs from authenticated APT digest')
    print(deb)
PY
)" || die "kernel APT receipt verification failed"
    fi
    if [[ -n "${selected}" ]]; then
      assert_staged_packages_unique "${staging}/debs" "${kernel_build_dir}"
      mv -- "${selected}" "${kernel_build_dir}/$(basename "${selected}")"
      reuse=(--reuse-deb "${kernel_build_dir}/$(basename "${selected}")")
      params="$("${RESOLVE_SH}" "${board}" --variant "${variant}" --kernel-apt)" \
        || die "APT kernel manifest resolution failed"
      eval "${params}"
      export CERALIVE_KERNEL_SOURCE_SUPPRESSED_PKGS="${KERNEL_SOURCE_SUPPRESSED_PACKAGES}"
    elif [[ "${CERALIVE_REQUIRE_KERNEL_APT:-0}" == 1 || "${CERALIVE_BUILD_MODE:-}" == production ]]; then
      die "kernel_not_on_apt: production images never compile a kernel"
    fi
  fi
  if [[ "${kernel_from_source}" == "1" ]]; then
    if (( ${#reuse[@]} )); then
      log_info "[2b/9] reusing released kernel artifact (variant '${KERNEL_VARIANT:-${variant}}') → ${kernel_build_dir}"
    else
      log_info "[2b/9] building kernel from pinned source (variant '${KERNEL_VARIANT:-${variant}}') → ${kernel_build_dir}"
    fi
    "${BUILD_KERNEL_SH}" --board "${board}" --out "${kernel_build_dir}" "${reuse[@]}" \
      || die "kernel-build-from-source failed for board '${board}'"
  fi

  if [[ "${DRY_RUN:-0}" != "1" && "${kernel_from_source}" == "1" ]]; then
    assert_staged_packages_unique "${staging}/debs" "${kernel_build_dir}"
    shopt -s nullglob
    local _kdeb
    for _kdeb in "${kernel_build_dir}"/*.deb; do
      "${MKOSI_PACKAGE_STAGING_SH}" "${_kdeb}" "${staging}/debs"
    done
    shopt -u nullglob
  fi
}
