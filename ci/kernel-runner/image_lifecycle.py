"""Private pipes, receipts and owned-resource reconciliation for image guests."""

from __future__ import annotations

from dataclasses import asdict
from contextlib import ExitStack, contextmanager
import ctypes
import errno
import hashlib
from functools import partial
from io import FileIO, StringIO
import json
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import time
import tempfile
from typing import BinaryIO, Callable
import uuid

from image_resources import CAPS, GIB, AdmissionError, IOPriorityError, disk_headroom, process_priority
from image_stages import StageTail, optional
from image_stream import (
    CONTROL_LOG_LIMIT, IO_ATTEMPTS, RETRYABLE_IO, ExclusiveFile, FileSyncError, Identity, Member, PositionedReader,
    StreamError, can_rewrite, list_directory, positioned_open, read_check_text, read_once, report_error,
    retry_check, retry_io, rewrite_file, sync_file, transfer, unlink_owned, write_all,
)
from vm_process import (
    COMMITTED, FRESH_REWRITE, POLL_SECONDS, RENAME, SYNC, VERIFY, WRITE, Cancelled, Cancellation,
    ChildContainmentError, ReceiptResult, close_transport, poll_owned, register_close, run, wait,
)

UNAVAILABLE_DIAGNOSTICS = {
    "last_observed_stage": None,
    "sequence_complete": False,
    "capture_lost": True,
    "console_tail": "",
    "console_tail_truncated": False,
    "control_bytes_received": 0,
}
RECEIPT_RETRY = RETRYABLE_IO | frozenset((errno.EINTR,))
RENAME_RETRY = RECEIPT_RETRY | frozenset((errno.ENOENT,))


def encode_diagnostic_fields(fields: dict) -> bytes:
    # Append members to an already encoded outcome object.
    text = json.dumps(fields, sort_keys=True, indent=2)
    suffix = ",\n" + text[2:] + "\n"
    return suffix.encode("ascii")


class ReceiptError(OSError):
    """A receipt publication failed."""


@contextmanager
def job_disk(base: Path, image_job=None, cancellation: Cancellation | None = None):
    """Shared anonymous disk lifecycle used by vm.py's kernel and image paths."""
    overlay_file = tempfile.TemporaryFile(prefix="job-", dir=base.parent)
    try:
        disk_fd = overlay_file.fileno()
        if image_job:
            image_job.overlay_created(disk_fd)
        overlay = Path(f"/proc/self/fd/{disk_fd}")
        run(["qemu-img", "create", "-f", "qcow2", "-F", "qcow2",
             "-b", str(base), str(overlay)], cancellation=cancellation or Cancellation(),
            pass_fds=(disk_fd,), timeout=180)
        yield overlay, disk_fd
    finally:
        close_transport(overlay_file.close)
        if image_job:
            image_job.state["overlay_descriptor_closed"] = True

def process_identity(pid: int) -> str:
    text = (Path("/proc") / str(pid) / "stat").read_text()
    return f"{pid}:{text[text.rindex(')') + 2:].split()[19]}"


def sync_directory(path: Path) -> None:
    fd = None
    try:
        fd = retry_io(os.open, path, os.O_DIRECTORY, recover=True)
        sync_file(fd, directory=True)
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError as error:
                report_error(error)  # Linux releases the number even on EINTR.


def create_directory(path: Path, *, parents: bool = False) -> None:
    """Make each new directory entry durable before relying on its children."""
    if parents:
        try:
            if stat.S_ISDIR(retry_io(path.stat, recover=True).st_mode):
                return
        except FileNotFoundError:
            pass
        create_directory(path.parent, parents=True)
    retry_io(path.mkdir, mode=0o700, recover=True)
    sync_directory(path.parent)


def receipt_temporary(path: Path) -> Path:
    return path.parent / (".receipt-" + retry_io(uuid.uuid4, recover=True).hex)


class Receipt:
    """Own the receipt's temporary file, rename and cleanup as a single transaction."""

    def __init__(self, path: Path, row: dict, outcome: Cancellation | None,
                 diagnostic: BaseException | None, probe: ImageJob | None = None,
                 temporary: Path | None = None) -> None:
        self.path = path
        self.row = row
        self.outcome = outcome
        self.primary = ExclusiveFile(temporary or receipt_temporary(path), readable=True)
        self.output = self.primary
        self.replacement: ExclusiveFile | None = None
        self.status = row["launcher_exit"] if outcome is not None else 1
        self.payload: tuple[bytes, ...] = ()
        self.probe = probe
        self.directory_fd: int | None = None
        self.result = outcome.receipt_result if outcome is not None else ReceiptResult()
        self.result.state = WRITE
        self.failure: BaseException | None = None
        self.failure_error = ReceiptError("receipt publication failed")
        self.cleanup_error = ReceiptError("receipt temporary cleanup could not be verified")
        self.verified_inode: os.stat_result | None = None
        self._candidate_inode: os.stat_result | None = None
        self._rewritten = False
        self._closed = False
        self._masked = False
        self._rename_error: BaseException | None = None
        self._rename_attempts = 0
        self._checkpoint = outcome.check_commit if outcome is not None and row.get("stop_reason") != "cancelled" else None
        self.diagnostic = diagnostic

    @property
    def renamed(self) -> bool:
        return self.result.state == COMMITTED

    @property
    def file_fd(self) -> int | None:
        return self.output.fd

    @property
    def temporary(self) -> Path:
        return self.output.path

    def temp_open(self) -> None:
        for attempt in range(IO_ATTEMPTS):
            try:
                self.output.open()
                return
            except FileExistsError:
                if attempt + 1 == IO_ATTEMPTS:
                    raise
                self.output.path = receipt_temporary(self.path)

    def temp_write(self) -> None:
        fd = self.file_fd
        assert fd is not None and fd >= 0
        if self.probe is None:
            with StringIO() as text:
                json.dump(self.row, text, sort_keys=True, indent=2)
                text.write("\n")
                self.payload = (text.getvalue().encode("utf-8"),)
        else:
            # Encode the authoritative fields before trying optional diagnostics.
            outcome = json.dumps(self.row, sort_keys=True, indent=2)[:-2].encode("ascii")
            fields = self.probe.fallback_fields
            try:
                fields = encode_diagnostic_fields(self.probe.diagnostic_summary())
            except Exception:
                pass
            self.payload = (outcome, fields)
        self._write_payload(fd)
        self.result.state = SYNC

    def _write_payload(self, fd: int) -> None:
        for fragment in self.payload:
            write_all(fd, fragment)

    def _verify_payload(self, fd: int) -> None:
        with PositionedReader(fd, checked=True) as source:
            if any(source.read(len(fragment)) != fragment for fragment in self.payload) or source.read(1):
                raise ReceiptError("receipt content differs before publication")
        self.verified_inode = self._candidate_inode
        self.result.state = RENAME

    def file_sync(self) -> None:
        assert self.file_fd is not None and self.file_fd >= 0
        if self.outcome is not None and self.outcome.exit_sync_calls >= 2:
            raise ReceiptError("terminal receipt sync budget exhausted")
        self._candidate_inode = retry_io(os.fstat, self.file_fd, recover=True)
        sync_file(self.file_fd, terminal_budget=self.outcome); self.result.state = VERIFY

    def _fresh_rewrite(self) -> None:
        # Keep the failed inode linked until the replacement has its own name.
        self.replacement = ExclusiveFile(receipt_temporary(self.path), readable=True)
        self.replacement.open()
        self._write_payload(self.replacement.fileno())
        self.primary.discard()
        self.output = self.replacement
        self._rewritten = True
        self.result.state = SYNC

    def file_close(self) -> None:
        try:
            try:
                self.output.close()
            except MemoryError as error:
                report_error(error)
                self.output.close()  # The owner has already invalidated a released FD.
        except (OSError, MemoryError) as error:
            if self.file_fd is not None and self.file_fd >= 0:
                raise
            report_error(error)

    def temp_cleanup(self) -> None:
        if not self.renamed:
            try:
                self.primary.discard()
            finally:
                if self.replacement is not None:
                    self.replacement.discard()

    def mask_block(self) -> None:
        if self.outcome is not None:
            if not self.outcome.begin_finalization():
                report_error("finalization signal mask unverified; catchable signals ignored")

    def _owns_name(self, path: Path) -> bool:
        try:
            found = path.lstat()
        except FileNotFoundError:
            return False
        return found.st_dev == self.verified_inode.st_dev and found.st_ino == self.verified_inode.st_ino

    def _resolve_rename(self) -> bool | None:
        """Identify a published inode or a safe retry. Absence alone proves neither."""
        for _ in range(IO_ATTEMPTS):
            try:
                if self._owns_name(self.path):
                    return True
                if self._owns_name(self.temporary):
                    return False
            except MemoryError:
                continue
            except OSError as error:
                if error.errno not in RENAME_RETRY:
                    raise
        return None

    def rename(self) -> None:
        if self.file_fd != -1 or self.verified_inode is None:
            raise ReceiptError("receipt is not verified and closed")
        while True:
            if self._rename_error is not None:
                error = self._rename_error
                owner = self._resolve_rename()
                if owner is True:
                    self.result.exit_status = self.status
                    self.result.state = COMMITTED
                    return
                if owner is not False or self._rename_attempts == IO_ATTEMPTS or not (
                        isinstance(error, MemoryError)
                        or isinstance(error, OSError) and error.errno in RENAME_RETRY):
                    raise error
                self._rename_error = None
            if self._checkpoint is not None:
                retry_io(self._checkpoint, recover=True)
            source = self.temporary
            self._rename_attempts += 1
            try:
                # The syscall is the only fallible operation after arming the result.
                self.result.exit_status = self.status
                self.result.state = COMMITTED; os.replace(source, self.path)
            except BaseException as error:
                # The attempted syscall may have consumed the temporary before raising.
                self._rename_error = error
                self.result.exit_status = 1; self.result.state = RENAME
            else:
                return

    def dir_open(self) -> None:
        if self.renamed:
            self.directory_fd = retry_io(os.open, self.path.parent, os.O_DIRECTORY, recover=self.outcome is None)

    def dir_sync(self) -> None:
        if self.directory_fd is not None:
            sync_file(self.directory_fd, directory=True, recover=self.outcome is None)

    def dir_close(self) -> None:
        if self.directory_fd is not None:
            try:
                os.close(self.directory_fd)
            except OSError as error:
                report_error(error)
            finally:
                self.directory_fd = None

    def log_errors(self) -> None:
        if self.diagnostic is not None:
            report_error(self.diagnostic)
        if self.result.diagnostic is not None:
            report_error(self.result.diagnostic)

    def _record_failure(self, error: BaseException) -> None:
        if self.result.first_failure_cause is None and not isinstance(error, Cancelled):
            self.result.first_failure_cause = error
            if isinstance(error, OSError):
                self.result.failure_errno = error.errno
            if isinstance(error, FileSyncError):
                self.result.failure_code = "receipt fsync failed"
        if self.failure is None:
            self.failure = error

    def _advance(self) -> None:
        """Resume at the first unfinished operation on the same inode."""
        if self.result.state == WRITE:
            self.temp_open()
            self.temp_write()
        if self.result.state == FRESH_REWRITE:
            self._fresh_rewrite()
        if self.result.state == SYNC:
            self.file_sync()
        if self.result.state == VERIFY:
            retry_io(self._verify_payload, self.file_fd, recover=True)
        if self.result.state == RENAME:
            if not self._closed:
                self.file_close()
                self._closed = True
            if not self._masked:
                self.mask_block()
                self._masked = True
            self.rename()

    def _note_cleanup(self, error: BaseException) -> None:
        if self.result.diagnostic is None:
            self.result.diagnostic = error
        if self.outcome is None or not self.renamed:
            self._record_failure(error)

    def _finish(self) -> None:
        """Each cleanup step is isolated. A committed terminal result is immutable."""
        for step in (None if self._closed else Receipt.file_close, Receipt.dir_open, Receipt.dir_sync,
                     Receipt.dir_close, Receipt.temp_cleanup):
            try:
                if step is not None:
                    step(self)
            except BaseException as error:
                self._note_cleanup(error)
        for _ in range(IO_ATTEMPTS - 1):
            try:
                if self.directory_fd is not None:
                    self.dir_close()
                if not self.renamed and (self.primary.fd is not None
                        or self.replacement is not None and self.replacement.fd is not None):
                    self.temp_cleanup()
            except BaseException as error:
                self._note_cleanup(error)
        try:
            self.log_errors()
        except BaseException as error:
            self._note_cleanup(error)


def receipt(path: Path, row: dict, *, outcome: Cancellation | None = None,
            diagnostic: BaseException | None = None, probe: ImageJob | None = None,
            temporary: Path | None = None) -> None:
    if outcome is not None and outcome.receipt_result.state == COMMITTED:
        return
    transaction = Receipt(path, row, outcome, diagnostic, probe, temporary)
    result = transaction.result
    resume = 0
    try:
        while True:
            try:
                transaction._advance()
            except BaseException as error:
                state = result.state
                if state == COMMITTED:
                    result.diagnostic = error
                    break
                if (isinstance(error, MemoryError) and state in (VERIFY, RENAME)
                        and resume < IO_ATTEMPTS - 1):
                    resume += 1
                    continue
                if (isinstance(error, OSError) and state in (SYNC, VERIFY) and not transaction._rewritten
                        and error.errno in RECEIPT_RETRY
                        and (outcome is None or outcome.exit_sync_calls < 2)
                        and (outcome is not None or not isinstance(error, FileSyncError) or can_rewrite(error))):
                    result.state = FRESH_REWRITE
                    continue
                if state == RENAME and transaction.file_fd == -1:
                    transaction._closed = True
                result.exit_status = 1
                transaction._record_failure(error)
            break
    finally:
        try:
            transaction._finish()
        except BaseException as error:
            transaction._note_cleanup(error)
    failure = transaction.failure
    if failure is not None and (outcome is None or not transaction.renamed):
        if not transaction.renamed and (transaction.primary.fd is not None or (
                transaction.replacement is not None and transaction.replacement.fd is not None)):
            raise transaction.cleanup_error from failure
        if isinstance(failure, Cancelled):
            raise failure
        raise transaction.failure_error from failure


def reconcile(store: Path) -> None:
    try:
        row = retry_check(_reconcile_inventory, store, disappearing=True)
    except OSError as error:
        raise AdmissionError(f"cannot complete previous image ownership scan: {error}") from error
    if row is None:
        return
    receipt(store / (row["attempt"] + ".reconciled.json"), {
        **row, "stop_reason": "previous launcher interrupted; guest cleanup unknown",
        "overlay_descriptors_closed": True, "reconciled_at": time.time(),
    })
    unlink_owned(store / "active.json")
    sync_directory(store)


PROC_ROOT = Path("/proc")


def _reconcile_inventory(store: Path) -> dict | None:
    active = store / "active.json"
    if active.name not in list_directory(store):
        return None
    if not stat.S_ISREG(active.lstat().st_mode):
        raise AdmissionError("active journal is not a regular file")
    row = json.loads(read_check_text(active))
    pids = {name for name in list_directory(PROC_ROOT) if name.isdecimal()}
    for key in ("launcher", "qemu"):
        if key not in row:
            continue
        pid = str(int(row[key].split(":")[0]))
        if pid not in pids:
            continue
        status = read_check_text(PROC_ROOT / pid / "stat")
        current = f"{pid}:{status[status.rindex(')') + 2:].split()[19]}"
        if current == row[key] and status[status.rindex(")") + 2:].split()[0] != "Z":
            raise AdmissionError(f"previous owned {key} still running: {row[key]}")
    owned = tuple(row["overlay_inode"])
    for pid in sorted(pids):
        directory = PROC_ROOT / pid / "fd"
        for number in list_directory(directory, omit_open_fd=pid == str(os.getpid())):
            descriptor = directory / number
            info = descriptor.stat()
            if (info.st_dev, info.st_ino) == owned:
                raise AdmissionError(f"previous owned overlay still held by {descriptor}")
    return row


def retire_journal(cancellation: Cancellation) -> None:
    """Retire a safely released journal after the attempt outcome is settled."""
    journal = cancellation.safe_journal
    if journal is None:
        return
    path, directory = journal
    try:
        unlink_owned(path)
    except (OSError, MemoryError) as error:
        report_error(f"journal_removed=false: {error}")
        return
    try:
        sync_directory(directory)
    except (OSError, MemoryError) as error:
        report_error(f"active journal directory sync unconfirmed: {error}")


_PIPE_SLOTS = ctypes.c_int * 2
_PIPE2 = ctypes.CDLL(None, use_errno=True).pipe2
_PIPE2.argtypes = (_PIPE_SLOTS, ctypes.c_int)
_PIPE2.restype = ctypes.c_int
PIPE_READ_RETRY = frozenset((errno.EINTR, errno.EAGAIN, errno.EIO, errno.EPERM, errno.EACCES, errno.EBUSY,
                            errno.ENOSYS, errno.ENOSPC, errno.EBADF))


class PipeEnd:
    """Own a kernel result slot before pipe2 has any descriptor to return."""

    def __init__(self, slots: ctypes.Array, index: int, mode: str) -> None:
        self.slots = slots
        self.index = index
        self.mode = mode
        self.file = FileIO.__new__(FileIO)
        self.attached = False

    def fileno(self) -> int:
        if self.attached:
            return self.file.fileno()
        fd = self.slots[self.index]
        if fd < 0:
            raise ValueError("closed pipe end")
        return fd

    def close(self) -> None:
        fd = self.slots[self.index]
        if fd < 0:
            return
        if not self.attached:
            if self.file.closed:
                self.file.__init__(fd, self.mode)
            self.attached = True
        # FileIO consumes its FD inside the native close. Keep the same owner
        # even if close raises or Python is interrupted before clearing the slot.
        self.file.close()
        self.slots[self.index] = -1


def pipe_files(flags: int, inputs: ExitStack, writers: ExitStack, name: str,
               on_loss: Callable[[], None] | None = None,
               close_reader: Callable[[], None] | None = None) -> tuple[PipeEnd, PipeEnd]:
    """Write pipe2 results straight into slots held by preallocated owners."""
    slots = _PIPE_SLOTS(-1, -1)
    reader = PipeEnd(slots, 0, "rb")
    writer = PipeEnd(slots, 1, "wb")
    register_close(inputs, name + "-reader", reader.close, on_loss, close_reader)
    register_close(writers, name + "-writer", writer.close, on_loss)
    try:
        if _PIPE2(slots, flags):
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        return reader, writer
    except BaseException:
        try:
            close_transport(reader.close)
        finally:
            close_transport(writer.close)
        raise


class ImageJob:
    """Mutable attempt journal and private descriptor ownership for one guest."""

    def __init__(self, directory: Path, identity: Identity, capsule: Path,
                 cancellation: Cancellation | None = None, *, probe: bool = False) -> None:
        self.directory = directory
        self.artifacts = directory / "artifacts"
        self.identity = identity
        self.cancellation = cancellation or Cancellation()
        self.probe = probe
        self.outputs = ExitStack()
        self.inputs = ExitStack()
        self.capture_scope = ExitStack()
        self.active_directory = directory.parents[1]
        self.active = self.active_directory / "active.json"
        self.journal_paths = self.active, self.active_directory
        self.teardown = directory / "teardown.json"
        self.teardown_temporary = receipt_temporary(self.teardown)
        self.validation = directory / "transport-validation.json"
        self.validation_temporary = receipt_temporary(self.validation)
        self.state = {"schema": 1, "identity": asdict(identity), "caps": asdict(CAPS),
                      "launcher": process_identity(os.getpid()), "acquired_at": time.time(),
                      "stop_reason": "not started", "qemu_reaped": False,
                      "stream_budget": CAPS.stream_max,
                      "input_descriptor_closed": False, "overlay_descriptor_closed": False, "ended_at": None}
        if probe:
            self.fallback_fields = encode_diagnostic_fields(UNAVAILABLE_DIAGNOSTICS)
        self.stage_tail = None
        self.control_bytes = 0
        self.capture_lost = False
        self.observe_stages = True
        self.console_open = True
        self.probe_events: selectors.BaseSelector | None = None
        self.probe_artifact_events: selectors.BaseSelector | None = None
        with ExitStack() as inputs:
            on_loss = self.lose_diagnostics if probe else None
            capsule_file = FileIO(capsule, "rb", opener=lambda path, flags: os.open(path, flags | os.O_NOFOLLOW))
            register_close(inputs, "capsule", capsule_file.close, on_loss)
            self.capsule_fd = capsule_file.fileno()
            self.console_reader, self.console_writer = pipe_files(
                os.O_CLOEXEC | (os.O_NONBLOCK if probe else 0), inputs, inputs, "console",
                on_loss, self.close_console_reader if probe else None)
            self.release_console_reader = self.console_reader.close
            self.console_read = self.console_reader.fileno()
            self.console_write = self.console_writer.fileno()
            self.inputs = inputs.pop_all()

    def __enter__(self) -> ImageJob:
        return self

    def __exit__(self, _type, error, _traceback) -> None:
        containment_unknown = isinstance(error, ChildContainmentError)
        sync_error = None
        try:
            # Attempt every descriptor close even if an earlier close or sync fails.
            try:
                with self.outputs:
                    try:
                        self.capture_scope.close()
                    finally:
                        self.inputs.close()
                    self.state["input_descriptor_closed"] = True
            except FileSyncError as exc:
                sync_error = error = exc
            if not containment_unknown:
                try:
                    self.state["ended_at"] = time.time()
                except MemoryError:
                    pass  # The preallocated null timestamp records unavailable timing.
                if error is not None:
                    self.state["stop_reason"] = type(error).__name__
                    cause = error if isinstance(error, FileSyncError) else error.__cause__
                    if isinstance(cause, FileSyncError):
                        self.state["storage_errno"] = cause.errno
                receipt(self.teardown, self.state, temporary=self.teardown_temporary)
            if sync_error is not None:
                raise sync_error
        finally:
            # A failed receipt must not pin a safely closed attempt in the journal.
            if (not containment_unknown and self.state["overlay_descriptor_closed"]
                    and "overlay_inode" in self.state
                    and ("qemu" not in self.state or self.state["qemu_reaped"])):
                self.cancellation.safe_journal = self.journal_paths

    def lose_diagnostics(self) -> None:
        self.capture_lost = True

    def record_reaped(self, status: int) -> None:
        self.state.update(qemu_reaped=True, qemu_exit=status)

    def close_console_reader(self) -> None:
        self.release_console_reader()

    def overlay_created(self, disk_fd: int) -> None:
        """Journal ownership before any qemu-img or QEMU child can inherit it."""
        inode = os.fstat(disk_fd)
        self.state.update(overlay_fd=disk_fd, overlay_inode=[inode.st_dev, inode.st_ino])
        self.cancellation.safe_journal = None
        receipt(self.active, {
            "attempt": self.identity.attempt, "launcher": self.state["launcher"],
            "overlay_inode": self.state["overlay_inode"],
        })

    @staticmethod
    def _open_log(path: Path):
        return ExclusiveFile(path)

    def diagnostic_summary(self) -> dict:
        tail = self.stage_tail
        over_cap = self.control_bytes > CONTROL_LOG_LIMIT
        complete = not self.capture_lost and not over_cap and tail is not None and tail.complete
        return {
            "last_observed_stage": tail.last if tail is not None else None,
            "sequence_complete": complete,
            "capture_lost": not complete,
            "console_tail": tail.text() if tail is not None else "",
            "console_tail_truncated": over_cap or (tail is not None and tail.truncated),
            "control_bytes_received": self.control_bytes,
        }

    def prepare_probe_transport(self, writers: ExitStack) -> PipeEnd:
        """Register the artifact and serial streams before guest startup."""
        try:
            events = selectors.DefaultSelector()
            register_close(self.inputs, "console-selector", events.close, self.lose_diagnostics)
            stream_reader, stream_writer = pipe_files(
                os.O_CLOEXEC, self.inputs, writers, "artifact", self.lose_diagnostics)
            stream_read = stream_reader.fileno()
            for name, fd in (("stream", stream_read), ("console", self.console_read)):
                events.register(fd, selectors.EVENT_READ, name)
            # A stuck serial registration must not wake the artifact poll.
            artifact_events = selectors.DefaultSelector()
            register_close(self.inputs, "artifact-selector", artifact_events.close, self.lose_diagnostics)
            artifact_events.register(stream_read, selectors.EVENT_READ, "stream")
            self.probe_events = events
            self.probe_artifact_events = artifact_events
            self.stage_tail = optional(self.lose_diagnostics, StageTail)
        except Exception as error:
            # The pre-commit OSError path cannot publish an outcome for this setup failure.
            raise OSError("probe transport setup failed: " + str(error)) from error
        return stream_writer

    def read_console(self, fd: int) -> bool:
        """Consume one nonblocking serial read and report EOF."""
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            return True
        self.control_bytes += len(chunk)
        tail = self.stage_tail
        if self.observe_stages and tail is not None:
            self.observe_stages = bool(optional(self.lose_diagnostics, tail.observe, chunk))
        return False

    def drain(self, events: selectors.BaseSelector) -> None:
        if not self.console_open:
            return
        for key in events.get_map().values():
            if key.data == "stream":
                continue
            # The serial pipe is nonblocking and QEMU has been reaped.
            for _ in range(8):
                if self.read_console(key.fd):
                    break
            else:
                self.lose_diagnostics()

    def register_measure_transport(self, events: selectors.BaseSelector, process: subprocess.Popen) -> None:
        for name, pipe in (("stream", process.stdout), ("diagnostic", process.stderr),
                           ("console", self.console_read)):
            events.register(pipe, selectors.EVENT_READ, name)

    def prepare_capture(self) -> None:
        """Own selectors and output files before the guest can start."""
        if not self.probe:
            events = selectors.DefaultSelector()
            register_close(self.capture_scope, "measurement-selector", events.close)
            self.probe_events = events
        on_loss = self.lose_diagnostics if self.probe else None
        self.capture_counts = {"stream": 0, "console": 0, "diagnostic": 0}
        self.capture_read_errors = dict.fromkeys(self.capture_counts, 0)
        self.capture_buffer = ctypes.create_string_buffer(1024 * 1024)
        self.capture_hashes = {}
        self.capture_files = {}
        for name in (("stream",) if self.probe else ("stream", "diagnostic", "console")):
            output = self._open_log(self.directory / (name + ".partial"))
            digest = hashlib.sha256()
            self.capture_hashes[name] = digest
            register_close(self.outputs, name + "-capture", output.close, on_loss,
                           before_close=partial(sync_output, output, digest, self.cancellation.check))
            output.open()
            self.capture_files[name] = output

    def capture(self, process: subprocess.Popen, seconds: int) -> None:
        """Capture bounded guest streams without echoing them to a terminal."""
        self.state.update(qemu=process_identity(process.pid), started_at=time.time(),
                          stop_reason="running")
        receipt(self.directory / "started.json", self.state)
        receipt(self.active, {
            "attempt": self.identity.attempt, "launcher": self.state["launcher"],
            "qemu": self.state["qemu"], "overlay_inode": self.state["overlay_inode"],
        })
        on_loss = self.lose_diagnostics if self.probe else None
        close_transport(self.console_writer.close, on_loss)
        end = time.monotonic() + seconds
        next_priority_check = 0.0
        console_retry_at = None
        counts = self.capture_counts
        with self.capture_scope:
            events = self.probe_events
            assert events is not None
            if not self.probe:
                self.register_measure_transport(events, process)
            files = self.capture_files
            stream_open = True
            try:
                while (stream_open if self.probe else events.get_map()) or poll_owned(process, self.record_reaped) is None:
                    self.cancellation.check()
                    now = time.monotonic()
                    if now >= end:
                        command = "image guest"
                        if self.probe:
                            try:
                                stage = self.stage_tail.last if self.stage_tail is not None else None
                                command = f"image guest (last stage: {stage or 'none seen'})"
                            except Exception:
                                self.capture_lost = True
                        raise subprocess.TimeoutExpired(command, seconds)
                    if now >= next_priority_check and poll_owned(process, self.record_reaped) is None:
                        try:
                            self.state["qemu_priority"] = process_priority(process.pid, self.cancellation)
                        except (FileNotFoundError, ProcessLookupError, IOPriorityError):
                            if poll_owned(process, self.record_reaped) is None:
                                raise
                        next_priority_check = now + 5
                    if console_retry_at is not None and now >= console_retry_at:
                        console_retry_at = None
                        assert self.probe_events is not None
                        try:
                            self.probe_events.unregister(self.console_read)
                        except Exception:
                            self.capture_lost = True
                    try:
                        ready = events.select(timeout=min(POLL_SECONDS, end - now))
                    except InterruptedError:
                        continue
                    self.cancellation.check()
                    for event, _mask in ready:
                        self.cancellation.check()
                        name = event.data
                        if self.probe and name == "console":
                            if self.console_open:
                                try:
                                    self.console_open = not self.read_console(event.fd)
                                except Exception:
                                    self.console_open = False
                                    self.capture_lost = True
                                if not self.console_open:
                                    try:
                                        events.unregister(event.fileobj)
                                    except Exception:
                                        self.capture_lost = True
                                        assert self.probe_artifact_events is not None
                                        events = self.probe_artifact_events
                                        console_retry_at = time.monotonic() + POLL_SECONDS
                            continue
                        try:
                            chunk = read_once(event.fd, self.capture_buffer)
                        except OSError as error:
                            self.capture_read_errors[name] += 1
                            if error.errno not in PIPE_READ_RETRY or self.capture_read_errors[name] >= IO_ATTEMPTS:
                                raise StreamError(f"required {name} pipe read failed") from error
                            # Try again only on a new readiness observation.
                            continue
                        self.capture_read_errors[name] = 0
                        if not chunk:
                            if name == "stream":
                                stream_open = False
                            events.unregister(event.fileobj)
                            continue
                        counts[name] += len(chunk)
                        if (counts["stream"] > min(CAPS.stream_max, self.state["stream_budget"])
                                or counts["console"] + counts["diagnostic"] > CONTROL_LOG_LIMIT):
                            raise StreamError("image return stream or log budget exceeded")
                        files[name].write(chunk)
                        self.capture_hashes[name].update(chunk)
                    # Fixed caps bound growth between these observations.
                    retry_check(self.capture_headroom, sum(counts.values()))
                wait(process, end, self.cancellation, self.record_reaped)
                if self.probe:
                    try:
                        self.drain(events)
                    except Exception:
                        self.capture_lost = True
            finally:
                self.state["stream_bytes"] = counts["stream"]

    def capture_headroom(self, bytes_received: int) -> None:
        self.cancellation.check()
        overlay = Path(f"/proc/self/fd/{self.state['overlay_fd']}")
        remaining_overlay = max(0, CAPS.overlay_max - overlay.stat().st_blocks * 512)
        disk_headroom(((Path(self.state["overlay_directory"]), remaining_overlay),
                       (self.directory, 49 * GIB - self.state["retained_bytes"] - bytes_received)))


def check_rewrite_space(output: ExclusiveFile) -> int:
    size = os.fstat(output.fileno()).st_size
    disk_headroom(((output.path.parent, size),))
    return size


def sync_output(output: ExclusiveFile, digest, checkpoint: Callable[[], None]) -> None:
    """Sync output only after the child has been stopped and reaped."""
    if output.fileno() < 0:
        return
    retry_io(output.flush, recover=True)
    try:
        sync_file(output.fileno())
    except FileSyncError as error:
        if not can_rewrite(error):
            raise
        size = retry_check(check_rewrite_space, output)
        member = Member(output.path.name, size, digest.hexdigest())
        with positioned_open(output.path) as source:
            def replay(fd: int) -> None:
                transfer(source, fd, member, checkpoint)
                if source.read(1):
                    raise StreamError("capture length changed during sync recovery")

            rewrite_file(output.path, replay)
