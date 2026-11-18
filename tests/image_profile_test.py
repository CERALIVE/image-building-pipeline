#!/usr/bin/env python3
"""Run the real launcher lifecycle against small Python children, never a VM."""

from dataclasses import asdict, dataclass, replace
import errno
import fcntl
import io
import json
import hashlib
import os
import pathlib
import runpy
import selectors
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
from types import SimpleNamespace
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ci/kernel-runner"))
import image_lifecycle
import image_resources
import image_vm
from image_lifecycle import ImageJob, reconcile
from image_stream import Identity, StreamError, encode
import vm
from image_vm import retained_outputs, validate_base

IDENTITY = Identity("fixture", "rock-5b-plus", "a" * 40, 1, "b" * 64)
FIXTURE_PRIORITY = {"nice": 9, "ionice": "best-effort: prio 7", "cpu_weight": 10}


def fixture_launcher(root: pathlib.Path, mode: str, signum: signal.Signals) -> None:
    """Run the CLI and deliver a real signal inside the poll owned by select()."""
    poll_type = selectors.EpollSelector._selector_cls
    replace_file = os.replace
    read_text = pathlib.Path.read_text
    fsync = os.fsync
    unlink = pathlib.Path.unlink
    temporary_file = tempfile.TemporaryFile
    directory = root / "returns/fixture/build"
    fault = mode.split(":")[1:] if mode.startswith("fault:") else None
    sent = False
    fail_sync = False

    def cancel() -> None:
        nonlocal sent
        sent = True
        (root / "sent").write_text(str(time.monotonic()))
        os.kill(os.getpid(), signum)

    def fault_at(step: str) -> None:
        if fault is None or fault[1] != step or (root / "injected").exists():
            return
        (root / "injected").touch()
        if fault[0] == "fail":
            raise OSError(errno.EIO, f"fixture {step}")
        cancel()

    def publish(source, destination) -> None:
        nonlocal fail_sync
        if destination in {directory / "exit.json", directory / "teardown.json"}:
            # Compare real descriptor targets before the launcher exits.
            live = {os.readlink(fd) for fd in pathlib.Path("/proc/self/fd").iterdir()
                    if fd.is_symlink() and fd.exists()}
            owned = root / "owned-fds"
            held = set(json.loads(owned.read_text())) if owned.exists() else set()
            held.add(str(root / "capsule"))
            held.update(str(file) for file in directory.glob("*.partial"))
            (root / "leaks").write_text(json.dumps(sorted(live & held)))
            frozen = "launcher_exit" in json.loads(pathlib.Path(source).read_text())
            if not sent and (mode == "receipt" or mode == "committed" and frozen):
                cancel()
            if mode == "exit-sync-error" and frozen:
                fail_sync = True
            with (root / "fixture.lock").open("rb") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    raise AssertionError("receipt written without the lock held")
        replace_file(source, destination)

    def sync(fd):
        nonlocal fail_sync
        path = pathlib.Path(os.readlink(f"/proc/self/fd/{fd}"))
        if fail_sync and path == directory:
            fail_sync = False
            raise OSError(errno.EIO, "fixture exit directory sync")
        for location, stage in ((root, "parent-sync"), (directory / "stream.partial", "capture-sync"),
                                (directory / "artifacts/verification.json", "artifact-sync"),
                                (directory / "artifacts", "artifact-dir-sync")):
            if path == location:
                fault_at(stage)
        fsync(fd)

    def remove(path, *args, **kwargs):
        if path == directory / "stream.partial":
            fault_at("stream-unlink")
        if path == root / "returns/active.json":
            fault_at("journal-unlink")
        return unlink(path, *args, **kwargs)

    def overlay(*args, **kwargs):
        fault_at("overlay-create")
        file = temporary_file(*args, **kwargs)

        class Overlay:
            def fileno(self):
                return file.fileno()

            def close(self):
                file.close()
                fault_at("overlay-close")

        return Overlay()

    def read_result(path, *args, **kwargs):
        if mode == "validation" and path == directory / "artifacts/verification.json":
            cancel()
        return read_text(path, *args, **kwargs)

    def poller():
        epoll = poll_type()

        class Poll:
            def __getattr__(self, name):
                return getattr(epoll, name)

            def poll(self, *args):
                if not fault and mode not in {"receipt", "validation", "committed", "exit-sync-error"} and not sent:
                    until = time.monotonic() + 5
                    while not (root / "ready").exists():
                        assert time.monotonic() < until, "fake QEMU never reached startup"
                        time.sleep(0.01)
                    cancel()
                return epoll.poll(*args)

        return Poll()

    capsule = root / "capsule"
    base = root / "base"
    sys.argv = [str(ROOT / "ci/kernel-runner/vm.py"), "image", "--base", str(base),
                "--base-sha256", hashlib.sha256(base.read_bytes()).hexdigest(),
                "--input-capsule", str(capsule),
                "--input-sha256", hashlib.sha256(capsule.read_bytes()).hexdigest(),
                "--trust-policy", str(root / "unused-policy"), "--output-dir", str(root / "returns"),
                "--source-commit", IDENTITY.commit, "--source-epoch", str(IDENTITY.epoch),
                "--attempt", IDENTITY.attempt, "--board", IDENTITY.board, "--image-mode", "probe"]
    with patch.object(selectors.EpollSelector, "_selector_cls", staticmethod(poller)), \
            patch.object(os, "replace", publish), \
            patch.object(os, "fsync", sync), \
            patch.object(pathlib.Path, "unlink", remove), \
            patch.object(tempfile, "TemporaryFile", overlay), \
            patch.object(pathlib.Path, "read_text", read_result), \
            patch.multiple(image_vm, require_host_lock=lambda: None, cgroup_admission=lambda: None,
                           disk_admission=lambda *_args: None, disk_headroom=lambda *_args: None), \
            patch.object(image_vm, "load_policy", return_value=FixturePolicy()), \
            patch.object(image_lifecycle, "disk_headroom"), \
            patch.object(image_lifecycle, "process_priority", return_value=FIXTURE_PRIORITY):
        runpy.run_path(sys.argv[0], run_name="__main__")


@dataclass(frozen=True, slots=True)
class FixturePolicy:
    root_der_sha256: str = "d" * 64


def cancelled_fixture(mode: str, signum: signal.Signals = signal.SIGTERM) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        capsule = root / "capsule"
        capsule.write_bytes(b"public fixture")
        base = root / "base"
        base.write_bytes(b"public base")
        base.chmod(0o444)
        identity = replace(IDENTITY, input_sha256=hashlib.sha256(capsule.read_bytes()).hexdigest())
        with (root / "probe.frame").open("wb") as output:
            encode(output, [("verification.json", json.dumps({
                "schema": 1, "identity": asdict(identity), "network_denied": True,
            }).encode())], identity)
        qemu_img = root / "qemu-img"
        qemu_img.write_text(f"""#!{sys.executable}
import json, os, pathlib, signal, sys, time
if sys.argv[1] == "info":
    print(json.dumps({{"format": "qcow2", "virtual-size": 137438953472}}))
elif sys.argv[1] == "create":
    if {mode!r} == "overlay":
        root = pathlib.Path({tmp!r})
        (root / "pid").write_text(str(os.getpid()))
        (root / "owned-fds").write_text(json.dumps([os.readlink(sys.argv[-1])]))
        (root / "sent").write_text(str(time.monotonic()))
        os.kill(os.getppid(), signal.SIGTERM)
        time.sleep(60)
else:
    sys.exit(2)
""")
        qemu_img.chmod(0o700)
        qemu = root / "qemu-system-x86_64"
        qemu.write_text(f"""#!{sys.executable}
import json, os, pathlib, signal, sys, time
root = pathlib.Path({tmp!r})
mode = {mode!r}
def term(_signum, _frame):
    (root / "term").touch()
    if mode == "repeat":
        os.kill(os.getppid(), signal.SIGTERM)
    if mode != "ignore":
        sys.exit(0)
if mode != "slow":
    signal.signal(signal.SIGTERM, term)
fds = {{1, 2}} | {{int(arg.split("/proc/self/fd/")[1].split(",")[0])
                   for arg in sys.argv if "/proc/self/fd/" in arg}}
(root / "owned-fds").write_text(json.dumps([os.readlink(f"/proc/self/fd/{{fd}}") for fd in fds]))
(root / "pid").write_text(str(os.getpid()))
(root / "ready").touch()
if mode in {{"receipt", "validation", "committed", "exit-sync-error"}} or mode.startswith("fault:"):
    os.write(1, (root / "probe.frame").read_bytes())
    sys.exit(0)
if mode == "slow":
    # Startup has not initialized the guest or installed a TERM handler.
    time.sleep(60)
while True:
    signal.pause()
""")
        qemu.chmod(0o700)

        # A private flock gives the real CLI its required direct parent without
        # participating in workstation admission or touching the real host lock.
        with subprocess.Popen(
            ["flock", "--exclusive", "--close", str(root / "fixture.lock"), sys.executable,
             __file__, "--fixture-launcher", str(root), mode, str(signum.value)],
            env={"PATH": f"{root}:/usr/bin:/bin", "TMPDIR": tmp, "PYTHONDONTWRITEBYTECODE": "1"},
            start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ) as launcher:
            seconds = 27 if mode == "ignore" else 8
            try:
                _, stderr = launcher.communicate(timeout=seconds)
            except subprocess.TimeoutExpired as error:
                assert (root / "sent").exists(), "fixture never delivered cancellation"
                pid = (root / "pid").read_text()
                assert pathlib.Path(f"/proc/{pid}").exists()
                assert not (root / "returns/fixture/build/exit.json").exists()
                raise AssertionError("cancellation left the QEMU child alive and no exit receipt") from error
            finally:
                if launcher.poll() is None:
                    if (root / "pid").exists():
                        pid = int((root / "pid").read_text())
                        try:
                            handle = os.pidfd_open(pid)
                            try:
                                if os.getpgid(pid) == launcher.pid:
                                    signal.pidfd_send_signal(handle, signal.SIGKILL)
                            finally:
                                os.close(handle)
                        except ProcessLookupError:
                            pass
                    try:
                        launcher.communicate(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(launcher.pid, signal.SIGKILL)
                        launcher.communicate()

        directory = root / "returns/fixture/build"
        if mode.startswith("fault:"):
            action, boundary = mode.split(":")[1:]
            assert (root / "injected").is_file(), (mode, stderr)
            assert launcher.returncode == 1, (mode, stderr)
            marker = directory / "exit.json"
            assert marker.exists() == (action == "term" and boundary != "parent-sync"), mode
            if marker.exists():
                row = json.loads(marker.read_text())
                assert row["launcher_exit"] == launcher.returncode and row["stop_reason"] == "cancelled", mode
            assert not (directory.parent / "acceptance.json").exists(), mode
            assert not list(root.rglob(".receipt-*")), mode
            assert not list(root.glob("job-*")), mode
            if (root / "pid").exists():
                assert not pathlib.Path(f"/proc/{(root / 'pid').read_text()}").exists(), mode
            with (root / "fixture.lock").open("rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        expected_status = 0 if mode in {"committed", "exit-sync-error"} else 1
        pid = (root / "pid").read_text()
        assert not pathlib.Path(f"/proc/{pid}").exists(), "QEMU was not reaped"
        assert not list(root.glob("job-*"))
        assert json.loads((root / "leaks").read_text()) == []
        record = json.loads((directory / "exit.json").read_text())
        assert record["stop_reason"] == (
            "guest exited; transport validated" if expected_status == 0 else "cancelled"), record
        assert record["input_descriptor_closed"] is True
        assert record["overlay_descriptor_closed"] is True
        assert record["launcher_exit"] == expected_status
        assert launcher.returncode == record["launcher_exit"], stderr.decode()
        assert record["identity"] == asdict(identity)
        if mode == "overlay":
            assert not (directory / "started.json").exists()
            assert "qemu" not in record and record["qemu_reaped"] is False
        else:
            assert record["qemu"].split(":")[0] == pid
            assert record["qemu_reaped"] is True
            assert record["qemu_exit"] == {"ignore": -9, "slow": -15}.get(mode, 0)
            if mode not in {"receipt", "validation", "committed", "exit-sync-error"}:
                assert record["qemu_priority"] == FIXTURE_PRIORITY
        assert not (root / "returns/active.json").exists()
        if mode == "exit-sync-error":
            assert b"fixture exit directory sync" in stderr
        else:
            assert time.monotonic() - float((root / "sent").read_text()) < seconds
        if mode in {"term", "ignore", "repeat"}:
            assert (root / "term").exists(), "QEMU did not receive TERM"


def test_one_term_in_selector_reaps_term_resistant_qemu() -> None:
    cancelled_fixture("ignore")


def test_term_int_hup_and_repeated_term_preserve_teardown() -> None:
    for mode, signum in (("term", signal.SIGTERM), ("term", signal.SIGINT),
                         ("term", signal.SIGHUP), ("repeat", signal.SIGTERM),
                         ("slow", signal.SIGTERM), ("overlay", signal.SIGTERM),
                         ("receipt", signal.SIGTERM)):
        cancelled_fixture(mode, signum)


def test_term_during_final_probe_validation_updates_receipt_and_status() -> None:
    cancelled_fixture("validation")


def test_term_after_final_outcome_is_decided_preserves_receipt_and_status() -> None:
    cancelled_fixture("committed")


def test_final_receipt_rename_decides_status_even_if_directory_sync_fails() -> None:
    cancelled_fixture("exit-sync-error")


def test_failed_verifier_receipt_does_not_publish_pair_acceptance() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        attempt = pathlib.Path(temporary) / "fixture"
        build, verifier = attempt / "build", attempt / "verify"
        build.mkdir(parents=True)
        verifier.mkdir()
        acceptance = attempt / "acceptance.json"
        real_receipt = image_lifecycle.receipt

        def measure(_args, _parser, _cancellation, jobs):
            for directory in (build, verifier):
                state = {"stop_reason": "transport validated", "identity": asdict(IDENTITY)}
                jobs.append(SimpleNamespace(directory=directory, state=state))
                image_vm.receipt(directory / "teardown.json", state)
            return acceptance, {"content_verified": True}

        def publish(path, row, **kwargs):
            if path.parent == verifier:
                raise OSError(errno.EIO, "fixture verifier receipt write")
            return real_receipt(path, row, **kwargs)

        with patch.object(image_vm, "measure_image", measure), patch.object(image_vm, "receipt", publish):
            try:
                status = image_vm.run_image(SimpleNamespace(image_mode="measure"), None, vm.Cancellation())
            except OSError:
                status = 1  # The CLI catches launcher receipt failures.
        assert status == 1
        assert not acceptance.exists(), "pair was accepted before its verifier receipt"
        assert not (attempt / "exit.json").exists()
        assert "launcher_exit" not in json.loads((build / "teardown.json").read_text())


def test_pair_publication_failure_and_signal_matrix() -> None:
    # Exercise the real receipt writer at every step, for both prerequisite
    # receipts and the final marker. The pair stands in for the expensive guest
    # output; the earlier probe cases exercise the real child and overlay path.
    phases = ("temp-open", "temp-write", "file-sync", "rename", "dir-open", "dir-sync")
    receipts = ("overlay-journal", "started.json", "guest-journal", "transport-validation.json",
                "build/teardown.json", "verify/teardown.json", "acceptance.json", "exit.json")
    real_receipt, real_open, real_dump = image_lifecycle.receipt, os.open, json.dump
    real_fsync, real_replace = os.fsync, os.replace
    for target in receipts:
        for step in phases:
            for failure in (True, False):
                with tempfile.TemporaryDirectory() as temporary:
                    attempt = pathlib.Path(temporary) / IDENTITY.attempt
                    build, verifier = attempt / "build", attempt / "verify"
                    build.mkdir(parents=True)
                    verifier.mkdir()
                    candidate, marker = attempt / "acceptance.json", attempt / "exit.json"
                    paths = {"overlay-journal": attempt / "active.json", "started.json": build / "started.json",
                             "guest-journal": attempt / "active.json",
                             "transport-validation.json": verifier / "transport-validation.json",
                             "build/teardown.json": build / "teardown.json",
                             "verify/teardown.json": verifier / "teardown.json",
                             "acceptance.json": candidate, "exit.json": marker}
                    info = asdict(IDENTITY)
                    result = {"schema": 1, "identity": info, "content_verified": True}
                    cancellation = vm.Cancellation()
                    previous = signal.signal(signal.SIGTERM, cancellation.request)
                    active_name = None
                    injected = False

                    def inject(event):
                        nonlocal injected
                        if active_name == target and event == step and not injected:
                            injected = True
                            if failure:
                                raise OSError(errno.EIO, f"fixture {target} {step}")
                            os.kill(os.getpid(), signal.SIGTERM)

                    def open_file(path, flags, *args, **kwargs):
                        if isinstance(path, pathlib.Path) and path.name.startswith(".receipt-"):
                            inject("temp-open")
                        if flags & os.O_DIRECTORY:
                            inject("dir-open")
                        return real_open(path, flags, *args, **kwargs)

                    def dump(*args, **kwargs):
                        inject("temp-write")
                        return real_dump(*args, **kwargs)

                    def sync(fd):
                        kind = "dir-sync" if pathlib.Path(f"/proc/self/fd/{fd}").is_dir() else "file-sync"
                        inject(kind)
                        return real_fsync(fd)

                    def replace_file(source, destination):
                        inject("rename")
                        return real_replace(source, destination)

                    def publish(path, row, **kwargs):
                        nonlocal active_name
                        if path == paths.get(active_name):
                            pass
                        elif path in (candidate, marker):
                            active_name = path.name
                        try:
                            return real_receipt(path, row, **kwargs)
                        finally:
                            active_name = None

                    def measure(_args, _parser, flag, jobs):
                        nonlocal active_name
                        for directory in (build, verifier):
                            state = {"identity": info, "stop_reason": "guest exited; transport validated"}
                            jobs.append(SimpleNamespace(directory=directory, state=state))
                        for name in receipts[:-2]:
                            active_name = name
                            publish(paths[name], {"identity": info})
                            flag.check()
                        return candidate, result

                    try:
                        with patch.object(image_vm, "measure_image", measure), \
                                patch.object(image_vm, "receipt", publish), \
                                patch.object(os, "open", open_file), patch.object(json, "dump", dump), \
                                patch.object(os, "fsync", sync), patch.object(os, "replace", replace_file):
                            status = image_vm.run_image(SimpleNamespace(image_mode="measure"), None, cancellation)
                    finally:
                        signal.signal(signal.SIGTERM, previous)

                    case = (target, step, "failure" if failure else "TERM")
                    assert injected, case
                    after_commit = target == "exit.json" and (
                        step in {"dir-open", "dir-sync"} or step == "rename" and not failure)
                    assert status == (0 if after_commit else 1), case
                    if marker.exists():
                        outcome = json.loads(marker.read_text())
                        assert outcome["launcher_exit"] == status, case
                        if status:
                            assert outcome["stop_reason"] == "cancelled", case
                    assert marker.exists() == (after_commit or not failure), case
                    assert (image_vm.completed_acceptance(candidate) is not None) == after_commit, case
                    assert not list(attempt.rglob(".receipt-*")), case


def test_probe_cleanup_and_artifact_publication_failures_never_publish_success() -> None:
    for step in ("parent-sync", "overlay-create", "overlay-close", "capture-sync",
                 "artifact-sync", "artifact-dir-sync", "stream-unlink", "journal-unlink"):
        for action in ("fail", "term"):
            cancelled_fixture(f"fault:{action}:{step}")


def test_verifier_capsule_and_result_failures_leave_pair_unaccepted() -> None:
    real_open, real_read, real_unlink = os.open, pathlib.Path.read_text, pathlib.Path.unlink
    for step in ("capsule-create", "capsule-copy", "verifier-result", "capsule-unlink", "success"):
        for action in (("success",) if step == "success" else ("fail", "term")):
            with tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                base, input_file, store = root / "base", root / "input.tar", root / "returns"
                base.touch()
                with tarfile.open(input_file, "w") as archive:
                    data = b'{"objects":[]}'
                    header = tarfile.TarInfo("inventory.json")
                    header.size = len(data)
                    archive.addfile(header, io.BytesIO(data))
                identity = replace(IDENTITY, input_sha256=hashlib.sha256(input_file.read_bytes()).hexdigest())
                args = SimpleNamespace(
                    image_mode="measure", input_capsule=input_file, input_sha256=identity.input_sha256,
                    base=base, base_sha256="c" * 64, trust_policy=root / "policy", output_dir=store,
                    attempt=identity.attempt, board=identity.board, source_commit=identity.commit,
                    source_epoch=identity.epoch, source_bundle=None, check_script=None, group_id=None)
                attempt = store / identity.attempt
                capsule = attempt / "verifier-input.tar"
                verification = attempt / "verify/artifacts/verification.json"
                cancellation = vm.Cancellation()
                previous = signal.signal(signal.SIGTERM, cancellation.request)
                injected = False

                def inject(point):
                    nonlocal injected
                    if step != point or injected:
                        return
                    injected = True
                    if action == "fail":
                        raise OSError(errno.EIO, f"fixture {point}")
                    os.kill(os.getpid(), signal.SIGTERM)

                def open_file(path, *options, **kwargs):
                    if path == capsule:
                        inject("capsule-create")
                    return real_open(path, *options, **kwargs)

                def addfile(archive, header, file=None):
                    if header.name.startswith("objects/"):
                        inject("capsule-copy")
                    return real_addfile(archive, header, file)

                def read_text(path, *options, **kwargs):
                    if path == verification:
                        inject("verifier-result")
                    return real_read(path, *options, **kwargs)

                def unlink(path, *options, **kwargs):
                    if path == capsule:
                        inject("capsule-unlink")
                    return real_unlink(path, *options, **kwargs)

                def execute(_base, directory, request, _cancellation, jobs):
                    payload = request["payload"]
                    artifacts = directory / "artifacts"
                    artifacts.mkdir(parents=True)
                    state = {"identity": payload["identity"], "stop_reason": "guest exited; transport validated"}
                    jobs.append(SimpleNamespace(directory=directory, state=state))
                    image_lifecycle.receipt(directory / "teardown.json", state)
                    if payload["operation"] == "measure":
                        (artifacts / "fixture").write_bytes(b"public artifact")
                    else:
                        assert request["capsule"] == capsule and capsule.is_file()
                        verification.write_text(json.dumps({
                            "schema": 1, "verified": True, "build_identity": payload["build_identity"],
                            "artifacts": payload["artifacts"],
                            "slots": [{"slot": "rootfs_a"}, {"slot": "rootfs_b"}],
                        }))
                    return artifacts

                real_addfile = tarfile.TarFile.addfile
                try:
                    with patch.multiple(image_vm, require_host_lock=lambda: None, cgroup_admission=lambda: None,
                                        validate_base=lambda *_args: None, disk_admission=lambda *_args: None,
                                        load_policy=lambda *_args: FixturePolicy(), execute=execute), \
                            patch.object(image_resources.ImageCaps, "qemu_limit"), \
                            patch.object(os, "open", open_file), patch.object(tarfile.TarFile, "addfile", addfile), \
                            patch.object(pathlib.Path, "read_text", read_text), \
                            patch.object(pathlib.Path, "unlink", unlink):
                        status = image_vm.run_image(args, None, cancellation)
                finally:
                    signal.signal(signal.SIGTERM, previous)
                marker = attempt / "exit.json"
                successful = action == "success"
                assert injected != successful, (step, action)
                assert status == int(not successful), (step, action)
                assert marker.exists() == (action != "fail"), (step, action)
                if marker.exists():
                    row = json.loads(marker.read_text())
                    assert row["launcher_exit"] == status
                    assert row["pair_complete"] == successful
                assert (image_vm.completed_acceptance(attempt / "acceptance.json") is not None) == successful


def test_term_while_check_waits_for_fifo_releases_its_overlay_and_lock() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        script, base, lock = (root / name for name in ("script.fifo", "base", "fixture.lock"))
        os.mkfifo(script)
        base.touch()
        qemu_img = root / "qemu-img"
        qemu_img.write_text("#!/bin/sh\nexit 0\n")
        qemu_img.chmod(0o700)
        qemu = root / "qemu-system-x86_64"
        qemu.write_text(f"#!/bin/sh\ntouch '{root / 'unexpected-qemu'}'\nexit 3\n")
        qemu.chmod(0o700)
        command = ["flock", "--exclusive", "--close", str(lock), sys.executable,
                   str(ROOT / "ci/kernel-runner/vm.py"), "check",
                   "--check-script", str(script), "--base", str(base)]
        with subprocess.Popen(command, start_new_session=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env={"PATH": f"{root}:/usr/bin:/bin",
                              "TMPDIR": temporary, "PYTHONDONTWRITEBYTECODE": "1"}) as launcher:
            writer = handle = None
            try:
                until = time.monotonic() + 5
                while writer is None:
                    try:
                        writer = os.open(script, os.O_WRONLY | os.O_NONBLOCK)
                    except OSError as error:
                        if error.errno != errno.ENXIO:
                            raise
                        assert time.monotonic() < until, "launcher did not open the FIFO"
                        time.sleep(0.01)
                children = pathlib.Path(f"/proc/{launcher.pid}/task/{launcher.pid}/children")
                pid, = map(int, children.read_text().split())
                handle = os.pidfd_open(pid)
                descriptors = [os.readlink(fd) for fd in pathlib.Path(f"/proc/{pid}/fd").iterdir()]
                assert any(str(root) in fd and fd.endswith(" (deleted)") for fd in descriptors)

                signal.pidfd_send_signal(handle, signal.SIGTERM)
                try:
                    output, stderr = launcher.communicate(timeout=3)
                except subprocess.TimeoutExpired as error:
                    raise AssertionError("one TERM left the empty FIFO and lock held") from error

                assert launcher.returncode == 1, stderr.decode()
                assert b"runner cancelled" in stderr
                assert not output and not (root / "unexpected-qemu").exists()
                assert not pathlib.Path(f"/proc/{pid}").exists()
                assert not list(root.glob("job-*"))
                with lock.open("rb") as lock_file:
                    fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                if writer is not None:
                    os.close(writer)
                if handle is not None:
                    os.close(handle)
                if launcher.poll() is None:
                    try:
                        launcher.communicate(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(launcher.pid, signal.SIGKILL)
                        launcher.communicate()


def test_image_has_no_nic_shares_registration_or_credential_environment() -> None:
    real_popen = subprocess.Popen
    envelope = io.BytesIO()
    encode(envelope, [("verification.json", b"{}")], IDENTITY)
    observed = []

    def child(args, **options):
        observed.append(args)
        assert args[args.index("-smp") + 1] == "4"
        assert args[args.index("-m") + 1] == "20480"
        assert args[args.index("-nic") + 1] == "none"
        assert "-netdev" not in args
        assert not any(option in args for option in ("-virtfs", "-fsdev", "-qmp"))
        assert not any("9p" in arg or "hostfwd" in arg or "vhost-user" in arg for arg in args)
        assert "virtserialport,chardev=artifacts,name=ceralive-artifacts" in args
        capsule = next(arg for arg in args if "id=image-input," in arg)
        assert capsule.endswith(",readonly=on")
        assert capsule.startswith("file=/proc/self/fd/")
        assert set(options["env"]) == {"PATH", "LANG"}
        assert options["stdin"] == subprocess.DEVNULL
        assert options["preexec_fn"].func is vm.die_with_parent
        assert options["preexec_fn"].args == (os.getpid(),)
        return real_popen([sys.executable, "-c",
                          f"import os; os.write(1, {envelope.getvalue()!r})"], **options)

    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        directory = root / "fixture/build"
        directory.mkdir(parents=True)
        capsule = root / "capsule"
        capsule.write_bytes(b"not a credential")
        with tempfile.TemporaryFile(dir=root) as overlay, ImageJob(directory, IDENTITY, capsule) as job:
            job.state.update(overlay_directory=str(root), retained_bytes=0)
            job.overlay_created(overlay.fileno())
            with patch.object(vm.subprocess, "Popen", child), patch.object(image_lifecycle, "disk_headroom"), \
                    patch.object(image_lifecycle, "process_priority", return_value=FIXTURE_PRIORITY):
                vm.boot(pathlib.Path(f"/proc/self/fd/{overlay.fileno()}"), b"{}", "image", 5,
                        disk_fd=overlay.fileno(), image_job=job)
            assert job.state["qemu_reaped"] is True
        exit_record = json.loads((directory / "teardown.json").read_text())
        assert exit_record["input_descriptor_closed"] is True
        assert (directory / "stream.partial").read_bytes() == envelope.getvalue()
    assert len(observed) == 1


def test_kernel_check_keeps_its_existing_cpu_ram_and_network_defaults() -> None:
    real_popen = subprocess.Popen

    def child(args, **options):
        assert args[args.index("-smp") + 1] == "16"
        assert args[args.index("-m") + 1] == "16384"
        assert "user,id=net0" in args and "virtio-net-pci,netdev=net0" in args
        assert "-chardev" not in args
        return real_popen([sys.executable, "-c", 'print("CERALIVE_JOB_DONE=0")'], **options)

    with patch.object(vm.subprocess, "Popen", child):
        vm.boot(pathlib.Path("/unused"), b"exit 0", "check", 5)


def test_oversized_stream_reaps_only_its_owned_child_and_closes_inputs() -> None:
    real_popen = subprocess.Popen
    children = []

    def child(_args, **options):
        process = real_popen([sys.executable, "-c",
            'import os, signal; os.write(1, b"x" * 1025); signal.pause()'], **options)
        children.append(process)
        return process

    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        directory = root / "fixture/build"
        directory.mkdir(parents=True)
        capsule = root / "capsule"
        capsule.write_bytes(b"fixture")
        try:
            with tempfile.TemporaryFile(dir=root) as overlay, ImageJob(directory, IDENTITY, capsule) as job:
                job.state.update(overlay_directory=str(root), retained_bytes=0)
                job.overlay_created(overlay.fileno())
                with patch.object(vm.subprocess, "Popen", child), \
                        patch.object(image_lifecycle, "CAPS", replace(image_resources.CAPS, stream_max=1024)), \
                        patch.object(image_lifecycle, "disk_headroom"), \
                        patch.object(image_lifecycle, "process_priority", return_value=FIXTURE_PRIORITY):
                    vm.boot(pathlib.Path("/unused"), b"{}", "image", 5,
                            disk_fd=overlay.fileno(), image_job=job)
        except StreamError:
            pass
        else:
            raise AssertionError("oversized stream accepted")
        record = json.loads((directory / "teardown.json").read_text())
        assert record["qemu_reaped"] is True and record["input_descriptor_closed"] is True
        assert (directory / "stream.partial").stat().st_size == 0
        assert len(children) == 1 and children[0].returncode is not None


def test_same_filesystem_headroom_combines_overlay_and_return_budgets() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        path = pathlib.Path(temporary)
        class Usage:
            f_bavail = 50
            f_frsize = image_resources.GIB
        with patch.object(image_resources.os, "statvfs", return_value=Usage()):
            try:
                image_resources.disk_headroom(((path, 20 * image_resources.GIB),
                                              (path, 20 * image_resources.GIB)))
            except image_resources.AdmissionError:
                return
    raise AssertionError("shared filesystem was charged only once")


def test_image_admission_requires_effective_cgroup_caps() -> None:
    gib = image_resources.GIB
    files = {
        "/proc/self/cgroup": "0::/image\n",
        "/proc/meminfo": "MemAvailable: 33554432 kB\n",
        "/sys/fs/cgroup/image/memory.max": str(24 * gib),
        "/sys/fs/cgroup/image/memory.swap.max": "0",
        "/sys/fs/cgroup/image/cpu.max": "400000 100000",
        "/sys/fs/cgroup/image/cpu.weight": "10",
        "/sys/fs/cgroup/image/io.weight": "default 10\n",
    }
    for field, invalid in ((None, None), ("memory.max", "max"), ("memory.swap.max", "1"),
                           ("cpu.max", "max 100000"), ("io.weight", "default 100"),
                           ("cpu.weight", "100")):
        snapshot = files.copy()
        if field:
            snapshot["/sys/fs/cgroup/image/" + field] = invalid
        with patch.object(pathlib.Path, "read_text", lambda path: snapshot[str(path)]), \
                patch.object(pathlib.Path, "is_file", lambda path: str(path) in snapshot), \
                patch.object(image_resources.os, "sched_getscheduler", return_value=os.SCHED_OTHER), \
                patch.object(image_resources.os, "sched_getaffinity", return_value={0, 1, 2, 3}), \
                patch.object(image_resources.os, "getpriority", return_value=10):
            try:
                image_resources.cgroup_admission()
            except image_resources.AdmissionError:
                assert field is not None
            else:
                assert field is None


def test_nice_nine_requires_low_cpu_weight_and_all_hard_caps() -> None:
    files = {
        "/proc/self/cgroup": "0::/image\n",
        "/proc/meminfo": "MemAvailable: 33554432 kB\n",
        "/sys/fs/cgroup/image/memory.max": str(24 * image_resources.GIB),
        "/sys/fs/cgroup/image/memory.swap.max": "0",
        "/sys/fs/cgroup/image/cpu.max": "400000 100000",
        "/sys/fs/cgroup/image/cpu.weight": "10",
        "/sys/fs/cgroup/image/io.weight": "default 10\n",
    }
    for nice, missing, accepted in ((9, None, True), (19, None, True), (8, None, False),
                                    (-1, None, False), (9, "cpu.weight", False),
                                    (9, "cpu.max", False), (9, "memory.max", False),
                                    (9, "memory.swap.max", False)):
        snapshot = {path: value for path, value in files.items()
                    if pathlib.Path(path).name != missing}
        with patch.object(pathlib.Path, "read_text", lambda path: snapshot[str(path)]), \
                patch.object(pathlib.Path, "is_file", lambda path: str(path) in snapshot), \
                patch.object(image_resources.os, "sched_getscheduler", return_value=os.SCHED_OTHER), \
                patch.object(image_resources.os, "sched_getaffinity", return_value={0, 1, 2, 3}), \
                patch.object(image_resources.os, "getpriority", return_value=nice):
            try:
                image_resources.cgroup_admission()
            except image_resources.AdmissionError as error:
                assert not accepted, (nice, missing, str(error))
            else:
                assert accepted, (nice, missing)


def test_reconciliation_holds_admission_until_owned_overlay_descriptors_close() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        # Keep the inode linked through reconciliation so unrelated CI logs cannot reuse it.
        with (root / "overlay").open("w+b") as owned:
            inode = os.fstat(owned.fileno())
            (root / "active.json").write_text(json.dumps({
                "attempt": "interrupted", "overlay_inode": [inode.st_dev, inode.st_ino]}))
            try:
                reconcile(root)
            except image_resources.AdmissionError:
                pass
            else:
                raise AssertionError("live owned overlay admitted another guest")
        with (root / "unrelated.log").open("wb"):
            reconcile(root)
        record = json.loads((root / "interrupted.reconciled.json").read_text())
        assert record["overlay_descriptors_closed"] is True
        assert record["stop_reason"] == "previous launcher interrupted; guest cleanup unknown"


def test_image_base_rejects_backing_and_nested_external_data_files() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        base = pathlib.Path(temporary) / "public-base-fixture"
        base.write_bytes(b"synthetic public base")
        base.chmod(0o444)
        digest = hashlib.sha256(b"synthetic public base").hexdigest()
        valid = {"format": "qcow2", "virtual-size": 128 * image_resources.GIB,
                 "format-specific": {"type": "qcow2", "data": {"compat": "1.1"}}}
        for changes in ({}, {"backing-filename": "/foreign"},
                        {"format-specific": {"data": {"data-file": "/foreign"}}},
                        {"format-specific": {"data": {"data-file-raw": True}}},
                        {"virtual-size": 240 * image_resources.GIB}):
            result = subprocess.CompletedProcess([], 0, json.dumps(valid | changes).encode())
            with patch("image_vm.run", return_value=result):
                try:
                    validate_base(base, digest)
                except image_resources.AdmissionError:
                    assert changes
                else:
                    assert not changes


def test_quarantined_outputs_do_not_reduce_future_pair_disk_admission() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        store = pathlib.Path(temporary)
        artifacts = store / "previous/build/artifacts"
        artifacts.mkdir(parents=True)
        with (artifacts / "fixture").open("wb") as output:
            output.write(b"public fixture" * 1024)
            output.flush()
            os.fsync(output.fileno())
        allocated = (artifacts / "fixture").stat().st_blocks * 512
        assert allocated > 0
        assert retained_outputs(store, IDENTITY, ("c" * 64, "d" * 64)) == 0
        (store / "previous/acceptance.json").write_text(json.dumps({
            "schema": 1, "content_verified": True, "base_sha256": "c" * 64,
            "public_root_der_sha256": "d" * 64,
            "identity": {"attempt": "previous", "board": "orange-pi-5-plus",
                         "commit": IDENTITY.commit, "epoch": IDENTITY.epoch,
                         "input_sha256": "b" * 64}}))
        candidate = store / "previous/acceptance.json"
        assert retained_outputs(store, IDENTITY, ("c" * 64, "d" * 64)) == 0
        (candidate.parent / "exit.json").write_text(json.dumps({
            "schema": 1, "launcher_exit": 0, "pair_complete": True,
            "identity": json.loads(candidate.read_text())["identity"],
            "acceptance_sha256": hashlib.sha256(candidate.read_bytes()).hexdigest(),
        }))
        assert retained_outputs(store, IDENTITY, ("c" * 64, "d" * 64)) == allocated


if __name__ == "__main__":
    if sys.argv[1:2] == ["--fixture-launcher"]:
        fixture_launcher(pathlib.Path(sys.argv[2]), sys.argv[3], signal.Signals(int(sys.argv[4])))
        raise AssertionError("launcher did not exit")
    tests = [test for name, test in list(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"image profile: {len(tests)} passed")
