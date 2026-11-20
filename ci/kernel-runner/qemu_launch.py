"""Host-only launch boundary for the runner and the x86 boot smoke test."""

from collections.abc import Callable
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys

from vm_process import Cancelled, Cancellation, child_environment, spawn_gate, terminate, wait

QEMU_BINARY = "qemu-system-x86_64"


def parent_bound(args: list[str], parent: int) -> list[str]:
    """Arm SIGKILL on parent death, then check the race before exec on the same PID."""
    return ["/usr/bin/setpriv", "--pdeathsig", "KILL", "--", "/bin/sh", "-c",
            'test "$PPID" = "$1" || exit 125; shift; exec "$@"', "runner-child", str(parent), *args]


def require_output(name: str, fd: int) -> None:
    if os.isatty(fd):
        raise RuntimeError(f"refusing QEMU: {name} is a TTY")
    mode = os.fstat(fd).st_mode
    if not (stat.S_ISFIFO(mode) or stat.S_ISREG(mode)):
        raise RuntimeError(f"refusing QEMU: {name} must be a pipe or regular file")


def spawn_qemu(args: list[str], *, serial: int | Path, binary: str = QEMU_BINARY,
               stdin: int | None = subprocess.DEVNULL, stdout: int | None = subprocess.PIPE,
               stderr: int | None = subprocess.PIPE, pass_fds: tuple[int, ...] = (),
               cwd: str | None = None, preexec_fn: Callable[[], None] | None = None) -> subprocess.Popen:
    """Validate the streams before spawning; never attach any guest port to a terminal."""
    if stdin != subprocess.DEVNULL:
        fd = 0 if stdin is None else stdin
        if os.isatty(fd):
            raise RuntimeError("refusing QEMU: stdin is a TTY")
        if stdin is None or not os.path.samestat(os.fstat(fd), os.stat(os.devnull)):
            raise RuntimeError("refusing QEMU: stdin must be /dev/null")
    for name, fd, standard in (("stdout", stdout, 1), ("stderr", stderr, 2)):
        if fd == subprocess.PIPE or (name == "stderr" and fd in (subprocess.STDOUT, subprocess.DEVNULL)):
            continue  # Popen owns the pipe, merges into validated stdout, or discards to /dev/null.
        if fd is None:
            if os.isatty(standard):
                raise RuntimeError(f"refusing QEMU: {name} is a TTY")
            raise RuntimeError(f"refusing QEMU: {name} must be a pipe or regular file owned by the launcher")
        require_output(name, fd)

    if isinstance(serial, Path):
        if not all(stat.S_ISFIFO(Path(f"{serial}{suffix}").lstat().st_mode) for suffix in (".in", ".out")):
            raise RuntimeError("refusing QEMU: serial pipe requires two launcher-owned FIFOs")
        serial_target = f"pipe:{serial}"
    else:
        if serial != 1:
            if serial not in pass_fds or serial < 3:
                raise RuntimeError("refusing QEMU: serial descriptor must be passed by the launcher")
            require_output("serial", serial)
        serial_target = f"file:/proc/self/fd/{serial}"

    argv = [binary, "-display", "none", "-vga", "none", "-monitor", "none",
            "-nodefaults", "-serial", serial_target, *args]
    if preexec_fn is None:
        argv = parent_bound(argv, os.getpid())
    return spawn_gate(argv, stdin=stdin, stdout=stdout, stderr=stderr, start_new_session=True,
                      env=child_environment(), pass_fds=pass_fds, cwd=cwd,
                      preexec_fn=preexec_fn, restore_signals=True)


def smoke_main() -> int:
    binary, fifo, log, *args = sys.argv[1:]
    cancellation = Cancellation()
    for sig in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, cancellation.request)
    with open(log, "wb") as output:
        child = spawn_qemu(args, binary=binary, serial=Path(fifo),
                           stdout=output.fileno(), stderr=subprocess.STDOUT)
        try:
            return wait(child, None, cancellation)
        except Cancelled:
            return 1
        finally:
            terminate(child)


if __name__ == "__main__":
    raise SystemExit(smoke_main())
