#!/usr/bin/env python3
"""Offline object delivery. Repository authenticity stays with existing validators."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import lzma
import os
from pathlib import Path
import re
import shlex
import shutil
import sys
import subprocess
import tempfile
from urllib.parse import urlsplit
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci/kernel-runner"))
from image_urls import InputURLError, canonical_url

INDEX_LIMIT = 256 * 1024**2


class SealedError(Exception):
    """A sealed object or independent trust policy is missing or inconsistent."""

@dataclass(frozen=True, slots=True)
class Repository:
    inrelease: Path
    index: Path
    keyring: Path
    origin: str
    suite: str
    component: str
    arch: str
    index_path: str
    fingerprints: tuple[str, ...]
    max_age_seconds: int
    codename: str = ""


@dataclass(frozen=True, slots=True)
class ReleaseValidity:
    date: datetime
    deadline: datetime | None
    valid_until: datetime | None = None


def inventory(directory: Path) -> dict:
    with (directory / "inventory.json").open() as source:
        return json.load(source)


def object_path(directory: Path, digest: str) -> Path:
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise SealedError("invalid sealed object identity")
    path = directory / digest
    if not path.is_file() or path.is_symlink():
        raise SealedError("missing sealed object")
    with path.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != digest:
            raise SealedError("sealed object digest mismatch")
    return path


def url_object(directory: Path, url: str) -> Path:
    expected = canonical_url(url)
    rows = [row for row in inventory(directory)["objects"]
            if expected in {canonical_url(value) for value in row["urls"]}]
    if len(rows) != 1:
        raise SealedError("URL absent or ambiguous in sealed inventory")
    return object_path(directory, rows[0]["sha256"])


def repository(directory: Path, name: str) -> Repository:
    row = inventory(directory)["repositories"][name]
    with (directory / "trust.json").open() as source:
        trust = json.load(source)["repositories"][name]
    # The capsule cannot nominate its own trust anchor or logical origin.
    for field in ("origin", "keyring", "fingerprints", "suite", "component", "arch", "index_path"):
        if row[field] != trust[field]:
            raise SealedError("sealed repository differs from independently approved trust policy")
    if row.get("codename", "") != trust.get("codename", ""):
        raise SealedError("sealed repository differs from independently approved trust policy")
    origin = urlsplit(row["origin"])
    if (origin.scheme != "https" or origin.username or origin.password or origin.query
            or origin.fragment or origin.port or not origin.hostname):
        raise SealedError("invalid sealed logical origin")
    if name == "firstparty" and row["origin"] != "https://apt.ceralive.tv":
        raise SealedError("kernel_origin_mismatch: expected https://apt.ceralive.tv")
    if not row["fingerprints"] or any(not re.fullmatch(r"[A-F0-9]{40}", fp)
                                      for fp in row["fingerprints"]):
        raise SealedError("missing independently approved archive fingerprints")
    return Repository(*(object_path(directory, row[key]) for key in ("inrelease", "index", "keyring")),
                      *(row[key] for key in ("origin", "suite", "component", "arch", "index_path")),
                      tuple(row["fingerprints"]), trust["max_age_seconds"], row.get("codename", ""))


def decompress_index(source: Path, destination: Path, index_path: str) -> None:
    """Decode the signed index format without changing its original compressed bytes."""
    match Path(index_path).suffix:
        case ".gz":
            decoded = gzip.open(source, "rb")
            decoder = None
        case ".xz":
            decoded = source.open("rb")
            decoder = lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
        case _:
            raise SealedError("unsupported compressed package index")
    try:
        with decoded as stream, destination.open("wb") as output:
            remaining = INDEX_LIMIT
            pending = b""
            while True:
                length = min(1024 * 1024, remaining + 1)
                if decoder is None:
                    chunk = stream.read(length)
                    if not chunk:
                        break
                else:
                    if decoder.needs_input:
                        pending = pending or stream.read(1024 * 1024)
                        if not pending:
                            raise EOFError("truncated xz package index")
                    chunk = decoder.decompress(pending, max_length=length)
                    pending = b""
                if len(chunk) > remaining:
                    raise SealedError("decompressed package index exceeds the 256 MiB bound")
                output.write(chunk)
                remaining -= len(chunk)
                if decoder is not None and decoder.eof:
                    pending = decoder.unused_data or stream.read(1024 * 1024)
                    padding = 0
                    while pending.startswith(b"\0"):
                        unpadded = pending.lstrip(b"\0")
                        padding += len(pending) - len(unpadded)
                        pending = unpadded or stream.read(1024 * 1024)
                    if padding % 4:
                        raise SealedError("misaligned xz stream padding")
                    if not pending:
                        break
                    # LZMAFile can hide later stream errors; each decoder must reach EOF.
                    decoder = lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
    except (OSError, EOFError, lzma.LZMAError, zlib.error, SealedError) as exc:
        destination.unlink(missing_ok=True)
        raise SealedError("invalid or oversized compressed package index") from exc


def valid_release(path: Path, max_age: int, require_until: bool = True) -> ReleaseValidity:
    """Only verified plaintext supplies the signed validity window."""
    dates: dict[str, list[str]] = {"Date": [], "Valid-Until": [], "Origin": []}
    for line in path.read_text().splitlines():
        for key in dates:
            if line.startswith(key + ":"):
                dates[key].append(line[len(key) + 1:].strip())
    if (len(dates["Date"]) != 1 or len(dates["Valid-Until"]) > 1
            or len(dates["Origin"]) > 1
            or type(max_age) is not int or not 0 < max_age <= 2592000):
        raise SealedError("missing or ambiguous signed metadata validity")
    now = datetime.now(timezone.utc)
    date = parsedate_to_datetime(dates["Date"][0])
    if date.tzinfo is None:
        raise SealedError("signed metadata Date has no timezone")
    debian = dates["Origin"] == ["Debian"]
    if not dates["Valid-Until"] and require_until:
        if debian and os.environ.get("CERALIVE_BUILD_PURPOSE") == "rootfs-measurement":
            return ReleaseValidity(date, None)
        raise SealedError("missing or ambiguous signed metadata validity")
    if not 0 <= (now - date).total_seconds() <= max_age:
        raise SealedError("signed metadata expired or future-dated")
    deadline = date + timedelta(seconds=max_age)
    until = None
    if dates["Valid-Until"]:
        until = parsedate_to_datetime(dates["Valid-Until"][0])
        if until.tzinfo is None or until < now or until < date:
            raise SealedError("signed metadata Valid-Until expired")
        deadline = min(deadline, until)
    return ReleaseValidity(date, deadline, until)


def mirror_validities(directory: Path) -> tuple[ReleaseValidity, ...]:
    """Authenticate every original repository before mkosi can consume its bytes."""
    data = inventory(directory)
    with (directory / "trust.json").open() as source:
        policies = json.load(source)["repositories"]
    if not data["repositories"] or set(data["repositories"]) != set(policies):
        raise SealedError("mirror repositories require their complete approved validity policies")
    windows = []
    records = []
    metadata_origins: dict[str, set[str]] = {}
    library = Path(__file__).resolve().parent
    script = '''
source "$1/fetch-debs-auth.sh"
source "$1/fetch/index.sh"
log_error() { printf '%s\\n' "$*" >&2; }
auth_verify_release_to_file "$2" "$3" "$4" "${@:11}"
auth_release_has_identity "$4" "$5" "$6" "$7" "${10}"
expected="$(index_release_digest "$4" "$8")"
index_verify_digest "$9" "$expected" sealed-mirror
'''
    for name in data["repositories"]:
        repo = repository(directory, name)
        with tempfile.TemporaryDirectory(prefix=".metadata-", dir=directory) as temporary:
            release = Path(temporary) / "Release"
            try:
                subprocess.run(["bash", "-euo", "pipefail", "-c", script, "_", str(library),
                                str(repo.keyring), str(repo.inrelease), str(release), repo.suite,
                                repo.component, repo.arch, repo.index_path, str(repo.index),
                                repo.codename, *repo.fingerprints],
                               check=True, capture_output=True, text=True, timeout=60,
                               env={"PATH": os.environ["PATH"], "LANG": "C.UTF-8", "TMPDIR": temporary})
            except subprocess.SubprocessError as exc:
                raise SealedError(f"sealed {name} signature/index/identity verification rejected") from exc
            validity = valid_release(release, repo.max_age_seconds,
                                     require_until=name not in ("firstparty", "bsp"))
            windows.append(validity)
            records.append({
                "repository": name, "release_date": validity.date.isoformat(),
                "release_sha256": repo.inrelease.name,
                "freshness_checked": validity.deadline is not None,
                "freshness": "checked" if validity.deadline is not None else "NOT checked",
            })
        metadata_origins.setdefault(repo.inrelease.name, set()).add(repo.origin)
    for row in data["objects"]:
        for url in row["urls"]:
            canonical = canonical_url(url)
            if urlsplit(canonical).path.rsplit("/", 1)[-1] in ("InRelease", "Release"):
                origins = metadata_origins.get(row["sha256"], set())
                if not any(canonical.startswith(origin + "/") for origin in origins):
                    raise SealedError("mirror metadata has no authenticated repository policy")
    (directory / "metadata-validity.json").write_text(json.dumps({
        "schema": 1, "purpose": os.environ.get("CERALIVE_BUILD_PURPOSE", "full"),
        "repositories": records,
    }, sort_keys=True) + "\n")
    return tuple(windows)


def serve(directory: Path) -> None:
    """Finite guest-local mirror; no upstream client, CONNECT or credential endpoint."""
    validities = mirror_validities(directory)
    mapping = {}
    missing = False
    for row in inventory(directory)["objects"]:
        for url in row["urls"]:
            url = canonical_url(url)
            file = object_path(directory, row["sha256"])
            if url in mapping and mapping[url] != file:
                raise SealedError("ambiguous sealed URL")
            mapping[url] = file

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            nonlocal missing
            now = datetime.now(timezone.utc)
            if any(row.deadline is not None and not row.date <= now <= row.deadline for row in validities):
                missing = True
                (directory / "missing-object").write_text("repository metadata expired\n")
                self.send_error(410)
                return
            requested = self.path
            if requested.startswith("/HTTPS///"):
                requested = "https://" + requested[len("/HTTPS///"):]
            elif requested.startswith("http://"):
                requested = "https://" + requested[len("http://"):]
            status = 404
            try:
                file = mapping.get(canonical_url(requested))
            except InputURLError:
                file = None
                status = 400
            if file is None:
                missing = True
                marker = directory / "missing-object"
                marker.write_text(hashlib.sha256(requested.encode()).hexdigest() + "\n")
                self.send_error(status)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(file.stat().st_size))
            self.end_headers()
            with file.open("rb") as source:
                shutil.copyfileobj(source, self.wfile, length=1024 * 1024)

        def log_message(self, _format: str, *args: str) -> None:
            # The complete request inventory is already recorded privately.
            return

    with HTTPServer(("127.0.0.1", 3142), Handler) as server:
        print("CERALIVE_SEALED_MIRROR_READY", flush=True)
        while not missing:
            server.handle_request()
    raise SealedError("guest requested an object absent from the sealed inventory")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("copy", "repository", "valid-release", "decompress-index", "serve"))
    parser.add_argument("values", nargs="*")
    args = parser.parse_args()
    directory = Path(os.environ["CERALIVE_SEALED_INPUTS"])
    match args.operation:
        case "copy":
            url, destination = args.values
            shutil.copyfile(url_object(directory, url), destination)
        case "repository":
            repo = repository(directory, args.values[0])
            for key in ("inrelease", "index", "keyring", "origin", "suite", "component", "arch", "index_path", "codename"):
                print("sealed_" + key + "=" + shlex.quote(str(getattr(repo, key))))
            print("sealed_fingerprints=(" + " ".join(shlex.quote(fp) for fp in repo.fingerprints) + ")")
            print("sealed_max_age=" + shlex.quote(str(repo.max_age_seconds)))
        case "valid-release":
            path, age, *repository_name = args.values
            valid_release(Path(path), int(age), require_until=repository_name not in (["firstparty"], ["bsp"]))
        case "decompress-index":
            source, destination, index_path = args.values
            decompress_index(Path(source), Path(destination), index_path)
        case "serve":
            serve(directory)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, SealedError, InputURLError) as exc:
        print(f"sealed input: {exc}", file=sys.stderr)
        sys.exit(1)
