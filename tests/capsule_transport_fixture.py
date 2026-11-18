"""Socket boundary for capsule tests. Only the loopback fixture can receive a GET."""

import json
import os
from pathlib import Path
from functools import partial
import runpy
import socket
import sys
from urllib.parse import urlsplit


PUBLIC = "93.184.216.34"
PUBLIC_V6 = "2606:4700:4700::1111"
IDENTITY = 'identity "with":\\escapes'


def answers(work: Path, host: str) -> list[str]:
    return json.loads((work / "dns.json").read_text()).get(host, [])


def fixture_dns(work: Path, host: str, port: int, *, type: int) -> list[tuple]:
    return [(socket.AF_INET6 if ":" in ip else socket.AF_INET, type, 6, "", (ip, port))
            for ip in answers(work, host)]


def local_curl(work: Path, curl: str, port: int) -> None:
    args = sys.argv[1:]
    host = urlsplit(args[args.index("--url") + 1]).hostname
    routes = []
    if host in ("repo.example", "apt.armbian.com", "mirror-a.example", "mirror-b.example"):
        # Translate only the vetted production pin to the fixture's listening socket.
        ip = answers(work, host)[0]
        expected = f"{host}:443:" + (f"[{ip}]" if ":" in ip else ip)
        assert args[args.index("--resolve") + 1] == expected
        routes = ["--connect-to", f"{host}:443:{host}:{port}", "--resolve", f"{host}:{port}:127.0.0.1"]
    # Inspect the curl invocation and its live Python caller, without logging either.
    for pid in (os.getpid(), os.getppid()):
        for field in ("cmdline", "environ"):
            observed = Path(f"/proc/{pid}/{field}").read_bytes()
            for filename in ("client.pem", "client.key"):
                assert os.fsencode(work / IDENTITY / filename) not in observed, "identity path exposed"
    os.execv(curl, [curl, args[0], *routes, "--connect-to", f"::127.0.0.1:{port}", *args[1:]])


if __name__ == "__main__":
    # Install the offline resolver before either CLI can run.
    socket.getaddrinfo = partial(fixture_dns, Path(os.environ["TMPDIR"]))
    del sys.argv[0]
    runpy.run_path(sys.argv[0], run_name="__main__")
