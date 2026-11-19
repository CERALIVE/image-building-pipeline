"""Local image profile admission and independent artifact acceptance.

Recoverable OS/pipe faults and diagnostic exceptions cannot change the
verdict. A required operation that cannot complete fails closed. The exit
transaction can retry a one-shot commit allocation fault and has pre-encoded
unavailable diagnostics. Other main-path MemoryError failures are fatal to
the attempt, with teardown and no successful outcome.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict
import errno
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tarfile
import time

from image_capsule import INPUT_LIMIT, digest_file, verification_capsule
from image_lifecycle import (
    ImageJob, ReceiptError, create_directory, receipt, receipt_temporary, reconcile, report_error, sync_directory,
)
from image_policy import load_policy
from image_resources import CAPS, GIB, AdmissionError, cgroup_admission, disk_admission, disk_headroom, require_host_lock
from image_stream import (
    IO_ATTEMPTS, FileSyncError, Identity, StreamError, decode, list_directory, positioned_open, retry_io, verify_sidecar,
)
from vm_process import Cancelled, Cancellation, run

IMAGE_ERRORS = (ValueError, KeyError, TypeError, RuntimeError, MemoryError, AdmissionError,
                StreamError, subprocess.SubprocessError, tarfile.TarError)

def add_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--input-capsule", type=Path)
    parser.add_argument("--input-sha256")
    parser.add_argument("--base-sha256")
    parser.add_argument("--trust-policy", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--attempt")
    parser.add_argument("--board", choices=("rock-5b-plus", "orange-pi-5-plus"))
    parser.add_argument("--source-commit")
    parser.add_argument("--source-epoch", type=int)
    parser.add_argument("--image-mode", choices=("measure", "probe"), default="measure")


def image_arguments(job: ImageJob) -> list[str]:
    """Only owned disks, one typed read-only input and output-only stdio."""
    return [
        "-nic", "none", "-nodefaults",
        "-drive", f"file=/proc/self/fd/{job.capsule_fd},format=raw,if=none,id=image-input,readonly=on",
        "-device", "virtio-blk-pci,drive=image-input,serial=ceralive-image-input",
        "-device", "virtio-serial-pci",
        "-chardev", "stdio,id=artifacts,signal=off,mux=off",
        "-device", "virtserialport,chardev=artifacts,name=ceralive-artifacts",
    ]

def validate_base(base: Path, expected_sha256: str,
                  cancellation: Cancellation | None = None) -> None:
    """Require the selected immutable base to reference no additional host file."""
    cancellation = cancellation or Cancellation()
    mode = base.lstat().st_mode
    if (not stat.S_ISREG(mode) or mode & 0o222
            or digest_file(base, cancellation.check) != expected_sha256):
        raise AdmissionError("image base must be independently verified and read-only")
    info = run(["qemu-img", "info", "--output=json", str(base.absolute())],
               cancellation=cancellation, capture_output=True, timeout=30)
    row = json.loads(info.stdout)
    specific = row.get("format-specific", {}).get("data", {})
    if (row["format"] != "qcow2" or row["virtual-size"] != 128 * GIB
            or row.get("backing-filename") or specific.get("data-file")
            or specific.get("data-file-raw") or specific.get("corrupt")):
        raise AdmissionError("image profile requires a dedicated unbacked 128 GiB base")

def completed_acceptance(path: Path, *, entries: set[str] | None = None) -> dict | None:
    """Validate the final marker before consuming a pair's acceptance candidate."""
    if entries is not None and "exit.json" not in entries:
        return None
    marker_path = path.parent / "exit.json"
    if entries is not None and not stat.S_ISREG(marker_path.lstat().st_mode):
        raise AdmissionError("private pair marker is not a regular file")
    try:
        marker = json.loads(marker_path.read_text() if entries is not None else
                            retry_io(marker_path.read_text, recover=True))
    except FileNotFoundError:
        if entries is not None:
            raise
        return None
    if (marker["schema"] != 1 or type(marker["launcher_exit"]) is not int
            or marker["launcher_exit"] != 0 or marker.get("pair_complete") is not True):
        return None
    if entries is not None and not stat.S_ISREG(path.lstat().st_mode):
        raise AdmissionError("private pair acceptance is not a regular file")
    raw = path.read_bytes() if entries is not None else retry_io(path.read_bytes, recover=True)
    row = json.loads(raw)
    if (marker["acceptance_sha256"] != hashlib.sha256(raw).hexdigest()
            or marker["identity"] != row["identity"] or row["schema"] != 1
            or row["content_verified"] is not True):
        raise AdmissionError("image pair marker does not match its acceptance receipt")
    return row


def retained_outputs(store: Path, identity: Identity, trust_identity: tuple[str, str]) -> int:
    """Only a verified other board reduces the remaining pair allocation."""
    for attempt in range(IO_ATTEMPTS):
        try:
            return scan_retained_outputs(store, identity, trust_identity)
        except OSError as error:
            if error.errno not in (errno.EINTR, errno.EAGAIN) or attempt + 1 == IO_ATTEMPTS:
                raise AdmissionError(f"cannot complete private output store admission scan: {error}") from error


def scan_retained_outputs(store: Path, identity: Identity, trust_identity: tuple[str, str]) -> int:
    retained = 0
    boards = set()
    for name in list_directory(store):
        attempt = store / name
        mode = attempt.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise AdmissionError("private output store contains a symbolic link")
        if not stat.S_ISDIR(mode):
            continue
        names = set(list_directory(attempt))
        accepted = attempt / "acceptance.json"
        row = completed_acceptance(accepted, entries=names)
        if row is None:
            continue
        previous = Identity(**row["identity"])
        if ((previous.commit, previous.epoch, row["base_sha256"], row["public_root_der_sha256"])
                != (identity.commit, identity.epoch, *trust_identity)):
            raise AdmissionError("private output store belongs to another approved pair")
        if previous.board == identity.board or previous.board in boards:
            raise AdmissionError("private pair already contains this board; select a new reviewed store")
        boards.add(previous.board)
        artifacts = accepted.parent / "build/artifacts"
        for name in list_directory(artifacts):
            file = artifacts / name
            info = file.lstat()
            if not stat.S_ISREG(info.st_mode):
                raise AdmissionError("retained pair contains an unexpected object")
            retained += info.st_blocks * 512
    return retained

def validate_return(job: ImageJob, verifier: bool) -> None:
    target = job.artifacts
    envelope = job.directory / "stream.partial"
    with positioned_open(envelope) as source:
        members = decode(source, target, job.identity, job.cancellation.check)
    expected = {"verification.json"} if verifier else {
        "rootfs.tar", "rootfs.tar.sha256", "rootfs_a.ext4", "rootfs_b.ext4",
        "measurement.json", "packages.lock.json", "fetch.jsonl", "sealed-delivery.json",
        "resolved.json", "kernel-artifact.json", "resolved.config", "built-modules.txt",
        "kernel.SHA256SUMS", "boot.scr", "boot.scr.sha256", "build.log",
        "rootfs_a.reserve", "rootfs_b.reserve", "rootfs_a.header", "rootfs_b.header",
    }
    if {member.id for member in members} != expected:
        raise StreamError("returned artifact set is incomplete")
    if not verifier:
        measurement = json.loads(retry_io((target / "measurement.json").read_text, recover=True))
        stages = measurement["stages"]
        if (measurement["schema"] != 1 or (measurement["purpose"], measurement["build_mode"], measurement["board"],
             measurement["source_commit"], measurement["source_date_epoch"], measurement["input_sha256"])
                != ("rootfs-measurement", "production", job.identity.board, job.identity.commit,
                    job.identity.epoch, job.identity.input_sha256)
                or measurement["public_root_der_sha256"] != job.state["public_root_der_sha256"]
                or measurement["signed_candidate"] is not False
                or not isinstance(stages, dict)
                or set(stages) != {
                    "resolve", "fetch", "kernel-reuse", "rauc-build", "partition", "bsp",
                    "mkosi", "tar", "boot", "size", "firmware-closure", "packages-lock", "parity", "raw-slots"}
                or any(type(code) is not int or code != 0 for code in stages.values())):
            raise StreamError("measurement receipt identity or stage failure")
        for member in members:
            if member.id in measurement["artifacts"] and measurement["artifacts"][member.id] != {
                "sha256": member.sha256, "bytes": member.length,
            }:
                raise StreamError("measurement artifact digest disagrees with host")
        rootfs = next(member for member in members if member.id == "rootfs.tar")
        verify_sidecar(target / "rootfs.tar.sha256", rootfs)
        verify_sidecar(target / "boot.scr.sha256", next(member for member in members if member.id == "boot.scr"))
        job.state["guest_claimed_stage_exits"] = measurement["stages"]
    sync_directory(target)
    receipt(job.validation,
            {"schema": 1, "identity": asdict(job.identity),
             "members": [asdict(member) for member in members],
             "transport_valid": True, "content_verified": verifier},
            temporary=job.validation_temporary)
    retry_io(envelope.unlink, recover=True)

def execute(base: Path, directory: Path, request: dict, cancellation: Cancellation,
            jobs: list[ImageJob]) -> Path:
    """One owned overlay, exit receipt and independent host transport validation."""
    from vm import boot, job_disk
    identity = Identity(**request["payload"]["identity"])
    artifacts = directory / "artifacts"
    try:
        with ImageJob(directory, identity, request["capsule"], cancellation,
                      probe=request["payload"]["operation"] == "probe") as job:
            jobs.append(job)
            job.state.update(base_sha256=request["base_sha256"], base=str(base),
                             public_root_der_sha256=request["payload"]["trust"]["root_der_sha256"],
                             overlay_directory=str(base.parent), retained_bytes=request["retained_bytes"],
                             stream_budget=CAPS.stream_max if request["payload"]["operation"] == "measure" else 4 * 1024**2)
            with job_disk(base, job, cancellation) as (overlay, disk_fd):
                remaining = int(request["deadline"] - time.monotonic())
                if remaining <= 0:
                    raise AdmissionError("image deadline exhausted before guest launch")
                seconds = min(CAPS.verify_seconds if request["payload"]["operation"] == "verify" else CAPS.build_seconds, remaining)
                payload = json.dumps(request["payload"]).encode()
                if len(payload) > 1024 * 1024:
                    raise AdmissionError("image job public metadata exceeds 1 MiB")
                boot(overlay, payload, "image", seconds,
                     disk_fd=disk_fd, image_job=job)
            job.outputs.close()
            cancellation.check()
            disk_headroom(((directory, 16 * GIB),))
            validate_return(job, request["payload"]["operation"] != "measure")
            job.state["stop_reason"] = "guest exited; transport validated"
    except BaseException:
        # This covers constructor failure before ImageJob.__exit__ can run.
        try:
            retry_io(artifacts.rmdir, recover=True)
        except (OSError, MemoryError):
            pass  # Preserve a nonempty directory as diagnostic evidence.
        raise
    return artifacts


def run_image(args: argparse.Namespace, parser: argparse.ArgumentParser,
              cancellation: Cancellation) -> int:
    """Publish one authoritative outcome for the entire image attempt."""
    jobs: list[ImageJob] = []
    error = None
    accepted_sha = None
    retry_commit = args.image_mode == "probe"
    try:
        acceptance = measure_image(args, parser, cancellation, jobs)
        if acceptance is not None:
            receipt(*acceptance)
            accepted_sha = hashlib.sha256(retry_io(acceptance[0].read_bytes, recover=True)).hexdigest()
    except OSError as exc:
        report_error(exc)
        return 1
    except IMAGE_ERRORS as exc:
        error = exc
    while True:
        try:
            if not jobs:
                if error is not None:
                    report_error(error)
                return 1
            if cancellation.exit_status is not None:
                return cancellation.exit_status
            build = jobs[0]
            probe = args.image_mode == "probe"
            path = cancellation.exit_receipt
            assert path is not None
            if cancellation.requested:
                error = Cancelled("runner cancelled")
            status = int(error is not None)
            row = build.state | {"launcher_exit": status} if probe else {
                "schema": 1, "identity": build.state["identity"], "launcher_exit": status,
                "stop_reason": jobs[-1].state["stop_reason"],
            }
            if error is not None:
                row["stop_reason"] = "cancelled" if isinstance(error, Cancelled) else type(error).__name__
            if not probe:
                row["pair_complete"] = not status
                if not status:
                    row["acceptance_sha256"] = accepted_sha
            receipt(path, row, outcome=cancellation, diagnostic=error, probe=build if probe else None,
                    temporary=cancellation.exit_temporary if retry_commit or not probe else None)
            return status
        except Cancelled as exc:
            error = exc
            continue
        except (OSError, MemoryError) as exc:
            if cancellation.exit_status is not None:
                return cancellation.exit_status
            allocation_fault = isinstance(exc, MemoryError) or (
                isinstance(exc, ReceiptError) and isinstance(exc.__cause__, MemoryError))
            # The receipt transaction absorbs step failures after its rename.
            if retry_commit and allocation_fault:
                retry_commit = False
                continue
            if isinstance(build, ImageJob) and isinstance(exc.__cause__, FileSyncError):
                try:
                    receipt(build.teardown, build.state | {"stop_reason": "receipt fsync failed",
                                                           "storage_errno": exc.__cause__.errno},
                            temporary=build.teardown_temporary)
                except (OSError, MemoryError) as teardown_error:
                    report_error(teardown_error)
            report_error(exc)
            return 1


def prepare_exit_receipt(directory: Path, probe: bool, cancellation: Cancellation) -> None:
    """Allocate the final transaction paths before the attempt can spawn a child."""
    cancellation.exit_receipt = (directory / "build" if probe else directory) / "exit.json"
    cancellation.exit_temporary = receipt_temporary(cancellation.exit_receipt)


def measure_image(args: argparse.Namespace, parser: argparse.ArgumentParser,
                  cancellation: Cancellation, jobs: list[ImageJob]) -> tuple[Path, dict] | None:
    if not all((args.input_capsule, args.input_sha256, args.base_sha256,
                args.trust_policy, args.output_dir, args.attempt, args.board,
                args.source_commit, args.source_epoch is not None)):
        parser.error("image requires capsule/base digests, public trust policy, output store and exact source/board/attempt identity")
    if args.source_bundle or args.check_script or args.group_id:
        parser.error("image profile accepts no runner, script or public-source-only override")
    acquired_at = time.time()
    build_deadline = time.monotonic() + CAPS.build_seconds
    require_host_lock()
    cgroup_admission()
    identity = Identity(args.attempt, args.board, args.source_commit, args.source_epoch,
                        args.input_sha256)
    base = args.base.resolve(strict=True)
    input_info = args.input_capsule.lstat()
    if (not stat.S_ISREG(input_info.st_mode)
            or input_info.st_size > INPUT_LIMIT
            or digest_file(args.input_capsule, cancellation.check) != identity.input_sha256):
        raise AdmissionError("input capsule transport identity mismatch")
    store = args.output_dir.absolute()
    try:
        store_info = store.stat()
    except FileNotFoundError:
        # Confirm absence before taking the no-store path, which can spawn
        # qemu-img without checking for a recorded duplicate.
        try:
            store_info = store.stat()
        except FileNotFoundError:
            store_info = None
    if store_info is None:
        validate_base(args.base, args.base_sha256, cancellation)
        create_directory(store, parents=True)
        store_info = store.stat()
        base_checked = True
    else:
        base_checked = False
    cancellation.check()
    if not stat.S_ISDIR(store_info.st_mode) or store_info.st_uid != os.getuid() or store_info.st_mode & 0o077:
        raise AdmissionError("image return store must be owned by the launcher and mode 0700")
    store = store.resolve(strict=True)
    reconcile(store)
    trust = asdict(load_policy(args.trust_policy))
    retained = retained_outputs(store, identity, (args.base_sha256, trust["root_der_sha256"]))
    disk_admission(base.parent, store, retained)
    if not base_checked:
        validate_base(args.base, args.base_sha256, cancellation)
    directory = store / identity.attempt
    create_directory(directory)
    probe = args.image_mode == "probe"
    prepare_exit_receipt(directory, probe, cancellation)
    for name in ("build",) if probe else ("build", "verify"):
        job_directory = directory / name
        create_directory(job_directory)
        create_directory(job_directory / "artifacts")
    probe_result = directory / "build/artifacts/verification.json" if probe else None
    expected_probe = {"schema": 1, "identity": asdict(identity), "network_denied": True} if probe else None
    CAPS.qemu_limit()
    request = {"capsule": args.input_capsule, "base_sha256": args.base_sha256, "deadline": build_deadline,
               "retained_bytes": retained, "payload": {
                   "schema": 1, "identity": asdict(identity), "operation": args.image_mode, "trust": trust}}
    artifacts = execute(base, directory / "build", request, cancellation, jobs)
    cancellation.check()
    if probe_result is not None:
        result = json.loads(retry_io(probe_result.read_text, recover=True))
        if result != expected_probe:
            raise StreamError("offline probe receipt mismatch")
        return None
    capsule = directory / "verifier-input.tar"
    inventory = verification_capsule(args.input_capsule, artifacts, capsule, cancellation.check)
    verification = Identity(identity.attempt, identity.board, identity.commit, identity.epoch,
                            digest_file(capsule, cancellation.check))
    request = {"capsule": capsule, "base_sha256": args.base_sha256,
               "deadline": time.monotonic() + CAPS.verify_seconds,
               "retained_bytes": retained + capsule.stat().st_blocks * 512
                   + sum((artifacts / name).stat().st_blocks * 512 for name in list_directory(artifacts)),
               "payload": {"schema": 1, "identity": asdict(verification), "operation": "verify",
                           "trust": trust, "build_identity": asdict(identity), "artifacts": inventory}}
    verified = execute(base, directory / "verify", request, cancellation, jobs)
    cancellation.check()
    result = json.loads(retry_io((verified / "verification.json").read_text, recover=True))
    if (result["schema"] != 1 or result["verified"] is not True
            or result["build_identity"] != asdict(identity) or result["artifacts"] != inventory
            or {row["slot"] for row in result["slots"]} != {"rootfs_a", "rootfs_b"}):
        raise StreamError("independent verifier disagrees with host-selected identity or inventory")
    retry_io(capsule.unlink, recover=True)
    return directory / "acceptance.json", {
        "schema": 1, "identity": asdict(identity),
        "base_sha256": args.base_sha256, "artifacts": inventory, "content_verified": True,
        "public_root_der_sha256": trust["root_der_sha256"],
        "lock_unit_started_at": acquired_at,
        "verification_input_sha256": verification.input_sha256,
    }
