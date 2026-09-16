"""Authenticated release discovery and bounded-age catalog parsing."""
import json
import re
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

from pin_versions import APP_COMPONENTS, COMPONENTS, PLATFORM_COMPONENTS, PinError, compare, release_version


@dataclass(frozen=True, slots=True)
class Release:
    component: str
    tag: str
    published_at: str
    packages: dict[str, str]


@dataclass(frozen=True, slots=True)
class Catalog:
    checked_at: datetime
    releases: tuple[Release, ...]


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise PinError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_catalog(text: str) -> Catalog:
    data = json.loads(text, object_pairs_hook=unique_object)
    if not isinstance(data, dict) or set(data) != {"schema_version", "checked_at", "releases"} or data["schema_version"] != 1:
        raise PinError("invalid release catalog schema")
    checked_at = datetime.fromisoformat(data["checked_at"])
    if checked_at.tzinfo is None:
        raise PinError("catalog checked_at must include timezone")
    releases: list[Release] = []
    for row in data["releases"]:
        if not isinstance(row, dict) or set(row) != {"component", "tag", "published_at", "packages"}:
            raise PinError("invalid catalog release")
        component = row["component"]
        if component not in COMPONENTS or component in {r.component for r in releases}:
            raise PinError(f"unknown/duplicate release component: {component}")
        release_version(row["tag"])
        published = datetime.fromisoformat(row["published_at"])
        if published.tzinfo is None or published > checked_at:
            raise PinError(f"invalid publication time: {component}")
        packages = row["packages"]
        if not isinstance(packages, dict) or not packages:
            raise PinError(f"missing published packages: {component}")
        for key, value in packages.items():
            if not re.fullmatch(r"[a-z0-9.+-]+\[(?:amd64|arm64|all)\]", key):
                raise PinError(f"invalid published package: {key}")
            release_version(value)
        releases.append(Release(component, row["tag"], row["published_at"], packages))
    if {r.component for r in releases} != COMPONENTS:
        raise PinError("release catalog must cover every image component")
    return Catalog(checked_at, tuple(releases))


def require_fresh(catalog: Catalog, now: datetime, hours: int) -> None:
    age = now - catalog.checked_at
    if hours < 1 or age < timedelta(0) or age > timedelta(hours=hours):
        raise PinError(f"release catalog unverifiable: checked_at={catalog.checked_at.isoformat()}, maximum age={hours}h; refresh with authenticated GitHub access")


def github(args: list[str]) -> str:
    for attempt in range(3):
        try:
            result = subprocess.run(["gh", *args], text=True, capture_output=True, timeout=60, check=False)
        except subprocess.TimeoutExpired:
            result = None
        if result is not None and result.returncode == 0:
            return result.stdout
        if attempt < 2:
            time.sleep(2 ** attempt)
    raise PinError(f"GitHub release evidence unavailable after 3 attempts: {args[0]}; authenticate with access to all image component repositories")


def discover_release(component: str) -> Release:
    pages = json.loads(github(["api", f"repos/CERALIVE/{component}/releases?per_page=100", "--paginate", "--slurp"]))
    candidates = []
    for page in pages:
        for row in page:
            if row["draft"] or row["prerelease"]:
                continue
            tag = row["tag_name"]
            # Binding-only and inherited upstream releases are different release trains.
            if tag.startswith("bindings-") or (component == "srt" and not tag.startswith("srt-v")):
                continue
            release_version(tag)
            candidates.append(row)
    if not candidates:
        raise PinError(f"no published stable release: {component}")
    newest = candidates[0]
    for row in candidates[1:]:
        if compare(row["tag_name"], newest["tag_name"]) > 0:
            newest = row
    packages: dict[str, str] = {}
    owned = {pkg for pkg, owner in (APP_COMPONENTS | PLATFORM_COMPONENTS).items() if owner == component}
    if component == "modem-stack":
        manifest = github(["release", "download", newest["tag_name"], "--repo", f"CERALIVE/{component}", "--pattern", "release-manifest.txt", "--output", "-"])
        if f"tag: {newest['tag_name']}" not in manifest.splitlines():
            raise PinError("modem release manifest tag mismatch")
        for line in manifest.splitlines():
            fields = line.split()
            if len(fields) == 7 and fields[0] in {"amd64", "arm64", "all"} and fields[1] in owned:
                key = f"{fields[1]}[{fields[0]}]"
                if key in packages:
                    raise PinError(f"duplicate modem release row: {key}")
                packages[key] = fields[3]
    else:
        for asset in newest["assets"]:
            match = re.fullmatch(r"([^_]+)_(.+)_(amd64|arm64|all)\.deb", asset["name"])
            if match and match[1] in owned:
                key = f"{match[1]}[{match[3]}]"
                if key in packages or compare(match[2], newest["tag_name"]) != 0:
                    raise PinError(f"ambiguous package or release identity: {key}")
                packages[key] = match[2]
    for package in owned:
        arches = ("arm64",) if package in PLATFORM_COMPONENTS else ("amd64", "arm64")
        for arch in arches:
            if f"{package}[{arch}]" not in packages and f"{package}[all]" not in packages:
                raise PinError(f"newest release lacks {package}[{arch}]: {newest['tag_name']}")
    return Release(component, newest["tag_name"], newest["published_at"], packages)


def refresh_catalog(path: Path) -> Catalog:
    releases = tuple(discover_release(component) for component in sorted(COMPONENTS))
    checked_at = datetime.now(timezone.utc)
    text = json.dumps({"schema_version": 1, "checked_at": checked_at.isoformat(), "releases": [
        {"component": r.component, "tag": r.tag, "published_at": r.published_at, "packages": r.packages} for r in releases
    ]}, indent=2) + "\n"
    catalog = parse_catalog(text)
    if path.exists():
        previous = parse_catalog(path.read_text())
        for old in previous.releases:
            new = next(r for r in releases if r.component == old.component)
            if compare(new.tag, old.tag) < 0:
                raise PinError(f"release evidence regressed: {old.component}; previous catalog preserved")
    path.write_text(text)
    return catalog
