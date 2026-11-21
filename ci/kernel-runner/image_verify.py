"""Independent data-only verification in a fresh offline overlay."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import runpy
import stat
import subprocess
import tarfile

from image_capsule import Capsule, digest_file
from image_stream import Identity, StreamError, list_directory, listed_entry, retry_check, unique_object
from vm_process import reset_child_status, run as run_gate

FIRMWARE_FLOOR = frozenset({"brcm", "rtl_bt", "rtw88", "rtw89", "rockchip", "mediatek", "mrvl", "mrvl/prestera"})


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


def approved_modules(modules: bytes, digest: str) -> list[str]:
    """Read the released module inventory only after checking the independent policy pin."""
    if hashlib.sha256(modules).hexdigest() != digest:
        raise StreamError("module inventory differs from independently approved release")
    paths = modules.decode("ascii").splitlines()
    if not paths or not all(firmware_path(path) and path.endswith(".ko") for path in paths):
        raise StreamError("invalid released module inventory")
    return sorted({path.rsplit("/", 1)[-1] for path in paths})


def firmware_path(path: str) -> bool:
    return (re.fullmatch(r"[A-Za-z0-9_.,+/-]+", path) is not None
            and not {"", ".", ".."}.intersection(path.split("/")))


def candidate_consumers(candidates: list[str], references: list[str]) -> dict[str, list[str]]:
    """Project exact reader rows to the module names responsible for each candidate."""
    consumers: dict[str, set[str]] = {candidate: set() for candidate in candidates}
    for row in references:
        path, _, owner = row.partition("\t")
        leaf = owner.rsplit("/", 1)[-1]
        module = re.fullmatch(r"([A-Za-z0-9_-]+)\.ko(?:\.(?:xz|zst|gz))?", leaf)
        builtin = re.fullmatch(r"([A-Za-z0-9_]+(?::[A-Za-z0-9_]+)*) \(built-in\)", owner)
        matched = [name for name in candidates if path == name or path.startswith(name + "/")]
        if not firmware_path(path) or not matched or not ((module and firmware_path(owner)) or builtin):
            raise StreamError("invalid candidate firmware reference")
        names = [module[1]] if module else builtin[1].split(":")
        for candidate in matched:
            consumers[candidate].update(names)
    return {name: sorted(names) for name, names in consumers.items()}


def check_nouveau_evidence(expected: bool, references: list[str]) -> None:
    nouveau = [row for row in references if re.search(r"(?:\t|/)nouveau\.ko(?:\.(?:xz|zst|gz))?$", row)]
    if (expected and not any(row.startswith("nvidia/") for row in nouveau)) or (not expected and nouveau):
        raise StreamError("Nouveau firmware proof differs from the approved module inventory")


def firmware_rows(refs: list[str], candidates: list[str]) -> list[str]:
    """Select the flat receipt rows directly from the reader output."""
    rows = []
    for row in refs:
        path = row.partition("\t")[0]
        if any(path == name or path.startswith(name + "/") for name in candidates):
            rows.append(row)
    return sorted(rows)


def check_firmware(source: Path, slot: Path, params: dict[str, str],
                   env: dict[str, str], nouveau_present: bool) -> dict:
    """Check sweep results; the tar closure gate checks individual firmware objects."""
    firmware = slot / "usr/lib/firmware"
    scan = run_gate(["bash", "-euo", "pipefail", "-c",
        'source "$1"; firmware_sweep_module_refs "$2"; '
        'moddir="$2/usr/lib/modules"; [[ -d "$moddir" ]] || moddir="$2/lib/modules"; '
        'find "$moddir" -type f -name "*.ko*" -printf "\\t%f\\n"', "_",
        str(source / "mkosi/customize/firmware-sweep.sh"), str(slot)],
        env=env, capture_output=True, text=True, timeout=300).stdout.splitlines()
    refs = [line for line in scan if not line.startswith("\t")]
    modules = sorted(re.sub(r"\.(?:xz|zst|gz)$", "", line.rsplit("/", 1)[-1].lstrip("\t"))
                     for line in scan if line.startswith("\t"))
    if not refs:
        raise StreamError("found no installed-module or built-in firmware references")
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
    retained = set(FIRMWARE_FLOOR)
    preserved = params["FIRMWARE_PRESERVED_ROOTS"].split()
    for name in preserved:
        if any(path == name or path.startswith(name + "/") for path in owned):
            retained.add(name)
    decisions = dict.fromkeys(preserved, False)
    for name in sorted(retained):
        info = listed_entry(firmware, name)
        decisions[name] = info is not None and stat.S_ISDIR(info.st_mode)
        if not decisions[name]:
            raise StreamError(f"preserved firmware directory is absent: {name}")
    removed = set()
    sweep_rows = {}
    candidate_types = {}
    prefixes = set(params["FIRMWARE_SWEEP_PREFIXES"].split())
    candidates = (params["FIRMWARE_SWEEP_PREFIXES"] + " " + params["FIRMWARE_SWEEP_FILES"]).split()
    for name in candidates:
        matched = [(path, line) for path, line in references if path == name or path.startswith(name + "/")]
        sweep_rows[name] = sorted(line for _, line in matched)
        runtime = any(path == name or path.startswith(name + "/") for path in bluetooth)
        info = listed_entry(firmware, name)
        present = info is not None
        decisions[name] = present
        if info is not None:
            kind = ("directory" if stat.S_ISDIR(info.st_mode)
                    else "file" if stat.S_ISREG(info.st_mode) else "other")
            expected = "directory" if name in prefixes else "file"
            if kind != expected:
                raise StreamError(f"retained firmware candidate is not a {expected}: {name}")
            candidate_types[name] = kind
            if not matched and not runtime:
                raise StreamError(f"firmware sweep left an unreferenced candidate: {name}")
            retained.add(name)
        else:
            # The sweep protects the whole candidate, even if the particular
            # requested file was never packaged.
            if runtime or (matched and any(path == name or path.startswith(name + "/") for path in owned)):
                raise StreamError(f"firmware sweep removed a referenced candidate: {name}")
            removed.add(name)
    consumers = {name: candidate_consumers([name], rows)[name] for name, rows in sweep_rows.items()}
    evidence = firmware_rows(refs, candidates)
    check_nouveau_evidence(nouveau_present, evidence)
    return {"removed": sorted(removed), "retained": sorted(retained), "firmware_references": evidence,
            "candidate_consumers": consumers, "nouveau_present": nouveau_present,
            "examined_firmware_references": len(refs), "examined_modules": modules,
            "retention_scan": {"candidate_rows": sweep_rows, "present": decisions, "candidate_types": candidate_types,
                               "examined_firmware_references": len({row for _, row in references})}}


def kernel_receipt(kernel: tuple[str, str, str], digest: str) -> dict[str, str]:
    package, version, arch = kernel
    return {"name": package, "version": version, "arch": arch, "sha256": digest,
            "origin": "measurement-candidate"}


def check_kernel_lock(packages: list[dict[str, str]], expected: tuple[str, str, str], digest: str, *,
                      origin: str = "ceralive-kernel") -> None:
    if type(packages) is not list or any(type(row) is not dict or type(row.get("name")) is not str
                                        for row in packages):
        raise StreamError("invalid installed package lock entries")
    kernels = [row for row in packages if row["name"].startswith("linux-image-")]
    keys = ("name", "version", "arch", "sha256", "origin")
    if (origin not in ("ceralive-kernel", "measurement-candidate") or len(kernels) != 1
            or kernels[0].keys() != set(keys)
            or tuple(kernels[0][key] for key in keys) != (*expected, digest, origin)):
        label = "released" if origin == "ceralive-kernel" else "candidate"
        raise StreamError(f"installed kernel lock differs from the approved {label} identity")


def checked_lock(lock: dict, epoch: int, *, origin: str = "ceralive-kernel") -> list[dict[str, str]]:
    """Validate a measurement lock before using any of its rows."""
    if (type(lock) is not dict or lock.keys() != {"built_at", "source_date_epoch", "packages", "debian_release_dates"}
            or type(lock["source_date_epoch"]) is not int or lock["source_date_epoch"] != epoch
            or type(lock["built_at"]) is not str
            or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", lock["built_at"])
            or type(lock["debian_release_dates"]) is not dict or not lock["debian_release_dates"]
            or any(not suite or type(date) is not str or not date
                   for suite, date in lock["debian_release_dates"].items())
            or type(lock["packages"]) is not list or not lock["packages"]):
        raise StreamError("invalid released measurement lock")
    identities = set()
    for row in lock["packages"]:
        if (type(row) is not dict or row.keys() != {"name", "version", "arch", "origin", "sha256"}
                or any(type(value) is not str or not value for value in row.values())
                or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"])
                or (row["origin"] == "measurement-candidate"
                    and (origin != "measurement-candidate" or not row["name"].startswith("linux-image-")))):
            raise StreamError("invalid released package lock entry")
        key = row["name"], row["arch"]
        if key in identities:
            raise StreamError("duplicate installed package lock entry")
        identities.add(key)
    return lock["packages"]


def verify(source: Path, capsule: Capsule, job: dict) -> list[tuple[str, Path]]:
    reset_child_status()
    from image_candidate_policy import FIELD, KIND
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
    trust = job["trust"]
    metadata = HOME / "approved-kernel"
    if FIELD in trust:
        pins = trust[FIELD]["payloads"]
        package, version, arch = expected_kernel
        kernel_digest = pins.get(f"{package}_{version}_{arch}.deb", {}).get("sha256")
        observed = run_gate(["python3", str(source / "lib/measurement-candidate.py"), "stage",
                             str(inputs), capsule.board, package, version, arch, str(metadata)],
                            env=env | {"CERALIVE_BUILD_PURPOSE": "rootfs-measurement"},
                            timeout=1200, capture_output=True, text=True).stdout.strip()
        if kernel_digest is None or observed != kernel_digest:
            raise StreamError("candidate verifier staged different kernel bytes")
        kernel_origin = KIND
        approved_metadata = {name: pins[name]["sha256"] for name in KERNEL_METADATA}
    else:
        approved_metadata = trust["kernel_metadata"]
        kernel_digest = stage_kernel_metadata(source, capsule, params, approved_metadata, metadata)
        kernel_origin = "ceralive-kernel"
    modules = approved_modules((metadata / "built-modules.txt").read_bytes(), approved_metadata["built-modules.txt"])
    for name in KERNEL_METADATA:
        supplied = artifacts["kernel.SHA256SUMS" if name == "SHA256SUMS" else name]
        if digest_file(supplied) != approved_metadata[name]:
            label = "release" if kernel_origin == "ceralive-kernel" else "candidate"
            raise StreamError(f"returned kernel metadata differs from independently selected {label}")
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
            locked = checked_lock(
                json.loads(artifacts["packages.lock.json"].read_text(), object_pairs_hook=unique_object),
                identity.epoch, origin=kernel_origin)
            check_kernel_lock(locked, expected_kernel, kernel_digest, origin=kernel_origin)
            parser = runpy.run_path(str(source / "lib/packages-lock.py"))["installed_packages"]
            installed = parser(mount / "var/lib/dpkg/status")
            if sorted((row["name"], row["version"], row["arch"]) for row in installed) != sorted(
                    (row["name"], row["version"], row["arch"]) for row in locked):
                raise StreamError("returned package lock disagrees with installed slot")
            if digest_file(mount / "etc/rauc/ceralive-keyring.pem") != digest_file(inputs / capsule.device_root):
                raise StreamError("installed device root bytes differ from approved public root")
            firmware = retry_check(check_firmware, source, mount, params, env, "nouveau.ko" in modules)
            slots.append({"slot": label, "reserve": reserve.strip(), **firmware})
        finally:
            run_gate(["umount", str(mount)], env=env, timeout=60)
    result = HOME / "verification.json"
    row = {"schema": 1, "verified": True, "build_identity": asdict(identity),
           "artifacts": job["artifacts"], "slots": slots}
    if kernel_origin == KIND:
        row["kernel"] = kernel_receipt(expected_kernel, kernel_digest)
    result.write_text(json.dumps(row) + "\n")
    return [("verification.json", result)]
