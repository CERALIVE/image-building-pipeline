#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
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
openssl req -newkey rsa:2048 -nodes -keyout "$tmp/leaf.key" -out "$tmp/leaf.csr" \
  -subj '/CN=CeraLive OTA Manifest Signer' >/dev/null 2>&1
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n' >"$tmp/leaf.ext"
openssl x509 -req -in "$tmp/leaf.csr" -CA "$tmp/root.pem" -CAkey "$tmp/root.key" \
  -CAcreateserial -days 1 -extfile "$tmp/leaf.ext" -out "$tmp/leaf.pem" >/dev/null 2>&1
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
            if path.name.endswith('part0001') and (root/'fail').exists():
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
            if path.name.endswith('part0001') and (root/'corrupt').exists():
                (root/'corrupt').unlink()
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
sign() { openssl cms -sign -binary -in "$channel" -signer "$tmp/leaf.pem" -inkey "$tmp/leaf.key" -outform DER -out "$channel.sig" >/dev/null; }
sign
run() { bash "$repo/tools/flash-download.sh" --board rock-5b-plus --out "$tmp/out" --jobs 2 --keyring "$tmp/root.pem"; }
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
if bash "$repo/tools/flash-download.sh" --board rock-5b-plus --out "$tmp/badout" --jobs 2 --keyring "$tmp/root.pem" >"$tmp/mismatch.log" 2>&1; then
  printf 'FAIL: full-hash mismatch accepted\n' >&2; exit 1
fi
grep -q 'full flash SHA-256 mismatch' "$tmp/mismatch.log"
[[ ! -f "$tmp/badout/rock-5b-plus/2026.10.1/flash.raw.xz" ]] || exit 1
printf 'PASS: final full-hash mismatch refused (valid per-part hashes)\n'

python3 - "$repo/tools/flash-download.sh" "$tmp/no-full-check.sh" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]).read_text()
old='sha_ok "$flash.partial" "$flash_size" "$flash_sha" || die \'full flash SHA-256 mismatch\''
assert p.count(old)==1
pathlib.Path(sys.argv[2]).write_text(p.replace(old, ':'))
PY
mkdir -p "$tmp/mutantout"
bash "$tmp/no-full-check.sh" --board rock-5b-plus --out "$tmp/mutantout" --jobs 2 --keyring "$tmp/root.pem" >"$tmp/mutant.log" 2>&1
printf 'PASS: removing full SHA guard makes mismatch fixture wrongly succeed (non-vacuity)\n'

python3 - "$release/index.json" "$release/SHA256SUMS" <<'PY'
import hashlib,json,pathlib,sys
p,s=map(pathlib.Path,sys.argv[1:]);i=json.loads(p.read_text());i['files']['flash.raw.xz']['parts'][1]['name']='../../outside';p.write_text(json.dumps(i))
s.write_text('\n'.join((hashlib.sha256(p.read_bytes()).hexdigest()+'  index.json') if l.endswith('  index.json') else l for l in s.read_text().splitlines())+'\n')
PY
if bash "$repo/tools/flash-download.sh" --board rock-5b-plus --out "$tmp/badout" --keyring "$tmp/root.pem" >"$tmp/traversal.log" 2>&1; then
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
bash "$repo/tools/flash-download.sh" --board rock-5b-plus --out "$tmp/rawout" --keyring "$tmp/root.pem" --decompress >"$tmp/raw.log" 2>&1
cmp "$tmp/raw-source" "$tmp/rawout/rock-5b-plus/2026.10.1/flash.raw"
printf 'PASS: optional xz extraction verifies raw SHA-256\n'
python3 - "$channel" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);m=json.loads(p.read_text());m['flash']['raw_sha256']='0'*64;p.write_text(json.dumps(m))
PY
sign
mkdir -p "$tmp/wrongraw"
if bash "$repo/tools/flash-download.sh" --board rock-5b-plus --out "$tmp/wrongraw" --keyring "$tmp/root.pem" --decompress >"$tmp/wrongraw.log" 2>&1; then
  printf 'FAIL: wrong raw checksum accepted\n' >&2; exit 1
fi
grep -q 'raw SHA-256 mismatch' "$tmp/wrongraw.log"
[[ ! -e "$tmp/wrongraw/rock-5b-plus/2026.10.1/flash.raw" ]] || exit 1
printf 'PASS: raw hash mismatch refused\n'
