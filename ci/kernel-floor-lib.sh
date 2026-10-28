#!/usr/bin/env bash
# Sourced inside publish-release.sh's transaction and shared publisher lock.
# shellcheck shell=bash
# shellcheck disable=SC2154

kernel_sidecar_check() {
  python3 - "${BASH_SOURCE[0]%/*}/../lib" "$1" "$board" "$2" <<'PY'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1])
from kernel_release import sidecar
path = pathlib.Path(sys.argv[2])
record = sidecar(path)
row = json.loads(path.read_text())
if (row['board'], row['os_version']) != tuple(sys.argv[3:]):
    sys.exit('OS kernel sidecar release identity mismatch')
print(record.version)
PY
}

kernel_floor_check() {
  local candidate="$1" history="${tmp}/kernel-floor" keys="${tmp}/kernel-floor-keys"
  local token="" next="" prefix board_name os_version n=0
  mkdir -p "${history}"
  : >"${keys}"
  while :; do
    local -a args=(--prefix releases/ --no-paginate --output json)
    [[ -z "${token}" ]] || args+=(--continuation-token "${token}")
    s3 list-objects-v2 "${args[@]}" >"${tmp}/kernel-floor-page.json" \
      || die "kernel floor inventory failed"
    next="$(python3 - "${tmp}/kernel-floor-page.json" "${keys}" "${token}" <<'PY'
import json, re, sys
page = json.load(open(sys.argv[1]))
with open(sys.argv[2], 'a') as output:
    for entry in page.get('Contents', []):
        key = entry['Key']
        if not isinstance(key, str):
            sys.exit('invalid kernel floor inventory key')
        match = re.fullmatch(r'releases/([a-z0-9]+(?:-[a-z0-9]+)*)/([0-9]{4}\.[0-9]+\.[0-9]+)/channels/(?:beta|stable|drill)', key)
        if match and match[1] != 'x86-minipc':
            output.write(key.rsplit('/channels/', 1)[0] + '\n')
if page.get('IsTruncated'):
    token = page['NextContinuationToken']
    if not isinstance(token, str) or not token or token == sys.argv[3]:
        sys.exit('incomplete kernel floor inventory')
    print(token)
PY
)" || die "incomplete kernel floor inventory"
    [[ -n "${next}" ]] || break
    token="${next}"
  done
  while IFS= read -r prefix; do
    [[ -n "${prefix}" ]] || continue
    n=$((n + 1))
    read_key "${prefix}/kernel.json" "${history}/${n}.json" || die "published OS kernel sidecar absent: ${prefix}"
    read_key "${prefix}/kernel.json.sig" "${history}/${n}.sig" || die "published OS kernel signature absent: ${prefix}"
    verify_cms "${history}/${n}.json" "${history}/${n}.sig" || die "published OS kernel sidecar signature invalid: ${prefix}"
    board_name="${prefix#releases/}"; board_name="${board_name%%/*}"
    os_version="${prefix##*/}"
    ( board="${board_name}"; kernel_sidecar_check "${history}/${n}.json" "${os_version}" >/dev/null ) \
      || die "published OS kernel identity invalid: ${prefix}"
  done < <(sort -u "${keys}")
  python3 "${BASH_SOURCE[0]%/*}/check-kernel-version-monotonic.py" \
    --floor --os-releases "${history}" --version "${candidate}" \
    || die "os_kernel_below_floor: publication refused"
}

kernel_prepare_sidecar() {
  [[ "${board}" != x86-minipc ]] || return 0
  python3 "${BASH_SOURCE[0]%/*}/check-kernel-version-monotonic.py" \
    --sidecar "${tmp}/packages.lock.json" --board "${board}" --version "${version}" \
    --out "${tmp}/kernel.json" || die "candidate kernel identity verification failed"
  local selected
  selected="$(kernel_sidecar_check "${tmp}/kernel.json" "${version}")" || die "invalid candidate kernel sidecar"
  kernel_floor_check "${selected}" || return 1
  if [[ "${dry_run}" != 1 ]]; then
    signer_check
    openssl cms -sign -binary -noattr -in "${tmp}/kernel.json" \
      -signer "${OTA_MANIFEST_SIGNER_DIR}/leaf.pem" -inkey "${OTA_MANIFEST_SIGNER_DIR}/leaf.key" \
      -certfile "${OTA_MANIFEST_SIGNER_DIR}/intermediate-ca.pem" \
      -outform DER -out "${tmp}/kernel.json.sig" || return 1
    verify_cms "${tmp}/kernel.json" "${tmp}/kernel.json.sig" || die "kernel sidecar CMS verification failed"
  fi
}

kernel_promote_check() {
  [[ "${board}" != x86-minipc ]] || return 0
  local prefix selected
  prefix="$(release_prefix "${version}")"
  read_key "${prefix}/kernel.json" "${tmp}/promoted-kernel.json" || die "promoted OS kernel sidecar absent"
  read_key "${prefix}/kernel.json.sig" "${tmp}/promoted-kernel.sig" || die "promoted OS kernel signature absent"
  verify_cms "${tmp}/promoted-kernel.json" "${tmp}/promoted-kernel.sig" || die "promoted OS kernel signature invalid"
  selected="$(kernel_sidecar_check "${tmp}/promoted-kernel.json" "${version}")" || die "invalid promoted kernel sidecar"
  kernel_floor_check "${selected}"
}
