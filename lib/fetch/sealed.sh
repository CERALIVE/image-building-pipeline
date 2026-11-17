#!/usr/bin/env bash
# Sealed delivery reuses the live signature/index/control validators, never overrides.
# shellcheck shell=bash

SEALED_INPUT_TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sealed-inputs.py"

input_fetch() {
  local url="$1" destination="$2"
  shift 2
  if [[ -n "${CERALIVE_SEALED_INPUTS:-}" ]]; then
    python3 "${SEALED_INPUT_TOOL}" copy "${url}" "${destination}"
  else
    curl "$@" -o "${destination}" "${url}"
  fi
}

sealed_repository() {
  [[ -z "${APT_CLIENT_CRT_B64:-}${APT_CLIENT_KEY_B64:-}${CERALIVE_FIRST_PARTY_LOCAL_DEBS_DIR:-}" ]] \
    || die "sealed inputs refuse direct credentials and local overrides"
  local name="$1" state="$2" params expected
  mkdir -p "${state}"
  local sealed_inrelease sealed_index sealed_keyring sealed_origin sealed_suite
  local sealed_component sealed_arch sealed_index_path sealed_max_age
  local -a sealed_fingerprints=()
  params="$(python3 "${SEALED_INPUT_TOOL}" repository "${name}")" || return 1
  eval "${params}"
  local configured_origin
  case "${name}" in
    firstparty) configured_origin="${APT_CERALIVE_URL}" ;;
    bsp) configured_origin="${ARMBIAN_APT_URL}" ;;
    *) die "unsupported sealed package repository: ${name}" ;;
  esac
  [[ "${sealed_origin}" == "${configured_origin}" ]] || die "sealed ${name} logical origin mismatch"
  [[ "${sealed_arch}" == "${ARCH}" ]] || die "sealed repository architecture mismatch"
  auth_verify_release_to_file "${sealed_keyring}" "${sealed_inrelease}" "${state}/Release" \
    "${sealed_fingerprints[@]}" || die "sealed ${name} signature rejected"
  python3 "${SEALED_INPUT_TOOL}" valid-release "${state}/Release" "${sealed_max_age}" "${name}" \
    || die "sealed ${name} metadata validity rejected"
  auth_release_has_identity "${state}/Release" "${sealed_suite}" "${sealed_component}" "${ARCH}" \
    || die "sealed ${name} signed repository identity mismatch"
  expected="$(index_release_digest "${state}/Release" "${sealed_index_path}")" \
    || die "sealed ${name} index absent from signed metadata"
  index_verify_digest "${sealed_index}" "${expected}" "sealed ${name} index" \
    || die "sealed ${name} index digest mismatch"
  index_decompress_gz "${sealed_index}" "${state}/Packages" || return 1
  _SEALED_INDEX="${state}/Packages"
}

sealed_stage_deb() {
  local spec="$1" all_ok="${2:-}" record filename digest version url tmp
  record="$(auth_lookup_package "${_SEALED_INDEX}" "${spec%%=*}" "${spec#*=}" "${ARCH}")" \
    || die "sealed package missing or ambiguous: ${spec}"
  IFS=$'\t' read -r filename digest version <<<"${record}"
  [[ "${version}" == "${spec#*=}" && "${filename}" != /* && "${filename}" != *..* \
      && "${filename}" != *://* && "${digest}" =~ ^[0-9a-f]{64}$ ]] \
    || die "sealed package index identity invalid: ${spec}"
  url="${_SEALED_BASE}/${filename#./}"
  tmp="$(mktemp "${_SEALED_DEBS}/.sealed-deb.XXXXXX")"
  local -a opts=()
  [[ -z "${all_ok}" ]] || opts+=("${all_ok}")
  if ! input_fetch "${url}" "${tmp}" ||
      ! auth_verify_file "${tmp}" "${digest}" ||
      ! assert_deb_identity "${tmp}" "${spec%%=*}" "${spec#*=}" "${ARCH}" "${opts[@]}"; then
    rm -f -- "${tmp}"
    die "sealed package signature/hash/control chain rejected: ${spec}"
  fi
  publish_staged_deb "${tmp}" "${_SEALED_DEBS}/$(basename "${filename}")"
}
