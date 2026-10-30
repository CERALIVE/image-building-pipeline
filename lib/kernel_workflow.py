"""Approved Actions adapter for the local kernel candidate engine."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

from kernel_release import (
    REPOSITORY, KernelReleaseError, command, verified_metadata,
)

WORKFLOW = ".github/workflows/kernel-release.yml"
API = f"repos/{REPOSITORY}"
BOOTSTRAP_STATEMENT = "No kernel-apt-stage image is published."


def prepare_bootstrap(repo: Path, work: Path, gate: list[str], tag: str, selected: str,
                      commit: str, deb_sha256: str, names: tuple[str, ...]) -> None:
    """Single-step first publication: create the identity Release if absent and attach the
    owner's bootstrap statement. authorize/dispatch then re-verify everything independently."""
    owner = os.environ.get("KERNEL_BOOTSTRAP_OWNER", "")
    if not owner or owner != os.environ.get("GITHUB_ACTOR"):
        raise KernelReleaseError("bootstrap owner must be the dispatching actor")
    view = ["gh", "release", "view", tag, "--repo", REPOSITORY]
    if subprocess.run(view, capture_output=True).returncode != 0:
        command([*gate, "--published"], repo)
        command(["gh", "release", "create", tag, "--repo", REPOSITORY, "--verify-tag",
                 "--target", commit, "--title", tag, "--notes", "Immutable kernel candidate.",
                 *[str(work / name) for name in names]], repo)
    bench = f"bench-{selected}.json"
    if bench in command([*view, "--json", "assets", "--jq", ".assets[].name"], repo).split():
        return  # an existing report wins; authorize validates it
    report = work / bench
    report.write_text(json.dumps({
        "type": "bootstrap", "version": selected, "deb_sha256": deb_sha256,
        "approving_owner": owner, "statement": BOOTSTRAP_STATEMENT,
    }, indent=2, sort_keys=True) + "\n")
    command(["gh", "release", "upload", tag, str(report), "--repo", REPOSITORY], repo)


def api(path: str) -> dict:
    return json.loads(command(["gh", "api", f"{API}/{path}"]))


def approved_context(repo: Path) -> tuple[str, str]:
    """Check GitHub's run, environment review and live shared floor lease."""
    run_id = os.environ["GITHUB_RUN_ID"]
    commit = command(["git", "rev-parse", "HEAD"], repo)
    if not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise KernelReleaseError("invalid workflow run ID")
    run = api(f"actions/runs/{run_id}")
    if (
        run["id"] != int(run_id) or run["run_attempt"] != 1
        or run["path"] != WORKFLOW or run["event"] != "workflow_dispatch"
        or run["head_sha"] != commit or run["head_branch"] != "master"
        or run["status"] != "in_progress"
        or run["repository"]["full_name"] != REPOSITORY
    ):
        raise KernelReleaseError("publish run provenance refused")
    approvals = json.loads(command(["gh", "api", f"{API}/actions/runs/{run_id}/approvals"]))
    if not any(row["state"] == "approved" and any(
        env["name"] == "kernel-release" for env in row["environments"]
    ) for row in approvals):
        raise KernelReleaseError("kernel-release environment is not approved")
    lease = json.loads(command([
        "gh", "api", f"{API}/actions/concurrency_groups/ceralive-kernel-floor",
        "-H", "X-GitHub-Api-Version: 2026-03-10",
    ]))
    holders = [row for row in lease["group_members"] if row["status"] == "in_progress"]
    if lease["group_name"] != "ceralive-kernel-floor" or len(holders) != 1 or (
        holders[0]["run_id"] != int(run_id)
        or holders[0]["job_id"] != int(os.environ["KERNEL_PUBLISH_JOB_ID"])
    ):
        raise KernelReleaseError("shared kernel floor exclusion refused")
    return run_id, commit


def download_artifact(run_id: str, commit: str, name: str, dest: Path) -> None:
    pages = command(["gh", "api", "--paginate",
                     f"{API}/actions/runs/{run_id}/artifacts?per_page=100",
                     "--jq", f'.artifacts[] | select(.name == "{name}")'])
    # gh's --jq prints one JSON object per match; reject duplicates before extraction.
    row = json.loads(pages)
    if (row["name"] != name or row["expired"] is not False
        or row["workflow_run"]["id"] != int(run_id)
        or row["workflow_run"]["head_sha"] != commit):
        raise KernelReleaseError("candidate artifact provenance refused")
    with tempfile.TemporaryFile() as archive:
        subprocess.run(["gh", "api", f"{API}/actions/artifacts/{row['id']}/zip"],
                       stdout=archive, check=True, timeout=300)
        archive.seek(0)
        with zipfile.ZipFile(archive) as bundle:
            names = bundle.namelist()
            if (len(names) != len(set(names)) or any(
                Path(n).name != n or n in (".", "..") or "\\" in n
                for n in names
            )):
                raise KernelReleaseError("unsafe artifact archive")
            for info in bundle.infolist():
                if info.is_dir() or (info.external_attr >> 16) & 0o170000 == 0o120000:
                    raise KernelReleaseError("artifact is not regular files")
                with bundle.open(info) as source, (dest / info.filename).open("xb") as output:
                    shutil.copyfileobj(source, output)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("release", "prepare", "authorize", "dispatch"))
    parser.add_argument("--candidate-run-id", required=True)
    parser.add_argument("--channel", choices=("beta", "stable"), required=True)
    parser.add_argument("--os-releases", type=Path, required=True)
    parser.add_argument("--authorization", type=Path, required=True)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[1-9][0-9]*", args.candidate_run_id):
        raise KernelReleaseError("invalid candidate run ID")
    repo = Path(__file__).resolve().parents[1]
    run_id, commit = approved_context(repo)
    if args.candidate_run_id == run_id:
        raise KernelReleaseError("candidate must be a completed earlier run")
    candidate = api(f"actions/runs/{args.candidate_run_id}")
    if (
        candidate["id"] != int(args.candidate_run_id) or candidate["path"] != WORKFLOW
        or candidate["event"] != "workflow_dispatch" or candidate["conclusion"] != "success"
        or candidate["run_attempt"] != 1 or candidate["head_sha"] != commit
        or candidate["head_branch"] != "master"
        or candidate["repository"]["full_name"] != REPOSITORY
    ):
        raise KernelReleaseError("candidate run provenance refused")
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        download_artifact(args.candidate_run_id, commit, f"kernel-candidate-{commit}", work)
        record = verified_metadata(json.loads((work / "kernel-artifact.json").read_text())["version"], work)
        selected = record.identity.version
        tag = f"kernel/v{selected}"
        if tag != os.environ["KERNEL_RELEASE_TAG"]:
            raise KernelReleaseError("requested tag differs from candidate identity")
        deb = f"{record.identity.package}_{selected}_arm64.deb"
        names = (deb, "resolved.config", "built-modules.txt", "kernel-artifact.json", "SHA256SUMS")
        if set(p.name for p in work.iterdir()) != set(names):
            raise KernelReleaseError("candidate must contain exactly five builder files")
        if hashlib.file_digest((work / deb).open("rb"), "sha256").hexdigest() != record.identity.deb_sha256:
            raise KernelReleaseError("candidate archive SHA256 mismatch")
        if set(record.boards) != {"rock-5b-plus", "orange-pi-5-plus"}:
            raise KernelReleaseError("candidate lacks both family board validations")
        if command(["git", "rev-list", "-n", "1", tag], repo) != commit:
            raise KernelReleaseError("kernel tag commit differs from workflow HEAD")
        gate = ["python3", str(repo / "ci/check-kernel-version-monotonic.py"),
                "--version", selected, "--repo", str(repo)]
        command([*gate, "--candidate", "--artifact", str(work / "kernel-artifact.json")], repo)
        command([*gate, "--floor", "--os-releases", str(args.os_releases)], repo)
        if args.operation == "prepare":
            prepare_bootstrap(repo, work, gate, tag, selected, commit, record.identity.deb_sha256, names)
            return 0
        if args.operation == "release":
            command([*gate, "--published"], repo)
            command(["gh", "release", "create", tag, "--repo", REPOSITORY, "--verify-tag",
                     "--target", commit, "--title", tag, "--notes", "Immutable kernel candidate.",
                     *[str(work / name) for name in names]], repo)
            return 0
        released = work / "released"
        released.mkdir()
        command(["gh", "release", "download", tag, "--repo", REPOSITORY, "--dir", str(released),
                 *[arg for name in names for arg in ("--pattern", name)],
                 "--pattern", f"bench-{selected}.json"], repo)
        if any((released / name).read_bytes() != (work / name).read_bytes() for name in names):
            raise KernelReleaseError("released bytes differ from candidate SHA256SUMS")
        bench = released / f"bench-{selected}.json"
        command(["python3", str(repo / "ci/validate-kernel-bench-report.py"),
                 str(bench), args.candidate_run_id, tag, commit, record.identity.deb_sha256, selected])
        authorization = {
            "mode": "apt-publish", "publish_run_id": run_id, "run_attempt": 1,
            "candidate_run_id": args.candidate_run_id, "tag": tag, "commit": commit,
            "package": record.identity.package, "version": selected,
            "deb_sha256": record.identity.deb_sha256, "channel": args.channel,
            "bench_report_sha256": hashlib.sha256(bench.read_bytes()).hexdigest(),
        }
        if args.operation == "authorize":
            with args.authorization.open("x") as output:
                json.dump(authorization, output, indent=2, sort_keys=True)
                output.write("\n")
            return 0
        uploaded = work / "uploaded"
        uploaded.mkdir()
        download_artifact(run_id, commit, "publish-authorization", uploaded)
        if set(p.name for p in uploaded.iterdir()) != {"publish-authorization.json"} or (
            json.loads((uploaded / "publish-authorization.json").read_text()) != authorization
            or (uploaded / "publish-authorization.json").read_bytes() != args.authorization.read_bytes()
        ):
            raise KernelReleaseError("uploaded authorization differs from validated publication")
        token = os.environ.get("CERALIVE_DISPATCH_TOKEN")
        if not token:
            raise KernelReleaseError("CERALIVE_DISPATCH_TOKEN is not provisioned on this repository")
        payload = {"event_type": "apt-reindex", "client_payload": {
            "component": "ceralive-kernel", "repo": "image-building-pipeline",
            "channel": args.channel, "tag": tag, "version": selected,
            "kernel_package": record.identity.package,
            "kernel_artifact_sha256": record.identity.deb_sha256, "publish_run_id": run_id,
        }}
        subprocess.run(["gh", "api", "repos/CERALIVE/apt-worker/dispatches", "--method", "POST",
                        "--input", "-"], input=json.dumps(payload), text=True, check=True,
                       env={**os.environ, "GH_TOKEN": token}, timeout=180)
    return 0
