"""Exercise the rendered sealed APT policy with real APT and a loopback fixture."""

from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import lzma
import os
from pathlib import Path
import pwd
import subprocess
import tempfile
from threading import Thread
from typing import Iterator
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
SUITES = {
    "trixie": ("debian", "gz"),
    "trixie-updates": ("debian", "xz"),
    "trixie-security": ("debian-security", "xz"),
}
TARGET = "main/binary-arm64/Packages"
POOL = "/debian/pool/main/s/sealed-fixture/sealed-fixture_1_all.deb"
PAYLOAD = b"synthetic bytes for download verification, not an installable deb"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@contextmanager
def mirror(objects: dict[str, bytes]) -> Iterator[tuple[int, list[str], list[str]]]:
    """Serve exact paths; refuse all further acquisitions after the first miss."""
    requested: list[str] = []
    misses: list[str] = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            uri = urlsplit(self.path)
            path = uri.path
            if path.startswith("/HTTPS///deb.debian.org/"):
                path = path.removeprefix("/HTTPS///deb.debian.org")
            requested.append(path)
            if path not in objects or uri.query or uri.netloc not in ("", "deb.debian.org"):
                misses.append(path)
            if misses:
                self.send_error(404)
                return
            body = objects[path]
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args: str) -> None:
            pass

    with HTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = Thread(target=server.serve_forever)
        thread.start()
        try:
            yield server.server_port, requested, misses
        finally:
            server.shutdown()
            thread.join()


def render(work: Path, mode: str) -> tuple[str, str]:
    """Run the production sandbox or runtime writer, not a copied stanza."""
    env = os.environ | {
        "APT_SUITE": "trixie",
        "APT_SUITE_UPDATES": "trixie-updates",
        "APT_SUITE_SECURITY": "trixie-security",
        "CERALIVE_SEALED_APT": "1",
        "CERALIVE_BUILD_APT_PROXY": "http://127.0.0.1:3142",
    }
    sandbox = work / "sandbox"
    if mode == "sandbox":
        subprocess.run(
            ["bash", "-ec", 'source "$1"; sealed_apt_sandbox "$2"', "_",
             ROOT / "mkosi/runtime/sealed-apt-policy.sh", sandbox],
            env=env, check=True, timeout=10,
        )
        apt = sandbox / "etc/apt"
        return (
            (apt / "sources.list.d/ceralive-sealed.list").read_text(),
            (apt / "apt.conf.d/99-ceralive-sealed").read_text(),
        )
    subprocess.run(
        ["bash", "-ec", """
            # Redirect only the device writer's filesystem paths into the fixture.
            postinst=$(head -n -1 "$SRCDIR/mkosi.images/runtime/mkosi.postinst.chroot")
            apt_root=/etc/apt
            mkdir -p "$3/apt.conf.d"
            source <(printf '%s\\n' "${postinst//"$apt_root"/"$3"}")
            configure_minimal_apt
            runtime_build_apt_scope
            cp "${CERALIVE_BUILD_APT_DIR}/sources/ceralive-sealed.list" "$1"
            cp "${APT_CONFIG}" "$2"
        """, "_", work / "sources", work / "config", work / "etc-apt"],
        env=env | {"SRCDIR": str(ROOT / "mkosi"), "RELEASE": "trixie"},
        check=True, timeout=10,
    )
    return (work / "sources").read_text(), (work / "config").read_text()


def archive(work: Path) -> tuple[Path, dict[str, bytes], dict[str, bytes], dict[str, bytes]]:
    """Build a signed archive with advertised but deliberately unsealed targets."""
    home = work / "g"
    home.mkdir(mode=0o700)
    gpg = ["gpg", "--homedir", str(home), "--batch"]
    subprocess.run(
        gpg + ["--pinentry-mode", "loopback", "--passphrase", "", "--quick-gen-key",
               "Offline fixture", "ed25519", "sign", "0"],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=15,
    )
    keyring = work / "fixture.gpg"
    with keyring.open("wb") as stream:
        subprocess.run(gpg + ["--export"], check=True, stdout=stream, timeout=10)
    objects: dict[str, bytes] = {}
    expired: dict[str, bytes] = {}
    changed: dict[str, bytes] = {}
    for version, (suite, (archive_name, extension)) in enumerate(SUITES.items(), 1):
        prefix = f"/{archive_name}/dists/{suite}/"
        main = (
            f"Package: sealed-fixture\nVersion: {version}\n"
            f"Architecture: all\nMaintainer: Fixture <fixture@example.invalid>\n"
            f"Description: sealed test package\nFilename: {POOL.split('/', 2)[2]}\n"
            f"Size: {len(PAYLOAD)}\nSHA256: {sha(PAYLOAD)}\n\n"
        ).encode()
        targets = {
            TARGET: main,
            TARGET + ".xz": lzma.compress(main),
            "main/source/Sources": b"unsealed source\n",
            "main/source/Sources.xz": lzma.compress(b"unsealed source\n"),
            "non-free-firmware/binary-arm64/Packages": b"unsealed firmware\n",
            "non-free-firmware/binary-arm64/Packages.xz": lzma.compress(b"unsealed firmware\n"),
            TARGET + ".diff/Index": b"unsealed pdiff\n",
        }
        if extension == "gz":
            targets[TARGET + ".gz"] = gzip.compress(main, mtime=0)
        now = datetime.now(timezone.utc)
        for target, expires in ((objects, now + timedelta(days=1)),
                                (expired, now - timedelta(minutes=1)),
                                (changed, now + timedelta(days=1))):
            if target is changed and suite == "trixie-updates":
                targets[TARGET] = main.replace(b"sealed test package", b"new test package")
                targets[TARGET + ".xz"] = lzma.compress(targets[TARGET])
            release = (
                f"Origin: Debian\nSuite: {suite}\nCodename: {suite}\nArchitectures: arm64 all\n"
                "No-Support-for-Architecture-all: Packages\n"
                "Components: main non-free-firmware\nAcquire-By-Hash: yes\n"
                f"Date: {format_datetime(now - timedelta(days=1))}\n"
                f"Valid-Until: {format_datetime(expires)}\nSHA256:\n"
                + "".join(f" {sha(blob)} {len(blob)} {name}\n" for name, blob in targets.items())
            )
            target[prefix + "InRelease"] = subprocess.run(
                gpg + ["--clearsign"], input=release.encode(), capture_output=True,
                check=True, timeout=10,
            ).stdout
            if target is not expired:
                target[prefix + TARGET + "." + extension] = targets[TARGET + "." + extension]
    subprocess.run(["gpgconf", "--homedir", home, "--kill", "gpg-agent"], check=True, timeout=10)
    return keyring, objects, expired, changed


def run_case(work: Path, mode: str, case: str, keyring: Path,
             objects: dict[str, bytes], expired: dict[str, bytes], changed: dict[str, bytes]) -> None:
    """Compare actual wire requests independently of APT's printed targets."""
    work.mkdir()
    sources, config = render(work, mode)
    available = objects.copy()
    if case == "valid":
        available[POOL] = PAYLOAD
    match case:
        case "debug":
            sources += sources.splitlines()[0].replace(".org/debian", ".org/debian-debug", 1).replace(
                " trixie main", " trixie-debug main"
            ) + "\n"
        case "sources":
            sources += "\n" + sources.replace("deb [", "deb-src [").replace(
                "target=Packages", "target=Sources"
            )
        case "by-hash":
            sources = sources.replace("by-hash=no", "by-hash=yes")
        case "firmware":
            sources = sources.replace(" main\n", " main non-free-firmware\n")
        case "order":
            config = config.replace('"gz xz lz4"', '"xz gz lz4"')
        case "missing-index":
            del available["/debian/dists/trixie/" + TARGET + ".gz"]
        case "missing-release":
            del available["/debian/dists/trixie/InRelease"]
        case "missing-payload" | "valid" | "warm" | "pdiffs":
            pass
        case "corrupt":
            key = "/debian/dists/trixie/InRelease"
            available[key] = available[key].replace(b"Codename: trixie", b"Codename: corrupt")
        case "expired":
            available.update(expired)
        case _:
            raise AssertionError(case)
    config_path = work / "apt.conf"
    parts = work / "etc-apt/apt.conf.d"
    src_path = work / "test.list"
    status = work / "status"
    status.touch()
    (work / "lists").mkdir()
    (work / "archives").mkdir()
    local = work / "local"
    local.mkdir()
    (local / "Packages").write_text(
        "Package: staged-fixture\nVersion: 1\nArchitecture: all\nDescription: staged\n"
        f"Filename: ./staged-fixture_1_all.deb\nSize: {len(PAYLOAD)}\nSHA256: {sha(PAYLOAD)}\n\n"
    )
    (local / "staged-fixture_1_all.deb").write_bytes(PAYLOAD)
    if mode == "sandbox":
        sources += f"deb [trusted=yes] file://{local} ./\n"
    with mirror(available) as (port, requested, misses):
        src_path.write_text(sources.replace(":3142/", f":{port}/").replace(
            "/usr/share/keyrings/debian-archive-keyring.gpg", str(keyring)
        ))
        config_path.write_text(config + f"""
Dir::Etc::parts "{parts if mode == 'runtime' else '/dev/null'}";
Dir::Etc::main "/dev/null";
Dir::Etc::sourcelist "{src_path}";
Dir::Etc::sourceparts "/dev/null";
Dir::State::lists "{work / 'lists'}";
Dir::State::status "{status}";
Dir::Cache::archives "{work / 'archives'}";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
Dir::Bin::Methods "{os.environ.get('SEALED_APT_METHODS', '/usr/lib/apt/methods')}";
APT::Architecture "arm64";
APT::Sandbox::User "{pwd.getpwuid(os.getuid()).pw_name}";
Acquire::http::Proxy "http://127.0.0.1:{port}";
Acquire::http::Proxy::127.0.0.1 "DIRECT";
Acquire::https::Proxy "http://127.0.0.1:{port}";
Acquire::Retries "0";
""")
        env = {key: value for key, value in os.environ.items() if not key.lower().endswith("_proxy")}
        env["APT_CONFIG"] = str(config_path)
        apt = os.environ.get("SEALED_APT_GET", "apt-get")
        if case == "valid":
            dumped = subprocess.run(
                [os.environ.get("SEALED_APT_CONFIG", "apt-config"), "dump"], env=env,
                capture_output=True, text=True, check=True, timeout=10,
            ).stdout
            for setting in (
                'Acquire::Languages:: "none";',
                'Acquire::http::AllowRedirect "false";',
                'Acquire::IndexTargets::deb::Packages::CompressionTypes "gz xz lz4";',
                'APT::Update::Error-Mode "any";',
            ):
                assert setting in dumped, setting
            if mode == "runtime":
                assert 'Acquire::GzipIndexes "true";' in dumped, dumped
        completed = subprocess.run([apt, "update"], env=env, capture_output=True, text=True, timeout=20)
        if case in ("warm", "pdiffs"):
            assert completed.returncode == 0, completed.stderr
            if case == "pdiffs":
                src_path.write_text(src_path.read_text().replace("pdiffs=no", "pdiffs=yes"))
            available.update(changed)
            requested.clear()
            completed = subprocess.run([apt, "update"], env=env, capture_output=True, text=True, timeout=20)
            patches = [p for p in requested if ".diff/" in p]
            assert bool(patches) == (case == "pdiffs"), requested
            assert (completed.returncode == 0) == (case == "warm"), completed.stderr
            return
        if case in ("valid", "missing-payload"):
            assert completed.returncode == 0, completed.stderr
            assert set(requested) == objects.keys() and not misses, requested
            if mode == "runtime":
                assert len(list((work / "lists").glob("*_Packages.lz4"))) == len(SUITES)
                planned = subprocess.run(
                    [apt, "--simulate", "install", "--no-install-recommends", "sealed-fixture=1"],
                    env=env, capture_output=True, text=True, timeout=10,
                )
                assert planned.returncode == 0 and "Inst sealed-fixture (1 " in planned.stdout, (
                    planned.stdout, planned.stderr,
                )
                assert set(requested) == objects.keys() and not misses, requested
            targets = subprocess.run(
                [apt, "indextargets", "--no-release-info", "--format", "$(URI) $(ARCHITECTURE) $(IDENTIFIER)"],
                env=env, capture_output=True, text=True, check=True, timeout=10,
            )
            transport = "http://deb.debian.org" if mode == "sandbox" else f"http://127.0.0.1:{port}/HTTPS///deb.debian.org"
            remote = {line for line in targets.stdout.splitlines() if not line.startswith("file:")}
            assert remote == {
                f"{transport}/{name}/dists/{suite}/{TARGET} arm64 Packages"
                for suite, (name, _) in SUITES.items()
            }, targets.stdout
            if mode == "sandbox":
                simulated = subprocess.run(
                    [apt, "--simulate", "install", "staged-fixture"], env=env,
                    capture_output=True, text=True, timeout=10,
                )
                assert simulated.returncode == 0 and "Inst staged-fixture (1 " in simulated.stdout, (
                    simulated.stdout, simulated.stderr, completed.stdout,
                )
            completed = subprocess.run(
                [apt, "download", "sealed-fixture=1"], cwd=work, env=env, capture_output=True,
                text=True, timeout=10,
            )
            assert (completed.returncode == 0) == (case == "valid"), completed.stderr
            assert requested[-1] == POOL, requested
            if case == "valid":
                assert sha((work / "sealed-fixture_1_all.deb").read_bytes()) == sha(PAYLOAD)
            return
        assert completed.returncode != 0, (case, requested)
        if case in ("corrupt", "expired", "missing-release"):
            assert not any(path.endswith(("/Release", "/Release.gpg")) for path in requested), requested
        if case in ("order", "missing-index"):
            assert "/debian/dists/trixie/" + TARGET + ".xz" in requested, requested


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="apt-") as directory:
        work = Path(directory)
        keyring, objects, expired, changed = archive(work)
        inventory_path = os.environ.get("SEALED_APT_INVENTORY")
        if inventory_path:
            inventory = json.loads(Path(inventory_path).read_text())
            keys = {"debian-trixie", "debian-updates", "debian-security"}
            digests = {inventory["repositories"][key][role] for key in keys for role in ("inrelease", "index")}
            sealed = {url for row in inventory["objects"] if row["sha256"] in digests for url in row["urls"]}
            assert sealed == {"https://deb.debian.org" + path for path in objects}, sealed
        for mode in ("sandbox", "runtime"):
            for case in ("valid", "debug", "sources", "by-hash", "firmware", "order",
                         "missing-index", "missing-release", "missing-payload", "corrupt", "expired",
                         "warm", "pdiffs"):
                run_case(work / f"{mode}-{case}", mode, case, keyring, objects, expired, changed)
                print(f"ok {mode} {case}", flush=True)


if __name__ == "__main__":
    main()
