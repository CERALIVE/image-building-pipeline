#!/usr/bin/env python3
"""Run repository container commands against the system Docker socket only."""

import csv
import json
import os
from pathlib import Path
import re
import subprocess
import sys

SOCKET = "unix:///var/run/docker.sock"
SESSION = {"DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS", "SSH_TTY"}
ACCESS = {"--allow-privileged", "--allow-host-devices", "--allow-host-namespaces", "--allow-host-network"}
VALUE_OPTIONS = {"--cpus", "--memory", "--platform", "--network", "--net", "--pid", "--ipc", "--device",
                 "--volume", "-v", "--mount", "--env", "-e", "--workdir", "-w", "--name", "--attach",
                 "--user", "-u", "--add-host", "--entrypoint", "--pull"}
SWITCHES = {"--rm", "--detach", "-d", "--privileged", "--read-only", "--tty", "-t", "--interactive", "-i",
            "-a", "--init"}


class Refused(ValueError):
    """An engine request violates the workstation launch policy."""


def require(access: set[str], flag: str, operation: str) -> None:
    if flag not in access:
        raise Refused(f"{operation} requires {flag}")


def device_path(path: str) -> bool:
    if "/" not in path and path not in {".", ".."}:
        return False
    resolved = os.path.realpath(path)
    return any(value == "/dev" or value.startswith("/dev/") for value in (path, resolved))


def positive(value: str, pattern: str) -> bool:
    return bool(re.fullmatch(pattern, value)) and any(char in "123456789" for char in value)


def launch_options(args: list[str], access: set[str], command: str) -> int:
    """Check engine options, stopping at the image/container before application argv."""
    i = 0
    caps = {}
    while i < len(args):
        word = args[i]
        if word == "--":
            i += 1
            break
        if not word.startswith("-"):
            break
        key, equal, value = word.partition("=")
        if re.fullmatch(r"-[itda]+", key) and ("i" in key or "t" in key):
            raise Refused("terminal options (-i/-t) are not allowed")
        if key in ("-t", "-i", "--tty", "--interactive"):
            raise Refused("terminal options (--tty/--interactive) are not allowed")
        if key.startswith(("-v", "-e", "-w", "-u")) and len(key) > 2:
            key, equal, value = word[:2], "=", word[2:]
        if key in VALUE_OPTIONS and not equal:
            i += 1
            if i == len(args):
                raise Refused(f"missing value for {key}")
            value = args[i]
        elif key not in VALUE_OPTIONS | SWITCHES:
            raise Refused(f"unsupported {command} option {key}")
        if command in ("exec", "start") and key not in {"-a", "--attach", "--detach", "-d", "-u", "--user",
                                                         "-e", "--env", "-w", "--workdir"}:
            raise Refused(f"unsupported {command} option {key}")
        if key == "--attach" and value == "stdin":
            raise Refused("terminal input attachment is not allowed")
        if key == "--privileged" and value != "false":
            require(access, "--allow-privileged", key)
        if key == "--device":
            require(access, "--allow-host-devices", key)
        if key in ("--net", "--network") and (value == "host" or value.startswith("container:")):
            require(access, "--allow-host-network", key)
        if key in ("--ipc", "--pid") and (value == "host" or value.startswith("container:")):
            require(access, "--allow-host-namespaces", key)
        if key in ("-v", "--volume") and any(device_path(path) for path in value.split(":")[:2]):
            require(access, "--allow-host-devices", key)
        if key == "--mount":
            fields = next(csv.reader([value], strict=True))
            if any(device_path(field.partition("=")[2]) for field in fields
                   if field.partition("=")[0].lower() in {"src", "source", "target", "dst", "destination"}):
                require(access, "--allow-host-devices", key)
        if key in ("--cpus", "--memory"):
            caps[key] = value
        i += 1
    if i == len(args):
        raise Refused(f"{command} requires an image or container")
    if command in ("run", "create") and not (
        positive(caps.get("--cpus", ""), r"(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)")
        and positive(caps.get("--memory", ""), r"[0-9]+[bBkKmMgG]?")
    ):
        raise Refused("positive --cpus and --memory caps are mandatory")
    return i


def docker_command(args: list[str]) -> int:
    if len(args) < 2 or args[0] != "docker":
        raise Refused("only the system Docker socket is supported; native Podman is not supported")
    access = set()
    tail = args[1:]
    while tail and tail[0] in ACCESS:
        access.add(tail[0])
        tail = tail[1:]
    if not tail:
        raise Refused("missing Docker command")
    command, *options = tail
    if command == "container" and options and options[0] in {"run", "create", "start", "exec"}:
        command, *options = options
    if command in {"run", "create", "start", "exec"}:
        operand = launch_options(options, access, command)
    elif command not in {"--version", "build", "info", "image", "pull", "load", "rm", "export", "cp",
                         "context", "apt-cache"}:
        raise Refused("unsupported Docker command")
    elif command == "image" and options[:1] != ["inspect"]:
        raise Refused("only Docker image inspect is supported")
    elif command == "context" and options[:1] != ["inspect"]:
        raise Refused("only Docker context inspect is supported")

    host, context = os.environ.get("DOCKER_HOST"), os.environ.get("DOCKER_CONTEXT")
    if host not in (None, "", SOCKET) or context == "desktop-linux":
        raise Refused("only the system Docker socket is allowed; select DOCKER_CONTEXT=default and unset other DOCKER_HOST values")
    env = {key: value for key, value in os.environ.items() if key not in SESSION}
    env.pop("DOCKER_HOST", None)
    child = dict(stdin=subprocess.DEVNULL, start_new_session=True, env=env)
    if command == "--version":
        return subprocess.run(["docker", "--version"], **child).returncode
    configured = subprocess.run(
        ["docker", "context", "inspect", "--format", "{{.Name}}|{{.Endpoints.docker.Host}}"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5, **child,
    )
    name, _, endpoint = configured.stdout.strip().partition("|")
    if configured.returncode or name == "desktop-linux" or endpoint != SOCKET:
        raise Refused("default Docker context must use unix:///var/run/docker.sock (the system Docker socket); use DOCKER_CONTEXT=default")
    if command == "context":
        # Expose only the endpoint already checked above, not the CLI's context store.
        if options != ["inspect", "default", "--format", "{{.Endpoints.docker.Host}}"] or name != "default":
            raise Refused("only the default system context endpoint can be queried")
        print(endpoint)
        return 0
    env.pop("DOCKER_CONTEXT", None)
    base = ["docker", "-H", SOCKET]
    if command == "apt-cache":
        if options not in (["up"], ["down"], ["status"]):
            raise Refused("apt-cache requires up, down or status")
        project = Path(__file__).resolve().parent / "apt-cache/compose.yml"
        config_file = Path(env.get("CERALIVE_APT_CACHE_CONFIG") or project.with_name("ceralive.conf"))
        # Compose resolves relative bind sources against its project directory.
        config_file = (project.parent / config_file).resolve()
        if device_path(str(config_file)) or ":" in str(config_file):
            raise Refused("APT cache configuration cannot bind host devices")
        if not config_file.is_file():
            raise Refused("APT cache configuration must be a regular file")
        env["CERALIVE_APT_CACHE_CONFIG"] = str(config_file)
        env.pop("COMPOSE_ENV_FILES", None)
        env["COMPOSE_DISABLE_ENV_FILE"] = "1"
        tails = {"up": ["up", "-d", "--wait"], "down": ["down"], "status": ["ps"]}
        command, options = "compose", ["-f", str(project), *tails[options[0]]]
    if command == "build":
        # BuildKit schedules inside the daemon, not inside the Docker CLI cgroup.
        if (env.get("RUNNER_ENVIRONMENT") != "github-hosted"
                and not Path("/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive").is_dir()):
            raise Refused("local BuildKit has no per-build CPU/memory caps; use a prebuilt builder image")
        env.pop("BUILDX_BUILDER", None)
    if command in {"exec", "start"}:
        if command == "start" and len(options) != operand + 1:
            raise Refused("start requires exactly one container")
        checked = subprocess.run([*base, "container", "inspect", "--", options[operand]],
                                 stdout=subprocess.PIPE, text=True, timeout=10, **child)
        if checked.returncode:
            return checked.returncode
        [row] = json.loads(checked.stdout)
        config, host_config = row["Config"], row["HostConfig"]
        if config["Tty"] or config["OpenStdin"]:
            raise Refused("terminal-enabled containers cannot be started or entered")
        if host_config["NanoCpus"] <= 0 or host_config["Memory"] <= 0:
            raise Refused("container needs existing --cpus and --memory caps")
        if host_config["Privileged"]:
            require(access, "--allow-privileged", "container")
        if host_config["Devices"] or any(
            device_path(mount[key]) for mount in row["Mounts"] if mount.get("Type") == "bind"
            for key in ("Source", "Destination")
        ):
            require(access, "--allow-host-devices", "container")
        if any(value == "host" or value.startswith("container:") for value in
               (host_config["PidMode"], host_config["IpcMode"])):
            require(access, "--allow-host-namespaces", "container")
        if host_config["NetworkMode"] == "host" or host_config["NetworkMode"].startswith("container:"):
            require(access, "--allow-host-network", "container")
        options[operand] = row["Id"]
    # Never send daemon/guest control bytes straight to an operator's terminal.
    if os.isatty(1) or os.isatty(2):
        print("Container output streams connected to a terminal are hidden; redirect to a log to retain them.",
              file=sys.stderr)
    return subprocess.run([*base, command, *options],
                          stdout=subprocess.DEVNULL if os.isatty(1) else None,
                          stderr=subprocess.DEVNULL if os.isatty(2) else None, **child).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(docker_command(sys.argv[1:]))
    except (ValueError, OSError, KeyError, TypeError, csv.Error, subprocess.SubprocessError) as error:
        print(f"container engine refused: {error}", file=sys.stderr)
        raise SystemExit(2)
