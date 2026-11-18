"""Credential eligibility is independent of download approval."""

import json
from unittest.mock import patch
from urllib.parse import urlsplit

from capsule_producer_test import ROOT, fixture, run
from image_policy import archive_policies
from image_stream import StreamError
from image_transport import fetch
from metadata_discovery_test import discovery


def test_archive_policy_rejects_an_identity_for_an_anonymous_repository() -> None:
    with fixture() as (work, _, _, _, requests, _):
        rows = json.loads((work / "policy.json").read_text())["repositories"]
        for origin in ("https://deb.debian.org/debian", "https://apt.ceralive.tv"):
            if origin == "https://apt.ceralive.tv":
                rows["debian-binary"] = rows["firstparty"]
            try:
                archive_policies(rows, [origin])
            except StreamError as exc:
                assert urlsplit(origin).hostname in str(exc)
            else:
                raise AssertionError("download approval authorized a client identity")
            assert requests == []


def test_identity_forms_reject_anonymous_and_lookalike_origins_before_get() -> None:
    with fixture("bsp") as (work, reviewed, producer, env, requests, _):
        cfg = work / "client-identities"
        for cli in (producer, discovery(work, reviewed, producer)):
            index = cli.index("--client-identity-config")
            for origin in ("https://deb.debian.org", "https://deb.debian.org/debian",
                           "https://deb.debian.org/debian-security", "https://apt.armbian.com",
                           "https://apt.ceralive.tv.evil.example", "https://apt.ceralive.tv@evil.example"):
                paths = [str(work / name) for name in ("client.pem", "client.key")]
                cfg.write_text(" ".join([origin, *paths]) + "\n")
                for flags in (cli[index:index + 2], ["--client-identity", origin, *paths]):
                    result = run(cli[:index] + flags + cli[index + 2:], env)
                    assert requests == [], "ineligible binding reached the network"
                    assert result.returncode != 0 and urlsplit(origin).hostname in result.stderr, result.stderr
                    assert all(p not in result.stderr for p in paths) and "tv@" not in result.stderr


def test_transport_refuses_wrong_repository_or_request_host_without_curl() -> None:
    with fixture() as (work, _, _, env, requests, _), patch("subprocess.run") as curl:
        for repo, url in (("debian-binary", "https://apt.ceralive.tv/index"),
                          ("firstparty", "https://deb.debian.org/index")):
            try:
                fetch(url, work / "index", 10, ("/fixture/cert", "/fixture/key"), None, 1, env, repo, 0)
            except StreamError as exc:
                assert urlsplit(url).hostname in str(exc)
            else:
                raise AssertionError("credentialed transport accepted an ineligible request")
            curl.assert_not_called()
            assert requests == []


def test_shared_bsp_metadata_rejects_conflicting_policy_in_either_order() -> None:
    with fixture("bsp") as (work, reviewed, args, env, requests, _):
        policy = json.loads((work / "policy.json").read_text())
        for other_first in (False, True):
            for rows in (reviewed["repositories"], policy["repositories"]):
                bsp = rows.pop("bsp")
                rows.pop("other", None)
                anonymous = dict(bsp)
                anonymous.pop("max_redirects", None)
                pair = [("bsp", bsp | {"max_redirects": 2}), ("other", anonymous)]
                rows.update(reversed(pair) if other_first else pair)
            (work / "reviewed.json").write_text(json.dumps(reviewed))
            (work / "policy.json").write_text(json.dumps(policy))
            result = run(args, env)
            assert requests == [] and result.returncode != 0
            assert "conflicting" in result.stderr and reviewed["repositories"]["bsp"]["inrelease"] in result.stderr


def test_missing_required_flags_remain_actionable() -> None:
    with fixture() as (work, _, _, env, requests, _):
        for script, missing in (("discover-image-metadata.py", "--selection"),
                                ("prepare-image-capsule.py", "--inventory")):
            secret = str(work / "client.key")
            result = run(["python3", str(ROOT / "ci" / script), secret], env)
            assert result.returncode != 0 and secret not in result.stderr
            assert missing in result.stderr.split("error:")[-1]
            assert requests == []


if __name__ == "__main__":
    for name, function in list(globals().items()):
        if name.startswith("test_"):
            function()
            print("PASS", name)
