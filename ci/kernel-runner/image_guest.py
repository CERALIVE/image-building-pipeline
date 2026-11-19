#!/usr/bin/env python3
"""Trusted base entrypoint for an unregistered offline image job."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict
import errno
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import selectors
import signal
import time

from image_capsule import Capsule, unpack
from image_stages import StageLog, stage_marker
from image_stream import (
    BUILD_LOG_LIMIT, ExclusiveFile, Identity, StreamError, encode, list_directory, listed_entry,
    positioned_open, read_input, retry_check, retry_io,
)
from vm_process import poll_owned, wait

HOME = Path("/opt/ceralive-image-job")
UNREACHABLE = frozenset((errno.ENETUNREACH, errno.EHOSTUNREACH))


def command(args: list[str], env: dict[str, str]) -> str:
    return subprocess.run(args, check=True, env=env, stdout=subprocess.PIPE,
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


@contextmanager
def ready_mirror(mirror: subprocess.Popen):
    """Require readiness and an owned shutdown, including legacy default TERM."""
    sent_term = False
    ready_seen = False
    try:
        with selectors.DefaultSelector() as ready:
            ready.register(mirror.stdout, selectors.EVENT_READ)
            if not ready.select(timeout=600) or mirror.stdout.readline() != b"CERALIVE_SEALED_MIRROR_READY\n":
                raise StreamError("sealed guest mirror did not become ready")
        if retry_io(poll_owned, mirror, recover=True) is not None:
            raise StreamError("sealed guest mirror exited during readiness")
        ready_seen = True
        yield
    finally:
        try:
            if retry_io(poll_owned, mirror, recover=True) is None:
                try:
                    retry_io(os.kill, mirror.pid, signal.SIGTERM, recover=True)
                    sent_term = True
                except ProcessLookupError:
                    pass
            retry_io(wait, mirror, time.monotonic() + 20, recover=True)
        except (OSError, subprocess.TimeoutExpired):
            if retry_io(poll_owned, mirror, recover=True) is None:
                try:
                    retry_io(os.kill, mirror.pid, signal.SIGKILL, recover=True)
                except ProcessLookupError:
                    pass
                retry_io(wait, mirror, time.monotonic() + 20, recover=True)
            raise
        if ready_seen and (not sent_term or mirror.returncode not in (0, -signal.SIGTERM)):
            raise StreamError("sealed guest mirror did not remain ready through the build")


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
            env[variable] = __import__("base64").b64encode(read_input(directory / trust[field])).decode()
    env["APT_GPG_PUBLIC_B64"] = __import__("base64").b64encode(
        read_input(directory / trust["repositories"]["firstparty"]["keyring"])).decode()
    env["ARMBIAN_APT_KEYRING"] = str(directory / trust["repositories"]["bsp"]["keyring"])
    shutil.copyfile(directory / trust["repositories"]["debian-source"]["keyring"],
                    "/usr/share/keyrings/debian-archive-keyring.gpg")
    history = HOME / "kernel-history/7.2.0-ceralive8"
    history.mkdir(parents=True)
    for name in ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS"):
        digest = trust["kernel_metadata"][name]
        shutil.copyfile(directory / digest, history / name)
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
        subprocess.run(["docker", "load", "-i", str(archive)], check=True, env=env, timeout=600,
                       stdout=subprocess.DEVNULL)
        inspected = json.loads(command(["docker", "image", "inspect", builder["tag"]], env))[0]
        if (inspected["Id"], inspected["Architecture"]) != (builder["image_id"], builder["arch"]):
            raise StreamError("loaded builder image differs from approved closure")
    params = resolve(source, capsule.board, env)
    swap = HOME / "swap"
    subprocess.run(["fallocate", "-l", "4G", str(swap)], check=True, env=env, timeout=60)
    swap.chmod(0o600)
    subprocess.run(["mkswap", str(swap)], check=True, env=env, timeout=60, stdout=subprocess.DEVNULL)
    subprocess.run(["swapon", str(swap)], check=True, env=env, timeout=60)
    subprocess.run(["bash", str(source / "ci/check-builder-resources.sh")],
                   check=True, env=env, cwd=source, timeout=60)
    log = HOME / "build.log"
    with ExclusiveFile(log, 0o666) as output:
        output.open()
        with subprocess.Popen(["python3", str(source / "lib/sealed-inputs.py"), "serve"],
                              env=env | {"CERALIVE_BUILD_PURPOSE": "rootfs-measurement"},
                              stdout=subprocess.PIPE, stderr=output) as mirror:
            with ready_mirror(mirror):
                args = ["bash", str(source / "build"), capsule.board, "--rootfs-measurement"]
                with subprocess.Popen(args, env=env, cwd=source, stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, start_new_session=True) as build:
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
                                    output.write(chunk)
                        code = build.wait(timeout=20)
                        if code:
                            raise subprocess.CalledProcessError(code, args)
                    finally:
                        if build.poll() is None:
                            os.killpg(build.pid, signal.SIGTERM)
                            try:
                                build.wait(timeout=20)
                            except subprocess.TimeoutExpired:
                                os.killpg(build.pid, signal.SIGKILL)
                                build.wait()
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
    for name in ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS"):
        records.append(("kernel.SHA256SUMS" if name == "SHA256SUMS" else name,
                        staging / "kernel-build" / name))
    return records


def main() -> int:
    raw = Path("/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive/image/raw")
    with positioned_open(raw) as payload:
        data = payload.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise StreamError("oversized image job")
    job = json.loads(data)
    if job["schema"] != 1 or set(job) - {"schema", "identity", "operation", "trust", "artifacts", "build_identity"}:
        raise StreamError("invalid image job contract")
    identity = Identity(**job["identity"])
    stages = stage_marker(StageLog) if job["operation"] == "probe" else None
    if stages:
        stages("probe_start")
    HOME.mkdir(mode=0o700)
    env = {"PATH": os.environ["PATH"], "HOME": str(HOME), "LANG": "C.UTF-8"}
    capsule_path = Path("/dev/disk/by-id/virtio-ceralive-image-input")
    if stages:
        stages("capsule_import_begin")
    capsule = unpack(capsule_path, HOME / "input", identity)
    if stages:
        stages("capsule_import_end", len(capsule.objects))
    directory = HOME / "input"
    (directory / "trust.json").write_text(json.dumps(job["trust"]) + "\n")
    if stages:
        stages("source_checkout_begin")
    source = source_checkout(capsule, directory, env)
    if stages:
        stages("source_checkout_end")
    failure = None
    try:
        match job["operation"]:
            case "measure":
                records = measure(source, capsule, job)
            case "verify":
                from image_verify import verify
                records = verify(source, capsule, job)
            case "probe":
                assert stages is not None
                denied = False
                stages("route_check_begin")
                try:
                    retry_check(check_route, env)
                    denied = True
                finally:
                    stages("route_check_end", int(denied))
                for index, address in enumerate(("10.0.2.2", "169.254.169.254", "192.168.0.1", "1.1.1.1"), 1):
                    denied = False
                    stages(f"tcp_check_{index}_begin")
                    try:
                        try:
                            retry_check(check_tcp, address, time.monotonic() + 1)
                        except OSError as error:
                            raise StreamError("offline guest TCP check is inconclusive") from error
                        denied = True
                    finally:
                        stages(f"tcp_check_{index}_end", int(denied))
                report = HOME / "verification.json"
                report.write_text(json.dumps({"schema": 1, "identity": asdict(identity),
                                             "network_denied": True}) + "\n")
                records = [("verification.json", report)]
            case _:
                raise StreamError("unknown image job operation")
    except (OSError, ValueError, KeyError, StreamError, subprocess.SubprocessError) as error:
        failure = error
        report = HOME / "failure.json"
        report.write_text(json.dumps({"schema": 1, "identity": asdict(identity),
                                     "failure": type(error).__name__,
                                     "exit": getattr(error, "returncode", None)}) + "\n")
        records = [("failure.json", report)]
        log = HOME / "build.log"
        if log.is_file():
            records.append(("build.log", log))
    if stages:
        stages("verdict_computed", int(failure is None))
        stages("stream_open_begin")
    with Path("/dev/virtio-ports/ceralive-artifacts").open("wb", buffering=0) as output:
        if stages:
            stages("stream_open_end")
        try:
            encode(output, records, identity, stages)
        finally:
            if stages:
                stages("stream_close_begin")
    if stages:
        stages("stream_close_end")
    # The frame already describes the failure. Exiting must not print a traceback.
    return int(failure is not None)


if __name__ == "__main__":
    raise SystemExit(main())
