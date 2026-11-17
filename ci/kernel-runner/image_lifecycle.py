"""Private pipes, receipts and owned-resource reconciliation for image guests."""

from __future__ import annotations

from dataclasses import asdict
from contextlib import contextmanager
from functools import partial
import json
import os
from pathlib import Path
import selectors
import subprocess
import time
import tempfile
import uuid

from image_resources import CAPS, GIB, AdmissionError, disk_headroom
from image_stream import CONTROL_LOG_LIMIT, Identity, StreamError

@contextmanager
def job_disk(base: Path, image_job=None):
    """Shared anonymous disk lifecycle used by vm.py's kernel and image paths."""
    from vm import die_with_parent
    with tempfile.TemporaryFile(prefix="job-", dir=base.parent) as overlay_file:
        disk_fd = overlay_file.fileno()
        if image_job:
            image_job.overlay_created(disk_fd)
        overlay = Path(f"/proc/self/fd/{disk_fd}")
        subprocess.run(["qemu-img", "create", "-f", "qcow2", "-F", "qcow2",
                        "-b", str(base), str(overlay)], check=True,
                       pass_fds=(disk_fd,), preexec_fn=partial(die_with_parent, os.getpid()),
                       timeout=180)
        yield overlay, disk_fd

def process_identity(pid: int) -> str:
    text = (Path("/proc") / str(pid) / "stat").read_text()
    return f"{pid}:{text[text.rindex(')') + 2:].split()[19]}"


def receipt(path: Path, row: dict) -> None:
    temporary = path.parent / (".receipt-" + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as destination:
        json.dump(row, destination, sort_keys=True, indent=2)
        destination.write("\n")
        destination.flush()
        os.fsync(destination.fileno())
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


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


class ImageJob:
    """Mutable attempt journal and private descriptor ownership for one guest."""

    def __init__(self, directory: Path, identity: Identity, capsule: Path) -> None:
        self.directory = directory
        self.identity = identity
        self.capsule_fd = os.open(capsule, os.O_RDONLY | os.O_NOFOLLOW)
        self.console_read, self.console_write = os.pipe()
        self.state = {"schema": 1, "identity": asdict(identity), "caps": asdict(CAPS),
                      "launcher": process_identity(os.getpid()), "acquired_at": time.time(),
                      "stop_reason": "not started", "qemu_reaped": False,
                      "stream_budget": CAPS.stream_max,
                      "input_descriptor_closed": False, "overlay_descriptor_closed": False}

    def __enter__(self) -> ImageJob:
        return self

    def __exit__(self, _type, error, _traceback) -> None:
        os.close(self.capsule_fd)
        os.close(self.console_read)
        if self.console_write >= 0:
            os.close(self.console_write)
        self.state.update(input_descriptor_closed=True, ended_at=time.time())
        if error:
            self.state["stop_reason"] = type(error).__name__
        receipt(self.directory / "exit.json", self.state)

    def overlay_created(self, disk_fd: int) -> None:
        """Journal ownership before any qemu-img or QEMU child can inherit it."""
        inode = os.fstat(disk_fd)
        self.state.update(overlay_fd=disk_fd, overlay_inode=[inode.st_dev, inode.st_ino])
        receipt(self.directory.parents[1] / "active.json", {
            "attempt": self.identity.attempt, "launcher": self.state["launcher"],
            "overlay_inode": self.state["overlay_inode"],
        })

    def capture(self, process: subprocess.Popen, seconds: int) -> None:
        """Drain three bounded pipes without echoing guest bytes to a terminal."""
        self.state.update(qemu=process_identity(process.pid), started_at=time.time(),
                          stop_reason="running")
        receipt(self.directory / "started.json", self.state)
        receipt(self.directory.parents[1] / "active.json", {
            "attempt": self.identity.attempt, "launcher": self.state["launcher"],
            "qemu": self.state["qemu"], "overlay_inode": self.state["overlay_inode"],
        })
        os.close(self.console_write)
        self.console_write = -1
        end = time.monotonic() + seconds
        counts = {"stream": 0, "console": 0, "diagnostic": 0}
        with selectors.DefaultSelector() as events:
            files = {}
            for name, pipe in (("stream", process.stdout), ("diagnostic", process.stderr),
                               ("console", self.console_read)):
                events.register(pipe, selectors.EVENT_READ, name)
                fd = os.open(self.directory / (name + ".partial"),
                             os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                files[name] = os.fdopen(fd, "wb")
            try:
                while events.get_map():
                    if time.monotonic() >= end:
                        raise subprocess.TimeoutExpired("image guest", seconds)
                    for event, _mask in events.select(timeout=1):
                        name = event.data
                        fd = event.fileobj if type(event.fileobj) is int else event.fileobj.fileno()
                        chunk = os.read(fd, 1024 * 1024)
                        if not chunk:
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
                process.wait(timeout=max(0.1, end - time.monotonic()))
            finally:
                for output in files.values():
                    output.flush()
                    os.fsync(output.fileno())
                    output.close()
                self.state["stream_bytes"] = counts["stream"]
