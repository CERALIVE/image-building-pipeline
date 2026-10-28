#!/usr/bin/env python3
"""Gate immutable family kernel identities and the published OS downgrade floor."""

from __future__ import annotations

import argparse
from dataclasses import asdict
from functools import cmp_to_key
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from kernel_release import (
    KernelIdentity, KernelReleaseError, artifact, command, compare, metadata,
    published_versions, sidecar, tag_versions, version,
)


def parameters(repo: Path, board: str, variant: str) -> dict[str, str]:
    output = command(["bash", str(repo / "lib/resolve.sh"), board, "--variant", variant])
    return dict(line.split("=", 1)[0:1] + [shlex.split(line.split("=", 1)[1])[0]]
                for line in output.splitlines() if line)


def candidate_identity(lock: Path) -> KernelIdentity:
    rows = [r for r in json.loads(lock.read_text())["packages"]
            if r["name"].startswith("linux-image-")]
    if len(rows) != 1:
        raise KernelReleaseError("candidate must contain exactly one installed kernel")
    row = rows[0]
    if row["origin"] != "ceralive-kernel" or row["arch"] != "arm64":
        raise KernelReleaseError("kernel_not_on_apt: candidate lacks an authenticated APT kernel")
    return KernelIdentity.parse({"package": row["name"], "version": row["version"],
                                 "deb_sha256": row["sha256"]})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--candidate", action="store_true")
    modes.add_argument("--published", action="store_true")
    modes.add_argument("--floor", action="store_true")
    modes.add_argument("--metadata", metavar="VERSION")
    modes.add_argument("--sidecar", metavar="PACKAGES_LOCK", type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--board", default="rock-5b-plus")
    parser.add_argument("--variant", default=os.environ.get("CERALIVE_KERNEL_VARIANT", "default"))
    parser.add_argument("--version")
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--os-releases", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    if args.metadata:
        if args.out is None:
            parser.error("--metadata requires --out")
        metadata(args.metadata, args.out)
        return 0
    if args.sidecar:
        if args.out is None or args.version is None:
            parser.error("--sidecar requires --out and --version (OS CalVer)")
        identity = candidate_identity(args.sidecar)
        with tempfile.TemporaryDirectory() as temp:
            released = metadata(identity.version, Path(temp))
        if identity != released.identity:
            raise KernelReleaseError("candidate kernel digest differs from released artifact")
        if args.board not in released.boards:
            raise KernelReleaseError("candidate board absent from released validated_boards")
        candidate_artifact = args.sidecar.parent / "kernel-artifact.json"
        if candidate_artifact.exists() and artifact(candidate_artifact).identity != identity:
            raise KernelReleaseError("candidate package lock/artifact identity mismatch")
        output = {"schema": 1, "board": args.board, "os_version": args.version,
                  "kernel": asdict(identity)}
        args.out.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
        sidecar(args.out)
        return 0
    if args.floor:
        versions = published_versions()
        if args.os_releases:
            if not args.os_releases.is_dir():
                raise KernelReleaseError("OS kernel history directory missing")
            versions.extend(sidecar(p).version for p in args.os_releases.rglob("*.json"))
        floor = max(versions, key=cmp_to_key(compare)) if versions else "none"
        if args.version and floor != "none" and compare(args.version, floor) < 0:
            raise KernelReleaseError(f"os_kernel_below_floor: {args.version} < {floor}")
        print(floor)
        return 0
    params = parameters(args.repo, args.board, args.variant)
    if "KERNEL_SOURCE_PACKAGE_VERSION" not in params:
        return 0
    selected = version(args.version or params["KERNEL_SOURCE_PACKAGE_VERSION"])
    if args.candidate and selected != params["KERNEL_SOURCE_PACKAGE_VERSION"]:
        raise KernelReleaseError("candidate version differs from manifest")
    versions = published_versions() if args.published else tag_versions(args.repo)
    if args.candidate and os.environ.get("CERALIVE_KERNEL_HISTORY_DIR"):
        versions.extend(published_versions())
    if not versions:
        print(f"kernel version {selected}: no previous publication")
        return 0
    newest = max(versions, key=cmp_to_key(compare))
    ordering = compare(selected, newest)
    if ordering < 0 or (args.published and ordering == 0):
        raise KernelReleaseError(f"bump package_version: {selected} does not exceed published {newest}")
    if args.candidate and ordering == 0 and selected in published_versions():
        with tempfile.TemporaryDirectory() as temp:
            released = metadata(selected, Path(temp))
            if args.artifact and artifact(args.artifact).identity != released.identity:
                raise KernelReleaseError("bump package_version: candidate artifact identity changed")
            inputs = args.artifact or Path(temp) / "kernel-artifact.json"
            env = dict(os.environ)
            # Match stage_resolve's exported inputs; KERNEL_VARIANT is not exported.
            env.update({k: v for k, v in params.items() if k != "KERNEL_VARIANT"})
            result = subprocess.run(
                ["bash", str(args.repo / "lib/kernel/released.sh"), "--board", args.board,
                 "--fingerprint-from", str(inputs)], env=env,
                capture_output=True, text=True, timeout=180,
            )
            if result.returncode or result.stdout.strip() != released.fingerprint:
                raise KernelReleaseError("bump package_version: released kernel inputs changed"
                                         + (f": {result.stderr.strip()}" if result.returncode else ""))
            if args.artifact and artifact(args.artifact).fingerprint != released.fingerprint:
                raise KernelReleaseError("bump package_version: builder closure or epoch changed")
    print(f"kernel version {selected}: immutable identity/ordering accepted")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError,
            KernelReleaseError) as exc:
        print(f"kernel release: {exc}", file=sys.stderr)
        sys.exit(1)
