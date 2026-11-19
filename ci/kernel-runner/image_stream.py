"""Bounded data-only image artifact protocol. Filenames belong to the controller."""

from __future__ import annotations

from contextlib import contextmanager
import ctypes
from dataclasses import asdict, dataclass
import errno
import hashlib
from io import BufferedReader, FileIO, RawIOBase
import json
import os
from pathlib import Path
import re
import stat
import struct
from typing import BinaryIO, Callable, Final, Iterable, TypeAlias
import uuid

JSONValue: TypeAlias = str | bool | int | float | None | list["JSONValue"] | dict[str, "JSONValue"]

LIMIT: Final = 16 * 1024**3
HEADER_LIMIT: Final = 4096
MANIFEST_LIMIT: Final = 65536
CONTROL_LOG_LIMIT: Final = 8 * 1024**2
BUILD_LOG_LIMIT: Final = 1024**3 - 16 * 1024**2
MAGIC: Final = b"CERALIVE_IMAGE_STREAM_V1\n"
IO_ATTEMPTS: Final = 3
CHECK_RETRY: Final = frozenset((errno.EINTR, errno.EAGAIN, errno.EIO))
RETRYABLE_IO: Final = frozenset((errno.EACCES, errno.EPERM, errno.EBUSY, errno.EIO, errno.ENOSPC,
                               errno.EBADF, errno.ENOSYS, errno.EAGAIN, errno.EDQUOT))
UNSUPPORTED_SYNC: Final = frozenset((errno.ENOSYS, errno.EINVAL, errno.EOPNOTSUPP, errno.ENOTSUP, errno.EROFS))
_LIBC = ctypes.CDLL(None, use_errno=True)
_FSYNC = _LIBC.fsync
_FSYNC.argtypes = (ctypes.c_int,)
_FSYNC.restype = ctypes.c_int
_GETDENTS = _LIBC.getdents64
_GETDENTS.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t)
_GETDENTS.restype = ctypes.c_ssize_t
_READ = _LIBC.read
_READ.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t)
_READ.restype = ctypes.c_ssize_t
_OPEN = _LIBC.open
_OPEN.argtypes = (ctypes.c_char_p, ctypes.c_int)
_OPEN.restype = ctypes.c_int
_OPENAT = _LIBC.openat
_OPENAT.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int)
_OPENAT.restype = ctypes.c_int
_PREAD = _LIBC.pread
_PREAD.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int64)
_PREAD.restype = ctypes.c_ssize_t
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


def report_error(error: BaseException | str) -> None:
    """Keep stderr backpressure out of receipt publication and launcher exit."""
    fd = None
    try:
        message = f"kernel runner: {error}\n".encode(errors="backslashreplace")
        # Reopen so setting nonblocking doesn't change the caller's descriptor.
        fd = os.open("/proc/self/fd/2", os.O_WRONLY | os.O_APPEND | os.O_NONBLOCK | os.O_NOCTTY | os.O_CLOEXEC)
        os.write(fd, message[:4096])
    except BaseException:
        pass
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except (OSError, MemoryError):
                pass


def close_checked(fd: int, *, completed: bool) -> None:
    """Report a late close failure without replacing an earlier error."""
    try:
        os.close(fd)
    except OSError as error:
        report_error(error)
        if completed:
            raise


def list_directory(path: Path, *, omit_open_fd: bool = False) -> list[str]:
    """Return a complete Linux directory scan, preserving ENOENT from getdents."""
    # glibc readdir treats an ENOENT from getdents as end of directory.
    # A safety check must distinguish a dead directory from normal EOF.
    buffer = ctypes.create_string_buffer(32 * 1024)
    fd = open_check(path, os.O_DIRECTORY)
    completed = False
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
        completed = True
        return names
    finally:
        close_checked(fd, completed=completed)


def retry_check(operation, *args, disappearing: bool = False):
    """Restart a read-only observation, discarding any incomplete result."""
    for attempt in range(IO_ATTEMPTS):
        try:
            return operation(*args)
        except OSError as error:
            retryable = error.errno in CHECK_RETRY or disappearing and error.errno in (errno.ENOENT, errno.ESRCH)
            if not retryable or attempt + 1 == IO_ATTEMPTS:
                raise


def open_check(path: Path, flags: int = 0, *, dir_fd: int | None = None) -> int:
    """Expose interrupted opens to the check that owns the complete observation."""
    name = os.fsencode(path)
    if b"\0" in name:
        raise ValueError("embedded null byte in observation path")
    flags |= os.O_RDONLY | os.O_CLOEXEC
    fd = _OPEN(name, flags) if dir_fd is None else _OPENAT(dir_fd, name, flags)
    if fd < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), path)
    return fd


def read_once(fd: int, buffer) -> bytes:
    size = _READ(fd, buffer, len(buffer))
    if size < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    return ctypes.string_at(buffer, size)


def read_check(path: Path, limit: int = 1024 * 1024) -> bytes:
    """Read a metadata file once. Its outer check owns retries, including EINTR."""
    buffer = ctypes.create_string_buffer(64 * 1024)
    result = bytearray()
    fd = open_check(path)
    completed = False
    try:
        while chunk := read_once(fd, buffer):
            result.extend(chunk)
            if len(result) > limit:
                raise StreamError("observation exceeded metadata limit")
        data = bytes(result)
        completed = True
        return data
    finally:
        close_checked(fd, completed=completed)


def read_check_text(path: Path) -> str:
    return read_check(path).decode("utf-8")


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


class FileSyncError(OSError):
    """The file may have lost data and cannot be synced again as recovery."""


def sync_once(fd: int) -> None:
    """Expose even EINTR so a regular file is never synced twice."""
    if _FSYNC(fd) == -1:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def sync_file(fd: int, *, directory: bool = False, recover: bool = True,
              terminal_budget=None) -> None:
    """Sync data or report unsupported durability."""
    try:
        if directory:
            retry_io(os.fsync, fd, recover=recover, no_retry=UNSUPPORTED_SYNC)
        elif terminal_budget is not None:
            # Reserve the call at the sync boundary so a late exception cannot refund it.
            terminal_budget.exit_sync_calls += 1; sync_once(fd)
        else:
            try:
                sync_once(fd)
            except OSError as error:
                if error.errno != errno.EINTR:
                    raise
                sync_once(fd)
    except OSError as error:
        if error.errno not in UNSUPPORTED_SYNC:
            if directory:
                raise
            raise FileSyncError(error.errno, "fsync failed") from error
        report_error("durability=unsupported")


def can_rewrite(error: FileSyncError) -> bool:
    return error.errno in RETRYABLE_IO


class PositionedReader(RawIOBase):
    """Keep the raw offset private. Retry only a read that made no progress."""

    def __init__(self, fd: int, *, checked: bool = False) -> None:
        self.fd = fd
        self.offset = 0
        self.checked = checked

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def seek(self, offset: int, whence: int = os.SEEK_SET) -> int:
        if whence == os.SEEK_CUR:
            offset += self.offset
        elif whence == os.SEEK_END:
            info = os.fstat(self.fd) if self.checked else retry_io(os.fstat, self.fd, recover=True)
            offset += info.st_size
        elif whence != os.SEEK_SET:
            raise ValueError("invalid seek origin")
        if offset < 0:
            raise OSError(errno.EINVAL, "negative input offset")
        self.offset = offset
        return offset

    def tell(self) -> int:
        return self.offset

    def readinto(self, buffer) -> int:
        read = 0
        raw = (ctypes.c_char * len(buffer)).from_buffer(buffer) if self.checked else None
        while read < len(buffer):
            if raw is not None:
                count = _PREAD(self.fd, ctypes.addressof(raw) + read, len(buffer) - read, self.offset + read)
                if count < 0:
                    error = ctypes.get_errno()
                    raise OSError(error, os.strerror(error))
            else:
                data = retry_io(os.pread, self.fd, len(buffer) - read, self.offset + read, recover=True)
                count = len(data)
                buffer[read:read + count] = data
            if not count:
                break
            read += count
        self.offset += read
        return read


@contextmanager
def positioned_open(path: Path, *, archive: bool = False, dir_fd: int | None = None,
                    nofollow: bool = False, checked: bool = False):
    """Own a regular input while exposing buffered reads over retry-safe pread."""
    fd = None
    completed = False
    try:
        flags = os.O_RDONLY | os.O_CLOEXEC | (os.O_NOFOLLOW if nofollow else 0)
        if checked:
            fd = open_check(path, flags, dir_fd=dir_fd)
        elif dir_fd is None:
            fd = retry_io(os.open, path, flags, recover=True)
        else:
            fd = retry_io(os.open, path, flags, dir_fd=dir_fd, recover=True)
        raw = PositionedReader(fd, checked=checked)
        with (raw if archive else BufferedReader(raw)) as stream:
            yield stream
        completed = checked
    finally:
        if fd is not None:
            close_checked(fd, completed=completed)


def write_all(destination: BinaryIO | int, data: bytes) -> int:
    """Write every byte without replaying any successfully written prefix."""
    offset = 0
    while offset < len(data):
        remaining = data if offset == 0 else memoryview(data)[offset:]
        if isinstance(destination, int):
            written = retry_io(os.write, destination, remaining, recover=True)
        else:
            written = retry_io(destination.write, remaining, recover=True)
        if written is None or not 0 < written <= len(remaining):
            raise OSError(errno.EIO, "file write made no progress")
        offset += written
    return offset


def read_input(path: Path) -> bytes:
    """Read a small seekable input using the same raw retry boundary."""
    with positioned_open(path) as source:
        return source.read()


def create_file(owner: ExclusiveFile) -> None:
    """Record ownership before returning from the exclusive open."""
    flags = (os.O_RDWR if owner.readable else os.O_WRONLY) | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
    for attempt in range(IO_ATTEMPTS):
        try:
            owner._fd = os.open(owner.path, flags, owner.mode)
        except OSError as error:
            if attempt + 1 == IO_ATTEMPTS or error.errno not in RETRYABLE_IO | CHECK_RETRY:
                raise
        else:
            return


def unlink_owned(path: Path) -> None:
    """Accept ENOENT only after confirming that the owned name is gone."""
    for attempt in range(IO_ATTEMPTS):
        try:
            os.unlink(path)
            return
        except FileNotFoundError:
            try:
                os.lstat(path)
            except FileNotFoundError:
                try:
                    if path.name not in list_directory(path.parent):
                        return
                except (OSError, MemoryError):
                    if attempt + 1 == IO_ATTEMPTS:
                        raise
            except (OSError, MemoryError):
                if attempt + 1 == IO_ATTEMPTS:
                    raise
            if attempt + 1 == IO_ATTEMPTS:
                raise
        except (OSError, MemoryError):
            if attempt + 1 == IO_ATTEMPTS:
                raise


class ExclusiveFile:
    """Preallocated owner for a raw exclusive output, with failure-only unlink."""

    def __init__(self, path: Path, mode: int = 0o600, *, readable: bool = False) -> None:
        self.path = path
        self.mode = mode
        self.readable = readable
        self._file = FileIO.__new__(FileIO)
        self._attached = False
        self._fd: int | None = None

    @property
    def fd(self) -> int | None:
        if self._attached:
            return -1 if self._file.closed else self._file.fileno()
        return self._fd

    def open(self) -> None:
        create_file(self)

    def __enter__(self) -> ExclusiveFile:
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        try:
            self.close()
        except OSError:
            # The kernel has already released the unbuffered file descriptor.
            pass
        finally:
            if exc_type is not None:
                self.discard()

    def discard(self) -> None:
        if self.fd is None:
            return
        try:
            self.close()
        except OSError as error:
            report_error(error)
        unlink_owned(self.path)
        self._fd = None
        self._attached = False

    def fileno(self) -> int:
        return self.fd if self.fd is not None else -1

    def write(self, data: bytes) -> int:
        write_all(self.fileno(), data)
        return len(data)

    def tell(self) -> int:
        return retry_io(os.lseek, self.fileno(), 0, os.SEEK_CUR, recover=True)

    def flush(self) -> None:
        """Unbuffered writes have nothing to flush."""

    def close(self) -> None:
        if self._fd is None:
            return
        if not self._attached:
            if self._file.closed:
                self._file.__init__(self._fd, "r+b" if self.readable else "wb")
            self._attached = True
        self._file.close()


def rewrite_file(path: Path, replay: Callable[[int], None]) -> None:
    """Replace an already-owned name only after a fresh inode has been synced."""
    temporary = path.with_name(f".rewrite-{path.name}-" + retry_io(uuid.uuid4, recover=True).hex)
    with ExclusiveFile(temporary) as output:
        output.open()
        replay(output.fileno())
        sync_file(output.fileno())
        retry_io(os.replace, temporary, path, recover=True)


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
    if not re.fullmatch(expected, retry_io(path.read_text, recover=True)):
        raise StreamError("artifact sidecar disagrees with host digest or canonical name")


def unique_object(pairs: list[tuple[str, JSONValue]]) -> dict[str, JSONValue]:
    """JSON duplicate keys must not change the meaning between validators."""
    result = {}
    for key, value in pairs:
        if key in result:
            raise StreamError("duplicate JSON key")
        result[key] = value
    return result


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


def transfer(source: BinaryIO, destination: BinaryIO | int, member: Member,
             checkpoint: Callable[[], None] | None = None) -> int:
    """Hash while copying exactly the declared length, with bounded memory."""
    digest = hashlib.sha256()
    remaining = member.length
    written = 0
    while remaining:
        if checkpoint is not None:
            checkpoint()
        size = min(1024 * 1024, remaining)
        chunk = source.read(size)
        if not chunk:
            raise StreamError("truncated artifact")
        written += write_all(destination, chunk)
        digest.update(chunk)
        remaining -= len(chunk)
    if digest.hexdigest() != member.sha256:
        raise StreamError("artifact digest mismatch")
    return written


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
            if manifest != {"schema": 1, "identity": asdict(expected),
                            "members": [asdict(item) for item in members]}:
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
        start = source.tell()
        path = directory / member.id
        with ExclusiveFile(path) as output:
            output.open()
            fd = output.fileno()
            transfer(source, fd, member, checkpoint)
            try:
                sync_file(fd)
            except FileSyncError as error:
                if not can_rewrite(error):
                    raise
                source.seek(start)
                rewrite_file(path, lambda fresh: transfer(source, fresh, member, checkpoint))
        members.append(member)


def encode(destination: BinaryIO, records: Iterable[tuple[str, bytes | Path]],
           identity: Identity, stages: Callable[[str, int], None] | None = None) -> None:
    """Guest producer; the host independently recomputes every record hash."""
    def mark(stage: str, count: int = 0) -> None:
        if stages is not None:
            stages(stage, count)

    def write_member(member: Member, value: bytes | Path) -> None:
        header = json.dumps(asdict(member), separators=(",", ":")).encode() + b"\n"
        mark("member_header_begin", len(header))
        mark("member_header_end", write_all(destination, header))
        mark("member_body_begin", member.length)
        if isinstance(value, Path):
            with value.open("rb") as source:
                written = transfer(source, destination, member)
        else:
            written = write_all(destination, value)
        mark("member_body_written", written)

    mark("magic_write_begin", len(MAGIC))
    mark("magic_written", write_all(destination, MAGIC))
    members = []
    for ordinal, (name, value) in enumerate(records, 1):
        mark("member_prepare_begin", ordinal)
        if isinstance(value, Path):
            with value.open("rb") as source:
                digest = hashlib.file_digest(source, "sha256").hexdigest()
            length = value.stat().st_size
        else:
            digest = hashlib.sha256(value).hexdigest()
            length = len(value)
        member = Member(name, length, digest)
        mark("member_prepare_end", ordinal)
        write_member(member, value)
        members.append(member)
    mark("member_prepare_begin", len(members) + 1)
    manifest = json.dumps({"schema": 1, "identity": asdict(identity),
                           "members": [asdict(item) for item in members]},
                          separators=(",", ":")).encode()
    terminal = Member("manifest", len(manifest), hashlib.sha256(manifest).hexdigest())
    mark("member_prepare_end", len(members) + 1)
    write_member(terminal, manifest)
    mark("flush_begin")
    destination.flush()
    mark("flush_end")
