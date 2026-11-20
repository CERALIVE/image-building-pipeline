"""Check the workstation container boundary without a daemon."""

import json
import os
from pathlib import Path
import pty
import re
import subprocess
import sys
import tempfile
from unittest import TestCase, main
import yaml

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = [sys.executable, str(ROOT / "ci/container-engine.py")]
SOCKET = "unix:///var/run/docker.sock"
SESSION = ("DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XAUTHORITY",
           "DBUS_SESSION_BUS_ADDRESS", "SSH_TTY")
CAPS = ("--cpus", "2", "--memory=1g")


class ContainerEngineTest(TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.log = root / "calls"
        fake = root / "docker"
        fake.write_text(f"""#!{sys.executable}
import json, os, sys
args = sys.argv[1:]
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(json.dumps(dict(argv=args, stdin=os.readlink('/proc/self/fd/0'),
                              session=os.getsid(0) == os.getpid(), env=list(os.environ))) + '\\n')
if args[:2] == ['context', 'inspect']:
    print(os.environ['FAKE_CONTEXT'] + '|' + os.environ['FAKE_ENDPOINT'])
elif args[2:4] == ['container', 'inspect']:
    print(json.dumps([dict(Id='a' * 64, Config=dict(Tty=False, OpenStdin=False), Mounts=[],
                           HostConfig=dict(NanoCpus=int(os.environ['FAKE_NANO_CPUS']),
                                           Memory=1073741824, NetworkMode='bridge',
                                           Privileged=False, PidMode='', IpcMode='private', Devices=[]))]))
""")
        fake.chmod(0o700)
        self.env = {"PATH": f"{root}:{os.defpath}", "FAKE_LOG": str(self.log),
                    "FAKE_CONTEXT": "default", "FAKE_ENDPOINT": SOCKET,
                    "FAKE_NANO_CPUS": "2000000000", **dict.fromkeys(SESSION, "host-session")}

    def invoke(self, *args: str, device: int | None = None, runtime: str = "docker",
               **env: str) -> subprocess.CompletedProcess:
        return subprocess.run([*WRAPPER, runtime, *args], stdin=device,
                              capture_output=True, text=True, env={**self.env, **env}, timeout=5)

    def calls(self) -> list[dict]:
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_pins_system_socket_with_no_terminal_or_desktop_environment(self) -> None:
        args = ["run", *CAPS, "-v", "/work:/work:ro", "fixture", "echo", "--tty"]
        master_fd, slave_fd = pty.openpty()
        try:
            result = self.invoke(*args, device=slave_fd)
        finally:
            os.close(slave_fd)
            os.close(master_fd)
        self.assertEqual(result.returncode, 0, result.stderr)
        context, launch = self.calls()
        self.assertEqual(context["argv"][:2], ["context", "inspect"])
        self.assertEqual(launch["argv"], ["-H", SOCKET, *args])
        for child in (context, launch):
            self.assertEqual(child["stdin"], "/dev/null")
            self.assertTrue(child["session"])
            self.assertFalse(set(SESSION) & set(child["env"]))
        self.assertFalse({"DOCKER_HOST", "DOCKER_CONTEXT"} & set(launch["env"]))

    def test_refuses_desktop_and_other_endpoints_before_run(self) -> None:
        for overrides in ({"DOCKER_CONTEXT": "desktop-linux"},
                          {"DOCKER_HOST": "unix:///home/example/.docker/desktop/docker.sock"},
                          {"DOCKER_HOST": "tcp://remote:2375"},
                          {"FAKE_CONTEXT": "desktop-linux", "FAKE_ENDPOINT": "unix:///tmp/desktop.sock"},
                          {"FAKE_ENDPOINT": "unix:///run/user/1000/podman/podman.sock"}):
            with self.subTest(overrides=overrides):
                result = self.invoke("run", *CAPS, "fixture", **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("system Docker socket", result.stderr)
        self.assertTrue(all(row["argv"][:2] == ["context", "inspect"] for row in self.calls()))
        result = self.invoke("run", *CAPS, "fixture", runtime="podman")
        self.assertIn("system Docker socket", result.stderr)
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_terminal_flags_and_host_access_before_calling_docker(self) -> None:
        for flags, error in (
            (["-t"], "terminal"), (["-i"], "terminal"), (["-it"], "terminal"),
            (["--tty"], "terminal"), (["--interactive=true"], "terminal"),
            (["--attach=stdin"], "terminal"), (["--privileged"], "--allow-privileged"),
            (["--device=/dev/kvm"], "--allow-host-devices"),
            (["-v/dev:/inside"], "--allow-host-devices"),
            (["--volume", "/work:/dev/tty1"], "--allow-host-devices"),
            (["--mount", "type=bind,src=/dev/tty1,dst=/inside"], "--allow-host-devices"),
            (["--pid=host"], "--allow-host-namespaces"), (["--ipc", "host"], "--allow-host-namespaces"),
            (["--net", "host"], "--allow-host-network"), (["--network=host"], "--allow-host-network"),
            (["--volumes-from", "other"], "unsupported"),
        ):
            with self.subTest(flags=flags):
                result = self.invoke("run", *CAPS, *flags, "fixture")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_explicit_host_access_exceptions_still_need_positive_caps(self) -> None:
        allowed = ("--allow-privileged", "--allow-host-devices", "--allow-host-network", "--allow-host-namespaces")
        flags = ("--privileged", "--device=/dev/kvm", "-v", "/dev:/dev", "--net=host", "--pid=host", "--ipc=host")
        for limits in ((), ("--cpus=2",), ("--memory=1g",), ("--cpus=0", "--memory=1g"),
                       (*CAPS, "--memory=0"), ("--cpus=2", "--memory=0g")):
            with self.subTest(limits=limits):
                result = self.invoke(*allowed, "create", *flags, *limits, "fixture")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("--cpus and --memory", result.stderr)
        self.assertEqual(self.calls(), [])
        result = self.invoke(*allowed, "create", *flags, *CAPS, "fixture")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[-1]["argv"], ["-H", SOCKET, "create", *flags, *CAPS, "fixture"])

    def test_exec_and_start_only_reach_preexisting_capped_containers(self) -> None:
        for args in (("exec", "fixture", "true"), ("start", "-a", "fixture")):
            with self.subTest(args=args):
                result = self.invoke(*args, FAKE_NANO_CPUS="0")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("--cpus and --memory", result.stderr)
                self.assertEqual(self.calls()[-1]["argv"][2:4], ["container", "inspect"])
                result = self.invoke(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("a" * 64, self.calls()[-1]["argv"])

    def test_cache_compose_only_uses_the_fixed_capped_stack(self) -> None:
        result = self.invoke("apt-cache", "up", CERALIVE_APT_CACHE_CONFIG="/dev")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("host devices", result.stderr)
        result = self.invoke("apt-cache", "up")
        self.assertEqual(result.returncode, 0, result.stderr)
        compose = ROOT / "ci/apt-cache/compose.yml"
        self.assertEqual(self.calls()[-1]["argv"],
                         ["-H", SOCKET, "compose", "-f", str(compose), "up", "-d", "--wait"])
        cache = yaml.safe_load(compose.read_text())["services"]["apt-cache"]
        self.assertGreater(cache["cpus"], 0)
        self.assertEqual(cache["mem_limit"], "512m")

    def test_local_build_cannot_schedule_uncapped_buildkit_work(self) -> None:
        result = self.invoke("build", "-t", "scratch", ".")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("use a prebuilt builder image", result.stderr)
        self.assertEqual([row["argv"][:2] for row in self.calls()], [["context", "inspect"]])

    def test_no_raw_container_start_in_repo_scripts(self) -> None:
        result = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            cwd=ROOT, env={**os.environ, "GIT_MASTER": "1"}, capture_output=True, text=True, check=True,
        )
        raw = re.compile(
            r"""(?:^|[\s;|(&`'"/])(?:docker|podman|\$\{?(?:runtime|RUNTIME|BUILD_MODE)\}?)[\'"]?\s+"""
            r"""(?:container\s+)?(?:run|exec|create|start)\b|"""
            r"""\[\s*['"](?:docker|podman)['"]\s*,\s*['"](?:run|exec|create|start)['"]""")
        unexpected = []
        self.maxDiff = None
        for name in sorted(set(result.stdout.rstrip("\0").split("\0"))):
            path = ROOT / name
            if not path.is_file() or name.startswith(".github/") or path.name in (
                "container_engine_test.py", "container-engine.py"
            ):
                continue
            if path.suffix not in (".sh", ".bash", ".bats", ".py") and name not in (
                "build", "dev-push", "dev-cache", "run-tests"
            ):
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if name == "tests/release-cache-contract.test.sh" and line.strip() == (
                    '"docker run --rm --read-only --network none",'
                ):
                    continue  # Asserts a hosted-only workflow command, never executes it.
                line = re.sub(r'(?:container_engine|container-engine\.py["\']?)\s+["\']?'
                              r'(?:docker|podman|\$\{?(?:runtime|RUNTIME|BUILD_MODE)\}?)["\']?(?=\s)',
                              "guarded_engine", line)
                if line.lstrip().startswith(("#", "assert ", "[[ ")) or not raw.search(line):
                    continue
                unexpected.append(f"{name}:{number}: {line.strip()}")
        self.assertEqual(unexpected, [])


if __name__ == "__main__":
    main()
