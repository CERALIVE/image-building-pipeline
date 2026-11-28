"""Check the workstation container boundary without a daemon.

The static scan is a best-effort tripwire for accidental raw launches in
well-formed source. It does not resolve eval, constructed command strings, or
generated scripts. Runtime guarantees come from ci/container-engine.py and
launcher refusals, not from the scan.
"""

import ast
import fcntl
import json
import os
from collections.abc import Iterator
from pathlib import Path
import pty
import re
import shlex
import subprocess
import sys
import termios
import tempfile
from unittest import TestCase, main
import yaml

ROOT = Path(__file__).resolve().parents[1]
# ci/container-engine.py relaxes its CI-job and display gates inside a disposable VM guest, which it
# detects through this fw_cfg directory. The build VM has it and a laptop does not, so every run pins
# the answer and the suite means the same thing everywhere.
GUEST_PATH = "/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive"
PIN_GUEST = (
    "import pathlib, runpy, sys\n"
    "guest = sys.argv.pop(1) == 'guest'\n"
    f"path = {GUEST_PATH!r}\n"
    "is_dir = pathlib.Path.is_dir\n"
    "pathlib.Path.is_dir = lambda self, *a, **k: guest if str(self) == path else is_dir(self, *a, **k)\n"
    "sys.argv = sys.argv[1:]\n"
    "runpy.run_path(sys.argv[0], run_name='__main__')\n"
)


def engine_wrapper(guest: bool) -> list[str]:
    return [sys.executable, "-c", PIN_GUEST, "guest" if guest else "host",
            str(ROOT / "ci/container-engine.py")]


WRAPPER = engine_wrapper(False)
SOCKET = "unix:///var/run/docker.sock"
SESSION = ("DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XAUTHORITY",
           "DBUS_SESSION_BUS_ADDRESS", "SSH_TTY")
CAPS = ("--cpus", "2", "--memory=1g")
ACTION_REPO = "CERALIVE/image-building-pipeline"
AUDIT_JOB = {
    "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted", "GITHUB_REPOSITORY": ACTION_REPO,
    "GITHUB_WORKFLOW_REF": f"{ACTION_REPO}/.github/workflows/real-build-audit.yml@refs/heads/master",
    "GITHUB_EVENT_NAME": "schedule", "GITHUB_REF": "refs/heads/master", "DOCKER_CONTEXT": "default",
}
ENGINES = {"docker", "podman", "docker-compose", "podman-compose", "podman-docker", "nerdctl", "buildx"}
VERBS = {"run", "exec", "create", "start", "build", "buildx", "compose", "up", "down", "restart",
         "pull", "push", "load", "save", "image", "container", "info", "ps", "inspect", "logs",
         "cp", "export", "rm", "stop", "attach", "system", "context", "builder"}
ENGINE_VAR = re.compile(r"\$(?:\{)?(?:[A-Z_]*(?:docker|podman|nerdctl)[A-Z_]*|"
                        r"runtime|build_mode|container_engine)(?::[-+][^}]+)?\}?", re.I)
GLOBAL_VALUE = {"-H", "--host", "--context", "--config", "-l", "--log-level", "--namespace",
                "-n", "--address", "-a", "-f", "--file", "-p", "--project-name",
                "--project-directory", "--env-file"}
ENGINE_TEXT = r"(?:docker(?:-compose)?|podman(?:-compose|-docker)?|nerdctl|buildx)"
INLINE_ENGINE = re.compile(
    rf"""(?:^|[\s"'`/(]){ENGINE_TEXT}["']?\s+(?:--?\S+\s+)*(?:{'|'.join(sorted(VERBS))})\b"""
)
INLINE_CODE = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")
DISCOVER_ENGINE = re.compile(
    rf"\$\(\s*(?:command\s+-v|which|type\s+-p)\s+({ENGINE_TEXT})\s*\)"
)


def engine_verb(tokens: list[str], index: int) -> str:
    j = index + 1
    while j < len(tokens) and tokens[j].startswith("-") and tokens[j] != "--":
        j += 2 if tokens[j] in GLOBAL_VALUE else 1
    if tokens[j:j + 1] == ["--"]:
        j += 1
    return tokens[j] if j < len(tokens) else ""


def raw_engine(line: str, aliases: set[str] | None = None, verbs: set[str] = VERBS) -> bool:
    """Recognize ordinary shell dispatch without running or expanding shell input."""
    line = DISCOVER_ENGINE.sub(r"\1", line)
    lexer = shlex.shlex(line, posix=True, punctuation_chars="();|&<>`")
    lexer.whitespace_split = True
    aliases = aliases if aliases is not None else set()
    try:
        tokens = list(lexer)
    except ValueError:
        # A multiline quoted payload may start after a valid wrapper invocation.
        prefix = re.sub(r'\b(?:[^\s"\']*/)?container-engine\.py\s+["\']?docker["\']?\b',
                        "guarded_engine", line)
        return bool(INLINE_ENGINE.search(prefix))
    for index, token in enumerate(tokens):
        assignment = re.fullmatch(r"(\w+)=(.+)", token)
        if assignment and assignment[2].rsplit("/", 1)[-1] in ENGINES:
            aliases.add(assignment[1])
        if " " in token:
            # Quoted command bodies (e.g. EXIT traps or a shell -c operand).
            if (index and tokens[index - 1] in {"trap", "-c", "command:"}) or "$(" in token:
                if raw_engine(token, aliases, verbs):
                    return True
            continue
        if token.startswith('"') and token.endswith('",'):
            if raw_engine(token[1:-2], aliases, verbs):
                return True
            continue
        fallback = re.fullmatch(r"\$\{\w+:-([^}]+)\}", token)
        executable = fallback[1] if fallback else token
        variable = re.fullmatch(r"\$\{?(\w+)\}?", token)
        if (executable.rsplit("/", 1)[-1] not in ENGINES
                and not ENGINE_VAR.fullmatch(token) and not (variable and variable[1] in aliases)):
            continue
        if index and tokens[index - 1].rsplit("/", 1)[-1] in {"container-engine.py", "container_engine"}:
            continue
        if engine_verb(tokens, index) in verbs:
            return True
    return False


def python_engine_lines(text: str) -> Iterator[tuple[int, str]]:
    """Inspect literal argv and command arguments without importing the scanned file."""
    lines = text.splitlines()

    def command_text(node: ast.AST) -> str:
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        if isinstance(node, ast.JoinedStr):
            return "".join(command_text(part) if isinstance(part, ast.Constant) else "__value__"
                           for part in node.values)
        return ""

    nodes = list(ast.walk(ast.parse(text)))
    commands = {target.id for node in nodes if isinstance(node, ast.Assign)
                and raw_engine(command_text(node.value), verbs=VERBS | {"__value__"})
                for target in node.targets if isinstance(target, ast.Name)}
    for node in nodes:
        if isinstance(node, (ast.List, ast.Tuple)):
            args = [item.value if isinstance(item, ast.Constant) and isinstance(item.value, str)
                    else "" for item in node.elts]
            suspect = bool(args and args[0].rsplit("/", 1)[-1] in ENGINES and engine_verb(args, 0) in VERBS)
        elif isinstance(node, ast.Call):
            arguments = [*node.args[:1], *(item.value for item in node.keywords if item.arg in {"args", "cmd"})]
            suspect = any(raw_engine(command_text(arg), verbs=VERBS | {"__value__"})
                          or (isinstance(arg, ast.Name) and arg.id in commands)
                          for arg in arguments)
        else:
            continue
        if suspect:
            yield node.lineno, lines[node.lineno - 1]


def yaml_run_blocks(text: str) -> Iterator[tuple[int, str]]:
    """Read YAML scalars so folded and literal shell blocks keep their distinct semantics."""
    if not re.search(r"(?m)^\s*(?:-\s+)?run:\s", text):
        return
    pending = list(yaml.compose_all(text, Loader=yaml.BaseLoader))
    seen: set[int] = set()
    while pending:
        node = pending.pop()
        if id(node) in seen:
            continue
        seen.add(id(node))
        if isinstance(node, yaml.MappingNode):
            for key, value in node.value:
                if isinstance(key, yaml.ScalarNode) and key.value == "run" and isinstance(value, yaml.ScalarNode):
                    yield value.start_mark.line + 1, value.value
                else:
                    pending.append(value)
        elif isinstance(node, yaml.SequenceNode):
            pending.extend(node.value)


def engine_lines(path: Path, text: str) -> Iterator[tuple[int, str]]:
    """Yield suspicious instructions from source and copyable examples."""
    if path.suffix == ".py":
        yield from python_engine_lines(text)
        return
    fenced = False
    aliases: set[str] = set()
    recipe = path.name.casefold() in {"makefile", "gnumakefile", "justfile"} or path.suffix == ".mk"
    shell = path.suffix in {".sh", ".bash", ".bats"} or recipe or text.startswith(
        ("#!/bin/sh", "#!/bin/bash", "#!/usr/bin/env sh", "#!/usr/bin/env bash")
    )
    markup = path.suffix in {".md", ".yml", ".yaml"} or recipe or path.name == "package.json"
    lines = text.splitlines()
    if path.suffix in {".yml", ".yaml"}:
        for number, block in yaml_run_blocks(text):
            if any(engine_lines(Path("run.sh"), block)):
                yield number, lines[number - 1]
    for index, line in enumerate(lines):
        if index and lines[index - 1].endswith("\\"):
            continue
        stripped = line.strip()
        if path.suffix == ".md":
            if stripped.startswith(("```", "~~~")):
                fenced = not fenced
                continue
            if not fenced:
                # In prose, flag copyable actions, not mentions such as `docker build`.
                for span in INLINE_CODE.finditer(stripped):
                    code = span[2]
                    if raw_engine(code, verbs={"run", "exec", "create", "start", "compose", "buildx",
                                               "up", "down", "restart"}):
                        yield index + 1, line
                        break
                continue
        payload = stripped.removeprefix("#").strip()
        if recipe:
            payload = payload.lstrip("@-+")
            assignment = re.fullmatch(r"(\w+)\s*[?:+]?=\s*(\S+)", payload)
            if assignment and assignment[2].rsplit("/", 1)[-1] in ENGINES:
                aliases.add(assignment[1])
            payload = re.sub(r"\$\(([A-Za-z_]\w*)\)", r"${\1}", payload)
        if stripped.startswith("#") and not re.match(
            rf"(?:(?:sudo|env|command|exec|xargs)\s+|[^\s]*?/)*{ENGINE_TEXT}\b", payload
        ):
            continue  # Explanatory comments are not command examples.
        end = index
        while lines[end].endswith("\\") and end + 1 < len(lines):
            end += 1
            payload = payload.removesuffix("\\") + lines[end].strip()
        suspect = raw_engine(payload, aliases) if shell or markup or stripped.startswith("#") else False
        if markup and not suspect and not ("container-engine.py" in payload or "container_engine " in payload):
            suspect = bool(INLINE_ENGINE.search(payload))
        if suspect:
            yield index + 1, line


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
                              session=os.getsid(0) == os.getpid(), env=list(os.environ),
                              buildkit=os.environ.get('DOCKER_BUILDKIT'))) + '\\n')
if args[:2] == ['context', 'inspect']:
    print(os.environ['FAKE_CONTEXT'] + '|' + os.environ['FAKE_ENDPOINT'])
elif args == ['--version']:
    print('Docker version 29.7.2')
elif args[2:3] == ['info']:
    print(os.environ.get('FAKE_DAEMON_OS', 'Debian GNU/Linux'))
elif args[2:5] == ['buildx', 'inspect', 'default']:
    print('Driver:', os.environ.get('FAKE_BUILDX_DRIVER', 'docker'))
    print('Endpoint:', os.environ.get('FAKE_BUILDX_ENDPOINT', 'default'))
    print('BuildKit version:', os.environ.get('FAKE_BUILDKIT_VERSION', 'v0.32.2'))
elif args[2:4] == ['image', 'inspect'] and os.environ.get('FAKE_COLD_CACHE') == '1':
    sys.exit(1)
elif args[2:4] == ['container', 'inspect']:
    print(json.dumps([dict(Id='a' * 64, Config=dict(Tty=False, OpenStdin=False), Mounts=[],
                           HostConfig=dict(NanoCpus=int(os.environ['FAKE_NANO_CPUS']),
                                           Memory=1073741824, NetworkMode='bridge',
                                           Privileged=False, PidMode='', IpcMode='private', Devices=[]))]))
""")
        fake.chmod(0o700)
        # The repo's shell helpers launch the engine themselves; pin the VM answer for them too.
        (root / "pin_guest.py").write_text(PIN_GUEST)
        shim = root / "python3"
        shim.write_text("#!/bin/bash\n"
                        'if [[ "${1:-}" == */ci/container-engine.py ]]; then\n'
                        f'  exec {sys.executable} {root}/pin_guest.py host "$@"\nfi\n'
                        f'exec {sys.executable} "$@"\n')
        shim.chmod(0o700)
        (root / "podman").symlink_to(fake)
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

    def test_protected_actions_jobs_build_cold_mkosi_and_rauc_images(self) -> None:
        release_job = {**AUDIT_JOB, "GITHUB_REF": "refs/tags/v2026.11.3", "GITHUB_EVENT_NAME": "push",
                       "GITHUB_TRIGGERING_ACTOR": "andrescera",
                       "GITHUB_WORKFLOW_REF": f"{ACTION_REPO}/.github/workflows/release.yml@refs/tags/v2026.11.3"}
        for job, kind, platform in ((AUDIT_JOB, "mkosi", None), (AUDIT_JOB, "rauc", "linux/arm64"),
                                    (release_job, "rauc", "linux/amd64")):
            with self.subTest(kind=kind, platform=platform):
                script = """
case "$2" in
    mkosi)
        source "$1/lib/common.sh"
        source "$1/lib/stages/mkosi.sh"
        MKOSI_BUILDER_IMAGE_OVERRIDDEN=0 MKOSI_BUILDER_IMAGE=fixture-mkosi
        MKOSI_BUILDER_DOCKERFILE="$1/ci/Dockerfile"
        MKOSI_VERSION_PIN=26 MKOSI_PYTHON_FLOOR=3.12
        ensure_builder_image docker
        ;;
    rauc)
        source "$1/lib/build-rauc.sh"
        ensure_rauc_builder_image docker fixture-base fixture-rauc "$3"
        ;;
esac
"""
                result = subprocess.run(["bash", "-c", script, "fixture", str(ROOT), kind, platform or ""],
                                        env={**self.headless_env(), **job, "FAKE_COLD_CACHE": "1",
                                             "CERALIVE_APT_PROXY": "http://127.0.0.1:3142" if job == AUDIT_JOB else "off",
                                             "BUILDX_BUILDER": "unexpected",
                                             "BUILDKIT_HOST": "tcp://unexpected:1234"},
                                        stdin=subprocess.DEVNULL, start_new_session=True,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = self.calls()
                self.assertTrue(any(row["argv"][2:4] == ["image", "inspect"] for row in calls))
                [build] = [row for row in calls if row["argv"][2:4] == ["buildx", "build"]]
                expected = ["-H", SOCKET, "buildx", "build", "--builder=default", "--resource=cpu-period=100000",
                            "--resource=cpu-quota=400000", "--resource=memory=16g", "--resource=memory-swap=16g"]
                if platform:
                    expected += ["--platform", platform, "--build-arg", "BASE_IMAGE=fixture-base"]
                if job == AUDIT_JOB:
                    expected += ["--add-host", "host.docker.internal:host-gateway",
                                 "--build-arg", "APT_PROXY=http://host.docker.internal:3142"]
                expected += ["-t", f"fixture-{kind}", "-f",
                             str(ROOT / ("ci/Dockerfile.rauc" if platform else "ci/Dockerfile")), str(ROOT / "ci")]
                self.assertEqual(build["argv"], expected)
                self.assertEqual(build["buildkit"], "1")
                self.assertEqual(build["stdin"], "/dev/null")
                self.assertTrue(build["session"])
                self.assertFalse(set(SESSION) & set(build["env"]))
                self.assertFalse({"BUILDX_BUILDER", "BUILDKIT_HOST"} & set(build["env"]))
                self.log.unlink()

    def headless_env(self) -> dict[str, str]:
        return {key: value for key, value in self.env.items() if key not in SESSION}

    def test_disposable_guest_skips_job_and_display_gates_but_keeps_option_checks(self) -> None:
        recipe = ["docker", "build", "-t", "fixture", "-f", str(ROOT / "ci/Dockerfile"), str(ROOT / "ci")]
        env = {**self.headless_env(), "DISPLAY": ":0"}  # no CI job identity and a display
        run = lambda wrapper, command: subprocess.run(  # noqa: E731
            [*wrapper, *command], env=env, stdin=subprocess.DEVNULL, start_new_session=True,
            capture_output=True, text=True, timeout=10)
        host = run(engine_wrapper(False), recipe)
        self.assertNotEqual(host.returncode, 0)
        self.assertIn("use a prebuilt builder image", host.stderr)
        guest = run(engine_wrapper(True), recipe)
        self.assertEqual(guest.returncode, 0, guest.stderr)
        unsafe = run(engine_wrapper(True), ["docker", "build", "--privileged", "-t", "fixture", "."])
        self.assertNotEqual(unsafe.returncode, 0)
        self.assertIn("unsupported", unsafe.stderr)

    def test_cold_build_refuses_terminal_desktop_untrusted_job_and_unsafe_options(self) -> None:
        command = [*WRAPPER, "docker", "build", "-t", "fixture", "."]
        env = {**self.headless_env(), **AUDIT_JOB}
        for overrides, options, reason in (
            ({"DOCKER_HOST": "unix:///home/example/.docker/desktop/docker.sock"}, [], "system Docker socket"),
            ({"DOCKER_CONTEXT": "desktop-linux"}, [], "system Docker socket"),
            ({"GITHUB_WORKFLOW_REF": f"{ACTION_REPO}/.github/workflows/v2-ci.yml@refs/pull/300/merge"},
             [], "use a prebuilt builder image"),
            ({"GITHUB_ACTIONS": "", "RUNNER_ENVIRONMENT": "github-hosted"}, [], "use a prebuilt builder image"),
            ({"DISPLAY": ":0"}, [], "headless"),
            ({"WAYLAND_DISPLAY": "wayland-0"}, [], "headless"),
            ({"FAKE_CONTEXT": "desktop-linux"}, [], "system Docker socket"),
            ({}, ["--allow=security.insecure"], "unsupported"),
            ({}, ["--privileged"], "unsupported"),
            ({}, ["--device=/dev/kvm"], "unsupported"),
            ({}, ["-v", "/dev/tty:/dev/tty"], "unsupported"),
            ({}, ["--resource=memory=0"], "unsupported"),
            ({}, ["--builder=remote"], "unsupported"),
            ({}, ["--build-arg", "BUILDKIT_SYNTAX=remote"], "unsupported"),
        ):
            with self.subTest(overrides=overrides, options=options):
                result = subprocess.run([*command[:-1], *options, "."], env={**env, **overrides},
                                        stdin=subprocess.DEVNULL, start_new_session=True,
                                        capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(reason, result.stderr)
        master, slave = pty.openpty()
        try:
            result = subprocess.run(command, env=env, stdin=slave, start_new_session=True,
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("headless", result.stderr)

            def controlling_terminal() -> None:
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

            result = subprocess.run(command, env=env, stdin=subprocess.DEVNULL, start_new_session=True,
                                    pass_fds=(slave,), preexec_fn=controlling_terminal,
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("headless", result.stderr)
        finally:
            os.close(slave)
            os.close(master)
        self.assertTrue(all(row["argv"][:2] == ["context", "inspect"] for row in self.calls()))

    def test_cold_build_refuses_wrong_repository_or_non_owner(self) -> None:
        release_ref = "refs/tags/v2026.11.3"
        for case, overrides in (
            ("wrong repository", {"GITHUB_REPOSITORY": "fixture/other-repo"}),
            ("non-owner release", {
                "GITHUB_EVENT_NAME": "push", "GITHUB_REF": release_ref,
                "GITHUB_WORKFLOW_REF": f"{ACTION_REPO}/.github/workflows/release.yml@{release_ref}",
                "GITHUB_TRIGGERING_ACTOR": "fixture-contributor",
            }),
            ("non-owner manual audit", {
                "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_TRIGGERING_ACTOR": "fixture-contributor",
            }),
        ):
            with self.subTest(case=case):
                self.log.unlink(missing_ok=True)
                result = subprocess.run([*WRAPPER, "docker", "build", "-t", "fixture",
                                         "-f", str(ROOT / "ci/Dockerfile"), str(ROOT / "ci")],
                                        env={**self.headless_env(), **AUDIT_JOB, **overrides},
                                        stdin=subprocess.DEVNULL, start_new_session=True,
                                        capture_output=True, text=True, timeout=5)
                self.assertFalse(any(row["argv"][2:4] == ["buildx", "build"] for row in self.calls()),
                                 "unauthorized job reached BuildKit dispatch")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("use a prebuilt builder image", result.stderr)

    def test_cold_build_refuses_unbounded_or_nonlocal_builder(self) -> None:
        env = {**self.headless_env(), **AUDIT_JOB}
        for overrides, reason in (
            ({"FAKE_DAEMON_OS": "Docker Desktop"}, "Docker Desktop"),
            ({"FAKE_BUILDKIT_VERSION": "v0.30.0"}, "resource limits"),
            ({"FAKE_BUILDX_DRIVER": "docker-container"}, "default Docker driver"),
            ({"FAKE_BUILDX_ENDPOINT": "tcp://other:2375"}, "default Docker driver"),
        ):
            with self.subTest(overrides=overrides):
                result = subprocess.run([*WRAPPER, "docker", "build", "-t", "fixture",
                                         "-f", str(ROOT / "ci/Dockerfile"), str(ROOT / "ci")],
                                        env={**env, **overrides}, stdin=subprocess.DEVNULL,
                                        start_new_session=True, capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(reason, result.stderr)
        self.assertFalse(any(row["argv"][2:4] == ["buildx", "build"] for row in self.calls()))

    def test_legacy_builder_inspects_and_launches_through_the_guard(self) -> None:
        script = """
source "$1/lib/build-kernel.sh"
ensure_kernel_builder_image docker fixture-base fixture-tag
runtime=docker
"$runtime" "$2" --rm fixture-tag true
"""
        command = ["bash", "-c", script, "fixture", str(ROOT), "run"]
        result = subprocess.run(command, cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [row for row in self.calls() if row["argv"][:2] != ["context", "inspect"]]
        self.assertEqual([row["argv"] for row in calls], [
            ["-H", SOCKET, "info", "--format", "{{.OperatingSystem}}"],
            ["-H", SOCKET, "image", "inspect", "fixture-tag"],
            ["-H", SOCKET, "run", "--cpus=4", "--memory=16g", "--rm", "fixture-tag", "true"],
        ])
        for child in calls:
            self.assertEqual(child["stdin"], "/dev/null")
            self.assertTrue(child["session"])
            self.assertFalse(set(SESSION) & set(child["env"]))

        self.log.unlink()
        result = subprocess.run(command, cwd=ROOT, env={**self.env, "DOCKER_CONTEXT": "desktop-linux"},
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("system Docker socket", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_legacy_rauc_inspection_and_podman_fallback_cannot_bypass_guard(self) -> None:
        script = """
source "$1/lib/build-rauc.sh"
ensure_rauc_builder_image "$2" fixture-base fixture-tag linux/amd64
"""
        prefix = ["bash", "-c", script, "fixture", str(ROOT)]
        result = subprocess.run([*prefix, "docker"], cwd=ROOT, env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[-1]["argv"], ["-H", SOCKET, "image", "inspect", "fixture-tag"])
        self.log.unlink()
        result = subprocess.run([*prefix, "podman"], cwd=ROOT, env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("system Docker socket", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_no_raw_container_start_in_repo_scripts(self) -> None:
        result = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            cwd=ROOT, env={**os.environ, "GIT_MASTER": "1"}, capture_output=True, text=True, check=True,
        )
        allowed_paths = {
            # These invoke the real CLI on hosted runners, not workstation builds.
            ".github/workflows/kernel-release.yml", ".github/workflows/real-build-audit.yml",
            ".github/workflows/release-candidate-build.yml", ".github/workflows/v2-ci.yml",
            # This is the boundary that implements the policy.
            "ci/container-engine.py",
            # The guard must be able to spell its inert negative probes.
            "tests/container_engine_test.py",
        }
        # These legacy dispatches retain their master bytes. Each follows
        # assert_container_daemon_supported, which binds the shell command to the guard.
        # The immutable kernel gate hashes lib/build-kernel.sh and lib/kernel/builder.sh.
        guarded_legacy = {
            "lib/build-kernel.sh": (
                """trap "${runtime} run --rm -v '${work}/src:/src' '${KERNEL_BUILDER_IMAGE_TAG}' bash -c """
                """'find /src -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'; rm -rf '${work}'" EXIT""",
                '"${runtime}" run "${container_args[@]}" -e KERNEL_EPOCH_ONLY=1 \\',
                'builder_packages="$("${runtime}" run --rm "${KERNEL_BUILDER_IMAGE_TAG}" \\',
                'builder_compiler="$("${runtime}" run --rm "${KERNEL_BUILDER_IMAGE_TAG}" aarch64-linux-gnu-gcc --version)" \\',
                """builder_digest="$("${runtime}" image inspect --format '{{.Id}}' "${KERNEL_BUILDER_IMAGE_TAG}")" \\""",
                '"${runtime}" run "${container_args[@]}" "${KERNEL_BUILDER_IMAGE_TAG}" \\',
            ),
            "lib/kernel/builder.sh": ('if "${runtime}" image inspect "${tag}" >/dev/null 2>&1; then',),
            "lib/rauc-build/builder.sh": ('if "${runtime}" image inspect "${tag}" >/dev/null 2>&1; then',),
            # Baked payload uses only the daemon inside the disposable guest.
            "ci/kernel-runner/provision.sh": ("docker buildx version",),
            "ci/kernel-runner/image_guest.py": (
                'run_gate(["docker", "load", "-i", str(archive)], env=env, timeout=600,',
                'inspected, = json.loads(command(["docker", "image", "inspect", "--", tag], env),',
                'run_gate(["docker", "image", "save", "--platform", f"linux/{arch}", "--", tag],',
            ),
            # These literals match calls intercepted by the fake engine.
            "tests/image_route_test.py": (
                'if args[:2] == ["docker", "load"]:',
                'if args in (["docker", "image", "inspect", tag], ["docker", "image", "inspect", "--", tag]):',
                'assert args == ["docker", "image", "save", "--platform", "linux/arm64", "--", tag]',
            ),
        }
        unexpected = []
        self.maxDiff = None
        for name in sorted(set(result.stdout.rstrip("\0").split("\0"))):
            path = ROOT / name
            if not path.is_file() or name in allowed_paths:
                continue
            if (path.suffix not in {".sh", ".bash", ".bats", ".py", ".md", ".yml", ".yaml", ".example", ".mk", ""}
                    and not path.name.startswith("Dockerfile") and path.name != "package.json"):
                continue
            data = path.read_bytes()
            if b"\x00" in data:
                continue
            for number, line in engine_lines(path, data.decode("utf-8")):
                stripped = line.strip()
                if stripped in guarded_legacy.get(name, ()):
                    continue
                unexpected.append(f"{name}:{number}: {line.strip()}")
        self.assertEqual(unexpected, [])

    def test_static_scan_catches_inert_bypass_forms(self) -> None:
        probes = (
            "docker run fixture", "docker -H unix:///tmp/other.sock run fixture",
            "docker --host=unix:///tmp/other.sock create fixture",
            "docker --context other start fixture", "docker --config /tmp/other exec fixture true",
            "docker -l debug run fixture", "docker buildx build .", "docker compose up",
            "docker-compose -f compose.yml up", "podman-compose up", "nerdctl --namespace k8s.io run fixture",
            "podman-docker run fixture", "podman run fixture", "/usr/bin/docker --context other run fixture",
            "sudo docker run fixture", "env DOCKER_HOST=other docker run fixture",
            "command docker run fixture", "exec docker run fixture", "xargs -r docker run",
            "'docker' run fixture", '"$DOCKER" run fixture', "${DOCKER:-docker} run fixture",
            "${ENGINE:-/usr/bin/docker} run fixture", "cid=$(docker create fixture)", "docker \\\n  run fixture",
        )
        for probe in probes:
            with self.subTest(probe=probe):
                self.assertTrue(list(engine_lines(Path("probe.sh"), probe)), probe)
        for filename, probe in (
            ("probe.md", "```bash\n/usr/bin/docker --context other run fixture\n```"),
            ("compose.yml", 'command: "/usr/bin/docker run fixture"'),
            ("Makefile", "probe:\n\t@docker compose up"),
            ("justfile", "probe:\n  nerdctl run fixture"),
            ("package.json", '{"scripts": {"fixture": "docker buildx build ."}}'),
        ):
            with self.subTest(filename=filename):
                self.assertTrue(list(engine_lines(Path(filename), probe)), probe)
        self.assertFalse(list(engine_lines(Path("safe.sh"), 'container_engine "${runtime}" run fixture')))
        self.assertFalse(list(engine_lines(Path("safe.md"), """```bash
DOCKER_CONTEXT=default python3 ci/container-engine.py docker run --cpus=1 --memory=1g fixture
```""")))

    def test_static_scan_tracks_shell_assignments(self) -> None:
        for probe in (
            "engine=docker; $engine run fixture",
            'engine=/usr/bin/docker\n"$engine" --context other run fixture',
            'DOCKER=docker\n"$DOCKER" run fixture',
            'export runner="podman"\n"${runner}" run fixture',
            'runner=nerdctl\n"$runner" --namespace k8s.io run fixture',
            'runner=docker-compose\n"$runner" -f compose.yml up',
            '"${ENGINE:-docker}" run fixture',
        ):
            with self.subTest(probe=probe):
                self.assertTrue(list(engine_lines(Path("probe.sh"), probe)), probe)

    def test_static_scan_reads_python_launch_arguments(self) -> None:
        for probe in (
            'argv = ["docker", "--context", "desktop-linux", "run", "fixture"]',
            'subprocess.run(["/usr/bin/docker", "--config", config, "run", image])',
            'subprocess.run((\n "docker", "-H", address, "run", image,\n))',
            'subprocess.run(shlex.split("docker --context desktop-linux run fixture"))',
            'subprocess.run("sudo podman run fixture", shell=True)',
        ):
            with self.subTest(probe=probe):
                self.assertTrue(list(engine_lines(Path("probe.py"), probe)), probe)
        self.assertFalse(list(engine_lines(Path("safe.py"), 'status = "docker build is a cache operation"')))

    def test_static_scan_reads_inline_and_fenced_markdown(self) -> None:
        for probe in (
            "To start the service, run `docker compose up -d`.",
            "To start the service, run ``/usr/bin/docker --context other compose up``.",
            "```sh\ndocker-compose -f compose.yml up -d\n```",
        ):
            with self.subTest(probe=probe):
                self.assertTrue(list(engine_lines(Path("probe.md"), probe)), probe)
        self.assertFalse(list(engine_lines(Path("safe.md"),
            "Use `python3 ci/container-engine.py docker run --cpus=1 --memory=1g fixture`.")))

    def test_static_scan_reads_make_and_shell_discovery(self) -> None:
        for name, probe in (
            ("Makefile", 'DOCKER ?= docker\ncheck:\n\t@"$(DOCKER)" run fixture'),
            ("Makefile", 'ENGINE := /usr/bin/podman\ncheck:\n\t$(ENGINE) run fixture'),
            ("probe.sh", 'engine=$(command -v docker)\n"$engine" run fixture'),
            ("probe.sh", 'engine="$(which docker)"\n"$engine" run fixture'),
            ("probe.sh", 'engine=$(type -p docker); "$engine" -H socket run fixture'),
            ("probe.sh", '"$(which docker)" run fixture'),
        ):
            with self.subTest(probe=probe):
                self.assertTrue(list(engine_lines(Path(name), probe)), probe)
        self.assertFalse(list(engine_lines(Path("safe.sh"), "if command -v docker; then :; fi")))

    def test_static_scan_reads_python_formatted_and_keyword_commands(self) -> None:
        for probe in (
            'subprocess.run(f"docker run {image}", shell=True)',
            'subprocess.run(f"docker {sub}", shell=True)',
            'subprocess.run(shlex.split(f"docker --context {context} run fixture"))',
            'subprocess.run(args=["docker", "--context", context, "run", image])',
            'launch(cmd=f"docker run {image}")',
            'cmd = f"docker run {image}"\nlaunch(cmd=cmd)',
            'cmd = "docker --context other run fixture"\nsubprocess.check_output(cmd, shell=True)',
        ):
            with self.subTest(probe=probe):
                self.assertTrue(list(engine_lines(Path("probe.py"), probe)), probe)

    def test_static_scan_reads_yaml_run_blocks(self) -> None:
        for probe in (
            "steps:\n  - run: >\n      /usr/bin/docker\n      --context other\n      run fixture",
            "steps:\n  - run: |\n      docker \\\n        run fixture",
            'steps:\n  - run: "docker --context other run fixture"',
        ):
            with self.subTest(probe=probe):
                self.assertTrue(list(engine_lines(Path("probe.yml"), probe)), probe)
        self.assertFalse(list(engine_lines(Path("safe.yml"),
            "steps:\n  - run: |\n      docker\n      run fixture")))

    def test_mkosi_missing_system_engine_points_to_supported_setup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            podman = Path(directory) / "podman"
            for podman_only in (False, True):
                if podman_only:
                    podman.write_text("#!/bin/sh\nexit 99\n")
                    podman.chmod(0o700)
                with self.subTest(podman_only=podman_only):
                    result = subprocess.run(
                        ["/bin/bash", "-c", '''
source "$1/lib/common.sh"
source "$1/lib/stages/mkosi.sh"
PATH="$2"
MKOSI_VERSION_PIN=26 MKOSI_PYTHON_FLOOR=3.12 MKOSI_BUILDER_IMAGE=fixture select_build_mode
''', "fixture", str(ROOT), directory],
                        cwd=ROOT, env={"PATH": os.defpath}, capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("Docker Engine or Moby", result.stderr)
                    self.assertIn("unix:///var/run/docker.sock", result.stderr)
                    self.assertIn("DOCKER_CONTEXT=default", result.stderr)
                    self.assertIn("Docker Desktop and standalone Podman are refused", result.stderr)


if __name__ == "__main__":
    main()
