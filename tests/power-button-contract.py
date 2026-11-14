"""Hardware-free production decoder, gesture and Unix socket contracts."""
import importlib.util
import inspect
import multiprocessing
import os
from pathlib import Path
import socket
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('button', ROOT / 'mkosi/runtime/power-button/button.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class Gestures(unittest.TestCase):
    def setUp(self):
        self.lights, self.off, self.replies = [], [], []
        self.g = b.Gestures(lambda *x: self.lights.append(x), lambda: self.off.append(True))

    def tap(self, now):
        self.g.key(1, now)
        self.g.key(0, now + .05)

    def test_releasable_inhibitor_child(self):
        spawn = b.subprocess.Popen
        commands = []
        def fake_inhibit(command, **kwargs):
            commands.append(command)
            return spawn(command[-3:], **kwargs)
        with patch.object(b.subprocess, 'Popen', fake_inhibit):
            ownership = b.PowerKeyOwnership()
        self.assertIn('--what=handle-power-key', commands[0])
        self.assertIsNone(ownership.process.poll())
        ownership.release()
        self.assertEqual(ownership.process.poll(), 0)
        ownership.release()  # idempotent shutdown/failure cleanup

    def test_taps(self):
        for live in (False, True):
            self.g.live = live
            self.tap(0)
            self.tap(.2)
            self.g.tick(20)
        self.assertFalse(self.off)
        self.assertEqual(len([x for x in self.lights if x[0] == 'status']), 4)

    def test_confirm(self):
        self.assertTrue(self.g.request_confirm(0, 10, self.replies.append))
        self.assertFalse(self.g.request_confirm(0, 10, self.replies.append))
        self.tap(1)
        self.tap(1.2)
        self.tap(1.3)
        self.tap(1.4)
        self.assertEqual(self.replies, ['CONFIRMED'])
        self.assertFalse(self.off)

    def test_windows(self):
        self.tap(0)  # tap before request cannot count
        self.g.request_confirm(.1, 1, self.replies.append)
        self.tap(.2)
        self.assertEqual(self.replies, [])
        self.tap(.7)  # too late to be a double press
        self.assertEqual(self.replies, [])
        self.g.tick(1.1)
        self.tap(1.2)
        self.assertEqual(self.replies, ['TIMEOUT'])
        self.g.request_confirm(2, 1, self.replies.append)
        self.g.drop_request()
        self.tap(2.1)
        self.tap(2.2)
        self.assertEqual(self.replies, ['TIMEOUT'])

    def test_holds(self):
        for live in (False, True):
            self.setUp()
            self.g.live = live
            for duration in (.5, 1, 2.999):
                self.g.key(1, 0)
                self.g.tick(duration)
                self.g.key(0, duration)
                self.g.tick(12)
                self.assertFalse(self.off)
            self.g.key(1, 20)
            self.g.tick(22.999)
            self.assertFalse(self.off)
            self.g.tick(23)
            self.g.tick(30)
            self.g.key(0, 31)
            self.assertEqual(self.off, [True])
            self.assertIn(('countdown', 3), self.lights)
            self.assertIn(('cancel', 0), self.lights)

    def test_decoder(self):
        decoder = b.Input(self.g)
        def ev(kind, code, value):
            return b.EVENT.pack(0, 0, kind, code, value)
        data = ev(1, 116, 1)
        decoder.feed(data[:7], 0)
        self.assertIsNone(self.g.down)
        decoder.feed(data[7:], 0)
        decoder.feed(ev(1, 116, 2) + ev(1, 30, 0), 1)
        self.assertEqual(self.g.down, 0)
        decoder.feed(ev(0, 3, 0), 2)  # dropped events cancel hold
        decoder.feed(ev(0, 0, 0) + ev(1, 116, 1), 3)
        self.g.tick(10)
        self.assertFalse(self.off)
        decoder.feed(ev(1, 116, 0), 11)
        decoder.feed(ev(1, 116, 2), 12)
        self.g.tick(20)
        self.assertFalse(self.off)
        decoder.feed(ev(1, 116, 1), 21)
        self.g.tick(24)
        self.assertEqual(self.off, [True])

    def test_queued_events(self):
        decoder = b.Input(self.g, event_clock=True)
        self.g.request_confirm(10, 10, self.replies.append)
        def tap(at):
            for value in (1, 0):
                decoder.feed(b.EVENT.pack(at, 0, 1, 116, value), 15)
        tap(8)
        tap(9)  # old physical events delivered after admission cannot confirm
        self.assertEqual(self.replies, [])
        tap(11)
        tap(12)  # same read time, physically too far apart
        self.assertEqual(self.replies, [])
        decoder.feed(b.EVENT.pack(12, 100000, 1, 116, 1), 15)
        decoder.feed(b.EVENT.pack(12, 150000, 1, 116, 0), 15)
        self.assertEqual(self.replies, ['CONFIRMED'])

    def test_pre_admission_press(self):
        self.g.key(1, 9.9)
        self.g.request_confirm(10, 1, self.replies.append)
        self.g.key(0, 10.01)
        self.tap(10.1)
        self.assertEqual(self.replies, [])
        self.tap(10.3)
        self.assertEqual(self.replies, ['CONFIRMED'])

    def test_delayed_confirmation(self):
        decoder = b.Input(self.g, event_clock=True)
        self.g.request_confirm(10, 1, self.replies.append)
        for at, usec, value in ((10, 100000, 1), (10, 150000, 0),
                                (10, 200000, 1), (10, 250000, 0)):
            decoder.feed(b.EVENT.pack(at, usec, 1, 116, value), 20)
        self.assertEqual(self.replies, ['TIMEOUT'])

    def test_final_confirmation_deadline(self):
        self.g.request_confirm(10, 1, self.replies.append)
        self.tap(10.1)
        self.g.key(1, 10.2)
        # Delivery starts on time but the final status callback crosses expiry.
        self.g.light = lambda *args: None
        with patch.object(b.time, 'monotonic', side_effect=[10.9, 11]):
            kwargs = {}
            if 'current_time' in inspect.signature(self.g.key).parameters:
                kwargs['current_time'] = b.time.monotonic
            self.g.key(0, 10.25, **kwargs)
        self.assertEqual(self.replies, ['TIMEOUT'])


class Socket(unittest.TestCase):
    def run_queued_release(self, pause=False, split=False, state=True, hold=False):
        with tempfile.TemporaryDirectory() as directory:
            fifo, path = directory + '/events', directory + '/control.sock'
            os.mkfifo(fifo)
            writer = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            read_gate, resume, ready, off = [multiprocessing.Event() for _ in range(4)]
            def child():
                original = b.os.read
                first = True
                def read(fd, size):
                    nonlocal first
                    data = original(fd, size)
                    if data and first:
                        first = False
                        read_gate.set()
                        if pause:
                            if not resume.wait(5):
                                raise RuntimeError('test resume deadline')
                    return data
                def light(*args):
                    ready.set()
                with patch.object(b.os, 'read', read):
                    kwargs = {}
                    # The FIFO has no EVIOCGKEY; inject its measured state.
                    if 'key_state' in inspect.signature(b.serve).parameters:
                        kwargs['key_state'] = lambda fd: state
                    b.serve(fifo, path, light, off.set, lambda fd: None, **kwargs)
            process = multiprocessing.get_context('fork').Process(target=child)
            process.start()
            try:
                deadline = time.monotonic() + 3
                while not os.path.exists(path):
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(.01)
                at = time.monotonic() - (3.1 if split or not pause else 0)
                sec = int(at)
                press = b.EVENT.pack(sec, int((at-sec)*1000000), 1, 116, 1)
                release = b.EVENT.pack(sec, int((at-sec)*1000000)+50000, 1, 116, 0)
                if split:
                    # Exactly one read's worth, release starts the next batch.
                    os.write(writer, press + b.EVENT.pack(sec, 0, 1, 30, 0)*63 + release)
                else:
                    os.write(writer, press)
                    self.assertTrue(read_gate.wait(2))
                    if pause:
                        time.sleep(.05)
                        os.write(writer, release)
                        time.sleep(3.1)
                        resume.set()
                self.assertTrue(ready.wait(2))
                self.assertFalse(off.wait(.2), 'short/stale/uncertain hold powered off')
                if not pause and not split:
                    if hold:
                        self.assertTrue(off.wait(3.5), 'continuous observed hold did not fire')
                    else:
                        self.assertFalse(off.wait(3.2), 'released/uncertain key powered off')
                self.assertTrue(process.is_alive())
            finally:
                resume.set()
                process.terminate()
                process.join(3)
                os.close(writer)

    def test_pause_between_read_and_tick(self):
        self.run_queued_release(pause=True)

    def test_split_batches(self):
        self.run_queued_release(split=True)

    def test_current_key_released(self):
        self.run_queued_release(state=False)

    def test_uncertain_key_state(self):
        self.run_queued_release(state=None)

    def test_observed_hold(self):
        self.run_queued_release(hold=True)

    def test_persistent_ioctl_failure_relinquishes_ownership(self):
        with tempfile.TemporaryDirectory() as directory:
            fifo, path = directory + '/events', directory + '/control.sock'
            os.mkfifo(fifo)
            writer = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            released, off = multiprocessing.Event(), multiprocessing.Event()
            def child():
                def broken(fd):
                    raise OSError('input query failed')
                b.serve(fifo, path, lambda *x: None, off.set, lambda fd: None,
                        **({"key_state": broken, "release_ownership": released.set}
                           if "release_ownership" in inspect.signature(b.serve).parameters
                           else {"key_state": broken}))
            process = multiprocessing.get_context('fork').Process(target=child)
            process.start()
            def query(command):
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(2)
                    client.connect(path)
                    client.sendall(command + b'\n')
                    return client.recv(100)
            def edge(value):
                now = time.monotonic()
                sec = int(now)
                os.write(writer, b.EVENT.pack(sec, int((now-sec)*1000000), 1, 116, value))
            try:
                deadline = time.monotonic() + 2
                while not os.path.exists(path) and process.is_alive():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(.01)
                pending = socket.socket(socket.AF_UNIX)
                pending.settimeout(2)
                pending.connect(path)
                pending.sendall(b'CONFIRM 60\n')
                self.assertEqual(pending.recv(100), b'READY\n')
                for _ in range(3):
                    edge(0)
                    time.sleep(.06)
                    edge(1)
                    self.assertFalse(off.wait(3.2))
                self.assertTrue(released.wait(1), 'logind ownership was not released')
                self.assertEqual(pending.recv(100), b'FAILED INPUT\n')
                pending.close()
                self.assertEqual(query(b'STATUS'), b'FAILED INPUT\n')
                self.assertEqual(query(b'CONFIRM 10'), b'FAILED INPUT\n')
                self.assertEqual(query(b'LIVE 1'), b'FAILED INPUT\n')
                edge(0)
                time.sleep(.06)
                edge(1)
                self.assertFalse(off.wait(3.2), 'failed daemon authorized a hold')
                self.assertTrue(process.is_alive())
            finally:
                process.terminate()
                process.join(3)
                os.close(writer)

    def test_socket(self):
        with tempfile.TemporaryDirectory() as directory:
            fifo, path = directory + '/events', directory + '/control.sock'
            os.mkfifo(fifo)
            writer = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            process = multiprocessing.get_context('fork').Process(target=b.serve, args=(fifo, path, lambda *x: None, lambda: None, lambda fd: None))
            process.start()
            clients = []
            def connect(command):
                c = socket.socket(socket.AF_UNIX)
                c.settimeout(2)
                c.connect(path)
                clients.append(c)
                c.sendall(command)
                return c
            def tap():
                for value in (1, 0):
                    now = time.monotonic()
                    sec = int(now)
                    os.write(writer, b.EVENT.pack(sec, int((now - sec) * 1_000_000), 1, 116, value))
            try:
                deadline = time.monotonic() + 3
                while not os.path.exists(path):
                    if time.monotonic() > deadline:
                        self.fail('socket did not start')
                    time.sleep(.01)
                self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
                self.assertEqual(connect(b'LIVE 1\n').recv(100), b'OK\n')
                for command in (b'CONFIRM 0\n', b'CONFIRM 61\n', b'CONFIRM nan\n', b'CONFIRM 1\nLIVE 0\n', b'x' * 81):
                    self.assertEqual(connect(command).recv(100), b'ERROR\n')
                c = connect(b'CONFIRM 10\n')
                self.assertEqual(c.recv(100), b'READY\n')
                self.assertEqual(connect(b'CONFIRM 1\n').recv(100), b'BUSY\n')
                tap()
                time.sleep(.06)
                tap()
                self.assertEqual(c.recv(100), b'CONFIRMED\n')
                self.assertEqual(c.recv(100), b'')
                c = connect(b'CONFIRM 1\n')
                self.assertEqual(c.recv(100), b'READY\n')
                self.assertEqual(c.recv(100), b'TIMEOUT\n')
                c = connect(b'CONFIRM 10\n')
                self.assertEqual(c.recv(100), b'READY\n')
                c.close()
                time.sleep(.06)
                c = connect(b'CONFIRM 1\n')
                self.assertEqual(c.recv(100), b'READY\n')
            finally:
                for c in clients:
                    c.close()
                process.terminate()
                process.join(3)
                os.close(writer)


if __name__ == '__main__':
    unittest.main()
