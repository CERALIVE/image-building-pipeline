#!/usr/bin/env python3
"""Source discovery with generated keys, staged files and localhost-only HTTPS."""

from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
import gzip
import hashlib
import json
import lzma
import os
from pathlib import Path
import shutil

from capsule_producer_test import ROOT, command, fixture, run


@contextmanager
def source_fixture(case: str = "valid"):
    with fixture() as (work, reviewed, producer_args, env, requests, remote):
        names = ("rauc_1.15.2-1.dsc", "rauc_1.15.2.orig.tar.xz", "rauc_1.15.2-1.debian.tar.xz")
        payloads = {name: ("staged " + name).encode() for name in names}
        paths = {}
        for name, data in payloads.items():
            # The staged upstream tarball need not have Debian's filename.
            path = work / ("rauc-1.15.2.tar.xz" if ".orig." in name else name)
            path.write_bytes(data)
            paths[name] = str(path)
        stanza = "Package: rauc\nVersion: 1.15.2-1\nDirectory: pool/main/r/rauc\nFiles:\n"
        stanza += "".join(f" {'0' * 32} {len(data)} {name}\n" for name, data in payloads.items())
        stanza += "Checksums-Sha256:\n"
        stanza += "".join(f" {hashlib.sha256(data).hexdigest()} {len(data)} {name}\n"
                           for name, data in payloads.items())
        stanza += "\n"
        match case:
            case "missing-source":
                stanza = stanza.replace("Package: rauc", "Package: other")
            case "missing-version":
                stanza = stanza.replace("Version: 1.15.2-1", "Version: 1.15.2-2")
            case "duplicate-stanza":
                stanza += stanza
            case "duplicate-field":
                stanza = stanza.replace("Version:", "Package: rauc\nVersion:")
            case "duplicate-file":
                stanza = stanza.rstrip() + "\n" + stanza.split("Checksums-Sha256:\n")[1]
            case "files-size":
                stanza = stanza.replace(f"{len(payloads[names[0]])} {names[0]}", f"1 {names[0]}", 1)
            case "files-missing":
                stanza = stanza.replace(f" {'0' * 32} {len(payloads[names[0]])} {names[0]}\n", "")
            case "directory" | "encoded-directory" | "absolute-directory":
                directory = {"directory": "../escape", "encoded-directory": "pool/%2e%2e/escape",
                             "absolute-directory": "/pool/main/r/rauc"}[case]
                stanza = stanza.replace("pool/main/r/rauc", directory)
            case "filename":
                stanza = stanza.replace(names[0], "../escape.dsc")
            case "digest":
                stanza = stanza.replace(hashlib.sha256(payloads[names[0]]).hexdigest(), "a" * 64)
            case "size":
                stanza = stanza.replace(f"{len(payloads[names[0]])} {names[0]}", f"1 {names[0]}")
            case "local-missing":
                Path(paths[names[0]]).unlink()
            case "local-symlink":
                alias = work / "alias.dsc"
                alias.symlink_to(paths[names[0]])
                paths[names[0]] = str(alias)
            case "local-directory":
                paths[names[0]] = str(work)
            case "local-fifo":
                fifo = work / "fifo"
                os.mkfifo(fifo)
                paths[names[0]] = str(fifo)
            case "local-parent-symlink":
                alias = work / "alias"
                alias.symlink_to(work, target_is_directory=True)
                paths[names[0]] = str(alias / names[0])
            case "selection-missing":
                del paths[names[0]]
            case "selection-extra":
                paths["extra.tar.xz"] = paths[names[0]]
        index_path = "main/source/Sources." + ("gz" if case == "gzip" else "xz")
        compressed = gzip.compress(stanza.encode(), mtime=0) if case == "gzip" else lzma.compress(stanza.encode())
        if case == "later-xz":
            compressed += lzma.compress(b"later stream")[:-5]
        origin = "https://deb.debian.org/debian"
        base = origin + "/dists/unstable"
        release_name = "Release" if case == "signed-release" else "InRelease"
        index_url, release_url = base + "/" + index_path, base + "/" + release_name
        now = datetime.now(timezone.utc)
        date = now - timedelta(days=3 if case.startswith("waiver") else 0, minutes=1)
        release = ("Origin: Debian\nSuite: unstable\nCodename: unstable\nComponents: main\n"
                   f"Architectures: source arm64\nDate: {format_datetime(date)}\n")
        if not case.startswith("waiver"):
            until = now + timedelta(days=-1 if case == "expired" else 1)
            release += f"Valid-Until: {format_datetime(until)}\n"
        signed_size = len(compressed) + (1 if case == "index-size" else 0)
        release += f"SHA256:\n {hashlib.sha256(compressed).hexdigest()} {signed_size} {index_path}\n"
        if case == "suite":
            release = release.replace("Suite: unstable", "Suite: testing")
        if case == "component":
            release = release.replace("Components: main", "Components: contrib")
        if case == "codename":
            release = release.replace("Codename: unstable", "Codename: other")
        source = work / "source-Release"
        source.write_text(release)
        gpg = ["gpg", "--homedir", str(work / "gnupg"), "--batch", "--yes",
               "--pinentry-mode", "loopback", "--passphrase", ""]
        signed = command(gpg + ["--armor", "--clearsign", "--output", "-", str(source)], work)
        remote[release_url] = signed.replace(b"Suite: unstable", b"Suite: tampered") if case == "signature" else signed
        remote[index_url] = compressed[:-1] + bytes([compressed[-1] ^ 1]) if case == "index-digest" else compressed
        if case == "index-404":
            del remote[index_url]
        policy = json.loads((work / "policy.json").read_text())
        repo = policy["repositories"]["debian-source"]
        repo.update(suite="unstable", codename="unstable", index_path=index_path)
        (work / "policy.json").write_text(json.dumps(policy))
        (work / "archives.json").write_text(json.dumps({"schema": 1, "repositories": {"debian-source": repo}}))
        selection = {"sources": [{"repository": "debian-source", "name": "rauc",
                                  "version": "1.15.2-1", "files": paths}]}
        (work / "selection.json").write_text(json.dumps(selection))
        args = ["python3", str(ROOT / "ci/discover-image-metadata.py"),
                "--selection", str(work / "selection.json"), "--trust-policy", str(work / "archives.json"),
                "--keyring", "debian-source", str(work / repo["keyring"]),
                "--ca-file", str(work / "ca.pem"), "--output", str(work / "discovered")]
        if case == "signed-release":
            args += ["--release-name", "debian-source", "Release"]
        if case in ("waiver-measurement", "expired"):
            env["CERALIVE_BUILD_PURPOSE"] = "rootfs-measurement"
        yield work, reviewed, producer_args, args, env, requests, remote, payloads, paths


def test_source_files_match_staged_inputs_and_feed_unchanged_producer() -> None:
    for case in ("valid", "gzip", "waiver-measurement", "signed-release"):
        with source_fixture(case) as (work, reviewed, producer_args, args, env, requests, remote, payloads, paths):
            result = run(args, env)
            assert result.returncode == 0, result.stderr
            directory = work / "discovered"
            fragment_bytes = (directory / "inventory-fragment.json").read_bytes()
            fragment = json.loads(fragment_bytes)
            receipt = json.loads((directory / "discovery.json").read_text())
            repo = fragment["repositories"]["debian-source"]
            index_url = f"{repo['origin']}/dists/unstable/{repo['index_path']}"
            release_name = "Release" if case == "signed-release" else "InRelease"
            assert requests == [(repo["origin"] + "/dists/unstable/" + release_name, False), (index_url, False)]
            expected = [{"sha256": hashlib.sha256(data).hexdigest(), "length": len(data),
                         "kind": "pinned-source", "urls": [repo["origin"] + "/pool/main/r/rauc/" + name],
                         "path": paths[name]} for name, data in payloads.items()]
            assert [row for row in fragment["objects"] if row["kind"] == "pinned-source"] == sorted(
                expected, key=lambda row: row["sha256"])
            assert fragment["packages"] == []
            assert receipt["sources"] == [
                {"repository": "debian-source", "name": "rauc", "version": "1.15.2-1",
                 "filename": name, "directory": "pool/main/r/rauc", "path": paths[name],
                 "sha256": hashlib.sha256(data).hexdigest(), "length": len(data),
                 "url": repo["origin"] + "/pool/main/r/rauc/" + name, "index_sha256": repo["index"],
                 "origin": repo["origin"]} for name, data in sorted(payloads.items())]
            for row in fragment["objects"]:
                if row["kind"] == "apt-metadata":
                    original = remote[row["urls"][0]] if row["urls"] else (work / repo["keyring"]).read_bytes()
                    assert (directory / "objects" / row["sha256"]).read_bytes() == original
                else:
                    assert not (directory / "objects" / row["sha256"]).exists()
            assert directory.stat().st_mode & 0o777 == 0o700
            assert all(path.stat().st_mode & 0o777 == 0o600 for path in directory.rglob("*") if path.is_file())
            selection = json.loads((work / "selection.json").read_text())
            selection["sources"][0]["files"] = dict(reversed(list(paths.items())))
            (work / "selection.json").write_text(json.dumps(selection))
            # Use the same output path so retained keyring paths also stay identical.
            shutil.rmtree(directory)
            assert run(args, env).returncode == 0
            assert (directory / "inventory-fragment.json").read_bytes() == fragment_bytes
            digests = {row["sha256"] for row in fragment["objects"]} | {
                reviewed["repositories"]["debian-source"][key] for key in ("inrelease", "index")}
            reviewed["objects"] = [row for row in reviewed["objects"] if row["sha256"] not in digests]
            reviewed["objects"] += fragment["objects"]
            reviewed["repositories"].update(fragment["repositories"])
            (work / "reviewed.json").write_text(json.dumps(reviewed))
            produced = run(producer_args, env)
            assert produced.returncode == 0, produced.stderr
            assert not any(url.endswith(tuple(payloads)) for url, _ in requests)


def test_source_rejections_publish_nothing_and_never_request_payloads() -> None:
    cases = {
        "missing-source": "signed package lookup", "missing-version": "signed package lookup",
        "duplicate-stanza": "signed package lookup", "duplicate-field": "signed package lookup",
        "duplicate-file": "signed package lookup", "files-size": "signed package lookup",
        "files-missing": "signed package lookup", "directory": "signed source",
        "encoded-directory": "traversal", "absolute-directory": "signed source",
        "filename": "signed source", "digest": "staged source", "size": "staged source",
        "local-missing": "staged source", "local-symlink": "staged source",
        "local-directory": "staged source", "selection-missing": "source file selection",
        "local-fifo": "staged source", "local-parent-symlink": "staged source",
        "selection-extra": "source file selection", "later-xz": "compressed package index",
        "index-404": "HTTP 404", "index-digest": "signed package lookup",
        "index-size": "signed Size", "signature": "signed package lookup",
        "suite": "signed package lookup", "component": "signed package lookup",
        "codename": "signed package lookup", "waiver-full": "signed metadata validity",
        "expired": "Valid-Until expired",
    }
    for case, expected in cases.items():
        with source_fixture(case) as (work, _reviewed, _producer_args, args, env, requests, _remote, _payloads, _paths):
            result = run(args, env)
            assert result.returncode != 0, case
            assert expected in result.stderr, (case, result.stderr)
            assert result.stdout == "", case
            assert not (work / "discovered").exists(), case
            assert not list(work.glob(".discovery-*")), case
            assert all(url.endswith(("InRelease", "Sources.xz")) for url, _ in requests), (case, requests)


if __name__ == "__main__":
    for name, function in list(globals().items()):
        if name.startswith("test_"):
            function()
            print("PASS", name)
