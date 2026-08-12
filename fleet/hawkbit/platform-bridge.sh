#!/usr/bin/env bash
# CeraLive — ceralive-platform ↔ hawkBit Management-API bridge (Stage 7, task 43).
#
# THE THIN, STABLE SEAM. A minimal bash wrapper over the hawkBit Management API
# endpoints documented in ../integration-contract.md (§3, §6). ceralive-platform
# can either SHELL OUT to this script or REPLICATE these curl/jq calls in its own
# backend (apps/api) — either way it codes against the CONTRACT, not hawkBit
# internals. This script adds ZERO ceralive-platform feature/UI code; it is the
# server-to-server bridge only.
#
# CONTRACT REFERENCE: ../integration-contract.md
#   list_targets            → §3.1  GET  /rest/v1/targets
#   get_target_status <cid> → §3.2  GET  /rest/v1/targets/{cid}(+/attributes,/installedDS,actions)
#   list_distribution_sets  → §3.3  GET  /rest/v1/distributionsets
#   trigger_rollout …       → §6    POST /rest/v1/rollouts (+ /start)
#
# AUTH (../integration-contract.md §2): HTTP Basic against hawkBit's built-in user
# store. .env stores HAWKBIT_ADMIN_PASSWORD as a {bcrypt} hash (what hawkBit verifies
# against); curl needs the PLAINTEXT. Provide it out-of-band via HAWKBIT_API_PASSWORD
# so plaintext is never written to a committed file. If unset, the script prompts
# (no echo). Same convention as provision.sh.
#
# NETWORK (../integration-contract.md §2.2): hawkBit binds 127.0.0.1:8080. Same-host
# platform uses the default; off-host platform sets HAWKBIT_URL to the private
# proxy/VPN/tunnel base URL. NEVER expose hawkBit publicly.
#
# USAGE:
#   set -a; source .env; set +a            # load HAWKBIT_URL / HAWKBIT_ADMIN_USER
#   export HAWKBIT_API_PASSWORD='...'       # PLAINTEXT admin/service password
#   ./platform-bridge.sh list_targets | jq .
#   ./platform-bridge.sh get_target_status rock5b-aabbccddeeff | jq .
#   ./platform-bridge.sh list_distribution_sets | jq .
#   ./platform-bridge.sh trigger_rollout 12 ceralive-rk3588 3
#
# Output is raw hawkBit JSON on stdout (pipe through jq); logs/errors go to stderr.

set -euo pipefail

# Source the v2 strict common lib (loud ERR trap, loggers, die, require_cmd).
# shellcheck source=../../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

# ─── config (../integration-contract.md §2) ───────────────────────────────────
HAWKBIT_URL="${HAWKBIT_URL:-http://127.0.0.1:8080}"
HAWKBIT_ADMIN_USER="${HAWKBIT_ADMIN_USER:?set HAWKBIT_ADMIN_USER (source your .env)}"

require_cmd curl
require_cmd jq

# Reject the forbidden default outright (matches provision.sh / task-40 policy).
if [ "${HAWKBIT_ADMIN_USER}" = "admin" ]; then
  die "HAWKBIT_ADMIN_USER=admin is the forbidden default — use the provisioned service user."
fi

# Plaintext password for Basic auth (NOT the bcrypt value at rest in .env).
if [ -z "${HAWKBIT_API_PASSWORD:-}" ]; then
  read -r -s -p "hawkBit Management API password (plaintext) for ${HAWKBIT_ADMIN_USER}: " HAWKBIT_API_PASSWORD
  echo >&2
fi
if [ "${HAWKBIT_API_PASSWORD}" = "admin" ]; then
  die "password 'admin' is the forbidden default."
fi

AUTH=(-u "${HAWKBIT_ADMIN_USER}:${HAWKBIT_API_PASSWORD}")
JSON=(-H 'Accept: application/json')

# ─── api METHOD PATH [BODY] → echoes response body on stdout; dies on non-2xx ──
api() {
  local method="$1" path="$2" body="${3:-}" resp code
  if [ -n "${body}" ]; then
    resp="$(curl -sS -w $'\n%{http_code}' "${AUTH[@]}" "${JSON[@]}" \
            -H 'Content-Type: application/json' \
            -X "${method}" "${HAWKBIT_URL}${path}" -d "${body}")"
  else
    resp="$(curl -sS -w $'\n%{http_code}' "${AUTH[@]}" "${JSON[@]}" \
            -X "${method}" "${HAWKBIT_URL}${path}")"
  fi
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  case "${code}" in
    2*) printf '%s' "${body}" ;;
    401) die "AUTH FAILED (401) — check HAWKBIT_ADMIN_USER / HAWKBIT_API_PASSWORD (contract §2)." ;;
    404) die "NOT FOUND (404): ${method} ${path} — unknown id?" ;;
    *)   die "API ${method} ${path} → HTTP ${code}: ${body}" ;;
  esac
}

# ─── list_targets — the fleet (contract §3.1) ─────────────────────────────────
# Optional args: LIMIT (default 50), OFFSET (default 0).
list_targets() {
  local limit="${1:-50}" offset="${2:-0}"
  log_info "list_targets limit=${limit} offset=${offset}"
  api GET "/rest/v1/targets?limit=${limit}&offset=${offset}"
}

# ─── get_target_status — one device's full read model (contract §3.2, §3.5, §7) ─
# Aggregates target + attributes + installedDS + assignedDS + latest action into one
# JSON object — the per-device view the platform's device-detail page consumes (§5.1).
# Sub-resources that are legitimately empty (no install yet) degrade to null, not error.
get_target_status() {
  local cid="${1:?usage: get_target_status <controllerId>}"
  local enc target attributes installed assigned actions
  enc="$(jq -rn --arg s "${cid}" '$s|@uri')"
  log_info "get_target_status ${cid}"

  target="$(api GET "/rest/v1/targets/${enc}")"
  attributes="$(api GET "/rest/v1/targets/${enc}/attributes")"
  installed="$(get_optional "/rest/v1/targets/${enc}/installedDS")"
  assigned="$(get_optional "/rest/v1/targets/${enc}/assignedDS")"
  actions="$(api GET "/rest/v1/targets/${enc}/actions?limit=1&sort=id:DESC")"

  jq -n \
    --argjson target "${target}" \
    --argjson attributes "${attributes}" \
    --argjson installed "${installed}" \
    --argjson assigned "${assigned}" \
    --argjson actions "${actions}" \
    '{
       controllerId:  $target.controllerId,
       updateStatus:  $target.updateStatus,
       pollStatus:    $target.pollStatus,
       attributes:    ($attributes.attributes // {}),
       installedDS:   (if $installed == null then null else {name:$installed.name, version:$installed.version} end),
       assignedDS:    (if $assigned  == null then null else {name:$assigned.name,  version:$assigned.version}  end),
       latestAction:  ($actions.content[0] // null)
     }'
}

# get_optional PATH → JSON body on 2xx, the literal `null` on 404 (sub-resource absent).
# A device with no install/assignment yet returns 404 for installedDS/assignedDS — that
# is "none", not a failure, so we map it to null instead of dying (contract §4.2).
get_optional() {
  local path="$1" resp code body
  resp="$(curl -sS -w $'\n%{http_code}' "${AUTH[@]}" "${JSON[@]}" \
          -X GET "${HAWKBIT_URL}${path}")"
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  case "${code}" in
    2*) printf '%s' "${body}" ;;
    404) printf 'null' ;;
    401) die "AUTH FAILED (401) — check credentials (contract §2)." ;;
    *)   die "API GET ${path} → HTTP ${code}: ${body}" ;;
  esac
}

# ─── list_distribution_sets — available OS bundles (contract §3.3) ────────────
list_distribution_sets() {
  local limit="${1:-50}" offset="${2:-0}"
  log_info "list_distribution_sets limit=${limit} offset=${offset}"
  api GET "/rest/v1/distributionsets?limit=${limit}&offset=${offset}"
}

# ─── trigger_rollout — create + start a compatible-scoped rollout (contract §6) ─
# Args: DS_ID  COMPATIBLE  [AMOUNT_GROUPS=3]  [NAME=ceralive-<compatible>-<date>]
# Creates a grouped, threshold-guarded rollout filtered by attribute.compatible, then
# STARTS it (hawkBit creates rollouts paused — both steps are required, §3.4/§6). Emits
# the started rollout's status JSON. Grouping + errorAction=PAUSEROLLOUT are the first
# safety net (device A/B rollback is the second) — never a single ungrouped blast (§6).
trigger_rollout() {
  local ds_id="${1:?usage: trigger_rollout <dsId> <compatible> [amountGroups] [name]}"
  local compatible="${2:?usage: trigger_rollout <dsId> <compatible> [amountGroups] [name]}"
  local groups="${3:-3}" name="${4:-}"
  if [ -z "${name}" ]; then
    name="ceralive-${compatible}-$(date -u +%Y%m%dT%H%M%SZ)"
  fi

  local body rid
  body="$(jq -nc \
    --arg name "${name}" \
    --argjson ds "${ds_id}" \
    --arg q "attribute.compatible==${compatible}" \
    --argjson groups "${groups}" \
    '{
       name: $name,
       distributionSetId: $ds,
       targetFilterQuery: $q,
       amountGroups: $groups,
       successCondition: {condition:"THRESHOLD", expression:"80"},
       successAction:    {action:"NEXTGROUP",    expression:""},
       errorCondition:   {condition:"THRESHOLD", expression:"20"},
       errorAction:      {action:"PAUSEROLLOUT", expression:""}
     }')"

  log_info "trigger_rollout name='${name}' dsId=${ds_id} compatible=${compatible} groups=${groups}"
  rid="$(api POST /rest/v1/rollouts "${body}" | jq -r '.id')"
  if [ -z "${rid}" ] || [ "${rid}" = "null" ]; then
    die "rollout creation returned no id (contract §6 step 2)."
  fi
  log_info "created rollout id=${rid}; starting (contract §6 step 4) ..."
  api POST "/rest/v1/rollouts/${rid}/start" >/dev/null
  log_success "rollout ${rid} started"
  api GET "/rest/v1/rollouts/${rid}"
}

# ─── dispatch ─────────────────────────────────────────────────────────────────
usage() {
  cat >&2 <<'EOF'
platform-bridge.sh — ceralive-platform ↔ hawkBit Management-API bridge (contract §3/§6)

  list_targets [limit] [offset]
  get_target_status <controllerId>
  list_distribution_sets [limit] [offset]
  trigger_rollout <dsId> <compatible> [amountGroups] [name]

Env: HAWKBIT_URL (default http://127.0.0.1:8080), HAWKBIT_ADMIN_USER (required),
     HAWKBIT_API_PASSWORD (plaintext; prompted if unset).
See ../integration-contract.md for the full endpoint/auth/read-model contract.
EOF
  exit 2
}

main() {
  local cmd="${1:-}"
  [ -n "${cmd}" ] || usage
  shift
  case "${cmd}" in
    list_targets)           list_targets "$@" ;;
    get_target_status)      get_target_status "$@" ;;
    list_distribution_sets) list_distribution_sets "$@" ;;
    trigger_rollout)        trigger_rollout "$@" ;;
    -h|--help|help)         usage ;;
    *) die "unknown command '${cmd}' (try: list_targets|get_target_status|list_distribution_sets|trigger_rollout)" ;;
  esac
}

# Run only when executed directly; allow sourcing for unit tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
