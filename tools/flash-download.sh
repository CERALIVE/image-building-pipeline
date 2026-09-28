#!/usr/bin/env bash
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  printf '%s\n' 'flash-download.sh --board B [--channel stable|beta|drill] [--out DIR] [--jobs 8] [--keyring ROOT.pem] [--decompress]'
}

board='' channel=stable out=images jobs=8 keyring='' decompress=0
while (($#)); do
  case "$1" in
    --board|--channel|--out|--jobs|--keyring)
      (($# >= 2)) || die "missing value for $1"
      case "$1" in
        --board) board="$2" ;; --channel) channel="$2" ;;
        --out) out="$2" ;; --jobs) jobs="$2" ;; --keyring) keyring="$2" ;;
      esac
      shift 2 ;;
    --decompress) decompress=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$board" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die 'invalid or missing board'
[[ "$channel" =~ ^(stable|beta|drill)$ ]] || die 'invalid channel'
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]] || (( ${#jobs} > 2 || jobs > 32 )); then die 'jobs must be 1..32'; fi
[[ -z "$keyring" || -f "$keyring" ]] || die 'keyring is not a file'
for tool in curl openssl python3 sha256sum stat xz; do command -v "$tool" >/dev/null || die "missing $tool"; done

# Only the test fixture may override the origin; never follow redirects or metadata URLs.
base="${CERALIVE_FLASH_BASE_URL:-https://images.ceralive.tv}"
if [[ "$base" != https://images.ceralive.tv ]]; then
  [[ "$base" =~ ^http://127\.0\.0\.1:[0-9]{1,5}$ ]] || die 'fixture origin must be loopback HTTP'
fi
proto=https; [[ "$base" == http:* ]] && proto=http
umask 077
[[ ! -L "$out" ]] || die 'output directory is a symlink'
mkdir -p -- "$out"
out="$(realpath -- "$out")"
tmp="$(mktemp -d -p "$out" .flash-download.XXXXXXXX)"
cleanup() {
  rm -rf -- "$tmp"
}
workers=()
trap cleanup EXIT

get() {
  local url="$1" dest="$2" expected="$3" status
  status="$(curl --silent --show-error --proto "=$proto" --noproxy '*' --connect-timeout 10 --max-time 600 \
    --output "$dest" --write-out '%{http_code}' "$url")" || return 1
  [[ "$status" == "$expected" ]] || { printf 'unexpected HTTP %s for %s (wanted %s)\n' "$status" "$url" "$expected" >&2; return 1; }
}
channel_url="$base/channels/$channel/$board.json"
get "$channel_url" "$tmp/channel.json" 200 || die 'channel manifest fetch failed'
if [[ -n "$keyring" ]]; then
  get "$channel_url.sig" "$tmp/channel.sig" 200 || die 'channel signature fetch failed'
  openssl cms -verify -binary -inform DER -in "$tmp/channel.sig" -content "$tmp/channel.json" \
    -CAfile "$keyring" -purpose any -signer "$tmp/channel-signer.pem" -out /dev/null >/dev/null 2>&1 || die 'channel CMS verification failed'
  eku="$(openssl x509 -in "$tmp/channel-signer.pem" -noout -ext extendedKeyUsage)"
  [[ "$eku" == *'Code Signing'* ]] || die 'channel signer must have Code Signing EKU'
else
  printf '%s\n' 'WARNING: unsigned verification skipped; sha256 only (no authenticated release identity)' >&2
fi

# The manifest selects the immutable version; never interpolate an unchecked version into a path.
version="$(python3 - "$tmp/channel.json" "$board" "$channel" "$base" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1]))
board, channel, base = sys.argv[2:]
assert m['schema'] == 1 and m['board'] == board and m['channel'] == channel
assert m['compatible'] == 'ceralive-' + board
v = m['version']
assert isinstance(v, str) and re.fullmatch(r'[0-9]{4}\.[0-9]+\.[0-9]+', v)
assert isinstance(m['serial'], int) and not isinstance(m['serial'], bool) and m['serial'] > 0
prefix = f'{base}/releases/{board}/{v}/'
for name, field in (('bundle.raucb', 'bundle'), ('flash.raw.xz', 'flash')):
    entry = m[field]
    assert entry['url'] == prefix + name
    assert type(entry['size']) is int and entry['size'] > 0
    assert re.fullmatch(r'[0-9a-f]{64}', entry['sha256'])
assert re.fullmatch(r'[0-9a-f]{64}', m['flash']['raw_sha256'])
print(v)
PY
)" || die 'invalid channel manifest'
release="$out/$board"
[[ ! -L "$release" ]] || die 'board output is a symlink'
mkdir -p -- "$release"
release="$release/$version"
[[ ! -L "$release" ]] || die 'version output is a symlink'
mkdir -p -- "$release"
prefix="$base/releases/$board/$version"
get "$prefix/index.json" "$tmp/index.json" 200 || die 'release index fetch failed'
get "$prefix/SHA256SUMS" "$tmp/SHA256SUMS" 200 || die 'release checksums fetch failed'

# Validate BOTH index entries before the first part is requested. The TSV is internal,
# with names restricted to the publisher's fixed basename + ordered numeric suffix.
python3 - "$tmp/index.json" "$tmp/channel.json" "$tmp/SHA256SUMS" >"$tmp/parts.tsv" <<'PY' || die 'invalid release metadata'
import json, re, sys
i, m = (json.load(open(p)) for p in sys.argv[1:3])
assert i['schema'] == 1 and set(i['files']) == {'bundle.raucb', 'flash.raw.xz'}
for name, field in (('bundle.raucb', 'bundle'), ('flash.raw.xz', 'flash')):
    entry = i['files'][name]
    assert entry['size'] == m[field]['size'] and entry['sha256'] == m[field]['sha256']
    assert type(entry['size']) is int and entry['size'] > 0
    assert re.fullmatch(r'[0-9a-f]{64}', entry['sha256'])
    assert entry['chunk_size'] == 268435456
    assert isinstance(entry['parts'], list) and entry['parts']
    total = 0
    seen = set()
    for n, part in enumerate(entry['parts']):
        pname = part['name']
        assert pname == f'{name}.part{n:04d}' and pname not in seen
        seen.add(pname)
        assert type(part['size']) is int and 0 < part['size'] <= entry['chunk_size']
        assert n == len(entry['parts']) - 1 or part['size'] == entry['chunk_size']
        assert re.fullmatch(r'[0-9a-f]{64}', part['sha256'])
        total += part['size']
        if field == 'flash':
            print(pname, part['size'], part['sha256'], sep='\t')
    assert total == entry['size']
lines = open(sys.argv[3]).read().splitlines()
assert len(lines) == 4
records = {}
for line in lines:
    match = re.fullmatch(r'([0-9a-f]{64})  (bundle\.raucb|flash\.raw\.xz|index\.json|packages\.lock\.json)', line)
    assert match and match[2] not in records
    records[match[2]] = match[1]
assert set(records) == {'bundle.raucb', 'flash.raw.xz', 'index.json', 'packages.lock.json'}
assert records['bundle.raucb'] == m['bundle']['sha256']
assert records['flash.raw.xz'] == m['flash']['sha256']
PY
expected_index="$(sha256sum "$tmp/index.json")"
[[ "${expected_index%% *}" == "$(python3 - "$tmp/SHA256SUMS" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
match = re.search(r'^([0-9a-f]{64})  index\.json$', text, re.M)
assert match
print(match[1])
PY
)" ]] || die 'index SHA-256 mismatch'

sha_ok() {
  [[ -f "$1" && ! -L "$1" && "$(stat -c %s -- "$1")" == "$2" ]] &&
    [[ "$(sha256sum -- "$1")" == "$3 "* ]]
}
download_part() {
  local name="$1" size="$2" digest="$3" attempt status current
  local target="$release/$name" partial="$release/$name.partial"
  [[ ! -L "$target" && ! -L "$partial" && ( ! -e "$target" || -f "$target" ) && ( ! -e "$partial" || -f "$partial" ) ]] || die "unsafe part path: $name"
  if sha_ok "$target" "$size" "$digest"; then printf 'reuse verified %s\n' "$name"; return; fi
  rm -f -- "$target"
  for attempt in 1 2 3; do
    current=0; [[ ! -f "$partial" ]] || current="$(stat -c %s -- "$partial")"
    if (( current >= size )); then
      if sha_ok "$partial" "$size" "$digest"; then mv -- "$partial" "$target"; return; fi
      rm -f -- "$partial"; current=0
    fi
    if (( current > 0 )); then
      status="$(curl --silent --show-error --proto "=$proto" --noproxy '*' --connect-timeout 10 --max-time 600 \
        -C - --output "$partial" --write-out '%{http_code}' "$prefix/$name")" || status=error
      [[ "$status" == error || "$status" == 206 ]] || { printf 'resume rejected: HTTP %s for %s\n' "$status" "$name" >&2; return 1; }
    else
      status="$(curl --silent --show-error --proto "=$proto" --noproxy '*' --connect-timeout 10 --max-time 600 \
        --output "$partial" --write-out '%{http_code}' "$prefix/$name")" || status=error
      [[ "$status" == error || "$status" == 200 ]] || { printf 'download rejected: HTTP %s for %s\n' "$status" "$name" >&2; return 1; }
    fi
    if [[ "$status" == error ]]; then printf 'retry %s (%s/3): transport error\n' "$name" "$attempt" >&2; continue; fi
    if sha_ok "$partial" "$size" "$digest"; then mv -- "$partial" "$target"; printf 'verified %s\n' "$name"; return; fi
    printf 'retry %s (%s/3): size or SHA-256 mismatch\n' "$name" "$attempt" >&2
    rm -f -- "$partial"
  done
  printf 'part SHA-256 mismatch after 3 attempts: %s\n' "$name" >&2
  return 1
}

while IFS=$'\t' read -r name size digest; do
  download_part "$name" "$size" "$digest" & workers+=("$!")
  if (( ${#workers[@]} >= jobs )); then
    failed=0
    for pid in "${workers[@]}"; do wait "$pid" || failed=1; done
    workers=()
    (( failed == 0 )) || die 'part download failed'
  fi
done <"$tmp/parts.tsv"
failed=0
for pid in "${workers[@]}"; do wait "$pid" || failed=1; done
workers=()
(( failed == 0 )) || die 'part download failed'

flash="$release/flash.raw.xz"
[[ ! -L "$flash" && ( ! -e "$flash" || -f "$flash" ) ]] || die 'unsafe assembled path'
flash_size="$(python3 - "$tmp/channel.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['flash']['size'])
PY
)"
flash_sha="$(python3 - "$tmp/channel.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['flash']['sha256'])
PY
)"
if ! sha_ok "$flash" "$flash_size" "$flash_sha"; then
  [[ ! -L "$flash.partial" && ( ! -e "$flash.partial" || -f "$flash.partial" ) ]] || die 'unsafe assembly path'
  rm -f -- "$flash"
  : >"$flash.partial"
  while IFS=$'\t' read -r name size digest; do cat -- "$release/$name" >>"$flash.partial"; done <"$tmp/parts.tsv"
  sha_ok "$flash.partial" "$flash_size" "$flash_sha" || die 'full flash SHA-256 mismatch'
  mv -- "$flash.partial" "$flash"
fi
printf 'verified compressed flash: %s\n' "$flash"
if (( decompress )); then
  raw="$release/flash.raw"
  [[ ! -L "$raw" && ! -L "$raw.partial" && ( ! -e "$raw" || -f "$raw" ) && ( ! -e "$raw.partial" || -f "$raw.partial" ) ]] || die 'unsafe raw output path'
  raw_sha="$(python3 - "$tmp/channel.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['flash']['raw_sha256'])
PY
)"
  if [[ ! -f "$raw" || "$(sha256sum -- "$raw")" != "$raw_sha "* ]]; then
    xz -dc -- "$flash" >"$raw.partial" || die 'flash decompression failed'
    [[ "$(sha256sum -- "$raw.partial")" == "$raw_sha "* ]] || die 'raw SHA-256 mismatch'
    mv -- "$raw.partial" "$raw"
  fi
  printf 'verified raw flash: %s\n' "$raw"
fi
