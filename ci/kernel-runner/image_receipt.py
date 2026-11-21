"""Read release evidence directly from the controller's admitted capsule."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import runpy
import subprocess
import tarfile
from tempfile import TemporaryDirectory
from typing import BinaryIO

from image_capsule import object_id
from image_stream import Identity, StreamError, exact_json, unique_object


@dataclass(frozen=True, slots=True)
class ReleaseEvidence:
    kernel: tuple[str, str, str]
    deb_sha256: str
    validity: dict


def released_evidence(file: BinaryIO, identity: Identity, trust: dict, parent: Path,
                      checkpoint: Callable[[], None]) -> ReleaseEvidence:
    """Reauthenticate public metadata without opening an archive-supplied pathname."""
    scripts = runpy.run_path(str(Path(__file__).resolve().parents[2] / "lib/sealed-inputs.py"))
    try:
        with tarfile.open(fileobj=file, mode="r:") as archive, TemporaryDirectory(
                prefix=".receipt-evidence-", dir=parent.resolve(strict=True)) as temporary:
            work = Path(temporary)
            entries = archive.getmembers()
            if len(entries) > 20000 or len({entry.name for entry in entries}) != len(entries):
                raise StreamError("duplicate or excessive capsule members")
            header = archive.getmember("inventory.json")
            if not header.isfile() or header.issparse() or not 0 < header.size <= 1024**2:
                raise StreamError("invalid capsule inventory evidence")
            with archive.extractfile(header) as stream:
                raw = stream.read()
            inventory = json.loads(raw, object_pairs_hook=unique_object)
            if (type(inventory) is not dict or type(inventory["repositories"]) is not dict
                    or type(inventory["objects"]) is not list
                    or any(type(row) is not dict for row in inventory["objects"])
                    or any(type(repo) is not dict for repo in inventory["repositories"].values())
                    or not exact_json([inventory["source_commit"], inventory["epoch"], inventory["board"]],
                               [identity.commit, identity.epoch, identity.board])
                    or not trust["repositories"] or inventory["repositories"].keys() != trust["repositories"].keys()
                    or "measurement_candidate" in inventory
                    or any(row["kind"] == "measurement-candidate" for row in inventory["objects"])):
                raise StreamError("invalid released capsule identity")
            kernel_object = object_id(trust["kernel_metadata"]["kernel-artifact.json"])
            expected = {kernel_object: ("kernel-metadata", 16 * 1024**2)}
            for repo in inventory["repositories"].values():
                for field, kind, limit in (("inrelease", "apt-metadata", 16 * 1024**2),
                                           ("index", "apt-metadata", 256 * 1024**2),
                                           ("keyring", "apt-metadata", 16 * 1024**2)):
                    expected.setdefault(object_id(repo[field]), (kind, limit))
            objects = {row["sha256"]: row for row in inventory["objects"]}
            if len(objects) != len(inventory["objects"]):
                raise StreamError("duplicate capsule evidence object")
            for digest, (kind, limit) in expected.items():
                checkpoint()
                row = objects[digest]
                entry = archive.getmember("objects/" + digest)
                if (row["kind"] != kind or type(row["length"]) is not int
                        or not 0 < entry.size == row["length"] <= limit
                        or not entry.isfile() or entry.issparse()):
                    raise StreamError("invalid released capsule evidence object")
                observed = hashlib.sha256()
                with archive.extractfile(entry) as stream, (work / digest).open("xb") as output:
                    while chunk := stream.read(1024 * 1024):
                        checkpoint()
                        observed.update(chunk)
                        output.write(chunk)
                if observed.hexdigest() != digest:
                    raise StreamError("released capsule evidence digest mismatch")
            (work / "inventory.json").write_bytes(raw)
            (work / "trust.json").write_text(json.dumps(trust))
            scripts["mirror_validities"](work, purpose="rootfs-measurement")
            validity = json.loads((work / "metadata-validity.json").read_text(), object_pairs_hook=unique_object)
            kernel = json.loads((work / kernel_object).read_text(), object_pairs_hook=unique_object)
            package, version, arch = (kernel[field] for field in ("package", "version", "arch"))
            if (type(package) is not str or type(version) is not str or arch != "arm64"
                    or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-ceralive[1-9][0-9]*", version)
                    or package != f"linux-image-{version.split('-ceralive')[0]}-ceralive-rk3588"
                    or type(kernel["validated_boards"]) is not list
                    or identity.board not in kernel["validated_boards"]):
                raise StreamError("invalid approved released kernel evidence")
            return ReleaseEvidence((package, version, arch), object_id(kernel["deb_sha256"]), validity)
    except (KeyError, OSError, TypeError, ValueError, subprocess.SubprocessError, tarfile.TarError,
            scripts["SealedError"]):
        raise StreamError("could not authenticate released capsule evidence") from None
