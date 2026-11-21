#!/usr/bin/env python3
"""Read and stage a candidate only from a launcher-approved guest job."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci/kernel-runner"))
from image_candidate import Candidate, check_identity, snapshot
from image_candidate_policy import Approval, FIELD, KIND, parse_approval
from image_policy import read_policy
from image_stream import Identity, StreamError, exact_json, unique_object

JOB = Path("/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive/image/raw")
INPUTS = Path("/opt/ceralive-image-job/input")


def authorized_candidate(directory: Path, board: str) -> Approval | None:
    trust = read_policy(directory / "trust.json")
    inventory = read_policy(directory / "inventory.json")
    rows = inventory.get("objects", [])
    if FIELD not in trust and FIELD not in inventory and all(row["kind"] != KIND for row in rows):
        return None
    if directory != INPUTS or os.environ.get("CERALIVE_BUILD_PURPOSE") != "rootfs-measurement":
        raise StreamError("candidate requires a controller-approved measurement guest")
    with JOB.open("rb") as firmware:
        raw = firmware.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise StreamError("oversized controller job")
    job = json.loads(raw, object_pairs_hook=unique_object)
    identity = Identity(**job["identity"])
    if (type(job["schema"]) is not int or job["schema"] != 1 or job["operation"] not in ("measure", "verify")
            or (identity.board, identity.commit, identity.epoch) != (board, inventory["source_commit"], inventory["epoch"])
            or inventory["board"] != board or "kernel_metadata" in trust
            or not exact_json(trust, job["trust"])):
        raise StreamError("candidate input differs from controller approval")
    candidate = parse_approval(trust[FIELD])
    if (board not in candidate["validated_boards"] or not exact_json(inventory[FIELD], candidate)
            or len([row for row in rows if row["kind"] == KIND]) != 5
            or any(row["kind"] == "kernel-metadata" for row in rows)):
        raise StreamError("candidate delivery differs from controller approval")
    for pin in candidate["payloads"].values():
        expected = pin | {"kind": KIND, "urls": []}
        if sum(exact_json(row, expected) for row in rows) != 1:
            raise StreamError("candidate delivery differs from controller approval")
    return candidate


def stage(directory: Path, board: str, expected: tuple[str, str, str], output: Path) -> str:
    approval = authorized_candidate(directory, board)
    if approval is None or tuple(approval[key] for key in ("package", "version", "arch")) != expected:
        raise StreamError("candidate package differs from the shipping manifest")
    package, version, arch = expected
    deb = f"{package}_{version}_{arch}.deb"
    with tempfile.TemporaryDirectory(prefix=".candidate-", dir=output.parent) as private:
        work = Path(private)
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            for name, pin in approval["payloads"].items():
                snapshot(fd, pin["sha256"], work / name, pin, "approved candidate payload")
        finally:
            os.close(fd)
        # Producer existence was checked at host sealing; both guests instead bind
        # the entire reviewed producer identity to the immutable controller job.
        env = {"PATH": os.environ["PATH"], "LANG": "C.UTF-8", "HOME": private, "TMPDIR": private}
        check_identity(work, Candidate(approval, directory, deb), env, check_local_producer=False)
        output.mkdir(exist_ok=True)
        for name in approval["payloads"]:
            os.link(work / name, output / name)
    return approval["payloads"][deb]["sha256"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("mode", "stage"))
    parser.add_argument("directory", type=Path)
    parser.add_argument("board")
    parser.add_argument("package", nargs="?")
    parser.add_argument("version", nargs="?")
    parser.add_argument("arch", nargs="?")
    parser.add_argument("output", nargs="?", type=Path)
    args = parser.parse_args()
    if args.operation == "mode":
        print(KIND if authorized_candidate(args.directory, args.board) is not None else "released")
    else:
        print(stage(args.directory, args.board, (args.package, args.version, args.arch), args.output))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, StreamError, TypeError, ValueError, subprocess.SubprocessError):
        sys.exit("sealed measurement kernel approval or payload validation failed")
