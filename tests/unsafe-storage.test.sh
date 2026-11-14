#!/usr/bin/env bash
# Host contract for the terminal storage refusal and onboarding probe.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
spec = importlib.util.spec_from_file_location('attention', 'mkosi/runtime/ceralive-attention.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    a.INPUT = root / 'input'
    a.INPUT.mkdir()
    out = root / 'output'
    receipt = root / 'receipt'
    for reason, text in [
        ('media-too-small', 'This card is too small for the box.'),
        ('card-io-failed', "The box couldn't prepare its storage."),
        ('card-read-only', 'This card is read-only.'),
        ('partition-growth', 'The card could not finish getting ready.'),
        ('filesystem-growth', 'The card could not finish getting ready.'),
    ]:
        receipt.write_text(reason + ' 8000000000 unknown unknown unknown')
        a.data_condition(receipt)
        item = json.loads((a.INPUT / 'data-readiness.json').read_text())
        assert item['line'] == text, item
        assert item['severity'] == 'fatal'
        a.render([item], out)
        page = (out / 'index.html').read_text()
        assert "can't start safely" in page
        if reason == 'media-too-small':
            assert '16 GB' in item['fix'] and '15000000000' in item['detail']
        terminal = root / 'tty'
        console = a.Console(directory=root / 'console', terminal=str(terminal),
                            run=lambda *args: False, foreground=lambda: '1')
        console.update(item)
        assert "can't start safely" in terminal.read_text()
        assert text in terminal.read_text().replace('\n', ' ')
        # Probe and browser consume the same volatile condition without TLS/data.
        for path in ['/', '/attention/', '/attention/status.json']:
            result = subprocess.run(['bash', 'mkosi/runtime/ceralive-data-diagnostic.sh'],
                input=f'GET {path} HTTP/1.1\r\n\r\n', text=True, capture_output=True,
                env=__import__('os').environ | {'CERALIVE_ATTENTION_OUTPUT': str(out)}, check=True)
            header, body = result.stdout.split('\n\n', 1)
            assert '200 OK' in header
            if path.endswith('.json'):
                assert json.loads(body)['highest']['line'] == text
                assert 'application/json' in header
            else:
                assert "can't start safely" in body
    # Dependency failure can prevent ExecStart entirely; do not rely on is-failed.
    calls = []
    def control(*args):
        calls.append(args)
        return 'inactive' if args[-1] in ('ceralive.service', 'ceralive-portal.socket', 'ceralive-data-ready.service') else ''
    a.command = control
    a.listener([{'id': 'data-readiness'}])
    assert calls[-1] == ('systemctl', '--no-block', 'start', 'ceralive-data-diagnostic.socket')
installer = Path('mkosi/customize/postinst.d/persistence.sh').read_text()
assert 'x-systemd.requires=ceralive-grow-data.service' in installer
print('unsafe storage messages, volatile probe routes and dependency-failure listener pass')
PY
