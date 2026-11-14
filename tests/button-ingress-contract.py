#!/usr/bin/env python3
import asyncio
import tempfile
import importlib.util
import pathlib
import socket
import errno
import unittest
from unittest.mock import Mock, patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ingress', ROOT / 'mkosi/runtime/button-ingress/ingress.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class Contract(unittest.TestCase):
    def test_identity_not_name(self):
        base = dict(ifname='eth0', link_type='ether', flags=['UP'], ifindex=2)
        self.assertTrue(m.eligible(base, True))
        self.assertTrue(m.eligible(dict(base, ifname='ap0'), True))
        for change in [dict(linkinfo={'info_kind':'wireguard'}), dict(master='br0'), dict(link_type='loopback'), dict(flags=[]), dict(linkinfo={'info_kind':'bridge'})]:
            self.assertFalse(m.eligible(dict(base, **change), True))
        self.assertFalse(m.eligible(base, False))

    def test_each_upgrade(self):
        good = b'GET /ws HTTP/1.1\r\nHost: box.local\r\nOrigin: http://box.local\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n'
        head = m.parse_head(good)
        self.assertTrue(m.privileged(head, True, '192.168.2.4', '192.168.2.1/24'))
        comma = m.parse_head(good.replace(b'Connection: Upgrade', b'Connection: keep-alive, Upgrade'))
        self.assertTrue(m.privileged(comma, True, '192.168.2.4', '192.168.2.1/24'))
        for name in ['Forwarded', 'X-Forwarded-For', 'x-forwarded-anything', 'Via', 'X-Ceralive-Button-Path']:
            self.assertFalse(m.privileged(m.parse_head(good[:-2] + name.encode() + b':\r\n\r\n'), True, '192.168.2.4', '192.168.2.1/24'))
        for peer in ['10.0.0.2', '::1', '127.0.0.1']:
            self.assertFalse(m.privileged(head, True, peer, '192.168.2.1/24'))
        self.assertFalse(m.privileged(head, False, '192.168.2.4', '192.168.2.1/24'))
        for raw in [good.replace(b'/ws ', b'/preview '), good.replace(b'/ws ', b'/ws?senderId=relay ')]:
            self.assertFalse(m.privileged(m.parse_head(raw), True, '192.168.2.4', '192.168.2.1/24'))
        for raw in [good.replace(b'GET ', b'CONNECT '), good.replace(b'Host:', b' Host:'), good.replace(b'Host: box.local', b'Host: x\r\nHost: y')]:
            with self.assertRaises(ValueError): m.parse_head(raw)

    def test_device_and_address_binding(self):
        fake = Mock()
        m.bound_socket(socket.AF_INET, 'eth7', '192.168.2.1', 80, lambda *a: fake)
        fake.setsockopt.assert_any_call(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b'eth7\0')
        fake.bind.assert_called_once_with(('192.168.2.1', 80))
        fake.reset_mock()
        fake.setsockopt.side_effect = OSError('denied')
        with self.assertRaises(OSError): m.bound_socket(socket.AF_INET, 'eth7', '192.168.2.1', 80, lambda *a: fake)
        fake.bind.assert_not_called()
        fake.close.assert_called_once()

    def test_ipv6_only(self):
        fake = Mock()
        m.bound_socket(socket.AF_INET6, 'eth7', 'fe80::1', 80, lambda *a: fake, 7)
        fake.setsockopt.assert_any_call(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        fake.bind.assert_called_once_with(('fe80::1', 80, 0, 7))

    def test_overflow_fences_before_resync(self):
        front = m.FrontDoor([])
        front.monitor.close()
        front.monitor = Mock()
        front.monitor.recvmsg.side_effect = OSError(errno.ENOBUFS, 'overflow')
        writer = Mock()
        front.state.writers.add(writer)
        front.schedule = Mock()
        front.event()
        writer.close.assert_called_once()
        front.schedule.assert_called_once()
        self.assertFalse(front.state.writers)

    def test_all_events_close_generations(self):
        state = m.Generation()
        writer = Mock()
        listener = Mock()
        state.writers.add(writer)
        state.listeners.append(listener)
        old = state.number
        state.invalidate()
        writer.close.assert_called_once()
        listener.close.assert_called_once()
        self.assertGreater(state.number, old)
        self.assertFalse(state.writers)
        # Removal and readdition, rename, mask/type change and overflow all use
        # this same unconditional fence, even with an identical next snapshot.
        state.invalidate()
        self.assertEqual(state.number, old + 2)


class Transport(unittest.IsolatedAsyncioTestCase):
    async def test_event_loss_retires_all_before_identical_snapshot(self):
        # The remove/readd events were lost: the replacement dump is identical.
        snapshot = b'[{"ifname":"eth7","ifindex":7,"link_type":"ether","flags":["UP"],"addr_info":[{"family":"inet","local":"192.168.2.1","prefixlen":24}]}]'
        for loss in (OSError(errno.ENOBUFS, 'overflow'),
                     (b'lost', [], socket.MSG_TRUNC, None),
                     (b'\x10\x00\x00\x00\x04\x00' + b'\0' * 10, [], 0, None),
                     (b'\x10\x00\x00\x00\x03\x00\x10\x00' + b'\0' * 8, [], 0, None)):
            with self.subTest(loss=loss):
                front = m.FrontDoor([])
                front.monitor.close()
                old_monitor, fresh_monitor = Mock(), Mock()
                front.monitor = old_monitor
                front.loop = Mock()
                old_monitor.recvmsg.side_effect = [loss] if isinstance(loss, OSError) else [loss, BlockingIOError()]
                fresh_monitor.recvmsg.side_effect = BlockingIOError()
                front.trusted_ready = True
                old_client, old_backend = Mock(), Mock()
                front.state.writers.update((old_client, old_backend))
                front.schedule = Mock()
                try:
                    front.event()
                    old_client.close.assert_called_once()
                    old_backend.close.assert_called_once()
                    self.assertFalse(front.trusted_ready)
                    generation = front.state.number
                    def dump(*args, **kwargs):
                        # A new subscription must exist before taking the dump.
                        fresh_monitor.bind.assert_called_once_with((0, 1 | 0x10 | 0x100))
                        self.assertIs(front.monitor, fresh_monitor)
                        return snapshot
                    with patch.object(m.socket, 'socket', return_value=fresh_monitor), patch.object(m.subprocess, 'check_output', side_effect=dump):
                        await front.reconcile()
                    old_monitor.close.assert_called_once()
                    front.loop.remove_reader.assert_called_once_with(old_monitor)
                    front.loop.add_reader.assert_called_once_with(fresh_monitor, front.event)
                    self.assertTrue(front.trusted_ready)
                    self.assertGreater(front.state.number, generation)
                    self.assertFalse(front.state.writers)
                    # Recovery cannot revive either side of the old grant path.
                    old_client.close.assert_called_once()
                    old_backend.close.assert_called_once()
                finally:
                    front.event_fence()
                    front.monitor.close()

    async def test_real_unix_and_ordinary_paths(self):
        received = []
        release = asyncio.Event()
        async def backend(reader, writer):
            raw = await reader.readuntil(b"\r\n\r\n")
            received.append(raw)
            if raw.startswith(b'POST '):
                body = await reader.readexactly(4)
                writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n' + body)
                await writer.drain()
                writer.close()
                return
            writer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            await writer.drain()
            await release.wait()
            writer.close()
        with tempfile.TemporaryDirectory() as directory:
            path = directory + '/rpc.sock'
            unix = await asyncio.start_unix_server(backend, path)
            ordinary = await asyncio.start_server(backend, '127.0.0.1', 0)
            front = m.FrontDoor([])
            front.trusted_ready = True
            front.unix_path = path
            front.backend_address = ordinary.sockets[0].getsockname()[:2]
            class Arrival:
                def __init__(self, writer): self.writer = writer
                def get_extra_info(self, name):
                    if name == 'peername': return ('192.168.2.4', 32000)
                    if name == 'sockname': return ('192.168.2.1', 80)
                    return self.writer.get_extra_info(name)
                def __getattr__(self, name): return getattr(self.writer, name)
            server = await asyncio.start_server(lambda r,w: front.accept(r, Arrival(w), 'eth7', '192.168.2.1/24', True, front.state.number), '127.0.0.1', 0)
            clients = []
            readers = []
            try:
                for extra in [b'', b'Forwarded:\r\n', b'X-Ceralive-Button-Path: forged\r\n', b'Via:\r\n']:
                    r, w = await asyncio.open_connection(*server.sockets[0].getsockname()[:2])
                    clients.append(w)
                    readers.append(r)
                    w.write(b'GET /ws HTTP/1.1\r\nHost: box.local\r\nOrigin: http://box.local\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' + extra + b'\r\n')
                    await w.drain()
                    await asyncio.wait_for(r.readuntil(b'\r\n\r\n'), 2)
                post_reader, post_writer = await asyncio.open_connection(*server.sockets[0].getsockname()[:2])
                clients.append(post_writer)
                post_writer.write(b'POST /api HTTP/1.1\r\nHost: box.local\r\nContent-Length: 4\r\n\r\ndata')
                await post_writer.drain()
                self.assertTrue((await asyncio.wait_for(post_reader.read(), 2)).endswith(b'data'))
                self.assertIn(b'"interface":"eth7"', received[0])
                self.assertIn(b'Origin: http://box.local', received[0])
                self.assertNotIn(b'X-Ceralive-Button-Path:', received[1])
                self.assertIn(b'X-Ceralive-Button-Path: forged', received[2])
                self.assertIn(b'Via:', received[3])
                # Lose a remove/readd interval, then recover the exact same
                # address/mask. Old upgraded Unix/TCP sessions must stay dead.
                front.monitor.close()
                front.monitor = Mock()
                front.monitor.recvmsg.side_effect = OSError(errno.ENOBUFS, 'overflow')
                front.schedule = Mock()
                front.event()
                fresh = Mock()
                fresh.recvmsg.side_effect = BlockingIOError()
                snapshot = b'[{"ifname":"eth7","ifindex":7,"addr_info":[{"family":"inet","local":"192.168.2.1","prefixlen":24}]}]'
                with patch.object(m.socket, 'socket', return_value=fresh), patch.object(m.subprocess, 'check_output', return_value=snapshot):
                    await front.reconcile()
                self.assertTrue(front.trusted_ready)
                for r in readers:
                    self.assertEqual(await asyncio.wait_for(r.read(), 2), b'')
                for w in clients: w.close()
                release.set()
                await asyncio.gather(*tuple(front.tasks), return_exceptions=True)
            finally:
                release.set()
                front.event_fence()
                front.monitor.close()
                for service in (server, unix, ordinary):
                    service.close()
                    await service.wait_closed()

if __name__ == '__main__': unittest.main()
