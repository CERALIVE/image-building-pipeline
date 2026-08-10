#!/usr/bin/env bash
#
# verify-bench-rauc-trust.sh — decide, per board, whether a candidate RAUC
# signer may be used for A/B deployment, or whether the physical path must be
# taken instead.
#
# WHY this exists: "we have a signing key" is not the question. The question is
# whether THAT key's leaf certificate, verified against the root THAT board
# actually carries in its installed keyring, satisfies what the device's own
# `rauc` will demand at install time. A signer that fails any leg is not a
# smaller problem than no signer at all — it is a bundle the board rejects
# after the update has already been staged.
#
# Every check is a read-only cryptographic operation. Nothing here writes to a
# board, mints a certificate, or touches any PKI. Selecting a signer is a
# decision recorded in a verdict file; issuing one is a separate, explicit
# rotation decision this tool must never make.
#
# THE EKUs ARE READ FROM THE OFFERED LEAF, NEVER ASSUMED FROM ITS DIRECTORY.
# A PKI generator that emits dual-EKU leaves today says nothing about the leaf
# a given directory happens to hold, and a board's installed keyring may still
# anchor an older single-EKU leaf. So `leaf_eku_list` parses the certificate in
# front of it and the verdict is computed from that, with the empirical list
# printed into the verdict for the reader.
#
# THE RAUC 1.8 PURPOSE LEG IS NOT REDUNDANT WITH THE EKU LEG. rauc 1.8 predates
# `check-purpose=codesign` entirely, so its CMS_verify() falls back to
# OpenSSL's default `smime_sign` purpose — under which a codeSigning-ONLY leaf
# is rejected with "unsuitable certificate purpose" while an emailProtection
# leaf passes. `emailProtection` is therefore what makes an install succeed on
# the shipped device, and `codeSigning` is what keeps a future rauc >= 1.9
# strict path working. Production mode requires BOTH; a leaf carrying only one
# is a real, expected finding that routes to the physical path rather than an
# error in this script.
#
# Usage:
#   verify-bench-rauc-trust.sh --preflight-root <dir> --candidate-pki <dir> \
#       --out <path> [--env-file <path>] [--board <board>]...
#   verify-bench-rauc-trust.sh --self-test
#
# `--candidate-pki` is a required, generic path argument with no default: this
# repo is built and tested standalone, so it may never resolve a bench PKI by
# proximity to its own checkout.
#
# Exit codes:
#   0  a verdict was written for every board (a PHYSICAL verdict is a RESULT)
#   1  no usable verdict could be produced (or a self-test leg failed)
#   2  usage / unreadable input
#
# shellcheck shell=bash

set -uo pipefail

SCHEMA_VERSION=1
TOOL_NAME="ci/verify-bench-rauc-trust.sh"

usage() { sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
fail() { printf 'verify-bench-rauc-trust: %s\n' "$*" >&2; }

json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

cert_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null \
    | sed 's/^.*Fingerprint=//' | tr 'A-F' 'a-f'
}
cert_subject() { openssl x509 -in "$1" -noout -subject 2>/dev/null | sed 's/^subject=//'; }
cert_issuer()  { openssl x509 -in "$1" -noout -issuer  2>/dev/null | sed 's/^issuer=//'; }
cert_not_after() { openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/^notAfter=//'; }

# leaf_eku_list <cert> — the leaf's OWN extendedKeyUsage, normalised to the
# OpenSSL short names, one per line. Empty output means the certificate carries
# no EKU extension at all, which is a distinct finding from carrying the wrong
# one and is reported as such.
leaf_eku_list() {
  openssl x509 -in "$1" -noout -ext extendedKeyUsage 2>/dev/null \
    | sed -n '2,$p' \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed 's/^Code Signing$/codeSigning/; s/^E-mail Protection$/emailProtection/;
           s/^TLS Web Server Authentication$/serverAuth/;
           s/^TLS Web Client Authentication$/clientAuth/;
           s/^Time Stamping$/timeStamping/;
           s/^OCSP Signing$/OCSPSigning/' \
    | grep -v '^$'
}

leaf_key_usage_list() {
  openssl x509 -in "$1" -noout -ext keyUsage 2>/dev/null \
    | sed -n '2,$p' \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed 's/^Digital Signature$/digitalSignature/; s/^Key Encipherment$/keyEncipherment/;
           s/^Certificate Sign$/keyCertSign/; s/^CRL Sign$/cRLSign/' \
    | grep -v '^$'
}

list_contains() {
  local needle="$1" line
  while IFS= read -r line; do [[ "${line}" == "${needle}" ]] && return 0; done <<<"${2-}"
  return 1
}

# pki_member <dir> <name>... — the first candidate filename that exists. A bench
# PKI and the repo's dev fixture use different spellings for the same role
# (`intermediate-ca.pem` vs `dev-intermediate-ca.pem` vs a bundled `chain.pem`),
# and refusing to look is not a safety property — every certificate found here
# is still verified on its own merits below.
pki_member() {
  local dir="$1"; shift
  local name
  for name in "$@"; do
    [[ -s "${dir}/${name}" ]] && { printf '%s' "${dir}/${name}"; return 0; }
  done
  printf '%s' "${dir}/$1"
}

# A trust anchor that names itself NON-PRODUCTION may never yield a production
# build mode, however cryptographically sound the chain is. The fixture
# generator bakes that marker into its subjects precisely so it is detectable,
# and a bench board flashed with the CI fixture root is exactly the case that
# would otherwise produce a technically-valid "production" claim about a test
# root of trust.
subject_is_non_production() {
  grep -qi 'NON-PRODUCTION\|TEST ROOT\|self-test' <<<"${1-}"
}

json_array_from_lines() {
  local first=1 line
  printf '['
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    [[ "${first}" == 1 ]] || printf ','
    first=0
    printf '"%s"' "$(json_escape "${line}")"
  done <<<"${1-}"
  printf ']'
}

# ---------------------------------------------------------------------------
# evaluate_board <board> <installed-root-pem> <candidate-pki-dir>
#
# Sets the EVAL_* globals rather than printing, so the caller can both render
# the verdict JSON and decide whether to write the signing env file without
# re-running any cryptographic check.
# ---------------------------------------------------------------------------
EVAL_VERDICT="" EVAL_BUILD_MODE="" EVAL_JSON=""
evaluate_board() {
  local board="$1" installed_root="$2" pki="$3"
  local leaf key inter candidate_root
  leaf="$(pki_member "${pki}" leaf-signing.pem dev-leaf-signing.pem)"
  key="$(pki_member "${pki}" leaf-signing.key dev-leaf-signing.key)"
  inter="$(pki_member "${pki}" intermediate-ca.pem dev-intermediate-ca.pem chain.pem)"
  candidate_root="$(pki_member "${pki}" root-ca.pem dev-root-ca.pem)"

  local reasons=() eku_list="" ku_list=""
  local have_installed_root=false have_candidate=false
  local key_match=false has_digital_signature=false
  local has_email_protection=false has_code_signing=false
  local chain_ok=false smimesign_ok=false
  local installed_fp="" leaf_fp="" candidate_root_fp=""
  local chain_output="" smimesign_output=""

  if [[ -s "${installed_root}" ]] && openssl x509 -in "${installed_root}" -noout >/dev/null 2>&1; then
    have_installed_root=true
    installed_fp="$(cert_fingerprint "${installed_root}")"
  else
    reasons+=("no readable installed keyring root for ${board}")
  fi

  if [[ -s "${leaf}" && -s "${key}" && -s "${inter}" ]]; then
    have_candidate=true
    leaf_fp="$(cert_fingerprint "${leaf}")"
    [[ -s "${candidate_root}" ]] && candidate_root_fp="$(cert_fingerprint "${candidate_root}")"
    eku_list="$(leaf_eku_list "${leaf}")"
    ku_list="$(leaf_key_usage_list "${leaf}")"
  else
    reasons+=("candidate PKI ${pki} is missing leaf-signing.pem, leaf-signing.key or intermediate-ca.pem")
  fi

  if [[ "${have_candidate}" == true ]]; then
    local leaf_pub key_pub
    leaf_pub="$(openssl x509 -in "${leaf}" -noout -pubkey 2>/dev/null)"
    key_pub="$(openssl pkey -in "${key}" -pubout 2>/dev/null)"
    if [[ -n "${leaf_pub}" && "${leaf_pub}" == "${key_pub}" ]]; then
      key_match=true
    else
      reasons+=("leaf-signing.key does not match leaf-signing.pem")
    fi

    if list_contains digitalSignature "${ku_list}"; then
      has_digital_signature=true
    else
      reasons+=("leaf keyUsage lacks digitalSignature")
    fi

    if [[ -z "${eku_list}" ]]; then
      reasons+=("leaf carries NO extendedKeyUsage extension at all (empirically read from the offered certificate)")
    else
      list_contains emailProtection "${eku_list}" && has_email_protection=true
      list_contains codeSigning "${eku_list}" && has_code_signing=true
      [[ "${has_email_protection}" == true ]] || \
        reasons+=("leaf EKU lacks emailProtection, which is what satisfies rauc 1.8's default smime_sign purpose")
      [[ "${has_code_signing}" == true ]] || \
        reasons+=("leaf EKU lacks codeSigning, which a rauc >= 1.9 check-purpose=codesign path requires")
    fi
  fi

  if [[ "${have_installed_root}" == true && "${have_candidate}" == true ]]; then
    chain_output="$(openssl verify -CAfile "${installed_root}" -untrusted "${inter}" "${leaf}" 2>&1)"
    if (( $? == 0 )); then chain_ok=true; else
      reasons+=("chain does not terminate at the root installed on ${board}: ${chain_output}")
    fi
    smimesign_output="$(openssl verify -purpose smimesign -CAfile "${installed_root}" \
      -untrusted "${inter}" "${leaf}" 2>&1)"
    if (( $? == 0 )); then smimesign_ok=true; else
      reasons+=("leaf fails OpenSSL's smimesign purpose, which is exactly the default purpose rauc 1.8 applies: ${smimesign_output}")
    fi
  fi

  local production_trust_anchor=true
  if subject_is_non_production "$(cert_subject "${installed_root}")" \
     || subject_is_non_production "$(cert_subject "${leaf}")"; then
    production_trust_anchor=false
    reasons+=("the trust anchor or signer identifies itself as NON-PRODUCTION, so no production build mode may be claimed from it regardless of chain validity")
  fi

  if [[ "${have_installed_root}" == true && "${have_candidate}" == true \
        && "${key_match}" == true && "${has_digital_signature}" == true \
        && "${has_email_protection}" == true && "${has_code_signing}" == true \
        && "${chain_ok}" == true && "${smimesign_ok}" == true ]]; then
    EVAL_VERDICT="RAUC"
    if [[ "${production_trust_anchor}" == true ]]; then
      EVAL_BUILD_MODE="production"
    else
      EVAL_BUILD_MODE="development"
    fi
  else
    EVAL_VERDICT="PHYSICAL"
    EVAL_BUILD_MODE="development"
  fi

  local reasons_json first=1 r
  reasons_json='['
  for r in "${reasons[@]+"${reasons[@]}"}"; do
    [[ "${first}" == 1 ]] || reasons_json+=','
    first=0
    reasons_json+="\"$(json_escape "${r}")\""
  done
  reasons_json+=']'

  EVAL_JSON="$(cat <<EOF
    {
      "board": "$(json_escape "${board}")",
      "verdict": "${EVAL_VERDICT}",
      "build_mode": "${EVAL_BUILD_MODE}",
      "installed_root": {
        "path": "$(json_escape "${installed_root}")",
        "present": ${have_installed_root},
        "sha256_fingerprint": "$(json_escape "${installed_fp}")",
        "subject": "$(json_escape "$(cert_subject "${installed_root}")")"
      },
      "candidate_signer": {
        "pki_dir": "$(json_escape "${pki}")",
        "present": ${have_candidate},
        "leaf_sha256_fingerprint": "$(json_escape "${leaf_fp}")",
        "leaf_subject": "$(json_escape "$(cert_subject "${leaf}")")",
        "leaf_issuer": "$(json_escape "$(cert_issuer "${leaf}")")",
        "leaf_not_after": "$(json_escape "$(cert_not_after "${leaf}")")",
        "candidate_root_sha256_fingerprint": "$(json_escape "${candidate_root_fp}")",
        "extended_key_usage_observed": $(json_array_from_lines "${eku_list}"),
        "key_usage_observed": $(json_array_from_lines "${ku_list}")
      },
      "checks": {
        "installed_root_readable": ${have_installed_root},
        "candidate_material_present": ${have_candidate},
        "leaf_key_match": ${key_match},
        "key_usage_digital_signature": ${has_digital_signature},
        "eku_email_protection": ${has_email_protection},
        "eku_code_signing": ${has_code_signing},
        "chain_terminates_at_installed_root": ${chain_ok},
        "rauc18_smimesign_purpose": ${smimesign_ok},
        "production_trust_anchor": ${production_trust_anchor}
      },
      "reasons": ${reasons_json}
    }
EOF
)"
}

# ---------------------------------------------------------------------------
run_verify() {
  local preflight_root="$1" pki="$2" out="$3" env_file="$4"; shift 4
  local -a boards=("$@")

  [[ -d "${preflight_root}" ]] || { fail "no preflight root: ${preflight_root}"; return 2; }
  [[ -d "${pki}" ]] || { fail "no candidate PKI dir: ${pki}"; return 2; }
  command -v openssl >/dev/null 2>&1 || { fail "openssl is required"; return 2; }

  if (( ${#boards[@]} == 0 )); then
    local f
    for f in "${preflight_root}"/*-preflight.json; do
      [[ -e "${f}" ]] || continue
      boards+=("$(basename "${f}" -preflight.json)")
    done
  fi
  (( ${#boards[@]} > 0 )) || { fail "no *-preflight.json under ${preflight_root}"; return 2; }

  local board entries="" first=1 rauc_board="" rauc_keyring=""
  local reachable_count=0
  for board in "${boards[@]}"; do
    local pf="${preflight_root}/${board}-preflight.json"
    local pem="${preflight_root}/${board}-keyring.pem"
    if [[ ! -s "${pf}" ]]; then
      fail "no preflight capture for ${board}"; return 2
    fi
    if grep -q '"reachable": false' "${pf}"; then
      local err
      err="$(sed -n 's/.*"error": "\(.*\)",/\1/p' "${pf}" | head -1)"
      [[ "${first}" == 1 ]] || entries+=$',\n'
      first=0
      entries+="$(cat <<EOF
    {
      "board": "$(json_escape "${board}")",
      "verdict": "UNKNOWN",
      "build_mode": null,
      "reachable": false,
      "reasons": ["board was not reachable at capture time; no trust verdict can be computed: $(json_escape "${err}")"]
    }
EOF
)"
      continue
    fi
    reachable_count=$((reachable_count + 1))
    evaluate_board "${board}" "${pem}" "${pki}"
    [[ "${first}" == 1 ]] || entries+=$',\n'
    first=0
    entries+="${EVAL_JSON}"
    if [[ "${EVAL_VERDICT}" == RAUC && -z "${rauc_board}" ]]; then
      rauc_board="${board}"
      rauc_keyring="$(cd "$(dirname "${pem}")" && pwd)/$(basename "${pem}")"
    fi
  done

  (( reachable_count > 0 )) || { fail "no reachable board had a capture to evaluate"; return 1; }

  mkdir -p "$(dirname "${out}")"
  {
    printf '{\n'
    printf '  "schema_version": %s,\n' "${SCHEMA_VERSION}"
    printf '  "verify_tool": "%s",\n' "$(json_escape "${TOOL_NAME}")"
    printf '  "evaluated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "candidate_pki_dir": "%s",\n' "$(json_escape "${pki}")"
    printf '  "boards": [\n%s\n  ]\n' "${entries}"
    printf '}\n'
  } >"${out}"

  if [[ -n "${env_file}" ]]; then
    if [[ -n "${rauc_board}" ]]; then
      mkdir -p "$(dirname "${env_file}")"
      ( umask 077
        {
          printf '# written by %s — PATHS ONLY, never key values\n' "${TOOL_NAME}"
          printf 'CERALIVE_RAUC_PKI_DIR=%s\n' "$(cd "${pki}" && pwd)"
          printf 'RAUC_KEYRING_FILE=%s\n' "${rauc_keyring}"
        } >"${env_file}" )
      chmod 600 "${env_file}"
      printf 'verify-bench-rauc-trust: RAUC verdict for %s — wrote %s (mode 0600)\n' \
        "${rauc_board}" "${env_file}"
    else
      printf 'verify-bench-rauc-trust: no board reached a RAUC verdict — %s deliberately NOT written\n' \
        "${env_file}" >&2
    fi
  fi

  printf 'verify-bench-rauc-trust: wrote %s\n' "${out}"
  return 0
}

# ---------------------------------------------------------------------------
# self-test — real certificates, real openssl, four candidate shapes.
# ---------------------------------------------------------------------------
self_test() {
  local failures=0 tmp
  tmp="$(mktemp -d)" || { fail "mktemp -d failed"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  check() {
    local label="$1"; shift
    if "$@"; then printf '  ok   %s\n' "${label}"
    else printf '  FAIL %s\n' "${label}"; failures=$((failures + 1)); fi
  }

  mk_root() {
    local dir="$1" cn="$2"
    mkdir -p "${dir}"
    openssl req -x509 -newkey rsa:2048 -keyout "${dir}/root-ca.key" \
      -out "${dir}/root-ca.pem" -days 5 -nodes -subj "/CN=${cn}" \
      -addext 'basicConstraints=critical,CA:TRUE' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
  }
  mk_intermediate() {
    local dir="$1"
    openssl req -newkey rsa:2048 -keyout "${dir}/intermediate-ca.key" -nodes \
      -out "${dir}/inter.csr" -subj '/CN=bench intermediate CA' >/dev/null 2>&1
    printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' \
      >"${dir}/inter.ext"
    openssl x509 -req -in "${dir}/inter.csr" -CA "${dir}/root-ca.pem" \
      -CAkey "${dir}/root-ca.key" -CAcreateserial -days 4 \
      -extfile "${dir}/inter.ext" -out "${dir}/intermediate-ca.pem" >/dev/null 2>&1
  }
  mk_leaf() {
    local dir="$1" eku="$2"
    openssl req -newkey rsa:2048 -keyout "${dir}/leaf-signing.key" -nodes \
      -out "${dir}/leaf.csr" -subj '/CN=bench signing leaf' >/dev/null 2>&1
    { printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n'
      [[ -z "${eku}" ]] || printf 'extendedKeyUsage=%s\n' "${eku}"; } >"${dir}/leaf.ext"
    openssl x509 -req -in "${dir}/leaf.csr" -CA "${dir}/intermediate-ca.pem" \
      -CAkey "${dir}/intermediate-ca.key" -CAcreateserial -days 3 \
      -extfile "${dir}/leaf.ext" -out "${dir}/leaf-signing.pem" >/dev/null 2>&1
  }

  # The board's installed root, and the preflight capture that carries it.
  local pfroot="${tmp}/preflight"
  mkdir -p "${pfroot}"
  mk_root "${tmp}/installed" "bench installed root CA"
  cp "${tmp}/installed/root-ca.pem" "${pfroot}/selftest-board-keyring.pem"
  printf '{\n  "board": "selftest-board",\n  "reachable": true,\n  "inventory": {}\n}\n' \
    >"${pfroot}/selftest-board-preflight.json"

  # (a) dual-EKU leaf under the installed root
  local dual="${tmp}/pki-dual"
  mkdir -p "${dual}"
  cp "${tmp}/installed/root-ca.pem" "${dual}/root-ca.pem"
  cp "${tmp}/installed/root-ca.key" "${dual}/root-ca.key"
  mk_intermediate "${dual}"; mk_leaf "${dual}" 'emailProtection,codeSigning'

  # (b) THE NEGATIVE FIXTURE: codeSigning-only, same root. This is the real
  # shape a bench PKI can present, and it must be REJECTED for production while
  # still producing a coherent PHYSICAL/development verdict.
  local csonly="${tmp}/pki-codesigning-only"
  mkdir -p "${csonly}"
  cp "${tmp}/installed/root-ca.pem" "${csonly}/root-ca.pem"
  cp "${tmp}/installed/root-ca.key" "${csonly}/root-ca.key"
  mk_intermediate "${csonly}"; mk_leaf "${csonly}" 'codeSigning'

  # (c) dual-EKU leaf under a DIFFERENT root
  local foreign="${tmp}/pki-foreign"
  mk_root "${foreign}" "bench foreign root CA"
  mk_intermediate "${foreign}"; mk_leaf "${foreign}" 'emailProtection,codeSigning'

  # (d) dual-EKU leaf whose private key does not match it
  local mismatch="${tmp}/pki-key-mismatch"
  mkdir -p "${mismatch}"
  cp "${dual}"/{root-ca.pem,intermediate-ca.pem,leaf-signing.pem} "${mismatch}/"
  openssl genrsa -out "${mismatch}/leaf-signing.key" 2048 >/dev/null 2>&1

  # (e) no EKU extension at all
  local noeku="${tmp}/pki-no-eku"
  mkdir -p "${noeku}"
  cp "${tmp}/installed/root-ca.pem" "${noeku}/root-ca.pem"
  cp "${tmp}/installed/root-ca.key" "${noeku}/root-ca.key"
  mk_intermediate "${noeku}"; mk_leaf "${noeku}" ''

  run_case() {
    local pki="$1" out="$2" env="$3"
    run_verify "${pfroot}" "${pki}" "${out}" "${env}" >/dev/null 2>&1
  }

  run_case "${dual}" "${tmp}/dual.json" "${tmp}/dual.env"
  check "dual-EKU leaf under the installed root yields RAUC" \
    bash -c 'grep -Fq "\"verdict\": \"RAUC\"" "$1"' _ "${tmp}/dual.json"
  check "dual-EKU leaf yields build_mode production" \
    bash -c 'grep -Fq "\"build_mode\": \"production\"" "$1"' _ "${tmp}/dual.json"
  check "RAUC verdict writes the signing env file" \
    bash -c '[[ -s "$1" ]]' _ "${tmp}/dual.env"
  check "the signing env file is mode 0600" \
    bash -c '[[ "$(stat -c %a "$1")" == 600 ]]' _ "${tmp}/dual.env"
  check "the signing env file carries PATHS ONLY, never key material" \
    bash -c '! grep -q "PRIVATE KEY" "$1" && grep -q "^CERALIVE_RAUC_PKI_DIR=" "$1" && grep -q "^RAUC_KEYRING_FILE=" "$1"' _ "${tmp}/dual.env"
  check "both observed EKUs are recorded empirically" \
    bash -c 'grep -Fq "\"extended_key_usage_observed\": [\"emailProtection\",\"codeSigning\"]" "$1"' _ "${tmp}/dual.json"

  run_case "${csonly}" "${tmp}/cs.json" "${tmp}/cs.env"
  check "NEGATIVE: a codeSigning-only leaf is refused for production" \
    bash -c '! grep -Fq "\"build_mode\": \"production\"" "$1"' _ "${tmp}/cs.json"
  check "NEGATIVE: a codeSigning-only leaf routes to PHYSICAL, not a crash" \
    bash -c 'grep -Fq "\"verdict\": \"PHYSICAL\"" "$1"' _ "${tmp}/cs.json"
  check "NEGATIVE: a codeSigning-only leaf routes to development mode" \
    bash -c 'grep -Fq "\"build_mode\": \"development\"" "$1"' _ "${tmp}/cs.json"
  check "NEGATIVE: the missing EKU is named in the reasons" \
    bash -c 'grep -Fq "leaf EKU lacks emailProtection" "$1"' _ "${tmp}/cs.json"
  check "NEGATIVE: its chain to the installed root still verifies (the EKU is the ONLY defect)" \
    bash -c 'grep -Fq "\"chain_terminates_at_installed_root\": true" "$1"' _ "${tmp}/cs.json"
  check "NEGATIVE: no signing env file is written without a RAUC verdict" \
    bash -c '[[ ! -e "$1" ]]' _ "${tmp}/cs.env"

  run_case "${foreign}" "${tmp}/foreign.json" "${tmp}/foreign.env"
  check "a chain to a DIFFERENT root is rejected" \
    bash -c 'grep -Fq "\"chain_terminates_at_installed_root\": false" "$1"' _ "${tmp}/foreign.json"
  check "a chain to a different root routes to PHYSICAL" \
    bash -c 'grep -Fq "\"verdict\": \"PHYSICAL\"" "$1"' _ "${tmp}/foreign.json"

  run_case "${mismatch}" "${tmp}/mismatch.json" "${tmp}/mismatch.env"
  check "a leaf whose key does not match it is rejected" \
    bash -c 'grep -Fq "\"leaf_key_match\": false" "$1"' _ "${tmp}/mismatch.json"

  run_case "${noeku}" "${tmp}/noeku.json" "${tmp}/noeku.env"
  check "a leaf with NO EKU extension is reported as such, distinctly" \
    bash -c 'grep -Fq "carries NO extendedKeyUsage extension at all" "$1"' _ "${tmp}/noeku.json"
  check "a leaf with no EKU routes to PHYSICAL/development" \
    bash -c 'grep -Fq "\"verdict\": \"PHYSICAL\"" "$1" && grep -Fq "\"build_mode\": \"development\"" "$1"' _ "${tmp}/noeku.json"

  # (f) a cryptographically PERFECT chain anchored at a self-declared
  # NON-PRODUCTION root: RAUC deployment is legitimate, a production claim is
  # not. This is the exact shape a bench board flashed from the CI fixture PKI
  # presents, so getting it wrong would mislabel a whole hardware campaign.
  local nonprod_pf="${tmp}/preflight-nonprod"
  mkdir -p "${nonprod_pf}"
  mk_root "${tmp}/nonprod" "CeraLive CI Test Root CA (NON-PRODUCTION)"
  cp "${tmp}/nonprod/root-ca.pem" "${nonprod_pf}/nonprod-board-keyring.pem"
  printf '{\n  "board": "nonprod-board",\n  "reachable": true,\n  "inventory": {}\n}\n' \
    >"${nonprod_pf}/nonprod-board-preflight.json"
  mk_intermediate "${tmp}/nonprod"; mk_leaf "${tmp}/nonprod" 'emailProtection,codeSigning'
  run_verify "${nonprod_pf}" "${tmp}/nonprod" "${tmp}/nonprod.json" "" >/dev/null 2>&1
  check "a NON-PRODUCTION anchor still yields a usable RAUC verdict" \
    bash -c 'grep -Fq "\"verdict\": \"RAUC\"" "$1"' _ "${tmp}/nonprod.json"
  check "a NON-PRODUCTION anchor is REFUSED a production build mode" \
    bash -c 'grep -Fq "\"build_mode\": \"development\"" "$1"' _ "${tmp}/nonprod.json"
  check "the NON-PRODUCTION anchor is named as the reason" \
    bash -c 'grep -Fq "identifies itself as NON-PRODUCTION" "$1"' _ "${tmp}/nonprod.json"
  check "its chain and both EKUs still verify (the anchor is the ONLY objection)" \
    bash -c 'grep -Fq "\"chain_terminates_at_installed_root\": true" "$1" && grep -Fq "\"rauc18_smimesign_purpose\": true" "$1"' _ "${tmp}/nonprod.json"

  # An unreachable board must produce an UNKNOWN row, never a fabricated one.
  cp "${pfroot}/selftest-board-preflight.json" "${tmp}/keep.json"
  cat >"${pfroot}/absent-board-preflight.json" <<'EOF'
{
  "board": "absent-board",
  "reachable": false,
  "error": "ssh: connect to host 192.0.2.1 port 22: No route to host",
  "inventory": null
}
EOF
  run_case "${dual}" "${tmp}/mixed.json" ""
  check "an unreachable board yields UNKNOWN, not a fabricated verdict" \
    bash -c 'grep -Fq "\"verdict\": \"UNKNOWN\"" "$1"' _ "${tmp}/mixed.json"
  check "the reachable board still gets its real verdict alongside" \
    bash -c 'grep -Fq "\"verdict\": \"RAUC\"" "$1"' _ "${tmp}/mixed.json"

  if (( failures == 0 )); then
    printf 'verify-bench-rauc-trust self-test: PASS\n'
    return 0
  fi
  printf 'verify-bench-rauc-trust self-test: FAIL (%s leg(s))\n' "${failures}" >&2
  return 1
}

main() {
  local preflight_root="" pki="" out="" env_file="" mode="verify"
  local -a boards=()
  while (( $# )); do
    case "$1" in
      --preflight-root) preflight_root="${2-}"; shift 2 ;;
      --candidate-pki)  pki="${2-}"; shift 2 ;;
      --out)            out="${2-}"; shift 2 ;;
      --env-file)       env_file="${2-}"; shift 2 ;;
      --board)          boards+=("${2-}"); shift 2 ;;
      --self-test)      mode="self-test"; shift ;;
      -h|--help)        usage; return 0 ;;
      *) fail "unknown option: $1"; usage >&2; return 2 ;;
    esac
  done

  if [[ "${mode}" == self-test ]]; then
    self_test
    return $?
  fi

  [[ -n "${preflight_root}" && -n "${pki}" && -n "${out}" ]] || {
    fail "--preflight-root, --candidate-pki and --out are all required"
    usage >&2
    return 2
  }
  run_verify "${preflight_root}" "${pki}" "${out}" "${env_file}" \
    "${boards[@]+"${boards[@]}"}"
}

main "$@"
