#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo/tests/lib/assertions.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/signer" "$tmp/seed/releases/rock-5b-plus/2026.10.1" "$tmp/seed/channels/beta"
export STUB_R2="$tmp/objects" STUB_LOG="$tmp/argv.jsonl"
export R2_IMAGES_BUCKET=ceralive-images R2_IMAGES_ENDPOINT=https://stub.invalid R2_IMAGES_ACCESS_KEY_ID=stub R2_IMAGES_SECRET_ACCESS_KEY=stub
export OTA_MANIFEST_SIGNER_DIR="$tmp/signer" RAUC_BUNDLE_KEYRING="$tmp/signer/root-ca.pem"
cat >"$tmp/bin/aws" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
argv=("$@")
encoded=''
for ((n=0; n<${#argv[@]}; n++)); do
  if [[ "${argv[n]}" == --body ]]; then encoded="$(base64 -w0 "${argv[n+1]}")"; break; fi
done
jq -cn --arg body "$encoded" --args '{argv:$ARGS.positional,body:$body}' -- "${argv[@]}" >>"$STUB_LOG"
[[ "$1" == s3api ]] || exit 2
op="$2"; shift 2
key='' body='' destination='' match='' create=0
while (($#)); do
  case "$1" in
    --key) key="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --if-match) match="$2"; shift 2 ;;
    --if-none-match) create=1; shift 2 ;;
    --bucket|--endpoint-url|--content-type|--cache-control|--query|--output|--prefix|--content-md5) shift 2 ;;
    --no-paginate) shift ;;
    *) destination="$1"; shift ;;
  esac
done
path="$STUB_R2/$key"
case "$op" in
  get-object|head-object)
    [[ -f "$path" ]] || { printf 'An error occurred (NoSuchKey)\n' >&2; exit 1; }
    if [[ "$op" == get-object ]]; then cp "$path" "$destination"; printf '{}\n'
    else printf '"%s"\n' "$(md5sum "$path" | cut -d' ' -f1)"; fi ;;
  put-object)
    if [[ "$create" == 1 && -f "$path" ]]; then printf 'An error occurred (PreconditionFailed)\n' >&2; exit 1; fi
    [[ -z "$match" || "$match" == "\"$(md5sum "$path" | cut -d' ' -f1)\"" ]] || exit 1
    mkdir -p "$(dirname "$path")"; cp "$body" "$path"; printf '{}\n' ;;
  delete-object) rm -f "$path"; printf '{}\n' ;;
  list-objects-v2)
    printf '{"Contents":[{"Key":"releases/rock-5b-plus/2026.9.1/channels/beta"},{"Key":"releases/rock-5b-plus/2026.9.2/channels/beta"},{"Key":"releases/rock-5b-plus/2026.9.3/channels/beta"},{"Key":"releases/rock-5b-plus/2026.9.4/channels/beta"}]}\n' ;;
  *) exit 2 ;;
esac
SH
cat >"$tmp/bin/rauc" <<'SH'
#!/usr/bin/env bash
# Bundle verification is exercised with real RAUC in publish-release.test.sh.
[[ "$1" == info ]] || exit 2
printf '{"compatible":"%s"}\n' "${STUB_COMPATIBLE:-ceralive-rock-5b-plus}"
SH
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
jq -cn --args '{argv:(["curl"]+$ARGS.positional)}' -- "$@" >>"$STUB_LOG"
exit 2
SH
chmod 700 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/root.key" -out "$tmp/signer/root-ca.pem" \
  -days 2 -subj '/CN=Dry-run fixture root' -addext 'basicConstraints=critical,CA:TRUE,pathlen:1' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$tmp/intermediate.key" -out "$tmp/intermediate.csr" \
  -subj '/O=CeraLive/CN=CeraLive RAUC Intermediate CA' >/dev/null 2>&1
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' >"$tmp/intermediate.ext"
openssl x509 -req -in "$tmp/intermediate.csr" -CA "$tmp/signer/root-ca.pem" -CAkey "$tmp/root.key" \
  -CAcreateserial -days 2 -extfile "$tmp/intermediate.ext" -out "$tmp/signer/intermediate-ca.pem" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$tmp/signer/leaf.key" -out "$tmp/leaf.csr" \
  -subj '/CN=CeraLive OTA Manifest Signer' >/dev/null 2>&1
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n' >"$tmp/leaf.ext"
openssl x509 -req -in "$tmp/leaf.csr" -CA "$tmp/signer/intermediate-ca.pem" -CAkey "$tmp/intermediate.key" \
  -CAcreateserial -days 2 -extfile "$tmp/leaf.ext" -out "$tmp/signer/leaf.pem" >/dev/null 2>&1
printf 'bundle fixture\n' >"$tmp/bundle.raucb"
printf 'flash fixture\n' >"$tmp/flash.raw"
xz -c "$tmp/flash.raw" >"$tmp/flash.raw.xz"
(cd "$tmp" && sha256sum flash.raw >raw.sha256)
printf '{}\n' >"$tmp/lock.json"
prefix="$tmp/seed/releases/rock-5b-plus/2026.10.1"
cp "$tmp/bundle.raucb" "$prefix/bundle.raucb.part0000"
cp "$tmp/flash.raw.xz" "$prefix/flash.raw.xz.part0000"
jq -cn \
  --arg bundle "$(sha256sum "$tmp/bundle.raucb" | cut -d' ' -f1)" --arg flash "$(sha256sum "$tmp/flash.raw.xz" | cut -d' ' -f1)" \
  --argjson bs "$(stat -c %s "$tmp/bundle.raucb")" --argjson fs "$(stat -c %s "$tmp/flash.raw.xz")" \
  '{schema:1,files:{"bundle.raucb":{size:$bs,sha256:$bundle,chunk_size:268435456,parts:[{name:"bundle.raucb.part0000",size:$bs,sha256:$bundle}]},
    "flash.raw.xz":{size:$fs,sha256:$flash,chunk_size:268435456,parts:[{name:"flash.raw.xz.part0000",size:$fs,sha256:$flash}]}}}' >"$prefix/index.json"
key=channels/beta/rock-5b-plus.json
jq --arg raw "$(sha256sum "$tmp/flash.raw" | cut -d' ' -f1)" '
  "https://images.ceralive.tv/releases/rock-5b-plus/2026.10.1/" as $url |
  {schema:1,board:"rock-5b-plus",compatible:"ceralive-rock-5b-plus",channel:"beta",version:"2026.10.1",serial:1,
   published_at:"2026-01-01T00:00:00Z",expires_at:"2026-04-01T00:00:00Z",os_version_id:"13",min_ceraui_version:"2026.9.5",
   bundle:{url:($url+"bundle.raucb"),size:.files["bundle.raucb"].size,sha256:.files["bundle.raucb"].sha256},
   flash:{url:($url+"flash.raw.xz"),size:.files["flash.raw.xz"].size,sha256:.files["flash.raw.xz"].sha256,raw_sha256:$raw},
   lock_url:($url+"packages.lock.json")}' "$prefix/index.json" >"$tmp/old.json"
jq '.serial=2' "$tmp/old.json" >"$tmp/next.json"
for pair in old next; do
  openssl cms -sign -binary -in "$tmp/$pair.json" -signer "$tmp/signer/leaf.pem" -inkey "$tmp/signer/leaf.key" \
    -certfile "$tmp/signer/intermediate-ca.pem" -outform DER -out "$tmp/$pair.sig"
done
etag="\"$(md5sum "$tmp/old.json" | cut -d' ' -f1)\""
publisher() { (cd "$repo" && bash "${PUBLISH_RELEASE_SCRIPT:-$repo/ci/publish-release.sh}" "$@"); }
reset_fixture() {
  rm -rf "$STUB_R2"; cp -a "$tmp/seed" "$STUB_R2"
  cp "$tmp/old.json" "$STUB_R2/$key"; cp "$tmp/old.sig" "$STUB_R2/$key.sig"
  : >"$STUB_LOG"
}
readonly_calls() {
  jq -se 'all(.[]; .argv[0]=="s3api" and (.argv[1]=="get-object" or .argv[1]=="head-object" or .argv[1]=="list-objects-v2"))' "$STUB_LOG" >/dev/null
}
seed_intent() {
  local mode="$1" signature="${2:-$tmp/next.sig}"
  reset_fixture
  mkdir -p "$STUB_R2/$key.recovery"
  jq -n --arg mode "$mode" --arg old "$(base64 -w0 "$tmp/old.json")" --arg next "$(base64 -w0 "$tmp/next.json")" \
    --arg sig "$(base64 -w0 "$signature")" --arg oldsig "$(base64 -w0 "$tmp/old.sig")" \
    '{schema:1,mode:$mode,board:"rock-5b-plus",channel:"beta",version:"2026.10.1",old:$old,next:$next,signature:$sig,old_signature:$oldsig}' \
    >"$STUB_R2/$key.recovery/${etag//\"/}-$mode-2026.10.1"
  cp "$signature" "$STUB_R2/$key.sig"
}
# Given authenticated old/next pairs and the exact signature-first interruption.
for mode in refresh publish promote; do
  seed_intent "$mode"
  args=("$mode" --board rock-5b-plus)
  case "$mode" in
    refresh) args+=(--channel beta --expect-serial 1 --expect-etag "$etag") ;;
    publish) args+=(--version 2026.10.1 --channel beta --bundle "$tmp/bundle.raucb" --flash "$tmp/flash.raw.xz" --raw-sha256 "$tmp/raw.sha256" --lock "$tmp/lock.json") ;;
    promote) args+=(--version 2026.10.1 --to stable) ;;
  esac
  # When the real CLI plans recovery; then no mutating command may be emitted.
  if publisher "${args[@]}" --dry-run >"$tmp/plan.log" 2>&1 && readonly_calls && \
     grep -q '^PLAN recover channels/beta/rock-5b-plus.json ' "$tmp/plan.log"; then
    ok "$mode dry-run plans authenticated recovery with zero writes"
  else
    bad "$mode dry-run plans authenticated recovery with zero writes"
    cat "$tmp/plan.log" "$STUB_LOG"
  fi
  # Given the same interruption, when run for real; then only JSON CAS commits.
  cp "$tmp/old.json" "$STUB_R2/$key"; cp "$tmp/next.sig" "$STUB_R2/$key.sig"; : >"$STUB_LOG"
  if publisher "${args[@]}" >"$tmp/recovery.log" 2>&1 && \
     jq -se --arg etag "$etag" --arg body "$(base64 -w0 "$tmp/next.json")" '
       all(.[]; .argv[1]!="delete-object") and
       ([.[] | select(.argv[1]=="put-object")]|length)==
         (if $ARGS.named.mode=="publish" then 7 else 1 end) and
       ([.[] | select(.argv[1]=="put-object" and (.argv[3]|startswith("channels/")))] as $writes |
       ($writes|length)==1 and $writes[0].body==$body and
       $writes[0].argv==["s3api","put-object","--key","channels/beta/rock-5b-plus.json","--body",$writes[0].argv[5],
         "--content-type","application/json","--cache-control","no-cache","--if-match",$etag,
         "--bucket","ceralive-images","--endpoint-url","https://stub.invalid"] and
       .[-2].argv[1:4]==["get-object","--key","channels/beta/rock-5b-plus.json"] and
       .[-1].argv[1:4]==["get-object","--key","channels/beta/rock-5b-plus.json.sig"])' --arg mode "$mode" "$STUB_LOG" >/dev/null && \
     cmp -s "$tmp/next.json" "$STUB_R2/$key" && cmp -s "$tmp/next.sig" "$STUB_R2/$key.sig"; then
    ok "$mode real recovery preserves JSON-only CAS bytes and readback order"
  else bad "$mode real recovery preserves JSON-only CAS bytes and readback order"; cat "$tmp/recovery.log"; fi
done
# Given a healthy pointer, when planning each mode; then every remote call is a read.
for mode in publish promote refresh prune --selftest; do
  reset_fixture
  case "$mode" in
    publish) args=(publish --board rock-5b-plus --version 2026.10.2 --channel beta --bundle "$tmp/bundle.raucb" --flash "$tmp/flash.raw.xz" --raw-sha256 "$tmp/raw.sha256" --lock "$tmp/lock.json") ;;
    promote) args=(promote --board rock-5b-plus --version 2026.10.1 --to stable) ;;
    refresh) args=(refresh --board rock-5b-plus --channel beta --expect-serial 1 --expect-etag "$etag") ;;
    prune) args=(prune --board rock-5b-plus --channel-family) ;;
    --selftest) args=(--selftest) ;;
  esac
  if publisher "${args[@]}" --dry-run >"$tmp/healthy.log" 2>&1 && readonly_calls; then
    ok "$mode healthy dry-run performs zero writes"
  else bad "$mode healthy dry-run performs zero writes"; cat "$tmp/healthy.log" "$STUB_LOG"; fi
done
# Given an interrupted refresh with independently invalid release metadata.
refresh_args=(refresh --board rock-5b-plus --channel beta --expect-serial 1 --expect-etag "$etag")
expect_refusal() {
  local label="$1"; shift
  # When the real CLI runs; then it must fail before any recovery plan or channel PUT.
  if publisher "$@" >"$tmp/refused.log" 2>&1; then
    bad "$label: accepted invalid input"; cat "$tmp/refused.log"
  elif grep -q '^PLAN recover' "$tmp/refused.log" || \
       ! jq -se 'all(.[]; .argv[1]!="put-object" or (.argv|index("--key") as $i|.[$i+1]|startswith("channels/")|not))' "$STUB_LOG" >/dev/null; then
    bad "$label: planned recovery or wrote a channel"; cat "$tmp/refused.log" "$STUB_LOG"
  else ok "$label: refused without a channel PUT or recovery plan"; fi
}
reset_fixture
if aws s3 cp fixture s3://stub/ignored-error 2>/dev/null; then bad 'aws stub accepted non-s3api call'
elif readonly_calls; then bad 'aws stub hid non-s3api call'; else ok 'aws stub records non-s3api calls before refusal'; fi
seed_intent refresh
python3 - "${PUBLISH_RELEASE_SCRIPT:-$repo/ci/publish-release.sh}" "$tmp/load-intent.sh" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text('load_intent() {'+text.split('load_intent() {',1)[1].split('\nrecover_channel() {',1)[0])
PY
# These dependencies are called indirectly by the extracted production function.
# shellcheck disable=SC2317
if (
  # shellcheck source=/dev/null
  source "$tmp/load-intent.sh"
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  intent_key() { printf 'channels/beta/rock-5b-plus.json.recovery/%s-refresh-2026.10.1' "${etag//\"/}"; }
  read_key() { cp "$STUB_R2/$1" "$2"; }
  verify_cms() { return 0; }
  verify_release() { return 1; }
  verify_pointer_source() { return 0; }
  export mode=refresh board=rock-5b-plus version=2026.10.1 expect_serial=1 expect_etag="$etag"
  load_intent beta "$tmp/intent-old" "$etag" "$tmp/intent-next" "$tmp/intent-sig" || exit 2
) >"$tmp/intent-status.log" 2>&1; then bad 'load_intent discarded release verifier failure'
elif grep -q '^ERROR: channel recovery release verification failed' "$tmp/intent-status.log"; then ok 'load_intent aborts on release verifier failure in a conditional'
else bad 'load_intent refused for the wrong reason'; cat "$tmp/intent-status.log"; fi
for defect in compatible index-schema whole-digest; do
  for execution in dry-run real; do
    seed_intent refresh
    export STUB_COMPATIBLE=ceralive-rock-5b-plus
    index="$STUB_R2/releases/rock-5b-plus/2026.10.1/index.json"
    case "$defect" in
      compatible) export STUB_COMPATIBLE=ceralive-WRONG-board ;;
      index-schema) jq '.schema=2' "$index" >"$tmp/index-bad.json"; cp "$tmp/index-bad.json" "$index" ;;
      whole-digest)
        jq '.files["bundle.raucb"].sha256=("0"*64)' "$index" >"$tmp/index-bad.json"; cp "$tmp/index-bad.json" "$index"
        # Keep the authenticated pointer consistent with the drifted index: only the whole-file check can reject it.
        jq '.bundle.sha256=("0"*64)' "$tmp/next.json" >"$tmp/drift-next.json"
        openssl cms -sign -binary -in "$tmp/drift-next.json" -signer "$tmp/signer/leaf.pem" -inkey "$tmp/signer/leaf.key" \
          -certfile "$tmp/signer/intermediate-ca.pem" -outform DER -out "$STUB_R2/$key.sig"
        intent="$STUB_R2/$key.recovery/${etag//\"/}-refresh-2026.10.1"
        jq --arg next "$(base64 -w0 "$tmp/drift-next.json")" --arg sig "$(base64 -w0 "$STUB_R2/$key.sig")" \
          '.next=$next|.signature=$sig' "$intent" >"$tmp/intent-bad.json"; cp "$tmp/intent-bad.json" "$intent" ;;
    esac
    extra=(); [[ "$execution" != dry-run ]] || extra=(--dry-run)
    expect_refusal "recovery $defect $execution" "${refresh_args[@]}" "${extra[@]}"
    case "$defect" in
      compatible) reason='signed bundle compatible mismatch' ;;
      index-schema) reason='release index validation failed' ;;
      whole-digest) reason='release whole-file verification failed' ;;
    esac
    if grep -q "^ERROR: $reason" "$tmp/refused.log"; then ok "$defect fails at its integrity gate"; else bad "$defect integrity gate did not abort"; fi
    if readonly_calls; then ok "$defect $execution remote calls read-only"; else bad "$defect $execution wrote remotely"; fi
  done
done
unset STUB_COMPATIBLE
# Given a trusted beta identity replayed onto the stable key.
for mode in refresh publish promote; do
  for execution in dry-run real; do
    reset_fixture; mkdir -p "$STUB_R2/channels/stable"
    cp "$tmp/old.json" "$STUB_R2/channels/stable/rock-5b-plus.json"
    cp "$tmp/old.sig" "$STUB_R2/channels/stable/rock-5b-plus.json.sig"
    case "$mode" in
      refresh) args=(refresh --board rock-5b-plus --channel stable --expect-serial 1 --expect-etag "$etag") ;;
      publish) args=(publish --board rock-5b-plus --version 2026.10.2 --channel stable --bundle "$tmp/bundle.raucb" --flash "$tmp/flash.raw.xz" --raw-sha256 "$tmp/raw.sha256" --lock "$tmp/lock.json") ;;
      promote) args=(promote --board rock-5b-plus --version 2026.10.1 --to stable) ;;
    esac
    extra=(); [[ "$execution" != dry-run ]] || extra=(--dry-run)
    expect_refusal "$mode cross-channel replay $execution" "${args[@]}" "${extra[@]}"
    if grep -q '^ERROR: signed channel identity mismatch: stable' "$tmp/refused.log"; then ok "$mode rejects the replay identity"; else bad "$mode did not enforce signed channel identity"; fi
  done
done
# Given foreign-root next CMS bytes or a mismatched pair without any intent.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/foreign.key" -out "$tmp/foreign.pem" -days 2 \
  -subj '/CN=CeraLive OTA Manifest Signer' -addext 'extendedKeyUsage=codeSigning' >/dev/null 2>&1
openssl cms -sign -binary -in "$tmp/next.json" -signer "$tmp/foreign.pem" -inkey "$tmp/foreign.key" -outform DER -out "$tmp/foreign.sig"
for defect in foreign-root missing-intent; do
  if [[ "$defect" == foreign-root ]]; then seed_intent refresh "$tmp/foreign.sig"
  else reset_fixture; cp "$tmp/next.sig" "$STUB_R2/$key.sig"; fi
  expect_refusal "$defect dry-run" "${refresh_args[@]}" --dry-run
  if readonly_calls; then ok "$defect remote calls read-only"; else bad "$defect wrote remotely"; fi
done
printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
