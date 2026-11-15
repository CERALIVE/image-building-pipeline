#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import importlib.util
import json
from pathlib import Path
import tempfile
import time
spec = importlib.util.spec_from_file_location('attention', 'mkosi/runtime/ceralive-attention.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    a.INPUT = root / 'input'
    a.INPUT.mkdir()
    out = root / 'output'
    for severity in a.SEVERITY:
        a.publish(severity, severity, '<Card needs attention>', 'Details & facts', 'Check the card.')
    items = a.conditions(a.INPUT)
    assert [i['severity'] for i in items] == ['fatal', 'critical', 'warn', 'info']
    a.render(items, out)
    assert '&lt;Card needs attention&gt;' in (out/'index.html').read_text()
    assert '<Card needs attention>' not in (out/'index.html').read_text()
    assert json.loads((out/'status.json').read_text())['highest']['severity'] == 'fatal'
    assert a.conditions(a.INPUT, time.time()+40) == []
    for value in ['not-json', '{}', json.dumps(dict(id='../../secret')), '[]']:
        (a.INPUT/'bad.json').write_text(value)
        assert len(a.conditions(a.INPUT)) == 4
    base = items[0]
    for mutation in [dict(expires=float('nan')), dict(line='escape\x1b'), dict(severity='urgent'), dict(expires=time.time()+90000), dict(led='arbitrary')]:
        try:
            a.validate(base | mutation, time.time())
            raise AssertionError(mutation)
        except ValueError:
            pass
    # Every readiness class produces a shared fatal condition and outputs.
    for reason in ['media-too-small','partition-growth','filesystem-growth','filesystem-incomplete','data-full','data-unusable','readiness-failed']:
        receipt=root/'receipt'
        receipt.write_text(reason+' 5923405824 unknown unknown unknown')
        a.data_condition(receipt)
        posted=json.loads((a.INPUT/'data-readiness.json').read_text())
        assert posted['severity']=='fatal'
        assert 'Minimum media: 15000000000 bytes' in posted['detail']
        if reason == 'media-too-small':
            assert '16 GB card or larger' in posted['line'] and '16 GB' in posted['fix']
        assert reason in posted['detail'] or reason=='readiness-failed'
        a.render([posted],out)
        assert posted['line'] in (out/'index.html').read_text()
    receipt.unlink()
    a.data_condition(receipt)
    assert not (a.INPUT/'data-readiness.json').exists()
    # Console/LED calls are exercised without touching the host devices.
    calls=[]
    a.command=lambda *args: calls.append(args) or ''
    a.apply(items[0])
    assert (a.LED, 'attention', 'fatal') in calls
    a.apply(None)
    assert (a.LED, 'attention', 'clear') in calls
    import unittest.mock as mock
    states={'ceralive.service':'inactive','ceralive-portal.socket':'inactive','ceralive-data-ready.service':'failed'}
    def control(*args):
        calls.append(args)
        return states.get(args[-1], '') if args[0]=='systemctl' and '--no-block' not in args else ''
    a.command=control
    a.listener([dict(id='data-readiness')])
    assert calls[-1]==('systemctl','--no-block','start','ceralive-data-diagnostic.socket')
    states['ceralive.service']='active'
    a.listener([dict(id='data-readiness')])
    assert calls[-1]==('systemctl','--no-block','stop','ceralive-data-diagnostic.socket')
    a.listener([])
    assert calls[-1]==('systemctl','--no-block','stop','ceralive-data-diagnostic.socket')
    thermal=root/'thermal'/'thermal_zone0'
    thermal.mkdir(parents=True)
    (thermal/'temp').write_text('85000')
    a.probes(root/'thermal')
    assert 'failed or timed out' in json.loads((a.INPUT/'data-readiness.json').read_text())['detail']
    assert json.loads((a.INPUT/'temperature-high.json').read_text())['severity']=='critical'
    with mock.patch.object(a.time, 'time', return_value=1700000000):
        a.probes(root/'thermal')
        assert (a.INPUT/'clock-unset.json').exists()
print('shared conditions, severity, expiry, escaping, invalid input, data/thermal/clock triggers and console pass')
PY
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/leds/blue:status" "$work/leds/mmc0::" "$work/leds/red:power" "$work/page"
printf 'none [heartbeat] timer\n' >"$work/leds/blue:status/trigger"
printf '[mmc0] timer\n' >"$work/leds/mmc0::/trigger"
printf '[default-on] timer\n' >"$work/leds/red:power/trigger"
export CERALIVE_LED_CLASS_DIR="$work/leds" CERALIVE_LED_ATTENTION_STATE="$work/led-state" CERALIVE_LED_WAIT=0
for severity in info warn critical fatal; do
  bash mkosi/runtime/ceralive-led-status.sh attention "$severity"
  grep -qx timer "$work/leds/blue:status/trigger"
done
grep -qx 1000 "$work/leds/blue:status/delay_on"
grep -qx 3000 "$work/leds/blue:status/delay_off"
bash mkosi/runtime/ceralive-led-status.sh attention clear
grep -qx heartbeat "$work/leds/blue:status/trigger"
grep -q '\[mmc0\]' "$work/leds/mmc0::/trigger"
grep -q '\[default-on\]' "$work/leds/red:power/trigger"
[[ ! -e $work/leds/blue:status/brightness ]]
printf '[heartbeat] none\n' >"$work/leds/blue:status/trigger"
bash mkosi/runtime/ceralive-led-status.sh attention fatal
grep -q '\[heartbeat\]' "$work/leds/blue:status/trigger"
export CERALIVE_ATTENTION_OUTPUT="$work/page"
echo 'Card needs attention.' >"$work/page/index.html"
for method in GET HEAD POST; do
  printf '%s / HTTP/1.1\r\nHost: example\r\n\r\n' "$method" | bash mkosi/runtime/ceralive-data-diagnostic.sh >"$work/response"
  if [[ $method == POST ]]; then grep -q '405 Method Not Allowed' "$work/response"
  else grep -q '200 OK' "$work/response"; fi
  if [[ $method == HEAD ]]; then ! grep -q 'Card needs' "$work/response"; fi
done
printf 'GET /../../etc/passwd HTTP/1.1\r\n\r\n' | bash mkosi/runtime/ceralive-data-diagnostic.sh >"$work/response"
grep -q '404 Not Found' "$work/response"
echo 'LED activation/hand-back/exclusions/no-timer and bounded read-only HTTP pass'
# Installation and network ownership contracts complement rendered ordering tests.
python3 - <<'PY'
from pathlib import Path
import configparser
unit=configparser.ConfigParser()
unit.read('mkosi/runtime/ceralive-attention.service')
assert not unit.has_option('Unit','RequiresMountsFor')
assert unit['Service']['RuntimeDirectory']=='ceralive/attention ceralive/attention-status'
sock=configparser.ConfigParser()
sock.read('mkosi/runtime/ceralive-data-diagnostic.socket')
assert sock['Socket']['ListenStream']=='0.0.0.0:80'
assert sock['Socket']['Accept']=='yes'
assert 'ceralive.service' not in sock.get('Unit','Conflicts',fallback='')
installer=Path('mkosi/customize/postinst.d/persistence.sh').read_text()
assert installer.index('ceralive-attention.py') < installer.index('if [[ "${BOARD_ID:-}" == rock-5b-plus ]]; then')
assert 'Wants=ceralive-attention.service data.mount ceralive-grow-data.service systemd-growfs@data.service' in installer
assert 'ExecStartPost=-/usr/bin/systemctl stop ceralive-data-diagnostic.socket' in installer
print('shared install, no-data dependency, fixed listener and recovery stop contracts pass')
PY
