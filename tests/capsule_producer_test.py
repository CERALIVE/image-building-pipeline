#!/usr/bin/env python3
"""Real local HTTPS/mTLS and archive signatures; no external connections or credentials."""

from contextlib import contextmanager
from collections.abc import Iterator
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import lzma
import os
from pathlib import Path
import runpy
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
from unittest.mock import patch

from sealed_inputs_test import deb

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ci/kernel-runner"))
from image_capsule import unpack
from image_stream import Identity


def command(args: list[str], work: Path) -> bytes:
    return subprocess.run(args, cwd=work, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True, timeout=30).stdout


@contextmanager
def fixture(case: str = "valid", *, redirects: dict[str, tuple[int, str]] | None = None,
            require_client: bool = True) -> Iterator[tuple]:
    with tempfile.TemporaryDirectory(prefix="capsule-producer-test-") as temporary:
        work = Path(temporary)
        work.chmod(0o700)
        # Every key below is generated for this fixture. Never consult a host PKI.
        command(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                 "-keyout", "ca.key", "-out", "ca.pem", "-days", "1", "-subj", "/CN=Fixture CA",
                 "-addext", "basicConstraints=critical,CA:TRUE"], work)
        if case == "untrusted-tls":
            command(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                     "-nodes", "-keyout", "untrusted-ca.key", "-out", "untrusted-ca.pem", "-days", "1",
                     "-subj", "/CN=Untrusted fixture CA",
                     "-addext", "basicConstraints=critical,CA:TRUE"], work)
        for name in ("server", "client"):
            command(["openssl", "req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                     "-nodes", "-keyout", name + ".key",
                     "-out", name + ".csr", "-subj", "/CN=Fixture " + name], work)
            firstparty_name = "" if case == "hostname" else "DNS:apt.ceralive.tv,"
            extension = ("subjectAltName=" + firstparty_name + "DNS:deb.debian.org,"
                         "DNS:repo.example,DNS:other.example,DNS:apt.armbian.com,"
                         "DNS:mirror-a.example,DNS:mirror-b.example\nextendedKeyUsage=serverAuth\n"
                         if name == "server" else "extendedKeyUsage=clientAuth\n")
            (work / (name + ".ext")).write_text(extension)
            command(["openssl", "x509", "-req", "-in", name + ".csr", "-CA", "ca.pem",
                     "-CAkey", "ca.key", "-CAcreateserial", "-out", name + ".pem", "-days", "1",
                     "-extfile", name + ".ext"], work)
        home = work / "gnupg"
        home.mkdir(mode=0o700)
        gpg = ["gpg", "--homedir", str(home), "--batch", "--pinentry-mode", "loopback", "--passphrase", ""]
        command(gpg + ["--quick-generate-key", "Capsule fixture <fixture@example.invalid>",
                       "ed25519", "sign", "0"], work)
        fingerprint = next(line.split(":")[9] for line in
                           command(gpg + ["--with-colons", "--list-keys"], work).decode().splitlines()
                           if line.startswith("fpr:"))
        objects = []
        remote = {}

        def store(data: bytes, kind: str, url: str = "") -> str:
            digest = hashlib.sha256(data).hexdigest()
            row = {"sha256": digest, "length": len(data), "kind": kind, "urls": [url] if url else []}
            if url:
                remote[url] = data
            else:
                path = work / digest
                path.write_bytes(data)
                row["path"] = str(path)
            if not any(item["sha256"] == digest for item in objects):
                objects.append(row)
            return digest

        keyring = store(command(gpg + ["--export"], work), "apt-metadata")
        source = store(b"public source bundle fixture", "source-bundle")
        root = store((work / "ca.pem").read_bytes(), "public-trust")
        policies = {}
        repositories = {}
        packages = []
        metadata = {}
        for name in ("kernel-artifact.json", "resolved.config", "built-modules.txt", "SHA256SUMS"):
            metadata[name] = store(name.encode(), "kernel-metadata")
        builders = [{"object": store(("builder " + arch).encode(), "builder-image"),
                     "tag": "fixture:" + arch, "image_id": "sha256:" + "1" * 64, "arch": arch}
                    for arch in ("arm64", "amd64")]
        origins = [("firstparty", "https://apt.ceralive.tv"),
                   ("bsp", "https://apt.armbian.com" if case.startswith("bsp") else "https://repo.example"),
                   ("debian-source", "https://deb.debian.org/debian")]
        if case.startswith("codename") or case == "packages-xz":
            origins.append(("debian-binary", "https://deb.debian.org/debian"))
        for name, origin in origins:
            suite = "trixie" if case.startswith("codename") and name == "debian-binary" else "stable"
            if case == "packages-xz" and name == "debian-binary":
                suite = "stable-updates"
            base = origin + "/dists/" + suite
            if name == "firstparty":
                base += "/binary-arm64"
            index_path = "Packages.gz" if name == "firstparty" else "main/binary-arm64/Packages.gz"
            index_bytes = b"Package: source-fixture\n"
            if name != "debian-source":
                version = {"firstparty": "1.0", "bsp": "1.1", "debian-binary": "1.2"}[name]
                package = deb("9.0" if case == "control-version" and name == "firstparty" else version,
                              "amd64" if case == "control-arch" and name == "firstparty" else "arm64")
                filename = "ceralive-device_" + version + "_arm64.deb"
                url = (base if name == "firstparty" else origin) + "/" + filename
                digest = store(package, "deb", url)
                packages.append({"repository": name, "name": "ceralive-device", "version": version,
                                 "arch": "arm64", "sha256": digest})
                index_bytes = (f"Package: ceralive-device\nVersion: {version}\nArchitecture: arm64\n"
                               f"Filename: {filename}\nSize: {len(package)}\nSHA256: {digest}\n\n").encode()
                if case == "ambiguous" and name == "firstparty":
                    index_bytes += index_bytes
            if case == "packages-xz" and name in ("bsp", "debian-binary"):
                index_path = index_path.removesuffix(".gz") + ".xz"
            compressed = lzma.compress(index_bytes) if index_path.endswith(".xz") else gzip.compress(index_bytes)
            index_digest = hashlib.sha256(compressed).hexdigest()
            index = store(compressed + (b"tampered" if case == "index" and name == "firstparty" else b""),
                          "apt-metadata", base + "/" + index_path)
            now = datetime.now(timezone.utc)
            date = now - timedelta(days=2 if case == "expired" else 0, minutes=1)
            until = now + timedelta(days=-1 if case == "expired" else 1)
            signed_suite = "stable" if case.startswith("codename") and name == "debian-binary" else suite
            if name == "debian-binary" and case == "codename-suite-mismatch":
                signed_suite = "testing"
            component = "contrib" if name == "debian-binary" and case == "codename-component" else "main"
            architecture = "amd64" if name == "debian-binary" and case == "codename-arch" else "arm64"
            release = (f"Origin: {'Debian' if name.startswith('debian-') else name}\nSuite: {signed_suite}\n"
                       f"Components: {component}\nArchitectures: {architecture}\nDate: {format_datetime(date)}\n")
            if name == "debian-binary" and case != "codename-missing":
                release += "Codename: " + ("bookworm" if case == "codename-mismatch" else "trixie") + "\n"
                if case == "codename-duplicate":
                    release += "Codename: trixie\n"
                if case == "codename-extra-token":
                    release = release.replace("Codename: trixie\n", "Codename: trixie bookworm\n")
                if case == "codename-duplicate-suite":
                    release += "Suite: stable\n"
            if not (case == "debian-waiver" and name == "debian-source"):
                release += f"Valid-Until: {format_datetime(until)}\n"
            release += f"SHA256:\n {index_digest} {len(compressed)} {index_path}\n"
            (work / "Release").write_text(release)
            signed = command(gpg + ["--armor", "--clearsign", "--output", "-", "Release"], work)
            if case == "signature" and name == "firstparty":
                signed = signed.replace(b"Suite: stable", b"Suite: forged")
            inrelease = store(signed, "apt-metadata", base + "/InRelease")
            repo = {"origin": origin, "keyring": keyring, "fingerprints": [fingerprint],
                    "suite": suite, "component": "main", "arch": "arm64", "index_path": index_path}
            if case.startswith("codename") and name == "debian-binary":
                repo |= {"suite": "stable", "codename": "trixie"}
            policies[name] = repo | {"max_age_seconds": 86400}
            repositories[name] = repo | {"inrelease": inrelease, "index": index}
        reviewed = {"schema": 1, "source_commit": "a" * 40, "epoch": 1234, "board": "rock-5b-plus",
                    "source_bundle": source, "device_root": root, "objects": objects,
                    "repositories": repositories, "packages": packages}
        root_der = command(["openssl", "x509", "-in", "ca.pem", "-outform", "DER"], work)
        policy = {"schema": 1, "root_der_sha256": hashlib.sha256(root_der).hexdigest(), "repositories": policies,
                  "kernel_metadata": metadata, "builder_images": builders}
        requests = []
        release_response = threading.Event()

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                host = self.headers["Host"]
                url = "https://" + host + self.path
                authenticated = bool(self.connection.getpeercert())
                requests.append((url, authenticated))
                if host == "apt.ceralive.tv" and require_client and not authenticated:
                    self.send_error(403)
                    return
                if redirects is not None and url in redirects:
                    status, location = redirects[url]
                    if case == "bsp-lf-headers":
                        self.wfile.write((f"HTTP/1.1 {status} Redirect\nLocation: {location}\n"
                                          "Content-Length: 0\n\n").encode())
                        return
                    self.send_response(status)
                    self.send_header("Location", location)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if case in ("redirect", "same-origin-redirect"):
                    self.send_response(302)
                    self.send_header("Location", "https://" +
                                     ("apt.ceralive.tv" if case == "same-origin-redirect"
                                      else "other.example") + "/redirected")
                    self.end_headers()
                    return
                if case in ("timeout", "bsp-timeout") and (redirects is None or host.startswith("mirror-")):
                    release_response.wait(5)
                    return
                data = remote.get(url)
                if host in ("mirror-a.example", "mirror-b.example"):
                    data = remote.get("https://apt.armbian.com" + self.path.removeprefix("/armbian/apt"))
                if case == "missing-object" and host == "apt.ceralive.tv" and url.endswith(".deb"):
                    data = None
                if data is None:
                    self.send_error(404)
                    return
                if case == "package-hash" and url.endswith(".deb"):
                    data = data[:-1] + bytes([data[-1] ^ 1])
                oversize = case == "oversize" or (case == "bsp-oversize" and host.startswith("mirror-"))
                if oversize:
                    data += b"excess"
                self.send_response(200)
                # No Content-Length on the oversize case: file limits must still hold.
                if not oversize:
                    self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *_args: str) -> None:
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(work / "server.pem", work / "server.key")
        context.load_verify_locations(work / "ca.pem")
        context.verify_mode = ssl.CERT_OPTIONAL
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        bin_dir = work / "bin"
        bin_dir.mkdir()
        # Route ALL curl connections to this fixture, including a regressed redirect.
        # This changes the socket destination, never the TLS hostname or CA checks.
        curl = bin_dir / "curl"
        curl.write_text("#!/usr/bin/env python3\nimport os, sys\n"
                        f"fd = os.open({str(work / 'curl-fixture.stderr')!r}, "
                        "os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)\nos.dup2(fd, 2)\n"
                        f"os.execv({shutil.which('curl')!r}, [{shutil.which('curl')!r}, '--disable', "
                        f"'--connect-to', '::127.0.0.1:{server.server_port}', *sys.argv[1:]])\n")
        curl.chmod(0o700)
        inventory_path = work / "reviewed.json"
        policy_path = work / "policy.json"
        inventory_path.write_text(json.dumps(reviewed))
        policy_path.write_text(json.dumps(policy))
        args = ["python3", str(ROOT / "ci/prepare-image-capsule.py"), "--inventory", str(inventory_path),
                "--trust-policy", str(policy_path), "--output", str(work / "capsule.tar"),
                "--client-identity", "https://apt.ceralive.tv", str(work / "client.pem"),
                str(work / "client.key"), "--ca-file", str(work / "ca.pem"),
                "--object-timeout", "1" if case in ("timeout", "bsp-timeout") else "10"]
        env = {"PATH": str(bin_dir) + ":" + os.environ["PATH"], "HOME": str(work), "TMPDIR": temporary,
               "PYTHONDONTWRITEBYTECODE": "1"}
        try:
            yield work, reviewed, args, env, requests, remote
        finally:
            release_response.set()
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
            command(["gpgconf", "--homedir", str(home), "--kill", "gpg-agent"], work)


def run(args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, env=env, capture_output=True, text=True, timeout=45)


def approve_redirects(work: Path, reviewed: dict, maximum: int = 3, name: str = "bsp") -> None:
    """Make the fixture's independent policy and reviewed delivery record agree."""
    policy = json.loads((work / "policy.json").read_text())
    policy["repositories"][name]["max_redirects"] = maximum
    reviewed["repositories"][name]["max_redirects"] = maximum
    (work / "policy.json").write_text(json.dumps(policy))
    (work / "reviewed.json").write_text(json.dumps(reviewed))


def bsp_urls(reviewed: dict) -> list[str]:
    return [url for row in reviewed["objects"] for url in row["urls"]
            if url.startswith("https://apt.armbian.com/")]


def mirror_url(url: str, mirror: str = "mirror-a.example") -> str:
    return url.replace("https://apt.armbian.com", "https://" + mirror + "/armbian/apt", 1)


def capsule_receipt(work: Path, digest: str, imported: str = "imported") -> tuple:
    capsule = unpack(work / "capsule.tar", work / imported,
                     Identity("test", "rock-5b-plus", "a" * 40, 1234, digest))
    receipts = [json.loads((capsule.directory / row.sha256).read_bytes())
                for row in capsule.objects if row.kind == "apt-metadata" and not row.urls
                and (capsule.directory / row.sha256).read_bytes().startswith(b'{"delivery"')]
    assert len(receipts) == 1
    return capsule, receipts[0]


def test_bsp_redirect_chain_preserves_authenticated_bytes_and_logical_origin() -> None:
    redirects = {}
    with fixture("bsp", redirects=redirects) as (work, reviewed, args, env, requests, remote):
        approve_redirects(work, reviewed)
        expected = []
        for url in sorted(bsp_urls(reviewed), key=lambda value: value.endswith(".deb")):
            first = mirror_url(url)
            second = mirror_url(url, "mirror-b.example")
            last = second.replace("/armbian/apt/", "/")
            redirects.update({url: (302, first), first: (307, second), second: (308, last)})
            digest = next(row["sha256"] for row in reviewed["objects"] if row["urls"] == [url])
            expected.append({"sha256": digest, "url": url, "final_url": last, "redirects": [
                {"status": 302, "from": url, "to": first},
                {"status": 307, "from": first, "to": second},
                {"status": 308, "from": second, "to": last}]})

        result = run(args, env)

        assert result.returncode == 0, result.stderr
        capsule, receipt = capsule_receipt(work, result.stdout.strip())
        assert receipt["transfers"] == expected
        assert json.loads((capsule.directory / "inventory.json").read_text())["repositories"] == reviewed["repositories"]
        for row in capsule.objects:
            for url in row.urls:
                assert (capsule.directory / row.sha256).read_bytes() == remote[url]
        assert all(not authenticated for url, authenticated in requests
                   if not url.startswith("https://apt.ceralive.tv/"))
        assert not any("mirror-" in url for row in capsule.objects for url in row.urls)


def test_bsp_redirect_rejections_leave_no_capsule_or_target_request() -> None:
    for case, expected in (
        ("limit", "redirect limit exceeded"),
        ("downgrade", "sealed objects require exact HTTPS origin URLs"),
        ("userinfo", "sealed objects require exact HTTPS origin URLs"),
        ("empty-userinfo", "sealed objects require exact HTTPS origin URLs"),
        ("loop", "redirect loop"),
        ("path", "redirect target changes logical object path"),
        ("missing", "HTTP 404"),
    ):
        redirects = {}
        with fixture("bsp", redirects=redirects) as (work, reviewed, args, env, requests, _remote):
            approve_redirects(work, reviewed)
            url = bsp_urls(reviewed)[0]
            target = mirror_url(url)
            if case == "limit":
                for prefix in ("one", "two", "three", "four"):
                    next_url = target.replace("/armbian/apt/", "/" + prefix + "/")
                    redirects[url] = (302, next_url)
                    url = next_url
                forbidden = url
            elif case == "loop":
                redirects[url] = (302, target)
                redirects[target] = (302, url)
                forbidden = None
            else:
                target = {
                    "downgrade": target.replace("https://", "http://"),
                    "userinfo": target.replace("https://", "https://user:password@"),
                    "empty-userinfo": target.replace("https://", "https://@"),
                    "path": "https://mirror-a.example/unrelated",
                    "missing": target.replace("/armbian/apt/", "/missing/"),
                }[case]
                redirects[url] = (302, target)
                forbidden = None if case == "missing" else target

            result = run(args, env)

            assert result.returncode != 0, case
            assert expected in result.stderr, (case, result.stderr)
            assert "object " in result.stderr, (case, result.stderr)
            assert all(request != forbidden for request, _ in requests), case
            if case == "loop":
                assert [request for request, _ in requests].count(url) == 1
            if case == "missing":
                assert requests[-1] == (target, False)
                assert next(row["sha256"] for row in reviewed["objects"] if row["urls"] == [url]) in result.stderr
            assert not (work / "capsule.tar").exists(), case
            assert not list(work.glob(".prefetch-*")), case


def test_firstparty_redirect_never_presents_client_identity_to_target() -> None:
    for credentialed in (True, False):
        redirects = {}
        with fixture(redirects=redirects, require_client=credentialed) as (
                work, _reviewed, args, env, requests, _remote):
            url = "https://apt.ceralive.tv/dists/stable/binary-arm64/Packages.gz"
            target = "https://mirror-a.example/dists/stable/binary-arm64/Packages.gz"
            redirects[url] = (302, target)
            if not credentialed:
                index = args.index("--client-identity")
                del args[index:index + 4]

            result = run(args, env)

            assert result.returncode != 0, result.stderr
            assert "HTTP 302" in result.stderr
            assert requests == [(url, credentialed)]
            assert not any(authenticated for request, authenticated in requests if request == target)
            assert not (work / "capsule.tar").exists()


def test_redirect_policy_rejects_invalid_or_credentialed_allowances_before_requests() -> None:
    for name, maximum, identity in (
        ("bsp", 4, False), ("bsp", -1, False), ("bsp", True, False),
        ("bsp", "3", False), ("firstparty", 1, False), ("debian-source", 1, False),
        ("bsp", 3, True),
    ):
        with fixture("bsp") as (work, reviewed, args, env, requests, _remote):
            approve_redirects(work, reviewed, maximum, name)
            if identity:
                args += ["--client-identity", "https://apt.armbian.com",
                         str(work / "client.pem"), str(work / "client.key")]

            result = run(args, env)

            assert result.returncode != 0, (name, maximum)
            assert "redirect policy" in result.stderr, result.stderr
            assert requests == []
            assert not (work / "capsule.tar").exists()


def test_redirected_mirror_bytes_must_match_reviewed_hashes() -> None:
    for suffix in ("InRelease", "Packages.gz", ".deb"):
        redirects = {}
        with fixture("bsp", redirects=redirects) as (work, reviewed, args, env, requests, remote):
            approve_redirects(work, reviewed)
            url = next(url for url in bsp_urls(reviewed) if url.endswith(suffix))
            redirects[url] = (302, mirror_url(url))
            data = remote[url]
            remote[url] = data[:-1] + bytes([data[-1] ^ 1])

            result = run(args, env)

            assert result.returncode != 0, result.stderr
            assert "size or digest mismatch" in result.stderr
            assert (mirror_url(url), False) in requests
            assert not (work / "capsule.tar").exists()


def test_redirected_targets_keep_size_and_timeout_bounds() -> None:
    for case in ("bsp-oversize", "bsp-timeout"):
        redirects = {}
        with fixture(case, redirects=redirects) as (work, reviewed, args, env, requests, _remote):
            approve_redirects(work, reviewed)
            url = bsp_urls(reviewed)[0]
            redirects[url] = (302, mirror_url(url))

            result = run(args, env)

            assert result.returncode != 0, result.stderr
            assert "exact HTTPS GET failed for object " in result.stderr
            assert (mirror_url(url), False) in requests
            assert not (work / "capsule.tar").exists()


def test_redirected_metadata_and_package_sizes_must_match_signed_sizes() -> None:
    for case in ("index", "package"):
        redirects = {}
        with fixture("bsp", redirects=redirects) as (work, reviewed, args, env, _requests, remote):
            approve_redirects(work, reviewed)
            urls = bsp_urls(reviewed)
            release_url = next(url for url in urls if url.endswith("InRelease"))
            index_url = next(url for url in urls if url.endswith("Packages.gz"))
            repository = reviewed["repositories"]["bsp"]
            index = remote[index_url]
            source = work / "signed-size-fixture"
            source.write_bytes(remote[release_url])
            gpg = ["gpg", "--homedir", str(work / "gnupg"), "--batch", "--yes",
                   "--pinentry-mode", "loopback", "--passphrase", ""]
            release = command(gpg + ["--decrypt", str(source)], work).decode()
            if case == "index":
                release = release.replace(f" {len(index)} {repository['index_path']}",
                                          f" {len(index) + 1} {repository['index_path']}")
            else:
                package_url = next(url for url in urls if url.endswith(".deb"))
                size = len(remote[package_url])
                payload = gzip.decompress(index).replace(f"Size: {size}\n".encode(),
                                                         f"Size: {size + 1}\n".encode())
                changed = gzip.compress(payload, mtime=0)
                digest = hashlib.sha256(changed).hexdigest()
                release = release.replace(hashlib.sha256(index).hexdigest(), digest)
                release = release.replace(f" {len(index)} {repository['index_path']}",
                                          f" {len(changed)} {repository['index_path']}")
                row = next(row for row in reviewed["objects"] if row["urls"] == [index_url])
                row.update(sha256=digest, length=len(changed))
                repository["index"] = digest
                remote[index_url] = changed
            source.write_text(release)
            signed = command(gpg + ["--armor", "--clearsign", "--output", "-", str(source)], work)
            digest = hashlib.sha256(signed).hexdigest()
            row = next(row for row in reviewed["objects"] if row["urls"] == [release_url])
            row.update(sha256=digest, length=len(signed))
            repository["inrelease"] = digest
            remote[release_url] = signed
            for url in urls:
                redirects[url] = (302, mirror_url(url))
            (work / "reviewed.json").write_text(json.dumps(reviewed))

            result = run(args, env)

            assert result.returncode != 0, (case, result.stderr)
            assert ("signature/index/identity verification rejected" if case == "index" else
                    "reviewed package differs from original signed index") in result.stderr
            assert not (work / "capsule.tar").exists()


def test_malformed_redirect_headers_never_appear_in_failure_diagnostics() -> None:
    redirects = {}
    with fixture("bsp-lf-headers", redirects=redirects) as (work, reviewed, args, env, requests, _remote):
        approve_redirects(work, reviewed)
        url = bsp_urls(reviewed)[0]
        redirects[url] = (302, mirror_url(url).replace("https://", "https://user:password@"))

        result = run(args, env)

        assert result.returncode != 0, result.stderr
        assert "user:password" not in result.stderr
        assert "Location:" not in result.stderr
        assert next(row["sha256"] for row in reviewed["objects"] if row["urls"] == [url]) in result.stderr
        assert not any("mirror-" in request for request, _ in requests)
        assert not (work / "capsule.tar").exists()


def test_redirect_hops_share_one_object_deadline() -> None:
    redirects = {}
    with fixture("bsp", redirects=redirects) as (work, reviewed, _args, env, requests, _remote):
        url = bsp_urls(reviewed)[0]
        redirects[url] = (302, mirror_url(url))
        row = next(row for row in reviewed["objects"] if row["urls"] == [url])
        producer = runpy.run_path(str(ROOT / "ci/prepare-image-capsule.py"))

        with patch("time.monotonic", side_effect=[0, 0, 9, 11]):
            try:
                producer["fetch"](url, work / row["sha256"], row["length"], None,
                                  str(work / "ca.pem"), 10, env, 3)
            except producer["StreamError"] as error:
                assert "object timeout" in str(error), str(error)
            else:
                raise AssertionError("redirect hop received a fresh object deadline")

        assert requests == [(url, False)]


def test_codename_path_accepts_original_signed_suite() -> None:
    with fixture("codename") as (work, _reviewed, args, env, requests, remote):
        result = run(args, env)
        assert result.returncode == 0, result.stderr
        capsule = unpack(work / "capsule.tar", work / "imported",
                         Identity("test", "rock-5b-plus", "a" * 40, 1234, result.stdout.strip()))
        url = "https://deb.debian.org/debian/dists/trixie/InRelease"
        row = next(row for row in capsule.objects if url in row.urls)
        assert (capsule.directory / row.sha256).read_bytes() == remote[url]
        assert b"Suite: stable\n" in remote[url] and b"Codename: trixie\n" in remote[url]
        assert {url for url, _authenticated in requests} == set(remote)


def test_xz_only_binary_indexes_seal_and_import_original_bytes() -> None:
    with fixture("packages-xz") as (work, _reviewed, args, env, requests, remote):
        result = run(args, env)
        assert result.returncode == 0, result.stderr
        capsule = unpack(work / "capsule.tar", work / "imported",
                         Identity("test", "rock-5b-plus", "a" * 40, 1234, result.stdout.strip()))
        shutil.copyfile(work / "policy.json", capsule.directory / "trust.json")
        importer_env = env | {"CERALIVE_SEALED_INPUTS": str(capsule.directory),
                              "CERALIVE_DEBCACHE": "0", "ARCH": "arm64",
                              "CERALIVE_BUILD_MODE": "production",
                              "ARMBIAN_APT_URL": "https://repo.example"}
        script = ('source "$1/lib/fetch-debs.sh"; sealed_repository bsp "$2/state"; '
                  '_SEALED_BASE=https://repo.example; _SEALED_DEBS="$2/debs"; '
                  'mkdir -p "$_SEALED_DEBS"; sealed_stage_deb ceralive-device=1.1')
        imported = run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT), str(work)], importer_env)
        assert imported.returncode == 0, imported.stderr
        assert (work / "debs/ceralive-device_1.1_arm64.deb").read_bytes() == remote[
            "https://repo.example/ceralive-device_1.1_arm64.deb"]
        for row in capsule.objects:
            for url in row.urls:
                assert (capsule.directory / row.sha256).read_bytes() == remote[url]
        assert {url for url, _authenticated in requests} == set(remote)
        assert ("https://deb.debian.org/debian/dists/stable-updates/main/binary-arm64/Packages.xz",
                False) in requests
        assert ("https://deb.debian.org/debian/dists/stable-updates/main/binary-arm64/Packages.gz",
                False) not in requests


def test_codename_does_not_waive_signed_suite_component_arch_or_cardinality() -> None:
    for case in ("codename-suite-mismatch", "codename-mismatch", "codename-missing",
                 "codename-duplicate", "codename-duplicate-suite", "codename-extra-token",
                 "codename-component", "codename-arch"):
        with fixture(case) as (work, _reviewed, args, env, requests, _remote):
            result = run(args, env)
            assert result.returncode != 0, case
            assert "signature/index/identity verification rejected" in result.stderr, (case, result.stderr)
            assert not any(url.endswith(".deb") for url, _ in requests), case
            assert not (work / "capsule.tar").exists(), case


def test_codename_cannot_be_changed_without_independent_policy_approval() -> None:
    for case, expected in (
        ("inventory", "repository differs from independently approved policy"),
        ("url", "metadata URL is outside the exact approved repository objects"),
        ("firstparty", "missing approved first-party/BSP/Debian-source origin policy"),
        ("traversal", "invalid archive validity or identity policy"),
    ):
        with fixture("codename") as (work, reviewed, args, env, requests, _remote):
            if case == "inventory":
                reviewed["repositories"]["debian-binary"]["codename"] = "bookworm"
            elif case == "url":
                digest = reviewed["repositories"]["debian-binary"]["inrelease"]
                selected = next(row for row in reviewed["objects"] if row["sha256"] == digest)
                selected["urls"] = ["https://deb.debian.org/debian/dists/testing/InRelease"]
            else:
                policy = json.loads((work / "policy.json").read_text())
                name = "firstparty" if case == "firstparty" else "debian-binary"
                value = "trixie" if case == "firstparty" else "../trixie"
                policy["repositories"][name]["codename"] = value
                reviewed["repositories"][name]["codename"] = value
                (work / "policy.json").write_text(json.dumps(policy))
            (work / "reviewed.json").write_text(json.dumps(reviewed))
            result = run(args, env)
            assert result.returncode != 0, case
            assert expected in result.stderr, (case, result.stderr)
            assert requests == [], case
            assert not (work / "capsule.tar").exists(), case


def test_cli_seals_original_bytes_and_importer_accepts_authenticated_closure() -> None:
    with fixture() as (work, reviewed, args, env, requests, remote):
        # A hostile curlrc/proxy must not affect the allowed request inventory.
        (work / ".curlrc").write_text("insecure\nlocation\nrequest = POST\n")
        env["HTTPS_PROXY"] = "http://127.0.0.1:1"
        result = run(args, env)
        assert result.returncode == 0, (result.stderr, requests,
                                       (work / "curl-fixture.stderr").read_text())
        digest = result.stdout.strip()
        capsule = unpack(work / "capsule.tar", work / "imported",
                         Identity("test", "rock-5b-plus", "a" * 40, 1234, digest))
        assert len(requests) == len(remote)
        assert {url for url, _authenticated in requests} == set(remote)
        assert all(authenticated == url.startswith("https://apt.ceralive.tv/")
                   for url, authenticated in requests)
        for row in capsule.objects:
            for url in row.urls:
                assert (capsule.directory / row.sha256).read_bytes() == remote[url]
        shutil.copyfile(work / "policy.json", capsule.directory / "trust.json")
        importer_env = env | {"CERALIVE_SEALED_INPUTS": str(capsule.directory),
                              "CERALIVE_DEBCACHE": "0", "ARCH": "arm64",
                              "CERALIVE_BUILD_MODE": "production",
                              "CERALIVE_BUILD_PURPOSE": "rootfs-measurement",
                              "ARMBIAN_APT_URL": "https://repo.example"}
        for name, base, version in (("firstparty", "https://apt.ceralive.tv/dists/stable/binary-arm64", "1.0"),
                                    ("bsp", "https://repo.example", "1.1")):
            script = ('source "$1/lib/fetch-debs.sh"; '
                      'sealed_repository "$3" "$2/state-$3"; '
                      '_SEALED_BASE="$4"; _SEALED_DEBS="$2/debs"; mkdir -p "$_SEALED_DEBS"; '
                      'sealed_stage_deb "ceralive-device=$5"')
            imported = run(["bash", "-euo", "pipefail", "-c", script, "_", str(ROOT),
                            str(work), name, base, version], importer_env)
            assert imported.returncode == 0, imported.stderr
            url = base + "/ceralive-device_" + version + "_arm64.deb"
            assert (work / "debs" / url.rsplit("/", 1)[-1]).read_bytes() == remote[url]
        assert len(requests) == len(remote), "sealed import attempted another HTTP fetch"
        with tarfile.open(work / "capsule.tar", "r:") as archive:
            receipts = []
            for row in capsule.objects:
                if row.kind == "apt-metadata" and not row.urls:
                    data = (capsule.directory / row.sha256).read_bytes()
                    if data.startswith(b'{"delivery"'):
                        receipts.append(json.loads(data))
            assert len(archive.getmembers()) == len(capsule.objects) + 1
        assert len(receipts) == 1
        assert receipts[0]["delivery"] == "offline-capsule"
        assert receipts[0]["packages"] == [
            package | {"origin": reviewed["repositories"][package["repository"]]["origin"],
                       "url": next(row["urls"][0] for row in reviewed["objects"]
                                   if row["sha256"] == package["sha256"]),
                       "length": next(row["length"] for row in reviewed["objects"]
                                      if row["sha256"] == package["sha256"])}
            for package in reviewed["packages"]]
        assert (work / "capsule.tar").stat().st_mode & 0o777 == 0o600
        assert not list(work.glob(".prefetch-*"))
        original = (work / "capsule.tar").read_bytes()
        assert (work / "client.key").read_bytes() not in original
        assert (work / "client.pem").read_bytes() not in original
        assert run(args, env).returncode != 0
        assert (work / "capsule.tar").read_bytes() == original


def test_signature_index_package_control_ambiguity_and_expiry_fail_closed() -> None:
    for case, expected in (
        ("signature", "signature/index/identity verification rejected"),
        ("index", "signature/index/identity verification rejected"),
        ("package-hash", "package size or digest mismatch"),
        ("control-version", "signed package lookup or control identity rejected"),
        ("control-arch", "signed package lookup or control identity rejected"),
        ("ambiguous", "signed package lookup or control identity rejected"),
        ("expired", "signed metadata expired"),
    ):
        with fixture(case) as (work, _reviewed, args, env, _requests, _remote):
            result = run(args, env)
            assert result.returncode != 0, case
            assert expected in result.stderr, (case, result.stderr)
            assert not (work / "capsule.tar").exists(), case
            assert not list(work.glob(".prefetch-*")), case


def test_redirects_unknown_tls_and_bounded_transfers_never_publish() -> None:
    for case in ("redirect", "same-origin-redirect", "oversize", "timeout", "untrusted-tls", "hostname"):
        with fixture(case) as (work, _reviewed, args, env, requests, _remote):
            if case == "untrusted-tls":
                args[args.index("--ca-file") + 1] = str(work / "untrusted-ca.pem")
            result = run(args, env)
            assert result.returncode != 0, case
            assert "exact HTTPS GET failed" in result.stderr, (case, result.stderr)
            assert not (work / "capsule.tar").exists(), case
            assert all(not url.endswith("/redirected") for url, _authenticated in requests), case
            assert not list(work.glob(".prefetch-*")), case


def test_missing_remote_object_is_named_and_leaves_no_capsule_or_partial_files() -> None:
    with fixture("missing-object") as (work, reviewed, args, env, requests, _remote):
        private = work / "private"
        private.mkdir(mode=0o700)
        args[args.index("--output") + 1] = str(private / "capsule.tar")
        missing = next(row for row in reviewed["objects"] if row["kind"] == "deb"
                       and row["urls"][0].startswith("https://apt.ceralive.tv/"))
        result = run(args, env)
        assert result.returncode != 0
        assert (f"exact HTTPS GET failed for object {missing['sha256']} at {missing['urls'][0]} (HTTP 404"
                in result.stderr), result.stderr
        assert (missing["urls"][0], True) in requests
        assert str(work / "client.pem") not in result.stderr
        assert str(work / "client.key") not in result.stderr
        # No capsule, partial download, staged archive or temporary directory survives.
        assert list(private.iterdir()) == []


def test_unapproved_objects_and_client_origins_are_rejected_before_requests() -> None:
    for case, expected in (
        ("origin", "client identity requires one exact independently approved origin"),
        ("traversal", "sealed URL path traversal"),
        ("encoded-traversal", "sealed URL path traversal"),
        ("encoded-separator", "sealed objects require exact HTTPS origin URLs"),
        ("arbitrary-url", "sealed objects require exact HTTPS origin URLs"),
        ("extra-metadata", "undeclared network metadata"),
        ("missing-package", "each package object requires one reviewed identity"),
        ("duplicate-url", "ambiguous reviewed object or URL"),
    ):
        with fixture() as (work, reviewed, args, env, requests, _remote):
            selected = next(row for row in reviewed["objects"] if row["kind"] == "deb")
            if case == "origin":
                args[args.index("--client-identity") + 1] = "https://other.example"
            elif case in ("traversal", "encoded-traversal", "encoded-separator"):
                selected["urls"] = ["https://apt.ceralive.tv/" + {
                    "traversal": "../key", "encoded-traversal": "%2e%2e/key",
                    "encoded-separator": "pool%2fkey"}[case]]
            elif case == "arbitrary-url":
                selected["urls"] = ["http://repo.example/package.deb"]
            elif case == "extra-metadata":
                selected["kind"] = "apt-metadata"
                reviewed["packages"] = reviewed["packages"][1:]
            elif case == "missing-package":
                reviewed["packages"] = reviewed["packages"][1:]
            elif case == "duplicate-url":
                selected["urls"] += selected["urls"]
            (work / "reviewed.json").write_text(json.dumps(reviewed))
            result = run(args, env)
            assert result.returncode != 0, case
            assert expected in result.stderr, (case, result.stderr)
            assert requests == [], case
            assert not (work / "capsule.tar").exists(), case


def test_mtls_is_required_without_using_any_host_identity() -> None:
    with fixture() as (work, _reviewed, args, env, requests, _remote):
        index = args.index("--client-identity")
        del args[index:index + 4]
        result = run(args, env)
        assert result.returncode != 0
        assert requests == [("https://apt.ceralive.tv/dists/stable/binary-arm64/Packages.gz", False)]
        assert not (work / "capsule.tar").exists()


def test_signed_package_url_cannot_authorize_another_reviewed_location() -> None:
    with fixture() as (work, reviewed, args, env, requests, _remote):
        selected = next(row for row in reviewed["objects"] if row["kind"] == "deb")
        selected["urls"] = ["https://other.example/package.deb"]
        (work / "reviewed.json").write_text(json.dumps(reviewed))
        result = run(args, env)
        assert result.returncode != 0
        assert "reviewed package differs from original signed index" in result.stderr
        assert len(requests) == 6
        assert all(not url.endswith(".deb") for url, _authenticated in requests)
        assert not (work / "capsule.tar").exists()


def test_local_input_links_size_and_hash_mismatches_never_publish() -> None:
    for case, expected in (("link", "local input is not a regular file"),
                           ("size", "local input is not a regular file"),
                           ("hash", "prefetched object size or digest mismatch")):
        with fixture() as (work, reviewed, args, env, requests, _remote):
            source = work / reviewed["source_bundle"]
            if case == "link":
                alias = work / "linked-source"
                alias.symlink_to(source)
                next(row for row in reviewed["objects"] if row["kind"] == "source-bundle")["path"] = str(alias)
            else:
                data = source.read_bytes()
                source.write_bytes(data + b"changed" if case == "size" else bytes([data[0] ^ 1]) + data[1:])
            (work / "reviewed.json").write_text(json.dumps(reviewed))
            result = run(args, env)
            assert result.returncode != 0, case
            assert expected in result.stderr, (case, result.stderr)
            assert requests == []
            assert not (work / "capsule.tar").exists()


def test_measurement_only_debian_missing_valid_until_waiver_is_preserved() -> None:
    with fixture("debian-waiver") as (work, _reviewed, args, env, _requests, _remote):
        result = run(args, env)
        assert result.returncode == 0, result.stderr
        capsule = unpack(work / "capsule.tar", work / "imported",
                         Identity("test", "rock-5b-plus", "a" * 40, 1234, result.stdout.strip()))
        receipts = [json.loads((capsule.directory / row.sha256).read_bytes())
                    for row in capsule.objects if row.kind == "apt-metadata" and not row.urls
                    and (capsule.directory / row.sha256).read_bytes().startswith(b'{"delivery"')]
        validity = receipts[0]["metadata_validity"]["repositories"]
        assert next(row for row in validity if row["repository"] == "debian-source")["freshness"] == "NOT checked"


if __name__ == "__main__":
    for name, function in list(globals().items()):
        if name.startswith("test_"):
            function()
            print("PASS", name)
