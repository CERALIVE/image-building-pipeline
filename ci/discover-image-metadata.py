#!/usr/bin/env python3
"""Discover reviewed package identities from original signed metadata, without payload GETs."""

from __future__ import annotations

import argparse
from dataclasses import asdict
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci/kernel-runner"))
from image_capsule import INPUT_LIMIT, digest_file, object_id, original_url
from image_policy import archive_policies
from image_sources import source_files, source_selections
from image_stream import StreamError

from image_transport import (SEALED, TransportParser, copy_local, fetch, metadata_base, read_json,
                             shell, transport_clients)


def discover(args: argparse.Namespace) -> str:
    reviewed = read_json(args.selection)
    approved = read_json(args.trust_policy)
    if (set(approved) != {"schema", "repositories"} or type(approved["schema"]) is not int
            or approved["schema"] != 1):
        raise StreamError("expected independently approved schema-1 archive policy")
    clients = transport_clients(args)
    policies = archive_policies(approved["repositories"], clients.keys())
    if any(Path(repo.index_path).name not in (
            ("Packages.gz", "Packages.xz", "Sources.gz", "Sources.xz") if name == "debian-source"
            else ("Packages.gz", "Packages.xz")) for name, repo in policies.items()):
        raise StreamError("discovery requires an exact gzip/xz binary Packages index")
    if (not reviewed or set(reviewed) - {"packages", "sources"}
            or any(type(rows) is not list for rows in reviewed.values())
            or not 0 < sum(len(rows) for rows in reviewed.values()) < 19999):
        raise StreamError("expected a finite reviewed exact package selection")
    sources = source_selections(reviewed.get("sources", []), policies)
    reviewed_packages = reviewed.get("packages", [])
    identities = set()
    for package in reviewed_packages:
        if (set(package) != {"repository", "name", "version", "arch"}
                or package["repository"] not in policies
                or Path(policies[package["repository"]].index_path).name not in ("Packages.gz", "Packages.xz")
                or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", package["name"])
                or not re.fullmatch(r"[A-Za-z0-9.+:~_-]+", package["version"])
                or package["arch"] not in ("arm64", "all")):
            raise StreamError("invalid reviewed package selection")
        identity = (package["repository"], package["name"], package["arch"])
        if identity in identities:
            raise StreamError("duplicate reviewed package selection")
        identities.add(identity)
    if ({row["repository"] for row in reviewed_packages} | {source.repository for source in sources}
            != set(policies)):
        raise StreamError("each approved discovery repository requires selected packages")
    keyrings = {}
    for name, path in args.keyring:
        if name not in policies or name in keyrings:
            raise StreamError("expected one explicit public keyring per approved repository")
        keyrings[name] = Path(path)
    if set(keyrings) != set(policies):
        raise StreamError("expected one explicit public keyring per approved repository")
    release_names = {}
    for name, filename in args.release_name:
        if name not in policies or name in release_names or filename not in ("InRelease", "Release"):
            raise StreamError("expected one exact signed Release name per repository")
        release_names[name] = filename
    destination = args.output.absolute()
    if destination.exists() or destination.is_symlink():
        raise StreamError("discovery output already exists")
    if (not destination.parent.is_dir() or destination.parent.is_symlink()
            or destination.parent.stat().st_uid != os.getuid()
            or destination.parent.stat().st_mode & 0o077):
        raise StreamError("discovery output parent must be owned and private (0700)")

    with tempfile.TemporaryDirectory(prefix=".discovery-", dir=destination.parent) as temporary:
        work = Path(temporary)
        data = work / "objects"
        data.mkdir(mode=0o700)
        env = {"PATH": os.environ["PATH"], "LANG": "C.UTF-8", "HOME": temporary, "TMPDIR": temporary}
        objects = {}
        repositories = {}
        packages = []
        receipts = []
        windows = []
        package_receipts = []
        source_receipts = []

        def retain(source: Path, url: str = "") -> str:
            """Retain original metadata bytes using the producer's object shape."""
            digest = digest_file(source)
            row = {"sha256": digest, "length": source.stat().st_size,
                   "kind": "apt-metadata", "urls": [url] if url else []}
            if not url:
                row["path"] = str(destination / "objects" / digest)
            if digest in objects and objects[digest] != row:
                raise StreamError("metadata object has ambiguous origin URL")
            if digest not in objects:
                shutil.copyfile(source, data / digest)
                (data / digest).chmod(0o600)
                objects[digest] = row
            return digest

        # Validate all supplied public anchors before making any request.
        for name in sorted(policies):
            source = keyrings[name]
            if source.is_symlink() or not source.is_file() or not 0 < source.stat().st_size <= SEALED["INDEX_LIMIT"]:
                raise StreamError("public keyring must be a bounded regular file")
            snapshot = work / (name + ".keyring")
            copy_local(source, snapshot, source.stat().st_size)
            digest = retain(snapshot)
            if digest != policies[name].keyring:
                raise StreamError("public keyring differs from independently approved digest")
            shell(
                'source "$1/lib/fetch-debs-auth.sh"; auth_keyring_has_exact_fingerprints "$2" "${@:3}"',
                [str(data / digest), *policies[name].fingerprints], env)

        for name, repo in sorted(policies.items()):
            base = metadata_base(name, repo)
            release_url = original_url(base + "/" + release_names.get(name, "InRelease"))
            index_url = original_url(base + "/" + repo.index_path)
            signed = work / "signed"
            release = work / "Release"
            release_transfer = fetch(
                release_url, signed, 16 * 1024**2, clients.get(repo.origin),
                args.ca_file, args.object_timeout, env, name, repo.max_redirects)
            shell(
                'source "$1/lib/fetch-debs-auth.sh"; '
                'auth_verify_release_to_file "$2" "$3" "$4" "${@:9}"; '
                'auth_release_has_identity "$4" "$5" "$6" "$7" "$8"',
                [str(data / repo.keyring), str(signed), str(release), repo.suite,
                 repo.component, repo.arch, repo.codename, *repo.fingerprints], env)
            validity = SEALED["valid_release"](release, repo.max_age_seconds,
                                               require_until=name not in ("firstparty", "bsp"))
            windows.append(validity)
            signed_digest, signed_length = shell(
                'source "$1/lib/fetch/index.sh"; index_release_digest "$2" "$3" identity',
                [str(release), repo.index_path], env).split("\t")
            length = int(signed_length)
            if not 0 < length <= SEALED["INDEX_LIMIT"]:
                raise StreamError("signed package index exceeds the 256 MiB bound")
            compressed = work / "compressed"
            index_transfer = fetch(
                index_url, compressed, length, clients.get(repo.origin),
                args.ca_file, args.object_timeout, env, name, repo.max_redirects)
            shell(
                'source "$1/lib/fetch/index.sh"; log_error() { printf "%s\\n" "$*" >&2; }; '
                'index_verify_digest "$2" "$3" discovery',
                [str(compressed), signed_digest], env)
            if compressed.stat().st_size != length:
                raise StreamError("original index differs from signed Size")
            inrelease = retain(signed, release_url)
            index = retain(compressed, index_url)
            record = asdict(repo)
            del record["max_age_seconds"]
            if not repo.codename:
                del record["codename"]
            if not repo.max_redirects:
                del record["max_redirects"]
            record["fingerprints"] = list(repo.fingerprints)
            repositories[name] = record | {"inrelease": inrelease, "index": index}
            receipts.append({"repository": name, "origin": repo.origin,
                             "release_sha256": inrelease, "index_sha256": index,
                             "release_date": validity.date.isoformat(),
                             "valid_until": validity.valid_until.isoformat() if validity.valid_until else None})
            transfers = [{"sha256": digest} | transfer for digest, transfer in
                         ((inrelease, release_transfer), (index, index_transfer)) if transfer]
            if transfers:
                receipts[-1]["transfers"] = transfers
            decoded = work / "Packages"
            SEALED["decompress_index"](compressed, decoded, repo.index_path)
            for source in (source for source in sources if source.repository == name):
                records = shell(
                    'source "$1/lib/rauc-build/source.sh"; rauc_debian_source_lookup "$2" "$3" "$4" identity',
                    [str(decoded), source.name, source.version], env)
                for file in source_files(source, records, repo.origin, copy_local):
                    if file.sha256 in objects:
                        raise StreamError("ambiguous signed source object")
                    objects[file.sha256] = {"sha256": file.sha256, "length": file.length,
                                            "kind": "pinned-source", "urls": [file.url], "path": file.path}
                    source_receipts.append({"repository": name, "name": source.name, "version": source.version,
                                            "origin": repo.origin, "index_sha256": index} | asdict(file))
            for package in sorted((row for row in reviewed_packages if row["repository"] == name),
                                  key=lambda row: (row["name"], row["arch"])):
                filename, digest, version, arch, size = shell(
                    'source "$1/lib/fetch-debs-auth.sh"; auth_lookup_package "$2" "$3" "$4" "$5" identity',
                    [str(decoded), package["name"], package["version"], repo.arch], env).split("\t")
                if arch != package["arch"] or version != package["version"]:
                    raise StreamError("signed package architecture or version differs from reviewed selection")
                if filename.startswith("/") or ".." in filename or "://" in filename:
                    raise StreamError("signed package filename is unsafe")
                package_base = base if name == "firstparty" else repo.origin
                url = original_url(package_base + "/" + filename.removeprefix("./"))
                if not 0 < int(size) <= INPUT_LIMIT or digest in objects:
                    raise StreamError("invalid or ambiguous signed package object")
                objects[object_id(digest)] = {"sha256": digest, "length": int(size), "kind": "deb", "urls": [url]}
                packages.append(package | {"sha256": digest})
                package_receipts.append(package | {"origin": repo.origin, "sha256": digest,
                                                   "length": int(size), "filename": filename,
                                                   "url": url, "index_sha256": index})
        now = datetime.now(timezone.utc)
        if any(row.deadline is not None and not row.date <= now <= row.deadline for row in windows):
            raise StreamError("repository metadata expired during discovery")
        fragment = {"repositories": repositories, "packages": packages,
                    "objects": sorted(objects.values(), key=lambda row: row["sha256"])}
        encoded = json.dumps(fragment, sort_keys=True, separators=(",", ":")) + "\n"
        if len(encoded.encode()) > 1024 * 1024:
            raise StreamError("discovered inventory fragment exceeds 1 MiB")
        receipt = {"schema": 1, "fetched_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                   "repositories": receipts, "packages": package_receipts}
        if sources:
            receipt["sources"] = source_receipts
        destination.mkdir(mode=0o700)
        try:
            data.rename(destination / "objects")
            for filename, content in (("inventory-fragment.json", encoded),
                                      ("discovery.json", json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n")):
                with (destination / filename).open("x") as output:
                    os.chmod(output.fileno(), 0o600)
                    output.write(content)
        except OSError:
            shutil.rmtree(destination)
            raise
        return digest_file(destination / "inventory-fragment.json")


def main() -> None:
    parser = TransportParser(description=__doc__)
    parser.add_argument("--selection", required=True, type=Path)
    parser.add_argument("--trust-policy", required=True, type=Path)
    parser.add_argument("--keyring", nargs=2, action="append", default=[], metavar=("REPOSITORY", "PUBLIC_KEYRING_PATH"))
    parser.add_argument("--release-name", nargs=2, action="append", default=[], metavar=("REPOSITORY", "NAME"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ca-file", help="explicit public HTTPS CA bundle; defaults to system trust")
    parser.add_argument("--object-timeout", type=int, default=120)
    args = parser.parse_args()
    try:
        print(discover(args))
    except (StreamError, SEALED["SealedError"]) as exc:
        print(f"metadata discovery rejected: {exc}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as exc:
        print(f"metadata discovery rejected: {type(exc).__name__}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
