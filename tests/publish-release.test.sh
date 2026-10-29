#!/usr/bin/env bash
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$repo/tests/lib/assertions.sh"
check() { if "$@"; then ok "$*"; else bad "$*"; fi; }
tmp=''
finish() {
  local status=$?
  [[ "$status" -eq 0 || "$FAIL" -gt 0 ]] || bad "unexpected exit: $status"
  [[ -z "$tmp" ]] || rm -rf "$tmp"
  printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
trap 'finish; exit $?' EXIT
set -o errtrace
trap 'bad "fixture command failed at line $LINENO: $BASH_COMMAND"; exit 1' ERR
check python3 - "$repo/.github/workflows/publish-release.yml" <<'PY'
from pathlib import Path
import sys

workflow = Path(sys.argv[1]).read_text()
step = workflow.split('- name: Publish, promote, refresh, or prune', 1)[1].split('- name: Remove materialized secrets', 1)[0]
script = step.split('run: |', 1)[1]
before_read = script.split('aws s3api get-object', 1)[0]
for destination, source in (
    ('AWS_ACCESS_KEY_ID', 'R2_IMAGES_ACCESS_KEY_ID'),
    ('AWS_SECRET_ACCESS_KEY', 'R2_IMAGES_SECRET_ACCESS_KEY'),
):
    assert f'export {destination}="${source}"' in before_read, f'{destination} not exported before refresh pre-read'
assert 'export AWS_DEFAULT_REGION=auto' in before_read, 'refresh pre-read missing AWS region'
PY
umask 077
tmp="$(mktemp -d)"
mkdir -p "$tmp/bin" "$tmp/objects" "$tmp/signer" "$tmp/other" "$tmp/publisher-tmp"
mkdir -p "$tmp/publisher-cwd"
ln -s "$repo/lib" "$tmp/publisher-cwd/lib"
ln -s "$repo/manifests" "$tmp/publisher-cwd/manifests"
printf 'CeraUI:\n  pin: v2026.9.3\n' >"$tmp/publisher-cwd/versions.yaml"
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
openssl req -newkey rsa:2048 -nodes -keyout "$tmp/signer/intermediate-ca.key" -out "$tmp/signer/intermediate.csr" -subj '/O=CeraLive/CN=CeraLive RAUC Intermediate CA' >/dev/null 2>&1
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
ROOT="$repo" WORK="$tmp"
source "$repo/tests/lib/kernel-release-fixtures.sh"
export CERALIVE_KERNEL_HISTORY_DIR="$tmp/kernel-history"
kernel_test_artifact "$CERALIVE_KERNEL_HISTORY_DIR/7.2.0-ceralive1" 7.2.0-ceralive1 "$repo"
jq '{schema:1,packages:[{name:.package,version,arch,origin:"ceralive-kernel",sha256:.deb_sha256}]}' \
  "$CERALIVE_KERNEL_HISTORY_DIR/7.2.0-ceralive1/kernel-artifact.json" >"$tmp/lock.json"
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
publisher() {
  ( cd "$tmp/publisher-cwd" && bash "${PUBLISH_RELEASE_SCRIPT:-$repo/ci/publish-release.sh}" "$@" )
}
publish() {
  local v="$1" c="$2"
  publisher publish --board rock-5b-plus --version "$v" --channel "$c" --bundle "$tmp/bundle.raucb" --flash "$tmp/flash.raw.xz" --raw-sha256 "$tmp/raw.sha256" --lock "$tmp/lock.json"
}
refresh() {
  local b="$1" c="$2" serial="$3" file etag
  file="$tmp/objects/channels/$c/$b.json"
  etag="\"$(openssl dgst -md5 "$file" | cut -d' ' -f2)\""
  publisher refresh --board "$b" --channel "$c" --expect-serial "$serial" --expect-etag "$etag"
}
assert() { check "$@"; }
check publish 2026.10.1 beta
base="$tmp/objects/releases/rock-5b-plus/2026.10.1"
assert test -f "$base/channels/beta"
check python3 - "$base/kernel.json" "$tmp/lock.json" <<'PY'
import json,sys
sidecar,lock=(json.load(open(p)) for p in sys.argv[1:])
row=lock['packages'][0]
assert sidecar == {'schema':1,'board':'rock-5b-plus','os_version':'2026.10.1',
                   'kernel':{'package':row['name'],'version':row['version'],'deb_sha256':row['sha256']}}
PY
check openssl cms -verify -binary -inform DER -in "$base/kernel.json.sig" \
  -content "$base/kernel.json" -CAfile "$tmp/signer/root-ca.pem" -purpose any -out /dev/null >/dev/null 2>&1
check python3 - "$base/index.json" "$tmp/objects/channels/beta/rock-5b-plus.json" <<'PY'
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
check openssl cms -verify -binary -inform DER -in "$channel.sig" -content "$channel" -CAfile "$tmp/signer/root-ca.pem" -purpose any -out /dev/null >/dev/null 2>&1
check python3 - "$tmp/aws.log" <<'PY'
import sys
puts=[l for l in open(sys.argv[1]) if l.startswith('put-object')]
assert puts[-2].strip()=='put-object channels/beta/rock-5b-plus.json.sig'
assert puts[-1].strip()=='put-object channels/beta/rock-5b-plus.json'
PY
make_issuer() {
  local name="$1" subject="$2" root="${3:-$tmp/signer/root-ca}"
  openssl req -newkey rsa:2048 -nodes -keyout "$tmp/$name.key" -out "$tmp/$name.csr" \
    -subj "$subject" >/dev/null 2>&1
  openssl x509 -req -in "$tmp/$name.csr" -CA "$root.pem" \
    -CAkey "$root.key" -CAcreateserial -days 10 \
    -extfile "$tmp/intermediate.ext" -out "$tmp/$name.pem" >/dev/null 2>&1
}
make_issuer bench '/O=CeraLive/CN=CeraLive RAUC Bench Intermediate CA'
make_issuer alternate '/O=CeraLive/CN=CeraLive Other Intermediate CA'
make_issuer near '/OU=Extra/O=CeraLive/CN=CeraLive RAUC Intermediate CA'
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/foreign-root.key" -out "$tmp/foreign-root.pem" -days 10 \
  -subj '/CN=Foreign Root' -addext 'basicConstraints=critical,CA:TRUE,pathlen:1' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
make_issuer foreign '/O=CeraLive/CN=CeraLive RAUC Intermediate CA' "$tmp/foreign-root"
for kind in bench root alternate near foreign; do
  ca="$tmp/$kind"
  [[ "$kind" != root ]] || ca="$tmp/signer/root-ca"
  openssl x509 -req -in "$tmp/manifest.csr" -CA "$ca.pem" -CAkey "$ca.key" \
    -CAcreateserial -days 10 -extfile "$tmp/manifest.ext" -out "$tmp/$kind-manifest.pem" >/dev/null 2>&1
done
printf '1000\n' >"$tmp/serial"
: >"$tmp/cert-index"
printf 'unique_subject = no\n' >"$tmp/cert-index.attr"
cat >"$tmp/dates.cnf" <<EOF
[ca]
default_ca = fixture
[fixture]
database = $tmp/cert-index
new_certs_dir = $tmp
certificate = $tmp/production-intermediate.pem
private_key = $tmp/signer/intermediate-ca.key
serial = $tmp/serial
default_md = sha256
policy = names
x509_extensions = leaf_ext
[names]
commonName = supplied
[leaf_ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
EOF
cp "$tmp/signer/intermediate-ca.pem" "$tmp/production-intermediate.pem"
openssl ca -batch -config "$tmp/dates.cnf" -startdate 20250101000000Z -enddate 20250102000000Z \
  -in "$tmp/manifest.csr" -out "$tmp/expired-manifest.pem" >/dev/null 2>&1
openssl req -new -key "$tmp/manifest.key" -subj '/O=CeraLive/CN=CeraLive OTA Manifest Signer' \
  -out "$tmp/future.csr" >/dev/null 2>&1
openssl ca -batch -config "$tmp/dates.cnf" -startdate 20350101000000Z -enddate 20360101000000Z \
  -in "$tmp/future.csr" -out "$tmp/future-manifest.pem" >/dev/null 2>&1
set_signer() {
  local kind="$1"
  if [[ "$kind" == production ]]; then
    cp "$tmp/manifest.pem" "$tmp/signer/leaf.pem"
    cp "$tmp/production-intermediate.pem" "$tmp/signer/intermediate-ca.pem"
  else
    cp "$tmp/$kind-manifest.pem" "$tmp/signer/leaf.pem"
    if [[ "$kind" == root || "$kind" == expired || "$kind" == future ]]; then
      cp "$tmp/production-intermediate.pem" "$tmp/signer/intermediate-ca.pem"
    else
      cp "$tmp/$kind.pem" "$tmp/signer/intermediate-ca.pem"
    fi
  fi
}
sign_channel() {
  local target="$1" kind="$2" cert chain
  cert="$tmp/$kind-manifest.pem" chain="$tmp/$kind.pem"
  [[ "$kind" != production ]] || { cert="$tmp/manifest.pem"; chain="$tmp/production-intermediate.pem"; }
  [[ "$kind" != expired && "$kind" != future ]] || chain="$tmp/production-intermediate.pem"
  local args=()
  [[ "$kind" != root ]] || chain=''
  [[ -z "$chain" ]] || args=(-certfile "$chain")
  openssl cms -sign -binary -in "$target" -signer "$cert" -inkey "$tmp/manifest.key" \
    "${args[@]}" -outform DER -out "$target.sig" >/dev/null
}
set_signer bench
check publish 2026.10.7 drill >"$tmp/bench-publish.log"
set_signer production
for kind in root alternate near foreign expired future; do
  set_signer "$kind"
  if publish 2026.10.9 drill >"$tmp/$kind-publish.log" 2>&1; then
    bad "$kind-issued signer published a channel"
  else
    ok "$kind-issued signer refused"
  fi
  if [[ "$kind" == root || "$kind" == alternate || "$kind" == near ]]; then
    issuer="$(openssl x509 -in "$tmp/$kind-manifest.pem" -noout -issuer -nameopt RFC2253)"
    assert grep -F -- "${issuer#issuer=}" "$tmp/$kind-publish.log"
  fi
done
set_signer production
cp "$channel.sig" "$tmp/production-channel.sig"
for kind in bench root alternate near foreign expired future; do
  sign_channel "$channel" "$kind"
  if [[ "$kind" == bench ]]; then
    check publisher prune --board rock-5b-plus --channel-family --dry-run >"$tmp/bench-pointer.log"
  else
    if publisher prune --board rock-5b-plus --channel-family --dry-run >"$tmp/$kind-pointer.log" 2>&1; then
      bad "$kind-issued channel pointer accepted"
    else
      ok "$kind-issued channel pointer refused"
    fi
    if [[ "$kind" == root || "$kind" == alternate || "$kind" == near ]]; then
      issuer="$(openssl x509 -in "$tmp/$kind-manifest.pem" -noout -issuer -nameopt RFC2253)"
      assert grep -F -- "${issuer#issuer=}" "$tmp/$kind-pointer.log"
    fi
  fi
done
cp "$tmp/production-channel.sig" "$channel.sig"
mkdir -p "$tmp/ci"
ln -s "$repo/ci/r2-immutable-lib.sh" "$tmp/ci/r2-immutable-lib.sh"
ln -s "$repo/ci/kernel-floor-lib.sh" "$tmp/ci/kernel-floor-lib.sh"
ln -s "$repo/ci/check-kernel-version-monotonic.py" "$tmp/ci/check-kernel-version-monotonic.py"
ln -s "$repo/lib" "$tmp/lib"
python3 - "$repo/ci/publish-release.sh" "$tmp/ci/publish-release.sh" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
for check in ('manifest_signer_issuer_allowed "$issuer" || die "manifest signer issuer refused: $issuer"',
              'manifest_signer_issuer_allowed "$issuer" || { printf \'channel signer issuer refused: %s\\n\' "$issuer" >&2; return 1; }'):
    assert text.count(check)==1
    text=text.replace(check, ':')
pathlib.Path(sys.argv[2]).write_text(text)
PY
for kind in root alternate; do
  set_signer "$kind"
  STUB_R2="$tmp/mutant-$kind" STUB_LOG="$tmp/mutant-$kind.log" \
    PUBLISH_RELEASE_SCRIPT="$tmp/ci/publish-release.sh" check publish 2026.10.9 drill >"$tmp/$kind-publish-mutant.log" 2>&1
done
set_signer production
for kind in root alternate; do
  sign_channel "$channel" "$kind"
  PUBLISH_RELEASE_SCRIPT="$tmp/ci/publish-release.sh" \
    check publisher prune --board rock-5b-plus --channel-family --dry-run >"$tmp/$kind-pointer-mutant.log" 2>&1
done
cp "$tmp/production-channel.sig" "$channel.sig"
rm -f "$tmp/objects/channels/drill/rock-5b-plus.json" "$tmp/objects/channels/drill/rock-5b-plus.json.sig"
if publish 2026.10.1 beta >"$tmp/collision.log" 2>&1; then
  bad 'same-version channel replay should be refused'
else
  ok 'same-version replay refused'
fi
if ! grep -q 'serial replay refused' "$tmp/collision.log"; then
  bad 'unexpected collision refusal'
  sed -n '1,8p' "$tmp/collision.log" >&2
else
  ok 'collision diagnosed as serial replay'
fi
cp "$tmp/bundle.raucb" "$tmp/original.raucb"
printf 'changed-bundle\n' >"$tmp/bundle.raucb"
if publish 2026.10.1 drill >"$tmp/content-collision.log" 2>&1; then
  bad 'changed immutable part accepted'
else
  ok 'invalid changed immutable part refused'
fi
assert grep -q 'signed bundle verification failed' "$tmp/content-collision.log"
assert test ! -e "$tmp/objects/channels/drill/rock-5b-plus.json"
cp "$tmp/original.raucb" "$tmp/bundle.raucb"
printf 'second signed candidate\n' >"$tmp/rootfs/etc/hostname"
mkfs.ext4 -q -F -d "$tmp/rootfs" "$tmp/rauc-input/rootfs.ext4"
make_bundle ceralive-rock-5b-plus "$tmp/changed-valid.raucb"
if publisher publish --board rock-5b-plus --version 2026.10.1 --channel drill \
    --bundle "$tmp/changed-valid.raucb" --flash "$tmp/flash.raw.xz" --raw-sha256 "$tmp/raw.sha256" --lock "$tmp/lock.json" >"$tmp/immutable-collision.log" 2>&1; then
  bad 'valid changed bundle replaced immutable release'
else
  ok 'valid changed immutable part refused'
fi
assert grep -q 'immutable R2 key exists with different bytes' "$tmp/immutable-collision.log"
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
if publisher promote --board rock-5b-plus --version 2026.10.1 --to stable >"$tmp/promote-mismatch.log" 2>&1; then
  bad 'promote accepted signed mismatched compatible'
else
  ok 'promotion refused signed incompatible beta'
fi
assert grep -q 'channel compatible mismatch' "$tmp/promote-mismatch.log"
assert test ! -e "$base/channels/stable"
cp "$tmp/beta-valid.json" "$beta"; cp "$tmp/beta-valid.sig" "$beta.sig"
check publisher promote --board rock-5b-plus --version 2026.10.1 --to stable
after="$(grep -c '^put-object releases/.*/.*part' "$tmp/aws.log")"
assert_eq 'promotion does not upload parts' "$before" "$after"
assert test -f "$base/channels/stable"
check python3 - "$tmp/objects/channels/stable/rock-5b-plus.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]));assert m['channel']=='stable' and m['serial']==1 and m['version']=='2026.10.1'
PY
before="$(grep -c '^put-object releases/.*/.*part' "$tmp/aws.log")"
cp "$channel" "$tmp/beta-before.json"
check refresh rock-5b-plus beta 1
after="$(grep -c '^put-object releases/.*/.*part' "$tmp/aws.log")"
assert_eq 'refresh does not upload parts' "$before" "$after"
check python3 - "$channel" "$tmp/objects/channels/stable/rock-5b-plus.json" "$tmp/beta-before.json" <<'PY'
import json,sys,datetime
b=json.load(open(sys.argv[1]));s=json.load(open(sys.argv[2]));old=json.load(open(sys.argv[3]));assert b['serial']==2 and s['serial']==1
assert b['version']==s['version'] and b['bundle']==s['bundle'] and b['flash']==s['flash']
assert b['published_at']>old['published_at'] and b['expires_at']>old['expires_at']
PY
cp "$tmp/bundle.pem" "$tmp/signer/leaf.pem";cp "$tmp/bundle.key" "$tmp/signer/leaf.key"
if refresh rock-5b-plus beta 2 >"$tmp/wrong-signer.log" 2>&1; then
  bad 'bundle leaf signed a manifest'
else
  ok 'bundle leaf refused for manifest signing'
fi
assert grep -q 'wrong manifest signer CN' "$tmp/wrong-signer.log"
cp "$tmp/manifest.pem" "$tmp/signer/leaf.pem";cp "$tmp/manifest.key" "$tmp/signer/leaf.key"
openssl cms -sign -binary -in "$channel" -signer "$tmp/bundle.pem" -inkey "$tmp/bundle.key" -certfile "$tmp/signer/intermediate-ca.pem" -outform DER -out "$tmp/bundle.sig" >/dev/null
check openssl cms -verify -binary -inform DER -in "$tmp/bundle.sig" -content "$channel" -CAfile "$tmp/signer/root-ca.pem" -purpose any -out /dev/null >/dev/null 2>&1
assert test "$(openssl x509 -in "$tmp/bundle.pem" -noout -subject -nameopt RFC2253)" = 'subject=CN=CeraLive Bundle Signer'
openssl x509 -req -in "$tmp/manifest.csr" -CA "$tmp/signer/intermediate-ca.pem" \
  -CAkey "$tmp/signer/intermediate-ca.key" -CAcreateserial -days 10 \
  -extfile "$tmp/bundle.ext" -out "$tmp/dual-manifest.pem" >/dev/null 2>&1
cp "$channel.sig" "$tmp/manifest-original.sig"
openssl cms -sign -binary -in "$channel" -signer "$tmp/dual-manifest.pem" \
  -inkey "$tmp/manifest.key" -certfile "$tmp/signer/intermediate-ca.pem" \
  -outform DER -out "$channel.sig" >/dev/null
if publisher prune --board rock-5b-plus --channel-family --dry-run >"$tmp/dual-prune.log" 2>&1; then
  bad 'dual-EKU channel signer accepted by publisher prune'
else
  ok 'dual-EKU channel signer refused'
fi
cp "$tmp/manifest-original.sig" "$channel.sig"
cp "$channel" "$tmp/pre-interruption.json"
cp "$channel.sig" "$tmp/pre-interruption.sig"
if (STUB_KILL_AFTER_SIG=1 refresh rock-5b-plus beta 2 >"$tmp/interrupt.log" 2>&1) 2>/dev/null; then
  bad 'publisher survived injected process kill after signature PUT'
else
  ok 'publisher killed after signature PUT'
fi
assert cmp "$channel" "$tmp/pre-interruption.json"
if cmp -s "$channel.sig" "$tmp/pre-interruption.sig"; then
  bad 'injection did not write new signature before killing publisher'
else
  ok 'injection wrote new signature'
fi
cp "$channel.sig" "$tmp/interrupted.sig"
printf 'foreign signature\n' >"$channel.sig"
if refresh rock-5b-plus beta 2 >"$tmp/foreign-recovery.log" 2>&1; then
  bad 'foreign signature repaired as if it were the interrupted write'
else
  ok 'foreign recovery signature refused'
fi
assert grep -q 'foreign signature refused' "$tmp/foreign-recovery.log"
assert cmp "$channel" "$tmp/pre-interruption.json"
cp "$tmp/interrupted.sig" "$channel.sig"
cp "$base/index.json" "$tmp/recovery-index.good"
printf 'index drift\n' >"$base/index.json"
if refresh rock-5b-plus beta 2 >"$tmp/recovery-drift.log" 2>&1; then
  bad 'recovery accepted drifted immutable index'
else
  ok 'recovery refused drifted immutable index'
fi
assert cmp "$channel" "$tmp/pre-interruption.json"
cp "$tmp/recovery-index.good" "$base/index.json"
check refresh rock-5b-plus beta 2 >"$tmp/recovered.log"
check openssl cms -verify -binary -inform DER -in "$channel.sig" -content "$channel" -CAfile "$tmp/signer/root-ca.pem" -purpose any -out /dev/null >/dev/null 2>&1
assert test "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["serial"])' "$channel")" = 3
if (STUB_KILL_AFTER_SIG=1 publish 2026.10.8 drill >"$tmp/initial-interrupt.log" 2>&1) 2>/dev/null; then
  bad 'initial publisher survived injected kill'
else
  ok 'initial publisher killed after signature PUT'
fi
assert test ! -e "$tmp/objects/channels/drill/rock-5b-plus.json"
check publish 2026.10.8 drill >"$tmp/initial-recovered.log"
check openssl cms -verify -binary -inform DER -in "$tmp/objects/channels/drill/rock-5b-plus.json.sig" \
  -content "$tmp/objects/channels/drill/rock-5b-plus.json" -CAfile "$tmp/signer/root-ca.pem" -purpose any -out /dev/null >/dev/null 2>&1
if STUB_REPLAY=1 refresh rock-5b-plus beta 3 >"$tmp/serial-refuse.txt" 2>&1; then
  bad 'stale serial accepted'
else
  ok 'serial replay refused'
fi
assert grep -q 'serial replay refused' "$tmp/serial-refuse.txt"
if refresh rock-5b-plus beta 2 >"$tmp/stale-precondition.log" 2>&1; then
  bad 'stale serial accepted'
else
  ok 'stale refresh precondition refused'
fi
assert grep -q 'refresh precondition' "$tmp/stale-precondition.log"

make_bundle ceralive-orangepi5-plus "$tmp/opi.raucb"
make_bundle ceralive-orangepi5-plus-extra "$tmp/near.raucb"
for pair in "rock-5b-plus:$tmp/opi.raucb" "orange-pi-5-plus:$tmp/bundle.raucb" "orange-pi-5-plus:$tmp/near.raucb"; do
  b="${pair%%:*}" candidate="${pair#*:}"
  if publisher publish --board "$b" --version 2026.12.1 --channel drill \
      --bundle "$candidate" --flash "$tmp/flash.raw.xz" --raw-sha256 "$tmp/raw.sha256" --lock "$tmp/lock.json" >"$tmp/mismatch.log" 2>&1; then
    bad "cross-board/near-spelling bundle accepted: $pair"
  else
    ok "cross-board/near-spelling bundle refused: $pair"
  fi
  assert grep -q 'signed bundle compatible mismatch' "$tmp/mismatch.log"
done
assert test ! -e "$tmp/objects/releases/orange-pi-5-plus/2026.12.1/index.json"

check publisher publish --board orange-pi-5-plus --version 2026.12.1 --channel drill \
  --bundle "$tmp/opi.raucb" --flash "$tmp/flash.raw.xz" --raw-sha256 "$tmp/raw.sha256" --lock "$tmp/lock.json" >/dev/null
opi="$tmp/objects/channels/drill/orange-pi-5-plus.json"
check python3 - "$opi" <<'PY'
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
check refresh orange-pi-5-plus drill 4 >/dev/null
after="$(grep -c '^put-object releases/orange-pi-5-plus/' "$tmp/aws.log")"
[[ "$before" == "$after" && "$opi_index_before" == "$(sha256sum "$opi_base/index.json")" && "$opi_parts_before" == "$(sha256sum "$opi_base"/*.part*)" ]] && ok 'refresh preserves release bytes' || bad 'refresh rewrote release'
check python3 - "$opi" "$tmp/opi-original.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]));old=json.load(open(sys.argv[2]))
assert m['compatible']=='ceralive-orangepi5-plus' and m['board']=='orange-pi-5-plus' and m['serial']==5
assert m['bundle']['url']=='https://images.ceralive.tv/releases/orange-pi-5-plus/2026.12.1/bundle.raucb'
assert m['version']==old['version'] and m['bundle']==old['bundle'] and m['flash']==old['flash'] and m['lock_url']==old['lock_url']
PY
check openssl cms -verify -binary -inform DER -in "$opi.sig" -content "$opi" -CAfile "$tmp/signer/root-ca.pem" -purpose any -out /dev/null >/dev/null 2>&1

cp "$opi" "$tmp/opi.good.json"; cp "$opi.sig" "$tmp/opi.good.sig"
python3 - "$opi" <<'PY'
import json,sys
p=sys.argv[1];m=json.load(open(p));m['bundle']['url']=m['bundle']['url'].replace('orange-pi-5-plus','rock-5b-plus')
with open(p,'w') as f:json.dump(m,f,separators=(',',':'));f.write('\n')
PY
openssl cms -sign -binary -in "$opi" -signer "$tmp/signer/leaf.pem" -inkey "$tmp/signer/leaf.key" \
  -certfile "$tmp/signer/intermediate-ca.pem" -outform DER -out "$opi.sig" >/dev/null
if refresh orange-pi-5-plus drill 5 >"$tmp/wrong-url.log" 2>&1; then bad 'signed cross-board URL accepted'; else ok 'signed cross-board URL refused'; fi
assert grep -q 'channel bundle/index mismatch' "$tmp/wrong-url.log"
cp "$tmp/opi.good.json" "$opi";cp "$tmp/opi.good.sig" "$opi.sig"
part="$opi_base/bundle.raucb.part0000";cp "$part" "$tmp/part.good"
printf wrong >>"$part"
if refresh orange-pi-5-plus drill 5 >"$tmp/drift.log" 2>&1; then bad 'drifted release part accepted'; else ok 'drifted release part refused'; fi
assert grep -q 'release part drift' "$tmp/drift.log"
cp "$tmp/part.good" "$part"
cp "$opi_base/index.json" "$tmp/index.good"
python3 - "$opi_base/index.json" <<'PY'
import json,sys
p=sys.argv[1];i=json.load(open(p));i['files']['bundle.raucb']['sha256']='0'*64
with open(p,'w') as f:json.dump(i,f)
PY
if refresh orange-pi-5-plus drill 5 >"$tmp/index-drift.log" 2>&1; then bad 'drifted index accepted'; else ok 'drifted index refused'; fi
assert grep -q 'bundle.raucb digest differs from index' "$tmp/index-drift.log"
cp "$tmp/index.good" "$opi_base/index.json"
python3 - "$opi.sig" <<'PY'
import sys
p=sys.argv[1]
with open(p,'rb') as f:content=bytearray(f.read())
content[-1]^=1
with open(p,'wb') as f:f.write(content)
PY
if refresh orange-pi-5-plus drill 5 >"$tmp/bad-signature.log" 2>&1; then bad 'unsigned old pointer accepted'; else ok 'unsigned old pointer refused'; fi
assert grep -q 'signed channel verification failed' "$tmp/bad-signature.log"
cp "$tmp/opi.good.sig" "$opi.sig"
printf 'CeraUI:\n  pin: v2026.10.9\n' >"$tmp/publisher-cwd/versions.yaml"
for v in 2026.10.2 2026.10.3 2026.10.4 2026.10.5; do check publish "$v" beta >/dev/null; done
check python3 - "$tmp/objects/channels/beta/rock-5b-plus.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['min_ceraui_version']=='2026.10.9'
PY
mkdir -p "$tmp/objects/releases/rock-5b-plus/2026.9.9"
printf orphan >"$tmp/objects/releases/rock-5b-plus/2026.9.9/index.json"
output="$(STUB_PAGE_SIZE=3 publisher prune --board rock-5b-plus --channel-family --dry-run)"
[[ "$output" == *'2026.10.2'* && "$output" != *'2026.10.1/'* && "$output" != *'2026.9.9/'* ]] && ok 'prune plan: newest plus references and unmarked' || bad 'prune plan not 3 newest + referenced + unmarked'
if STUB_PAGE_SIZE=3 STUB_NO_NEXT=1 publisher prune --board rock-5b-plus --channel-family >"$tmp/incomplete.log" 2>&1; then
  bad 'incomplete inventory was accepted'
else
  ok 'incomplete inventory refused'
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
if publisher prune --board rock-5b-plus --channel-family >"$tmp/prune-tampered.log" 2>&1; then
  bad 'prune accepted tampered stable pointer and deleted its signed-only release'
else
  ok 'tampered stable pointer refused'
fi
assert grep -q 'signed channel verification failed: stable' "$tmp/prune-tampered.log"
assert test -f "$base/index.json"
assert test -f "$tmp/objects/releases/rock-5b-plus/2026.10.2/index.json"
cp "$tmp/stable-prune-valid.json" "$stable_pointer"
rm "$stable_pointer.sig"
if publisher prune --board rock-5b-plus --channel-family >"$tmp/prune-unsigned.log" 2>&1; then
  bad 'prune accepted an unsigned stable pointer'
else
  ok 'unsigned stable pointer refused'
fi
assert grep -q 'signed channel signature absent: stable' "$tmp/prune-unsigned.log"
assert test -f "$base/index.json"
assert test -f "$tmp/objects/releases/rock-5b-plus/2026.10.2/index.json"
cp "$tmp/stable-prune-valid.sig" "$stable_pointer.sig"
check publisher prune --board rock-5b-plus --channel-family >/dev/null
assert test -f "$base/index.json"
assert test -f "$tmp/objects/releases/rock-5b-plus/2026.9.9/index.json"
assert test ! -e "$tmp/objects/releases/rock-5b-plus/2026.10.2/index.json"
check publish 2026.11.1 drill >/dev/null
check publish 2026.11.2 drill >/dev/null
check publisher prune --board rock-5b-plus --channel-family >/dev/null
assert test ! -e "$tmp/objects/releases/rock-5b-plus/2026.11.1/index.json"
assert test -f "$tmp/objects/releases/rock-5b-plus/2026.11.2/index.json"
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
export MODE=refresh BOARDS=rock-5b-plus CHANNEL=beta VERSION='' CANDIDATE_RUN='' GH_TOKEN=stub EXPECT_KERNEL_VERSION='' EXPECT_DEB_SHA256=''
export RUNNER_TEMP="$tmp" GITHUB_REPOSITORY=CERALIVE/image-building-pipeline STUB_WORKFLOW_ARGV="$tmp/workflow-argv"
EXPECT_SERIAL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["serial"])' "$channel")"
EXPECT_ETAG="$(python3 -c 'import hashlib,json,sys;print(json.dumps(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest()))' "$channel")"
export EXPECT_SERIAL EXPECT_ETAG
workflow_refresh() { /bin/bash "$tmp/workflow-validate.sh" && /bin/bash "$tmp/workflow-publish.sh"; }
check workflow_refresh >"$tmp/workflow-success.log" 2>&1
check python3 - "$tmp/workflow-argv" "$EXPECT_SERIAL" "$EXPECT_ETAG" <<'PY'
import sys
assert open(sys.argv[1]).read().splitlines()==['refresh','--board','rock-5b-plus','--channel','beta',
    '--expect-serial',sys.argv[2],'--expect-etag',sys.argv[3]]
PY
rm "$tmp/workflow-argv"
saved_serial="$EXPECT_SERIAL" saved_etag="$EXPECT_ETAG"
if EXPECT_SERIAL='' workflow_refresh >"$tmp/workflow-missing.log" 2>&1; then bad 'workflow accepted missing serial'; else ok 'workflow refused missing serial'; fi
if EXPECT_ETAG='' workflow_refresh >"$tmp/workflow-missing-etag.log" 2>&1; then bad 'workflow accepted missing ETag'; else ok 'workflow refused missing ETag'; fi
if EXPECT_SERIAL="$((saved_serial-1))" workflow_refresh >"$tmp/workflow-stale-serial.log" 2>&1; then bad 'workflow accepted stale serial'; else ok 'workflow refused stale serial'; fi
if EXPECT_ETAG='"00000000000000000000000000000000"' workflow_refresh >"$tmp/workflow-stale-etag.log" 2>&1; then bad 'workflow accepted stale ETag'; else ok 'workflow refused stale ETag'; fi
if EXPECT_ETAG="${saved_etag//\"/}" workflow_refresh >"$tmp/workflow-unquoted.log" 2>&1; then bad 'workflow accepted unquoted ETag'; else ok 'workflow refused unquoted ETag'; fi
assert test ! -e "$tmp/workflow-argv"
export EXPECT_SERIAL="$saved_serial" EXPECT_ETAG="$saved_etag"
workflow_backfill() {
  ( export MODE=backfill-kernel VERSION=2026.10.100 EXPECT_SERIAL='' EXPECT_ETAG=''
    env "$@" /bin/bash "$tmp/workflow-validate.sh" && env "$@" /bin/bash "$tmp/workflow-publish.sh" )
}
wf_sha="$(printf 'workflow-kernel-deb' | sha256sum | cut -d' ' -f1)"
check workflow_backfill BOARDS=rock-5b-plus EXPECT_KERNEL_VERSION=7.2.0-ceralive1 EXPECT_DEB_SHA256="$wf_sha" >"$tmp/workflow-backfill.log" 2>&1
check python3 - "$tmp/workflow-argv" "$wf_sha" <<'PY'
import sys
assert open(sys.argv[1]).read().splitlines()==['backfill-kernel','--board','rock-5b-plus','--version','2026.10.100',
    '--expect-kernel-version','7.2.0-ceralive1','--expect-deb-sha256',sys.argv[2]]
PY
rm "$tmp/workflow-argv"
if workflow_backfill BOARDS=rock-5b-plus EXPECT_KERNEL_VERSION='' EXPECT_DEB_SHA256="$wf_sha" >"$tmp/workflow-backfill-nokernel.log" 2>&1; then bad 'workflow accepted backfill without an attested kernel version'
else ok 'workflow refused backfill without an attested kernel version'; fi
if workflow_backfill BOARDS=rock-5b-plus EXPECT_KERNEL_VERSION=7.2.0-ceralive1 EXPECT_DEB_SHA256='' >"$tmp/workflow-backfill-nosha.log" 2>&1; then bad 'workflow accepted backfill without an attested digest'
else ok 'workflow refused backfill without an attested digest'; fi
if workflow_backfill BOARDS=rock-5b-plus,orange-pi-5-plus EXPECT_KERNEL_VERSION=7.2.0-ceralive1 EXPECT_DEB_SHA256="$wf_sha" >"$tmp/workflow-backfill-boards.log" 2>&1; then bad 'workflow accepted backfill for several boards'
else ok 'workflow refused backfill for several boards'; fi
if ( export MODE=refresh EXPECT_KERNEL_VERSION=7.2.0-ceralive1 EXPECT_DEB_SHA256="$wf_sha"; /bin/bash "$tmp/workflow-validate.sh" ) >"$tmp/workflow-attest-misuse.log" 2>&1; then bad 'workflow accepted kernel attestation outside backfill-kernel'
else ok 'workflow refused kernel attestation outside backfill-kernel'; fi
assert test ! -e "$tmp/workflow-argv"
OTA_MANIFEST_SIGNER_TAR_B64="$(tar -czf - -C "$tmp/signer" leaf.key leaf.pem intermediate-ca.pem root-ca.pem | base64 -w0)"
export OTA_MANIFEST_SIGNER_TAR_B64
MODE=prune check /bin/bash "$tmp/workflow-signer.sh"
assert cmp "$tmp/signer/root-ca.pem" "$RUNNER_TEMP/ota-manifest-signer/root-ca.pem"
unset OTA_MANIFEST_SIGNER_TAR_B64

# Candidate identity is independent of newer manifest pins in the dispatch checkout.
kernel_test_repo "$tmp/dispatch"
kernel_test_version "$tmp/dispatch" 7.2.0-ceralive2
PUBLISH_RELEASE_SCRIPT="$tmp/dispatch/ci/publish-release.sh" check publish 2027.1.1 drill >"$tmp/stale-checkout.log"
check jq -e '.kernel.version == "7.2.0-ceralive1"' "$tmp/objects/releases/rock-5b-plus/2027.1.1/kernel.json"
cp "$tmp/lock.json" "$tmp/lock.good"
jq '.packages[0].sha256 = ("f"*64)' "$tmp/lock.good" >"$tmp/lock.json"
if publish 2027.1.2 drill >"$tmp/kernel-digest.log" 2>&1; then bad 'candidate kernel differs from released bytes'
else ok 'candidate kernel digest mismatch refused'; fi
assert grep -q 'candidate kernel digest differs from released artifact' "$tmp/kernel-digest.log"
assert test ! -e "$tmp/objects/releases/rock-5b-plus/2027.1.2"
cp "$tmp/lock.good" "$tmp/lock.json"
kernel_test_artifact "$CERALIVE_KERNEL_HISTORY_DIR/7.2.0-ceralive2" 7.2.0-ceralive2 "$repo"
if publish 2027.1.3 drill >"$tmp/kernel-publish-floor.log" 2>&1; then bad 'publish accepted OS below kernel floor'
else ok 'publish below newly released kernel floor refused'; fi
assert grep -q os_kernel_below_floor "$tmp/kernel-publish-floor.log"
assert test ! -e "$tmp/objects/releases/rock-5b-plus/2027.1.3"
if publisher promote --board rock-5b-plus --version 2026.10.5 --to stable >"$tmp/kernel-promote-floor.log" 2>&1; then
  bad 'promote accepted OS below a newer released kernel'
else ok 'promote below newly released kernel floor refused'; fi
assert grep -q os_kernel_below_floor "$tmp/kernel-promote-floor.log"
assert test ! -e "$tmp/objects/releases/rock-5b-plus/2026.10.5/channels/stable"
# Legacy-attested kernel sidecar backfill for the pre-sidecar OS releases.
legacy="$tmp/objects/releases/rock-5b-plus/2026.10.100"
legacy_sha="$(printf 'legacy-kernel-deb' | sha256sum | cut -d' ' -f1)"
other_sha="$(printf 'other-kernel-deb' | sha256sum | cut -d' ' -f1)"
legacy_lock() {
  printf '{"schema":1,"packages":[{"name":"linux-image-7.2.0-ceralive-rk3588","version":"7.2.0-ceralive1","arch":"arm64","origin":"%s","sha256":"%s"}]}\n' "$1" "$legacy_sha" >"$legacy/packages.lock.json"
  ( cd "$legacy" && sha256sum packages.lock.json >SHA256SUMS )
}
mkdir -p "$legacy"
legacy_lock source-built
backfill() {
  local board="$1" os="$2" kv="$3" sha="$4"; shift 4
  ( export OTA_MANIFEST_SIGNER_DIR="$tmp/signer"
    publisher backfill-kernel --board "$board" --version "$os" --expect-kernel-version "$kv" --expect-deb-sha256 "$sha" "$@" )
}
if backfill rock-5b-plus 2026.10.100 7.2.0-ceralive1 "$other_sha" >"$tmp/backfill-digest.log" 2>&1; then bad 'backfill accepted a digest the owner did not attest'
else ok 'backfill refuses an unattested kernel digest'; fi
assert grep -q 'owner-attested version and digest' "$tmp/backfill-digest.log"
if backfill rock-5b-plus 2026.10.100 7.2.0-ceralive2 "$legacy_sha" >"$tmp/backfill-version.log" 2>&1; then bad 'backfill accepted an unattested kernel version'
else ok 'backfill refuses an unattested kernel version'; fi
assert grep -q 'owner-attested version and digest' "$tmp/backfill-version.log"
unlisted="$tmp/objects/releases/rock-5b-plus/2026.10.101"
mkdir -p "$unlisted"
cp -- "$legacy/packages.lock.json" "$legacy/SHA256SUMS" "$unlisted/"
if backfill rock-5b-plus 2026.10.101 7.2.0-ceralive1 "$legacy_sha" >"$tmp/backfill-scope.log" 2>&1; then bad 'backfill accepted a release outside the allowlist'
else ok 'backfill refuses an otherwise valid release outside the pre-sidecar allowlist'; fi
assert grep -q 'covers only the named pre-sidecar releases' "$tmp/backfill-scope.log"
assert test ! -e "$unlisted/kernel.json"
assert test ! -e "$unlisted/kernel.json.sig"
legacy_lock ceralive-kernel
if backfill rock-5b-plus 2026.10.100 7.2.0-ceralive1 "$legacy_sha" >"$tmp/backfill-origin.log" 2>&1; then bad 'backfill accepted an APT-origin kernel'
else ok 'backfill refuses an APT-origin kernel (normal path only)'; fi
assert grep -q 'only source-built arm64 legacy kernels' "$tmp/backfill-origin.log"
legacy_lock source-built
printf ' ' >>"$legacy/packages.lock.json"
if backfill rock-5b-plus 2026.10.100 7.2.0-ceralive1 "$legacy_sha" >"$tmp/backfill-sums.log" 2>&1; then bad 'backfill accepted a lock that differs from SHA256SUMS'
else ok 'backfill refuses a package lock that differs from the release checksums'; fi
assert grep -q 'does not match the release checksum list' "$tmp/backfill-sums.log"
legacy_lock source-built
assert test ! -e "$legacy/kernel.json"
check backfill rock-5b-plus 2026.10.100 7.2.0-ceralive1 "$legacy_sha" --dry-run
assert test ! -e "$legacy/kernel.json"
assert test ! -e "$legacy/kernel.json.sig"
check backfill rock-5b-plus 2026.10.100 7.2.0-ceralive1 "$legacy_sha"
check python3 - "$legacy/kernel.json" "$legacy_sha" <<'PY'
import json,sys
assert json.load(open(sys.argv[1])) == {'schema':1,'board':'rock-5b-plus','os_version':'2026.10.100',
    'kernel':{'package':'linux-image-7.2.0-ceralive-rk3588','version':'7.2.0-ceralive1','deb_sha256':sys.argv[2]}}
PY
check openssl cms -verify -binary -inform DER -in "$legacy/kernel.json.sig" \
  -content "$legacy/kernel.json" -CAfile "$tmp/signer/root-ca.pem" -purpose any -out /dev/null >/dev/null 2>&1
if backfill rock-5b-plus 2026.10.100 7.2.0-ceralive1 "$legacy_sha" >"$tmp/backfill-again.log" 2>&1; then bad 'backfill overwrote a published sidecar'
else ok 'backfill refuses to touch an already published sidecar'; fi
assert grep -q 'kernel sidecar already published' "$tmp/backfill-again.log"
# An interrupted run leaves one half; a retry may only complete it with the exact attested bytes.
cp -- "$legacy/kernel.json" "$tmp/kernel.good.json"
cms_ok() { openssl cms -verify -binary -inform DER -in "$legacy/kernel.json.sig" -content "$legacy/kernel.json" -CAfile "$tmp/signer/root-ca.pem" -purpose any -out /dev/null >/dev/null 2>&1; }
rm -f "$legacy/kernel.json.sig"
check backfill rock-5b-plus 2026.10.100 7.2.0-ceralive1 "$legacy_sha"
assert cmp -s "$legacy/kernel.json" "$tmp/kernel.good.json"
check cms_ok
cp -- "$legacy/kernel.json.sig" "$tmp/kernel.good.sig"
rm -f "$legacy/kernel.json"
check backfill rock-5b-plus 2026.10.100 7.2.0-ceralive1 "$legacy_sha"
assert cmp -s "$legacy/kernel.json" "$tmp/kernel.good.json"
assert cmp -s "$legacy/kernel.json.sig" "$tmp/kernel.good.sig"
check cms_ok
printf '{}\n' >"$legacy/kernel.json"; rm -f "$legacy/kernel.json.sig"
if backfill rock-5b-plus 2026.10.100 7.2.0-ceralive1 "$legacy_sha" >"$tmp/backfill-half-json.log" 2>&1; then bad 'backfill completed a half whose JSON differs from the attestation'
else ok 'backfill refuses a half-published sidecar that differs from the attestation'; fi
assert grep -q 'differs from the attested identity' "$tmp/backfill-half-json.log"
assert test ! -e "$legacy/kernel.json.sig"
rm -f "$legacy/kernel.json"; printf 'not-a-signature' >"$legacy/kernel.json.sig"
if backfill rock-5b-plus 2026.10.100 7.2.0-ceralive1 "$legacy_sha" >"$tmp/backfill-half-sig.log" 2>&1; then bad 'backfill completed a half whose signature does not verify'
else ok 'backfill refuses a half-published signature that does not verify'; fi
assert grep -q 'does not verify' "$tmp/backfill-half-sig.log"
assert test ! -e "$legacy/kernel.json"
if [[ -n "${PUBLISH_TEST_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$PUBLISH_TEST_EVIDENCE_DIR"
  cp "$tmp/serial-refuse.txt" "$PUBLISH_TEST_EVIDENCE_DIR/serial-refuse.txt"
  cp "$tmp/stale-checkout.log" "$tmp/kernel-digest.log" "$tmp/kernel-publish-floor.log" \
    "$tmp/kernel-promote-floor.log" "$PUBLISH_TEST_EVIDENCE_DIR/"
  cp "$tmp/objects/releases/rock-5b-plus/2027.1.1/kernel.json" \
    "$tmp/objects/releases/rock-5b-plus/2027.1.1/kernel.json.sig" \
    "$tmp/signer/root-ca.pem" "$tmp/signer/leaf.pem" "$PUBLISH_TEST_EVIDENCE_DIR/"
fi
trap - ERR
[[ "$FAIL" -eq 0 ]]
