"""Replay the sealed ARM64 Debian selection without downloading packages."""

from collections.abc import Iterator
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from tempfile import TemporaryDirectory
from urllib.parse import unquote, urlsplit

from image_capsule import digest_file, original_url
from image_policy import ArchivePolicy
from image_stream import StreamError
from image_transport import SEALED


# Match the source order in mkosi/runtime/sealed-apt-policy.sh, including
# the tie-break when the same version appears in more than one archive.
SUITES = (
    ("debian-trixie", "https://deb.debian.org/debian", "trixie"),
    ("debian-updates", "https://deb.debian.org/debian", "trixie-updates"),
    ("debian-security", "https://deb.debian.org/debian-security", "trixie-security"),
)
PACKAGE = re.compile(r"[a-z0-9][a-z0-9+.-]*")
VERSION = re.compile(r"[A-Za-z0-9.+:~_-]+")
URI = re.compile(r"'([^']+)'\s+(\S+)\s+(\d+)(?:\s+\S+)?\s*")


@dataclass(frozen=True, slots=True)
class ReplayIndex:
    repository: str
    origin: str
    suite: str
    packages: Path
    release: Path | None = None


@dataclass(frozen=True, slots=True)
class PackagePin:
    repository: str
    name: str
    version: str
    arch: str
    url: str
    sha256: str
    length: int


def replay_repositories(policies: dict[str, ArchivePolicy]) -> tuple[tuple[str, str, str], ...]:
    """Recognize the complete production Debian set, even under other labels."""
    by_suite = {}
    labels = {name for name, _, _ in SUITES}
    for name, origin, suite in SUITES:
        matches = [key for key, repo in policies.items()
                   if (repo.origin, repo.codename or repo.suite) == (origin, suite)
                   and re.fullmatch(r"main/binary-arm64/Packages\.(?:gz|xz)", repo.index_path)]
        if len(matches) > 1:
            raise StreamError("ambiguous Debian APT replay suite")
        if matches:
            by_suite[suite] = (matches[0], origin, suite)
    # A transport-only policy may omit Debian image inputs altogether.
    source = policies["debian-source"]
    image_source = source.index_path.startswith("main/source/Sources.")
    if not image_source and not labels.intersection(policies) and len(by_suite) < len(SUITES):
        return ()
    if len(by_suite) != len(SUITES):
        raise StreamError("Debian APT replay requires trixie, updates and security indices")
    return tuple(by_suite.values())


def rows_for(index: ReplayIndex, names: set[str]) -> Iterator[dict[str, str]]:
    """Read just the selected binary stanzas from an already authenticated index."""
    fields: dict[str, str] = {}
    keys = {"Package", "Version", "Architecture", "Size", "SHA256", "Filename"}
    with index.packages.open(encoding="utf-8") as stream:
        for line in stream:
            if not line.strip():
                if fields.get("Package") in names:
                    yield fields
                fields = {}
                continue
            key, sep, value = line.rstrip("\n").partition(": ")
            if sep and key in keys:
                if key in fields:
                    raise StreamError("duplicate field in Debian index")
                fields[key] = value
    if fields.get("Package") in names:
        yield fields


def solve(indices: list[ReplayIndex], scratch: Path, apt_get: Path, file_method: Path,
          requests: list[str]) -> dict[str, PackagePin]:
    """Run native APT with empty state and only a file transport."""
    if not requests or any(r != "?essential" and not PACKAGE.fullmatch(r) for r in requests):
        raise StreamError("invalid Debian APT replay roots")
    apt_get, file_method = apt_get.resolve(strict=True), file_method.resolve(strict=True)
    with TemporaryDirectory(prefix="apt-replay-", dir=scratch) as temporary:
        work = Path(temporary)
        for name in ("etc", "lists", "archives", "methods", "empty"):
            (work / name).mkdir()
        (work / "methods/file").symlink_to(file_method)
        (work / "status").touch()
        locations = {(work / f"archive-{i}").as_uri().replace("file://", "file:", 1): index
                     for i, index in enumerate(indices)}
        (work / "etc/sources.list").write_text("".join(
            f"deb [arch=arm64 arch-=all trusted=yes] {uri} {index.suite} main\n"
            for uri, index in locations.items()))
        config = {
            "Dir::Etc": str(work / "etc"), "Dir::Etc::parts": str(work / "empty"),
            "Dir::Etc::sourceparts": str(work / "empty"),
            "Dir::Etc::preferencesparts": str(work / "empty"),
            "Dir::State": temporary, "Dir::State::status": str(work / "status"),
            "Dir::Cache": temporary, "Dir::Cache::pkgcache": "", "Dir::Cache::srcpkgcache": "",
            "Dir::Bin::Methods": str(work / "methods"), "Dir::Bin::dpkg": "/usr/bin/false",
            "APT::Architecture": "arm64", "APT::Architectures": "arm64",
            "APT::Install-Recommends": "false", "APT::Install-Suggests": "false",
            "APT::Immediate-Configure": "off", "APT::Get::AutomaticRemove": "true",
            "APT::Get::Allow-Change-Held-Packages": "true", "APT::Get::Allow-Remove-Essential": "true",
            "pkgCacheGen::ForceEssential": ",", "Acquire::Languages": "none",
            "Acquire::Check-Valid-Until": "false", "Debug::NoLocking": "true",
        }
        if any(c in temporary for c in ('"', "\\", "\n", "\r")):
            raise StreamError("unsafe Debian replay scratch path")
        apt_conf = work / "apt.conf"
        apt_conf.write_text("".join(f'{key} "{value}";\n' for key, value in config.items()))
        env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": temporary,
               "TMPDIR": temporary, "APT_CONFIG": str(apt_conf)}

        def apt(*args: str) -> str:
            result = subprocess.run([str(apt_get), *args], env=env, cwd=work,
                                    capture_output=True, text=True, timeout=90)
            if result.returncode:
                raise StreamError(f"native offline APT {args[0]} failed (exit {result.returncode})")
            return result.stdout

        # Use APT's own cache key encoding. No update is executed; only the
        # signature-checked Release and decompressed Packages bytes are staged.
        cache = {}
        for line in apt("--print-uris", "update").splitlines():
            if match := URI.fullmatch(line):
                uri, filename, _ = match.groups()
                if Path(filename).name != filename:
                    raise StreamError("invalid APT index cache name")
                cache[unquote(uri)] = work / "lists" / filename
        for uri, index in locations.items():
            prefix = f"{unquote(uri)}/dists/{index.suite}/"
            candidates = {file for target, file in cache.items()
                          if target.startswith(prefix + "main/binary-arm64/Packages")}
            if len(candidates) != 1:
                raise StreamError("native APT did not provide one ARM64 index cache target")
            shutil.copyfile(index.packages, candidates.pop())
            if index.release is not None:
                shutil.copyfile(index.release, cache[prefix + "InRelease"])
        decisions = {}
        for line in apt("-s", "install", *requests).splitlines():
            if not line.startswith("Inst "):
                continue
            match = re.fullmatch(r"Inst (\S+) \((\S+) .+ \[(arm64|all)\]\)(?: .*)?", line)
            if not match:
                raise StreamError("unrecognized native APT selection row")
            name, version, arch = match.groups()
            if not PACKAGE.fullmatch(name) or not VERSION.fullmatch(version) or name in decisions:
                raise StreamError("invalid or duplicate native APT selection")
            decisions[name] = (version, arch)
        if not decisions:
            raise StreamError("native APT selected no packages")
        planned = {}
        for line in apt("--print-uris", "--download-only", "-y", "install", *requests).splitlines():
            if not line.startswith("'"):
                continue
            match = URI.fullmatch(line)
            if not match:
                raise StreamError("unrecognized native APT URI row")
            uri, filename, length = match.groups()
            name = unquote(filename).split("_", 1)[0]
            if name not in decisions or name in planned:
                raise StreamError("ambiguous native APT package URI")
            planned[name] = (unquote(uri), int(length))
        if (work / "status").stat().st_size or any((work / "archives").glob("*.deb")):
            raise StreamError("native APT replay changed package state")
        if decisions.keys() != planned.keys():
            raise StreamError("native APT selection and URI plan disagree")
        result = {}
        for location, index in locations.items():
            prefix = unquote(location) + "/"
            names = {name for name, (uri, _) in planned.items() if uri.startswith(prefix)}
            for row in rows_for(index, names):
                name = row["Package"]
                filename = row["Filename"].removeprefix("./")
                if (filename.startswith("/") or ".." in Path(filename).parts
                        or not re.fullmatch(r"[A-Za-z0-9_+./~%-]+", filename)):
                    raise StreamError("invalid Debian package filename")
                if ((row["Version"], row["Architecture"]) != decisions[name]
                        or planned[name] != (prefix + unquote(filename), int(row["Size"]))):
                    continue
                if name in result or not re.fullmatch(r"[0-9a-f]{64}", row["SHA256"]):
                    raise StreamError("ambiguous or invalid signed Debian package row")
                result[name] = PackagePin(index.repository, name, row["Version"], row["Architecture"],
                                          original_url(index.origin + "/" + filename),
                                          row["SHA256"], int(row["Size"]))
        if result.keys() != decisions.keys():
            raise StreamError("APT URI has no matching signed Debian package row")
        return result


def verify_selection(plan: dict[str, PackagePin], selection: dict[str, PackagePin]) -> None:
    """Every solved package must match an exact reviewed identity and route."""
    different = sorted(name for name, pin in plan.items() if selection.get(name) != pin)
    if different:
        raise StreamError("offline APT replay differs from reviewed selection: " + ", ".join(different[:20]))


def replay_selection(indices: list[ReplayIndex], scratch: Path,
                     selection: dict[str, PackagePin], apt_get: Path,
                     file_method: Path) -> dict[str, PackagePin]:
    """Solve both the empty bootstrap and all reviewed public binary roots."""
    bootstrap = solve(indices, scratch, apt_get, file_method, ["?essential", "base-files"])
    closure = solve(indices, scratch, apt_get, file_method, sorted(selection))
    verify_selection(bootstrap, closure)
    return closure


def selected_pins(packages: list[dict], objects: dict[str, dict],
                  names: set[str]) -> dict[str, PackagePin]:
    selected = {}
    for row in packages:
        if row["repository"] not in names:
            continue
        item = objects[row["sha256"]]
        url, = item["urls"]
        if row["name"] in selected:
            raise StreamError("ambiguous reviewed Debian replay package")
        selected[row["name"]] = PackagePin(**row, url=url, length=item["length"])
    if not selected:
        raise StreamError("missing reviewed Debian replay packages")
    return selected


def authenticated_indices(data: Path, scratch: Path, reviewed: dict,
                          policies: dict[str, ArchivePolicy],
                          repositories: tuple[tuple[str, str, str], ...]) -> list[ReplayIndex]:
    """Reuse the stock prefetch signature, Release identity and digest checks."""
    rows = {name: reviewed["repositories"][name] for name, _, _ in repositories}
    objects = {item["sha256"]: item for item in reviewed["objects"]}
    ids = metadata_ids(rows)
    for digest in ids:
        path = data / digest
        item = objects[digest]
        if path.stat().st_size != item["length"] or digest_file(path) != digest:
            raise StreamError("Debian replay metadata differs from the reviewed digest or size")
    (data / "inventory.json").write_text(json.dumps(
        {"repositories": rows, "objects": [objects[digest] for digest in sorted(ids)]}))
    (data / "trust.json").write_text(json.dumps(
        {"repositories": {name: asdict(policies[name]) for name in rows}}))
    SEALED["mirror_validities"](data, purpose="rootfs-measurement")
    indices = []
    for name, origin, suite in repositories:
        unpacked = scratch / (name + ".Packages")
        SEALED["decompress_index"](data / rows[name]["index"], unpacked, policies[name].index_path)
        indices.append(ReplayIndex(name, origin, suite, unpacked, data / rows[name]["inrelease"]))
    return indices


def metadata_ids(repositories: dict) -> set[str]:
    return {row[key] for row in repositories.values() for key in ("keyring", "inrelease", "index")}
