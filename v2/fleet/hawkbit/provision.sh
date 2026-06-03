#!/usr/bin/env bash
# CeraLive private hawkBit — one-time provisioning (Stage 7, task 40).
#
# Defines, via the hawkBit Management REST API, the objects that map a signed RAUC
# bundle on R2 to a hawkBit deployment with `compatible`-aware target filtering:
#
#   1. software-module TYPE  "rauc"      (key=rauc)        — the RAUC OS update unit
#   2. distribution-set TYPE "os-rauc"   (key=os-rauc)     — wraps that SM type
#   3. software MODULE       <name/version, type=rauc>
#   4. distribution SET      <name/version, type=os-rauc>  → contains the module
#   5. target FILTER         attribute.compatible==$RAUC_COMPATIBLE
#
# ARTIFACTS LIVE IN R2 — this script NEVER uploads a bundle blob to hawkBit. The
# device download link is rewritten to the R2 URL by the artifact URL handler
# (HAWKBIT_ARTIFACT_URL_PROTOCOLS_* in docker-compose.yml). R2 is the store; hawkBit
# holds metadata + the URL only. The bundle the example DS references is:
#       ${R2_BUNDLE_BASE_URL}/${EXAMPLE_BUNDLE_FILE}
#
# Idempotent: existing objects (HTTP 409 "already exists") are treated as success and
# the existing id is re-read. Safe to re-run.
#
# USAGE:
#   set -a; source .env; set +a          # load DB/admin/R2 vars
#   export HAWKBIT_API_PASSWORD='...'     # PLAINTEXT admin password (see note below)
#   ./provision.sh
#
# AUTH NOTE: .env stores HAWKBIT_ADMIN_PASSWORD as a {bcrypt} hash (what hawkBit verifies
# against). curl needs the PLAINTEXT. Provide it out-of-band via HAWKBIT_API_PASSWORD so the
# plaintext is never written to a committed file. If unset, the script prompts (no echo).

set -euo pipefail

# ─── config (from env / .env) ────────────────────────────────────────────────
HAWKBIT_URL="${HAWKBIT_URL:-http://127.0.0.1:8080}"
HAWKBIT_ADMIN_USER="${HAWKBIT_ADMIN_USER:?set HAWKBIT_ADMIN_USER (source your .env)}"
RAUC_COMPATIBLE="${RAUC_COMPATIBLE:-ceralive-rk3588}"
EXAMPLE_BUNDLE_FILE="${EXAMPLE_BUNDLE_FILE:-20260603T140027Z.raucb}"
EXAMPLE_BUNDLE_VERSION="${EXAMPLE_BUNDLE_VERSION:-2026.06.03}"
R2_BUNDLE_BASE_URL="${R2_BUNDLE_BASE_URL:?set R2_BUNDLE_BASE_URL (source your .env)}"

# Reject the forbidden default outright — defense against a careless .env.
if [ "${HAWKBIT_ADMIN_USER}" = "admin" ]; then
  echo "REFUSING TO RUN: HAWKBIT_ADMIN_USER=admin is the forbidden default. Pick another name." >&2
  exit 2
fi

# Plaintext admin password for curl Basic auth (NOT the bcrypt value from .env).
if [ -z "${HAWKBIT_API_PASSWORD:-}" ]; then
  read -r -s -p "hawkBit admin password (plaintext) for ${HAWKBIT_ADMIN_USER}: " HAWKBIT_API_PASSWORD
  echo
fi
if [ "${HAWKBIT_API_PASSWORD}" = "admin" ]; then
  echo "REFUSING TO RUN: password 'admin' is the forbidden default." >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

AUTH=(-u "${HAWKBIT_ADMIN_USER}:${HAWKBIT_API_PASSWORD}")
JSON=(-H 'Content-Type: application/json' -H 'Accept: application/json')

# ─── helpers ─────────────────────────────────────────────────────────────────
# api METHOD PATH [BODY] → echoes response body; fails (non-2xx, except 409) loudly.
api() {
  local method="$1" path="$2" body="${3:-}" resp code
  if [ -n "$body" ]; then
    resp="$(curl -sS -w $'\n%{http_code}' "${AUTH[@]}" "${JSON[@]}" \
            -X "$method" "${HAWKBIT_URL}${path}" -d "$body")"
  else
    resp="$(curl -sS -w $'\n%{http_code}' "${AUTH[@]}" "${JSON[@]}" \
            -X "$method" "${HAWKBIT_URL}${path}")"
  fi
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  case "$code" in
    2*) printf '%s' "$body" ;;
    401) echo "AUTH FAILED (401) — check HAWKBIT_ADMIN_USER / HAWKBIT_API_PASSWORD." >&2; exit 1 ;;
    409) printf '%s' "$body" ; return 9 ;;   # already exists — caller re-reads
    *)   echo "API $method $path → HTTP $code: $body" >&2; exit 1 ;;
  esac
}

# ensure_type ENDPOINT KEY JSON_ARRAY_BODY → echoes the type id (created or pre-existing).
ensure_type() {
  local endpoint="$1" key="$2" body="$3" out id
  if out="$(api POST "$endpoint" "$body")"; then
    id="$(printf '%s' "$out" | jq -r '.[0].id')"
  else
    # 409 → look it up by key
    out="$(api GET "${endpoint}?q=key==${key}")"
    id="$(printf '%s' "$out" | jq -r '.content[0].id')"
  fi
  printf '%s' "$id"
}

echo "==> hawkBit @ ${HAWKBIT_URL} as ${HAWKBIT_ADMIN_USER}"
echo "==> verifying auth is enforced ..."
anon="$(curl -sS -o /dev/null -w '%{http_code}' "${HAWKBIT_URL}/rest/v1/distributionsets" || true)"
[ "$anon" = "401" ] && echo "    OK anonymous → 401" || echo "    WARN anonymous → $anon (expected 401)"

# ─── 1. RAUC software-module type ────────────────────────────────────────────
echo "==> software-module type 'rauc'"
SM_TYPE_ID="$(ensure_type /rest/v1/softwaremoduletypes rauc \
  '[{"name":"RAUC Bundle","key":"rauc","description":"CeraLive signed RAUC .raucb OS update unit","maxAssignments":1}]')"
echo "    SM type id=${SM_TYPE_ID}"

# ─── 2. distribution-set type wrapping the RAUC SM type ───────────────────────
echo "==> distribution-set type 'os-rauc'"
DS_TYPE_ID="$(ensure_type /rest/v1/distributionsettypes os-rauc \
  "[{\"name\":\"CeraLive OS (RAUC)\",\"key\":\"os-rauc\",\"description\":\"Single RAUC bundle OS update\",\"mandatorymodules\":[{\"id\":${SM_TYPE_ID}}],\"optionalmodules\":[]}]")"
echo "    DS type id=${DS_TYPE_ID}"

# ─── 3. software module (the bundle's logical unit) ───────────────────────────
echo "==> software module ${EXAMPLE_BUNDLE_FILE} (v${EXAMPLE_BUNDLE_VERSION})"
SM_BODY="[{\"name\":\"ceralive-os\",\"version\":\"${EXAMPLE_BUNDLE_VERSION}\",\"type\":\"rauc\",\"description\":\"R2 artifact: ${R2_BUNDLE_BASE_URL}/${EXAMPLE_BUNDLE_FILE}\"}]"
if SM_OUT="$(api POST /rest/v1/softwaremodules "$SM_BODY")"; then
  SM_ID="$(printf '%s' "$SM_OUT" | jq -r '.[0].id')"
else
  SM_OUT="$(api GET "/rest/v1/softwaremodules?q=name==ceralive-os;version==${EXAMPLE_BUNDLE_VERSION}")"
  SM_ID="$(printf '%s' "$SM_OUT" | jq -r '.content[0].id')"
fi
echo "    SM id=${SM_ID}"

# NOTE ON ARTIFACTS (EXTERNAL R2 — NO BLOB UPLOAD):
#   We deliberately do NOT POST the .raucb to /rest/v1/softwaremodules/${SM_ID}/artifacts.
#   Uploading would put the (500 MB–2 GB) blob in hawkBit's LOCAL store — forbidden by task 40.
#   Instead the artifact URL handler (docker-compose.yml) rewrites the DDI download link to:
#       ${R2_BUNDLE_BASE_URL}/${EXAMPLE_BUNDLE_FILE}
#   and the device's rauc-hawkbit-updater pulls the bundle straight from R2.
#
#   If a future hawkBit version supports metadata-only artifact registration by URL, add it
#   here. Until then the SM description records the canonical R2 URL for operators.

# ─── 4. distribution set (the assignable unit) ────────────────────────────────
echo "==> distribution set ceralive-os ${EXAMPLE_BUNDLE_VERSION} (type os-rauc)"
DS_BODY="[{\"name\":\"ceralive-os\",\"version\":\"${EXAMPLE_BUNDLE_VERSION}\",\"type\":\"os-rauc\",\"requiredMigrationStep\":false,\"modules\":[{\"id\":${SM_ID}}]}]"
if DS_OUT="$(api POST /rest/v1/distributionsets "$DS_BODY")"; then
  DS_ID="$(printf '%s' "$DS_OUT" | jq -r '.[0].id')"
else
  DS_OUT="$(api GET "/rest/v1/distributionsets?q=name==ceralive-os;version==${EXAMPLE_BUNDLE_VERSION}")"
  DS_ID="$(printf '%s' "$DS_OUT" | jq -r '.content[0].id')"
fi
echo "    DS id=${DS_ID}"

# ─── 5. compatible-aware target filter ────────────────────────────────────────
# Devices report `compatible` as a target attribute when rauc-hawkbit-updater registers
# (task 41). This filter scopes any rollout to matching boards only — mirroring RAUC's own
# foreign-bundle guard (`rauc install` rejects a mismatched compatible). Defense in depth.
echo "==> target filter compatible==${RAUC_COMPATIBLE}"
TF_NAME="compatible-${RAUC_COMPATIBLE}"
TF_QUERY="attribute.compatible==${RAUC_COMPATIBLE}"
TF_BODY="$(jq -nc --arg n "$TF_NAME" --arg q "$TF_QUERY" '{name:$n,query:$q}')"
if TF_OUT="$(api POST /rest/v1/targetfilters "$TF_BODY")"; then
  TF_ID="$(printf '%s' "$TF_OUT" | jq -r '.id')"
else
  TF_OUT="$(api GET "/rest/v1/targetfilters?q=name==${TF_NAME}")"
  TF_ID="$(printf '%s' "$TF_OUT" | jq -r '.content[0].id')"
fi
echo "    target filter id=${TF_ID}  query='${TF_QUERY}'"

cat <<EOF

==> DONE.
    software-module type : rauc                 (id ${SM_TYPE_ID})
    distribution-set type: os-rauc              (id ${DS_TYPE_ID})
    software module      : ceralive-os ${EXAMPLE_BUNDLE_VERSION}   (id ${SM_ID})
    distribution set     : ceralive-os ${EXAMPLE_BUNDLE_VERSION}   (id ${DS_ID})
    target filter        : ${TF_QUERY}          (id ${TF_ID})
    artifact (R2, external): ${R2_BUNDLE_BASE_URL}/${EXAMPLE_BUNDLE_FILE}

Next (operator / ceralive-platform — task 43 seam): create a rollout binding DS ${DS_ID}
to the target filter:

  curl -u "\$HAWKBIT_ADMIN_USER:<pass>" -H 'Content-Type: application/json' \\
    -X POST ${HAWKBIT_URL}/rest/v1/rollouts -d '{
      "name": "${RAUC_COMPATIBLE}-${EXAMPLE_BUNDLE_VERSION}",
      "distributionSetId": ${DS_ID},
      "targetFilterQuery": "${TF_QUERY}",
      "amountGroups": 3
    }'
EOF
