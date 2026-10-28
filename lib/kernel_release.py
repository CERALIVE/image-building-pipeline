"""Immutable kernel metadata and Debian version ordering, shared by release gates."""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path
import re
import shutil
import subprocess
from typing import Final

VERSION: Final = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+-ceralive[1-9][0-9]*")
PACKAGE: Final = re.compile(r"linux-image-[0-9]+\.[0-9]+\.[0-9]+-ceralive-rk3588")
SHA256: Final = re.compile(r"[0-9a-f]{64}")
REPOSITORY: Final = "CERALIVE/image-building-pipeline"


class KernelReleaseError(Exception):
    """A release input or its authenticated transport violated the contract."""


def command(args: list[str], cwd: Path | None = None) -> str:
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise KernelReleaseError(f"{' '.join(args[:3])}: {result.stderr.strip()}")
    return result.stdout.strip()


def version(value: str) -> str:
    if not VERSION.fullmatch(value):
        raise KernelReleaseError(f"invalid kernel version: {value!r}")
    return value


def compare(left: str, right: str) -> int:
    """Use the same Debian ordering as APT, including multi-digit revisions."""
    for relation, answer in (("lt", -1), ("gt", 1)):
        result = subprocess.run(
            ["dpkg", "--compare-versions", version(left), relation, version(right)],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            return answer
        if result.returncode != 1:
            raise KernelReleaseError(f"Debian version comparison failed: {result.stderr}")
    return 0


@dataclass(frozen=True, slots=True)
class KernelIdentity:
    package: str
    version: str
    deb_sha256: str

    @classmethod
    def parse(cls, row: dict[str, str]) -> KernelIdentity:
        name, selected, digest = row["package"], version(row["version"]), row["deb_sha256"]
        if not PACKAGE.fullmatch(name) or not SHA256.fullmatch(digest):
            raise KernelReleaseError("invalid kernel package or SHA-256")
        if name != f"linux-image-{selected.split('-ceralive', 1)[0]}-ceralive-rk3588":
            raise KernelReleaseError("kernel package/version upstream mismatch")
        return cls(name, selected, digest)


@dataclass(frozen=True, slots=True)
class KernelArtifact:
    identity: KernelIdentity
    fingerprint: str
    epoch: int
    boards: tuple[str, ...]


def artifact(path: Path) -> KernelArtifact:
    row = json.loads(path.read_text())
    identity = KernelIdentity.parse(row)
    closure = row["builder_closure"]
    if (
        row["arch"] != "arm64"
        or row["kernel_release"] != identity.package.removeprefix("linux-image-")
        or not SHA256.fullmatch(row["input_fingerprint"])
        or type(row["kernel_epoch"]) is not int or row["kernel_epoch"] < 0
        or not isinstance(row["validated_boards"], list)
        or not row["validated_boards"]
        or len(set(row["validated_boards"])) != len(row["validated_boards"])
        or not all(isinstance(b, str) and re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", b)
                   for b in row["validated_boards"])
        or not isinstance(closure["base_image"], str)
        or not closure["base_image"]
        or not isinstance(closure["packages"], list) or not closure["packages"]
        or not all(isinstance(p, str) and p and "\n" not in p for p in closure["packages"])
        or closure["packages"] != sorted(set(closure["packages"]))
        or not isinstance(closure["compiler"], str) or not closure["compiler"]
        or not SHA256.fullmatch(closure["dockerfile_sha256"])
    ):
        raise KernelReleaseError(f"malformed kernel artifact: {path}")
    return KernelArtifact(identity, row["input_fingerprint"], row["kernel_epoch"],
                          tuple(row["validated_boards"]))


def tag_versions(repo: Path) -> list[str]:
    tags = command(["git", "tag", "--list", "kernel/*"], repo).splitlines()
    result = []
    for tag in tags:
        if not tag.startswith("kernel/v"):
            raise KernelReleaseError(f"malformed kernel tag: {tag}")
        result.append(version(tag.removeprefix("kernel/v")))
    return result


def published_versions() -> list[str]:
    history = os.environ.get("CERALIVE_KERNEL_HISTORY_DIR")
    if history:
        root = Path(history)
        if not root.is_dir():
            raise KernelReleaseError(f"kernel history missing: {root}")
        return [version(p.name) for p in sorted(root.iterdir()) if p.is_dir()]
    tags = command([
        "gh", "api", "--paginate", f"repos/{REPOSITORY}/releases",
        "--jq", ".[] | select(.draft == false) | .tag_name",
    ]).splitlines()
    result = []
    for tag in tags:
        if tag.startswith("kernel/"):
            if not tag.startswith("kernel/v"):
                raise KernelReleaseError(f"malformed kernel release tag: {tag}")
            result.append(version(tag.removeprefix("kernel/v")))
    return result


def metadata(selected: str, dest: Path) -> KernelArtifact:
    """Download metadata only; .deb bytes must come from the signed APT index."""
    version(selected)
    names = ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS")
    dest.mkdir(parents=True, exist_ok=True)
    history = os.environ.get("CERALIVE_KERNEL_HISTORY_DIR")
    if history:
        for name in names:
            shutil.copyfile(Path(history) / selected / name, dest / name)
    else:
        args = ["gh", "release", "download", f"kernel/v{selected}", "--repo", REPOSITORY,
                "--dir", str(dest)]
        for name in names:
            args.extend(("--pattern", name))
        command(args)
    return verified_metadata(selected, dest)


def verified_metadata(selected: str, dest: Path) -> KernelArtifact:
    """Verify the existing four metadata files without acquiring replacement bytes."""
    names = ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS")
    record = artifact(dest / "kernel-artifact.json")
    if record.identity.version != selected:
        raise KernelReleaseError("kernel release metadata version mismatch")
    deb = f"{record.identity.package}_{selected}_arm64.deb"
    hashes = {}
    for line in (dest / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64}) [ *](?:\./)?([^/\s]+)", line)
        if not match or match[2] in hashes:
            raise KernelReleaseError("malformed/duplicate kernel SHA256SUMS")
        hashes[match[2]] = match[1]
    if set(hashes) != {deb, *names[:-1]} or hashes[deb] != record.identity.deb_sha256:
        raise KernelReleaseError("kernel release checksum identity mismatch")
    for name in names[:-1]:
        if hashlib.sha256((dest / name).read_bytes()).hexdigest() != hashes[name]:
            raise KernelReleaseError(f"kernel release metadata checksum mismatch: {name}")
        if not (dest / name).stat().st_size:
            raise KernelReleaseError(f"empty kernel release metadata: {name}")
    return record


def sidecar(path: Path) -> KernelIdentity:
    row = json.loads(path.read_text())
    if (
        set(row) != {"schema", "board", "os_version", "kernel"}
        or type(row["schema"]) is not int or row["schema"] != 1
        or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", row["board"])
        or not re.fullmatch(r"[0-9]{4}\.[0-9]+\.[0-9]+", row["os_version"])
        or set(row["kernel"]) != {"package", "version", "deb_sha256"}
    ):
        raise KernelReleaseError(f"malformed OS kernel sidecar: {path}")
    return KernelIdentity.parse(row["kernel"])
