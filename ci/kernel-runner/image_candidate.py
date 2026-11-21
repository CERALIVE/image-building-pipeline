"""Host-only validation of a private kernel producer bundle before sealing."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tarfile

from image_capsule import INPUT_LIMIT
from image_candidate_deb import check_deb_archive
from image_stream import StreamError, unique_object
from vm_process import run as run_gate

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "lib"))
from kernel_release import KernelIdentity, KernelReleaseError, VERSION, verified_metadata

FIELD = "measurement_candidate"
KIND = "measurement-candidate"
METADATA = ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS")
PROOF = ("candidate.json", "publish-authorization.inputs.json", "BUNDLE.SHA256SUMS")
BOARDS = ("orange-pi-5-plus", "rock-5b-plus")
SHA = re.compile(r"[0-9a-f]{64}")
LABELS = dict(zip((*METADATA, *PROOF), ("artifact metadata", "resolved config", "module list",
                                        "payload checksums", "producer receipt", "producer authorization inputs",
                                        "producer checksum envelope"), strict=True))


@dataclass(frozen=True)
class Candidate:
    binding: dict
    bundle: Path
    deb: str

    def rows(self) -> list[dict]:
        return [pin | {"kind": KIND, "urls": []} for pin in self.binding["payloads"].values()]


def select_candidate(policy: dict, reviewed: dict, parent: Path) -> Candidate | None:
    if FIELD not in policy and FIELD not in reviewed:
        return None
    if FIELD not in policy:
        raise StreamError("measurement-candidate policy approval missing")
    selected = policy[FIELD]
    if (type(selected) is not dict or set(selected) != {
            "package", "version", "arch", "validated_boards", "input_fingerprint", "producer_commit",
            "candidate_run_id", "payloads", "proof"}
            or any(type(selected[key]) is not str for key in (
                "package", "version", "arch", "input_fingerprint", "producer_commit", "candidate_run_id"))):
        raise StreamError("invalid measurement-candidate policy fields or types")
    package, version, arch = (selected[key] for key in ("package", "version", "arch"))
    boards = selected["validated_boards"]
    if (not VERSION.fullmatch(version) or package != f"linux-image-{version.split('-ceralive')[0]}-ceralive-rk3588"
            or arch != "arm64" or type(boards) is not list or not all(type(board) is str for board in boards)
            or sorted(boards) != list(BOARDS) or not SHA.fullmatch(selected["input_fingerprint"])
            or not re.fullmatch(r"[0-9a-f]{40}", selected["producer_commit"])
            or not re.fullmatch(r"[1-9][0-9]*", selected["candidate_run_id"])):
        raise StreamError("invalid measurement-candidate policy identity")
    deb = f"{package}_{version}_{arch}.deb"
    digests = set()
    for key, names in (("payloads", {deb, *METADATA}), ("proof", set(PROOF))):
        pins = selected[key]
        if type(pins) is not dict or pins.keys() != names:
            raise StreamError("invalid measurement-candidate policy file closure")
        for name, pin in pins.items():
            if (type(pin) is not dict or pin.keys() != {"sha256", "length"}
                    or type(pin["sha256"]) is not str or not SHA.fullmatch(pin["sha256"])
                    or type(pin["length"]) is not int
                    or not 0 < pin["length"] <= (INPUT_LIMIT if name == deb else 16 * 1024**2)
                    or pin["sha256"] in digests):
                raise StreamError("invalid measurement-candidate policy file pin")
            digests.add(pin["sha256"])
    choice = reviewed.get(FIELD)
    if (type(choice) is not dict or choice.keys() != {"bundle"} or type(choice["bundle"]) is not str
            or not choice["bundle"] or ".." in Path(choice["bundle"]).parts):
        raise StreamError("invalid measurement-candidate inventory selection")
    return Candidate(selected, parent / choice["bundle"], deb)


def snapshot(directory: int, name: str, target: Path, pin: dict, role: str) -> None:
    size = "unavailable"
    observed = "unavailable"
    expected = pin["sha256"]
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if stat.S_ISREG(info.st_mode):
                size = str(info.st_size)
                if info.st_size == pin["length"]:
                    digest = hashlib.sha256()
                    remaining = info.st_size
                    with target.open("xb") as output:
                        while remaining and (chunk := source.read(min(1024 * 1024, remaining))):
                            remaining -= len(chunk)
                            digest.update(chunk)
                            output.write(chunk)
                    if not remaining and not source.read(1):
                        observed = digest.hexdigest()
                        if observed == expected:
                            return
    except OSError:
        pass
    raise StreamError(f"{KIND} object mismatch: {role}; size (bytes) pinned={pin['length']} observed={size}; "
                      f"SHA-256 (first 16) pinned={expected[:16]} observed={observed[:16]}")


def check_envelope(file: Path, pins: dict) -> None:
    observed = {}
    for line in file.read_text().splitlines():
        row = re.fullmatch(r"([0-9a-f]{64})  ([a-zA-Z0-9_.+-]+)", line)
        if not row or row[2] in observed:
            raise StreamError("invalid measurement-candidate checksum envelope")
        observed[row[2]] = row[1]
    if observed.keys() != pins.keys():
        raise StreamError("invalid measurement-candidate checksum envelope coverage")
    for name, expected in pins.items():
        if observed[name] != expected:
            raise StreamError(f"{KIND} checksum envelope mismatch: {LABELS.get(name, 'kernel deb')}; "
                              f"SHA-256 (first 16) pinned={expected[:16]} observed={observed[name][:16]}")


def read_record(path: Path, fields: set[str], role: str) -> dict:
    try:
        row = json.loads(path.read_text(), object_pairs_hook=unique_object)
    except (ValueError, StreamError):
        raise StreamError(f"invalid {KIND} {role} record") from None
    if type(row) is not dict or row.keys() != fields:
        raise StreamError(f"invalid {KIND} {role} record")
    return row


def check_producer(work: Path, selected: dict, deb_digest: str) -> None:
    receipt = read_record(work / PROOF[0], {"schema", "family", "commit", "candidate_run_id",
                                           "kernel_floor", "publication"}, "producer receipt")
    auth = read_record(work / PROOF[1], {"mode", "publish_run_id", "run_attempt", "candidate_run_id", "tag", "commit",
                                        "package", "version", "deb_sha256", "channel", "bench_report_sha256"},
                       "producer authorization inputs")
    if (type(receipt["schema"]) is not int or receipt["schema"] != 1 or receipt["family"] != "rk3588"
            or receipt["publication"] != "blocked-pending-owner" or type(receipt["kernel_floor"]) is not str
            or (receipt["kernel_floor"] != "none" and not VERSION.fullmatch(receipt["kernel_floor"]))
            or auth["mode"] != "apt-publish" or auth["publish_run_id"] is not None or auth["run_attempt"] is not None
            or auth["channel"] not in ("stable", "beta") or auth["bench_report_sha256"] is not None):
        raise StreamError("invalid measurement-candidate producer receipt state")
    for field, expected, values in (
        ("commit", selected["producer_commit"], (receipt["commit"], auth["commit"])),
        ("run", selected["candidate_run_id"], (receipt["candidate_run_id"], auth["candidate_run_id"])),
        ("package", selected["package"], (auth["package"],)),
        ("version", selected["version"], (auth["version"],)),
        ("tag", f"kernel/v{selected['version']}", (auth["tag"],)),
        ("deb digest", deb_digest, (auth["deb_sha256"],)),
    ):
        if any(value != expected for value in values):
            raise StreamError(f"{KIND} producer {field} differs from approved policy")


def check_identity(work: Path, candidate: Candidate, env: dict[str, str]) -> None:
    selected = candidate.binding
    metadata = work / METADATA[0]
    pins = selected["payloads"]
    deb_digest = pins[candidate.deb]["sha256"]
    # Use the existing checksum and metadata parser on private snapshots.
    json.loads(metadata.read_text(), object_pairs_hook=unique_object)
    try:
        record = verified_metadata(selected["version"], work)
    except (KernelReleaseError, KeyError, TypeError, ValueError):
        raise StreamError("invalid measurement-candidate payload checksum or metadata") from None
    if record.identity != KernelIdentity(selected["package"], selected["version"], deb_digest):
        raise StreamError("measurement-candidate metadata package identity differs from policy")
    if sorted(record.boards) != sorted(selected["validated_boards"]):
        raise StreamError("measurement-candidate both-board validation differs from policy")
    fp = selected["input_fingerprint"]
    if record.fingerprint != fp:
        raise StreamError(f"{KIND} artifact fingerprint mismatch; "
                          f"SHA-256 (first 16) pinned={fp[:16]} observed={record.fingerprint[:16]}")
    def run(*args: str, extra_env: dict[str, str] | None = None,
            failure: str = "measurement-candidate package or family fingerprint check failed") -> str:
        try:
            return run_gate(list(args), cwd=ROOT, env=env if extra_env is None else env | extra_env,
                            stdin=subprocess.DEVNULL, capture_output=True, check=True, text=True,
                            timeout=180).stdout.strip()
        except (OSError, ValueError, subprocess.SubprocessError):
            raise StreamError(failure) from None

    commit_error = f"{KIND} producer commit is not a local commit"
    if run("git", "-c", "protocol.allow=never", "cat-file", "-t", selected["producer_commit"],
           extra_env={"GIT_MASTER": "1", "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"},
           failure=commit_error) != "commit":
        raise StreamError(commit_error)
    expected = (selected["package"], selected["version"], selected["arch"])
    fields = ("Package", "Version", "Architecture")
    actual = run("dpkg-deb", "-f", str(work / candidate.deb), *fields).splitlines()
    if actual != [f"{field}: {value}" for field, value in zip(fields, expected, strict=True)]:
        raise StreamError("measurement-candidate deb control identity differs from policy")
    boards = run("bash", "-euo", "pipefail", "-c",
                 'PIPELINE_DIR="$1"; source "$1/lib/kernel/only.sh"; kernel_family_boards rk3588', "_", str(ROOT))
    if boards.splitlines() != list(BOARDS):
        raise StreamError("measurement-candidate family board set differs from policy")
    paths = {}
    for target in BOARDS:
        params = {}
        for line in run("bash", str(ROOT / "lib/resolve.sh"), target, "--variant", "default").splitlines():
            key, value = line.split("=", 1)
            params[key] = shlex.split(value)[0]
        if (params["KERNEL_PACKAGES"], params["KERNEL_SOURCE_PACKAGE_VERSION"], params["ARCH"]) != expected:
            raise StreamError("measurement-candidate shipping manifest identity differs from policy")
        dtb_path = f"{params['KERNEL_SOURCE_DTB_DEB_DIR']}/{params['DTB_NAME']}"
        paths[target] = dtb_path.removeprefix("/")
        try:
            run("bash", "-euo", "pipefail", "-c",
                'source "$1/lib/common.sh"; source "$1/lib/kernel/package.sh"; '
                'shift; validate_built_kernel_deb "$@"',
                "_", str(ROOT), str(work / candidate.deb), *expected, dtb_path,
                failure=f"{KIND} kernel deb board check failed: {target}; DTB presence pinned=present observed=unverified")
        except StreamError:
            # The producer lists directories differently; report a concrete type when we can.
            check_deb_archive(work / candidate.deb, {target: paths[target]}, env, require_present=False)
            raise
        params.pop("KERNEL_VARIANT", None)  # Match the producer's fingerprint input frame.
        observed = run("bash", str(ROOT / "lib/kernel/released.sh"), "--board", target,
                       "--fingerprint-from", str(metadata), extra_env=params)
        if observed != fp:
            prefix = observed[:16] if SHA.fullmatch(observed) else "unavailable"
            raise StreamError(f"{KIND} family fingerprint mismatch; "
                              f"SHA-256 (first 16) pinned={fp[:16]} observed={prefix}")
    check_deb_archive(work / candidate.deb, paths, env)


def stage_candidate(candidate: Candidate, work: Path, data: Path, env: dict[str, str]) -> None:
    work.mkdir(mode=0o700)
    pins = candidate.binding["payloads"] | candidate.binding["proof"]
    try:
        directory = os.open(candidate.bundle, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        raise StreamError("invalid measurement-candidate bundle directory") from None
    try:
        entries = set(os.listdir(directory))
        if entries - pins.keys():
            raise StreamError("invalid measurement-candidate bundle closure")
        for name, pin in pins.items():
            snapshot(directory, name, work / name, pin, LABELS.get(name, "kernel deb"))
    finally:
        os.close(directory)
    counts = {name: pin["sha256"] for name, pin in pins.items() if name != PROOF[2]}
    check_envelope(work / PROOF[2], counts)
    check_producer(work, candidate.binding, pins[candidate.deb]["sha256"])
    check_identity(work, candidate, env)
    for name, pin in candidate.binding["payloads"].items():
        os.link(work / name, data / pin["sha256"])


def check_sealed_candidate_archive(path: Path, inventory: bytes, rows: list[dict]) -> None:
    """Verify the final host-only archive without teaching the baked guest its new kind."""
    if path.stat().st_size > INPUT_LIMIT:
        raise StreamError("measurement-candidate capsule exceeds the unchanged size limit")
    with tarfile.open(path, "r:") as archive:
        entries = archive.getmembers()
        if (len(entries) != len(rows) + 1 or not entries or entries[0].name != "inventory.json"
                or any(not entry.isfile() or entry.issparse() for entry in entries)):
            raise StreamError("invalid measurement-candidate sealed archive closure")
        source = archive.extractfile(entries[0])
        if source is None or entries[0].size != len(inventory) or source.read() != inventory:
            raise StreamError("invalid measurement-candidate sealed inventory")
        for entry, row in zip(entries[1:], rows, strict=True):
            if entry.name != "objects/" + row["sha256"] or entry.size != row["length"]:
                raise StreamError("invalid measurement-candidate sealed archive object")
            source = archive.extractfile(entry)
            if source is None or hashlib.file_digest(source, "sha256").hexdigest() != row["sha256"]:
                raise StreamError("invalid measurement-candidate sealed archive digest")
