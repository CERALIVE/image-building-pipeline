#!/usr/bin/env python3
"""Unprivileged image transport regressions; never start QEMU or read credentials."""

from contextlib import ExitStack
import errno
import fcntl
import hashlib
import io
import json
import os
import pathlib
import sys
import tempfile
import tarfile
from dataclasses import asdict, replace
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "ci/kernel-runner"))
import image_guest
from image_stream import Identity, Member, StreamError, decode, encode, verify_sidecar
from image_capsule import unpack, verification_capsule
from image_transport import copy_local
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


def test_guest_probe_emits_only_ordered_stage_data_and_preserves_verdict() -> None:
    baseline = None
    for logging_available, route_present, fault in (
        (True, False, None), (False, False, None), (False, True, None),
        (True, False, "open"), (True, False, "write"), (True, False, "close"),
        (True, False, "init:RuntimeError"), (True, False, "init:OSError"),
        (True, False, "init:MemoryError"),
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            guest_home, console, stage_log = (root / name for name in ("guest", "console", "stages"))
            console.touch()
            if not logging_available:
                console.unlink()
            request = root / "request"
            request.write_text(json.dumps({"schema": 1, "identity": asdict(IDENTITY),
                                           "operation": "probe", "trust": {}}))
            wire = root / "wire"
            no_connection = SimpleNamespace(settimeout=lambda _seconds: None,
                                            connect_ex=lambda _address: 101)

            def import_fixture(_capsule, destination, _identity):
                destination.mkdir()
                return SimpleNamespace(objects=tuple(range(610)))

            with (patch.object(image_guest, "HOME", guest_home),
                  patch.object(image_guest, "Path", side_effect=lambda path: {
                      "/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive/image/raw": request,
                      "/dev/virtio-ports/ceralive-artifacts": wire,
                  }.get(path, pathlib.Path(path))),
                  patch.object(image_guest, "unpack", side_effect=import_fixture),
                  patch.object(image_guest, "source_checkout", return_value=root / "CLIENT_KEY_PATH"),
                  patch.object(image_guest, "command", return_value="[{}]" if route_present else "[]"),
                  patch.object(image_guest.socket, "socket") as socket_factory):
                socket_factory.return_value.__enter__.return_value = no_connection
                with patch("image_stages.CONSOLE", console):
                    with ExitStack() as faults:
                        if fault and fault.startswith("init:"):
                            error = {"RuntimeError": RuntimeError, "OSError": OSError,
                                     "MemoryError": MemoryError}[fault.split(":")[1]]
                            failed_init = faults.enter_context(patch.object(image_guest, "StageLog", side_effect=error))
                        elif fault:
                            operation = getattr(os, fault)
                            injected = False

                            def fail_once(target, *args):
                                nonlocal injected
                                path = str(target) if fault == "open" else os.readlink(f"/proc/self/fd/{target}")
                                if not injected and path == str(console):
                                    injected = True
                                    if fault == "close":
                                        operation(target, *args)
                                    raise MemoryError(f"fixture stage {fault}")
                                return operation(target, *args)

                            faults.enter_context(patch.object(os, fault, side_effect=fail_once))
                        assert image_guest.main() == int(route_present)
                        if fault and fault.startswith("init:"):
                            failed_init.assert_called_once()
                        elif fault:
                            assert injected
            artifacts = root / "returns"
            artifacts.mkdir()
            with wire.open("rb") as source:
                decode(source, artifacts, IDENTITY)
            if route_present:
                assert json.loads((artifacts / "failure.json").read_text())["failure"] == "StreamError"
            else:
                assert json.loads((artifacts / "verification.json").read_text())["network_denied"] is True
                if baseline is None:
                    baseline = wire.read_bytes()
                else:
                    assert wire.read_bytes() == baseline
            if fault and not fault.startswith("init:"):
                assert any(line.split()[2:3] == ["diagnostics_lost"]
                           for line in console.read_text().splitlines())
            if logging_available and not fault:
                lines = console.read_text().splitlines()
                records = [line.split() for line in lines]
                assert [int(seq) for _, _, _, _, seq in records] == list(range(1, len(lines) + 1))
                from image_stages import StageTail
                tail = StageTail()
                tail.observe(console.read_bytes())
                assert tail.complete and tail.text() == console.read_text()
                records = [record[:4] for record in records]
                assert [event for _, _, event, _ in records] == [
                    "probe_start", "capsule_import_begin", "capsule_import_end",
                    "source_checkout_begin", "source_checkout_end", "route_check_begin", "route_check_end",
                    "tcp_check_1_begin", "tcp_check_1_end", "tcp_check_2_begin", "tcp_check_2_end",
                    "tcp_check_3_begin", "tcp_check_3_end", "tcp_check_4_begin", "tcp_check_4_end",
                    "verdict_computed", "stream_open_begin", "stream_open_end",
                    "magic_write_begin", "magic_written", "member_prepare_begin", "member_prepare_end",
                    "member_header_begin", "member_header_end", "member_body_begin", "member_body_written",
                    "member_prepare_begin", "member_prepare_end", "member_header_begin", "member_header_end",
                    "member_body_begin", "member_body_written", "flush_begin", "flush_end",
                    "stream_close_begin", "stream_close_end",
                ]
                timestamps = [int(ns) for _, ns, _, _ in records]
                assert timestamps == sorted(timestamps)
                counts = {stage: int(count) for _, _, stage, count in records}
                assert counts["capsule_import_end"] == 610 and counts["magic_written"] == 25
                assert all(counts[stage] == 1 for stage in (
                    "route_check_end", "tcp_check_1_end", "tcp_check_2_end", "tcp_check_3_end",
                    "tcp_check_4_end", "verdict_computed"))
                assert b"CLIENT_KEY_PATH" not in console.read_bytes()
            assert not stage_log.exists()


def test_stage_logger_returns_when_the_console_pipe_is_full() -> None:
    from image_stages import StageLog

    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        fifo = root / "serial"
        os.mkfifo(fifo)
        with (os.fdopen(os.open(fifo, os.O_RDONLY | os.O_NONBLOCK), "rb", buffering=0) as reader,
              os.fdopen(os.open(fifo, os.O_WRONLY | os.O_NONBLOCK), "wb", buffering=0) as writer,
              patch("image_stages.CONSOLE", fifo)):
            capacity = fcntl.fcntl(writer.fileno(), fcntl.F_GETPIPE_SZ)
            assert writer.write(b"x" * capacity) == capacity
            stages = StageLog()
            stages.emit("probe_start")
            assert not (root / "log").exists()
            assert reader.read(capacity) == b"x" * capacity
            stages.emit("capsule_import_begin")
            assert [line.split()[2] for line in reader.read(capacity).splitlines() if line] == [
                b"diagnostics_lost", b"capsule_import_begin",
            ]


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


def test_copy_reads_and_writes_survive_transient_errors() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        artifacts = root / "artifacts"
        artifacts.mkdir()
        artifact = artifacts / "verification.json"
        payload = bytes(range(256)) * 4097
        artifact.write_bytes(payload)
        digest = hashlib.sha256(payload).hexdigest()
        capsule = root / "original.tar"
        trusted = b"public fixture input"
        trusted_digest = hashlib.sha256(trusted).hexdigest()
        inventory = json.dumps({"objects": [{"kind": "source-bundle", "sha256": trusted_digest,
                                             "length": len(trusted)}]}).encode()
        with tarfile.open(capsule, "w:") as source:
            for name, data in (("inventory.json", inventory), ("objects/" + trusted_digest, trusted)):
                header = tarfile.TarInfo(name)
                header.size = len(data)
                source.addfile(header, io.BytesIO(data))
        target = root / "target"
        pread, write = os.pread, os.write
        for action in (lambda: copy_local(artifact, target, len(payload)),
                       lambda: verification_capsule(capsule, artifacts, target)):
            def run_fault(fault=None, persistent=False):
                calls = []
                injected = 0

                def dispatch(name, fd, position, operation, *args):
                    nonlocal injected
                    site = (name, len(calls))
                    if fault and (not injected and site == fault[:2] or persistent and injected):
                        injected += 1
                        raise OSError(fault[2], "fixture transfer failure")
                    calls.append((name, os.readlink(f"/proc/self/fd/{fd}"), position))
                    return operation(fd, *args)

                with patch.object(os, "pread", lambda fd, n, at: dispatch("read", fd, at, pread, n, at)), \
                        patch.object(os, "write", lambda fd, data: dispatch("write", fd, len(data), write, data)):
                    if persistent:
                        try:
                            action()
                        except OSError as error:
                            assert error.errno == errno.EIO
                        else:
                            raise AssertionError("persistent transfer failure was accepted")
                    else:
                        action()
                assert injected == (3 if persistent else int(fault is not None)), (fault, injected)
                if persistent:
                    assert not target.exists()
                    return None, calls
                result = target.read_bytes()
                target.unlink()
                return result, calls

            baseline, calls = run_fault()
            if baseline != payload:
                with tarfile.open(fileobj=io.BytesIO(baseline), mode="r:") as result:
                    assert result.extractfile("objects/" + digest).read() == payload
                    assert result.extractfile("objects/" + trusted_digest).read() == trusted
            assert any(name == "read" for name, _, _ in calls)
            assert any(name == "write" for name, _, _ in calls)
            for index, (name, _, _) in enumerate(calls):
                for error in (errno.EIO, errno.EINTR):
                    actual, reached = run_fault((name, index, error))
                    assert (actual, reached) == (baseline, calls), (name, index, error)
            writes = [(name, index) for index, (name, _, _) in enumerate(calls) if name == "write"]
            run_fault((*writes[-1], errno.EIO), persistent=True)


def test_guest_import_retries_archive_reads_and_preserves_object_hashes() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        archive_path = root / "input.tar"
        bundle = bytes(range(256)) * 2561 + b"tail"
        trust = b"synthetic public trust"
        objects = {hashlib.sha256(data).hexdigest(): data for data in (bundle, trust)}
        source_id, root_id = objects
        inventory = {"schema": 1, "source_commit": IDENTITY.commit, "epoch": IDENTITY.epoch,
                     "board": IDENTITY.board, "source_bundle": source_id, "device_root": root_id,
                     "fetched_at": "2020-01-01T00:00:00Z", "repositories": {}, "objects": [
                         {"sha256": digest, "length": len(data), "kind": kind, "urls": []}
                         for (digest, data), kind in zip(objects.items(), ("source-bundle", "public-trust"))]}
        with tarfile.open(archive_path, "w:") as archive:
            for name, data in (("inventory.json", json.dumps(inventory).encode()),
                               *((f"objects/{digest}", data) for digest, data in objects.items())):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        original = archive_path.read_bytes()
        identity = replace(IDENTITY, input_sha256=hashlib.sha256(original).hexdigest())
        pread = os.pread
        sites = []

        def run(site=None, error=errno.EIO, count=0):
            seen = []
            remaining = count
            positions = []

            def read_at(fd, size, offset):
                nonlocal remaining
                assert os.readlink(f"/proc/self/fd/{fd}") == str(archive_path)
                if len(seen) == site and remaining:
                    remaining -= 1
                    positions.append(offset)
                    raise OSError(error, "fixture capsule read")
                seen.append(offset)
                return pread(fd, min(size, 65535), offset)

            with tempfile.TemporaryDirectory(dir=root) as attempt, patch.object(os, "pread", read_at):
                target = pathlib.Path(attempt) / "objects"
                if count == 3:
                    try:
                        unpack(archive_path, target, identity)
                    except OSError as exc:
                        assert exc.errno == error
                    else:
                        raise AssertionError("exhausted capsule read accepted")
                else:
                    assert unpack(archive_path, target, identity).source_bundle == source_id
                    assert {digest: (target / digest).read_bytes() for digest in objects} == objects
            assert remaining == 0 and positions == ([] if site is None else [sites[site]] * count)
            return seen

        sites = run()
        assert sites.count(0) >= 2, sites  # The archive is rewound after the transport hash.
        for site in range(len(sites)):
            for error in (errno.EIO, errno.EINTR, errno.EAGAIN):
                for count in (1, 2):
                    assert run(site, error, count) == sites
            run(site, count=3)
        archive_path.write_bytes(original.replace(bundle, bytes(len(bundle))))
        try:
            unpack(archive_path, root / "rejected", identity)
        except StreamError as exc:
            assert "transport digest mismatch" in str(exc)
        else:
            raise AssertionError("tampered capsule accepted")


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
