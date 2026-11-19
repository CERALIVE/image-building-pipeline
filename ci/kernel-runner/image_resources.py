"""Admission for the image profile; limits must already be effective above flock."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
import errno
import os
from pathlib import Path
import resource
from typing import Final, TypedDict

from image_stream import retry_check
from vm_process import Cancellation

GIB: Final = 1024**3
MIN_NICE: Final = 9
MAX_CPU_WEIGHT: Final = 10

SYS_IOPRIO_GET: Final = 252
IOPRIO_WHO_PROCESS: Final = 1
IOPRIO_CLASS_SHIFT: Final = 13
_LIBC = ctypes.CDLL(None, use_errno=True)
_LIBC.syscall.restype = ctypes.c_long


class AdmissionError(Exception):
    """An image attempt cannot fit its approved resource envelope."""


class IOPriorityError(AdmissionError):
    """The live guest's I/O class could not be verified."""


class IOPrioritySyscallError(OSError):
    """A native sampling error whose errno must reach the observation retry."""


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
    group = Path("/sys/fs/cgroup") / membership[4:].lstrip("/")
    ancestors = (group, *group.parents)
    roots = [path for path in ancestors if path.is_relative_to("/sys/fs/cgroup")]
    memory = []
    quotas = []
    swaps = []
    weights = []
    for path in roots:
        for field, values in (("memory.max", memory), ("memory.swap.max", swaps)):
            file = path / field
            if file.is_file():
                value = file.read_text().strip()
                if value != "max":
                    values.append(int(value))
        cpu = path / "cpu.max"
        if cpu.is_file():
            quota, period = cpu.read_text().split()
            if quota != "max":
                quotas.append(int(quota) / int(period))
        io = path / "io.weight"
        if io.is_file():
            for line in io.read_text().splitlines():
                if line.startswith("default "):
                    weights.append(int(line.split()[1]))
    if not memory or min(memory) != CAPS.memory_max:
        raise AdmissionError("image profile needs effective MemoryMax = 24 GiB")
    if not quotas or min(quotas) > CAPS.cpus:
        raise AdmissionError("image profile needs effective CPUQuota <= 400%")
    if not swaps or min(swaps) != 0:
        raise AdmissionError("image profile needs effective MemorySwapMax=0")
    if not weights or min(weights) > 10:
        raise AdmissionError("image profile needs effective IOWeight <= 10")
    cpu_weight = group / "cpu.weight"
    if not cpu_weight.is_file() or not 1 <= (weight := int(cpu_weight.read_text())) <= MAX_CPU_WEIGHT:
        raise AdmissionError(f"image profile needs CPUWeight <= {MAX_CPU_WEIGHT} on its cgroup")
    return weight


def require_process_priority(pid: int) -> int:
    """Admit only low-priority, non-realtime CPU scheduling."""
    nice = os.getpriority(os.PRIO_PROCESS, pid)
    if (nice < MIN_NICE or os.sched_getscheduler(pid) not in
            (os.SCHED_OTHER, os.SCHED_BATCH, os.SCHED_IDLE)):
        raise AdmissionError(f"image profile needs non-realtime scheduling and nice >= {MIN_NICE}")
    return nice


class PriorityObservation(TypedDict):
    nice: int
    ionice: str
    cpu_weight: int


def process_priority(pid: int, cancellation: Cancellation) -> PriorityObservation:
    """Observe the owned QEMU process, including containment after exec."""
    try:
        return retry_check(_process_priority, pid, cancellation)
    except IOPrioritySyscallError as error:
        raise IOPriorityError(f"ioprio_get failed: {error.strerror}") from error


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
    cgroup_limits("self")
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
