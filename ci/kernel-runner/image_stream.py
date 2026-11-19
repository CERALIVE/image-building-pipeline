"""Bounded data-only image artifact protocol. Filenames belong to the controller."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import errno
import hashlib
import json
import os
from pathlib import Path
import re
from typing import BinaryIO, Callable, Final, Iterable, TypeAlias

JSONValue: TypeAlias = str | bool | int | float | None | list["JSONValue"] | dict[str, "JSONValue"]

LIMIT: Final = 16 * 1024**3
HEADER_LIMIT: Final = 4096
MANIFEST_LIMIT: Final = 65536
CONTROL_LOG_LIMIT: Final = 8 * 1024**2
BUILD_LOG_LIMIT: Final = 1024**3 - 16 * 1024**2
MAGIC: Final = b"CERALIVE_IMAGE_STREAM_V1\n"
IO_ATTEMPTS: Final = 3
RETRYABLE_IO: Final = frozenset((errno.EACCES, errno.EPERM, errno.EBUSY, errno.EIO, errno.ENOSPC, errno.EBADF))
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


def retry_io(operation, *args, recover: bool = False, **kwargs):
    """Retry safe operations at most three times including the first call."""
    for attempt in range(IO_ATTEMPTS):
        try:
            return operation(*args, **kwargs)
        except OSError as error:
            if (attempt + 1 == IO_ATTEMPTS or not (
                    isinstance(error, InterruptedError) or error.errno == errno.EINTR
                    or recover and error.errno in RETRYABLE_IO)):
                raise


def write_all(destination: BinaryIO | int, data: bytes) -> None:
    """Only retry the unwritten bytes of an unbuffered regular file."""
    remaining = memoryview(data)
    while remaining:
        if isinstance(destination, int):
            written = retry_io(os.write, destination, remaining, recover=True)
        else:
            written = retry_io(destination.write, remaining, recover=True)
        if not written:
            raise OSError(errno.EIO, "file write made no progress")
        remaining = remaining[written:]


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
    line = retry_io(source.readline, HEADER_LIMIT + 1, recover=True)
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
             checkpoint: Callable[[], None] | None = None, *, decoding: bool = False) -> int:
    """Hash while copying exactly the declared length, with bounded memory."""
    digest = hashlib.sha256()
    remaining = member.length
    written = 0
    while remaining:
        if checkpoint is not None:
            checkpoint()
        size = min(1024 * 1024, remaining)
        chunk = retry_io(source.read, size, recover=True) if decoding else source.read(size)
        if not chunk:
            raise StreamError("truncated artifact")
        if decoding:
            write_all(destination, chunk)
            written += len(chunk)
        else:
            written += destination.write(chunk) or 0
        digest.update(chunk)
        remaining -= len(chunk)
    if digest.hexdigest() != member.sha256:
        raise StreamError("artifact digest mismatch")
    return written


def decode(source: BinaryIO, directory: Path, expected: Identity,
           checkpoint: Callable[[], None] | None = None) -> tuple[Member, ...]:
    """Decode only fixed IDs into exclusive private files; never extract an archive."""
    if retry_io(source.read, len(MAGIC), recover=True) != MAGIC:
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
            transfer(source, manifest_bytes, member, decoding=True)
            try:
                manifest = json.loads(manifest_bytes.getvalue(), object_pairs_hook=unique_object)
            except ValueError as exc:
                raise StreamError("invalid terminal manifest") from exc
            if manifest != {"schema": 1, "identity": asdict(expected),
                            "members": [asdict(item) for item in members]}:
                raise StreamError("terminal manifest identity or inventory mismatch")
            if not members or retry_io(source.read, 1, recover=True):
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
        with retry_io(open, directory / member.id, "xb", buffering=0,
                      opener=lambda path, flags: os.open(path, flags, 0o600), recover=True) as output:
            transfer(source, output, member, checkpoint, decoding=True)
            retry_io(os.fsync, output.fileno(), recover=True)
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
        mark("member_header_end", destination.write(header) or 0)
        mark("member_body_begin", member.length)
        if isinstance(value, Path):
            with value.open("rb") as source:
                written = transfer(source, destination, member)
        else:
            written = destination.write(value) or 0
        mark("member_body_written", written)

    mark("magic_write_begin", len(MAGIC))
    mark("magic_written", destination.write(MAGIC) or 0)
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
