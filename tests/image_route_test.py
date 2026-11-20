#!/usr/bin/env python3
"""Unprivileged image transport regressions; never start QEMU or read credentials."""

import ast
import base64
import errno
import fcntl
import hashlib
import http.client
import io
import json
import os
import pathlib
import select
import signal
import subprocess
import sys
import tempfile
import tarfile
import time
import threading
from copy import deepcopy
from dataclasses import asdict
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import patch

from bootstrap_metadata_test import PACKAGE_URL, bootstrap_fixture

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "ci/kernel-runner"))
import image_guest
import image_resources
import image_verify
import image_vm
import vm
from image_stream import Identity, Member, StreamError, decode, encode, exact_json, verify_sidecar
from image_capsule import unpack
from image_policy import load_policy
from image_verify import compare_slot
from image_urls import InputURLError, canonical_url
from vm_process import ChildStatusError, wait


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
    for case in ("valid", "object-hash", "extra-path", "credential-field", "replace-after-hash"):
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
            real_digest = hashlib.file_digest
            replaced = []

            def digest(stream, algorithm):
                result = real_digest(stream, algorithm)
                if case == "replace-after-hash":
                    capsule.rename(root / "reviewed.tar")
                    capsule.write_bytes(b"unreviewed bytes at the same path")
                    replaced.append(True)
                return result

            valid = case in ("valid", "replace-after-hash")
            with patch.object(hashlib, "file_digest", digest):
                try:
                    result = unpack(capsule, root / "imported", expected)
                except StreamError:
                    assert not valid
                else:
                    assert valid
                    assert result.source_commit == IDENTITY.commit
                    assert (root / "imported" / source_sha).read_bytes() == source
            assert replaced == ([True] if case == "replace-after-hash" else [])
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


def test_public_trust_policy_requires_a_regular_selected_file() -> None:
    repo = {"keyring": "a" * 64, "fingerprints": ["B" * 40], "suite": "stable",
            "component": "main", "arch": "arm64", "index_path": "Packages.gz", "max_age_seconds": 3600}
    policy = {"schema": 1, "root_der_sha256": "c" * 64, "repositories": {
        name: repo | {"origin": origin} for name, origin in (
            ("firstparty", "https://apt.ceralive.tv"), ("bsp", "https://apt.armbian.com"),
            ("debian-source", "https://deb.debian.org/debian"))},
        "kernel_metadata": dict.fromkeys(("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS"),
                                         "d" * 64),
        "builder_images": [{"object": "e" * 64, "tag": "fixture:v1",
                            "image_id": "sha256:" + "f" * 64, "arch": "arm64"}]}
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        trusted = root / "trusted.json"
        trusted.write_text(json.dumps(policy))
        assert load_policy(trusted).root_der_sha256 == policy["root_der_sha256"]
        link = root / "policy.json"
        link.symlink_to(trusted)
        try:
            load_policy(link)
        except StreamError:
            pass
        else:
            raise AssertionError("a symlink nominated the approved public trust policy")


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


def test_slot_content_read_error_restarts_the_comparison() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        work = pathlib.Path(temporary)
        root = work / "slot"
        root.mkdir()
        member = root / "file"
        member.write_bytes(b"fixture")
        archive = work / "rootfs.tar"
        with tarfile.open(archive, "w") as output:
            output.add(root, arcname=".")
        real_digest = image_verify.hashlib.file_digest
        real_open = tarfile.open
        attempts = []
        injected = []

        def digest(source, algorithm):
            if type(source) is io.BufferedReader and not injected:
                assert os.readlink(f"/proc/self/fd/{source.fileno()}") == str(member)
                injected.append(source.tell())
                raise OSError(errno.EIO, "fixture slot content read")
            return real_digest(source, algorithm)

        def open_tar(*args, **kwargs):
            attempts.append(args[0])
            return real_open(*args, **kwargs)

        with patch.object(image_verify.hashlib, "file_digest", digest), patch.object(tarfile, "open", open_tar):
            compare_slot(root, archive, {})
        assert injected == [0] and attempts == [archive, archive]


def test_verifier_requires_observed_e2fsck_exit() -> None:
    class ReserveReached(Exception):
        pass

    spawn, waitpid = subprocess.Popen, os.waitpid
    for code, fault in ((8, "normal"), (4, "normal"), (1, "normal"), (0, "normal"),
                        (8, "premature-reap"), (8, "ignored-during-spawn"), (0, "echild"),
                        (8, "inherited-ignore")):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            home = root / "home"
            home.mkdir()
            fsck = root / "e2fsck"
            fsck.write_text(f"#!/bin/sh\nexit {code}\n")
            fsck.chmod(0o700)
            metadata = ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS")
            artifacts = {name: name for name in ("resolved.json", "measurement.json", "rootfs.tar",
                "kernel-artifact.json", "resolved.config", "built-modules.txt", "kernel.SHA256SUMS",
                "boot.scr", "boot.scr.sha256", "rootfs_a.ext4")}
            trust = {"root_der_sha256": "fixture-root", "kernel_metadata": dict.fromkeys(metadata, "approved")}
            for name in (*artifacts, "approved"):
                (root / name).touch()
            params = {"BOARD_ID": IDENTITY.board, "DTB_NAME": "fixture", "SERIAL_CONSOLE": "fixture"}
            (root / "resolved.json").write_text(json.dumps(params))
            (root / "measurement.json").write_text(json.dumps({"public_root_der_sha256": "fixture-root"}))
            with tarfile.open(root / "rootfs.tar", "w"):
                pass
            capsule = SimpleNamespace(directory=root, board=IDENTITY.board, device_root="approved")
            kernel = SimpleNamespace(verified_metadata=lambda *_: SimpleNamespace(boards=[IDENTITY.board]))
            seen, reaped = [], []

            def start(args, **options):
                if "slot_reserve_assert_ext4" in " ".join(args):
                    seen.append("reserve")
                    raise ReserveReached
                if args[0] != "e2fsck":
                    if "boot-payload" in args:
                        for name in ("boot.scr", "boot.scr.sha256"):
                            (home / "compiled-boot" / name).touch()
                    return spawn(["/bin/true"], **options)
                seen.append("e2fsck")
                assert args == ["e2fsck", "-fn", str(root / "rootfs_a.ext4")]
                if fault == "ignored-during-spawn":
                    signal.signal(signal.SIGCHLD, signal.SIG_IGN)
                child = spawn([str(fsck), *args[1:]], **options)
                if fault == "premature-reap":
                    waiter = threading.Thread(target=lambda: reaped.append(waitpid(child.pid, 0)))
                    waiter.start()
                    waiter.join(timeout=3)
                    assert not waiter.is_alive() and reaped == [(child.pid, code << 8)]
                if fault == "echild":
                    assert waitpid(child.pid, 0) == (child.pid, code << 8)
                    faults.add(child.pid)
                return child

            faults = set()

            def wait_with_fault(pid, flags):
                if pid in faults:
                    raise ChildProcessError(errno.ECHILD, "fixture wait status unavailable")
                return waitpid(pid, flags)

            inherited = signal.getsignal(signal.SIGCHLD)
            before_path = sys.path[:]
            try:
                if fault == "inherited-ignore":
                    signal.signal(signal.SIGCHLD, signal.SIG_IGN)
                with patch.object(image_guest, "HOME", home), patch.object(image_guest, "resolve", return_value=params), \
                        patch.dict(sys.modules, {"kernel_release": kernel}), patch.object(subprocess, "Popen", start), \
                        patch.object(os, "waitpid", wait_with_fault):
                    try:
                        image_verify.verify(root, capsule, {"build_identity": asdict(IDENTITY),
                                                           "artifacts": artifacts, "trust": trust})
                    except ReserveReached:
                        assert (code, fault) == (0, "normal"), (code, fault, "unverified success")
                    except subprocess.CalledProcessError as error:
                        assert fault in ("normal", "inherited-ignore") and error.returncode == code != 0
                    except ChildStatusError as error:
                        assert fault in ("premature-reap", "ignored-during-spawn", "echild"), (fault, error)
                        assert isinstance(error.__cause__, ChildProcessError) and error.__cause__.errno == errno.ECHILD
                    else:
                        raise AssertionError("verifier returned before checking reserve")
                    if fault == "inherited-ignore":
                        assert signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL
            finally:
                sys.path[:] = before_path
                signal.signal(signal.SIGCHLD, inherited)
            assert seen == (["e2fsck", "reserve"] if (code, fault) == (0, "normal") else ["e2fsck"])


def test_guest_gate_refuses_ignored_sigchld_before_spawn() -> None:
    previous = signal.signal(signal.SIGCHLD, signal.SIG_IGN)
    try:
        with patch.object(subprocess, "Popen", side_effect=AssertionError("spawned with SIGCHLD ignored")) as spawn:
            try:
                image_guest.command(["/bin/true"], {})
            except ChildStatusError as error:
                assert "SIGCHLD is ignored" in str(error)
            else:
                raise AssertionError("gate ran with SIGCHLD ignored")
            spawn.assert_not_called()
    finally:
        signal.signal(signal.SIGCHLD, previous)


def test_gate_rejects_popen_echild_fallback_zero() -> None:
    spawn = subprocess.Popen

    def with_unobserved_zero(args, **options):
        child = spawn(args, **options)
        assert os.waitpid(child.pid, 0) == (child.pid, 8 << 8)
        assert child.poll() == 0  # CPython's ECHILD fallback has no actual exit status.
        return child

    with patch.object(subprocess, "Popen", with_unobserved_zero):
        try:
            image_guest.command(["/bin/sh", "-c", "exit 8"], {})
        except ChildStatusError as error:
            assert "unobserved returncode" in str(error)
        else:
            raise AssertionError("gate accepted a fallback zero")


def test_gate_transfers_input_and_observes_captured_command_exit() -> None:
    # Pipe more than the buffer can hold to ensure input and output drain together.
    from vm_process import run

    data = b"x\r\n" * 65536
    result = run([sys.executable, "-c", "import sys; sys.stderr.write('ready\\r\\n'); "
                  "sys.stdout.buffer.write(sys.stdin.buffer.read()); raise SystemExit(7)"],
                 input=data, capture_output=True, text=True, timeout=5, check=False)
    assert (result.returncode, result.stdout, result.stderr) == (7, "x\n" * 65536, "ready\n")


def test_image_verdicts_do_not_use_subprocess_convenience_waiters() -> None:
    root = pathlib.Path(__file__).resolve().parents[1]
    violations = []
    forbidden = {"run", "check_call", "check_output", "call", "getstatusoutput", "getoutput"}
    for path in (*sorted((root / "ci/kernel-runner").rglob("*.py")), root / "lib/sealed-inputs.py"):
        tree = ast.parse(path.read_text(), filename=str(path))
        modules = {alias.asname or alias.name for node in ast.walk(tree) if isinstance(node, ast.Import)
                   for alias in node.names if alias.name == "subprocess"}
        functions = {alias.asname or alias.name for node in ast.walk(tree)
                     if isinstance(node, ast.ImportFrom) and node.module == "subprocess"
                     for alias in node.names if alias.name in forbidden or alias.name == "*"}
        for node in ast.walk(tree):
            if (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
                    and node.value.id in modules and node.attr in forbidden
                    or isinstance(node, ast.Name) and node.id in functions):
                violations.append(f"{path.relative_to(root)}:{node.lineno}")
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in {
                    "wait", "poll", "communicate"}:
                violations.append(f"{path.relative_to(root)}:{node.lineno}")
        assert "*" not in functions, path
    assert not violations, f"Image verdicts must use the owned-child waiter: {violations}"


def test_mirror_requires_readiness_and_owned_clean_shutdown() -> None:
    child = """
import os, signal, sys
mode = sys.argv[1]
if mode == 'early':
    sys.exit(0)
if mode == 'partial':
    print('CERALIVE_', end='', flush=True)
    signal.pause()
if mode == 'closed-control':
    os.close(0)
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
    for mode in ("clean", "legacy", "early", "partial", "full-control", "closed-control", "bad", "foreign-term", "kill"):
        with subprocess.Popen([sys.executable, "-c", child, mode], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE) as mirror:
            entered = False
            try:
                with patch.object(image_guest, "MIRROR_READY_SECONDS", 2 if mode != "partial" else 0.25), \
                        patch.object(image_guest, "MIRROR_STOP_SECONDS", 0.25), image_guest.ready_mirror(mirror):
                    entered = True
                    if mode in ("foreign-term", "kill"):
                        os.kill(mirror.pid, signal.SIGTERM if mode == "foreign-term" else signal.SIGKILL)
                        wait(mirror, time.monotonic() + 2)
                    if mode == "full-control":
                        fd = mirror.stdin.fileno()
                        capacity = fcntl.fcntl(fd, fcntl.F_GETPIPE_SZ)
                        assert os.write(fd, b"x" * capacity) == capacity
            except StreamError as error:
                assert mode in ("legacy", "early", "partial", "full-control", "closed-control", "bad", "foreign-term",
                                "kill"), mode
                if mode == "closed-control":
                    assert isinstance(error.__cause__, BrokenPipeError), error
                    assert error.__cause__.errno == errno.EPIPE
            else:
                assert mode == "clean", mode
            finally:
                if mirror.poll() is None:
                    mirror.kill()
                    mirror.wait(timeout=2)
            assert entered == (mode not in ("early", "partial")), mode
            if mode in ("partial", "full-control", "closed-control"):
                assert mirror.returncode == -signal.SIGTERM, mode
            if mode in ("clean", "legacy"):
                assert mirror.returncode == (0 if mode == "clean" else -signal.SIGTERM)


def test_mirror_control_retries_partial_reads_and_readiness() -> None:
    child = """
import sys
print('CERALIVE_SEALED_MIRROR_READY', flush=True)
assert sys.stdin.buffer.read(1) == b'S'
print('CERALIVE_SEALED_MIRROR_STOPPED', flush=True)
"""
    read = os.read
    select_type = image_guest.selectors.DefaultSelector
    ready, stopped = b"CERALIVE_SEALED_MIRROR_READY\n", b"CERALIVE_SEALED_MIRROR_STOPPED\n"
    for position in (0, len(ready), len(ready + stopped)):
        with subprocess.Popen([sys.executable, "-c", child], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE) as mirror:
            received = bytearray()
            injected = set()

            def fault(fd, size):
                if fd != mirror.stdout.fileno():
                    return read(fd, size)
                if len(received) == position and "read" not in injected:
                    injected.add("read")
                    raise OSError(errno.EIO, "fixture mirror read")
                chunk = read(fd, min(size, 7))
                received.extend(chunk)
                return chunk

            class Selector(select_type):
                def select(self, timeout=None):
                    events = super().select(timeout)
                    if any(mask & image_guest.selectors.EVENT_WRITE for _, mask in events) and "select" not in injected:
                        injected.add("select")
                        raise OSError(errno.ENOSYS, "fixture mirror control readiness")
                    return events

            with patch.object(image_guest.os, "read", fault), \
                    patch.object(image_guest.selectors, "DefaultSelector", Selector), image_guest.ready_mirror(mirror):
                pass
            assert injected == {"read", "select"} and received == ready + stopped and mirror.returncode == 0


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


def test_real_guest_probe_emits_only_the_frame_for_its_outcome() -> None:
    addresses = ["10.0.2.2", "169.254.169.254", "192.168.0.1", "1.1.1.1"]
    cases = (
        ("[]", (errno.ENETUNREACH,), addresses, None),
        ("[]", (errno.EINTR, errno.EAGAIN, errno.ENETUNREACH), addresses[:1] * 2 + addresses, None),
        ("[{}]", (), [], StreamError),
        ("[]", (0,), addresses[:1], StreamError),
        ("[]", (errno.EIO,), addresses[:1] * 3, OSError),
    )
    for route, errors, expected_addresses, expected_error in cases:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            request, wire = root / "request", root / "wire"
            request.write_text(json.dumps({"schema": 1, "identity": asdict(IDENTITY),
                                           "operation": "probe", "trust": {}}))
            replies = iter(errors[:-1])
            connected = []

            def connect(address):
                connected.append(address)
                error = next(replies, errors[-1])
                if error:
                    raise OSError(error, "fixture TCP outcome")

            paths = {"/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive/image/raw": request,
                     "/dev/virtio-ports/ceralive-artifacts": wire}
            with patch.object(image_guest, "HOME", root / "guest"), \
                    patch.object(image_guest, "Path", side_effect=lambda p: paths.get(p, pathlib.Path(p))), \
                    patch.object(image_guest, "unpack", side_effect=lambda _p, output, _i: output.mkdir()), \
                    patch.object(image_guest, "source_checkout", return_value=root / "source"), \
                    patch.object(image_guest, "command", return_value=route), \
                    patch.object(image_guest.socket, "socket") as factory:
                factory.return_value.__enter__.return_value.connect = connect
                try:
                    image_guest.main()
                except (StreamError, OSError) as exc:
                    assert type(exc) is expected_error
                else:
                    assert expected_error is None
            assert connected == [(address, 443) for address in expected_addresses]
            target = root / "decoded"
            target.mkdir()
            with wire.open("rb") as frame:
                members = decode(frame, target, IDENTITY)
            name = "verification.json" if expected_error is None else "failure.json"
            assert [member.id for member in members] == [name]
            expected = {"schema": 1, "identity": asdict(IDENTITY)}
            expected.update({"network_denied": True} if expected_error is None else
                            {"failure": expected_error.__name__, "exit": None})
            assert exact_json(json.loads((target / name).read_text()), expected)


def test_measure_checks_loaded_platform_config_and_returns_safe_failure_frame() -> None:
    class BuildReady(Exception):
        """Builder admission reached the next measurement step."""

    tag = "fixture-builder:v1"
    archive_id = "e" * 64
    config = b'{"architecture":"arm64","os":"linux","config":{"Env":["FIXTURE=original"]}}'
    wrong_config = config.replace(b"original", b"modified")
    wrong_arch = config.replace(b"arm64", b"amd64")
    config_id = "sha256:" + hashlib.sha256(config).hexdigest()
    target_id = "sha256:" + "d" * 64
    for shape in ("containerd", "classic"):
        image_id = config_id if shape == "classic" else target_id
        inspect = {"Id": image_id, "Architecture": "arm64", "Os": "linux", "Config": {}}
        if shape == "containerd":
            inspect["Descriptor"] = {"digest": target_id, "mediaType": "application/vnd.oci.image.manifest.v1+json"}
        for case, row, blob, code, observed in (
            ("match", inspect, config, None, None),
            ("config mismatch", inspect, wrong_config, "builder_config_digest_mismatch",
             "sha256:" + hashlib.sha256(wrong_config).hexdigest()),
            ("tampered config", inspect, wrong_config, "builder_config_digest_mismatch",
             "sha256:" + hashlib.sha256(wrong_config).hexdigest()),
            ("inspect platform mismatch", inspect | {"Architecture": "amd64"}, config,
             "builder_platform_mismatch", None),
            ("exported platform mismatch", inspect, wrong_arch, "builder_platform_mismatch",
             "sha256:" + hashlib.sha256(wrong_arch).hexdigest()),
            ("missing config", inspect, None, "builder_config_unavailable", None),
            ("malformed config", inspect, b"/private/path/credential", "builder_config_unavailable",
             "sha256:" + hashlib.sha256(b"/private/path/credential").hexdigest()),
            ("inspect error", None, None, "builder_engine_inspect_error", None),
            ("export error", inspect, None, "builder_engine_export_error", None),
        ):
            with tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                root.joinpath("source/mkosi").mkdir(parents=True)
                request, wire = root / "request", root / "wire"
                repos = {name: {"suite": "stable", "keyring": "data", "origin": "unused"}
                         for name in ("firstparty", "bsp", "debian-source")}
                trust = {"repositories": repos, "root_der_sha256": "0" * 64, "os_version": "",
                         "addon_public_object": "", "paseto_public_object": "",
                         "kernel_metadata": dict.fromkeys(
                             ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS"), "data"),
                         "builder_images": [{"tag": tag, "object": archive_id, "image_id": config_id, "arch": "arm64"}]}
                request.write_text(json.dumps({"schema": 1, "identity": asdict(IDENTITY),
                                               "operation": "measure", "trust": trust}))
                paths = {"/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive/image/raw": request,
                         "/dev/virtio-ports/ceralive-artifacts": wire}

                def unpack_builder(_path, output, _identity):
                    output.mkdir()
                    (output / "data").write_bytes(b"fixture keyring and source")
                    return SimpleNamespace(directory=output, board=IDENTITY.board, device_root="data",
                                           source_commit=IDENTITY.commit, epoch=IDENTITY.epoch, objects=(
                                               SimpleNamespace(sha256="data", kind="pinned-source"),
                                               SimpleNamespace(sha256=archive_id, kind="builder-image")))

                def engine(args, **kwargs):
                    if args[:1] == ["bash"]:
                        return subprocess.CompletedProcess(args, 0, "data")
                    if args[:2] == ["docker", "load"]:
                        assert args[2:] == ["-i", str(root / "guest/input" / archive_id)]
                        return subprocess.CompletedProcess(args, 0)
                    if args in (["docker", "image", "inspect", tag], ["docker", "image", "inspect", "--", tag]):
                        if row is None:
                            raise subprocess.CalledProcessError(1, args, stderr=b"/private/path/credential")
                        return subprocess.CompletedProcess(args, 0, json.dumps([row]))
                    assert args == ["docker", "image", "save", "--platform", "linux/arm64", "--", tag]
                    if case == "export error":
                        raise subprocess.CalledProcessError(1, args, stderr=b"/private/path/credential")
                    named_digest = hashlib.sha256(config if case == "tampered config" else blob or config).hexdigest()
                    config_name = "blobs/sha256/" + named_digest
                    entries = {"manifest.json": json.dumps([{"Config": config_name, "RepoTags": [tag],
                                                            "Layers": []}]).encode()}
                    if blob is not None:
                        entries[config_name] = blob
                    with tarfile.open(fileobj=kwargs["stdout"], mode="w") as tar:
                        for name, data in entries.items():
                            member = tarfile.TarInfo(name)
                            member.size = len(data)
                            tar.addfile(member, io.BytesIO(data))
                    return subprocess.CompletedProcess(args, 0)

                with patch.object(image_guest, "HOME", root / "guest"), \
                        patch.object(image_guest, "Path", side_effect=lambda p: paths.get(p, pathlib.Path(p))), \
                        patch.object(image_guest, "unpack", side_effect=unpack_builder), \
                        patch.object(image_guest, "source_checkout", return_value=root / "source"), \
                        patch.object(image_guest.shutil, "copyfile"), \
                        patch.object(image_guest, "resolve", side_effect=BuildReady), \
                        patch.object(image_guest, "run_gate", side_effect=engine):
                    try:
                        image_guest.main()
                    except BuildReady:
                        assert code is None and not wire.exists(), (shape, case)
                        continue
                    except StreamError:
                        assert code is not None, (shape, case, "approved image was refused")
                    else:
                        raise AssertionError((shape, case, "did not reach builder admission boundary"))
                target = root / "decoded"
                target.mkdir()
                with wire.open("rb") as frame:
                    assert [member.id for member in decode(frame, target, IDENTITY)] == ["failure.json"]
                assert exact_json(json.loads((target / "failure.json").read_text()), {
                    "schema": 1, "identity": asdict(IDENTITY), "failure": "StreamError", "exit": None,
                    "failure_code": code, "expected_config_digest": config_id, "observed_config_digest": observed,
                }), (shape, case)


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


def assemble_image_payload(root: pathlib.Path) -> None:
    """Decode the cloud-init file emitted by the real build-base command."""
    image = b"fixture cloud image"
    proc = pathlib.Path("/proc/123")
    read_text, read_bytes = pathlib.Path.read_text, pathlib.Path.read_bytes

    def run(args, **_kwargs):
        match args[:2]:
            case ["curl", "-fSL"]:
                pathlib.Path(args[-1]).write_bytes(image)
            case ["qemu-img", "convert"]:
                pathlib.Path(args[-1]).touch()
            case ["qemu-img", "resize"]:
                pass
            case ["xorriso", "-as"]:
                config = vm.yaml.safe_load(pathlib.Path(args[-2]).read_text())
                for row in config["write_files"]:
                    destination = root / row["path"].lstrip("/")
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    content = row["content"].encode()
                    destination.write_bytes(base64.b64decode(content) if row.get("encoding") == "b64" else content)
                    destination.chmod(int(row["permissions"], 8))
            case _:
                raise AssertionError(args)

    argv = ["vm.py", "build-base", "--profile", "image", "--base", str(root / "fixture-base")]
    with patch.object(sys, "argv", argv), patch.object(vm.os, "getppid", return_value=123), \
            patch.object(pathlib.Path, "read_text",
                         lambda path: "flock\n" if path == proc / "comm" else read_text(path)), \
            patch.object(pathlib.Path, "read_bytes",
                         lambda path: b"flock\0--exclusive\0--close\0" if path == proc / "cmdline" else read_bytes(path)), \
            patch.object(vm, "sanitize_startup", return_value=[]), patch.object(vm, "die_with_parent"), \
            patch.object(image_resources, "require_host_lock"), patch.object(image_resources, "cgroup_admission"), \
            patch.object(image_resources, "disk_headroom"), patch.object(type(image_resources.CAPS), "qemu_limit"), \
            patch.object(vm, "IMAGE_SHA", hashlib.sha256(image).hexdigest()), \
            patch.object(vm, "run", run), patch.object(vm, "boot"):
        assert vm.main(vm.Cancellation()) == 0


def test_generated_image_payload_starts_mirror_and_reports_http_outcomes() -> None:
    # Substitute only the bind address and the fixture's signature verifier.
    # The isolated interpreter can import only the standard library and the installed files.
    child = """
import errno, hashlib, http.server, os, pathlib, runpy, selectors, sys
script, port_file = map(pathlib.Path, sys.argv[1:3])
mode = sys.argv[3]
objects = pathlib.Path(os.environ["CERALIVE_SEALED_INPUTS"])
if mode == "marker-error":
    write_text = pathlib.Path.write_text
    def fail_marker(path, *args, **kwargs):
        if path == objects / "missing-object":
            port_file.with_name("marker-failed").touch()
            raise OSError(errno.EIO, "fixture failed miss marker")
        return write_text(path, *args, **kwargs)
    pathlib.Path.write_text = fail_marker
if mode == "stop-retry":
    read = os.read
    selector = selectors.DefaultSelector
    def interrupt(operation):
        marker = port_file.with_name(operation)
        if not marker.exists():
            marker.touch()
            raise OSError(errno.EIO, "fixture stop " + operation)
    def read_control(fd, size):
        if fd == 0:
            interrupt("read")
        return read(fd, size)
    class StopSelector(selector):
        def select(self, timeout=None):
            events = super().select(timeout)
            if any(key.fd == 0 for key, _ in events):
                interrupt("select")
            return events
    os.read = read_control
    selectors.DefaultSelector = StopSelector
class LoopbackServer(http.server.HTTPServer):
    def __init__(self, address, handler):
        assert address == ("127.0.0.1", 3142)
        class FixtureHandler(handler):
            def end_headers(self):
                super().end_headers()
                if mode == "short-source":
                    expected = hashlib.sha256(b"public package fixture").hexdigest()
                    (objects / expected).write_bytes(b"public package fixtur")
                if mode == "short":
                    original = self.wfile
                    class Short:
                        def write(self, data):
                            return original.write(data[:-1])
                        def __getattr__(self, name):
                            return getattr(original, name)
                    self.wfile = Short()
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        port_file.write_text(str(self.server_port))
http.server.HTTPServer = LoopbackServer
sys.path.insert(0, str(script.parent))
sys.argv = [str(script), "serve-managed"]
runpy.run_path(str(script), run_name="__main__")
"""
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        assemble_image_payload(root)
        library = root / "usr/local/lib/ceralive-kernel-runner"
        script, address = library / "sealed-inputs.py", root / "mirror-port"
        argv = [sys.executable, "-B", "-I", "-S", "-c", child, str(script), str(address)]
        def mirror_env(objects: pathlib.Path) -> dict[str, str]:
            return {"PATH": os.environ["PATH"], "HOME": temporary, "LANG": "C.UTF-8",
                    "CERALIVE_SEALED_INPUTS": str(objects), "CERALIVE_BUILD_PURPOSE": "rootfs-measurement"}

        # The entry point imports the Python helpers and sources both shell validators.
        dependencies = ("sealed-inputs.py", "image_urls.py", "vm_process.py", "fetch-debs-auth.sh", "fetch/index.sh")
        for name in dependencies:
            installed = library / name
            omitted = installed.with_suffix(".omitted")
            installed.rename(omitted)
            try:
                with bootstrap_fixture() as objects:
                    result = subprocess.run([*argv, "hit"], cwd=root,
                                            env=mirror_env(objects),
                                            input=b"S", capture_output=True, timeout=5)
                assert result.returncode == 1 and b"CERALIVE_SEALED_MIRROR_READY" not in result.stdout, (
                    name, result.returncode, result.stdout, result.stderr)
            finally:
                omitted.rename(installed)
        for mode in ("hit", "miss", "short", "short-source", "marker-error", "foreign-term", "stop-retry"):
            healthy = mode in ("hit", "stop-retry")
            with bootstrap_fixture() as objects, subprocess.Popen(
                [*argv, mode], cwd=root, env=mirror_env(objects),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            ) as mirror:
                try:
                    assert select.select([mirror.stdout], [], [], 5)[0], "installed mirror did not report readiness"
                    ready = mirror.stdout.readline()
                    if ready != b"CERALIVE_SEALED_MIRROR_READY\n":
                        stdout, stderr = mirror.communicate(timeout=2)
                        raise AssertionError((mirror.returncode, ready + stdout, stderr))
                    if mode == "foreign-term":
                        mirror.terminate()
                        stdout, stderr = mirror.communicate(timeout=2)
                        assert (mirror.returncode, stdout) == (1, b""), stderr
                        assert not (objects / "missing-object").exists()
                        continue
                    connection = http.client.HTTPConnection("127.0.0.1", int(address.read_text()), timeout=2)
                    try:
                        url = PACKAGE_URL + ".missing" if mode in ("miss", "marker-error") else PACKAGE_URL
                        connection.request("GET", url)
                        try:
                            response = connection.getresponse()
                            body = response.read()
                        except http.client.IncompleteRead as error:
                            assert mode in ("short", "short-source") and error.partial == b"public package fixtur"
                            body = error.partial
                        except http.client.RemoteDisconnected:
                            assert mode == "marker-error"
                        else:
                            assert mode not in ("short", "short-source", "marker-error")
                    finally:
                        connection.close()
                    stdout, stderr = mirror.communicate(b"S", timeout=2)
                    assert (mirror.returncode, stdout) == (
                        (0, b"CERALIVE_SEALED_MIRROR_STOPPED\n") if healthy else (1, b"")
                    ), stderr
                    if mode == "marker-error":
                        assert address.with_name("marker-failed").is_file()
                        assert not (objects / "missing-object").exists()
                        continue
                    assert response.status == (404 if mode == "miss" else 200)
                    if mode == "miss":
                        assert (objects / "missing-object").read_text() == hashlib.sha256(url.encode()).hexdigest() + "\n"
                    else:
                        assert body == (b"public package fixture" if healthy else b"public package fixtur")
                        assert not (objects / "missing-object").exists()
                    if mode == "stop-retry":
                        assert all(address.with_name(op).is_file() for op in ("read", "select"))
                    validity = json.loads((objects / "metadata-validity.json").read_text())
                    release_sha = json.loads((objects / "inventory.json").read_text())["repositories"]["debian-bootstrap"]["inrelease"]
                    assert validity["purpose"] == "rootfs-measurement"
                    assert [(row["repository"], row["release_sha256"], row["freshness_checked"])
                            for row in validity["repositories"]] == [("debian-bootstrap", release_sha, True)]
                finally:
                    if mirror.poll() is None:
                        mirror.kill()
                        mirror.wait(timeout=2)


def test_measure_uses_base_mirror_for_historical_and_current_sources() -> None:
    spawn = subprocess.Popen
    server = pathlib.Path(__file__).resolve().parents[1] / "lib/sealed-inputs.py"
    mirror_code = """
import hashlib, http.server, pathlib, runpy, sys
script, objects, address, transcript = map(pathlib.Path, sys.argv[1:])
module = runpy.run_path(str(script))
serve = module["serve"]
digest = hashlib.sha256((objects / "data").read_bytes()).hexdigest()
(objects / "data").rename(objects / digest)
class LoopbackServer(http.server.HTTPServer):
    def __init__(self, requested, handler):
        assert requested == ("127.0.0.1", 3142)
        super().__init__(("127.0.0.1", 0), handler)
        address.write_text(str(self.server_port))
def record_marker(marker, *, flush):
    print(marker, flush=flush)
    with transcript.open("a") as copy:
        print(marker, file=copy)
serve.__globals__.update(HTTPServer=LoopbackServer, print=record_marker, mirror_validities=lambda _: (),
                         inventory=lambda _: {"objects": [{
                             "urls": ["https://deb.debian.org/debian/fixture"], "sha256": digest
                         }]})
serve(objects, managed=True)
"""
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
                replies = []
                address = root / "mirror-port"
                transcript = root / "mirror-control"
                mirrors = []

                def start(args, **kwargs):
                    launches.append(args)
                    if args[-1] == "serve-managed":
                        assert args[1] == str(pathlib.Path(image_guest.__file__).with_name("sealed-inputs.py"))
                        child = spawn([sys.executable, "-B", "-c", mirror_code,
                                       str(server), str(objects), str(address), str(transcript)], **kwargs)
                        mirrors.append(child)
                        return child
                    assert args == ["bash", str(source / "build"), board, "--rootfs-measurement"]
                    assert kwargs["env"]["CERALIVE_IMAGE_BUILD_COMMIT"] == revision
                    connection = http.client.HTTPConnection("127.0.0.1", int(address.read_text()), timeout=2)
                    try:
                        name = "missing" if missed else "fixture"
                        connection.request("GET", f"http://deb.debian.org/debian/{name}")
                        response = connection.getresponse()
                        replies.append((response.status, response.read()))
                    finally:
                        connection.close()
                    return spawn([sys.executable, "-B", "-c", "pass"], **kwargs)

                with patch.object(image_guest, "HOME", home), patch.object(image_guest.shutil, "copyfile"), \
                        patch.object(image_guest, "command", return_value="data"), \
                        patch.object(image_guest, "resolve", return_value={}), \
                        patch.object(image_guest, "run_gate"), \
                        patch.object(image_guest.subprocess, "Popen", start):
                    try:
                        records = image_guest.measure(source, capsule, job)
                    except StreamError:
                        assert missed, revision
                    else:
                        assert not missed and len(records) == 20, (revision, records)
                assert len(launches) == 2, (revision, missed, launches)
                markers = transcript.read_text().splitlines()
                assert markers == (["CERALIVE_SEALED_MIRROR_READY"] if missed else
                                   ["CERALIVE_SEALED_MIRROR_READY", "CERALIVE_SEALED_MIRROR_STOPPED"]), (
                                       revision, missed, markers)
                assert [child.returncode for child in mirrors] == [1 if missed else 0]
                if missed:
                    assert len(replies) == 1 and replies[0][0] == 404
                    assert (objects / "missing-object").is_file()
                else:
                    assert replies == [(200, b"offline fixture")]
                    assert not (objects / "missing-object").exists()


def wrong_typed_records(record):
    def fields(value, path):
        if type(value) in (int, bool):
            replacements = (float(value), str(value), None, bool(value) if type(value) is int else int(value))
        else:
            replacements = ({dict: [], list: {}, str: 1}[type(value)], None)
        for invalid in replacements:
            yield path, invalid
        if type(value) is dict:
            for key, child in value.items():
                yield from fields(child, (*path, key))
        if type(value) is list:
            for index, child in enumerate(value):
                yield from fields(child, (*path, index))

    for path, replacement in fields(record, ()):
        if not path:
            yield path, replacement
            continue
        changed = deepcopy(record)
        parent = changed
        for key in path[:-1]:
            parent = parent[key]
        parent[path[-1]] = replacement
        yield path, changed


def test_measurement_and_verifier_records_reject_every_wrong_typed_field() -> None:
    root = "d" * 64
    members = tuple(Member(name, 1, "a" * 64) for name in (
        "rootfs.tar", "packages.lock.json", "rootfs_a.ext4", "rootfs_b.ext4", "rootfs_a.reserve",
        "rootfs_b.reserve", "rootfs_a.header", "rootfs_b.header", "boot.scr", "boot.scr.sha256"))
    row = {
        "schema": 1, "purpose": "rootfs-measurement", "build_mode": "production",
        "board": IDENTITY.board, "source_commit": IDENTITY.commit, "source_date_epoch": IDENTITY.epoch,
        "input_sha256": IDENTITY.input_sha256, "public_root_der_sha256": root, "kernel_version": "fixture",
        "stages": dict.fromkeys(("resolve", "fetch", "kernel-reuse", "rauc-build", "partition", "bsp",
                                 "mkosi", "tar", "boot", "size", "firmware-closure", "packages-lock",
                                 "parity", "raw-slots"), 0),
        "slot_only_additions": ["usr/lib/ceralive/boot/boot.scr", "usr/lib/ceralive/boot/boot.scr.sha256"],
        "metadata_validity": {"schema": 1, "purpose": "rootfs-measurement", "repositories": [{
            "repository": "firstparty", "release_date": "2026-11-19T00:00:00+00:00",
            "release_sha256": "e" * 64, "freshness_checked": False, "freshness": "NOT checked",
        }]},
        "artifacts": {member.id: {"sha256": member.sha256, "bytes": member.length} for member in members},
        "signed_candidate": False,
    }
    inventory = {member.id: member.sha256 for member in members}
    verifier = {"schema": 1, "verified": True, "build_identity": asdict(IDENTITY), "artifacts": inventory, "slots": [
        {"slot": slot, "reserve": "reserved", "removed": ["amdgpu"], "retained": ["nvidia"],
         "nvidia_references": ["nvidia/nouveau.ko"]} for slot in ("rootfs_a", "rootfs_b")
    ]}
    for record, check, args in (
        (row, image_vm.measurement_stages, (IDENTITY, root, members)),
        (verifier, image_vm.validate_verification, (IDENTITY, inventory)),
    ):
        check(record, *args)
        for path, invalid in wrong_typed_records(record):
            try:
                check(invalid, *args)
            except StreamError:
                pass
            else:
                raise AssertionError(f"accepted wrong type at {path}")


def test_terminal_manifest_rejects_every_wrong_typed_field() -> None:
    from image_stream import MAGIC

    content = b"{}"
    member = Member("verification.json", len(content), hashlib.sha256(content).hexdigest())
    first = MAGIC + json.dumps(asdict(member)).encode() + b"\n" + content
    manifest = {"schema": 1, "identity": asdict(IDENTITY), "members": [asdict(member)]}

    def frame(row):
        data = json.dumps(row).encode()
        header = Member("manifest", len(data), hashlib.sha256(data).hexdigest())
        return first + json.dumps(asdict(header)).encode() + b"\n" + data

    with tempfile.TemporaryDirectory() as temporary:
        assert decode(io.BytesIO(frame(manifest)), pathlib.Path(temporary), IDENTITY) == (member,)
    for _, invalid in wrong_typed_records(manifest):
        rejected(frame(invalid))


if __name__ == "__main__":
    tests = [value for name, value in list(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"image route: {len(tests)} passed")
