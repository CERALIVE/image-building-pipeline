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
import tempfile
import time
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
    directory = root / "returns/fixture/build"
    sent = False

    def cancel() -> None:
        nonlocal sent
        sent = True
        (root / "sent").write_text(str(time.monotonic()))
        os.kill(os.getpid(), signum)

    def publish(source, destination) -> None:
        if destination == directory / "exit.json":
            # Compare real descriptor targets before the launcher exits.
            live = {os.readlink(fd) for fd in pathlib.Path("/proc/self/fd").iterdir()
                    if fd.is_symlink() and fd.exists()}
            held = set(json.loads((root / "owned-fds").read_text()))
            held.add(str(root / "capsule"))
            held.update(str(file) for file in directory.glob("*.partial"))
            (root / "leaks").write_text(json.dumps(sorted(live & held)))
            frozen = "launcher_exit" in json.loads(pathlib.Path(source).read_text())
            if not sent and (mode == "receipt" or mode == "committed" and frozen):
                cancel()
        replace_file(source, destination)

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
                if mode not in {"receipt", "validation", "committed"} and not sent:
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
if mode in {{"receipt", "validation", "committed"}}:
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

        expected_status = 0 if mode == "committed" else 1
        assert launcher.returncode == expected_status, stderr.decode()
        pid = (root / "pid").read_text()
        assert not pathlib.Path(f"/proc/{pid}").exists(), "QEMU was not reaped"
        assert not list(root.glob("job-*"))
        assert json.loads((root / "leaks").read_text()) == []
        directory = root / "returns/fixture/build"
        record = json.loads((directory / "exit.json").read_text())
        assert record["stop_reason"] == (
            "guest exited; transport validated" if mode == "committed" else "cancelled"), record
        assert record["input_descriptor_closed"] is True
        assert record["overlay_descriptor_closed"] is True
        assert record["launcher_exit"] == expected_status
        assert record["identity"] == asdict(identity)
        if mode == "overlay":
            assert not (directory / "started.json").exists()
            assert "qemu" not in record and record["qemu_reaped"] is False
        else:
            assert record["qemu"].split(":")[0] == pid
            assert record["qemu_reaped"] is True
            assert record["qemu_exit"] == {"ignore": -9, "slow": -15}.get(mode, 0)
            if mode not in {"receipt", "validation", "committed"}:
                assert record["qemu_priority"] == FIXTURE_PRIORITY
        assert not (root / "returns/active.json").exists()
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
        exit_record = json.loads((directory / "exit.json").read_text())
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
        record = json.loads((directory / "exit.json").read_text())
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
