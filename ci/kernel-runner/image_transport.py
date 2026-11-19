"""Host-only archive transport and input validation shared by both measurement CLIs."""

from __future__ import annotations

import argparse
from email.parser import BytesParser
import ipaddress
import json
import os
from pathlib import Path
import re
import resource
import runpy
import shlex
import socket
import stat
import subprocess
import sys
import threading
import time
from urllib.parse import urljoin, urlsplit

from image_capsule import original_url
from image_policy import ArchivePolicy, require_client_origin
from image_stream import ExclusiveFile, StreamError, positioned_open, read_check, retry_check, retry_io, unique_object

ROOT = Path(__file__).resolve().parents[2]
SEALED = runpy.run_path(str(ROOT / "lib/sealed-inputs.py"))
INDEX_LIMIT = SEALED["INDEX_LIMIT"]


def child_limit(length: int) -> None:
    """Bound downloaded/decompressed files independently of HTTP Content-Length."""
    resource.setrlimit(resource.RLIMIT_FSIZE, (length, length))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def read_json(path: Path) -> dict:
    return retry_check(_read_json, path)


def _read_json(path: Path) -> dict:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024:
        raise StreamError("missing, linked or oversized reviewed inventory")
    return json.loads(read_check(path), object_pairs_hook=unique_object)


def bsp_pin(url: str, target: Path, seconds: float) -> str:
    """Resolve once under the object deadline. Never give curl an unvetted answer."""
    rejected = f"BSP hop rejected for object {target.name}"
    parsed = urlsplit(url)
    host = parsed.hostname
    if not host:
        raise StreamError(f"{rejected}: missing DNS host")
    try:
        socket.inet_aton(host)  # Includes legacy numeric IPv4 spellings accepted by curl.
    except OSError:
        pass
    else:
        raise StreamError(f"{rejected}: IP literal")
    if ":" in host:
        raise StreamError(f"{rejected}: IP literal")
    if (not parsed.netloc.isascii() or parsed.netloc.lower() != host or len(host) > 253
            or not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
                                  for label in host.split(".")) or host.split(".")[-1] == "localhost"):
        raise StreamError(f"{rejected}: invalid DNS host")
    answers = []

    def resolve() -> None:
        try:
            answers.extend(socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM))
        except OSError:
            pass  # An empty answer fails closed below.

    # libc getaddrinfo has no timeout. A stalled resolver must not hold the CLI open.
    resolver = threading.Thread(target=resolve, daemon=True)
    resolver.start()
    resolver.join(min(10, seconds))
    if resolver.is_alive():
        raise StreamError(f"{rejected}: DNS timeout")
    if not answers:
        raise StreamError(f"{rejected}: no DNS addresses")
    pins = []
    for family, _, _, _, address in answers:
        if family not in (socket.AF_INET, socket.AF_INET6):
            raise StreamError(f"{rejected}: unsupported address family")
        ip = ipaddress.ip_address(address[0])
        if isinstance(ip, ipaddress.IPv6Address):
            ip = ip.ipv4_mapped or ip
        if (not ip.is_global or ip.is_multicast or ip.is_reserved
                or ip in ipaddress.IPv4Network("192.88.99.0/24")
                or isinstance(ip, ipaddress.IPv6Address) and (ip.is_site_local or ip.sixtofour or ip.teredo)):
            raise StreamError(f"{rejected}: non-public address")
        pins.append(f"[{ip}]" if ip.version == 6 else str(ip))
    return f"{host}:443:{pins[0]}"


def fetch(url: str, target: Path, length: int, client: tuple[str, str] | None,
          ca_file: str | None, seconds: int, env: dict[str, str], repository: str, max_redirects: int) -> dict:
    """Bounded manual HTTPS GETs; redirects never carry a client identity."""
    if client:
        parsed = urlsplit(url)
        require_client_origin(f"{parsed.scheme}://{parsed.netloc}", repository)
    if max_redirects and (client or repository != "bsp"):
        raise StreamError("invalid archive redirect policy for a client identity")
    current = original_url(url)
    logical_path = urlsplit(current).path
    seen = {(urlsplit(current).hostname, logical_path)}
    redirects = []
    deadline = time.monotonic() + seconds
    while True:
        remaining = deadline - time.monotonic() if repository == "bsp" else seconds
        if remaining <= 0:
            raise StreamError(f"object timeout for object {target.name} at {current}")
        connect_time = min(10, remaining)
        pin = None
        if repository == "bsp":
            connect_deadline = deadline - remaining + connect_time
            pin = bsp_pin(current, target, remaining)
            now = time.monotonic()
            remaining = deadline - now
            connect_time = connect_deadline - now
            if connect_time <= 0:
                raise StreamError(f"object timeout for object {target.name} after DNS")
        args = ["curl", "--disable", "--silent", "--fail", "--globoff", "--noproxy", "*",
                "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "0",
                "--connect-timeout", str(connect_time), "--max-time", str(remaining),
                "--max-filesize", str(length), "--output", str(target),
                "--write-out", "%{http_code}"]
        if pin:
            args += ["--resolve", pin]
        config = None
        if client:
            # --cert parses filename[:password] after curl parses the config.
            cert = client[0].replace("\\", "\\\\").replace(":", "\\:")
            escapes = str.maketrans({"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r",
                                     "\t": "\\t", "\v": "\\v"})
            config = os.fsencode(f'cert = "{cert.translate(escapes)}"\n'
                                 f'key = "{client[1].translate(escapes)}"\n')
            args += ["-K", "-"]
        if ca_file:
            args += ["--cacert", ca_file]
        if max_redirects:
            # Raw Location preserves forbidden spellings that curl may normalize away.
            args += ["--dump-header", "-"]
        result = subprocess.run(args + ["--url", current], env=env, input=config,
                                stdin=None if client else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=remaining + 5, start_new_session=True,
                                preexec_fn=lambda: child_limit(length))
        headers, status = result.stdout[:-3], result.stdout[-3:]
        if result.returncode or status != b"200" and (
                not max_redirects or status not in (b"301", b"302", b"303", b"307", b"308")):
            # Never render curl stderr, server bytes or unvalidated redirect URLs.
            raise StreamError(f"exact HTTPS GET failed for object {target.name} at {current} "
                              f"(HTTP {status.decode(errors='replace')}, curl exit {result.returncode})")
        if max_redirects and time.monotonic() > deadline:
            raise StreamError(f"object timeout for object {target.name} at {current}")
        if max_redirects and len(headers) > 64 * 1024:
            raise StreamError(f"oversized response headers for object {target.name} at {current}")
        if status == b"200":
            return {"url": url, "redirects": redirects, "final_url": current} if redirects else {}
        if len(redirects) >= max_redirects:
            raise StreamError(f"redirect limit exceeded for object {target.name} at {current}")
        final_headers = headers.removesuffix(b"\r\n\r\n").rsplit(b"\r\n\r\n", 1)[-1].partition(b"\r\n")[2]
        locations = BytesParser().parsebytes(final_headers).get_all("Location", [])
        if len(locations) != 1:
            raise StreamError(f"missing or ambiguous redirect Location for object {target.name} at {current}")
        location = locations[0]
        try:
            if any(char.isspace() or ord(char) < 32 for char in location):
                raise StreamError("invalid sealed origin URL")
            joined = urljoin(current, location)
            hop = urlsplit(joined)
            if hop.port is not None:
                if hop.port != 443:
                    raise StreamError("BSP hop rejected: non-default port")
                joined = hop._replace(netloc=hop.netloc.rsplit(":", 1)[0]).geturl()
            destination = original_url(joined)
        except ValueError:
            raise StreamError(f"invalid BSP hop authority for object {target.name}") from None
        except StreamError as exc:
            raise StreamError(f"{exc} for object {target.name} at {current}") from exc
        parsed = urlsplit(destination)
        if not parsed.path.endswith(logical_path):
            raise StreamError(f"redirect target changes logical object path for object {target.name} at {current}")
        identity = (parsed.hostname, parsed.path)
        if identity in seen:
            raise StreamError(f"redirect loop for object {target.name} at {current}")
        seen.add(identity)
        redirects.append({"status": int(status), "from": current, "to": destination})
        current = destination


def shell(script: str, arguments: list[str], env: dict[str, str]) -> str:
    """Run only the repository's data validators, never package code."""
    result = subprocess.run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT),
                             *arguments], env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                            timeout=120, preexec_fn=lambda: child_limit(INDEX_LIMIT))
    if result.returncode:
        raise StreamError("signed package lookup or control identity rejected")
    return result.stdout.strip()


def identity_config(path: Path) -> list[list[str]]:
    """Check the directory and file descriptors used for the actual read."""
    try:
        from image_stream import open_directory, open_owned

        with open_directory(path.parent, os.O_NOFOLLOW) as directory_owner:
            directory = directory_owner.fileno()
            parent = os.fstat(directory)
            if parent.st_mode & 0o022 or parent.st_uid not in (0, os.getuid()):
                raise StreamError("client identity config directory must not be writable by others")
            with open_owned(path.name, flags=os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOCTTY,
                            dir_fd=directory) as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
                    raise StreamError("client identity config must be a regular file owned by the invoking user, mode 0600")
                data = stream.read(1024 * 1024 + 1)
    except OSError:
        raise StreamError("cannot open client identity config as a regular file without following symlinks") from None
    if len(data) > 1024 * 1024 or b"\0" in data:
        raise StreamError("invalid or oversized client identity config")
    try:
        return [shlex.split(line) for line in os.fsdecode(data).split("\n")
                if line.strip() and not line.lstrip().startswith("#")]
    except ValueError:
        raise StreamError("invalid quoting in client identity config") from None


def transport_clients(args: argparse.Namespace) -> dict[str, tuple[str, str]]:
    """Collect exact origin bindings before validating the archive policy."""
    clients = {}
    if args.client_identity:
        print("warning: --client-identity exposes credential paths in process arguments; "
              "use --client-identity-config instead", file=sys.stderr)
    rows = identity_config(args.client_identity_config) if args.client_identity_config is not None else []
    for row in [*args.client_identity, *rows]:
        if len(row) != 3:
            raise StreamError("client identity requires exactly ORIGIN CERT_PATH KEY_PATH")
        origin, cert, key = row
        require_client_origin(origin)
        if origin in clients:
            raise StreamError("duplicate client identity origin")
        if not Path(cert).is_absolute() or not Path(key).is_absolute():
            raise StreamError("client certificate and key must be explicit absolute paths")
        clients[origin] = (cert, key)
    if not 1 <= args.object_timeout <= 600:
        raise StreamError("object timeout must be between 1 and 600 seconds")
    return clients


def metadata_base(name: str, repo: ArchivePolicy) -> str:
    """Use the same exact distribution path for discovery and capsule preparation."""
    base = repo.origin + "/dists/" + (repo.codename or repo.suite)
    return base + "/binary-" + repo.arch if name == "firstparty" else base


def copy_local(source: Path, target: Path, length: int) -> None:
    """Snapshot only the reviewed number of bytes from a regular local input."""
    try:
        info = retry_io(source.lstat, recover=True)
    except FileNotFoundError as error:
        raise StreamError("local input is not a regular file of the approved size") from error
    if not stat.S_ISREG(info.st_mode) or info.st_size != length:
        raise StreamError("local input is not a regular file of the approved size")
    with positioned_open(source, nofollow=True) as stream, ExclusiveFile(target, 0o666) as output:
        output.open()
        remaining = length
        while remaining:
            chunk = stream.read(min(1024 * 1024, remaining))
            if not chunk:
                break
            output.write(chunk)
            remaining -= len(chunk)
        if remaining or stream.read(1):
            raise StreamError("local input changed from its approved size")


class TransportParser(argparse.ArgumentParser):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.add_argument("--client-identity-config", type=Path, metavar="FILE",
                          help="owned mode-0600 origin/certificate/key path mapping")
        self.add_argument("--client-identity", action="append", nargs=3, default=[],
                          metavar=("ORIGIN", "CERTIFICATE_PATH", "KEY_PATH"),
                          help="legacy form exposes paths in process arguments")

    def error(self, message: str) -> None:
        # Legacy invocations may have supplied credential paths as extra arguments.
        if message.startswith("the following arguments are required: "):
            super().error(message)
        super().error("invalid arguments (see --help)")
