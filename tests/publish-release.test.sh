#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/objects" "$tmp/signer" "$tmp/other" "$tmp/publisher-tmp"
export TMPDIR="$tmp/publisher-tmp"
export STUB_R2="$tmp/objects" STUB_LOG="$tmp/aws.log" R2_IMAGES_BUCKET=ceralive-images
export R2_IMAGES_ENDPOINT="https://stub.invalid" R2_IMAGES_ACCESS_KEY_ID=stub R2_IMAGES_SECRET_ACCESS_KEY=stub
export OTA_MANIFEST_SIGNER_DIR="$tmp/signer"
export RAUC_BUNDLE_KEYRING="$tmp/signer/root-ca.pem"
cat >"$tmp/bin/aws" <<'PY'
#!/usr/bin/env python3
import hashlib,json,os,pathlib,shutil,signal,sys
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
    if os.environ.get('STUB_KILL_AFTER_SIG')=='1' and key.startswith('channels/') and key.endswith('.json.sig'):
        os.kill(os.getppid(),signal.SIGKILL)
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
    keys=sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and str(p.relative_to(root)).startswith(prefix))
    start=int(flag('--continuation-token','0'))
    size=int(os.environ.get('STUB_PAGE_SIZE','100000'))
    page=keys[start:start+size]
    response={'Contents':[{'Key':item} for item in page], 'IsTruncated':start+size<len(keys)}
    if response['IsTruncated'] and os.environ.get('STUB_NO_NEXT')!='1':response['NextContinuationToken']=str(start+size)
    print(json.dumps(response))
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
mkdir -p "$tmp/rootfs/etc" "$tmp/rauc-input"
printf 'publisher fixture\n' >"$tmp/rootfs/etc/hostname"
dd if=/dev/urandom of="$tmp/rootfs/etc/fixture" bs=16K count=1 status=none
truncate -s 16M "$tmp/rauc-input/rootfs.ext4"
mkfs.ext4 -q -F -d "$tmp/rootfs" "$tmp/rauc-input/rootfs.ext4"
make_bundle() {
  local compatible="$1" output="$2"
  printf '[update]\ncompatible=%s\nversion=1\n\n[bundle]\nformat=verity\n\n[image.rootfs]\nfilename=rootfs.ext4\n' "$compatible" >"$tmp/rauc-input/manifest.raucm"
  rauc bundle --cert="$tmp/bundle.pem" --key="$tmp/bundle.key" --intermediate="$tmp/signer/intermediate-ca.pem" \
    "$tmp/rauc-input" "$output" >/dev/null
}
make_bundle ceralive-rock-5b-plus "$tmp/bundle.raucb"
printf 'flash-content\n' >"$tmp/flash.raw"
xz -c "$tmp/flash.raw" >"$tmp/flash.raw.xz"
( cd "$tmp" && sha256sum flash.raw > raw.sha256 )
publish() {
  local v="$1" c="$2"
  bash "$repo/ci/publish-release.sh" publish --board rock-5b-plus --version "$v" --channel "$c" --bundle "$tmp/bundle.raucb" --flash "$tmp/flash.raw.xz" --raw-sha256 "$tmp/raw.sha256" --lock "$tmp/lock.json"
}
refresh() {
  local b="$1" c="$2" serial="$3" file etag
  file="$tmp/objects/channels/$c/$b.json"
  etag="\"$(openssl dgst -md5 "$file" | cut -d' ' -f2)\""
  bash "$repo/ci/publish-release.sh" refresh --board "$b" --channel "$c" --expect-serial "$serial" --expect-etag "$etag"
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
cp "$tmp/bundle.raucb" "$tmp/original.raucb"
printf 'changed-bundle\n' >"$tmp/bundle.raucb"
if publish 2026.10.1 drill >"$tmp/content-collision.log" 2>&1; then
  printf 'FAIL: changed immutable part accepted\n' >&2; exit 1
fi
assert grep -q 'signed bundle verification failed' "$tmp/content-collision.log"
assert test ! -e "$tmp/objects/channels/drill/rock-5b-plus.json"
cp "$tmp/original.raucb" "$tmp/bundle.raucb"
printf 'second signed candidate\n' >"$tmp/rootfs/etc/hostname"
mkfs.ext4 -q -F -d "$tmp/rootfs" "$tmp/rauc-input/rootfs.ext4"
make_bundle ceralive-rock-5b-plus "$tmp/changed-valid.raucb"
if bash "$repo/ci/publish-release.sh" publish --board rock-5b-plus --version 2026.10.1 --channel drill \
    --bundle "$tmp/changed-valid.raucb" --flash "$tmp/flash.raw.xz" --raw-sha256 "$tmp/raw.sha256" --lock "$tmp/lock.json" >"$tmp/immutable-collision.log" 2>&1; then
  printf 'FAIL: valid changed bundle replaced immutable release\n' >&2; exit 1
fi
assert grep -q 'immutable R2 key exists with different bytes' "$tmp/immutable-collision.log"
printf 'PASS: changed immutable part refused before channel mutation\n'
before="$(grep -c '^put-object releases/.*/.*part' "$tmp/aws.log")"
beta="$tmp/objects/channels/beta/rock-5b-plus.json"
cp "$beta" "$tmp/beta-valid.json"; cp "$beta.sig" "$tmp/beta-valid.sig"
python3 - "$beta" <<'PY'
import json,sys
p=sys.argv[1];m=json.load(open(p));m['compatible']='ceralive-orange-pi-5-plus'
with open(p,'w') as f:json.dump(m,f,separators=(',',':'));f.write('\n')
PY
openssl cms -sign -binary -in "$beta" -signer "$tmp/signer/leaf.pem" -inkey "$tmp/signer/leaf.key" \
  -certfile "$tmp/signer/intermediate-ca.pem" -outform DER -out "$beta.sig" >/dev/null
if bash "$repo/ci/publish-release.sh" promote --board rock-5b-plus --version 2026.10.1 --to stable >"$tmp/promote-mismatch.log" 2>&1; then
  printf 'FAIL: promote accepted signed mismatched compatible\n' >&2; exit 1
fi
assert grep -q 'channel compatible mismatch' "$tmp/promote-mismatch.log"
assert test ! -e "$base/channels/stable"
cp "$tmp/beta-valid.json" "$beta"; cp "$tmp/beta-valid.sig" "$beta.sig"
printf 'PASS: promotion refuses a signed incompatible beta pointer before membership write\n'
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
refresh rock-5b-plus beta 1
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
if refresh rock-5b-plus beta 2 >"$tmp/wrong-signer.log" 2>&1; then
  printf 'FAIL: bundle leaf signed a manifest\n' >&2; exit 1
fi
assert grep -q 'wrong manifest signer CN' "$tmp/wrong-signer.log"
cp "$tmp/manifest.pem" "$tmp/signer/leaf.pem";cp "$tmp/manifest.key" "$tmp/signer/leaf.key"
openssl cms -sign -binary -in "$channel" -signer "$tmp/bundle.pem" -inkey "$tmp/bundle.key" -certfile "$tmp/signer/intermediate-ca.pem" -outform DER -out "$tmp/bundle.sig" >/dev/null
openssl cms -verify -binary -inform DER -in "$tmp/bundle.sig" -content "$channel" -CAfile "$tmp/signer/root-ca.pem" -purpose codesign -out /dev/null >/dev/null 2>&1
assert test "$(openssl x509 -in "$tmp/bundle.pem" -noout -subject -nameopt RFC2253)" = 'subject=CN=CeraLive Bundle Signer'
printf 'PASS: bundle leaf cryptographically valid but identity gate refuses it\n'
cp "$channel" "$tmp/pre-interruption.json"
cp "$channel.sig" "$tmp/pre-interruption.sig"
if (STUB_KILL_AFTER_SIG=1 refresh rock-5b-plus beta 2 >"$tmp/interrupt.log" 2>&1) 2>/dev/null; then
  printf 'FAIL: publisher survived injected process kill after signature PUT\n' >&2; exit 1
fi
assert cmp "$channel" "$tmp/pre-interruption.json"
if cmp -s "$channel.sig" "$tmp/pre-interruption.sig"; then
  printf 'FAIL: injection did not write new signature before killing publisher\n' >&2; exit 1
fi
cp "$channel.sig" "$tmp/interrupted.sig"
printf 'foreign signature\n' >"$channel.sig"
if refresh rock-5b-plus beta 2 >"$tmp/foreign-recovery.log" 2>&1; then
  printf 'FAIL: foreign signature repaired as if it were the interrupted write\n' >&2; exit 1
fi
assert grep -q 'foreign signature refused' "$tmp/foreign-recovery.log"
assert cmp "$channel" "$tmp/pre-interruption.json"
cp "$tmp/interrupted.sig" "$channel.sig"
cp "$base/index.json" "$tmp/recovery-index.good"
printf 'index drift\n' >"$base/index.json"
if refresh rock-5b-plus beta 2 >"$tmp/recovery-drift.log" 2>&1; then
  printf 'FAIL: recovery accepted drifted immutable index\n' >&2; exit 1
fi
assert cmp "$channel" "$tmp/pre-interruption.json"
cp "$tmp/recovery-index.good" "$base/index.json"
refresh rock-5b-plus beta 2 >"$tmp/recovered.log"
openssl cms -verify -binary -inform DER -in "$channel.sig" -content "$channel" -CAfile "$tmp/signer/root-ca.pem" -purpose codesign -out /dev/null >/dev/null 2>&1
assert test "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["serial"])' "$channel")" = 3
printf 'PASS: killed between signature and JSON PUT; authenticated retry repairs pair\n'
if (STUB_KILL_AFTER_SIG=1 publish 2026.10.8 drill >"$tmp/initial-interrupt.log" 2>&1) 2>/dev/null; then
  printf 'FAIL: initial publisher survived injected kill\n' >&2; exit 1
fi
assert test ! -e "$tmp/objects/channels/drill/rock-5b-plus.json"
publish 2026.10.8 drill >"$tmp/initial-recovered.log"
openssl cms -verify -binary -inform DER -in "$tmp/objects/channels/drill/rock-5b-plus.json.sig" \
  -content "$tmp/objects/channels/drill/rock-5b-plus.json" -CAfile "$tmp/signer/root-ca.pem" -purpose codesign -out /dev/null >/dev/null 2>&1
printf 'PASS: initial channel signature-only interruption resumes from authenticated intent\n'
if STUB_REPLAY=1 refresh rock-5b-plus beta 3 >"$tmp/serial-refuse.txt" 2>&1; then
  printf 'FAIL: stale serial accepted\n' >&2; exit 1
fi
assert grep -q 'serial replay refused' "$tmp/serial-refuse.txt"
printf 'PASS: stale channel ETag refuses serial replay\n'
if refresh rock-5b-plus beta 2 >"$tmp/stale-precondition.log" 2>&1; then
  printf 'FAIL: stale serial accepted\n' >&2; exit 1
fi
assert grep -q 'refresh precondition' "$tmp/stale-precondition.log"

make_bundle ceralive-orangepi5-plus "$tmp/opi.raucb"
make_bundle ceralive-orangepi5-plus-extra "$tmp/near.raucb"
for pair in "rock-5b-plus:$tmp/opi.raucb" "orange-pi-5-plus:$tmp/bundle.raucb" "orange-pi-5-plus:$tmp/near.raucb"; do
  b="${pair%%:*}" candidate="${pair#*:}"
  if bash "$repo/ci/publish-release.sh" publish --board "$b" --version 2026.12.1 --channel drill \
      --bundle "$candidate" --flash "$tmp/flash.raw.xz" --raw-sha256 "$tmp/raw.sha256" --lock "$tmp/lock.json" >"$tmp/mismatch.log" 2>&1; then
    printf 'FAIL: cross-board/near-spelling bundle accepted: %s\n' "$pair" >&2; exit 1
  fi
  assert grep -q 'signed bundle compatible mismatch' "$tmp/mismatch.log"
done
assert test ! -e "$tmp/objects/releases/orange-pi-5-plus/2026.12.1/index.json"
printf 'PASS: cross-board and near-spelling signed bundles refused before immutable writes\n'

bash "$repo/ci/publish-release.sh" publish --board orange-pi-5-plus --version 2026.12.1 --channel drill \
  --bundle "$tmp/opi.raucb" --flash "$tmp/flash.raw.xz" --raw-sha256 "$tmp/raw.sha256" --lock "$tmp/lock.json" >/dev/null
opi="$tmp/objects/channels/drill/orange-pi-5-plus.json"
python3 - "$opi" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]));assert m['compatible']=='ceralive-orangepi5-plus' and m['board']=='orange-pi-5-plus' and m['serial']==1
PY
opi_base="$tmp/objects/releases/orange-pi-5-plus/2026.12.1"
opi_index_before="$(sha256sum "$opi_base/index.json")"
opi_parts_before="$(sha256sum "$opi_base"/*.part*)"
cp "$opi" "$tmp/opi-original.json"
python3 - "$opi" <<'PY'
import json,sys
p=sys.argv[1];m=json.load(open(p));m['compatible']='ceralive-orange-pi-5-plus';m['serial']=4
with open(p,'w') as f:json.dump(m,f,separators=(',',':'));f.write('\n')
PY
openssl cms -sign -binary -in "$opi" -signer "$tmp/signer/leaf.pem" -inkey "$tmp/signer/leaf.key" \
  -certfile "$tmp/signer/intermediate-ca.pem" -outform DER -out "$opi.sig" >/dev/null
before="$(grep -c '^put-object releases/orange-pi-5-plus/' "$tmp/aws.log")"
refresh orange-pi-5-plus drill 4 >/dev/null
after="$(grep -c '^put-object releases/orange-pi-5-plus/' "$tmp/aws.log")"
[[ "$before" == "$after" && "$opi_index_before" == "$(sha256sum "$opi_base/index.json")" && "$opi_parts_before" == "$(sha256sum "$opi_base"/*.part*)" ]] || { printf 'FAIL: refresh rewrote release\n' >&2; exit 1; }
python3 - "$opi" "$tmp/opi-original.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]));old=json.load(open(sys.argv[2]))
assert m['compatible']=='ceralive-orangepi5-plus' and m['board']=='orange-pi-5-plus' and m['serial']==5
assert m['bundle']['url']=='https://images.ceralive.tv/releases/orange-pi-5-plus/2026.12.1/bundle.raucb'
assert m['version']==old['version'] and m['bundle']==old['bundle'] and m['flash']==old['flash'] and m['lock_url']==old['lock_url']
PY
openssl cms -verify -binary -inform DER -in "$opi.sig" -content "$opi" -CAfile "$tmp/signer/root-ca.pem" -purpose codesign -out /dev/null >/dev/null 2>&1
printf 'PASS: legacy signed Orange pointer refresh corrects compatible at serial 5 without release writes\n'

cp "$opi" "$tmp/opi.good.json"; cp "$opi.sig" "$tmp/opi.good.sig"
python3 - "$opi" <<'PY'
import json,sys
p=sys.argv[1];m=json.load(open(p));m['bundle']['url']=m['bundle']['url'].replace('orange-pi-5-plus','rock-5b-plus')
with open(p,'w') as f:json.dump(m,f,separators=(',',':'));f.write('\n')
PY
openssl cms -sign -binary -in "$opi" -signer "$tmp/signer/leaf.pem" -inkey "$tmp/signer/leaf.key" \
  -certfile "$tmp/signer/intermediate-ca.pem" -outform DER -out "$opi.sig" >/dev/null
if refresh orange-pi-5-plus drill 5 >"$tmp/wrong-url.log" 2>&1; then printf 'FAIL: signed cross-board URL accepted\n' >&2; exit 1; fi
assert grep -q 'channel bundle/index mismatch' "$tmp/wrong-url.log"
cp "$tmp/opi.good.json" "$opi";cp "$tmp/opi.good.sig" "$opi.sig"
part="$opi_base/bundle.raucb.part0000";cp "$part" "$tmp/part.good"
printf wrong >>"$part"
if refresh orange-pi-5-plus drill 5 >"$tmp/drift.log" 2>&1; then printf 'FAIL: drifted release part accepted\n' >&2; exit 1; fi
assert grep -q 'release part drift' "$tmp/drift.log"
cp "$tmp/part.good" "$part"
cp "$opi_base/index.json" "$tmp/index.good"
python3 - "$opi_base/index.json" <<'PY'
import json,sys
p=sys.argv[1];i=json.load(open(p));i['files']['bundle.raucb']['sha256']='0'*64
with open(p,'w') as f:json.dump(i,f)
PY
if refresh orange-pi-5-plus drill 5 >"$tmp/index-drift.log" 2>&1; then printf 'FAIL: drifted index accepted\n' >&2; exit 1; fi
assert grep -q 'bundle.raucb digest differs from index' "$tmp/index-drift.log"
cp "$tmp/index.good" "$opi_base/index.json"
python3 - "$opi.sig" <<'PY'
import sys
p=sys.argv[1]
with open(p,'rb') as f:content=bytearray(f.read())
content[-1]^=1
with open(p,'wb') as f:f.write(content)
PY
if refresh orange-pi-5-plus drill 5 >"$tmp/bad-signature.log" 2>&1; then printf 'FAIL: unsigned old pointer accepted\n' >&2; exit 1; fi
assert grep -q 'signed channel verification failed' "$tmp/bad-signature.log"
cp "$tmp/opi.good.sig" "$opi.sig"
printf 'PASS: signed wrong URL and immutable part drift both refuse refresh\n'
for v in 2026.10.2 2026.10.3 2026.10.4 2026.10.5; do publish "$v" beta >/dev/null; done
mkdir -p "$tmp/objects/releases/rock-5b-plus/2026.9.9"
printf orphan >"$tmp/objects/releases/rock-5b-plus/2026.9.9/index.json"
output="$(STUB_PAGE_SIZE=3 bash "$repo/ci/publish-release.sh" prune --board rock-5b-plus --channel-family --dry-run)"
[[ "$output" == *'2026.10.2'* && "$output" != *'2026.10.1/'* && "$output" != *'2026.9.9/'* ]] || { printf 'FAIL: prune plan not 3 newest + referenced + unmarked\n' >&2; exit 1; }
if STUB_PAGE_SIZE=3 STUB_NO_NEXT=1 bash "$repo/ci/publish-release.sh" prune --board rock-5b-plus --channel-family >"$tmp/incomplete.log" 2>&1; then
  printf 'FAIL: incomplete inventory was accepted\n' >&2; exit 1
fi
assert grep -q 'incomplete R2 inventory' "$tmp/incomplete.log"
stable_pointer="$tmp/objects/channels/stable/rock-5b-plus.json"
cp "$stable_pointer" "$tmp/stable-prune-valid.json"
cp "$stable_pointer.sig" "$tmp/stable-prune-valid.sig"
assert test -f "$base/index.json"
assert test -f "$tmp/objects/releases/rock-5b-plus/2026.10.2/index.json"
python3 - "$stable_pointer" <<'PY'
import json,sys
p=sys.argv[1];m=json.load(open(p))
assert m['version']=='2026.10.1' and m['channel']=='stable'
m['version']='2026.10.5'
with open(p,'w') as f:json.dump(m,f,separators=(',',':'));f.write('\n')
PY
if bash "$repo/ci/publish-release.sh" prune --board rock-5b-plus --channel-family >"$tmp/prune-tampered.log" 2>&1; then
  printf 'FAIL: prune accepted tampered stable pointer and deleted its signed-only release\n' >&2; exit 1
fi
assert grep -q 'signed channel verification failed: stable' "$tmp/prune-tampered.log"
assert test -f "$base/index.json"
assert test -f "$tmp/objects/releases/rock-5b-plus/2026.10.2/index.json"
cp "$tmp/stable-prune-valid.json" "$stable_pointer"
rm "$stable_pointer.sig"
if bash "$repo/ci/publish-release.sh" prune --board rock-5b-plus --channel-family >"$tmp/prune-unsigned.log" 2>&1; then
  printf 'FAIL: prune accepted an unsigned stable pointer\n' >&2; exit 1
fi
assert grep -q 'signed channel signature absent: stable' "$tmp/prune-unsigned.log"
assert test -f "$base/index.json"
assert test -f "$tmp/objects/releases/rock-5b-plus/2026.10.2/index.json"
cp "$tmp/stable-prune-valid.sig" "$stable_pointer.sig"
printf 'PASS: tampered or unsigned channel refuses prune before any eligible release deletion\n'
bash "$repo/ci/publish-release.sh" prune --board rock-5b-plus --channel-family >/dev/null
assert test -f "$base/index.json"
assert test -f "$tmp/objects/releases/rock-5b-plus/2026.9.9/index.json"
assert test ! -e "$tmp/objects/releases/rock-5b-plus/2026.10.2/index.json"
printf 'PASS: prune keeps 3 newest + references, leaves unmarked versions alone\n'
printf 'PASS: paginated inventory complete; missing continuation refuses deletion\n'
publish 2026.11.1 drill >/dev/null
publish 2026.11.2 drill >/dev/null
bash "$repo/ci/publish-release.sh" prune --board rock-5b-plus --channel-family >/dev/null
assert test ! -e "$tmp/objects/releases/rock-5b-plus/2026.11.1/index.json"
assert test -f "$tmp/objects/releases/rock-5b-plus/2026.11.2/index.json"
printf 'PASS: drill retains one newest marked version\n'
python3 - "$repo/.github/workflows/publish-release.yml" "$tmp" <<'PY'
import pathlib,sys,yaml
w=yaml.safe_load(open(sys.argv[1]))
steps=w['jobs']['publish']['steps']
signer=next(s for s in steps if s.get('name')=='Materialize dedicated signer')
assert 'if' not in signer, 'prune must materialize the existing CMS verification root'
pathlib.Path(sys.argv[2],'workflow-signer.sh').write_text(signer['run']+'\n')
for name,target in (('Validate dispatch and candidate provenance','workflow-validate.sh'),
                    ('Publish, promote, refresh, or prune','workflow-publish.sh')):
    step=next(s for s in steps if s.get('name')==name)
    pathlib.Path(sys.argv[2],target).write_text(step['run']+'\n')
PY
cat >"$tmp/bin/bash" <<'SH'
#!/bin/sh
if [ "$1" = ci/publish-release.sh ]; then
  shift
  printf '%s\n' "$@" >"$STUB_WORKFLOW_ARGV"
  exit 0
fi
exec /bin/bash "$@"
SH
chmod 700 "$tmp/bin/bash"
export MODE=refresh BOARDS=rock-5b-plus CHANNEL=beta VERSION='' CANDIDATE_RUN='' GH_TOKEN=stub
export RUNNER_TEMP="$tmp" GITHUB_REPOSITORY=CERALIVE/image-building-pipeline STUB_WORKFLOW_ARGV="$tmp/workflow-argv"
EXPECT_SERIAL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["serial"])' "$channel")"
EXPECT_ETAG="$(python3 -c 'import hashlib,json,sys;print(json.dumps(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest()))' "$channel")"
export EXPECT_SERIAL EXPECT_ETAG
workflow_refresh() { /bin/bash "$tmp/workflow-validate.sh" && /bin/bash "$tmp/workflow-publish.sh"; }
workflow_refresh >"$tmp/workflow-success.log" 2>&1
python3 - "$tmp/workflow-argv" "$EXPECT_SERIAL" "$EXPECT_ETAG" <<'PY'
import sys
assert open(sys.argv[1]).read().splitlines()==['refresh','--board','rock-5b-plus','--channel','beta',
    '--expect-serial',sys.argv[2],'--expect-etag',sys.argv[3]]
PY
rm "$tmp/workflow-argv"
saved_serial="$EXPECT_SERIAL" saved_etag="$EXPECT_ETAG"
EXPECT_SERIAL='' workflow_refresh >"$tmp/workflow-missing.log" 2>&1 && { printf 'FAIL: workflow accepted missing serial\n' >&2; exit 1; }
EXPECT_ETAG='' workflow_refresh >"$tmp/workflow-missing-etag.log" 2>&1 && { printf 'FAIL: workflow accepted missing ETag\n' >&2; exit 1; }
EXPECT_SERIAL="$((saved_serial-1))" workflow_refresh >"$tmp/workflow-stale-serial.log" 2>&1 && { printf 'FAIL: workflow accepted stale serial\n' >&2; exit 1; }
EXPECT_ETAG='"00000000000000000000000000000000"' workflow_refresh >"$tmp/workflow-stale-etag.log" 2>&1 && { printf 'FAIL: workflow accepted stale ETag\n' >&2; exit 1; }
EXPECT_ETAG="${saved_etag//\"/}" workflow_refresh >"$tmp/workflow-unquoted.log" 2>&1 && { printf 'FAIL: workflow accepted unquoted ETag\n' >&2; exit 1; }
assert test ! -e "$tmp/workflow-argv"
export EXPECT_SERIAL="$saved_serial" EXPECT_ETAG="$saved_etag"
printf 'PASS: workflow refresh passes observed serial + quoted ETag and refuses missing/stale values\n'
OTA_MANIFEST_SIGNER_TAR_B64="$(tar -czf - -C "$tmp/signer" leaf.key leaf.pem intermediate-ca.pem root-ca.pem | base64 -w0)"
export OTA_MANIFEST_SIGNER_TAR_B64
MODE=prune /bin/bash "$tmp/workflow-signer.sh"
assert cmp "$tmp/signer/root-ca.pem" "$RUNNER_TEMP/ota-manifest-signer/root-ca.pem"
unset OTA_MANIFEST_SIGNER_TAR_B64
printf 'PASS: prune workflow provides the existing CMS verification root\n'
if [[ -n "${PUBLISH_TEST_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$PUBLISH_TEST_EVIDENCE_DIR"
  cp "$tmp/serial-refuse.txt" "$PUBLISH_TEST_EVIDENCE_DIR/serial-refuse.txt"
fi
printf 'publish-release: PASS\n'
