#!/usr/bin/python3
"""Root-only synthetic network test; launch inside fresh PID/mount/network namespaces."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import struct
import sys
import subprocess as sp
import tempfile
import time

spec = importlib.util.spec_from_file_location('clat', Path(__file__).resolve().parents[1] / 'mkosi/runtime/ceralive-clat.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
c.TAYGA = os.environ.get('CLAT_TEST_TAYGA', '/usr/sbin/tayga')
c.RUN = Path(tempfile.mkdtemp())
processes = []
links = []
def run(*a): return c.command(*a)
def spawn(a):
    p = sp.Popen(a); processes.append(p); return p
def ns(p, *a): return ['nsenter', '-t', str(p.pid), '-n', '--', *a]
def probe(source, port=9010, prefix=[]):
    code = "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind((%r,0)); s.settimeout(3); s.sendto(b'clat-test',('192.0.2.2',%d)); assert s.recv(100)==b'clat-test'" % (source, port)
    run(*(prefix+['python3','-c',code]))
# Exercise the callback boundary with the real GLib timer implementation.
from gi.repository import GLib
loop = GLib.MainLoop()
calls = []
def flaky_sync():
    calls.append(1)
    if len(calls) == 1:
        raise OSError('injected synchronization failure')
    loop.quit()
timer = GLib.timeout_add(1, lambda: c.retry(flaky_sync))
deadline = GLib.timeout_add(1000, lambda: (loop.quit(), False)[1])
loop.run()
GLib.source_remove(timer)
GLib.source_remove(deadline)
assert len(calls) == 2
print('PASS real GLib retry timer survives synchronization exception', flush=True)
try:
    run('ip','link','set','lo','up')
    run('sysctl','-qw','net.ipv4.ip_forward=1')
    peer = spawn(['unshare','-n','sleep','300']); client = spawn(['unshare','-n','sleep','300']); time.sleep(.1)
    for p in [peer,client]: run(*ns(p,'ip','link','set','lo','up'))
    run(*ns(peer,'ip','addr','add','192.0.2.2/32','dev','lo'))
    run(*ns(peer,'sysctl','-qw','net.ipv4.ip_forward=1'))
    run(*ns(peer,'sysctl','-qw','net.ipv6.conf.all.forwarding=1'))
    cfg=c.RUN/'nat64.conf';cfg.write_text('tun-device nat64\nipv4-addr 192.0.2.254\nipv6-addr fd50::64\nprefix fd64:51::/96\ndynamic-pool 192.168.255.0/24\n')
    run(*ns(peer,c.TAYGA,'-c',str(cfg),'--mktun'))
    run(*ns(peer,'ip','link','set','nat64','up'))
    run(*ns(peer,'ip','-6','route','add','fd64:51::/96','dev','nat64'))
    run(*ns(peer,'ip','route','add','192.168.255.0/24','dev','nat64'))
    spawn(ns(peer,c.TAYGA,'-c',str(cfg),'-d'))
    sink="""import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('192.0.2.2',9010))
while True:
 b,a=s.recvfrom(65535);s.sendto(b,a)
"""
    spawn(ns(peer,'python3','-c',sink))
    dns="""import socket,struct,pathlib
s=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM);s.bind(('::',53))
while True:
 b,a=s.recvfrom(999);q=b[12:];ans=b''
 for v in (['fd64:51::1','fd64:51::2'] if pathlib.Path(%r).exists() else ['fd64:51::c000:aa','fd64:51::c000:ab']):
  ans+=bytes.fromhex('c00c001c00010000001e0010')+socket.inet_pton(socket.AF_INET6,v)
 s.sendto(b[:2]+bytes.fromhex('81800001000200000000')+q+ans,a)
"""
    dns = dns % str(c.RUN/'bad-dns')
    spawn(ns(peer,'python3','-c',dns))
    for i in [1,2]:
        wan=f'cell.{i}';srv=f'srv{i}'
        run('ip','link','add',wan,'type','veth','peer','name',srv)
        run('ip','link','set',srv,'netns',str(peer.pid))
        for a,dev,p in [(f'fd51:{i}::1/'+('128' if i==2 else '64'),wan,None),(f'fd51:{i}::2/64',srv,peer)]:
            cmd=['ip','addr','add',a,'dev',dev,'nodad']; run(*(ns(p,*cmd) if p else cmd))
            cmd=['ip','link','set',dev,'up'];run(*(ns(p,*cmd) if p else cmd))
        if i == 2:
            run('ip','-6','route','add','fd51:2::2/128','dev','cell.2')
        time.sleep(.5)
        run('sysctl','-qw',f'net/ipv6/conf/{wan}/accept_ra=0')
        run('sysctl','-qw',f'net/ipv6/conf/{wan}/forwarding=0')
        link=c.Link(wan,f'fd51:{i}::1',f'fd51:{i}::2',[f'fd51:{i}::2']);links.append(link)
        if i == 1:
            # A foreign table must survive a refused ownership claim.
            run('nft','create','table','inet',link.nft)
            link.start()
            assert not link.undo
            run('nft','list','table','inet',link.nft)
            run('nft','delete','table','inet',link.nft)
        link.start()
        assert json.loads((c.RUN/f'{link.index}.json').read_text())['state']=='up', (c.RUN/f'{link.index}.json').read_text()
        probe(link.v4)
    print('PASS two IPv6-only links: source-bound IPv4 echo over real tayga/NAT64',flush=True)
    run('ip','link','add','lan0','type','veth','peer','name','cli0');run('ip','link','set','cli0','netns',str(client.pid))
    run('ip','addr','add','10.42.0.1/24','dev','lan0');run('ip','link','set','lan0','up')
    run(*ns(client,'ip','addr','add','10.42.0.2/24','dev','cli0'));run(*ns(client,'ip','link','set','cli0','up'));run(*ns(client,'ip','route','add','default','via','10.42.0.1'))
    probe('10.42.0.2',prefix=ns(client))
    print('PASS hotspot NAT44 + CLAT + NAT64',flush=True)
    if '--service-only' not in sys.argv:
        sender=os.environ['CLAT_TEST_SENDER'];receiver=os.environ['CLAT_TEST_RECEIVER']
        received=c.RUN/'received'
        sink2="""import socket,pathlib
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('192.0.2.2',9002))
while True:
 b,a=s.recvfrom(999)
 if b.endswith(b'CLAT'):open(%r,'ab').write(b)
""" % str(received)
        spawn(ns(peer,'python3','-c',sink2));spawn(ns(peer,receiver,'9000','192.0.2.2','9002'))
        for link in links:
            ips=c.RUN/'ips';ips.write_text(link.v4+'\n')
            snd=spawn([sender,'--verbose','9001','192.0.2.2','9000',str(ips)])
            time.sleep(3)
            before=received.stat().st_size if received.exists() else 0
            u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
            for i in range(30): u.sendto(struct.pack('!IIII',i,0,0,1)+b'CLAT',('127.0.0.1',9001));time.sleep(.02)
            time.sleep(.3);assert received.stat().st_size>before
            snd.terminate();snd.wait(timeout=3)
        print('PASS real srtla_send -> IPv4 srtla_rec through each CLAT',flush=True)
    controller=c.Controller()
    for link in links:controller.links[link.interface]=((link.source,link.gateway,link.resolvers),link)
    # A flap drops owned IPv6 routes even when NM restores the same grant.
    signature = {link.interface: (link.source,link.gateway,link.resolvers) for link in links}
    run('ip','link','set','cell.2','down')
    run('ip','link','set','cell.2','up')
    run('ip','addr','replace','fd51:2::1/128','dev','cell.2','nodad')
    run('ip','-6','route','replace','fd51:2::2/128','dev','cell.2')
    controller.sync(signature)
    assert json.loads(run('ip','-j','-6','route','show','table',links[1].table))
    probe(links[1].v4)
    print('PASS route repair after interface flap',flush=True)
    for link in links:
        assert run('sysctl','-n',f'net/ipv6/conf/{link.interface}/accept_ra').strip() == '0'
        assert run('sysctl','-n',f'net/ipv6/conf/{link.interface}/forwarding').strip() == '0'
    # Observe fragments before conntrack reassembly on the NAT64 peer. Default
    # sockets deliberately retain IP_PMTUDISC_WANT, as ordinary senders do.
    run(*ns(peer,'nft','add','table','inet','fragment_probe'))
    run(*ns(peer,'nft','add','chain','inet','fragment_probe','ingress',
            '{ type filter hook prerouting priority -450; }'))
    run(*ns(peer,'nft','add','rule','inet','fragment_probe','ingress',
            'ip6','nexthdr','44','counter'))
    def fragments():
        rules = json.loads(run(*ns(peer,'nft','-j','list','chain','inet','fragment_probe','ingress')))
        return sum(expr['counter']['packets'] for item in rules['nftables']
                   for expr in item.get('rule', {}).get('expr', []) if 'counter' in expr)
    bulk_server = """import socket
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('192.0.2.2',9012));s.listen()
while True:
 c,a=s.accept();total=0
 while True:
  b=c.recv(65535)
  if not b:break
  total+=len(b)
 c.sendall(str(total).encode());c.close()
"""
    spawn(ns(peer,'python3','-c',bulk_server));time.sleep(.2)
    default_udp = """import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind((%r,0));s.settimeout(3)
for size in (1332,1372,1452):
 b=b'x'*size;s.sendto(b,('192.0.2.2',9010));assert s.recv(65535)==b
"""
    default_tcp = """import socket
s=socket.socket();s.bind((%r,0));s.settimeout(3);s.connect(('192.0.2.2',9012))
s.sendall(b'x'*200000);s.shutdown(socket.SHUT_WR)
assert s.recv(100)==b'200000'
"""
    for label, source, prefix in [('box '+link.interface,link.v4,[]) for link in links] + [('hotspot','10.42.0.2',ns(client))]:
        for protocol, code in [('UDP',default_udp),('TCP',default_tcp)]:
            before_fragments = fragments()
            run(*(prefix+['python3','-c',code % source]))
            count = fragments()-before_fragments
            assert count == 0, (label,protocol,count)
            print(f'PASS default-socket {label} {protocol}: zero IPv6 fragments',flush=True)
    run(*ns(peer,'nft','delete','table','inet','fragment_probe'))
    # A single transmission must fit in both directions without PTB/retry.
    def packet_too_big():
        fields = Path('/proc/net/snmp6').read_text().split()
        return int(fields[fields.index('Icmp6OutPktTooBigs') + 1])
    before = packet_too_big()
    large = """import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.bind((%r,0));s.settimeout(3)
s.setsockopt(socket.IPPROTO_IP,10,2) # IP_MTU_DISCOVER = IP_PMTUDISC_DO
b=b'x'*1452 # IPv4 total 1480, translated IPv6 total 1500
s.sendto(b,('192.0.2.2',9010));assert s.recv(65535)==b
"""
    for link in links:
        run('python3','-c',large % link.v4)
        assert int(json.loads(run('ip','-j','link','show','dev',link.tun))[0]['mtu']) == 1500
        for args in [('table',link.table),('dev',link.tun)]:
            routes = json.loads(run('ip','-j','-4','route','show',*args))
            default = next(r for r in routes if r['dst']=='default')
            metrics = default['metrics']
            if isinstance(metrics, list):
                metrics = {key: value for item in metrics for key, value in item.items()}
            assert metrics['mtu'] == 1480, default
            assert 'mtu 1480' in run('ip','-4','route','show',*args), default
            assert 'lock' not in run('ip','-4','route','show',*args), default
    run(*ns(client,'python3','-c',large % '10.42.0.2'))
    assert packet_too_big() == before
    print('PASS DF-forced IPv4 1480 / IPv6 1500 datagram each way without PTB',flush=True)
    # Check negotiated MSS at both ends, including the hotspot's 1500-byte LAN.
    tcp_server="""import socket,pathlib
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('192.0.2.2',9011));s.listen()
while True:
 c,a=s.accept();m=c.getsockopt(socket.IPPROTO_TCP,socket.TCP_MAXSEG)
 c.sendall(str(m).encode());c.close()
"""
    spawn(ns(peer,'python3','-c',tcp_server));time.sleep(.2)
    tcp_client="""import socket
s=socket.socket();s.bind((%r,0));s.settimeout(3);s.connect(('192.0.2.2',9011))
m=s.getsockopt(socket.IPPROTO_TCP,socket.TCP_MAXSEG)
r=int(s.recv(100));assert 1400 <= m <= 1440 and 1400 <= r <= 1440,(m,r)
"""
    for link in links:run('python3','-c',tcp_client % link.v4)
    run(*ns(client,'python3','-c',tcp_client % '10.42.0.2'))
    small = tcp_client.replace("s.bind(", "s.setsockopt(socket.IPPROTO_TCP,socket.TCP_MAXSEG,1200);s.bind(").replace('1400 <= m <= 1440 and 1400 <= r <= 1440', '1100 <= m <= 1200 and 1100 <= r <= 1200')
    run('python3','-c',small % links[0].v4)
    run(*ns(client,'python3','-c',small % '10.42.0.2'))
    print('PASS TCP MSS clamp for box and hotspot in both directions, smaller MSS preserved',flush=True)
    # Unrelated IPv6 traffic must not inherit forwarding enabled for CLAT.
    run('ip','addr','add','fd52::1/64','dev','lan0','nodad')
    run(*ns(client,'ip','addr','add','fd52::2/64','dev','cli0','nodad'))
    run(*ns(client,'ip','-6','route','add','fd51:1::/64','via','fd52::1'))
    run('ip','-6','route','add','fd51:1::/64','dev','cell.1')
    run(*ns(peer,'ip','-6','route','add','fd52::/64','via','fd51:1::1'))
    ping=ns(client,'ping','-6','-c','1','-W','1','fd51:1::2')
    assert sp.run(ping,stdout=sp.DEVNULL,stderr=sp.DEVNULL).returncode != 0
    # Stop all links, then emulate another owner's pre-existing forwarding.
    controller.sync({})
    assert run('sysctl','-n','net.ipv6.conf.all.forwarding').strip() == '0'
    run('sysctl','-qw','net.ipv6.conf.all.forwarding=1')
    for link in links:link.start()
    assert sp.run(ping,stdout=sp.DEVNULL,stderr=sp.DEVNULL).returncode == 0
    for link in links:link.stop()
    c.restore_forwarding()
    assert run('sysctl','-n','net.ipv6.conf.all.forwarding').strip() == '1'
    run('sysctl','-qw','net.ipv6.conf.all.forwarding=0')
    controller.sync(signature)
    links = [controller.links[name][1] for name in signature]
    print('PASS scoped IPv6 filter blocks unrelated traffic and preserves prior forwarding',flush=True)
    run('ip','link','set','cell.1','down')
    controller.sync({'cell.2': (links[1].source,links[1].gateway,links[1].resolvers)})
    probe(links[1].v4)
    assert not json.loads(run('ip','-j','link','show','type','tun')) == [] # second remains
    # Native IPv4 arrives: admission excludes the former IPv6-only grant.
    run('ip','addr','add','198.51.100.1/24','dev','cell.2')
    addresses=json.loads(run('ip','-j','addr','show','dev','cell.2'))[0]['addr_info']
    assert not c.eligible(addresses)
    controller.sync({})
    assert not any('clat' in a['ifname'] for a in json.loads(run('ip','-j','link')))
    assert 'clat_' not in run('nft','list','ruleset')
    run('ip','link','set','cell.1','up')
    run('ip','addr','replace','fd51:1::1/64','dev','cell.1','nodad')
    bad=c.Link('cell.1','fd51:1::1','fd51:1::2',[]);bad.start()
    assert json.loads((c.RUN/f'{bad.index}.json').read_text())['state']=='error' and not bad.undo
    assert not any('lookup 4600' in run('ip',family,'rule') for family in ['-4','-6'])
    print('PASS link teardown, survivor, absent prefix fails closed',flush=True)
    # Exercise the actual service entrypoint against NetworkManager D-Bus state.
    bus = sp.Popen(['dbus-daemon','--session','--nofork','--print-address=1'],stdout=sp.PIPE,text=True)
    processes.append(bus)
    address = bus.stdout.readline().strip()
    state = c.RUN/'nm-state';state.write_text(json.dumps({'1':100,'2':100,'ipv4_only':True}))
    fixture = spawn(['/usr/bin/python3',str(Path(__file__).with_name('clat-nm-fixture.py')),address,str(state)])
    run('ip','addr','add','198.51.100.2/24','dev','cell.1')
    # Both dual stack: the service must create no translator.
    module=c.RUN/'runtime.py';module.write_text(Path(c.__file__).read_text())
    code = "import importlib.util,os,pathlib; s=importlib.util.spec_from_file_location('clat',%r); c=importlib.util.module_from_spec(s);s.loader.exec_module(c);c.RUN=pathlib.Path(%r);c.TAYGA=%r;os.environ['DBUS_SYSTEM_BUS_ADDRESS']=%r;c.main()" % (str(module),str(c.RUN),c.TAYGA,address)
    time.sleep(.3)
    daemon=spawn(['setpriv','--bounding-set=-all,+net_admin,+net_raw,+kill,+setuid,+setgid','--no-new-privs','/usr/bin/python3','-c',code])
    time.sleep(.7)
    assert daemon.poll() is None
    assert not any('clat' in a['ifname'] for a in json.loads(run('ip','-j','link')))
    def wait_state(index, expected):
        for _ in range(200):
            path=c.RUN/f'{index}.json'
            if path.exists() and json.loads(path.read_text())['state']==expected:return
            time.sleep(.1)
        raise AssertionError(path.read_text() if path.exists() else 'no service status')
    run('ip','addr','del','198.51.100.1/24','dev','cell.2')
    wait_state(links[1].index,'up');probe(links[1].v4)
    assert links[0].tun not in [a['ifname'] for a in json.loads(run('ip','-j','link'))]
    run('ip','addr','del','198.51.100.2/24','dev','cell.1')
    state.write_text(json.dumps({'1':100,'2':100}))
    for link in links:wait_state(link.index,'up');probe(link.v4)
    state.write_text(json.dumps({'1':100,'2':100,'ipv4_only':True}))
    wait_state(links[0].index,'down')
    assert json.loads((c.RUN/f'{links[1].index}.json').read_text())['state']=='up'
    probe(links[1].v4)
    state.write_text(json.dumps({'1':30,'2':100}))
    wait_state(links[0].index,'down');probe(links[1].v4)
    state.write_text(json.dumps({'1':30,'2':30}))
    wait_state(links[1].index,'down')
    daemon.terminate();daemon.wait(timeout=5)
    assert not any('clat' in a['ifname'] for a in json.loads(run('ip','-j','link')))
    (c.RUN/'bad-dns').touch()
    bad=c.Link('cell.1','fd51:1::1','fd51:1::2',['fd51:1::2']);bad.start()
    assert not bad.undo and json.loads((c.RUN/f'{bad.index}.json').read_text())['state']=='error'
    (c.RUN/'bad-dns').unlink()
    # Simulate death after creation returns, before add() can do further work.
    early=c.Link('cell.1','fd51:1::1','fd51:1::2',['fd51:1::2'])
    original=c.command
    def crash_after_create(*args, **kwargs):
        original(*args, **kwargs)
        raise SystemExit('simulated abrupt exit')
    c.command=crash_after_create
    try:
        early.add(['ip','link','add',early.tun,'type','dummy'], ['ip','link','del',early.tun])
    except SystemExit:
        pass
    finally:
        c.command=original
    c.cleanup()
    assert early.tun not in [a['ifname'] for a in json.loads(run('ip','-j','link'))]
    print('PASS crash immediately after resource creation',flush=True)
    orphan=c.Link('cell.1','fd51:1::1','fd51:1::2',['fd51:1::2']);orphan.start()
    assert orphan.undo
    orphan.process.kill();orphan.process.wait()
    c.cleanup()
    assert not any('clat' in a['ifname'] for a in json.loads(run('ip','-j','link')))
    assert 'clat_' not in run('nft','list','ruleset')
    assert run('sysctl','-n','net.ipv6.conf.all.forwarding').strip() == '0'
    print('PASS crash journal cleanup and global forwarding restoration',flush=True)
    print('PASS malformed DNS64 prefix fails closed',flush=True)
    print('PASS actual D-Bus service: dual-stack exclusion, two grants, link loss and clean stop',flush=True)

finally:
    for link in links:link.stop()
    c.cleanup()
    for p in reversed(processes):
        if p.poll() is None:p.terminate()
    for p in processes:
        try:p.wait(timeout=3)
        except sp.TimeoutExpired:p.kill();p.wait()
