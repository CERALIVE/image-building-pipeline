#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/objects" "$tmp/signer" "$tmp/other"
export STUB_R2="$tmp/objects" STUB_LOG="$tmp/aws.log" R2_IMAGES_BUCKET=ceralive-images
export R2_IMAGES_ENDPOINT="https://stub.invalid" R2_IMAGES_ACCESS_KEY_ID=stub R2_IMAGES_SECRET_ACCESS_KEY=stub
export OTA_MANIFEST_SIGNER_DIR="$tmp/signer"
cat >"$tmp/bin/aws" <<'PY'
#!/usr/bin/env python3
import hashlib,json,os,pathlib,shutil,sys
args=sys.argv[1:]
assert args.pop(0)=='s3api'
op=args.pop(0)
def flag(name,default=None):
    if name not in args:return default
    i=args.index(name)
    return args[i+1] if i+1<len(args) else None
key=flag('--key')
root=pathlib.Path(os.environ['STUB_R2'])
if key and ('..' in key.split('/') or key.startswith('/')):sys.exit(2)
path=root/key if key else root
with open(os.environ['STUB_LOG'],'a') as log:log.write(f'{op} {key or flag("--prefix","")}\n')
def error(code):print(f'An error occurred ({code}) when calling the {op} operation',file=sys.stderr);sys.exit(1)
if op=='put-object':
    if '--if-none-match' in args and path.exists():error('PreconditionFailed')
    if '--if-match' in args and (not path.exists() or flag('--if-match')!='"'+hashlib.md5(path.read_bytes()).hexdigest()+'"'):error('PreconditionFailed')
    if os.environ.get('STUB_REPLAY')=='1' and key.startswith('channels/') and key.endswith('.json'):error('PreconditionFailed')
    path.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(flag('--body'),path)
    print('{}')
elif op=='get-object':
    if not path.is_file():error('NoSuchKey')
    values={'--bucket','--endpoint-url','--key','--range'}
    pos=[];i=0
    while i<len(args):
        if args[i] in values:i+=2
        else:pos.append(args[i]);i+=1
    assert len(pos)==1
    shutil.copyfile(path,pos[0]);print('{}')
elif op=='head-object':
    if not path.is_file():error('NotFound')
    print('"'+hashlib.md5(path.read_bytes()).hexdigest()+'"')
elif op=='list-objects-v2':
    prefix=flag('--prefix','')
    print(json.dumps({'Contents':[{'Key':str(p.relative_to(root))} for p in root.rglob('*') if p.is_file() and str(p.relative_to(root)).startswith(prefix)]}))
elif op=='delete-object':
    path.unlink(missing_ok=True);print('{}')
else:error('UnsupportedOperation')
PY
chmod 700 "$tmp/bin/aws"
export PATH="$tmp/bin:$PATH"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/signer/root-ca.key" -out "$tmp/signer/root-ca.pem" -days 10 -subj '/CN=Test root' -addext 'basicConstraints=critical,CA:TRUE,pathlen:1' -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$tmp/signer/intermediate-ca.key" -out "$tmp/signer/intermediate.csr" -subj '/CN=Test intermediate' >/dev/null 2>&1
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' >"$tmp/intermediate.ext"
openssl x509 -req -in "$tmp/signer/intermediate.csr" -CA "$tmp/signer/root-ca.pem" -CAkey "$tmp/signer/root-ca.key" -CAcreateserial -days 10 -extfile "$tmp/intermediate.ext" -out "$tmp/signer/intermediate-ca.pem" >/dev/null 2>&1
for kind in manifest bundle; do
  if [[ "$kind" == manifest ]]; then cn='CeraLive OTA Manifest Signer'; eku='codeSigning'; else cn='CeraLive Bundle Signer'; eku='emailProtection,codeSigning'; fi
  openssl req -newkey rsa:2048 -nodes -keyout "$tmp/$kind.key" -out "$tmp/$kind.csr" -subj "/CN=$cn" >/dev/null 2>&1
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=%s\n' "$eku" >"$tmp/$kind.ext"
  openssl x509 -req -in "$tmp/$kind.csr" -CA "$tmp/signer/intermediate-ca.pem" -CAkey "$tmp/signer/intermediate-ca.key" -CAcreateserial -days 10 -extfile "$tmp/$kind.ext" -out "$tmp/$kind.pem" >/dev/null 2>&1
done
cp "$tmp/manifest.key" "$tmp/signer/leaf.key"
cp "$tmp/manifest.pem" "$tmp/signer/leaf.pem"
printf '{"schema":1}\n' >"$tmp/lock.json"
printf 'bundle-content\n' >"$tmp/bundle.raucb"
printf 'flash-content\n' >"$tmp/flash.raw"
xz -c "$tmp/flash.raw" >"$tmp/flash.raw.xz"
( cd "$tmp" && sha256sum flash.raw > raw.sha256 )
publish() {
  local v="$1" c="$2"
  bash "$repo/ci/publish-release.sh" publish --board rock-5b-plus --version "$v" --channel "$c" --bundle "$tmp/bundle.raucb" --flash "$tmp/flash.raw.xz" --raw-sha256 "$tmp/raw.sha256" --lock "$tmp/lock.json"
}
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
publish 2026.10.1 beta
base="$tmp/objects/releases/rock-5b-plus/2026.10.1"
assert test -f "$base/channels/beta"
python3 - "$base/index.json" "$tmp/objects/channels/beta/rock-5b-plus.json" <<'PY'
import json,sys
i=json.load(open(sys.argv[1]));m=json.load(open(sys.argv[2]))
assert i['schema']==1 and set(i['files'])=={'bundle.raucb','flash.raw.xz'}
assert set(m)=={'schema','board','compatible','channel','version','serial','published_at','expires_at','os_version_id','min_ceraui_version','bundle','flash','lock_url'}
assert set(m['bundle'])=={'url','size','sha256'} and set(m['flash'])=={'url','size','sha256','raw_sha256'}
assert m['schema']==1 and m['serial']==1 and m['min_ceraui_version']=='2026.9.3'
assert m['flash']['raw_sha256']!=m['flash']['sha256']
assert m['compatible']=='ceralive-rock-5b-plus' and m['lock_url'].endswith('/packages.lock.json')
PY
channel="$tmp/objects/channels/beta/rock-5b-plus.json"
openssl cms -verify -binary -inform DER -in "$channel.sig" -content "$channel" -CAfile "$tmp/signer/root-ca.pem" -purpose codesign -out /dev/null >/dev/null 2>&1
printf 'PASS: dedicated CMS signature verifies with test keyring\n'
python3 - "$tmp/aws.log" <<'PY'
import sys
puts=[l for l in open(sys.argv[1]) if l.startswith('put-object')]
assert puts[-2].strip()=='put-object channels/beta/rock-5b-plus.json.sig'
assert puts[-1].strip()=='put-object channels/beta/rock-5b-plus.json'
PY
printf 'PASS: signature before manifest LAST\n'
if publish 2026.10.1 beta >"$tmp/collision.log" 2>&1; then
  printf 'FAIL: same-version channel replay should be refused\n' >&2; exit 1
fi
if ! grep -q 'serial replay refused' "$tmp/collision.log"; then
  printf 'FAIL: unexpected collision refusal:\n' >&2
  sed -n '1,8p' "$tmp/collision.log" >&2
  exit 1
fi
printf 'PASS: create-only collision refused\n'
printf 'changed-bundle\n' >"$tmp/bundle.raucb"
if publish 2026.10.1 drill >"$tmp/content-collision.log" 2>&1; then
  printf 'FAIL: changed immutable part accepted\n' >&2; exit 1
fi
assert grep -q 'immutable R2 key exists with different bytes' "$tmp/content-collision.log"
assert test ! -e "$tmp/objects/channels/drill/rock-5b-plus.json"
printf 'bundle-content\n' >"$tmp/bundle.raucb"
printf 'PASS: changed immutable part refused before channel mutation\n'
before="$(grep -c '^put-object releases/.*/.*part' "$tmp/aws.log")"
bash "$repo/ci/publish-release.sh" promote --board rock-5b-plus --version 2026.10.1 --to stable
after="$(grep -c '^put-object releases/.*/.*part' "$tmp/aws.log")"
[[ "$before" == "$after" ]] || { printf 'FAIL: promote uploaded parts\n' >&2; exit 1; }
assert test -f "$base/channels/stable"
python3 - "$tmp/objects/channels/stable/rock-5b-plus.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]));assert m['channel']=='stable' and m['serial']==1 and m['version']=='2026.10.1'
PY
printf 'PASS: promote reused existing parts\n'
before="$(grep -c '^put-object releases/.*/.*part' "$tmp/aws.log")"
cp "$channel" "$tmp/beta-before.json"
bash "$repo/ci/publish-release.sh" refresh --board rock-5b-plus --channel beta
after="$(grep -c '^put-object releases/.*/.*part' "$tmp/aws.log")"
[[ "$before" == "$after" ]] || { printf 'FAIL: refresh uploaded parts\n' >&2; exit 1; }
python3 - "$channel" "$tmp/objects/channels/stable/rock-5b-plus.json" "$tmp/beta-before.json" <<'PY'
import json,sys,datetime
b=json.load(open(sys.argv[1]));s=json.load(open(sys.argv[2]));old=json.load(open(sys.argv[3]));assert b['serial']==2 and s['serial']==1
assert b['version']==s['version'] and b['bundle']==s['bundle'] and b['flash']==s['flash']
assert b['published_at']>old['published_at'] and b['expires_at']>old['expires_at']
PY
printf 'PASS: refresh preserved artifacts, advanced serial and expiry, no parts\n'
cp "$tmp/bundle.pem" "$tmp/signer/leaf.pem";cp "$tmp/bundle.key" "$tmp/signer/leaf.key"
if bash "$repo/ci/publish-release.sh" refresh --board rock-5b-plus --channel beta >"$tmp/wrong-signer.log" 2>&1; then
  printf 'FAIL: bundle leaf signed a manifest\n' >&2; exit 1
fi
assert grep -q 'wrong manifest signer CN' "$tmp/wrong-signer.log"
cp "$tmp/manifest.pem" "$tmp/signer/leaf.pem";cp "$tmp/manifest.key" "$tmp/signer/leaf.key"
openssl cms -sign -binary -in "$channel" -signer "$tmp/bundle.pem" -inkey "$tmp/bundle.key" -certfile "$tmp/signer/intermediate-ca.pem" -outform DER -out "$tmp/bundle.sig" >/dev/null
openssl cms -verify -binary -inform DER -in "$tmp/bundle.sig" -content "$channel" -CAfile "$tmp/signer/root-ca.pem" -purpose codesign -out /dev/null >/dev/null 2>&1
assert test "$(openssl x509 -in "$tmp/bundle.pem" -noout -subject -nameopt RFC2253)" = 'subject=CN=CeraLive Bundle Signer'
printf 'PASS: bundle leaf cryptographically valid but identity gate refuses it\n'
if STUB_REPLAY=1 bash "$repo/ci/publish-release.sh" refresh --board rock-5b-plus --channel beta >"$tmp/serial-refuse.txt" 2>&1; then
  printf 'FAIL: stale serial accepted\n' >&2; exit 1
fi
assert grep -q 'serial replay refused' "$tmp/serial-refuse.txt"
printf 'PASS: stale channel ETag refuses serial replay\n'
for v in 2026.10.2 2026.10.3 2026.10.4 2026.10.5; do publish "$v" beta >/dev/null; done
mkdir -p "$tmp/objects/releases/rock-5b-plus/2026.9.9"
printf orphan >"$tmp/objects/releases/rock-5b-plus/2026.9.9/index.json"
output="$(bash "$repo/ci/publish-release.sh" prune --board rock-5b-plus --channel-family --dry-run)"
[[ "$output" == *'2026.10.2'* && "$output" != *'2026.10.1/'* && "$output" != *'2026.9.9/'* ]] || { printf 'FAIL: prune plan not 3 newest + referenced + unmarked\n' >&2; exit 1; }
bash "$repo/ci/publish-release.sh" prune --board rock-5b-plus --channel-family >/dev/null
assert test -f "$base/index.json"
assert test -f "$tmp/objects/releases/rock-5b-plus/2026.9.9/index.json"
assert test ! -e "$tmp/objects/releases/rock-5b-plus/2026.10.2/index.json"
printf 'PASS: prune keeps 3 newest + references, leaves unmarked versions alone\n'
publish 2026.11.1 drill >/dev/null
publish 2026.11.2 drill >/dev/null
bash "$repo/ci/publish-release.sh" prune --board rock-5b-plus --channel-family >/dev/null
assert test ! -e "$tmp/objects/releases/rock-5b-plus/2026.11.1/index.json"
assert test -f "$tmp/objects/releases/rock-5b-plus/2026.11.2/index.json"
printf 'PASS: drill retains one newest marked version\n'
if [[ -n "${PUBLISH_TEST_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$PUBLISH_TEST_EVIDENCE_DIR"
  cp "$tmp/serial-refuse.txt" "$PUBLISH_TEST_EVIDENCE_DIR/serial-refuse.txt"
fi
printf 'publish-release: PASS\n'
