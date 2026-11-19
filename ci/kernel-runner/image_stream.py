"""Bounded data-only image artifact protocol. Filenames belong to the controller."""

from __future__ import annotations

import ctypes
from dataclasses import asdict, dataclass
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
from typing import BinaryIO, Callable, Final, Iterable, TypeAlias

JSONValue: TypeAlias = str | bool | int | float | None | list["JSONValue"] | dict[str, "JSONValue"]

LIMIT: Final = 16 * 1024**3
HEADER_LIMIT: Final = 4096
MANIFEST_LIMIT: Final = 65536
CONTROL_LOG_LIMIT: Final = 8 * 1024**2
BUILD_LOG_LIMIT: Final = 1024**3 - 16 * 1024**2
MAGIC: Final = b"CERALIVE_IMAGE_STREAM_V1\n"
IO_ATTEMPTS: Final = 3
CHECK_RETRY: Final = frozenset((errno.EINTR, errno.EAGAIN, errno.EIO))
RETRYABLE_IO: Final = CHECK_RETRY | frozenset((errno.EACCES, errno.EPERM, errno.EBUSY, errno.ENOSPC,
                                              errno.EBADF, errno.ENOSYS, errno.EDQUOT))
_LIBC = ctypes.CDLL(None, use_errno=True)
_GETDENTS = _LIBC.getdents64
_GETDENTS.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t)
_GETDENTS.restype = ctypes.c_ssize_t
ARTIFACTS: Final = frozenset((
    "rootfs.tar", "rootfs.tar.sha256", "rootfs_a.ext4", "rootfs_b.ext4",
    "measurement.json", "packages.lock.json", "fetch.jsonl", "sealed-delivery.json",
    "resolved.json", "kernel-artifact.json", "resolved.config", "built-modules.txt",
    "kernel.SHA256SUMS", "boot.scr", "boot.scr.sha256", "build.log",
    "rootfs_a.reserve", "rootfs_b.reserve", "rootfs_a.header", "rootfs_b.header",
    "verification.json",
    "failure.json",
))


class StreamError(Exception):
    """Untrusted stream violates the fixed artifact contract."""


@dataclass(frozen=True, slots=True)
class Identity:
    attempt: str
    board: str
    commit: str
    epoch: int
    input_sha256: str

    def __post_init__(self) -> None:
        if (not re.fullmatch(r"[a-zA-Z0-9_-]{1,80}", self.attempt)
                or self.board not in ("rock-5b-plus", "orange-pi-5-plus")
                or not re.fullmatch(r"[0-9a-f]{40}", self.commit)
                or type(self.epoch) is not int or self.epoch < 0
                or not re.fullmatch(r"[0-9a-f]{64}", self.input_sha256)):
            raise StreamError("invalid host-selected identity")


@dataclass(frozen=True, slots=True)
class Member:
    id: str
    length: int
    sha256: str

def verify_sidecar(path: Path, member: Member) -> None:
    names = {"rootfs.tar": r"[0-9]{8}T[0-9]{6}Z[.]rootfs[.]tar", "boot.scr": r"boot[.]scr"}
    expected = re.escape(member.sha256) + r" [ *]" + names[member.id] + "\n"
    if not re.fullmatch(expected, path.read_text()):
        raise StreamError("artifact sidecar disagrees with host digest or canonical name")


def unique_object(pairs: list[tuple[str, JSONValue]]) -> dict[str, JSONValue]:
    """JSON duplicate keys must not change the meaning between validators."""
    result = {}
    for key, value in pairs:
        if key in result:
            raise StreamError("duplicate JSON key")
        result[key] = value
    return result


def exact_json(value, expected) -> bool:
    """Compare JSON records without treating booleans, integers and floats as equal."""
    if type(value) is not type(expected):
        return False
    if isinstance(expected, dict):
        return value.keys() == expected.keys() and all(exact_json(value[k], v) for k, v in expected.items())
    if isinstance(expected, list):
        return len(value) == len(expected) and all(exact_json(v, e) for v, e in zip(value, expected))
    return value == expected


def retry_io(operation, *args, recover: bool = False, no_retry: frozenset[int] = frozenset(), **kwargs):
    """Retry safe operations at most three times including the first call."""
    for attempt in range(IO_ATTEMPTS):
        try:
            return operation(*args, **kwargs)
        except OSError as error:
            if (error.errno in no_retry or attempt + 1 == IO_ATTEMPTS or not (
                    isinstance(error, InterruptedError) or error.errno == errno.EINTR
                    or recover and error.errno in RETRYABLE_IO)):
                raise


def list_directory(path: Path, *, omit_open_fd: bool = False) -> list[str]:
    """Return a complete Linux directory scan, preserving ENOENT from getdents."""
    # glibc readdir treats an ENOENT from getdents as end of directory.
    # A safety check must distinguish a dead directory from normal EOF.
    buffer = ctypes.create_string_buffer(32 * 1024)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        names = []
        while (length := _GETDENTS(fd, buffer, len(buffer))) > 0:
            batch = buffer.raw[:length]
            offset = 0
            while offset < length:
                record_size = struct.unpack_from("=H", batch, offset + 16)[0]
                if record_size < 20 or offset + record_size > length:
                    raise OSError(errno.EIO, "invalid getdents record", path)
                name = batch[offset + 19:offset + record_size].split(b"\0", 1)[0]
                if name not in (b".", b"..") and not (omit_open_fd and name == str(fd).encode()):
                    names.append(os.fsdecode(name))
                offset += record_size
        if length < 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), path)
        return names
    finally:
        os.close(fd)


def retry_check(operation, *args, errors: frozenset[int] = CHECK_RETRY):
    """Restart a read-only observation, discarding any incomplete result."""
    for attempt in range(IO_ATTEMPTS):
        try:
            return operation(*args)
        except OSError as error:
            if error.errno not in errors or attempt + 1 == IO_ATTEMPTS:
                raise


def listed_entry(root: Path, relative: str) -> os.stat_result | None:
    """Prove absence by listing the parent, including each intermediate path."""
    parts = Path(relative).parts
    for index, name in enumerate(parts):
        if name not in list_directory(root):
            return None
        root = root / name
        info = root.lstat()
        if index == len(parts) - 1:
            return info
        if not stat.S_ISDIR(info.st_mode):
            raise StreamError("inventory ancestor is not a directory")
    raise ValueError("inventory entry must have a name")


def write_all(destination: BinaryIO | int, data: bytes) -> int:
    """Write every byte without replaying any successfully written prefix."""
    offset = 0
    while offset < len(data):
        remaining = data if offset == 0 else memoryview(data)[offset:]
        if isinstance(destination, int):
            written = retry_io(os.write, destination, remaining, recover=True)
        else:
            written = destination.write(remaining)
        if written is None or not 0 < written <= len(remaining):
            raise OSError(errno.EIO, "file write made no progress")
        offset += written
    return offset


def read_header(source: BinaryIO) -> Member:
    line = source.readline(HEADER_LIMIT + 1)
    if len(line) > HEADER_LIMIT or not line.endswith(b"\n"):
        raise StreamError("missing or oversized record header")
    try:
        row = json.loads(line, object_pairs_hook=unique_object)
        if (set(row) != {"id", "length", "sha256"}
                or type(row["id"]) is not str or type(row["length"]) is not int
                or not 0 <= row["length"] <= LIMIT
                or type(row["sha256"]) is not str
                or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"])):
            raise StreamError("invalid artifact header")
        return Member(**row)
    except (ValueError, TypeError) as exc:
        raise StreamError("invalid artifact JSON") from exc


def transfer(source: BinaryIO, destination: BinaryIO, member: Member,
             checkpoint: Callable[[], None] | None = None) -> None:
    """Hash while copying exactly the declared length, with bounded memory."""
    digest = hashlib.sha256()
    remaining = member.length
    while remaining:
        if checkpoint is not None:
            checkpoint()
        chunk = source.read(min(1024 * 1024, remaining))
        if not chunk:
            raise StreamError("truncated artifact")
        write_all(destination, chunk)
        digest.update(chunk)
        remaining -= len(chunk)
    if digest.hexdigest() != member.sha256:
        raise StreamError("artifact digest mismatch")


def decode(source: BinaryIO, directory: Path, expected: Identity,
           checkpoint: Callable[[], None] | None = None) -> tuple[Member, ...]:
    """Decode only fixed IDs into exclusive private files; never extract an archive."""
    if source.read(len(MAGIC)) != MAGIC:
        raise StreamError("invalid stream version")
    members: list[Member] = []
    seen = set()
    total = len(MAGIC)
    while True:
        member = read_header(source)
        total += member.length + HEADER_LIMIT
        if total > LIMIT:
            raise StreamError("artifact stream exceeds 16 GiB")
        if member.id == "manifest":
            if member.length > MANIFEST_LIMIT:
                raise StreamError("oversized terminal manifest")
            import io
            manifest_bytes = io.BytesIO()
            transfer(source, manifest_bytes, member)
            try:
                manifest = json.loads(manifest_bytes.getvalue(), object_pairs_hook=unique_object)
            except ValueError as exc:
                raise StreamError("invalid terminal manifest") from exc
            if not exact_json(manifest, {"schema": 1, "identity": asdict(expected),
                                         "members": [asdict(item) for item in members]}):
                raise StreamError("terminal manifest identity or inventory mismatch")
            if not members or source.read(1):
                raise StreamError("empty stream or trailing bytes")
            return tuple(members)
        if member.id not in ARTIFACTS or member.id in seen:
            raise StreamError("duplicate or unknown artifact ID")
        if member.id in ("rootfs_a.ext4", "rootfs_b.ext4") and member.length != 4096 * 1024**2:
            raise StreamError("returned slot has wrong frozen geometry")
        if member.id == "build.log" and member.length > BUILD_LOG_LIMIT:
            raise StreamError("returned build log exceeds its budget")
        if member.id in ("verification.json", "failure.json") and member.length > 1024**2:
            raise StreamError("oversized verification or failure receipt")
        if member.id not in ("rootfs.tar", "rootfs_a.ext4", "rootfs_b.ext4", "build.log") and member.length > 16 * 1024**2:
            raise StreamError("oversized artifact metadata")
        if member.id == "rootfs.tar" and member.length > 3_500_000_000:
            raise StreamError("rootfs tar exceeds unchanged size ceiling")
        seen.add(member.id)
        fd = os.open(directory / member.id, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as output:
            transfer(source, output, member, checkpoint)
            output.flush()
            os.fsync(output.fileno())
        members.append(member)


def encode(destination: BinaryIO, records: Iterable[tuple[str, bytes | Path]],
           identity: Identity) -> None:
    """Guest producer; the host independently recomputes every record hash."""
    write_all(destination, MAGIC)
    members = []
    for name, value in records:
        if isinstance(value, Path):
            with value.open("rb") as source:
                digest = hashlib.file_digest(source, "sha256").hexdigest()
            length = value.stat().st_size
        else:
            digest = hashlib.sha256(value).hexdigest()
            length = len(value)
        member = Member(name, length, digest)
        write_all(destination, json.dumps(asdict(member), separators=(",", ":")).encode() + b"\n")
        if isinstance(value, Path):
            with value.open("rb") as source:
                transfer(source, destination, member)
        else:
            write_all(destination, value)
        members.append(member)
    manifest = json.dumps({"schema": 1, "identity": asdict(identity),
                           "members": [asdict(item) for item in members]},
                          separators=(",", ":")).encode()
    terminal = Member("manifest", len(manifest), hashlib.sha256(manifest).hexdigest())
    write_all(destination, json.dumps(asdict(terminal), separators=(",", ":")).encode() + b"\n")
    write_all(destination, manifest)
    destination.flush()
