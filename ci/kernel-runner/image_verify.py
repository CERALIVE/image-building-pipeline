"""Independent data-only verification in a fresh offline overlay."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import runpy
import stat
import subprocess
import tarfile

from image_capsule import Capsule, digest_file
from image_stream import Identity, StreamError, list_directory, listed_entry, retry_check
from vm_process import reset_child_status, run as run_gate


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


def check_firmware(source: Path, slot: Path, params: dict[str, str],
                   env: dict[str, str]) -> dict[str, list[str]]:
    """Check sweep results; the tar closure gate checks individual firmware objects."""
    firmware = slot / "usr/lib/firmware"
    refs = run_gate(["bash", "-euo", "pipefail", "-c",
        'source "$1"; firmware_sweep_module_refs "$2"', "_",
        str(source / "mkosi/customize/firmware-sweep.sh"), str(slot)],
        env=env, capture_output=True, text=True, timeout=300).stdout.splitlines()
    bluetooth = run_gate(["bash", "-euo", "pipefail", "-c",
        'source "$1"; bluetooth_firmware_load "$2"; bluetooth_firmware_snapshot "$3"; '
        'printf "%s\\n" "${BT_FW_OBJECTS[@]}"', "_",
        str(source / "mkosi/customize/bluetooth-firmware.sh"),
        str(source / "manifests/rk3588-bluetooth-firmware-roots.txt"), str(firmware)],
        env=env, capture_output=True, text=True, timeout=300).stdout.splitlines()
    owners = (slot / "var/lib/dpkg/info/armbian-firmware-full.list").read_text().splitlines()
    owned = {line.removeprefix("/usr/lib/firmware/").removesuffix(".zst").removesuffix(".xz")
             for line in owners if line.startswith("/usr/lib/firmware/")}
    references = [(line.split("\t", 1)[0], line) for line in refs]
    # The existing RK3588 retention floor includes Marvell and six populated
    # roots. The registry may also protect roots not shipped by this archive.
    retained = {"brcm", "rtl_bt", "rtw88", "rtw89", "rockchip", "mediatek", "mrvl", "mrvl/prestera"}
    for name in params["FIRMWARE_PRESERVED_ROOTS"].split():
        if any(path == name or path.startswith(name + "/") for path in owned):
            retained.add(name)
    for name in sorted(retained):
        info = listed_entry(firmware, name)
        if info is None or not stat.S_ISDIR(info.st_mode):
            raise StreamError(f"preserved firmware directory is absent: {name}")
    removed = set()
    proof = set()
    candidates = (params["FIRMWARE_SWEEP_PREFIXES"] + " " + params["FIRMWARE_SWEEP_FILES"]).split()
    for name in candidates:
        matched = [(path, line) for path, line in references if path == name or path.startswith(name + "/")]
        runtime = any(path == name or path.startswith(name + "/") for path in bluetooth)
        present = listed_entry(firmware, name) is not None
        if present:
            if not matched and not runtime:
                raise StreamError(f"firmware sweep left an unreferenced candidate: {name}")
            retained.add(name)
            proof.update(line for _, line in matched)
        else:
            if runtime or any(path.removesuffix(".zst").removesuffix(".xz") in owned for path, _ in matched):
                raise StreamError(f"firmware sweep removed a referenced candidate: {name}")
            removed.add(name)
    return {"removed": sorted(removed), "retained": sorted(retained), "firmware_references": sorted(proof)}


def check_kernel_lock(packages: list[dict[str, str]], expected: tuple[str, str, str], digest: str) -> None:
    kernels = [row for row in packages if row["name"].startswith("linux-image-")]
    if len(kernels) != 1 or tuple(kernels[0].get(key) for key in ("name", "version", "arch", "sha256", "origin")) != (
        *expected, digest, "ceralive-kernel"
    ):
        raise StreamError("installed kernel lock differs from the approved released identity")


def verify(source: Path, capsule: Capsule, job: dict) -> list[tuple[str, Path]]:
    reset_child_status()
    from image_guest import HOME, KERNEL_METADATA, kernel_identity, resolve, stage_kernel_metadata
    inputs = capsule.directory
    identity = Identity(**job["build_identity"])
    artifacts = {name: inputs / digest for name, digest in job["artifacts"].items()}
    env = {"PATH": os.environ["PATH"], "HOME": str(HOME), "LANG": "C.UTF-8",
           "LC_ALL": "C", "SOURCE_DATE_EPOCH": str(identity.epoch),
           "APT_GPG_PUBLIC_B64": "sealed-public-trust", "CERALIVE_BUILD_MODE": "production"}
    params = resolve(source, capsule.board, env)
    if json.loads(artifacts["resolved.json"].read_text()) != params:
        raise StreamError("returned resolver output differs from approved source")
    run_gate(["bash", "-euo", "pipefail", "-c",
        'source "$1"; rauc_public_root_resolve "$2" "$3"', "_",
        str(source / "lib/rauc-pki-contract.sh"), str(inputs / capsule.device_root),
        job["trust"]["root_der_sha256"]], env=env, capture_output=True)
    measurement = json.loads(artifacts["measurement.json"].read_text())
    if measurement["public_root_der_sha256"] != job["trust"]["root_der_sha256"]:
        raise StreamError("returned public device trust identity mismatch")
    expected_kernel = kernel_identity(params)
    if measurement["kernel_version"] != expected_kernel[1]:
        raise StreamError("returned measurement kernel version differs from approved source")
    metadata = HOME / "released-kernel"
    kernel_digest = stage_kernel_metadata(source, capsule, params, job["trust"]["kernel_metadata"], metadata)
    for name in KERNEL_METADATA:
        supplied = artifacts["kernel.SHA256SUMS" if name == "SHA256SUMS" else name]
        if digest_file(supplied) != job["trust"]["kernel_metadata"][name]:
            raise StreamError("returned kernel metadata differs from independently selected release")
    with tarfile.open(artifacts["rootfs.tar"], "r:") as archive:
        if any(member.name.removeprefix("./").startswith("var/cache/apt/archives/")
               and member.name.endswith(".deb") for member in archive):
            raise StreamError("emitted tar retains downloaded package archives")
    for script, args in (
        ("lib/measure-size.sh", [identity.board, str(artifacts["rootfs.tar"])]),
        ("lib/verify-boot-artifacts.sh", [str(artifacts["rootfs.tar"]), "--dtb-name", params["DTB_NAME"]]),
        ("lib/check-firmware-closure.sh", [str(artifacts["rootfs.tar"])]),
    ):
        run_gate(["bash", str(source / script), *args], env=env, timeout=600,
                 stdout=subprocess.DEVNULL)
    compiled = HOME / "compiled-boot"
    compiled.mkdir()
    boot_env = env | {"BOARD_ID": params["BOARD_ID"], "DTB_NAME": params["DTB_NAME"],
                      "SERIAL_CONSOLE": params["SERIAL_CONSOLE"],
                      "COMPATIBLE_STRING": "ceralive-" + params["BOARD_ID"],
                      "SINGLE_SLOT_FALLBACK": "false"}
    run_gate(["bash", str(source / "mkosi/platform/boot/install-boot.sh"),
                    "boot-payload", str(compiled)], env=boot_env, timeout=60)
    boot = {}
    for name in ("boot.scr", "boot.scr.sha256"):
        if digest_file(compiled / name) != digest_file(artifacts[name]):
            raise StreamError("returned boot payload differs from approved source")
        boot["usr/lib/ceralive/boot/" + name] = compiled / name
    slots = []
    for label in ("rootfs_a", "rootfs_b"):
        image = artifacts[label + ".ext4"]
        run_gate(["e2fsck", "-fn", str(image)], env=env, timeout=300,
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        reserve = run_gate(["bash", "-euo", "pipefail", "-c",
            'source "$1"; slot_reserve_assert_ext4 "$2" "$3"', "_",
            str(source / "lib/shared/slot-reserve.sh"), str(image), label],
            env=env, capture_output=True, text=True, timeout=60).stdout
        if reserve != artifacts[label + ".reserve"].read_text():
            raise StreamError("returned reserve evidence disagrees with actual slot")
        header = run_gate(["dumpe2fs", "-h", str(image)], env=env,
                          capture_output=True, text=True, timeout=60).stdout
        if header.rstrip("\n") + "\n" != artifacts[label + ".header"].read_text():
            raise StreamError("returned clean filesystem header disagrees with actual slot")
        fields = dict(line.split(":", 1) for line in header.splitlines() if ":" in line)
        if fields.get("Filesystem volume name", "").strip() != label:
            raise StreamError("slot filesystem label differs from frozen production label")
        uuid = run_gate(["bash", "-euo", "pipefail", "-c",
            'source "$1"; det_uuid "$2"', "_", str(source / "lib/disk/slot-image.sh"),
            "ceralive-" + params["BOARD_ID"] + "-" + label], env=env,
            capture_output=True, text=True, timeout=60).stdout
        if fields.get("Filesystem UUID", "").strip() != uuid:
            raise StreamError("slot filesystem UUID differs from existing writer contract")
        mount = HOME / label
        mount.mkdir()
        run_gate(["mount", "-o", "loop,ro,noload,nodev,nosuid,noexec", str(image), str(mount)],
                 env=env, timeout=60)
        try:
            compare_slot(mount, artifacts["rootfs.tar"], boot)
            run_gate(["bash", str(source / "lib/parity-check.sh"), str(mount)],
                     env=env, timeout=300, stdout=subprocess.DEVNULL)
            lock = json.loads(artifacts["packages.lock.json"].read_text())
            parser = runpy.run_path(str(source / "lib/packages-lock.py"))["installed_packages"]
            installed = parser(mount / "var/lib/dpkg/status")
            if sorted((row["name"], row["version"], row["arch"]) for row in installed) != sorted(
                    (row["name"], row["version"], row["arch"]) for row in lock["packages"]):
                raise StreamError("returned package lock disagrees with installed slot")
            check_kernel_lock(lock["packages"], expected_kernel, kernel_digest)
            if digest_file(mount / "etc/rauc/ceralive-keyring.pem") != digest_file(inputs / capsule.device_root):
                raise StreamError("installed device root bytes differ from approved public root")
            firmware = retry_check(check_firmware, source, mount, params, env)
            slots.append({"slot": label, "reserve": reserve.strip(), **firmware})
        finally:
            run_gate(["umount", str(mount)], env=env, timeout=60)
    result = HOME / "verification.json"
    result.write_text(json.dumps({"schema": 1, "verified": True, "build_identity": asdict(identity),
                                  "artifacts": job["artifacts"], "slots": slots}) + "\n")
    return [("verification.json", result)]
