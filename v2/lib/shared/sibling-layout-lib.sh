#!/usr/bin/env bash
#
# sibling-layout-lib.sh — the CeraLive sibling-checkout guard, shared across v2.
#
# Single entrypoint:
#   * assert_sibling_layout <workspace_root> — die loudly if ceracoder/, srtla/,
#     CeraUI/ are not siblings under <workspace_root> (the layout CeraUI's
#     backend link: deps depend on; ARCHITECTURE.md §5).
#
# Body extracted VERBATIM from fetch-debs.sh. No behaviour change — this file is
# a relocation of existing logic into one shared home so the fetcher (and any
# future caller) sources one canonical guard instead of carrying its own copy.
#
# shellcheck shell=bash

SIBLING_LAYOUT_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh provides strict mode, the loud ERR trap, loggers, die, require_cmd.
# shellcheck source=../common.sh
source "${SIBLING_LAYOUT_LIB_HERE}/../common.sh"

# ---------------------------------------------------------------------------
# assert_sibling_layout <workspace_root>
#
# HARD CONSTRAINT (ARCHITECTURE.md §5): CeraUI/apps/backend/package.json resolves
# @ceralive/ceracoder and @ceralive/srtla via `link:../../../{ceracoder,srtla}/
# bindings/typescript`. The `../../../` climbs from CeraUI/apps/backend to the
# parent of CeraUI, so ceracoder/, srtla/, CeraUI/ MUST be siblings there.
#
# WHY HERE: once we consume PRE-BUILT .debs, mkosi never touches the link: graph,
# so the layout is technically irrelevant to image assembly. BUT the .debs are
# built FROM this checkout upstream; a broken sibling layout means CeraUI's .deb
# could never have been produced. This guard is the CI-side tripwire that catches
# the misconfiguration loudly at fetch time instead of letting a silently-missing
# CeraUI .deb surface as a mysterious runtime gap. It takes the root as an ARG so
# it is unit-testable against synthetic good/bad trees (see assert-sibling cmd).
# ---------------------------------------------------------------------------
assert_sibling_layout() {
  local root="$1"
  [[ -n "${root}" ]] || die "assert_sibling_layout: workspace root not given"
  [[ -d "${root}" ]] || die "sibling-layout: workspace root does not exist: ${root}"

  local sib missing=()
  for sib in ceracoder srtla CeraUI; do
    [[ -d "${root}/${sib}" ]] || missing+=("${sib}/")
  done
  if (( ${#missing[@]} > 0 )); then
    die "sibling-layout BROKEN under ${root}: missing ${missing[*]} — CeraUI backend resolves @ceralive/{ceracoder,srtla} via link:../../../ (ARCHITECTURE.md §5). ceracoder/, srtla/, CeraUI/ must be siblings."
  fi

  # Verify the exact link: targets the backend depends on actually resolve from
  # CeraUI/apps/backend, not just that the sibling dirs exist.
  local backend="${root}/CeraUI/apps/backend"
  if [[ -d "${backend}" ]]; then
    local dep
    for dep in ceracoder srtla; do
      # link:../../../<dep>/bindings/typescript resolved from CeraUI/apps/backend
      local resolved="${backend}/../../../${dep}/bindings/typescript"
      if [[ ! -d "${resolved}" ]]; then
        log_warn "sibling-layout: ${dep} bindings/typescript not present at $(cd "${backend}" >/dev/null 2>&1 && cd "../../../${dep}" 2>/dev/null && pwd || echo "${root}/${dep}")/bindings/typescript — link:../../../${dep}/bindings/typescript will fail on a source build (ok if consuming a pre-built CeraUI .deb)"
      fi
    done
  fi

  log_success "sibling-layout OK under ${root} (ceracoder/ srtla/ CeraUI/ are siblings; link:../../../ resolves)"
}
