"""Payload-free diagnostics for the isolated image probe."""

from collections import deque
import os
from pathlib import Path
import re
import stat
import time

CONSOLE = Path("/dev/ttyS0")
GUEST_LOG = Path("/run/ceralive-image-stages.log")
GUEST_LIMIT = 16 * 1024
TAIL_LIMIT = 64 * 1024
LINE_LIMIT = 96
STAGE_LINE = re.compile(
    rb"STAGE ([0-9]{1,20}) (probe_start|capsule_import_(?:begin|end)|"
    rb"source_checkout_(?:begin|end)|route_check_(?:begin|end)|"
    rb"tcp_check_[1-4]_(?:begin|end)|verdict_computed|stream_open_(?:begin|end)|"
    rb"magic_write_begin|magic_written|member_prepare_(?:begin|end)|"
    rb"member_header_(?:begin|end)|member_body_(?:begin|written)|"
    rb"flush_(?:begin|end)|stream_close_(?:begin|end)|diagnostics_lost) ([0-9]{1,20})"
)


class StageLog:
    """Write best-effort stage markers with no diagnostic I/O on the artifact port."""

    def __init__(self) -> None:
        self.pending_loss = False
        self.reported_loss = False

    def emit(self, stage: str, count: int = 0) -> None:
        try:
            timestamp = time.monotonic_ns()
            line = f"STAGE {timestamp} {stage} {count}".encode("ascii")
            if not STAGE_LINE.fullmatch(line):
                return
            line += b"\n"
        except Exception:
            self.pending_loss = True
            return
        flags = os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOCTTY
        try:
            fd = os.open(GUEST_LOG, flags | os.O_CREAT, 0o600)
            try:
                info = os.fstat(fd)
                if (not stat.S_ISREG(info.st_mode) or info.st_size + len(line) > GUEST_LIMIT
                        or os.write(fd, line) != len(line)):
                    self.pending_loss = True
            finally:
                os.close(fd)
        except Exception:
            self.pending_loss = True
        try:
            fd = os.open(CONSOLE, flags)
            try:
                if self.pending_loss and not self.reported_loss:
                    # Start on a fresh line even if an earlier write was short.
                    marker = f"\nSTAGE {timestamp} diagnostics_lost 0\n".encode("ascii")
                    self.reported_loss = os.write(fd, marker) == len(marker)
                if os.write(fd, line) != len(line):
                    self.pending_loss = True
            finally:
                os.close(fd)
        except Exception:
            self.pending_loss = True


class StageTail:
    """Keep only complete, allowlisted STAGE records from the guest console."""

    def __init__(self) -> None:
        self.pending: bytes | None = b""
        self.lines: deque[bytes] = deque()
        self.size = 0
        self.last: str | None = None
        self.lost = False

    def observe(self, chunk: bytes) -> None:
        parts = chunk.split(b"\n")
        for index, part in enumerate(parts):
            prefix = self.pending if index == 0 else b""
            complete = index < len(parts) - 1
            joined = prefix + part if prefix is not None and len(prefix) + len(part) <= LINE_LIMIT else None
            if not complete:
                self.pending = joined
                break
            if joined is None:
                continue
            line = joined.removesuffix(b"\r")
            if match := STAGE_LINE.fullmatch(line):
                if match[2] == b"diagnostics_lost":
                    self.lost = True
                else:
                    self.last = match[2].decode("ascii")
                line += b"\n"
                self.lines.append(line)
                self.size += len(line)
                while self.size > TAIL_LIMIT:
                    self.size -= len(self.lines.popleft())

    def text(self) -> str:
        return b"".join(self.lines).decode("ascii")
