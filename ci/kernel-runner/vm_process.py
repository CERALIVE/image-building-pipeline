"""Cooperative signal handling and bounded waits for launcher-owned children."""

from __future__ import annotations

from contextlib import ExitStack, contextmanager
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time

POLL_SECONDS = 1
TERM_GRACE_SECONDS = 20
CATCHABLE_SIGNALS = signal.valid_signals() - {signal.SIGKILL, signal.SIGSTOP}
STOP_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
CHILD_CWD = "/"
CHILD_LOCALE = "C.UTF-8"


class Cancelled(RuntimeError):
    """The launcher was asked to stop."""


class ChildStatusError(RuntimeError):
    """The kernel did not give the launcher its owned child's exit status."""


class Cancellation:
    """A one-way flag set by the main thread's signal handler."""

    requested = False
    exit_receipt: Path | None = None
    committed_exit: int | None = None
    safe_journal: Path | None = None
    finalizing = False

    def request(self, _signum: int, _frame) -> None:
        self.requested = True

    def check(self) -> None:
        if self.requested:
            raise Cancelled("runner cancelled")

    def begin_finalization(self) -> None:
        """Enter the single-threaded image CLI's terminal section until os._exit."""
        if not self.finalizing:
            signal.pthread_sigmask(signal.SIG_BLOCK, CATCHABLE_SIGNALS)
            self.finalizing = True


def check_spawn_signals(cancellation: Cancellation) -> None:
    """Allow exec to inherit a clean mask and reset caught stop dispositions."""
    if cancellation.finalizing:
        raise RuntimeError("cannot spawn a child during terminal finalization")
    cancellation.check()
    if (signal.pthread_sigmask(signal.SIG_BLOCK, set())
            or any(signal.getsignal(sig) == signal.SIG_IGN for sig in STOP_SIGNALS)):
        raise RuntimeError("cannot spawn a child with blocked signals or ignored stop signals")


def child_environment(*, registration: bool = False) -> dict[str, str]:
    """Keep host configuration only for the explicit runner-registration command."""
    environment = {key: value for key, value in os.environ.items()
                   if key != "LANGUAGE" and not key.startswith("LC_")} if registration else {}
    # Preserve the configured search path, including caller-relative entries.
    path = os.environ.get("PATH", os.defpath)
    environment.update(PATH=os.pathsep.join(os.path.abspath(entry) for entry in path.split(os.pathsep)),
                       LANG=CHILD_LOCALE)
    return environment


@contextmanager
def child_pipes(process: subprocess.Popen):
    """Close Popen's pipes without its context manager's implicit wait."""
    with ExitStack() as stack:
        for pipe in (process.stdin, process.stdout, process.stderr):
            if pipe is not None:
                stack.callback(pipe.close)
        yield process


def poll_owned(process: subprocess.Popen) -> int | None:
    """Collect an actual wait status. ECHILD cannot be reported as exit zero."""
    if process.returncode is None:
        while True:
            try:
                pid, status = os.waitpid(process.pid, os.WNOHANG)
                break
            except InterruptedError:
                continue
            except ChildProcessError as error:
                raise ChildStatusError(f"exit status unavailable for owned child PID {process.pid}") from error
        if pid == 0:
            return None
        if pid != process.pid or not (os.WIFEXITED(status) or os.WIFSIGNALED(status)):
            raise ChildStatusError(f"invalid exit status for owned child PID {process.pid}")
        process.returncode = os.waitstatus_to_exitcode(status)
    return process.returncode


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
    delay = 0.001
    while True:
        if cancellation is not None:
            cancellation.check()
        if poll_owned(process) is not None:
            return
        remaining = POLL_SECONDS if deadline is None else deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(delay, remaining))
        delay = min(delay * 2, 0.05)
    raise subprocess.TimeoutExpired(process.args, 0)


def terminate(process: subprocess.Popen) -> None:
    """Stop only the owned child, without allowing another signal to abort reaping."""
    if poll_owned(process) is not None:
        return
    pidfd = os.pidfd_open(process.pid)
    try:
        if poll_owned(process) is not None:
            return
        try:
            signal.pidfd_send_signal(pidfd, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            wait(process, time.monotonic() + TERM_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            try:
                signal.pidfd_send_signal(pidfd, signal.SIGKILL)
            except ProcessLookupError:
                pass
            wait(process, None)
    finally:
        os.close(pidfd)


def run(args: list[str], *, timeout: int, cancellation: Cancellation,
        capture_output: bool = False, registration: bool = False, **options) -> subprocess.CompletedProcess:
    """Like run(check=True), with cancellation checks during helper subprocesses."""
    check_spawn_signals(cancellation)
    if capture_output:
        options.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + timeout
    process = subprocess.Popen(args, restore_signals=True, cwd=CHILD_CWD,
                               env=child_environment(registration=registration), **options)
    with child_pipes(process):
        output = [bytearray(), bytearray()]
        try:
            with selectors.PollSelector() as events:
                if capture_output:
                    events.register(process.stdout, selectors.EVENT_READ, 0)
                    events.register(process.stderr, selectors.EVENT_READ, 1)
                while events.get_map():
                    cancellation.check()
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(args, timeout)
                    try:
                        for key, _ in events.select(timeout=min(POLL_SECONDS, remaining)):
                            cancellation.check()
                            data = os.read(key.fd, 65536)
                            if data:
                                output[key.data].extend(data)
                            else:
                                events.unregister(key.fileobj)
                    except InterruptedError:
                        continue
            wait(process, deadline, cancellation)
        finally:
            terminate(process)
    cancellation.check()
    stdout, stderr = map(bytes, output) if capture_output else (None, None)
    result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    result.check_returncode()
    return result
