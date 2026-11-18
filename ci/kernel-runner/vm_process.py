"""Cooperative signal handling and bounded waits for launcher-owned children."""

from __future__ import annotations

import os
from pathlib import Path
import selectors
import subprocess
import time

POLL_SECONDS = 1
TERM_GRACE_SECONDS = 20


class Cancelled(RuntimeError):
    """The launcher was asked to stop."""


class Cancellation:
    """A one-way flag set by the main thread's signal handler."""

    requested = False
    committed_exit: int | None = None

    def request(self, _signum: int, _frame) -> None:
        self.requested = True

    def check(self) -> None:
        if self.requested:
            raise Cancelled("runner cancelled")


def read_check_script(path: Path, cancellation: Cancellation) -> bytes:
    """Read a regular file or FIFO without blocking cancellation on a FIFO writer."""
    chunks = bytearray()
    cancellation.check()
    with open(path, "rb", opener=lambda name, flags: os.open(name, flags | os.O_NONBLOCK)) as source, \
            selectors.PollSelector() as events:
        fd = source.fileno()
        events.register(fd, selectors.EVENT_READ)
        while True:
            cancellation.check()
            try:
                # Wait first on Linux: a FIFO with no writer yet returns false EOF on read.
                if not events.select(timeout=POLL_SECONDS):
                    continue
                cancellation.check()
                chunk = os.read(fd, 1024 * 1024)
            except (BlockingIOError, InterruptedError):
                continue
            if not chunk:
                return bytes(chunks)
            chunks.extend(chunk)


def wait(process: subprocess.Popen, deadline: float | None,
         cancellation: Cancellation | None = None) -> None:
    """Retry interruptions without restarting the deadline or losing cancellation."""
    while True:
        if cancellation is not None:
            cancellation.check()
        try:
            if process.poll() is not None:
                return
            remaining = POLL_SECONDS if deadline is None else deadline - time.monotonic()
            if remaining <= 0:
                break
            process.wait(timeout=min(POLL_SECONDS, remaining))
        except (InterruptedError, subprocess.TimeoutExpired):
            continue
    raise subprocess.TimeoutExpired(process.args, 0)


def terminate(process: subprocess.Popen) -> None:
    """Stop only the owned child, without allowing another signal to abort reaping."""
    if process.poll() is None:
        process.terminate()
        try:
            wait(process, time.monotonic() + TERM_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            process.kill()
            wait(process, None)


def run(args: list[str], *, timeout: int, cancellation: Cancellation,
        capture_output: bool = False, **options) -> subprocess.CompletedProcess:
    """Like run(check=True), with cancellation checks during helper subprocesses."""
    cancellation.check()
    if capture_output:
        options.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + timeout
    with subprocess.Popen(args, **options) as process:
        try:
            while True:
                cancellation.check()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(args, timeout)
                try:
                    stdout, stderr = process.communicate(timeout=min(POLL_SECONDS, remaining))
                    break
                except (InterruptedError, subprocess.TimeoutExpired):
                    continue
        finally:
            terminate(process)
    cancellation.check()
    result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    result.check_returncode()
    return result
