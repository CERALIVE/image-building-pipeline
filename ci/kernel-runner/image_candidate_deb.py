"""Inspect the candidate deb's data archive without extracting its members."""

from os import SEEK_END
from pathlib import Path, PurePosixPath
import posixpath
import subprocess
import tarfile
import tempfile
from typing import BinaryIO

from image_capsule import INPUT_LIMIT
from image_stream import StreamError
from vm_process import run as run_gate

BLOCK = tarfile.BLOCKSIZE
REGULAR = (tarfile.REGTYPE, tarfile.AREGTYPE)
TYPES = {
    tarfile.SYMTYPE: "symlink",
    tarfile.LNKTYPE: "hardlink",
    tarfile.FIFOTYPE: "fifo",
    tarfile.DIRTYPE: "directory",
    tarfile.CHRTYPE: "device",
    tarfile.BLKTYPE: "device",
}


def archive_error(reason: str) -> StreamError:
    return StreamError(f"measurement-candidate kernel deb data archive rejected: {reason}")


def member_error(board: str, observed: str) -> StreamError:
    return StreamError(f"measurement-candidate kernel deb board check failed: {board}; "
                       f"DTB member pinned=regular observed={observed}")


def check_members(source: BinaryIO, paths: dict[str, str], *, require_present: bool) -> None:
    """Check the exact DTBs and any explicit directory entries above them."""
    members = {path: board for board, path in paths.items()}
    if len(members) != len(paths):
        raise member_error(next(iter(paths)), "shared")
    parents = {str(parent): board for path, board in members.items() for parent in PurePosixPath(path).parents}
    seen: set[str] = set()
    archive_size = source.seek(0, SEEK_END)
    if archive_size % BLOCK:
        raise archive_error("unaligned tar size")
    source.seek(0)
    extension: tuple[bytes, str] | None = None
    while True:
        header = source.read(BLOCK)
        if header == bytes(BLOCK):
            if extension is not None or source.read(BLOCK) != bytes(BLOCK):
                raise archive_error("invalid end marker")
            while padding := source.read(64 * 1024):
                if padding.strip(b"\0"):
                    raise archive_error("nonzero trailer")
            break
        entry = tarfile.TarInfo.frombuf(header, "utf-8", "surrogateescape")
        if entry.type in (tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.SOLARIS_XHDTYPE):
            raise archive_error("pax header")
        if entry.type == tarfile.GNUTYPE_SPARSE:
            raise archive_error("sparse header")
        end = source.tell() + (entry.size + BLOCK - 1) // BLOCK * BLOCK
        if entry.size < 0 or end > archive_size:
            raise archive_error("invalid member size")
        if entry.type in (tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK):
            if extension is not None or not 1 < entry.size <= 4096:
                raise archive_error("invalid GNU extension")
            value = source.read(entry.size)
            if not value.endswith(b"\0") or b"\0" in value[:-1]:
                raise archive_error("invalid GNU extension")
            extension = entry.type, value[:-1].decode("utf-8", "surrogateescape")
            source.seek(end)
            continue
        if entry.type not in (*REGULAR, *TYPES) or (entry.type in TYPES and entry.size != 0):
            raise archive_error("unsupported member header")
        if extension and extension[0] == tarfile.GNUTYPE_LONGLINK and not (entry.issym() or entry.islnk()):
            raise archive_error("invalid GNU extension")
        # TarInfo strips directory suffixes; keep their original spelling for the path check.
        stored_name = header[:100].split(b"\0", 1)[0]
        suffix = stored_name[len(stored_name.rstrip(b"/")):].decode("ascii") if entry.isdir() else ""
        raw_name = (extension[1] if extension and extension[0] == tarfile.GNUTYPE_LONGNAME
                    else entry.name + suffix)
        name = raw_name.removeprefix("./").removesuffix("/") if entry.isdir() else raw_name.removeprefix("./")
        canonical = posixpath.normpath("/" + name.lstrip("/")).lstrip("/") or "."
        board = members.get(canonical)
        owner = board or parents.get(canonical)
        if canonical != name and not (entry.isdir() and raw_name == "./"):
            raise member_error(owner, "non-canonical") if owner else archive_error("non-canonical member name")
        if owner is not None:
            if canonical in seen:
                raise member_error(owner, "duplicate")
            seen.add(canonical)
            if board is not None and entry.type not in REGULAR:
                raise member_error(board, TYPES.get(entry.type, "other"))
            if board is None and not entry.isdir():
                raise member_error(owner, "non-directory ancestor")
            if extension is not None:
                raise member_error(owner, "extended name or link")
        extension = None
        source.seek(end)
    if require_present:
        for path, board in members.items():
            if path not in seen:
                raise member_error(board, "missing")


def check_deb_archive(deb: Path, paths: dict[str, str], env: dict[str, str], *, require_present: bool = True) -> None:
    """Read dpkg's data stream into bounded private scratch, never onto an install tree."""
    try:
        with tempfile.TemporaryFile(dir=deb.parent) as archive:
            run_gate(["prlimit", f"--fsize={INPUT_LIMIT}", "--", "dpkg-deb", "--fsys-tarfile", str(deb)],
                     env=env, stdin=subprocess.DEVNULL, stdout=archive, stderr=subprocess.DEVNULL, timeout=180)
            check_members(archive, paths, require_present=require_present)
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError):
        raise archive_error("unreadable") from None
