"""Typed, read-only image capsule: inventory plus digest-named regular objects."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import tarfile
from typing import BinaryIO, Callable, Final

from image_stream import ExclusiveFile, Identity, StreamError, retry_io, unique_object
from image_urls import InputURLError, canonical_url

INPUT_LIMIT: Final = 32 * 1024**3
KINDS: Final = frozenset(("source-bundle", "public-trust", "apt-metadata", "deb",
                         "pinned-source", "builder-image", "kernel-metadata", "artifact"))


@dataclass(frozen=True, slots=True)
class InputObject:
    sha256: str
    length: int
    kind: str
    urls: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Capsule:
    source_commit: str
    epoch: int
    board: str
    objects: tuple[InputObject, ...]
    source_bundle: str
    device_root: str
    directory: Path
    fetched_at: str


def digest_file(path: Path, checkpoint: Callable[[], None] | None = None) -> str:
    with path.open("rb") as source:
        if checkpoint is None:
            return hashlib.file_digest(source, "sha256").hexdigest()
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checkpoint()
            digest.update(chunk)
        return digest.hexdigest()


def object_id(value: str) -> str:
    if type(value) is not str or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise StreamError("invalid capsule object digest")
    return value


def original_url(value: str) -> str:
    try:
        return canonical_url(value)
    except InputURLError as exc:
        raise StreamError(str(exc)) from exc


def unpack(capsule: Path, directory: Path, expected: Identity) -> Capsule:
    """Guest-only import; paths and archive link semantics never cross this boundary."""
    if capsule.stat().st_size > INPUT_LIMIT or digest_file(capsule) != expected.input_sha256:
        raise StreamError("input capsule length or transport digest mismatch")
    retry_io(directory.mkdir, mode=0o700, recover=True)
    with tarfile.open(capsule, "r:") as archive:
        entries = archive.getmembers()
        if (len(entries) > 20000 or len({entry.name for entry in entries}) != len(entries)
                or any(not entry.isfile() or entry.issparse() for entry in entries)):
            raise StreamError("capsule requires unique nonsparse regular objects")
        inventories = [entry for entry in entries if entry.name == "inventory.json"]
        if len(inventories) != 1 or inventories[0].size > 1024 * 1024:
            raise StreamError("missing or oversized capsule inventory")
        source = archive.extractfile(inventories[0])
        if source is None:
            raise StreamError("unreadable capsule inventory")
        with source:
            row = json.load(source, object_pairs_hook=unique_object)
        if (set(row) != {"schema", "source_commit", "epoch", "board", "objects", "fetched_at",
                        "source_bundle", "device_root", "repositories"}
                or type(row["schema"]) is not int or row["schema"] != 1
                or type(row["epoch"]) is not int or type(row["objects"]) is not list
                or type(row["repositories"]) is not dict
                or (row["source_commit"], row["epoch"], row["board"])
                != (expected.commit, expected.epoch, expected.board)):
            raise StreamError("capsule source or board identity mismatch")
        fetched_at = datetime.strptime(row["fetched_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        if fetched_at > datetime.now(timezone.utc):
            raise StreamError("capsule prefetch completion time is in the future")
        objects = []
        urls = set()
        for item in row["objects"]:
            if (set(item) != {"sha256", "length", "kind", "urls"}
                    or item["kind"] not in KINDS or type(item["length"]) is not int
                    or not 0 < item["length"] <= INPUT_LIMIT or type(item["urls"]) is not list):
                raise StreamError("invalid typed capsule object")
            names = tuple(original_url(url) for url in item["urls"])
            if any(url in urls for url in names) or len(set(names)) != len(names):
                raise StreamError("ambiguous sealed URL mapping")
            urls.update(names)
            objects.append(InputObject(object_id(item["sha256"]), item["length"],
                                       item["kind"], names))
        ids = {item.sha256 for item in objects}
        if len(ids) != len(objects) or len(entries) != len(objects) + 1:
            raise StreamError("duplicate or extra capsule objects")
        for selected, kind in ((row["source_bundle"], "source-bundle"),
                               (row["device_root"], "public-trust")):
            if not any(item.sha256 == object_id(selected) and item.kind == kind for item in objects):
                raise StreamError("missing typed source or public device root")
        for item in objects:
            try:
                entry = archive.getmember("objects/" + item.sha256)
            except KeyError as exc:
                raise StreamError("missing capsule object") from exc
            if entry.size != item.length:
                raise StreamError("capsule inventory length mismatch")
            stream = archive.extractfile(entry)
            if stream is None:
                raise StreamError("unreadable capsule object")
            digest = hashlib.sha256()
            with stream, ExclusiveFile(directory / item.sha256, 0o400) as destination:
                destination.open()
                while chunk := stream.read(1024 * 1024):
                    digest.update(chunk)
                    destination.write(chunk)
                if digest.hexdigest() != item.sha256:
                    raise StreamError("capsule object hash mismatch")
    # Public repository trust is selected independently in the host job payload.
    # This document only describes deliveries; fetch/sealed.sh rechecks signatures.
    config = directory / "inventory.json"
    config.write_text(json.dumps(row) + "\n")
    config.chmod(0o400)
    return Capsule(row["source_commit"], row["epoch"], row["board"], tuple(objects),
                   row["source_bundle"], row["device_root"], directory, row["fetched_at"])


def verification_capsule(original: Path, artifacts: Path, destination: Path,
                         checkpoint: Callable[[], None] | None = None) -> dict[str, str]:
    """Host packs only selected regular data; no pathname or extraction from the guest."""
    selected = {}
    with tarfile.open(original, "r:") as source:
        header = source.getmember("inventory.json")
        if not header.isfile() or header.size > 1024 * 1024:
            raise StreamError("oversized verification input inventory")
        stream = source.extractfile(header)
        if stream is None:
            raise StreamError("missing input inventory")
        with stream:
            row = json.load(stream, object_pairs_hook=unique_object)
        objects = {item["sha256"]: item for item in row["objects"]
                   if item["kind"] in ("source-bundle", "public-trust", "apt-metadata", "kernel-metadata")}
        files = {}
        for file in artifacts.iterdir():
            if not file.is_file() or file.is_symlink():
                raise StreamError("returned artifact is not a controller-owned regular file")
            digest = digest_file(file, checkpoint)
            selected[file.name] = digest
            files[digest] = file
            objects.setdefault(digest, {"sha256": digest, "length": file.stat().st_size,
                                        "kind": "artifact", "urls": []})
        row["objects"] = list(objects.values())
        if sum(item["length"] for item in objects.values()) + 16 * 1024**2 > INPUT_LIMIT:
            raise StreamError("verification capsule exceeds the unchanged 32 GiB budget")
        with ExclusiveFile(destination) as output:
            output.open()
            with tarfile.open(fileobj=output, mode="w:", copybufsize=1024 * 1024) as target:
                import io
                data = json.dumps(row, separators=(",", ":")).encode()
                header = tarfile.TarInfo("inventory.json")
                header.size = len(data)
                target.addfile(header, io.BytesIO(data))
                for digest, item in objects.items():
                    header = tarfile.TarInfo("objects/" + digest)
                    header.size = item["length"]
                    if digest in files:
                        with files[digest].open("rb") as member:
                            target.addfile(header, CheckedReader(member, checkpoint))
                    else:
                        member = source.extractfile("objects/" + digest)
                        if member is None:
                            raise StreamError("missing verifier public input")
                        with member:
                            target.addfile(header, CheckedReader(member, checkpoint))
    return selected


@dataclass(frozen=True, slots=True)
class CheckedReader:
    source: BinaryIO
    checkpoint: Callable[[], None] | None

    def read(self, size: int) -> bytes:
        if self.checkpoint is not None:
            self.checkpoint()
        return self.source.read(size)
