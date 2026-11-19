"""Reviewed staged source files bound to authenticated Sources entries."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
import re
import tempfile

from image_capsule import INPUT_LIMIT, digest_file, object_id, original_url
from image_policy import ArchivePolicy
from image_stream import StreamError


@dataclass(frozen=True, slots=True)
class SourceSelection:
    repository: str
    name: str
    version: str
    files: dict[str, str]


@dataclass(frozen=True, slots=True)
class SourceFile:
    filename: str
    directory: str
    sha256: str
    length: int
    url: str
    path: str


def source_selections(rows: list, policies: dict[str, ArchivePolicy]) -> tuple[SourceSelection, ...]:
    """Require exact source versions and explicit local paths for every source file."""
    selected = []
    identities = set()
    for row in rows:
        if (set(row) != {"repository", "name", "version", "files"}
                or row["repository"] != "debian-source"
                or row["repository"] not in policies
                or Path(policies[row["repository"]].index_path).name not in ("Sources.gz", "Sources.xz")
                or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", row["name"])
                or not re.fullmatch(r"[A-Za-z0-9.+:~_-]+", row["version"])
                or type(row["files"]) is not dict or not row["files"]
                or any(type(path) is not str or not Path(path).is_absolute()
                       or ".." in Path(path).parts for path in row["files"].values())):
            raise StreamError("invalid reviewed source selection")
        identity = (row["repository"], row["name"])
        if identity in identities:
            raise StreamError("duplicate reviewed source selection")
        identities.add(identity)
        selected.append(SourceSelection(**row))
    return tuple(sorted(selected, key=lambda source: (source.repository, source.name)))


def source_files(selection: SourceSelection, records: str, origin: str,
                 copy_local: Callable[[Path, Path, int], None]) -> tuple[SourceFile, ...]:
    """Check authenticated filenames and staged bytes using the producer's bounded copy."""
    files = []
    for record in records.splitlines():
        filename, digest, size, directory = record.split("\t")
        if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+:~_-]*", filename)
                or directory.startswith("/") or "://" in directory
                or any(part in ("", ".", "..") for part in directory.split("/"))):
            raise StreamError("signed source path is unsafe")
        url = original_url(origin + "/" + directory + "/" + filename)
        length = int(size)
        if not 0 < length <= INPUT_LIMIT:
            raise StreamError("invalid signed source size")
        files.append((filename, directory, object_id(digest), length, url))
    if {file[0] for file in files} != set(selection.files):
        raise StreamError("source file selection differs from authenticated stanza")
    verified = []
    with tempfile.TemporaryDirectory(prefix="source-discovery-") as temporary:
        for filename, directory, digest, length, url in sorted(files):
            path = selection.files[filename]
            source = Path(path)
            if (source.is_symlink() or not source.is_file()
                    or any(parent.is_symlink() for parent in source.parents)
                    or source.stat().st_size != length):
                raise StreamError("staged source must be a regular file of the authenticated size")
            snapshot = Path(temporary) / filename
            copy_local(source, snapshot, length)
            if digest_file(snapshot) != digest:
                raise StreamError("staged source differs from authenticated SHA256")
            verified.append(SourceFile(filename, directory, digest, length, url, path))
    return tuple(verified)
