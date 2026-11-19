"""Independent data-only verification in a fresh offline overlay."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import runpy
import shutil
import stat
import subprocess
import tarfile

from image_capsule import Capsule, digest_file
from image_stream import Identity, StreamError, list_directory, listed_entry, retry_check


@contextmanager
def parent_fd(root: Path, name: str):
    """Walk a mounted root without letting any ancestor symlink escape it."""
    parts = PurePosixPath(name).parts
    if not parts or any(part in (".", "..") for part in parts) or name.startswith("/"):
        raise StreamError("unsafe returned tar path")
    fd = os.open(root, os.O_DIRECTORY)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd, parts[-1]
    finally:
        os.close(fd)


def compare_slot(root: Path, archive: Path, boot: dict[str, Path]) -> None:
    """Bind file bytes, ownership, modes, links and special-file identities."""
    retry_check(_compare_slot, root, archive, boot)


def _compare_slot(root: Path, archive: Path, boot: dict[str, Path]) -> None:
    """Bind file bytes, ownership, modes, links and special-file identities."""
    expected = set()
    with tarfile.open(archive, "r:") as tar:
        for member in tar:
            name = member.name.removeprefix("./").rstrip("/")
            if name in ("", "."):
                actual = root.stat()
                if not member.isdir() or (stat.S_IMODE(actual.st_mode), actual.st_uid, actual.st_gid) != (
                        member.mode, member.uid, member.gid):
                    raise StreamError("slot root metadata differs from emitted tar")
                continue
            if name in expected or len(name) > 4096 or len(expected) >= 1_000_000:
                raise StreamError("duplicate or excessive returned rootfs inventory")
            expected.add(name)
            with parent_fd(root, name) as (fd, leaf):
                actual = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
                if (stat.S_IMODE(actual.st_mode), actual.st_uid, actual.st_gid) != (
                        member.mode, member.uid, member.gid):
                    raise StreamError("slot ownership/mode differs from emitted tar")
                if member.isfile():
                    if not stat.S_ISREG(actual.st_mode) or actual.st_size != member.size:
                        raise StreamError("slot file identity differs from emitted tar")
                    content = tar.extractfile(member)
                    if content is None:
                        raise StreamError("unreadable returned tar file")
                    handle = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
                    with content, os.fdopen(handle, "rb") as file:
                        if hashlib.file_digest(content, "sha256").digest() != hashlib.file_digest(file, "sha256").digest():
                            raise StreamError("slot file bytes differ from emitted tar")
                elif member.issym():
                    if not stat.S_ISLNK(actual.st_mode) or os.readlink(leaf, dir_fd=fd) != member.linkname:
                        raise StreamError("slot symlink differs from emitted tar")
                elif member.islnk():
                    linked = member.linkname.removeprefix("./")
                    with parent_fd(root, linked) as (linked_fd, linked_leaf):
                        other = os.stat(linked_leaf, dir_fd=linked_fd, follow_symlinks=False)
                    if not stat.S_ISREG(actual.st_mode) or actual.st_ino != other.st_ino:
                        raise StreamError("slot hardlink differs from emitted tar")
                elif member.isdir():
                    if not stat.S_ISDIR(actual.st_mode):
                        raise StreamError("slot directory differs from emitted tar")
                elif member.ischr() or member.isblk():
                    checker = stat.S_ISCHR if member.ischr() else stat.S_ISBLK
                    if not checker(actual.st_mode) or actual.st_rdev != os.makedev(member.devmajor, member.devminor):
                        raise StreamError("slot device metadata differs from emitted tar")
                elif member.isfifo():
                    if not stat.S_ISFIFO(actual.st_mode):
                        raise StreamError("slot FIFO differs from emitted tar")
                else:
                    raise StreamError("unsupported returned tar member")
    actual_names = set()
    directories = [root]
    while directories:
        directory = directories.pop()
        for name in list_directory(directory):
            path = directory / name
            actual_names.add(str(path.relative_to(root)))
            if len(actual_names) > 1_000_000 + len(boot) + 2:
                raise StreamError("excessive slot directory inventory")
            if stat.S_ISDIR(path.lstat().st_mode):
                directories.append(path)
    additions = set(boot) | {"usr/lib/ceralive/boot", "lost+found"}
    if actual_names - expected - additions:
        raise StreamError("slot contains unexpected additions to emitted tar")
    if "lost+found" in actual_names:
        housekeeping = root / "lost+found"
        if not stat.S_ISDIR(housekeeping.lstat().st_mode) or list_directory(housekeeping):
            raise StreamError("slot lost+found is not an empty directory")
    for name, content in boot.items():
        with parent_fd(root, name) as (fd, leaf):
            actual = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
            if not stat.S_ISREG(actual.st_mode) or (stat.S_IMODE(actual.st_mode), actual.st_uid, actual.st_gid) != (0o644, 0, 0):
                raise StreamError("slot boot payload metadata mismatch")
            handle = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
            with os.fdopen(handle, "rb") as file:
                if hashlib.file_digest(file, "sha256").hexdigest() != digest_file(content):
                    raise StreamError("slot boot payload differs from trusted compilation")


def check_firmware(firmware: Path, removed: tuple[str, ...], retained: tuple[str, ...]) -> None:
    unexpected = any(listed_entry(firmware, name) is not None for name in removed)
    if unexpected or not all((info := listed_entry(firmware, name)) is not None
                             and stat.S_ISDIR(info.st_mode) for name in retained):
        raise StreamError("ceralive8 removed/retained firmware inventory mismatch")


def verify(source: Path, capsule: Capsule, job: dict) -> list[tuple[str, Path]]:
    from image_guest import HOME, resolve
    inputs = capsule.directory
    identity = Identity(**job["build_identity"])
    artifacts = {name: inputs / digest for name, digest in job["artifacts"].items()}
    env = {"PATH": os.environ["PATH"], "HOME": str(HOME), "LANG": "C.UTF-8",
           "LC_ALL": "C", "SOURCE_DATE_EPOCH": str(identity.epoch),
           "APT_GPG_PUBLIC_B64": "sealed-public-trust", "CERALIVE_BUILD_MODE": "production"}
    params = resolve(source, capsule.board, env)
    if json.loads(artifacts["resolved.json"].read_text()) != params:
        raise StreamError("returned resolver output differs from approved source")
    subprocess.run(["bash", "-euo", "pipefail", "-c",
        'source "$1"; rauc_public_root_resolve "$2" "$3"', "_",
        str(source / "lib/rauc-pki-contract.sh"), str(inputs / capsule.device_root),
        job["trust"]["root_der_sha256"]], check=True, env=env, capture_output=True)
    measurement = json.loads(artifacts["measurement.json"].read_text())
    if measurement["public_root_der_sha256"] != job["trust"]["root_der_sha256"]:
        raise StreamError("returned public device trust identity mismatch")
    metadata = HOME / "released-kernel"
    metadata.mkdir()
    for name in ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS"):
        supplied = artifacts["kernel.SHA256SUMS" if name == "SHA256SUMS" else name]
        approved = inputs / job["trust"]["kernel_metadata"][name]
        if digest_file(supplied) != digest_file(approved):
            raise StreamError("returned kernel metadata differs from independently selected release")
        shutil.copyfile(approved, metadata / name)
    # Existing strict checksum/identity reader, selected from the approved source.
    import sys
    sys.path.insert(0, str(source / "lib"))
    from kernel_release import verified_metadata
    released = verified_metadata("7.2.0-ceralive8", metadata)
    if identity.board not in released.boards:
        raise StreamError("board absent from released kernel validation")
    with tarfile.open(artifacts["rootfs.tar"], "r:") as archive:
        if any(member.name.removeprefix("./").startswith("var/cache/apt/archives/")
               and member.name.endswith(".deb") for member in archive):
            raise StreamError("emitted tar retains downloaded package archives")
    for script, args in (
        ("lib/measure-size.sh", [identity.board, str(artifacts["rootfs.tar"])]),
        ("lib/verify-boot-artifacts.sh", [str(artifacts["rootfs.tar"]), "--dtb-name", params["DTB_NAME"]]),
        ("lib/check-firmware-closure.sh", [str(artifacts["rootfs.tar"])]),
    ):
        subprocess.run(["bash", str(source / script), *args], check=True, env=env, timeout=600,
                       stdout=subprocess.DEVNULL)
    compiled = HOME / "compiled-boot"
    compiled.mkdir()
    boot_env = env | {"BOARD_ID": params["BOARD_ID"], "DTB_NAME": params["DTB_NAME"],
                      "SERIAL_CONSOLE": params["SERIAL_CONSOLE"],
                      "COMPATIBLE_STRING": "ceralive-" + params["BOARD_ID"],
                      "SINGLE_SLOT_FALLBACK": "false"}
    subprocess.run(["bash", str(source / "mkosi/platform/boot/install-boot.sh"),
                    "boot-payload", str(compiled)], check=True, env=boot_env, timeout=60)
    boot = {}
    for name in ("boot.scr", "boot.scr.sha256"):
        if digest_file(compiled / name) != digest_file(artifacts[name]):
            raise StreamError("returned boot payload differs from approved source")
        boot["usr/lib/ceralive/boot/" + name] = compiled / name
    slots = []
    for label in ("rootfs_a", "rootfs_b"):
        image = artifacts[label + ".ext4"]
        subprocess.run(["e2fsck", "-fn", str(image)], check=True, env=env, timeout=300,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        reserve = subprocess.run(["bash", "-euo", "pipefail", "-c",
            'source "$1"; slot_reserve_assert_ext4 "$2" "$3"', "_",
            str(source / "lib/shared/slot-reserve.sh"), str(image), label],
            check=True, env=env, capture_output=True, text=True, timeout=60).stdout
        if reserve != artifacts[label + ".reserve"].read_text():
            raise StreamError("returned reserve evidence disagrees with actual slot")
        header = subprocess.run(["dumpe2fs", "-h", str(image)], check=True, env=env,
                                capture_output=True, text=True, timeout=60).stdout
        if header.rstrip("\n") + "\n" != artifacts[label + ".header"].read_text():
            raise StreamError("returned clean filesystem header disagrees with actual slot")
        fields = dict(line.split(":", 1) for line in header.splitlines() if ":" in line)
        if fields.get("Filesystem volume name", "").strip() != label:
            raise StreamError("slot filesystem label differs from frozen production label")
        uuid = subprocess.run(["bash", "-euo", "pipefail", "-c",
            'source "$1"; det_uuid "$2"', "_", str(source / "lib/disk/slot-image.sh"),
            "ceralive-" + params["BOARD_ID"] + "-" + label], check=True, env=env,
            capture_output=True, text=True, timeout=60).stdout
        if fields.get("Filesystem UUID", "").strip() != uuid:
            raise StreamError("slot filesystem UUID differs from existing writer contract")
        mount = HOME / label
        mount.mkdir()
        subprocess.run(["mount", "-o", "loop,ro,noload,nodev,nosuid,noexec", str(image), str(mount)],
                       check=True, env=env, timeout=60)
        try:
            compare_slot(mount, artifacts["rootfs.tar"], boot)
            subprocess.run(["bash", str(source / "lib/parity-check.sh"), str(mount)],
                           check=True, env=env, timeout=300, stdout=subprocess.DEVNULL)
            lock = json.loads(artifacts["packages.lock.json"].read_text())
            parser = runpy.run_path(str(source / "lib/packages-lock.py"))["installed_packages"]
            installed = parser(mount / "var/lib/dpkg/status")
            if sorted((row["name"], row["version"], row["arch"]) for row in installed) != sorted(
                    (row["name"], row["version"], row["arch"]) for row in lock["packages"]):
                raise StreamError("returned package lock disagrees with installed slot")
            kernels = [row for row in lock["packages"] if row["name"].startswith("linux-image-")]
            if len(kernels) != 1 or (kernels[0]["name"], kernels[0]["version"], kernels[0]["sha256"],
                                    kernels[0]["origin"]) != (
                    released.identity.package, released.identity.version,
                    released.identity.deb_sha256, "ceralive-kernel"):
                raise StreamError("installed kernel lock differs from authenticated released identity")
            if digest_file(mount / "etc/rauc/ceralive-keyring.pem") != digest_file(inputs / capsule.device_root):
                raise StreamError("installed device root bytes differ from approved public root")
            removed = ("amdgpu", "radeon", "i915", "xe", "mellanox", "netronome", "intel/ipu", "intel/vsc")
            retained = ("brcm", "rtl_bt", "rtw88", "rtw89", "rockchip", "mediatek", "mrvl", "mrvl/prestera", "nvidia")
            firmware = mount / "usr/lib/firmware"
            retry_check(check_firmware, firmware, removed, retained)
            references = subprocess.run(["bash", "-euo", "pipefail", "-c",
                'source "$1"; firmware_sweep_module_refs "$2"', "_",
                str(source / "mkosi/customize/firmware-sweep.sh"), str(mount)],
                check=True, env=env, capture_output=True, text=True, timeout=300).stdout
            nouveau = [line for line in references.splitlines()
                       if line.startswith("nvidia/") and "nouveau.ko" in line]
            if not nouveau:
                raise StreamError("ceralive8 retained nvidia lacks its actual installed Nouveau reference")
            slots.append({"slot": label, "reserve": reserve.strip(), "removed": list(removed),
                          "retained": list(retained), "nvidia_references": nouveau})
        finally:
            subprocess.run(["umount", str(mount)], check=True, env=env, timeout=60)
    result = HOME / "verification.json"
    result.write_text(json.dumps({"schema": 1, "verified": True, "build_identity": asdict(identity),
                                  "artifacts": job["artifacts"], "slots": slots}) + "\n")
    return [("verification.json", result)]
