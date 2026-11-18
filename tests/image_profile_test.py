#!/usr/bin/env python3
"""Run the real launcher lifecycle against small Python children, never a VM."""

from dataclasses import replace
import io
import json
import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ci/kernel-runner"))
import image_lifecycle
import image_resources
from image_lifecycle import ImageJob, reconcile
from image_stream import Identity, StreamError, encode
import vm
from image_vm import retained_outputs, validate_base

IDENTITY = Identity("fixture", "rock-5b-plus", "a" * 40, 1, "b" * 64)


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
            with patch.object(vm.subprocess, "Popen", child), patch.object(image_lifecycle, "disk_headroom"):
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
                        patch.object(image_lifecycle, "disk_headroom"):
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
        "/sys/fs/cgroup/image/io.weight": "default 10\n",
    }
    for field, invalid in ((None, None), ("memory.max", "max"), ("memory.swap.max", "1"),
                           ("cpu.max", "max 100000"), ("io.weight", "default 100")):
        snapshot = files.copy()
        if field:
            snapshot["/sys/fs/cgroup/image/" + field] = invalid
        with patch.object(pathlib.Path, "read_text", lambda path: snapshot[str(path)]), \
                patch.object(pathlib.Path, "is_file", lambda path: str(path) in snapshot), \
                patch.object(image_resources.os, "sched_getaffinity", return_value={0, 1, 2, 3}), \
                patch.object(image_resources.os, "getpriority", return_value=10):
            try:
                image_resources.cgroup_admission()
            except image_resources.AdmissionError:
                assert field is not None
            else:
                assert field is None


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
            with patch("image_vm.subprocess.run", return_value=result):
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
    tests = [test for name, test in list(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"image profile: {len(tests)} passed")
