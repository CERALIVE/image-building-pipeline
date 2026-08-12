#!/usr/bin/env bash
#
# build-input-lib.sh — build-input resolution for the native (srtla)
# dev-sync path. Resolves WHAT feeds build_app_layer for each app:
#
#   * _stage_for          — resolve the staging tree for an app (prefer
#                           <root>/<app>, else <root>); explode the matching .deb
#                           first when --from-deb is active
#   * _find_staged_binary — echo the first executable under usr/bin / usr/sbin
#                           (the ELF arch_guard reads)
#
# Bodies extracted VERBATIM from dev-sync/sync-native.sh. No behaviour change —
# this file is a relocation of existing logic into one focused home.
#
# _stage_for reads FROM_DEB, which the consumer (sync-native.sh) sets in main()
# from --from-deb; common.sh (sourced by the consumer) supplies log_info, die,
# and require_cmd.
#
# shellcheck shell=bash
# shellcheck disable=SC2154  # FROM_DEB supplied by the sourcing consumer (sync-native.sh main())

BUILD_INPUT_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# deb-lib.sh pulls in common.sh (strict mode, loggers, die, require_cmd) and the
# one shared .deb data-tarball extractor (explode_deb) --from-deb staging uses.
# shellcheck source=../shared/deb-lib.sh
source "${BUILD_INPUT_LIB_HERE}/../shared/deb-lib.sh"

# ---------------------------------------------------------------------------
# _stage_for <app> <staging_root> <out_root> — resolve the staging tree for <app>
# under <staging_root> (prefer <staging_root>/<app>, else <staging_root>); when
# --from-deb is active, explode the matching .deb into a fresh tree first. Echoes
# the resolved staging dir on stdout.
# ---------------------------------------------------------------------------
_stage_for() {
  local app="$1" staging_root="$2" out_root="$3"
  if [[ -n "${FROM_DEB}" ]]; then
    local tree="${out_root}/staging/${app}"
    shopt -s nullglob
    local matches=("${FROM_DEB}/${app}"*.deb)
    shopt -u nullglob
    (( ${#matches[@]} > 0 )) || die "_stage_for: no ${app}*.deb in ${FROM_DEB}"
    log_info "build(${app}): exploding prod .deb ${matches[0]}"
    explode_deb "${matches[0]}" "${tree}"
    printf '%s' "${tree}"
    return 0
  fi
  if [[ -d "${staging_root}/${app}" ]]; then
    printf '%s' "${staging_root}/${app}"
  else
    printf '%s' "${staging_root}"
  fi
}

# ---------------------------------------------------------------------------
# _find_staged_binary <staging> — echo the first executable regular file under
# the staging tree's usr/bin or usr/sbin (the artifact arch_guard reads), or
# nothing if none is found.
# ---------------------------------------------------------------------------
_find_staged_binary() {
  local staging="$1" d f
  for d in usr/bin usr/sbin; do
    [[ -d "${staging}/${d}" ]] || continue
    for f in "${staging}/${d}"/*; do
      [[ -f "${f}" && -x "${f}" ]] && { printf '%s' "${f}"; return 0; }
    done
  done
}
