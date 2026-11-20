"""Admission for the image profile; limits must already be effective above flock."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
import errno
import math
import os
from pathlib import Path
import re
import resource
import time
from typing import Callable, Final, TypedDict

from image_stream import list_directory, retry_check
from vm_process import Cancellation

GIB: Final = 1024**3
MIN_NICE: Final = 9
MAX_CPU_WEIGHT: Final = 10
MAX_IO_WEIGHT: Final = 10
QEMU_NICE: Final = 10
# A host daemon may renice the launch wrapper or QEMU just after exec; admission waits this long.
PRIORITY_SETTLE_SECONDS: Final = 5.0
PRIORITY_SETTLE_INTERVAL: Final = 0.1
# Proof of the wrapper handoff: the kernel keeps the first 15 bytes of qemu-system-x86_64.
QEMU_COMM: Final = "qemu-system-x86"
SCHEDULERS: Final = {os.SCHED_OTHER: "SCHED_OTHER", os.SCHED_BATCH: "SCHED_BATCH", os.SCHED_IDLE: "SCHED_IDLE"}
REALTIME: Final = {os.SCHED_FIFO: "SCHED_FIFO", os.SCHED_RR: "SCHED_RR", 6: "SCHED_DEADLINE"}

SYS_IOPRIO_GET: Final = 252
IOPRIO_WHO_PROCESS: Final = 1
IOPRIO_CLASS_SHIFT: Final = 13
_LIBC = ctypes.CDLL(None, use_errno=True)
_LIBC.syscall.restype = ctypes.c_long


class AdmissionError(Exception):
    """An image attempt cannot fit its approved resource envelope."""


class PriorityRefusal(AdmissionError):
    """A sampled process is outside the low-priority, non-realtime floor."""

    def __init__(self, nice: int, policy: int, thread: int | None = None) -> None:
        name = SCHEDULERS.get(policy) or REALTIME.get(policy) or f"policy {policy}"
        self.realtime = policy not in SCHEDULERS
        self.observed = {"nice": nice, "policy": name} | ({} if thread is None else {"thread": thread})
        where = "" if thread is None else f", thread {thread}"
        super().__init__(f"image profile needs non-realtime scheduling and nice >= {MIN_NICE} "
                         f"(observed nice {nice}, {name}{where})")


class GuestDeadline(Exception):
    """The guest's own deadline arrived during the priority settle."""


class IOPriorityError(AdmissionError):
    """The live guest's I/O class could not be verified."""


class IOPrioritySyscallError(OSError):
    """A native sampling error whose errno must reach the observation retry."""


class BFQObservationError(OSError):
    """An incomplete BFQ observation must restart the cgroup sample."""

    def __init__(self, reason: str) -> None:
        super().__init__(errno.EIO, reason)


@dataclass(frozen=True, slots=True)
class ImageCaps:
    cpus: int = 4
    ram_mib: int = 20480
    memory_max: int = 24 * GIB
    overlay_max: int = 144 * GIB
    stream_max: int = 16 * GIB
    log_max: int = GIB
    build_seconds: int = 21600
    verify_seconds: int = 1800

    def qemu_limit(self) -> None:
        resource.setrlimit(resource.RLIMIT_FSIZE, (self.overlay_max, self.overlay_max))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


CAPS: Final = ImageCaps()

def require_host_lock() -> None:
    """Allow an additional inner plan lock while retaining the outer host inode."""
    expected = Path("/tmp/host-heavy.lock").stat()
    pid = os.getppid()
    for _depth in range(32):
        process = Path("/proc") / str(pid)
        args = (process / "cmdline").read_bytes().split(b"\0")
        if ((process / "comm").read_text().strip() == "flock" and len(args) > 3
                and args[1:3] == [b"--exclusive", b"--close"]):
            lock = Path(os.fsdecode(args[3])).stat()
            if (lock.st_dev, lock.st_ino) == (expected.st_dev, expected.st_ino):
                return
        status = (process / "stat").read_text()
        parent = int(status[status.rindex(")") + 2:].split()[1])
        if parent <= 1 or parent == pid:
            break
        pid = parent
    raise AdmissionError("image profile requires outer flock --exclusive --close /tmp/host-heavy.lock")


def cgroup_limits(pid: int | str) -> int:
    """Require low CPU weight on the process's cgroup and effective hard caps."""
    membership = Path(f"/proc/{pid}/cgroup").read_text().strip()
    if not membership.startswith("0::/"):
        raise AdmissionError("image profile requires unified cgroup v2")
    root = Path("/sys/fs/cgroup")
    relative = Path(membership[4:])
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise AdmissionError("image profile requires a dedicated non-root cgroup")
    group = root / relative
    memory = []
    quotas = []
    swaps = []
    weights: list[dict[str, int]] = []
    bfq_weights: list[dict[str, int]] = []

    def read(path: Path, field: str) -> str:
        try:
            return (path / field).read_text().strip()
        except FileNotFoundError as error:
            raise AdmissionError(f"missing required cgroup control {path / field}") from error

    def number(value: str) -> int:
        if not re.fullmatch(r"[0-9]+", value):
            raise ValueError("expected an unsigned decimal integer")
        return int(value)

    def parse_weights(text: str) -> dict[str, int]:
        by_device: dict[str, int] = {}
        for line in text.strip().splitlines():
            selector, value = line.split()
            weight = number(value)
            if (selector in by_device or not 1 <= weight <= 10000 or
                    (selector != "default" and not re.fullmatch(r"[0-9]+:[0-9]+", selector))):
                raise ValueError("invalid I/O weight")
            by_device[selector] = weight
        if "default" not in by_device:
            raise ValueError("expected one default I/O weight")
        return by_device

    # Controllers expose these controls on non-root cgroups. A missing
    # workload or ancestor control cannot be filled in from another sample.
    try:
        for path in (group, *group.parents):
            if path == root:
                break
            for field, values in (("memory.max", memory), ("memory.swap.max", swaps)):
                value = read(path, field)
                if value != "max":
                    values.append(number(value))
            quota, period = read(path, "cpu.max").split()
            period = number(period)
            if period == 0:
                raise ValueError("CPU period is zero")
            if quota != "max":
                cpu_quota = number(quota)
                if cpu_quota == 0:
                    raise ValueError("CPU quota is zero")
                quotas.append(cpu_quota / period)
            weights.append(parse_weights(read(path, "io.weight")))
            bfq = path / "io.bfq.weight"
            try:
                try:
                    text = bfq.read_text()
                except FileNotFoundError:
                    try:
                        bfq.lstat()
                    except FileNotFoundError:
                        continue
                    raise
                bfq_weights.append(parse_weights(text))
            except (OSError, ValueError) as error:
                raise BFQObservationError(f"cannot sample {bfq}: {error}") from error
        weight = number(read(group, "cpu.weight"))
    except ValueError as error:
        raise AdmissionError(f"invalid cgroup limit: {error}") from error
    if not memory or min(memory) != CAPS.memory_max:
        raise AdmissionError("image profile needs effective MemoryMax = 24 GiB")
    if not quotas or min(quotas) > CAPS.cpus:
        raise AdmissionError("image profile needs effective CPUQuota <= 400%")
    if not swaps or min(swaps) != 0:
        raise AdmissionError("image profile needs effective MemorySwapMax=0")
    if bfq_weights and len(bfq_weights) != len(weights):
        raise BFQObservationError("io.bfq.weight is missing on part of the cgroup hierarchy")
    for field, hierarchy in (("io.weight", weights), ("io.bfq.weight", bfq_weights)):
        # A device override replaces the default only at its own level.
        if any(min(level.get(device, level["default"]) for level in hierarchy) > MAX_IO_WEIGHT
               for device in set().union(*hierarchy)):
            raise AdmissionError(f"image profile needs effective IOWeight <= {MAX_IO_WEIGHT} for {field}")
    if not 1 <= weight <= MAX_CPU_WEIGHT:
        raise AdmissionError(f"image profile needs CPUWeight <= {MAX_CPU_WEIGHT} on its cgroup")
    return weight


def require_process_priority(pid: int) -> int:
    """Admit only low-priority, non-realtime CPU scheduling."""
    nice = os.getpriority(os.PRIO_PROCESS, pid)
    policy = os.sched_getscheduler(pid)
    if nice < MIN_NICE or policy not in SCHEDULERS:
        raise PriorityRefusal(nice, policy)
    return nice


class PriorityObservation(TypedDict):
    nice: int
    ionice: str
    cpu_weight: int


@dataclass(frozen=True, slots=True)
class Settle:
    """The first live sample's child-exit check and the clock of its bound."""

    exited: Callable[[], bool]
    guest_deadline: float | None = None
    clock: Callable[[], float] = time.monotonic
    pause: Callable[[float], None] = time.sleep


def process_priority(pid: int, cancellation: Cancellation, *, settle: Settle | None = None) -> PriorityObservation:
    """Observe the owned QEMU process, including containment after exec.

    The first sample settles: it restores the launch niceness on the exec'd QEMU threads and
    needs a conformant observation within PRIORITY_SETTLE_SECONDS. Later samples verify only.
    """
    if settle is not None:
        return _settled_priority(pid, cancellation, settle)
    try:
        return retry_check(_process_priority, pid, cancellation)
    except IOPrioritySyscallError as error:
        raise IOPriorityError(f"ioprio_get failed: {error.strerror}") from error


def _settled_priority(pid: int, cancellation: Cancellation, settle: Settle) -> PriorityObservation:
    """Accept only a clean confirming pass; the earlier deadline decides any other end.

    A child exit always wins. A realtime policy refuses before any write. Observation errors
    before the governing deadline are inconclusive; at or after it, the deadline's result stands.
    """
    start = settle.clock()
    settle_end = start + PRIORITY_SETTLE_SECONDS
    guest_end = math.inf if settle.guest_deadline is None else settle.guest_deadline
    guest_first = guest_end <= settle_end

    def remaining() -> float:
        return min(settle_end, guest_end) - settle.clock()

    reason: AdmissionError = _handoff_error(pid)
    previous: frozenset[int] | None = None
    while True:
        cancellation.check()
        if settle.exited():
            raise _settle_exit(pid)
        if remaining() <= 0:
            _expire(guest_first, reason)
        confirmed, observation, found = False, None, None
        try:
            policy = os.sched_getscheduler(pid)
            if policy not in SCHEDULERS:
                raise PriorityRefusal(os.getpriority(os.PRIO_PROCESS, pid), policy)
            if _comm(pid) != QEMU_COMM:
                reason, previous = _handoff_error(pid), None
            else:
                result = _thread_pass(pid, policy, remaining)
                found = result.reason
                reason = found or _unconfirmed_error(pid)
                unchanged, previous = result.listing == previous, result.listing
                observation = process_priority(pid, cancellation)
                confirmed = found is None and unchanged
        except PriorityRefusal as error:
            if settle.exited():
                raise _settle_exit(pid) from error
            if error.realtime and remaining() > 0:
                raise
            reason, previous = found or error, None
        except OSError as error:
            if settle.exited():
                raise _settle_exit(pid) from error
            reason, previous = found or _unobservable_error(pid, error), None
        except AdmissionError as error:
            if settle.exited():
                raise _settle_exit(pid) from error
            if remaining() > 0:
                raise
            reason = error
        if settle.exited():
            raise _settle_exit(pid)
        left = remaining()
        if left <= 0:
            _expire(guest_first, reason)
        if confirmed:
            return observation
        settle.pause(min(PRIORITY_SETTLE_INTERVAL, left))


@dataclass(frozen=True, slots=True)
class _ThreadPass:
    listing: frozenset[int]
    reason: AdmissionError | None  # None only for a pass with no write, low thread or vanished thread


def _thread_pass(pid: int, policy: int, remaining: Callable[[], float]) -> _ThreadPass:
    """Read every listed thread; raise, never lower, one below the floor; never write after the deadline."""
    listing = frozenset(int(name) for name in list_directory(Path(f"/proc/{pid}/task")))
    reason = None
    for tid in sorted(listing):
        try:
            nice = os.getpriority(os.PRIO_PROCESS, tid)
        except ProcessLookupError:
            reason = AdmissionError(f"QEMU PID {pid} thread {tid} exited during the priority settle")
            continue
        if nice >= MIN_NICE:
            continue
        reason = PriorityRefusal(nice, policy, None if tid == pid else tid)
        if remaining() <= 0:
            break
        try:
            os.setpriority(os.PRIO_PROCESS, tid, QEMU_NICE)
        except PermissionError as error:
            # A host renice may land between the read and the write; the next pass decides.
            reason = AdmissionError(_raise_failure(pid, tid, error))
        except ProcessLookupError as error:
            reason = AdmissionError(_raise_failure(pid, tid, error))
    return _ThreadPass(listing, reason)


def _handoff_error(pid: int) -> AdmissionError:
    return AdmissionError(f"QEMU PID {pid} did not hand over from its launch wrapper within {PRIORITY_SETTLE_SECONDS} s")


def _unconfirmed_error(pid: int) -> AdmissionError:
    return AdmissionError(f"QEMU PID {pid} priority was not confirmed by a clean pass within {PRIORITY_SETTLE_SECONDS} s")


def _unobservable_error(pid: int, error: OSError) -> AdmissionError:
    refusal = AdmissionError(f"QEMU PID {pid} priority could not be observed within {PRIORITY_SETTLE_SECONDS} s: {error}")
    refusal.__cause__ = error
    return refusal


def _expire(guest_first: bool, reason: AdmissionError) -> None:
    """The earlier deadline governs: the guest's ends the attempt as a guest timeout."""
    if guest_first:
        raise GuestDeadline("image guest deadline reached during the priority settle")
    raise reason


def _settle_exit(pid: int) -> ProcessLookupError:
    return ProcessLookupError(errno.ESRCH, f"QEMU PID {pid} exited during the priority settle")


def _comm(pid: int) -> str:
    """An empty or unreadable name is inconclusive, never proof of the handoff."""
    try:
        return Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        return ""


def _raise_failure(pid: int, tid: int, error: OSError) -> str:
    thread = "" if tid == pid else f" thread {tid}"
    return f"cannot raise QEMU PID {pid}{thread} to nice {QEMU_NICE}: {error.strerror}"


def _process_priority(pid: int, cancellation: Cancellation) -> PriorityObservation:
    cancellation.check()
    if cancellation.finalizing:
        raise RuntimeError("cannot sample a child during terminal finalization")
    nice = require_process_priority(pid)
    cpu_weight = cgroup_limits(pid)
    if os.uname().machine != "x86_64" or ctypes.sizeof(ctypes.c_void_p) != 8:
        raise IOPriorityError(os.strerror(errno.ENOSYS))
    value = _LIBC.syscall(ctypes.c_long(SYS_IOPRIO_GET), IOPRIO_WHO_PROCESS, pid)
    if value == -1:
        error = ctypes.get_errno()
        raise IOPrioritySyscallError(error, os.strerror(error))
    policy, level = divmod(value, 1 << IOPRIO_CLASS_SHIFT)
    if policy == 1:
        raise AdmissionError("image profile forbids realtime I/O priority")
    if policy not in (0, 2, 3):
        raise IOPriorityError(f"unrecognized I/O priority class {policy}")
    ionice = f"{('none', 'realtime', 'best-effort', 'idle')[policy]}: prio {level}"
    return {"nice": nice, "ionice": ionice, "cpu_weight": cpu_weight}


def cgroup_admission() -> None:
    """Check the launcher before any image preparation or guest is started."""
    retry_check(cgroup_limits, "self")
    require_process_priority(0)
    if len(os.sched_getaffinity(0)) != CAPS.cpus:
        raise AdmissionError("image profile needs four selected CPUs")
    available = next(int(line.split()[1]) * 1024
                     for line in Path("/proc/meminfo").read_text().splitlines()
                     if line.startswith("MemAvailable:"))
    if available < 32 * GIB:
        raise AdmissionError("image profile needs >= 32 GiB actual MemAvailable")


def disk_headroom(demands_by_path: tuple[tuple[Path, int], ...]) -> None:
    """Combine concurrent remaining allocations before checking a shared filesystem."""
    demands: dict[int, tuple[Path, int]] = {}
    for path, required in demands_by_path:
        device = path.stat().st_dev
        previous = demands.get(device, (path, 0))[1]
        demands[device] = (path, previous + max(0, required))
    for path, required in demands.values():
        usage = os.statvfs(path)
        available = usage.f_bavail * usage.f_frsize
        if available < required + 30 * GIB:
            raise AdmissionError(f"insufficient image disk headroom on {path}: "
                                 f"available={available}, required={required + 30 * GIB}")


def disk_admission(overlay: Path, outputs: Path, retained: int = 0) -> None:
    """Charge remaining growth on each affected filesystem, with 30 GiB left over."""
    # Base and capsule are complete, digest-verified, read-only inputs. They have
    # already consumed space; only the overlay and private return store can grow.
    if not 0 <= retained <= 32 * GIB:
        raise AdmissionError("retained pair outputs exceed 32 GiB")
    disk_headroom(((overlay, CAPS.overlay_max), (outputs, 49 * GIB - retained)))
