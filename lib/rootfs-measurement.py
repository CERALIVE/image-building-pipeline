#!/usr/bin/env python3
"""Record actual retained rootfs artifacts after all existing content gates pass."""

import hashlib
import json
import os
from pathlib import Path
import sys


def identity(path: Path) -> dict[str, str | int]:
    with path.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    return {"sha256": digest, "bytes": path.stat().st_size}


def main() -> None:
    output, tar, lock, slots = map(Path, sys.argv[1:])
    contents = {"rootfs.tar": identity(tar), "packages.lock.json": identity(lock)}
    for slot in ("rootfs_a", "rootfs_b"):
        image = slots / f"{slot}.ext4"
        contents[f"{slot}.ext4"] = identity(image)
        if image.stat().st_size != 4096 * 1024 * 1024:
            raise ValueError("measurement slot geometry changed")
        for suffix in ("reserve", "header"):
            receipt = slots / f"{slot}.{suffix}"
            if not receipt.is_file() or not receipt.stat().st_size:
                raise ValueError("measurement reserve/header evidence missing")
            contents[f"{slot}.{suffix}"] = identity(receipt)
    for name in ("boot.scr", "boot.scr.sha256"):
        contents[name] = identity(slots / name)
    row = {
        "schema": 1, "purpose": "rootfs-measurement", "build_mode": "production",
        "board": os.environ["CERALIVE_BOARD"], "source_commit": os.environ["CERALIVE_IMAGE_BUILD_COMMIT"],
        "source_date_epoch": int(os.environ["SOURCE_DATE_EPOCH"]),
        "input_sha256": os.environ["CERALIVE_SEALED_INPUT_SHA256"],
        "public_root_der_sha256": os.environ["RAUC_ROOT_SHA256"],
        "kernel_version": os.environ["KERNEL_SOURCE_PACKAGE_VERSION"],
        "stages": {name: 0 for name in ("resolve", "fetch", "kernel-reuse", "rauc-build",
                                        "partition", "bsp", "mkosi", "tar", "boot", "size",
                                        "firmware-closure", "packages-lock", "parity", "raw-slots")},
        "slot_only_additions": ["usr/lib/ceralive/boot/boot.scr",
                                "usr/lib/ceralive/boot/boot.scr.sha256"],
        "metadata_validity": json.loads(
            (Path(os.environ["CERALIVE_SEALED_INPUTS"]) / "metadata-validity.json").read_text()),
        "artifacts": contents, "signed_candidate": False,
    }
    with output.open("x") as destination:
        json.dump(row, destination, indent=2, sort_keys=True)
        destination.write("\n")


if __name__ == "__main__":
    main()
