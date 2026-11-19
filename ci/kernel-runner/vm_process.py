"""Cooperative signal handling and bounded waits for launcher-owned children."""

from __future__ import annotations

from contextlib import ExitStack, contextmanager
import errno
from io import FileIO
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time
from typing import Callable

POLL_SECONDS = 1
TERM_GRACE_SECONDS = 20
CATCHABLE_SIGNALS = signal.valid_signals() - {signal.SIGKILL, signal.SIGSTOP}
STOP_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
CHILD_CWD = "/"
CHILD_LOCALE = "C.UTF-8"


def close_transport(release: Callable[[], None], on_loss: Callable[[], None] | None = None,
                    attempt: Callable[[], None] | None = None) -> None:
    """Isolate optional close faults and retry only through the same idempotent owner."""
    try:
        (attempt or release)()
    except Exception:
        if on_loss is None:
            raise
        on_loss()
        try:
            release()
        except Exception:
            on_loss()


def register_close(stack: ExitStack, role: str, release: Callable[[], None],
                   on_loss: Callable[[], None] | None = None,
                   attempt: Callable[[], None] | None = None,
                   before_close: Callable[[], None] | None = None, *,
                   close_on_error: bool = True) -> None:
    """Keep the owner's role and failure policy together in the cleanup stack."""
    def retire(_role: str) -> None:
        try:
            if before_close is not None:
                before_close()
        finally:
            close_transport(release, on_loss, attempt)

    try:
        stack.callback(retire, role)
    except (MemoryError, OSError):
        if close_on_error:
            close_transport(release, on_loss)
        raise


def open_pidfd(process: subprocess.Popen) -> FileIO:
    return FileIO("/dev/null", "rb", opener=lambda _path, _flags: os.pidfd_open(process.pid))


def ignore_cleanup_failure() -> None:
    """A process handle is disposable once the kernel wait status is known."""


class Cancelled(RuntimeError):
    """The launcher was asked to stop."""


class ChildStatusError(RuntimeError):
    """The kernel did not give the launcher its owned child's exit status."""


class ChildSetupError(RuntimeError):
    """A spawned child could not be registered for I/O."""


class Cancellation:
    """A one-way flag set by the main thread's signal handler."""

    requested = False
    exit_receipt: Path | None = None
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


def register_child_pipes(stack: ExitStack, process: subprocess.Popen) -> None:
    for role, pipe in (("child-stdin", process.stdin), ("child-stdout", process.stdout),
                       ("child-stderr", process.stderr)):
        if pipe is not None:
            register_close(stack, role, pipe.close)


@contextmanager
def spawn_owned(args: list[str], *, cancellation: Cancellation, registration: bool = False,
                on_reaped: Callable[[int], None] | None = None,
                on_loss: Callable[[], None] | None = None,
                after_reap: Callable[[], None] | None = None, **options):
    """Own every host spawn before registering its pipes or optional pidfd."""
    children: list[subprocess.Popen] = []
    process = handle = None
    handle_registered = False
    check_spawn_signals(cancellation)
    with ExitStack() as pipes, ExitStack() as handles:
        try:
            try:
                process = subprocess.Popen(args, restore_signals=True, cwd=CHILD_CWD,
                                           env=child_environment(registration=registration), **options)
                children.append(process)
                register_child_pipes(pipes, process)
            except (MemoryError, OSError) as error:
                if process is None:
                    raise
                raise ChildSetupError(f"cannot register child {args[0]}") from error
            if on_loss is not None:
                try:
                    handle = open_pidfd(process)
                    register_close(handles, "qemu-pidfd", handle.close, on_loss, close_on_error=False)
                    handle_registered = True
                except (OSError, MemoryError):
                    on_loss()
            yield process
        finally:
            if process is not None:
                try:
                    # The local still owns the child if appending it failed.
                    try:
                        terminate(children.pop() if children else process, handle, on_reaped)
                    finally:
                        if after_reap is not None:
                            after_reap()
                finally:
                    try:
                        if handle is not None and not handle_registered:
                            close_transport(handle.close, on_loss)
                    finally:
                        try:
                            pipes.close()
                        finally:
                            for pipe in (process.stdin, process.stdout, process.stderr):
                                if pipe is not None and not pipe.closed:
                                    close_transport(pipe.close, ignore_cleanup_failure)


def poll_owned(process: subprocess.Popen, on_reaped: Callable[[int], None] | None = None) -> int | None:
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
        if on_reaped is not None:
            on_reaped(process.returncode)
    return process.returncode


def read_check_script(path: Path, cancellation: Cancellation) -> bytes:
    """Read a regular file or FIFO without blocking cancellation on a FIFO writer."""
    chunks = bytearray()
    cancellation.check()
    with ExitStack() as owners:
        source = open(path, "rb", opener=lambda name, flags: os.open(name, flags | os.O_NONBLOCK))
        register_close(owners, "check-script", source.close)
        events = selectors.PollSelector()
        register_close(owners, "check-selector", events.close)
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
         cancellation: Cancellation | None = None,
         on_reaped: Callable[[int], None] | None = None) -> None:
    """Retry interruptions without restarting the deadline or losing cancellation."""
    delay = 0.001
    while True:
        if cancellation is not None:
            cancellation.check()
        if poll_owned(process, on_reaped) is not None:
            return
        remaining = POLL_SECONDS if deadline is None else deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(delay, remaining))
        delay = min(delay * 2, 0.05)
    raise subprocess.TimeoutExpired(process.args, 0)


def terminate(process: subprocess.Popen, handle: FileIO | None = None,
              on_reaped: Callable[[int], None] | None = None) -> None:
    """Stop only the owned child, without allowing another signal to abort reaping."""
    if poll_owned(process, on_reaped) is not None:
        return
    with ExitStack() as handles:
        if handle is None:
            try:
                candidate = open_pidfd(process)
                register_close(handles, "termination-pidfd", candidate.close, ignore_cleanup_failure)
                handle = candidate
            except (OSError, MemoryError):
                pass  # Signal the still-owned, unreaped child below.
        signal_owned(process, handle, signal.SIGTERM)
        try:
            wait(process, time.monotonic() + TERM_GRACE_SECONDS, on_reaped=on_reaped)
        except subprocess.TimeoutExpired:
            signal_owned(process, handle, signal.SIGKILL)
            wait(process, None, on_reaped=on_reaped)


def signal_owned(process: subprocess.Popen, handle: FileIO | None, signum: signal.Signals) -> None:
    """Use a PID only while this launcher still owns its wait status."""
    if handle is not None and not handle.closed:
        try:
            signal.pidfd_send_signal(handle.fileno(), signum)
        except OSError as error:
            if error.errno == errno.ESRCH:
                return
        except MemoryError:
            pass
        else:
            return
    try:
        # A child which exits here keeps its PID until our wait collects it.
        os.kill(process.pid, signum)
    except ProcessLookupError:
        pass


def run(args: list[str], *, timeout: int, cancellation: Cancellation,
        capture_output: bool = False, registration: bool = False, **options) -> subprocess.CompletedProcess:
    """Like run(check=True), with cancellation checks during helper subprocesses."""
    if capture_output:
        options.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + timeout
    with spawn_owned(args, cancellation=cancellation, registration=registration, **options) as process:
        with ExitStack() as owners:
            try:
                output = [bytearray(), bytearray()]
                events = selectors.PollSelector()
                register_close(owners, "helper-selector", events.close)
                if capture_output:
                    events.register(process.stdout, selectors.EVENT_READ, 0)
                    events.register(process.stderr, selectors.EVENT_READ, 1)
            except (MemoryError, OSError) as error:
                raise ChildSetupError(f"cannot register helper output {args[0]}") from error
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
    cancellation.check()
    stdout, stderr = map(bytes, output) if capture_output else (None, None)
    result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    result.check_returncode()
    return result
