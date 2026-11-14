#!/usr/bin/python3
"""Image-owned, per-cellular-link CLAT. NetworkManager remains link owner."""
import ipaddress as ip
import json
import os
import re
from pathlib import Path
import signal
import socket
import subprocess
import time
import sys

RUN = Path('/run/ceralive/clat')
TAYGA = '/usr/sbin/tayga'


def command(*args, check=True, data=None):
    return subprocess.run(args, input=data, text=True, capture_output=True,
                          check=check, timeout=10).stdout


def embed(prefix, address):
    network = ip.IPv6Network(prefix)
    bits = f'{int(ip.IPv4Address(address)):032b}'
    head = f'{int(network.network_address):0128b}'[:network.prefixlen]
    if network.prefixlen == 96:
        return str(ip.IPv6Address(int(head + bits, 2)))
    before = 64 - network.prefixlen
    return str(ip.IPv6Address(int((head + bits[:before] + '00000000' + bits[before:]).ljust(128, '0'), 2)))


def prefix_from_answers(answers):
    addresses = {ip.IPv6Address(a) for a in answers}
    candidates = set()
    for address in addresses:
        for length in (32, 40, 48, 56, 64, 96):
            network = ip.IPv6Network((address, length), strict=False)
            if network.is_multicast or network.is_link_local or network.network_address == ip.IPv6Address('::'):
                continue
            if {ip.IPv6Address(embed(network, a)) for a in ('192.0.0.170', '192.0.0.171')} <= addresses:
                candidates.add(str(network))
    if len(candidates) != 1:
        raise ValueError('DNS64 must confirm one prefix with both RFC 7050 literals')
    return candidates.pop()


def discover(interface, source, resolvers):
    import dns.exception
    import dns.flags
    import dns.message
    import dns.rcode
    import dns.rdatatype
    # Only IP6Config DNS servers, through a link/source-bound socket.
    question = dns.message.make_query('ipv4only.arpa.', dns.rdatatype.AAAA)
    for resolver in resolvers:
        try:
            with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, interface.encode() + b'\0')
                sock.bind((source, 0))
                sock.settimeout(2)
                sock.connect((resolver, 53, 0, socket.if_nametoindex(interface)))
                sock.send(question.to_wire())
                answer = dns.message.from_wire(sock.recv(4096))
            if (not question.is_response(answer) or answer.rcode() != dns.rcode.NOERROR
                    or answer.flags & dns.flags.TC):
                continue
            addresses = [str(record.address) for rrset in answer.answer
                         if rrset.name == question.question[0].name
                         and rrset.rdtype == dns.rdatatype.AAAA for record in rrset]
            return prefix_from_answers(addresses)
        except (OSError, ValueError, dns.exception.DNSException):
            continue
    raise ValueError('No validated RFC 7050 prefix from uplink DNS')


def set_forwarding(value):
    # The global switch is required by the IPv6 forward path. Its sysctl setter
    # also changes every device: preserve those independent device settings.
    devices = {p: p.read_text().strip() for p in Path('/proc/sys/net/ipv6/conf').glob('*/forwarding')
               if p.parent.name not in ('all', 'default')}
    command('sysctl', '-qw', 'net.ipv6.conf.all.forwarding=' + value)
    for path, old in devices.items():
        if path.exists():
            path.write_text(old)


def eligible(addresses):
    if any(a['family'] == 'inet' and a['scope'] == 'global' for a in addresses):
        return []
    return sorted(a['local'] for a in addresses if a['family'] == 'inet6' and a['scope'] == 'global'
            and not any(a.get(flag) for flag in ('tentative', 'deprecated', 'dadfailed', 'temporary')))


def ip6_dns(config):
    # NM 1.52 and 1.58 IP6Config.Nameservers is aay, including link-local DNS.
    return tuple(socket.inet_ntop(socket.AF_INET6, bytes(address))
                 for address in config.get('Nameservers', []))


def retry(action):
    try:
        action()
    except Exception as error:
        print(f'CLAT reconciliation failed: {error}', file=sys.stderr, flush=True)
    return True


class Controller:
    def __init__(self):
        self.links = {}

    def sync(self, wanted):
        for interface, (signature, link) in list(self.links.items()):
            if wanted.get(interface) != signature or (link.process and link.process.poll() is not None):
                link.stop()
                del self.links[interface]
        for interface, signature in wanted.items():
            if interface not in self.links:
                try:
                    link = Link(interface, *signature)
                except (OSError, ValueError):
                    continue
                link.start()
                if link.undo:
                    self.links[interface] = (signature, link)
            else:
                link = self.links[interface][1]
                try:
                    link.repair_routes()
                except subprocess.SubprocessError as error:
                    link.stop('error', str(error))
                    del self.links[interface]
                    continue
                if time.monotonic() - getattr(link, 'refreshed', time.monotonic()) >= 60:
                    try:
                        prefix = discover(link.interface, link.source, link.resolvers)
                        link.failures = 0
                        if prefix != link.prefix:
                            link.stop()
                            del self.links[interface]
                            continue
                    except ValueError as error:
                        link.failures += 1
                        if link.failures >= 3:
                            link.stop('error', str(error))
                            del self.links[interface]
                            continue
                        link.status('up', str(error))
                        continue
                    finally:
                        link.refreshed = time.monotonic()
                link.status('up')
        if not self.links:
            restore_forwarding()


def restore_forwarding():
    state = RUN / 'forwarding'
    if state.exists():
        set_forwarding(state.read_text().strip())
        state.unlink()


class Link:
    def __init__(self, interface, source, gateway, resolvers):
        if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', interface):
            raise ValueError('unsupported interface name')
        source = str(ip.IPv6Address(source))
        gateway = str(ip.IPv6Address(gateway)) if gateway else ''
        self.interface, self.source, self.gateway, self.resolvers = interface, source, gateway, resolvers
        self.index = socket.if_nametoindex(interface)
        if self.index > 8191:
            raise ValueError('interface index exceeds CLAT allocation')
        self.tun = f'clat{self.index}'
        self.table = str(46000 + self.index)
        self.priority = str(10000 + self.index)
        self.v4 = str(ip.IPv4Address(int(ip.IPv4Address('10.254.0.0')) + self.index))
        self.v6 = f'fd46:4:4::{self.index:x}'
        self.nft = f'clat_{self.index}'
        self.process = None
        self.undo = []
        self.prefix = None
        self.forwarding = None
        self.failures = 0

    def status(self, state, error=None):
        try:
            RUN.mkdir(parents=True, exist_ok=True)
            path = RUN / f'{self.index}.json'
            temp = path.with_suffix('.tmp')
            temp.write_text(json.dumps(dict(schema_version=1, interface=self.interface,
                tun=self.tun, prefix=self.prefix, ipv4=self.v4, state=state,
                last_error=error, updated_at=int(time.time()))) + '\n')
            temp.chmod(0o644)
            temp.replace(path)
        except OSError as error:
            print(f'CLAT {self.interface} status write failed: {error}', file=sys.stderr, flush=True)

    def add(self, args, undo):
        self.undo.append(undo)
        self.save_cleanup()
        try:
            command(*args)
        except subprocess.CalledProcessError:
            self.undo.pop()
            self.save_cleanup()
            raise

    def save_cleanup(self):
        path = RUN / f'{self.index}.cleanup'
        temp = path.with_suffix('.journal')
        temp.write_text(json.dumps(self.undo))
        temp.chmod(0o600)
        temp.replace(path)

    def repair_routes(self):
        # Device down/up removes these routes without changing NM's grant.
        for family, route in [('-4', ['default', 'dev', self.tun, 'mtu', str(self.ipv4_mtu)]),
                              ('-6', ['default'] + (['via', self.gateway, 'onlink'] if self.gateway else []) + ['dev', self.interface])]:
            command('ip', family, 'route', 'replace', 'table', self.table, *route)
        command('ip', '-6', 'route', 'replace', self.v6 + '/128', 'dev', self.tun)
        command('ip', '-4', 'route', 'replace', 'default', 'dev', self.tun, 'metric', self.table, 'mtu', str(self.ipv4_mtu))

    def start(self):
        # Replay before discovery or ownership checks can reject leftover resources.
        # Retain failed undo commands until a later retry succeeds.
        journal = RUN / f'{self.index}.cleanup'
        try:
            if journal.exists():
                pending = []
                for args in reversed(json.loads(journal.read_text())):
                    try:
                        command(*args)
                    except (OSError, subprocess.SubprocessError) as error:
                        pending.insert(0, args)
                        print(f'CLAT {self.interface} cleanup replay failed: {error}', file=sys.stderr, flush=True)
                if pending:
                    self.undo = pending
                    try:
                        self.save_cleanup()
                    finally:
                        self.undo.clear()
                    self.status('error', 'cleanup replay incomplete')
                    return
                journal.unlink()
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.status('error', str(error))
            return
        try:
            self.prefix = discover(self.interface, self.source, self.resolvers)
            self.refreshed = time.monotonic()
            # Refuse overlap with any existing local IPv4 subnet.
            for device in json.loads(command('ip', '-j', 'addr')):
                for address in device['addr_info']:
                    if address['family'] == 'inet' and ip.IPv4Address(self.v4) in ip.IPv4Network((address['local'], address['prefixlen']), strict=False):
                        raise ValueError('CLAT service IPv4 allocation overlaps a local subnet')
            if self.tun in dict(socket.if_nameindex()).values():
                raise ValueError('CLAT TUN already owned')
            for family in ('-4', '-6'):
                routes = command('ip', '-j', family, 'route', 'show', 'table', self.table, check=False)
                if json.loads(routes or '[]'):
                    raise ValueError('CLAT routing table already owned')
                rules = json.loads(command('ip', '-j', family, 'rule'))
                if any(str(rule.get('priority')) == self.priority for rule in rules):
                    raise ValueError('CLAT rule priority already owned')
            tables = json.loads(command('nft', '-j', 'list', 'tables')).get('nftables', [])
            if any(t.get('table', {}).get('family') == 'inet' and
                   t['table'].get('name') == self.nft for t in tables):
                raise ValueError('CLAT firewall table already owned')
            self.status('starting')
            self.forwarding = command('sysctl', '-n', 'net.ipv6.conf.all.forwarding').strip()
            if self.forwarding != '1':
                global_state = RUN / 'forwarding'
                if not global_state.exists():
                    global_state.write_text(self.forwarding)
                set_forwarding('1')
            cfg = RUN / f'{self.index}.conf'
            cfg.write_text(f'tun-device {self.tun}\nipv4-addr 192.0.0.2\nipv6-addr fd46:4:ffff::{self.index:x}\nprefix {self.prefix}\nmap {self.v4} {self.v6}\n')
            self.add([TAYGA, '-c', str(cfg), '--mktun'], ['ip', 'link', 'del', self.tun])
            command('ip', 'link', 'set', self.tun, 'up')
            mtu = int(json.loads(command('ip', '-j', 'link', 'show', 'dev', self.interface))[0]['mtu'])
            self.ipv4_mtu = mtu - 20
            if self.ipv4_mtu < 1280:
                raise ValueError('uplink MTU too small for CLAT')
            command('ip', 'link', 'set', self.tun, 'mtu', str(mtu))
            command('ip', 'addr', 'add', self.v4 + '/32', 'dev', self.tun)
            # Loose checks are needed only on our synthetic link; do not change WAN settings.
            command('sysctl', '-qw', f'net.ipv4.conf.{self.tun}.rp_filter=2')
            for family, route in [('-4', ['default', 'dev', self.tun, 'mtu', str(self.ipv4_mtu)]),
                                  ('-6', ['default'] + (['via', self.gateway, 'onlink'] if self.gateway else []) + ['dev', self.interface])]:
                self.add(['ip', family, 'route', 'add', 'table', self.table] + route,
                         ['ip', family, 'route', 'flush', 'table', self.table])
            for family, src in [('-4', self.v4), ('-6', self.v6)]:
                self.add(['ip', family, 'rule', 'add', 'priority', self.priority, 'from', src, 'lookup', self.table],
                         ['ip', family, 'rule', 'del', 'priority', self.priority, 'from', src, 'lookup', self.table])
            self.add(['ip', '-6', 'route', 'add', self.v6 + '/128', 'dev', self.tun],
                     ['ip', '-6', 'route', 'del', self.v6 + '/128', 'dev', self.tun])
            self.add(['ip', '-4', 'route', 'add', 'default', 'dev', self.tun, 'metric', self.table, 'mtu', str(self.ipv4_mtu)],
                     ['ip', '-4', 'route', 'del', 'default', 'dev', self.tun, 'metric', self.table])
            self.add(['nft', 'create', 'table', 'inet', self.nft],
                     ['nft', 'delete', 'table', 'inet', self.nft])
            # The reply route points to the LAN, so rt mtu alone would use its
            # larger MTU. Cap both directions at this translator's IPv4 ceiling.
            command('nft', '-f', '-', data=f'''add chain inet {self.nft} post {{ type nat hook postrouting priority 110; }}
add rule inet {self.nft} post oifname "{self.tun}" ip saddr != {self.v4} snat ip to {self.v4}
add rule inet {self.nft} post oifname "{self.interface}" ip6 saddr {self.v6} snat ip6 to {self.source}
add chain inet {self.nft} mss_forward {{ type filter hook forward priority mangle; }}
add rule inet {self.nft} mss_forward meta nfproto ipv4 oifname "{self.tun}" tcp flags & syn == syn tcp option maxseg size > {self.ipv4_mtu - 40} tcp option maxseg size set {self.ipv4_mtu - 40}
add rule inet {self.nft} mss_forward meta nfproto ipv4 iifname "{self.tun}" tcp flags & syn == syn tcp option maxseg size > {self.ipv4_mtu - 40} tcp option maxseg size set {self.ipv4_mtu - 40}
add chain inet {self.nft} mss_output {{ type route hook output priority mangle; }}
add rule inet {self.nft} mss_output meta nfproto ipv4 oifname "{self.tun}" tcp flags & syn == syn tcp option maxseg size > {self.ipv4_mtu - 40} tcp option maxseg size set {self.ipv4_mtu - 40}
add chain inet {self.nft} forward {{ type filter hook forward priority 0; }}
add rule inet {self.nft} forward iifname "{self.tun}" oifname "{self.interface}" ip6 saddr {self.v6} ip6 daddr {self.prefix} accept
add rule inet {self.nft} forward iifname "{self.interface}" oifname "{self.tun}" ip6 daddr {self.v6} ct state established,related accept
add rule inet {self.nft} forward meta nfproto ipv6 iifname "{self.tun}" drop
add rule inet {self.nft} forward meta nfproto ipv6 oifname "{self.tun}" drop
''')
            if (RUN / 'forwarding').exists() and (RUN / 'forwarding').read_text().strip() == '0':
                command('nft', '-f', '-', data=f'add rule inet {self.nft} forward meta nfproto ipv6 iifname != "clat*" oifname != "clat*" drop\n')
            self.process = subprocess.Popen([TAYGA, '-c', str(cfg), '-n', '-u', 'nobody', '-g', 'nogroup'])
            time.sleep(.1)
            if self.process.poll() is not None:
                raise RuntimeError('tayga exited during startup')
            self.status('up')
        except Exception as error:
            self.stop('error', str(error))

    def stop(self, state='down', error=None):
        try:
            if self.process and self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=3)
        except (OSError, subprocess.SubprocessError) as failure:
            print(f'CLAT {self.interface} process cleanup failed: {failure}', file=sys.stderr, flush=True)
        pending = []
        for args in reversed(self.undo):
            try:
                command(*args, check=False)
            except (OSError, subprocess.SubprocessError) as failure:
                pending.insert(0, args)
                print(f'CLAT {self.interface} cleanup failed: {failure}', file=sys.stderr, flush=True)
        self.undo = pending
        try:
            if pending:
                self.save_cleanup()
            else:
                (RUN / f'{self.index}.cleanup').unlink(missing_ok=True)
        except OSError as failure:
            print(f'CLAT {self.interface} cleanup journal failed: {failure}', file=sys.stderr, flush=True)
        # Pending recovery belongs to the journal, not the live-link marker.
        self.undo.clear()
        self.status(state, error)


def main():
    import dbus
    import dbus.mainloop.glib
    from gi.repository import GLib
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    name = 'org.freedesktop.NetworkManager'
    controller = Controller()
    loop = GLib.MainLoop()
    def props(path, interface):
        return dbus.Interface(bus.get_object(name, path), 'org.freedesktop.DBus.Properties').GetAll(interface)
    def reconcile():
        wanted = {}
        try:
            manager = dbus.Interface(bus.get_object(name, '/org/freedesktop/NetworkManager'), name)
            for path in manager.GetDevices():
                try:
                    dev = props(path, name + '.Device')
                    if int(dev['DeviceType']) != 8 or int(dev['State']) != 100:
                        continue
                    interface = str(dev['IpInterface'])
                    addr = json.loads(command('ip', '-j', 'addr', 'show', 'dev', interface))[0]['addr_info']
                    sources = eligible(addr)
                    if not sources:
                        continue
                    config = props(dev['Ip6Config'], name + '.IP6Config')
                    gateway = str(config['Gateway'])
                    dns = ip6_dns(config)
                    has_default = gateway or json.loads(command('ip', '-j', '-6', 'route', 'show', 'default', 'dev', interface))
                    if sources and has_default:
                        wanted[interface] = (sources[0], gateway, dns)
                except Exception:
                    # A disappearing/incomplete device must not withdraw its neighbours.
                    continue
        except Exception:
            # Manager loss invalidates every previous grant; no stale translation.
            wanted = {}
        return retry(lambda: controller.sync(wanted))
    # D-Bus changes trigger reconciliation; periodic retry also recovers DNS/startup failures.
    pending = [False]
    def changed(*args, **kwargs):
        if not pending[0]:
            pending[0] = True
            def once():
                pending[0] = False
                reconcile()
                return False
            GLib.idle_add(once)
    bus.add_signal_receiver(changed, bus_name=name)
    def shutdown(*args):
        loop.quit()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    GLib.timeout_add_seconds(10, reconcile)
    reconcile()
    try:
        loop.run()
    finally:
        controller.sync({})
        cleanup()


def cleanup():
    for path in RUN.glob('*.cleanup'):
        for args in reversed(json.loads(path.read_text())):
            command(*args, check=False)
        path.unlink()
    restore_forwarding()
    for path in RUN.glob('*.json'):
        data = json.loads(path.read_text())
        data['state'] = 'down'
        temp = path.with_suffix('.tmp')
        temp.write_text(json.dumps(data) + '\n')
        temp.chmod(0o644)
        temp.replace(path)


if __name__ == '__main__':
    cleanup()
    if '--cleanup' not in sys.argv:
        main()
