"""Local image profile admission and independent artifact acceptance.

The output store, job directories, capsule and journal are private to the invoking user and
written only by the launcher and its children. A same-user process that replaces files between
a check and their use is outside this model, so later paths resolve through admitted descriptors.
"""

from __future__ import annotations

import argparse
from contextlib import ExitStack
from dataclasses import asdict
from functools import partial
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tarfile
from tempfile import TemporaryDirectory
import time

from image_capsule import INPUT_LIMIT, digest_file, verification_capsule
from image_lifecycle import ImageJob, create_directory, receipt, reconcile, report_error, sync_directory, unlink_observed
from image_policy import load_policy
from image_resources import CAPS, GIB, AdmissionError, cgroup_admission, disk_admission, disk_headroom, require_host_lock
from image_stream import (
    BUILD_LOG_LIMIT, HEADER_LIMIT, MAGIC, MANIFEST_LIMIT, Identity, StreamError, checked_open, decode, exact_json,
    list_directory, listed_entry, read_header, retry_check, unique_object, verify_sidecar,
)
from image_verify import approved_nouveau, candidate_consumers, check_nouveau_evidence, firmware_path
from vm_process import Cancelled, Cancellation, run

IMAGE_ERRORS = (ValueError, KeyError, TypeError, RuntimeError, AdmissionError,
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
    """Only owned disks, one typed read-only input and an output-only artifact channel."""
    return [
        "-nic", "none",
        "-drive", f"file=/proc/self/fd/{job.capsule_fd},format=raw,if=none,id=image-input,readonly=on",
        "-device", "virtio-blk-pci,drive=image-input,serial=ceralive-image-input",
        "-device", "virtio-serial-pci",
        "-chardev", "file,id=artifacts,path=/proc/self/fd/1",
        "-device", "virtserialport,chardev=artifacts,name=ceralive-artifacts",
    ]

def validate_base(base: Path, expected_sha256: str,
                  cancellation: Cancellation | None = None) -> int:
    """Require the selected immutable base to reference no additional host file."""
    from vm import die_with_parent
    cancellation = cancellation or Cancellation()
    fd = checked_digest(base, expected_sha256, cancellation, base=True)
    try:
        info = run(["qemu-img", "info", "--output=json", f"/proc/self/fd/{fd}"],
                   cancellation=cancellation, capture_output=True, timeout=30,
                   pass_fds=(fd,), preexec_fn=partial(die_with_parent, os.getpid()))
        row = json.loads(info.stdout)
        specific = row.get("format-specific", {}).get("data", {})
        if (row["format"] != "qcow2" or row["virtual-size"] != 128 * GIB
                or row.get("backing-filename") or specific.get("data-file")
                or specific.get("data-file-raw") or specific.get("corrupt")):
            raise AdmissionError("image profile requires a dedicated unbacked 128 GiB base")
    except BaseException:
        os.close(fd)
        raise
    return fd


def checked_digest(path: Path, expected_sha256: str, cancellation: Cancellation, *, base=False) -> int:
    fd = checked_open(path, immutable=base, limit=None if base else INPUT_LIMIT)
    try:
        with os.fdopen(os.dup(fd), "rb") as source:
            digest = hashlib.sha256()
            while chunk := source.read(1024 * 1024):
                cancellation.check()
                digest.update(chunk)
        if digest.hexdigest() != expected_sha256:
            raise AdmissionError("image input digest disagrees with selected identity")
        os.lseek(fd, 0, os.SEEK_SET)
    except BaseException:
        os.close(fd)
        raise
    return fd

def completed_acceptance(path: Path, *, entries: set[str] | None = None) -> dict | None:
    """Validate the final marker before consuming a pair's acceptance candidate."""
    if entries is None:
        entries = set(retry_check(list_directory, path.parent))
    if "exit.json" not in entries:
        return None
    store = path.parent.parent
    if listed_entry(store, path.parent.name + ".reconciled.json") is not None:
        return None
    active = store / "active.json"
    active_info = listed_entry(store, active.name)
    if active_info is not None:
        if not stat.S_ISREG(active_info.st_mode):
            raise AdmissionError("active journal is not a regular file")
        if returned_json(active, private=True)["attempt"] == path.parent.name:
            return None
    marker_path = path.parent / "exit.json"
    marker = returned_json(marker_path, private=True)
    if (marker["schema"] != 1 or type(marker["launcher_exit"]) is not int
            or marker["launcher_exit"] != 0 or marker.get("pair_complete") is not True):
        return None
    raw = read_return_record(path, private=True)
    row = json.loads(raw)
    if (marker["acceptance_sha256"] != hashlib.sha256(raw).hexdigest()
            or marker["identity"] != row["identity"] or row["schema"] != 1
            or row["content_verified"] is not True):
        raise AdmissionError("image pair marker does not match its acceptance receipt")
    return row


def retained_outputs(store: Path, identity: Identity, trust_identity: tuple[str, str]) -> int:
    """Only a verified other board reduces the remaining pair allocation."""
    try:
        return retry_check(scan_retained_outputs, store, identity, trust_identity)
    except OSError as error:
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


def admit_output_store(store: Path, identity: Identity, base: Path, base_sha256: str,
                       trust_policy: Path) -> tuple[dict, int]:
    """Recompute the store and capacity observation together on every attempt."""
    trust = asdict(load_policy(trust_policy))
    retained = scan_retained_outputs(store, identity, (base_sha256, trust["root_der_sha256"]))
    disk_admission(store, store, retained)
    return trust, retained

def returned_json(path: Path, *, private: bool = False):
    return json.loads(read_return_record(path, private=private), object_pairs_hook=unique_object)


def read_return_record(path: Path, *, private: bool) -> bytes:
    limit = 1024 * 1024
    def read() -> bytes:
        with os.fdopen(checked_open(path, private=private, limit=limit), "rb") as source:
            data = source.read(limit + 1)
        if len(data) > limit:
            raise StreamError("image receipt exceeds its metadata limit")
        return data

    return retry_check(read)


def measurement_stages(row, identity: Identity, public_root: str, members) -> dict:
    stages = dict.fromkeys(("resolve", "fetch", "kernel-reuse", "rauc-build", "partition", "bsp",
                           "mkosi", "tar", "boot", "size", "firmware-closure", "packages-lock",
                           "parity", "raw-slots"), 0)
    artifacts = {
        member.id: {"sha256": member.sha256, "bytes": member.length} for member in members
        if member.id in {"rootfs.tar", "packages.lock.json", "rootfs_a.ext4", "rootfs_b.ext4", "rootfs_a.reserve",
                         "rootfs_b.reserve", "rootfs_a.header", "rootfs_b.header", "boot.scr", "boot.scr.sha256"}
    }
    if type(row) is not dict:
        raise StreamError("invalid measurement receipt")
    kernel = row.get("kernel_version")
    metadata = row.get("metadata_validity")
    if type(kernel) is not str or not kernel or type(metadata) is not dict:
        raise StreamError("invalid measurement metadata")
    repositories = metadata.get("repositories")
    if (type(repositories) is not list or not repositories
            or not exact_json(metadata, {"schema": 1, "purpose": "rootfs-measurement", "repositories": repositories})):
        raise StreamError("invalid measurement repository metadata")
    for repository in repositories:
        if (type(repository) is not dict
                or repository.keys() != {"repository", "release_date", "release_sha256", "freshness_checked", "freshness"}
                or any(type(repository[key]) is not str
                       for key in ("repository", "release_date", "release_sha256", "freshness"))
                or type(repository["freshness_checked"]) is not bool
                or repository["freshness"] != ("checked" if repository["freshness_checked"] else "NOT checked")):
            raise StreamError("invalid measurement repository record")
    expected = {
        "schema": 1, "purpose": "rootfs-measurement", "build_mode": "production", "board": identity.board,
        "source_commit": identity.commit, "source_date_epoch": identity.epoch, "input_sha256": identity.input_sha256,
        "public_root_der_sha256": public_root, "kernel_version": kernel, "stages": stages,
        "slot_only_additions": ["usr/lib/ceralive/boot/boot.scr", "usr/lib/ceralive/boot/boot.scr.sha256"],
        "metadata_validity": metadata, "artifacts": artifacts, "signed_candidate": False,
    }
    if not exact_json(row, expected):
        raise StreamError("measurement receipt identity, stage or artifact mismatch")
    return stages


def validate_verification(row, identity: Identity, inventory: dict, nouveau_present: bool) -> None:
    if type(row) is not dict:
        raise StreamError("invalid verifier receipt")
    slots = row.get("slots")
    if (type(slots) is not list or len(slots) != 2
            or not exact_json(row, {"schema": 1, "verified": True, "build_identity": asdict(identity),
                                    "artifacts": inventory, "slots": slots})):
        raise StreamError("independent verifier disagrees with host-selected identity or inventory")
    labels = set()
    for slot in slots:
        if (type(slot) is not dict or slot.keys() != {"slot", "reserve", "removed", "retained",
                                                     "firmware_references", "examined_firmware_references",
                                                     "candidate_consumers", "nouveau_present"}
                or type(slot["slot"]) is not str or slot["slot"] not in ("rootfs_a", "rootfs_b")
                or type(slot["reserve"]) is not str or not slot["reserve"]
                or any(type(slot[key]) is not list or any(type(item) is not str for item in slot[key])
                       for key in ("removed", "retained", "firmware_references"))
                or not slot["removed"] or not slot["retained"]
                or type(slot["examined_firmware_references"]) is not int
                or slot["examined_firmware_references"] < max(1, len(slot["firmware_references"]))
                or type(slot["nouveau_present"]) is not bool
                or type(slot["candidate_consumers"]) is not dict):
            raise StreamError("invalid verifier slot record")
        if slot["nouveau_present"] != nouveau_present:
            raise StreamError("reported Nouveau presence differs from the approved module inventory")
        references = slot["firmware_references"]
        consumers = slot["candidate_consumers"]
        removed = set(slot["removed"])
        retained = set(slot["retained"])
        if (not removed <= consumers.keys() or not consumers.keys() <= removed | retained
                or any(type(name) is not str or not firmware_path(name) for name in consumers)
                or len(references) != len(set(references))
                or not exact_json(consumers, candidate_consumers(list(consumers), references))):
            raise StreamError("invalid candidate firmware consumers")
        check_nouveau_evidence(nouveau_present, references)
        labels.add(slot["slot"])
    if labels != {"rootfs_a", "rootfs_b"}:
        raise StreamError("missing or duplicate verifier slot")


def failure_record(path: Path, identity: Identity) -> dict:
    data = read_return_record(path, private=True)
    try:
        row = json.loads(data, object_pairs_hook=unique_object)
    except (Cancelled, TimeoutError, subprocess.TimeoutExpired, InterruptedError):
        raise
    except Exception:
        # The parser's diagnostics may include receipt data.
        raise StreamError("returned artifact set is incomplete") from None
    if type(row) is not dict:
        raise StreamError("invalid guest failure diagnostics")
    kind, status = row.get("failure"), row.get("exit")
    if kind == "CalledProcessError":
        # A normally exited Linux child reports a nonzero 8-bit status, not a signal.
        if type(status) is not int or not 1 <= status <= 255:
            raise StreamError("invalid guest failure diagnostics")
    elif status is not None or kind not in (
            "StreamError", "TimeoutExpired", "OSError", "BlockingIOError", "BrokenPipeError",
            "ChildProcessError", "ConnectionAbortedError", "ConnectionRefusedError", "ConnectionResetError",
            "FileExistsError", "FileNotFoundError", "InterruptedError", "IsADirectoryError",
            "NotADirectoryError", "PermissionError", "ProcessLookupError", "TimeoutError",
            "ValueError", "JSONDecodeError", "UnicodeDecodeError", "UnicodeEncodeError", "KeyError"):
        raise StreamError("invalid guest failure diagnostics")
    base = {"schema": 1, "identity": asdict(identity), "failure": kind, "exit": status}
    if exact_json(row, base):
        return base
    fields = {"failure_code", "expected_config_digest", "observed_config_digest"}
    if (kind not in ("StreamError", "CalledProcessError") or set(row) != set(base) | fields
            or not exact_json({key: row[key] for key in base}, base)):
        raise StreamError("invalid guest failure diagnostics")
    code, expected, observed = (row[key] for key in
                                ("failure_code", "expected_config_digest", "observed_config_digest"))
    digest = r"sha256:[0-9a-f]{64}"
    if (type(code) is not str or code not in (
            "builder_engine_inspect_error", "builder_engine_export_error", "builder_config_unavailable",
            "builder_platform_mismatch", "builder_config_digest_mismatch")
            or type(expected) is not str or not re.fullmatch(digest, expected)
            or (observed is not None and (type(observed) is not str or not re.fullmatch(digest, observed)))):
        raise StreamError("invalid guest failure diagnostics")
    return base | {"failure_code": code, "expected_config_digest": expected,
                   "observed_config_digest": observed}


def validate_return(job: ImageJob, verifier: bool, guest_exit: RuntimeError | None = None) -> None:
    target = job.directory / "artifacts"
    envelope = job.directory / "stream.partial"
    expected = {"verification.json"} if verifier else {
        "rootfs.tar", "rootfs.tar.sha256", "rootfs_a.ext4", "rootfs_b.ext4",
        "measurement.json", "packages.lock.json", "fetch.jsonl", "sealed-delivery.json",
        "resolved.json", "kernel-artifact.json", "resolved.config", "built-modules.txt",
        "kernel.SHA256SUMS", "boot.scr", "boot.scr.sha256", "build.log",
        "rootfs_a.reserve", "rootfs_b.reserve", "rootfs_a.header", "rootfs_b.header",
    }
    failure = None
    # Never publish a decoded failure record before the terminal frame and its schema are checked.
    with TemporaryDirectory(dir=job.directory, prefix=".return-") as staged:
        staging = Path(staged)
        try:
            with envelope.open("rb") as source:
                if guest_exit is not None:
                    # A failure can contain only its receipt, a build log, and the terminal manifest.
                    limit = len(MAGIC) + 3 * HEADER_LIMIT + MANIFEST_LIMIT + 1024**2 + BUILD_LOG_LIMIT
                    if os.fstat(source.fileno()).st_size > limit:
                        raise StreamError("oversized guest failure frame")
                    if source.read(len(MAGIC)) != MAGIC or read_header(source).id != "failure.json":
                        raise StreamError("no guest failure frame")
                    source.seek(0)
                    disk_headroom(((job.directory, 16 * GIB),))
                members = decode(source, staging, job.identity, job.cancellation.check)
            ids = {member.id for member in members}
            if ids in ({"failure.json"}, {"failure.json", "build.log"}):
                failure = failure_record(staging / "failure.json", job.identity)
            elif guest_exit is not None or ids != expected:
                raise StreamError("returned artifact set is incomplete")
        except (TimeoutError, InterruptedError):
            raise
        except (AdmissionError, OSError, ValueError, TypeError, StreamError):
            if guest_exit is not None:
                raise RuntimeError(str(guest_exit)) from None
            raise
        if failure is None:
            staging.rename(target)
            sync_directory(job.directory)
    if failure is not None:
        create_directory(target)
        receipt(target / "failure.json", failure)
        code = failure.get("failure_code")
        if failure["failure"] == "CalledProcessError":
            raise StreamError(f"guest build command failed (exit {failure['exit']})")
        if failure["failure"] == "TimeoutExpired":
            raise StreamError("guest command timed out")
        raise StreamError(f"guest builder check failed: {code}" if code else "guest reported a failure")
    if not verifier:
        stages = measurement_stages(returned_json(target / "measurement.json"), job.identity,
                                    job.state["public_root_der_sha256"], members)
        rootfs = next(member for member in members if member.id == "rootfs.tar")
        verify_sidecar(target / "rootfs.tar.sha256", rootfs)
        verify_sidecar(target / "boot.scr.sha256", next(member for member in members if member.id == "boot.scr"))
        job.state["guest_claimed_stage_exits"] = stages
    sync_directory(target)
    receipt(job.directory / "transport-validation.json",
            {"schema": 1, "identity": asdict(job.identity),
             "members": [asdict(member) for member in members],
             "transport_valid": True, "content_verified": verifier})
    envelope.unlink()

def execute(base: Path, directory: Path, request: dict, cancellation: Cancellation,
            jobs: list[ImageJob]) -> Path:
    """One owned overlay, exit receipt and independent host transport validation."""
    from vm import ImageGuestExit, boot, job_disk
    identity = Identity(**request["payload"]["identity"])
    create_directory(directory)
    with ImageJob(directory, identity, request["capsule"], cancellation,
                  capsule_fd=request.get("capsule_fd"), base_fd=request.get("base_fd"),
                  probe=request["payload"]["operation"] == "probe") as job:
        jobs.append(job)
        job.state.update(base_sha256=request["base_sha256"], base=str(base),
                         public_root_der_sha256=request["payload"]["trust"]["root_der_sha256"],
                         overlay_directory=str(directory), retained_bytes=request["retained_bytes"],
                         stream_budget=CAPS.stream_max if request["payload"]["operation"] == "measure" else 4 * 1024**2)
        with job_disk(base, job, cancellation) as (overlay, disk_fd):
            remaining = int(request["deadline"] - time.monotonic())
            if remaining <= 0:
                raise AdmissionError("image deadline exhausted before guest launch")
            seconds = min(CAPS.verify_seconds if request["payload"]["operation"] == "verify" else CAPS.build_seconds, remaining)
            payload = json.dumps(request["payload"]).encode()
            if len(payload) > 1024 * 1024:
                raise AdmissionError("image job public metadata exceeds 1 MiB")
            guest_exit = None
            try:
                boot(overlay, payload, "image", seconds,
                     disk_fd=disk_fd, image_job=job)
            except ImageGuestExit as error:
                guest_exit = error
        job.outputs.close()
        cancellation.check()
        verifier = request["payload"]["operation"] != "measure"
        if guest_exit is not None:
            validate_return(job, verifier, guest_exit)
            raise RuntimeError(str(guest_exit))
        disk_headroom(((directory, 16 * GIB),))
        validate_return(job, verifier)
        job.state["stop_reason"] = "guest exited; transport validated"
    return directory / "artifacts"


def run_image(args: argparse.Namespace, parser: argparse.ArgumentParser,
              cancellation: Cancellation) -> int:
    """Publish one authoritative outcome for the entire image attempt."""
    jobs: list[ImageJob] = []
    error = None
    accepted_sha = None
    try:
        acceptance = measure_image(args, parser, cancellation, jobs)
        if acceptance is not None:
            receipt(*acceptance)
            accepted_sha = digest_file(acceptance[0])
    except OSError as exc:
        report_error(exc)
        return 1
    except IMAGE_ERRORS as exc:
        error = exc
    if not jobs:
        if error is not None:
            report_error(error)
        return 1

    build = jobs[0]
    probe = args.image_mode == "probe"
    path = (build.directory if probe else build.directory.parent) / "exit.json"
    cancellation.exit_receipt = path
    while True:
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
        try:
            # The successful rename latches the verdict before journal retirement.
            receipt(path, row, outcome=cancellation, diagnostic=error)
        except Cancelled as exc:
            error = exc
            continue
        except OSError as exc:
            report_error(exc)
            return 1
        return cancellation.committed_exit if cancellation.committed_exit is not None else 1


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
    retry_check(require_host_lock)
    cgroup_admission()
    identity = Identity(args.attempt, args.board, args.source_commit, args.source_epoch,
                        args.input_sha256)
    with ExitStack() as inputs:
        capsule_fd = checked_digest(args.input_capsule, identity.input_sha256, cancellation)
        inputs.callback(os.close, capsule_fd)
        return measure_admitted(args, identity, cancellation, jobs, acquired_at, build_deadline, capsule_fd, inputs)


def measure_admitted(args, identity, cancellation, jobs, acquired_at, build_deadline, capsule_fd, inputs):
    base = args.base.absolute()
    store = args.output_dir.absolute()
    base_fd = None
    try:
        store_fd = checked_open(store, directory=True, private=True)
    except FileNotFoundError:
        if listed_entry(Path(store.anchor), str(store.relative_to(store.anchor))) is not None:
            raise AdmissionError("cannot establish private output store ownership")
        load_policy(args.trust_policy)  # Refuse an unusable policy before running the backing tool.
        base_fd = validate_base(base, args.base_sha256, cancellation)
        if base_fd is not None:
            inputs.callback(os.close, base_fd)
        create_directory(store, parents=True)
        store_fd = checked_open(store, directory=True, private=True)
    # Every later path resolves through the admitted inode, so it stays open until the direct exit.
    store = Path(f"/proc/self/fd/{store_fd}")
    cancellation.check()
    reconcile(store)
    try:
        trust, retained = retry_check(admit_output_store, store, identity, base, args.base_sha256, args.trust_policy)
    except OSError as error:
        raise AdmissionError(f"cannot complete private output store admission scan: {error}") from error
    if base_fd is None:
        base_fd = validate_base(base, args.base_sha256, cancellation)
        if base_fd is not None:
            inputs.callback(os.close, base_fd)
    info = retry_check(os.fstat, store_fd)
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise AdmissionError("image return store must be owned by the launcher and mode 0700")
    directory = store / identity.attempt
    create_directory(directory)
    CAPS.qemu_limit()
    request = {"capsule": args.input_capsule, "capsule_fd": capsule_fd, "base_fd": base_fd,
               "base_sha256": args.base_sha256, "deadline": build_deadline,
               "retained_bytes": retained, "payload": {
                   "schema": 1, "identity": asdict(identity), "operation": args.image_mode, "trust": trust}}
    artifacts = execute(base, directory / "build", request, cancellation, jobs)
    cancellation.check()
    if args.image_mode == "probe":
        result = returned_json(artifacts / "verification.json")
        if (type(result) is not dict or result.get("network_denied") is not True
                or not exact_json(result, {"schema": 1, "identity": asdict(identity), "network_denied": True})):
            raise StreamError("offline probe receipt mismatch")
        return None
    nouveau_present = approved_nouveau(read_return_record(artifacts / "built-modules.txt", private=True),
                                       trust["kernel_metadata"]["built-modules.txt"])
    capsule = directory / "verifier-input.tar"
    verifier_fd = os.open(capsule, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    inputs.callback(os.close, verifier_fd)
    # The verifier receives this written inode; the name is used only for its removal.
    with os.fdopen(os.dup(capsule_fd), "rb") as original, os.fdopen(os.dup(verifier_fd), "r+b") as output:
        inventory = verification_capsule(original, artifacts, output, cancellation.check)
        output.seek(0)
        verification_digest = hashlib.file_digest(output, "sha256").hexdigest()
    verifier_info = os.fstat(verifier_fd)
    verification = Identity(identity.attempt, identity.board, identity.commit, identity.epoch,
                            verification_digest)
    request = {"capsule": capsule, "capsule_fd": verifier_fd, "base_fd": base_fd, "base_sha256": args.base_sha256,
               "deadline": time.monotonic() + CAPS.verify_seconds,
               "retained_bytes": retained + os.fstat(verifier_fd).st_blocks * 512
                   + sum(file.stat().st_blocks * 512 for file in artifacts.iterdir()),
               "payload": {"schema": 1, "identity": asdict(verification), "operation": "verify",
                           "trust": trust, "build_identity": asdict(identity), "artifacts": inventory}}
    verified = execute(base, directory / "verify", request, cancellation, jobs)
    cancellation.check()
    validate_verification(returned_json(verified / "verification.json"), identity, inventory, nouveau_present)
    unlink_observed(capsule, verifier_info)
    return directory / "acceptance.json", {
        "schema": 1, "identity": asdict(identity),
        "base_sha256": args.base_sha256, "artifacts": inventory, "content_verified": True,
        "public_root_der_sha256": trust["root_der_sha256"],
        "lock_unit_started_at": acquired_at,
        "verification_input_sha256": verification.input_sha256,
    }
