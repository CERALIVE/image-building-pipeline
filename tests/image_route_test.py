#!/usr/bin/env python3
"""Unprivileged image transport regressions; never start QEMU or read credentials."""

import errno
import hashlib
import io
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import tarfile
import time
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "ci/kernel-runner"))
import image_guest
import image_verify
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


def test_guest_encoder_finishes_all_short_writes_or_raises() -> None:
    class ShortWriter(io.BytesIO):
        def write(self, chunk):
            return super().write(chunk[:7])

    with tempfile.TemporaryDirectory() as temporary:
        member = pathlib.Path(temporary) / "input"
        body = bytes(range(256)) * 8193
        member.write_bytes(body)
        records = [("rootfs.tar", member), ("verification.json", b'{"verified":true}')]
        healthy = io.BytesIO()
        encode(healthy, records, IDENTITY)
        short = ShortWriter()
        encode(short, records, IDENTITY)
        assert short.getvalue() == healthy.getvalue()
        with patch.object(short, "write", return_value=0):
            try:
                encode(short, records, IDENTITY)
            except OSError:
                pass
            else:
                raise AssertionError("stalled guest writer returned successfully")


def test_slot_inventory_restarts_at_root_and_refuses_unreadable_or_extra_entries() -> None:
    from image_stream import list_directory

    with tempfile.TemporaryDirectory() as temporary:
        work = pathlib.Path(temporary)
        root = work / "slot"
        child = root / "sub"
        child.mkdir(parents=True)
        archive = work / "rootfs.tar"
        with tarfile.open(archive, "w") as output:
            output.add(root, arcname=".")
        for error in (errno.EIO, errno.EINTR, errno.EAGAIN, errno.EPERM, errno.ENOENT):
            for hidden in (False, True):
                extra = child / "extra"
                if hidden:
                    extra.touch()
                calls = []

                def scan(path):
                    calls.append(path)
                    if path == child and calls.count(child) == 1:
                        raise OSError(error, "fixture incomplete subtree")
                    return list_directory(path)

                with patch.object(image_verify, "list_directory", scan, create=True):
                    try:
                        compare_slot(root, archive, {})
                    except (OSError, StreamError):
                        assert hidden or error in (errno.EPERM, errno.ENOENT)
                    else:
                        assert not hidden and error in (errno.EIO, errno.EINTR, errno.EAGAIN)
                assert calls.count(root) == (2 if error in (errno.EIO, errno.EINTR, errno.EAGAIN) else 1)
                extra.unlink(missing_ok=True)


def test_mirror_requires_readiness_and_owned_clean_shutdown() -> None:
    child = """
import os, signal, sys
mode = sys.argv[1]
if mode == 'early':
    sys.exit(0)
print('CERALIVE_SEALED_MIRROR_READY', flush=True)
if mode in ('clean', 'bad'):
    if os.read(sys.stdin.fileno(), 1) != b'S':
        sys.exit(8)
    if mode == 'bad':
        sys.exit(7)
    print('CERALIVE_SEALED_MIRROR_STOPPED', flush=True)
    sys.exit(0)
while True:
    signal.pause()
"""
    for mode in ("clean", "legacy", "early", "bad", "foreign-term", "kill"):
        with subprocess.Popen([sys.executable, "-c", child, mode], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE) as mirror:
            entered = False
            try:
                with patch.object(image_guest, "MIRROR_STOP_SECONDS", 0.25), image_guest.ready_mirror(mirror):
                    entered = True
                    if mode in ("foreign-term", "kill"):
                        os.kill(mirror.pid, signal.SIGTERM if mode == "foreign-term" else signal.SIGKILL)
                        mirror.wait(timeout=2)
            except StreamError:
                assert mode in ("legacy", "early", "bad", "foreign-term", "kill"), mode
            else:
                assert mode == "clean", mode
            finally:
                if mirror.poll() is None:
                    mirror.kill()
                    mirror.wait(timeout=2)
            assert entered == (mode != "early"), mode
            if mode in ("clean", "legacy"):
                assert mirror.returncode == (0 if mode == "clean" else -signal.SIGTERM)


def test_probe_requires_affirmative_route_and_tcp_denial() -> None:
    for rows in ("null", "false", "{}", '""', "0", "[{}]", "[]"):
        with patch.object(image_guest, "command", return_value=rows):
            if rows == "[]":
                image_guest.check_route({})
            else:
                try:
                    image_guest.check_route({})
                except StreamError:
                    pass
                else:
                    raise AssertionError(f"accepted invalid route inventory {rows}")

    for result in (None, errno.ENETUNREACH, errno.EHOSTUNREACH, errno.ECONNREFUSED,
                   errno.ETIMEDOUT, errno.EPERM, errno.EIO, errno.EINTR, errno.ENOSYS):
        def connect(_address):
            if result is not None:
                raise OSError(result, "fixture TCP result")

        with patch.object(image_guest.socket, "socket") as factory:
            factory.return_value.__enter__.return_value = SimpleNamespace(
                connect=connect, setblocking=lambda _blocking: None)
            try:
                image_guest.check_tcp("192.0.2.1", time.monotonic() + 1)
            except (OSError, StreamError):
                assert result not in (errno.ENETUNREACH, errno.EHOSTUNREACH)
            else:
                assert result in (errno.ENETUNREACH, errno.EHOSTUNREACH)


def test_mirror_never_accepts_exit_without_a_shutdown_acknowledgement() -> None:
    child = """
import os, signal, sys
print('CERALIVE_SEALED_MIRROR_READY', flush=True)
os.read(sys.stdin.fileno(), 1)
if sys.argv[1] == 'foreign':
    os.kill(os.getpid(), signal.SIGTERM)
elif sys.argv[1] == 'ack':
    print('CERALIVE_SEALED_MIRROR_STOPPED', flush=True)
"""
    for mode in ("ack", "silent", "foreign"):
        with subprocess.Popen([sys.executable, "-c", child, mode],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE) as mirror:
            try:
                with image_guest.ready_mirror(mirror):
                    pass
            except StreamError:
                assert mode != "ack", mode
            else:
                assert mode == "ack", mode
            finally:
                if mirror.poll() is None:
                    mirror.kill()
                    mirror.wait(timeout=2)


def test_measure_uses_base_mirror_for_historical_and_current_sources() -> None:
    spawn = subprocess.Popen
    for revision in ("14bf9c4ab61d340951f5b8a46e988df2e5445c98", "c" * 40):
        for missed in (False, True):
            with tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                source, home, objects = (root / name for name in ("source", "home", "objects"))
                board = IDENTITY.board
                for directory in (source / "lib", source / "mkosi", home, objects,
                                  source / "images" / board):
                    directory.mkdir(parents=True)
                # The checked-out script must not run, regardless of its protocol.
                (source / "lib/sealed-inputs.py").write_text("raise SystemExit(99)\n")
                (source / "images" / board / "fixture.measurement.json").touch()
                (objects / "data").write_bytes(b"offline fixture")
                (home / "swap").touch()
                capsule = SimpleNamespace(directory=objects, board=board, device_root="data",
                                          source_commit=revision, epoch=IDENTITY.epoch,
                                          objects=[SimpleNamespace(sha256="data", kind="pinned-source")])
                repositories = {name: {"suite": "stable", "keyring": "data", "origin": "unused"}
                                for name in ("firstparty", "bsp", "debian-source")}
                job = {"identity": {"input_sha256": IDENTITY.input_sha256}, "trust": {
                    "root_der_sha256": "0" * 64, "repositories": repositories, "os_version": "",
                    "addon_public_object": "", "paseto_public_object": "", "builder_images": [],
                    "kernel_metadata": dict.fromkeys(
                        ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS"), "data"),
                }}
                launches = []

                def start(args, **kwargs):
                    launches.append(args)
                    if args[-1] == "serve-managed":
                        assert args[1] == str(pathlib.Path(image_guest.__file__).with_name("sealed-inputs.py"))
                        child = ("import sys\nprint('CERALIVE_SEALED_MIRROR_READY', flush=True)\n"
                                 "assert sys.stdin.buffer.read(1) == b'S'\n"
                                 f"if {missed!r}: raise SystemExit(1)\n"
                                 "print('CERALIVE_SEALED_MIRROR_STOPPED', flush=True)\n")
                    else:
                        assert args == ["bash", str(source / "build"), board, "--rootfs-measurement"]
                        assert kwargs["env"]["CERALIVE_IMAGE_BUILD_COMMIT"] == revision
                        child = "pass"
                    return spawn([sys.executable, "-B", "-c", child], **kwargs)

                with patch.object(image_guest, "HOME", home), patch.object(image_guest.shutil, "copyfile"), \
                        patch.object(image_guest, "command", return_value="data"), \
                        patch.object(image_guest, "resolve", return_value={}), \
                        patch.object(image_guest.subprocess, "run"), \
                        patch.object(image_guest.subprocess, "Popen", start):
                    try:
                        records = image_guest.measure(source, capsule, job)
                    except StreamError:
                        assert missed, revision
                    else:
                        assert not missed and len(records) == 20, (revision, records)
                assert len(launches) == 2, (revision, missed, launches)


if __name__ == "__main__":
    tests = [value for name, value in list(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"image route: {len(tests)} passed")
