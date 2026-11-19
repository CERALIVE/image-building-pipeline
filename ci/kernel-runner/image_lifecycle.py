"""Private pipes, receipts and owned-resource reconciliation for image guests."""

from __future__ import annotations

from dataclasses import asdict
from contextlib import ExitStack, contextmanager
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
from typing import BinaryIO, TextIO
import uuid

from image_resources import CAPS, GIB, AdmissionError, disk_headroom, process_priority
from image_stages import StageTail, optional
from image_stream import CONTROL_LOG_LIMIT, Identity, StreamError
from vm_process import POLL_SECONDS, STOP_SIGNALS, Cancelled, Cancellation, poll_owned, run, wait

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
            self.file.close()

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
    """Diagnostics must not affect an already committed exit code."""
    try:
        os.write(2, f"kernel runner: {error}\n".encode(errors="backslashreplace"))
    except BaseException:
        return  # There may be no stderr reader.


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


class ImageJob:
    """Mutable attempt journal and private descriptor ownership for one guest."""

    def __init__(self, directory: Path, identity: Identity, capsule: Path,
                 cancellation: Cancellation | None = None, *, probe: bool = False) -> None:
        self.directory = directory
        self.identity = identity
        self.cancellation = cancellation or Cancellation()
        self.probe = probe
        self.console_read = self.console_write = -1
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
        with ExitStack() as inputs:
            self.capsule_fd = os.open(capsule, os.O_RDONLY | os.O_NOFOLLOW)
            inputs.callback(os.close, self.capsule_fd)
            self.console_read, self.console_write = os.pipe2(os.O_NONBLOCK) if probe else os.pipe()
            if probe:
                inputs.callback(optional, self.lose_diagnostics, self.close_console_writer)
                try:
                    self.probe_console_reader = FileIO(self.console_read, "rb")
                except (MemoryError, OSError):
                    optional(self.lose_diagnostics, os.close, self.console_read)
                    raise
                # The same owner closes the fd if the optional callback fails at entry.
                inputs.callback(optional, self.lose_diagnostics, self.probe_console_reader.close)
                inputs.callback(optional, self.lose_diagnostics, self.close_console_reader)
            else:
                inputs.callback(self._close_console, "console_read")
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
            self.active.unlink(missing_ok=True)
            sync_directory(self.active.parent)

    def lose_diagnostics(self) -> None:
        self.capture_lost = True

    def _close_console(self, end: str) -> None:
        fd = getattr(self, end)
        if fd >= 0:
            setattr(self, end, -1)
            if self.probe:
                optional(self.lose_diagnostics, os.close, fd)
                return
            os.close(fd)

    def close_console_reader(self) -> None:
        self.probe_console_reader.close()

    def close_console_writer(self) -> None:
        self._close_console("console_write")

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
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            return os.fdopen(fd, "wb")
        except Exception:
            os.close(fd)
            raise

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

    def prepare_probe_transport(self, writers: ExitStack) -> int:
        """Register the artifact and serial streams before guest startup."""
        try:
            events = self.inputs.enter_context(selectors.DefaultSelector())
            stream_read, stream_write = os.pipe2(os.O_CLOEXEC)
            self.inputs.callback(os.close, stream_read)
            writers.callback(os.close, stream_write)
            for name, fd in (("stream", stream_read), ("console", self.console_read)):
                events.register(fd, selectors.EVENT_READ, name)
            self.probe_events = events
            self.stage_tail = optional(self.lose_diagnostics, StageTail)
        except Exception as error:
            # The pre-commit OSError path cannot publish an outcome for this setup failure.
            raise OSError("probe transport setup failed: " + str(error)) from error
        return stream_write

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
        lose = self.lose_diagnostics
        if self.probe:
            optional(lose, self.close_console_writer)
        else:
            self.close_console_writer()
        end = time.monotonic() + seconds
        next_priority_check = 0.0
        counts = {"stream": 0, "console": 0, "diagnostic": 0}
        with ExitStack() as local:
            events = self.probe_events
            if not self.probe:
                events = local.enter_context(selectors.DefaultSelector())
                self.register_measure_transport(events, process)
            assert events is not None
            files = {}
            for name in (("stream",) if self.probe else ("stream", "diagnostic", "console")):
                output = self.outputs.enter_context(self._open_log(self.directory / (name + ".partial")))
                self.outputs.callback(sync_output, output)
                files[name] = output
            stream_open = True
            try:
                while (stream_open if self.probe else events.get_map()) or poll_owned(process) is None:
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
                    if now >= next_priority_check and poll_owned(process) is None:
                        try:
                            self.state["qemu_priority"] = process_priority(process.pid, self.cancellation)
                        except (FileNotFoundError, ProcessLookupError, subprocess.CalledProcessError):
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
                wait(process, end, self.cancellation)
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
