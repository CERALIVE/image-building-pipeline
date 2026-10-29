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
  local candidate="$1" history="${2:-${tmp}/kernel-floor}" keys="${tmp}/kernel-floor-keys"
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

# Owner-attested sidecar for the two OS releases published before kernel.json existed. Their
# kernel is source-built (no APT origin, no kernel Release), so the normal generator refuses
# it; the OTA signer's signature here means the owner attests the named kernel shipped in
# that image. The floor is deliberately not run: it cannot pass until these sidecars exist.
# shortcut: allowlist is hard-coded to the pre-sidecar releases, extend it only by reviewed PR.
kernel_legacy_backfill() {
  [[ "${board}" != x86-minipc ]] || die "x86-minipc carries no kernel sidecar"
  case "${board}/${version}" in
    rock-5b-plus/2026.10.100|orange-pi-5-plus/2026.10.100) ;;
    *) die "legacy kernel backfill covers only the named pre-sidecar releases" ;;
  esac
  [[ "${expect_kernel_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-ceralive[1-9][0-9]*$ &&
     "${expect_deb_sha256}" =~ ^[0-9a-f]{64}$ ]] \
    || die "backfill-kernel requires --expect-kernel-version and --expect-deb-sha256"
  local prefix have_json=0 have_sig=0
  prefix="$(release_prefix "${version}")"
  if read_key "${prefix}/kernel.json" "${tmp}/existing-kernel.json"; then have_json=1; fi
  if read_key "${prefix}/kernel.json.sig" "${tmp}/existing-kernel.sig"; then have_sig=1; fi
  [[ "${have_json}${have_sig}" != 11 ]] || die "kernel sidecar already published: ${prefix}"
  read_key "${prefix}/packages.lock.json" "${tmp}/packages.lock.json" || die "release package lock absent: ${prefix}"
  read_key "${prefix}/SHA256SUMS" "${tmp}/SHA256SUMS" || die "release checksum list absent: ${prefix}"
  python3 - "${tmp}/packages.lock.json" "${tmp}/SHA256SUMS" "${board}" "${version}" \
    "${expect_kernel_version}" "${expect_deb_sha256}" "${tmp}/kernel.json" <<'PY' || die "legacy kernel identity refused"
import hashlib, json, re, sys
lock_path, sums_path, board, os_version, want_version, want_sha, out = sys.argv[1:]
lock_bytes = open(lock_path, 'rb').read()
sums = {m[2]: m[1] for m in re.finditer(r'^([0-9a-f]{64})  (\S+)$', open(sums_path).read(), re.M)}
if sums.get('packages.lock.json') != hashlib.sha256(lock_bytes).hexdigest():
    sys.exit('package lock does not match the release checksum list')
rows = [r for r in json.loads(lock_bytes)['packages'] if r['name'].startswith('linux-image-')]
if len(rows) != 1:
    sys.exit('release must contain exactly one installed kernel')
row = rows[0]
if row['origin'] != 'source-built' or row['arch'] != 'arm64':
    sys.exit('only source-built arm64 legacy kernels may be backfilled')
deb = f"{row['name']}_{row['version']}_arm64.deb"
digests = row.get('artifact', {}).get('sha256', {})
if list(digests) != [deb]:
    sys.exit('kernel row must carry exactly its own .deb digest')
if row['version'] != want_version or digests[deb] != want_sha:
    sys.exit('kernel differs from the owner-attested version and digest')
record = {'schema': 1, 'board': board, 'os_version': os_version,
          'kernel': {'package': row['name'], 'version': row['version'], 'deb_sha256': digests[deb]}}
with open(out, 'w') as handle:
    handle.write(json.dumps(record, indent=2, sort_keys=True) + '\n')
PY
  kernel_sidecar_check "${tmp}/kernel.json" "${version}" >/dev/null || die "invalid legacy kernel sidecar"
  # An interrupted run leaves one half; a retry completes it only if that half is exactly what
  # this attestation yields, and never overwrites it.
  if [[ "${have_json}" == 1 ]]; then
    cmp -s "${tmp}/existing-kernel.json" "${tmp}/kernel.json" \
      || die "published kernel sidecar differs from the attested identity: ${prefix}"
  fi
  if [[ "${have_sig}" == 1 && "${dry_run}" != 1 ]]; then
    verify_cms "${tmp}/kernel.json" "${tmp}/existing-kernel.sig" \
      || die "published kernel signature does not verify: ${prefix}"
    cp -- "${tmp}/existing-kernel.sig" "${tmp}/kernel.json.sig"
  fi
  if [[ "${dry_run}" != 1 && "${have_sig}" == 0 ]]; then
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
