#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
downloader="${FLASH_DOWNLOAD_SCRIPT:-$repo/tools/flash-download.sh}"
tmp="$(mktemp -d -p "${TMPDIR:-/tmp}" flash-download.XXXXXXXX)"
server=''
cleanup() { [[ -z "$server" ]] || { kill "$server" 2>/dev/null || :; wait "$server" 2>/dev/null || :; }; rm -rf -- "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/site/channels/stable" "$tmp/site/releases/rock-5b-plus/2026.10.1" "$tmp/out"
release="$tmp/site/releases/rock-5b-plus/2026.10.1"
channel="$tmp/site/channels/stable/rock-5b-plus.json"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/root.key" -out "$tmp/root.pem" -days 1 \
  -subj '/CN=Fixture Root' -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
make_intermediate() {
  local name="$1" subject="$2" ca="${3:-$tmp/root}"
  openssl req -newkey rsa:2048 -nodes -keyout "$tmp/$name.key" -out "$tmp/$name.csr" \
    -subj "$subject" >/dev/null 2>&1
  printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' >"$tmp/$name.ext"
  openssl x509 -req -in "$tmp/$name.csr" -CA "$ca.pem" -CAkey "$ca.key" \
    -CAcreateserial -days 1 -extfile "$tmp/$name.ext" -out "$tmp/$name.pem" >/dev/null 2>&1
}
make_intermediate intermediate '/O=CeraLive/CN=CeraLive RAUC Intermediate CA'
make_intermediate bench '/O=CeraLive/CN=CeraLive RAUC Bench Intermediate CA'
make_intermediate alternate '/O=CeraLive/CN=CeraLive Other Intermediate CA'
make_intermediate near '/OU=Extra/O=CeraLive/CN=CeraLive RAUC Intermediate CA'
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/foreign-root.key" -out "$tmp/foreign-root.pem" -days 1 \
  -subj '/CN=Foreign Root' -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
make_intermediate foreign '/O=CeraLive/CN=CeraLive RAUC Intermediate CA' "$tmp/foreign-root"
openssl req -newkey rsa:2048 -nodes -keyout "$tmp/leaf.key" -out "$tmp/leaf.csr" \
  -subj '/CN=CeraLive OTA Manifest Signer' >/dev/null 2>&1
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n' >"$tmp/leaf.ext"
issue_leaf() {
  local name="$1" ca="$2"
  openssl x509 -req -in "$tmp/leaf.csr" -CA "$tmp/$ca.pem" -CAkey "$tmp/$ca.key" \
    -CAcreateserial -days 1 -extfile "$tmp/leaf.ext" -out "$tmp/$name.pem" >/dev/null 2>&1
}
issue_leaf leaf intermediate
issue_leaf bench-leaf bench
issue_leaf root-leaf root
issue_leaf alternate-leaf alternate
issue_leaf near-leaf near
issue_leaf foreign-leaf foreign
printf '1000\n' >"$tmp/serial"
: >"$tmp/cert-index"
printf 'unique_subject = no\n' >"$tmp/cert-index.attr"
cat >"$tmp/dates.cnf" <<EOF
[ca]
default_ca = fixture
[fixture]
database = $tmp/cert-index
new_certs_dir = $tmp
certificate = $tmp/intermediate.pem
private_key = $tmp/intermediate.key
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
openssl ca -batch -config "$tmp/dates.cnf" -startdate 20250101000000Z -enddate 20250102000000Z \
  -in "$tmp/leaf.csr" -out "$tmp/expired-leaf.pem" >/dev/null 2>&1
openssl req -new -key "$tmp/leaf.key" -subj '/O=CeraLive/CN=CeraLive OTA Manifest Signer' \
  -out "$tmp/future.csr" >/dev/null 2>&1
openssl ca -batch -config "$tmp/dates.cnf" -startdate 20350101000000Z -enddate 20360101000000Z \
  -in "$tmp/future.csr" -out "$tmp/future-leaf.pem" >/dev/null 2>&1
python3 - "$release" "$channel" <<'PY'
import hashlib, json, pathlib, sys
root, channel = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()
bundle = root/'bundle.raucb.part0000'
bundle.write_bytes(b'bundle')
(root/'bundle.raucb').write_bytes(bundle.read_bytes())
part0 = root/'flash.raw.xz.part0000'
with part0.open('wb') as f: f.truncate(268435456)
part1 = root/'flash.raw.xz.part0001'
part1.write_bytes(b'flash final part')
flash = root/'flash.raw.xz'
with flash.open('wb') as f:
    for part in (part0, part1):
        with part.open('rb') as source:
            for block in iter(lambda: source.read(1024 * 1024), b''): f.write(block)
files = {}
for name, parts in [('bundle.raucb', [bundle]), ('flash.raw.xz', [part0, part1])]:
    files[name] = {'size': sum(p.stat().st_size for p in parts), 'sha256': digest(flash) if name == 'flash.raw.xz' else digest(bundle),
                   'chunk_size': 268435456, 'parts': [{'name': p.name, 'size': p.stat().st_size, 'sha256': digest(p)} for p in parts]}
(root/'index.json').write_text(json.dumps({'schema': 1, 'files': files}))
(root/'packages.lock.json').write_text('{}')
(root/'SHA256SUMS').write_text(''.join(f'{digest(root/name)}  {name}\n' for name in ('bundle.raucb', 'flash.raw.xz', 'index.json', 'packages.lock.json')))
channel.write_text(json.dumps({'schema': 1, 'board': 'rock-5b-plus', 'compatible': 'ceralive-rock-5b-plus',
    'channel': 'stable', 'version': '2026.10.1', 'serial': 1,
    'bundle': {'url': 'BASE/releases/rock-5b-plus/2026.10.1/bundle.raucb', 'size': files['bundle.raucb']['size'], 'sha256': files['bundle.raucb']['sha256']},
    'flash': {'url': 'BASE/releases/rock-5b-plus/2026.10.1/flash.raw.xz', 'size': files['flash.raw.xz']['size'],
              'sha256': files['flash.raw.xz']['sha256'], 'raw_sha256': digest(flash)}}))
PY
cat >"$tmp/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os, threading, time

root = Path(os.environ['FIXTURE_SITE'])
lock = threading.Lock()
active = 0
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        global active
        path = root/self.path.lstrip('/')
        with lock:
            active += 1
            with (root/'requests.log').open('a') as log: log.write(f'{self.path} {self.headers.get("Range", "-")}\n')
            peak = max(active, int((root/'max-active').read_text() or '0'))
            (root/'max-active').write_text(str(peak))
        try:
            if (path.name.endswith('part0001') and (root/'fail').exists()) or (path.name.endswith('part0000') and (root/'fail-first').exists()):
                time.sleep(1)
                self.send_error(503); return
            if not path.is_file(): self.send_error(404); return
            start = 0
            if self.headers.get('Range'):
                start = int(self.headers['Range'].removeprefix('bytes=').split('-')[0])
                if start >= path.stat().st_size: self.send_error(416); return
            length = path.stat().st_size - start
            self.send_response(206 if start else 200)
            self.send_header('Content-Length', str(length))
            if start: self.send_header('Content-Range', f'bytes {start}-{path.stat().st_size-1}/{path.stat().st_size}')
            self.end_headers()
            if path.name.endswith('part0001') and ((root/'corrupt').exists() or (root/'corrupt-always').exists()):
                (root/'corrupt').unlink(missing_ok=True)
                self.wfile.write(b'X'*length)
                return
            if path.name.endswith('part0001'): time.sleep(0.2)
            with path.open('rb') as f:
                f.seek(start)
                while data := f.read(1024*1024): self.wfile.write(data)
        finally:
            with lock: active -= 1

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Path(os.environ['FIXTURE_PORT']).write_text(str(server.server_port))
server.serve_forever()
PY
printf '0' >"$tmp/site/max-active"
FIXTURE_SITE="$tmp/site" FIXTURE_PORT="$tmp/port" python3 "$tmp/server.py" & server=$!
for ((i=0; i<100; i++)); do [[ ! -s "$tmp/port" ]] || break; sleep 0.05; done
[[ -s "$tmp/port" ]] || { printf 'FAIL: local server failed to start\n' >&2; exit 1; }
CERALIVE_FLASH_BASE_URL="http://127.0.0.1:$(<"$tmp/port")"
export CERALIVE_FLASH_BASE_URL
python3 - "$channel" "$CERALIVE_FLASH_BASE_URL" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('BASE',sys.argv[2]))
PY
sign() {
  local cert="${1:-$tmp/leaf.pem}" chain="${2-$tmp/intermediate.pem}"
  local args=()
  [[ -z "$chain" ]] || args=(-certfile "$chain")
  openssl cms -sign -binary -in "$channel" -signer "$cert" -inkey "$tmp/leaf.key" \
    "${args[@]}" -outform DER -out "$channel.sig" >/dev/null
}
sign
run() { bash "$downloader" --board rock-5b-plus --out "$tmp/out" --jobs 2 --keyring "$tmp/root.pem"; }
orange_channel="$tmp/site/channels/stable/orange-pi-5-plus.json"
mkdir -p "$tmp/site/releases/orange-pi-5-plus/2026.10.1"
cp -a --reflink=auto "$release/." "$tmp/site/releases/orange-pi-5-plus/2026.10.1/"
python3 - "$channel" "$orange_channel" <<'PY'
import json, pathlib, sys
source, target = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(source.read_text())
manifest['board'] = 'orange-pi-5-plus'
manifest['compatible'] = 'ceralive-orangepi5-plus'
for entry in ('bundle', 'flash'):
    manifest[entry]['url'] = manifest[entry]['url'].replace('/rock-5b-plus/', '/orange-pi-5-plus/')
target.write_text(json.dumps(manifest))
PY
openssl cms -sign -binary -in "$orange_channel" -signer "$tmp/leaf.pem" -inkey "$tmp/leaf.key" \
  -certfile "$tmp/intermediate.pem" -outform DER -out "$orange_channel.sig" >/dev/null
if ! bash "$downloader" --board orange-pi-5-plus --out "$tmp/orangeout" --keyring "$tmp/root.pem" >"$tmp/orange.log" 2>&1; then
  printf 'FAIL: correctly signed Orange manifest refused\n' >&2; exit 1
fi
[[ -f "$tmp/orangeout/orange-pi-5-plus/2026.10.1/flash.raw.xz" ]] || exit 1
cp "$channel" "$tmp/rock-channel.json"
cp "$channel.sig" "$tmp/rock-channel.sig"
cp "$orange_channel" "$tmp/orange-channel.json"
cp "$orange_channel.sig" "$tmp/orange-channel.sig"
cp "$orange_channel" "$channel"
cp "$orange_channel.sig" "$channel.sig"
if run >"$tmp/orange-for-rock.log" 2>&1; then printf 'FAIL: Orange manifest accepted for Rock\n' >&2; exit 1; fi
cp "$tmp/rock-channel.json" "$channel"
cp "$tmp/rock-channel.sig" "$channel.sig"
cp "$tmp/rock-channel.json" "$orange_channel"
cp "$tmp/rock-channel.sig" "$orange_channel.sig"
if bash "$downloader" --board orange-pi-5-plus --out "$tmp/orangeout" --keyring "$tmp/root.pem" >"$tmp/rock-for-orange.log" 2>&1; then
  printf 'FAIL: Rock manifest accepted for Orange\n' >&2; exit 1
fi
cp "$tmp/orange-channel.json" "$orange_channel"
cp "$tmp/orange-channel.sig" "$orange_channel.sig"
printf 'PASS: signed Orange manifest and both cross-board refusals\n'
mkdir -p "$tmp/tools"
ln -s "$repo/lib" "$tmp/lib"
python3 - "$downloader" "$tmp/tools/no-compatible.sh" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
check="assert m['compatible'] == compatible"
assert text.count(check)==1
pathlib.Path(sys.argv[2]).write_text(text.replace(check,'pass'))
PY
for pair in "rock-5b-plus:$channel:ceralive-rock-5b-plus-extra" \
            "orange-pi-5-plus:$orange_channel:ceralive-orange-pi-5-plus"; do
  IFS=: read -r selected target wrong <<<"$pair"
  cp "$target" "$tmp/$selected-good.json"
  cp "$target.sig" "$tmp/$selected-good.sig"
  python3 - "$target" "$wrong" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);m=json.loads(p.read_text());m['compatible']=sys.argv[2];p.write_text(json.dumps(m))
PY
  openssl cms -sign -binary -in "$target" -signer "$tmp/leaf.pem" -inkey "$tmp/leaf.key" \
    -certfile "$tmp/intermediate.pem" -outform DER -out "$target.sig" >/dev/null
  if bash "$downloader" --board "$selected" --out "$tmp/out" --keyring "$tmp/root.pem" >"$tmp/$selected-compatible.log" 2>&1; then
    printf 'FAIL: same-board wrong compatible accepted: %s\n' "$selected" >&2; exit 1
  fi
  if ! bash "$tmp/tools/no-compatible.sh" --board "$selected" --out "$tmp/compatible-mutant-out" --keyring "$tmp/root.pem" >"$tmp/$selected-compatible-mutant.log" 2>&1; then
    printf 'FAIL: compatible mutation did not accept %s\n' "$selected" >&2
    cat "$tmp/$selected-compatible-mutant.log" >&2
    exit 1
  fi
  cp "$tmp/$selected-good.json" "$target"
  cp "$tmp/$selected-good.sig" "$target.sig"
done
printf 'PASS: same-board wrong compatible refused for both boards; removing comparison accepts both\n'
sign "$tmp/bench-leaf.pem" "$tmp/bench.pem"
bash "$downloader" --board rock-5b-plus --out "$tmp/issuer-accepted-out" --keyring "$tmp/root.pem" >"$tmp/bench-issuer.log" 2>&1
sign
for variant in root alternate near; do
  chain="$tmp/$variant.pem"
  [[ "$variant" != root ]] || chain=''
  sign "$tmp/$variant-leaf.pem" "$chain"
  if run >"$tmp/$variant-issuer.log" 2>&1; then
    printf 'FAIL: %s-issued manifest signer accepted\n' "$variant" >&2; exit 1
  fi
  issuer="$(openssl x509 -in "$tmp/$variant-leaf.pem" -noout -issuer -nameopt RFC2253)"
  grep -F -- "${issuer#issuer=}" "$tmp/$variant-issuer.log" >/dev/null || {
    printf 'FAIL: refused %s issuer was not diagnosed\n' "$variant" >&2; exit 1;
  }
done
for variant in foreign expired future; do
  chain="$tmp/intermediate.pem"
  [[ "$variant" != foreign ]] || chain="$tmp/foreign.pem"
  sign "$tmp/$variant-leaf.pem" "$chain"
  if run >"$tmp/$variant-invalid-chain.log" 2>&1; then
    printf 'FAIL: %s manifest signer accepted against root keyring\n' "$variant" >&2; exit 1
  fi
  grep -F 'channel CMS verification failed' "$tmp/$variant-invalid-chain.log" >/dev/null
done
python3 - "$downloader" "$tmp/tools/no-issuer.sh" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
check='manifest_signer_issuer_allowed "$issuer" || die "channel signer issuer refused: $issuer"'
assert text.count(check)==1
pathlib.Path(sys.argv[2]).write_text(text.replace(check, ':'))
PY
for variant in root alternate; do
  chain="$tmp/$variant.pem"
  [[ "$variant" != root ]] || chain=''
  sign "$tmp/$variant-leaf.pem" "$chain"
  bash "$tmp/tools/no-issuer.sh" --board rock-5b-plus --out "$tmp/issuer-mutant-out" --keyring "$tmp/root.pem" >"$tmp/$variant-issuer-mutant.log" 2>&1 || {
    printf 'FAIL: removing issuer check did not accept %s-issued signer\n' "$variant" >&2; exit 1;
  }
done
sign
printf 'PASS: production and bench issuers accepted; root-direct, alternate and near-miss refused; foreign-root/expired/future chains refused; issuer mutation accepts root/alternate\n'
openssl req -newkey rsa:2048 -nodes -keyout "$tmp/bundle.key" -out "$tmp/bundle.csr" \
  -subj '/CN=CeraLive OTA Manifest Signer' >/dev/null 2>&1
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning,emailProtection\n' >"$tmp/bundle.ext"
openssl x509 -req -in "$tmp/bundle.csr" -CA "$tmp/root.pem" -CAkey "$tmp/root.key" \
  -CAcreateserial -days 1 -extfile "$tmp/bundle.ext" -out "$tmp/bundle.pem" >/dev/null 2>&1
openssl cms -sign -binary -in "$channel" -signer "$tmp/bundle.pem" -inkey "$tmp/bundle.key" -outform DER -out "$channel.sig" >/dev/null
if run >"$tmp/bundle-signer.log" 2>&1; then printf 'FAIL: dual-EKU bundle leaf accepted as manifest signer\n' >&2; exit 1; fi
openssl req -newkey rsa:2048 -nodes -keyout "$tmp/foreign.key" -out "$tmp/foreign.csr" \
  -subj '/CN=Other Signer' >/dev/null 2>&1
openssl x509 -req -in "$tmp/foreign.csr" -CA "$tmp/root.pem" -CAkey "$tmp/root.key" \
  -CAcreateserial -days 1 -extfile "$tmp/leaf.ext" -out "$tmp/foreign.pem" >/dev/null 2>&1
openssl cms -sign -binary -in "$channel" -signer "$tmp/foreign.pem" -inkey "$tmp/foreign.key" -outform DER -out "$channel.sig" >/dev/null
if run >"$tmp/foreign-signer.log" 2>&1; then printf 'FAIL: wrong-CN code-signing leaf accepted\n' >&2; exit 1; fi
sign
printf 'PASS: dedicated signer accepted; dual-EKU and wrong-CN signers refused\n'
printf '1' >"$tmp/site/fail"
if run >"$tmp/first.log" 2>&1; then printf 'FAIL: interrupted fetch accepted\n' >&2; exit 1; fi
part0="$tmp/out/rock-5b-plus/2026.10.1/flash.raw.xz.part0000"
[[ -f "$part0" ]] || { printf 'FAIL: first part was not saved for resume\n' >&2; exit 1; }
first_count="$(python3 - "$tmp/site/requests.log" <<'PY'
import sys
print(sum('part0000' in l for l in open(sys.argv[1])))
PY
)"
rm "$tmp/site/fail"
printf 'flash' >"$tmp/out/rock-5b-plus/2026.10.1/flash.raw.xz.part0001.partial"
printf '1' >"$tmp/site/corrupt"
run >"$tmp/second.log" 2>&1
python3 - "$tmp/site/requests.log" "$first_count" "$tmp/site/max-active" <<'PY'
import sys
lines=open(sys.argv[1]).readlines()
assert sum('part0000' in l for l in lines)==int(sys.argv[2]), 'verified first part downloaded again'
assert sum('part0001' in l for l in lines)>=3, 'corrupt part not retried'
assert any('part0001 bytes=5-' in l for l in lines), 'partial part not resumed by range'
assert int(open(sys.argv[3]).read())>=2, 'bounded parallel work did not overlap'
PY
[[ "$(sha256sum "$tmp/out/rock-5b-plus/2026.10.1/flash.raw.xz" | cut -d' ' -f1)" == "$(sha256sum "$release/flash.raw.xz" | cut -d' ' -f1)" ]] || exit 1
printf 'PASS: parallel fetch, interrupted-run reuse, corrupted part re-fetched\n'

final="$tmp/out/rock-5b-plus/2026.10.1/flash.raw.xz"
part1="$tmp/out/rock-5b-plus/2026.10.1/flash.raw.xz.part0001"
failure=0
printf 'corrupt assembled file\n' >"$final"
rm -- "$part1"
touch "$tmp/site/corrupt-always"
if run >"$tmp/corrupt-part.log" 2>&1; then printf 'FAIL: corrupt part accepted\n' >&2; exit 1; fi
[[ ! -e "$final" ]] || { printf 'FAIL: corrupt part left final image\n' >&2; failure=1; }
grep -q 'part download failed' "$tmp/corrupt-part.log"
rm -- "$tmp/site/corrupt-always"

printf 'corrupt assembled file\n' >"$final"
printf 'corrupt cached part\n' >"$part0"
touch "$tmp/site/fail-first"
if run >"$tmp/unavailable.log" 2>&1; then printf 'FAIL: unavailable part accepted\n' >&2; exit 1; fi
[[ ! -e "$final" ]] || { printf 'FAIL: unavailable part left final image\n' >&2; failure=1; }
grep -q 'part download failed' "$tmp/unavailable.log"
rm -- "$tmp/site/fail-first"
(( failure == 0 )) || exit 1
run >"$tmp/recovered.log" 2>&1
cmp -- "$release/flash.raw.xz" "$final"
printf 'PASS: corrupt part and unavailable origin remove stale final; recovery verifies exact image\n'

mkdir -p "$tmp/badout"
python3 - "$release/index.json" "$release/SHA256SUMS" "$channel" <<'PY'
import hashlib,json,pathlib,sys
i,s,m=map(pathlib.Path,sys.argv[1:]);index=json.loads(i.read_text());channel=json.loads(m.read_text())
wrong='0'*64
assert wrong != channel['flash']['sha256']
index['files']['flash.raw.xz']['sha256']=wrong
channel['flash']['sha256']=wrong
i.write_text(json.dumps(index));m.write_text(json.dumps(channel))
lines=s.read_text().splitlines()
s.write_text('\n'.join((hashlib.sha256(i.read_bytes()).hexdigest()+'  index.json') if l.endswith('  index.json') else (wrong+'  flash.raw.xz') if l.endswith('  flash.raw.xz') else l for l in lines)+'\n')
PY
sign
if bash "$downloader" --board rock-5b-plus --out "$tmp/badout" --jobs 2 --keyring "$tmp/root.pem" >"$tmp/mismatch.log" 2>&1; then
  printf 'FAIL: full-hash mismatch accepted\n' >&2; exit 1
fi
grep -q 'full flash SHA-256 mismatch' "$tmp/mismatch.log"
[[ ! -e "$tmp/badout/rock-5b-plus/2026.10.1/flash.raw.xz" ]] || exit 1
[[ -z "$(compgen -G "$tmp/badout/rock-5b-plus/2026.10.1/.flash.raw.xz.*")" ]] || exit 1
printf 'PASS: final full-hash mismatch refused (valid per-part hashes)\n'

python3 - "$downloader" "$tmp/tools/no-full-check.sh" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]).read_text()
old='sha_ok "$flash_tmp" "$flash_size" "$flash_sha" || die \'full flash SHA-256 mismatch\''
assert p.count(old)==1
pathlib.Path(sys.argv[2]).write_text(p.replace(old, ':'))
PY
mkdir -p "$tmp/mutantout"
bash "$tmp/tools/no-full-check.sh" --board rock-5b-plus --out "$tmp/mutantout" --jobs 2 --keyring "$tmp/root.pem" >"$tmp/mutant.log" 2>&1
printf 'PASS: removing full SHA guard makes mismatch fixture wrongly succeed (non-vacuity)\n'

python3 - "$release/index.json" "$release/SHA256SUMS" <<'PY'
import hashlib,json,pathlib,sys
p,s=map(pathlib.Path,sys.argv[1:]);i=json.loads(p.read_text());i['files']['flash.raw.xz']['parts'][1]['name']='../../outside';p.write_text(json.dumps(i))
s.write_text('\n'.join((hashlib.sha256(p.read_bytes()).hexdigest()+'  index.json') if l.endswith('  index.json') else l for l in s.read_text().splitlines())+'\n')
PY
if bash "$downloader" --board rock-5b-plus --out "$tmp/badout" --keyring "$tmp/root.pem" >"$tmp/traversal.log" 2>&1; then
  printf 'FAIL: traversal accepted\n' >&2; exit 1
fi
grep -q 'invalid release metadata' "$tmp/traversal.log"
[[ ! -e "$tmp/outside" ]] || exit 1
printf 'PASS: unsafe part metadata refused before download\n'

printf 'raw flash bytes\n' >"$tmp/raw-source"
xz -c "$tmp/raw-source" >"$release/flash.raw.xz.part0000"
python3 - "$release" "$channel" "$tmp/raw-source" <<'PY'
import hashlib,json,pathlib,sys
root,channel,raw=map(pathlib.Path,sys.argv[1:])
index=json.loads((root/'index.json').read_text());m=json.loads(channel.read_text())
part=root/'flash.raw.xz.part0000'
h=lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
index['files']['flash.raw.xz']={'size':part.stat().st_size,'sha256':h(part),'chunk_size':268435456,
    'parts':[{'name':part.name,'size':part.stat().st_size,'sha256':h(part)}]}
m['flash'].update(size=part.stat().st_size,sha256=h(part),raw_sha256=h(raw))
(root/'index.json').write_text(json.dumps(index));channel.write_text(json.dumps(m))
PY
cp "$release/flash.raw.xz.part0000" "$release/flash.raw.xz"
python3 - "$release" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]);h=lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
(root/'SHA256SUMS').write_text(''.join(f'{h(root/name)}  {name}\n' for name in ('bundle.raucb','flash.raw.xz','index.json','packages.lock.json')))
PY
sign
mkdir -p "$tmp/rawout"
bash "$downloader" --board rock-5b-plus --out "$tmp/rawout" --keyring "$tmp/root.pem" --decompress >"$tmp/raw.log" 2>&1
cmp "$tmp/raw-source" "$tmp/rawout/rock-5b-plus/2026.10.1/flash.raw"
printf 'PASS: optional xz extraction verifies raw SHA-256\n'
printf 'old unverified raw\n' >"$tmp/rawout/rock-5b-plus/2026.10.1/flash.raw"
mkdir -p "$tmp/failing-bin"
cat >"$tmp/failing-bin/xz" <<'SH'
#!/usr/bin/env bash
exit 42
SH
chmod 700 "$tmp/failing-bin/xz"
if PATH="$tmp/failing-bin:$PATH" bash "$downloader" --board rock-5b-plus --out "$tmp/rawout" --keyring "$tmp/root.pem" --decompress >"$tmp/extract-failed.log" 2>&1; then
  printf 'FAIL: failing extraction accepted\n' >&2; exit 1
fi
[[ ! -e "$tmp/rawout/rock-5b-plus/2026.10.1/flash.raw" ]] || {
  printf 'FAIL: old unverified raw survived failed extraction\n' >&2; exit 1;
}
printf 'PASS: failed extraction leaves no stale final raw\n'
python3 - "$channel" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);m=json.loads(p.read_text());m['flash']['raw_sha256']='0'*64;p.write_text(json.dumps(m))
PY
sign
mkdir -p "$tmp/wrongraw"
if bash "$downloader" --board rock-5b-plus --out "$tmp/wrongraw" --keyring "$tmp/root.pem" --decompress >"$tmp/wrongraw.log" 2>&1; then
  printf 'FAIL: wrong raw checksum accepted\n' >&2; exit 1
fi
grep -q 'raw SHA-256 mismatch' "$tmp/wrongraw.log"
[[ ! -e "$tmp/wrongraw/rock-5b-plus/2026.10.1/flash.raw" ]] || exit 1
printf 'PASS: raw hash mismatch refused\n'
