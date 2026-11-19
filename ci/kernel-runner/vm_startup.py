"""Normalize and verify the initial state of the single-threaded Linux launcher."""

from __future__ import annotations

import errno
import os
from pathlib import Path
import signal
import sys

from image_stream import list_directory, read_check_text, retry_check
from vm_process import CATCHABLE_SIGNALS, STOP_SIGNALS, Cancellation

STARTUP_ERROR = 78
DEFAULT_SIGNALS = (
    signal.SIGCHLD, signal.SIGALRM, signal.SIGVTALRM, signal.SIGPROF,
    signal.SIGQUIT, signal.SIGUSR1, signal.SIGUSR2,
)
# Keep CPython's write-error behavior in the launcher. Popen restores these at exec.
PYTHON_IGNORES = tuple(getattr(signal, name) for name in ("SIGPIPE", "SIGXFSZ", "SIGXFZ")
                       if hasattr(signal, name))
TIMERS = (signal.ITIMER_REAL, signal.ITIMER_VIRTUAL, signal.ITIMER_PROF)
PRIVATE_UMASK = 0o077


class StartupError(Exception):
    """The launcher could not establish its startup baseline."""


def fd_table() -> set[int]:
    return {int(name) for name in retry_check(
        lambda: list_directory(Path("/proc/self/fd"), omit_open_fd=True))}


def ensure_standard_fds() -> None:
    for fd, flag in enumerate((os.O_RDONLY, os.O_WRONLY, os.O_WRONLY)):
        try:
            os.fstat(fd)
        except OSError as error:
            if error.errno != errno.EBADF:
                raise
            opened = os.open(os.devnull, flag)
            if opened != fd:
                try:
                    os.dup2(opened, fd)
                finally:
                    os.close(opened)
        os.set_inheritable(fd, True)

    for fd, name, mode in ((0, "stdin", "r"), (1, "stdout", "w"), (2, "stderr", "w")):
        if getattr(sys, name) is None:
            setattr(sys, name, open(fd, mode, closefd=False, encoding="utf-8"))


def verify_startup(checks: dict[str, bool]) -> None:
    for baseline, established in checks.items():
        if not established:
            raise StartupError(f"could not establish {baseline}")


def sanitize_startup(cancellation: Cancellation) -> list[str]:
    """Run before admission, I/O on caller paths, or spawning any child."""
    inherited = signal.pthread_sigmask(signal.SIG_BLOCK, CATCHABLE_SIGNALS)
    signal.alarm(0)
    for timer in TIMERS:
        signal.setitimer(timer, 0, 0)
    # An alarm already queued before disarming the timers must not survive unmasking.
    alarms = {signal.SIGALRM, signal.SIGVTALRM, signal.SIGPROF}
    for pending in signal.sigpending().intersection(alarms):
        signal.sigwait({pending})

    ignored = [sig.name for sig in (*STOP_SIGNALS, *DEFAULT_SIGNALS)
               if signal.getsignal(sig) == signal.SIG_IGN]
    handlers = {sig: signal.SIG_DFL for sig in DEFAULT_SIGNALS}
    handlers.update({sig: signal.SIG_IGN for sig in PYTHON_IGNORES})
    handlers.update({sig: cancellation.request for sig in STOP_SIGNALS})
    for sig, handler in handlers.items():
        signal.signal(sig, handler)

    ensure_standard_fds()
    for fd in sorted(fd_table() - {0, 1, 2}):
        os.close(fd)
    os.umask(PRIVATE_UMASK)

    pending_other = signal.sigpending() - {*STOP_SIGNALS, *PYTHON_IGNORES, signal.SIGCHLD}
    if pending_other:
        raise StartupError(f"unexpected pending signals: {sorted(map(int, pending_other))}")

    # Handlers and descriptors are ready before a pending cancellation is delivered.
    # Child tooling receives a fixed cwd and locale. Preserve the caller's cwd
    # for interpreting relative CLI paths, but refuse a deleted cwd.
    os.getcwd()
    signal.pthread_sigmask(signal.SIG_SETMASK, set())
    status = dict(line.split(":", 1) for line in retry_check(read_check_text, Path("/proc/self/status")).splitlines()
                  if ":" in line)
    tracked = sum(1 << (sig - 1) for sig in handlers)
    expected_ignored = sum(1 << (sig - 1) for sig in PYTHON_IGNORES)
    expected_caught = sum(1 << (sig - 1) for sig in STOP_SIGNALS)
    verify_startup({
        "standard descriptors": all(os.get_inheritable(fd) for fd in range(3)),
        "no inherited extra descriptors": fd_table() == {0, 1, 2},
        "disarmed timers": all(signal.getitimer(timer) == (0, 0) for timer in TIMERS),
        "signal dispositions": (all(signal.getsignal(sig) == handler for sig, handler in handlers.items())
                                and int(status["SigIgn"], 16) & tracked == expected_ignored
                                and int(status["SigCgt"], 16) & tracked == expected_caught),
        "empty signal mask": not int(status["SigBlk"], 16) and not signal.pthread_sigmask(signal.SIG_BLOCK, set()),
        "private umask": int(status["Umask"], 8) == PRIVATE_UMASK,
    })

    changes = []
    if inherited:
        changes.append(f"cleared inherited signal mask: {sorted(map(int, inherited))}")
    stop_ignored = [name for name in ignored if name in {sig.name for sig in STOP_SIGNALS}]
    if stop_ignored:
        changes.append(f"replaced inherited ignored stop signals: {', '.join(stop_ignored)}")
    return changes
