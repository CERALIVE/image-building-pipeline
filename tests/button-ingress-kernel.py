#!/usr/bin/python3
"""Run only inside a disposable root network namespace; no host networking."""
import importlib.util
import pathlib
import socket
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ingress', root / 'mkosi/runtime/button-ingress/ingress.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)

child = subprocess.Popen(['unshare', '-n', 'sleep', '60'])
try:
    # Wait for unshare to complete without arbitrary timing delays.
    import os
    import time
    deadline = time.monotonic() + 3
    while os.readlink(f'/proc/{child.pid}/ns/net') == os.readlink('/proc/self/ns/net'):
        if child.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('child namespace unavailable')
    def client(*args): run('nsenter', '-t', str(child.pid), '-n', *args)
    run('ip', 'link', 'set', 'lo', 'up')
    for iface, peer, address in [('lan0', 'client0', '192.0.2.2'), ('vpn0', 'client1', '192.0.2.3')]:
        run('ip', 'link', 'add', iface, 'type', 'veth', 'peer', 'name', peer)
        run('ip', 'link', 'set', peer, 'netns', str(child.pid))
        run('ip', 'addr', 'add', '192.0.2.1/24', 'dev', iface)
        run('ip', 'link', 'set', iface, 'up')
        client('ip', 'addr', 'add', address + '/24', 'dev', peer)
        client('ip', 'link', 'set', peer, 'up')
        run('sysctl', '-q', '-w', f'net.ipv4.conf.{iface}.rp_filter=0')
    run('sysctl', '-q', '-w', 'net.ipv4.conf.all.rp_filter=0')
    listener = m.bound_socket(socket.AF_INET, 'lan0', '192.0.2.1', 18888)
    listener.settimeout(2)
    probe = "import socket,sys;s=socket.socket();s.settimeout(.5);\ntry:s.connect(('192.0.2.1',18888));ok=True\nexcept OSError:ok=False\ns.close();sys.exit(0 if ok == (sys.argv[1]=='yes') else 1)"
    client('ip', 'route', 'replace', '192.0.2.1/32', 'dev', 'client0')
    client('python3', '-c', probe, 'yes')
    conn, _ = listener.accept()
    conn.close()
    client('ip', 'route', 'replace', '192.0.2.1/32', 'dev', 'client1')
    client('python3', '-c', probe, 'no')
    listener.settimeout(.1)
    try:
        conn, _ = listener.accept()
        conn.close()
        raise AssertionError('wrong-interface ingress accepted')
    except socket.timeout:
        pass
    listener.close()
    # The backend stays wildcard in the partner application. Verify the real
    # image fence, including local access, in this same disposable namespace.
    backend = socket.socket()
    backend.bind(('0.0.0.0', 18080))
    backend.listen()
    client('python3', '-c', probe.replace('18888', '18080'), 'yes')
    accepted, _ = backend.accept()
    accepted.close()
    run('nft', '-f', str(root / 'mkosi/runtime/button-ingress/backend.nft'))
    loopback = socket.create_connection(('127.0.0.1', 18080), timeout=1)
    loopback.close()
    client('python3', '-c', probe.replace('18888', '18080'), 'no')
    backend.close()
    print('actual SO_BINDTODEVICE: direct accepted, overlapping wrong-device ingress refused')
finally:
    child.terminate()
    child.wait()
