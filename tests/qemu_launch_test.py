"""Exercise the host launch boundary using a stand-in, never a real VM."""

import io
import json
import os
from pathlib import Path
import pty
import re
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest import TestCase, main
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ci/kernel-runner"))
import vm

SESSION = ("DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XAUTHORITY",
           "DBUS_SESSION_BUS_ADDRESS", "SSH_TTY")


def assert_headless(argv: list[str]) -> None:
    for flag in ("-display", "-vga", "-monitor"):
        assert argv.count(flag) == 1 and argv[argv.index(flag) + 1] == "none", argv
    assert "-nodefaults" in argv, argv
    assert not {"-nographic", "-vnc", "-spice", "-mon", "-qmp", "-curses"}.intersection(argv), argv
    assert argv.count("-serial") == 1, argv
    assert argv[argv.index("-serial") + 1].startswith(("file:/proc/self/fd/", "pipe:")), argv


class QemuLaunchTest(TestCase):
    def test_runner_and_image_profiles(self) -> None:
        # The launch contract is checked at Popen, after argv and stdio are resolved.
        for mode in ("kernel-base", "image-base", "check", "jit", "measure", "probe"):
            with self.subTest(mode=mode), tempfile.TemporaryFile() as owned:
                marker = b"CERALIVE_BASE_READY" if mode.endswith("-base") else b"CERALIVE_JOB_DONE=0"
                captured = []

                def child(argv, **options):
                    captured.append((argv, options))
                    return SimpleNamespace(stdin=None, stdout=io.BytesIO(marker + b"\n"), stderr=None)

                fd = owned.fileno()
                job = (SimpleNamespace(base_fd=fd, capsule_fd=fd, console_write=fd,
                                       cancellation=vm.Cancellation(), probe=mode == "probe",
                                       capture=lambda *_: None, state={})
                       if mode in ("measure", "probe") else None)
                with patch.dict(os.environ, dict.fromkeys(SESSION, "host-session")), \
                        patch.object(subprocess, "Popen", side_effect=child), \
                        patch.object(vm, "wait"), patch.object(vm, "terminate"), \
                        patch.object(vm, "poll_owned", return_value=0), \
                        patch.object(sys, "stdout", io.TextIOWrapper(io.BytesIO())):
                    vm.boot(Path("disk"), b"", mode if not job else "image", 1,
                            seed=Path("seed") if mode.endswith("-base") else None,
                            disk_fd=fd if job else None, image_job=job, image_base=mode == "image-base")
                [(argv, options)] = captured
                assert_headless(argv)
                serial = argv[argv.index("-serial") + 1]
                self.assertEqual(serial, f"file:/proc/self/fd/{fd if job else 1}")
                self.assertEqual(options["stdin"], subprocess.DEVNULL)
                self.assertEqual(options["stdout"], subprocess.PIPE)
                self.assertEqual(options["stderr"], {"probe": subprocess.DEVNULL,
                                                     "measure": subprocess.PIPE}.get(mode, subprocess.STDOUT))
                self.assertTrue(options["start_new_session"])
                self.assertFalse(set(SESSION) & options["env"].keys())
                if job:
                    artifact_backends = [spec for flag, spec in zip(argv, argv[1:])
                                         if flag == "-chardev" and "id=artifacts" in spec.split(",")]
                    self.assertEqual(artifact_backends, ["file,id=artifacts,path=/proc/self/fd/1"])

    def test_refuses_pty_and_other_unowned_streams_before_spawning(self) -> None:
        from qemu_launch import spawn_qemu

        master, slave = pty.openpty()
        try:
            self.assertTrue(os.isatty(slave))
            with tempfile.TemporaryFile() as file, patch.object(subprocess, "Popen") as spawn:
                for override, error in (
                    ({"stdin": slave}, "stdin is a TTY"),
                    ({"stdout": slave}, "stdout is a TTY"),
                    ({"stderr": slave}, "stderr is a TTY"),
                    ({"stdin": file.fileno()}, "stdin must be /dev/null"),
                    ({"stdout": None}, "stdout (is a TTY|must be a pipe or regular file)"),
                ):
                    with self.subTest(override=override), self.assertRaisesRegex(RuntimeError, error):
                        spawn_qemu([], serial=1, **override)
                with self.assertRaisesRegex(RuntimeError, "serial is a TTY"):
                    spawn_qemu([], serial=slave, pass_fds=(slave,))
                spawn.assert_not_called()
        finally:
            os.close(slave)
            os.close(master)

    def test_x86_smoke_drives_serial_fifos_not_stdio(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stub = root / "vm-standin"
            stub.write_text(f"""#!{sys.executable}
import json, os, pathlib, stat, sys
args = sys.argv[1:]
fifo = args[args.index('-serial') + 1].removeprefix('pipe:')
with open(fifo + '.out', 'w', buffering=1) as console, open(fifo + '.in', 'rb') as commands:
    console.write('Reached target multi-user.target\\nlogin:\\n')
    assert commands.read(5) == b'root\\r'
    print(json.dumps(dict(argv=args, stdin=os.readlink('/proc/self/fd/0'),
                          stdout=stat.S_ISREG(os.fstat(1).st_mode),
                          stderr=stat.S_ISREG(os.fstat(2).st_mode),
                          session=os.getsid(0) == os.getpid(),
                          env=list(os.environ))), flush=True)
    pathlib.Path({str(root / "config")!r}).write_text(pathlib.Path('/proc/self/fd/1').read_text())
    console.write('===CERALIVE-QEMU-CHECK-END===\\n')
""")
            stub.chmod(0o700)
            raw = root / "fixture.img"
            raw.touch()
            env = {"PATH": os.environ["PATH"], "QEMU_BIN": str(stub), "IMAGE_PATH": str(raw),
                   "TMPDIR": str(root), "BOOT_TIMEOUT": "3", "LOGIN_TIMEOUT": "3",
                   **dict.fromkeys(SESSION, "host-session")}
            # The real shell probe sleeps after a login; replace only its pacing command.
            sleep = root / "sleep"
            sleep.write_text("#!/bin/sh\nexit 0\n")
            sleep.chmod(0o700)
            env["PATH"] = f"{root}:{env['PATH']}"
            result = subprocess.run(["bash", str(ROOT / "tests/qemu-x86.sh")], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            config = json.loads((root / "config").read_text())
            assert_headless(config["argv"])
            self.assertEqual(config["stdin"], "/dev/null")
            self.assertTrue(config["stdout"] and config["stderr"] and config["session"], config)
            self.assertFalse(set(SESSION) & set(config["env"]))

    def test_no_unsanctioned_qemu_invocations(self) -> None:
        # Allow known mentions, test stand-ins and non-boot version/availability checks
        # by line shape, not by exempting entire files that can grow launch commands.
        references = {
            "ci/kernel-runner/qemu_launch.py": r'QEMU_BINARY = "qemu-system-x86_64"',
            "ci/kernel-runner/image_resources.py": r'QEMU_COMM: Final = "qemu-system-x86"',
            ".github/workflows/v2-ci.yml": (
                r"(?:- name: (?:Install|Verify) qemu-system-.*|"
                r"sudo apt-get install -y --no-install-recommends qemu-system-x86 ovmf|"
                r"qemu-system-x86_64 --version \| head -1|"
                r"if ! command -v qemu-system-x86_64 &>/dev/null; then|"
                r'echo "::error::qemu-system-x86_64 not found in PATH after install step"|'
                r'echo "qemu-system-x86_64 available: \$\(qemu-system-x86_64 --version \| head -1\)")'),
            "tests/addon-e2e.sh": (
                r'QEMU_BIN="\$\{QEMU_BIN:-qemu-system-x86_64\}"|'
                r'''log_warn "qemu unavailable — skip: '\$\{QEMU_BIN\}' not found \(install qemu-system-x86\)\."'''),
            "tests/qemu-x86.sh": (
                r'QEMU_BIN="\$\{QEMU_BIN:-qemu-system-x86_64\}"|'
                r'''log_warn "qemu unavailable — skip: '\$\{QEMU_BIN\}' not found\. Install it with 'apt-get install qemu-system-x86'\. \(Treated as a SKIP, not a failure — CI leg is continue-on-error\.\)"'''),
            "tests/kernel-runner.test.sh": (
                r'''(?:cat|printf '#!/usr/bin/env bash\\nexit 8\\n') >"\$\{WORK\}/bin/qemu-system-x86_64"(?: <<'PY')?'''),
            "tests/image_profile_test.py": (
                r'''(?:assert "qemu-system-x86_64" in argv|(?:name|qemu|script) = (?:root / |directory / )?"qemu-system-x86_64"|'''
                r'''if name == "qemu-system-x86_64":|.*"qemu-img create", "qemu-system-x86_64"\]|'''
                r'''assert args\[7:10\] == \["runner-child", str\(os.getpid\(\)\), "qemu-system-x86_64"\]|'''
                r'''assert pathlib.Path\(f"/proc/\{child.pid\}/comm"\).read_text\(\) == "qemu-system-x86\\n"|'''
                r'''row, _, _ = settle_sample\(12, comm=\[.*"qemu-system-x86\\n"\]\)|return "qemu-system-x86\\n")'''),
        }
        result = subprocess.run(
            ["git", "grep", "--untracked", "--exclude-standard", "-In", "-E",
             r"qemu-system|qemu-kvm|mon:stdio|-serial[^[:alnum:]]+stdio|"
             r"-monitor[^[:alnum:]]+stdio|-display[^[:alnum:]]+(sdl|gtk|vnc|spice)|-vnc\b|-spice\b",
             "--", ":!*.md", ":!tests/qemu_launch_test.py"],
            cwd=ROOT, env={**os.environ, "GIT_MASTER": "1"}, capture_output=True, text=True, check=True,
        )
        unexpected = []
        for match in result.stdout.splitlines():
            path, _, line = match.split(":", 2)
            if not line.lstrip().startswith("#") and not re.fullmatch(references.get(path, r"(?!)"), line.strip()):
                unexpected.append(match)
        self.assertEqual(unexpected, [])


if __name__ == "__main__":
    main()
