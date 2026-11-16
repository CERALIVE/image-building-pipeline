#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# How to run: python3 lib/firmware-closure.py <rootfs.tar|root-directory> <exceptions>
"""Check final firmware closure, sharing the sweep's installed/built-in reader."""

from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile


class ClosureError(RuntimeError):
    """The supplied rootfs cannot establish firmware closure."""


@dataclass(frozen=True, slots=True)
class Entry:
    directory: bool = False
    regular: bool = False
    link: str | None = None
    hardlink: bool = False


def relative_path(value: str) -> str:
    """Require an exact relative object name, without patterns or traversal."""
    if (
        not value or value.startswith("/") or
        any(part in {"", ".", ".."} for part in value.split("/")) or
        any(c.isspace() or c in "*?[]\0" for c in value)
    ):
        raise ClosureError(f"invalid object path: {value!r}")
    return value


def firmware_name(value: str) -> str:
    """Package manifests may own the compressed spelling of a static reference."""
    return relative_path(value.removesuffix(".zst").removesuffix(".xz"))


class Rootfs:
    """Index without host symlink traversal; copy only modules into private scratch."""

    def __init__(self, path: Path, stack: ExitStack) -> None:
        self.path = path
        self.archive: tarfile.TarFile | None = None
        self.members: dict[str, tarfile.TarInfo] = {}
        self.entries: dict[str, Entry] = {"": Entry(directory=True)}
        self.children: dict[str, set[str]] = {}
        if path.is_dir():
            self.scan(path, "")
        else:
            # GNU tar's status must not disappear behind process substitution.
            subprocess.run(["tar", "-tf", str(path)], stdout=subprocess.DEVNULL, check=True)
            self.archive = stack.enter_context(tarfile.open(path, "r:*"))
            for member in self.archive:
                name = member.name.removeprefix("./").rstrip("/")
                if not name or name == ".":
                    continue
                if name.startswith("/") or any(part in {"", ".."} for part in name.split("/")):
                    raise ClosureError(f"unsafe artifact member: {name!r}")
                if name in self.entries:
                    raise ClosureError(f"duplicate artifact member: {name}")
                self.members[name] = member
                self.entries[name] = Entry(
                    directory=member.isdir(), regular=member.isfile(),
                    link=member.linkname if member.issym() or member.islnk() else None,
                    hardlink=member.islnk(),
                )
        for name in tuple(self.entries):
            if name:
                parent = str(PurePosixPath(name).parent)
                self.children.setdefault("" if parent == "." else parent, set()).add(name)

    def scan(self, directory: Path, prefix: str) -> None:
        """scandir propagates traversal failures, unlike permissive glob helpers."""
        if directory.stat().st_mode & 0o555 == 0:
            raise ClosureError(f"unreadable directory inventory: {directory}")
        with os.scandir(directory) as entries:
            for item in entries:
                name = f"{prefix}/{item.name}".lstrip("/")
                mode = item.stat(follow_symlinks=False).st_mode
                self.entries[name] = Entry(
                    directory=stat.S_ISDIR(mode), regular=stat.S_ISREG(mode),
                    link=os.readlink(item.path) if stat.S_ISLNK(mode) else None,
                )
                if stat.S_ISDIR(mode):
                    self.scan(Path(item.path), name)

    def resolve(self, name: str) -> str:
        """Resolve runtime absolute links inside the rootfs, never against the host."""
        pending = name.split("/")
        parts: list[str] = []
        links = 0
        while pending:
            part = pending.pop(0)
            if part in {"", "."}:
                continue
            if part == "..":
                if not parts:
                    raise ClosureError(f"symlink escapes rootfs: {name}")
                parts.pop()
                continue
            parts.append(part)
            current = "/".join(parts)
            entry = self.entries.get(current)
            if entry is None:
                raise FileNotFoundError(current)
            if entry.link is not None:
                links += 1
                if links > 40:
                    raise ClosureError(f"symlink cycle: {name}")
                target = entry.link
                parts.pop()
                if target.startswith("/") or entry.hardlink:
                    parts = []
                pending = target.split("/") + pending
            elif pending and not entry.directory:
                raise ClosureError(f"non-directory path component: {current}")
        return "/".join(parts)

    def files(
        self, directory: str, ancestors: tuple[str, ...] = (), *, module_inventory: bool = False,
    ) -> list[str]:
        """Enumerate runtime directory aliases while refusing loops and lost entries."""
        resolved = self.resolve(directory)
        if resolved in ancestors:
            raise ClosureError(f"directory cycle: {directory}")
        if not self.entries[resolved].directory:
            raise ClosureError(f"inventory is not a directory: {directory}")
        result: list[str] = []
        for child in sorted(self.children.get(resolved, ())):
            leaf = PurePosixPath(child).name
            # Kernel development links do not contain the installed driver tree.
            if module_inventory and len(ancestors) == 1 and leaf in {"build", "source"} and self.entries[child].link is not None:
                continue
            logical = f"{directory}/{leaf}"
            canonical = self.resolve(logical)
            if self.entries[canonical].directory:
                result.extend(self.files(logical, (*ancestors, resolved), module_inventory=module_inventory))
            else:
                result.append(logical)
        return result

    def copy(self, name: str, destination: Path) -> None:
        """Read only a resolved regular file; no archive paths become host paths."""
        resolved = self.resolve(name)
        if not self.entries[resolved].regular:
            raise ClosureError(f"not a regular rootfs file: {name}")
        with ExitStack() as stack:
            if self.archive is None:
                source = self.path / resolved
                if source.stat().st_mode & 0o444 == 0:
                    raise ClosureError(f"unreadable inventory file: {name}")
                handle = stack.enter_context(source.open("rb"))
            else:
                extracted = self.archive.extractfile(self.members[resolved])
                if extracted is None:
                    raise ClosureError(f"unreadable artifact member: {name}")
                handle = stack.enter_context(extracted)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("wb") as output:
                shutil.copyfileobj(handle, output)

    def present(self, name: str) -> bool:
        """A dangling link is absent, whereas traversal and cycles are fatal."""
        try:
            return self.entries[self.resolve(name)].regular
        except FileNotFoundError:
            return False


def check(artifact: Path, exceptions_file: Path) -> None:
    """Check every static reference against all dpkg-owned firmware paths."""
    exceptions: dict[str, str] = {}
    for line in exceptions_file.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 2 or not fields[1].strip():
            raise ClosureError("exceptions require path<TAB>reason")
        path = relative_path(fields[0])
        if path in exceptions:
            raise ClosureError(f"duplicate exception: {path}")
        exceptions[path] = fields[1]
    with ExitStack() as stack:
        tree = Rootfs(artifact, stack)
        work = Path(stack.enter_context(tempfile.TemporaryDirectory()))
        module_root = "usr/lib/modules"
        if module_root not in tree.entries:
            module_root = "lib/modules"
        module_root = tree.resolve(module_root)
        try:
            legacy_root = tree.resolve("lib/modules")
        except FileNotFoundError:
            legacy_root = module_root
        if legacy_root != module_root:
            raise ClosureError("conflicting /lib/modules and /usr/lib/modules inventories")
        modules = tree.files(module_root, module_inventory=True)
        releases = {PurePosixPath(name).relative_to(module_root).parts[0] for name in modules}
        for release in releases:
            if not any(f"{module_root}/{release}/{leaf}" in modules for leaf in ("modules.builtin", "modules.builtin.modinfo")):
                raise ClosureError(f"missing built-in inventory for {release}")
        drivers = 0
        for name in modules:
            leaf = PurePosixPath(name).name
            if ".ko" in leaf or leaf in {"modules.builtin", "modules.builtin.modinfo"}:
                target = work / "usr/lib/modules" / PurePosixPath(name).relative_to(module_root)
                tree.copy(name, target)
                if leaf == "modules.builtin":
                    data = target.read_bytes()
                    if b"\0" in data or (data and not data.endswith(b"\n")):
                        raise ClosureError(f"truncated or malformed built-in list: {name}")
                if ".ko" in leaf or target.stat().st_size > 0:
                    drivers += 1
        if not drivers:
            raise ClosureError("no modules found in kernel inventory")
        collector = Path(__file__).parent.parent / "mkosi/customize/firmware-sweep.sh"
        refs = subprocess.run(
            ["bash", "-euo", "pipefail", "-c",
             'source "$1"; firmware_sweep_module_refs "$2"', "_", str(collector), str(work)],
            capture_output=True, text=True, check=False,
        )
        if refs.returncode:
            raise ClosureError(f"incomplete or unreadable module inventory: {refs.stderr.strip()}")
        lists = [name for name in tree.files("var/lib/dpkg/info") if name.endswith(".list")]
        if not lists:
            raise ClosureError("no dpkg *.list inventory")
        shipped: set[str] = set()
        for name in lists:
            tree.copy(name, work / "package.list")
            data = (work / "package.list").read_text()
            if "\0" in data or (data and not data.endswith("\n")):
                raise ClosureError(f"truncated or malformed dpkg list: {name}")
            for path in data.splitlines():
                path = path.removeprefix("/")
                if path.startswith("usr/lib/firmware/"):
                    shipped.add(firmware_name(path.removeprefix("usr/lib/firmware/")))
        checked = never_shipped = missing = 0
        for row in refs.stdout.splitlines():
            fields = row.split("\t", 1)
            if len(fields) != 2:
                raise ClosureError(f"malformed firmware reference record: {row!r}")
            ref, module = fields
            relative_path(ref)
            checked += 1
            if firmware_name(ref) not in shipped:
                never_shipped += 1
                print(f"firmware closure: never-shipped {module}: {ref}")
            elif not any(tree.present(f"usr/lib/firmware/{ref}{suffix}") for suffix in ("", ".zst", ".xz")):
                if ref in exceptions:
                    print(f"firmware closure: exception {module}: {ref}: {exceptions[ref]}")
                else:
                    missing += 1
                    print(f"firmware closure: MISSING {module}: {ref}", file=sys.stderr)
        print(f"firmware closure: checked={checked} never-shipped={never_shipped} missing={missing}")
        if missing:
            raise ClosureError(f"{missing} shipped driver firmware reference(s) absent")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ClosureError("usage: firmware-closure.py <rootfs> <exceptions>")
        check(Path(sys.argv[1]), Path(sys.argv[2]))
    except (ClosureError, OSError, UnicodeError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(f"firmware closure: FATAL: {error}", file=sys.stderr)
        sys.exit(1)
