#!/usr/bin/env python3
"""Build an immutable kernel candidate; publish only through the approved VM workflow."""

from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("family")
    parser.add_argument("--candidate-run-id", required=True,
                        help="positive decimal local candidate ID, not an Actions run")
    parser.add_argument("--channel", choices=("beta", "stable"), default="beta")
    parser.add_argument("--os-releases", type=Path, required=True,
                        help="already authenticated snapshot of published OS kernel sidecars")
    parser.add_argument("--output-dir", type=Path,
                        help="repo-local bundle store (default: mkosi/build/kernel-releases)")
    parser.add_argument("--bench-report", type=Path)
    parser.add_argument("--publish", action="store_true",
                        help="always refuses until the owner resolves publisher authorization")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.family):
        raise KernelReleaseError("invalid family")
    if not re.fullmatch(r"[1-9][0-9]*", args.candidate_run_id):
        raise KernelReleaseError("invalid candidate_run_id")
    if os.environ.get("DRY_RUN", "0") != "0":
        raise KernelReleaseError("DRY_RUN cannot establish a kernel candidate")
    if command(["git", "rev-parse", "--is-shallow-repository"], repo) != "false":
        raise KernelReleaseError("complete local tag history is required (shallow repository)")
    if command(["git", "status", "--porcelain", "--untracked-files=normal"], repo):
        raise KernelReleaseError("candidate requires a clean source checkout")
    commit = command(["git", "rev-parse", "HEAD"], repo)
    boards = command([
        "env", f"PIPELINE_DIR={repo}", "bash", "-c",
        'source "$1/lib/kernel/only.sh"; kernel_family_boards "$2"',
        "kernel-release", str(repo), args.family,
    ], repo)
    board = boards.splitlines()[0]
    resolved = command(["bash", str(repo / "lib/resolve.sh"), board, "--variant", "default"])
    params = {key: shlex.split(value)[0]
              for key, value in (line.split("=", 1) for line in resolved.splitlines())}
    selected = version(params["KERNEL_SOURCE_PACKAGE_VERSION"])
    tag = f"kernel/v{selected}"
    tagged = command(["git", "tag", "--list", tag], repo)
    if tagged and command(["git", "rev-list", "-n", "1", tag], repo) != commit:
        raise KernelReleaseError("kernel tag commit differs from candidate checkout")
    output = (args.output_dir or repo / "mkosi/build/kernel-releases").resolve()
    if not output.is_relative_to(repo):
        raise KernelReleaseError("bundle store must be inside this repository")
    lock_path = repo / "mkosi/.kernel-release.lock"
    if lock_path.is_relative_to(output):
        raise KernelReleaseError("bundle store must not contain the producer lock")
    destination = output / selected
    if os.path.lexists(destination):
        raise KernelReleaseError(f"immutable candidate already exists: {destination}")
    gate = [sys.executable, str(repo / "ci/check-kernel-version-monotonic.py"),
            "--repo", str(repo), "--board", board, "--version", selected]
    command(["bash", str(repo / "ci/check-release-variant.sh"), "--variant", "default"], repo)
    command([*gate, "--candidate"], repo)
    command([*gate, "--published"], repo)
    floor = command([*gate, "--floor", "--os-releases", str(args.os_releases.resolve())], repo)
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if os.path.lexists(destination):
            raise KernelReleaseError(f"immutable candidate already exists: {destination}")
        created: list[Path] = []
        try:
            for directory in reversed((output, *output.parents)):
                if directory.is_dir():
                    continue
                try:
                    directory.mkdir()
                except FileExistsError:
                    continue
                created.append(directory)
            subprocess.run(["./build", args.family, "--kernel-only"], cwd=repo,
                           check=True, timeout=21600)
            built = repo / "mkosi/build/kernel-only" / args.family
            with tempfile.TemporaryDirectory(prefix=".candidate-", dir=output) as temp:
                work = Path(temp)
                # Reuse todo 8's strict metadata/checksum parser against local build output.
                history = work / "history"
                history.mkdir()
                (history / selected).symlink_to(built, target_is_directory=True)
                snapshot = work / "bundle"
                snapshot.mkdir()
                subprocess.run([
                    sys.executable, str(repo / "ci/check-kernel-version-monotonic.py"),
                    "--metadata", selected, "--out", str(snapshot),
                ], cwd=repo, env={**os.environ, "CERALIVE_KERNEL_HISTORY_DIR": str(history)},
                    check=True, timeout=180)
                record = artifact(snapshot / "kernel-artifact.json")
                if set(record.boards) != set(boards.splitlines()):
                    raise KernelReleaseError("kernel candidate lacks all family board validations")
                deb = f"{record.identity.package}_{selected}_arm64.deb"
                if sorted(p.name for p in built.glob("*.deb")) != [deb]:
                    raise KernelReleaseError("kernel candidate requires exactly one production archive")
                shutil.copyfile(built / deb, snapshot / deb)
                command(["sha256sum", "--check", "SHA256SUMS"], snapshot)
                env = {**os.environ, **{k: v for k, v in params.items() if k != "KERNEL_VARIANT"}}
                fingerprint = subprocess.run([
                    "bash", str(repo / "lib/kernel/released.sh"), "--board", board,
                    "--fingerprint-from", str(snapshot / "kernel-artifact.json"),
                ], cwd=repo, env=env, capture_output=True, text=True, check=True, timeout=180)
                if fingerprint.stdout.strip() != record.fingerprint:
                    raise KernelReleaseError("kernel candidate input fingerprint mismatch")
                command([*gate, "--candidate", "--artifact", str(snapshot / "kernel-artifact.json")], repo)
                command([*gate, "--published"], repo)
                floor = command([*gate, "--floor", "--os-releases", str(args.os_releases.resolve())], repo)
                if command(["git", "rev-parse", "HEAD"], repo) != commit or command(
                    ["git", "status", "--porcelain", "--untracked-files=normal"], repo
                ):
                    raise KernelReleaseError("source checkout changed during candidate build")
                bench_digest = None
                if args.bench_report:
                    bench = snapshot / f"bench-{selected}.json"
                    shutil.copyfile(args.bench_report, bench)
                    command([
                        sys.executable, str(repo / "ci/validate-kernel-bench-report.py"),
                        str(bench), args.candidate_run_id, tag, commit,
                        record.identity.deb_sha256, selected,
                    ], repo)
                    bench_digest = hashlib.sha256(bench.read_bytes()).hexdigest()
                # These are publisher inputs, NOT a valid Actions authorization.
                inputs = {
                    "mode": "apt-publish", "publish_run_id": None, "run_attempt": None,
                    "candidate_run_id": args.candidate_run_id, "tag": tag, "commit": commit,
                    "package": record.identity.package, "version": selected,
                    "deb_sha256": record.identity.deb_sha256, "channel": args.channel,
                    "bench_report_sha256": bench_digest,
                }
                (snapshot / "publish-authorization.inputs.json").write_text(
                    json.dumps(inputs, indent=2, sort_keys=True) + "\n")
                (snapshot / "candidate.json").write_text(json.dumps({
                    "schema": 1, "family": args.family, "commit": commit,
                    "candidate_run_id": args.candidate_run_id, "kernel_floor": floor,
                    "publication": "blocked-pending-owner",
                }, indent=2, sort_keys=True) + "\n")
                names = sorted(p.name for p in snapshot.iterdir())
                (snapshot / "BUNDLE.SHA256SUMS").write_text("".join(
                    f"{hashlib.sha256((snapshot / name).read_bytes()).hexdigest()}  {name}\n"
                    for name in names))
                # The lock serializes local producers; never replace even an empty version directory.
                if os.path.lexists(destination):
                    raise KernelReleaseError(f"immutable candidate already exists: {destination}")
                for path in snapshot.iterdir():
                    path.chmod(0o444)
                # Linux's create-only rename also closes the last-check/rename collision race.
                rename = ctypes.CDLL(None, use_errno=True).renameat2
                rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                                   ctypes.c_char_p, ctypes.c_uint]
                rename.restype = ctypes.c_int
                if rename(-100, os.fsencode(snapshot), -100, os.fsencode(destination), 1):
                    error = ctypes.get_errno()
                    if error == errno.EEXIST:
                        raise KernelReleaseError(f"immutable candidate already exists: {destination}")
                    raise OSError(error, os.strerror(error), str(destination))
                destination.chmod(0o555)
        finally:
            for directory in reversed(created):
                try:
                    directory.rmdir()
                except OSError as exc:
                    if exc.errno not in (errno.ENOTEMPTY, errno.EEXIST, errno.ENOENT):
                        raise
    print(f"local kernel candidate: {destination}")
    return 0


if __name__ == "__main__":
    # Refuse before loading repository code, parsing inputs or creating any file.
    workflow_publish = "--publish" in sys.argv[1:]
    workflow_context = (
        os.environ.get("GITHUB_ACTIONS") == "true"
        and os.environ.get("GITHUB_REPOSITORY") == "CERALIVE/image-building-pipeline"
        and os.environ.get("GITHUB_WORKFLOW_REF") ==
        "CERALIVE/image-building-pipeline/.github/workflows/kernel-release.yml@refs/heads/master"
        and os.environ.get("GITHUB_REF") == "refs/heads/master"
        and os.environ.get("GITHUB_RUN_ATTEMPT") == "1"
        and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
    )
    if workflow_publish and not workflow_context:
        sys.exit(
            "kernel release: publication blocked pending owner decision: apt-worker requires a "
            "kernel-release.yml workflow_dispatch run approved in the kernel-release "
            "environment; choose a self-hosted kernel-release.yml on this PC or an "
            "apt-worker contract change"
        )
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
    from kernel_release import KernelReleaseError, artifact, command, version

    try:
        if workflow_publish:
            from kernel_workflow import main as publish
            sys.exit(publish([arg for arg in sys.argv[1:] if arg != "--publish"]))
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError,
            KernelReleaseError) as exc:
        print(f"kernel release: {exc}", file=sys.stderr)
        sys.exit(1)
