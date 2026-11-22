"""Exercise the native APT resolver without allowing package downloads."""

from dataclasses import replace
import os
from pathlib import Path
import shutil
import sys
from tempfile import TemporaryDirectory

from capsule_producer_test import fixture, run

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci/kernel-runner"))
from image_apt_replay import PackagePin, ReplayIndex, solve, verify_selection
from image_stream import StreamError


def stanza(pin: PackagePin, extra: str = "") -> str:
    filename = "pool/" + pin.url.split("/pool/", 1)[1]
    return (f"Package: {pin.name}\nVersion: {pin.version}\nArchitecture: {pin.arch}\n"
            f"Size: {pin.length}\nSHA256: {pin.sha256}\nFilename: {filename}\n"
            f"{extra}\n")


def apt_tools() -> tuple[Path, Path]:
    apt = Path(os.environ.get("IMAGE_REPLAY_TEST_APT_GET") or shutil.which("apt-get") or "/usr/bin/apt-get")
    method = Path(os.environ.get("IMAGE_REPLAY_TEST_FILE_METHOD") or "/usr/lib/apt/methods/file")
    return apt, method


def regression() -> None:
    main = "https://deb.debian.org/debian"
    secure = "https://deb.debian.org/debian-security"
    base = PackagePin("debian-trixie", "base-files", "1", "arm64",
                      main + "/pool/base-files_1_arm64.deb", "1" * 64, 123)
    old = PackagePin("debian-security", "libssl3t64", "3.5.7-1~deb13u3", "arm64",
                     secure + "/pool/libssl3t64_old_arm64.deb", "2" * 64, 321)
    new = PackagePin("debian-trixie", "libssl3t64", "3.5.9-1~deb13u1", "arm64",
                     main + "/pool/libssl3t64_new_arm64.deb", "3" * 64, 432)
    with TemporaryDirectory() as directory:
        work = Path(directory)
        trixie = work / "trixie"
        security = work / "security"
        trixie.write_text(stanza(base, "Essential: yes\nDepends: libssl3t64\n") + stanza(new))
        security.write_text(stanza(old))
        apt_get, method = apt_tools()
        plan = solve([
            ReplayIndex("debian-trixie", main, "trixie", trixie),
            ReplayIndex("debian-security", secure, "trixie-security", security),
        ], work, apt_get, method, ["?essential", "base-files"])
        assert plan == {"base-files": base, "libssl3t64": new}, plan
        verify_selection(plan, {"base-files": base, "libssl3t64": new})
        for stale in (old, replace(new, url=old.url), replace(new, sha256=old.sha256),
                      replace(new, length=old.length)):
            try:
                verify_selection(plan, {"base-files": base, "libssl3t64": stale})
            except StreamError as exc:
                assert "libssl3t64" in str(exc), exc
            else:
                raise AssertionError("APT replay accepted a mismatched version, URL, digest or size")


def reject_before_identity_config() -> None:
    """A stale signed selection fails even if opening the identity would fail."""
    with fixture("replay-stale") as (work, inventory, args, env, requests, _remote):
        apt, file = apt_tools()
        args[args.index("--client-identity-config") + 1] = str(work / "unavailable-identity")
        result = run([*args, "--apt-get", str(apt), "--apt-file-method", str(file)], env)
        assert result.returncode == 1 and "replay differs from reviewed selection: libssl3t64" in result.stderr, (
            result.returncode, result.stdout, result.stderr, requests)
        expected = {url for row in inventory["objects"] if row["kind"] == "apt-metadata"
                    for url in row["urls"] if "/dists/trixie" in url}
        assert len(expected) == 6 and set(requests) == {(url, False) for url in expected}, requests
        assert not (work / "capsule.tar").exists()


if __name__ == "__main__":
    regression()
    reject_before_identity_config()
