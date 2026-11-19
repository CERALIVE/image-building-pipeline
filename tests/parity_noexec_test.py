#!/usr/bin/env python3
"""Exercise parity with the kernel access denial of a noexec verification surface."""

from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import tempfile
from typing import Iterator

ROOT = Path(__file__).resolve().parents[1]


@contextmanager
def parity_fixture() -> Iterator[tuple[Path, dict[str, str]]]:
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        root = work / "rootfs"
        env = {"PATH": os.environ["PATH"], "HOME": str(work), "TMPDIR": str(work),
               "PYTHONDONTWRITEBYTECODE": "1", "CERALIVE_DEBUG_IMAGE": "0"}
        script = '''
source "$1/tests/manifest-helpers.bash"
PIPELINE_DIR="$1"; COMMON_SH="$1/lib/common.sh"
make_parity_rootfs "$2"
printf 'Package: libsrt1.5-ceralive\\nStatus: install ok installed\\n\\n' >>"$2/var/lib/dpkg/status"
mkdir -p "$2/opt/ceralive" "$2/etc/systemd/system/multi-user.target.wants"
printf 'image executable fixture\\n' >"$2/opt/ceralive/ceralive"
chmod 0755 "$2/opt/ceralive/ceralive"
printf '[Service]\\nExecStart=/opt/ceralive/ceralive\\n' >"$2/etc/systemd/system/ceralive.service"
ln -s ../ceralive.service "$2/etc/systemd/system/multi-user.target.wants/ceralive.service"
'''
        subprocess.run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT), str(root)],
                       check=True, env=env, capture_output=True, text=True, timeout=30)
        yield root, env


def test_parity_accepts_stored_executables_when_noexec_denies_x_ok() -> None:
    with parity_fixture() as (root, env):
        sudo = root / "usr/bin/sudo"
        service = root / "opt/ceralive/ceralive"
        trace = root.parent / "access-denial.log"
        command = ["strace", "-qq", "-f", "-o", str(trace),
                   "-e", "trace=access,faccessat,faccessat2",
                   "-e", "inject=access,faccessat,faccessat2:error=EACCES",
                   "-P", str(sudo), "-P", str(service)]
        control = subprocess.run([*command, "bash", "-c", '[[ -x "$1" ]]', "_", str(sudo)],
                                 env=env, capture_output=True, text=True, timeout=10)
        assert control.returncode == 1
        assert "X_OK" in trace.read_text() and "INJECTED" in trace.read_text()
        assert sudo.stat().st_mode & 0o111 and service.stat().st_mode & 0o111
        result = subprocess.run([*command, "bash", str(ROOT / "lib/parity-check.sh"), str(root)],
                                env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "sudo binary present" in result.stdout + result.stderr
        assert "ExecStart target exists and is executable" in result.stdout + result.stderr


def test_parity_still_requires_execute_bits_for_each_required_binary() -> None:
    with parity_fixture() as (root, env):
        for relative, expected in (
            ("usr/bin/sudo", "sudo binary missing"),
            ("opt/ceralive/ceralive", "ExecStart target missing/not executable"),
        ):
            file = root / relative
            file.chmod(0o644)
            result = subprocess.run(["bash", str(ROOT / "lib/parity-check.sh"), str(root)],
                                    env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode != 0 and expected in result.stdout + result.stderr
            file.chmod(0o755)


def test_parity_rejects_a_directory_instead_of_an_executable_file() -> None:
    with parity_fixture() as (root, env):
        file = root / "opt/ceralive/ceralive"
        file.unlink()
        file.mkdir(mode=0o755)
        result = subprocess.run(["bash", str(ROOT / "lib/parity-check.sh"), str(root)],
                                env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode != 0
        assert "ExecStart target missing/not executable" in result.stdout + result.stderr


if __name__ == "__main__":
    tests = [test for name, test in list(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"noexec parity: {len(tests)} passed")
