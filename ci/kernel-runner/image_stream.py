"""Bounded data-only image artifact protocol. Filenames belong to the controller."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re
from typing import BinaryIO, Final, Iterable, TypeAlias

JSONValue: TypeAlias = str | bool | int | float | None | list["JSONValue"] | dict[str, "JSONValue"]

LIMIT: Final = 16 * 1024**3
HEADER_LIMIT: Final = 4096
MANIFEST_LIMIT: Final = 65536
CONTROL_LOG_LIMIT: Final = 8 * 1024**2
BUILD_LOG_LIMIT: Final = 1024**3 - 16 * 1024**2
MAGIC: Final = b"CERALIVE_IMAGE_STREAM_V1\n"
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


def transfer(source: BinaryIO, destination: BinaryIO, member: Member) -> None:
    """Hash while copying exactly the declared length, with bounded memory."""
    digest = hashlib.sha256()
    remaining = member.length
    while remaining:
        chunk = source.read(min(1024 * 1024, remaining))
        if not chunk:
            raise StreamError("truncated artifact")
        destination.write(chunk)
        digest.update(chunk)
        remaining -= len(chunk)
    if digest.hexdigest() != member.sha256:
        raise StreamError("artifact digest mismatch")


def decode(source: BinaryIO, directory: Path, expected: Identity) -> tuple[Member, ...]:
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
        fd = os.open(directory / member.id, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as output:
            transfer(source, output, member)
            output.flush()
            os.fsync(output.fileno())
        members.append(member)


def encode(destination: BinaryIO, records: Iterable[tuple[str, bytes | Path]],
           identity: Identity) -> None:
    """Guest producer; the host independently recomputes every record hash."""
    destination.write(MAGIC)
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
        destination.write(json.dumps(asdict(member), separators=(",", ":")).encode() + b"\n")
        if isinstance(value, Path):
            with value.open("rb") as source:
                transfer(source, destination, member)
        else:
            destination.write(value)
        members.append(member)
    manifest = json.dumps({"schema": 1, "identity": asdict(identity),
                           "members": [asdict(item) for item in members]},
                          separators=(",", ":")).encode()
    terminal = Member("manifest", len(manifest), hashlib.sha256(manifest).hexdigest())
    destination.write(json.dumps(asdict(terminal), separators=(",", ":")).encode() + b"\n")
    destination.write(manifest)
    destination.flush()
