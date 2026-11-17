#!/usr/bin/env python3
"""Unprivileged image transport regressions; never start QEMU or read credentials."""

import hashlib
import io
import json
import pathlib
import sys
import tempfile
import tarfile
from datetime import datetime, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "ci/kernel-runner"))
from image_stream import Identity, Member, StreamError, decode, encode, verify_sidecar
from image_capsule import unpack
from image_verify import compare_slot
from image_urls import InputURLError, canonical_url


IDENTITY = Identity("fixture-attempt", "rock-5b-plus", "a" * 40, 123, "b" * 64)


def rejected(payload: bytes, expected: Identity = IDENTITY) -> None:
    with tempfile.TemporaryDirectory() as directory:
        try:
            decode(io.BytesIO(payload), pathlib.Path(directory), expected)
        except StreamError:
            return
    raise AssertionError("malformed artifact stream accepted")


def stream(records: list[tuple[str, bytes]], identity: Identity = IDENTITY) -> bytes:
    output = io.BytesIO()
    encode(output, records, identity)
    return output.getvalue()


def test_artifacts_return_with_private_fixed_names() -> None:
    payload = stream([("verification.json", b'{"verified":true}\n')])
    with tempfile.TemporaryDirectory() as directory:
        result = decode(io.BytesIO(payload), pathlib.Path(directory), IDENTITY)
        assert result[0].sha256 == hashlib.sha256(b'{"verified":true}\n').hexdigest()
        artifact = pathlib.Path(directory) / "verification.json"
        assert artifact.read_bytes() == b'{"verified":true}\n'
        assert artifact.stat().st_mode & 0o777 == 0o600


def test_identity_is_selected_by_host() -> None:
    rejected(stream([("verification.json", b"{}")]),
             Identity("other-attempt", "rock-5b-plus", "a" * 40, 123, "b" * 64))


def test_duplicate_unknown_and_traversal_ids_are_refused() -> None:
    for name in ("unknown", "../outside", "/tmp/outside"):
        rejected(stream([(name, b"x")]))
    rejected(stream([("verification.json", b"{}"), ("verification.json", b"{}")]))


def test_truncation_trailing_bytes_and_digest_changes_are_refused() -> None:
    payload = stream([("verification.json", b"fixture-payload")])
    rejected(payload[:-1])
    rejected(payload + b"trailing")
    rejected(payload.replace(b"fixture-payload", b"changed-payload"))


def test_invalid_and_oversized_lengths_fail_before_payload_writes() -> None:
    for length in (-1, True, "1", 16 * 1024**3 + 1):
        header = json.dumps({"id": "verification.json", "length": length,
                             "sha256": "a" * 64}).encode()
        rejected(b"CERALIVE_IMAGE_STREAM_V1\n" + header + b"\n")


def test_missing_terminal_manifest_is_refused() -> None:
    payload = stream([("verification.json", b"{}")])
    rejected(payload[:payload.index(b'{"id":"manifest"')])

def test_capsule_accepts_only_declared_digest_named_regular_objects() -> None:
    for case in ("valid", "object-hash", "extra-path", "credential-field"):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = b"public source bundle fixture"
            public = b"synthetic public trust fixture"
            source_sha = hashlib.sha256(source).hexdigest()
            public_sha = hashlib.sha256(public).hexdigest()
            inventory = {"schema": 1, "source_commit": IDENTITY.commit, "epoch": IDENTITY.epoch,
                         "fetched_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                         "board": IDENTITY.board, "source_bundle": source_sha,
                         "device_root": public_sha, "repositories": {}, "objects": [
                             {"sha256": source_sha, "length": len(source), "kind": "source-bundle", "urls": []},
                             {"sha256": public_sha, "length": len(public), "kind": "public-trust", "urls": []}]}
            if case == "credential-field":
                inventory["private_signer"] = "forbidden"
            capsule = root / "input.tar"
            with tarfile.open(capsule, "w:") as archive:
                records = [("inventory.json", json.dumps(inventory).encode()),
                           ("objects/" + source_sha, source),
                           ("objects/" + public_sha, public if case != "object-hash" else b"x" * len(public))]
                if case == "extra-path":
                    records.append(("../escaped", b"outside"))
                for name, data in records:
                    header = tarfile.TarInfo(name)
                    header.size = len(data)
                    archive.addfile(header, io.BytesIO(data))
            expected = Identity(IDENTITY.attempt, IDENTITY.board, IDENTITY.commit, IDENTITY.epoch,
                                hashlib.sha256(capsule.read_bytes()).hexdigest())
            try:
                result = unpack(capsule, root / "imported", expected)
            except StreamError:
                assert case != "valid"
            else:
                assert case == "valid"
                assert result.source_commit == IDENTITY.commit
                assert (root / "imported" / source_sha).read_bytes() == source
            assert not (root.parent / "escaped").exists()


def test_slot_comparison_rejects_changed_bytes_extra_files_and_root_metadata() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        work = pathlib.Path(temporary)
        root = work / "slot"
        root.mkdir(mode=0o755)
        root.chmod(0o755)
        (root / "content").write_bytes(b"expected")
        archive = work / "rootfs.tar"
        with tarfile.open(archive, "w:") as output:
            output.add(root, arcname=".")
        compare_slot(root, archive, {})
        for case in ("bytes", "extra", "root-mode"):
            (root / "content").write_bytes(b"changed" if case == "bytes" else b"expected")
            if case == "extra":
                (root / "unexpected").write_bytes(b"extra")
            if case == "root-mode":
                (root / "unexpected").unlink()
                root.chmod(0o700)
            try:
                compare_slot(root, archive, {})
            except StreamError:
                pass
            else:
                raise AssertionError(f"slot comparison accepted {case}")


def test_sidecar_rejects_wrong_hash_filename_and_trailing_records() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        path = pathlib.Path(temporary) / "sidecar"
        member = Member("rootfs.tar", 1, "a" * 64)
        valid = "a" * 64 + "  20261116T000000Z.rootfs.tar\n"
        path.write_text(valid)
        verify_sidecar(path, member)
        for value in (valid.replace("a", "b", 1), valid.replace("rootfs.tar", "../other"), valid + "extra\n"):
            path.write_text(value)
            try:
                verify_sidecar(path, member)
            except StreamError:
                pass
            else:
                raise AssertionError("malformed artifact sidecar accepted")


def test_encoded_package_urls_preserve_origin_and_reject_encoded_traversal() -> None:
    expected = "https://apt.ceralive.tv/pool/libstdc++6.deb"
    assert canonical_url(expected) == expected
    assert canonical_url("https://apt.ceralive.tv/pool/libstdc%2b%2B6.deb") == expected
    for value in ("https://apt.ceralive.tv/pool/%2e%2e/private",
                  "https://apt.ceralive.tv/pool%2fprivate",
                  "https://apt.ceralive.tv/pool%5cprivate",
                  "https://apt.ceralive.tv/pool/%0afile",
                  "https://apt.ceralive.tv:invalid/pool/a.deb",
                  "https://apt.ceralive.tv:0/pool/a.deb",
                  "https://user@apt.ceralive.tv/pool/a.deb"):
        try:
            canonical_url(value)
        except InputURLError:
            pass
        else:
            raise AssertionError("unsafe encoded URL accepted")


if __name__ == "__main__":
    tests = [value for name, value in list(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"image route: {len(tests)} passed")
