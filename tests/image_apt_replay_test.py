"""Exercise the native APT resolver without allowing package downloads."""

from dataclasses import replace
import json
import os
from pathlib import Path
import shutil
import subprocess
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


def reject_remote_keyring_before_any_fetch() -> None:
    """A public replay keyring must be a local, independently pinned file."""
    with fixture("replay-stale") as (work, inventory, args, env, requests, _remote):
        apt, method = apt_tools()
        policy_path = work / "policy.json"
        policy = json.loads(policy_path.read_text())
        repo = inventory["repositories"]["debian-trixie"]
        repo["keyring"] = repo["inrelease"]
        policy["repositories"]["debian-trixie"]["keyring"] = repo["inrelease"]
        policy_path.write_text(json.dumps(policy))
        (work / "reviewed.json").write_text(json.dumps(inventory))
        result = run([*args, "--apt-get", str(apt), "--apt-file-method", str(method)], env)
        assert result.returncode == 1 and "replay keyring must be local" in result.stderr, (
            result.stdout, result.stderr, requests)
        assert requests == [] and not (work / "capsule.tar").exists()


def reject_incomplete_trixie_binary_set_before_any_fetch() -> None:
    """A partial trixie binary policy cannot bypass replay by renaming its rows."""
    with fixture("replay-stale") as (work, inventory, args, env, requests, _remote):
        apt, method = apt_tools()
        policy_path = work / "policy.json"
        policy = json.loads(policy_path.read_text())
        args[args.index("--client-identity-config") + 1] = str(work / "unavailable-identity")
        for missing in (("debian-updates",), ("debian-updates", "debian-security")):
            for record, path in ((inventory, work / "reviewed.json"), (policy, policy_path)):
                repos = {name: row for name, row in record["repositories"].items() if name not in missing}
                repos["base"] = repos.pop("debian-trixie")
                if "debian-security" in repos:
                    repos["security"] = repos.pop("debian-security")
                path.write_text(json.dumps(record | {"repositories": repos}))
            result = run([*args, "--apt-get", str(apt), "--apt-file-method", str(method)], env)
            assert result.returncode == 1 and "requires trixie, updates and security indices" in result.stderr, (
                missing, result.stdout, result.stderr, requests)
            assert requests == [] and not (work / "capsule.tar").exists()


def reject_reviewed_package_missing_from_plan() -> None:
    """A virtual name resolved to an already-reviewed provider is not a concrete pin."""
    main = "https://deb.debian.org/debian"
    provider = PackagePin("debian-trixie", "provider", "1", "arm64",
                          main + "/pool/provider_1_arm64.deb", "1" * 64, 123)
    missing = PackagePin("debian-trixie", "old-package", "1", "arm64",
                         main + "/pool/old-package_1_arm64.deb", "2" * 64, 321)
    with TemporaryDirectory() as directory:
        work = Path(directory)
        packages = work / "Packages"
        packages.write_text(stanza(provider, "Provides: old-package\n"))
        apt, method = apt_tools()
        plan = solve([ReplayIndex("debian-trixie", main, "trixie", packages)],
                     work, apt, method, [missing.name, provider.name])
        assert plan == {provider.name: provider}, plan
        try:
            verify_selection(plan, {provider.name: provider, missing.name: missing})
        except StreamError as exc:
            assert missing.name in str(exc), exc
        else:
            raise AssertionError("APT replay accepted a reviewed row the solver did not select")


def regenerate_then_verify_in_another_directory() -> None:
    """A corrected inventory can be replayed from its new private directory."""
    with fixture("replay-stale") as (work, inventory, args, env, requests, remote):
        apt, method = apt_tools()
        cache = work / "public-index-cache"
        cache.mkdir()
        keyring = inventory["repositories"]["debian-trixie"]["keyring"]
        for row in inventory["objects"]:
            if row["sha256"] == keyring:
                row["path"] = keyring
            for url in row["urls"]:
                if row["kind"] == "apt-metadata" and "/dists/trixie" in url:
                    (cache / row["sha256"]).write_bytes(remote[url])
        source = work / "reviewed.json"
        source.write_text(json.dumps(inventory))
        identity = args.index("--client-identity-config")
        del args[identity:identity + 2]
        args += ["--apt-get", str(apt), "--apt-file-method", str(method),
                 "--replay-metadata", str(cache)]
        input_arg = args.index("--inventory") + 1
        output_arg = args.index("--output") + 1
        relative = Path("..") / os.path.relpath(source, Path.cwd().parent)
        for case, input_path in (("absolute", source), ("relative", relative)):
            private = work / case
            private.mkdir(mode=0o700)
            corrected = private / "inventory.json"
            args[input_arg] = str(input_path)
            args[output_arg] = str(corrected)
            result = run([*args, "--write-replayed-inventory"], env)
            assert result.returncode == 0, (case, result.stdout, result.stderr)
            assert corrected.stat().st_mode & 0o777 == 0o600
            pins = json.loads(corrected.read_text())["packages"]
            ssl, = [pin for pin in pins if pin["name"] == "libssl3t64"]
            assert (ssl["repository"], ssl["version"]) == ("debian-trixie", "3.5.9-1~deb13u1")
            args[input_arg] = str(corrected)
            verify_only = private / "verify-only"
            args[output_arg] = str(verify_only)
            result = run(args, env)
            assert result.returncode == 0 and "2 Debian packages" in result.stdout, (
                case, result.stdout, result.stderr)
            assert requests == [] and not verify_only.exists()


def runtime_rauc_replays_target_dependencies_not_the_archive_rauc(
        *, requires_upgrade: bool = False, shared_pool_url: bool = False) -> None:
    """Replay the built pair over installed ARM64 state; retain the chosen signed URL."""
    from image_apt_replay import merge_runtime_fetches, replay_runtime_rauc, verify_runtime_fetches

    main = "https://deb.debian.org/debian"
    secure = "https://deb.debian.org/debian-security"
    version = "2.41.5-0+deb13u1"
    fdisk = PackagePin("debian-security", "libfdisk1", version, "arm64",
                       secure + f"/pool/updates/main/u/util-linux/libfdisk1_{version}_arm64.deb",
                       "1" * 64, 321)
    installed = PackagePin("debian-trixie", "libblkid1", version, "arm64",
                           main + f"/pool/libblkid1_{version}_arm64.deb", "2" * 64, 123)
    with TemporaryDirectory() as directory:
        work = Path(directory)
        packages = work / "trixie"
        primary = replace(fdisk, repository="debian-trixie", url=main + f"/pool/libfdisk1_{version}_arm64.deb")
        packages.write_text(stanza(installed) + stanza(primary, f"Depends: libblkid1 (= {version})\n") + stanza(PackagePin(
            "debian-trixie", "rauc", "1.13-3", "arm64", main + "/pool/rauc_1.13-3_arm64.deb",
            "3" * 64, 432), "Depends: absent-from-archive\n"))
        security = work / "security"
        security.write_text(stanza(fdisk, f"Depends: libblkid1 (= {version})\n"))
        updates = work / "updates"
        updates.write_text(stanza(primary, f"Depends: libblkid1 (= {version})\n"))
        main_index = ReplayIndex("debian-trixie", main, "trixie", packages)
        indices = [main_index, ReplayIndex("debian-security", secure, "trixie-security", security)]
        if shared_pool_url:
            indices.insert(1, ReplayIndex("debian-updates", main, "trixie-updates", updates))
        status = work / "post-platform.status"
        installed_version = "2.41.5-0" if requires_upgrade else version
        status.write_text(f"Package: libblkid1\nStatus: install ok installed\n"
                          f"Architecture: arm64\nVersion: {installed_version}\n\n")
        built = []
        for name, arch, depends in (("rauc", "arm64", "libfdisk1"), ("rauc-service", "all", "rauc")):
            tree = work / name
            (tree / "DEBIAN").mkdir(parents=True)
            (tree / "DEBIAN").chmod(0o755)
            (tree / "DEBIAN/control").write_text(
                f"Package: {name}\nVersion: 1.15.2-1+ceralive.1\nArchitecture: {arch}\n"
                f"Maintainer: Fixture <test@example.invalid>\nDescription: fixture\nDepends: {depends}\n")
            output = work / f"{name}.deb"
            subprocess.run(["dpkg-deb", "--root-owner-group", "--build", str(tree), str(output)], check=True)
            built.append(output)
        apt, method = apt_tools()
        plan = replay_runtime_rauc(indices, work, apt, method, status, tuple(built), "1.15.2-1+ceralive.1")
        expected = {"libfdisk1": replace(primary, aliases=(fdisk.url,))}
        if requires_upgrade:
            expected[installed.name] = installed
        assert plan == expected, plan
        if shared_pool_url:
            updates.write_text(stanza(replace(primary, sha256="f" * 64), f"Depends: libblkid1 (= {version})\n"))
            try:
                replay_runtime_rauc(indices, work, apt, method, status, tuple(built), "1.15.2-1+ceralive.1")
            except StreamError as exc:
                assert str(exc) == "ambiguous or invalid signed Debian package row"
            else:
                raise AssertionError("runtime replay accepted different signed bytes at the same pool URL")
            return
        if requires_upgrade:
            return
        corrected = merge_runtime_fetches({primary.name: primary}, plan)
        for pins in ({}, {primary.name: primary}, {primary.name: replace(corrected[primary.name], sha256="f" * 64)},
                     {primary.name: replace(corrected[primary.name], length=99)},
                     {primary.name: replace(corrected[primary.name], version="1")},
                     {primary.name: replace(corrected[primary.name], arch="all")},
                     {primary.name: replace(corrected[primary.name], aliases=(secure + "/pool/other.deb",))}):
            try:
                verify_runtime_fetches(plan, pins)
            except StreamError as exc:
                assert fdisk.url in str(exc), exc
            else:
                raise AssertionError("runtime replay accepted an unsealed or inexact acquisition")
        verify_runtime_fetches(plan, {primary.name: replace(primary, aliases=(fdisk.url.replace("+", "%2b"),))})
        security.write_text(stanza(replace(fdisk, sha256="f" * 64), f"Depends: libblkid1 (= {version})\n"))
        try:
            replay_runtime_rauc(
                [ReplayIndex("debian-trixie", main, "trixie", packages),
                 ReplayIndex("debian-security", secure, "trixie-security", security)],
                work, apt, method, status, (built[0], built[1]), "1.15.2-1+ceralive.1")
        except StreamError as exc:
            assert "signed runtime archives disagree on package bytes: libfdisk1" in str(exc)
        else:
            raise AssertionError("runtime replay accepted conflicting bytes at an alternate URL")


if __name__ == "__main__":
    regression()
    reject_before_identity_config()
    reject_remote_keyring_before_any_fetch()
    reject_incomplete_trixie_binary_set_before_any_fetch()
    reject_reviewed_package_missing_from_plan()
    regenerate_then_verify_in_another_directory()
    runtime_rauc_replays_target_dependencies_not_the_archive_rauc()
    runtime_rauc_replays_target_dependencies_not_the_archive_rauc(requires_upgrade=True)
    runtime_rauc_replays_target_dependencies_not_the_archive_rauc(shared_pool_url=True)
