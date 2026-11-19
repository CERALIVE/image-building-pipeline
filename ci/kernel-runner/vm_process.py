"""Cooperative signal handling and bounded waits for launcher-owned children."""

from __future__ import annotations

from contextlib import ExitStack, contextmanager
import ctypes
import errno
from functools import partial
from io import FileIO
import os
from pathlib import Path
import selectors
import signal
import subprocess
from threading import get_native_id
import time
from typing import Callable

from image_stream import retry_io

POLL_SECONDS = 1
TERM_GRACE_SECONDS = 20
LOST_CHILD_SECONDS = 2
CATCHABLE_SIGNALS = signal.valid_signals() - {signal.SIGKILL, signal.SIGSTOP}
STOP_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
CHILD_CWD = "/"
CHILD_LOCALE = "C.UTF-8"
_SIGNAL_SET = ctypes.c_ulong * (128 // ctypes.sizeof(ctypes.c_ulong))
_SIGPENDING = ctypes.CDLL(None, use_errno=True).sigpending
_SIGPENDING.argtypes = (ctypes.POINTER(_SIGNAL_SET),)
_SIGPENDING.restype = ctypes.c_int
# These Linux signals are all in the first sigset_t word.
_STOP_PENDING = sum(1 << (sig - 1) for sig in STOP_SIGNALS)


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


def ignore_cleanup_failure() -> None:
    """A process handle is disposable once the kernel wait status is known."""


class Cancelled(RuntimeError):
    """The launcher was asked to stop."""


class ChildStatusError(RuntimeError):
    """The kernel did not give the launcher its owned child's exit status."""


class ChildSetupError(RuntimeError):
    """A spawned child could not be registered for I/O."""


class ChildContainmentError(OSError):
    """The launcher cannot verify that a child has stopped."""


WRITE, SYNC, VERIFY, RENAME, COMMITTED, FRESH_REWRITE = range(6)


class ReceiptResult:
    """Preallocated commit result and failure storage."""

    __slots__ = ("state", "first_failure_cause", "failure_errno", "failure_code", "candidate_status", "diagnostic",
                 "sync_done", "retain_journal")

    def __init__(self) -> None:
        self.state = WRITE
        self.first_failure_cause: BaseException | None = None
        self.failure_errno: int | None = None
        self.failure_code = "receipt publication failed"
        self.candidate_status = 1
        self.diagnostic: BaseException | None = None
        self.sync_done = False
        self.retain_journal = False

    @property
    def exit_status(self) -> int:
        return self.candidate_status if self.state == COMMITTED else 1


class Cancellation:
    """Signal state and the authoritative status of a renamed exit receipt."""

    __slots__ = ("requested", "exit_receipt", "exit_temporary", "receipt_result", "exit_sync_calls", "finalizing",
                 "saved_dispositions", "safe_journal", "_pending", "_pending_ref")

    def __init__(self) -> None:
        self.requested = False
        self.exit_receipt: Path | None = None
        self.exit_temporary: Path | None = None
        self.receipt_result = ReceiptResult()
        self.exit_sync_calls = 0
        self.finalizing = False
        self._pending = _SIGNAL_SET()
        self._pending_ref = ctypes.pointer(self._pending)
        self.saved_dispositions: dict[int, signal.Handlers | Callable] = {}
        self.safe_journal: tuple[Path, Path] | None = None

    @property
    def exit_status(self) -> int | None:
        result = self.receipt_result
        return result.exit_status if result.state == COMMITTED else None

    def request(self, _signum: int, _frame) -> None:
        self.requested = True

    def check(self) -> None:
        if self.requested:
            raise Cancelled("runner cancelled")

    def check_commit(self) -> None:
        self.check()
        if _SIGPENDING(self._pending_ref) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        if self._pending[0] & _STOP_PENDING:
            raise Cancelled("runner cancelled")

    def begin_finalization(self) -> bool:
        """Protect the terminal section from all catchable signals until os._exit."""
        if not self.finalizing:
            try:
                retry_io(signal.pthread_sigmask, signal.SIG_BLOCK, CATCHABLE_SIGNALS, recover=True,
                         no_retry=frozenset((errno.ENOSYS,)))
            except OSError:
                try:
                    for signum in sorted(CATCHABLE_SIGNALS):
                        previous = signal.getsignal(signum)
                        if previous is None:
                            raise OSError(errno.EIO, "cannot restore previous signal disposition")
                        self.saved_dispositions[signum] = previous
                        retry_io(signal.signal, signum, signal.SIG_IGN, recover=True)
                except (OSError, ValueError, MemoryError):
                    self.restore_dispositions()
                    raise
            self.finalizing = True
        return not self.saved_dispositions

    def restore_dispositions(self) -> None:
        """Restore the sigaction fallback if control returns without process exit."""
        for signum, previous in self.saved_dispositions.items():
            retry_io(signal.signal, signum, previous, recover=True)
        self.saved_dispositions.clear()


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


def die_with_parent(parent: int) -> None:
    """Bind the launcher to its lock holder."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGKILL, 0, 0, 0):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if os.getppid() != parent:
        os.kill(os.getpid(), signal.SIGKILL)


def retire_lost_child(children: Path, on_reaped: Callable[[int], None] | None) -> None:
    """Kill and collect a child created on the previously empty spawning thread."""
    deadline = time.monotonic() + LOST_CHILD_SECONDS
    try:
        for child in children.read_text().split():
            pid = int(child)
            try:
                if os.getsid(pid) == pid and os.getpgid(pid) == pid:
                    os.killpg(pid, signal.SIGKILL)
                else:
                    # The child may have forked but not reached setsid yet.
                    os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass  # Still collect a zombie if the wait status is available.
            while True:
                try:
                    waited, status = os.waitpid(pid, os.WNOHANG)
                except InterruptedError:
                    waited = 0
                except ChildProcessError:
                    if child not in children.read_text().split():
                        break
                    raise
                if waited:
                    if on_reaped is not None and (os.WIFEXITED(status) or os.WIFSIGNALED(status)):
                        on_reaped(os.waitstatus_to_exitcode(status))
                    break
                if time.monotonic() >= deadline:
                    raise ChildContainmentError(f"child {pid} did not stop within {LOST_CHILD_SECONDS}s")
                time.sleep(0.01)
    except (OSError, MemoryError) as error:
        raise ChildContainmentError("cannot verify failed-spawn child is gone") from error


@contextmanager
def spawn_owned(args: list[str], *, cancellation: Cancellation, registration: bool = False,
                on_reaped: Callable[[int], None] | None = None,
                on_loss: Callable[[], None] | None = None,
                after_reap: Callable[[], None] | None = None, **options):
    """Prepare cleanup before spawn and keep it active from Popen return."""
    process = handle = owners = None
    handle_registered = False

    def release_pipe(name: str) -> None:
        if process is not None and (pipe := getattr(process, name)) is not None:
            close_transport(pipe.close, ignore_cleanup_failure)

    def pidfd_opener(_path: str, _flags: int) -> int:
        assert process is not None
        return os.pidfd_open(process.pid)

    try:
        try:
            owners = ExitStack()
            for name in ("stdin", "stdout", "stderr"):
                register_close(owners, f"child-{name}", partial(release_pipe, name))
            if on_loss is not None:
                try:
                    handle = FileIO.__new__(FileIO)
                    register_close(owners, "qemu-pidfd", handle.close, on_loss)
                    handle_registered = True
                except (OSError, MemoryError):
                    on_loss()
            parent = os.getpid()
            # The shell checks for parent death before setpriv could arm the
            # signal. Both exec in place, so there is only one child and PID.
            command = ["/usr/bin/setpriv", "--pdeathsig", "KILL", "--", "/bin/sh", "-c",
                       'test "$PPID" = "$1" || exit 125; shift; exec "$@"',
                       "runner-child", str(parent), *args]
            environment = child_environment(registration=registration)
            children = Path(f"/proc/self/task/{get_native_id()}/children")
            check_spawn_signals(cancellation)
            if children.read_text().strip():
                raise ChildSetupError("spawning thread already owns a child")
            try:
                process = subprocess.Popen(command, restore_signals=True, cwd=CHILD_CWD,
                                           start_new_session=True, env=environment, **options)
            except (MemoryError, OSError, subprocess.SubprocessError) as error:
                try:
                    retire_lost_child(children, on_reaped)
                finally:
                    # Release any parent-side pipes retained by the failed constructor.
                    error.with_traceback(None)
                raise
            if handle_registered:
                try:
                    handle.__init__("/dev/null", "rb", opener=pidfd_opener)
                except (OSError, MemoryError):
                    on_loss()
        except ChildContainmentError:
            raise
        except (MemoryError, OSError, subprocess.SubprocessError) as error:
            raise ChildSetupError(f"cannot start child {args[0]}") from error.with_traceback(None)
        yield process
    finally:
        try:
            if process is not None:
                try:
                    try:
                        terminate(process, handle, on_reaped)
                    except (OSError, MemoryError, ChildStatusError):
                        retire_lost_child(children, on_reaped)
                        raise
                finally:
                    if after_reap is not None:
                        after_reap()
        finally:
            if owners is not None:
                owners.close()


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
    owners = None
    setup_complete = False
    try:
        if capture_output:
            options.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + timeout
        owners = ExitStack()
        output = [bytearray(), bytearray()]
        events = selectors.PollSelector()
        register_close(owners, "helper-selector", events.close)
        with spawn_owned(args, cancellation=cancellation, registration=registration, **options) as process:
            if capture_output:
                events.register(process.stdout, selectors.EVENT_READ, 0)
                events.register(process.stderr, selectors.EVENT_READ, 1)
            setup_complete = True
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
    except ChildContainmentError:
        raise
    except (MemoryError, OSError) as error:
        if setup_complete:
            raise
        raise ChildSetupError(f"cannot set up helper {args[0]}") from error
    finally:
        if owners is not None:
            owners.close()
    cancellation.check()
    stdout, stderr = map(bytes, output) if capture_output else (None, None)
    result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    result.check_returncode()
    return result
