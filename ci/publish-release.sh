#!/usr/bin/env bash
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  printf '%s\n' 'publish-release.sh publish --board B --version YYYY.M.P --channel stable|beta|drill --bundle FILE --flash FILE --raw-sha256 FILE --lock FILE [--dry-run]' \
    'publish-release.sh promote --board B --version YYYY.M.P --to stable [--dry-run]' \
    'publish-release.sh refresh --board B --channel stable|beta|drill --expect-serial N --expect-etag "\"MD5\"" [--dry-run]' \
    'publish-release.sh prune --board B --channel-family [--dry-run]' \
    'publish-release.sh --selftest [--dry-run]'
}

mode="${1:-}"; [[ -n "$mode" ]] || { usage; exit 2; }; shift
board='' version='' channel='' to='' bundle='' flash='' raw_sha256='' lock='' dry_run=0 channel_family=0 expect_serial='' expect_etag=''
while (($#)); do
  case "$1" in
    --board|--version|--channel|--to|--bundle|--flash|--raw-sha256|--lock|--expect-serial|--expect-etag)
      (($# >= 2)) || die "missing value for $1"
      case "$1" in
        --board) board="$2" ;; --version) version="$2" ;; --channel) channel="$2" ;;
        --to) to="$2" ;; --bundle) bundle="$2" ;; --flash) flash="$2" ;;
        --raw-sha256) raw_sha256="$2" ;; --lock) lock="$2" ;;
        --expect-serial) expect_serial="$2" ;; --expect-etag) expect_etag="$2" ;;
      esac
      shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --channel-family) channel_family=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$mode" == --selftest || "$board" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die 'invalid or missing board'
[[ -z "$version" || "$version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || die 'invalid CalVer'
[[ -z "$channel" || "$channel" =~ ^(stable|beta|drill)$ ]] || die 'invalid channel'
[[ "$mode" == --selftest || "$mode" == prune || "$mode" == refresh || -n "$version" ]] || die 'version is required'
[[ "$mode" != publish || ( -n "$channel" && -f "$bundle" && -f "$flash" && -f "$raw_sha256" && -f "$lock" ) ]] || die 'publish requires channel and all four input files'
[[ "$mode" != promote || "$to" == stable ]] || die 'promotion target must be stable'
[[ "$mode" != refresh || -n "$channel" ]] || die 'refresh needs channel'
[[ "$mode" != refresh || ( "$expect_serial" =~ ^[1-9][0-9]*$ && "$expect_etag" =~ ^\"[a-fA-F0-9]{32}\"$ ) ]] || die 'refresh needs --expect-serial and quoted --expect-etag'
[[ "$mode" == refresh || ( -z "$expect_serial" && -z "$expect_etag" ) ]] || die 'expect-serial/etag only apply to refresh'
[[ "$mode" != prune || ( -z "$channel" && "$channel_family" == 1 ) ]] || die 'prune requires --channel-family (not --channel)'
[[ "$mode" == prune || "$channel_family" == 0 ]] || die '--channel-family only applies to prune'
command -v aws >/dev/null || die 'aws CLI is required'
command -v python3 >/dev/null || die 'python3 is required'
command -v openssl >/dev/null || die 'openssl is required'
bucket="${R2_IMAGES_BUCKET:-ceralive-images}"
endpoint="${R2_IMAGES_ENDPOINT:-${R2_ENDPOINT:-}}"
[[ -n "$endpoint" ]] || die 'R2_IMAGES_ENDPOINT or R2_ENDPOINT is required'
export AWS_ACCESS_KEY_ID="${R2_IMAGES_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
export AWS_SECRET_ACCESS_KEY="${R2_IMAGES_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
export AWS_DEFAULT_REGION=auto
[[ "$dry_run" == 1 || ( -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ) ]] || die 'R2 images credentials absent'
umask 077
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/r2-immutable-lib.sh"

s3() { aws s3api "$@" --bucket "$bucket" --endpoint-url "$endpoint"; }
md5_of() { openssl dgst -md5 -binary "$1" | base64 -w0; }
immutable() {
  local key="$1" file="$2" type="$3"
  if [[ "$dry_run" == 1 ]]; then printf 'PLAN create-only %s\n' "$key"; return; fi
  put_or_verify "$key" "$file" "$(md5_of "$file")" "$type"
}
missing() { grep -Eq '(\((404|NoSuchKey|NotFound)\)|Not Found|NoSuchKey)' "$1"; }
read_key() {
  local key="$1" output="$2" error="$tmp/read-error"
  rm -f "$output"
  if s3 get-object --key "$key" "$output" >/dev/null 2>"$error"; then return 0; fi
  if missing "$error"; then return 1; fi
  die "R2 read failed for $key: $(tr '\n' ' ' <"$error")"
}
current_etag() {
  local key="$1" error="$tmp/head-error" result
  if result="$(s3 head-object --key "$key" --query ETag --output text 2>"$error")"; then
    [[ "$result" =~ ^\"[a-fA-F0-9]{32}\"$ ]] || die "invalid ETag for $key"
    printf '%s' "$result"; return 0
  fi
  if missing "$error"; then return 1; fi
  die "R2 HEAD failed for $key: $(tr '\n' ' ' <"$error")"
}
channel_key() { printf 'channels/%s/%s.json' "$1" "$board"; }
release_prefix() { printf 'releases/%s/%s' "$board" "$1"; }
read_channel() {
  local c="$1" destination="$2"
  if read_key "$(channel_key "$c")" "$destination"; then
    if [[ "$mode" != prune ]]; then
      read_key "$(channel_key "$c").sig" "$destination.sig" || die "signed channel signature absent: $c"
      [[ -f "${OTA_MANIFEST_SIGNER_DIR:-}/root-ca.pem" ]] || die 'manifest verification root absent'
      openssl cms -verify -binary -inform DER -in "$destination.sig" -content "$destination" \
        -CAfile "$OTA_MANIFEST_SIGNER_DIR/root-ca.pem" -purpose codesign \
        -signer "$tmp/read-signer.pem" -out /dev/null >/dev/null 2>&1 || die "signed channel verification failed: $c"
      [[ "$(openssl x509 -in "$tmp/read-signer.pem" -noout -subject -nameopt RFC2253)" == *'CN=CeraLive OTA Manifest Signer'* ]] || die 'signed channel signer identity mismatch'
    fi
    python3 - "$destination" "$board" "$c" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
assert m['schema']==1 and m['board']==sys.argv[2] and m['channel']==sys.argv[3]
assert isinstance(m['serial'],int) and 0 < m['serial'] < 9007199254740991
assert m['version'].count('.')==2
PY
    return 0
  fi
  return 1
}
resolve_compatible() {
  local params
  params="$(bash "$(dirname "${BASH_SOURCE[0]}")/../lib/resolve.sh" "$board")" || die "cannot resolve board: $board"
  compatible="$(python3 - "$params" <<'PY'
import ast,re,sys
matches=[line.split('=',1)[1] for line in sys.argv[1].splitlines() if line.startswith('BOARD_ID=')]
assert len(matches)==1, 'resolved board_id absent or ambiguous'
board_id=ast.literal_eval(matches[0])
assert isinstance(board_id,str) and re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*',board_id), 'invalid board_id'
print('ceralive-'+board_id)
PY
)" || die 'invalid resolved board identity'
}
verify_release() {
  local v="$1" index="$tmp/index.json" name part size digest actual_size actual_digest
  local prefix
  prefix="$(release_prefix "$v")"
  read_key "$prefix/index.json" "$index" || die 'release index absent'
  python3 - "$index" >"$tmp/release-parts" <<'PY'
import json,re,sys
i=json.load(open(sys.argv[1]))
assert i['schema']==1 and set(i['files'])=={'bundle.raucb','flash.raw.xz'}, 'release index files invalid'
for name,entry in i['files'].items():
    assert isinstance(entry['size'],int) and entry['size']>0 and re.fullmatch(r'[0-9a-f]{64}',entry['sha256'])
    assert entry['chunk_size']==268435456 and entry['parts'], 'invalid release chunking'
    assert sum(p['size'] for p in entry['parts'])==entry['size'], 'release size mismatch'
    for n,p in enumerate(entry['parts']):
        assert p['name']==f'{name}.part{n:04d}' and isinstance(p['size'],int) and 0<p['size']<=268435456
        assert re.fullmatch(r'[0-9a-f]{64}',p['sha256']), 'invalid part digest'
        print(name,p['name'],p['size'],p['sha256'])
PY
  : >"$tmp/verified-bundle.raucb"
  : >"$tmp/verified-flash.raw.xz"
  while read -r name part size digest; do
    read_key "$prefix/$part" "$tmp/verified-part" || die "release part absent: $part"
    actual_size="$(stat -c %s "$tmp/verified-part")"
    actual_digest="$(sha256sum "$tmp/verified-part" | cut -d' ' -f1)"
    [[ "$actual_size" == "$size" && "$actual_digest" == "$digest" ]] || die "release part drift: $part"
    cat "$tmp/verified-part" >>"$tmp/verified-$name"
  done <"$tmp/release-parts"
  python3 - "$index" "$tmp" <<'PY'
import hashlib,json,os,sys
for name,entry in json.load(open(sys.argv[1]))['files'].items():
    path=os.path.join(sys.argv[2],f'verified-{name}')
    assert os.path.getsize(path)==entry['size'], f'{name} size differs from index'
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for block in iter(lambda:f.read(4*1024*1024),b''):h.update(block)
    assert h.hexdigest()==entry['sha256'], f'{name} digest differs from index'
PY
  [[ -f "${RAUC_BUNDLE_KEYRING:-}" ]] || die 'RAUC_BUNDLE_KEYRING is required for signed bundle verification'
  command -v rauc >/dev/null || die 'rauc is required for signed bundle verification'
  rauc info -C keyring:check-purpose=codesign --keyring="$RAUC_BUNDLE_KEYRING" \
    --output-format=json "$tmp/verified-bundle.raucb" >"$tmp/bundle-info.json" || die 'signed bundle verification failed'
  python3 - "$tmp/bundle-info.json" "$compatible" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['compatible']==sys.argv[2], 'signed bundle compatible mismatch'
PY
}
verify_pointer_source() {
  local source="$1" v="$2" allow_legacy="$3"
  python3 - "$source" "$tmp/index.json" "$board" "$v" "$compatible" "$allow_legacy" <<'PY'
import json,sys
source,index,board,version,compatible,allow_legacy=sys.argv[1:]
m=json.load(open(source));files=json.load(open(index))['files']
prefix=f'https://images.ceralive.tv/releases/{board}/{version}/'
assert m['schema']==1 and m['board']==board and m['version']==version, 'channel release identity mismatch'
assert m['compatible']==compatible or (allow_legacy=='yes' and m['compatible']==f'ceralive-{board}'), 'channel compatible mismatch'
assert m['bundle']=={'url':prefix+'bundle.raucb','size':files['bundle.raucb']['size'],'sha256':files['bundle.raucb']['sha256']}, 'channel bundle/index mismatch'
assert m['flash']['url']==prefix+'flash.raw.xz' and m['flash']['size']==files['flash.raw.xz']['size'] and m['flash']['sha256']==files['flash.raw.xz']['sha256'], 'channel flash/index mismatch'
assert m['lock_url']==prefix+'packages.lock.json', 'channel lock URL mismatch'
PY
}
signer_check() {
  [[ -f "${OTA_MANIFEST_SIGNER_DIR:-}/leaf.pem" && -f "${OTA_MANIFEST_SIGNER_DIR:-}/leaf.key" && -f "${OTA_MANIFEST_SIGNER_DIR:-}/intermediate-ca.pem" && -f "${OTA_MANIFEST_SIGNER_DIR:-}/root-ca.pem" ]] || die 'dedicated manifest signer files absent'
  local cn eku
  cn="$(openssl x509 -in "$OTA_MANIFEST_SIGNER_DIR/leaf.pem" -noout -subject -nameopt RFC2253)"
  [[ "$cn" == *'CN=CeraLive OTA Manifest Signer'* ]] || die 'wrong manifest signer CN'
  eku="$(openssl x509 -in "$OTA_MANIFEST_SIGNER_DIR/leaf.pem" -noout -ext extendedKeyUsage)"
  [[ "$eku" == *'Code Signing'* && "$eku" != *'E-mail Protection'* ]] || die 'manifest signer must have codeSigning only'
  openssl verify -purpose codesign -CAfile "$OTA_MANIFEST_SIGNER_DIR/root-ca.pem" -untrusted "$OTA_MANIFEST_SIGNER_DIR/intermediate-ca.pem" "$OTA_MANIFEST_SIGNER_DIR/leaf.pem" >/dev/null
  [[ "$(openssl pkey -in "$OTA_MANIFEST_SIGNER_DIR/leaf.key" -pubout | openssl sha256)" == "$(openssl x509 -in "$OTA_MANIFEST_SIGNER_DIR/leaf.pem" -pubkey -noout | openssl sha256)" ]] || die 'manifest signer key mismatch'
}
write_manifest() {
  local c="$1" v="$2" source="$3" serial="$4" output="$5" min_version="$6" raw="$7"
  python3 - "$c" "$v" "$source" "$serial" "$output" "$min_version" "$raw" "$board" "${OS_VERSION_ID}" "$compatible" <<'PY'
import datetime,json,sys
c,v,source,serial,out,minimum,raw,board,osid,compatible=sys.argv[1:]
now=datetime.datetime.now(datetime.timezone.utc)
stamp=lambda d:d.strftime('%Y-%m-%dT%H:%M:%SZ')
prefix=f'https://images.ceralive.tv/releases/{board}/{v}/'
if source:
    m=json.load(open(source))
    assert m['board']==board and m['version']==v and m['schema']==1
    m['channel']=c
    m['compatible']=compatible
else:
    index=json.load(open(out+'.index'))['files']
    m={'schema':1,'board':board,'compatible':compatible,
       'channel':c,'version':v,'os_version_id':osid,'min_ceraui_version':minimum,
       'bundle':{'url':prefix+'bundle.raucb','size':index['bundle.raucb']['size'],'sha256':index['bundle.raucb']['sha256']},
       'flash':{'url':prefix+'flash.raw.xz','size':index['flash.raw.xz']['size'],'sha256':index['flash.raw.xz']['sha256'],'raw_sha256':raw},
       'lock_url':prefix+'packages.lock.json'}
m.update(serial=int(serial),published_at=stamp(now),expires_at=stamp(now+datetime.timedelta(days=90)))
assert 0 < m['serial'] < 9007199254740991
with open(out,'w') as f: json.dump(m,f,separators=(',',':'));f.write('\n')
PY
}
advance_channel() {
  local c="$1" v="$2" from="$3" minimum="$4" raw="$5"
  local key old_serial=0 etag='' sig_etag='' prior="$tmp/current-$c.json" next="$tmp/next-$c.json"
  key="$(channel_key "$c")"
  if read_channel "$c" "$prior"; then
    if [[ -z "$from" ]] && python3 - "$prior" "$v" <<'PY'
import json,sys
sys.exit(0 if json.load(open(sys.argv[1]))['version']==sys.argv[2] else 1)
PY
    then die "serial replay refused: $c already publishes version $v"; fi
    old_serial="$(python3 - "$prior" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['serial'])
PY
)"
    etag="$(current_etag "$key")"
    [[ "$etag" == "\"$(openssl dgst -md5 "$prior" | cut -d' ' -f2)\"" ]] || die 'channel changed between signed read and ETag read'
    sig_etag="$(current_etag "$key.sig")"
    [[ "$sig_etag" == "\"$(openssl dgst -md5 "$prior.sig" | cut -d' ' -f2)\"" ]] || die 'channel signature changed between signed read and ETag read'
    if [[ "$mode" == refresh ]]; then
      [[ "$old_serial" == "$expect_serial" && "$etag" == "$expect_etag" ]] || die 'refresh precondition: serial or ETag changed'
    fi
  fi
  source lib/shared/target-release-lib.sh
  target_release_load
  write_manifest "$c" "$v" "$from" "$((old_serial + 1))" "$next" "$minimum" "$raw"
  if (( old_serial > 0 )); then
    python3 - "$next" "$prior" <<'PY'
import datetime,json,sys
new,old=(json.load(open(p)) for p in sys.argv[1:])
assert new['serial']>old['serial'], 'serial replay refused'
if new['published_at']<=old['published_at']:
    now=datetime.datetime.fromisoformat(old['published_at'].replace('Z','+00:00'))+datetime.timedelta(seconds=1)
    fmt=lambda d:d.strftime('%Y-%m-%dT%H:%M:%SZ')
    new.update(published_at=fmt(now),expires_at=fmt(now+datetime.timedelta(days=90)))
    with open(sys.argv[1],'w') as f:json.dump(new,f,separators=(',',':'));f.write('\n')
PY
  fi
  printf 'channel=%s board=%s version=%s serial=%s -> %s\n' "$c" "$board" "$v" "$old_serial" "$((old_serial+1))"
  if [[ "$dry_run" == 1 ]]; then printf 'PLAN channel signature %s.sig then manifest %s LAST\n' "$key" "$key"; return; fi
  signer_check
  openssl cms -sign -binary -in "$next" -signer "$OTA_MANIFEST_SIGNER_DIR/leaf.pem" \
    -inkey "$OTA_MANIFEST_SIGNER_DIR/leaf.key" -certfile "$OTA_MANIFEST_SIGNER_DIR/intermediate-ca.pem" \
    -outform DER -out "$tmp/channel.sig" >/dev/null
  openssl cms -verify -binary -inform DER -in "$tmp/channel.sig" -content "$next" \
    -CAfile "$OTA_MANIFEST_SIGNER_DIR/root-ca.pem" -purpose codesign -out /dev/null >/dev/null 2>&1 || die 'manifest CMS verification failed'
  # The workflow serializes channel writers; an ETag CAS also refuses stale manifests.
  local args=(--key "$key.sig" --body "$tmp/channel.sig" --content-type application/pkcs7-signature)
  if [[ -n "$sig_etag" ]]; then args+=(--if-match "$sig_etag"); else args+=(--if-none-match '*'); fi
  s3 put-object "${args[@]}" >/dev/null || die 'channel signature changed during publication'
  args=(--key "$key" --body "$next" --content-type application/json --cache-control no-cache)
  if [[ -n "$etag" ]]; then args+=(--if-match "$etag"); else args+=(--if-none-match '*'); fi
  if ! s3 put-object "${args[@]}" >/dev/null; then
    if [[ -n "$etag" && "$(current_etag "$key")" == "$etag" ]]; then
      s3 put-object --key "$key.sig" --body "$prior.sig" --content-type application/pkcs7-signature \
        --if-match "\"$(openssl dgst -md5 "$tmp/channel.sig" | cut -d' ' -f2)\"" >/dev/null \
        || die 'serial replay refused: signature rollback failed; inspect channel pair'
    fi
    die 'serial replay refused: channel changed during publication'
  fi
}
parse_checksum() {
  local sidecar="$1" filename="$2" digest
  digest="$(python3 - "$sidecar" "$filename" <<'PY'
import re,sys
lines=open(sys.argv[1]).read().splitlines()
assert len(lines)==1, 'one checksum record required'
match=re.fullmatch(r'([0-9a-f]{64})\s+\*?([^\s]+)',lines[0])
assert match and match[2] in (sys.argv[2],'raw','raw.sha256'), 'wrong checksum filename'
print(match[1])
PY
)" || die 'invalid raw checksum sidecar'
  printf '%s' "$digest"
}
make_parts() {
  local name="$1" input="$2" prefix="$3" size digest offset=0 count=0 part part_size
  size="$(stat -c %s "$input")"; ((size > 0)) || die "$name is empty"
  digest="$(sha256sum "$input" | cut -d' ' -f1)"
  printf '%s\t%s\t%s\n' "$name" "$size" "$digest" >>"$tmp/files.tsv"
  while ((offset < size)); do
    part_size=$((size-offset)); ((part_size > 268435456)) && part_size=268435456
    part="${name}.part$(printf '%04d' "$count")"
    dd if="$input" of="$tmp/$part" bs=4M skip="$((offset/4194304))" count="$(( (part_size+4194303)/4194304 ))" iflag=fullblock status=none
    truncate -s "$part_size" "$tmp/$part"
    printf '%s\t%s\t%s\t%s\n' "$name" "$part" "$part_size" "$(sha256sum "$tmp/$part" | cut -d' ' -f1)" >>"$tmp/parts.tsv"
    immutable "$prefix/$part" "$tmp/$part" application/octet-stream
    rm -f "$tmp/$part"
    offset=$((offset+part_size)); count=$((count+1))
  done
}
build_index() {
  python3 - "$tmp/files.tsv" "$tmp/parts.tsv" "$tmp/index.json" <<'PY'
import json,sys
files={}
for line in open(sys.argv[1]):
    name,size,digest=line.rstrip('\n').split('\t')
    files[name]={'size':int(size),'sha256':digest,'chunk_size':268435456,'parts':[]}
for line in open(sys.argv[2]):
    name,part,size,digest=line.rstrip('\n').split('\t')
    files[name]['parts'].append({'name':part,'size':int(size),'sha256':digest})
with open(sys.argv[3],'w') as f:json.dump({'schema':1,'files':files},f,separators=(',',':'));f.write('\n')
PY
}
case "$mode" in
  publish)
    resolve_compatible
    [[ "$(basename "$bundle")" == *.raucb && "$(basename "$flash")" == *.raw.xz ]] || die 'publish expects .raucb and .raw.xz files (never relabel zstd bytes)'
    xz -t "$flash" || die 'flash is not a valid xz stream'
    raw="$(parse_checksum "$raw_sha256" "$(basename "$flash" .xz)")"
    [[ "$(xz -dc "$flash" | sha256sum | cut -d' ' -f1)" == "$raw" ]] || die 'raw SHA-256 mismatch after decompression'
    min="$(python3 - versions.yaml <<'PY'
import re,sys
text=open(sys.argv[1]).read()
block=re.search(r'^CeraUI:\s*\n(.*?)(?=^\S|\Z)',text,re.M|re.S)
assert block, 'CeraUI pin missing'
pin=re.search(r'^  pin:\s*v?([0-9]{4}\.[0-9]+\.[0-9]+)\s*$',block[1],re.M)
assert pin, 'CeraUI pin invalid'
print(pin[1])
PY
)"
    prefix="$(release_prefix "$version")"
    cp --reflink=auto -- "$bundle" "$tmp/bundle.raucb"
    [[ -f "${RAUC_BUNDLE_KEYRING:-}" ]] || die 'RAUC_BUNDLE_KEYRING is required for signed bundle verification'
    command -v rauc >/dev/null || die 'rauc is required for signed bundle verification'
    rauc info -C keyring:check-purpose=codesign --keyring="$RAUC_BUNDLE_KEYRING" --output-format=json "$tmp/bundle.raucb" >"$tmp/local-bundle-info.json" || die 'signed bundle verification failed'
    python3 - "$tmp/local-bundle-info.json" "$compatible" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['compatible']==sys.argv[2], 'signed bundle compatible mismatch'
PY
    cp --reflink=auto -- "$flash" "$tmp/flash.raw.xz"
    cp -- "$lock" "$tmp/packages.lock.json"
    python3 -m json.tool "$tmp/packages.lock.json" >/dev/null || die 'invalid package lock JSON'
    : >"$tmp/files.tsv"; : >"$tmp/parts.tsv"
    make_parts bundle.raucb "$tmp/bundle.raucb" "$prefix"
    make_parts flash.raw.xz "$tmp/flash.raw.xz" "$prefix"
    build_index
    ( cd "$tmp" && sha256sum bundle.raucb flash.raw.xz index.json packages.lock.json > SHA256SUMS )
    immutable "$prefix/packages.lock.json" "$tmp/packages.lock.json" application/json
    immutable "$prefix/SHA256SUMS" "$tmp/SHA256SUMS" text/plain
    immutable "$prefix/index.json" "$tmp/index.json" application/json
    printf '%s\n' "$version" >"$tmp/marker"
    immutable "$prefix/channels/$channel" "$tmp/marker" text/plain
    if [[ "$dry_run" != 1 ]]; then verify_release "$version"; fi
    cp "$tmp/index.json" "$tmp/next-$channel.json.index"
    advance_channel "$channel" "$version" '' "$min" "$raw"
    ;;
  promote)
    resolve_compatible
    prefix="$(release_prefix "$version")"
    [[ "$version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || die 'version required'
    read_channel beta "$tmp/beta.json" || die 'beta manifest absent: cannot promote'
    verify_release "$version"
    verify_pointer_source "$tmp/beta.json" "$version" no
    printf '%s\n' "$version" >"$tmp/marker"
    immutable "$prefix/channels/stable" "$tmp/marker" text/plain
    advance_channel stable "$version" "$tmp/beta.json" '' ''
    ;;
  refresh)
    resolve_compatible
    read_channel "$channel" "$tmp/refresh.json" || die 'channel manifest absent: cannot refresh'
    version="$(python3 - "$tmp/refresh.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['version'])
PY
)"
    [[ "$version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || die 'invalid signed channel version'
    verify_release "$version"
    verify_pointer_source "$tmp/refresh.json" "$version" yes
    advance_channel "$channel" "$version" "$tmp/refresh.json" '' ''
    ;;
  prune)
    token=''; : >"$tmp/keys.txt"
    while :; do
      args=(--prefix "releases/$board/" --no-paginate --output json)
      [[ -z "$token" ]] || args+=(--continuation-token "$token")
      if ! s3 list-objects-v2 "${args[@]}" >"$tmp/page.json"; then
        die 'R2 inventory failed; refusing prune'
      fi
      next="$(python3 - "$tmp/page.json" "$tmp/keys.txt" "$token" <<'PY'
import json,sys
page=json.load(open(sys.argv[1]))
assert isinstance(page.get('Contents',[]),list)
keys=[entry['Key'] for entry in page.get('Contents',[])]
assert all(isinstance(key,str) for key in keys)
with open(sys.argv[2],'a') as output:
    for key in keys: output.write(key+'\n')
if page.get('IsTruncated'):
    next_token=page['NextContinuationToken']
    assert isinstance(next_token,str) and next_token and next_token!=sys.argv[3]
    print(next_token)
PY
)" || die 'incomplete R2 inventory; refusing prune'
      [[ -n "$next" ]] || break
      token="$next"
    done
    python3 - "$tmp/keys.txt" "$tmp/list.json" <<'PY'
import json,sys
keys=open(sys.argv[1]).read().splitlines()
assert len(keys)==len(set(keys)), 'duplicate object in R2 inventory'
with open(sys.argv[2],'w') as output:json.dump({'Contents':[{'Key':key} for key in keys]},output)
PY
    for c in stable beta drill; do
      if ! read_channel "$c" "$tmp/ref-$c.json"; then
        printf '{}' >"$tmp/ref-$c.json"
      fi
    done
    python3 - "$tmp/list.json" "$board" "$tmp" <<'PY' >"$tmp/prune-keys"
import json,re,sys
listing,board,root=sys.argv[1:]
keys=[o['Key'] for o in json.load(open(listing)).get('Contents',[])]
prefix=f'releases/{board}/'
versions={}
for key in keys:
    match=re.fullmatch(re.escape(prefix)+r'([0-9]{4}\.[0-9]+\.[0-9]+)/channels/(stable|beta|drill)',key)
    if match:versions.setdefault(match[1],set()).add(match[2])
referenced=set()
for channel in ('stable','beta','drill'):
    m=json.load(open(f'{root}/ref-{channel}.json'))
    if m:referenced.add(m['version'])
sort=lambda v:tuple(map(int,v.split('.')))
family=sorted((v for v,flags in versions.items() if flags & {'stable','beta'}),key=sort,reverse=True)
drill=sorted((v for v,flags in versions.items() if 'drill' in flags),key=sort,reverse=True)
for v,flags in versions.items():
    if v in referenced or v in family[:3] or (('drill' in flags) and v in drill[:1]):continue
    for key in keys:
        if key.startswith(prefix+v+'/'):print(key)
PY
    if [[ ! -s "$tmp/prune-keys" ]]; then printf 'No eligible release keys to prune for %s\n' "$board"; fi
    while IFS= read -r key; do
      [[ "$key" == releases/"$board"/* ]] || die 'prune escaped board prefix'
      if [[ "$dry_run" == 1 ]]; then printf 'PLAN delete %s\n' "$key"; else s3 delete-object --key "$key" >/dev/null; fi
    done <"$tmp/prune-keys"
    ;;
  --selftest)
    [[ "$dry_run" == 0 ]] || { printf 'PLAN synthetic 629145600-byte / 3-part R2 round trip\n'; exit 0; }
    command -v curl >/dev/null || die 'curl is required for the public range proof'
    token="$(openssl rand -hex 3)"
    board=selftest
    version="2099.1.$(date +%s)$((16#$token))"
    prefix="$(release_prefix "$version")"
    truncate -s 629145600 "$tmp/bundle.raucb"
    : >"$tmp/files.tsv"; : >"$tmp/parts.tsv"
    selftest_cleanup() {
      local key failed=0
      if [[ -f "$tmp/selftest-keys" ]]; then
        while IFS= read -r key; do
          if ! s3 delete-object --key "$key" >/dev/null; then
            printf 'selftest cleanup failed: %s\n' "$key" >&2; failed=1
          elif s3 head-object --key "$key" >/dev/null 2>"$tmp/cleanup-error"; then
            printf 'selftest object survived deletion: %s\n' "$key" >&2; failed=1
          elif ! missing "$tmp/cleanup-error"; then
            printf 'selftest deletion unverified: %s\n' "$key" >&2; failed=1
          fi
        done <"$tmp/selftest-keys"
      fi
      rm -rf -- "$tmp"
      return "$failed"
    }
    trap selftest_cleanup EXIT
    if current_etag "$prefix/index.json" >/dev/null; then die 'selftest prefix collision'; fi
    printf '%s\n' "$prefix/bundle.raucb.part0000" "$prefix/bundle.raucb.part0001" "$prefix/bundle.raucb.part0002" "$prefix/index.json" >"$tmp/selftest-keys"
    make_parts bundle.raucb "$tmp/bundle.raucb" "$prefix"
    build_index
    immutable "$prefix/index.json" "$tmp/index.json" application/json
    python3 - "$tmp/index.json" <<'PY'
import json,sys
parts=json.load(open(sys.argv[1]))['files']['bundle.raucb']['parts']
assert [p['size'] for p in parts]==[268435456,268435456,92274688]
PY
    curl -fsS --retry 2 -H 'Range: bytes=268435400-268435600' \
      "https://images.ceralive.tv/$prefix/bundle.raucb" -o "$tmp/range"
    dd if="$tmp/bundle.raucb" of="$tmp/expected-range" bs=1 skip=268435400 count=201 status=none
    cmp "$tmp/range" "$tmp/expected-range" || die 'selftest cross-part Range read mismatch'
    printf 'selftest PASS: 629145600 bytes / 268435456,268435456,92274688; cross-boundary Range identical\n'
    ;;
  *) usage; die "invalid mode: $mode" ;;
esac
