#!/usr/bin/python3
"""Bounded, device-bound HTTP/WebSocket front door. Linux, stdlib only."""
import asyncio
import ipaddress
import json
import logging
from pathlib import Path
import socket
import ssl
import struct
import subprocess

UNIX = '/run/ceralive-button-ingress/rpc.sock'
MAX_CONNECTIONS = 128
HEADER_LIMIT = 16384


def eligible(link, physical):
    return (physical and link.get('link_type') == 'ether'
            and 'UP' in link.get('flags', []) and not link.get('master')
            and not link.get('linkinfo', {}).get('info_kind'))


def parse_head(raw):
    if len(raw) > HEADER_LIMIT or not raw.endswith(b'\r\n\r\n'):
        raise ValueError('header size/framing')
    lines = raw[:-4].decode('ascii').split('\r\n')
    method, target, version = lines[0].split(' ')
    if version != 'HTTP/1.1' or method == 'CONNECT' or not target.startswith('/') or target.startswith('//'):
        raise ValueError('request target')
    headers = {}
    for line in lines[1:]:
        name, value = line.split(':', 1)
        if not name or any(c not in "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" for c in name):
            raise ValueError('header name')
        name = name.lower()
        if name in headers or any(ord(c) < 32 and c != '\t' for c in value) or '\x7f' in value:
            raise ValueError('ambiguous header')
        headers[name] = value.strip()
    if 'host' not in headers or ('transfer-encoding' in headers and 'content-length' in headers):
        raise ValueError('ambiguous framing')
    return method, target, headers


def privileged(head, direct, peer, cidr):
    method, target, headers = head
    if not direct or method != 'GET' or target != '/ws':
        return False
    if any(k in ('forwarded', 'via', 'x-ceralive-button-path') or k.startswith('x-forwarded-') for k in headers):
        return False
    if headers.get('upgrade', '').lower() != 'websocket' or 'upgrade' not in [token.strip().lower() for token in headers.get('connection', '').split(',')]:
        return False
    if 'content-length' in headers or 'transfer-encoding' in headers:
        return False
    try:
        address = ipaddress.ip_address(peer)
        return address.version == 4 and not address.is_loopback and address in ipaddress.ip_interface(cidr).network
    except ValueError:
        return False


def bound_socket(family, name, address, port, factory=socket.socket, index=0):
    sock = factory(family, socket.SOCK_STREAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, name.encode() + b'\0')
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((address, port) if family == socket.AF_INET else (address, port, 0, index))
        sock.listen(64)
        sock.setblocking(False)
        return sock
    except BaseException:
        sock.close()
        raise


class Generation:
    def __init__(self):
        self.number = 0
        self.writers = set()
        self.listeners = []

    def invalidate(self):
        self.number += 1
        for listener in self.listeners:
            listener.close()
        for writer in self.writers:
            writer.close()
        self.listeners.clear()
        self.writers.clear()


class FrontDoor:
    def __init__(self, contexts):
        self.state = Generation()
        self.contexts = contexts
        self.tasks = set()
        self.trusted_ready = False
        self.backend_address = ('127.0.0.1', 18080)
        self.unix_path = UNIX
        self.monitor = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE)
        # Subscribe BEFORE the initial ip dump. Link + IPv4/IPv6 address events.
        self.monitor.bind((0, 1 | 0x10 | 0x100))
        self.monitor.setblocking(False)
        self.pending = None
        self.needs_subscription = False
        self.loop = None

    def resubscribe(self):
        monitor = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE)
        try:
            monitor.bind((0, 1 | 0x10 | 0x100))
            monitor.setblocking(False)
        except BaseException:
            monitor.close()
            raise
        if self.loop is not None:
            self.loop.remove_reader(self.monitor)
        self.monitor.close()
        self.monitor = monitor
        if self.loop is not None:
            self.loop.add_reader(self.monitor, self.event)
        self.needs_subscription = False

    def drain_events(self):
        changed = False
        while True:
            try:
                data, _, flags, _ = self.monitor.recvmsg(262144)
                changed = True
                if not data or flags & socket.MSG_TRUNC:
                    raise OSError('netlink truncated')
                offset = 0
                while offset < len(data):
                    if len(data) - offset < 16:
                        raise OSError('netlink incomplete header')
                    length, kind, message_flags = struct.unpack_from('=IHH', data, offset)
                    # NLMSG_ERROR/OVERRUN and NLM_F_DUMP_INTR lose continuity.
                    if length < 16 or offset + length > len(data) or kind in (2, 4) or message_flags & 0x10:
                        raise OSError('netlink event history unavailable')
                    offset += (length + 3) & ~3
            except BlockingIOError:
                return changed
            except OSError:
                # ENOBUFS/overflow or uncertain message: same full invalidation.
                self.needs_subscription = True
                self.event_fence()
                return True

    def event(self):
        if self.drain_events():
            self.event_fence()
            self.schedule()

    def schedule(self):
        if self.pending is None or self.pending.done():
            self.pending = asyncio.create_task(self.reconcile())

    async def reconcile(self):
        self.event_fence()
        failed = False
        try:
            if self.needs_subscription:
                self.resubscribe()
            # Synchronous bounded dumps: no application handler runs between
            # snapshot and event drain. Queued events discard the whole snapshot.
            links = json.loads(subprocess.check_output(['/usr/sbin/ip', '-j', '-d', 'address', 'show'], timeout=3))
            if self.drain_events():
                return
            generation = self.state.number
            for link in links:
                name, index = link['ifname'], link['ifindex']
                direct = eligible(link, Path('/sys/class/net', name, 'device').exists())
                for addr in link.get('addr_info', []):
                    if addr.get('family') not in ('inet', 'inet6') or 'tentative' in addr.get('flags', []):
                        continue
                    family = socket.AF_INET if addr['family'] == 'inet' else socket.AF_INET6
                    local = addr['local']
                    cidr = f"{local}/{addr['prefixlen']}"
                    for port, context in self.contexts:
                        try:
                            sock = bound_socket(family, name, local, port, index=index)
                            server = await asyncio.start_server(
                                lambda r, w, n=name, c=cidr, d=direct and family == socket.AF_INET, g=generation: self.accept(r, w, n, c, d, g),
                                sock=sock, ssl=context, limit=HEADER_LIMIT,
                                **({'ssl_handshake_timeout': 5} if context else {}))
                            if generation != self.state.number:
                                server.close()
                                return
                            self.state.listeners.append(server)
                        except OSError:
                            failed = True
                            logging.exception('listener unavailable for %s:%s', name, port)
            if self.drain_events():
                self.event_fence()
            else:
                self.trusted_ready = not failed
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            self.needs_subscription = True
            self.event_fence()
            logging.exception('listener reconciliation unavailable')
        finally:
            asyncio.get_running_loop().call_later(2, self.retry)

    def event_fence(self):
        self.trusted_ready = False
        self.state.invalidate()
        for task in tuple(self.tasks):
            task.cancel()

    def retry(self):
        # Retry partial bind/dump failures; unchanged snapshots need no churn.
        if not self.state.listeners or not self.trusted_ready:
            self.schedule()

    async def accept(self, reader, writer, name, cidr, direct, generation):
        task = asyncio.current_task()
        if len(self.tasks) >= MAX_CONNECTIONS or generation != self.state.number:
            writer.close()
            return
        self.tasks.add(task)
        self.state.writers.add(writer)
        backend = None
        pumps = []
        async def pump(source, sink):
            while True:
                data = await asyncio.wait_for(source.read(65536), 120)
                if not data:
                    return
                sink.write(data)
                await asyncio.wait_for(sink.drain(), 10)
        try:
            raw = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 5)
            head = parse_head(raw)
            peer = writer.get_extra_info('peername')[0]
            local = writer.get_extra_info('sockname')[0]
            if self.drain_events():
                self.event_fence()
                self.schedule()
            trusted = privileged(head, direct and self.trusted_ready, peer, cidr)
            if generation != self.state.number:
                return
            if trusted:
                try:
                    upstream, backend = await asyncio.wait_for(asyncio.open_unix_connection(self.unix_path, limit=HEADER_LIMIT), 3)
                except (OSError, asyncio.TimeoutError):
                    trusted = False
            if trusted:
                evidence = json.dumps(dict(version=1, peer=peer, interface=name, local=local), separators=(',', ':'))
                raw = raw[:-2] + b'X-Ceralive-Button-Path: ' + evidence.encode() + b'\r\n\r\n'
            else:
                upstream, backend = await asyncio.wait_for(asyncio.open_connection(*self.backend_address, limit=HEADER_LIMIT), 3)
                # Ordinary HTTP is one request per connection. An ordinary WS
                # remains ordinary for its entire lifetime, never reclassified.
                if head[2].get('upgrade', '').lower() != 'websocket':
                    lines = raw[:-4].split(b'\r\n')
                    raw = b'\r\n'.join([lines[0]] + [x for x in lines[1:] if not x.lower().startswith(b'connection:')]) + b'\r\nConnection: close\r\n\r\n'
            self.state.writers.add(backend)
            if self.drain_events():
                self.event_fence()
                self.schedule()
            if generation != self.state.number:
                return
            backend.write(raw)
            await asyncio.wait_for(backend.drain(), 5)
            if not trusted:
                # HTTP POST bodies must flow before the backend can respond.
                pumps.append(asyncio.create_task(pump(reader, backend)))
            # Inspect upstream response before tunnelling: no second HTTP request
            # may reach the private endpoint after a rejected upgrade.
            response = await asyncio.wait_for(upstream.readuntil(b'\r\n\r\n'), 5)
            writer.write(response)
            await asyncio.wait_for(writer.drain(), 5)
            if trusted and not response.startswith(b'HTTP/1.1 101 '):
                return
            if trusted:
                pumps.append(asyncio.create_task(pump(reader, backend)))
            pumps.append(asyncio.create_task(pump(upstream, writer)))
            await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
        except (OSError, ValueError, asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            pass
        finally:
            for p in pumps:
                p.cancel()
            for w in (writer, backend):
                if w:
                    w.close()
                    self.state.writers.discard(w)
            self.tasks.discard(task)
            await asyncio.gather(*pumps, return_exceptions=True)

    async def run(self):
        self.loop = asyncio.get_running_loop()
        self.loop.add_reader(self.monitor, self.event)
        self.schedule()
        try:
            await asyncio.Future()
        finally:
            self.event_fence()
            self.loop.remove_reader(self.monitor)
            self.monitor.close()


def main():
    logging.basicConfig(level=logging.INFO)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    directory = Path('/data/ceralive/tls')
    if not directory.is_dir():
        directory = Path('/etc/ceralive/tls')
    context.load_cert_chain(directory / 'ceralive.crt', directory / 'ceralive.key')
    asyncio.run(FrontDoor([(80, None), (443, context)]).run())


if __name__ == '__main__':
    main()
