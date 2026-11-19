"""Private pipes, receipts and owned-resource reconciliation for image guests."""

from __future__ import annotations

from dataclasses import asdict
from contextlib import ExitStack, contextmanager
import errno
from functools import partial
import json
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import time
import tempfile
from typing import TextIO
import uuid

from image_resources import CAPS, GIB, AdmissionError, disk_headroom, process_priority
from image_stream import (
    CONTROL_LOG_LIMIT, IO_ATTEMPTS, RETRYABLE_IO, Identity, StreamError, list_directory, retry_check, write_all,
)
from vm_process import POLL_SECONDS, STOP_SIGNALS, Cancelled, Cancellation, poll_owned, run, wait


class ReceiptError(OSError):
    """A receipt publication failed."""

@contextmanager
def job_disk(base: Path, image_job=None, cancellation: Cancellation | None = None):
    """Shared anonymous disk lifecycle used by vm.py's kernel and image paths."""
    from vm import die_with_parent
    overlay_file = tempfile.TemporaryFile(prefix="job-", dir=base.parent)
    try:
        disk_fd = overlay_file.fileno()
        if image_job:
            image_job.overlay_created(disk_fd)
        overlay = Path(f"/proc/self/fd/{disk_fd}")
        run(["qemu-img", "create", "-f", "qcow2", "-F", "qcow2",
             "-b", str(base), str(overlay)], cancellation=cancellation or Cancellation(),
            pass_fds=(disk_fd,), preexec_fn=partial(die_with_parent, os.getpid()), timeout=180)
        yield overlay, disk_fd
    finally:
        overlay_file.close()
        if image_job:
            image_job.state["overlay_descriptor_closed"] = True

def process_identity(pid: int) -> str:
    text = (Path("/proc") / str(pid) / "stat").read_text()
    return f"{pid}:{text[text.rindex(')') + 2:].split()[19]}"


def sync_directory(path: Path) -> None:
    fd = os.open(path, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def create_directory(path: Path, *, parents: bool = False) -> None:
    """Make each new directory entry durable before relying on its children."""
    if parents and path.is_dir():
        return
    if parents:
        create_directory(path.parent, parents=True)
    path.mkdir(mode=0o700)
    sync_directory(path.parent)


class Receipt:
    """Own the receipt's temporary file, rename and cleanup as a single transaction."""

    def __init__(self, path: Path, row: dict, outcome: Cancellation | None,
                 diagnostic: BaseException | None) -> None:
        self.path = path
        self.row = row
        self.outcome = outcome
        self.temporary = path.parent / (".receipt-" + uuid.uuid4().hex)
        self.file: TextIO | None = None
        self.directory_fd: int | None = None
        self.renamed = False
        self.errors: list[BaseException] = [] if diagnostic is None else [diagnostic]

    def temp_open(self) -> None:
        self.file = open(
            self.temporary, "x", encoding="utf-8",
            opener=lambda name, flags: os.open(Path(name), flags, 0o600))

    def temp_write(self) -> None:
        assert self.file is not None
        json.dump(self.row, self.file, sort_keys=True, indent=2)
        self.file.write("\n")

    def temp_flush(self) -> None:
        assert self.file is not None
        self.file.flush()

    def file_sync(self) -> None:
        assert self.file is not None
        os.fsync(self.file.fileno())

    def file_close(self) -> None:
        if self.file is not None:
            self.file.close()

    def temp_cleanup(self) -> None:
        if not self.renamed and self.file is not None:
            self.temporary.unlink(missing_ok=True)

    def mask_block(self) -> None:
        if self.outcome is not None:
            self.outcome.begin_finalization()

    def rename(self) -> None:
        if self.outcome is not None and self.row["stop_reason"] != "cancelled":
            self.outcome.check()
            if signal.sigpending().intersection(STOP_SIGNALS):
                raise Cancelled("runner cancelled")
        status = self.row["launcher_exit"] if self.outcome is not None else None
        os.replace(self.temporary, self.path)
        if self.outcome is not None:
            self.outcome.committed_exit = status
        self.renamed = True

    def dir_open(self) -> None:
        if self.renamed:
            self.directory_fd = os.open(self.path.parent, os.O_DIRECTORY)

    def dir_sync(self) -> None:
        if self.directory_fd is not None:
            os.fsync(self.directory_fd)

    def dir_close(self) -> None:
        if self.directory_fd is not None:
            os.close(self.directory_fd)

    def log_errors(self) -> None:
        for error in self.errors:
            report_error(error)


# The order and failure policy here also drive the complete fault matrix.
RECEIPT_STEPS = (
    (Receipt.temp_open, False), (Receipt.temp_write, False),
    (Receipt.temp_flush, False), (Receipt.file_sync, False),
    (Receipt.file_close, True), (Receipt.mask_block, False), (Receipt.rename, False),
    (Receipt.dir_open, True), (Receipt.dir_sync, True),
    (Receipt.dir_close, True), (Receipt.temp_cleanup, True), (Receipt.log_errors, True),
)


def receipt(path: Path, row: dict, *, outcome: Cancellation | None = None,
            diagnostic: BaseException | None = None) -> None:
    transaction = Receipt(path, row, outcome, diagnostic)
    failure: BaseException | None = None
    for action, cleanup in RECEIPT_STEPS:
        if failure is not None and not cleanup and not transaction.renamed:
            continue
        try:
            action(transaction)
        except BaseException as error:
            if failure is None:
                failure = error
            if action is Receipt.log_errors:
                report_error(error)
            elif not isinstance(error, Cancelled):
                transaction.errors.append(error)
    if failure is not None and (outcome is None or not transaction.renamed):
        if isinstance(failure, Cancelled):
            raise failure
        raise ReceiptError(str(failure)) from failure


def report_error(error: BaseException | str) -> None:
    """Diagnostics must not affect an already committed exit code."""
    try:
        os.write(2, f"kernel runner: {error}\n".encode(errors="backslashreplace"))
    except BaseException:
        return  # There may be no stderr reader.


def reconcile(store: Path) -> None:
    try:
        row = retry_check(_reconcile_inventory, store, errors=frozenset(
            (errno.ENOENT, errno.ESRCH, errno.EINTR, errno.EAGAIN)))
    except OSError as error:
        raise AdmissionError(f"cannot complete previous image ownership scan: {error}") from error
    if row is None:
        return
    receipt(store / (row["attempt"] + ".reconciled.json"), {
        **row, "stop_reason": "previous launcher interrupted; guest cleanup unknown",
        "overlay_descriptors_closed": True, "reconciled_at": time.time(),
    })
    (store / "active.json").unlink()
    sync_directory(store)


def _reconcile_inventory(store: Path) -> dict | None:
    active = store / "active.json"
    if active.name not in list_directory(store):
        return None
    if not stat.S_ISREG(active.lstat().st_mode):
        raise AdmissionError("active journal is not a regular file")
    row = json.loads(active.read_text())
    proc = Path("/proc")
    pids = {name for name in list_directory(proc) if name.isdecimal()}
    for key in ("launcher", "qemu"):
        if key not in row:
            continue
        pid = str(int(row[key].split(":")[0]))
        if pid not in pids:
            continue
        status = (proc / pid / "stat").read_text()
        fields = status[status.rindex(")") + 2:].split()
        if f"{pid}:{fields[19]}" == row[key] and fields[0] != "Z":
            raise AdmissionError(f"previous owned {key} still running: {row[key]}")
    owned = tuple(row["overlay_inode"])
    for pid in sorted(pids):
        directory = proc / pid / "fd"
        for number in list_directory(directory, omit_open_fd=pid == str(os.getpid())):
            descriptor = directory / number
            info = descriptor.stat()
            if (info.st_dev, info.st_ino) == owned:
                raise AdmissionError(f"previous owned overlay still held by {descriptor}")
    return row


class ImageJob:
    """Mutable attempt journal and private descriptor ownership for one guest."""

    def __init__(self, directory: Path, identity: Identity, capsule: Path,
                 cancellation: Cancellation | None = None, *, probe: bool = False) -> None:
        self.directory = directory
        self.identity = identity
        self.cancellation = cancellation or Cancellation()
        self.probe = probe
        self.outputs = ExitStack()
        self.inputs = ExitStack()
        self.active = directory.parents[1] / "active.json"
        self.state = {"schema": 1, "identity": asdict(identity), "caps": asdict(CAPS),
                      "launcher": process_identity(os.getpid()), "acquired_at": time.time(),
                      "stop_reason": "not started", "qemu_reaped": False,
                      "stream_budget": CAPS.stream_max,
                      "input_descriptor_closed": False, "overlay_descriptor_closed": False}
        with ExitStack() as inputs:
            self.capsule_fd = os.open(capsule, os.O_RDONLY | os.O_NOFOLLOW)
            inputs.callback(os.close, self.capsule_fd)
            self.console_read, self.console_write = os.pipe()
            inputs.callback(os.close, self.console_read)
            inputs.callback(self.close_console_writer)
            self.inputs = inputs.pop_all()

    def __enter__(self) -> ImageJob:
        return self

    def __exit__(self, _type, error, _traceback) -> None:
        # Attempt every descriptor close even if an earlier close or sync fails.
        with self.outputs:
            self.inputs.close()
            self.state["input_descriptor_closed"] = True
        self.state["ended_at"] = time.time()
        if error:
            self.state["stop_reason"] = type(error).__name__
        receipt(self.directory / "teardown.json", self.state)
        if (self.state["overlay_descriptor_closed"] and "overlay_inode" in self.state
                and ("qemu" not in self.state or self.state["qemu_reaped"])):
            self.cancellation.safe_journal = self.active

    def close_console_writer(self) -> None:
        if self.console_write >= 0:
            fd, self.console_write = self.console_write, -1
            os.close(fd)

    def overlay_created(self, disk_fd: int) -> None:
        """Journal ownership before any qemu-img or QEMU child can inherit it."""
        self.cancellation.safe_journal = None
        inode = os.fstat(disk_fd)
        self.state.update(overlay_fd=disk_fd, overlay_inode=[inode.st_dev, inode.st_ino])
        receipt(self.active, {
            "attempt": self.identity.attempt, "launcher": self.state["launcher"],
            "overlay_inode": self.state["overlay_inode"],
        })

    def capture(self, process: subprocess.Popen, seconds: int) -> None:
        """Drain the artifact and console ports without echoing guest bytes."""
        self.state.update(qemu=process_identity(process.pid), started_at=time.time(),
                          stop_reason="running")
        receipt(self.directory / "started.json", self.state)
        receipt(self.active, {
            "attempt": self.identity.attempt, "launcher": self.state["launcher"],
            "qemu": self.state["qemu"], "overlay_inode": self.state["overlay_inode"],
        })
        self.close_console_writer()
        end = time.monotonic() + seconds
        next_priority_check = 0.0
        counts = {"stream": 0, "console": 0, "diagnostic": 0}
        read_errors = dict.fromkeys(counts, 0)
        with selectors.DefaultSelector() as events:
            files = {}
            pipes = [("stream", process.stdout), ("console", self.console_read)]
            if not self.probe:
                pipes.append(("diagnostic", process.stderr))
            for name, pipe in pipes:
                events.register(pipe, selectors.EVENT_READ, name)
                fd = os.open(self.directory / (name + ".partial"),
                             os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                output = self.outputs.enter_context(os.fdopen(fd, "wb", buffering=0))
                self.outputs.callback(sync_output, output)
                files[name] = output
            try:
                while events.get_map() or poll_owned(process) is None:
                    self.cancellation.check()
                    now = time.monotonic()
                    if now >= end:
                        raise subprocess.TimeoutExpired("image guest", seconds)
                    if now >= next_priority_check and poll_owned(process) is None:
                        try:
                            self.state["qemu_priority"] = process_priority(process.pid, self.cancellation)
                        except (FileNotFoundError, ProcessLookupError):
                            if poll_owned(process) is None:
                                raise
                        next_priority_check = now + 5
                    try:
                        ready = events.select(timeout=min(POLL_SECONDS, end - now))
                    except InterruptedError:
                        continue
                    self.cancellation.check()
                    for event, _mask in ready:
                        self.cancellation.check()
                        name = event.data
                        fd = event.fileobj if type(event.fileobj) is int else event.fileobj.fileno()
                        try:
                            chunk = os.read(fd, 1024 * 1024)
                        except OSError as error:
                            read_errors[name] += 1
                            if error.errno not in RETRYABLE_IO or read_errors[name] >= IO_ATTEMPTS:
                                raise
                            continue
                        read_errors[name] = 0
                        if not chunk:
                            events.unregister(event.fileobj)
                            continue
                        counts[name] += len(chunk)
                        if (counts["stream"] > min(CAPS.stream_max, self.state["stream_budget"])
                                or counts["console"] + counts["diagnostic"] > CONTROL_LOG_LIMIT):
                            raise StreamError("image return stream or log budget exceeded")
                        write_all(files[name], chunk)
                    # Fixed caps bound growth between these observations.
                    overlay = Path(f"/proc/self/fd/{self.state['overlay_fd']}")
                    remaining_overlay = max(0, CAPS.overlay_max - overlay.stat().st_blocks * 512)
                    disk_headroom(((Path(self.state["overlay_directory"]), remaining_overlay),
                                   (self.directory, 49 * GIB - self.state["retained_bytes"] - sum(counts.values()))))
                wait(process, end, self.cancellation)
            finally:
                self.state["stream_bytes"] = counts["stream"]


def sync_output(output) -> None:
    """Sync output only after the child has been stopped and reaped."""
    output.flush()
    os.fsync(output.fileno())
