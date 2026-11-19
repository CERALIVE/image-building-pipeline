"""Payload-free diagnostics for the isolated image probe."""

import os
from pathlib import Path
import re
import time
from typing import Callable, ParamSpec, TypeVar

CONSOLE = Path("/dev/ttyS0")
TAIL_LIMIT = 4 * 1024
LINE_LIMIT = 96
STAGE_LINE = re.compile(
    rb"STAGE ([0-9]{1,20}) (probe_start|capsule_import_(?:begin|end)|"
    rb"source_checkout_(?:begin|end)|route_check_(?:begin|end)|"
    rb"tcp_check_[1-4]_(?:begin|end)|verdict_computed|stream_open_(?:begin|end)|"
    rb"magic_write_begin|magic_written|member_prepare_(?:begin|end)|"
    rb"member_header_(?:begin|end)|member_body_(?:begin|written)|"
    rb"flush_(?:begin|end)|stream_close_(?:begin|end)|diagnostics_lost) ([0-9]{1,20})"
    rb"(?: ([0-9]{1,20}))?"
)

P = ParamSpec("P")
T = TypeVar("T")


def optional(on_loss: Callable[[], None], operation: Callable[P, T],
             *args: P.args, **kwargs: P.kwargs) -> T | None:
    """Diagnostics are optional. No ordinary diagnostic exception reaches the probe."""
    try:
        return operation(*args, **kwargs)
    except Exception:
        on_loss()
        return None


class StageLog:
    """Write best-effort stage markers with no diagnostic I/O on the artifact port."""

    def __init__(self) -> None:
        self.pending_loss = False
        self.reported_loss = False
        self.sequence = 0

    def lose(self) -> None:
        self.pending_loss = True

    @staticmethod
    def _write(line: bytes) -> bool:
        from image_stream import open_owned

        with open_owned(CONSOLE, "ab", os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOCTTY, existing=True) as output:
            return os.write(output.fileno(), line) == len(line)

    def emit(self, stage: str, count: int = 0) -> None:
        optional(self.lose, self._emit, stage, count)

    def _emit(self, stage: str, count: int) -> None:
        self.sequence += 1
        timestamp = time.monotonic_ns()
        line = f"STAGE {timestamp} {stage} {count} {self.sequence}".encode("ascii")
        if not STAGE_LINE.fullmatch(line):
            self.lose()
            return
        line += b"\n"
        # Emit a loss notice before the next stage. A stalled guest that
        # cannot send the notice is still incomplete at host teardown.
        if self.pending_loss and not self.reported_loss:
            marker = f"\nSTAGE {timestamp} diagnostics_lost 0\n".encode("ascii")
            self.reported_loss = bool(optional(self.lose, self._write, marker))
        if not optional(self.lose, self._write, line):
            self.lose()


def stage_marker(factory: Callable[[], StageLog]) -> Callable[[str, int], None]:
    """Return a fail-silent emission boundary, including logger construction."""
    lost = False

    def disable() -> None:
        nonlocal lost
        lost = True

    logger = optional(disable, factory)

    def emit(stage: str, count: int = 0) -> None:
        if logger is not None and not lost:
            optional(disable, logger.emit, stage, count)

    return emit


class StageTail:
    """Keep only complete, allowlisted STAGE records from the guest console."""

    def __init__(self) -> None:
        self.pending: bytes | None = b""
        self.ring = bytearray(TAIL_LIMIT)
        self.head = 0
        self.size = 0
        self.last: str | None = None
        self.lost = False
        self.truncated = False
        self.sequence = 0

    @property
    def complete(self) -> bool:
        return self.last == "stream_close_end" and not self.lost and self.pending == b""

    def observe(self, chunk: bytes) -> bool:
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
                    if (match[4] is None or int(match[4]) != self.sequence + 1
                            or (self.sequence == 0 and match[2] != b"probe_start")
                            or self.last == "stream_close_end"):
                        self.lost = True
                    if match[4] is not None:
                        self.sequence = int(match[4])
                    self.last = match[2].decode("ascii")
                self._append(line + b"\n")
        return True

    def _append(self, line: bytes) -> None:
        # Only allowlisted complete records enter this fixed-size memory ring.
        while self.size + len(line) > TAIL_LIMIT:
            self.lost = self.truncated = True
            for _ in range(LINE_LIMIT + 1):
                end = self.ring[self.head] == 10
                self.head = (self.head + 1) % TAIL_LIMIT
                self.size -= 1
                if end:
                    break
        start = (self.head + self.size) % TAIL_LIMIT
        first = min(len(line), TAIL_LIMIT - start)
        self.ring[start:start + first] = line[:first]
        self.ring[:len(line) - first] = line[first:]
        self.size += len(line)

    def text(self) -> str:
        first = min(self.size, TAIL_LIMIT - self.head)
        return (self.ring[self.head:self.head + first] + self.ring[:self.size - first]).decode("ascii")
