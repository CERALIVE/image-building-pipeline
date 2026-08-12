#!/bin/bash
#
# provision-token.sh — per-device hawkBit DDI enrollment for rauc-hawkbit-updater.
#
# Installed on-device as /usr/local/sbin/ceralive-hawkbit-provision and run once
# per boot by ceralive-hawkbit-provision.service (oneshot, RemainAfterExit). It is
# the SECURE-ENROLLMENT half of task 41: the image NEVER bakes a shared static
# token; this script provisions a per-device token onto /data on first boot.
#
# TOKEN STRATEGY (task 41 — "token written to /data on first boot", the preferred
# option). Operator drops an enrollment file on the data partition (NOT in the
# image, NOT in git):
#
#     /data/ceralive/hawkbit.conf   (mode 0600, key=value)
#       HAWKBIT_SERVER=hawkbit.internal.example:8080      # required
#       HAWKBIT_TARGET_TOKEN=<per-device DDI target token> # preferred, OR
#       HAWKBIT_GATEWAY_TOKEN=<tenant gateway token>       # alternative
#       HAWKBIT_PROVISION_URL=https://provision.example/…  # alternative: fetch token
#       HAWKBIT_TARGET_NAME=<id>        # optional; defaults to hostname
#       HAWKBIT_TENANT=DEFAULT          # optional
#       HAWKBIT_SSL=true                # optional
#       HAWKBIT_SSL_VERIFY=true         # optional
#
# This script then:
#   1. Resolves the token — from HAWKBIT_TARGET_TOKEN/HAWKBIT_GATEWAY_TOKEN, or by
#      fetching HAWKBIT_PROVISION_URL over mTLS (reusing the apt client cert) — and
#      persists it to /data/ceralive/hawkbit-token (mode 0600, the canonical store).
#   2. RENDERS the baked-in template /etc/rauc-hawkbit-updater/config.conf into the
#      EFFECTIVE config /data/ceralive/hawkbit-updater/config.conf (mode 0600), with
#      every @PLACEHOLDER@ filled, the auth line set to auth_token OR gateway_token,
#      and `compatible` taken from /etc/rauc/system.conf (board-aware, arch-neutral).
#
# The systemd drop-in (10-ceralive.conf) runs the updater with `-c` pointing at the
# rendered /data config and is GATED (ConditionPathExists) on it — so until this
# script succeeds the updater never starts. Idempotent: re-runs only rewrite when
# inputs changed.
#
# DUAL-TRACK: an inline twin is written by mkosi.images/runtime/mkosi.postinst.chroot
# (the wired runtime executor). Keep the two in sync.
#
# shellcheck shell=bash

set -euo pipefail

PROG="ceralive-hawkbit-provision"

ENROLL_CONF="${CERALIVE_HAWKBIT_ENROLL_CONF:-/data/ceralive/hawkbit.conf}"
TOKEN_FILE="${CERALIVE_HAWKBIT_TOKEN_FILE:-/data/ceralive/hawkbit-token}"
TEMPLATE="${CERALIVE_HAWKBIT_TEMPLATE:-/etc/rauc-hawkbit-updater/config.conf}"
EFFECTIVE="${CERALIVE_HAWKBIT_EFFECTIVE:-/data/ceralive/hawkbit-updater/config.conf}"
RAUC_SYSTEM_CONF="${CERALIVE_RAUC_SYSTEM_CONF:-/etc/rauc/system.conf}"
# mTLS client cert reused for an optional provisioning-endpoint fetch (task: "token
# fetched from a provisioning endpoint on first boot").
APT_CLIENT_CRT="${CERALIVE_APT_CLIENT_CRT:-/etc/apt/certs/client.crt}"
APT_CLIENT_KEY="${CERALIVE_APT_CLIENT_KEY:-/etc/apt/certs/client.key}"

log()  { printf '%s: %s\n' "${PROG}" "$*"; }
die()  { printf '%s: ERROR: %s\n' "${PROG}" "$*" >&2; exit 1; }

# read_compatible — the device's RAUC `compatible` (board-aware, single source of
# truth). Empty if system.conf is absent (un-provisioned RAUC) — non-fatal.
read_compatible() {
  [ -r "${RAUC_SYSTEM_CONF}" ] || { printf ''; return 0; }
  awk -F= '/^[[:space:]]*compatible[[:space:]]*=/{
             gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }' \
      "${RAUC_SYSTEM_CONF}"
}

# fetch_token_from_url URL — pull a per-device token over mTLS, echo it.
fetch_token_from_url() {
  local url="$1"
  command -v curl >/dev/null 2>&1 || die "curl missing — cannot fetch token from ${url}"
  local -a auth=()
  if [ -s "${APT_CLIENT_CRT}" ] && [ -s "${APT_CLIENT_KEY}" ]; then
    auth=(--cert "${APT_CLIENT_CRT}" --key "${APT_CLIENT_KEY}")
  fi
  local token
  token="$(curl -fsS "${auth[@]}" "${url}")" \
    || die "provisioning endpoint fetch failed: ${url}"
  token="$(printf '%s' "${token}" | tr -d '\r\n[:space:]')"
  [ -n "${token}" ] || die "provisioning endpoint returned an empty token: ${url}"
  printf '%s' "${token}"
}

main() {
  [ -r "${ENROLL_CONF}" ] || {
    log "no enrollment file at ${ENROLL_CONF} — device not yet enrolled; nothing to do"
    log "drop ${ENROLL_CONF} (HAWKBIT_SERVER + a token) on /data to enroll, then re-run"
    exit 0
  }

  # Load operator enrollment (key=value). Defaults first so missing keys degrade.
  local HAWKBIT_SERVER="" HAWKBIT_TARGET_TOKEN="" HAWKBIT_GATEWAY_TOKEN=""
  local HAWKBIT_PROVISION_URL="" HAWKBIT_TARGET_NAME="" HAWKBIT_TENANT="DEFAULT"
  local HAWKBIT_SSL="true" HAWKBIT_SSL_VERIFY="true"
  # shellcheck disable=SC1090
  . "${ENROLL_CONF}"

  [ -n "${HAWKBIT_SERVER}" ] || die "${ENROLL_CONF}: HAWKBIT_SERVER is required"

  # 1. Resolve + persist the token (target token preferred; else gateway; else fetch).
  local auth_kind="" token=""
  if [ -n "${HAWKBIT_TARGET_TOKEN}" ]; then
    auth_kind="auth_token"; token="${HAWKBIT_TARGET_TOKEN}"
  elif [ -n "${HAWKBIT_GATEWAY_TOKEN}" ]; then
    auth_kind="gateway_token"; token="${HAWKBIT_GATEWAY_TOKEN}"
  elif [ -n "${HAWKBIT_PROVISION_URL}" ]; then
    log "fetching per-device token from provisioning endpoint"
    auth_kind="auth_token"; token="$(fetch_token_from_url "${HAWKBIT_PROVISION_URL}")"
  elif [ -s "${TOKEN_FILE}" ]; then
    log "reusing previously provisioned token at ${TOKEN_FILE}"
    auth_kind="auth_token"; token="$(tr -d '\r\n[:space:]' <"${TOKEN_FILE}")"
  else
    die "${ENROLL_CONF}: provide HAWKBIT_TARGET_TOKEN, HAWKBIT_GATEWAY_TOKEN or HAWKBIT_PROVISION_URL"
  fi
  [ -n "${token}" ] || die "resolved an empty token — refusing to write config"

  install -d -m 0700 "$(dirname "${TOKEN_FILE}")"
  ( umask 077; printf '%s\n' "${token}" >"${TOKEN_FILE}" )
  chmod 0600 "${TOKEN_FILE}"
  log "token persisted to ${TOKEN_FILE} (mode 0600, on /data)"

  # 2. Render the effective config from the baked-in template.
  [ -r "${TEMPLATE}" ] || die "template missing: ${TEMPLATE}"
  local target_name="${HAWKBIT_TARGET_NAME}"
  [ -n "${target_name}" ] || target_name="$(hostname)"
  local compatible; compatible="$(read_compatible)"
  [ -n "${compatible}" ] || log "WARN: no compatible in ${RAUC_SYSTEM_CONF} — rendering empty (rollout target filter won't match until RAUC is provisioned)"

  local content auth_line
  content="$(cat "${TEMPLATE}")"
  auth_line="${auth_kind}                = ${token}"
  content="${content//@HAWKBIT_SERVER@/${HAWKBIT_SERVER}}"
  content="${content//@HAWKBIT_SSL@/${HAWKBIT_SSL}}"
  content="${content//@HAWKBIT_SSL_VERIFY@/${HAWKBIT_SSL_VERIFY}}"
  content="${content//@HAWKBIT_AUTH_LINE@/${auth_line}}"
  content="${content//@HAWKBIT_TENANT@/${HAWKBIT_TENANT}}"
  content="${content//@HAWKBIT_TARGET_NAME@/${target_name}}"
  content="${content//@COMPATIBLE@/${compatible}}"

  install -d -m 0700 "$(dirname "${EFFECTIVE}")"
  ( umask 077; printf '%s\n' "${content}" >"${EFFECTIVE}" )
  chmod 0600 "${EFFECTIVE}"
  log "rendered effective config → ${EFFECTIVE} (mode 0600; auth=${auth_kind}, target=${target_name}, compatible=${compatible:-<none>})"
  log "rauc-hawkbit-updater.service may now start (its ConditionPathExists is satisfied)"
}

main "$@"
