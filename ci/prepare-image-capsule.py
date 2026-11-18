#!/usr/bin/env python3
"""Prefetch a reviewed finite package closure and seal an offline measurement capsule."""

from __future__ import annotations

import argparse
from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import resource
import runpy
import subprocess
import sys
import tarfile
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci/kernel-runner"))
from image_capsule import INPUT_LIMIT, KINDS, digest_file, object_id, original_url, unpack
from image_policy import ArchivePolicy, load_policy
from image_stream import Identity, StreamError, unique_object

ROOT = Path(__file__).resolve().parents[1]
SEALED = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
INDEX_LIMIT = SEALED["INDEX_LIMIT"]


def child_limit(length: int) -> None:
    """Bound downloaded/decompressed files independently of HTTP Content-Length."""
    resource.setrlimit(resource.RLIMIT_FSIZE, (length, length))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def read_json(path: Path) -> dict:
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 1024 * 1024:
        raise StreamError("missing, linked or oversized reviewed inventory")
    return json.loads(path.read_text(), object_pairs_hook=unique_object)


def fetch(url: str, target: Path, length: int, client: tuple[str, str] | None,
          ca_file: str | None, seconds: int, env: dict[str, str]) -> None:
    """One exact GET, without curl configuration, proxies, redirects or retries."""
    args = ["curl", "--disable", "--silent", "--fail", "--globoff", "--noproxy", "*",
            "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "0",
            "--connect-timeout", str(min(10, seconds)), "--max-time", str(seconds),
            "--max-filesize", str(length), "--output", str(target),
            "--write-out", "%{http_code}"]
    if client:
        args += ["--cert", client[0], "--key", client[1]]
    if ca_file:
        args += ["--cacert", ca_file]
    result = subprocess.run(args + ["--url", url], env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            timeout=seconds + 5, start_new_session=True,
                            preexec_fn=lambda: child_limit(length))
    if result.returncode or result.stdout != b"200":
        # Name only reviewed public identity; curl stderr can carry credential paths.
        raise StreamError(f"exact HTTPS GET failed for object {target.name} at {url} "
                          f"(HTTP {result.stdout.decode(errors='replace')}, curl exit {result.returncode})")


def shell(script: str, arguments: list[str], env: dict[str, str]) -> str:
    """Run only the repository's data validators, never package code."""
    result = subprocess.run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT),
                             *arguments], env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                            timeout=120, preexec_fn=lambda: child_limit(INDEX_LIMIT))
    if result.returncode:
        raise StreamError("signed package lookup or control identity rejected")
    return result.stdout.strip()


def transport_clients(args: argparse.Namespace, origins: set[str]) -> dict[str, tuple[str, str]]:
    """Bind in-place client identities to independently approved exact origins."""
    clients = {}
    for origin, certificate, key in args.client_identity:
        if origin not in origins or origin in clients:
            raise StreamError("client identity requires one exact independently approved origin")
        if any(not Path(path).is_absolute() for path in (certificate, key)):
            raise StreamError("client certificate and key must be explicit absolute paths")
        clients[origin] = (certificate, key)
    if not 1 <= args.object_timeout <= 600:
        raise StreamError("object timeout must be between 1 and 600 seconds")
    return clients


def metadata_base(name: str, repo: ArchivePolicy) -> str:
    """Use the same exact distribution path for discovery and capsule preparation."""
    base = repo.origin + "/dists/" + (repo.codename or repo.suite)
    return base + "/binary-" + repo.arch if name == "firstparty" else base


def copy_local(source: Path, target: Path, length: int) -> None:
    """Snapshot only the reviewed number of bytes from a regular local input."""
    if source.is_symlink() or not source.is_file() or source.stat().st_size != length:
        raise StreamError("local input is not a regular file of the approved size")
    with source.open("rb") as stream, target.open("xb") as output:
        remaining = length
        while remaining:
            chunk = stream.read(min(1024 * 1024, remaining))
            if not chunk:
                break
            output.write(chunk)
            remaining -= len(chunk)
        if remaining or stream.read(1):
            raise StreamError("local input changed from its approved size")


def prepare(args: argparse.Namespace) -> str:
    policy = load_policy(args.trust_policy)
    reviewed = read_json(args.inventory)
    if set(reviewed) != {"schema", "source_commit", "epoch", "board", "source_bundle",
                         "device_root", "objects", "repositories", "packages"}:
        raise StreamError("invalid reviewed inventory fields")
    Identity("prefetch", reviewed["board"], reviewed["source_commit"], reviewed["epoch"], "0" * 64)
    if type(reviewed["schema"]) is not int or reviewed["schema"] != 1:
        raise StreamError("invalid reviewed inventory schema")
    if (type(reviewed["objects"]) is not list or not 0 < len(reviewed["objects"]) < 19999
            or type(reviewed["packages"]) is not list or not reviewed["packages"]):
        raise StreamError("expected a finite reviewed complete package closure")
    if set(reviewed["repositories"]) != set(policy.repositories):
        raise StreamError("repositories differ from independently approved public policy")

    # The approved inventory is explicit closure input; this command never runs APT.
    objects = {}
    urls = set()
    for item in reviewed["objects"]:
        if (set(item) not in ({"sha256", "length", "kind", "urls"},
                              {"sha256", "length", "kind", "urls", "path"})
                or item["kind"] not in KINDS - {"artifact"}
                or type(item["length"]) is not int or not 0 < item["length"] <= INPUT_LIMIT
                or type(item["urls"]) is not list):
            raise StreamError("invalid reviewed object")
        digest = object_id(item["sha256"])
        names = [original_url(value) for value in item["urls"]]
        if digest in objects or any(name in urls for name in names) or len(names) != len(set(names)):
            raise StreamError("ambiguous reviewed object or URL")
        if "path" in item:
            if (not isinstance(item["path"], str) or item["kind"] == "deb"
                    or ".." in Path(item["path"]).parts):
                raise StreamError("packages must be fetched from their signed repository")
        elif len(names) != 1 or item["kind"] not in ("deb", "apt-metadata"):
            raise StreamError("only exact repository metadata and package GETs are permitted")
        if item["kind"] == "apt-metadata" and item["length"] > INDEX_LIMIT:
            raise StreamError("repository metadata exceeds the 256 MiB bound")
        objects[digest] = item | {"urls": names}
        urls.update(names)
    if sum(item["length"] + 1024 for item in objects.values()) + 2 * 1024**2 > INPUT_LIMIT:
        raise StreamError("reviewed capsule exceeds the unchanged 32 GiB budget")
    for digest, kind in ((reviewed["source_bundle"], "source-bundle"),
                         (reviewed["device_root"], "public-trust")):
        if digest not in objects or objects[digest]["kind"] != kind:
            raise StreamError("missing reviewed source bundle or public root")
    for digest in (repo.keyring for repo in policy.repositories.values()):
        if digest not in objects or objects[digest]["kind"] != "apt-metadata":
            raise StreamError("missing independently approved archive keyring")
    for digest in policy.kernel_metadata.values():
        if digest not in objects or objects[digest]["kind"] != "kernel-metadata":
            raise StreamError("missing independently approved kernel metadata")
    for builder in policy.builder_images:
        if builder.object not in objects or objects[builder.object]["kind"] != "builder-image":
            raise StreamError("missing independently approved builder")

    allowed = {}
    bases = {}
    for name, repo in policy.repositories.items():
        record = reviewed["repositories"][name]
        expected = asdict(repo)
        expected["fingerprints"] = list(repo.fingerprints)
        del expected["max_age_seconds"]
        if not repo.codename:
            del expected["codename"]
        if (set(record) != set(expected) | {"inrelease", "index"}
                or any(record[key] != value for key, value in expected.items())):
            raise StreamError("repository differs from independently approved policy")
        base = metadata_base(name, repo)
        bases[name] = base if name == "firstparty" else repo.origin
        for key, suffixes in (("inrelease", ("InRelease", "Release")),
                              ("index", (repo.index_path,))):
            digest = record[key]
            if (digest not in objects or objects[digest]["kind"] != "apt-metadata"
                    or "path" in objects[digest]
                    or len(objects[digest]["urls"]) != 1
                    or objects[digest]["urls"][0] not in
                    {original_url(base + "/" + suffix) for suffix in suffixes}):
                raise StreamError("metadata URL is outside the exact approved repository objects")
            allowed[digest] = repo.origin
        if objects[record["inrelease"]]["length"] > 16 * 1024**2:
            raise StreamError("signed Release metadata exceeds the 16 MiB bound")

    packages = {}
    identities = set()
    for package in reviewed["packages"]:
        if (set(package) != {"repository", "name", "version", "arch", "sha256"}
                or package["repository"] not in policy.repositories
                or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", package["name"])
                or not re.fullmatch(r"[A-Za-z0-9.+:~_-]+", package["version"])
                or package["arch"] not in ("arm64", "all")):
            raise StreamError("invalid reviewed package identity")
        identity = (package["repository"], package["name"], package["arch"])
        digest = package["sha256"]
        if (identity in identities or digest in packages or digest not in objects
                or objects[digest]["kind"] != "deb"):
            raise StreamError("missing or ambiguous reviewed package")
        identities.add(identity)
        packages[digest] = package
    if {digest for digest, item in objects.items() if item["kind"] == "deb"} != set(packages):
        raise StreamError("each package object requires one reviewed identity")
    if any("path" not in item and item["kind"] == "apt-metadata" and digest not in allowed
           for digest, item in objects.items()):
        raise StreamError("undeclared network metadata")

    clients = transport_clients(args, {repo.origin for repo in policy.repositories.values()})
    destination = args.output
    if destination.exists() or destination.is_symlink():
        raise StreamError("capsule output already exists")
    if (not destination.parent.is_dir() or destination.parent.is_symlink()
            or destination.parent.stat().st_uid != os.getuid()
            or destination.parent.stat().st_mode & 0o077):
        raise StreamError("capsule output directory must be owned and private (0700)")

    with tempfile.TemporaryDirectory(prefix=".prefetch-", dir=destination.parent) as temporary:
        work = Path(temporary)
        data = work / "inputs"
        data.mkdir(mode=0o700)
        env = {"PATH": os.environ["PATH"], "LANG": "C.UTF-8", "HOME": temporary,
               "TMPDIR": temporary, "CERALIVE_BUILD_PURPOSE": "rootfs-measurement"}
        for digest, item in objects.items():
            if item["kind"] == "deb":
                continue
            target = data / digest
            if "path" in item:
                source = Path(item["path"])
                if not source.is_absolute():
                    source = args.inventory.parent / source
                copy_local(source, target, item["length"])
            else:
                fetch(item["urls"][0], target, item["length"], clients.get(allowed[digest]),
                      args.ca_file, args.object_timeout, env)
            target.chmod(0o600)
            if target.stat().st_size != item["length"] or digest_file(target) != digest:
                raise StreamError("prefetched object size or digest mismatch")
        rows = [{key: item[key] for key in ("sha256", "length", "kind", "urls")}
                for item in objects.values()]
        inventory = {key: reviewed[key] for key in
                     ("schema", "source_commit", "epoch", "board", "source_bundle",
                      "device_root", "repositories")} | {"objects": rows}
        (data / "inventory.json").write_text(json.dumps(inventory))
        (data / "trust.json").write_text(json.dumps(asdict(policy)))
        shell('source "$1/lib/rauc-pki-contract.sh"; rauc_public_root_resolve "$2" "$3"',
              [str(data / reviewed["device_root"]), policy.root_der_sha256], env)
        # Use the importer's original signature -> Release -> compressed index checks.
        previous = os.environ.get("CERALIVE_BUILD_PURPOSE")
        os.environ["CERALIVE_BUILD_PURPOSE"] = "rootfs-measurement"
        try:
            validities = SEALED["mirror_validities"](data)
        finally:
            if previous is None:
                del os.environ["CERALIVE_BUILD_PURPOSE"]
            else:
                os.environ["CERALIVE_BUILD_PURPOSE"] = previous
        indexes = {}
        for name in dict.fromkeys(package["repository"] for package in packages.values()):
            index = data / reviewed["repositories"][name]["index"]
            indexes[name] = work / (name + ".Packages")
            SEALED["decompress_index"](index, indexes[name], policy.repositories[name].index_path)
        package_inventory = []
        for digest, package in packages.items():
            repo = policy.repositories[package["repository"]]
            record = shell('source "$1/lib/fetch-debs-auth.sh"; auth_lookup_package "$2" "$3" "$4" "$5"',
                           [str(indexes[package["repository"]]), package["name"], package["version"], repo.arch], env)
            filename, signed_digest, version = record.split("\t")
            if filename.startswith("/") or ".." in filename or "://" in filename:
                raise StreamError("signed package filename is unsafe")
            url = original_url(bases[package["repository"]] + "/" + filename.removeprefix("./"))
            item = objects[digest]
            if signed_digest != digest or version != package["version"] or item["urls"] != [url]:
                raise StreamError("reviewed package differs from original signed index")
            target = data / digest
            fetch(url, target, item["length"], clients.get(repo.origin),
                  args.ca_file, args.object_timeout, env)
            target.chmod(0o600)
            if target.stat().st_size != item["length"] or digest_file(target) != digest:
                raise StreamError("package size or digest mismatch")
            shell('source "$1/lib/shared/deb-lib.sh"; '
                  'assert_deb_identity "$2" "$3" "$4" "$5"',
                  [str(target), package["name"], package["version"], package["arch"]], env)
            package_inventory.append(package | {"origin": repo.origin, "url": url, "length": item["length"]})
        inventory["fetched_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        receipt = json.dumps({"schema": 1, "delivery": "offline-capsule",
                              "fetched_at": inventory["fetched_at"],
                              "packages": package_inventory,
                              "metadata_validity": read_json(data / "metadata-validity.json")},
                             sort_keys=True, separators=(",", ":")).encode()
        receipt_digest = hashlib.sha256(receipt).hexdigest()
        (data / receipt_digest).write_bytes(receipt)
        rows.append({"sha256": receipt_digest, "length": len(receipt),
                     "kind": "apt-metadata", "urls": []})
        encoded = json.dumps(inventory, separators=(",", ":")).encode()
        if len(encoded) > 1024 * 1024:
            raise StreamError("capsule inventory exceeds 1 MiB")
        staged = work / "capsule.tar"
        with staged.open("xb") as output, tarfile.open(fileobj=output, mode="w:") as archive:
            header = tarfile.TarInfo("inventory.json")
            header.size = len(encoded)
            header.mode = 0o600
            archive.addfile(header, io.BytesIO(encoded))
            for row in rows:
                header = tarfile.TarInfo("objects/" + row["sha256"])
                header.size = row["length"]
                header.mode = 0o600
                with (data / row["sha256"]).open("rb") as source:
                    archive.addfile(header, source)
        digest = digest_file(staged)
        unpack(staged, work / "checked",
               Identity("prefetch", reviewed["board"], reviewed["source_commit"], reviewed["epoch"], digest))
        now = datetime.now(timezone.utc)
        if any(row.deadline is not None and not row.date <= now <= row.deadline for row in validities):
            raise StreamError("repository metadata expired during prefetch")
        staged.chmod(0o600)
        os.link(staged, destination)
        return digest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--trust-policy", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--client-identity", nargs=3, action="append", default=[],
                        metavar=("ORIGIN", "CERTIFICATE_PATH", "KEY_PATH"))
    parser.add_argument("--ca-file", help="explicit public HTTPS CA bundle; defaults to system trust")
    parser.add_argument("--object-timeout", type=int, default=120)
    args = parser.parse_args()
    try:
        print(prepare(args))
    except (StreamError, SEALED["SealedError"]) as exc:
        print(f"capsule preparation rejected: {exc}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        # Do not render curl stderr, server bytes, package contents or key paths.
        print(f"capsule preparation rejected: {type(exc).__name__}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
