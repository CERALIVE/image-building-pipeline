"""Replay the sealed ARM64 Debian selection without downloading packages."""

from collections.abc import Iterator
from dataclasses import asdict, dataclass, replace
import json
from pathlib import Path
import re
import shutil
from tempfile import TemporaryDirectory
from urllib.parse import unquote

from image_capsule import digest_file, original_url
from image_policy import ArchivePolicy
from image_stream import StreamError
from image_transport import SEALED
from image_urls import canonical_url
from vm_process import run as run_gate


# Match the source order in mkosi/runtime/sealed-apt-policy.sh, including
# the tie-break when the same version appears in more than one archive.
SUITES = (
    ("debian-trixie", "https://deb.debian.org/debian", "trixie"),
    ("debian-updates", "https://deb.debian.org/debian", "trixie-updates"),
    ("debian-security", "https://deb.debian.org/debian-security", "trixie-security"),
)
PACKAGE = re.compile(r"[a-z0-9][a-z0-9+.-]*")
VERSION = re.compile(r"[A-Za-z0-9.+:~_-]+")
INSTALL_ROW = re.compile(rf"Inst (\S+)(?: \[({VERSION.pattern})\])? \((\S+) .+ \[(arm64|all)\]\)(?: .*)?")
URI = re.compile(r"'([^']+)'\s+(\S+)\s+(\d+)(?:\s+\S+)?\s*")
BINARY_INDEX = re.compile(r"main/binary-arm64/Packages\.(?:gz|xz)")
MKOSI_APT_VERSION = "3.0.3"


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
    aliases: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class RuntimeRauc:
    status: Path
    debs: tuple[Path, Path]
    version: str
    apt_version: str | None = None


def pinned_rauc_version(root: Path) -> str:
    """Use the same version and local suffix consumed by the package builder."""
    pins = dict(line.split("=", 1) for line in (root / "manifests/rauc-deb-versions.txt").read_text().splitlines()
                if line.startswith(("DEBIAN_SOURCE_VERSION=", "CERALIVE_SUFFIX=")))
    return pins["DEBIAN_SOURCE_VERSION"] + pins["CERALIVE_SUFFIX"]


def stage_local_rauc(work: Path, runtime: RuntimeRauc) -> dict[str, PackagePin]:
    """Build the flat mkosi repository index from the actual built package controls."""
    directory = work / "repository"
    directory.mkdir()
    local = {}
    with (directory / "Packages").open("w", encoding="utf-8") as index:
        for path, name, arch in zip(runtime.debs, ("rauc", "rauc-service"), ("arm64", "all"), strict=True):
            package = path.resolve(strict=True)
            control = run_gate(["dpkg-deb", "--field", str(package)], capture_output=True,
                               text=True, timeout=30).stdout.strip()
            fields = {key: value for line in control.splitlines() if not line.startswith((" ", "\t"))
                      for key, _, value in [line.partition(": ")]}
            if ("\n\n" in control or (fields.get("Package"), fields.get("Version"), fields.get("Architecture"))
                    != (name, runtime.version, arch) or not VERSION.fullmatch(runtime.version)
                    or any(key.lower() in {"filename", "size", "sha256"} for key in fields)):
                raise StreamError(f"invalid local RAUC control: {name}")
            filename = f"{name}_{runtime.version}_{arch}.deb"
            link = directory / filename
            link.symlink_to(package)
            digest = digest_file(package)
            size = package.stat().st_size
            index.write(f"{control}\nFilename: ./{filename}\nSize: {size}\nSHA256: {digest}\n\n")
            local[name] = PackagePin("local", name, runtime.version, arch,
                                     link.as_uri().replace("file://", "file:", 1), digest, size)
    return local


def replay_repositories(policies: dict[str, ArchivePolicy], *,
                        candidate_sealing: bool) -> tuple[tuple[str, str, str], ...]:
    """Require the complete trixie binary set when any trixie binary route is declared."""
    by_suite = {}
    marked_binary = False
    for name, origin, suite in SUITES:
        if name in policies:
            marked_binary |= (policies[name].origin == origin
                              and BINARY_INDEX.fullmatch(policies[name].index_path) is not None)
        matches = [key for key, repo in policies.items()
                   if (repo.origin, repo.codename or repo.suite) == (origin, suite)
                   and not repo.index_path.startswith("main/source/Sources.")]
        if len(matches) > 1:
            raise StreamError("ambiguous Debian APT replay suite")
        if matches:
            if not BINARY_INDEX.fullmatch(policies[matches[0]].index_path):
                raise StreamError("Debian APT replay requires the exact ARM64 binary index")
            by_suite[suite] = (matches[0], origin, suite)
    if len(by_suite) == len(SUITES):
        return tuple(by_suite.values())
    # A Sources index can supply RAUC sources without any Debian image binaries.
    has_source = policies["debian-source"].index_path.startswith("main/source/Sources.")
    if marked_binary or by_suite or (has_source and candidate_sealing):
        raise StreamError("Debian APT replay requires trixie, updates and security indices")
    return ()


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


def signed_filename(row: dict[str, str]) -> str:
    filename = row["Filename"].removeprefix("./")
    if (filename.startswith("/") or ".." in Path(filename).parts
            or not re.fullmatch(r"[A-Za-z0-9_+./~%-]+", filename)):
        raise StreamError("invalid Debian package filename")
    return filename


def solve(indices: list[ReplayIndex], scratch: Path, apt_get: Path, file_method: Path,
          requests: list[str], *, runtime: RuntimeRauc | None = None) -> dict[str, PackagePin]:
    """Run native APT with isolated state and only a file transport."""
    if not requests or any(r != "?essential" and not PACKAGE.fullmatch(r) for r in requests):
        raise StreamError("invalid Debian APT replay roots")
    apt_get, file_method = apt_get.resolve(strict=True), file_method.resolve(strict=True)
    with TemporaryDirectory(prefix="apt-replay-", dir=scratch) as temporary:
        work = Path(temporary)
        for name in ("etc", "lists", "archives", "methods", "empty"):
            (work / name).mkdir()
        (work / "methods/file").symlink_to(file_method)
        status = work / "status"
        local = {}
        local_source = ""
        if runtime is None:
            status.touch()
        else:
            # The URI planner starts a method for its capabilities. Alias the
            # offline file method, never an implementation that can access HTTP.
            (work / "methods/http").symlink_to(file_method)
            shutil.copyfile(runtime.status, status)
            if not status.stat().st_size:
                raise StreamError("runtime RAUC replay requires post-platform installed state")
            local = stage_local_rauc(work, runtime)
            local_source = f"deb [trusted=yes] {(work / 'repository').as_uri()} ./\n"
        original_status = status.read_bytes()
        locations = {(index.origin.replace("https://", "http://", 1) if runtime else
                      (work / f"archive-{i}").as_uri().replace("file://", "file:", 1), index.suite): index
                     for i, index in enumerate(indices)}
        (work / "etc/sources.list").write_text(local_source + "".join(
            f"deb [arch=arm64 arch-=all trusted=yes] {uri} {index.suite} main\n"
            for (uri, _), index in locations.items()))
        if runtime:
            # mkosi pins the flat repository above Debian. Keep the real
            # public origins in the planner but do not install an HTTP method.
            (work / "etc/preferences").write_text('Package: *\nPin: origin ""\nPin-Priority: 1100\n')
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
            result = run_gate([str(apt_get), *args], env=env, cwd=work, check=False,
                              capture_output=True, text=True, timeout=90)
            if result.returncode:
                raise StreamError(f"native offline APT {args[0]} failed (exit {result.returncode})")
            return result.stdout

        # Use APT's own cache key encoding. No update is executed; only the
        # signature-checked Release and decompressed Packages bytes are staged.
        if runtime is not None and runtime.apt_version is not None:
            if not apt("--version").splitlines()[0].startswith(f"apt {runtime.apt_version} ("):
                raise StreamError(f"runtime RAUC replay requires APT {runtime.apt_version}")
        cache = {}
        for line in apt("--print-uris", "update").splitlines():
            if match := URI.fullmatch(line):
                uri, filename, _ = match.groups()
                if Path(filename).name != filename:
                    raise StreamError("invalid APT index cache name")
                cache[unquote(uri)] = work / "lists" / filename
        for (uri, _), index in locations.items():
            prefix = f"{unquote(uri)}/dists/{index.suite}/"
            candidates = {file for target, file in cache.items()
                          if target.startswith(prefix + "main/binary-arm64/Packages")}
            if len(candidates) != 1:
                raise StreamError("native APT did not provide one ARM64 index cache target")
            shutil.copyfile(index.packages, candidates.pop())
            if index.release is not None:
                shutil.copyfile(index.release, cache[prefix + "InRelease"])
        if runtime is not None:
            candidates = {file for target, file in cache.items()
                          if target.startswith("file:" + str(work / "repository") + "/./Packages")}
            if len(candidates) != 1:
                raise StreamError("native APT did not provide the local RAUC index cache target")
            shutil.copyfile(work / "repository/Packages", candidates.pop())
        install = ["install", "--no-install-recommends", *requests]
        decisions = {}
        for line in apt("-s", *install).splitlines():
            if runtime is not None and line.startswith("Remv "):
                raise StreamError("runtime RAUC replay would remove installed packages")
            if not line.startswith("Inst "):
                continue
            match = INSTALL_ROW.fullmatch(line)
            if not match or (runtime is None and match.group(2) is not None):
                raise StreamError("unrecognized native APT selection row")
            name, _, version, arch = match.groups()
            if not PACKAGE.fullmatch(name) or not VERSION.fullmatch(version) or name in decisions:
                raise StreamError("invalid or duplicate native APT selection")
            decisions[name] = (version, arch)
        if not decisions:
            raise StreamError("native APT selected no packages")
        planned = {}
        for line in apt("--print-uris", "--download-only", "-y", *install).splitlines():
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
        if status.read_bytes() != original_status or any((work / "archives").glob("*.deb")):
            raise StreamError("native APT replay changed package state")
        if decisions.keys() != planned.keys():
            raise StreamError("native APT selection and URI plan disagree")
        for name, pin in local.items():
            location = planned.get(name)
            if (decisions.pop(name, None) != (pin.version, pin.arch) or location is None
                    or Path(unquote(location[0].removeprefix("file:"))) != Path(unquote(pin.url.removeprefix("file:")))
                    or location[1] != pin.length or not location[0].startswith("file:")):
                raise StreamError(f"runtime RAUC replay did not choose the built local package: {name}")
            del planned[name]
        result = {}
        for (location, _), index in locations.items():
            prefix = unquote(location) + "/"
            names = {name for name, (uri, _) in planned.items() if uri.startswith(prefix)}
            matched = set()
            for row in rows_for(index, names):
                name = row["Package"]
                filename = signed_filename(row)
                if ((row["Version"], row["Architecture"]) != decisions[name]
                        or planned[name] != (prefix + unquote(filename), int(row["Size"]))):
                    continue
                if name in matched or not re.fullmatch(r"[0-9a-f]{64}", row["SHA256"]):
                    raise StreamError("ambiguous or invalid signed Debian package row")
                matched.add(name)
                pin = PackagePin(index.repository, name, row["Version"], row["Architecture"],
                                 original_url(index.origin + "/" + filename), row["SHA256"], int(row["Size"]))
                if name in result:
                    if runtime is None or replace(pin, repository=result[name].repository) != result[name]:
                        raise StreamError("ambiguous or invalid signed Debian package row")
                    # Two signed suites can publish the same bytes at one pool URI.
                    continue
                result[name] = pin
        if result.keys() != decisions.keys():
            raise StreamError("APT URI has no matching signed Debian package row")
        return result


def replay_runtime_rauc(indices: list[ReplayIndex], scratch: Path, apt_get: Path, file_method: Path,
                        status: Path, debs: tuple[Path, Path], version: str, *,
                        apt_version: str | None = None) -> dict[str, PackagePin]:
    plan = solve(indices, scratch, apt_get, file_method, ["rauc", "rauc-service"],
                 runtime=RuntimeRauc(status, debs, version, apt_version))
    # APT's URI printer exposes the primary only. The acquire implementation
    # can try another index entry for that same binary version after failure.
    alternates: dict[str, set[str]] = {name: set() for name in plan}
    for index in indices:
        matched = set()
        for row in rows_for(index, set(plan)):
            pin = plan[row["Package"]]
            if (row["Version"], row["Architecture"]) != (pin.version, pin.arch):
                continue
            if pin.name in matched:
                raise StreamError(f"ambiguous signed runtime archive package: {pin.name}")
            matched.add(pin.name)
            if (row["SHA256"], int(row["Size"])) != (pin.sha256, pin.length):
                raise StreamError(f"signed runtime archives disagree on package bytes: {pin.name}")
            url = original_url(index.origin + "/" + signed_filename(row))
            if url != pin.url:
                alternates[pin.name].add(url)
    return {name: replace(pin, aliases=tuple(sorted(alternates[name]))) for name, pin in plan.items()}


def verify_runtime_fetches(plan: dict[str, PackagePin], selection: dict[str, PackagePin]) -> None:
    missing = []
    for name, pin in sorted(plan.items()):
        item = selection.get(name)
        routes = {canonical_url(url) for url in (item.url, *item.aliases)} if item else set()
        for url in (*pin.aliases, pin.url):
            if (canonical_url(url) not in routes or item is None
                    or (item.name, item.version, item.arch, item.length, item.sha256)
                    != (pin.name, pin.version, pin.arch, pin.length, pin.sha256)):
                missing.append(url)
    if missing:
        raise StreamError("runtime RAUC replay requires unsealed or mismatched package URLs: "
                          + ", ".join(missing))


def merge_runtime_fetches(base: dict[str, PackagePin], runtime: dict[str, PackagePin]) -> dict[str, PackagePin]:
    """Keep the original replay's primary pin and attach only signed compatible routes."""
    merged = dict(base)
    for name, pin in runtime.items():
        primary = base.get(name, pin)
        if (primary.version, primary.arch, primary.sha256, primary.length) != (
                pin.version, pin.arch, pin.sha256, pin.length):
            raise StreamError(f"bootstrap and runtime require different package pins: {name}")
        urls = {pin.url, *pin.aliases}
        if primary.url not in urls:
            raise StreamError(f"bootstrap URL is not a signed runtime route: {name}")
        aliases = urls - {primary.url}
        merged[name] = replace(primary, aliases=tuple(sorted(aliases)))
    return merged


def verify_selection(plan: dict[str, PackagePin], selection: dict[str, PackagePin]) -> None:
    """The reviewed and solved closures must have exactly the same pins."""
    different = sorted(name for name in plan.keys() | selection.keys()
                       if plan.get(name) != selection.get(name))
    if different:
        raise StreamError("offline APT replay differs from reviewed selection: " + ", ".join(different[:20]))


def replay_selection(indices: list[ReplayIndex], scratch: Path,
                     selection: dict[str, PackagePin], apt_get: Path,
                     file_method: Path) -> dict[str, PackagePin]:
    """Solve both the empty bootstrap and all reviewed public binary roots."""
    bootstrap = solve(indices, scratch, apt_get, file_method, ["?essential", "base-files"])
    closure = solve(indices, scratch, apt_get, file_method, sorted(selection))
    verify_selection(bootstrap, {name: closure[name] for name in bootstrap if name in closure})
    return closure


def selected_pins(packages: list[dict], objects: dict[str, dict],
                  names: set[str]) -> dict[str, PackagePin]:
    selected = {}
    for row in packages:
        if row["repository"] not in names:
            continue
        item = objects[row["sha256"]]
        url, *aliases = item["urls"]
        if row["name"] in selected:
            raise StreamError("ambiguous reviewed Debian replay package")
        selected[row["name"]] = PackagePin(**row, url=url, length=item["length"], aliases=tuple(aliases))
    if not selected:
        raise StreamError("missing reviewed Debian replay packages")
    return selected


def authenticated_indices(data: Path, scratch: Path, reviewed: dict,
                          policies: dict[str, ArchivePolicy],
                          repositories: tuple[tuple[str, str, str], ...]) -> list[ReplayIndex]:
    """Authenticate the staged and digest-checked public metadata."""
    rows = {name: reviewed["repositories"][name] for name, _, _ in repositories}
    objects = {item["sha256"]: item for item in reviewed["objects"]}
    ids = metadata_ids(rows)
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
