#!/usr/bin/env python3
import hashlib
import json
import pathlib
import re
import sys


class LockError(Exception):
    pass


def installed_packages(status: pathlib.Path) -> list[dict[str, str]]:
    packages = []
    for paragraph in status.read_text().split("\n\n"):
        fields = {}
        for line in paragraph.splitlines():
            if line and not line[0].isspace() and ": " in line:
                name, value = line.split(": ", 1)
                fields[name] = value
        if fields.get("Status", "").endswith(" ok installed"):
            packages.append(
                {
                    "name": fields["Package"],
                    "version": fields["Version"],
                    "arch": fields["Architecture"],
                }
            )
    if not packages:
        raise LockError(f"no installed packages in {status}")
    return packages


def merge(
    root: pathlib.Path,
    staging: pathlib.Path,
    output: pathlib.Path,
    epoch: str,
    built_at: str,
    commit: str,
    patches_commit: str,
) -> None:
    receipts: dict[tuple[str, str, str], dict[str, str]] = {}
    dates: dict[str, str] = {}
    receipt_dirs = (root / "usr/lib/ceralive/build-lock", staging / "packages-lock")
    for directory in receipt_dirs:
        if not directory.is_dir():
            continue
        for file in sorted(directory.glob("*.jsonl")):
            for line in file.read_text().splitlines():
                row = json.loads(line)
                if set(row) != {"name", "version", "arch", "origin", "sha256"}:
                    raise LockError(f"invalid receipt shape in {file}: {row}")
                if not re.fullmatch(r"[0-9a-f]{64}", row["sha256"]):
                    raise LockError(f"invalid SHA-256 for {row['name']} in {file}")
                key = (row["name"], row["version"], row["arch"])
                previous = receipts.get(key)
                if previous and previous != row:
                    raise LockError(f"conflicting receipts for {key}: {previous} / {row}")
                receipts[key] = row
        for file in sorted(directory.glob("*.dates")):
            for line in file.read_text().splitlines():
                suite, date = line.split("\t", 1)
                dates[suite] = date

    if not dates:
        raise LockError("no authenticated Debian Release dates were captured")
    if not epoch.isdecimal():
        raise LockError("invalid SOURCE_DATE_EPOCH")

    packages = []
    for identity in installed_packages(root / "var/lib/dpkg/status"):
        key = (identity["name"], identity["version"], identity["arch"])
        if identity["name"].startswith("linux-image-"):
            if not re.fullmatch(r"[0-9a-f]{40}", commit) or not re.fullmatch(
                r"[0-9a-f]{40}", patches_commit
            ):
                raise LockError(f"source-built kernel {key}: commit pins absent or malformed")
            debs = list((staging / "kernel-build").glob("*.deb"))
            matches = [
                deb
                for deb in debs
                if deb.name.startswith(identity["name"] + "_")
                and deb.name.endswith("_" + identity["arch"] + ".deb")
            ]
            if len(matches) != 1:
                raise LockError(f"source-built kernel {key}: expected one staged artifact, got {len(matches)}")
            deb = matches[0]
            packages.append(
                {
                    **identity,
                    "origin": "source-built",
                    "source": {"commit": commit, "patches_commit": patches_commit},
                    "artifact": {"sha256": {deb.name: hashlib.sha256(deb.read_bytes()).hexdigest()}},
                }
            )
        elif identity["name"] in ("rauc", "rauc-service"):
            # [2c/9] (lib/stages/rauc-build.sh) compiles the pipeline's own RAUC pin
            # from pinned upstream source into staging/rauc-build/*.deb — the same
            # "produced by this build's own container, never fetched from any apt
            # archive or index" shape as the generated-locally libv4l-0 sidecar, minus
            # a git-commit object to report (RAUC's build stage carries no equivalent
            # pin this merge can read, unlike the kernel branch above). Hash the
            # staged .deb bytes directly rather than requiring a fetch-stage sidecar.
            debs = list((staging / "rauc-build").glob("*.deb"))
            matches = [
                deb
                for deb in debs
                if deb.name.startswith(identity["name"] + "_")
                and deb.name.endswith("_" + identity["arch"] + ".deb")
            ]
            if len(matches) != 1:
                raise LockError(f"rauc platform pin {key}: expected one staged artifact, got {len(matches)}")
            deb = matches[0]
            packages.append(
                {
                    **identity,
                    "origin": "generated-locally",
                    "sha256": hashlib.sha256(deb.read_bytes()).hexdigest(),
                }
            )
        else:
            receipt = receipts.get(key)
            if receipt is None:
                raise LockError(f"unaccounted installed package {key}: no apt/fetch/generated SHA-256 receipt")
            packages.append(receipt)

    output.parent.mkdir(parents=True, exist_ok=True)
    temp = output.with_name(output.name + ".tmp")
    temp.write_text(
        json.dumps(
            {
                "debian_release_dates": dates,
                "built_at": built_at,
                "source_date_epoch": int(epoch),
                "packages": sorted(packages, key=lambda row: (row["name"], row["arch"])),
            },
            sort_keys=True,
            indent=2,
        )
        + "\n"
    )
    temp.replace(output)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 9 or sys.argv[1] != "merge":
            raise LockError("usage: packages-lock.py merge ROOT STAGING OUTPUT EPOCH BUILT_AT COMMIT PATCHES_COMMIT")
        merge(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4]), *sys.argv[5:])
    except (OSError, ValueError, KeyError, TypeError, LockError) as exc:
        print(f"packages lock: {exc}", file=sys.stderr)
        sys.exit(1)
