#!/usr/bin/env python3
"""Run the real launcher lifecycle against small Python children, never a VM."""

from dataclasses import asdict, dataclass, replace
import atexit
from contextlib import ExitStack, contextmanager, suppress
import dis
import errno
import fcntl
import io
import inspect
from itertools import count, product
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
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ci/kernel-runner"))
import image_lifecycle
import image_resources
import image_vm
import vm_process
import vm_startup
from image_lifecycle import ImageJob, reconcile
from image_stream import Identity, StreamError, encode
import vm
from image_vm import retained_outputs, validate_base
from vm_process import CATCHABLE_SIGNALS, Cancellation, run

IDENTITY = Identity("fixture", "rock-5b-plus", "a" * 40, 1, "b" * 64)
FIXTURE_PRIORITY = {"nice": 9, "ionice": "best-effort: prio 7", "cpu_weight": 10}
SUCCESS_GUEST_MODES = ("receipt", "validation", "committed", "exit-sync-error", "mask-restore-error",
                       "raising-handler", "late-exit", "unreadable-exit", "shutdown-gap")
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


def named(path) -> pathlib.Path:
    """Resolve a launcher path that passes through a held /proc/self/fd directory."""
    return pathlib.Path(os.path.realpath(path))


def signal_status(path: pathlib.Path) -> tuple[int, int, int]:
    fields = dict(line.split(":", 1) for line in path.read_text().splitlines() if ":" in line)
    return tuple(int(fields[key], 16) for key in ("SigBlk", "SigIgn", "SigCgt"))


def fixture_launcher(root: pathlib.Path, mode: str, signum: signal.Signals) -> None:
    """Run the CLI and deliver a real signal inside the poll owned by select()."""
    poll_type = selectors.EpollSelector._selector_cls
    replace_file = os.replace
    sigmask = signal.pthread_sigmask
    read_text = pathlib.Path.read_text
    read_bytes = pathlib.Path.read_bytes
    fsync = os.fsync
    unlink = pathlib.Path.unlink
    open_image_overlay = image_lifecycle.open_image_overlay
    returned_json = image_vm.returned_json
    directory = root / "returns/fixture/build"
    fault = mode.split(":")[1:] if mode.startswith("fault:") else None
    receipt_fault = mode.split(":")[1:] if mode.startswith("receipt-step:") else None
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

    def fixture_verify(checks):
        verify_startup(checks)
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
        if mode == "unreadable-exit" and named(path) == directory / "exit.json":
            raise OSError(errno.EIO, "fixture final receipt readback")
        if named(path) == directory.parent / "exit.json" and trace_terminal:
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
        final = named(transaction.path) == directory / "exit.json"
        if final:
            with (root / "steps").open("a") as log:
                print(action.__name__, file=log)
        if (final and receipt_fault and action.__name__ == receipt_fault[0]
                and not (root / "injected").exists()):
            (root / "injected").touch()
            kind = receipt_fault[1]
            if kind == "term-before":
                cancel()
            if kind in {"exception", "oserror", "systemexit", "interrupt"}:
                # Successful close can also report an error. For rename,
                # inject before the syscall to model a failed commit.
                if action.__name__ in {"file_close", "dir_close", "temp_cleanup"}:
                    action(transaction)
                error = {"exception": Exception, "oserror": OSError,
                         "systemexit": SystemExit, "interrupt": KeyboardInterrupt}[kind]
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
        if (mode == "mask-restore-error" and how == signal.SIG_SETMASK
                and (directory / "exit.json").exists()):
            (root / "restore-attempt").touch()
            raise OSError(errno.EPERM, "fixture final mask restoration")
        previous = sigmask(how, signals)
        if (how == signal.SIG_BLOCK and signals == CATCHABLE_SIGNALS
                and sys._getframe(1).f_code.co_name != "sanitize_startup"):
            assert not terminal_entered, "terminal mask was installed twice"
            terminal_entered = True
        return previous

    def cancel() -> None:
        nonlocal sent
        sent = True
        (root / "sent").write_text(str(time.monotonic()))
        os.kill(os.getpid(), signum)

    def fault_at(step: str) -> None:
        if fault is None or fault[1] != step or (root / "injected").exists():
            return
        (root / "injected").touch()
        if fault[0] == "fail":
            raise OSError(errno.EIO, f"fixture {step}")
        cancel()

    def publish(source, destination) -> None:
        nonlocal during, fail_sync
        destination = named(destination)
        if pair:
            with (root / "sequence").open("a") as log:
                print(destination.relative_to(root / "returns"), file=log)
        if (destination in {directory / "exit.json", directory / "teardown.json"}
                or pair and destination.name in {"teardown.json", "exit.json"}):
            # Compare real descriptor targets before the launcher exits.
            live = {os.readlink(fd) for fd in pathlib.Path("/proc/self/fd").iterdir()
                    if fd.is_symlink() and fd.exists()}
            owned = root / "owned-fds"
            if fault and not (root / "ready").exists():
                held = set()
            else:
                held = set(json.loads(owned.read_text()))
                assert held, "started fake QEMU has no inherited descriptor inventory"
            if destination.name == "teardown.json":
                # The validated input owner remains for a subsequent verifier.
                pins = {str(root / "capsule"), str(directory.parent / "verifier-input.tar")}
                held -= pins
                for pin in pins:
                    assert sum(1 for fd in pathlib.Path("/proc/self/fd").iterdir()
                               if fd.exists() and os.readlink(fd) == pin) <= 1
            else:
                held.update((str(root / "capsule"), str(root / "base"),
                             str(directory.parent / "verifier-input.tar")))
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
        if mode == "raising-handler" and destination == directory / "exit.json":
            os.kill(os.getpid(), signal.SIGUSR1)
            assert signal.SIGUSR1 in signal.sigpending()
            (root / "handler-pending").touch()
        if trace_terminal and destination == directory.parent / "exit.json":
            inject_terminal("rename:published")

    def sync(fd):
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
            if path == location:
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
        path = named(path)
        if path == directory / "stream.partial":
            fault_at("stream-unlink")
        if path == root / "returns/active.json":
            fault_at("journal-unlink")
        return unlink(path, *args, **kwargs)

    def overlay(*args, **kwargs):
        fault_at("overlay-create")
        file = open_image_overlay(*args, **kwargs)

        class Overlay:
            def fileno(self):
                return file.fileno()

            def close(self):
                file.close()
                fault_at("overlay-close")

        return Overlay()

    def read_result(path, *args, **kwargs):
        if mode == "validation" and named(path) == directory / "artifacts/verification.json":
            cancel()
        return returned_json(path, *args, **kwargs)

    def poller():
        epoll = poll_type()

        class Poll:
            def __getattr__(self, name):
                return getattr(epoll, name)

            def poll(self, *args):
                if (not fault and not audit_receipts and not pair
                        and startup not in {"success", "failure", "signal"}
                        and not mode.startswith(("stderr-flood:", "probe-invalid:"))
                        and mode not in ("priority-failure", "priority-floor")
                        and mode not in SUCCESS_GUEST_MODES and not sent):
                    until = time.monotonic() + 5
                    while not (root / "ready").exists():
                        assert time.monotonic() < until, "fake QEMU never reached startup"
                        time.sleep(0.01)
                    cancel()
                    if startup and (root / "startup-ready").exists():
                        return []  # The startup matrix targets entry state, not the existing 1s poll bound.
                return epoll.poll(*args)

        return Poll()

    validate_return = image_vm.validate_return
    capture = ImageJob.capture

    def fixture_capture(job, process, seconds):
        if mode.startswith("stderr-flood:"):
            assert process.stderr is None, "launcher received a guest stderr read end"
            children = pathlib.Path("/proc/thread-self/children").read_text().split()
            assert children == [str(process.pid)], ("children at capture entry", children)
            read = os.read
            received = 0
            interrupted = False
            stream_fd = process.stdout.fileno()

            def read_capture(fd, size):
                nonlocal received, interrupted
                if fd == stream_fd and received and not interrupted:
                    interrupted = True
                    raise OSError(errno.EIO, "fixture live frame read")
                chunk = read(fd, size)
                if fd == stream_fd:
                    received += len(chunk)
                return chunk

            with patch.object(os, "read", read_capture):
                capture(job, process, seconds)
            assert interrupted and received == 787_274
            return
        return capture(job, process, seconds)

    def capture_priority(pid, cancellation, **options):
        with (root / "priority-calls").open("a") as calls:
            print(json.dumps({"settle": options.get("settle") is not None}), file=calls)
        if mode in ("priority-failure", "priority-floor"):
            deadline = time.monotonic() + 2
            while not (root / "ready").exists():
                assert time.monotonic() < deadline, "fixture guest never reached live priority check"
                time.sleep(0.005)
            assert pathlib.Path("/proc/thread-self/children").read_text().split() == [str(pid)]
            (root / "priority-failed").touch()
            if mode == "priority-floor":
                # As with the failed ioprio sample, refuse once the stand-in has written its frame and exited.
                exited = os.pidfd_open(pid)
                try:
                    assert select.select([exited], [], [], 5)[0], "fixture guest did not exit"
                finally:
                    os.close(exited)
                raise image_resources.PriorityRefusal(-4, os.SCHED_OTHER)
            with patch.object(image_resources._LIBC, "syscall", return_value=-1), \
                    patch.object(image_resources.ctypes, "get_errno", return_value=errno.EPERM):
                return image_resources.process_priority(pid, cancellation)
        if mode.startswith("stderr-flood:"):
            children = pathlib.Path("/proc/thread-self/children").read_text().split()
            assert children == [str(pid)], ("children during capture", children)
            (root / "sole-child").touch()
        return image_resources.process_priority(pid, cancellation, **options) if inherited else FIXTURE_PRIORITY

    if mode.startswith("stderr-flood:"):
        def audit_capture_spawns(event, args):
            if event not in {"subprocess.Popen", "os.fork", "os.posix_spawn"}:
                return
            assert not (directory / "started.json").exists(), ("extra child during capture", event)
            assert event == "subprocess.Popen", event
            argv = args[1]
            name = pathlib.Path(argv[0]).name
            if name == "setpriv":
                assert "qemu-system-x86_64" in argv
                name = "qemu-system-x86_64"
            if name == "qemu-system-x86_64":
                assert not pathlib.Path("/proc/thread-self/children").read_text().split()
            with (root / "launches").open("a") as log:
                print(" ".join((name, argv[1])) if name == "qemu-img" else name, file=log)

        sys.addaudithook(audit_capture_spawns)

    def fixture_return(job, verifier):
        # Only the production build's multi-GiB artifact set is substituted.
        if not pair or verifier:
            if mode.startswith("stderr-flood:"):
                assert (job.directory / "stream.partial").read_bytes() == (root / "probe.frame").read_bytes()
                assert not (job.directory / "diagnostic.partial").exists()
            return validate_return(job, verifier)
        job.cancellation.check()
        target = job.directory / "artifacts"
        target.mkdir()
        (target / "fixture").write_bytes(b"public artifact")

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
             if audit_receipts else image_lifecycle.RECEIPT_STEPS)
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
    if mode == "audit-mutation":
        namespace = image_lifecycle.__dict__.copy()
        tail = "    return transaction.entry\n"
        source = inspect.getsource(writer)
        assert source.count(tail) == 1 and source.endswith(tail)
        source = source.replace(tail, "    transaction.path.stat()\n    os.statvfs(transaction.path.parent)\n" + tail)
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
        patches.enter_context(patch.object(vm_startup, "verify_startup", fixture_verify))
        patches.enter_context(patch.object(
            vm_process, "TERM_GRACE_SECONDS", 0.2 if startup else vm_process.TERM_GRACE_SECONDS))
        patches.enter_context(patch.object(selectors.EpollSelector, "_selector_cls", staticmethod(poller)))
        for patcher in (
            patch.object(image_lifecycle, "RECEIPT_STEPS", table),
            patch.object(image_lifecycle, "receipt", writer),
            patch.object(image_vm, "receipt", writer),
            patch.object(image_vm, "run_image", image_entry),
            patch.object(os, "_exit", terminal_exit if trace_terminal
                         else audited_exit if audit_receipts else real_exit),
            patch.object(os, "replace", publish),
            patch.object(signal, "pthread_sigmask", mask),
            patch.object(os, "fsync", sync),
            patch.object(pathlib.Path, "unlink", remove),
            patch.object(image_lifecycle, "open_image_overlay", overlay),
            patch.object(image_vm, "returned_json", read_result),
            patch.object(pathlib.Path, "read_bytes", fixture_read_bytes),
            patch.object(ImageJob, "capture", fixture_capture),
            patch.object(image_vm, "validate_return", fixture_return),
            patch.multiple(image_vm, require_host_lock=lambda: None, cgroup_admission=lambda: None,
                           disk_admission=lambda *_args: None, disk_headroom=lambda *_args: None),
            patch.object(image_vm, "load_policy", return_value=FixturePolicy()),
            patch.object(image_lifecycle, "disk_headroom"),
            patch.object(image_lifecycle, "process_priority", capture_priority),
            patch.object(image_resources, "require_process_priority", return_value=FIXTURE_PRIORITY["nice"]),
            patch.object(image_resources, "cgroup_limits", return_value=FIXTURE_PRIORITY["cpu_weight"]),
            # Keep priority observations independent of the runner's inherited I/O class.
            patch.object(image_resources._LIBC, "syscall",
                         return_value=(2 << image_resources.IOPRIO_CLASS_SHIFT) | 7),
        ):
            patches.enter_context(patcher)
        runpy.run_path(sys.argv[0], run_name="__main__")


@dataclass(frozen=True, slots=True)
class FixturePolicy:
    root_der_sha256: str = "d" * 64


def cancelled_fixture(mode: str, signum: signal.Signals = signal.SIGTERM, *,
                      blocked: tuple[signal.Signals, ...] = (),
                      ignored: tuple[signal.Signals, ...] = (),
                      entry_setup: str | None = None) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
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
        result = {"schema": 1, "identity": asdict(identity), "network_denied": True}
        if mode.startswith("probe-invalid:"):
            field, encoded = mode.split(":", 2)[1:]
            target = result["identity"] if field.startswith("identity.") else result
            target[field.rsplit(".", 1)[-1]] = json.loads(encoded)
        payload = json.dumps(result).encode()
        frame = io.BytesIO()
        encode(frame, [("verification.json", payload)], identity)
        if mode.startswith("stderr-flood:"):
            padding = 0
            for _ in range(3):
                padding += 787_274 - frame.tell()
                frame = io.BytesIO()
                encode(frame, [("verification.json", payload + b" " * padding)], identity)
            assert frame.tell() == 787_274
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
        (root / "owned-fds").write_text(json.dumps([os.readlink(sys.argv[-1])]))
        (root / "sent").write_text(str(time.monotonic()))
        os.kill(os.getppid(), signal.SIGTERM)
        time.sleep(60)
else:
    sys.exit(2)
""")
        qemu_img.chmod(0o700)
        qemu = root / "qemu-system-x86_64"
        qemu.write_text(f"""#!{sys.executable}
import json, os, pathlib, signal, sys, time
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
        if mode == "startup:cancel":
            sys.exit(37)
    elif mode != "ignore":
        sys.exit(0)
if mode != "slow":
    signal.signal(signal.SIGTERM, term)
fds = ({{1, 2}} if mode.startswith("pair:") else {{1}}) | {{int(arg.split("/proc/self/fd/")[1].split(",")[0])
                   for arg in sys.argv if "/proc/self/fd/" in arg}}
if not mode.startswith("pair:"):
    assert os.readlink("/proc/self/fd/2") == "/dev/null"
(root / "owned-fds").write_text(json.dumps([os.readlink(f"/proc/self/fd/{{fd}}") for fd in fds]))
(root / "pid").write_text(str(os.getpid()))
with (root / "children").open("a") as logged:
    print(os.getpid(), file=logged)
(root / "ready").touch()
if mode in ("priority-failure", "priority-floor"):
    while not (root / "priority-failed").exists():
        time.sleep(0.005)
    os.write(1, (root / "probe.frame").read_bytes())
    sys.exit(0)
if mode.startswith("startup:") and signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0):
    (root / "startup-ready").touch()
if mode.startswith(("stderr-flood:", "probe-invalid:")):
    assert os.readlink("/proc/self/fd/2") == "/dev/null"
    if mode.startswith("stderr-flood:"):
        count = int(mode.split(":")[1]) * 1024**2
        block = b"x" * 65536
        for _ in range(count // len(block)):
            assert os.write(2, block) == len(block)
        (root / "flood-completed").write_text(str(count))
    with (root / "probe.frame").open("rb") as frame:
        while chunk := frame.read(65536):
            remaining = memoryview(chunk)
            while remaining:
                remaining = remaining[os.write(1, remaining):]
    sys.exit(0)
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
                  "artifacts": payload["artifacts"], "slots": [
                      {{"slot": slot, "reserve": "reserve", "removed": ["amdgpu"], "retained": ["nvidia"],
                        "nvidia_references": ["nvidia/nouveau.ko"]}} for slot in ("rootfs_a", "rootfs_b")]}}
        encode(sys.stdout.buffer, [("verification.json", json.dumps(result).encode())],
               Identity(**payload["identity"]))
    sys.exit(0)
if mode in (*{SUCCESS_GUEST_MODES!r}, "audit-mutation") or mode.startswith(("fault:", "receipt-step:")):
    os.write(1, (root / "probe.frame").read_bytes())
    sys.exit(0)
if mode == "slow":
    # Startup has not initialized the guest or installed a TERM handler.
    time.sleep(60)
while True:
    signal.pause()
""")
        qemu.chmod(0o700)
        if blocked or ignored:
            ionice = root / "ionice"
            ionice.write_text(f"""#!{sys.executable}
import pathlib
pathlib.Path({str(root / "status-ionice")!r}).write_text(pathlib.Path("/proc/self/status").read_text())
print("best-effort: prio 7")
""")
            ionice.chmod(0o700)

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
        with subprocess.Popen(
            command,
            env={"PATH": f"{root}:/usr/bin:/bin", "TMPDIR": tmp, "PYTHONDONTWRITEBYTECODE": "1"},
            start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ) as launcher:
            seconds = 27 if mode == "ignore" else 8
            try:
                _, stderr = launcher.communicate(timeout=seconds)
            except subprocess.TimeoutExpired as error:
                assert (root / "sent").exists(), "fixture never delivered cancellation"
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
                                if os.getpgid(pid) == launcher.pid:
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
        if mode in ("priority-failure", "priority-floor"):
            terminal = directory / "exit.json"
            assert terminal.is_file(), stderr
            marker = json.loads(terminal.read_text())
            pid = (root / "pid").read_text()
            assert (root / "priority-failed").exists()
            assert marker["qemu"].split(":")[0] == pid and marker["qemu_reaped"] is True
            assert not pathlib.Path(f"/proc/{pid}").exists()
            # The first live sample settles; later ones verify only.
            assert (root / "priority-calls").read_text().splitlines()[0] == '{"settle": true}'
            if mode == "priority-floor":
                text = stderr.decode() if isinstance(stderr, bytes) else stderr
                assert marker["qemu_priority_refusal"] == {"nice": -4, "policy": "SCHED_OTHER"}, marker
                assert "observed nice -4, SCHED_OTHER" in text, text
            assert launcher.returncode == marker["launcher_exit"] == 1, (stderr, marker)
            assert marker["stop_reason"] == ("PriorityRefusal" if mode == "priority-floor" else "IOPriorityError")
            assert marker["input_descriptor_closed"] and marker["overlay_descriptor_closed"]
            assert not (directory / "transport-validation.json").exists()
            assert not (root / "returns/active.json").exists(), (mode, entry_setup, stderr.decode())
            return
        if mode.startswith(("stderr-flood:", "probe-invalid:")):
            terminal = directory / "exit.json"
            assert terminal.exists(), stderr.decode(errors="replace")
            marker = json.loads(terminal.read_text())
            assert marker["qemu_exit"] == 0 and marker["qemu_reaped"] is True
            if mode.startswith("stderr-flood:"):
                assert launcher.returncode == marker["launcher_exit"] == 0, stderr
                assert (root / "sole-child").exists()
                assert (root / "launches").read_text().splitlines() == [
                    "qemu-img info", "qemu-img create", "qemu-system-x86_64"]
                assert (root / "flood-completed").read_text() == str(int(mode.split(":")[1]) * 1024**2)
                assert not (directory / "diagnostic.partial").exists()
                assert marker["stream_bytes"] == 787_274
                assert marker["identity"] == asdict(identity)
                assert marker["input_descriptor_closed"] and marker["overlay_descriptor_closed"]
                assert not (root / "returns/active.json").exists()
            else:
                assert (directory / "transport-validation.json").is_file(), (mode, stderr, marker)
                assert launcher.returncode == marker["launcher_exit"] == 1, (mode, stderr)
                assert not (directory.parent / "acceptance.json").exists()
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
            assert marker["qemu_exit"] == STARTUP_EXITS[outcome], (entry_setup, outcome, marker)
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
            if outcome in {"resistant", "cancel"}:
                assert marker["stop_reason"] == "cancelled"
                assert (root / "sent").exists() and (root / "term").exists()
            with (root / "fixture.lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        if mode == "unreadable-exit":
            assert json.loads((directory / "exit.json").read_text())["launcher_exit"] == 0
            assert launcher.returncode == 0 and b"fixture final receipt readback" in stderr
            assert json.loads((root / "leaks").read_text()) == []
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
            assert launcher.returncode == (0 if after else 1), (mode, stderr)
            assert marker.exists() == (after or action.startswith("term-")), mode
            if marker.exists():
                assert json.loads(marker.read_text())["launcher_exit"] == launcher.returncode, mode
            executed = (root / "steps").read_text().splitlines()
            if after:
                assert executed == names, mode
            elif not action.startswith("term-"):
                assert executed[index + 1:] == [
                    step.__name__ for step, cleanup in image_lifecycle.RECEIPT_STEPS[index + 1:]
                    if cleanup], mode
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
            committed = boundary == "journal-unlink"
            assert launcher.returncode == (0 if committed else 1), (mode, stderr)
            marker = directory / "exit.json"
            assert marker.exists() == (committed or action == "term" and boundary != "parent-sync"), mode
            if marker.exists():
                row = json.loads(marker.read_text())
                assert row["launcher_exit"] == launcher.returncode
                assert row["stop_reason"] == ("guest exited; transport validated" if committed else "cancelled"), mode
            if committed:
                assert (root / "returns/active.json").exists() == (action == "fail")
            assert not (directory.parent / "acceptance.json").exists(), mode
            assert not list(root.rglob(".receipt-*")), mode
            assert not list(root.glob("job-*")), mode
            if (root / "pid").exists():
                assert not pathlib.Path(f"/proc/{(root / 'pid').read_text()}").exists(), mode
            with (root / "fixture.lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
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
            assert not (root / "status-ionice").exists()
            for child in ("info", "create", "qemu"):
                mask, ignored_bits, caught = signal_status(root / f"status-{child}")
                assert mask == 0, (child, blocked, mask)
                assert ignored_bits & stop_bits == 0, (child, ignored, ignored_bits)
                # CPython installs default_int_handler after exec.
                assert caught & stop_bits == 1 << (signal.SIGINT - 1), (child, caught)
            with (root / "fixture.lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)


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
            cancelled_fixture(f"startup:{outcome}", entry_setup=setup)


def test_startup_verification_failure_refuses_before_spawning() -> None:
    for baseline, state in STARTUP_CHECK_CASES.items():
        cancelled_fixture(f"startup-reject:{baseline}", entry_setup=STARTUP_STATES[state])


def test_echild_cannot_be_reported_as_guest_or_helper_success() -> None:
    popen = subprocess.Popen

    def lose_status_at_spawn(_args, **kwargs):
        signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        return popen([sys.executable, "-c", 'print("CERALIVE_JOB_DONE=0"); raise SystemExit(37)'], **kwargs)

    for operation in (
        lambda: run([sys.executable, "-c", "raise SystemExit(37)"], timeout=2,
                    cancellation=Cancellation(), capture_output=True),
        lambda: run([sys.executable, "-c", "raise SystemExit(37)"], timeout=2,
                    cancellation=Cancellation()),
        lambda: vm.boot(pathlib.Path("/unused"), b"", "check", 2),
    ):
        previous = signal.getsignal(signal.SIGCHLD)
        try:
            with patch.object(subprocess, "Popen", lose_status_at_spawn):
                operation()
        except vm_process.ChildStatusError as error:
            assert "exit status unavailable for owned child PID" in str(error)
            assert error.__cause__.errno == errno.ECHILD
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


def test_each_receipt_step_preserves_commit_and_releases_owned_resources() -> None:
    declared = {name for name, value in vars(image_lifecycle.Receipt).items()
                if not name.startswith("_") and callable(value)}
    scheduled = {step.__name__ for step, _ in image_lifecycle.RECEIPT_STEPS}
    assert scheduled == declared
    for step, _cleanup in image_lifecycle.RECEIPT_STEPS:
        for action in ("exception", "oserror", "systemexit", "interrupt", "term-before", "term-during"):
            cancelled_fixture(f"receipt-step:{step.__name__}:{action}")


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
                        if active_name == target and event == step and not injected:
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
                                patch.object(os, "fsync", sync), patch.object(os, "replace", replace_file):
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
    for step in ("capsule-create", "capsule-copy", "verifier-result", "capsule-unlink", "success", "replace"):
        for action in ((step,) if step in ("success", "replace") else ("fail", "term")):
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
                    if step != point or injected:
                        return
                    injected = True
                    if action == "fail":
                        raise OSError(errno.EIO, f"fixture {point}")
                    os.kill(os.getpid(), signal.SIGTERM)

                def open_file(path, *options, **kwargs):
                    if named(path) == capsule:
                        inject("capsule-create")
                    return real_open(path, *options, **kwargs)

                def addfile(archive, header, file=None):
                    if header.name.startswith("objects/"):
                        inject("capsule-copy")
                    return real_addfile(archive, header, file)

                read_record = image_vm.returned_json
                pack = image_vm.verification_capsule
                written = []

                def pack_capsule(*args):
                    inventory = pack(*args)
                    if action == "replace":
                        written.append((capsule.stat().st_ino, hashlib.sha256(capsule.read_bytes()).hexdigest()))
                        capsule.rename(capsule.with_suffix(".original"))
                        capsule.write_bytes(b"independent fixture")
                        capsule.chmod(0o600)
                    return inventory

                def read_result(path, **kwargs):
                    if named(path) == verification:
                        inject("verifier-result")
                    return read_record(path, **kwargs)

                def unlink(path, *options, **kwargs):
                    if named(path) == capsule:
                        inject("capsule-unlink")
                    return real_unlink(path, *options, **kwargs)

                def execute(_base, directory, request, _cancellation, jobs):
                    payload = request["payload"]
                    artifacts = directory / "artifacts"
                    artifacts.mkdir(parents=True)
                    state = {"identity": payload["identity"], "stop_reason": "guest exited; transport validated"}
                    jobs.append(SimpleNamespace(directory=directory, state=state))
                    image_lifecycle.receipt(directory / "teardown.json", state)
                    if payload["operation"] == "measure":
                        (artifacts / "fixture").write_bytes(b"public artifact")
                    else:
                        assert os.path.samefile(request["capsule"], capsule)
                        if action == "replace":
                            assert [(os.fstat(request["capsule_fd"]).st_ino, payload["identity"]["input_sha256"])] == written
                        verification.write_text(json.dumps({
                            "schema": 1, "verified": True, "build_identity": payload["build_identity"],
                            "artifacts": payload["artifacts"],
                            "slots": [
                                {"slot": slot, "reserve": "reserve", "removed": ["amdgpu"], "retained": ["nvidia"],
                                 "nvidia_references": ["nvidia/nouveau.ko"]} for slot in ("rootfs_a", "rootfs_b")
                            ],
                        }))
                    return artifacts

                real_addfile = tarfile.TarFile.addfile
                try:
                    with patch.multiple(image_vm, require_host_lock=lambda: None, cgroup_admission=lambda: None,
                                        validate_base=lambda *_args: None, disk_admission=lambda *_args: None,
                                        load_policy=lambda *_args: FixturePolicy(), execute=execute), \
                            patch.object(image_resources.ImageCaps, "qemu_limit"), \
                            patch.object(os, "open", open_file), patch.object(tarfile.TarFile, "addfile", addfile), \
                            patch.object(image_vm, "returned_json", read_result), \
                            patch.object(image_vm, "verification_capsule", pack_capsule), \
                            patch.object(pathlib.Path, "unlink", unlink):
                        with fixture_signal_mask():
                            status = image_vm.run_image(args, None, cancellation)
                finally:
                    signal.signal(signal.SIGTERM, previous)
                marker = attempt / "exit.json"
                successful = action == "success"
                assert injected == (action in ("fail", "term")), (step, action)
                if action == "replace":
                    assert written and capsule.read_bytes() == b"independent fixture"
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


def test_image_has_no_nic_shares_registration_or_credential_environment() -> None:
    real_popen = subprocess.Popen
    envelope = io.BytesIO()
    encode(envelope, [("verification.json", b"{}")], IDENTITY)
    observed = []
    artifact_fd = -1
    injected = False
    native_read = os.read

    def child(args, **options):
        nonlocal artifact_fd
        observed.append(args)
        assert args[:6] == ["/usr/bin/setpriv", "--pdeathsig", "KILL", "--", "/bin/sh", "-c"]
        assert args[6] == 'test "$PPID" = "$1" || exit 125; shift; exec "$@"'
        assert args[7:10] == ["runner-child", str(os.getpid()), "qemu-system-x86_64"]
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
        assert options["preexec_fn"] is None and options["stderr"] == subprocess.DEVNULL
        assert options["start_new_session"] is True
        guest = ("import ctypes, os, signal\n"
                 "death = ctypes.c_int()\n"
                 "assert ctypes.CDLL(None).prctl(2, ctypes.byref(death), 0, 0, 0) == 0\n"
                 "assert death.value == signal.SIGKILL\n"
                 "assert os.getsid(0) == os.getpid()\n"
                 "os.write(2, b'x' * (2 * 1024**2))\n"
                 f"os.write(1, {envelope.getvalue()!r})")
        process = real_popen([*args[:9], sys.executable, "-c",
                              guest], **options)
        artifact_fd = process.stdout.fileno()
        return process

    def read(fd, length):
        nonlocal injected
        if fd == artifact_fd and not injected:
            injected = True
            raise OSError(errno.EIO, "fixture live artifact read")
        return native_read(fd, length)

    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        directory = root / "fixture/build"
        directory.mkdir(parents=True)
        capsule = root / "capsule"
        capsule.write_bytes(b"not a credential")
        with tempfile.TemporaryFile(dir=root) as overlay, ImageJob(directory, IDENTITY, capsule, probe=True) as job:
            job.state.update(overlay_directory=str(root), retained_bytes=0)
            job.overlay_created(overlay.fileno())
            with patch.object(vm.subprocess, "Popen", child), patch.object(image_lifecycle, "disk_headroom"), \
                    patch.object(image_lifecycle.os, "read", read), \
                    patch.object(image_lifecycle, "process_priority", return_value=FIXTURE_PRIORITY):
                vm.boot(pathlib.Path(f"/proc/self/fd/{overlay.fileno()}"), b"{}", "image", 5,
                        disk_fd=overlay.fileno(), image_job=job)
            assert job.state["qemu_reaped"] is True
        exit_record = json.loads((directory / "teardown.json").read_text())
        assert exit_record["input_descriptor_closed"] is True
        assert (directory / "stream.partial").read_bytes() == envelope.getvalue()
        assert not (directory / "diagnostic.partial").exists()
    assert len(observed) == 1 and injected


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
                raise FileNotFoundError(errno.ENOENT, "fixture missing control", str(path))
            return snapshot[str(path)]

        with patch.object(pathlib.Path, "read_text", read_text), \
                patch.object(pathlib.Path, "is_file", lambda path: str(path) in snapshot), \
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
                raise FileNotFoundError(errno.ENOENT, "fixture missing control", str(path))
            return snapshot[str(path)]

        with patch.object(pathlib.Path, "read_text", read_text), \
                patch.object(pathlib.Path, "is_file", lambda path: str(path) in snapshot), \
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
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        with leased_fixture(root) as owned:
            fcntl.flock(owned, fcntl.LOCK_EX | fcntl.LOCK_NB)
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


def leased_fixture(store: pathlib.Path):
    build = store / "interrupted/build"
    build.mkdir(parents=True, mode=0o700)
    build.parent.chmod(0o700)
    overlay = build / "overlay.qcow2"
    file = open(overlay, "x+b", opener=lambda name, flags: os.open(name, flags, 0o600))
    info = os.fstat(file.fileno())
    active = store / "active.json"
    active.write_text(json.dumps({"attempt": "interrupted", "overlay_lease": 1, "overlay_job": "build",
                                  "overlay_inode": [info.st_dev, info.st_ino]}))
    active.chmod(0o600)
    return file

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
                    os.close(validate_base(base, digest))
                except image_resources.AdmissionError:
                    assert changes
                else:
                    assert not changes


def test_image_base_never_admits_unchecked_or_replaced_path() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        base = root / "base"
        target = root / "target"
        target.write_bytes(b"fixture")
        target.chmod(0o444)
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        base.symlink_to(target)
        real_lstat = pathlib.Path.lstat
        for role, error in product(("base", "capsule"), (errno.EIO, errno.EINTR, errno.EAGAIN, errno.EPERM)):
            seen = []

            def lookup(path):
                if path == base:
                    seen.append(path)
                    if len(seen) == 1:
                        raise OSError(error, "fixture lstat failure")
                return real_lstat(path)

            info = subprocess.CompletedProcess([], 0, b'{"format":"qcow2","virtual-size":137438953472}')
            with patch.object(pathlib.Path, "lstat", lookup), patch.object(image_vm, "run", return_value=info) as tool:
                try:
                    if role == "base":
                        os.close(validate_base(base, digest))
                    else:
                        os.close(image_vm.checked_digest(base, digest, Cancellation()))
                except (OSError, StreamError, image_resources.AdmissionError):
                    pass
                else:
                    raise AssertionError(("input link admitted after metadata fault", role, error))
            tool.assert_not_called()
            assert len(seen) == (1 if error == errno.EPERM else 2)


def test_host_inputs_restart_transient_metadata_and_refuse_replaced_inodes() -> None:
    from image_policy import load_policy
    from image_stream import checked_open

    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        policy = {"schema": 1, "root_der_sha256": "c" * 64, "repositories": {
            name: {"origin": origin, "keyring": "a" * 64, "fingerprints": ["B" * 40], "suite": "stable",
                   "component": "main", "arch": "arm64", "index_path": "Packages", "max_age_seconds": 3600}
            for name, origin in (("firstparty", "https://apt.ceralive.tv"), ("bsp", "https://apt.armbian.com"),
                                 ("debian-source", "https://deb.debian.org/debian"))},
            "kernel_metadata": dict.fromkeys(("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS"),
                                             "d" * 64),
            "builder_images": [{"object": "e" * 64, "tag": "fixture:v1",
                                "image_id": "sha256:" + "f" * 64, "arch": "arm64"}]}
        data = json.dumps(policy).encode()
        digest = hashlib.sha256(data).hexdigest()
        info = subprocess.CompletedProcess([], 0, b'{"format":"qcow2","virtual-size":137438953472}')
        lstat, native_open, fstat = pathlib.Path.lstat, os.open, os.fstat
        transient = (errno.EIO, errno.EINTR, errno.EAGAIN)
        for role, site, code in product(("base", "capsule", "policy", "store", "receipt"),
                                        ("lstat", "open", "fstat"), (*transient, errno.EPERM, errno.EACCES,
                                        errno.ENOENT, errno.ESTALE, errno.EBUSY, errno.ELOOP, errno.ENOTDIR, 0)):
            path = root / "input"
            if role == "store":
                path.mkdir(mode=0o700)
            else:
                path.write_bytes(data)
                path.chmod(0o400 if role == "base" else 0o600)
            identity = lstat(path)
            hits = []
            stages = []

            def observe(stage):
                stages.append(stage)
                if stage == site and not hits:
                    hits.append(stage)
                    if code:
                        raise OSError(code, f"fixture {stage}", path)
                    # The replacement has identical content, ownership and mode.
                    path.rename(root / "old")
                    if role == "store":
                        path.mkdir(mode=0o700)
                    else:
                        path.write_bytes(data)
                        path.chmod(stat.S_IMODE(identity.st_mode))

            def lookup(candidate):
                result = lstat(candidate)
                if candidate == path:
                    observe("lstat")
                return result

            def open_input(candidate, flags, *args, **kwargs):
                if candidate == path:
                    assert flags & os.O_NOFOLLOW
                    observe("open")
                return native_open(candidate, flags, *args, **kwargs)

            def stat_input(fd):
                result = fstat(fd)
                if os.path.samestat(identity, result):
                    observe("fstat")
                return result

            def admit():
                match role:
                    case "base":
                        os.close(validate_base(path, digest))
                    case "capsule":
                        os.close(image_vm.checked_digest(path, digest, Cancellation()))
                    case "policy":
                        assert load_policy(path).root_der_sha256 == "c" * 64
                    case "store":
                        os.close(checked_open(path, directory=True, private=True))
                    case "receipt":
                        assert image_vm.returned_json(path, private=True) == policy

            def backing_tool(args, **kwargs):
                base_fd, = kwargs["pass_fds"]
                assert args[-1] == f"/proc/self/fd/{base_fd}"
                assert os.path.samestat(identity, fstat(base_fd))
                return info

            pinned = not code and site == "fstat"
            with patch.object(pathlib.Path, "lstat", lookup), patch.object(os, "open", open_input), \
                    patch.object(os, "fstat", stat_input), patch.object(image_vm, "run", side_effect=backing_tool) as tool:
                try:
                    admit()
                except (OSError, StreamError, image_resources.AdmissionError):
                    assert code not in transient and not pinned, (role, site, code, stages)
                    tool.assert_not_called()
                else:
                    assert code in transient or pinned, (role, site, code, stages)
                    if not pinned:
                        assert stages.count("lstat") >= 2, (role, site, code, stages)
                assert hits == [site]
            for target in (path, root / "old"):
                if target.exists():
                    target.rmdir() if role == "store" else target.unlink()


def test_overlay_handoff_after_pid_listing_cannot_retire_journal() -> None:
    forward = """
import os, pathlib, subprocess, sys
fd = int(sys.argv[1])
print('ready', flush=True)
sys.stdin.readline()
code = 'import os,sys; fd=int(sys.argv[1]); s=os.fstat(fd); print(f\"{s.st_dev}:{s.st_ino}\",flush=True); sys.stdin.read()'
with subprocess.Popen([sys.executable, '-c', code, str(fd)], stdin=subprocess.PIPE,
                      stdout=subprocess.PIPE, pass_fds=(fd,)) as child:
    os.close(fd)
    print(child.pid, flush=True)
    print(child.stdout.readline().decode().strip(), flush=True)
    sys.stdin.readline()
    child.stdin.close()
    assert child.wait(timeout=2) == 0
"""
    with tempfile.TemporaryDirectory() as temporary:
        store = pathlib.Path(temporary)
        build = store / "interrupted/build"
        build.mkdir(parents=True, mode=0o700)
        build.parent.chmod(0o700)
        overlay = build / "overlay.qcow2"
        with open(overlay, "x+b", opener=lambda name, flags: os.open(name, flags, 0o600)) as locked:
            fcntl.flock(locked, fcntl.LOCK_EX | fcntl.LOCK_NB)
            info = os.fstat(locked.fileno())
            parent = subprocess.Popen([sys.executable, "-c", forward, str(locked.fileno())],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, pass_fds=(locked.fileno(),))
        with parent:
            try:
                assert select.select([parent.stdout], [], [], 2)[0] and parent.stdout.readline() == b"ready\n"
                active = store / "active.json"
                row = {"attempt": "interrupted", "overlay_inode": [info.st_dev, info.st_ino],
                       "overlay_lease": 1, "overlay_job": "build"}
                active.write_text(json.dumps(row))
                active.chmod(0o600)
                record = store / "interrupted.reconciled.json"
                listing = fixture_process_inventory({str(parent.pid)})
                pids = []

                def handoff():
                    if not pids:
                        parent.stdin.write(b"handoff\n")
                        parent.stdin.flush()
                        assert select.select([parent.stdout], [], [], 2)[0]
                        pids.append(int(parent.stdout.readline()))
                        assert parent.stdout.readline().decode().strip() == f"{info.st_dev}:{info.st_ino}"

                def scan(path, **kwargs):
                    rows = listing(path, **kwargs)
                    if path == pathlib.Path("/proc"):
                        handoff()
                    return rows

                flock = fcntl.flock

                def lock(fd, operation):
                    handoff()
                    return flock(fd, operation)

                with patch.object(image_lifecycle, "list_directory", scan), patch.object(fcntl, "flock", lock):
                    try:
                        reconcile(store)
                    except image_resources.AdmissionError:
                        pass
                    else:
                        raise AssertionError("reconciliation retired a journal during live descriptor handoff")
                assert pids and active.is_file() and not record.exists() and overlay.is_file()
                parent.stdin.close()
                assert parent.wait(timeout=2) == 0
                reconcile(store)
                assert not active.exists() and not overlay.exists()
                assert json.loads(record.read_text())["overlay_descriptors_closed"] is True
            finally:
                if parent.poll() is None:
                    if parent.stdin and not parent.stdin.closed:
                        parent.stdin.close()
                    parent.wait(timeout=3)


def fixture_process_inventory(pids: set[str]):
    """Limit fixtures to their own real processes without masking their descriptor reads."""
    from image_stream import list_directory

    def inventory(path, **kwargs):
        entries = list_directory(path, **kwargs)
        return [entry for entry in entries if entry in pids] if path == pathlib.Path("/proc") else entries

    return inventory


def test_reconciliation_checks_descriptors_of_a_second_real_process() -> None:
    code = """
import os, sys
fd = int(sys.argv[1])
def inode():
    info = os.fstat(fd)
    print(f'{info.st_dev}:{info.st_ino}', flush=True)
inode()
for request in sys.stdin:
    inode()
"""
    with tempfile.TemporaryDirectory() as temporary:
        store = pathlib.Path(temporary)
        with leased_fixture(store) as overlay:
            inode = os.fstat(overlay.fileno())
            fcntl.flock(overlay, fcntl.LOCK_EX | fcntl.LOCK_NB)
            number = str(overlay.fileno())
            child = subprocess.Popen([sys.executable, "-c", code, number],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     pass_fds=(overlay.fileno(),))
        with child:
            try:
                expected = f"{inode.st_dev}:{inode.st_ino}\n".encode()
                assert select.select([child.stdout], [], [], 2)[0] and child.stdout.readline() == expected
                journal = store / "active.json"
                row = json.loads(journal.read_text()) | {"launcher": f"{child.pid}:0"}
                journal.write_text(json.dumps(row))
                record = store / "interrupted.reconciled.json"
                proc = pathlib.Path("/proc")
                child_status = proc / str(child.pid) / "stat"
                launcher_status = proc / str(os.getpid()) / "stat"
                fd_root = child_status.with_name("fd")
                descriptor = fd_root / number
                inventory = fixture_process_inventory({str(child.pid)})
                stat_path, lstat_path, read_text = pathlib.Path.stat, pathlib.Path.lstat, pathlib.Path.read_text
                native_fdopen, journal_inode = os.fdopen, journal.lstat().st_ino
                journal_read = store / "journal-read"
                cases = [(descriptor, errno.EACCES, 1), (descriptor, errno.ENOENT, 1), (None, None, 0)]
                cases += list(product((store, journal, journal_read, proc, launcher_status, child_status, fd_root, descriptor),
                                      (errno.EACCES, errno.EPERM, errno.EIO, errno.EBUSY, errno.ESRCH,
                                       errno.ENOENT, errno.EINTR), (1, 3)))
                for site, error, count in cases:
                    attempts = []
                    faults = []

                    def observe(path):
                        if path == site and len(faults) < count:
                            faults.append(path)
                            raise OSError(error, "fixture incomplete process observation", path)

                    def scan(path, **kwargs):
                        if named(path) == store:
                            attempts.append(path)
                        observe(path)
                        return inventory(path, **kwargs)

                    def descriptor_stat(path, **kwargs):
                        if path == descriptor:
                            observe(path)
                        return stat_path(path, **kwargs)

                    def journal_stat(path):
                        if path == journal:
                            observe(path)
                        return lstat_path(path)

                    def process_read(path):
                        if path in (child_status, launcher_status):
                            observe(path)
                        return read_text(path)

                    def open_read(fd, flags, *args, **kwargs):
                        stream = native_fdopen(fd, flags, *args, **kwargs)
                        if os.fstat(fd).st_ino == journal_inode:
                            read = stream.read

                            def injected_read(size):
                                observe(journal_read)
                                return read(size)

                            stream.read = injected_read
                        return stream

                    with patch.object(image_lifecycle, "list_directory", scan, create=True), \
                            patch.object(pathlib.Path, "stat", descriptor_stat), \
                            patch.object(pathlib.Path, "lstat", journal_stat), \
                            patch.object(os, "fdopen", open_read), \
                            patch.object(pathlib.Path, "read_text", process_read):
                        try:
                            reconcile(store)
                        except image_resources.AdmissionError as exc:
                            assert "still held" in str(exc) or "cannot establish previous overlay closure" in str(exc)
                        else:
                            raise AssertionError(("a second process still held the owned overlay", site, error))
                    retries = 3 if error in (errno.EIO, errno.EINTR, errno.EAGAIN) else 1
                    assert len(attempts) == (min(count + 1, retries) if site == store else 1)
                    if site not in (store, journal, journal_read):
                        assert not faults, "reconciliation used the superseded proc scan"
                    else:
                        expected_reads = min(count, retries)
                        assert len(faults) == expected_reads
                    assert json.loads(journal.read_text()) == row and not record.exists()
                    child.stdin.write(b"check\n")
                    child.stdin.flush()
                    assert select.select([child.stdout], [], [], 2)[0] and child.stdout.readline() == expected
                with patch.object(image_lifecycle, "list_directory", inventory, create=True), \
                        patch.object(pathlib.Path, "stat", side_effect=AssertionError("journal existence must use inventory")):
                    journal.write_text(json.dumps(row | {"launcher": image_lifecycle.process_identity(child.pid)}))
                    try:
                        reconcile(store)
                    except image_resources.AdmissionError as exc:
                        assert "previous image overlay is still held" in str(exc)
                    else:
                        raise AssertionError("live recorded launcher was missed")
                assert journal.exists() and not record.exists()
                child.stdin.close()
                assert child.wait(timeout=2) == 0
                with patch.object(image_lifecycle, "list_directory", inventory, create=True):
                    reconcile(store)
                assert not journal.exists()
                assert json.loads(record.read_text())["overlay_descriptors_closed"] is True
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=2)


def test_startup_inventory_keeps_a_real_inherited_fd_despite_a_failed_presence_probe() -> None:
    with tempfile.TemporaryFile() as owned:
        target = f"/proc/self/fd/{owned.fileno()}"
        lexists = os.path.lexists
        with patch.object(os.path, "lexists", side_effect=lambda path: path != target and lexists(path)):
            assert owned.fileno() in vm_startup.fd_table()


def test_reconciliation_restarts_after_a_real_process_disappears() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        store = pathlib.Path(temporary)
        path = store / "active.json"
        with leased_fixture(store) as overlay:
            fcntl.flock(overlay, fcntl.LOCK_EX | fcntl.LOCK_NB)
            child = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"],
                                     stdin=subprocess.PIPE, pass_fds=(overlay.fileno(),))
        with child:
            flock = fcntl.flock

            def lock(fd, flags):
                child.stdin.close()
                assert child.wait(timeout=2) == 0
                return flock(fd, flags)

            with patch.object(fcntl, "flock", lock):
                reconcile(store)
        assert not path.exists()
        assert json.loads((store / "interrupted.reconciled.json").read_text())["overlay_descriptors_closed"] is True


def test_overlay_lease_faults_preserve_active_ownership_until_proven() -> None:
    from image_stream import list_directory

    # The recovery decision no longer reads /proc PID or descriptor inventories.
    cases = ("list", "journal-lstat", "journal-open", "journal-fstat",
             "attempt-lstat", "job-lstat", "overlay-lstat", "overlay-open",
             "overlay-fstat", "lease", "publish", "overlay-unlink", "active-unlink")
    transient = (errno.EIO, errno.EINTR, errno.EAGAIN)
    failures = (*transient, errno.ENOENT, errno.EACCES, errno.EPERM, errno.EBUSY, errno.ESTALE, errno.ENOSPC)
    lstat, native_open, fstat, flock, publish, unlink = (
        pathlib.Path.lstat, os.open, os.fstat, fcntl.flock, image_lifecycle.receipt, pathlib.Path.unlink)
    for site, code in product(cases, failures):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as hooks:
            store = pathlib.Path(temporary)
            with leased_fixture(store) as created:
                disk_inode = os.fstat(created.fileno()).st_ino
            active = store / "active.json"
            journal_inode = active.lstat().st_ino
            record = store / "interrupted.reconciled.json"
            hits = []

            def fault(step, path):
                if site == step and not hits:
                    hits.append(step)
                    raise OSError(code, "fixture lease observation", path)

            def scan(path, **kwargs):
                fault("list", path)
                return list_directory(path, **kwargs)

            def lookup(path):
                if what := {"active.json": "journal", "interrupted": "attempt", "build": "job",
                            "overlay.qcow2": "overlay"}.get(path.name):
                    fault(what + "-lstat", path)
                return lstat(path)

            def open_input(path, options, *args, **kwargs):
                if what := {"active.json": "journal", "overlay.qcow2": "overlay"}.get(pathlib.Path(path).name):
                    fault(what + "-open", path)
                return native_open(path, options, *args, **kwargs)

            def stat_input(fd):
                result = fstat(fd)
                if what := {journal_inode: "journal", disk_inode: "overlay"}.get(result.st_ino):
                    fault(what + "-fstat", fd)
                return result

            def lease(fd, flags):
                fault("lease", fd)
                return flock(fd, flags)

            def write_record(path, row):
                fault("publish", path)
                return publish(path, row)

            def remove(path, **kwargs):
                if what := {"active.json": "active", "overlay.qcow2": "overlay"}.get(path.name):
                    fault(what + "-unlink", path)
                return unlink(path, **kwargs)

            for owner, name, replacement in (
                (image_lifecycle, "list_directory", scan), (pathlib.Path, "lstat", lookup),
                (os, "open", open_input), (os, "fstat", stat_input), (fcntl, "flock", lease),
                (image_lifecycle, "receipt", write_record), (pathlib.Path, "unlink", remove),
            ):
                hooks.enter_context(patch.object(owner, name, replacement))
            retries = site not in ("publish", "overlay-unlink", "active-unlink")
            expected = (retries and code in transient and not (site == "lease" and code == errno.EAGAIN))
            try:
                reconcile(store)
            except (image_resources.AdmissionError, OSError, StreamError):
                assert not expected, (site, code)
            else:
                assert expected, (site, code)
            assert hits == [site], (site, code)
            assert active.exists() != expected, (site, code)
            assert record.exists() == (expected or site in ("overlay-unlink", "active-unlink")), (site, code)


def test_overlay_recovery_requires_exact_contention_errno() -> None:
    flags = fcntl.LOCK_EX | fcntl.LOCK_NB
    native_lock = fcntl.flock
    contention = (errno.EAGAIN, errno.EWOULDBLOCK)
    errors = (*contention, errno.EINPROGRESS, errno.EALREADY, errno.EINTR, errno.EACCES,
              errno.EBADF, errno.EIO, errno.ENOLCK)
    for phase, code in product(("acquire", "probe"), errors):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as held:
            store = pathlib.Path(temporary)
            with leased_fixture(store):
                pass
            overlay = store / "interrupted/build/overlay.qcow2"
            journal = store / "active.json"
            recovery = store / "interrupted.reconciled.json"
            if phase == "acquire":
                holder = held.enter_context(overlay.open("r+b"))
                native_lock(holder, flags)
            original = journal.read_bytes()
            attempts = 0

            def observe(fd, operations):
                nonlocal attempts
                try:
                    native_lock(fd, operations)
                except OSError as error:
                    # The independent description is really contending in both cases.
                    assert error.errno in contention
                    attempts += 1
                    raise OSError(code, "fixture lock errno") from error

            retires = phase == "probe" and code in contention
            with patch.object(fcntl, "flock", observe):
                try:
                    reconcile(store)
                except image_resources.AdmissionError as error:
                    assert not retires, (phase, code, error)
                    assert str(error).startswith("previous image overlay is still held:") == (
                        phase == "acquire" and code in contention), (phase, code, error)
                    assert error.__cause__.errno == code, (phase, code, error)
                else:
                    assert retires, (phase, code, "retired without proven contention")
            assert attempts == (3 if code in (errno.EINTR, errno.EIO) else 1), (phase, code, attempts)
            if retires:
                assert not journal.exists() and not overlay.exists()
                assert json.loads(recovery.read_text())["overlay_descriptors_closed"] is True
            else:
                assert journal.read_bytes() == original and overlay.is_file() and not recovery.exists()


def test_legacy_overlay_never_uses_a_process_scan_to_certify_closure() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        store = pathlib.Path(temporary)
        journal = store / "active.json"
        journal.write_text(json.dumps({"attempt": "interrupted", "overlay_inode": [0, 0]}))
        journal.chmod(0o600)
        try:
            reconcile(store)
        except image_resources.AdmissionError as error:
            assert "manual recovery" in str(error)
        else:
            raise AssertionError("legacy anonymous overlay retired without proof")
        assert journal.is_file() and not (store / "interrupted.reconciled.json").exists()


def test_overlay_or_journal_replacement_during_lease_keeps_journal() -> None:
    for name in ("overlay", "journal"):
        with tempfile.TemporaryDirectory() as temporary:
            store = pathlib.Path(temporary)
            with leased_fixture(store):
                pass
            active = store / "active.json"
            overlay = store / "interrupted/build/overlay.qcow2"
            selected = overlay if name == "overlay" else active
            payload = selected.read_bytes()
            holder = selected.with_suffix(".original")
            native_lock = fcntl.flock

            def replace_then_lock(fd, flags):
                # One replacement; the contention probe also calls flock.
                if not holder.exists():
                    selected.rename(holder)
                    selected.write_bytes(payload)
                    selected.chmod(0o600)
                return native_lock(fd, flags)

            with patch.object(fcntl, "flock", replace_then_lock):
                try:
                    reconcile(store)
                except image_resources.AdmissionError:
                    pass
                else:
                    raise AssertionError(f"reconciliation accepted a replaced {name}")
            assert active.exists() and overlay.exists() and holder.exists()
            assert not (store / "interrupted.reconciled.json").exists()


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
        for receipt_path in (candidate, candidate.parent / "exit.json"):
            receipt_path.chmod(0o600)
        assert retained_outputs(store, IDENTITY, ("c" * 64, "d" * 64)) == allocated
        for name in ("active.json", "previous.reconciled.json"):
            interrupted = store / name
            interrupted.write_text(json.dumps({"attempt": "previous"}))
            interrupted.chmod(0o600)
            assert image_vm.completed_acceptance(candidate) is None
            assert retained_outputs(store, IDENTITY, ("c" * 64, "d" * 64)) == 0
            interrupted.unlink()


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
        for receipt_path in (prior / "exit.json", prior / "acceptance.json"):
            receipt_path.chmod(0o600)
        listdir = os.listdir

        for error in (errno.EIO, errno.EINTR, errno.EAGAIN, errno.EPERM, errno.ENOENT):
            for failures in (1, 3):
                scans = 0
                injected = 0
                diagnostics = []

                def scan(path):
                    nonlocal scans, injected
                    if named(path) == store:
                        scans += 1
                        return ["unfinished", "previous"]
                    if named(path) == store / "unfinished" and injected < failures:
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


def probe_fixture_args(root):
    base = root / "base"
    capsule = root / "capsule"
    base.write_bytes(b"fixture base")
    base.chmod(0o444)
    capsule.write_bytes(b"fixture capsule")
    return SimpleNamespace(base=base, input_capsule=capsule,
                           input_sha256=hashlib.sha256(capsule.read_bytes()).hexdigest(),
                           base_sha256=hashlib.sha256(base.read_bytes()).hexdigest(),
                           trust_policy=root / "policy", output_dir=root / "store",
                           attempt=IDENTITY.attempt, board=IDENTITY.board, source_commit=IDENTITY.commit,
                           source_epoch=IDENTITY.epoch, source_bundle=None, check_script=None,
                           group_id=None, image_mode="probe")


def test_fresh_store_requires_policy_before_backing_tool_with_one_retry_budget() -> None:
    for code, attempts in ((errno.EIO, 3), (errno.EINTR, 3), (errno.EAGAIN, 3), (errno.EPERM, 1)):
        with tempfile.TemporaryDirectory() as temporary:
            args = probe_fixture_args(pathlib.Path(temporary))
            calls = []
            native_lstat = pathlib.Path.lstat

            def lstat(path):
                if path == args.trust_policy:
                    calls.append("policy lstat")
                    raise OSError(code, "fixture policy observation")
                return native_lstat(path)

            def backing(args, **kwargs):
                calls.append("qemu-img")
                return subprocess.CompletedProcess(args, 0, b'{"format":"qcow2","virtual-size":137438953472}')

            with patch.object(pathlib.Path, "lstat", lstat), patch.multiple(
                    image_vm, require_host_lock=lambda: None, cgroup_admission=lambda: None,
                    run=backing, disk_admission=lambda *_: None), \
                    patch.object(image_vm, "execute") as execute, patch.object(image_vm, "report_error"):
                assert image_vm.run_image(args, None, Cancellation()) == 1
            execute.assert_not_called()
            assert calls == ["policy lstat"] * attempts, calls
            assert not args.output_dir.exists()


def test_attempt_stays_in_admitted_directory_after_its_name_changes() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        args = probe_fixture_args(root)
        args.output_dir.mkdir(mode=0o700)
        admitted = root / "admitted"
        used = []
        real_mkdir = os.mkdir

        def mkdir(path, mode=0o777, *, dir_fd=None):
            if pathlib.Path(path).name == IDENTITY.attempt:
                args.output_dir.rename(admitted)
                real_mkdir(args.output_dir, 0o755)
            return real_mkdir(path, mode, dir_fd=dir_fd)

        def execute(_base, directory, request, _cancel, jobs):
            used.append(directory.parents[1].stat().st_ino)
            artifacts = directory / "artifacts"
            artifacts.mkdir(parents=True)
            identity = request["payload"]["identity"]
            (artifacts / "verification.json").write_text(json.dumps({
                "schema": 1, "identity": identity, "network_denied": True}))
            jobs.append(SimpleNamespace(directory=directory, state={"identity": identity,
                                         "stop_reason": "guest exited; transport validated"}))
            return artifacts

        with patch.multiple(image_vm, require_host_lock=lambda: None, cgroup_admission=lambda: None,
                            load_policy=lambda *_: FixturePolicy(), validate_base=lambda *_: None,
                            disk_admission=lambda *_: None, execute=execute), \
                patch.object(image_resources.ImageCaps, "qemu_limit"), patch.object(os, "mkdir", mkdir):
            with fixture_signal_mask():
                assert image_vm.run_image(args, None, Cancellation()) == 0
        assert used == [admitted.stat().st_ino]
        assert (admitted / IDENTITY.attempt / "build/exit.json").is_file()
        assert list(args.output_dir.iterdir()) == []


def test_reconcile_refuses_a_filesystem_that_ignores_lease_contention() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        store = pathlib.Path(temporary)
        with leased_fixture(store):
            pass
        # A successful return from flock is insufficient on this backend.
        with patch.object(fcntl, "flock", return_value=None):
            try:
                reconcile(store)
            except image_resources.AdmissionError as error:
                assert "does not enforce overlay flock contention" in str(error)
            else:
                raise AssertionError("recovery relied on a no-op flock")
        assert (store / "active.json").is_file()
        assert (store / "interrupted/build/overlay.qcow2").is_file()
        assert not (store / "interrupted.reconciled.json").exists()


def test_late_disk_error_restarts_store_admission_before_execution() -> None:
    for error, failures in product((errno.EINTR, errno.EAGAIN, errno.EIO, errno.EPERM), (1, 3)):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            store = root / "store"
            store.mkdir(mode=0o700)
            base, capsule = root / "base", root / "capsule"
            base.touch()
            capsule.write_bytes(b"fixture capsule")
            args = SimpleNamespace(base=base, input_capsule=capsule,
                                   input_sha256=hashlib.sha256(capsule.read_bytes()).hexdigest(),
                                   base_sha256="a" * 64, trust_policy=root / "trust", output_dir=store,
                                   attempt=IDENTITY.attempt, board=IDENTITY.board, source_commit=IDENTITY.commit,
                                   source_epoch=IDENTITY.epoch, source_bundle=None, check_script=None,
                                   group_id=None, image_mode="probe")
            steps = []
            inventory = image_vm.list_directory

            def policy(_path):
                steps.append("policy")
                return FixturePolicy()

            def scan(path):
                if named(path) == store:
                    steps.append("store")
                return inventory(path)

            def disk(*_args):
                steps.append("disk")
                if steps.count("disk") <= failures:
                    raise OSError(error, "fixture late disk observation")

            def execute(_base, directory, request, *_args):
                steps.append("execute")
                artifacts = directory / "artifacts"
                artifacts.mkdir(parents=True)
                (artifacts / "verification.json").write_text(json.dumps({
                    "schema": 1, "identity": request["payload"]["identity"], "network_denied": True}))
                return artifacts

            success = failures == 1 and error != errno.EPERM
            with patch.multiple(image_vm, require_host_lock=lambda: None, cgroup_admission=lambda: None,
                                validate_base=lambda *_: None, load_policy=policy, list_directory=scan,
                                disk_admission=disk, execute=execute), \
                    patch.object(image_resources.ImageCaps, "qemu_limit"):
                try:
                    image_vm.measure_image(args, None, Cancellation(), [])
                except image_resources.AdmissionError as exc:
                    assert not success and exc.__cause__.errno == error, (error, failures, exc)
                else:
                    assert success, (error, failures)
            tries = 1 if error == errno.EPERM else min(failures + 1, 3)
            assert steps == ["policy", "store", "disk"] * tries + (["execute"] if success else []), steps
            assert (store / IDENTITY.attempt).exists() == success


def test_guest_poweroff_does_not_depend_on_image_completion_marker() -> None:
    body = json.dumps({"schema": 1, "identity": asdict(IDENTITY), "network_denied": True}).encode()
    frame = io.BytesIO()
    encode(frame, [("verification.json", body)], IDENTITY)
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "image").mkdir()
        (root / "image/raw").touch()
        wire, returned = root / "wire", root / "returned"
        wire.write_bytes(frame.getvalue())
        helper = root / "image_guest.py"
        helper.write_text(f"import pathlib, sys\npathlib.Path({str(returned)!r}).write_bytes("
                          f"pathlib.Path({str(wire)!r}).read_bytes())\n"
                          "print('late stdout', flush=True)\nprint('late stderr', file=sys.stderr, flush=True)\n"
                          "raise SystemExit(int(sys.argv[1]))\n")
        observed = root / "poweroff"
        for tool, command in (
            ("modprobe", "exit 0"),
            ("systemctl", f'[[ $* = poweroff ]] && cmp -s "{wire}" "{returned}" && : >"{observed}"'),
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
            with ExitStack() as pipes:
                writers = []
                for _ in range(2):
                    reader, writer = os.pipe()
                    pipes.callback(os.close, reader)
                    pipes.callback(os.close, writer)
                    capacity = fcntl.fcntl(writer, fcntl.F_GETPIPE_SZ)
                    assert os.write(writer, b"x" * capacity) == capacity
                    writers.append(writer)
                termios.tcflow(slave, termios.TCOOFF)
                for status, sink in product((0, 1, 37), (str(root / "serial"), os.ttyname(slave), "/dev/full")):
                    observed.unlink(missing_ok=True)
                    returned.unlink(missing_ok=True)
                    with subprocess.Popen(
                        ["/bin/bash", "-c", wrapper.replace("/dev/ttyS0", sink), "fixture", str(status)],
                        env={"PATH": f"{root}:/usr/bin:/bin"}, start_new_session=True,
                        stdout=writers[0], stderr=writers[1],
                    ) as guest:
                        try:
                            guest.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            os.killpg(guest.pid, signal.SIGKILL)
                            guest.wait()
                            failures.append((sink, status, "shutdown exceeded two seconds"))
                        else:
                            if not observed.is_file() or guest.returncode != status:
                                failures.append((sink, status, observed.is_file(), guest.returncode))
                    assert returned.read_bytes() == frame.getvalue()
                    if sink == str(root / "serial"):
                        assert pathlib.Path(sink).read_bytes() == f"\nCERALIVE_JOB_DONE={status}\n".encode()
        finally:
            os.close(slave)
            os.close(master)
        assert not failures, failures


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


QEMU_STANDIN = '''import json, os, sys, threading
early = threading.Thread(target=threading.Event().wait, daemon=True)
early.start()
if sys.argv[1:] and sys.argv[1].startswith("exit:"):
    sys.exit(int(sys.argv[1][5:]))
if sys.argv[1:] == ["hold"]:
    import signal
    signal.pause()
print("ready", flush=True)
line = sys.stdin.readline()
if line.startswith("exit"):
    sys.exit(int(line.split()[1]))
if line.startswith("threads"):
    report = {"leader": os.getpriority(os.PRIO_PROCESS, 0), "early": os.getpriority(os.PRIO_PROCESS, early.native_id)}
    late = threading.Thread(target=lambda: report.update(late=os.getpriority(os.PRIO_PROCESS, 0)))
    late.start()
    late.join()
    print(json.dumps(report), flush=True)
sys.stdin.read()
'''


def qemu_standin(directory: pathlib.Path) -> pathlib.Path:
    """A script named like QEMU: exec through the wrapper gives it QEMU's kernel comm."""
    script = directory / "qemu-system-x86_64"
    script.write_text(f"#!{sys.executable}\n" + QEMU_STANDIN)
    script.chmod(0o700)
    return script


def settle_sample(initial, *, settle=True, daemon=None, undo=0, race=None, set_error=None,
                  policy=os.SCHED_OTHER, comm=None, cost=None, guest=None, interval=None, exit_code=None):
    """Sample a stand-in through the production wrapper with a modelled unprivileged nice.

    Time moves only by the settle's pauses and by each verification sample's cost.
    """
    real_get, real_set, real_policy = os.getpriority, os.setpriority, os.sched_getscheduler
    read_text = pathlib.Path.read_text
    with tempfile.TemporaryDirectory() as temporary, subprocess.Popen(
            vm.parent_bound([str(qemu_standin(pathlib.Path(temporary)))], os.getpid()),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
        assert child.stdout.readline() == b"ready\n"
        assert pathlib.Path(f"/proc/{child.pid}/comm").read_text() == "qemu-system-x86\n"
        now = [0.0]
        costs = list(cost or ())
        state = {"nice": initial, "reads": 0, "writes": [], "write_times": [], "pauses": [], "undo": undo}

        def exited():
            return os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None

        def get(which, who):
            if who != child.pid:
                return real_get(which, who)
            state["reads"] += 1
            if exit_code is not None and state["reads"] == 1:
                child.stdin.write(f"exit {exit_code}\n".encode())
                child.stdin.flush()
                os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOWAIT)
            nice = state["nice"]
            if daemon is not None and state["reads"] == daemon[0]:
                state["nice"] = daemon[1]
            return nice

        def put(which, who, value):
            state["writes"].append((who, value))
            state["write_times"].append(now[0])
            if who != child.pid:
                return real_set(which, who, value)
            if race is not None:
                state["nice"] = race  # A host renice lands between the launcher's read and write.
            if set_error is not None or value < state["nice"]:
                code = set_error or errno.EACCES
                raise OSError(code, os.strerror(code))
            state["nice"] = initial if state["undo"] else value
            state["undo"] = max(0, state["undo"] - 1)

        def scheduler(who):
            if who != child.pid:
                return real_policy(who)
            if isinstance(policy, BaseException):
                raise policy
            return policy

        names = iter(comm or ())

        def proc_text(path, *args, **kwargs):
            if comm is not None and path == pathlib.Path(f"/proc/{child.pid}/comm"):
                value = next(names, comm[-1])
                if isinstance(value, BaseException):
                    raise value
                return value
            return read_text(path, *args, **kwargs)

        def pause(seconds):
            state["pauses"].append(round(seconds, 9))
            now[0] += seconds

        verify = image_resources.process_priority

        def timed(pid, cancellation, **options):
            assert not options
            now[0] += costs.pop(0) if costs else 0.0
            return verify(pid, cancellation)

        options = {"settle": image_resources.Settle(exited, guest_deadline=guest, clock=lambda: now[0], pause=pause)
                   } if settle else {}
        try:
            with ExitStack() as hooks:
                for owner, name, value in ((os, "getpriority", get), (os, "setpriority", put),
                                           (os, "sched_getscheduler", scheduler), (pathlib.Path, "read_text", proc_text),
                                           (image_resources, "process_priority", timed)):
                    hooks.enter_context(patch.object(owner, name, value))
                hooks.enter_context(patch.object(image_resources, "cgroup_limits", return_value=10))
                if interval is not None:
                    hooks.enter_context(patch.object(image_resources, "PRIORITY_SETTLE_INTERVAL", interval))
                return verify(child.pid, Cancellation(), **options), state, child
        except (image_resources.AdmissionError, image_resources.GuestDeadline, OSError) as error:
            return error, state, child
        finally:
            with suppress(BrokenPipeError):
                child.stdin.close()


def test_first_qemu_priority_sample_restores_launch_nice_and_fails_closed() -> None:
    leader = lambda state, child: [value for who, value in state["writes"] if who == child.pid]
    # The wrapper left -4 and no daemon follows up: the launcher itself restores nice 10.
    row, state, child = settle_sample(-4)
    assert type(row) is dict and row["nice"] == 10 and leader(state, child) == [10], (row, state)
    # The daemon undoes the first raise, then renices QEMU to 9 shortly after start.
    row, state, _ = settle_sample(-4, daemon=(3, 9), undo=1)
    assert type(row) is dict and row["nice"] >= image_resources.MIN_NICE, (row, state)
    # Already within the floor: leave it.
    row, state, child = settle_sample(12)
    assert type(row) is dict and row["nice"] == 12 and leader(state, child) == [], (row, state)
    # A host renice to 12 lands between the read and the write: accept it, do not abort.
    row, state, child = settle_sample(-4, race=12)
    assert type(row) is dict and row["nice"] == 12 and leader(state, child) == [10], (row, state)
    # A failed raise of a still-low child refuses with the exact error.
    for code in (errno.EPERM, errno.ESRCH):
        error, _, child = settle_sample(-4, set_error=code)
        assert type(error) is image_resources.AdmissionError, error
        assert str(error) == f"cannot raise QEMU PID {child.pid} to nice 10: {os.strerror(code)}", error
    # Policy is checked first: realtime or unknown classes refuse before any priority write.
    for nice, (policy, name) in product((5, 12), ((os.SCHED_FIFO, "SCHED_FIFO"), (os.SCHED_RR, "SCHED_RR"),
                                                  (6, "SCHED_DEADLINE"), (7, "policy 7"))):
        error, state, _ = settle_sample(nice, policy=policy)
        assert isinstance(error, image_resources.PriorityRefusal) and state["writes"] == [], (error, state)
        assert str(error) == f"image profile needs non-realtime scheduling and nice >= 9 (observed nice {nice}, {name})"
    error, state, _ = settle_sample(5, policy=OSError(errno.EIO, "fixture policy"))
    assert isinstance(error, OSError) and error.errno == errno.EIO and state["writes"] == [], (error, state)
    # One monotonic bound, checked before a sample is accepted.
    row, _, _ = settle_sample(12, cost=[4.9])
    assert type(row) is dict and row["nice"] == 12, row
    for seconds in (5.0, 5.1):
        error, _, _ = settle_sample(12, cost=[seconds])
        assert str(error) == f"QEMU priority conformed after {seconds:.3f} s, not within the 5.0 s settle bound", error
    # Only QEMU's own name proves the wrapper handed over; empty or unreadable names keep waiting.
    row, _, _ = settle_sample(12, comm=["", PermissionError(errno.EACCES, "fixture"), "sh", "setpriv", "qemu-system-x86\n"])
    assert type(row) is dict and row["nice"] == 12, row
    for names in ([""], [PermissionError(errno.EACCES, "fixture")], ["sh\n"], ["setpriv\n"]):
        error, _, child = settle_sample(12, comm=names)
        assert str(error) == f"QEMU PID {child.pid} did not hand over from its launch wrapper within 5.0 s", (names, error)
    # A daemon that keeps lowering it exhausts the bound and refuses with the observed value.
    error, _, _ = settle_sample(-4, undo=100)
    assert isinstance(error, image_resources.PriorityRefusal), error
    assert error.observed == {"nice": -4, "policy": "SCHED_OTHER"} and "observed nice -4, SCHED_OTHER" in str(error)
    # A child that exits during the settle is reported as an exit, never as a priority error.
    for code in (0, 37):
        error, _, child = settle_sample(-4, exit_code=code)
        assert type(error) is ProcessLookupError and "exited during the priority settle" in str(error), error
        assert child.returncode == code
    # Periodic verification is unchanged: it never renices and still refuses below the floor.
    row, state, _ = settle_sample(9, settle=False)
    assert type(row) is dict and row["nice"] == 9 and state["writes"] == [], (row, state)
    error, state, _ = settle_sample(-4, settle=False)
    assert isinstance(error, image_resources.PriorityRefusal) and state["writes"] == [], (error, state)


def test_settle_raises_every_qemu_thread_and_later_threads_inherit_it() -> None:
    # Linux nice is per thread: the stand-in starts a thread before the settle and one after it.
    real_get, real_set = os.getpriority, os.setpriority
    with tempfile.TemporaryDirectory() as temporary, subprocess.Popen(
            vm.parent_bound([str(qemu_standin(pathlib.Path(temporary)))], os.getpid()),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
        assert child.stdout.readline() == b"ready\n"
        tids = {int(name) for name in os.listdir(f"/proc/{child.pid}/task")}
        assert child.pid in tids and len(tids) == 2, tids
        # Model every existing thread at the wrapper's -4; the real threads are raised too where needed.
        nice = dict.fromkeys(tids, -4)

        def get(which, who):
            return nice[who] if who in nice else real_get(which, who)

        def put(which, who, value):
            if who not in nice:
                return real_set(which, who, value)
            nice[who] = value
            if real_get(which, who) < value:
                real_set(which, who, value)

        exited = lambda: os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
        with patch.object(os, "getpriority", get), patch.object(os, "setpriority", put), \
                patch.object(image_resources, "cgroup_limits", return_value=10):
            row = image_resources.process_priority(
                child.pid, Cancellation(), settle=image_resources.Settle(exited, pause=lambda _seconds: None))
        child.stdin.write(b"threads\n")
        child.stdin.flush()
        report = json.loads(child.stdout.readline())
        child.stdin.close()
    assert row["nice"] == 10 and nice == dict.fromkeys(tids, 10), (row, nice)
    # A thread created after the settle inherits its creator's raised niceness.
    assert min(report.values()) >= image_resources.MIN_NICE, report


def test_settle_never_outlasts_the_guest_deadline() -> None:
    # Guest time runs out during a pause: no pause or write past it, and the guest times out.
    error, state, _ = settle_sample(-4, undo=100, guest=1.0, interval=0.4)
    assert type(error) is image_resources.GuestDeadline, error
    assert state["pauses"] == [0.4, 0.4, 0.2] and max(state["write_times"]) < 1.0, state
    # An inconclusive sample completing at exactly the 5.0 s bound: refuse, with no further pause or write.
    error, state, _ = settle_sample(-4, undo=100, interval=4.9, cost=[0.0, 0.1])
    assert isinstance(error, image_resources.PriorityRefusal), error
    assert state["pauses"] == [4.9] and max(state["write_times"]) < 5.0, state
    # A conforming sample completing exactly at the guest deadline is a guest timeout.
    error, _, _ = settle_sample(12, guest=1.0, cost=[1.0])
    assert type(error) is image_resources.GuestDeadline, error


def test_settle_converges_on_threads_created_during_the_raise() -> None:
    real_get, real_set, real_list = os.getpriority, os.setpriority, image_resources.list_directory

    def settle(creations, *, workers=0, guest=None, write_cost=0.0):
        """Model every thread; a not-yet-raised thread clones a worker right after a listing."""
        with tempfile.TemporaryDirectory() as temporary, subprocess.Popen(
                vm.parent_bound([str(qemu_standin(pathlib.Path(temporary)))], os.getpid()),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
            assert child.stdout.readline() == b"ready\n"
            nice = {child.pid: -4} | {10**7 + n: -4 for n in range(workers)}
            now, writes, listings = [0.0], [], [0]
            task = pathlib.Path(f"/proc/{child.pid}/task")

            def listing(path, **kwargs):
                if path != task:
                    return real_list(path, **kwargs)
                listings[0] += 1
                names = [str(tid) for tid in nice]
                if listings[0] <= creations:
                    nice[2 * 10**7 + listings[0]] = 5  # Inherits its unraised creator's nice.
                return names

            def get(which, who):
                return nice[who] if who in nice else real_get(which, who)

            def put(which, who, value):
                if who not in nice:
                    return real_set(which, who, value)
                writes.append(now[0])
                nice[who] = value
                now[0] += write_cost

            exited = lambda: os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
            rule = image_resources.Settle(exited, guest_deadline=guest, clock=lambda: now[0],
                                          pause=lambda seconds: now.__setitem__(0, now[0] + seconds))
            try:
                with patch.object(os, "getpriority", get), patch.object(os, "setpriority", put), \
                        patch.object(image_resources, "list_directory", listing), \
                        patch.object(image_resources, "cgroup_limits", return_value=10):
                    result = image_resources.process_priority(child.pid, Cancellation(), settle=rule)
            except (image_resources.AdmissionError, image_resources.GuestDeadline) as error:
                result = error
            finally:
                child.stdin.close()
            return result, nice, writes

    # A worker cloned between the listing and the first raise, then one per pass for three passes.
    for creations in (1, 3):
        result, nice, _ = settle(creations)
        assert type(result) is dict and len(nice) == 1 + creations, (result, nice)
        assert min(nice.values()) >= image_resources.MIN_NICE, nice
    # A process that never stops cloning low workers is never accepted.
    result, nice, _ = settle(10**6)
    assert isinstance(result, image_resources.PriorityRefusal) and "thread" in result.observed, result
    # No priority write after the deadline: the second low thread is left once guest time is gone.
    result, nice, writes = settle(0, workers=1, guest=1.0, write_cost=1.0)
    assert type(result) is image_resources.GuestDeadline and writes == [0.0], (result, writes)


def test_guest_deadline_during_priority_settle_times_out_the_guest() -> None:
    real_popen, real_get, real_set = subprocess.Popen, os.getpriority, os.setpriority
    now, owned = [0.0], {}
    clock = SimpleNamespace(monotonic=lambda: now[0], time=time.time,
                            sleep=lambda seconds: now.__setitem__(0, now[0] + seconds))
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        standin = qemu_standin(root)

        def child(args, **options):
            process = real_popen([*args[:9], str(standin), "hold"], **options)
            owned["pid"] = process.pid
            return process

        # The host keeps the stand-in below the floor for the whole one-second guest budget.
        def get(which, who):
            return -4 if who == owned.get("pid") else real_get(which, who)

        def put(which, who, value):
            return None if who == owned.get("pid") else real_set(which, who, value)

        directory = root / "fixture/build"
        directory.mkdir(parents=True)
        capsule = root / "capsule"
        capsule.write_bytes(b"fixture")
        try:
            with tempfile.TemporaryFile(dir=root) as overlay, ImageJob(directory, IDENTITY, capsule, probe=True) as job:
                job.state.update(overlay_directory=str(root), retained_bytes=0)
                job.overlay_created(overlay.fileno())
                with patch.object(vm.subprocess, "Popen", child), patch.object(image_lifecycle, "disk_headroom"), \
                        patch.object(image_lifecycle, "time", clock), \
                        patch.object(image_resources, "cgroup_limits", return_value=10), \
                        patch.object(os, "getpriority", get), patch.object(os, "setpriority", put):
                    vm.boot(pathlib.Path("/unused"), b"{}", "image", 1, disk_fd=overlay.fileno(), image_job=job)
        except subprocess.TimeoutExpired as error:
            assert error.cmd == "image guest" and error.timeout == 1, error
        else:
            raise AssertionError("guest deadline was not reported as a guest timeout")
        record = json.loads((directory / "teardown.json").read_text())
        assert record["qemu_reaped"] is True and "qemu_priority_refusal" not in record, record


def test_guest_exit_during_priority_settle_reports_the_exit() -> None:
    real_popen, real_get, real_set = subprocess.Popen, os.getpriority, os.setpriority
    for code in (0, 37):
        owned = {}
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            standin = qemu_standin(root)

            def child(args, **options):
                process = real_popen([*args[:9], str(standin), f"exit:{code}"], **options)
                owned["pid"] = process.pid
                return process

            # The host keeps the stand-in below the floor, so only its exit can end the settle.
            def get(which, who):
                return -4 if who == owned.get("pid") else real_get(which, who)

            def put(which, who, value):
                return None if who == owned.get("pid") else real_set(which, who, value)

            directory = root / "fixture/build"
            directory.mkdir(parents=True)
            capsule = root / "capsule"
            capsule.write_bytes(b"fixture")
            error = None
            try:
                with tempfile.TemporaryFile(dir=root) as overlay, \
                        ImageJob(directory, IDENTITY, capsule, probe=True) as job:
                    job.state.update(overlay_directory=str(root), retained_bytes=0)
                    job.overlay_created(overlay.fileno())
                    with patch.object(vm.subprocess, "Popen", child), patch.object(image_lifecycle, "disk_headroom"), \
                            patch.object(image_resources, "cgroup_limits", return_value=10), \
                            patch.object(os, "getpriority", get), patch.object(os, "setpriority", put):
                        vm.boot(pathlib.Path("/unused"), b"{}", "image", 5, disk_fd=overlay.fileno(), image_job=job)
            except RuntimeError as exc:
                error = str(exc)
            assert error == (None if code == 0 else "image guest exited (37)"), error
            record = json.loads((directory / "teardown.json").read_text())
            assert record["qemu_exit"] == code and "qemu_priority_refusal" not in record, record


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


def test_cgroup_sample_retries_whole_observation_or_refuses() -> None:
    child, parent = "/sys/fs/cgroup/parent/child", "/sys/fs/cgroup/parent"
    membership = "/proc/123/cgroup"
    caps = {"memory.max": str(24 * image_resources.GIB), "memory.swap.max": "0",
            "cpu.max": "400000 100000", "io.weight": "default 10\n"}
    files = {f"{level}/{name}": value for level in (child, parent) for name, value in caps.items()}
    files.update({membership: "0::/parent/child\n", f"{child}/cpu.weight": "10"})
    transient = (errno.EIO, errno.EINTR, errno.EAGAIN)
    for path, code in product(files, (*transient, errno.EPERM, errno.ENOENT)):
        seen = []

        def read_text(file):
            name = str(file)
            if name == path and name not in seen:
                seen.append(name)
                raise OSError(code, "fixture cgroup read", name)
            seen.append(name)
            if name not in files:
                raise FileNotFoundError(errno.ENOENT, "controller file absent", name)
            return files[name]

        with patch.object(pathlib.Path, "read_text", read_text), \
                patch.object(pathlib.Path, "is_file", lambda p: str(p) in files):
            if code in transient:
                assert image_resources.retry_check(image_resources.cgroup_limits, 123) == 10
                assert seen.count(membership) == 2 and seen.count(path) == 2, (path, code, seen)
            else:
                try:
                    image_resources.retry_check(image_resources.cgroup_limits, 123)
                except (OSError, image_resources.AdmissionError):
                    assert path in seen, (path, code)
                else:
                    raise AssertionError((path, code, "inconclusive sample accepted"))

    files[f"{child}/memory.max"] = str(8 * image_resources.GIB)
    for failure in ("metadata", "malformed"):
        def read_text(file):
            if str(file) not in files:
                raise FileNotFoundError(errno.ENOENT, "controller file absent", str(file))
            return "invalid" if failure == "malformed" and str(file) == f"{child}/memory.max" else files[str(file)]

        def is_file(file):
            return str(file) in files and not (failure == "metadata" and str(file) == f"{child}/memory.max")

        with patch.object(pathlib.Path, "read_text", read_text), patch.object(pathlib.Path, "is_file", is_file):
            try:
                image_resources.retry_check(image_resources.cgroup_limits, 123)
            except image_resources.AdmissionError:
                pass
            else:
                raise AssertionError(f"accepted child limit after {failure}")

    for code in transient:
        reads = []

        def failed_read(path):
            name = str(path)
            reads.append(name)
            if name == f"{child}/memory.max":
                raise OSError(code, "persistent fixture cgroup read", name)
            return files[name]

        with patch.object(pathlib.Path, "read_text", failed_read):
            try:
                image_resources.retry_check(image_resources.cgroup_limits, 123)
            except OSError as error:
                assert error.errno == code
                assert reads == [membership, f"{child}/memory.max"] * 3
            else:
                raise AssertionError("persistent cgroup error accepted")


def test_admission_and_live_sampling_enforce_all_device_io_weights() -> None:
    child, parent = "/sys/fs/cgroup/parent/child", "/sys/fs/cgroup/parent"
    caps = {"memory.max": str(24 * image_resources.GIB), "memory.swap.max": "0",
            "cpu.max": "400000 100000"}
    files = {f"{level}/{name}": value for level in (child, parent) for name, value in caps.items()}
    files.update({"/proc/self/cgroup": "0::/parent/child\n", "/proc/123/cgroup": "0::/parent/child\n",
                  f"{child}/cpu.weight": "10", "/proc/meminfo": "MemAvailable: 33554432 kB\n"})
    cases = (
        ("default 10\n", "default 100\n", None),
        ("default 100\n", "default 100\n", "IOWeight"),
        ("default 10\n8:0 100\n", "default 100\n", "IOWeight"),
        ("default 10\n8:0 10\n", "default 100\n", None),
        ("default 10\n8:0 9\n", "default 100\n", None),
        ("default 10\n8:0 10\n8:1 1\n", "default 100\n", None),
        ("default 10\n8:0 10\n8:1 11\n", "default 100\n", "IOWeight"),
        ("default 10\n253:17 11\n", "default 100\n8:0 10\n", "IOWeight"),
        ("default 100\n", "default 10\n253:17 11\n", "IOWeight"),
        ("default 10\n8:0 100\n", "default 100\n8:0 9\n", None),
        ("default 10\n8:0 wrong\n", "default 100\n", "invalid cgroup limit"),
        ("default 10\n8 9\n", "default 100\n", "invalid cgroup limit"),
        ("default 10\n8:0 0\n", "default 100\n", "invalid cgroup limit"),
        ("default 10\n8:0 9\n8:0 10\n", "default 100\n", "invalid cgroup limit"),
    )
    def read_text(path):
        if str(path) not in files:
            raise FileNotFoundError(errno.ENOENT, "fixture absent control", str(path))
        return files[str(path)]

    with patch.object(pathlib.Path, "read_text", read_text), \
            patch.object(image_resources, "require_process_priority", return_value=9), \
            patch.object(os, "sched_getaffinity", return_value={0, 1, 2, 3}), \
            patch.object(image_resources._LIBC, "syscall", return_value=0):
        for child_weights, parent_weights, expected in cases:
            files[f"{child}/io.weight"] = child_weights
            files[f"{parent}/io.weight"] = parent_weights
            for observe in (image_resources.cgroup_admission,
                            lambda: image_resources.process_priority(123, Cancellation())):
                try:
                    observe()
                except image_resources.AdmissionError as error:
                    assert expected and expected in str(error), (child_weights, parent_weights, observe, error)
                else:
                    assert expected is None, (child_weights, parent_weights, observe, "invalid device weight accepted")


def test_admission_and_live_sampling_require_conclusive_bfq_weights() -> None:
    child, parent = "/sys/fs/cgroup/parent/child", "/sys/fs/cgroup/parent"
    caps = {"memory.max": str(24 * image_resources.GIB), "memory.swap.max": "0",
            "cpu.max": "400000 100000", "io.weight": "default 7\n"}
    baseline = {f"{level}/{name}": value for level in (child, parent) for name, value in caps.items()}
    baseline.update({"/proc/self/cgroup": "0::/parent/child\n", "/proc/123/cgroup": "0::/parent/child\n",
                     f"{child}/cpu.weight": "10", "/proc/meminfo": "MemAvailable: 33554432 kB\n"})
    high = "default 100\n"
    cases = (
        (None, None, None, 0, True, 1),
        (high, high, None, 0, False, 1),
        ("default 11\n", high, None, 0, False, 1),
        ("default 10\n", high, None, 0, True, 1),
        ("default 7\n", high, None, 0, True, 1),
        ("default 7\n8:1 100\n", high, None, 0, False, 1),
        ("default 7\n8:1 10\n253:17 9\n", high, None, 0, True, 1),
        ("default 7\n8:1 9\n253:17 11\n", high, None, 0, False, 1),
        ("default 7\n8:1 100\n", "default 11\n8:1 9\n", None, 0, True, 1),
        (high, "default 10\n253:17 11\n", None, 0, False, 1),
        ("default 7\n", None, None, 0, False, 3),
        (None, "default 7\n", None, 0, False, 3),
        ("default 7\n", "default 7\n8:1 malformed\n", None, 0, False, 3),
        ("default 7\n8:1 8\n8:1 9\n", high, None, 0, False, 3),
    )
    for child_text, parent_text, code, failures, accept, observations in (
        *cases,
        *((("default 7\n", high, error, count, count == 1, count + (count == 1)))
          for error, count in product((errno.EIO, errno.EINTR, errno.EAGAIN, errno.EACCES, errno.ENOENT), (1, 3))),
    ):
        files = baseline.copy()
        for level, text in ((child, child_text), (parent, parent_text)):
            if text is not None:
                files[f"{level}/io.bfq.weight"] = text
        for pid, observe in (("self", image_resources.cgroup_admission),
                             ("123", lambda: image_resources.process_priority(123, Cancellation()))):
            reads = []
            fault = f"{parent}/io.bfq.weight"

            def read_text(path):
                name = str(path)
                reads.append(name)
                if name == fault and code is not None and reads.count(name) <= failures:
                    raise OSError(code, "fixture BFQ read")
                if name not in files:
                    raise FileNotFoundError(errno.ENOENT, "fixture absent control")
                return files[name]

            def lstat(path):
                if str(path) not in files:
                    raise FileNotFoundError(errno.ENOENT, "fixture absent control")
                return os.stat_result((0,) * 10)

            with patch.object(pathlib.Path, "read_text", read_text), patch.object(pathlib.Path, "lstat", lstat), \
                    patch.object(image_resources, "require_process_priority", return_value=9), \
                    patch.object(os, "sched_getaffinity", return_value={0, 1, 2, 3}), \
                    patch.object(image_resources._LIBC, "syscall", return_value=0):
                try:
                    observe()
                except (image_resources.AdmissionError, OSError) as exc:
                    assert not accept and ("bfq" in str(exc) or "BFQ" in str(exc)), (pid, reads, exc)
                else:
                    assert accept, (pid, child_text, parent_text, code, reads)
            assert reads.count(f"/proc/{pid}/cgroup") == observations, (pid, reads)
            assert reads.count(f"{child}/memory.max") == observations, (pid, reads)


def test_full_launcher_probe_stderr_flood() -> None:
    for mib in (3, 8):
        cancelled_fixture(f"stderr-flood:{mib}")


def test_launcher_refuses_and_reaps_after_failed_live_priority_sample() -> None:
    cancelled_fixture("priority-failure")


def test_priority_refusal_records_the_observed_nice_and_policy() -> None:
    cancelled_fixture("priority-floor")


def test_probe_exact_result_types_never_commit_success() -> None:
    for field, values in {
        "schema": (True, 1.0, "1", None),
        "network_denied": (1, "true", 0, 1.0, None, False),
        "identity": ([], None),
        "identity.attempt": (1,), "identity.board": (False,), "identity.commit": (None,),
        "identity.input_sha256": (False,), "identity.epoch": (float(IDENTITY.epoch), "123", None),
    }.items():
        for value in values:
            cancelled_fixture(f"probe-invalid:{field}:{json.dumps(value)}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--fixture-launcher"]:
        fixture_launcher(pathlib.Path(sys.argv[2]), sys.argv[3], signal.Signals(int(sys.argv[4])))
        raise AssertionError("launcher did not exit")
    startup_tests = (
        test_hostile_startup_does_not_change_guest_outcome,
        test_startup_verification_failure_refuses_before_spawning,
        test_echild_cannot_be_reported_as_guest_or_helper_success,
    )
    tests = [test for name, test in list(globals().items()) if name.startswith("test_")]
    match sys.argv[1:]:
        case []:
            pass
        case ["--startup"]:
            tests = list(startup_tests)
        case ["--lifecycle"]:
            tests = [test for test in tests if test not in startup_tests]
        case _:
            raise SystemExit("usage: image_profile_test.py [--startup | --lifecycle]")
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"image profile: {len(tests)} passed")
