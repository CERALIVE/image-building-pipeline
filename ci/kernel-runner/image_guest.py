#!/usr/bin/env python3
"""Trusted base entrypoint for an unregistered offline image job."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import selectors
import signal
import tarfile
from tempfile import TemporaryFile
import time
from typing import Literal

from image_capsule import Capsule, digest_file, object_id, unpack
from image_candidate_policy import FIELD
from image_stream import (
    BUILD_LOG_LIMIT, IO_ATTEMPTS, RETRYABLE_IO, Identity, StreamError, encode, list_directory, listed_entry,
    retry_check, retry_io, unique_object, write_all,
)
from vm_process import child_pipes, poll_owned, reset_child_status, run as run_gate, spawn_gate, wait

HOME = Path("/opt/ceralive-image-job")
MIRROR_READY_SECONDS = 600
MIRROR_STOP_SECONDS = 20
MIRROR_RETRY = RETRYABLE_IO | {errno.EINTR}
UNREACHABLE = frozenset((errno.ENETUNREACH, errno.EHOSTUNREACH))
KERNEL_METADATA = ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS")
BuilderFailureCode = Literal["builder_engine_inspect_error", "builder_engine_export_error",
                             "builder_config_unavailable", "builder_platform_mismatch",
                             "builder_config_digest_mismatch"]


class BuilderImageError(StreamError):
    """Carry only an allowlisted failure code and digests into the failure frame."""

    def __init__(self, code: BuilderFailureCode, expected: str, observed: str | None = None) -> None:
        super().__init__(code)
        self.diagnostics = {"failure_code": code, "expected_config_digest": expected,
                            "observed_config_digest": observed}


def command(args: list[str], env: dict[str, str]) -> str:
    return run_gate(args, env=env, stdout=subprocess.PIPE,
                    text=True, timeout=180).stdout.strip()


def check_route(env: dict[str, str]) -> None:
    rows = json.loads(command(["ip", "-j", "route", "show", "default"], env))
    if type(rows) is not list:
        raise StreamError("offline guest route inventory is invalid")
    if rows:
        raise StreamError("offline guest has a default route")


def check_tcp(address: str, deadline: float) -> None:
    timeout = deadline - time.monotonic()
    if timeout <= 0:
        raise StreamError("offline guest TCP check exhausted its deadline")
    with socket.socket() as probe:
        probe.setblocking(False)
        try:
            probe.connect((address, 443))
        except OSError as error:
            result = error.errno
            if result == errno.EINPROGRESS:
                with selectors.DefaultSelector() as ready:
                    ready.register(probe, selectors.EVENT_WRITE)
                    if not ready.select(max(0, deadline - time.monotonic())):
                        raise StreamError("offline guest TCP check exhausted its deadline")
                result = probe.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
        else:
            result = 0
    if result == 0:
        raise StreamError("offline guest can reach an external endpoint")
    if result not in UNREACHABLE:
        raise OSError(result, "offline guest TCP check is inconclusive")


def mirror_io(events: selectors.BaseSelector, deadline: float, operation, *args):
    """Retry a zero-progress control operation only after fresh readiness."""
    for attempt in range(IO_ATTEMPTS):
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not events.select(remaining):
                raise StreamError("sealed mirror control operation timed out")
            return operation(*args)
        except OSError as error:
            if error.errno not in MIRROR_RETRY or attempt + 1 == IO_ATTEMPTS:
                raise


def mirror_marker(events: selectors.BaseSelector, fd: int, marker: bytes, deadline: float) -> None:
    received = bytearray()
    while len(received) < len(marker):
        data = mirror_io(events, deadline, os.read, fd, len(marker) - len(received))
        received.extend(data)
        if not data or not marker.startswith(received):
            raise StreamError("sealed mirror control marker is incomplete or invalid")


@contextmanager
def ready_mirror(mirror: subprocess.Popen):
    """Only a positive response on the owned pipe authorizes acceptance."""
    try:
        output = mirror.stdout.fileno()
        os.set_blocking(output, False)
        with selectors.DefaultSelector() as response:
            response.register(output, selectors.EVENT_READ)
            mirror_marker(response, output, b"CERALIVE_SEALED_MIRROR_READY\n",
                          time.monotonic() + MIRROR_READY_SECONDS)
            if retry_io(poll_owned, mirror, recover=True) is not None:
                raise StreamError("sealed guest mirror exited during readiness")
            yield
            deadline = time.monotonic() + MIRROR_STOP_SECONDS
            if mirror.stdin is None or retry_io(poll_owned, mirror, recover=True) is not None:
                raise StreamError("sealed guest mirror exited before shutdown request")
            control = mirror.stdin.fileno()
            os.set_blocking(control, False)
            with selectors.DefaultSelector() as request:
                request.register(control, selectors.EVENT_WRITE)
                try:
                    written = mirror_io(request, deadline, os.write, control, b"S")
                except BrokenPipeError as error:
                    raise StreamError("sealed guest mirror closed its control pipe before shutdown") from error
                if written != 1:
                    raise StreamError("sealed mirror shutdown request was not written")
            mirror_marker(response, output, b"CERALIVE_SEALED_MIRROR_STOPPED\n", deadline)
            code = retry_io(wait, mirror, deadline, recover=True)
            if code != 0 or mirror_io(response, deadline, os.read, output, 1):
                raise StreamError("sealed guest mirror did not shut down cleanly")
    finally:
        if retry_io(poll_owned, mirror, recover=True) is None:
            try:
                retry_io(os.kill, mirror.pid, signal.SIGTERM, recover=True)
                retry_io(wait, mirror, time.monotonic() + MIRROR_STOP_SECONDS, recover=True)
            except ProcessLookupError:
                retry_io(wait, mirror, time.monotonic() + MIRROR_STOP_SECONDS, recover=True)
            except subprocess.TimeoutExpired:
                try:
                    retry_io(os.kill, mirror.pid, signal.SIGKILL, recover=True)
                except ProcessLookupError:
                    pass
                retry_io(wait, mirror, time.monotonic() + MIRROR_STOP_SECONDS, recover=True)


def source_checkout(capsule: Capsule, directory: Path, env: dict[str, str]) -> Path:
    source = HOME / "source"
    command(["git", "-c", "core.hooksPath=/dev/null", "clone", "--no-checkout",
             str(directory / capsule.source_bundle), str(source)], env)
    command(["git", "-C", str(source), "checkout", "--detach", capsule.source_commit], env)
    if (command(["git", "-C", str(source), "rev-parse", "HEAD"], env) != capsule.source_commit
            or command(["git", "-C", str(source), "rev-parse", "--is-shallow-repository"], env) != "false"
            or command(["git", "-C", str(source), "show", "-s", "--format=%ct", "HEAD"], env) != str(capsule.epoch)):
        raise StreamError("public source bundle identity, history or epoch mismatch")
    files = command(["git", "-C", str(source), "ls-tree", "-r", "--name-only", "HEAD"], env)
    forbidden = {".env", ".dev-keys", ".omo", "cert-work"}
    if any(forbidden.intersection(Path(name).parts) for name in files.splitlines()):
        raise StreamError("source capsule includes an excluded path")
    return source


def resolve(source: Path, board: str, env: dict[str, str]) -> dict[str, str]:
    params = command(["bash", str(source / "lib/resolve.sh"), board, "--kernel-apt"], env)
    result = {}
    for line in params.splitlines():
        key, value = line.split("=", 1)
        parsed = shlex.split(value)
        if len(parsed) > 1:
            raise StreamError("invalid resolved parameter")
        result[key] = parsed[0] if parsed else ""
    return result


def kernel_identity(params: dict[str, str]) -> tuple[str, str, str]:
    return params["KERNEL_PACKAGES"], params["KERNEL_SOURCE_PACKAGE_VERSION"], params["ARCH"]


def stage_kernel_metadata(source: Path, capsule: Capsule, params: dict[str, str],
                          approved: dict[str, str], destination: Path) -> str:
    """Stage only independently approved release metadata for the manifest kernel."""
    sys.path.insert(0, str(source / "lib"))
    from kernel_release import KernelReleaseError, verified_metadata

    package, version, arch = kernel_identity(params)
    destination.mkdir(parents=True)
    for name in KERNEL_METADATA:
        digest = object_id(approved[name])
        path = destination / name
        shutil.copyfile(capsule.directory / digest, path)
        if digest_file(path) != digest:
            raise StreamError("released kernel metadata differs from approved digest")
    try:
        released = verified_metadata(version, destination)
    except KernelReleaseError as error:
        raise StreamError("released kernel metadata failed validation against the manifest") from error
    if (released.identity.package != package or arch != "arm64" or capsule.board not in released.boards):
        raise StreamError("approved released kernel does not match manifest package, architecture or board")
    return released.identity.deb_sha256


def check_builder_config(tag: str, arch: str, expected: str, env: dict[str, str]) -> None:
    """Hash the engine-exported config bytes, not an inspect ID or reserialized JSON."""
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", expected):
        raise StreamError("invalid approved builder config digest")
    try:
        inspected, = json.loads(command(["docker", "image", "inspect", "--", tag], env),
                                object_pairs_hook=unique_object)
        platform = inspected["Os"], inspected["Architecture"]
        if not all(isinstance(part, str) and part for part in platform):
            raise ValueError
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, StreamError):
        raise BuilderImageError("builder_engine_inspect_error", expected) from None
    if platform != ("linux", arch):
        raise BuilderImageError("builder_platform_mismatch", expected)

    observed = None
    with TemporaryFile(dir=HOME) as exported:
        try:
            run_gate(["docker", "image", "save", "--platform", f"linux/{arch}", "--", tag],
                     env=env, timeout=180, stdout=exported, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError):
            raise BuilderImageError("builder_engine_export_error", expected) from None
        exported.seek(0)
        try:
            with tarfile.open(fileobj=exported, mode="r:") as archive:
                members = archive.getmembers()

                def metadata(name: str) -> bytes:
                    member, = (item for item in members if item.name == name)
                    if not member.isfile() or not 0 < member.size <= 1024**2:
                        raise ValueError
                    contents = archive.extractfile(member)
                    if contents is None:
                        raise ValueError
                    with contents:
                        return contents.read()

                entry, = json.loads(metadata("manifest.json"), object_pairs_hook=unique_object)
                config_name = entry["Config"]
                if not re.fullmatch(r"blobs/sha256/[0-9a-f]{64}", config_name):
                    raise ValueError
                raw = metadata(config_name)
                observed = "sha256:" + hashlib.sha256(raw).hexdigest()
                config = json.loads(raw, object_pairs_hook=unique_object)
                platform = config["os"], config["architecture"]
                if not all(isinstance(part, str) and part for part in platform):
                    raise ValueError
        except (OSError, tarfile.TarError, ValueError, KeyError, TypeError, StreamError):
            raise BuilderImageError("builder_config_unavailable", expected, observed) from None
    if platform != ("linux", arch):
        raise BuilderImageError("builder_platform_mismatch", expected, observed)
    if observed != expected:
        raise BuilderImageError("builder_config_digest_mismatch", expected, observed)


def measure(source: Path, capsule: Capsule, job: dict) -> list[tuple[str, Path]]:
    directory = capsule.directory
    env = {"PATH": os.environ["PATH"], "HOME": str(HOME), "LANG": "C.UTF-8",
           "CERALIVE_BUILD_MODE": "production", "CERALIVE_BUILD_PURPOSE": "full",
           "CERALIVE_SEALED_INPUTS": str(directory),
           "CERALIVE_SEALED_INPUT_SHA256": job["identity"]["input_sha256"],
           "RAUC_KEYRING_FILE": str(directory / capsule.device_root),
           "CERALIVE_MEASUREMENT_ROOT_SHA256": job["trust"]["root_der_sha256"],
           "CERALIVE_APT_PROXY": "http://127.0.0.1:3142",
           "CERALIVE_IMAGE_BUILD_COMMIT": capsule.source_commit,
           "SOURCE_DATE_EPOCH": str(capsule.epoch), "DOCKER_CONTEXT": "default",
           "FETCH_JOBS": "4", "MAKEFLAGS": "-j4"}
    trust = job["trust"]
    env["CHANNEL"] = trust["repositories"]["firstparty"]["suite"]
    env["ARMBIAN_SUITE"] = trust["repositories"]["bsp"]["suite"]
    env["ARMBIAN_APT_URL"] = trust["repositories"]["bsp"]["origin"]
    if trust["os_version"]:
        env["CERALIVE_OS_RELEASE_VERSION"] = trust["os_version"]
    for field, variable in (("addon_public_object", "ADDON_KEYRING_B64"),
                            ("paseto_public_object", "PASETO_PUBLIC_KEY_B64")):
        if trust[field]:
            env[variable] = __import__("base64").b64encode((directory / trust[field]).read_bytes()).decode()
    env["APT_GPG_PUBLIC_B64"] = __import__("base64").b64encode(
        (directory / trust["repositories"]["firstparty"]["keyring"]).read_bytes()).decode()
    env["ARMBIAN_APT_KEYRING"] = str(directory / trust["repositories"]["bsp"]["keyring"])
    shutil.copyfile(directory / trust["repositories"]["debian-source"]["keyring"],
                    "/usr/share/keyrings/debian-archive-keyring.gpg")
    params = resolve(source, capsule.board, env)
    if FIELD not in trust:
        history = HOME / "kernel-history" / params["KERNEL_SOURCE_PACKAGE_VERSION"]
        stage_kernel_metadata(source, capsule, params, trust["kernel_metadata"], history)
        env["CERALIVE_KERNEL_HISTORY_DIR"] = str(history.parent)
    mediamtx = command(["bash", "-euo", "pipefail", "-c",
        'source "$1"; printf "%s" "$MEDIAMTX_SHA256_arm64"', "_",
        str(source / "mkosi/runtime/rtmp-gateway/mediamtx.recipe.conf")], env)
    if not any(row.sha256 == mediamtx and row.kind == "pinned-source" for row in capsule.objects):
        raise StreamError("sealed input capsule lacks the pinned MediaMTX source")
    media_inputs = source / "mkosi/.image-inputs"
    media_inputs.mkdir(mode=0o700)
    os.link(directory / mediamtx, media_inputs / mediamtx)
    env["CERALIVE_SEALED_MEDIAMTX_SHA256"] = mediamtx
    for builder in trust["builder_images"]:
        archive = directory / builder["object"]
        if not any(row.sha256 == builder["object"] and row.kind == "builder-image" for row in capsule.objects):
            raise StreamError("missing reviewed builder archive")
        run_gate(["docker", "load", "-i", str(archive)], env=env, timeout=600,
                 stdout=subprocess.DEVNULL)
        check_builder_config(builder["tag"], builder["arch"], builder["image_id"], env)
    swap = HOME / "swap"
    run_gate(["fallocate", "-l", "4G", str(swap)], env=env, timeout=60)
    swap.chmod(0o600)
    run_gate(["mkswap", str(swap)], env=env, timeout=60, stdout=subprocess.DEVNULL)
    run_gate(["swapon", str(swap)], env=env, timeout=60)
    run_gate(["bash", str(source / "ci/check-builder-resources.sh")], env=env, cwd=source, timeout=60)
    log = HOME / "build.log"
    with log.open("xb") as output:
        with child_pipes(spawn_gate(["python3", str(Path(__file__).with_name("sealed-inputs.py")), "serve-managed"],
                              env=env | {"CERALIVE_BUILD_PURPOSE": "rootfs-measurement"},
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=output)) as mirror:
            with ready_mirror(mirror):
                args = ["bash", str(source / "build"), capsule.board, "--rootfs-measurement"]
                with child_pipes(spawn_gate(args, env=env, cwd=source, stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, start_new_session=True)) as build:
                    try:
                        deadline = time.monotonic() + 21000
                        written = 0
                        with selectors.DefaultSelector() as log_events:
                            log_events.register(build.stdout, selectors.EVENT_READ)
                            while log_events.get_map():
                                if time.monotonic() >= deadline:
                                    raise subprocess.TimeoutExpired(args, 21000)
                                for event, _mask in log_events.select(timeout=1):
                                    chunk = os.read(event.fileobj.fileno(), 1024 * 1024)
                                    if not chunk:
                                        log_events.unregister(event.fileobj)
                                        continue
                                    written += len(chunk)
                                    if written > BUILD_LOG_LIMIT:
                                        raise StreamError("guest build log exceeded its 1 GiB budget")
                                    write_all(output, chunk)
                        code = wait(build, time.monotonic() + 20)
                        if code:
                            raise subprocess.CalledProcessError(code, args)
                    finally:
                        if poll_owned(build) is None:
                            os.killpg(build.pid, signal.SIGTERM)
                            try:
                                wait(build, time.monotonic() + 20)
                            except subprocess.TimeoutExpired:
                                os.killpg(build.pid, signal.SIGKILL)
                                wait(build, None)
    if retry_check(listed_entry, directory, "missing-object") is not None:
        raise StreamError("guest requested an object absent from the sealed inventory")
    out = source / "images" / capsule.board
    receipts = [out / name for name in retry_check(list_directory, out) if name.endswith(".measurement.json")]
    if len(receipts) != 1:
        raise StreamError("build did not emit exactly one measurement receipt")
    prefix = receipts[0].name.removesuffix(".measurement.json")
    slots = out / "measurement-slots"
    staging = source / "mkosi/.staging" / capsule.board
    resolved = HOME / "resolved.json"
    resolved.write_text(json.dumps(params, sort_keys=True) + "\n")
    records = [
        ("rootfs.tar", out / f"{prefix}.rootfs.tar"),
        ("rootfs.tar.sha256", out / f"{prefix}.rootfs.tar.sha256"),
        ("measurement.json", receipts[0]),
        ("packages.lock.json", out / f"{prefix}.packages.lock.json"),
        ("fetch.jsonl", staging / "packages-lock/fetch.jsonl"),
        ("sealed-delivery.json", staging / "sealed-delivery.json"),
        ("resolved.json", resolved), ("build.log", log),
    ]
    for name in ("rootfs_a.ext4", "rootfs_b.ext4", "rootfs_a.reserve", "rootfs_b.reserve",
                 "rootfs_a.header", "rootfs_b.header", "boot.scr", "boot.scr.sha256"):
        records.append((name, slots / name))
    for name in KERNEL_METADATA:
        records.append(("kernel.SHA256SUMS" if name == "SHA256SUMS" else name,
                        staging / "kernel-build" / name))
    return records


def main() -> None:
    reset_child_status()
    raw = Path("/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive/image/raw")
    with raw.open("rb") as payload:
        data = payload.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise StreamError("oversized image job")
    job = json.loads(data)
    if job["schema"] != 1 or set(job) - {"schema", "identity", "operation", "trust", "artifacts", "build_identity"}:
        raise StreamError("invalid image job contract")
    identity = Identity(**job["identity"])
    approved_candidate = job["trust"].get(FIELD)
    if FIELD in job["trust"] and (
            approved_candidate is None or "kernel_metadata" in job["trust"] or job["operation"] not in ("measure", "verify")):
        raise StreamError("candidate requires an explicit measurement or verification job")
    HOME.mkdir(mode=0o700)
    env = {"PATH": os.environ["PATH"], "HOME": str(HOME), "LANG": "C.UTF-8"}
    capsule_path = Path("/dev/disk/by-id/virtio-ceralive-image-input")
    capsule = unpack(capsule_path, HOME / "input", identity, approved_candidate=approved_candidate)
    directory = HOME / "input"
    trust_path = directory / "trust.json"
    trust_path.write_text(json.dumps(job["trust"]) + "\n")
    trust_path.chmod(0o400)
    source = source_checkout(capsule, directory, env)
    failure = None
    try:
        match job["operation"]:
            case "measure":
                records = measure(source, capsule, job)
            case "verify":
                from image_verify import verify
                records = verify(source, capsule, job)
            case "probe":
                check_route(env)
                for address in ("10.0.2.2", "169.254.169.254", "192.168.0.1", "1.1.1.1"):
                    retry_check(lambda: check_tcp(address, time.monotonic() + 1))
                report = HOME / "verification.json"
                report.write_text(json.dumps({"schema": 1, "identity": asdict(identity),
                                             "network_denied": True}) + "\n")
                records = [("verification.json", report)]
            case _:
                raise StreamError("unknown image job operation")
    except (OSError, ValueError, KeyError, StreamError, subprocess.SubprocessError) as error:
        failure = error
        report = HOME / "failure.json"
        payload = {"schema": 1, "identity": asdict(identity), "failure": type(error).__name__,
                   "exit": getattr(error, "returncode", None)}
        if isinstance(error, BuilderImageError):
            payload.update(failure="StreamError", **error.diagnostics)
        report.write_text(json.dumps(payload) + "\n")
        records = [("failure.json", report)]
        log = HOME / "build.log"
        if log.is_file():
            records.append(("build.log", log))
    with Path("/dev/virtio-ports/ceralive-artifacts").open("wb", buffering=0) as output:
        encode(output, records, identity)
    if failure is not None:
        raise failure


if __name__ == "__main__":
    main()
