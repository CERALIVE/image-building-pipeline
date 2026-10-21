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
encoded=''; [[ -z "$body" ]] || encoded="$(base64 -w0 "$body")"
jq -cn --arg body "$encoded" --args '{argv:$ARGS.positional,body:$body}' -- "${argv[@]}" >>"$STUB_LOG"
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
printf '{"compatible":"ceralive-rock-5b-plus"}\n'
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
# Given authenticated old/next pairs and the exact signature-first interruption.
for mode in refresh publish promote; do
  reset_fixture
  mkdir -p "$STUB_R2/$key.recovery"
  jq -n --arg mode "$mode" --arg old "$(base64 -w0 "$tmp/old.json")" --arg next "$(base64 -w0 "$tmp/next.json")" \
    --arg sig "$(base64 -w0 "$tmp/next.sig")" --arg oldsig "$(base64 -w0 "$tmp/old.sig")" \
    '{schema:1,mode:$mode,board:"rock-5b-plus",channel:"beta",version:"2026.10.1",old:$old,next:$next,signature:$sig,old_signature:$oldsig}' \
    >"$STUB_R2/$key.recovery/${etag//\"/}-$mode-2026.10.1"
  cp "$tmp/next.sig" "$STUB_R2/$key.sig"
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
printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
