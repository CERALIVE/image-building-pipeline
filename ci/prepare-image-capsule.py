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
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci/kernel-runner"))
from image_capsule import INPUT_LIMIT, KINDS, digest_file, object_id, original_url, unpack
from image_apt_replay import (authenticated_indices, metadata_ids, replay_repositories,
                              replay_selection, selected_pins, verify_selection)
from image_candidate import FIELD as CANDIDATE_FIELD, KIND as CANDIDATE_KIND
from image_candidate import check_sealed_candidate_archive, select_candidate, stage_candidate
from kernel_release import KernelReleaseError, local_status, read_kernel_json
from image_policy import archive_policies, parse_policy, read_policy
from image_stream import Identity, StreamError
from image_transport import (INDEX_LIMIT, SEALED, TransportParser, copy_local, fetch, metadata_base,
                             read_json, shell, transport_clients)


def prepare(args: argparse.Namespace) -> str:
    if not 1 <= args.object_timeout <= 600:
        raise StreamError("object timeout must be between 1 and 600 seconds")
    policy_record = read_policy(args.trust_policy)
    reviewed = read_json(args.inventory)
    if type(reviewed) is not dict:
        raise StreamError("invalid reviewed inventory fields")
    candidate = select_candidate(policy_record, reviewed, args.inventory.parent)
    policy = parse_policy({key: value for key, value in policy_record.items() if key != CANDIDATE_FIELD},
                          (), candidate_sealing=candidate is not None)
    replay = replay_repositories(policy.repositories)
    if args.replay_metadata is not None and not replay:
        raise StreamError("no production Debian repositories to replay")
    clients = {} if replay else transport_clients(args)
    if clients:
        archive_policies(policy_record["repositories"], clients.keys())
    required = {"schema", "source_commit", "epoch", "board", "source_bundle",
                "device_root", "objects", "repositories", "packages"}
    if candidate:
        required.add(CANDIDATE_FIELD)
    if reviewed.keys() != required:
        raise StreamError("invalid reviewed inventory fields")
    Identity("prefetch", reviewed["board"], reviewed["source_commit"], reviewed["epoch"], "0" * 64)
    if type(reviewed["schema"]) is not int or reviewed["schema"] != 1:
        raise StreamError("invalid reviewed inventory schema")
    if (type(reviewed["objects"]) is not list or not 0 < len(reviewed["objects"]) < 19999
            or type(reviewed["packages"]) is not list or not reviewed["packages"]):
        raise StreamError("expected a finite reviewed complete package closure")
    if set(reviewed["repositories"]) != set(policy.repositories):
        raise StreamError("repositories differ from independently approved public policy")

    # The inventory is an independent input; a solve never authorizes a new pin.
    objects = {}
    urls = set()
    for item in reviewed["objects"]:
        if type(item) is dict and (item.get("kind") == CANDIDATE_KIND
                                   or candidate and item.get("kind") == "kernel-metadata"):
            raise StreamError("measurement-candidate inventory must select a single private producer bundle")
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
    candidate_rows = candidate.rows() if candidate else []
    if candidate and any(pin["sha256"] in objects for pin in (
            candidate.binding["payloads"] | candidate.binding["proof"]).values()):
        raise StreamError("measurement-candidate inventory reuses a private bundle object")
    if (len(objects) + len(candidate_rows) >= 19999
            or sum(item["length"] + 1024 for item in (*objects.values(), *candidate_rows))
            + 2 * 1024**2 > INPUT_LIMIT):
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
        if not repo.max_redirects and "max_redirects" not in record:
            del expected["max_redirects"]
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
            # Use the validated inventory role, never a URL or filename, in diagnostics.
            role = "InRelease" if key == "inrelease" else "index"
            previous, _ = allowed.setdefault(digest, (name, role))
            if (previous == "bsp") != (name == "bsp"):
                raise StreamError(f"conflicting BSP transport requirements for metadata object {digest}")
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
        if candidate and package["name"].startswith("linux-image-"):
            raise StreamError("measurement-candidate inventory cannot also seal an APT kernel")
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
        transfers = []

        def stage(digest: str, *, cached: Path | None = None) -> None:
            item = objects[digest]
            target = data / digest
            if "path" in item:
                label = item["kind"]
                source = Path(item["path"])
                if not source.is_absolute():
                    source = args.inventory.parent / source
                copy_local(source, target, item["length"])
            elif cached is not None:
                label = allowed[digest][1]
                copy_local(cached / digest, target, item["length"])
            else:
                name, role = allowed[digest]
                label = f"{name} {role}"
                repo = policy.repositories[name]
                transfer = fetch(item["urls"][0], target, item["length"], clients.get(repo.origin),
                                 args.ca_file, args.object_timeout, env, name, repo.max_redirects)
                if transfer:
                    transfers.append({"sha256": digest} | transfer)
            target.chmod(0o600)
            pinned_size = item["length"]
            observed_size = target.stat().st_size
            observed_digest = digest_file(target)
            if observed_size != pinned_size or observed_digest != digest:
                raise StreamError(
                    f"prefetched object size or digest mismatch: {label}; "
                    f"size (bytes) pinned={pinned_size} observed={observed_size}; "
                    f"SHA-256 (first 16) pinned={digest[:16]} observed={observed_digest[:16]}"
                )
            if not candidate and digest == policy.kernel_metadata["kernel-artifact.json"]:
                try:
                    local_status(read_kernel_json(target))
                except KernelReleaseError as error:
                    raise StreamError(str(error)) from error

        public = set()
        if replay:
            repo_names = {name for name, _, _ in replay}
            replay_rows = {name: reviewed["repositories"][name] for name in repo_names}
            keyrings = {row["keyring"] for row in replay_rows.values()}
            if any("path" not in objects[digest] or objects[digest]["urls"] for digest in keyrings):
                raise StreamError("Debian APT replay keyring must be local")
            public = metadata_ids(replay_rows)
            if any(allowed[digest][0] not in repo_names for digest in public - keyrings):
                raise StreamError("Debian APT replay requires public Debian metadata routes")
            # The public archives and local keyrings are checked before the
            # first-party identity config is even opened.
            for digest in sorted(public):
                stage(digest, cached=args.replay_metadata)
            indices = authenticated_indices(data, work, reviewed, policy.repositories, replay)
            selected = selected_pins(list(packages.values()), objects, repo_names)
            plan = replay_selection(indices, work, selected, args.apt_get, args.apt_file_method)
            if args.write_replayed_inventory:
                output = refreshed_inventory(reviewed, selected, plan, args.inventory.parent)
                verify_selection(plan, selected_pins(output["packages"],
                                 {row["sha256"]: row for row in output["objects"]}, repo_names))
                staged_inventory = work / "reviewed.json"
                staged_inventory.write_text(json.dumps(output, indent=2) + "\n")
                staged_inventory.chmod(0o600)
                os.link(staged_inventory, destination)
                return f"offline APT replay passed: {len(plan)} Debian packages; new inventory is unapproved"
            verify_selection(plan, selected)
            if args.replay_metadata is not None:
                return f"offline APT replay passed: {len(plan)} Debian packages; no capsule written"
            clients = transport_clients(args)
            archive_policies(policy_record["repositories"], clients.keys())
        if candidate:
            stage_candidate(candidate, work / "candidate", data, env)
        for digest, item in objects.items():
            if digest not in public and item["kind"] != "deb":
                stage(digest)
        rows = [{key: item[key] for key in ("sha256", "length", "kind", "urls")}
                for item in objects.values()]
        inventory = {key: reviewed[key] for key in
                     ("schema", "source_commit", "epoch", "board", "source_bundle",
                      "device_root", "repositories")} | {"objects": rows}
        if candidate:
            inventory[CANDIDATE_FIELD] = candidate.binding
            rows.extend(candidate_rows)
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
            record = shell('source "$1/lib/fetch-debs-auth.sh"; auth_lookup_package "$2" "$3" "$4" "$5" identity',
                           [str(indexes[package["repository"]]), package["name"], package["version"], repo.arch], env)
            filename, signed_digest, version, arch, size = record.split("\t")
            if filename.startswith("/") or ".." in filename or "://" in filename:
                raise StreamError("signed package filename is unsafe")
            url = original_url(bases[package["repository"]] + "/" + filename.removeprefix("./"))
            item = objects[digest]
            if (signed_digest != digest or version != package["version"] or arch != package["arch"]
                    or int(size) != item["length"] or item["urls"] != [url]):
                raise StreamError("reviewed package differs from original signed index")
            target = data / digest
            transfer = fetch(url, target, item["length"], clients.get(repo.origin),
                             args.ca_file, args.object_timeout, env, package["repository"], repo.max_redirects)
            if transfer:
                transfers.append({"sha256": digest} | transfer)
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
                              "metadata_validity": read_json(data / "metadata-validity.json")} |
                             ({"transfers": transfers} if transfers else {}),
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
        if candidate:
            check_sealed_candidate_archive(staged, encoded, rows)
        else:
            unpack(staged, work / "checked",
                   Identity("prefetch", reviewed["board"], reviewed["source_commit"], reviewed["epoch"], digest))
        now = datetime.now(timezone.utc)
        if any(row.deadline is not None and not row.date <= now <= row.deadline for row in validities):
            raise StreamError("repository metadata expired during prefetch")
        staged.chmod(0o600)
        os.link(staged, destination)
        return digest


def refreshed_inventory(reviewed: dict, selected: dict, plan: dict, input_directory: Path) -> dict:
    """Replace only the replayed Debian binary rows, preserving other inputs."""
    replaced = {pin.sha256 for pin in selected.values()}
    packages = [row for row in reviewed["packages"] if row["sha256"] not in replaced]
    objects = []
    for row in reviewed["objects"]:
        if row["sha256"] in replaced:
            continue
        if "path" in row and not Path(row["path"]).is_absolute():
            row = row | {"path": str(input_directory.absolute() / row["path"])}
        objects.append(row)
    for pin in plan.values():
        packages.append({field: getattr(pin, field) for field in
                         ("repository", "name", "version", "arch", "sha256")})
        objects.append({"sha256": pin.sha256, "length": pin.length, "kind": "deb", "urls": [pin.url]})
    if len({row["sha256"] for row in objects}) != len(objects):
        raise StreamError("replayed Debian object collides with another reviewed input")
    output = reviewed | {"packages": packages, "objects": objects}
    if CANDIDATE_FIELD in output:
        bundle = Path(output[CANDIDATE_FIELD]["bundle"])
        output[CANDIDATE_FIELD] = {"bundle": str(input_directory.absolute() / bundle)}
    return output


def main() -> None:
    parser = TransportParser(description=__doc__)
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--trust-policy", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ca-file", help="explicit public HTTPS CA bundle; defaults to system trust")
    parser.add_argument("--object-timeout", type=int, default=120)
    parser.add_argument("--replay-metadata", type=Path, metavar="DIR",
                        help="verification only; use locally retained digest-named Debian metadata")
    parser.add_argument("--write-replayed-inventory", action="store_true",
                        help="write an unapproved corrected inventory to --output; no prefetch or sealing")
    parser.add_argument("--apt-get", type=Path, default=Path(shutil.which("apt-get") or "/usr/bin/apt-get"))
    parser.add_argument("--apt-file-method", type=Path, default=Path("/usr/lib/apt/methods/file"))
    args = parser.parse_args()
    if args.write_replayed_inventory and args.replay_metadata is None:
        parser.error("--write-replayed-inventory requires --replay-metadata")
    if args.replay_metadata is not None and (args.client_identity or args.client_identity_config is not None):
        parser.error("offline replay does not accept client identities")
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
