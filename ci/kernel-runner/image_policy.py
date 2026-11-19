"""The host's independently approved public identities, never guest-selected trust."""

from __future__ import annotations

from collections.abc import Collection
from dataclasses import dataclass
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

from image_capsule import object_id, original_url
from image_stream import StreamError, unique_object


FIRSTPARTY_ORIGIN = "https://apt.ceralive.tv"


def require_client_origin(origin: str, repository: str = "firstparty") -> None:
    """Download approval alone never authorizes presentation of an identity."""
    if repository == "firstparty" and origin == FIRSTPARTY_ORIGIN:
        return
    # Never echo userinfo, paths, or malformed input in a rejection.
    try:
        host = urlsplit(origin).hostname or ""
    except ValueError:
        host = ""
    label = f"https://{host}" if re.fullmatch(r"[a-z0-9.-]{1,253}", host) else "<invalid origin>"
    raise StreamError(f"client identity requires one exact independently approved origin: {FIRSTPARTY_ORIGIN}; "
                      f"{label} rejected by the credential and redirect policy")


@dataclass(frozen=True, slots=True)
class ArchivePolicy:
    origin: str
    keyring: str
    fingerprints: tuple[str, ...]
    suite: str
    component: str
    arch: str
    index_path: str
    max_age_seconds: int
    codename: str = ""
    max_redirects: int = 0


@dataclass(frozen=True, slots=True)
class BuilderPolicy:
    object: str
    tag: str
    image_id: str
    arch: str


@dataclass(frozen=True, slots=True)
class PublicPolicy:
    schema: int
    root_der_sha256: str
    repositories: dict[str, ArchivePolicy]
    kernel_metadata: dict[str, str]
    builder_images: tuple[BuilderPolicy, ...]
    addon_public_object: str = ""
    paseto_public_object: str = ""
    os_version: str = ""


def archive_policies(rows: dict, client_origins: Collection[str] = ()) -> dict[str, ArchivePolicy]:
    """Parse independently approved archives without requiring image ingredients."""
    repositories = {}
    for origin in client_origins:
        require_client_origin(origin)
    for name, repo in rows.items():
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,40}", name):
            raise StreamError("invalid archive policy name")
        optional_fields = {"codename", "max_redirects"}
        required_fields = set(ArchivePolicy.__dataclass_fields__) - optional_fields
        if not required_fields.issubset(repo) or set(repo) - required_fields - optional_fields:
            raise StreamError("invalid archive policy fields")
        origin = original_url(repo["origin"])
        if origin in client_origins:
            require_client_origin(origin, name)
        maximum = repo.get("max_redirects", 0)
        if (type(maximum) is not int or not 0 <= maximum <= 3
                or (maximum and (name != "bsp" or origin in client_origins))):
            raise StreamError("invalid archive redirect policy: only uncredentialed bsp permits 1-3 hops")
        fingerprints = repo["fingerprints"]
        if (type(fingerprints) is not list or not fingerprints or len(fingerprints) != len(set(fingerprints))
                or any(not re.fullmatch(r"[A-F0-9]{40}", item) for item in fingerprints)
                or type(repo["max_age_seconds"]) is not int
                or not 0 < repo["max_age_seconds"] <= 2592000
                or repo["arch"] != "arm64"
                or any(not re.fullmatch(r"[a-zA-Z0-9_./+-]{1,120}", repo[key])
                       for key in ("suite", "component", "index_path"))
                or (repo.get("codename", "") != ""
                    and not re.fullmatch(r"[a-zA-Z0-9_+-]{1,120}", repo["codename"]))
                or any(part in ("", ".", "..") for part in repo["index_path"].split("/"))):
            raise StreamError("invalid archive validity or identity policy")
        repositories[name] = ArchivePolicy(**(repo | {
            "origin": origin, "keyring": object_id(repo["keyring"]),
            "fingerprints": tuple(fingerprints)}))
    if set(client_origins) - {repo.origin for repo in repositories.values()}:
        raise StreamError(f"credential origin {FIRSTPARTY_ORIGIN} missing from approved archive policy")
    if (("firstparty" in repositories
         and (repositories["firstparty"].origin != FIRSTPARTY_ORIGIN
              or repositories["firstparty"].suite not in ("stable", "beta")
              or repositories["firstparty"].codename))
            or ("debian-source" in repositories
                and repositories["debian-source"].origin != "https://deb.debian.org/debian")):
        raise StreamError("missing approved first-party/BSP/Debian-source origin policy")
    return repositories


def load_policy(path: Path, client_origins: Collection[str] = ()) -> PublicPolicy:
    if not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise StreamError("missing or oversized public trust policy")
    row = json.loads(path.read_text(), object_pairs_hook=unique_object)
    required = {"schema", "root_der_sha256", "repositories", "kernel_metadata", "builder_images"}
    optional = {"addon_public_object", "paseto_public_object", "os_version"}
    if (not required.issubset(row) or set(row) - required - optional
            or type(row["schema"]) is not int or row["schema"] != 1):
        raise StreamError("invalid public trust policy fields")
    repositories = archive_policies(row["repositories"], client_origins)
    if not {"firstparty", "bsp", "debian-source"}.issubset(repositories):
        raise StreamError("missing approved first-party/BSP/Debian-source origin policy")
    metadata = row["kernel_metadata"]
    if set(metadata) != {"kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS"}:
        raise StreamError("policy requires the exact four released kernel metadata objects")
    for digest in metadata.values():
        object_id(digest)
    builders = []
    for builder in row["builder_images"]:
        if (set(builder) != set(BuilderPolicy.__dataclass_fields__)
                or not re.fullmatch(r"[a-zA-Z0-9_./:@+-]{1,200}", builder["tag"])
                or not re.fullmatch(r"sha256:[0-9a-f]{64}", builder["image_id"])
                or builder["arch"] not in ("arm64", "amd64")):
            raise StreamError("invalid approved builder identity")
        builders.append(BuilderPolicy(**(builder | {"object": object_id(builder["object"])})))
    if not builders or len({builder.tag for builder in builders}) != len(builders):
        raise StreamError("missing or ambiguous approved builder closure")
    for key in ("addon_public_object", "paseto_public_object"):
        if row.get(key):
            object_id(row[key])
    if row.get("os_version") and not re.fullmatch(r"[0-9]{4}\.[0-9]+\.[0-9]+", row["os_version"]):
        raise StreamError("invalid image version identity")
    return PublicPolicy(1, object_id(row["root_der_sha256"]), repositories, metadata,
                        tuple(builders), **{key: row.get(key, "") for key in optional})
