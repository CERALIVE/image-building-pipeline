#!/usr/bin/env python3
"""Metadata discovery through generated archive keys and localhost-only HTTPS."""

from datetime import datetime, timedelta, timezone
from email.utils import format_datetime, parsedate_to_datetime
import gzip
import hashlib
import json
from pathlib import Path
import re

from capsule_producer_test import ROOT, approve_redirects, bsp_urls, command, fixture, mirror_url, run
from capsule_transport_fixture import IDENTITY


def discovery(work: Path, reviewed: dict, producer_args: list[str]) -> list[str]:
    policy = json.loads((work / "policy.json").read_text())
    names = {row["repository"] for row in reviewed["packages"]}
    archive_policy = {"schema": 1, "repositories": {
        name: row for name, row in policy["repositories"].items() if name in names}}
    (work / "archives.json").write_text(json.dumps(archive_policy))
    (work / "selection.json").write_text(json.dumps({"packages": [
        {key: row[key] for key in ("repository", "name", "version", "arch")}
        for row in reviewed["packages"]]}))
    args = ["python3", str(ROOT / "ci/discover-image-metadata.py"),
            "--selection", str(work / "selection.json"), "--trust-policy", str(work / "archives.json"),
            "--output", str(work / "discovered")]
    for name in sorted(names):
        args += ["--keyring", name, str(work / policy["repositories"][name]["keyring"])]
    for option, count in (("--client-identity-config", 2), ("--ca-file", 2), ("--object-timeout", 2)):
        index = producer_args.index(option)
        args += producer_args[index:index + count]
    return args


def alter_signed_metadata(work: Path, reviewed: dict, remote: dict, case: str) -> None:
    repository = reviewed["repositories"]["firstparty"]
    release_url = "https://apt.ceralive.tv/dists/stable/binary-arm64/InRelease"
    index_url = release_url.removesuffix("InRelease") + repository["index_path"]
    original = remote[index_url]
    index = gzip.decompress(original).decode()
    match case:
        case "missing-version":
            index = index.replace("Version: 1.0", "Version: 9.0")
        case "wrong-arch" | "all-arch":
            index = index.replace("Architecture: arm64", "Architecture: all")
        case "duplicate-field":
            index = index.replace("Size: ", "Size: 1\nSize: ")
        case "missing-size":
            index = re.sub(r"Size: .*\n", "", index)
        case "invalid-size":
            index = re.sub(r"Size: .*\n", "Size: -1\n", index)
        case "unsafe-filename":
            index = re.sub(r"Filename: .*\n", "Filename: ../escape.deb\n", index)
        case "encoded-filename":
            index = re.sub(r"Filename: .*\n", "Filename: pool%2fescape.deb\n", index)
        case _:
            pass
    compressed = gzip.compress(index.encode(), mtime=0)
    source = work / "original-signed"
    source.write_bytes(remote[release_url])
    gpg = ["gpg", "--homedir", str(work / "gnupg"), "--batch", "--yes",
           "--pinentry-mode", "loopback", "--passphrase", ""]
    release = command(gpg + ["--decrypt", str(source)], work).decode()
    release = release.replace(hashlib.sha256(original).hexdigest(), hashlib.sha256(compressed).hexdigest())
    release = release.replace(f" {len(original)} {repository['index_path']}",
                              f" {len(compressed)} {repository['index_path']}")
    match case:
        case "index-size":
            release = release.replace(f" {len(compressed)} Packages.gz",
                                      f" {len(compressed) + 1} Packages.gz")
        case "duplicate-index":
            release += f" {hashlib.sha256(compressed).hexdigest()} {len(compressed)} Packages.gz\n"
        case "until-expired":
            past = datetime.now(timezone.utc) - timedelta(seconds=30)
            release = re.sub(r"Valid-Until: .*\n", f"Valid-Until: {format_datetime(past)}\n", release)
        case "missing-until":
            release = re.sub(r"Valid-Until: .*\n", "", release)
        case "firstparty-waiver":
            release = re.sub(r"Valid-Until: .*\n", "", release)
            release = release.replace("Origin: firstparty", "Origin: Debian")
            past = datetime.now(timezone.utc) - timedelta(days=3)
            release = re.sub(r"Date: .*\n", f"Date: {format_datetime(past)}\n", release)
        case "signed-release":
            del remote[release_url]
            release_url = release_url.removesuffix("InRelease") + "Release"
        case _:
            pass
    source.write_text(release)
    remote[release_url] = command(gpg + ["--armor", "--clearsign", "--output", "-", str(source)], work)
    remote[index_url] = compressed


def test_two_redirect_mirrors_give_identical_authenticated_rows_and_original_bytes() -> None:
    redirects = {}
    with fixture("bsp", redirects=redirects) as (work, reviewed, producer_args, env, requests, remote):
        approve_redirects(work, reviewed)
        fragments = []
        for mirror in ("mirror-a.example", "mirror-b.example"):
            args = discovery(work, reviewed, producer_args)
            expected = []
            redirects.clear()
            for url in bsp_urls(reviewed):
                if url.endswith(".deb"):
                    continue
                intermediate = mirror_url(url, mirror)
                relative = url.removeprefix("https://apt.armbian.com")
                final = "https://" + mirror + relative
                redirects.update({url: (302, intermediate), intermediate: (303, relative)})
                digest = next(row["sha256"] for row in reviewed["objects"] if row["urls"] == [url])
                expected.append({"sha256": digest, "url": url, "final_url": final, "redirects": [
                    {"status": 302, "from": url, "to": intermediate},
                    {"status": 303, "from": intermediate, "to": final}]})
            start = len(requests)

            result = run(args, env)

            assert result.returncode == 0, result.stderr
            directory = work / "discovered"
            fragments.append((directory / "inventory-fragment.json").read_bytes())
            fragment = json.loads(fragments[-1])
            receipt = json.loads((directory / "discovery.json").read_text())
            record = next(row for row in receipt["repositories"] if row["repository"] == "bsp")
            # Discovery requests Release before its authenticated index.
            assert record["transfers"] == list(reversed(expected))
            assert record["origin"] == "https://apt.armbian.com"
            assert fragment["repositories"]["bsp"] == reviewed["repositories"]["bsp"]
            for row in fragment["objects"]:
                for url in row["urls"]:
                    assert "mirror-" not in url
                    if row["kind"] == "apt-metadata":
                        assert (directory / "objects" / row["sha256"]).read_bytes() == remote[url]
            assert all(not authenticated for url, authenticated in requests[start:]
                       if not url.startswith("https://apt.ceralive.tv/"))
            assert not any(url.endswith(".deb") for url, _ in requests)
            directory.rename(work / mirror)
        assert fragments[0] == fragments[1]


def test_explicit_zero_redirect_policy_keeps_existing_discovery_bytes() -> None:
    with fixture() as (work, reviewed, producer_args, env, _requests, _remote):
        args = discovery(work, reviewed, producer_args)
        result = run(args, env)
        assert result.returncode == 0, result.stderr
        original = (work / "discovered/inventory-fragment.json").read_bytes()
        original_receipt = json.loads((work / "discovered/discovery.json").read_text())
        (work / "discovered").rename(work / "original")
        approve_redirects(work, reviewed, 0)
        args = discovery(work, reviewed, producer_args)

        result = run(args, env)

        assert result.returncode == 0, result.stderr
        assert (work / "discovered/inventory-fragment.json").read_bytes() == original
        receipt = json.loads((work / "discovered/discovery.json").read_text())
        del original_receipt["fetched_at"]
        del receipt["fetched_at"]
        assert receipt == original_receipt


def test_redirected_metadata_still_requires_original_signature_and_signed_index_hash() -> None:
    for suffix in ("InRelease", "Packages.gz"):
        redirects = {}
        with fixture("bsp", redirects=redirects) as (work, reviewed, producer_args, env, requests, remote):
            approve_redirects(work, reviewed)
            url = next(url for url in bsp_urls(reviewed) if url.endswith(suffix))
            redirects[url] = (302, mirror_url(url))
            if suffix == "InRelease":
                remote[url] = remote[url].replace(b"Suite: stable", b"Suite: forged")
            else:
                data = remote[url]
                remote[url] = data[:-1] + bytes([data[-1] ^ 1])
            args = discovery(work, reviewed, producer_args)

            result = run(args, env)

            assert result.returncode != 0, result.stderr
            assert "signed package lookup or control identity rejected" in result.stderr
            assert (mirror_url(url), False) in requests
            assert not any(request.endswith(".deb") for request, _ in requests)
            assert not (work / "discovered").exists()


def test_missing_redirected_metadata_names_object_and_target_without_output() -> None:
    redirects = {}
    with fixture("bsp", redirects=redirects) as (work, reviewed, producer_args, env, requests, _remote):
        approve_redirects(work, reviewed)
        url = next(url for url in bsp_urls(reviewed) if url.endswith("InRelease"))
        target = mirror_url(url).replace("/armbian/apt/", "/missing/")
        redirects[url] = (302, target)
        args = discovery(work, reviewed, producer_args)

        result = run(args, env)

        assert result.returncode != 0, result.stderr
        assert f"exact HTTPS GET failed for object signed at {target} (HTTP 404," in result.stderr
        assert requests == [(url, False), (target, False)]
        assert not (work / "discovered").exists()


def test_metadata_only_rows_feed_unchanged_producer_and_preserve_original_objects() -> None:
    with fixture("packages-xz") as (work, reviewed, producer_args, env, requests, remote):
        args = discovery(work, reviewed, producer_args)
        (work / ".curlrc").write_text("insecure\nlocation\nrequest = POST\n")
        env["HTTPS_PROXY"] = "http://127.0.0.1:1"
        started = datetime.now(timezone.utc).replace(microsecond=0)
        result = run(args, env)
        assert result.returncode == 0, result.stderr
        directory = work / "discovered"
        fragment = json.loads((directory / "inventory-fragment.json").read_text())
        receipt = json.loads((directory / "discovery.json").read_text())
        assert [row["repository"] for row in receipt["repositories"]] == ["bsp", "debian-binary", "firstparty"]
        assert set(fragment) == {"objects", "repositories", "packages"}
        assert fragment["packages"] == sorted(reviewed["packages"],
                                              key=lambda row: (row["repository"], row["name"], row["arch"]))
        assert fragment["repositories"] == {name: reviewed["repositories"][name]
                                            for name in ("firstparty", "bsp", "debian-binary")}
        assert set(receipt) == {"schema", "fetched_at", "repositories", "packages"}
        expected_digests = {row["sha256"] for row in reviewed["packages"]} | {
            reviewed["repositories"][name][key] for name in fragment["repositories"]
            for key in ("keyring", "inrelease", "index")}
        expected_objects = [
            (row | {"path": str(directory / "objects" / row["sha256"])}) if "path" in row else row
            for row in reviewed["objects"] if row["sha256"] in expected_digests]
        expected_fragment = {"packages": fragment["packages"],
                             "repositories": fragment["repositories"],
                             "objects": sorted(expected_objects, key=lambda row: row["sha256"])}
        assert (directory / "inventory-fragment.json").read_bytes() == (
            json.dumps(expected_fragment, sort_keys=True, separators=(",", ":")) + "\n").encode()
        metadata = {reviewed["repositories"][name][key]
                    for name in ("firstparty", "bsp", "debian-binary") for key in ("inrelease", "index")}
        expected_urls = {url for row in reviewed["objects"] if row["sha256"] in metadata for url in row["urls"]}
        assert {url for url, _ in requests} == expected_urls
        assert len(requests) == len(expected_urls)
        assert all(authenticated == url.startswith("https://apt.ceralive.tv/")
                   for url, authenticated in requests)
        for row in fragment["objects"]:
            if row["kind"] == "apt-metadata":
                original = remote[row["urls"][0]] if row["urls"] else (work / row["sha256"]).read_bytes()
                assert (directory / "objects" / row["sha256"]).read_bytes() == original
            else:
                assert not (directory / "objects" / row["sha256"]).exists()
        assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", receipt["fetched_at"])
        assert started <= datetime.fromisoformat(receipt["fetched_at"]) <= datetime.now(timezone.utc)
        for row in receipt["packages"]:
            assert row["arch"] == "arm64"
            assert row["filename"] == f"ceralive-device_{row['version']}_arm64.deb"
            assert row["index_sha256"] == reviewed["repositories"][row["repository"]]["index"]
            assert row["length"] == len(remote[row["url"]])
        for row in receipt["repositories"]:
            digest = reviewed["repositories"][row["repository"]]["inrelease"]
            signed = next(remote[url] for item in reviewed["objects"] if item["sha256"] == digest for url in item["urls"])
            date = re.search(rb"^Date: (.+)$", signed, re.MULTILINE).group(1).decode()
            until = re.search(rb"^Valid-Until: (.+)$", signed, re.MULTILINE).group(1).decode()
            assert row["release_date"] == parsedate_to_datetime(date).isoformat()
            assert row["valid_until"] == parsedate_to_datetime(until).isoformat()
        assert (directory.stat().st_mode & 0o777) == 0o700
        assert all((path.stat().st_mode & 0o777) == 0o600 for path in directory.rglob("*") if path.is_file())
        assert str(work / "client.key") not in (directory / "discovery.json").read_text()
        for name in ("client.pem", "client.key"):
            path = str(work / IDENTITY / name)
            for artifact in ("discovery.json", "inventory-fragment.json"):
                assert json.dumps(path)[1:-1] not in (directory / artifact).read_text()
            assert path not in result.stdout + result.stderr
        # Reordering the reviewed list must not change selected identities or request order.
        first_requests = list(requests)
        selection = json.loads((work / "selection.json").read_text())
        selection["packages"].reverse()
        (work / "selection.json").write_text(json.dumps(selection))
        args[args.index("--output") + 1] = str(work / "again")
        assert run(args, env).returncode == 0
        second = json.loads((work / "again/inventory-fragment.json").read_text())
        assert {key: second[key] for key in ("packages", "repositories")} == {
            key: fragment[key] for key in ("packages", "repositories")}
        assert requests[len(first_requests):] == first_requests
        # The producer consumes the fragment without new fields or a schema change.
        digests = {row["sha256"] for row in fragment["objects"]}
        reviewed["objects"] = [row for row in reviewed["objects"] if row["sha256"] not in digests]
        reviewed["objects"] += fragment["objects"]
        reviewed["repositories"].update(fragment["repositories"])
        reviewed["packages"] = fragment["packages"]
        (work / "reviewed.json").write_text(json.dumps(reviewed))
        produced = run(producer_args, env)
        assert produced.returncode == 0, produced.stderr


def test_rejected_metadata_never_downloads_payloads_or_publishes_partial_output() -> None:
    cases = ("signature", "index", "ambiguous", "expired", "missing-version", "wrong-arch",
             "duplicate-field", "missing-size", "invalid-size", "unsafe-filename", "encoded-filename",
             "index-size", "duplicate-index", "until-expired", "firstparty-waiver", "codename-suite-mismatch",
             "codename-mismatch", "codename-component", "codename-arch", "codename-duplicate")
    for case in cases:
        fixture_case = case if case in ("signature", "index", "ambiguous", "expired") or case.startswith("codename") else "valid"
        with fixture(fixture_case) as (work, reviewed, producer_args, env, requests, remote):
            args = discovery(work, reviewed, producer_args)
            if fixture_case == "valid":
                alter_signed_metadata(work, reviewed, remote, case)
            if case == "firstparty-waiver":
                env["CERALIVE_BUILD_PURPOSE"] = "rootfs-measurement"
            result = run(args, env)
            assert result.returncode != 0, case
            assert "metadata discovery rejected:" in result.stderr, (case, result.stderr)
            assert not any(url.endswith(".deb") for url, _ in requests), case
            assert not (work / "discovered").exists(), case
            assert not list(work.glob(".discovery-*")), case


def test_metadata_transport_reuses_tls_mtls_redirect_and_timeout_boundaries() -> None:
    for case in ("redirect", "same-origin-redirect", "oversize", "timeout", "hostname",
                 "untrusted-tls", "no-client"):
        with fixture(case) as (work, reviewed, producer_args, env, requests, _remote):
            args = discovery(work, reviewed, producer_args)
            if case == "untrusted-tls":
                args[args.index("--ca-file") + 1] = str(work / "untrusted-ca.pem")
            elif case == "no-client":
                index = args.index("--client-identity-config")
                del args[index:index + 2]
            result = run(args, env)
            assert result.returncode != 0, case
            assert "exact HTTPS GET failed" in result.stderr, (case, result.stderr)
            assert not any(url.endswith(".deb") or url.endswith("/redirected") for url, _ in requests)
            assert not (work / "discovered").exists()
            assert str(work / "client.pem") not in result.stderr
            assert str(work / "client.key") not in result.stderr
            for name in ("client.pem", "client.key"):
                assert str(work / IDENTITY / name) not in result.stderr


def test_missing_metadata_names_http_404_and_leaves_no_output_or_payload_requests() -> None:
    for missing_name in ("InRelease", "Release", "Packages.gz"):
        with fixture() as (work, reviewed, producer_args, env, requests, remote):
            args = discovery(work, reviewed, producer_args)
            private = work / "private"
            private.mkdir(mode=0o700)
            args[args.index("--output") + 1] = str(private / "discovered")
            if missing_name == "Release":
                alter_signed_metadata(work, reviewed, remote, "signed-release")
                args += ["--release-name", "firstparty", "Release"]
            missing_url = "https://apt.ceralive.tv/dists/stable/binary-arm64/" + missing_name
            del remote[missing_url]

            result = run(args, env)

            assert result.returncode != 0, missing_name
            assert "exact HTTPS GET failed for object" in result.stderr, result.stderr
            assert f"at {missing_url} (HTTP 404," in result.stderr, result.stderr
            assert result.stdout == ""
            assert str(work / "client.pem") not in result.stderr
            assert str(work / "client.key") not in result.stderr
            assert requests[-1] == (missing_url, True)
            assert not any(url.endswith(".deb") for url, _ in requests), requests
            assert list(private.iterdir()) == []


def test_approved_keyring_selection_and_origin_fail_before_any_request() -> None:
    for case in ("keyring", "fingerprint", "origin", "duplicate-selection", "client-origin", "format", "existing"):
        with fixture() as (work, reviewed, producer_args, env, requests, _remote):
            args = discovery(work, reviewed, producer_args)
            if case == "keyring":
                digest = reviewed["repositories"]["firstparty"]["keyring"]
                (work / digest).write_bytes(b"wrong fixture keyring")
            elif case in ("fingerprint", "origin"):
                policy = json.loads((work / "archives.json").read_text())
                policy["repositories"]["firstparty"][case if case == "origin" else "fingerprints"] = (
                    "https://other.example" if case == "origin" else ["A" * 40])
                (work / "archives.json").write_text(json.dumps(policy))
            elif case == "duplicate-selection":
                selection = json.loads((work / "selection.json").read_text())
                selection["packages"] += selection["packages"]
                (work / "selection.json").write_text(json.dumps(selection))
            elif case == "client-origin":
                config = work / "client-identities"
                config.write_text(config.read_text().replace("apt.ceralive.tv", "other.example"))
            elif case == "format":
                policy = json.loads((work / "archives.json").read_text())
                policy["repositories"]["firstparty"]["index_path"] = "Sources.xz"
                (work / "archives.json").write_text(json.dumps(policy))
            else:
                (work / "discovered").mkdir()
                (work / "discovered/keep").write_text("owned before invocation")
            result = run(args, env)
            assert result.returncode != 0, case
            assert requests == [], case
            if case == "existing":
                assert (work / "discovered/keep").read_text() == "owned before invocation"


def test_explicit_signed_release_and_absent_firstparty_until_keep_original_metadata() -> None:
    for case in ("signed-release", "missing-until", "all-arch", "codename"):
        with fixture("codename" if case == "codename" else "valid") as (work, reviewed, producer_args, env, requests, remote):
            args = discovery(work, reviewed, producer_args)
            if case != "codename":
                alter_signed_metadata(work, reviewed, remote, case)
            if case == "all-arch":
                selection = json.loads((work / "selection.json").read_text())
                next(row for row in selection["packages"] if row["repository"] == "firstparty")["arch"] = "all"
                (work / "selection.json").write_text(json.dumps(selection))
            if case == "signed-release":
                args += ["--release-name", "firstparty", "Release"]
            result = run(args, env)
            assert result.returncode == 0, result.stderr
            receipt = json.loads((work / "discovered/discovery.json").read_text())
            row = next(row for row in receipt["repositories"] if row["repository"] == "firstparty")
            assert (row["valid_until"] is None) == (case == "missing-until")
            if case == "all-arch":
                assert next(row for row in receipt["packages"] if row["repository"] == "firstparty")["arch"] == "all"
            if case == "signed-release":
                assert ("https://apt.ceralive.tv/dists/stable/binary-arm64/InRelease", True) not in requests
                assert ("https://apt.ceralive.tv/dists/stable/binary-arm64/Release", True) in requests


if __name__ == "__main__":
    for name, function in list(globals().items()):
        if name.startswith("test_"):
            function()
            print("PASS", name)
