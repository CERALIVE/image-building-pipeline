"""Local image profile admission and independent artifact acceptance."""

from __future__ import annotations

import argparse
from dataclasses import asdict
from functools import partial
import json
import os
from pathlib import Path
import stat
import subprocess
import time

from image_capsule import INPUT_LIMIT, digest_file, verification_capsule
from image_lifecycle import ImageJob, receipt, reconcile
from image_policy import load_policy
from image_resources import CAPS, GIB, AdmissionError, cgroup_admission, disk_admission, disk_headroom, require_host_lock
from image_stream import Identity, StreamError, decode, verify_sidecar
from vm_process import Cancellation, run

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
    from vm import die_with_parent
    cancellation = cancellation or Cancellation()
    if (base.is_symlink() or not base.is_file() or base.stat().st_mode & 0o222
            or digest_file(base, cancellation.check) != expected_sha256):
        raise AdmissionError("image base must be independently verified and read-only")
    info = run(["qemu-img", "info", "--output=json", str(base)],
               cancellation=cancellation, capture_output=True, timeout=30,
               env={"PATH": os.environ["PATH"], "LANG": "C.UTF-8"},
               preexec_fn=partial(die_with_parent, os.getpid()))
    row = json.loads(info.stdout)
    specific = row.get("format-specific", {}).get("data", {})
    if (row["format"] != "qcow2" or row["virtual-size"] != 128 * GIB
            or row.get("backing-filename") or specific.get("data-file")
            or specific.get("data-file-raw") or specific.get("corrupt")):
        raise AdmissionError("image profile requires a dedicated unbacked 128 GiB base")

def retained_outputs(store: Path, identity: Identity, trust_identity: tuple[str, str]) -> int:
    """Only a verified other board reduces the remaining pair allocation."""
    retained = 0
    boards = set()
    for accepted in store.glob("*/acceptance.json"):
        row = json.loads(accepted.read_text())
        previous = Identity(**row["identity"])
        if (row["schema"] != 1 or row["content_verified"] is not True
                or (previous.commit, previous.epoch, row["base_sha256"], row["public_root_der_sha256"])
                != (identity.commit, identity.epoch, *trust_identity)):
            raise AdmissionError("private output store belongs to another approved pair")
        if previous.board == identity.board or previous.board in boards:
            raise AdmissionError("private pair already contains this board; select a new reviewed store")
        boards.add(previous.board)
        for file in (accepted.parent / "build/artifacts").iterdir():
            if file.is_symlink() or not file.is_file():
                raise AdmissionError("retained pair contains an unexpected object")
            retained += file.stat().st_blocks * 512
    return retained

def validate_return(job: ImageJob, verifier: bool) -> None:
    target = job.directory / "artifacts"
    target.mkdir(mode=0o700)
    envelope = job.directory / "stream.partial"
    with envelope.open("rb") as source:
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
        measurement = json.loads((target / "measurement.json").read_text())
        if (measurement["schema"] != 1 or (measurement["purpose"], measurement["build_mode"], measurement["board"],
             measurement["source_commit"], measurement["source_date_epoch"], measurement["input_sha256"])
                != ("rootfs-measurement", "production", job.identity.board, job.identity.commit,
                    job.identity.epoch, job.identity.input_sha256)
                or measurement["public_root_der_sha256"] != job.state["public_root_der_sha256"]
                or measurement["signed_candidate"] is not False
                or set(measurement["stages"]) != {
                    "resolve", "fetch", "kernel-reuse", "rauc-build", "partition", "bsp",
                    "mkosi", "tar", "boot", "size", "firmware-closure", "packages-lock", "parity", "raw-slots"}
                or any(type(code) is not int or code != 0 for code in measurement["stages"].values())):
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
    directory_fd = os.open(target, os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    receipt(job.directory / "transport-validation.json",
            {"schema": 1, "identity": asdict(job.identity),
             "members": [asdict(member) for member in members],
             "transport_valid": True, "content_verified": verifier})
    envelope.unlink()

def execute(base: Path, directory: Path, request: dict, cancellation: Cancellation) -> Path:
    """One owned overlay, exit receipt and independent host transport validation."""
    from vm import boot, job_disk
    identity = Identity(**request["payload"]["identity"])
    directory.mkdir(mode=0o700)
    store = directory.parents[1]
    with ImageJob(directory, identity, request["capsule"], cancellation) as job:
        job.state.update(base_sha256=request["base_sha256"], base=str(base),
                         public_root_der_sha256=request["payload"]["trust"]["root_der_sha256"],
                         overlay_directory=str(base.parent), retained_bytes=request["retained_bytes"],
                         stream_budget=CAPS.stream_max if request["payload"]["operation"] == "measure" else 4 * 1024**2)
        try:
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
        finally:
            job.state["overlay_descriptor_closed"] = True
        job.outputs.close()
        cancellation.check()
        disk_headroom(((directory, 16 * GIB),))
        validate_return(job, request["payload"]["operation"] != "measure")
        job.state["stop_reason"] = "guest exited; transport validated"
    (store / "active.json").unlink()
    return directory / "artifacts"


def run_image(args: argparse.Namespace, parser: argparse.ArgumentParser,
              cancellation: Cancellation) -> int:
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
    validate_base(args.base, args.base_sha256, cancellation)
    base = args.base.resolve()
    if (args.input_capsule.is_symlink() or not stat.S_ISREG(args.input_capsule.stat().st_mode)
            or args.input_capsule.stat().st_size > INPUT_LIMIT
            or digest_file(args.input_capsule, cancellation.check) != identity.input_sha256):
        raise AdmissionError("input capsule transport identity mismatch")
    store = args.output_dir.resolve()
    store.mkdir(mode=0o700, parents=True, exist_ok=True)
    if store.stat().st_uid != os.getuid() or store.stat().st_mode & 0o077:
        raise AdmissionError("image return store must be owned by the launcher and mode 0700")
    reconcile(store)
    trust = asdict(load_policy(args.trust_policy))
    retained = retained_outputs(store, identity, (args.base_sha256, trust["root_der_sha256"]))
    disk_admission(base.parent, store, retained)
    directory = store / identity.attempt
    directory.mkdir(mode=0o700)
    CAPS.qemu_limit()
    request = {"capsule": args.input_capsule, "base_sha256": args.base_sha256, "deadline": build_deadline,
               "retained_bytes": retained, "payload": {
                   "schema": 1, "identity": asdict(identity), "operation": args.image_mode, "trust": trust}}
    artifacts = execute(base, directory / "build", request, cancellation)
    if args.image_mode == "probe":
        result = json.loads((artifacts / "verification.json").read_text())
        if result != {"schema": 1, "identity": asdict(identity), "network_denied": True}:
            raise StreamError("offline probe receipt mismatch")
        return 0
    capsule = directory / "verifier-input.tar"
    inventory = verification_capsule(args.input_capsule, artifacts, capsule, cancellation.check)
    verification = Identity(identity.attempt, identity.board, identity.commit, identity.epoch,
                            digest_file(capsule, cancellation.check))
    request = {"capsule": capsule, "base_sha256": args.base_sha256,
               "deadline": time.monotonic() + CAPS.verify_seconds,
               "retained_bytes": retained + capsule.stat().st_blocks * 512
                   + sum(file.stat().st_blocks * 512 for file in artifacts.iterdir()),
               "payload": {"schema": 1, "identity": asdict(verification), "operation": "verify",
                           "trust": trust, "build_identity": asdict(identity), "artifacts": inventory}}
    verified = execute(base, directory / "verify", request, cancellation)
    result = json.loads((verified / "verification.json").read_text())
    if (result["schema"] != 1 or result["verified"] is not True
            or result["build_identity"] != asdict(identity) or result["artifacts"] != inventory
            or {row["slot"] for row in result["slots"]} != {"rootfs_a", "rootfs_b"}):
        raise StreamError("independent verifier disagrees with host-selected identity or inventory")
    cancellation.check()
    receipt(directory / "acceptance.json", {"schema": 1, "identity": asdict(identity),
            "base_sha256": args.base_sha256, "artifacts": inventory, "content_verified": True,
            "public_root_der_sha256": trust["root_der_sha256"],
            "lock_unit_started_at": acquired_at,
            "verification_input_sha256": verification.input_sha256})
    capsule.unlink()
    return 0
