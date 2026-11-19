#!/usr/bin/env python3
"""Bootstrap metadata authentication and purpose-scoped freshness checks."""

from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime, parsedate_to_datetime
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import tempfile
from typing import Iterator
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
FINGERPRINT = "A" * 40
ORIGIN = "https://deb.debian.org/debian"
METADATA_URL = ORIGIN + "/dists/trixie/InRelease"
PACKAGE_URL = ORIGIN + "/pool/libstdc++6.deb"


@contextmanager
def bootstrap_fixture(case: str = "valid") -> Iterator[Path]:
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        objects = []

        def store(data: bytes, urls: tuple[str, ...] = ()) -> str:
            digest = hashlib.sha256(data).hexdigest()
            (work / digest).write_bytes(data)
            objects.append({"sha256": digest, "length": len(data),
                            "kind": "apt-metadata", "urls": list(urls)})
            return digest

        index_bytes = gzip.compress(b"Package: public-bootstrap-fixture\n")
        expected_index = hashlib.sha256(index_bytes).hexdigest()
        index = store(index_bytes if case != "index-hash" else index_bytes + b"changed")
        now = datetime.now(timezone.utc)
        date = now - timedelta(days=60 if case in ("missing-until", "other-origin", "missing-origin") else
                               3 if case in ("stale-date", "unsigned-prefix") else 0, minutes=1)
        until = now + timedelta(days=-1 if case in ("expired", "expired-no-space", "unsigned-prefix") else 1)
        origin = "Other" if case == "other-origin" else "Debian"
        release = f"Origin: {origin}\n" if case != "missing-origin" else ""
        release += "Suite: stable\nComponents: main\nArchitectures: arm64\n"
        if case == "codename":
            release += "Codename: trixie\n"
        if case != "missing-date":
            release += f"Date: {format_datetime(date)}\n"
        if case not in ("missing-until", "other-origin", "missing-origin"):
            space = "" if case == "expired-no-space" else " "
            release += f"Valid-Until:{space}{format_datetime(until)}\n"
        release += f"SHA256:\n {expected_index} {len(index_bytes)} main/binary-arm64/Packages.gz\n"
        original = release.encode()
        if case == "unsigned-prefix":
            original = (f"Date: {format_datetime(now)}\nValid-Until: {format_datetime(now + timedelta(days=2))}\n"
                        "FAKE_SIGNED_PAYLOAD\n").encode() + original
        inrelease = store(original, (METADATA_URL,))
        keyring = store(b"SYNTHETIC PUBLIC TRUST FIXTURE - NOT A KEY")
        store(b"public package fixture", (PACKAGE_URL,))
        record = {"origin": ORIGIN, "suite": "stable", "component": "main", "arch": "arm64",
                  "index_path": "main/binary-arm64/Packages.gz", "keyring": keyring,
                  "fingerprints": [FINGERPRINT], "inrelease": inrelease, "index": index}
        if case == "codename":
            record["codename"] = "trixie"
        approved = {key: value for key, value in record.items() if key not in ("inrelease", "index")}
        approved["max_age_seconds"] = 86400
        repositories = {"debian-bootstrap": record}
        policies = {"debian-bootstrap": approved}
        if case == "missing-policy":
            policies = {}
        if case == "undeclared":
            repositories = {}
            policies = {}
        (work / "inventory.json").write_text(json.dumps({"objects": objects, "repositories": repositories}))
        (work / "trust.json").write_text(json.dumps({"repositories": policies}))
        bin_dir = work / "bin"
        bin_dir.mkdir()
        gpgv = bin_dir / "gpgv"
        gpgv.write_text(
            "#!/usr/bin/env python3\nimport os, pathlib, sys\n"
            f"if {case == 'signature'}: sys.exit(1)\n"
            "args=sys.argv[1:]\n"
            "raw=pathlib.Path(args[-1]).read_bytes().split(b'FAKE_SIGNED_PAYLOAD\\n',1)[-1]\n"
            "pathlib.Path(args[args.index('--output')+1]).write_bytes(raw)\n"
            f"os.write(3, b'[GNUPG:] VALIDSIG {FINGERPRINT} 2026-11-16 0 0 4 0 1 10 00 {FINGERPRINT}\\n')\n")
        gpgv.chmod(0o755)
        with patch.dict(os.environ, {"PATH": str(bin_dir) + ":" + os.environ["PATH"],
                                    "HOME": str(work), "TMPDIR": str(work), "PYTHONDONTWRITEBYTECODE": "1",
                                    "CERALIVE_BUILD_PURPOSE": "full"}):
            yield work


def test_codename_is_verified_against_signed_metadata_and_independent_policy() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    with bootstrap_fixture("codename") as directory:
        module["mirror_validities"](directory)
        approved = json.loads((directory / "trust.json").read_text())
        approved["repositories"]["debian-bootstrap"]["codename"] = "bookworm"
        (directory / "trust.json").write_text(json.dumps(approved))
        try:
            module["mirror_validities"](directory)
        except module["SealedError"] as error:
            assert "independently approved trust policy" in str(error)
        else:
            raise AssertionError("capsule codename overrode independent policy")


def test_bootstrap_rejects_expired_missing_or_unauthenticated_metadata_before_serving() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    serve = module["serve"]
    for case in ("expired", "stale-date", "missing-date", "missing-until",
                 "missing-policy", "undeclared", "signature", "index-hash", "unsigned-prefix"):
        def forbidden_server(*_args):
            raise AssertionError(f"mirror admitted invalid bootstrap metadata: {case}")
        with bootstrap_fixture(case) as directory, patch.dict(serve.__globals__, {"HTTPServer": forbidden_server}):
            try:
                serve(directory)
            except module["SealedError"]:
                pass
            else:
                raise AssertionError(f"metadata validation did not fail closed: {case}")


def test_bootstrap_serves_original_bytes_only_after_signature_and_validity_checks() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    serve = module["serve"]
    with bootstrap_fixture() as directory:
        original = next(row["sha256"] for row in json.loads((directory / "inventory.json").read_text())["objects"]
                        if METADATA_URL in row["urls"])
        expected = (directory / original).read_bytes()
        responses = []
        output = io.BytesIO()
        class Server:
            def __init__(self, _address, handler):
                self.handler = handler
                self.calls = 0
            def __enter__(self):
                return self
            def __exit__(self, *_args):
                return False
            def handle_request(self):
                self.calls += 1
                assert self.calls <= 2
                request = self.handler.__new__(self.handler)
                request.path = METADATA_URL if self.calls == 1 else ORIGIN + "/missing"
                request.wfile = output
                request.send_response = responses.append
                request.send_error = responses.append
                request.send_header = lambda *_args: None
                request.end_headers = lambda: None
                request.do_GET()
        with patch.dict(serve.__globals__, {"HTTPServer": Server}):
            try:
                serve(directory)
            except module["SealedError"]:
                pass
        assert responses == [200, 404]
        assert output.getvalue() == expected


def test_bootstrap_stops_delivery_if_verified_metadata_expires_while_serving() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    serve = module["serve"]
    responses = []
    clock = serve.__globals__["datetime"]
    class FutureClock:
        @staticmethod
        def now(zone):
            return datetime.now(zone) + timedelta(days=2)
    class Server:
        def __init__(self, _address, handler):
            self.handler = handler
            serve.__globals__["datetime"] = FutureClock
        def __enter__(self):
            return self
        def __exit__(self, *_args):
            return False
        def handle_request(self):
            def unexpected_success(_code):
                raise AssertionError("expired metadata served")
            request = self.handler.__new__(self.handler)
            request.path = METADATA_URL
            request.send_error = responses.append
            request.send_response = unexpected_success
            request.do_GET()
    with bootstrap_fixture() as directory, patch.dict(serve.__globals__, {"HTTPServer": Server}):
        try:
            try:
                serve(directory)
            except module["SealedError"]:
                pass
        finally:
            serve.__globals__["datetime"] = clock
        assert responses == [410]
        assert (directory / "missing-object").is_file()


def test_measurement_accepts_missing_until_and_records_authenticated_date_digest_and_waiver() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    with bootstrap_fixture("missing-until") as directory:
        original = next(row["sha256"] for row in json.loads((directory / "inventory.json").read_text())["objects"]
                        if METADATA_URL in row["urls"])
        signed = (directory / original).read_bytes()
        date = next(line[6:] for line in signed.decode().splitlines() if line.startswith("Date: "))
        with patch.dict(os.environ, {"CERALIVE_BUILD_PURPOSE": "rootfs-measurement"}):
            module["mirror_validities"](directory)
        receipt = json.loads((directory / "metadata-validity.json").read_text())
        assert receipt == {
            "schema": 1, "purpose": "rootfs-measurement", "repositories": [{
                "repository": "debian-bootstrap",
                "release_date": parsedate_to_datetime(date).isoformat(),
                "release_sha256": hashlib.sha256(signed).hexdigest(),
                "freshness_checked": False, "freshness": "NOT checked",
            }],
        }


def test_measurement_rejects_present_expired_until() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    for case in ("expired", "expired-no-space"):
        with bootstrap_fixture(case) as directory, patch.dict(
                os.environ, {"CERALIVE_BUILD_PURPOSE": "rootfs-measurement"}):
            try:
                module["mirror_validities"](directory)
            except module["SealedError"] as error:
                assert "Valid-Until expired" in str(error)
            else:
                raise AssertionError("measurement accepted expired Valid-Until")
            assert not (directory / "metadata-validity.json").exists()


def test_non_measurement_purposes_reject_missing_until() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    for purpose in ("full", "candidate", "release", "future-production", ""):
        with bootstrap_fixture("missing-until") as directory, patch.dict(
                os.environ, {"CERALIVE_BUILD_PURPOSE": purpose}):
            try:
                module["mirror_validities"](directory)
            except module["SealedError"] as error:
                assert "missing or ambiguous signed metadata validity" in str(error)
            else:
                raise AssertionError(f"{purpose!r} accepted missing Valid-Until")
            assert not (directory / "metadata-validity.json").exists()


def test_debian_source_validity_rejects_missing_until_outside_measurement() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    for case in ("missing-until", "missing-origin"):
        with bootstrap_fixture(case) as directory:
            digest = json.loads((directory / "inventory.json").read_text())["repositories"]["debian-bootstrap"]["inrelease"]
            try:
                module["valid_release"](directory / digest, 86400)
            except module["SealedError"] as error:
                assert "missing or ambiguous signed metadata validity" in str(error)
            else:
                raise AssertionError("Debian source validation accepted missing Valid-Until")


def test_measurement_waiver_requires_authenticated_debian_origin() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    with bootstrap_fixture("other-origin") as directory, patch.dict(
            os.environ, {"CERALIVE_BUILD_PURPOSE": "rootfs-measurement"}):
        try:
            module["mirror_validities"](directory)
        except module["SealedError"] as error:
            assert "missing or ambiguous signed metadata validity" in str(error)
        else:
            raise AssertionError("measurement waived non-Debian metadata")


if __name__ == "__main__":
    tests = [test for name, test in list(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"bootstrap metadata: {len(tests)} passed")
