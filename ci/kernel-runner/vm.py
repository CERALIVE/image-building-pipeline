#!/usr/bin/env python3
"""Owner-started, single-job KVM runners; never share host directories or tokens."""

from __future__ import annotations

import argparse
import base64
import ctypes
from functools import partial
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading

import yaml

HERE = Path(__file__).resolve().parent
IMAGE_URL = "https://cloud-images.ubuntu.com/noble/20261017/noble-server-cloudimg-amd64.img"
IMAGE_SHA = "04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94"
RUNNER_VERSION = "2.338.2"
RUNNER_SHA = "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40"


def interrupted(_signum: int, _frame: object) -> None:
    raise InterruptedError("runner stopped; destroying job disk")


def die_with_parent(parent: int) -> None:
    """Kernel-enforced cleanup still works when the launcher receives SIGKILL."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGKILL, 0, 0, 0):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if os.getppid() != parent:
        os.kill(os.getpid(), signal.SIGKILL)


def boot(disk: Path, payload: bytes, kind: str, seconds: int,
         seed: Path | None = None, source_bundle: Path | None = None,
         disk_fd: int | None = None) -> None:
    """Pass the one-job credential in an anonymous RAM fd, not argv or a file."""
    fd = os.memfd_create("ceralive-job", 0)
    try:
        os.write(fd, payload)
        os.lseek(fd, 0, os.SEEK_SET)
        args = [
            "qemu-system-x86_64", "-enable-kvm", "-machine", "q35", "-cpu", "host",
            "-smp", "16", "-m", "16384", "-display", "none", "-monitor", "none",
            "-serial", "stdio", "-no-reboot",
            "-drive", f"file={disk},format=qcow2,if=none,id=system",
            "-device", "virtio-blk-pci,drive=system,bootindex=1",
            "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0",
            "-fw_cfg", f"name=opt/ceralive/{kind},file=/proc/self/fd/{fd}",
        ]
        if seed:
            args += ["-drive", f"file={seed},format=raw,media=cdrom,readonly=on"]
        if source_bundle:
            args += ["-drive", f"file={source_bundle.resolve()},format=raw,if=none,id=source,readonly=on",
                     "-device", "virtio-blk-pci,drive=source,serial=ceralive-source"]
        # The gh credential stays in the host's gh process; QEMU gets no host env secrets.
        env = {"PATH": os.environ["PATH"], "LANG": "C.UTF-8"}
        descriptors = (fd,) if disk_fd is None else (fd, disk_fd)
        process = subprocess.Popen(args, pass_fds=descriptors, env=env,
                                   preexec_fn=partial(die_with_parent, os.getpid()),
                                   stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        lines: list[bytes] = []

        def console() -> None:
            for line in process.stdout:
                lines.append(line)
                if kind != "jit":
                    sys.stdout.buffer.write(line)
                    sys.stdout.buffer.flush()

        reader = threading.Thread(target=console)
        reader.start()
        try:
            process.wait(timeout=seconds)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            reader.join()
        # Never relay runner logs: an untrusted job could print the JIT credential.
        expected = b"CERALIVE_BASE_READY" if seed else b"CERALIVE_JOB_DONE=0"
        output = b"".join(lines)
        if process.returncode or expected not in output.splitlines():
            raise RuntimeError(f"guest failed or timed out ({process.returncode})")
        print(expected.decode())
    finally:
        os.close(fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("build-base", "run", "check"))
    parser.add_argument("--base", required=True, type=Path)
    parser.add_argument("--group-id", type=int)
    parser.add_argument("--check-script", type=Path)
    parser.add_argument("--source-bundle", type=Path,
                        help="check only: read-only public-source tar capsule, never a directory share")
    parser.add_argument("--timeout", type=int, default=21600)
    args = parser.parse_args()
    parent = os.getppid()
    parent_proc = Path("/proc") / str(parent)
    if (
        (parent_proc / "comm").read_text().strip() != "flock"
        or not {b"--exclusive", b"--close"}.issubset(
            (parent_proc / "cmdline").read_bytes().split(b"\0"))
    ):
        raise RuntimeError("run vm.py directly under flock --exclusive --close")
    die_with_parent(parent)
    child_setup = partial(die_with_parent, os.getpid())
    base = args.base.resolve()
    if "," in str(base):
        parser.error("commas are not supported in VM disk paths")
    if args.operation == "build-base":
        if base.exists():
            parser.error("base already exists; select a new base path")
        base.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="base-", dir=base.parent) as directory:
            work = Path(directory)
            image = work / "ubuntu.img"
            subprocess.run(["curl", "-fSL", "--connect-timeout", "30", "--max-time", "900",
                            IMAGE_URL, "-o", str(image)], check=True,
                           preexec_fn=child_setup, timeout=900)
            with image.open("rb") as downloaded:
                image_digest = hashlib.file_digest(downloaded, "sha256").hexdigest()
            if image_digest != IMAGE_SHA:
                raise RuntimeError("Ubuntu cloud image digest mismatch")
            disk = work / "base.qcow2"
            subprocess.run(["qemu-img", "convert", "-O", "qcow2", str(image), str(disk)],
                           check=True, preexec_fn=child_setup, timeout=300)
            subprocess.run(["qemu-img", "resize", str(disk), "240G"], check=True,
                           preexec_fn=child_setup, timeout=180)
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
                "runcmd": [["bash", "/root/provision.sh", RUNNER_VERSION, RUNNER_SHA]],
                "power_state": {"mode": "poweroff", "delay": "now", "timeout": 30},
            }
            (work / "user-data").write_text("#cloud-config\n" + yaml.safe_dump(config))
            (work / "meta-data").write_text("instance-id: kernel-base\nlocal-hostname: kernel-runner\n")
            seed = work / "seed.iso"
            subprocess.run(["xorriso", "-as", "mkisofs", "-quiet", "-volid", "cidata",
                            "-joliet", "-rock", "-o", str(seed),
                            str(work / "user-data"), str(work / "meta-data")], check=True,
                           preexec_fn=child_setup, timeout=180)
            boot(disk, b"", "base", args.timeout, seed)
            disk.chmod(0o444)
            # link is create-only, including against a concurrent base builder.
            os.link(disk, base)
        return 0
    if not base.is_file():
        parser.error("build and verify the pristine base first")
    if args.operation == "check" and args.check_script is None:
        parser.error("check requires --check-script; no GitHub registration is performed")
    if args.source_bundle and args.operation != "check":
        parser.error("--source-bundle is only for offline checks")
    if args.source_bundle and (
        not args.source_bundle.is_file() or "," in str(args.source_bundle.resolve())
    ):
        parser.error("--source-bundle requires a regular capsule file without commas")
    if args.operation == "run" and (not args.group_id or args.group_id in (1, 5)):
        parser.error("run requires the dedicated kernel-release group ID, never a default")
    # An unlinked disk has no pathname to leak, even when Python cannot run finally.
    with tempfile.TemporaryFile(prefix="job-", dir=base.parent) as overlay_file:
        disk_fd = overlay_file.fileno()
        overlay = Path(f"/proc/self/fd/{disk_fd}")
        subprocess.run(["qemu-img", "create", "-f", "qcow2", "-F", "qcow2",
                        "-b", str(base), str(overlay)], check=True,
                       pass_fds=(disk_fd,), preexec_fn=child_setup, timeout=180)
        if args.operation == "run":
            response = subprocess.run([
                "gh", "api", "--method", "POST",
                "orgs/CERALIVE/actions/runners/generate-jitconfig",
                "-f", f"name=kernel-release-{os.getpid()}", "-F", f"runner_group_id={args.group_id}",
                "-f", "labels[]=self-hosted", "-f", "labels[]=Linux", "-f", "labels[]=X64",
                "-f", "labels[]=ceralive-kernel-vm", "-f", "work_folder=_work",
            ], check=True, capture_output=True, timeout=180, preexec_fn=child_setup)
            payload = json.loads(response.stdout)["encoded_jit_config"].encode()
            if not payload or b"\n" in payload:
                raise RuntimeError("invalid JIT response")
            boot(overlay, payload, "jit", args.timeout, disk_fd=disk_fd)
        else:
            boot(overlay, args.check_script.read_bytes(), "check", args.timeout,
                 source_bundle=args.source_bundle, disk_fd=disk_fd)
    print("CERALIVE_OVERLAY_REMOVED")
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"kernel runner: {exc}", file=sys.stderr)
        sys.exit(1)
