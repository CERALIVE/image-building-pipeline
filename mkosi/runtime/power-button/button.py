#!/usr/bin/python3
"""Power-key gestures and a root-only, connection-scoped confirmation socket."""
import fcntl
import glob
import logging
import os
import selectors
import socket
import struct
import subprocess
import sys
import time

EVENT = struct.Struct('@llHHi')  # native Linux input_event (arm64 and amd64)


class Gestures:
    def __init__(self, light, poweroff):
        self.light, self.poweroff = light, poweroff
        self.down = self.tap = self.observed_down = None
        self.fired = False
        self.request = None
        self.live = False

    def cancel(self):
        self.down = self.tap = self.observed_down = None
        self.fired = False
        self.light('cancel', 0)

    def request_confirm(self, now, ttl, reply):
        if self.request:
            return False
        self.tap = None  # never carry a tap across request ownership
        self.request = (now + ttl, reply, now)
        return True

    def drop_request(self):
        self.request = None
        self.tap = None

    def expire(self, now):
        if self.request and now >= self.request[0]:
            reply = self.request[1]
            self.drop_request()
            reply('TIMEOUT')

    def tick(self, now, authorize=lambda: True):
        self.expire(now)
        if self.down is not None and not self.fired:
            elapsed = now - self.observed_down
            self.light('countdown', max(0, 3 - elapsed))
            pressed = self.down
            if elapsed >= 3 and authorize() and self.down == pressed and self.down is not None:
                self.fired = True
                self.tap = None
                self.poweroff()
                self.light('shutdown', 0)

    def key(self, value, now, current_time=None):
        current_time = current_time or (lambda: now)
        self.expire(current_time())
        if value == 1 and self.down is None:
            self.down, self.fired = now, False
            self.observed_down = max(now, current_time())
            self.light('countdown', 3)
        elif value == 0 and self.down is not None:
            pressed = self.down
            duration = now - pressed
            self.down = None
            if self.fired:
                return
            if duration < 0 or duration >= 0.5:
                self.tap = None
                self.light('cancel', 0)
                return
            self.light('status', 0)
            if self.request and self.request[2] <= pressed <= now < self.request[0]:
                if self.tap is not None and 0 <= now - self.tap <= 0.4:
                    self.expire(current_time())  # final decision after callbacks
                    if not self.request:
                        return
                    reply = self.request[1]
                    self.drop_request()  # consume before delivering
                    reply('CONFIRMED')
                    return
                self.tap = now
        # Autorepeat and unmatched releases never start a gesture.


class Input:
    def __init__(self, gestures, event_clock=False):
        self.g = gestures
        self.event_clock = event_clock
        self.buffer = b''
        self.dropped = False

    def feed(self, data, now, current_time=None):
        self.g.expire(now)
        self.buffer += data
        while len(self.buffer) >= EVENT.size:
            sec, usec, kind, code, value = EVENT.unpack(self.buffer[:EVENT.size])
            self.buffer = self.buffer[EVENT.size:]
            if kind == 0 and code == 3:  # SYN_DROPPED: lose the whole gesture
                self.g.cancel()
                self.dropped = True
            elif self.dropped:
                # Require a release after resync; never infer a new press.
                if kind == 1 and code == 116 and value == 0:
                    self.dropped = False
            elif kind == 1 and code == 116:
                self.g.key(value, sec + usec / 1_000_000 if self.event_clock else now, current_time or (lambda: now))


def discover():
    candidates = []
    for name in glob.glob('/sys/class/input/event*/device/name'):
        with open(name, encoding='utf-8') as source:
            if source.read().strip() in ('rk805 pwrkey', 'rk806 pwrkey'):
                candidates.append('/dev/input/' + name.split('/')[4])
    if len(candidates) != 1:
        raise RuntimeError('expected exactly one RK80x power key; configure --device')
    return candidates[0]


def monotonic_input(fd):
    # EVIOCSCLOCKID: use event time for physical gesture windows under load.
    fcntl.ioctl(fd, 0x400445A0, struct.pack("i", time.CLOCK_MONOTONIC))


def power_key_down(fd):
    # EVIOCGKEY: Linux KEY_MAX is 0x2ff, bitmap includes KEY_POWER (116).
    keys = bytearray(96)
    fcntl.ioctl(fd, 0x80604518, keys, True)
    return bool(keys[116 // 8] & (1 << (116 % 8)))


def serve(device, path, light, poweroff, configure_input=monotonic_input,
          key_state=power_key_down, release_ownership=lambda: None):
    g = Gestures(light, poweroff)
    decoder = Input(g, event_clock=True)
    sel = selectors.DefaultSelector()
    # No EVIOCGRAB: logind must still receive events for its fallback policy.
    fd = os.open(device, os.O_RDONLY | os.O_NONBLOCK)
    configure_input(fd)
    sel.register(fd, selectors.EVENT_READ, 'input')
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)  # RuntimeDirectory is removed by systemd on stop.
    os.chmod(path, 0o600)
    server.listen(8)
    server.setblocking(False)
    sel.register(server, selectors.EVENT_READ, 'accept')
    clients = {}
    owner = None
    failures = 0
    failed = False

    def close(client):
        nonlocal owner
        if client is owner:
            g.drop_request()
            owner = None
        sel.unregister(client)
        clients.pop(client)
        client.close()

    def reply(client, message):
        try:
            client.sendall((message + '\n').encode())
        except OSError:
            pass
        close(client)

    def drain():
        # Bound work under a noisy/broken input source; uncertainty denies holds.
        for _ in range(256):
            try:
                data = os.read(fd, EVENT.size * 64)
            except BlockingIOError:
                return not decoder.buffer and not decoder.dropped
            if not data:
                raise RuntimeError('power key disconnected')
            now = time.monotonic()  # read may have been descheduled
            if not failed:
                decoder.feed(data, now, time.monotonic)
        return False

    def authorize_hold():
        nonlocal failures, failed
        if failed:
            return False
        started = time.monotonic()
        try:
            certain = drain() and key_state(fd) is True
            failures = 0
        except OSError:
            failures += 1
            certain = False
            if failures >= 3:
                failed = True
                logging.error('Power-button input failed after %d queries; handing power key back to logind', failures)
                g.cancel()
                if owner:
                    reply(owner, 'FAILED INPUT')
                release_ownership()
                light('failed', 0)
        now = time.monotonic()
        # A pause loses continuity even if a later press is currently down.
        certain = certain and now - last_tick <= .25 and now - started <= .25
        if not certain:
            g.cancel()
            decoder.dropped = True  # require release, then a fresh press
        return certain

    last_tick = time.monotonic()
    try:
        while True:
            for key, _ in sel.select(0.025):
                now = time.monotonic()
                if key.data == 'input':
                    drain()
                elif key.data == 'accept':
                    client, _ = server.accept()
                    client.setblocking(False)
                    if len(clients) >= 32:
                        client.close()
                        continue
                    clients[client] = [b'', now + 5, False]
                    sel.register(client, selectors.EVENT_READ, 'client')
                else:
                    client = key.fileobj
                    try:
                        data = client.recv(256)
                    except OSError:
                        data = b''
                    if not data:
                        close(client)
                        continue
                    state = clients[client]
                    state[0] += data
                    if state[2] or len(state[0]) > 80:
                        reply(client, 'ERROR')
                    elif b'\n' in state[0]:
                        line, rest = state[0].split(b'\n', 1)
                        parts = line.split()
                        if rest:
                            reply(client, 'ERROR')
                        elif line == b'STATUS':
                            reply(client, 'FAILED INPUT' if failed else 'OK')
                        elif failed:
                            reply(client, 'FAILED INPUT')
                        elif len(parts) == 2 and parts[0] == b'CONFIRM' and parts[1].isdigit() and 1 <= int(parts[1]) <= 60:
                            now = time.monotonic()
                            g.expire(now)
                            if g.request_confirm(now, int(parts[1]), lambda msg, c=client: reply(c, msg)):
                                owner = client
                                state[2] = True
                                try:
                                    client.sendall(b'READY\n')
                                except OSError:
                                    close(client)
                            else:
                                reply(client, 'BUSY')
                        elif line in (b'LIVE 0', b'LIVE 1'):
                            g.live = line == b'LIVE 1'
                            reply(client, 'OK')
                        else:
                            reply(client, 'ERROR')
            now = time.monotonic()
            if now - last_tick > .25:
                g.cancel()
                decoder.dropped = True
            if not failed:
                g.tick(now, authorize_hold)
            last_tick = now
            for client, state in list(clients.items()):
                if not state[2] and now >= state[1]:
                    reply(client, 'TIMEOUT')
    finally:
        release_ownership()
        g.cancel()
        for client in list(clients):
            close(client)
        server.close()
        os.close(fd)
        sel.close()
        os.unlink(path)


def light_stub(event, remaining):
    # Deliberately no LED writes until the board-specific light owner is wired.
    if event != 'countdown':
        print('light:', event, flush=True)


class PowerKeyOwnership:
    """Keep the inhibitor in a separate child whose stdin defines its lifetime."""
    def __init__(self):
        self.process = subprocess.Popen([
            '/usr/bin/systemd-inhibit', '--what=handle-power-key',
            '--who=power-button', '--why=gesture-countdown', '--mode=block',
            sys.executable, '-c',
            "import sys; print('READY', flush=True); sys.stdin.buffer.read()",
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        with selectors.DefaultSelector() as ready:
            ready.register(self.process.stdout, selectors.EVENT_READ)
            if not ready.select(5) or self.process.stdout.readline() != b'READY\n':
                self.release()
                raise RuntimeError('could not acquire power-key ownership')

    def release(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=2)
        self.process.stdout.close()


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', help='explicit evdev path; otherwise discover RK80x')
    args = parser.parse_args()
    device = args.device or discover()
    ownership = PowerKeyOwnership()
    try:
        serve(device, '/run/ceralive-button/control.sock', light_stub,
              lambda: subprocess.run(['/usr/bin/systemctl', 'poweroff'], check=True, timeout=10),
              release_ownership=ownership.release)
    finally:
        ownership.release()


if __name__ == '__main__':
    main()
