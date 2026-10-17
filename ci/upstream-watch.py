#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 ci/upstream-watch.py --self-test
# python3 ci/upstream-watch.py              # scheduled, authenticated issue reconciliation
# ──────────────────
# noqa: SIZE_OK — the requested single-file watcher contains both seven probes and its offline self-test.
"""Read upstream inputs and reconcile one GitHub issue per pinned input; never edit pins."""

from __future__ import annotations

import ast
import base64
import gzip
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Final

from pin_versions import APP_COMPONENTS, PinError, compare, image_pins

ROOT: Final = Path(__file__).resolve().parents[1]
LABEL: Final = "upstream-input-watch"
CHANNELS: Final = ("stable", "beta")


@dataclass(frozen=True, slots=True)
class Issue:
    key: str
    subject: str
    finding: str

    @property
    def title(self) -> str:
        return f"[upstream-watch:{self.key}] {self.subject}"

    @property
    def body(self) -> str:
        return f"{self.finding}\n\nIssue-only advisory: review and change pins manually; this watch never edits the checkout.\n"


def command(args: list[str], *, input_bytes: bytes | None = None) -> bytes:
    allowed = {"curl", "gpgv", "openssl"}
    if not (args[0] in allowed or args[:2] in (["git", "ls-remote"], ["git", "ls-files"],
                                                ["gh", "api"], ["gh", "label"], ["gh", "issue"])):
        raise RuntimeError(f"upstream watch command is not an allowed read or issue operation: {args[:2]}")
    if args[0] == "curl" and any(flag in args for flag in ("-o", "--output", "-T", "--upload-file", "--data", "--request")):
        raise RuntimeError("curl must not write files or send mutations")
    if args[:2] == ["gh", "api"] and any(flag in args for flag in ("-X", "--method", "-f", "-F", "--input")):
        raise RuntimeError("release discovery must use read-only GitHub API requests")
    proc = subprocess.run(args, input=input_bytes, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False, timeout=90)
    if proc.returncode:
        raise RuntimeError(f"{args[0]} failed ({proc.returncode}): {proc.stderr.decode(errors='replace')[:300]}")
    return proc.stdout


def curl(url: str) -> bytes:
    return command(["curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "35", url])


def verified_release(url: str, keyring: str) -> str:
    """Use only gpgv's verified plaintext, never headers from the untrusted envelope."""
    return command(["gpgv", "--quiet", "--keyring", keyring, "--output", "-", "-"],
                   input_bytes=curl(url)).decode()


def signed_packages(base: str, index_path: str, keyring: str) -> str:
    release = verified_release(f"{base}/InRelease", keyring)
    sha_block = re.search(r"(?m)^SHA256:\n((?: [^\n]+\n)+)", release)
    if sha_block is None:
        raise RuntimeError(f"signed Release has no SHA256 block: {base}")
    digest = re.search(rf"(?m)^ ([a-fA-F0-9]{{64}})\s+\d+\s+{re.escape(index_path)}$", sha_block[1])
    if digest is None:
        raise RuntimeError(f"signed Release has no SHA256 entry for {index_path}")
    archive = curl(f"{base}/{index_path}")
    if hashlib.sha256(archive).hexdigest().lower() != digest[1].lower():
        raise RuntimeError(f"signed Packages digest mismatch: {base}/{index_path}")
    return gzip.decompress(archive).decode()


def package_versions(index: str, name: str) -> tuple[str, ...]:
    versions: list[str] = []
    for stanza in index.split("\n\n"):
        fields = dict(re.findall(r"(?m)^([A-Za-z-]+): ([^\n]+)$", stanza))
        if fields.get("Package") == name and "Version" in fields:
            versions.append(fields["Version"])
    return tuple(versions)


def package_issue(key: str, pinned: str, index: str, source: str) -> Issue | None:
    name, old = pinned.split("=", 1)
    versions = package_versions(index, name)
    subject = f"{source}: {name}"
    if old not in versions:
        return Issue(key, subject, f"Pinned `{name}={old}` has vanished from the signed {source} Packages index. Available: {', '.join(versions) or '(none)'}. Review before changing the pin.")
    newer = sorted((v for v in versions if compare(v, old) > 0), key=lambda v: VersionOrder(v))
    if newer:
        return Issue(key, subject, f"Pinned `{name}={old}`; newer published version `{name}={newer[-1]}` in the signed {source} Packages index.")
    return None


class VersionOrder:
    def __init__(self, version: str) -> None:
        self.version = comparable_tag(version)

    def __lt__(self, other: VersionOrder) -> bool:
        return compare(self.version, other.version) < 0


def release_fields(text: str) -> tuple[str, datetime]:
    version = re.search(r"(?m)^Version: (\S+)$", text)
    date = re.search(r"(?m)^Date: (.+)$", text)
    if version is None or date is None:
        raise RuntimeError("Debian Release lacks Version or Date")
    return version[1], datetime.strptime(date[1], "%a, %d %b %Y %H:%M:%S %Z").replace(tzinfo=timezone.utc)


def comparable_tag(tag: str) -> str:
    if re.fullmatch(r"v?\d+", tag):
        return f"{tag}.0.0"
    if re.fullmatch(r"v?\d+\.\d+", tag):
        return f"{tag}.0"
    return tag


def debian_issue(release: str, base_date: str, major: str) -> Issue | None:
    version, date = release_fields(release)
    if version.split(".")[0] != major:
        raise RuntimeError(f"Debian Release changed major: {version} (target {major})")
    if date.date() > datetime.fromisoformat(base_date).date():
        return Issue("debian-trixie", "Debian trixie point release", f"Builder base `trixie-{base_date}` predates Release `Version: {version}`, `Date: {date.isoformat()}`. Review the base digest and full target-suite closure before rebuilding.")
    return None


def tag_issue(key: str, subject: str, pinned: str, tags: list[str]) -> Issue | None:
    if not tags:
        raise RuntimeError(f"no stable tags for {subject}")
    newest = max(tags, key=VersionOrder)
    if compare(comparable_tag(newest), comparable_tag(pinned)) > 0:
        return Issue(key, subject, f"Pinned `{pinned}`; newest stable release `{newest}`. Review compatibility before changing the pin.")
    return None


def expiry_issue(key: str, subject: str, expiry: datetime, now: datetime, days: int,
                 instruction: str) -> Issue | None:
    if expiry <= now + timedelta(days=days):
        return Issue(key, subject, f"Expires at `{expiry.isoformat()}` (within {days} days). {instruction}")
    return None


def timestamp(value: str) -> datetime:
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise RuntimeError("expires_at must have a time zone")
    return result


def refresh_command(channel: str, board: str) -> str:
    return ("gh workflow run publish-release.yml --repo CERALIVE/image-building-pipeline "
            f"-f mode=refresh -f boards={board} -f channel={channel}")


def live_manifest(channel: str, board: str, now: datetime) -> Issue | None:
    url = f"https://images.ceralive.tv/channels/{channel}/{board}.json"
    response = command(["curl", "--silent", "--show-error", "--location", "--max-time", "35",
                        "--write-out", "\n%{http_code}", url]).decode()
    content, code = response.rsplit("\n", 1)
    if code == "404":
        return None
    if code != "200":
        raise RuntimeError(f"channel manifest {url} returned HTTP {code}")
    document = json.loads(content)
    if document.get("board") != board or document.get("channel") != channel:
        raise RuntimeError(f"channel manifest identity mismatch: {url}")
    return expiry_issue(f"channel-{channel}-{board}", f"Channel manifest {channel}/{board}",
                        timestamp(document["expires_at"]), now, 30,
                        f"Refresh the current signed manifest without republishing parts:\n\n```sh\n{refresh_command(channel, board)}\n```\n")


def pins(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


def observe(now: datetime) -> list[Issue]:
    issues: list[Issue] = []
    dockerfile = (ROOT / "ci/Dockerfile").read_text()
    base_date = re.search(r"debian:trixie-(\d{8})-slim", dockerfile)
    target = (ROOT / "manifests/target-release.env").read_text()
    major = re.search(r'OS_VERSION_ID:=(\d+)', target)
    if base_date is None or major is None:
        raise RuntimeError("builder base date or Debian major is not pinned")
    baseline = datetime.strptime(base_date[1], "%Y%m%d").date().isoformat()
    debian = verified_release("https://deb.debian.org/debian/dists/trixie/InRelease",
                              "/usr/share/keyrings/debian-archive-keyring.gpg")
    if finding := debian_issue(debian, baseline, major[1]):
        issues.append(finding)

    armbian_key = os.environ["ARMBIAN_KEYRING_PATH"]
    build_source = (ROOT / "lib/orchestrate.sh").read_text()
    source_url = re.search(r'(?m)^ARMBIAN_APT_URL="\$\{ARMBIAN_APT_URL:-([^}]+)\}"', build_source)
    source_suite = re.search(r'(?m)^ARMBIAN_SUITE="\$\{ARMBIAN_SUITE:-([^}]+)\}"', build_source)
    if source_url is None or source_suite is None:
        raise RuntimeError("Armbian source defaults could not be read from the build orchestrator")
    armbian = signed_packages(f"{source_url[1]}/dists/{source_suite[1]}",
                              "main/binary-arm64/Packages.gz", armbian_key)
    for pin in pins(ROOT / "manifests/armbian-bsp-deb-versions.txt"):
        name = pin.split("=", 1)[0]
        if finding := package_issue(f"armbian-{name}", pin, armbian, "Armbian"):
            issues.append(finding)

    mkosi_pin = (ROOT / ".mkosi-version").read_text().strip()
    mkosi_json = json.loads(command(["gh", "api", "repos/systemd/mkosi/releases/latest"]))
    if finding := tag_issue("mkosi", "mkosi", mkosi_pin, [mkosi_json["tag_name"].lstrip("v")]):
        issues.append(finding)

    family = (ROOT / "manifests/families/rk3588.yaml").read_text()
    kernel = re.search(r"(?m)^\s+tag: (v7\.2(?:\.\d+)?)\s*$", family)
    if kernel is None:
        raise RuntimeError("missing production v7.2 kernel tag")
    refs = command(["git", "ls-remote", "--tags", "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git",
                    "refs/tags/v7.2.*"]).decode()
    stable = re.findall(r"refs/tags/(v7\.2\.\d+)\s*$", refs, re.M)
    if finding := tag_issue("kernel-v7.2", "Linux stable v7.2.x", kernel[1], stable + [kernel[1]]):
        issues.append(finding)

    firstparty_key = os.environ["FIRST_PARTY_KEYRING_PATH"]
    indexes = {arch: signed_packages(f"https://apt.ceralive.tv/dists/stable/binary-{arch}",
                                      "Packages.gz", firstparty_key) for arch in ("amd64", "arm64")}
    image = image_pins(ROOT)
    for pin in image:
        if pin.package not in APP_COMPONENTS:
            continue
        index = indexes[pin.arch]
        if finding := package_issue(f"first-party-{pin.package}-{pin.arch}",
                                    f"{pin.package}={pin.version}", index, f"CeraLive stable/{pin.arch}"):
            issues.append(finding)

    certificate = base64.b64decode(os.environ["APT_CLIENT_CRT_B64"], validate=True)
    enddate = command(["openssl", "x509", "-noout", "-enddate"], input_bytes=certificate).decode().strip()
    if not enddate.startswith("notAfter="):
        raise RuntimeError("openssl did not report certificate notAfter")
    cert_expiry = datetime.strptime(enddate.removeprefix("notAfter="), "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    if finding := expiry_issue("apt-client-cert", "Image APT client certificate", cert_expiry, now, 120,
                               "Rotate the image repository secret and packaged credential; never paste certificate bytes into this issue."):
        issues.append(finding)

    boards = sorted(path.stem for path in (ROOT / "manifests/boards").glob("*.yaml"))
    for channel in CHANNELS:
        for board in boards:
            if finding := live_manifest(channel, board, now):
                issues.append(finding)
    return issues


def reconcile(issues: list[Issue]) -> None:
    command(["gh", "label", "create", LABEL, "--color", "0E8A16", "--force",
             "--description", "Scheduled pinned-input and expiry watch"])
    existing = json.loads(command(["gh", "issue", "list", "--label", LABEL, "--state", "open",
                                   "--limit", "1000", "--json", "number,title,body"]))
    if len(existing) >= 1000:
        raise RuntimeError("issue list truncated; refusing reconciliation")
    by_key = {match[1]: row for row in existing
              if (match := re.match(r"^\[upstream-watch:([a-z0-9-]+)\] ", row["title"]))}
    desired = {issue.key: issue for issue in issues}
    if len(desired) != len(issues):
        raise RuntimeError("duplicate watcher input identity")
    for key, issue in desired.items():
        old = by_key.get(key)
        if old is None:
            command(["gh", "issue", "create", "--label", LABEL, "--title", issue.title, "--body", issue.body])
        elif old["title"] != issue.title or old["body"] != issue.body:
            command(["gh", "issue", "edit", str(old["number"]), "--title", issue.title, "--body", issue.body])
    for key, old in by_key.items():
        if key not in desired:
            command(["gh", "issue", "close", str(old["number"]), "--comment", "Pinned input is current again; closed by the scheduled issue-only watch."])


def tree_digest() -> str:
    paths = command(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]).split(b"\0")
    digest = hashlib.sha256()
    for raw in sorted(set(paths) - {b""}):
        path = ROOT / os.fsdecode(raw)
        digest.update(raw)
        digest.update(path.read_bytes() if path.is_file() else os.readlink(path).encode())
    return digest.hexdigest()


def forbidden_write_calls(source: ast.AST) -> list[str]:
    forbidden = {"write_text", "write_bytes", "open", "rename", "unlink", "remove", "rmtree", "mkdir", "touch", "write"}
    calls: list[str] = []
    for node in ast.walk(source):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in forbidden:
            calls.append(node.func.attr)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in {"open", "exec", "eval"}:
            calls.append(node.func.id)
    return calls


def self_test() -> None:
    before = tree_digest()
    fixture = json.loads((ROOT / "ci/fixtures/upstream-watch.json").read_text())
    today = timestamp(fixture["today"])
    debian = fixture["debian"]
    assert debian_issue(debian["current"], debian["pinned_date"], "13") is None
    changed = debian_issue(debian["newer"], debian["pinned_date"], "13")
    assert changed and "13.1" in changed.body and debian["pinned_date"] in changed.body
    pkg = fixture["packages"]
    assert package_issue("armbian-test", pkg["pinned"], pkg["current"], "Armbian") is None
    changed = package_issue("armbian-test", pkg["pinned"], pkg["newer"], "Armbian")
    assert changed and "26.8.3" in changed.body and "26.9.0" in changed.body
    vanished = package_issue("armbian-test", pkg["pinned"], pkg["vanished"], "Armbian")
    assert vanished and "vanished" in vanished.body
    assert tag_issue("mkosi", "mkosi", "26", ["26"]) is None
    assert "27" in tag_issue("mkosi", "mkosi", "26", ["27"]).body
    assert tag_issue("kernel", "kernel", "v7.2", ["v7.2.0"]) is None
    assert "v7.2.1" in tag_issue("kernel", "kernel", "v7.2", ["v7.2.1"]).body
    assert package_issue("first-party", "cerastream=2026.9.6",
                         "Package: cerastream\nVersion: 2026.9.7\n\n", "CeraLive")
    assert expiry_issue("cert", "cert", today + timedelta(days=100), today, 120, "Rotate")
    assert expiry_issue("cert", "cert", today + timedelta(days=140), today, 120, "Rotate") is None
    manifest = fixture["manifest"]
    cmd = refresh_command(manifest["channel"], manifest["board"])
    assert cmd == manifest["refresh_command"]
    expiring = expiry_issue("channel", "channel", timestamp(manifest["expiring_20_days"]["expires_at"]),
                            today, 30, cmd)
    assert expiring and cmd in expiring.body
    assert expiry_issue("channel", "channel", timestamp(manifest["expiring_60_days"]["expires_at"]),
                        today, 30, cmd) is None
    assert forbidden_write_calls(ast.parse(fixture["forbidden_pin_write"])) == ["write_text"]
    assert forbidden_write_calls(ast.parse(Path(__file__).read_text())) == []
    try:
        command(["git", "add", "manifests/first-party-deb-versions.txt"])
    except RuntimeError:
        pass
    else:
        raise AssertionError("command allowlist permitted a pin write")
    assert tree_digest() == before, "self-test mutated the repository tree"
    print("PASS: current, newer, vanished, tags, certificate, manifest 20d/60d, exact refresh command, structural no-writes, entire checkout byte-identical")


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if len(sys.argv) != 1:
        print("usage: upstream-watch.py [--self-test]", file=sys.stderr)
        return 2
    try:
        issues = observe(datetime.now(timezone.utc))
        reconcile(issues)
    except (KeyError, PinError, OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"upstream watch incomplete; issues preserved: {exc}", file=sys.stderr)
        return 1
    print(f"Reconciled {len(issues)} input issue(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
