#!/usr/bin/env bash
#
# upload-addons.sh — publish a SIGNED feature-sysext add-on to R2 so the
# apt-worker can serve it at addons/{os_version}/{board}/{feature}.raw.
#
# build-feature-sysext.sh emits three co-located artifacts per add-on:
#   <feature>-<board>-<os_version>.raw         the squashfs sysext (/usr+/opt)
#   <feature>-<board>-<os_version>.raw.sha256  integrity sidecar
#   <feature>-<board>-<os_version>.raw.sig     detached GPG signature
# This publisher maps them onto the per-board/per-OS R2 delivery path
#   addons/{os_version}/{board}/{feature}.raw[.sha256|.sig]
# the device add-on manager downloads from.
#
# It REFUSES to publish an unsigned (or unchecksummed) artifact: the .raw.sig
# and .raw.sha256 MUST exist locally. This mirrors the device-side trust
# contract — CeraUI verifies both before activating an add-on — so an unsigned
# .raw can never reach R2 in the first place. Content-type is pinned per file so
# R2 stores the exact type the worker serves (octet-stream for the sysext,
# text/plain for the checksum and the signature).
#
# Modes mirror fetch-debs.sh::fetch_first_party:
#   CI mode : R2_ACCESS_KEY_ID set -> aws s3 cp ... --endpoint-url $R2_ENDPOINT
#   Dry-run : DRY_RUN=1 -> log the EXACT command that WOULD run; upload nothing.
# There is deliberately no `|| true`: a real upload that fails trips the ERR trap.
#
# Usage:
#   upload-addons.sh --feature <name> --board <board> --os-version <ver> \
#                    --dist <dir>
#
# Env: DRY_RUN R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_ENDPOINT
#      ADDON_PREFIX (default: addons)
#
# shellcheck shell=bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${HERE}/common.sh"

: "${DRY_RUN:=}"
ADDON_PREFIX="${ADDON_PREFIX:-addons}"

run_or_plan() {
  if [[ -n "${DRY_RUN}" ]]; then
    log_info "DRY-RUN would run: $*"
    return 0
  fi
  log_info "exec: $*"
  "$@"
}

content_type_for() {
  case "$1" in
    *.sha256) printf 'text/plain; charset=utf-8' ;;
    *.sig)    printf 'text/plain; charset=utf-8' ;;
    *.raw)    printf 'application/octet-stream' ;;
    *)        printf 'application/octet-stream' ;;
  esac
}

usage() {
  cat >&2 <<EOF
Usage:
  upload-addons.sh --feature <name> --board <board> --os-version <ver> --dist <dir>

Publishes <dist>/<feature>-<board>-<os_version>.raw{,.sha256,.sig} to R2 at
${ADDON_PREFIX}/<os_version>/<board>/<feature>.raw{,.sha256,.sig}.

Env: DRY_RUN R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_ENDPOINT ADDON_PREFIX
EOF
}

upload_one() {
  local src="$1" key="$2" ctype
  [[ -s "${src}" ]] || die "missing/empty artifact: ${src}"
  ctype="$(content_type_for "${src}")"
  run_or_plan aws s3 cp \
    "${src}" \
    "s3://${R2_BUCKET:-}/${key}" \
    --endpoint-url "${R2_ENDPOINT:-}" \
    --content-type "${ctype}"
}

main() {
  local feature="" board="" os_version="" dist=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --feature)    feature="${2:-}";    shift 2 ;;
      --board)      board="${2:-}";      shift 2 ;;
      --os-version) os_version="${2:-}"; shift 2 ;;
      --dist)       dist="${2:-}";       shift 2 ;;
      -h | --help)  usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
  done

  [[ -n "${feature}" ]]    || { usage; die "--feature is required"; }
  [[ -n "${board}" ]]      || { usage; die "--board is required"; }
  [[ -n "${os_version}" ]] || { usage; die "--os-version is required"; }
  [[ -n "${dist}" ]]       || { usage; die "--dist is required"; }

  local stem="${feature}-${board}-${os_version}"
  local raw="${dist}/${stem}.raw"
  local sha="${raw}.sha256"
  local sig="${raw}.sig"

  # Trust gate FIRST — never publish an artifact the device could not trust.
  [[ -s "${raw}" ]] || die "no sysext to publish: ${raw} (run build-feature-sysext.sh first)"
  [[ -s "${sig}" ]] || die "refusing to publish UNSIGNED add-on: missing ${sig}"
  [[ -s "${sha}" ]] || die "refusing to publish add-on without integrity sidecar: missing ${sha}"

  if [[ -z "${R2_ACCESS_KEY_ID:-}" && -z "${DRY_RUN}" ]]; then
    die "R2_ACCESS_KEY_ID unset and DRY_RUN unset — nothing to upload with (set creds or DRY_RUN=1)"
  fi
  if [[ -n "${R2_ACCESS_KEY_ID:-}" ]]; then
    [[ -n "${R2_BUCKET:-}" ]]   || die "CI mode: R2_BUCKET unset"
    [[ -n "${R2_ENDPOINT:-}" ]] || die "CI mode: R2_ENDPOINT unset"
    [[ -n "${DRY_RUN}" ]] || require_cmd aws
    run_or_plan aws configure set aws_access_key_id "${R2_ACCESS_KEY_ID}"
    run_or_plan aws configure set aws_secret_access_key "${R2_SECRET_ACCESS_KEY:-}"
  fi

  local base="${ADDON_PREFIX}/${os_version}/${board}/${feature}"
  log_info "publishing add-on '${feature}' (board=${board} os_version=${os_version}) -> ${base}.raw{,.sha256,.sig}"
  upload_one "${raw}" "${base}.raw"
  upload_one "${sha}" "${base}.raw.sha256"
  upload_one "${sig}" "${base}.raw.sig"
  log_success "add-on published: ${base}.raw (+ .raw.sha256 + .raw.sig)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
