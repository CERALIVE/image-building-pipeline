"""Private pipes, receipts and owned-resource reconciliation for image guests."""

from __future__ import annotations

from dataclasses import asdict
from contextlib import ExitStack, contextmanager
import ctypes
from functools import partial
from io import FileIO
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time
import tempfile
from typing import BinaryIO, Callable, TextIO
import uuid

from image_resources import CAPS, GIB, AdmissionError, disk_headroom, process_priority
from image_stages import StageTail, optional
from image_stream import CONTROL_LOG_LIMIT, Identity, StreamError
from vm_process import (
    POLL_SECONDS, STOP_SIGNALS, Cancelled, Cancellation, close_transport, poll_owned,
    register_close, run, wait,
)

UNAVAILABLE_DIAGNOSTICS = {
    "last_observed_stage": None,
    "sequence_complete": False,
    "capture_lost": True,
    "console_tail": "",
    "console_tail_truncated": False,
    "control_bytes_received": 0,
}


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
        close_transport(overlay_file.close)
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
        close_transport(partial(os.close, fd))


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
                 diagnostic: BaseException | None, probe: ImageJob | None = None) -> None:
        self.path = path
        self.row = row
        self.outcome = outcome
        self.temporary = path.parent / (".receipt-" + uuid.uuid4().hex)
        self.file: TextIO | BinaryIO | None = None
        self.probe = probe
        self.directory_fd: int | None = None
        self.renamed = False
        self.errors: list[BaseException] = [] if diagnostic is None else [diagnostic]

    def temp_open(self) -> None:
        self.file = open(
            self.temporary, "xb" if self.probe is not None else "x",
            encoding=None if self.probe is not None else "utf-8",
            opener=lambda name, flags: os.open(Path(name), flags, 0o600))

    def temp_write(self) -> None:
        assert self.file is not None
        if self.probe is None:
            json.dump(self.row, self.file, sort_keys=True, indent=2)
            self.file.write("\n")
            return
        # Encode the authoritative fields before trying optional diagnostics.
        # On an encoding fault, both fragments are already available as bytes.
        outcome = json.dumps(self.row, sort_keys=True, indent=2)[:-2].encode("ascii")
        fields = self.probe.fallback_fields
        try:
            fields = encode_diagnostic_fields(self.probe.diagnostic_summary())
        except Exception:
            pass
        self.file.write(outcome)
        self.file.write(fields)

    def temp_flush(self) -> None:
        assert self.file is not None
        self.file.flush()

    def file_sync(self) -> None:
        assert self.file is not None
        os.fsync(self.file.fileno())

    def file_close(self) -> None:
        if self.file is not None:
            close_transport(self.file.close)

    def temp_cleanup(self) -> None:
        if not self.renamed:
            self.temporary.unlink(missing_ok=True)

    def mask_block(self) -> None:
        if self.outcome is not None:
            self.outcome.begin_finalization()

    def rename(self) -> None:
        if self.outcome is not None and self.row["stop_reason"] != "cancelled":
            self.outcome.check()
            if signal.sigpending().intersection(STOP_SIGNALS):
                raise Cancelled("runner cancelled")
        os.replace(self.temporary, self.path)
        self.renamed = True

    def dir_open(self) -> None:
        if self.renamed:
            self.directory_fd = os.open(self.path.parent, os.O_DIRECTORY)

    def dir_sync(self) -> None:
        if self.directory_fd is not None:
            os.fsync(self.directory_fd)

    def dir_close(self) -> None:
        if self.directory_fd is not None:
            close_transport(partial(os.close, self.directory_fd))

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
            diagnostic: BaseException | None = None, probe: ImageJob | None = None) -> None:
    transaction = Receipt(path, row, outcome, diagnostic, probe)
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
    """Keep stderr backpressure out of receipt publication and launcher exit."""
    try:
        message = f"kernel runner: {error}\n".encode(errors="backslashreplace")
        # Reopen so setting nonblocking doesn't change the caller's descriptor.
        sink = FileIO("/proc/self/fd/2", "ab",
                      opener=lambda path, flags: os.open(path, flags | os.O_NONBLOCK | os.O_NOCTTY))
        try:
            sink.write(message[:4096])
        finally:
            close_transport(sink.close)
    except BaseException:
        return


def reconcile(store: Path) -> None:
    active = store / "active.json"
    if not active.exists():
        return
    row = json.loads(active.read_text())
    for key in ("launcher", "qemu"):
        if key not in row:
            continue
        pid = int(row[key].split(":")[0])
        try:
            current = process_identity(pid)
            status = (Path("/proc") / str(pid) / "stat").read_text()
        except FileNotFoundError:
            continue
        if current == row[key] and status[status.rindex(")") + 2:].split()[0] != "Z":
            raise AdmissionError(f"previous owned {key} still running: {row[key]}")
    owned = tuple(row["overlay_inode"])
    for process in Path("/proc").iterdir():
        if not process.name.isdecimal():
            continue
        try:
            descriptors = list((process / "fd").iterdir())
        except (FileNotFoundError, PermissionError):
            continue
        for descriptor in descriptors:
            try:
                info = descriptor.stat()
            except (FileNotFoundError, PermissionError):
                continue
            if (info.st_dev, info.st_ino) == owned:
                raise AdmissionError(f"previous owned overlay still held by {descriptor}")
    receipt(store / (row["attempt"] + ".reconciled.json"), {
        **row, "stop_reason": "previous launcher interrupted; guest cleanup unknown",
        "overlay_descriptors_closed": True, "reconciled_at": time.time(),
    })
    active.unlink()
    sync_directory(store)


_PIPE_SLOTS = ctypes.c_int * 2
_PIPE2 = ctypes.CDLL(None, use_errno=True).pipe2
_PIPE2.argtypes = (_PIPE_SLOTS, ctypes.c_int)
_PIPE2.restype = ctypes.c_int


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
            self.active.unlink(missing_ok=True)
            sync_directory(self.active.parent)

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
        receipt(self.active, {
            "attempt": self.identity.attempt, "launcher": self.state["launcher"],
            "overlay_inode": self.state["overlay_inode"],
        })

    @staticmethod
    def _open_log(path: Path):
        return open(path, "xb", opener=lambda name, flags: os.open(name, flags, 0o600))

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
        counts = {"stream": 0, "console": 0, "diagnostic": 0}
        with ExitStack() as local:
            events = self.probe_events
            if not self.probe:
                events = selectors.DefaultSelector()
                register_close(local, "measurement-selector", events.close)
                self.register_measure_transport(events, process)
            assert events is not None
            files = {}
            for name in (("stream",) if self.probe else ("stream", "diagnostic", "console")):
                output = self._open_log(self.directory / (name + ".partial"))
                register_close(self.outputs, name + "-capture", output.close, on_loss,
                               before_close=partial(sync_output, output))
                files[name] = output
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
                        except (FileNotFoundError, ProcessLookupError, subprocess.CalledProcessError):
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
                            chunk = os.read(event.fd, 1024 * 1024)
                        except InterruptedError:
                            continue
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
                    # Fixed caps bound growth between these observations.
                    overlay = Path(f"/proc/self/fd/{self.state['overlay_fd']}")
                    remaining_overlay = max(0, CAPS.overlay_max - overlay.stat().st_blocks * 512)
                    disk_headroom(((Path(self.state["overlay_directory"]), remaining_overlay),
                                   (self.directory, 49 * GIB - self.state["retained_bytes"] - sum(counts.values()))))
                wait(process, end, self.cancellation, self.record_reaped)
                if self.probe:
                    try:
                        self.drain(events)
                    except Exception:
                        self.capture_lost = True
            finally:
                self.state["stream_bytes"] = counts["stream"]


def sync_output(output) -> None:
    """Sync output only after the child has been stopped and reaped."""
    output.flush()
    os.fsync(output.fileno())
