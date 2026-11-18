#!/usr/bin/env python3
"""Exercise original signature/index/package validators with synthetic bytes only."""

from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
import gzip
import hashlib
import io
import json
import lzma
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import runpy
from unittest.mock import patch
from bootstrap_metadata_test import bootstrap_fixture

ROOT = Path(__file__).resolve().parents[1]
FINGERPRINT = "A" * 40


def deb(version: str, arch: str) -> bytes:
    control = io.BytesIO()
    with tarfile.open(fileobj=control, mode="w:gz") as archive:
        data = f"Package: ceralive-device\nVersion: {version}\nArchitecture: {arch}\n".encode()
        header = tarfile.TarInfo("./control")
        header.size = len(data)
        archive.addfile(header, io.BytesIO(data))
    result = b"!<arch>\n"
    for name, data in (("debian-binary", b"2.0\n"), ("control.tar.gz", control.getvalue())):
        header = f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n".encode()
        result += header + data + (b"\n" if len(data) % 2 else b"")
    return result


def scenario(case: str) -> tuple[int, str]:
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        objects = work / "objects"
        objects.mkdir()
        bin_dir = work / "bin"
        bin_dir.mkdir()
        rows = []

        def store(data: bytes, urls: list[str] | None = None) -> str:
            digest = hashlib.sha256(data).hexdigest()
            (objects / digest).write_bytes(data)
            rows.append({"sha256": digest, "length": len(data), "kind": "apt-metadata", "urls": urls or []})
            return digest

        version = "2.0" if case == "version" else "1.0"
        architecture = "amd64" if case == "architecture" else "arm64"
        package = deb(version, architecture)
        digest = hashlib.sha256(package).hexdigest()
        index = (f"Package: ceralive-device\nVersion: 1.0\nArchitecture: arm64\n"
                 f"Filename: ./ceralive-device_1.0_arm64.deb\nSize: {len(package)}\nSHA256: {digest}\n\n").encode()
        if case == "ambiguous":
            index += index
        compressed = gzip.compress(index)
        index_digest = hashlib.sha256(compressed).hexdigest()
        date = datetime.now(timezone.utc) - timedelta(days=60 if case == "expired" else 0)
        release = (f"Suite: stable\nComponents: main\nArchitectures: arm64\nDate: {format_datetime(date)}\n"
                   f"SHA256:\n {index_digest} {len(compressed)} Packages.gz\n").encode()
        inrelease = store(release)
        index_object = store(compressed if case != "index-hash" else compressed + b"tampered")
        keyring = store(b"SYNTHETIC PUBLIC TRUST FIXTURE - NOT A KEY")
        url = "https://apt.ceralive.tv/dists/stable/binary-arm64/ceralive-device_1.0_arm64.deb"
        store(package if case != "package-hash" else package + b"tampered", [url])
        repo = {"origin": "https://apt.ceralive.tv", "suite": "stable", "component": "main",
                "arch": "arm64", "index_path": "Packages.gz", "keyring": keyring,
                "fingerprints": [FINGERPRINT], "inrelease": inrelease, "index": index_object}
        policy = {key: value for key, value in repo.items() if key not in ("inrelease", "index")}
        policy["max_age_seconds"] = 86400
        if case == "trust":
            policy["keyring"] = "b" * 64
        (objects / "inventory.json").write_text(json.dumps({"objects": rows, "repositories": {"firstparty": repo}}))
        (objects / "trust.json").write_text(json.dumps({"repositories": {"firstparty": policy}}))
        (bin_dir / "gpgv").write_text(
            "#!/usr/bin/env python3\nimport os, pathlib, sys\n"
            "if os.environ.get('SIGNATURE_FAIL') == '1': sys.exit(1)\n"
            "args=sys.argv[1:]\n"
            "pathlib.Path(args[args.index('--output')+1]).write_bytes(pathlib.Path(args[-1]).read_bytes())\n"
            f"os.write(3, b'[GNUPG:] VALIDSIG {FINGERPRINT} 2026-11-16 0 0 4 0 1 10 00 {FINGERPRINT}\\n')\n")
        (bin_dir / "curl").write_text("#!/bin/sh\nprintf 'NETWORK ATTEMPT\\n' >&2\nexit 99\n")
        for file in bin_dir.iterdir():
            file.chmod(0o755)
        destination = work / "debs"
        destination.mkdir()
        env = {"PATH": str(bin_dir) + ":" + os.environ["PATH"], "HOME": str(work), "TMPDIR": str(work),
               "PYTHONDONTWRITEBYTECODE": "1",
               "CERALIVE_SEALED_INPUTS": str(objects), "CERALIVE_DEBCACHE": "0",
               "ARCH": "arm64", "SIGNATURE_FAIL": "1" if case == "signature" else "0",
               "CERALIVE_BUILD_MODE": "production"}
        if case == "origin":
            env["APT_CERALIVE_URL"] = "https://unapproved.invalid"
        script = (
            'source "$1/lib/fetch-debs.sh"\n'
            'sealed_repository firstparty "$2/state"\n'
            '_SEALED_BASE=https://apt.ceralive.tv/dists/stable/binary-arm64\n'
            '_SEALED_DEBS="$2/debs"\n'
            'sealed_stage_deb ceralive-device=1.0\n'
            '[[ "$CERALIVE_BUILD_MODE" == production ]]\n'
            '[[ -s "$2/debs/ceralive-device_1.0_arm64.deb" ]]\n'
            '_FIRST_PARTY_INDEX="$_SEALED_INDEX"; DEST="$2"\n'
            'printf "[]\\n" >"$2/first-party-local-override.json"\n'
            'fetch_lock_sidecar\n')
        result = subprocess.run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT), str(work)],
                                env=env, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            row = json.loads((work / "packages-lock/fetch.jsonl").read_text())
            assert row == {"name": "ceralive-device", "version": "1.0", "arch": "arm64",
                           "origin": "first-party", "sha256": digest}
        return result.returncode, result.stdout + result.stderr


def test_sealed_import_preserves_production_and_original_authenticated_origin() -> None:
    code, output = scenario("valid")
    assert code == 0, output
    assert "NETWORK ATTEMPT" not in output


def test_index_decoding_keeps_original_bytes_and_enforces_one_shared_size_bound() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    decode = module["decompress_index"]
    with tempfile.TemporaryDirectory() as temporary, patch.dict(decode.__globals__, {"INDEX_LIMIT": 32}):
        source = Path(temporary) / "original"
        destination = Path(temporary) / "Packages"
        for suffix, compress in ((".gz", gzip.compress), (".xz", lzma.compress)):
            for length in (31, 32):
                payload = b"x" * length
                original = compress(payload)
                source.write_bytes(original)
                decode(source, destination, "main/binary-arm64/Packages" + suffix)
                assert destination.read_bytes() == payload
                assert source.read_bytes() == original
            for original in (compress(b"x" * 33), compress(b"x" * 16) + compress(b"x" * 17),
                             compress(b"valid")[:-1], b"invalid compressed bytes"):
                source.write_bytes(original)
                try:
                    decode(source, destination, "main/binary-arm64/Packages" + suffix)
                except module["SealedError"] as error:
                    assert "invalid or oversized compressed package index" in str(error)
                else:
                    raise AssertionError(f"invalid or oversized {suffix} index accepted")
                assert not destination.exists()
                assert source.read_bytes() == original
        source.write_bytes(gzip.compress(b"valid"))
        try:
            decode(source, destination, "Packages.bz2")
        except module["SealedError"] as error:
            assert "unsupported compressed package index" in str(error)
        else:
            raise AssertionError("unsupported index format accepted")
        assert not destination.exists()


def test_xz_decoding_rejects_every_invalid_stream_and_trailing_byte() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    decode = module["decompress_index"]
    first = lzma.compress(b"first")
    second = lzma.compress(b"second")
    corrupt_header = bytearray(second)
    corrupt_header[8] ^= 1
    corrupt_footer = bytearray(second)
    corrupt_footer[-12] ^= 1
    cases = (
        ("corrupt-second-header", first + bytes(corrupt_header)),
        ("corrupt-second-footer", first + bytes(corrupt_footer)),
        ("corrupt-third-header", first + second + bytes(corrupt_header)),
        ("trailing-garbage", first + b"garbage"),
        ("long-trailing-garbage", first + b"trailing non-stream bytes"),
        ("truncated-first", first[:-1]),
        ("truncated-second-header", first + second[:5]),
        ("truncated-second-footer", first + second[:-1]),
        ("truncated-third-footer", first + second + second[:-1]),
        ("misaligned-padding", first + b"\0" + second),
        ("misaligned-final-padding", first + b"\0" * 3),
        ("padding-before-garbage", first + b"\0" * 4 + b"garbage"),
        ("padding-before-long-garbage", first + b"\0" * 4 + b"trailing non-stream bytes"),
        ("empty-input", b""),
    )
    accepted = []
    with tempfile.TemporaryDirectory() as temporary:
        source = Path(temporary) / "original"
        destination = Path(temporary) / "Packages"
        for name, original in cases:
            source.write_bytes(original)
            try:
                decode(source, destination, "Packages.xz")
            except module["SealedError"] as error:
                assert "invalid or oversized compressed package index" in str(error), name
                assert not destination.exists(), name
            else:
                accepted.append(name)
            assert source.read_bytes() == original, name
    assert accepted == [], f"invalid xz input accepted: {accepted}"


def test_valid_concatenated_indexes_preserve_all_streams_and_padding() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    decode = module["decompress_index"]
    first, second = b"a" * 16, b"b" * 16
    with tempfile.TemporaryDirectory() as temporary, patch.dict(decode.__globals__, {"INDEX_LIMIT": 32}):
        source = Path(temporary) / "original"
        destination = Path(temporary) / "Packages"
        for suffix, compress in ((".gz", gzip.compress), (".xz", lzma.compress)):
            for padding in (b"", b"\0" * 4, b"\0" * (1024 * 1024)):
                original = compress(first) + padding + compress(second) + b"\0" * 8
                source.write_bytes(original)
                decode(source, destination, "Packages" + suffix)
                assert destination.read_bytes() == first + second
                assert source.read_bytes() == original
        payload = b"x" * (1024 * 1024 + 1) + b"tail"
        original = lzma.compress(payload[:-4]) + lzma.compress(payload[-4:])
        source.write_bytes(original)
        with patch.dict(decode.__globals__, {"INDEX_LIMIT": len(payload)}):
            decode(source, destination, "Packages.xz")
        assert destination.read_bytes() == payload
        assert source.read_bytes() == original


def test_sealed_import_rejects_signature_index_package_identity_and_validity_failures() -> None:
    for case, expected in (
        ("signature", "signature rejected"), ("index-hash", "index digest mismatch"),
        ("package-hash", "signature/hash/control chain rejected"),
        ("version", "signature/hash/control chain rejected"),
        ("architecture", "signature/hash/control chain rejected"),
        ("ambiguous", "missing or ambiguous"), ("expired", "metadata validity rejected"),
        ("trust", "independently approved trust policy"),
        ("origin", "logical origin mismatch"),
    ):
        code, output = scenario(case)
        assert code != 0 and expected in output, f"{case}: {output}"
        assert "NETWORK ATTEMPT" not in output


def test_missing_guest_mirror_object_latches_failure_even_if_client_ignores_404() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    serve = module["serve"]
    codes = []
    with bootstrap_fixture() as work:
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
                assert self.calls == 1, "mirror continued after an absent input"
                request = self.handler.__new__(self.handler)
                request.path = "http://deb.debian.org/debian/missing"
                request.send_error = codes.append
                request.do_GET()
        original = serve.__globals__["HTTPServer"]
        serve.__globals__["HTTPServer"] = Server
        try:
            try:
                serve(work)
            except module["SealedError"]:
                pass
            else:
                raise AssertionError("absent mirror object accepted")
        finally:
            serve.__globals__["HTTPServer"] = original
        assert codes == [404]
        assert (work / "missing-object").is_file()


def test_guest_mirror_matches_encoded_package_urls_without_changing_origin() -> None:
    module = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
    serve = module["serve"]
    responses = []
    output = io.BytesIO()
    with bootstrap_fixture() as work:
        data = b"public package fixture"
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
                request.path = ("http://deb.debian.org/debian/pool/libstdc%2b%2b6.deb"
                                if self.calls == 1 else "http://unapproved.invalid/missing")
                request.wfile = output
                request.send_response = responses.append
                request.send_error = responses.append
                request.send_header = lambda *_args: None
                request.end_headers = lambda: None
                request.do_GET()
        original = serve.__globals__["HTTPServer"]
        serve.__globals__["HTTPServer"] = Server
        try:
            try:
                serve(work)
            except module["SealedError"]:
                pass
        finally:
            serve.__globals__["HTTPServer"] = original
        assert responses == [200, 404]
        assert output.getvalue() == data


if __name__ == "__main__":
    tests = [test for name, test in list(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"sealed input: {len(tests)} passed")
