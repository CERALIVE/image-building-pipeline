#!/usr/bin/env python3
"""Owner-started, single-job KVM runners; never share host directories or tokens."""

from __future__ import annotations

import argparse
import base64
from contextlib import ExitStack
import hashlib
from io import FileIO
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

import yaml
from image_lifecycle import job_disk, report_error, retire_journal
from image_stream import listed_entry, read_check, read_check_text, retry_check, retry_io
from vm_process import (
    STOP_SIGNALS, Cancellation, ChildContainmentError, ChildSetupError, close_transport, die_with_parent,
    read_check_script, register_close, run,
    spawn_owned, wait,
)
from vm_startup import STARTUP_ERROR, StartupError, sanitize_startup

HERE = Path(__file__).resolve().parent
IMAGE_URL = "https://cloud-images.ubuntu.com/noble/20261017/noble-server-cloudimg-amd64.img"
IMAGE_SHA = "04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94"
RUNNER_VERSION = "2.338.2"
RUNNER_SHA = "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40"


def boot(disk: Path, payload: bytes, kind: str, seconds: int,
         seed: Path | None = None, source_bundle: Path | None = None,
         disk_fd: int | None = None, image_job=None, image_base: bool = False,
         cancellation: Cancellation | None = None) -> None:
    """Pass the one-job credential in an anonymous RAM fd, not argv or a file."""
    cancellation = cancellation or (image_job.cancellation if image_job else Cancellation())
    cancellation.check()
    try:
        startup = ExitStack()
        writers = ExitStack()
    except (MemoryError, OSError) as error:
        raise ChildSetupError("cannot prepare guest ownership") from error
    with startup, writers:
        config = FileIO("/dev/null", "wb", opener=lambda _path, _flags: os.memfd_create(
            "ceralive-job", os.MFD_CLOEXEC))
        on_loss = image_job.lose_diagnostics if image_job and image_job.probe else None
        register_close(startup, "fw-cfg", config.close, on_loss)
        fd = config.fileno()
        os.write(fd, payload)
        os.lseek(fd, 0, os.SEEK_SET)
        serial = "stdio"
        if image_job:
            console = image_job.console_write
            serial = f"file:/dev/fdset/{console}" if image_job.probe else f"file:/proc/self/fd/{console}"
        args = [
            "qemu-system-x86_64", "-enable-kvm", "-machine", "q35", "-cpu", "host",
            "-smp", "4" if image_job or image_base else "16",
            "-m", "20480" if image_job or image_base else "16384", "-display", "none", "-monitor", "none",
            "-serial", serial,
            "-no-reboot",
            "-drive", f"file={disk},format=qcow2,if=none,id=system",
            "-device", "virtio-blk-pci,drive=system,bootindex=1",
            "-fw_cfg", f"name=opt/ceralive/{kind},file=/proc/self/fd/{fd}",
        ]
        if image_job:
            from image_vm import image_arguments
            args += image_arguments(image_job)
            if image_job.probe:
                # Duplicate the inherited nonblocking writer without reopening a
                # FIFO that might no longer have a reader.
                args += ["-add-fd", f"fd={console},set={console}"]
        else:
            args += ["-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0"]
        if seed:
            args += ["-drive", f"file={seed},format=raw,media=cdrom,readonly=on"]
        if source_bundle:
            args += ["-drive", f"file={source_bundle.resolve()},format=raw,if=none,id=source,readonly=on",
                     "-device", "virtio-blk-pci,drive=source,serial=ceralive-source"]
        # The gh credential stays in the host's gh process; QEMU gets no host env secrets.
        descriptors = (fd,) if disk_fd is None else (fd, disk_fd)
        if image_job:
            descriptors += (image_job.capsule_fd, console)
        if any(private_fd < 3 for private_fd in descriptors):
            raise RuntimeError("guest descriptor aliases a standard stream")
        stdout, stderr = subprocess.PIPE, subprocess.PIPE if image_job else subprocess.STDOUT
        artifact_writer = None
        if image_job and image_job.probe:
            artifact_writer = stdout = image_job.prepare_probe_transport(writers)
            stderr = subprocess.DEVNULL
        lines: list[bytes] = []

        def console() -> None:
            for line in process.stdout:
                lines.append(line)
                if kind != "jit":
                    sys.stdout.buffer.write(line)
                    sys.stdout.buffer.flush()

        def finish_capture() -> None:
            try:
                if artifact_writer is not None:
                    close_transport(artifact_writer.close, on_loss)
            finally:
                if reader is not None and reader.ident is not None:
                    reader.join()

        reader = None if image_job else threading.Thread(target=console)
        if image_job:
            try:
                image_job.prepare_capture()
            except (MemoryError, OSError) as error:
                raise ChildSetupError("cannot prepare guest capture") from error
        setup_complete = False
        try:
            with spawn_owned(args, cancellation=cancellation, pass_fds=descriptors,
                             stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, on_loss=on_loss,
                             on_reaped=image_job.record_reaped if image_job else None,
                             after_reap=finish_capture) as process:
                writers.close()
                if reader is not None:
                    reader.start()
                setup_complete = True
                if image_job:
                    image_job.capture(process, seconds)
                else:
                    wait(process, time.monotonic() + seconds, cancellation)
        except ChildContainmentError:
            raise
        except (MemoryError, OSError) as error:
            if setup_complete:
                raise
            raise ChildSetupError("cannot set up guest") from error
        cancellation.check()
        if image_job:
            if process.returncode:
                raise RuntimeError(f"image guest exited ({process.returncode})")
            return
        # Never relay runner logs: an untrusted job could print the JIT credential.
        expected = b"CERALIVE_BASE_READY" if seed else b"CERALIVE_JOB_DONE=0"
        output = b"".join(lines)
        if process.returncode or expected not in output.splitlines():
            raise RuntimeError(f"guest failed or timed out ({process.returncode})")
        print(expected.decode())


def check_flock_parent(parent_proc: Path) -> None:
    if (read_check_text(parent_proc / "comm").strip() != "flock"
            or not {b"--exclusive", b"--close"}.issubset(read_check(parent_proc / "cmdline").split(b"\0"))):
        raise RuntimeError("run vm.py directly under flock --exclusive --close")


def main(cancellation: Cancellation) -> int:
    try:
        changes = sanitize_startup(cancellation)
    except (OSError, ValueError, KeyError, RuntimeError, StartupError) as error:
        report_error(f"startup baseline failed: {error}")
        return STARTUP_ERROR
    for change in changes:
        report_error(change)

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("build-base", "run", "check", "image"))
    parser.add_argument("--base", required=True, type=Path)
    parser.add_argument("--group-id", type=int)
    parser.add_argument("--check-script", type=Path)
    parser.add_argument("--source-bundle", type=Path,
                        help="check only: read-only public-source tar capsule, never a directory share")
    parser.add_argument("--timeout", type=int, default=21600)
    parser.add_argument("--profile", choices=("kernel", "image"), default="kernel",
                        help="build-base provisioning identity; kernel defaults remain unchanged")
    from image_vm import add_arguments
    add_arguments(parser)
    try:
        args = parser.parse_args()
    except SystemExit as exc:
        if exc.code == 0:  # argparse successfully printed help.
            return 0
        raise
    parent = os.getppid()
    parent_proc = Path("/proc") / str(parent)
    retry_check(check_flock_parent, parent_proc)
    die_with_parent(parent)
    cancellation.check()
    base = args.base.resolve()
    if "," in str(base):
        parser.error("commas are not supported in VM disk paths")
    if args.operation == "image":
        from image_vm import run_image
        return run_image(args, parser, cancellation)
    if args.operation == "build-base":
        if retry_check(listed_entry, Path(base.anchor), str(base.relative_to(base.anchor))) is not None:
            parser.error("base already exists; select a new base path")
        retry_io(base.parent.mkdir, parents=True, exist_ok=True, recover=True)
        if args.profile == "image":
            from image_resources import cgroup_admission, disk_headroom, require_host_lock
            retry_check(require_host_lock)
            retry_check(cgroup_admission)
            retry_check(disk_headroom, ((base.parent, 257 * 1024**3),))
            from image_resources import CAPS
            CAPS.qemu_limit()
        with tempfile.TemporaryDirectory(prefix="base-", dir=base.parent) as directory:
            work = Path(directory)
            image = work / "ubuntu.img"
            run(["curl", "-fSL", "--connect-timeout", "30", "--max-time", "900",
                 IMAGE_URL, "-o", str(image)], cancellation=cancellation,
                 timeout=900)
            with image.open("rb") as downloaded:
                image_digest = hashlib.file_digest(downloaded, "sha256").hexdigest()
            if image_digest != IMAGE_SHA:
                raise RuntimeError("Ubuntu cloud image digest mismatch")
            disk = work / "base.qcow2"
            run(["qemu-img", "convert", "-O", "qcow2", str(image), str(disk)],
                cancellation=cancellation, timeout=300)
            run(["qemu-img", "resize", str(disk), "128G" if args.profile == "image" else "240G"],
                cancellation=cancellation, timeout=180)
            files = []
            for source, destination in (
                ("provision.sh", "/root/provision.sh"),
                ("guest-job.sh", "/usr/local/sbin/ceralive-runner-job"),
                ("keyring.sh", "/usr/local/lib/ceralive-kernel-runner/keyring.sh"),
                ("admit-job.sh", "/usr/local/lib/ceralive-kernel-runner/admit-job.sh"),
                ("armbian-old.asc", "/usr/local/lib/ceralive-kernel-runner/armbian-old.asc"),
                ("armbian-new.asc", "/usr/local/lib/ceralive-kernel-runner/armbian-new.asc"),
            ):
                files.append({"path": destination, "permissions": "0755", "encoding": "b64",
                              "content": base64.b64encode((HERE / source).read_bytes()).decode()})
            if args.profile == "image":
                for source in ("image_guest.py", "image_verify.py", "image_stream.py",
                               "image_capsule.py", "image_urls.py", "image_stages.py"):
                    files.append({"path": "/usr/local/lib/ceralive-kernel-runner/" + source,
                                  "permissions": "0755", "encoding": "b64",
                                  "content": base64.b64encode((HERE / source).read_bytes()).decode()})
            files.append({
                "path": "/etc/systemd/system/ceralive-runner.service", "permissions": "0644",
                "content": "[Unit]\nAfter=network-online.target cloud-final.service docker.service\n"
                           "Wants=network-online.target\nRequires=docker.service\n"
                           "[Service]\nType=oneshot\nStandardOutput=journal+console\n"
                           "StandardError=journal+console\n"
                           "Environment=ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/lib/ceralive-kernel-runner/admit-job.sh\n"
                           "ExecStart=/usr/local/sbin/ceralive-runner-job\n"
                           "[Install]\nWantedBy=multi-user.target\n",
            })
            config = {
                "ssh_pwauth": False, "disable_root": True, "write_files": files,
                "runcmd": [["bash", "/root/provision.sh", RUNNER_VERSION, RUNNER_SHA, args.profile]],
                "power_state": {"mode": "poweroff", "delay": "now", "timeout": 30},
            }
            (work / "user-data").write_text("#cloud-config\n" + yaml.safe_dump(config))
            (work / "meta-data").write_text(
                f"instance-id: {args.profile}-base\nlocal-hostname: {args.profile}-runner\n")
            seed = work / "seed.iso"
            run(["xorriso", "-as", "mkisofs", "-quiet", "-volid", "cidata",
                 "-joliet", "-rock", "-o", str(seed), str(work / "user-data"), str(work / "meta-data")],
                cancellation=cancellation, timeout=180)
            boot(disk, b"", "base", args.timeout, seed, image_base=args.profile == "image",
                 cancellation=cancellation)
            if args.profile == "image" and disk.stat().st_blocks * 512 > 32 * 1024**3:
                raise RuntimeError("image base exceeds the 32 GiB allocated-byte budget")
            disk.chmod(0o444)
            # link is create-only, including against a concurrent base builder.
            cancellation.check()
            os.link(disk, base)
        return 0
    if not stat.S_ISREG(retry_check(base.stat).st_mode):
        parser.error("build and verify the pristine base first")
    if args.operation == "check" and args.check_script is None:
        parser.error("check requires --check-script; no GitHub registration is performed")
    if args.source_bundle and args.operation != "check":
        parser.error("--source-bundle is only for offline checks")
    if args.source_bundle and (
        not stat.S_ISREG(retry_check(args.source_bundle.stat).st_mode)
        or "," in str(retry_check(lambda: args.source_bundle.resolve(strict=True)))
    ):
        parser.error("--source-bundle requires a regular capsule file without commas")
    if args.operation == "run" and (not args.group_id or args.group_id in (1, 5)):
        parser.error("run requires the dedicated kernel-release group ID, never a default")
    # An unlinked disk has no pathname to leak, even when Python cannot run finally.
    with job_disk(base, cancellation=cancellation) as (overlay, disk_fd):
        if args.operation == "run":
            response = run([
                "gh", "api", "--method", "POST",
                "orgs/CERALIVE/actions/runners/generate-jitconfig",
                "-f", f"name=kernel-release-{os.getpid()}", "-F", f"runner_group_id={args.group_id}",
                "-f", "labels[]=self-hosted", "-f", "labels[]=Linux", "-f", "labels[]=X64",
                "-f", "labels[]=ceralive-kernel-vm", "-f", "work_folder=_work",
            ], cancellation=cancellation, capture_output=True, timeout=180, registration=True)
            payload = json.loads(response.stdout)["encoded_jit_config"].encode()
            if not payload or b"\n" in payload:
                raise RuntimeError("invalid JIT response")
            boot(overlay, payload, "jit", args.timeout, disk_fd=disk_fd, cancellation=cancellation)
        else:
            boot(overlay, read_check_script(args.check_script, cancellation), "check", args.timeout,
                 source_bundle=args.source_bundle, disk_fd=disk_fd, cancellation=cancellation)
    print("CERALIVE_OVERLAY_REMOVED")
    cancellation.check()
    return 0


def exit_launcher() -> None:
    """Exit with the committed image status, using readback only for verification."""
    cancellation = Cancellation()
    status = 1
    try:
        status = main(cancellation)
    except SystemExit as exc:
        if type(exc.code) is int and 0 < exc.code <= 255:
            status = exc.code
        if cancellation.exit_receipt is not None or status == 1:
            report_error(exc)
    except BaseException as exc:
        report_error(exc)
    finally:
        try:
            if cancellation.exit_receipt is not None:
                committed = cancellation.exit_status
                status = 1 if committed is None else committed
                retire_journal(cancellation)
                # Keep terminal signal protection in force through direct exit.
                if committed is not None:
                    verify_exit_receipt(cancellation.exit_receipt, committed)
            else:
                for stream in (sys.stdout, sys.stderr):
                    try:
                        stream.flush()
                    except BaseException as exc:
                        report_error(exc)
        finally:
            try:
                os._exit(status)
            finally:
                cancellation.restore_dispositions()


def verify_exit_receipt(path: Path, committed: int) -> None:
    """Check the committed receipt without granting the read authority over exit."""
    try:
        raw = retry_io(path.read_bytes)
        published = json.loads(raw)["launcher_exit"]
        if type(published) is not int or published != committed:
            raise ValueError("image receipt disagrees with committed launcher_exit")
    except Exception as error:
        report_error(error)


if __name__ == "__main__":
    exit_launcher()
