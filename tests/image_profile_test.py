#!/usr/bin/env python3
"""Run the real launcher lifecycle against small Python children, never a VM.

The AST ownership checks are a best-effort tripwire for known mistakes.
The behavioral fault cases and /proc/self/fd snapshots verify ownership.
"""

import ast
from collections import Counter
from dataclasses import asdict, dataclass, replace
import atexit
from contextlib import ExitStack, contextmanager
import dis
import errno
import fcntl
from functools import partial
import io
import inspect
from itertools import product
import json
import hashlib
import os
import pathlib
import pty
import runpy
import select
import selectors
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import termios
import time
from types import SimpleNamespace
from textwrap import dedent
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ci/kernel-runner"))
import image_lifecycle
import image_resources
import image_vm
import vm_process
import vm_startup
from image_lifecycle import ImageJob, reconcile
from image_stream import MAGIC, UNSUPPORTED_SYNC, Identity, StreamError, decode, encode
import vm
from image_vm import retained_outputs, validate_base
from vm_process import CATCHABLE_SIGNALS, Cancellation, run

IDENTITY = Identity("fixture", "rock-5b-plus", "a" * 40, 1, "b" * 64)
FIXTURE_PRIORITY = {"nice": 9, "ionice": "best-effort: prio 7", "cpu_weight": 10}
SUCCESS_GUEST_MODES = ("receipt", "validation", "committed", "exit-sync-error", "mask-restore-error",
                       "raising-handler", "late-exit", "unreadable-exit", "shutdown-gap")
STAGE_MODES = ("stages:success", "stages:timeout", "stages:logging-error", "stages:at-cap",
               "stages:over-cap", "stages:blocked-header", "stages:guest-loss",
               "stages:priority-timeout", "stages:before-header")
DIAGNOSTIC_ERRORS = {"RuntimeError": RuntimeError, "OSError": OSError, "MemoryError": MemoryError}
SUMMARY_ALLOCATION_SITES = {
    f"{name}-{instruction.offset}": (function.__code__, instruction.offset)
    for name, function in (
        ("summary", ImageJob.diagnostic_summary),
        ("tail", image_lifecycle.StageTail.text),
    )
    for instruction in dis.get_instructions(function)
    if instruction.opname.startswith(("BUILD_", "BINARY_", "CALL"))
}
ENCODE_SITES = {
    instruction.offset
    for instruction in dis.get_instructions(image_lifecycle.encode_diagnostic_fields)
    if instruction.starts_line and instruction.opname != "RESUME"
}
READER_CLEANUP = ImageJob.close_console_reader.__code__
READER_CLEANUP_SITES = tuple(
    instruction.offset for instruction in dis.get_instructions(READER_CLEANUP)
    if instruction.opname != "RESUME"
    and (instruction.starts_line or instruction.opname.startswith("RETURN"))
)
READER_CLEANUP_MODES = tuple(
    f"isolated:reader-cleanup-{site}:{error}"
    for site in READER_CLEANUP_SITES for error in ("MemoryError", "OSError")
)
STDERR_FLOOD_MODES = tuple(f"isolated:sink-{size}-{case}"
                          for size in ("small", "large") for case in ("baseline", "flood", "fault"))
UNREGISTER_MODES = ("isolated:unregister-once:OSError", "isolated:unregister-always:OSError")
CLOSE_FAULTS = [(phase, error) for phase in ("before", "after") for error in ("MemoryError", "OSError")]
PREPARATION_HELPERS = {
    "curl": ["curl"], "convert": ["qemu-img", "convert"], "resize": ["qemu-img", "resize"],
    "xorriso": ["xorriso"], "gh": ["gh"],
}
BACKUP_SELECTOR_CLOSE_MODES = tuple(
    f"isolated:backup-selector-close-{phase}:{error}" for phase, error in CLOSE_FAULTS
)
PRESTART_MODES = tuple(
    f"prestart:{step}:{error}"
    for step in ("pipe", "stream", "console", "console-after-register", "artifact-selector")
    for error in DIAGNOSTIC_ERRORS)
ISOLATION_MODES = ("isolated:baseline", "isolated:complete", "isolated:exclusive", "isolated:gap", "isolated:dropped",
                   *(f"isolated:{step}:{error}" for step in
                     ("read", "close", "StageTail", "observe", "drain", "summary", "text")
                     for error in DIAGNOSTIC_ERRORS),
                   "isolated:summary-timeout:MemoryError", "isolated:fallback:MemoryError",
                   "isolated:read-dispatch:MemoryError", "isolated:unregister:OSError",
                   *UNREGISTER_MODES,
                   *BACKUP_SELECTOR_CLOSE_MODES,
                   *READER_CLEANUP_MODES,
                   *STDERR_FLOOD_MODES,
                   "isolated:encode-empty:MemoryError", "isolated:encode-tail:MemoryError",
                   *(f"isolated:encode-{tail}-{site}:MemoryError"
                     for tail in ("empty", "tail") for site in sorted(ENCODE_SITES)),
                   *(f"isolated:alloc-{site}:MemoryError" for site in SUMMARY_ALLOCATION_SITES))
STARTUP_EXITS = {"success": 0, "failure": 37, "signal": -signal.SIGUSR1,
                 "resistant": -signal.SIGKILL, "cancel": 37}
STARTUP_STATES = {
    "flock": "",
    **{f"blocked-{sig.name}": f"signal.pthread_sigmask(signal.SIG_BLOCK, {{{sig.value}}})"
       for sig in (*vm.STOP_SIGNALS, signal.SIGCHLD, signal.SIGALRM, signal.SIGPIPE,
                   signal.SIGVTALRM, signal.SIGPROF, signal.SIGQUIT, signal.SIGUSR1,
                   signal.SIGUSR2, signal.SIGXFSZ)},
    **{f"ignored-{sig.name}": f"signal.signal({sig.value}, signal.SIG_IGN)"
       for sig in (*vm.STOP_SIGNALS, signal.SIGCHLD, signal.SIGALRM, signal.SIGPIPE,
                   signal.SIGQUIT, signal.SIGUSR1, signal.SIGUSR2, signal.SIGVTALRM,
                   signal.SIGPROF, signal.SIGXFSZ)},
    "alarm": "signal.alarm(1)",
    "itimer-real": "signal.setitimer(signal.ITIMER_REAL, 0.8, 0.1)",
    "itimer-virtual": "signal.setitimer(signal.ITIMER_VIRTUAL, 0.8, 0.1)",
    "itimer-prof": "signal.setitimer(signal.ITIMER_PROF, 0.8, 0.1)",
    "pending-alarm": "signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM}); "
                     "os.kill(os.getpid(), signal.SIGALRM)",
    **{f"closed-{fds}": f"for fd in {tuple(map(int, fds))!r}: os.close(fd)"
       for fds in ("0", "1", "2", "01", "02", "12", "012")},
    "extra-fds": """
extra = os.open(root / "extra", os.O_WRONLY | os.O_CREAT, 0o600)
reader, writer = os.pipe()
os.write(writer, b"unexpected inherited input")
os.dup2(reader, 73, inheritable=True)
os.dup2(extra, 74, inheritable=True)
(root / "pipe-id").write_text(os.readlink("/proc/self/fd/73"))
""",
    "cwd-umask-locale": 'os.chdir(root); os.umask(0o777); os.environ["LANG"] = "invalid"; '
                        'os.environ["LC_ALL"] = "invalid"',
    "no-altstack": "stack = (ctypes.c_void_p * 3)(None, 2, 0); "
                   "assert ctypes.CDLL(None).sigaltstack(ctypes.byref(stack), None) == 0",
}
STARTUP_CHECK_CASES = {
    "standard descriptors": "closed-01",
    "no inherited extra descriptors": "extra-fds",
    "disarmed timers": "itimer-real",
    "signal dispositions": "ignored-SIGCHLD",
    "empty signal mask": "blocked-SIGTERM",
    "private umask": "cwd-umask-locale",
}


@contextmanager
def fixture_signal_mask():
    """Restore the test process after calling the terminal publisher in-process."""
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, set())
    try:
        yield
    finally:
        for signum in signal.sigpending().intersection(vm.STOP_SIGNALS) - previous:
            signal.sigwait({signum})
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def signal_status(path: pathlib.Path) -> tuple[int, int, int]:
    fields = dict(line.split(":", 1) for line in path.read_text().splitlines() if ":" in line)
    return tuple(int(fields[key], 16) for key in ("SigBlk", "SigIgn", "SigCgt"))


def descriptor_snapshot() -> dict[int, tuple[str, int, int]]:
    result = {}
    for entry in pathlib.Path("/proc/self/fd").iterdir():
        try:
            target = os.readlink(entry)
            info = os.fstat(int(entry.name))
        except FileNotFoundError:
            continue  # The directory scan itself has already closed its FD.
        except OSError as error:
            if error.errno != errno.EBADF:
                raise
            continue
        result[int(entry.name)] = (target, info.st_dev, info.st_ino)
    return result


def waits_for_guest_ready(mode: str) -> bool:
    return (not mode.startswith(("fault:", "receipt-step:", "pair:", "readback:", "teardown-memory:",
                                 "commit-memory:", "tail-io:"))
            and mode not in ("audit-mutation", "startup:success", "startup:failure", "startup:signal",
                             "isolated:validated-helper",
                             *SUCCESS_GUEST_MODES, *STAGE_MODES, *ISOLATION_MODES, *PRESTART_MODES))


def test_pipe_setup_allocation_failure_does_not_close_a_reused_fd() -> None:
    pipe_files = image_lifecycle.pipe_files
    monitor = sys.monitoring
    tool = monitor.DEBUGGER_ID
    instructions = tuple(dis.get_instructions(pipe_files))
    start = next(i for i, x in enumerate(instructions) if x.argval == "_PIPE2")
    returned = next(i for i, x in enumerate(instructions[start:], start) if x.opname.startswith("RETURN"))
    syscall = next(i for i in range(start, returned) if instructions[i].opname == "CALL")
    # Includes the tuple allocation and its handoff. The error branch cannot
    # execute after the fixture's successful pipe2, so skip its bytecode.
    call_result = instructions[syscall + 1]
    jump = next(x for x in instructions[syscall + 1:returned] if "JUMP" in x.opname)
    offsets = {x.offset for x in instructions if jump.argval <= x.offset <= instructions[returned].offset}
    offsets.update((call_result.offset, jump.offset))
    original_pipe = image_lifecycle._PIPE2
    before = descriptor_snapshot()
    monitor.use_tool_id(tool, "pipe setup fault")
    try:
        for point in (None, *sorted(offsets)):
            pipe_writer = None
            replacement = None

            def acquire_pipe(slots, flags):
                nonlocal pipe_writer
                assert original_pipe(slots, flags) == 0
                pipe_writer = slots[1]
                if point is None:
                    raise MemoryError("fixture pipe handoff")
                return 0

            class ReusingFile(io.FileIO):
                def close(self):
                    nonlocal replacement
                    fd = None if self.closed else self.fileno()
                    super().close()
                    if fd is not None and fd == pipe_writer and replacement is None:
                        new_fd = os.open(os.devnull, os.O_RDONLY | os.O_CLOEXEC)
                        if new_fd != fd:
                            os.dup2(new_fd, fd, inheritable=False)
                            os.close(new_fd)
                        replacement = fd

            def inject(_code, offset):
                if offset == point:
                    raise MemoryError("fixture pipe handoff")

            monitor.register_callback(tool, monitor.events.INSTRUCTION, inject)
            monitor.set_local_events(tool, pipe_files.__code__, monitor.events.INSTRUCTION)
            try:
                with patch.object(image_lifecycle, "_PIPE2", acquire_pipe), \
                        patch.object(image_lifecycle, "FileIO", ReusingFile), ExitStack() as owners:
                    try:
                        pipe_files(os.O_CLOEXEC, owners, owners, "fixture")
                    except MemoryError as error:
                        assert str(error) == "fixture pipe handoff"
                    else:
                        raise AssertionError(f"unreached pipe allocation fault {point}")
                assert replacement is not None
                assert os.readlink(f"/proc/self/fd/{replacement}") == os.devnull, point
            finally:
                if replacement is not None and replacement in descriptor_snapshot():
                    os.close(replacement)
            assert descriptor_snapshot() == before, point
    finally:
        monitor.set_local_events(tool, pipe_files.__code__, 0)
        monitor.free_tool_id(tool)


def fixture_launcher(root: pathlib.Path, mode: str, signum: signal.Signals) -> None:
    """Run the CLI and deliver a real signal inside the poll owned by select()."""
    launcher_pid = os.getpid()
    poll_type = selectors.EpollSelector._selector_cls
    replace_file = os.replace
    sigmask = signal.pthread_sigmask
    read_text = pathlib.Path.read_text
    read_bytes = pathlib.Path.read_bytes
    fsync = os.fsync
    unlink_syscall = os.unlink

    def unlink(path, *, missing_ok=False):
        try:
            unlink_syscall(os.fspath(path))
        except FileNotFoundError:
            if not missing_ok:
                raise
    temporary_file = tempfile.TemporaryFile
    native_open, native_close = os.open, os.close
    directory = root / "returns/fixture/build"
    lost_pid_file = root / "lost-child-pid"
    fault = mode.split(":")[1:] if mode.startswith("fault:") else None
    receipt_fault = mode.split(":")[1:] if mode.startswith("receipt-step:") else None
    teardown_fault = mode.removeprefix("teardown-memory:") if mode.startswith("teardown-memory:") else ""
    commit_fault = mode.removeprefix("commit-memory:") if mode.startswith("commit-memory:") else ""
    tail_case = (mode.split("tail-io:", 1)[1].split("/")
                 if mode.startswith(("tail-io:", "pair:tail-io:")) else [])
    tail_count = 0
    frame_offsets = set()

    def tail_fault(point):
        nonlocal tail_count
        if not tail_case or point != tail_case[0] or tail_count >= int(tail_case[2]):
            return
        tail_count += 1
        (root / "tail-fault-count").write_text(str(tail_count))
        if tail_case[1] == "MemoryError":
            raise MemoryError(point)
        raise OSError(getattr(errno, tail_case[1]), point)

    def tail_signal_at(point):
        if not tail_case or tail_case[0] not in {"exit-mask", "exit-ignore"}:
            return
        if point != (tail_case[3] if len(tail_case) > 3 else "rename"):
            return
        mask_bits, ignore_bits, _ = signal_status(pathlib.Path("/proc/self/status"))
        required = sum(1 << (sig - 1) for sig in CATCHABLE_SIGNALS)
        assert (mask_bits | ignore_bits) & required == required
        os.kill(os.getpid(), signum)
        (root / "tail-signal-sent").touch()

    def receipt_phase(frame):
        while frame is not None:
            transaction = frame.f_locals.get("transaction")
            if isinstance(transaction, image_lifecycle.Receipt):
                return {"exit.json": "exit", "teardown.json": "teardown",
                        "transport-validation.json": "validation", "active.json": "active",
                        "started.json": "started"}.get(transaction.path.name)
            if frame.f_code is image_lifecycle.retire_journal.__code__:
                return "journal"
            frame = frame.f_back
        return None
    pair = mode.startswith("pair:")
    inherited = mode == "inherited"
    startup = mode.removeprefix("startup:") if mode.startswith("startup:") else None
    rejected = mode.removeprefix("startup-reject:") if mode.startswith("startup-reject:") else None
    critical_target = mode.removeprefix("pair:critical:") if mode.startswith("pair:critical:") else None
    mask_mutation = mode == "pair:mask-mutation"
    trace_terminal = critical_target is not None or mask_mutation
    terminal_code = {str(ROOT / "ci/kernel-runner" / name)
                     for name in ("vm_process.py", "image_lifecycle.py", "image_vm.py", "vm.py")}
    terminal_entered = False
    terminal_synced = False
    traced = set()
    violations = set()
    delivered = None
    audit_receipts = bool(receipt_fault) or mode == "audit-mutation"
    events = set()
    outside = set()
    active_step = None
    during = None
    sent = False
    fail_sync = False
    if inherited:
        (root / "status-launcher").write_text(pathlib.Path("/proc/self/status").read_text())

    verify_startup = vm_startup.verify_startup
    initial_fds = None

    def fixture_verify(checks):
        nonlocal initial_fds
        verify_startup(checks)
        if check_descriptors:
            initial_fds = descriptor_snapshot()
        if startup or rejected:
            (root / "startup-baseline").write_text(json.dumps(checks))
        if rejected:
            verify_startup(checks | {rejected: False})

    def raising_handler(_signum, _frame):
        (root / "handler-ran").touch()
        raise SystemExit(71)

    if mode in {"raising-handler", "shutdown-gap"}:
        signal.signal(signal.SIGUSR1, raising_handler)
    if trace_terminal:
        # Linux resumes a process on SIGCONT even when blocked. Install a
        # handler so the blocked handler delivery is also observable as pending.
        for caught in (signal.SIGCONT, signal.SIGUSR1, signal.SIGUSR2):
            signal.signal(caught, raising_handler)

    def inject_terminal(point):
        nonlocal delivered
        if critical_target != point or delivered is not None:
            return
        delivered = []
        for catchable in sorted(CATCHABLE_SIGNALS):
            os.kill(os.getpid(), catchable)
            assert catchable in signal.sigpending(), (point, catchable)
            delivered.append(int(catchable))

    def observe_instruction(code, offset):
        if not terminal_entered:
            return
        name = code.co_name
        if not CATCHABLE_SIGNALS.issubset(sigmask(signal.SIG_BLOCK, set())):
            violations.add((name, offset))
        if name == "exit_launcher" and terminal_synced:
            inject_terminal("after-sync")
        if name not in traced:
            inject_terminal(f"{name}:first")
        traced.add(name)
        if dis.opname[code.co_code[offset]].startswith("RETURN"):
            inject_terminal(f"{name}:last")

    if trace_terminal:
        monitor = sys.monitoring
        tool_id = monitor.DEBUGGER_ID
        monitor.use_tool_id(tool_id, "terminal mask fixture")
        monitor.register_callback(tool_id, monitor.events.INSTRUCTION, observe_instruction)

        def observe_start(code, _offset):
            if code.co_filename in terminal_code:
                monitor.set_local_events(tool_id, code, monitor.events.INSTRUCTION)

        monitor.register_callback(tool_id, monitor.events.PY_START, observe_start)
        monitor.set_events(tool_id, monitor.events.PY_START)

    if mode == "shutdown-gap":
        def trace(frame, event, _arg):
            if (frame.f_code.co_name == "exit_launcher" and event == "line"
                    and pathlib.Path(frame.f_code.co_filename).name == "vm.py"
                    and (root / "final-sync").exists()):
                sys.settrace(None)
                os.kill(os.getpid(), signal.SIGUSR1)
            return trace
        sys.settrace(trace)

    run_image = image_vm.run_image

    def image_entry(*args):
        status = run_image(*args)
        if mode == "late-exit":
            raise SystemExit(71)
        return status

    def fixture_read_bytes(path):
        if path == directory / "exit.json":
            tail_signal_at("readback")
            tail_fault("readback")
        if path == directory / "exit.json" and (mode == "unreadable-exit" or mode.startswith("readback:")):
            mark = root / "readback-injected"
            if mode == "unreadable-exit" or not mark.exists():
                mark.touch()
                errors = {
                    "readback:eintr": InterruptedError(errno.EINTR, "fixture final receipt readback"),
                    "readback:oserror": OSError(errno.EIO, "fixture final receipt readback"),
                    "readback:memory": MemoryError("fixture final receipt readback"),
                    "unreadable-exit": OSError(errno.EIO, "fixture final receipt readback"),
                }
                raise errors[mode]
            (root / "readback-retried").touch()
        if path == directory.parent / "exit.json" and trace_terminal:
            inject_terminal("readback:before")
            result = read_bytes(path)
            inject_terminal("readback:after")
            return result
        return read_bytes(path)

    def step_fixture(action):
        def run_step(transaction):
            nonlocal active_step, during
            active_step = action.__name__
            try:
                inject_step(action, transaction)
            finally:
                active_step = during = None
        return run_step

    def inject_step(action, transaction):
        nonlocal during
        final = transaction.path == directory / "exit.json"
        if (teardown_fault == action.__name__ and transaction.path == directory / "teardown.json"
                and not (root / "injected").exists()):
            (root / "injected").touch()
            if action.__name__ in {"file_close", "dir_close", "temp_cleanup"}:
                action(transaction)
            raise MemoryError("fixture teardown receipt allocation")
        if final:
            with (root / "steps").open("a") as log:
                print(action.__name__, file=log)
        if (final and receipt_fault and action.__name__ == receipt_fault[0]
                and not (root / "injected").exists()):
            (root / "injected").touch()
            kind = receipt_fault[1]
            if kind == "term-before":
                cancel()
            if kind in {"exception", "oserror", "systemexit", "interrupt", "memory"}:
                # Successful close can also report an error. For rename,
                # inject before the syscall to model a failed commit.
                if action.__name__ in {"file_close", "dir_close", "temp_cleanup"}:
                    action(transaction)
                error = {"exception": Exception, "oserror": OSError,
                         "systemexit": SystemExit, "interrupt": KeyboardInterrupt, "memory": MemoryError}[kind]
                raise error(f"fixture {action.__name__}")
            if kind == "term-during":
                during = action.__code__
        action(transaction)

    def observe(operation, frame):
        while frame is not None:
            if (frame.f_code.co_filename == image_lifecycle.__file__
                    and frame.f_code.co_name == "receipt"):
                if active_step is None:
                    outside.add(operation)
                else:
                    events.add((active_step, operation))
                break
            frame = frame.f_back

    def audit(event, _args):
        if event == "open" or event.startswith("os."):
            observe(event, sys._getframe(1))

    def audit_terminal_spawns(event, _args):
        if terminal_entered and event in {"subprocess.Popen", "os.posix_spawn", "os.fork", "os.exec"}:
            violations.add((event, -1))

    native = {fn: fn.__name__ for fn in (
        os.rename, os.replace, os.fsync, os.close, os.unlink, os.kill, os.open,
        os.write, os.stat, os.lstat, os.statvfs, signal.signal, sigmask, signal.sigpending,
    )}

    def profile(frame, event, arg):
        nonlocal during
        if event == "call" and frame.f_code is during and active_step != "rename":
            during = None
            cancel()
        elif event == "c_call":
            operation = native.get(arg)
            if operation is None and isinstance(getattr(arg, "__self__", None), io.IOBase):
                if arg.__name__ in {"write", "flush", "close"}:
                    operation = arg.__name__
            if operation is not None:
                observe(operation, frame)

    def mask(how, signals):
        nonlocal terminal_entered
        if (mode == "mask-restore-error" and os.getpid() == launcher_pid and how == signal.SIG_SETMASK
                and (directory / "exit.json").exists()):
            (root / "restore-attempt").touch()
            raise OSError(errno.EPERM, "fixture final mask restoration")
        terminal = (how == signal.SIG_BLOCK and signals == CATCHABLE_SIGNALS
                    and sys._getframe(1).f_code.co_name != "sanitize_startup")
        if terminal:
            if tail_case and tail_case[0] == "exit-ignore":
                raise OSError(errno.ENOSYS, "fixture has no sigprocmask")
            tail_fault("exit-mask")
        previous = sigmask(how, signals)
        if terminal:
            assert not terminal_entered, "terminal mask was installed twice"
            terminal_entered = True
        return previous

    def cancel() -> None:
        nonlocal sent
        sent = True
        (root / "sent").write_text(str(time.monotonic()))
        os.kill(os.getpid(), signum)

    def fault_at(step: str) -> None:
        if fault is None or fault[1] != step:
            return
        if (root / "injected").exists():
            if fault[0] == "fail" and step != "journal-unlink":
                raise OSError(errno.EIO, f"fixture {step}")
            return
        (root / "injected").touch()
        if fault[0] == "fail":
            raise OSError(errno.EIO, f"fixture {step}")
        cancel()

    def teardown_memory(point: str) -> None:
        if teardown_fault == point and not (root / "injected").exists():
            (root / "injected").touch()
            raise MemoryError(f"fixture teardown allocation at {point}")

    def publish(source, destination) -> None:
        nonlocal during, fail_sync
        if tail_case and tail_case[0].endswith("-temp-unlink"):
            discarded = {"validation": "transport-validation.json", "teardown": "teardown.json", "exit": "exit.json"}
            if destination.parent == directory and destination.name == discarded[tail_case[0].split("-")[0]]:
                raise OSError(errno.ENOSPC, "fixture leaves an uncommitted receipt to clean up")
        if destination == directory / "exit.json":
            tail_fault("exit-rename")
        if destination == directory / "teardown.json":
            tail_fault("teardown-rename")
        if destination == directory / "transport-validation.json":
            tail_fault("validation-rename")
        if destination == directory / "started.json":
            tail_fault("started-rename")
        if destination == root / "returns/active.json":
            tail_fault("active-rename")
        if destination == directory / "teardown.json":
            fault_at("teardown-rename")
        if pair:
            with (root / "sequence").open("a") as log:
                print(destination.relative_to(root / "returns"), file=log)
        if (destination in {directory / "exit.json", directory / "teardown.json"}
                or pair and destination.name in {"teardown.json", "exit.json"}):
            # Startup may independently repair a standard stream to /dev/null.
            live = {target for fd in pathlib.Path("/proc/self/fd").iterdir()
                    if fd.is_symlink() and fd.exists() and (
                        (target := os.readlink(fd)) != "/dev/null" or int(fd.name) > 2)}
            owned = root / "owned-fds"
            if (fault and not (root / "ready").exists()
                    or (root / "child-fault").exists() and not owned.exists()):
                held = set()
            elif mode in PRESTART_MODES:
                held = set(json.loads((root / "prestart-fds").read_text()))
            else:
                held = set(json.loads(owned.read_text()))
                assert held, "started fake QEMU has no inherited descriptor inventory"
            held.add(str(root / "capsule"))
            held.update(str(file) for file in directory.glob("*.partial"))
            (root / "leaks").write_text(json.dumps(sorted(live & held)))
            assert not live & held, sorted(live & held)
            frozen = "launcher_exit" in json.loads(pathlib.Path(source).read_text())
            if not sent and (mode == "receipt" or mode == "committed" and frozen):
                cancel()
            if mode == "exit-sync-error" and frozen:
                fail_sync = True
            with (root / "fixture.lock").open("rb") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    raise AssertionError("receipt written without the lock held")
            if mode == "pair:fail" and destination == directory.parent / "verify/teardown.json":
                raise OSError(errno.EIO, "fixture verifier teardown rename")
        if during is not None and active_step == "rename" and destination == directory / "exit.json":
            during = None
            cancel()
            assert signum in signal.sigpending(), "TERM was not pending in the rename step"
        replace_file(source, destination)
        if destination == directory / "exit.json":
            tail_signal_at("rename")
        if mode == "raising-handler" and destination == directory / "exit.json":
            os.kill(os.getpid(), signal.SIGUSR1)
            assert signal.SIGUSR1 in signal.sigpending()
            (root / "handler-pending").touch()
        if trace_terminal and destination == directory.parent / "exit.json":
            inject_terminal("rename:published")

    def sync(fd):
        phase = receipt_phase(sys._getframe(1)) if tail_case else None
        if phase:
            point = f"{phase}-{'dir' if os.path.isdir(f'/proc/self/fd/{fd}') else 'file'}-fsync"
            tail_signal_at(point)
            tail_fault(point)
        nonlocal fail_sync, terminal_synced
        if startup:
            # Keep receipt publication real without timing host disk flushes in the startup matrix.
            os.fstat(fd)
            return
        path = pathlib.Path(os.readlink(f"/proc/self/fd/{fd}"))
        if fail_sync and path == directory:
            fail_sync = False
            raise OSError(errno.EIO, "fixture exit directory sync")
        for location, stage in ((root, "parent-sync"), (directory / "stream.partial", "capture-sync"),
                                (directory / "artifacts/verification.json", "artifact-sync"),
                                (directory / "artifacts", "artifact-dir-sync")):
            if path == location or path.parent == location.parent and path.name.startswith(f".rewrite-{location.name}-"):
                tail_fault(stage)
                fault_at(stage)
        final = (terminal_entered and path == directory.parent and pair
                 and (directory.parent / "exit.json").exists())
        if final and mask_mutation:
            previous = sigmask(signal.SIG_UNBLOCK, {signal.SIGUSR2})
            try:
                fsync(fd)
            finally:
                sigmask(signal.SIG_SETMASK, previous)
        else:
            fsync(fd)
        if final:
            terminal_synced = True
        if mode in {"raising-handler", "shutdown-gap", "mask-restore-error"} \
                and path == directory and (directory / "exit.json").exists():
            (root / "final-sync").touch()

    def remove(path, *args, **kwargs):
        if tail_case and path.name.startswith(".receipt-"):
            phase = receipt_phase(sys._getframe(1))
            if phase:
                tail_fault(f"{phase}-temp-unlink")
        if path == directory / "stream.partial":
            fault_at("stream-unlink")
        if path == root / "returns/active.json":
            tail_signal_at("journal-unlink")
            if tail_case and tail_case[0] == "journal-unlink":
                assert (directory / "exit.json").exists(), "journal unlink ran before exit commit"
                if tail_case[1] == "ENOENT" and tail_count == 0 and not mode.endswith("/still-present"):
                    unlink(path, *args, **kwargs)
                tail_fault("journal-unlink")
            teardown_memory("journal-unlink")
            fault_at("journal-unlink")
        return unlink(path, *args, **kwargs)

    def remove_owned(path, *args, **kwargs):
        if isinstance(path, pathlib.Path):
            return remove(path, *args, **kwargs)
        return unlink_syscall(path, *args, **kwargs)

    def overlay(*args, **kwargs):
        fault_at("overlay-create")
        file = temporary_file(*args, **kwargs)

        class Overlay:
            def fileno(self):
                return file.fileno()

            def close(self):
                file.close()
                fault_at("overlay-close")

        return Overlay()

    def read_result(path, *args, **kwargs):
        if path == directory / "artifacts/verification.json":
            tail_fault("verification-read")
            if tail_case and tail_case[0].startswith("rejected-fd-line-"):
                raise StreamError("fixture independently rejects semantic verification")
        if mode == "validation" and path == directory / "artifacts/verification.json":
            cancel()
        return read_text(path, *args, **kwargs)

    def wait_for_guest() -> None:
        fd = os.open(root / "guest-ready", os.O_RDWR | os.O_CLOEXEC)
        try:
            assert select.select([fd], [], [], 5)[0], "fake QEMU never reached startup"
            assert os.read(fd, 1) == b"1"
        finally:
            os.close(fd)

    def poller():
        epoll = poll_type()

        class Poll:
            def __getattr__(self, name):
                return getattr(epoll, name)

            def poll(self, *args):
                if waits_for_guest_ready(mode) and not sent:
                    wait_for_guest()
                    cancel()
                    if startup and (root / "startup-ready").exists():
                        return []  # The startup matrix targets entry state, not the existing 1s poll bound.
                return epoll.poll(*args)

        return Poll()

    validate_return = image_vm.validate_return

    def fixture_return(job, verifier):
        # Only the production build's multi-GiB artifact set is substituted.
        if not pair or verifier:
            if mode in (*ISOLATION_MODES, "stages:at-cap", "stages:over-cap"):
                assert (job.directory / "stream.partial").read_bytes() == (root / "probe.frame").read_bytes()
            validate_return(job, verifier)
            if commit_fault:
                run_code = run_image.__code__
                measure_code = image_vm.measure_image.__code__
                passed_validation = False
                source, first = inspect.getsourcelines(run_image)
                last = first + next(i for i, line in enumerate(source) if "except Cancelled as exc" in line)
                statement_points = {first + node.lineno - 1 for node in ast.walk(ast.parse(dedent("".join(source))))
                                    if isinstance(node, (ast.Assign, ast.Expr, ast.Return))}
                seen = set()

                def commit_trace(frame, event, _arg):
                    nonlocal passed_validation
                    if frame.f_code is measure_code and event == "return":
                        passed_validation = True
                    if (frame.f_code is run_code and passed_validation and event == "line"
                            and frame.f_lineno in statement_points and frame.f_lineno < last):
                        point = str(frame.f_lineno)
                        if commit_fault == "baseline" and point not in seen:
                            seen.add(point)
                            with (root / "commit-points").open("a") as log:
                                print(point, file=log)
                        if commit_fault == point:
                            sys.settrace(None)
                            (root / "injected").touch()
                            raise MemoryError(f"fixture finalization at {point}")
                    return commit_trace

                sys.settrace(commit_trace)
                frame = sys._getframe(1)
                while frame is not None:
                    if frame.f_code in {run_code, measure_code}:
                        frame.f_trace = commit_trace
                    frame = frame.f_back
            if mode == "isolated:validated-helper":
                step = (root / "child-fault").read_text().partition(":")[0]
                run(["qemu-img", step, str(root / "base")],
                    cancellation=job.cancellation, timeout=2, capture_output=step == "info")
            if mode == "isolated:fallback:MemoryError":
                class NoLateDefaults(dict):
                    def __or__(self, other):
                        if "capture_lost" in other:
                            raise MemoryError("fixture late fallback merge")
                        return super().__or__(other)

                job.state = NoLateDefaults(job.state)
            return
        job.cancellation.check()
        target = job.directory / "artifacts"
        (target / "fixture").write_bytes(b"public artifact")

    def priority_timeout(_pid, _cancellation):
        wait_for_guest()
        raise image_resources.IOPriorityError("ioprio_get fixture")

    tail_guest_released = False

    def priority_sample(pid, cancellation):
        nonlocal tail_guest_released
        if tail_case and not tail_guest_released:
            (root / "tail-priority-ready").write_bytes(b"1")
            tail_guest_released = True
        if mode == "isolated:exclusive":
            wait_for_guest()
            children = (pathlib.Path(f"/proc/self/task/{launcher_pid}/children").read_text().split())
            assert children == [str(pid)], children
            (root / "exclusive-sample").touch()
            return image_resources.process_priority(pid, cancellation)
        return FIXTURE_PRIORITY

    if mode == "isolated:exclusive":
        def no_capture_spawns(event, args):
            if event in {"subprocess.Popen", "os.fork", "os.posix_spawn"}:
                assert not (directory / "started.json").exists(), f"extra child during capture: {event}"
                assert event == "subprocess.Popen", event
                argv = child_command(args[1])
                with (root / "exclusive-spawns").open("a") as output:
                    print(" ".join(argv[:2] if argv[0] == "qemu-img" else argv[:1]), file=output)

        sys.addaudithook(no_capture_spawns)

    capsule = root / "capsule"
    base = root / "base"
    sys.argv = [str(ROOT / "ci/kernel-runner/vm.py"), "image", "--base", str(base),
                "--base-sha256", hashlib.sha256(base.read_bytes()).hexdigest(),
                "--input-capsule", str(capsule),
                "--input-sha256", hashlib.sha256(capsule.read_bytes()).hexdigest(),
                "--trust-policy", str(root / "unused-policy"), "--output-dir", str(root / "returns"),
                "--source-commit", IDENTITY.commit, "--source-epoch", str(IDENTITY.epoch),
                "--attempt", IDENTITY.attempt, "--board", IDENTITY.board, "--image-mode",
                "measure" if pair else "probe"]
    table = (tuple((step_fixture(action), cleanup) for action, cleanup in image_lifecycle.RECEIPT_STEPS)
             if audit_receipts or teardown_fault else image_lifecycle.RECEIPT_STEPS)
    real_exit = os._exit

    def audited_exit(status):
        sys.setprofile(None)
        try:
            (root / "audit").write_text(json.dumps({"events": sorted(events), "outside": sorted(outside)}))
        finally:
            real_exit(status)

    def terminal_profile(_frame, event, function):
        if terminal_entered and event == "c_call" and function is fsync:
            if not CATCHABLE_SIGNALS.issubset(sigmask(signal.SIG_BLOCK, set())):
                violations.add(("fsync", -1))

    def terminal_exit(status):
        inject_terminal("exit:direct")
        try:
            if not CATCHABLE_SIGNALS.issubset(sigmask(signal.SIG_BLOCK, set())):
                violations.add(("os._exit", -1))
            (root / "terminal").write_text(json.dumps({
                "delivered": delivered, "pending": sorted(map(int, signal.sigpending())),
                "traced": sorted(traced), "violations": sorted(violations),
            }))
        finally:
            real_exit(status)

    writer = image_lifecycle.receipt
    real_receipt = writer

    def check_lost_child_at_receipt(path, row, **kwargs):
        if path == directory / "teardown.json":
            teardown_memory("receipt")
        if path.parent == directory and path.name in {"teardown.json", "exit.json"} and lost_pid_file.exists():
            pid = lost_pid_file.read_text()
            assert not pathlib.Path(f"/proc/{pid}").exists(), (path.name, pid)
            with (root / "lost-child-receipts").open("a") as observed:
                print(path.name, file=observed)
        if path == directory / "exit.json" and tail_case and "-fd-line-" in tail_case[0]:
            from image_stream import retry_io, write_all

            prefix = tail_case[0].split("-fd-line-")[0] + "-fd-line-"
            watched = {fn.__code__ for fn in (image_lifecycle.Receipt.temp_open,
                                             image_lifecycle.Receipt.temp_write,
                                             image_lifecycle.Receipt.file_sync,
                                             image_lifecycle.Receipt.file_close, write_all)}
            live = set()

            def trace_live_fd(frame, event, _arg):
                if frame.f_code not in watched and frame.f_code is not retry_io.__code__:
                    return None
                if event == "line":
                    current = frame
                    while current is not None:
                        owner = current.f_locals.get("self")
                        if isinstance(owner, image_lifecycle.Receipt):
                            fd = getattr(owner, "file_fd", None)
                            if fd is not None and fd >= 0:
                                # The close dispatch itself has a separate post-release
                                # syscall matrix. Everything up to dispatch is covered.
                                if (frame.f_code is image_lifecycle.Receipt.file_close.__code__
                                        and frame.f_lineno >= frame.f_code.co_firstlineno + 5):
                                    break
                                point = f"{frame.f_code.co_name}-{frame.f_lineno}"
                                live.add(point)
                                tail_fault(prefix + point)
                            break
                        current = current.f_back
                return trace_live_fd

            sys.settrace(trace_live_fd)
            try:
                real_receipt(path, row, **kwargs)
            finally:
                sys.settrace(None)
                (root / "live-receipt-lines").write_text(json.dumps(sorted(live)))
            return
        real_receipt(path, row, **kwargs)

    writer = check_lost_child_at_receipt
    if mode == "audit-mutation":
        writer = real_receipt
        namespace = image_lifecycle.__dict__.copy()
        source = inspect.getsource(writer) + "\n    transaction.path.stat()\n    os.statvfs(transaction.path.parent)\n"
        exec(compile(source, image_lifecycle.__file__, "exec"), namespace)
        writer = namespace["receipt"]
        writer.__globals__["RECEIPT_STEPS"] = table
    if audit_receipts:
        def shutdown_hook():
            (root / "atexit-ran").touch()
            raise SystemExit(7)
        atexit.register(shutdown_hook)
        sys.addaudithook(audit)
        sys.setprofile(profile)
    if trace_terminal:
        sys.addaudithook(audit_terminal_spawns)
        sys.setprofile(terminal_profile)
    with ExitStack() as patches:
        ownership_case = root / "ownership-case"
        pidfd_case = root / "pidfd-case"
        pipe_fault = (root / "pipe-fault").read_text() if (root / "pipe-fault").exists() else ""
        registration_fault = ((root / "registration-fault").read_text()
                              if (root / "registration-fault").exists() else "")
        child_fault = (root / "child-fault").read_text() if (root / "child-fault").exists() else ""
        signal_fault = (root / "signal-fault").read_text() if (root / "signal-fault").exists() else ""
        check_descriptors = (ownership_case.exists() or pidfd_case.exists() or pipe_fault or registration_fault
                             or child_fault or signal_fault or teardown_fault or commit_fault or tail_case
                             or mode.startswith("readback:") or mode == "unreadable-exit"
                             or mode in (*BACKUP_SELECTOR_CLOSE_MODES, *READER_CLEANUP_MODES, *PRESTART_MODES))
        if check_descriptors:
            def checked_exit(status):
                final_fds = descriptor_snapshot()
                assert initial_fds is not None, "startup did not establish a descriptor baseline"
                (root / "descriptor-check").write_text(json.dumps([initial_fds, final_fds]))
                if child_fault or signal_fault or teardown_fault or commit_fault or tail_case:
                    children = pathlib.Path(f"/proc/self/task/{launcher_pid}/children").read_text().split()
                    (root / "launcher-children").write_text(json.dumps(children))
                if tail_case and tail_case[0].startswith("frame-read-"):
                    (root / "frame-offsets").write_text(json.dumps(sorted(frame_offsets)))
                real_exit(status)

        if check_descriptors:
            selected, phase, kind = (json.loads(ownership_case.read_text())
                                     if ownership_case.exists() else (-1, "", ""))
            pidfd_fault = (pidfd_case.read_text() if pidfd_case.exists() else "baseline")
            register_owner = vm_process.register_close
            inventory = []

            def inject_in_call(watched, target, line_or_return, marker):
                def trace(frame, event, arg):
                    if frame.f_code is not watched or not target(frame.f_locals):
                        return None
                    if ((event == "line" and str(frame.f_lineno) == line_or_return)
                            or (event == line_or_return == "return")):
                        marker.touch()
                        sys.settrace(None)
                        raise MemoryError("fixture ownership transition")
                    return trace

                sys.settrace(trace)

            if registration_fault or child_fault or signal_fault:
                waitpid = os.waitpid

                def record_launcher_wait(pid, options):
                    waited, status = waitpid(pid, options)
                    if waited and os.getpid() == launcher_pid:
                        with (root / "launcher-waits").open("a") as output:
                            print(waited, os.waitstatus_to_exitcode(status), file=output)
                    return waited, status

                patches.enter_context(patch.object(os, "waitpid", record_launcher_wait))
                if registration_fault == "unusable":
                    def unusable_pidfd(*_args):
                        (root / "registration-injected").touch()
                        raise OSError(errno.EBADF, "fixture unusable pidfd")

                    patches.enter_context(patch.object(signal, "pidfd_send_signal", unusable_pidfd))
                elif registration_fault.startswith("rollback:"):
                    callback = ExitStack.callback

                    def fail_pidfd_callback(stack, function, *args, **kwargs):
                        if args == ("qemu-pidfd",):
                            raise OSError("fixture pidfd callback allocation")
                        return callback(stack, function, *args, **kwargs)

                    patches.enter_context(patch.object(ExitStack, "callback", fail_pidfd_callback))
                if signal_fault:
                    send_signal = signal.pidfd_send_signal
                    fault_boundary, _, fault_error = signal_fault.partition("/")
                    if not fault_error:
                        fault_boundary, fault_error = "signal", fault_boundary

                    def pidfd_error():
                        (root / "signal-injected").touch()
                        if fault_error == "MemoryError":
                            raise MemoryError("fixture pidfd operation")
                        raise OSError(getattr(errno, fault_error), "fixture pidfd operation")

                    def fail_pidfd_signal(fd, signum):
                        if fault_error == "ESRCH":
                            # Model the target exiting just before the syscall.
                            send_signal(fd, signum)
                        pidfd_error()

                    if fault_boundary == "open":
                        patches.enter_context(patch.object(os, "pidfd_open", lambda _pid: pidfd_error()))
                    else:
                        patches.enter_context(patch.object(signal, "pidfd_send_signal", fail_pidfd_signal))
                if child_fault:
                    target, operation, kind = child_fault.split(":")
                    popen = subprocess.Popen
                    if operation == "selector-stack":
                        stack = vm_process.ExitStack

                        def fail_selector_stack():
                            caller = sys._getframe(1)
                            args = caller.f_locals.get("args", ())
                            if caller.f_code is vm_process.run.__code__ and (
                                args[1] if args[0] == "qemu-img" else args[0]
                            ) == target and (mode != "isolated:validated-helper"
                                             or (directory / "transport-validation.json").exists()):
                                (root / "child-injected").touch()
                                raise DIAGNOSTIC_ERRORS[kind]("fixture selector stack allocation")
                            return stack()

                        patches.enter_context(patch.object(vm_process, "ExitStack", fail_selector_stack))
                    if operation.startswith(("prepare/", "pre-spawn/")):
                        location, _, expected_name = operation.split("/")[1].partition("@")
                        point = int(location)
                        watched_prepare = (vm_process.run if operation.startswith("prepare/")
                                           else vm_process.spawn_owned.__wrapped__).__code__

                        def prepare_trace(frame, event, _arg):
                            if frame.f_code is not watched_prepare:
                                return None
                            args = frame.f_locals["args"]
                            if (args[1] if args[0] == "qemu-img" else args[0]) != target:
                                return None
                            if mode == "isolated:validated-helper" and not (directory / "transport-validation.json").exists():
                                return None
                            if expected_name and frame.f_locals.get("name") != expected_name:
                                return prepare_trace
                            if event == "line" and frame.f_lineno == point:
                                (root / "child-injected").touch()
                                sys.settrace(None)
                                raise DIAGNOSTIC_ERRORS[kind]("fixture helper preparation")
                            return prepare_trace

                        sys.settrace(prepare_trace)

                    def inject_child(args, *positional, **kwargs):
                        command_args = child_command(args)
                        command = command_args[1] if command_args[0] == "qemu-img" else command_args[0]
                        if command != target or (mode == "isolated:validated-helper"
                                                 and not (directory / "transport-validation.json").exists()):
                            process = popen(args, *positional, **kwargs)
                            if command == "qemu-system-x86_64":
                                (root / "spawned-qemu").write_text(str(process.pid))
                            return process
                        if operation == "baseline":
                            (root / "child-injected").touch()
                            raise vm_process.ChildSetupError("fixture helper setup")
                        if command == "qemu-system-x86_64":
                            kwargs.update(stdin=subprocess.PIPE, stderr=subprocess.PIPE)
                        else:
                            # Every helper uses this owner, including helpers with
                            # inherited output. Exercise all stdio registrations.
                            kwargs.update(stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        child_args = [*args[:-len(command_args)], "fixture-helper"] if command in PREPARATION_HELPERS else args
                        process = popen(child_args, *positional, **kwargs)
                        (root / "fault-pid").write_text(str(process.pid))
                        if command == "qemu-system-x86_64":
                            (root / "spawned-qemu").write_text(str(process.pid))
                            wait_for_guest()
                        if operation.startswith("sweep"):
                            # Observe the reached lines on the healthy path, then fail
                            # each line once on a new launcher with the same input.
                            watched = {fn.__code__ for fn in (
                                vm_process.spawn_owned.__wrapped__, vm_process.run,
                                vm.boot, ImageJob.capture, image_vm.execute,
                                validate_return, image_vm.measure_image,
                            )}
                            if command != "qemu-system-x86_64":
                                watched &= {vm_process.spawn_owned.__wrapped__.__code__, vm_process.run.__code__}
                            main_lines = {}
                            for code in watched:
                                source, start = inspect.getsourcelines(code)
                                tree = ast.parse(dedent("".join(source)))
                                # Line events also fire on compiler scaffolding (try,
                                # implicit context exits and finally dispatch). Those
                                # are not executable source statements in the main path.
                                main_lines[code] = {
                                    start + statement.lineno - 1
                                    for statement in ast.walk(tree)
                                    if isinstance(statement, (ast.Assign, ast.AnnAssign, ast.AugAssign,
                                                              ast.Delete, ast.Expr, ast.If, ast.While,
                                                              ast.For, ast.Return))
                                }
                            for function, cutoff in ((vm_process.spawn_owned.__wrapped__, "yield process"),
                                                     (vm_process.run, "if owners is not None:"),
                                                     (ImageJob.capture, 'self.state["stream_bytes"]')):
                                if function.__code__ in main_lines:
                                    source, start = inspect.getsourcelines(function)
                                    point = start + next(i for i, line in enumerate(source) if cutoff in line)
                                    if function is vm_process.run:
                                        main_lines[function.__code__].difference_update({point, point + 1})
                                    elif function is ImageJob.capture:
                                        main_lines[function.__code__].discard(point)
                                    else:
                                        main_lines[function.__code__] = {
                                            line for line in main_lines[function.__code__] if line <= point}
                            capture_src, first = inspect.getsourcelines(ImageJob.capture)
                            optional_lines = set()
                            for begin, end in (
                                ("if self.probe:\n", "raise subprocess.TimeoutExpired("),
                                ("if console_retry_at is not None", "ready = events.select("),
                                ('if self.probe and name == "console":', "chunk = read_once("),
                                ("if self.probe:\n", 'self.state["stream_bytes"]'),
                            ):
                                last = max(i for i, line in enumerate(capture_src) if end in line)
                                start = max(i for i, line in enumerate(capture_src[:last]) if begin in line)
                                optional_lines.update(range(first + start + 1, first + last))
                            # The replay targets the main path. The existing ownership
                            # and diagnostics matrices inject inside optional boundaries.
                            seen = set()

                            def sweep_trace(frame, event, _arg):
                                if frame.f_code not in watched:
                                    return None
                                if event == "line" and frame.f_lineno in main_lines[frame.f_code] and not (
                                    frame.f_code is ImageJob.capture.__code__ and frame.f_lineno in optional_lines
                                    or frame.f_code is vm_process.spawn_owned.__wrapped__.__code__
                                    and "process" in frame.f_locals and frame.f_locals["process"] is None
                                ):
                                    key = f"{frame.f_code.co_qualname}@{frame.f_lineno}"
                                    if operation == "sweep-baseline" and key not in seen:
                                        seen.add(key)
                                        with (root / "sweep-points").open("a") as output:
                                            print(key, file=output)
                                    if operation == f"sweep/{key}":
                                        (root / "child-injected").touch()
                                        if frame.f_code is vm_process.spawn_owned.__wrapped__.__code__ and (
                                            "handle.__init__(" in inspect.getsource(frame.f_code).splitlines()[
                                                frame.f_lineno - frame.f_code.co_firstlineno]
                                        ):
                                            (root / "sweep-optional").touch()
                                        sys.settrace(None)
                                        raise MemoryError(f"fixture allocation at {key}")
                                return sweep_trace

                            sys.settrace(sweep_trace)
                            frame = sys._getframe(1)
                            while frame is not None:
                                if frame.f_code in watched:
                                    frame.f_trace = sweep_trace
                                frame = frame.f_back
                            return process
                        if operation in {"lost-return", "lost-already-collected"}:
                            if operation == "lost-already-collected":
                                process.kill()
                                process.wait(timeout=2)
                            lost_pid_file.write_text(str(process.pid))
                            (root / "child-injected").touch()
                            raise DIAGNOSTIC_ERRORS[kind]("fixture lost Popen result")
                        if operation == "selector-stack":
                            return process
                        function, point = operation.split("/")
                        point, _, role = point.partition("@")
                        watched = {
                            "spawn": vm_process.spawn_owned.__wrapped__.__code__,
                            "helper": vm_process.run.__code__,
                            "boot": vm.boot.__code__,
                        }[function]

                        def trace(frame, event, _arg):
                            if frame.f_code is not watched:
                                return None
                            if role and frame.f_locals.get("name") != role:
                                return trace
                            if ((event == "line" and str(frame.f_lineno) == point)
                                    or event == point == "return"):
                                (root / "child-injected").touch()
                                sys.settrace(None)
                                raise DIAGNOSTIC_ERRORS[kind]("fixture child registration")
                            return trace

                        sys.settrace(trace)
                        frame = sys._getframe(1)
                        while frame is not None:
                            if frame.f_code is watched:
                                frame.f_trace = trace
                            frame = frame.f_back
                        return process

                    patches.enter_context(patch.object(subprocess, "Popen", inject_child))
                    if target in PREPARATION_HELPERS:
                        def use_preparation_helper(job, verifier):
                            fixture_return(job, verifier)
                            run(PREPARATION_HELPERS[target], cancellation=job.cancellation,
                                timeout=1, capture_output=target == "gh")

                        patches.enter_context(patch.object(image_vm, "validate_return", use_preparation_helper))

            def inspect_registration(stack, role, release, on_loss=None, attempt=None, before_close=None, **options):
                point = None
                marker = root / "diag-injected"
                if role == "artifact-writer" and pipe_fault:
                    inject_in_call(image_lifecycle.PipeEnd.close.__code__,
                                   lambda local: local["self"] is release.__self__, pipe_fault, marker)
                if role == "qemu-pidfd" and registration_fault and registration_fault != "unusable":
                    inject_in_call(register_owner.__code__, lambda local: local["role"] == role,
                                   registration_fault.removeprefix("rollback:"), root / "registration-injected")
                if role == "qemu-pidfd" and pidfd_fault != "baseline":
                    point = pidfd_fault.split(":")
                    marker = root / "pidfd-injected"
                if on_loss is not None and role != "qemu-pidfd":
                    if len(inventory) == selected:
                        point = phase, kind
                    inventory.append(role)
                    (root / "ownership-inventory").write_text(json.dumps(inventory))
                if point is None:
                    return register_owner(stack, role, release, on_loss, attempt, before_close, **options)

                def fail_close():
                    if role == "qemu-pidfd":
                        started = json.loads((directory / "started.json").read_text())
                        assert not pathlib.Path(f"/proc/{started['qemu'].split(':')[0]}").exists()
                    if point[0] == "after":
                        (attempt or release)()
                    marker.touch()
                    raise DIAGNOSTIC_ERRORS[point[1]]("fixture transport close")

                return register_owner(stack, role, release, on_loss, fail_close, before_close, **options)

            patches.enter_context(patch.object(image_lifecycle, "register_close", inspect_registration))
            patches.enter_context(patch.object(vm_process, "register_close", inspect_registration))
            patches.enter_context(patch.object(vm, "register_close", inspect_registration))
        if mode in STDERR_FLOOD_MODES:
            stderr_fd = None
            console_fd = None
            register = selectors.EpollSelector.register

            def track_probe_stderr(selector, file, events, data=None):
                nonlocal stderr_fd, console_fd
                if data == "diagnostic":
                    stderr_fd = file if isinstance(file, int) else file.fileno()
                if data == "console":
                    console_fd = file
                return register(selector, file, events, data)

            def check_stderr_reader(operation, fd, target):
                if fd == console_fd and mode.endswith("-fault"):
                    (root / "serial-read-fault").touch()
                    raise OSError(errno.EIO, "fixture rejects serial reads")
                if fd == stderr_fd:
                    (root / "stderr-read-attempted").touch()
                    if mode.endswith("-fault"):
                        raise OSError(errno.EIO, "fixture rejects all host stderr reads")
                return operation(fd, target)

            patches.enter_context(patch.object(selectors.EpollSelector, "register", track_probe_stderr))
            patches.enter_context(patch.object(os, "read", partial(check_stderr_reader, os.read)))
            patches.enter_context(patch.object(os, "readv", partial(check_stderr_reader, os.readv)))
        if mode in {"stages:timeout", "stages:before-header", "stages:blocked-header", "isolated:dropped",
                    "isolated:summary-timeout:MemoryError", *STDERR_FLOOD_MODES} or pipe_fault:
            capture = ImageJob.capture
            patches.enter_context(patch.object(ImageJob, "capture", lambda job, process, _: capture(job, process, 2)))
        if mode == "stages:logging-error":
            from image_stages import StageTail
            patches.enter_context(patch.object(StageTail, "observe", side_effect=OSError("fixture observer failure")))
        if mode.count(":") == 2 and mode.startswith(("isolated:", "prestart:")):
            _, operation, kind = mode.split(":")
            failure_type = DIAGNOSTIC_ERRORS[kind]
            def diagnostic_failure():
                if not (root / "diag-injected").exists():
                    (root / "diag-injected").touch()
                    raise failure_type("fixture console fault")
            if mode in PRESTART_MODES:
                tracked = []
                pipe2 = image_lifecycle._PIPE2
                register = selectors.EpollSelector.register
                popen = subprocess.Popen
                stream_registrations = 0

                def reject_guest_spawn(args, *positional, **kwargs):
                    assert child_command(args)[0] != "qemu-system-x86_64", "guest spawn preceded transport setup"
                    return popen(args, *positional, **kwargs)

                def startup_pipe(slots, flags):
                    if operation == "pipe":
                        (root / "prestart-fds").write_text("[]")
                        diagnostic_failure()
                    status = pipe2(slots, flags)
                    if status == 0:
                        tracked.extend(os.readlink(f"/proc/self/fd/{fd}") for fd in slots)
                    return status

                def fail_register(selector, file, events, data=None):
                    nonlocal stream_registrations
                    if data == "stream":
                        stream_registrations += 1
                    if (data == operation or (data, operation) == ("console", "console-after-register")
                            or (data, operation, stream_registrations) == ("stream", "artifact-selector", 2)):
                        assert not (root / "pid").exists()
                        (root / "prestart-fds").write_text(json.dumps(tracked))
                        if operation == "console-after-register":
                            register(selector, file, events, data)
                        diagnostic_failure()
                    return register(selector, file, events, data)
                patches.enter_context(patch.object(image_lifecycle, "_PIPE2", startup_pipe))
                patches.enter_context(patch.object(selectors.EpollSelector, "register", fail_register))
                patches.enter_context(patch.object(subprocess, "Popen", reject_guest_spawn))
            elif operation == "read":
                original_read = os.read
                def fail_read(fd, length):
                    console_fd = root / "console-inode"
                    if console_fd.exists() and os.readlink(f"/proc/self/fd/{fd}") == console_fd.read_text():
                        diagnostic_failure()
                    return original_read(fd, length)
                patches.enter_context(patch.object(os, "read", fail_read))
            elif operation == "read-dispatch":
                reader = ImageJob.read_console

                def lookup_reader(job):
                    diagnostic_failure()
                    return reader.__get__(job, ImageJob)

                patches.enter_context(patch.object(ImageJob, "read_console", property(lookup_reader)))
            elif operation.startswith("backup-selector-close-"):
                close = selectors.EpollSelector.close

                def fail_backup_close(selector):
                    if (directory / "artifacts/verification.json").exists() and {
                        key.data for key in selector.get_map().values()
                    } == {"stream"}:
                        if operation.endswith("-before"):
                            diagnostic_failure()
                        close(selector)
                        diagnostic_failure()
                        return
                    close(selector)

                patches.enter_context(patch.object(selectors.EpollSelector, "close", fail_backup_close))
            elif operation.startswith("unregister"):
                unregister = selectors.EpollSelector.unregister
                attempts = []
                checks = 0

                def fail_console_eof(selector, file):
                    if selector.get_key(file).data == "console":
                        attempts.append(time.monotonic())
                        if mode in UNREGISTER_MODES:
                            (root / "unregister-attempts").write_text(json.dumps(attempts))
                        if len(attempts) == (2 if mode in UNREGISTER_MODES else 1):
                            with (root / "unregister-ready").open("wb", buffering=0) as ready:
                                ready.write(b"1")
                        if operation == "unregister-always" and len(attempts) > 1:
                            raise OSError("fixture persistent unregister failure")
                        diagnostic_failure()
                    return unregister(selector, file)

                def observe_disk_checks(*_args):
                    nonlocal checks
                    checks += 1
                    if checks > 16:
                        raise AssertionError(f"console EOF spun through {checks} disk checks")

                patches.enter_context(patch.object(selectors.EpollSelector, "unregister", fail_console_eof))
                if mode in UNREGISTER_MODES:
                    patches.enter_context(patch.object(image_lifecycle, "disk_headroom", observe_disk_checks))
            elif operation.startswith(("alloc-", "reader-cleanup-")):
                if operation.startswith("reader-cleanup-"):
                    target_code, target_offset = READER_CLEANUP, int(operation.rsplit("-", 1)[1])
                else:
                    target_code, target_offset = SUMMARY_ALLOCATION_SITES[operation.removeprefix("alloc-")]
                monitor = sys.monitoring
                tool_id = monitor.DEBUGGER_ID
                monitor.use_tool_id(tool_id, "probe diagnostic statement fault")

                def inject_statement(_code, offset):
                    if offset == target_offset:
                        diagnostic_failure()

                monitor.register_callback(tool_id, monitor.events.INSTRUCTION, inject_statement)
                monitor.set_local_events(tool_id, target_code, monitor.events.INSTRUCTION)
            elif operation in {"encode-empty", "encode-tail"}:
                iterencode = json.JSONEncoder.iterencode

                def fail_encode(encoder, row, *args, **kwargs):
                    if (root / "pid").exists() and "console_tail" in row:
                        if (root / "diag-injected").exists():
                            (root / "late-fallback-encoding").touch()
                            raise MemoryError("fixture tried to re-encode diagnostic defaults")
                        if bool(row["console_tail"]) == (operation == "encode-tail"):
                            diagnostic_failure()
                    return iterencode(encoder, row, *args, **kwargs)

                patches.enter_context(patch.object(json.JSONEncoder, "iterencode", fail_encode))
            elif operation.startswith("encode-"):
                target_offset = int(operation.rsplit("-", 1)[1])
                monitor = sys.monitoring
                tool_id = monitor.DEBUGGER_ID
                monitor.use_tool_id(tool_id, "probe encode statement fault")

                def inject_encode(_code, offset):
                    if offset == target_offset and (root / "pid").exists():
                        diagnostic_failure()

                monitor.register_callback(tool_id, monitor.events.INSTRUCTION, inject_encode)
                monitor.set_local_events(tool_id, image_lifecycle.encode_diagnostic_fields.__code__,
                                         monitor.events.INSTRUCTION)
            elif operation in {"summary", "summary-timeout", "fallback", "text", "drain"}:
                owner, method = {
                    "text": (image_lifecycle.StageTail, "text"), "drain": (ImageJob, "drain"),
                }.get(operation, (ImageJob, "diagnostic_summary"))
                inject = property(lambda _: diagnostic_failure()) if operation == "fallback" else (
                    lambda *_: diagnostic_failure())
                patches.enter_context(patch.object(owner, method, inject))
            elif operation == "close":
                boundary = image_lifecycle.close_transport

                def fail_after_close(release, on_loss=None, attempt=None):
                    def close_then_fail():
                        (attempt or release)()
                        diagnostic_failure()

                    return boundary(release, on_loss, close_then_fail if on_loss else attempt)

                patches.enter_context(patch.object(image_lifecycle, "close_transport", fail_after_close))
            else:
                boundary = image_lifecycle.optional
                def fault_boundary(on_loss, action, *args, **kwargs):
                    if action.__name__ == operation:
                        original = action
                        def action(*args, **kwargs):
                            # Close through the real syscall before reporting a close error.
                            if original.__name__ == "close":
                                original(*args, **kwargs)
                            diagnostic_failure()
                            if original.__name__ != "close":
                                return original(*args, **kwargs)
                    return boundary(on_loss, action, *args, **kwargs)
                patches.enter_context(patch.object(image_lifecycle, "optional", fault_boundary))
        if tail_case:
            native_write, native_pread, native_read = os.write, os.pread, image_lifecycle.read_once
            native_signal = signal.signal
            native_pending = signal.sigpending
            native_mkdir = pathlib.Path.mkdir
            frame_cuts = ()
            if tail_case[0].startswith("frame-read-"):
                frame = (root / "probe.frame").read_bytes()
                header_end = frame.index(b"\n", len(MAGIC)) + 1
                trailer = frame.index(b'{"id":"manifest"', header_end)
                frame_cuts = (len(MAGIC), header_end, 128 * 1024, trailer,
                              frame.index(b"\n", trailer) + 1, len(frame))

            def tail_pread(fd, size, offset):
                if frame_cuts and os.readlink(f"/proc/self/fd/{fd}") == str(directory / "stream.partial"):
                    frame_offsets.add(offset)
                    tail_fault(f"frame-read-{offset}")
                    size = min(size, next((cut - offset for cut in frame_cuts if cut > offset), size))
                return native_pread(fd, size, offset)

            def tail_pending():
                if receipt_phase(sys._getframe(1)) == "exit":
                    tail_signal_at("checkpoint")
                return native_pending()

            def tail_read(fd, size):
                caller = sys._getframe(1)
                if caller.f_code is ImageJob.capture.__code__ and caller.f_locals.get("name") == "stream":
                    tail_fault("live-stream-read")
                return native_read(fd, size)

            def tail_signal(sig, handler):
                if sig == signal.SIGUSR1 and handler == signal.SIG_IGN:
                    tail_fault("exit-ignore")
                return native_signal(sig, handler)

            def tail_mkdir(path, *args, **kwargs):
                assert not (root / "pid").exists(), f"directory created after spawn: {path}"
                name = {root / "returns": "store", directory.parent: "attempt",
                        directory: "build", directory / "artifacts": "artifacts",
                        directory.parent / "verify": "verify",
                        directory.parent / "verify/artifacts": "verify-artifacts"}.get(path)
                if name:
                    tail_fault(f"mkdir-{name}")
                return native_mkdir(path, *args, **kwargs)

            def tail_open(path, flags, *args, **kwargs):
                phase = receipt_phase(sys._getframe(1))
                if phase:
                    point = f"{phase}-{'dir' if flags & os.O_DIRECTORY else 'file'}-open"
                    tail_signal_at(point)
                    tail_fault(point)
                if path == directory / "artifacts/verification.json" and flags & os.O_EXCL:
                    tail_fault("artifact-open")
                if path == directory / "stream.partial" and flags & os.O_EXCL:
                    tail_fault("capture-open")
                return native_open(path, flags, *args, **kwargs)

            def tail_close(fd):
                phase = receipt_phase(sys._getframe(1))
                directory_fd = os.path.isdir(f"/proc/self/fd/{fd}") if phase else False
                target = os.readlink(f"/proc/self/fd/{fd}") if sys._getframe(1).f_code.co_name == "close" else ""
                native_close(fd)
                if phase:
                    point = f"{phase}-{'dir' if directory_fd else 'file'}-close"
                    tail_signal_at(point)
                    tail_fault(point)
                if target == str(directory / "artifacts/verification.json"):
                    tail_fault("artifact-close")
                if target == str(directory / "stream.partial"):
                    tail_fault("capture-close")

            def tail_write(fd, data):
                phase = receipt_phase(sys._getframe(1))
                if phase:
                    tail_fault(f"{phase}-write")
                else:
                    target = os.readlink(f"/proc/self/fd/{fd}")
                    if target == str(directory / "artifacts/verification.json"):
                        tail_fault("artifact-write")
                    if target == str(directory / "stream.partial"):
                        tail_fault("capture-write")
                return native_write(fd, data)

            def tail_partial(fn, *args, **kwargs):
                if fn is os.close:
                    fd_target = os.readlink(f"/proc/self/fd/{args[0]}")
                    if fd_target == str(directory):
                        tail_fault("exit-close-allocation")
                    if fd_target == str(root / "returns"):
                        tail_fault("journal-close-allocation")
                return partial(fn, *args, **kwargs)

            patches.enter_context(patch.object(image_lifecycle, "partial", tail_partial))
            patches.enter_context(patch.object(os, "open", tail_open))
            patches.enter_context(patch.object(image_lifecycle, "read_once", tail_read))
            patches.enter_context(patch.object(os, "close", tail_close))
            patches.enter_context(patch.object(os, "write", tail_write))
            patches.enter_context(patch.object(os, "pread", tail_pread))
            patches.enter_context(patch.object(signal, "signal", tail_signal))
            patches.enter_context(patch.object(signal, "sigpending", tail_pending))
            patches.enter_context(patch.object(pathlib.Path, "mkdir", tail_mkdir))
        if teardown_fault:
            wall_time = time.time
            directory_sync = image_lifecycle.sync_directory

            def teardown_time():
                if sys._getframe(1).f_code is ImageJob.__exit__.__code__:
                    teardown_memory("timestamp")
                return wall_time()

            def teardown_directory_sync(path):
                if sys._getframe(1).f_code is image_lifecycle.retire_journal.__code__:
                    teardown_memory("journal-sync")
                return directory_sync(path)

            patches.enter_context(patch.object(time, "time", teardown_time))
            patches.enter_context(patch.object(image_lifecycle, "sync_directory", teardown_directory_sync))
        if commit_fault:
            path_join = pathlib.Path.__truediv__

            def guard_commit_path(path, child):
                joined = path_join(path, child)
                if joined == exit_path and sys._getframe(1).f_globals.get("__name__") == image_vm.__name__:
                    assert not (root / "pid").exists(), "exit destination was allocated after spawn"
                    (root / "commit-path-prepared").touch()
                return joined

            exit_path = directory / "exit.json"
            patches.enter_context(patch.object(pathlib.Path, "__truediv__", guard_commit_path))
        patches.enter_context(patch.object(vm_startup, "verify_startup", fixture_verify))
        patches.enter_context(patch.object(
            vm_process, "TERM_GRACE_SECONDS",
            0.2 if startup == "resistant" or signal_fault and mode == "ignore" or mode == "stages:priority-kill-fast"
            else vm_process.TERM_GRACE_SECONDS))
        patches.enter_context(patch.object(selectors.EpollSelector, "_selector_cls", staticmethod(poller)))
        for patcher in (
            patch.object(image_lifecycle, "RECEIPT_STEPS", table),
            patch.object(image_lifecycle, "receipt", writer),
            patch.object(image_vm, "receipt", writer),
            patch.object(image_vm, "run_image", image_entry),
            patch.object(os, "_exit", terminal_exit if trace_terminal else audited_exit if audit_receipts
                         else checked_exit if check_descriptors else real_exit),
            patch.object(os, "replace", publish),
            patch.object(signal, "pthread_sigmask", mask),
             patch.object(os, "fsync", sync), patch("image_stream.sync_once", sync),
            patch.object(pathlib.Path, "unlink", remove),
             patch.object(os, "unlink", remove_owned),
            patch.object(tempfile, "TemporaryFile", overlay),
            patch.object(pathlib.Path, "read_text", read_result),
            patch.object(pathlib.Path, "read_bytes", fixture_read_bytes),
            *(() if child_fault and child_fault.partition(":")[0] in PREPARATION_HELPERS
              else (patch.object(image_vm, "validate_return", fixture_return),)),
            patch.multiple(image_vm, require_host_lock=lambda: None, cgroup_admission=lambda: None,
                           disk_admission=lambda *_args: None, disk_headroom=lambda *_args: None),
            patch.object(image_vm, "load_policy", return_value=FixturePolicy()),
            *(() if mode in UNREGISTER_MODES else (patch.object(image_lifecycle, "disk_headroom"),)),
            patch.object(image_lifecycle, "process_priority",
                         side_effect=(priority_timeout
                                      if mode.startswith("stages:priority-")
                                      else priority_sample),
                         return_value=FIXTURE_PRIORITY),
            patch.object(image_resources, "require_process_priority", return_value=FIXTURE_PRIORITY["nice"]),
            patch.object(image_resources, "cgroup_limits", return_value=FIXTURE_PRIORITY["cpu_weight"]),
        ):
            patches.enter_context(patcher)
        runpy.run_path(sys.argv[0], run_name="__main__")


@dataclass(frozen=True, slots=True)
class FixturePolicy:
    root_der_sha256: str = "d" * 64


def cancelled_fixture(mode: str, signum: signal.Signals = signal.SIGTERM, *,
                      blocked: tuple[signal.Signals, ...] = (),
                      ignored: tuple[signal.Signals, ...] = (),
                      entry_setup: str | None = None, full_stderr: bool = False,
                      ownership_case: tuple[int, str, str] | None = None,
                      pidfd_case: str | None = None, pipe_fault: str = "",
                      registration_fault: str = "", signal_fault: str = "",
                      child_fault: str = "") -> dict | None:
    with tempfile.TemporaryDirectory() as tmp, ExitStack() as launch_io:
        root = pathlib.Path(tmp)
        child_target = child_fault.partition(":")[0]
        qemu_fault = child_target == "qemu-system-x86_64"
        boot_fault = qemu_fault and ":boot/" in child_fault
        lost_already_collected = ":lost-already-collected:" in child_fault
        lost_return = ":lost-return:" in child_fault or lost_already_collected
        sweep = ":sweep" in child_fault
        priority_failure = mode.startswith("stages:priority-")
        if mode.startswith("tail-io:"):
            os.mkfifo(root / "tail-priority-ready")
        if waits_for_guest_ready(mode) or priority_failure or mode == "isolated:exclusive" or qemu_fault:
            os.mkfifo(root / "guest-ready")
        if mode.startswith("isolated:unregister"):
            os.mkfifo(root / "unregister-ready")
        if ownership_case is not None:
            (root / "ownership-case").write_text(json.dumps(ownership_case))
        if pidfd_case is not None:
            (root / "pidfd-case").write_text(pidfd_case)
        if pipe_fault:
            (root / "pipe-fault").write_text(pipe_fault)
        if registration_fault:
            (root / "registration-fault").write_text(registration_fault)
        if signal_fault:
            (root / "signal-fault").write_text(signal_fault)
        if child_fault:
            (root / "child-fault").write_text(child_fault)
        capsule = root / "capsule"
        if mode.startswith("pair:"):
            with tarfile.open(capsule, "w") as archive:
                data = b'{"objects":[]}'
                header = tarfile.TarInfo("inventory.json")
                header.size = len(data)
                archive.addfile(header, io.BytesIO(data))
        else:
            capsule.write_bytes(b"public fixture")
        base = root / "base"
        base.write_bytes(b"public base")
        base.chmod(0o444)
        identity = replace(IDENTITY, input_sha256=hashlib.sha256(capsule.read_bytes()).hexdigest())
        probe_body = json.dumps({
            "schema": 1, "identity": asdict(identity), "network_denied": True,
        }).encode()
        frame = io.BytesIO()
        encode(frame, [("verification.json", probe_body)], identity)
        if mode.startswith(("isolated:sink-large-", "tail-io:frame-read-")):
            padding = 787274 - frame.tell()
            for _ in range(2):
                frame = io.BytesIO()
                encode(frame, [("verification.json", probe_body + b" " * padding)], identity)
                if frame.tell() == 787274:
                    probe_body += b" " * padding
                    break
                padding += 787274 - frame.tell()
            assert frame.tell() == 787274
        (root / "probe.frame").write_bytes(frame.getvalue())
        qemu_img = root / "qemu-img"
        qemu_img.write_text(f"""#!{sys.executable}
import json, os, pathlib, signal, sys, time
root = pathlib.Path({tmp!r})
(root / ("status-" + sys.argv[1])).write_text(pathlib.Path(f"/proc/{{os.getpid()}}/status").read_text())
if sys.argv[1] == "info":
    print(json.dumps({{"format": "qcow2", "virtual-size": 137438953472}}))
elif sys.argv[1] == "create":
    if {mode!r} == "overlay":
        root = pathlib.Path({tmp!r})
        (root / "pid").write_text(str(os.getpid()))
        inventory = root / "owned-fds.tmp"
        inventory.write_text(json.dumps([os.readlink(sys.argv[-1])]))
        inventory.replace(root / "owned-fds")
        (root / "sent").write_text(str(time.monotonic()))
        os.kill(os.getppid(), signal.SIGTERM)
        time.sleep(60)
else:
    sys.exit(2)
""")
        qemu_img.chmod(0o700)
        qemu = root / "qemu-system-x86_64"
        qemu.write_text(f"""#!{sys.executable}
import fcntl, json, os, pathlib, signal, sys, time
root = pathlib.Path({tmp!r})
mode = {mode!r}
(root / "status-qemu").write_text(pathlib.Path(f"/proc/{{os.getpid()}}/status").read_text())
if mode.startswith("startup:"):
    arg = next(arg for arg in sys.argv if ",id=image-input," in arg)
    capsule = pathlib.Path(arg.split(",")[0].split("=")[1])
    expected = (root / "capsule").stat()
    attached = capsule.stat()
    unexpected = []
    for fd in pathlib.Path("/proc/self/fd").iterdir():
        try:
            target = os.readlink(fd)
        except FileNotFoundError:
            continue
        if "/extra" in target or target == (root / "pipe-id").read_text():
            unexpected.append(target)
    (root / "child-baseline").write_text(json.dumps({{
        "capsule": capsule.name not in ("0", "1", "2") and
                   (attached.st_dev, attached.st_ino) == (expected.st_dev, expected.st_ino),
        "extra_fds": unexpected, "lang": os.environ["LANG"], "cwd": os.getcwd(),
        "umask": os.umask(0o077),
    }}))
def term(_signum, _frame):
    (root / "term").touch()
    if mode == "repeat":
        os.kill(os.getppid(), signal.SIGTERM)
    if mode.startswith("startup:"):
        if mode in ("startup:cancel", "startup:delayed-cancel"):
            if mode == "startup:delayed-cancel":
                # Exercise the old fixture's shortened grace deterministically.
                time.sleep(0.4)
            sys.exit(37)
    elif mode != "ignore":
        sys.exit(0)
if mode != "slow":
    signal.signal(signal.SIGTERM, term)
if {priority_failure or boot_fault!r}:
    signal.pthread_sigmask(signal.SIG_BLOCK, {{signal.SIGTERM}})
fds = {{1, 2}} | {{int(arg.split("/proc/self/fd/")[1].split(",")[0])
                   for arg in sys.argv if "/proc/self/fd/" in arg}}
fds.update(int(arg.split("/dev/fdset/")[1]) for arg in sys.argv if "/dev/fdset/" in arg)
inventory = root / "owned-fds.tmp"
inventory.write_text(json.dumps([os.readlink(f"/proc/self/fd/{{fd}}") for fd in fds]))
inventory.replace(root / "owned-fds")
(root / "pid").write_text(str(os.getpid()))
with (root / "children").open("a") as logged:
    print(os.getpid(), file=logged)
(root / "ready").touch()
if mode.startswith("startup:") and signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0):
    (root / "startup-ready").touch()
if {priority_failure!r}:
    console = int(sys.argv[sys.argv.index("-serial") + 1].rsplit("/", 1)[1])
    os.set_blocking(console, True)
    payload = b"STAGE 1 probe_start 0\\r\\n" * 4000
    assert len(payload) == 92000
    with (root / "guest-ready").open("wb", buffering=0) as ready:
        ready.write(b"1")
    assert signal.sigwait({{signal.SIGTERM}}) == signal.SIGTERM
    (root / "term-before-write").write_text(str(time.monotonic()))
    if mode.startswith("stages:priority-kill"):
        assert fcntl.fcntl(console, fcntl.F_SETPIPE_SZ, 4096) == 4096
        os.write(console, payload)
        raise AssertionError("undrained serial write unexpectedly completed")
    term(signal.SIGTERM, None)
if {(waits_for_guest_ready(mode) or mode == "isolated:exclusive" or qemu_fault) and not (boot_fault or sweep or priority_failure)!r}:
    with (root / "guest-ready").open("wb", buffering=0) as ready:
        ready.write(b"1")
if {lost_return and qemu_fault!r}:
    time.sleep(60)
if mode in ("startup:success", "startup:failure", "startup:signal"):
    os.write(1, (root / "probe.frame").read_bytes())
    if mode == "startup:signal":
        os.kill(os.getpid(), signal.SIGUSR1)
    sys.exit(37 if mode == "startup:failure" else 0)
if mode.startswith("pair:"):
    payload = json.loads(pathlib.Path(sys.argv[sys.argv.index("-fw_cfg") + 1].split("file=")[1]).read_text())
    if payload["operation"] == "verify":
        sys.path.insert(0, {str(ROOT / 'ci/kernel-runner')!r})
        from image_stream import Identity, encode
        result = {{"schema": 1, "verified": True, "build_identity": payload["build_identity"],
                  "artifacts": payload["artifacts"], "slots": [{{"slot": "rootfs_a"}}, {{"slot": "rootfs_b"}}]}}
        encode(sys.stdout.buffer, [("verification.json", json.dumps(result).encode())],
               Identity(**payload["identity"]))
    sys.exit(0)
if mode in (*{ISOLATION_MODES!r}, "isolated:validated-helper") and mode != "isolated:summary-timeout:MemoryError":
    serial = sys.argv[sys.argv.index("-serial") + 1]
    if serial != "null":
        console = int(serial.rsplit("/", 1)[1])
        (root / "console-inode").write_text(os.readlink(f"/proc/self/fd/{{console}}"))
        def serial_write(data):
            try:
                os.write(console, data)
            except OSError:
                pass
        if mode != "isolated:baseline" and not mode.startswith("isolated:encode-empty"):
            serial_write(b"STAGE 1 probe_start 0 1\\n")
            serial_write(b"STAGE 2 stream_close_end 0 " + (b"3" if mode == "isolated:gap" else b"2") + b"\\n")
        if mode.startswith("isolated:unregister"):
            os.close(console)
            with (root / "unregister-ready").open("rb", buffering=0) as ready:
                assert ready.read(1) == b"1"
    if mode in {STDERR_FLOOD_MODES!r}:
        assert not os.get_blocking(console)
        if mode.endswith("-fault"):
            try:
                for _ in range(16):
                    os.write(console, b"z" * 65537)
            except BlockingIOError:
                (root / "serial-would-block").touch()
        if not mode.endswith("-baseline"):
            size = 4 * 1024 * 1024 if "-large-" in mode else 65537
            data = b"x" * size
            sent = 0
            while sent < size:
                sent += os.write(2, data[sent:])
            (root / "stderr-written").write_text(str(sent))
        (root / "stderr-target").write_text(os.readlink("/proc/self/fd/2"))
        if "-large-" in mode:
            fcntl.fcntl(1, fcntl.F_SETPIPE_SZ, 4096)
    if mode != "isolated:dropped":
        frame = (root / "probe.frame").read_bytes()
        sent = 0
        while sent < len(frame):
            sent += os.write(1, frame[sent:])
        if {qemu_fault and (sweep or boot_fault)!r}:
            with (root / "guest-ready").open("wb", buffering=0) as ready:
                ready.write(b"1")
        if {boot_fault!r}:
            assert signal.sigwait({{signal.SIGTERM}}) == signal.SIGTERM
            term(signal.SIGTERM, None)
        sys.exit(0)
if mode in {STAGE_MODES!r} or mode in ("isolated:dropped", "isolated:summary-timeout:MemoryError"):
    console = int(sys.argv[sys.argv.index("-serial") + 1].rsplit("/", 1)[1])
    os.set_blocking(console, True)
    if mode in ("stages:at-cap", "stages:over-cap"):
        os.write(1, (root / "probe.frame").read_bytes())
        for _ in range(128):
            os.write(console, b"x" * (64 * 1024 - 1) + b"\\n")
        if mode == "stages:over-cap":
            os.write(console, b"STAGE 2 stream_close_end 0\\n")
        sys.exit(0)
    os.write(console, b"STAGE 1 probe_start 0\\r\\n" * 4000)
    os.write(console, b"Bearer FIXTURE_NOT_A_REAL_SECRET\\n" + b"x" * (70 * 1024) + b"\\n")
    os.write(console, b"STAGE 2 magic_writ")
    os.write(console, b"ten 25\\r\\n")
    if mode in ("stages:before-header", "stages:blocked-header", "isolated:dropped"):
        sys.path.insert(0, {str(ROOT / 'ci/kernel-runner')!r})
        from image_stages import StageLog
        from image_stream import Identity, MAGIC, encode
        reader, writer = os.pipe()
        capacity = fcntl.fcntl(writer, fcntl.F_GETPIPE_SZ)
        assert os.write(writer, b"x" * capacity) == capacity

        class BlockedHeader:
            def write(self, data):
                if data == MAGIC:
                    return os.write(1, data)
                (root / "header-write-entered").touch()
                count = os.write(writer, data)
                (root / "header-write-returned").touch()
                return count

        import image_stages
        image_stages.CONSOLE = pathlib.Path(f"/proc/self/fd/{{console}}")
        # Feed the real logger's serial records to the stand-in console.
        class ConsoleStages(StageLog):
            def _write(self, line):
                if mode == "stages:before-header" and b" member_prepare_begin " in line:
                    (root / "member-prepare-entered").touch()
                if mode == "isolated:dropped" and b" member_header_begin " in line:
                    (root / "header-marker-dropped").write_bytes(line)
                    raise BlockingIOError("fixture dropped marker")
                return os.write(console, line) == len(line)

        value = b"{{}}"
        if mode == "stages:before-header":
            value = root / "blocked-input"
            os.mkfifo(value)
        encode(BlockedHeader(), [("verification.json", value)],
               Identity("fixture", "rock-5b-plus", "a" * 40, 1, "b" * 64), ConsoleStages().emit)
        sys.exit(3)
    if mode == "stages:guest-loss":
        os.write(console, b"STAGE 3 diagnostics_lost 0\\n")
    if mode not in ("stages:timeout", "isolated:summary-timeout:MemoryError"):
        os.write(1, (root / "probe.frame").read_bytes())
        os.write(console, b"STAGE 3 stream_close_end 0\\n")
        if {bool(signal_fault)!r}:
            signal.pause()
        sys.exit(0)
    os.write(1, b"CERALIVE_IMAGE_STREAM_V1\\n")
if mode in (*{SUCCESS_GUEST_MODES!r}, "audit-mutation") or mode.startswith(
        ("fault:", "receipt-step:", "readback:", "teardown-memory:", "commit-memory:", "tail-io:")):
    if mode.startswith("tail-io:"):
        # Keep the guest alive until its first I/O priority sample.
        assert (root / "tail-priority-ready").read_bytes() == b"1"
    os.write(1, (root / "probe.frame").read_bytes())
    sys.exit(0)
while True:
    signal.pause()
""")
        qemu.chmod(0o700)
        if child_target in PREPARATION_HELPERS:
            helper = root / "fixture-helper"
            helper.write_text(f"#!{sys.executable}\nimport signal\nsignal.pause()\n")
            helper.chmod(0o700)

        # A private flock gives the real CLI its required direct parent without
        # participating in workstation admission or touching the real host lock.
        command = ["flock", "--exclusive", "--close", str(root / "fixture.lock"), sys.executable,
                   __file__, "--fixture-launcher", str(root), mode, str(signum.value)]
        if entry_setup is not None:
            setup = f"""
import ctypes, os, pathlib, signal, sys
root = pathlib.Path(sys.argv[1])
(root / "pipe-id").write_text("")
{entry_setup}
os.execv(sys.executable, [sys.executable, *sys.argv[2:]])
"""
            command = [*command[:5], "-c", setup, str(root), str(pathlib.Path(__file__).resolve()), *command[6:]]
        if blocked or ignored:
            # exec keeps flock as the launcher's direct parent and passes on
            # the calling process's mask and ignored dispositions.
            setup = f"""
import os, signal, sys
for signum in {tuple(map(int, ignored))!r}:
    signal.signal(signum, signal.SIG_IGN)
signal.pthread_sigmask(signal.SIG_BLOCK, {tuple(map(int, blocked))!r})
os.execvp(sys.argv[1], sys.argv[1:])
"""
            command = [sys.executable, "-c", setup, *command]
        stderr_target = subprocess.PIPE
        if full_stderr:
            read_end, stderr_target = os.pipe()
            launch_io.callback(os.close, read_end)
            launch_io.callback(os.close, stderr_target)
            capacity = fcntl.fcntl(stderr_target, fcntl.F_GETPIPE_SZ)
            assert os.write(stderr_target, b"x" * capacity) == capacity
        with subprocess.Popen(
            command,
            env={"PATH": f"{root}:/usr/bin:/bin", "TMPDIR": tmp, "PYTHONDONTWRITEBYTECODE": "1"},
            start_new_session=True, stdout=subprocess.PIPE, stderr=stderr_target,
        ) as launcher:
            seconds = 27 if mode in {"ignore", "stages:priority-kill"} else 5 if full_stderr else 8
            try:
                _, stderr = launcher.communicate(timeout=seconds)
                stderr = stderr or b""
            except subprocess.TimeoutExpired as error:
                if full_stderr:
                    marker = root / "returns/fixture/build/exit.json"
                    assert marker.exists(), "timeout occurred before receipt publication"
                    raise AssertionError("launcher blocked on full stderr after committing exit.json") from error
                if not (root / "sent").exists():
                    proc = pathlib.Path("/proc")
                    observed = {}
                    guest = (root / "pid").read_text() if (root / "pid").exists() else None
                    for entry in proc.iterdir():
                        if not entry.name.isdecimal():
                            continue
                        try:
                            status = (entry / "stat").read_text().rsplit(")", 1)[1].split()
                            if int(status[2]) == launcher.pid or entry.name == guest:
                                observed[entry.name] = (status[:4], (entry / "wchan").read_text(),
                                                        signal_status(entry / "status"))
                        except (FileNotFoundError, ProcessLookupError):
                            continue
                    raise AssertionError(("fixture timed out before cancellation", mode, child_fault,
                                          sorted(p.name for p in root.iterdir()), observed,
                                          error.stderr)) from error
                pid = (root / "pid").read_text()
                assert pathlib.Path(f"/proc/{pid}").exists()
                assert not (root / "returns/fixture/build/exit.json").exists()
                raise AssertionError("cancellation left the QEMU child alive and no exit receipt") from error
            finally:
                if launcher.poll() is None:
                    if (root / "pid").exists():
                        pid = int((root / "pid").read_text())
                        try:
                            handle = os.pidfd_open(pid)
                            try:
                                parent = int(pathlib.Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])
                                if parent in {launcher.pid, *map(int, pathlib.Path(
                                    f"/proc/{launcher.pid}/task/{launcher.pid}/children").read_text().split())}:
                                    signal.pidfd_send_signal(handle, signal.SIGKILL)
                            finally:
                                os.close(handle)
                        except ProcessLookupError:
                            pass
                    try:
                        launcher.communicate(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(launcher.pid, signal.SIGKILL)
                        launcher.communicate()

        directory = root / "returns/fixture/build"
        if mode.startswith("tail-io:"):
            point, error, count, *_ = mode.removeprefix("tail-io:").split("/")
            marker = directory / "exit.json"
            required_exhaustion = (point == "verification-read" and int(count) == 3
                                   or point == "exit-file-fsync" and int(count) >= 2)
            live_exhausted = point == "live-stream-read" and int(count) == 3
            required_memory_fault = error == "MemoryError" and (
                point == "verification-read" or point.startswith(("teardown-", "validation-")))
            checkpoint_cancelled = mode == "tail-io:exit-mask/EINTR/0/checkpoint"
            failed = (required_exhaustion or live_exhausted or required_memory_fault or point.endswith("-temp-unlink")
                      or checkpoint_cancelled
                      or point.startswith("rejected-fd-line-") or point == "exit-ignore" and int(count) == 3)
            assert launcher.returncode == int(failed), (mode, launcher.returncode, stderr)
            row = json.loads(marker.read_text()) if marker.exists() else None
            if row is not None:
                assert row["launcher_exit"] == launcher.returncode
                assert row["qemu_reaped"]
                if live_exhausted:
                    assert row["stream_bytes"] == 0
                    assert row["stop_reason"] == "StreamError"
                else:
                    assert row["qemu_exit"] == 0 and row["stream_bytes"] == frame.tell()
                assert row["qemu_priority"] == FIXTURE_PRIORITY
            else:
                assert failed
            artifact = directory / "artifacts/verification.json"
            if live_exhausted:
                assert row is not None and not artifact.exists()
            else:
                assert artifact.read_bytes() == probe_body
            assert json.loads((root / "launcher-children").read_text()) == []
            initial, final = json.loads((root / "descriptor-check").read_text())
            assert initial == final, (mode, initial, final, stderr)
            assert not list(root.rglob(".receipt-*"))
            if point == "exit-mask":
                fallback = int(count) == 3 or error == "ENOSYS"
                assert (b"catchable signals ignored" in stderr) == fallback
                assert (root / "tail-signal-sent").exists()
                if mode.endswith("/checkpoint"):
                    assert (row["stop_reason"] == "cancelled") == checkpoint_cancelled
            if point == "exit-ignore":
                assert (root / "tail-signal-sent").exists() is (not failed)
            if point.endswith("-allocation") or int(count) == 0:
                assert not (root / "tail-fault-count").exists(), (mode, stderr)
            else:
                expected_count = 2 if point == "exit-file-fsync" and required_exhaustion else int(count)
                assert int((root / "tail-fault-count").read_text()) == expected_count, (mode, stderr)
            active = root / "returns/active.json"
            if point == "journal-unlink" and int(count) == 3:
                assert active.exists() and b"journal_removed=false" in stderr
                scan = image_lifecycle.list_directory
                with patch.object(image_lifecycle, "list_directory", side_effect=lambda path, **kwargs:
                                  [str(os.getpid())] if path == image_lifecycle.PROC_ROOT else scan(path, **kwargs)):
                    reconcile(active.parent)
                assert (active.parent / "fixture.reconciled.json").exists()
            assert not active.exists()
            if point.endswith("-fd-line-baseline"):
                return json.loads((root / "live-receipt-lines").read_text())
            if (point.endswith(("-sync", "-fsync")) and error != "MemoryError"
                    and getattr(errno, error) in UNSUPPORTED_SYNC):
                assert b"durability=unsupported" in stderr, (mode, stderr)
            if row is not None:
                for key in ("acquired_at", "started_at", "ended_at", "base", "launcher", "qemu",
                            "overlay_directory", "overlay_inode", "overlay_fd"):
                    row.pop(key, None)
            if point == "frame-read-baseline":
                return {"offsets": json.loads((root / "frame-offsets").read_text()), "row": row}
            return row
        if sweep:
            initial, final = json.loads((root / "descriptor-check").read_text())
            assert initial == final, (child_fault, initial, final, stderr)
            assert json.loads((root / "launcher-children").read_text()) == []
            fault_pid = (root / "fault-pid").read_text()
            assert not pathlib.Path(f"/proc/{fault_pid}").exists(), (child_fault, fault_pid)
            assert not (root / "returns/active.json").exists()
            teardown = json.loads((directory / "teardown.json").read_text())
            assert teardown["input_descriptor_closed"] and teardown["overlay_descriptor_closed"]
            if not qemu_fault or ":sweep-baseline:" in child_fault:
                assert (directory / "artifacts/verification.json").read_bytes() == probe_body
            if ":sweep-baseline:" in child_fault:
                assert launcher.returncode == json.loads((directory / "exit.json").read_text())["launcher_exit"] == 0
                return {"points": (root / "sweep-points").read_text().splitlines()}
            assert (root / "child-injected").exists(), (child_fault, stderr)
            if (root / "sweep-optional").exists():
                assert launcher.returncode == json.loads((directory / "exit.json").read_text())["launcher_exit"] == 0
                assert (directory / "artifacts/verification.json").read_bytes() == probe_body
                return
            assert launcher.returncode == 1, (child_fault, stderr)
            if (directory / "exit.json").exists():
                assert json.loads((directory / "exit.json").read_text())["launcher_exit"] == launcher.returncode
            return
        if signal_fault or child_fault:
            assert (root / ("signal-injected" if signal_fault else "child-injected")).exists(), stderr
            assert json.loads((root / "launcher-children").read_text()) == [], (mode, signal_fault, child_fault, stderr)
            assert not (root / "returns/active.json").exists()
            wait_log = root / "launcher-waits"
            waits = wait_log.read_text().splitlines() if wait_log.exists() else []
            if child_fault:
                setup_operation = child_fault.split(":")[1]
                after_spawn = lost_return or setup_operation.startswith(("spawn/", "boot/", "helper/"))
                assert (root / "fault-pid").exists() == after_spawn, (child_fault, stderr)
                if after_spawn:
                    fault_pid = (root / "fault-pid").read_text()
                    assert len([entry for entry in waits if entry.split()[0] == fault_pid]) == 1, waits
                    assert not pathlib.Path(f"/proc/{fault_pid}").exists()
                if lost_return and (child_target != "info" or mode == "isolated:validated-helper"):
                    assert (root / "lost-child-receipts").read_text().splitlines() == ["teardown.json", "exit.json"]
            if not child_fault.startswith("info:") or mode == "isolated:validated-helper":
                exit_row, teardown = [json.loads((directory / name).read_text())
                                      for name in ("exit.json", "teardown.json")]
                assert exit_row["launcher_exit"] == launcher.returncode == 1
                pid_file = root / ("spawned-qemu" if child_fault else "pid")
                if pid_file.exists() and not lost_already_collected:
                    pid = pid_file.read_text()
                    assert exit_row["qemu_reaped"] and teardown["qemu_reaped"]
                    assert [entry for entry in waits if entry.split()[0] == pid] == [f"{pid} {exit_row['qemu_exit']}"]
                else:
                    assert not exit_row["qemu_reaped"] and not teardown["qemu_reaped"], (child_fault, exit_row)
                    assert "qemu_exit" not in exit_row and "qemu_exit" not in teardown
        if pipe_fault or registration_fault:
            assert (directory / "exit.json").is_file(), (mode, pipe_fault, registration_fault, stderr)
            exit_row = json.loads((directory / "exit.json").read_text())
            teardown = json.loads((directory / "teardown.json").read_text())
            assert launcher.returncode == (1 if mode == "term" else 0), (exit_row, teardown, stderr)
            assert exit_row["qemu_reaped"] and teardown["qemu_reaped"], (exit_row, teardown)
            assert not (root / "returns/active.json").exists()
            if pipe_fault:
                assert (root / "diag-injected").is_file(), pipe_fault
                assert exit_row["stream_bytes"] == teardown["stream_bytes"] == 836
            if registration_fault:
                assert (root / "registration-injected").is_file(), registration_fault
                pid = (root / "pid").read_text()
                waits = (root / "launcher-waits").read_text().splitlines()
                assert [entry for entry in waits if entry.split()[0] == pid] == [f"{pid} {exit_row['qemu_exit']}"]
                assert not pathlib.Path(f"/proc/{pid}").exists()
        if pidfd_case is not None:
            assert (directory / "exit.json").is_file(), (mode, pidfd_case, stderr)
            assert (directory / "teardown.json").is_file()
            assert not (root / "returns/active.json").exists()
            assert (root / "pidfd-injected").exists() == (pidfd_case != "baseline"), (mode, pidfd_case)
            assert all(json.loads((directory / receipt).read_text())["qemu_reaped"]
                       for receipt in ("exit.json", "teardown.json"))
        if (root / "descriptor-check").exists() or (pipe_fault or registration_fault
                                                   or ownership_case is not None or pidfd_case is not None
                                                   or mode in (*BACKUP_SELECTOR_CLOSE_MODES,
                                                               *READER_CLEANUP_MODES, *PRESTART_MODES)):
            initial, final = json.loads((root / "descriptor-check").read_text())
            assert initial == final, (mode, ownership_case, pidfd_case, child_fault, initial, final, stderr)
        if child_fault:
            if child_fault.startswith("info:") and mode != "isolated:validated-helper":
                assert launcher.returncode == 1 and not (root / "returns").exists(), stderr
                return
            assert exit_row["stop_reason"] == "ChildSetupError", (exit_row, stderr)
            assert teardown["input_descriptor_closed"] and teardown["overlay_descriptor_closed"]
            assert json.loads((root / "leaks").read_text()) == []
            if mode == "isolated:validated-helper" or boot_fault:
                if mode != "isolated:validated-helper":
                    assert (root / "probe.frame").stat().st_size == 836
                    assert (root / "term").exists() and exit_row["qemu_exit"] == teardown["qemu_exit"] == 0
                    fields = ("launcher_exit", "stop_reason", "qemu_reaped", "qemu_exit",
                              "input_descriptor_closed", "overlay_descriptor_closed")
                    return {key: exit_row[key] for key in fields}
                assert (directory / "artifacts/verification.json").read_bytes() == probe_body
                assert (directory / "transport-validation.json").is_file()
                fields = ("launcher_exit", "stop_reason", "qemu_reaped", "qemu_exit", "stream_bytes",
                          "input_descriptor_closed", "overlay_descriptor_closed")
                return {key: exit_row[key] for key in fields}
            return
        if signal_fault and mode == "stages:priority-timeout":
            assert exit_row["stop_reason"] == "IOPriorityError", (exit_row, stderr)
            assert exit_row["qemu_exit"] == 0
            assert not (root / "sent").exists()
        if full_stderr:
            assert os.get_blocking(stderr_target)
        if mode in PRESTART_MODES:
            assert launcher.returncode == 1, (mode, stderr)
            assert (root / "diag-injected").is_file() and b"fixture console fault" in stderr
            assert not (root / "pid").exists() and not (directory / "started.json").exists()
            assert not (directory / "exit.json").exists() and not (directory / "artifacts").exists()
            assert not (root / "returns/active.json").exists() and not list(root.glob("job-*"))
            if (root / "leaks").exists():
                assert json.loads((root / "leaks").read_text()) == []
            with (root / "fixture.lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        if mode.startswith("startup-reject:"):
            baseline = mode.removeprefix("startup-reject:")
            assert launcher.returncode == vm_startup.STARTUP_ERROR, stderr.decode()
            assert f"startup baseline failed: could not establish {baseline}".encode() in stderr, (baseline, stderr)
            assert not list(root.glob("status-*")) and not (root / "returns").exists()
            assert not list(root.glob("job-*"))
            with (root / "fixture.lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        if entry_setup is not None:
            marker = json.loads((directory / "exit.json").read_text()) if (directory / "exit.json").exists() else None
            outcome = mode.split(":")[1]
            assert marker is not None and launcher.returncode == marker["launcher_exit"] == int(outcome != "success"), (
                entry_setup, outcome, launcher.returncode, stderr.decode(), marker)
            expected_exit = STARTUP_EXITS["cancel" if outcome == "delayed-cancel" else outcome]
            assert marker["qemu_exit"] == expected_exit, (entry_setup, outcome, marker)
            assert marker["qemu_reaped"] and marker["input_descriptor_closed"] and marker["overlay_descriptor_closed"]
            assert not (root / "returns/active.json").exists()
            child = json.loads((root / "child-baseline").read_text())
            assert child["capsule"], (entry_setup, child)
            assert child["extra_fds"] == [], (entry_setup, child)
            mask, ignored_bits, caught = signal_status(root / "status-qemu")
            # Python ignores SIGPIPE/SIGXFSZ and installs its SIGINT handler at startup.
            assert mask == 0 and ignored_bits == sum(1 << (sig - 1) for sig in (signal.SIGPIPE, signal.SIGXFSZ))
            assert caught == 1 << (signal.SIGINT - 1)
            assert child["lang"] == "C.UTF-8"
            assert child["cwd"] == "/" and child["umask"] == 0o077, (entry_setup, child)
            checks = json.loads((root / "startup-baseline").read_text())
            assert set(checks) == set(STARTUP_CHECK_CASES) and all(checks.values()), checks
            assert not pathlib.Path(f"/proc/{(root / 'pid').read_text()}").exists()
            assert not list(root.glob("job-*"))
            assert json.loads((root / "leaks").read_text()) == []
            if outcome in {"resistant", "cancel", "delayed-cancel"}:
                assert marker["stop_reason"] == "cancelled"
                assert (root / "sent").exists() and (root / "term").exists()
            with (root / "fixture.lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        if mode == "unreadable-exit" or mode.startswith("readback:"):
            row = json.loads((directory / "exit.json").read_text())
            assert launcher.returncode == row["launcher_exit"] == 0, (mode, row, stderr)
            assert row["qemu_reaped"] and row["qemu_exit"] == 0 and row["stream_bytes"] == 836
            assert (directory / "artifacts/verification.json").read_bytes() == probe_body
            assert (root / "readback-injected").exists()
            assert (root / "readback-retried").exists() == (mode == "readback:eintr")
            assert (b"fixture final receipt readback" in stderr) == (mode != "readback:eintr")
            assert json.loads((root / "leaks").read_text()) == []
            assert (directory / "teardown.json").exists() and not (root / "returns/active.json").exists()
            assert not pathlib.Path(f"/proc/{(root / 'pid').read_text()}").exists()
            return
        if mode.startswith(("teardown-memory:", "commit-memory:")) or mode == "fault:fail:teardown-rename":
            assert not (root / "returns/active.json").exists(), (mode, stderr)
            assert not pathlib.Path(f"/proc/{(root / 'pid').read_text()}").exists()
            assert not list(root.rglob(".receipt-*")), (mode, stderr)
            assert (directory / "artifacts/verification.json").read_bytes() == probe_body
            teardown_path = directory / "teardown.json"
            exit_path = directory / "exit.json"
            if mode.startswith("commit-memory:"):
                assert (root / "commit-path-prepared").exists()
                assert launcher.returncode == json.loads(exit_path.read_text())["launcher_exit"] == 0, (mode, stderr)
                assert json.loads(teardown_path.read_text())["qemu_reaped"]
                if mode == "commit-memory:baseline":
                    return {"points": (root / "commit-points").read_text().splitlines()}
            elif mode in {"teardown-memory:timestamp", "teardown-memory:journal-unlink",
                          "teardown-memory:journal-sync"}:
                assert launcher.returncode == json.loads(exit_path.read_text())["launcher_exit"] == 0, (mode, stderr)
                row = json.loads(teardown_path.read_text())
                assert row["qemu_reaped"] and row["qemu_exit"] == 0
                assert (row["ended_at"] is None) == (mode == "teardown-memory:timestamp")
            else:
                assert launcher.returncode == 1, (mode, stderr)
                if exit_path.exists():
                    assert json.loads(exit_path.read_text())["launcher_exit"] == 1
                surviving = {"dir_open", "dir_sync", "dir_close", "temp_cleanup", "log_errors"}
                assert teardown_path.exists() == (mode.removeprefix("teardown-memory:") in surviving), (mode, stderr)
            assert (root / "injected").exists(), (mode, stderr)
            if (root / "launcher-children").exists():
                assert json.loads((root / "launcher-children").read_text()) == []
            return
        if mode == "audit-mutation":
            assert launcher.returncode == 0, stderr.decode()
            audit = json.loads((root / "audit").read_text())
            assert "stat" in audit["outside"], audit
            assert "statvfs" in audit["outside"], audit
            return
        if mode.startswith("pair:"):
            attempt = directory.parent
            accepted = attempt / "acceptance.json"
            marker = attempt / "exit.json"
            failed = mode == "pair:fail"
            point = mode.removeprefix("pair:critical:")
            cancelled = point in {"begin_finalization:first", "begin_finalization:last",
                                  "mask_block:first", "mask_block:last", "rename:first"}
            assert launcher.returncode == int(failed or cancelled), (
                mode, launcher.returncode, stderr.decode(),
                (root / "terminal").read_text() if (root / "terminal").exists() else None,
            )
            sequence = (root / "sequence").read_text().splitlines()
            assert sequence.index("fixture/build/teardown.json") < sequence.index("fixture/verify/teardown.json")
            assert "launcher_exit" not in json.loads((directory / "teardown.json").read_text())
            if failed:
                assert not accepted.exists() and not marker.exists()
            else:
                assert sequence[-2:] == ["fixture/acceptance.json", "fixture/exit.json"], (mode, sequence, stderr)
                assert json.loads(marker.read_text())["launcher_exit"] == launcher.returncode
            assert (image_vm.completed_acceptance(accepted) is not None) == (not failed and not cancelled)
            if mode.startswith("pair:critical:") or mode == "pair:mask-mutation":
                audit = json.loads((root / "terminal").read_text())
                if mode == "pair:mask-mutation":
                    assert ["fsync", -1] in audit["violations"], audit
                else:
                    expected_signals = sorted(map(int, signal.valid_signals() - {signal.SIGKILL, signal.SIGSTOP}))
                    assert audit["delivered"] == expected_signals, (point, audit)
                    # Later job-control stop signals clear pending SIGCONT on Linux.
                    assert audit["pending"] == [sig for sig in expected_signals if sig != signal.SIGCONT], (point, audit)
                    assert not audit["violations"], (point, audit)
                    assert {"begin_finalization", "rename", "dir_sync", "exit_launcher"} <= set(audit["traced"])
                assert json.loads((root / "leaks").read_text()) == []
            children = (root / "children").read_text().splitlines()
            assert len(children) == 2
            assert all(not pathlib.Path(f"/proc/{pid}").exists() for pid in children)
            assert not list(root.glob("job-*")) and not list(root.rglob(".receipt-*"))
            if mode.startswith("pair:tail-io:"):
                assert (root / "tail-fault-count").read_text() == "1"
                initial, final = json.loads((root / "descriptor-check").read_text())
                assert initial == final
                assert not (root / "returns/active.json").exists()
            with (root / "fixture.lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        if mode.startswith("receipt-step:"):
            point, action = mode.split(":")[1:]
            marker = directory / "exit.json"
            names = [step.__name__ for step, _ in image_lifecycle.RECEIPT_STEPS]
            index, rename = names.index(point), names.index("rename")
            after = index > rename or index == rename and action == "term-during"
            assert (root / "injected").exists(), (mode, stderr)
            audit = json.loads((root / "audit").read_text())
            assert not audit["outside"], (mode, audit["outside"])
            if action.startswith("term-"):
                assert [point, "os.kill"] in audit["events"], (mode, audit)
            retried = action == "memory" and not after
            assert launcher.returncode == (0 if after or retried else 1), (mode, stderr)
            assert marker.exists() == (after or retried or action.startswith("term-")), mode
            if marker.exists():
                assert json.loads(marker.read_text())["launcher_exit"] == launcher.returncode, mode
            executed = (root / "steps").read_text().splitlines()
            if after:
                assert executed == names, mode
            elif not action.startswith("term-"):
                assert executed[index + 1:] == [
                    step.__name__ for step, cleanup in image_lifecycle.RECEIPT_STEPS[index + 1:]
                    if cleanup] + (names if retried else []), mode
            if action == "memory":
                assert (directory / "artifacts/verification.json").read_bytes() == probe_body
                assert json.loads(marker.read_text())["qemu_exit"] == 0
            assert not (root / "atexit-ran").exists(), mode
            assert not list(root.rglob(".receipt-*")), mode
            assert not list(root.glob("job-*")), mode
            assert json.loads((root / "leaks").read_text()) == [], mode
            assert not pathlib.Path(f"/proc/{(root / 'pid').read_text()}").exists(), mode
            with (root / "fixture.lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        if mode.startswith("fault:"):
            action, boundary = mode.split(":")[1:]
            assert (root / "injected").is_file(), (mode, stderr)
            if boundary == "journal-unlink":
                assert launcher.returncode == 0
                assert json.loads((directory / "exit.json").read_text())["launcher_exit"] == 0
                assert not (root / "returns/active.json").exists()
                assert not pathlib.Path(f"/proc/{(root / 'pid').read_text()}").exists()
                return
            assert launcher.returncode == 1, (mode, stderr)
            marker = directory / "exit.json"
            assert marker.exists() == (action == "term" and boundary != "parent-sync"), mode
            if marker.exists():
                row = json.loads(marker.read_text())
                assert row["launcher_exit"] == launcher.returncode and row["stop_reason"] == "cancelled", mode
            assert not (directory.parent / "acceptance.json").exists(), mode
            assert not list(root.rglob(".receipt-*")), mode
            assert not list(root.glob("job-*")), mode
            if (root / "pid").exists():
                assert not pathlib.Path(f"/proc/{(root / 'pid').read_text()}").exists(), mode
            with (root / "fixture.lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        if mode in ISOLATION_MODES:
            operation = mode.split(":")[1]
            stalled = operation in {"dropped", "summary-timeout"}
            assert (directory / "exit.json").is_file(), (
                mode, launcher.returncode, stderr.decode(),
                (directory / "artifacts/verification.json").is_file(),
                (directory / "teardown.json").is_file(), (root / "returns/active.json").is_file(),
            )
            record, teardown = [json.loads((directory / name).read_text()) for name in ("exit.json", "teardown.json")]
            assert record["launcher_exit"] == launcher.returncode == int(stalled), stderr.decode()
            close_injected = (ownership_case is not None and ownership_case[0] >= 0
                              or pidfd_case not in (None, "baseline") or pipe_fault or registration_fault)
            complete = not close_injected and (
                operation in {"complete", "exclusive"} or (mode in STDERR_FLOOD_MODES and not mode.endswith("-fault")))
            if operation == "exclusive":
                assert (root / "exclusive-sample").exists()
                assert (root / "exclusive-spawns").read_text().splitlines() == [
                    "qemu-img info", "qemu-img create", "qemu-system-x86_64",
                ]
            assert record["capture_lost"] is (not complete), (mode, record, stderr.decode())
            assert record["sequence_complete"] is complete
            for row in (record, teardown):
                assert row["stream_bytes"] == (25 if stalled else (root / "probe.frame").stat().st_size)
                assert row["qemu_reaped"] and row["input_descriptor_closed"] and row["overlay_descriptor_closed"]
            if operation == "dropped":
                assert record["last_observed_stage"] == "member_prepare_end"
                assert (root / "header-write-entered").exists()
                assert not (root / "header-write-returned").exists()
                assert b" member_header_begin " in (root / "header-marker-dropped").read_bytes()
                assert "member_header_begin" not in record["console_tail"]
            if stalled:
                assert (directory / "stream.partial").read_bytes() == b"CERALIVE_IMAGE_STREAM_V1\n"
            else:
                assert (directory / "artifacts/verification.json").read_bytes() == probe_body
            if mode.count(":") == 2:
                assert (root / "diag-injected").exists(), mode
            if ownership_case is not None and close_injected:
                assert (root / "diag-injected").is_file(), ownership_case
            if mode in UNREGISTER_MODES:
                first, retry = json.loads((root / "unregister-attempts").read_text())
                assert retry - first >= image_lifecycle.POLL_SECONDS, (first, retry)
            if operation in {"summary", "summary-timeout", "fallback", "text"} or operation.startswith(
                ("alloc-", "encode-")
            ):
                assert record["last_observed_stage"] is None and record["console_tail"] == ""
                assert not record["console_tail_truncated"] and record["control_bytes_received"] == 0
                assert not (root / "late-fallback-encoding").exists()
            if mode in STDERR_FLOOD_MODES:
                assert record["stream_bytes"] == (787274 if "-large-" in mode else 836)
                assert (root / "stderr-target").read_text() == "/dev/null"
                assert not (root / "stderr-read-attempted").exists()
                if mode.endswith("-fault"):
                    assert (root / "serial-read-fault").is_file() and (root / "serial-would-block").is_file()
                if not mode.endswith("-baseline"):
                    assert (root / "stderr-written").read_text() == str(4 * 1024**2 if "-large-" in mode else 65537)
                assert record["control_bytes_received"] == len(record["console_tail"])
            assert json.loads((root / "leaks").read_text()) == []
            assert not pathlib.Path(f"/proc/{(root / 'pid').read_text()}").exists()
            assert not (root / "returns/active.json").exists()
            assert (directory / "exit.json").stat().st_mode & 0o777 == 0o600
            assert not any((directory / name).exists() for name in
                           ("console.partial", "diagnostic.partial", "diagnostics.json"))
            with (root / "fixture.lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            excluded = {"last_observed_stage", "sequence_complete", "capture_lost", "console_tail",
                        "console_tail_truncated", "control_bytes_received", "launcher", "qemu", "base",
                        "overlay_directory", "overlay_fd", "overlay_inode", "acquired_at",
                        "started_at", "ended_at", "qemu_priority"}
            stable = {key: value for key, value in record.items() if key not in excluded}
            if ownership_case is not None:
                stable["close_inventory"] = json.loads((root / "ownership-inventory").read_text())
            return stable
        if mode in STAGE_MODES or priority_failure:
            stalled = mode in {"stages:timeout", "stages:before-header", "stages:blocked-header"}
            logging_error = mode == "stages:logging-error"
            exit_row = json.loads((directory / "exit.json").read_text())
            teardown = json.loads((directory / "teardown.json").read_text())
            if priority_failure:
                assert launcher.returncode == exit_row["launcher_exit"] == 1
                assert b"ioprio_get fixture" in stderr and b"image guest (last stage" not in stderr
                elapsed = time.monotonic() - float((root / "term-before-write").read_text())
                assert not (root / "returns/active.json").exists()
                assert not pathlib.Path(f"/proc/{(root / 'pid').read_text()}").exists()
                if mode.startswith("stages:priority-kill"):
                    grace = 0.2 if mode.endswith("-fast") else vm_process.TERM_GRACE_SECONDS
                    assert elapsed <= grace + 2, elapsed
                    assert exit_row["qemu_exit"] == teardown["qemu_exit"] == -signal.SIGKILL
                else:
                    assert (root / "term").exists()
                    assert exit_row["qemu_exit"] == teardown["qemu_exit"] == 0
                assert exit_row["qemu_reaped"] and teardown["qemu_reaped"]
                return
            if mode in {"stages:at-cap", "stages:over-cap"}:
                assert launcher.returncode == exit_row["launcher_exit"] == 0, stderr.decode()
                assert (directory / "artifacts/verification.json").is_file()
                assert not (directory / "console.partial").exists()
                assert exit_row["control_bytes_received"] == 8 * 1024**2 + (
                    len(b"STAGE 2 stream_close_end 0\n") if mode == "stages:over-cap" else 0)
                assert exit_row["console_tail_truncated"] is (mode == "stages:over-cap")
                for row in (exit_row, teardown):
                    assert row["stream_bytes"] == (root / "probe.frame").stat().st_size
                assert exit_row["capture_lost"] and not exit_row["sequence_complete"]
                if mode == "stages:over-cap":
                    assert exit_row["last_observed_stage"] == "stream_close_end"
                return
            assert launcher.returncode == exit_row["launcher_exit"] == int(stalled), stderr.decode()
            for row in (exit_row, teardown):
                assert row["qemu_reaped"] and row["input_descriptor_closed"] and row["overlay_descriptor_closed"]
                assert row["stream_bytes"] == (25 if stalled else (root / "probe.frame").stat().st_size)
            expected_stage = {"stages:blocked-header": "member_header_begin",
                              "stages:before-header": "member_prepare_begin",
                              "stages:timeout": "magic_written"}.get(mode, "stream_close_end")
            assert exit_row["last_observed_stage"] == (None if logging_error else expected_stage)
            tail = exit_row["console_tail"]
            assert "FIXTURE_NOT_A_REAL_SECRET" not in tail
            if not logging_error:
                assert 4 * 1024 - 96 < len(tail.encode()) <= 4 * 1024 and exit_row["console_tail_truncated"]
                assert tail.splitlines()[-1].split()[2] == expected_stage
            if stalled:
                if mode == "stages:blocked-header":
                    assert (root / "header-write-entered").exists()
                    assert not (root / "header-write-returned").exists()
                    assert b"member_header_begin" in stderr
                elif mode == "stages:before-header":
                    assert (root / "member-prepare-entered").exists()
                    assert not (root / "header-write-entered").exists()
                    assert b"member_prepare_begin" in stderr
                    assert "member_header_begin" not in tail
                else:
                    assert b"magic_written" in stderr
                assert (directory / "stream.partial").read_bytes() == b"CERALIVE_IMAGE_STREAM_V1\n"
            if mode in {"stages:logging-error", "stages:guest-loss"}:
                assert exit_row["capture_lost"]
            assert not (root / "returns/active.json").exists()
            return
        expected_status = 0 if mode in {"committed", "exit-sync-error", "mask-restore-error",
                                        "raising-handler", "late-exit", "shutdown-gap"} else 1
        pid = (root / "pid").read_text()
        assert not pathlib.Path(f"/proc/{pid}").exists(), "QEMU was not reaped"
        assert not list(root.glob("job-*"))
        assert json.loads((root / "leaks").read_text()) == []
        record = json.loads((directory / "exit.json").read_text())
        assert record["stop_reason"] == (
            "guest exited; transport validated" if expected_status == 0 else "cancelled"), record
        assert record["input_descriptor_closed"] is True
        assert record["overlay_descriptor_closed"] is True
        assert record["launcher_exit"] == expected_status
        assert launcher.returncode == record["launcher_exit"], stderr.decode()
        assert record["identity"] == asdict(identity)
        if mode == "overlay":
            assert not (directory / "started.json").exists()
            assert "qemu" not in record and record["qemu_reaped"] is False
        else:
            assert record["qemu"].split(":")[0] == pid
            assert record["qemu_reaped"] is True
            assert record["qemu_exit"] == {"ignore": -9, "slow": -15}.get(mode, 0)
            if mode not in SUCCESS_GUEST_MODES:
                assert record["qemu_priority"] == FIXTURE_PRIORITY
        assert not (root / "returns/active.json").exists()
        if mode == "exit-sync-error":
            assert b"fixture exit directory sync" in stderr
        elif mode == "mask-restore-error":
            assert not (root / "restore-attempt").exists(), "launcher attempted to restore the terminal mask"
            assert (root / "final-sync").exists()
        elif mode == "raising-handler":
            assert (root / "handler-pending").exists() and not (root / "handler-ran").exists()
            assert (root / "final-sync").exists(), "raising handler skipped final directory sync"
        elif mode == "late-exit":
            assert b"kernel runner: 71" in stderr
        elif mode == "shutdown-gap":
            assert (root / "final-sync").exists()
            assert not (root / "handler-ran").exists(), "SIGUSR1 ran before direct exit"
        else:
            assert time.monotonic() - float((root / "sent").read_text()) < seconds
        if mode in {"term", "ignore", "repeat", "inherited"}:
            assert (root / "term").exists(), "QEMU did not receive TERM"
        if blocked or ignored:
            stop_bits = sum(1 << (sig - 1) for sig in vm.STOP_SIGNALS)
            entry_mask, entry_ignored, _ = signal_status(root / "status-launcher")
            if blocked:
                assert entry_mask & sum(1 << (sig - 1) for sig in blocked) == sum(1 << (sig - 1) for sig in blocked)
                assert b"cleared inherited signal mask" in stderr
            if ignored:
                assert entry_ignored & (1 << (signal.SIGTERM - 1))
                assert b"replaced inherited ignored stop signals: SIGTERM" in stderr
            for child in ("info", "create", "qemu"):
                mask, ignored_bits, caught = signal_status(root / f"status-{child}")
                assert mask == 0, (child, blocked, mask)
                assert ignored_bits & stop_bits == 0, (child, ignored, ignored_bits)
                # CPython installs default_int_handler after exec.
                assert caught & stop_bits == 1 << (signal.SIGINT - 1), (child, caught)
            with (root / "fixture.lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)


def test_probe_receipts_record_safe_console_tail_and_last_stage_on_success_and_timeout() -> None:
    for mode in STAGE_MODES:
        cancelled_fixture(mode)


def test_priority_failure_reaps_at_the_serial_write_boundary() -> None:
    for _ in range(20):
        cancelled_fixture("stages:priority-timeout")
        cancelled_fixture("stages:priority-kill-fast")
    cancelled_fixture("stages:priority-kill")


def test_diagnostic_acquisition_and_sequence_are_independent_of_the_probe() -> None:
    baseline = cancelled_fixture("isolated:baseline")
    for mode in ISOLATION_MODES[1:]:
        if mode in (*STDERR_FLOOD_MODES, *READER_CLEANUP_MODES, *UNREGISTER_MODES,
                    *BACKUP_SELECTOR_CLOSE_MODES):
            continue
        result = cancelled_fixture(mode)
        if mode.split(":")[1] not in {"dropped", "summary-timeout"}:
            assert result is not None and result == baseline, (mode, result, baseline)


def test_serial_reader_cleanup_faults_preserve_the_committed_probe() -> None:
    baseline = cancelled_fixture("isolated:complete")
    for mode in READER_CLEANUP_MODES:
        assert cancelled_fixture(mode) == baseline, mode


def test_failed_console_unregister_does_not_spin_or_change_probe_result() -> None:
    baseline = cancelled_fixture("isolated:complete")
    for mode in UNREGISTER_MODES:
        assert cancelled_fixture(mode) == baseline, mode


def test_backup_selector_close_faults_preserve_the_committed_probe() -> None:
    baseline = cancelled_fixture("isolated:complete")
    for mode in BACKUP_SELECTOR_CLOSE_MODES:
        assert cancelled_fixture(mode) == baseline, mode


def test_pidfd_close_faults_preserve_normal_and_cancelled_probe_receipts() -> None:
    for mode in ("term", "isolated:complete"):
        baseline = cancelled_fixture(mode, pidfd_case="baseline")
        for phase, error in CLOSE_FAULTS:
            assert cancelled_fixture(mode, pidfd_case=f"{phase}:{error}") == baseline


def test_pipe_close_statement_faults_preserve_eof_and_the_complete_probe() -> None:
    baseline = cancelled_fixture("isolated:complete")
    code = image_lifecycle.PipeEnd.close.__code__
    for point in (*statement_lines(code), "return"):
        assert cancelled_fixture("isolated:complete", pipe_fault=point) == baseline, point


def test_pidfd_registration_statement_faults_preserve_launcher_reaping() -> None:
    register = vm_process.register_close
    code = register.__code__
    source = inspect.getsource(register).splitlines()
    callback_line = next(i.positions.lineno for i in dis.get_instructions(code) if i.argval == "callback")
    for mode in ("isolated:complete", "term"):
        baseline = cancelled_fixture(mode)
        for point in (*dict.fromkeys(statement_lines(code)), "return"):
            if point != "return" and int(point) > callback_line:
                # The release arm is excluded: the caller still owns this handle.
                line = source[int(point) - code.co_firstlineno]
                if line.strip() == "close_transport(release, on_loss)":
                    continue
                point = "rollback:" + point
            assert cancelled_fixture(mode, registration_fault=point) == baseline, (mode, point)
    assert cancelled_fixture("term", registration_fault="unusable") == cancelled_fixture("term")


def test_pidfd_signal_faults_preserve_launcher_reaping_and_receipts() -> None:
    for mode in ("term", "stages:priority-timeout"):
        for error in ("ENOSYS", "EPERM", "EINVAL", "EBADF", "ESRCH", "MemoryError"):
            cancelled_fixture(mode, signal_fault=error)
        for error in ("ENOSYS", "EPERM", "EINVAL", "EBADF"):
            cancelled_fixture(mode, signal_fault=f"open/{error}")
    cancelled_fixture("ignore", signal_fault="ENOSYS")


def check_post_spawn_faults(targets: tuple[str, ...], *, mode: str = "isolated:complete",
                            baseline: dict | None = None) -> None:
    def lines(function, first, last):
        source, start = inspect.getsourcelines(function)
        first = next(i for i, line in enumerate(source) if first in line)
        last = next(i for i, line in enumerate(source) if last in line)
        return [str(start + i) for i in range(first, last + 1)]

    spawn = vm_process.spawn_owned.__wrapped__
    spawn_line = lines(spawn, "if handle_registered:", "if handle_registered:")[0]
    owner_line = lines(spawn, "owners = ExitStack()", "owners = ExitStack()")[0]
    pipe_line = lines(spawn, 'register_close(owners, f"child-', 'register_close(owners, f"child-')[0]
    helper_lines = lines(vm_process.run, "if capture_output:", "setup_complete = True")[-4:]
    prepare_lines = [*lines(vm_process.run, "owners = ExitStack()", 'register_close(owners, "helper-selector"'),
                     *lines(vm_process.run, "deadline = time.monotonic()", "deadline = time.monotonic()")]
    for target in targets:
        points = [f"spawn/{spawn_line}", f"pre-spawn/{owner_line}",
                  *(f"pre-spawn/{pipe_line}@{name}" for name in ("stdin", "stdout", "stderr"))]
        if target == "qemu-system-x86_64":
            points.extend(f"boot/{line}" for line in lines(vm.boot, "writers.close()", "setup_complete = True")
                          if "reader.start()" not in inspect.getsource(vm.boot).splitlines()[
                              int(line) - vm.boot.__code__.co_firstlineno])
        else:
            points.extend(f"prepare/{line}" for line in prepare_lines)
            points.append("selector-stack")
        if target in ("info", "gh"):
            points.append("prepare/" + lines(vm_process.run, "options.update(stdout=", "options.update(stdout=")[0])
            points.extend(f"helper/{line}" for line in helper_lines)
        elif target != "qemu-system-x86_64":
            points.extend(f"helper/{line}" for line in (helper_lines[0], helper_lines[-1]))
        for point in points:
            for error in ("MemoryError", "OSError"):
                case = f"{target}:{point}:{error}"
                try:
                    outcome = cancelled_fixture(mode, child_fault=case)
                    if baseline is not None:
                        assert outcome == baseline, (outcome, baseline)
                except (AssertionError, OSError) as failure:
                    failure.add_note(case)
                    raise


def test_post_spawn_faults_reap_each_child_and_close_its_pipes() -> None:
    check_post_spawn_faults(("qemu-system-x86_64", "info", "create"))
    source, first = inspect.getsourcelines(vm.boot)
    points = [first + i for i, line in enumerate(source)
              if line.strip() in {"writers.close()", "if reader is not None:", "setup_complete = True"}
              and not line.lstrip().startswith("if reader is not None and")]
    baseline = cancelled_fixture("isolated:complete",
                                 child_fault=f"qemu-system-x86_64:boot/{points[0]}:OSError")
    assert baseline is not None and baseline["launcher_exit"] == 1
    for point in points:
        for error in ("MemoryError", "OSError"):
            fault = f"qemu-system-x86_64:boot/{point}:{error}"
            outcome = cancelled_fixture("isolated:complete", child_fault=fault)
            assert outcome == baseline, (fault, outcome, baseline)


def test_lost_popen_result_is_reaped_before_terminal_receipts() -> None:
    for target in ("qemu-system-x86_64", "info", "create"):
        for error in ("OSError", "MemoryError"):
            cancelled_fixture("isolated:complete", child_fault=f"{target}:lost-return:{error}")
    for target in ("info", "create"):
        cancelled_fixture("isolated:validated-helper", child_fault=f"{target}:lost-return:MemoryError")
    cancelled_fixture("isolated:complete", child_fault="qemu-system-x86_64:lost-already-collected:OSError")


def check_main_path_memory_faults(target: str, mode: str) -> None:
    baseline = cancelled_fixture(mode, child_fault=f"{target}:sweep-baseline:MemoryError")
    assert baseline and len(baseline["points"]) > 10, (target, baseline)
    for point in baseline["points"]:
        try:
            cancelled_fixture(mode, child_fault=f"{target}:sweep/{point}:MemoryError")
        except AssertionError as error:
            error.add_note(f"{target}: {point}")
            raise
    print(f"{target}: {len(baseline['points'])} main-path allocation faults", flush=True)


def test_qemu_main_path_memory_faults_fail_closed() -> None:
    check_main_path_memory_faults("qemu-system-x86_64", "isolated:complete")


def test_disk_helper_main_path_memory_faults_fail_closed() -> None:
    for target in ("info", "create"):
        check_main_path_memory_faults(target, "isolated:validated-helper")


def test_post_spawn_faults_cover_preparation_and_registration_helpers() -> None:
    check_post_spawn_faults(tuple(PREPARATION_HELPERS))


def test_helper_failures_preserve_the_validated_probe_receipt() -> None:
    mode = "isolated:validated-helper"
    for step in ("info", "create"):
        baseline = cancelled_fixture(mode, child_fault=f"{step}:baseline:MemoryError")
        assert baseline is not None and baseline["stream_bytes"] == 836
        check_post_spawn_faults((step,), mode=mode, baseline=baseline)


def test_only_qemu_is_alive_during_probe_capture() -> None:
    assert cancelled_fixture("isolated:exclusive") == cancelled_fixture("isolated:complete")


def test_io_priority_is_sampled_in_process_and_fails_closed() -> None:
    with patch.object(image_resources, "require_process_priority", return_value=9), \
            patch.object(image_resources, "cgroup_limits", return_value=10), \
            patch.object(subprocess, "Popen") as spawn:
        for value, error in ((0, None), ((2 << 13) | 7, None), (1 << 13, None),
                             (4 << 13, None), (-1, errno.ENOSYS), (-1, errno.EPERM)):
            with patch.object(image_resources._LIBC, "syscall", return_value=value), \
                    patch.object(image_resources.ctypes, "get_errno", return_value=error):
                if value in (0, (2 << 13) | 7):
                    row = image_resources.process_priority(os.getpid(), Cancellation())
                    assert row["ionice"] == ("none: prio 0" if value == 0 else "best-effort: prio 7")
                else:
                    try:
                        image_resources.process_priority(os.getpid(), Cancellation())
                    except image_resources.AdmissionError:
                        pass
                    else:
                        raise AssertionError((value, error))
        spawn.assert_not_called()


def test_priority_syscall_error_restarts_the_whole_observation() -> None:
    for error, failures in product((errno.EINTR, errno.EAGAIN, errno.EIO, errno.EPERM), (1, 3)):
        steps = []

        def cpu(_pid):
            steps.append("cpu")
            return 9

        def cgroup(_pid):
            steps.append("cgroup")
            return 10

        def ioprio(*_args):
            steps.append("ioprio")
            return -1 if steps.count("ioprio") <= failures else 0

        with patch.object(image_resources, "require_process_priority", cpu), \
                patch.object(image_resources, "cgroup_limits", cgroup), \
                patch.object(image_resources._LIBC, "syscall", ioprio), \
                patch.object(image_resources.ctypes, "get_errno", return_value=error):
            try:
                assert image_resources.process_priority(os.getpid(), Cancellation())["ionice"] == "none: prio 0"
            except image_resources.IOPriorityError:
                assert failures == 3 or error == errno.EPERM
        assert steps == ["cpu", "cgroup", "ioprio"] * (1 if error == errno.EPERM else min(failures + 1, 3))


def test_late_disk_error_restarts_store_admission_before_execution() -> None:
    for error, failures in product((errno.EINTR, errno.EAGAIN, errno.EIO, errno.EPERM), (1, 3)):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            store = root / "store"
            store.mkdir(mode=0o700)
            base, capsule = root / "base", root / "capsule"
            base.touch()
            capsule.touch()
            args = SimpleNamespace(base=base, input_capsule=capsule, input_sha256=IDENTITY.input_sha256,
                                   base_sha256="a" * 64, trust_policy=root / "trust", output_dir=store,
                                   attempt=IDENTITY.attempt, board=IDENTITY.board, source_commit=IDENTITY.commit,
                                   source_epoch=IDENTITY.epoch, source_bundle=None, check_script=None,
                                   group_id=None, image_mode="probe")
            steps = []
            inventory = image_vm.list_directory

            def scan(path, **kwargs):
                if path == store:
                    steps.append("store")
                return inventory(path, **kwargs)

            def disk(*_args):
                steps.append("disk")
                if steps.count("disk") <= failures:
                    raise OSError(error, "fixture disk observation")

            def execute(_base, directory, request, *_args):
                steps.append("execute")
                artifacts = directory / "artifacts"
                (artifacts / "verification.json").write_text(json.dumps({
                    "schema": 1, "identity": request["payload"]["identity"], "network_denied": True}))
                return artifacts

            with patch.multiple(image_vm, require_host_lock=lambda: None, cgroup_admission=lambda: None,
                                check_capsule=lambda *_: None, validate_base=lambda *_: None,
                                load_policy=lambda *_: FixturePolicy(), reconcile=lambda *_: None,
                                list_directory=scan, disk_admission=disk, execute=execute), \
                    patch.object(image_resources.ImageCaps, "qemu_limit"):
                try:
                    image_vm.measure_image(args, None, Cancellation(), [])
                except (OSError, image_resources.AdmissionError):
                    assert failures == 3 or error == errno.EPERM
                else:
                    assert failures == 1 and error != errno.EPERM
            tries = 1 if error == errno.EPERM else min(failures + 1, 3)
            success = failures == 1 and error != errno.EPERM
            assert steps == ["store", "disk"] * tries + (["execute"] if success else []), steps
            assert (store / IDENTITY.attempt).exists() == success


def statement_lines(code) -> tuple[str, ...]:
    return tuple(str(line) for _, line in dis.findlinestarts(code)
                 if line is not None and line > code.co_firstlineno)


def test_all_probe_transport_owner_close_faults_preserve_the_committed_probe() -> None:
    baseline = cancelled_fixture("isolated:complete", ownership_case=(-1, "", ""))
    assert baseline is not None
    inventory = baseline["close_inventory"]
    assert Counter(inventory) == Counter((
        "capsule", "console-reader", "console-writer", "fw-cfg", "console-selector",
        "artifact-reader", "artifact-writer", "artifact-selector", "stream-capture",
    )), inventory
    for index, resource in enumerate(inventory):
        for phase, error in CLOSE_FAULTS:
            row = cancelled_fixture("isolated:complete", ownership_case=(index, phase, error))
            assert row == baseline, (resource, phase, error, row)


def test_full_host_stderr_does_not_block_exit_after_probe_timeout() -> None:
    mode = "isolated:summary-timeout:MemoryError"
    assert cancelled_fixture(mode, full_stderr=True) == cancelled_fixture(mode)


def test_guest_poweroff_does_not_depend_on_image_completion_marker() -> None:
    body = json.dumps({"schema": 1, "identity": asdict(IDENTITY), "network_denied": True}).encode()
    frame = io.BytesIO()
    encode(frame, [("verification.json", body)], IDENTITY)
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "image").mkdir()
        (root / "image/raw").touch()
        wire = root / "wire"
        wire.write_bytes(frame.getvalue())
        helper = root / "image_guest.py"
        helper.write_text(f"import sys\nopen({str(root / 'returned')!r}, 'wb').write(open({str(wire)!r}, 'rb').read())\n"
                          "raise SystemExit(int(sys.argv[1]))\n")
        observed = root / "poweroff"
        for tool, command in (
            ("modprobe", "exit 0"),
            ("systemctl", f'[[ $* = poweroff ]] && cmp -s "{wire}" "{root / "returned"}"'
                          f' && : >"{observed}"'),
        ):
            stub = root / tool
            stub.write_text(f"#!/bin/bash\n{command}\n")
            stub.chmod(0o700)
        wrapper = (ROOT / "ci/kernel-runner/guest-job.sh").read_text()
        wrapper = wrapper.replace("/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive", str(root))
        wrapper = wrapper.replace("/usr/local/lib/ceralive-kernel-runner/image_guest.py", f'"{helper}" "$1"')
        master, slave = pty.openpty()
        failures = []
        try:
            termios.tcflow(slave, termios.TCOOFF)
            for status in (0, 1, 37):
                for sink in ("healthy", "stopped", "write-error"):
                    observed.unlink(missing_ok=True)
                    serial = {"healthy": str(root / "serial"), "stopped": os.ttyname(slave),
                              "write-error": "/dev/full"}[sink]
                    (root / "returned").unlink(missing_ok=True)
                    with subprocess.Popen(
                        ["/bin/bash", "-c", wrapper.replace("/dev/ttyS0", serial), "fixture", str(status)],
                        env={"PATH": f"{root}:/usr/bin:/bin"}, start_new_session=True, stdout=subprocess.DEVNULL,
                        stderr=subprocess.PIPE,
                    ) as guest:
                        try:
                            _, stderr = guest.communicate(timeout=2)
                        except subprocess.TimeoutExpired:
                            os.killpg(guest.pid, signal.SIGKILL)
                            guest.communicate()
                            failures.append((sink, status, "shutdown exceeded two seconds"))
                        else:
                            if not observed.is_file() or guest.returncode != status:
                                failures.append((sink, status, observed.is_file(), guest.returncode, stderr))
                    assert (root / "returned").read_bytes() == frame.getvalue()
                    if sink == "healthy":
                        marker = (root / "serial").read_bytes()
                        assert marker == f"\nCERALIVE_JOB_DONE={status}\n".encode(), (status, marker, failures)
        finally:
            os.close(slave)
            os.close(master)
        assert not failures, failures


def test_guest_failure_frame_and_poweroff_survive_full_standard_streams() -> None:
    with tempfile.TemporaryDirectory() as tmp, ExitStack() as resources:
        root = pathlib.Path(tmp)
        (root / "image").mkdir()
        request = root / "image/raw"
        request.write_text(json.dumps({"schema": 1, "identity": asdict(IDENTITY),
                                       "operation": "probe", "trust": {}}))
        wire = root / "wire"
        helper = root / "fixture.py"
        helper.write_text(f"""
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0, {str(ROOT / 'ci/kernel-runner')!r})
import image_guest
import image_stages

def unpack(_capsule, destination, _identity):
    destination.mkdir()
    return SimpleNamespace(objects=())

with patch.object(image_guest, 'HOME', Path({str(root / 'guest')!r})), \\
     patch.object(image_guest, 'Path', side_effect=lambda path: {{
         '/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive/image/raw': Path({str(request)!r}),
         '/dev/virtio-ports/ceralive-artifacts': Path({str(wire)!r}),
     }}.get(path, Path(path))), \\
     patch.object(image_guest, 'unpack', unpack), \\
     patch.object(image_guest, 'source_checkout'), \\
     patch.object(image_guest, 'command', return_value='[{{}}]'), \\
     patch.object(image_stages, 'CONSOLE', Path('/dev/null')):
    result = image_guest.main()
    if 'wrapper' in sys.argv:
        import atexit
        import os
        atexit.register(os.write, 1, b'late stdout\\n')
        atexit.register(os.write, 2, b'late stderr\\n')
    raise SystemExit(result)
""")
        observed = root / "poweroff"
        for name, command in (
            ("modprobe", "exit 0"),
            ("systemctl", f'[[ $* = poweroff && -s "{wire}" ]] && : >"{observed}"'),
        ):
            stub = root / name
            stub.write_text(f"#!/bin/bash\n{command}\n")
            stub.chmod(0o700)
        wrapper = (ROOT / "ci/kernel-runner/guest-job.sh").read_text()
        wrapper = wrapper.replace("/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive", str(root))
        wrapper = wrapper.replace("/usr/local/lib/ceralive-kernel-runner/image_guest.py", f'"{helper}" wrapper')
        wrapper = wrapper.replace("/dev/ttyS0", "/dev/null")
        pipes = []
        for _ in range(2):
            reader, writer = os.pipe()
            resources.callback(os.close, reader)
            resources.callback(os.close, writer)
            size = fcntl.fcntl(writer, fcntl.F_GETPIPE_SZ)
            assert os.write(writer, b"x" * size) == size
            pipes.append(writer)

        failures = []
        for mode, argv in (
            ("helper", [sys.executable, str(helper)]),
            ("wrapper", ["/bin/bash", "-c", wrapper]),
        ):
            wire.unlink(missing_ok=True)
            if (root / "guest").exists():
                (root / "guest").rename(root / "previous-guest")
            with subprocess.Popen(argv, env={"PATH": f"{root}:/usr/bin:/bin"}, start_new_session=True,
                                  stdout=pipes[0], stderr=pipes[1]) as process:
                try:
                    assert process.wait(timeout=2) == 1
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    failures.append(f"{mode} blocked after closing the failure frame")
            target = root / mode
            target.mkdir()
            with wire.open("rb") as source:
                members = decode(source, target, IDENTITY)
            assert [member.id for member in members] == ["failure.json"]
            assert json.loads((target / "failure.json").read_text()) == {
                "schema": 1, "identity": asdict(IDENTITY), "failure": "StreamError", "exit": None,
            }
            assert wire.stat().st_size == 843
        assert observed.is_file() and not failures, failures


def test_probe_stderr_flood_does_not_depend_on_host_reads() -> None:
    for size in ("small", "large"):
        baseline = cancelled_fixture(f"isolated:sink-{size}-baseline")
        for case in ("flood", "fault"):
            assert cancelled_fixture(f"isolated:sink-{size}-{case}") == baseline


def test_probe_transport_setup_failure_prevents_guest_launch_and_exit_commit() -> None:
    for mode in PRESTART_MODES:
        cancelled_fixture(mode)


def test_live_capture_rejects_new_diagnostic_io() -> None:
    from image_stages import StageTail

    def node_for(owner, name):
        tree = ast.parse(pathlib.Path(inspect.getfile(owner)).read_text())
        return next(node for node in ast.walk(tree)
                    if isinstance(node, (ast.ClassDef, ast.FunctionDef)) and node.name == name)

    def unexpected(tree, allowed, exact=()):
        # Some inherited calls perform I/O. Allow their exact expressions once,
        # regardless of which branch a new call is added to.
        remaining = Counter(exact)
        bad = set()
        for call in ast.walk(tree):
            if not isinstance(call, ast.Call) or ast.unparse(call.func) in allowed:
                continue
            expression = ast.unparse(call)
            if remaining[expression]:
                remaining[expression] -= 1
            else:
                bad.add(expression)
        return bad

    capture = node_for(ImageJob, "capture")
    capture_calls = {"Path", "StreamError", "counts.values",
                     "events.get_map", "len", "max", "min", "poll_owned",
                     "self.cancellation.check", "self.state.update", "subprocess.TimeoutExpired",
                     "sum", "time.monotonic", "time.time", "wait"}
    capture_exact = (
        "files[name].write(chunk)", "self.read_console(event.fd)",
        "self.capture_hashes[name].update(chunk)",
        "events.unregister(event.fileobj)", "events.unregister(event.fileobj)",
        "self.probe_events.unregister(self.console_read)",
        "self.drain(events)", "close_transport(self.console_writer.close, on_loss)",
        "read_once(event.fd, self.capture_buffer)",
        "events.select(timeout=min(POLL_SECONDS, end - now))",
        "self.register_measure_transport(events, process)",
        "retry_check(self.capture_headroom, sum(counts.values()))",
        "process_identity(process.pid)", "process_priority(process.pid, self.cancellation)",
        "receipt(self.directory / 'started.json', self.state)",
        "receipt(self.active, {'attempt': self.identity.attempt, 'launcher': self.state['launcher'], "
        "'qemu': self.state['qemu'], 'overlay_inode': self.state['overlay_inode']})",
    )
    assert not (bad := unexpected(capture, capture_calls, capture_exact)), bad
    helpers = (
        ("capture_headroom", {"Path", "max", "self.cancellation.check"},
         ("overlay.stat()", "disk_headroom(((Path(self.state['overlay_directory']), remaining_overlay), "
          "(self.directory, 49 * GIB - self.state['retained_bytes'] - bytes_received)))")),
        ("read_console", {"bool", "len"},
         {"os.read(fd, 1024 * 1024)", "optional(self.lose_diagnostics, tail.observe, chunk)"}),
        ("drain", {"events.get_map", "events.get_map().values", "range", "self.lose_diagnostics"},
         {"self.read_console(key.fd)"}),
        ("diagnostic_summary", {"tail.text"}, set()),
        ("lose_diagnostics", set(), set()),
        ("close_console_reader", set(), {"self.release_console_reader()"}),
    )
    for name, calls, exact in helpers:
        assert not (bad := unexpected(node_for(ImageJob, name), calls, exact)), (name, bad)
    encode_calls = {"json.dumps(fields, sort_keys=True, indent=2)", "suffix.encode('ascii')"}
    assert not (bad := unexpected(node_for(image_lifecycle, "encode_diagnostic_fields"), set(), encode_calls)), bad
    tail = node_for(StageTail, "StageTail")
    memory_calls = {"bytearray", "chunk.split", "enumerate", "int", "joined.removesuffix",
                    "len", "match[2].decode", "min", "range", "self._append", "STAGE_LINE.fullmatch",
                    "(self.ring[self.head:self.head + first] + self.ring[:self.size - first]).decode"}
    assert not (bad := unexpected(tail, memory_calls)), bad
    assert not (bad := unexpected(node_for(StageTail, "optional"), {"on_loss", "operation"})), bad
    run_calls = {"Cancelled", "int", "isinstance", "measure_image",
                 "receipt", "report_error", "type"}
    run_exact = {
        "hashlib.sha256(retry_io(acceptance[0].read_bytes, recover=True)).hexdigest()",
        "hashlib.sha256(retry_io(acceptance[0].read_bytes, recover=True))",
        "retry_io(acceptance[0].read_bytes, recover=True)",
        "isinstance(build, ImageJob)",
        "isinstance(exc.__cause__, FileSyncError)",
        "receipt(build.teardown, build.state | {'stop_reason': 'receipt fsync failed', "
        "'storage_errno': exc.__cause__.errno}, temporary=build.teardown_temporary)",
    }
    assert not (bad := unexpected(node_for(image_vm, "run_image"), run_calls, run_exact)), bad

    mutations = (
        "self.finish_diagnostics()", "self.flush()", "self.persist_diagnostics()",
        "os.fstat(event.fd)", "open('other', 'w')", "files[name].write(b'\\n')",
        "files[name].write(chunk)", "os.fork()", "self.unlisted_call()",
        "events.register(event.fd, selectors.EVENT_READ, name)",
        "optional(lose, self.finish_diagnostics)", "os.close(fd)", "os.readv(fd, buffers)", "time.sleep(0.01)",
    )
    # Every statement block in capture and its diagnostic helpers is tried,
    # including exception/finally, EOF, timeout, and nested readiness branches.
    guarded = (("capture", capture_calls, capture_exact), *helpers, ("run_image", run_calls, run_exact))
    for name, calls, exact in guarded:
        private = node_for(image_vm if name == "run_image" else ImageJob, name)
        blocks = [value for node in ast.walk(private) for _, value in ast.iter_fields(node)
                  if isinstance(value, list) and value and isinstance(value[0], ast.stmt)]
        for block in blocks:
            for source in mutations:
                block.insert(0, ast.parse(source).body[0])
                assert unexpected(private, calls, exact), (name, source)
                block.pop(0)
    private_summary = node_for(ImageJob, "diagnostic_summary")
    private_summary.body.insert(0, ast.parse("tail.flush()").body[0])
    assert unexpected(private_summary, {"tail.text"})


def test_live_and_teardown_closes_go_through_transport_guard() -> None:
    def unguarded(tree, acquisitions):
        parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
        stack_closes = {"self.inputs.close()", "self.capture_scope.close()", "job.outputs.close()",
                        "writers.close()", "owners.close()"}
        constructors = {
            "selectors.DefaultSelector", "selectors.PollSelector", "selectors.EpollSelector",
            "selectors.SelectSelector", "open", "os.open", "os.fdopen", "FileIO", "os.memfd_create",
            "os.pipe", "os.pipe2", "_PIPE2", "os.pidfd_open", "FileIO.__new__", "PipeEnd", "pipe_files",
            "subprocess.Popen", "tempfile.TemporaryFile", "self._open_log",
        }
        remaining = Counter(acquisitions)
        raw_close = Counter({
            "sync_directory": ("os.close(fd)",),
            "dir_close": ("os.close(self.directory_fd)",),
            "file_close": ("self.output.close()",),
            "report_error": ("os.close(fd)",),
        }.get(tree.body[0].name, ()))
        registration_methods = {"enter_context", "push", "callback", "closing", "aclosing", "__enter__", "__exit__"}
        bad = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                for imported in node.names:
                    if imported.name in {"DefaultSelector", "PollSelector", "EpollSelector", "SelectSelector"}:
                        bad.add(ast.unparse(node))
            if isinstance(node, ast.Call):
                name = ast.unparse(node.func)
                if name in {"closing", "aclosing"}:
                    bad.add(name)
                if (name == "getattr" and len(node.args) >= 2
                        and isinstance(attribute := node.args[1], ast.Constant)
                        and isinstance(attribute.value, str)
                        and attribute.value in registration_methods | {"close"}):
                    bad.add(ast.unparse(node))
                if name in constructors:
                    if remaining[name] > 0:
                        remaining[name] -= 1
                    else:
                        bad.add(name)
            if isinstance(node, ast.With):
                for item in node.items:
                    if ast.unparse(item.context_expr) not in {
                        "ExitStack()", "self.outputs", "self.capture_scope", "startup", "writers",
                        "job_disk(base, job, cancellation)",
                        "ImageJob(directory, identity, request['capsule'], cancellation, "
                        "probe=request['payload']['operation'] == 'probe')",
                    } and not (isinstance(item.context_expr, ast.Call)
                               and ast.unparse(item.context_expr.func) == "spawn_owned"):
                        bad.add(ast.unparse(item.context_expr))
            if not isinstance(node, ast.Attribute):
                continue
            if node.attr in registration_methods:
                bad.add(ast.unparse(node))
            if node.attr != "close":
                continue
            parent = parents[node]
            if isinstance(parent, ast.Call):
                if ast.unparse(parent) in stack_closes:
                    continue
                if raw_close[ast.unparse(parent)] > 0:
                    raw_close[ast.unparse(parent)] -= 1
                    continue
                if (ast.unparse(parent.func) == "close_transport" and parent.args[:1] == [node]
                        or ast.unparse(parent.func) == "register_close" and parent.args[2:3] == [node]):
                    continue
                if ast.unparse(parent.func) == "partial" and ast.unparse(parent) in {
                    "partial(os.close, fd)", "partial(os.close, self.directory_fd)",
                    "partial(os.close, reader)", "partial(os.close, writer)",
                }:
                    ancestor = parents[parent]
                    if isinstance(ancestor, ast.IfExp):
                        ancestor = parents[ancestor]
                    if isinstance(ancestor, ast.Call) and ast.unparse(ancestor.func) == "close_transport":
                        continue
            if isinstance(parent, ast.IfExp):
                use = parents[parent]
                if isinstance(use, ast.Call) and ast.unparse(use.func) == "close_transport":
                    continue
            if isinstance(parent, ast.Assign) and ast.unparse(parent) == (
                    "self.release_console_reader = self.console_reader.close"):
                continue
            bad.add(ast.unparse(node))
        return bad

    functions = (
        (ImageJob.__init__, ("FileIO", "os.open", "pipe_files")),
        (ImageJob.__exit__, ()),
        (ImageJob.prepare_probe_transport, ("selectors.DefaultSelector", "selectors.DefaultSelector", "pipe_files")),
        (ImageJob.prepare_capture, ("selectors.DefaultSelector", "self._open_log")),
        (ImageJob.capture, ()),
        (ImageJob.close_console_reader, ()),
        (image_lifecycle.pipe_files, ("_PIPE2", "PipeEnd", "PipeEnd")),
        (image_lifecycle.job_disk, ("tempfile.TemporaryFile",)),
        (image_lifecycle.report_error, ("os.open",)),
        (image_lifecycle.sync_directory, ("os.open",)),
        (image_lifecycle.Receipt.file_close, ()),
        (image_lifecycle.Receipt.dir_close, ()),
        (vm.boot, ("FileIO", "os.memfd_create")),
        (vm_process.spawn_owned.__wrapped__, ("FileIO.__new__", "os.pidfd_open", "subprocess.Popen")),
        (vm_process.run, ("selectors.PollSelector",)),
        (vm_process.read_check_script, ("open", "os.open", "selectors.PollSelector")),
        (vm_process.terminate, ()),
        (image_vm.execute, ()),
    )
    mutations = (
        "selector.close()", "os.close(fd)", "file.close()",
        "stack.enter_context(selectors.DefaultSelector())", "stack.push(extra)",
        "stack.callback(release)", "contextlib.closing(extra)",
        "self.extra = selectors.DefaultSelector()", "self.extra = open('file', 'rb')",
        'alias = stack\ngetattr(alias, "callback")(getattr(events, "close"))',
        'close_transport(lambda: getattr(events, "close")())',
        'from transport import DefaultSelector as Reexported\nself.extra = Reexported()',
        'from transport import DefaultSelector as Reexported\ngetattr(stack, "enter_context")(Reexported())',
    )
    for fn, acquisitions in functions:
        source = inspect.getsource(fn)
        private = ast.parse(dedent(source))
        assert not (bad := unguarded(private, acquisitions)), (fn.__qualname__, bad)
        for mutation in mutations:
            statements = ast.parse(mutation).body
            private.body[-1].body[:0] = statements
            compile(private, "<private-copy>", "exec")
            assert unguarded(private, acquisitions), (fn.__qualname__, mutation)
            del private.body[-1].body[:len(statements)]


def test_one_term_in_selector_reaps_term_resistant_qemu() -> None:
    cancelled_fixture("ignore")


def test_inherited_blocked_and_ignored_signals_do_not_reach_children() -> None:
    for blocked in ((signal.SIGTERM,), (signal.SIGINT,), (signal.SIGHUP,),
                    vm.STOP_SIGNALS, (signal.SIGUSR1,)):
        cancelled_fixture("inherited", blocked=blocked)
    cancelled_fixture("inherited", ignored=(signal.SIGTERM,))


def test_hostile_startup_does_not_change_guest_outcome() -> None:
    assert set(STARTUP_CHECK_CASES.values()) <= STARTUP_STATES.keys()
    for sig in (*vm.STOP_SIGNALS, *vm_startup.DEFAULT_SIGNALS, *vm_startup.PYTHON_IGNORES):
        assert f"blocked-{sig.name}" in STARTUP_STATES and f"ignored-{sig.name}" in STARTUP_STATES
    assert set(vm_startup.TIMERS) == {signal.ITIMER_REAL, signal.ITIMER_VIRTUAL, signal.ITIMER_PROF}
    for setup in STARTUP_STATES.values():
        for outcome in STARTUP_EXITS:
            ownership = (-1, "", "") if setup == STARTUP_STATES["extra-fds"] else None
            cancelled_fixture(f"startup:{outcome}", entry_setup=setup, ownership_case=ownership)
    cancelled_fixture("startup:delayed-cancel", entry_setup=STARTUP_STATES["blocked-SIGINT"])


def test_startup_verification_failure_refuses_before_spawning() -> None:
    for baseline, state in STARTUP_CHECK_CASES.items():
        cancelled_fixture(f"startup-reject:{baseline}", entry_setup=STARTUP_STATES[state])


def test_echild_cannot_be_reported_as_guest_or_helper_success() -> None:
    popen = subprocess.Popen

    def fake_qemu(_args, **kwargs):
        return popen([sys.executable, "-c", 'print("CERALIVE_JOB_DONE=0"); raise SystemExit(37)'], **kwargs)

    previous = signal.signal(signal.SIGCHLD, signal.SIG_IGN)
    try:
        def boot_fake():
            with patch.object(subprocess, "Popen", fake_qemu):
                vm.boot(pathlib.Path("/unused"), b"", "check", 2)

        for operation in (
            lambda: run([sys.executable, "-c", "raise SystemExit(37)"], timeout=2,
                        cancellation=Cancellation(), capture_output=True),
            lambda: run([sys.executable, "-c", "raise SystemExit(37)"], timeout=2,
                        cancellation=Cancellation()),
            boot_fake,
        ):
            try:
                operation()
            except vm_process.ChildStatusError as error:
                assert "exit status unavailable for owned child PID" in str(error)
            else:
                raise AssertionError("ECHILD turned a known failure into success")
    finally:
        signal.signal(signal.SIGCHLD, previous)


def test_no_qemu_or_helper_spawn_under_terminal_mask() -> None:
    cancellation = Cancellation()
    with fixture_signal_mask(), patch.object(subprocess, "Popen") as spawn:
        cancellation.begin_finalization()
        for attempt in (
            lambda: run(["unused"], timeout=1, cancellation=cancellation),
            lambda: vm.boot(pathlib.Path("/unused"), b"", "check", 1, cancellation=cancellation),
            lambda: image_resources.process_priority(os.getpid(), cancellation),
        ):
            with patch.object(image_resources, "require_process_priority", return_value=10), \
                    patch.object(image_resources, "cgroup_limits", return_value=10):
                try:
                    attempt()
                except RuntimeError as error:
                    assert "during terminal finalization" in str(error)
                else:
                    raise AssertionError("child spawn allowed during terminal finalization")
            spawn.assert_not_called()


def test_term_int_hup_and_repeated_term_preserve_teardown() -> None:
    for mode, signum in (("term", signal.SIGTERM), ("term", signal.SIGINT),
                         ("term", signal.SIGHUP), ("repeat", signal.SIGTERM),
                         ("slow", signal.SIGTERM), ("overlay", signal.SIGTERM),
                         ("receipt", signal.SIGTERM)):
        cancelled_fixture(mode, signum)


def test_term_during_final_probe_validation_updates_receipt_and_status() -> None:
    cancelled_fixture("validation")


def test_term_after_final_outcome_is_decided_preserves_receipt_and_status() -> None:
    cancelled_fixture("committed")


def test_final_receipt_rename_decides_status_even_if_directory_sync_fails() -> None:
    cancelled_fixture("exit-sync-error")


def test_mask_restoration_after_rename_cannot_change_launcher_exit() -> None:
    cancelled_fixture("mask-restore-error")


def test_raising_signal_handler_during_rename_cannot_change_published_status() -> None:
    cancelled_fixture("raising-handler")


def test_pending_handler_cannot_interrupt_exit_receipt_readback() -> None:
    cancelled_fixture("shutdown-gap")


def test_every_catchable_signal_stays_blocked_through_committed_pair_exit() -> None:
    start = [name.__name__ for name, _ in image_lifecycle.RECEIPT_STEPS]
    # Trace every production opcode after mask installation. Send real signals
    # at both edges of each protected step, plus the syscall and CLI boundaries.
    for boundary in ("begin_finalization:first", "begin_finalization:last", "mask_block:last",
                     *(f"{step}:{edge}" for step in start[start.index("rename"):]
                       for edge in ("first", "last")),
                     "rename:published", "after-sync", "readback:before", "readback:after", "exit:direct"):
        cancelled_fixture(f"pair:critical:{boundary}")
    cancelled_fixture("pair:mask-mutation")


def test_single_exit_point_uses_readback_after_return_or_exception() -> None:
    cancelled_fixture("late-exit")
    cancelled_fixture("unreadable-exit")
    for fault in ("eintr", "oserror", "memory"):
        cancelled_fixture(f"readback:{fault}")


def test_each_receipt_step_preserves_commit_and_releases_owned_resources() -> None:
    declared = {name for name, value in vars(image_lifecycle.Receipt).items()
                if not name.startswith("_") and callable(value)}
    scheduled = {step.__name__ for step, _ in image_lifecycle.RECEIPT_STEPS}
    assert scheduled == declared
    for step, _cleanup in image_lifecycle.RECEIPT_STEPS:
        for action in ("exception", "oserror", "systemexit", "interrupt", "term-before", "term-during", "memory"):
            cancelled_fixture(f"receipt-step:{step.__name__}:{action}")


def test_teardown_survives_allocation_faults_without_stranding_the_journal() -> None:
    for point in ("timestamp", "receipt", "journal-unlink", "journal-sync",
                  *(step.__name__ for step, _ in image_lifecycle.RECEIPT_STEPS)):
        cancelled_fixture(f"teardown-memory:{point}")
    cancelled_fixture("fault:fail:teardown-rename")


def test_validated_probe_retries_each_commit_preparation_allocation() -> None:
    baseline = cancelled_fixture("commit-memory:baseline")
    assert baseline is not None and len(baseline["points"]) >= 7
    for point in baseline["points"]:
        cancelled_fixture(f"commit-memory:{point}")
    print(f"{len(baseline['points'])} post-validation commit statements", flush=True)


def test_tail_syscall_faults_preserve_the_validated_probe() -> None:
    baseline = cancelled_fixture("tail-io:baseline/EINTR/0")
    assert baseline and baseline["launcher_exit"] == 0 and baseline["stream_bytes"] == 836
    operations = (
        "verification-read", "readback", "journal-unlink", "journal-dir-open", "journal-dir-fsync",
        "journal-dir-close", "exit-mask", "artifact-open", "artifact-write", "artifact-sync", "artifact-close",
        "capture-open", "capture-write", "capture-sync", "live-stream-read",
        *(f"{phase}-{operation}" for phase in ("validation", "teardown", "exit") for operation in (
            "file-open", "write", "file-fsync", "file-close", "rename",
            "dir-open", "dir-fsync", "dir-close",
        )),
    )
    for point in operations:
        for error in ("EINTR", "EPERM", "EIO", "ENOSPC", "EBADF"):
            row = cancelled_fixture(f"tail-io:{point}/{error}/1")
            assert row == baseline, (point, error, baseline, row)
    for phase in ("validation", "teardown", "exit"):
        for error in ("EINTR", "EPERM", "EIO", "ENOSPC", "EBADF"):
            cancelled_fixture(f"tail-io:{phase}-temp-unlink/{error}/1")
    for point in ("verification-read", "readback", "exit-write", "exit-file-fsync", "exit-rename",
                  "exit-dir-fsync", "journal-unlink", "exit-mask"):
        row = cancelled_fixture(f"tail-io:{point}/EINTR/2")
        assert row == (None if point == "exit-file-fsync" else baseline), point
    for error in ("EAGAIN", "ENOSYS", "EIO"):
        assert cancelled_fixture(f"tail-io:live-stream-read/{error}/2") == baseline
    for error in ("EACCES", "EBUSY"):
        assert cancelled_fixture(f"tail-io:live-stream-read/{error}/1") == baseline
    assert cancelled_fixture("tail-io:live-stream-read/EIO/3")["launcher_exit"] == 1
    for point in ("verification-read", "exit-file-fsync", "exit-dir-fsync", "readback", "journal-unlink"):
        cancelled_fixture(f"tail-io:{point}/EINTR/3")
    for error in ("EACCES", "ENOENT", "EBUSY"):
        assert cancelled_fixture(f"tail-io:journal-unlink/{error}/1") == baseline, error
    assert cancelled_fixture("tail-io:journal-unlink/ENOENT/1/still-present") == baseline
    assert cancelled_fixture("tail-io:journal-unlink/EPERM/3") == baseline
    print(f"{len(operations)} tail syscall sites tested with five one-shot errno values", flush=True)


def test_finalization_disposition_fallback_preserves_receipt_and_exit() -> None:
    baseline = cancelled_fixture("tail-io:baseline/EINTR/0")
    for error in ("EINTR", "EPERM", "EIO", "ENOSPC", "EBADF"):
        for signum in (signal.SIGUSR1, *vm.STOP_SIGNALS):
            assert cancelled_fixture(f"tail-io:exit-mask/{error}/3", signum) == baseline, (error, signum)
    for signum in (signal.SIGUSR1, *vm.STOP_SIGNALS):
        assert cancelled_fixture("tail-io:exit-mask/ENOSYS/1", signum) == baseline
        assert cancelled_fixture("tail-io:exit-ignore/EPERM/1", signum) == baseline
        for point in ("exit-dir-open", "exit-dir-fsync", "exit-dir-close", "journal-unlink",
                      "journal-dir-open", "journal-dir-fsync", "journal-dir-close", "readback"):
            for fault in ("EPERM/3", "ENOSYS/1"):
                assert cancelled_fixture(f"tail-io:exit-mask/{fault}/{point}", signum) == baseline
    assert cancelled_fixture("tail-io:exit-ignore/EPERM/3") is None
    assert cancelled_fixture("tail-io:exit-mask/ENOSYS/1/checkpoint") == baseline
    stopped = cancelled_fixture("tail-io:exit-mask/EINTR/0/checkpoint")
    assert stopped["launcher_exit"] == 1 and stopped["stop_reason"] == "cancelled"


def test_large_frame_retries_each_read_at_the_same_offset() -> None:
    control = cancelled_fixture("tail-io:frame-read-baseline/EIO/0")
    offsets, baseline = control["offsets"], control["row"]
    assert offsets[0] == 0 and offsets[-1] == baseline["stream_bytes"] == 787274
    assert len(MAGIC) in offsets and 128 * 1024 in offsets and len(offsets) >= 7
    for offset in offsets:
        for error, count in (("EIO", 1), ("EIO", 2), ("EINTR", 1), ("EINTR", 2), ("EAGAIN", 2)):
            row = cancelled_fixture(f"tail-io:frame-read-{offset}/{error}/{count}")
            assert row == baseline, (offset, error, count, baseline, row)


def test_unsupported_durability_preserves_published_outcome() -> None:
    baseline = cancelled_fixture("tail-io:baseline/EINTR/0")
    paths = ("parent-sync", "capture-sync", "artifact-sync", "artifact-dir-sync", "journal-dir-fsync",
             *(f"{phase}-{where}-fsync" for phase in ("active", "started", "validation", "teardown", "exit")
               for where in ("file", "dir")))
    for path in paths:
        for error in ("ENOSYS", "EINVAL", "ENOTSUP", "EROFS"):
            row = cancelled_fixture(f"tail-io:{path}/{error}/1")
            assert row == baseline, (path, error, baseline, row)
    for error in ("EIO", "ENOSPC", "EDQUOT", "EPERM", "EINTR"):
        assert cancelled_fixture(f"tail-io:exit-file-fsync/{error}/3") is None
        assert cancelled_fixture(f"tail-io:exit-file-fsync/{error}/2") is None


def test_receipt_writeback_failure_rewrites_prepared_bytes_on_a_fresh_inode() -> None:
    fsync = os.fsync
    for error in (errno.EIO, errno.ENOSPC, errno.EDQUOT):
        for failures in (1, 2):
            with tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                marker = root / "exit.json"
                row = {"schema": 1, "launcher_exit": 0, "stop_reason": "verified"}
                attempts = []

                def lose_writeback(fd):
                    info = os.fstat(fd)
                    if stat.S_ISDIR(info.st_mode):
                        return fsync(fd)
                    attempts.append((info.st_ino, pathlib.Path(f"/proc/self/fd/{fd}").read_bytes()))
                    if len(attempts) <= failures:
                        os.ftruncate(fd, 0)
                        raise OSError(error, "modeled writeback loss")
                    return fsync(fd)

                with patch("image_stream.sync_once", lose_writeback):
                    try:
                        image_lifecycle.receipt(marker, row)
                    except image_lifecycle.ReceiptError as exc:
                        assert failures == 2 and exc.__cause__.errno == error
                    else:
                        assert failures == 1
                assert len(attempts) == 2 and attempts[0][0] != attempts[1][0]
                assert attempts[0][1] == attempts[1][1]
                assert json.loads(attempts[1][1]) == row
                assert list(root.iterdir()) == ([marker] if failures == 1 else [])
                if failures == 1:
                    assert marker.read_bytes() == attempts[1][1]


def test_receipt_recovery_does_not_publish_unverified_bytes_or_abandon_a_temporary() -> None:
    import image_stream

    for case in ("corruption", "unlink-enoent", "allocation-after-create"):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            target = root / "exit.json"
            row = {"schema": 1, "launcher_exit": 0, "stop_reason": "verified"}
            real_sync, real_unlink = image_stream.sync_once, os.unlink
            first = root / ".receipt-original"
            failures = 0

            def sync(fd):
                nonlocal failures
                file = pathlib.Path(os.readlink(f"/proc/self/fd/{fd}"))
                failures += 1
                if file == first:
                    if case == "corruption":
                        os.ftruncate(fd, 1)
                        return real_sync(fd)
                    raise OSError(errno.EIO, "fixture writeback error")
                return real_sync(fd)

            unlinks = 0

            def unlink(path, *args, **kwargs):
                nonlocal unlinks
                if path == first and case == "unlink-enoent":
                    unlinks += 1
                    if unlinks == 1 and not kwargs.get("missing_ok"):
                        raise FileNotFoundError(errno.ENOENT, "fixture did not remove the file")
                    if unlinks == 1:
                        return None
                return real_unlink(path, *args, **kwargs)

            created = 0

            def after_acquisition(frame, event, _value):
                nonlocal created
                if event == "return" and frame.f_code is image_stream.create_file.__code__:
                    created += 1
                    if created == 2:
                        raise MemoryError("fixture at exclusive-create return")
                return after_acquisition

            before = set(os.listdir("/proc/self/fd"))
            with patch("image_stream.sync_once", sync), patch.object(os, "unlink", unlink):
                if case == "allocation-after-create":
                    sys.settrace(after_acquisition)
                try:
                    image_lifecycle.receipt(target, row, temporary=first)
                except image_lifecycle.ReceiptError:
                    assert case in ("allocation-after-create", "corruption")
                    assert not target.exists()
                else:
                    assert case == "unlink-enoent" or failures == 2
                    assert json.loads(target.read_bytes()) == row
                finally:
                    sys.settrace(None)
            assert set(os.listdir("/proc/self/fd")) == before
            assert list(root.iterdir()) == ([target] if target.exists() else [])


def test_terminal_receipt_sync_has_one_two_call_budget() -> None:
    import image_stream

    errors = (errno.EINTR, errno.EPERM, errno.EIO, errno.ENOSPC, errno.EDQUOT, errno.ENOSYS)
    row = {"schema": 1, "launcher_exit": 0, "stop_reason": "verified"}
    real_sync = image_stream.sync_once
    with fixture_signal_mask(), tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        for sequence in (*product(errors, repeat=2), *product(errors, repeat=3),
                         *((error,) for error in errors)):
            marker = root / "exit.json"
            issued = []
            verified = False

            def sync(fd):
                index = len(issued)
                issued.append(os.fstat(fd).st_ino)
                if index < len(sequence):
                    raise OSError(sequence[index], "fixture terminal sync")
                real_sync(fd)

            expected = len(sequence) == 1 or errno.ENOSYS in sequence[:2]
            with patch("image_stream.sync_once", sync), patch("image_stream.report_error"):
                try:
                    image_lifecycle.receipt(marker, row, outcome=Cancellation())
                    verified = True
                except image_lifecycle.ReceiptError:
                    pass
            assert len(issued) == (1 if sequence[0] == errno.ENOSYS else 2), (sequence, issued)
            assert len(set(issued)) == len(issued), (sequence, issued)
            assert verified == expected, (sequence, verified)
            assert list(root.iterdir()) == ([marker] if expected else []), sequence
            if expected:
                assert json.loads(marker.read_bytes()) == row
                marker.unlink()


def test_terminal_receipt_readback_restarts_and_uses_the_remaining_attempt() -> None:
    import image_stream

    errors = (errno.EINTR, errno.EAGAIN, errno.EIO, errno.EACCES, errno.EPERM, errno.EBUSY,
              errno.ENOSPC, errno.EDQUOT, errno.ENOSYS, errno.EBADF)
    row = {"schema": 1, "launcher_exit": 0, "stop_reason": "verified"}
    read_at = image_stream._PREAD
    with fixture_signal_mask(), tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        summary = {"capture_lost": False}
        probe = SimpleNamespace(diagnostic_summary=lambda: summary,
                                fallback_fields=image_lifecycle.encode_diagnostic_fields(summary))
        body_length = len(json.dumps(row, sort_keys=True, indent=2)[:-2].encode("ascii"))
        probes = ((None, 0), (None, len((json.dumps(row, sort_keys=True, indent=2) + "\n").encode())),
                  (probe, 0), (probe, body_length), (probe, body_length + len(probe.fallback_fields)))
        for error, (probe, target_offset), fault_scope in product(errors, probes, ("once", "first-inode", "always")):
            marker = root / "exit.json"
            reads = []

            def pread(fd, address, size, offset):
                inode = os.fstat(fd).st_ino
                reads.append((inode, offset))
                if offset == target_offset and (
                    fault_scope == "always"
                    or fault_scope == "first-inode" and inode == reads[0][0]
                    or fault_scope == "once" and sum(at == target_offset for _, at in reads) == 1
                ):
                    image_stream.ctypes.set_errno(error)
                    return -1
                return read_at(fd, address, size, offset)

            with patch("image_stream._PREAD", pread):
                try:
                    image_lifecycle.receipt(marker, row, outcome=Cancellation(), probe=probe)
                except image_lifecycle.ReceiptError:
                    assert fault_scope == "always", (error, target_offset, fault_scope, reads)
            assert list(root.iterdir()) == ([] if fault_scope == "always" else [marker]), (error, target_offset, fault_scope)
            assert len({inode for inode, _ in reads}) == (1 if fault_scope == "once" else 2), reads
            assert sum(not offset for _, offset in reads) >= 2, reads
            if marker.exists():
                assert json.loads(marker.read_bytes()) == (row | summary if probe else row)
                marker.unlink()


def test_each_reached_fresh_receipt_recovery_line_keeps_ownership() -> None:
    import image_stream

    watched = {fn.__code__ for fn in (image_lifecycle.Receipt.file_sync,
                                     image_lifecycle.Receipt._write_payload,
                                     image_stream.create_file,
                                     image_stream.ExclusiveFile.discard,
                                     image_stream.unlink_owned)}
    healthy_lines = set()

    def replay(point=None):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            target, first = directory / "exit.json", directory / ".receipt-original"
            baseline = set(os.listdir("/proc/self/fd"))
            row = {"schema": 1, "launcher_exit": 0, "stop_reason": "verified"}
            recovering = False
            injected = False
            real_sync = image_stream.sync_once

            def sync(fd):
                nonlocal recovering
                if os.readlink(f"/proc/self/fd/{fd}") == str(first):
                    recovering = True
                    raise OSError(errno.EIO, "fixture recovery")
                real_sync(fd)

            def line_fault(frame, event, _arg):
                nonlocal injected
                if frame.f_code not in watched:
                    return None
                if event == "line" and recovering:
                    site = (frame.f_code.co_qualname, frame.f_lineno)
                    if point is None:
                        healthy_lines.add(site)
                    elif site == point:
                        injected = True
                        sys.settrace(None)
                        raise MemoryError("fixture fresh receipt recovery")
                return line_fault

            with patch("image_stream.sync_once", sync):
                sys.settrace(line_fault)
                try:
                    image_lifecycle.receipt(target, row, temporary=first)
                except image_lifecycle.ReceiptError:
                    assert point is not None
                finally:
                    sys.settrace(None)
            assert recovering and injected == (point is not None)
            assert set(os.listdir("/proc/self/fd")) == baseline
            assert list(directory.iterdir()) == ([target] if target.exists() else [])
            if target.exists():
                assert json.loads(target.read_bytes()) == row

    replay()
    assert len(healthy_lines) >= 12
    for point in sorted(healthy_lines):
        replay(point)


def test_failed_terminal_rewrite_cleans_both_temps_after_allocation_faults() -> None:
    import image_stream

    watched = {fn.__code__ for fn in (image_lifecycle.Receipt.temp_cleanup,
                                     image_stream.ExclusiveFile.discard,
                                     image_stream.ExclusiveFile.close, image_stream.unlink_owned)}
    sites = set()

    def replay(fault=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            baseline = set(os.listdir("/proc/self/fd"))
            syncs = 0
            hit = False

            def sync(_fd):
                nonlocal syncs
                syncs += 1
                raise OSError(errno.EIO, "both terminal syncs failed")

            def trace(frame, event, _arg):
                nonlocal hit
                if frame.f_code not in watched:
                    return None
                if syncs == 2 and event == "line":
                    site = (frame.f_code.co_qualname, frame.f_lineno)
                    if fault is None:
                        sites.add(site)
                    elif site == fault:
                        hit = True
                        sys.settrace(None)
                        raise MemoryError("terminal cleanup")
                return trace

            with patch("image_stream.sync_once", sync):
                sys.settrace(trace)
                try:
                    image_lifecycle.receipt(root / "exit.json", {"launcher_exit": 0}, outcome=Cancellation())
                except image_lifecycle.ReceiptError as error:
                    assert isinstance(error.__cause__, image_stream.FileSyncError)
                else:
                    raise AssertionError("published after two failed sync calls")
                finally:
                    sys.settrace(None)
            assert syncs == 2 and hit == (fault is not None)
            assert list(root.iterdir()) == [], fault
            assert set(os.listdir("/proc/self/fd")) == baseline, fault

    replay()
    assert sites
    for site in sorted(sites):
        replay(site)


def test_attempt_preparation_and_journal_survive_transient_io() -> None:
    baseline = cancelled_fixture("tail-io:baseline/EINTR/0")
    for name in ("store", "attempt", "build", "artifacts"):
        for error in ("EINTR", "EPERM", "EIO", "ENOSPC", "EBADF"):
            row = cancelled_fixture(f"tail-io:mkdir-{name}/{error}/1")
            assert row == baseline, (name, error, baseline, row)
    for name in ("verify", "verify-artifacts"):
        for error in ("EINTR", "EPERM", "EIO", "ENOSPC", "EBADF"):
            cancelled_fixture(f"pair:tail-io:mkdir-{name}/{error}/1")
    for phase in ("active", "started"):
        for operation in ("file-open", "write", "file-fsync", "file-close", "rename",
                          "dir-open", "dir-fsync", "dir-close"):
            for error in ("EINTR", "EPERM", "EIO", "ENOSPC", "EBADF"):
                row = cancelled_fixture(f"tail-io:{phase}-{operation}/{error}/1")
                assert row == baseline, (phase, operation, error, baseline, row)


def test_tail_directory_fd_ownership_survives_allocation_faults() -> None:
    for point in ("exit-close-allocation", "journal-close-allocation", "verification-read", "readback"):
        cancelled_fixture(f"tail-io:{point}/MemoryError/1")
    for phase in ("validation", "teardown", "exit", "journal"):
        for operation in ("dir-open", "dir-fsync", "dir-close"):
            cancelled_fixture(f"tail-io:{phase}-{operation}/MemoryError/1")


def test_receipt_temporary_collisions_do_not_remove_unowned_files() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        marker = root / "exit.json"
        occupied = [root / f".receipt-{index}" for index in range(3)]
        for item in occupied:
            item.write_bytes(b"belongs to another transaction")
        spare = root / ".receipt-spare"
        before = descriptor_snapshot()
        with patch.object(image_lifecycle, "receipt_temporary", side_effect=[occupied[1], spare]):
            image_lifecycle.receipt(marker, {"launcher_exit": 0}, temporary=occupied[0])
        assert json.loads(marker.read_bytes()) == {"launcher_exit": 0}
        assert not spare.exists()
        with patch.object(image_lifecycle, "receipt_temporary", side_effect=occupied[1:]):
            try:
                image_lifecycle.receipt(marker, {"launcher_exit": 1}, temporary=occupied[0])
            except image_lifecycle.ReceiptError as error:
                assert isinstance(error.__cause__, FileExistsError)
            else:
                raise AssertionError("exhausted collision retries allowed a rename")
        assert json.loads(marker.read_bytes()) == {"launcher_exit": 0}
        assert all(path.read_bytes() == b"belongs to another transaction" for path in occupied)
        assert descriptor_snapshot() == before


def test_receipt_allocation_faults_close_live_temporary_descriptors() -> None:
    for verdict in ("accepted", "rejected"):
        lines = cancelled_fixture(f"tail-io:{verdict}-fd-line-baseline/MemoryError/0")
        assert lines and len(lines) >= 10
        for line in lines:
            row = cancelled_fixture(f"tail-io:{verdict}-fd-line-{line}/MemoryError/1")
            assert row and row["launcher_exit"] == int(verdict == "rejected"), (verdict, line, row)
        print(f"{verdict}: {len(lines)} receipt FD allocation fault locations", flush=True)


def test_exclusive_file_creation_has_one_owner() -> None:
    def bypasses(file, tree):
        allowed = next((node for node in tree.body if isinstance(node, ast.FunctionDef)
                        and node.name == "create_file"), None) if file == "image_stream.py" else None
        owner_nodes = set(ast.walk(allowed)) if allowed is not None else set()
        for node in ast.walk(tree):
            if ((isinstance(node, ast.Attribute) and node.attr == "O_EXCL")
                    or (isinstance(node, ast.alias) and node.name == "O_EXCL")
                    or (isinstance(node, ast.Constant) and node.value == "O_EXCL")):
                if node not in owner_nodes:
                    yield node.lineno
            if isinstance(node, ast.Call) and (
                    isinstance(node.func, ast.Name) and node.func.id == "open"
                    or isinstance(node.func, ast.Attribute) and node.func.attr == "open"):
                if any(isinstance(arg, ast.Constant) and isinstance(arg.value, str)
                       and arg.value.startswith("x") and set(arg.value) <= set("xbt+")
                       for arg in (*node.args, *(kw.value for kw in node.keywords if kw.arg == "mode"))):
                    yield node.lineno

    root = ROOT / "ci/kernel-runner"
    for file in root.glob("*.py"):
        assert not (violations := list(bypasses(file.name, ast.parse(file.read_text())))), (file, violations)
    for source in ("os.open(path, os.O_CREAT | os.O_EXCL)", "from os import O_EXCL as flags",
                   "path.open('xb')", "open(path, mode='x')"):
        assert list(bypasses("new_owner.py", ast.parse(source))), source


def test_receipt_audit_detects_executed_work_outside_step_table() -> None:
    cancelled_fixture("audit-mutation")


def test_failed_verifier_receipt_does_not_publish_pair_acceptance() -> None:
    cancelled_fixture("pair:fail")
    cancelled_fixture("pair:success")
    with tempfile.TemporaryDirectory() as temporary:
        attempt = pathlib.Path(temporary) / "fixture"
        build, verifier = attempt / "build", attempt / "verify"
        build.mkdir(parents=True)
        verifier.mkdir()
        acceptance = attempt / "acceptance.json"
        real_receipt = image_lifecycle.receipt

        def measure(_args, _parser, _cancellation, jobs):
            image_vm.prepare_exit_receipt(attempt, False, _cancellation)
            for directory in (build, verifier):
                state = {"stop_reason": "transport validated", "identity": asdict(IDENTITY)}
                jobs.append(SimpleNamespace(directory=directory, state=state))
                image_vm.receipt(directory / "teardown.json", state)
            return acceptance, {"content_verified": True}

        def publish(path, row, **kwargs):
            if path.parent == verifier:
                raise OSError(errno.EIO, "fixture verifier receipt write")
            return real_receipt(path, row, **kwargs)

        with patch.object(image_vm, "measure_image", measure), patch.object(image_vm, "receipt", publish):
            try:
                status = image_vm.run_image(SimpleNamespace(image_mode="measure"), None, vm.Cancellation())
            except OSError:
                status = 1  # The CLI catches launcher receipt failures.
        assert status == 1
        assert not acceptance.exists(), "pair was accepted before its verifier receipt"
        assert not (attempt / "exit.json").exists()
        assert "launcher_exit" not in json.loads((build / "teardown.json").read_text())


def test_pair_publication_failure_and_signal_matrix() -> None:
    # Exercise the real receipt writer at every step, for both prerequisite
    # receipts and the final marker. The pair stands in for the expensive guest
    # output; the earlier probe cases exercise the real child and overlay path.
    phases = ("temp-open", "temp-write", "file-sync", "rename", "dir-open", "dir-sync")
    receipts = ("overlay-journal", "started.json", "guest-journal", "transport-validation.json",
                "build/teardown.json", "verify/teardown.json", "acceptance.json", "exit.json")
    real_receipt, real_open, real_dump = image_lifecycle.receipt, os.open, json.dump
    real_fsync, real_replace = os.fsync, os.replace
    for target in receipts:
        for step in phases:
            for failure in (True, False):
                with tempfile.TemporaryDirectory() as temporary:
                    attempt = pathlib.Path(temporary) / IDENTITY.attempt
                    build, verifier = attempt / "build", attempt / "verify"
                    build.mkdir(parents=True)
                    verifier.mkdir()
                    candidate, marker = attempt / "acceptance.json", attempt / "exit.json"
                    paths = {"overlay-journal": attempt / "active.json", "started.json": build / "started.json",
                             "guest-journal": attempt / "active.json",
                             "transport-validation.json": verifier / "transport-validation.json",
                             "build/teardown.json": build / "teardown.json",
                             "verify/teardown.json": verifier / "teardown.json",
                             "acceptance.json": candidate, "exit.json": marker}
                    info = asdict(IDENTITY)
                    result = {"schema": 1, "identity": info, "content_verified": True}
                    cancellation = vm.Cancellation()
                    previous = signal.signal(signal.SIGTERM, cancellation.request)
                    active_name = None
                    injected = False

                    def inject(event):
                        nonlocal injected
                        if active_name == target and event == step and (failure or not injected):
                            injected = True
                            if failure:
                                raise OSError(errno.EIO, f"fixture {target} {step}")
                            os.kill(os.getpid(), signal.SIGTERM)

                    def open_file(path, flags, *args, **kwargs):
                        if isinstance(path, pathlib.Path) and path.name.startswith(".receipt-"):
                            inject("temp-open")
                        if flags & os.O_DIRECTORY:
                            inject("dir-open")
                        return real_open(path, flags, *args, **kwargs)

                    def dump(*args, **kwargs):
                        inject("temp-write")
                        return real_dump(*args, **kwargs)

                    def sync(fd):
                        kind = "dir-sync" if pathlib.Path(f"/proc/self/fd/{fd}").is_dir() else "file-sync"
                        inject(kind)
                        return real_fsync(fd)

                    def replace_file(source, destination):
                        inject("rename")
                        return real_replace(source, destination)

                    def publish(path, row, **kwargs):
                        nonlocal active_name
                        if path == paths.get(active_name):
                            pass
                        elif path in (candidate, marker):
                            active_name = path.name
                        try:
                            return real_receipt(path, row, **kwargs)
                        finally:
                            active_name = None

                    def measure(_args, _parser, flag, jobs):
                        nonlocal active_name
                        image_vm.prepare_exit_receipt(attempt, False, flag)
                        for directory in (build, verifier):
                            state = {"identity": info, "stop_reason": "guest exited; transport validated"}
                            jobs.append(SimpleNamespace(directory=directory, state=state))
                        for name in receipts[:-2]:
                            active_name = name
                            publish(paths[name], {"identity": info})
                            flag.check()
                        return candidate, result

                    try:
                        with patch.object(image_vm, "measure_image", measure), \
                                patch.object(image_vm, "receipt", publish), \
                                patch.object(os, "open", open_file), patch.object(json, "dump", dump), \
                                 patch.object(os, "fsync", sync), patch("image_stream.sync_once", sync), \
                                 patch.object(os, "replace", replace_file):
                            with fixture_signal_mask():
                                status = image_vm.run_image(SimpleNamespace(image_mode="measure"), None, cancellation)
                    finally:
                        signal.signal(signal.SIGTERM, previous)

                    case = (target, step, "failure" if failure else "TERM")
                    assert injected, case
                    after_commit = target == "exit.json" and (
                        step in {"dir-open", "dir-sync"} or step == "rename" and not failure)
                    assert status == (0 if after_commit else 1), case
                    if marker.exists():
                        outcome = json.loads(marker.read_text())
                        assert outcome["launcher_exit"] == status, case
                        if status:
                            assert outcome["stop_reason"] == "cancelled", case
                    assert marker.exists() == (after_commit or not failure), case
                    assert (image_vm.completed_acceptance(candidate) is not None) == after_commit, case
                    assert not list(attempt.rglob(".receipt-*")), case


def test_probe_cleanup_and_artifact_publication_failures_never_publish_success() -> None:
    for step in ("parent-sync", "overlay-create", "overlay-close", "capture-sync",
                 "artifact-sync", "artifact-dir-sync", "stream-unlink", "journal-unlink"):
        for action in ("fail", "term"):
            cancelled_fixture(f"fault:{action}:{step}")


def test_verifier_capsule_and_result_failures_leave_pair_unaccepted() -> None:
    real_open, real_read, real_unlink = os.open, pathlib.Path.read_text, pathlib.Path.unlink
    for step in ("capsule-create", "capsule-copy", "verifier-result", "capsule-unlink", "success"):
        for action in (("success",) if step == "success" else ("fail", "term")):
            with tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                base, input_file, store = root / "base", root / "input.tar", root / "returns"
                base.touch()
                with tarfile.open(input_file, "w") as archive:
                    data = b'{"objects":[]}'
                    header = tarfile.TarInfo("inventory.json")
                    header.size = len(data)
                    archive.addfile(header, io.BytesIO(data))
                identity = replace(IDENTITY, input_sha256=hashlib.sha256(input_file.read_bytes()).hexdigest())
                args = SimpleNamespace(
                    image_mode="measure", input_capsule=input_file, input_sha256=identity.input_sha256,
                    base=base, base_sha256="c" * 64, trust_policy=root / "policy", output_dir=store,
                    attempt=identity.attempt, board=identity.board, source_commit=identity.commit,
                    source_epoch=identity.epoch, source_bundle=None, check_script=None, group_id=None)
                attempt = store / identity.attempt
                capsule = attempt / "verifier-input.tar"
                verification = attempt / "verify/artifacts/verification.json"
                cancellation = vm.Cancellation()
                previous = signal.signal(signal.SIGTERM, cancellation.request)
                injected = False

                def inject(point):
                    nonlocal injected
                    if step != point or (injected and action != "fail"):
                        return
                    injected = True
                    if action == "fail":
                        raise OSError(errno.EIO, f"fixture {point}")
                    os.kill(os.getpid(), signal.SIGTERM)

                def open_file(path, *options, **kwargs):
                    if path == capsule:
                        inject("capsule-create")
                    return real_open(path, *options, **kwargs)

                def addfile(archive, header, file=None):
                    if header.name.startswith("objects/"):
                        inject("capsule-copy")
                    return real_addfile(archive, header, file)

                def read_text(path, *options, **kwargs):
                    if path == verification:
                        inject("verifier-result")
                    return real_read(path, *options, **kwargs)

                def unlink(path, *options, **kwargs):
                    if path == capsule:
                        inject("capsule-unlink")
                    return real_unlink(path, *options, **kwargs)

                def execute(_base, directory, request, _cancellation, jobs):
                    payload = request["payload"]
                    artifacts = directory / "artifacts"
                    assert artifacts.is_dir()
                    state = {"identity": payload["identity"], "stop_reason": "guest exited; transport validated"}
                    jobs.append(SimpleNamespace(directory=directory, state=state))
                    image_lifecycle.receipt(directory / "teardown.json", state)
                    if payload["operation"] == "measure":
                        (artifacts / "fixture").write_bytes(b"public artifact")
                    else:
                        assert request["capsule"] == capsule and capsule.is_file()
                        verification.write_text(json.dumps({
                            "schema": 1, "verified": True, "build_identity": payload["build_identity"],
                            "artifacts": payload["artifacts"],
                            "slots": [{"slot": "rootfs_a"}, {"slot": "rootfs_b"}],
                        }))
                    return artifacts

                real_addfile = tarfile.TarFile.addfile
                try:
                    with patch.multiple(image_vm, require_host_lock=lambda: None, cgroup_admission=lambda: None,
                                        validate_base=lambda *_args: None, disk_admission=lambda *_args: None,
                                        load_policy=lambda *_args: FixturePolicy(), execute=execute), \
                            patch.object(image_resources.ImageCaps, "qemu_limit"), \
                            patch.object(os, "open", open_file), patch.object(tarfile.TarFile, "addfile", addfile), \
                            patch.object(pathlib.Path, "read_text", read_text), \
                            patch.object(pathlib.Path, "unlink", unlink):
                        with fixture_signal_mask():
                            status = image_vm.run_image(args, None, cancellation)
                finally:
                    signal.signal(signal.SIGTERM, previous)
                marker = attempt / "exit.json"
                successful = action == "success"
                assert injected != successful, (step, action)
                assert status == int(not successful), (step, action)
                assert marker.exists() == (action != "fail"), (step, action)
                if marker.exists():
                    row = json.loads(marker.read_text())
                    assert row["launcher_exit"] == status
                    assert row["pair_complete"] == successful
                assert (image_vm.completed_acceptance(attempt / "acceptance.json") is not None) == successful


def test_term_while_check_waits_for_fifo_releases_its_overlay_and_lock() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        script, base, lock = (root / name for name in ("script.fifo", "base", "fixture.lock"))
        os.mkfifo(script)
        base.touch()
        qemu_img = root / "qemu-img"
        qemu_img.write_text("#!/bin/sh\nexit 0\n")
        qemu_img.chmod(0o700)
        qemu = root / "qemu-system-x86_64"
        qemu.write_text(f"#!/bin/sh\ntouch '{root / 'unexpected-qemu'}'\nexit 3\n")
        qemu.chmod(0o700)
        command = ["flock", "--exclusive", "--close", str(lock), sys.executable,
                   str(ROOT / "ci/kernel-runner/vm.py"), "check",
                   "--check-script", str(script), "--base", str(base)]
        with subprocess.Popen(command, start_new_session=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env={"PATH": f"{root}:/usr/bin:/bin",
                              "TMPDIR": temporary, "PYTHONDONTWRITEBYTECODE": "1"}) as launcher:
            writer = handle = None
            try:
                until = time.monotonic() + 5
                while writer is None:
                    try:
                        writer = os.open(script, os.O_WRONLY | os.O_NONBLOCK)
                    except OSError as error:
                        if error.errno != errno.ENXIO:
                            raise
                        assert time.monotonic() < until, "launcher did not open the FIFO"
                        time.sleep(0.01)
                children = pathlib.Path(f"/proc/{launcher.pid}/task/{launcher.pid}/children")
                pid, = map(int, children.read_text().split())
                handle = os.pidfd_open(pid)
                descriptors = [os.readlink(fd) for fd in pathlib.Path(f"/proc/{pid}/fd").iterdir()]
                assert any(str(root) in fd and fd.endswith(" (deleted)") for fd in descriptors)

                signal.pidfd_send_signal(handle, signal.SIGTERM)
                try:
                    output, stderr = launcher.communicate(timeout=3)
                except subprocess.TimeoutExpired as error:
                    raise AssertionError("one TERM left the empty FIFO and lock held") from error

                assert launcher.returncode == 1, stderr.decode()
                assert b"runner cancelled" in stderr
                assert not output and not (root / "unexpected-qemu").exists()
                assert not pathlib.Path(f"/proc/{pid}").exists()
                assert not list(root.glob("job-*"))
                with lock.open("rb") as lock_file:
                    fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                if writer is not None:
                    os.close(writer)
                if handle is not None:
                    os.close(handle)
                if launcher.poll() is None:
                    try:
                        launcher.communicate(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(launcher.pid, signal.SIGKILL)
                        launcher.communicate()


def child_command(args: list[str]) -> list[str]:
    return args[9:] if args[:4] == ["/usr/bin/setpriv", "--pdeathsig", "KILL", "--"] else args


def test_image_has_no_nic_shares_registration_or_credential_environment() -> None:
    real_popen = subprocess.Popen
    envelope = io.BytesIO()
    encode(envelope, [("verification.json", b"{}")], IDENTITY)
    observed = []

    def child(args, **options):
        observed.append(args)
        assert args[args.index("-smp") + 1] == "4"
        assert args[args.index("-m") + 1] == "20480"
        assert args[args.index("-nic") + 1] == "none"
        assert "-netdev" not in args
        assert not any(option in args for option in ("-virtfs", "-fsdev", "-qmp"))
        assert not any("9p" in arg or "hostfwd" in arg or "vhost-user" in arg for arg in args)
        assert "virtserialport,chardev=artifacts,name=ceralive-artifacts" in args
        capsule = next(arg for arg in args if "id=image-input," in arg)
        assert capsule.endswith(",readonly=on")
        assert capsule.startswith("file=/proc/self/fd/")
        assert set(options["env"]) == {"PATH", "LANG"}
        assert options["stdin"] == subprocess.DEVNULL
        assert "preexec_fn" not in options
        assert options["start_new_session"] is True
        assert args[:6] == ["/usr/bin/setpriv", "--pdeathsig", "KILL", "--", "/bin/sh", "-c"]
        assert args[8] == str(os.getpid())
        assert child_command(args)[0] == "qemu-system-x86_64"
        return real_popen([*args[:9], sys.executable, "-c",
                          f"import os; os.write(1, {envelope.getvalue()!r})"], **options)

    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        directory = root / "fixture/build"
        directory.mkdir(parents=True)
        capsule = root / "capsule"
        capsule.write_bytes(b"not a credential")
        with tempfile.TemporaryFile(dir=root) as overlay, ImageJob(directory, IDENTITY, capsule) as job:
            job.state.update(overlay_directory=str(root), retained_bytes=0)
            job.overlay_created(overlay.fileno())
            with patch.object(vm.subprocess, "Popen", child), patch.object(image_lifecycle, "disk_headroom"), \
                    patch.object(image_lifecycle, "process_priority", return_value=FIXTURE_PRIORITY):
                vm.boot(pathlib.Path(f"/proc/self/fd/{overlay.fileno()}"), b"{}", "image", 5,
                        disk_fd=overlay.fileno(), image_job=job)
            assert job.state["qemu_reaped"] is True
        exit_record = json.loads((directory / "teardown.json").read_text())
        assert exit_record["input_descriptor_closed"] is True
        assert (directory / "stream.partial").read_bytes() == envelope.getvalue()
    assert len(observed) == 1


def test_kernel_check_keeps_its_existing_cpu_ram_and_network_defaults() -> None:
    real_popen = subprocess.Popen

    def child(args, **options):
        assert args[args.index("-smp") + 1] == "16"
        assert args[args.index("-m") + 1] == "16384"
        assert "user,id=net0" in args and "virtio-net-pci,netdev=net0" in args
        assert "-chardev" not in args
        return real_popen([sys.executable, "-c", 'print("CERALIVE_JOB_DONE=0")'], **options)

    with patch.object(vm.subprocess, "Popen", child):
        vm.boot(pathlib.Path("/unused"), b"exit 0", "check", 5)


def test_oversized_stream_reaps_only_its_owned_child_and_closes_inputs() -> None:
    real_popen = subprocess.Popen
    children = []

    def child(_args, **options):
        process = real_popen([sys.executable, "-c",
            'import os, signal; os.write(1, b"x" * 1025); signal.pause()'], **options)
        children.append(process)
        return process

    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        directory = root / "fixture/build"
        directory.mkdir(parents=True)
        capsule = root / "capsule"
        capsule.write_bytes(b"fixture")
        try:
            with tempfile.TemporaryFile(dir=root) as overlay, ImageJob(directory, IDENTITY, capsule) as job:
                job.state.update(overlay_directory=str(root), retained_bytes=0)
                job.overlay_created(overlay.fileno())
                with patch.object(vm.subprocess, "Popen", child), \
                        patch.object(image_lifecycle, "CAPS", replace(image_resources.CAPS, stream_max=1024)), \
                        patch.object(image_lifecycle, "disk_headroom"), \
                        patch.object(image_lifecycle, "process_priority", return_value=FIXTURE_PRIORITY):
                    vm.boot(pathlib.Path("/unused"), b"{}", "image", 5,
                            disk_fd=overlay.fileno(), image_job=job)
        except StreamError:
            pass
        else:
            raise AssertionError("oversized stream accepted")
        record = json.loads((directory / "teardown.json").read_text())
        assert record["qemu_reaped"] is True and record["input_descriptor_closed"] is True
        assert (directory / "stream.partial").stat().st_size == 0
        assert len(children) == 1 and children[0].returncode is not None


def test_same_filesystem_headroom_combines_overlay_and_return_budgets() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        path = pathlib.Path(temporary)
        class Usage:
            f_bavail = 50
            f_frsize = image_resources.GIB
        with patch.object(image_resources.os, "statvfs", return_value=Usage()):
            try:
                image_resources.disk_headroom(((path, 20 * image_resources.GIB),
                                              (path, 20 * image_resources.GIB)))
            except image_resources.AdmissionError:
                return
    raise AssertionError("shared filesystem was charged only once")


def test_image_admission_requires_effective_cgroup_caps() -> None:
    gib = image_resources.GIB
    files = {
        "/proc/self/cgroup": "0::/image\n",
        "/proc/meminfo": "MemAvailable: 33554432 kB\n",
        "/sys/fs/cgroup/image/memory.max": str(24 * gib),
        "/sys/fs/cgroup/image/memory.swap.max": "0",
        "/sys/fs/cgroup/image/cpu.max": "400000 100000",
        "/sys/fs/cgroup/image/cpu.weight": "10",
        "/sys/fs/cgroup/image/io.weight": "default 10\n",
    }
    for field, invalid in ((None, None), ("memory.max", "max"), ("memory.swap.max", "1"),
                           ("cpu.max", "max 100000"), ("io.weight", "default 100"),
                           ("cpu.weight", "100")):
        snapshot = files.copy()
        if field:
            snapshot["/sys/fs/cgroup/image/" + field] = invalid
        def read_text(path):
            if str(path) not in snapshot:
                raise FileNotFoundError(path)
            return snapshot[str(path)]

        with patch.object(image_resources, "read_check_text", read_text), \
                patch.object(image_resources, "list_directory", lambda path: [p.name for key in snapshot
                             if (p := pathlib.Path(key)).parent == path]), \
                patch.object(image_resources.os, "sched_getscheduler", return_value=os.SCHED_OTHER), \
                patch.object(image_resources.os, "sched_getaffinity", return_value={0, 1, 2, 3}), \
                patch.object(image_resources.os, "getpriority", return_value=10):
            try:
                image_resources.cgroup_admission()
            except image_resources.AdmissionError:
                assert field is not None
            else:
                assert field is None


def test_nice_nine_requires_low_cpu_weight_and_all_hard_caps() -> None:
    files = {
        "/proc/self/cgroup": "0::/image\n",
        "/proc/meminfo": "MemAvailable: 33554432 kB\n",
        "/sys/fs/cgroup/image/memory.max": str(24 * image_resources.GIB),
        "/sys/fs/cgroup/image/memory.swap.max": "0",
        "/sys/fs/cgroup/image/cpu.max": "400000 100000",
        "/sys/fs/cgroup/image/cpu.weight": "10",
        "/sys/fs/cgroup/image/io.weight": "default 10\n",
    }
    for nice, missing, accepted in ((9, None, True), (19, None, True), (8, None, False),
                                    (-1, None, False), (9, "cpu.weight", False),
                                    (9, "cpu.max", False), (9, "memory.max", False),
                                    (9, "memory.swap.max", False)):
        snapshot = {path: value for path, value in files.items()
                    if pathlib.Path(path).name != missing}
        def read_text(path):
            if str(path) not in snapshot:
                raise FileNotFoundError(path)
            return snapshot[str(path)]

        with patch.object(image_resources, "read_check_text", read_text), \
                patch.object(image_resources, "list_directory", lambda path: [p.name for key in snapshot
                             if (p := pathlib.Path(key)).parent == path]), \
                patch.object(image_resources.os, "sched_getscheduler", return_value=os.SCHED_OTHER), \
                patch.object(image_resources.os, "sched_getaffinity", return_value={0, 1, 2, 3}), \
                patch.object(image_resources.os, "getpriority", return_value=nice):
            try:
                image_resources.cgroup_admission()
            except image_resources.AdmissionError as error:
                assert not accepted, (nice, missing, str(error))
            else:
                assert accepted, (nice, missing)


def test_reconciliation_holds_admission_until_owned_overlay_descriptors_close() -> None:
    scan = image_lifecycle.list_directory
    with tempfile.TemporaryDirectory() as temporary, \
            patch.object(image_lifecycle, "list_directory", side_effect=lambda path, **kwargs:
                         [str(os.getpid())] if path == image_lifecycle.PROC_ROOT else scan(path, **kwargs)):
        root = pathlib.Path(temporary)
        # Keep the inode linked through reconciliation so unrelated CI logs cannot reuse it.
        with (root / "overlay").open("w+b") as owned:
            inode = os.fstat(owned.fileno())
            (root / "active.json").write_text(json.dumps({
                "attempt": "interrupted", "overlay_inode": [inode.st_dev, inode.st_ino]}))
            try:
                reconcile(root)
            except image_resources.AdmissionError:
                pass
            else:
                raise AssertionError("live owned overlay admitted another guest")
        with (root / "unrelated.log").open("wb"):
            reconcile(root)
        record = json.loads((root / "interrupted.reconciled.json").read_text())
        assert record["overlay_descriptors_closed"] is True
        assert record["stop_reason"] == "previous launcher interrupted; guest cleanup unknown"


def test_reconciliation_checks_descriptors_of_a_second_real_process() -> None:
    code = "import os,sys; os.fstat(int(sys.argv[1])); print('ready', flush=True); sys.stdin.read()"
    scan = image_lifecycle.list_directory
    with tempfile.TemporaryDirectory() as temporary:
        store = pathlib.Path(temporary)
        with (store / "overlay").open("wb") as overlay:
            inode = os.fstat(overlay.fileno())
            child = subprocess.Popen([sys.executable, "-c", code, str(overlay.fileno())],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     pass_fds=(overlay.fileno(),))
        with child:
            try:
                assert select.select([child.stdout], [], [], 2)[0]
                assert child.stdout.readline() == b"ready\n"
                journal = store / "active.json"
                journal.write_text(json.dumps({"attempt": "interrupted",
                                               "overlay_inode": [inode.st_dev, inode.st_ino]}))
                record = store / "interrupted.reconciled.json"

                def scoped_proc(path, **kwargs):
                    entries = scan(path, **kwargs)
                    if path == image_lifecycle.PROC_ROOT:
                        return [pid for pid in entries if pid in (str(os.getpid()), str(child.pid))]
                    return entries

                with patch.object(image_lifecycle, "list_directory", scoped_proc):
                    try:
                        reconcile(store)
                    except image_resources.AdmissionError as error:
                        assert f"/proc/{child.pid}/fd/" in str(error), error
                    else:
                        raise AssertionError("foreign process still held the owned overlay")
                    assert journal.exists() and not record.exists()
                    child.stdin.close()
                    assert child.wait(timeout=2) == 0
                    reconcile(store)
                assert not journal.exists()
                assert json.loads(record.read_text())["overlay_descriptors_closed"] is True
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=2)


def test_journal_reconciliation_restarts_and_never_certifies_an_incomplete_proc_scan() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        store, proc = root / "store", root / "proc"
        store.mkdir()
        fd_directory = proc / "123" / "fd"
        fd_directory.mkdir(parents=True)
        (fd_directory / "7").touch()
        (proc / "123" / "stat").write_text(f"123 (fixture) Z {'0 ' * 19}\n")
        row = {"attempt": "interrupted", "launcher": "123:0", "overlay_inode": [0, 0]}
        active = store / "active.json"
        scan = image_lifecycle.list_directory
        for site in (store, proc, fd_directory):
            for error in (errno.EIO, errno.EINTR, errno.EAGAIN, errno.EACCES, errno.EPERM, errno.ENOENT):
                for count in (1, 3):
                    active.write_text(json.dumps(row))
                    record = store / "interrupted.reconciled.json"
                    record.unlink(missing_ok=True)
                    calls = []

                    def enumerate_fault(path, *args, **kwargs):
                        calls.append(path)
                        if path == site and calls.count(site) <= count:
                            raise OSError(error, "fixture unreadable inventory")
                        return scan(path, *args, **kwargs)

                    with patch.object(image_lifecycle, "PROC_ROOT", proc, create=True), \
                            patch.object(image_lifecycle, "list_directory", enumerate_fault):
                        try:
                            reconcile(store)
                        except (OSError, image_resources.AdmissionError):
                            assert active.exists() and not record.exists()
                        else:
                            assert count == 1 and error in (errno.EIO, errno.EINTR, errno.EAGAIN, errno.ENOENT)
                            assert calls.count(store) >= 2
                            assert not active.exists() and json.loads(record.read_bytes())["overlay_descriptors_closed"]


def test_image_base_rejects_backing_and_nested_external_data_files() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        base = pathlib.Path(temporary) / "public-base-fixture"
        base.write_bytes(b"synthetic public base")
        base.chmod(0o444)
        digest = hashlib.sha256(b"synthetic public base").hexdigest()
        valid = {"format": "qcow2", "virtual-size": 128 * image_resources.GIB,
                 "format-specific": {"type": "qcow2", "data": {"compat": "1.1"}}}
        for changes in ({}, {"backing-filename": "/foreign"},
                        {"format-specific": {"data": {"data-file": "/foreign"}}},
                        {"format-specific": {"data": {"data-file-raw": True}}},
                        {"virtual-size": 240 * image_resources.GIB}):
            result = subprocess.CompletedProcess([], 0, json.dumps(valid | changes).encode())
            with patch("image_vm.run", return_value=result):
                try:
                    validate_base(base, digest)
                except image_resources.AdmissionError:
                    assert changes
                else:
                    assert not changes


def test_quarantined_outputs_do_not_reduce_future_pair_disk_admission() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        store = pathlib.Path(temporary)
        artifacts = store / "previous/build/artifacts"
        artifacts.mkdir(parents=True)
        with (artifacts / "fixture").open("wb") as output:
            output.write(b"public fixture" * 1024)
            output.flush()
            os.fsync(output.fileno())
        allocated = (artifacts / "fixture").stat().st_blocks * 512
        assert allocated > 0
        assert retained_outputs(store, IDENTITY, ("c" * 64, "d" * 64)) == 0
        (store / "previous/acceptance.json").write_text(json.dumps({
            "schema": 1, "content_verified": True, "base_sha256": "c" * 64,
            "public_root_der_sha256": "d" * 64,
            "identity": {"attempt": "previous", "board": "orange-pi-5-plus",
                         "commit": IDENTITY.commit, "epoch": IDENTITY.epoch,
                         "input_sha256": "b" * 64}}))
        candidate = store / "previous/acceptance.json"
        assert retained_outputs(store, IDENTITY, ("c" * 64, "d" * 64)) == 0
        (candidate.parent / "exit.json").write_text(json.dumps({
            "schema": 1, "launcher_exit": 0, "pair_complete": True,
            "identity": json.loads(candidate.read_text())["identity"],
            "acceptance_sha256": hashlib.sha256(candidate.read_bytes()).hexdigest(),
        }))
        assert retained_outputs(store, IDENTITY, ("c" * 64, "d" * 64)) == allocated


def test_duplicate_store_refusal_does_not_treat_a_partial_scan_as_empty() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        store = root / "returns"
        prior = store / "previous"
        prior.mkdir(parents=True, mode=0o700)
        store.chmod(0o700)
        (store / "unfinished").mkdir()
        base, capsule = root / "base", root / "input"
        base.write_bytes(b"base")
        capsule.write_bytes(b"capsule")
        digest = hashlib.sha256(b"capsule").hexdigest()
        args = SimpleNamespace(image_mode="probe", base=base, input_capsule=capsule, input_sha256=digest,
                               base_sha256="c" * 64, trust_policy=root / "policy", output_dir=store,
                               attempt=IDENTITY.attempt, board=IDENTITY.board, source_commit=IDENTITY.commit,
                               source_epoch=IDENTITY.epoch, source_bundle=None, check_script=None, group_id=None)
        identity = asdict(replace(IDENTITY, attempt="previous", input_sha256=digest))
        acceptance = json.dumps({"schema": 1, "identity": identity, "content_verified": True,
                                 "base_sha256": "c" * 64, "public_root_der_sha256": "d" * 64}).encode()
        (prior / "acceptance.json").write_bytes(acceptance)
        (prior / "exit.json").write_text(json.dumps({"schema": 1, "launcher_exit": 0, "pair_complete": True,
                                                    "identity": identity,
                                                    "acceptance_sha256": hashlib.sha256(acceptance).hexdigest()}))
        listdir = os.listdir

        for error in (errno.EIO, errno.EINTR, errno.EAGAIN, errno.EPERM, errno.ENOENT):
            for failures in (1, 3):
                scans = 0
                injected = 0
                diagnostics = []

                def scan(path):
                    nonlocal scans, injected
                    if path == store:
                        scans += 1
                        return ["unfinished", "previous"]
                    if path == store / "unfinished" and injected < failures:
                        injected += 1
                        raise OSError(error, "fixture scan failure")
                    return listdir(path)

                with patch.object(image_vm, "list_directory", scan), \
                        patch.object(image_vm, "require_host_lock"), patch.object(image_vm, "cgroup_admission"), \
                        patch.object(image_vm, "load_policy", return_value=SimpleNamespace()) as policy, \
                        patch.object(image_vm, "asdict", side_effect=lambda value: {"root_der_sha256": "d" * 64}
                                     if value is policy.return_value else asdict(value)), \
                        patch.object(image_vm, "report_error", side_effect=diagnostics.append), \
                        patch.object(image_vm, "run") as launch, patch.object(image_vm, "execute") as execute:
                    assert image_vm.run_image(args, None, vm.Cancellation()) == 1
                launch.assert_not_called()
                execute.assert_not_called()
                recovered = error in (errno.EIO, errno.EINTR, errno.EAGAIN) and failures == 1
                assert scans == (2 if recovered else 3 if error in (errno.EIO, errno.EINTR, errno.EAGAIN) else 1)
                assert len(diagnostics) == 1
                assert ("already contains this board" if recovered else "cannot complete") in str(diagnostics[0])
                assert not (store / IDENTITY.attempt).exists()


class TransportCases:
    tests = (
        test_pipe_setup_allocation_failure_does_not_close_a_reused_fd,
        test_probe_receipts_record_safe_console_tail_and_last_stage_on_success_and_timeout,
        test_diagnostic_acquisition_and_sequence_are_independent_of_the_probe,
        test_serial_reader_cleanup_faults_preserve_the_committed_probe,
        test_failed_console_unregister_does_not_spin_or_change_probe_result,
        test_backup_selector_close_faults_preserve_the_committed_probe,
        test_full_host_stderr_does_not_block_exit_after_probe_timeout,
        test_guest_poweroff_does_not_depend_on_image_completion_marker,
        test_guest_failure_frame_and_poweroff_survive_full_standard_streams,
        test_probe_stderr_flood_does_not_depend_on_host_reads,
    )


class OwnershipCases:
    tests = (
        test_pidfd_close_faults_preserve_normal_and_cancelled_probe_receipts,
        test_pipe_close_statement_faults_preserve_eof_and_the_complete_probe,
        test_pidfd_registration_statement_faults_preserve_launcher_reaping,
        test_all_probe_transport_owner_close_faults_preserve_the_committed_probe,
        test_probe_transport_setup_failure_prevents_guest_launch_and_exit_commit,
        test_live_capture_rejects_new_diagnostic_io,
        test_live_and_teardown_closes_go_through_transport_guard,
    )


class ProcessCases:
    tests = (
        test_pidfd_signal_faults_preserve_launcher_reaping_and_receipts,
        test_post_spawn_faults_reap_each_child_and_close_its_pipes,
        test_helper_failures_preserve_the_validated_probe_receipt,
        test_only_qemu_is_alive_during_probe_capture,
        test_io_priority_is_sampled_in_process_and_fails_closed,
    )


class PreparationHelperCases:
    tests = (test_post_spawn_faults_cover_preparation_and_registration_helpers,)


class ShutdownCases:
    tests = (
        test_one_term_in_selector_reaps_term_resistant_qemu,
        test_inherited_blocked_and_ignored_signals_do_not_reach_children,
        test_no_qemu_or_helper_spawn_under_terminal_mask,
        test_term_int_hup_and_repeated_term_preserve_teardown,
        test_term_during_final_probe_validation_updates_receipt_and_status,
    )


class ReceiptCases:
    tests = (
        test_term_after_final_outcome_is_decided_preserves_receipt_and_status,
        test_final_receipt_rename_decides_status_even_if_directory_sync_fails,
        test_mask_restoration_after_rename_cannot_change_launcher_exit,
        test_raising_signal_handler_during_rename_cannot_change_published_status,
        test_pending_handler_cannot_interrupt_exit_receipt_readback,
        test_every_catchable_signal_stays_blocked_through_committed_pair_exit,
        test_single_exit_point_uses_readback_after_return_or_exception,
        test_each_receipt_step_preserves_commit_and_releases_owned_resources,
        test_receipt_audit_detects_executed_work_outside_step_table,
    )


class PairAndAdmissionCases:
    tests = (
        test_failed_verifier_receipt_does_not_publish_pair_acceptance,
        test_pair_publication_failure_and_signal_matrix,
        test_probe_cleanup_and_artifact_publication_failures_never_publish_success,
        test_verifier_capsule_and_result_failures_leave_pair_unaccepted,
        test_term_while_check_waits_for_fifo_releases_its_overlay_and_lock,
        test_image_has_no_nic_shares_registration_or_credential_environment,
        test_kernel_check_keeps_its_existing_cpu_ram_and_network_defaults,
        test_oversized_stream_reaps_only_its_owned_child_and_closes_inputs,
        test_same_filesystem_headroom_combines_overlay_and_return_budgets,
        test_image_admission_requires_effective_cgroup_caps,
        test_nice_nine_requires_low_cpu_weight_and_all_hard_caps,
        test_reconciliation_holds_admission_until_owned_overlay_descriptors_close,
        test_reconciliation_checks_descriptors_of_a_second_real_process,
        test_journal_reconciliation_restarts_and_never_certifies_an_incomplete_proc_scan,
        test_image_base_rejects_backing_and_nested_external_data_files,
        test_quarantined_outputs_do_not_reduce_future_pair_disk_admission,
        test_duplicate_store_refusal_does_not_treat_a_partial_scan_as_empty,
    )


if __name__ == "__main__":
    if sys.argv[1:2] == ["--fixture-launcher"]:
        fixture_launcher(pathlib.Path(sys.argv[2]), sys.argv[3], signal.Signals(int(sys.argv[4])))
        raise AssertionError("launcher did not exit")
    selections = {
        "--tail-syscalls": (test_tail_syscall_faults_preserve_the_validated_probe,
                            test_tail_directory_fd_ownership_survives_allocation_faults,
                            test_receipt_temporary_collisions_do_not_remove_unowned_files,
                            test_receipt_allocation_faults_close_live_temporary_descriptors,
                            test_exclusive_file_creation_has_one_owner),
        "--terminal-fallback": (test_finalization_disposition_fallback_preserves_receipt_and_exit,),
        "--read-and-sync": (test_large_frame_retries_each_read_at_the_same_offset,
                            test_unsupported_durability_preserves_published_outcome,
                            test_receipt_writeback_failure_rewrites_prepared_bytes_on_a_fresh_inode,
                            test_receipt_recovery_does_not_publish_unverified_bytes_or_abandon_a_temporary,
                            test_each_reached_fresh_receipt_recovery_line_keeps_ownership),
        "--terminal-io-budget": (test_terminal_receipt_sync_has_one_two_call_budget,
                                 test_terminal_receipt_readback_restarts_and_uses_the_remaining_attempt,
                                 test_failed_terminal_rewrite_cleans_both_temps_after_allocation_faults),
        "--admission-restart": (test_priority_syscall_error_restarts_the_whole_observation,
                                test_late_disk_error_restarts_store_admission_before_execution),
        "--attempt-preparation": (test_attempt_preparation_and_journal_survive_transient_io,),
        "--term-boundary": (test_priority_failure_reaps_at_the_serial_write_boundary,),
        "--finalization": (test_teardown_survives_allocation_faults_without_stranding_the_journal,
                           test_validated_probe_retries_each_commit_preparation_allocation),
        "--transport": TransportCases.tests, "--ownership": OwnershipCases.tests,
        "--process": ProcessCases.tests,
        "--helper-process": PreparationHelperCases.tests,
        "--lost-child": (test_lost_popen_result_is_reaped_before_terminal_receipts,),
        "--qemu-memory": (test_qemu_main_path_memory_faults_fail_closed,),
        "--disk-memory": (test_disk_helper_main_path_memory_faults_fail_closed,),
        "--shutdown": ShutdownCases.tests, "--receipts": ReceiptCases.tests,
        "--pair-and-admission": PairAndAdmissionCases.tests,
        "--startup": (test_hostile_startup_does_not_change_guest_outcome,
                      test_startup_verification_failure_refuses_before_spawning,
                      test_echild_cannot_be_reported_as_guest_or_helper_success),
    }
    selected = tuple(test for shard in selections.values() for test in shard)
    assert Counter(selected) == Counter(test for name, test in globals().items() if name.startswith("test_"))
    args = sys.argv[1:]
    if not args:
        tests = selected
    elif args == ["--lifecycle"]:
        tests = selected[:-len(selections["--startup"])]
    elif len(args) == 1 and args[0] in selections:
        tests = selections[args[0]]
    else:
        raise SystemExit("usage: image_profile_test.py [" + " | ".join(selections) + "]")
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"image profile: {len(tests)} passed")
