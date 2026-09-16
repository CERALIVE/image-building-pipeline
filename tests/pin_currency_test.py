#!/usr/bin/env python3
"""Offline CLI acceptance: release truth is independent of the pinned input."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ci"))
from pin_releases import discover_release, github, refresh_catalog  # noqa: E402 - standalone CLI module path
from pin_versions import PinError, compare  # noqa: E402 - standalone CLI module path


class PinCurrencyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="pin-currency-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / "lib", self.root / "lib")
        shutil.copytree(ROOT / "manifests", self.root / "manifests")
        shutil.copy2(ROOT / "versions.yaml", self.root / "versions.yaml")
        self.catalog = self.root / "releases.json"
        self.data = json.loads((ROOT / "manifests/first-party-releases.json").read_text())
        self.data["checked_at"] = datetime.now(timezone.utc).isoformat()
        # Historical incident fixtures must not follow the live release catalog.
        for component, tag, packages in (
            ("cerastream", "v2026.9.3", {"cerastream[amd64]": "2026.9.3", "cerastream[arm64]": "2026.9.3"}),
            ("gstreamer-rockchip", "1.14.4+ceralive.5", {"gstreamer1.0-rockchip-ceralive[arm64]": "1.14.4+ceralive.5"}),
        ):
            release = next(row for row in self.data["releases"] if row["component"] == component)
            release.update(tag=tag, packages=packages)
        pins = self.root / "manifests/rk3588-userspace-deb-versions.txt"
        plugin = "gstreamer1.0-rockchip-ceralive"
        row = (f"{plugin}  {plugin}_1.14.4+ceralive.5_arm64.deb  "
               "9b991e6320f13c4a281308c49fe9df7518e837e38a3e2db5e6ade4ad6f805e1a  "
               f"https://github.com/CERALIVE/gstreamer-rockchip/releases/download/1.14.4%2Bceralive.5/{plugin}_1.14.4%2Bceralive.5_arm64.deb")
        pins.write_text("\n".join(row if line.startswith(plugin + " ") else line
                                  for line in pins.read_text().splitlines()) + "\n")
        self.save_catalog()
        self.overrides = self.root / "overrides.json"
        self.overrides.write_text("[]\n")
        self.engine_pin("2026.9.3")

    def save_catalog(self) -> None:
        self.catalog.write_text(json.dumps(self.data))

    def engine_pin(self, version: str) -> None:
        pins = self.root / "manifests/first-party-deb-versions.txt"
        lines = pins.read_text().splitlines()
        pins.write_text("\n".join(f"cerastream={version}" if line.startswith("cerastream=") else line for line in lines) + "\n")
        registry = self.root / "versions.yaml"
        import re
        registry.write_text(re.sub(r"(cerastream:\n.*?  pin: )\S+", rf"\g<1>v{version}", registry.read_text(), count=1, flags=re.S))

    def run_guard(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([
            sys.executable, str(ROOT / "ci/check-first-party-pins.py"),
            "--root", str(self.root), "--catalog", str(self.catalog),
            "--overrides", str(self.overrides), *extra,
        ], text=True, capture_output=True, check=False, timeout=20)

    def test_rejects_incident_downgrade(self) -> None:
        # Given the incident pin and independently published v2026.9.3.
        self.engine_pin("2026.9.2")
        # When the shipped CLI checks that input.
        result = self.run_guard()
        # Then it fails for the measured downgrade, not for missing data/tooling.
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("STALE cerastream", result.stdout)
        self.assertIn("2026.9.2", result.stdout)
        self.assertIn("2026.9.3", result.stdout)

    def test_forward_bump_passes(self) -> None:
        self.engine_pin("2026.9.4")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CURRENT cerastream", result.stdout)

    def test_current_release_passes(self) -> None:
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def rollback(self) -> list[dict[str, str]]:
        return [{"subject": subject, "pinned": pinned, "released": released,
                 "reason": "Regression bisect; restore qualified input", "expires": "2099-01-01"}
                for subject, pinned, released in (
                    ("cerastream[amd64]", "2026.9.2", "2026.9.3"),
                    ("cerastream[arm64]", "2026.9.2", "2026.9.3"),
                    ("versions.yaml:cerastream", "v2026.9.2", "v2026.9.3"))]

    def test_explicit_rollback_passes(self) -> None:
        self.engine_pin("2026.9.2")
        self.overrides.write_text(json.dumps(self.rollback()))
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("ROLLBACK cerastream"), 3)

    def test_invalid_overrides_fail(self) -> None:
        self.engine_pin("2026.9.2")
        for field, value in (("reason", " "), ("expires", "2000-01-01"),
                             ("pinned", "2026.9.1"), ("released", "2026.9.4"),
                             ("subject", "unknown")):
            with self.subTest(field=field):
                rows = self.rollback()
                rows[0][field] = value
                self.overrides.write_text(json.dumps(rows))
                self.assertEqual(self.run_guard().returncode, 2)

    def test_unused_override_fails(self) -> None:
        self.overrides.write_text(json.dumps(self.rollback()))
        self.assertEqual(self.run_guard().returncode, 2)

    def test_missing_and_stale_catalog_fail(self) -> None:
        for timestamp in ("2000-01-01T00:00:00Z", "2099-01-01T00:00:00Z"):
            with self.subTest(timestamp=timestamp):
                self.data["checked_at"] = timestamp
                self.save_catalog()
                self.assertEqual(self.run_guard().returncode, 2)
        self.catalog.unlink()
        self.assertEqual(self.run_guard().returncode, 2)

    def test_catalog_component_omission_fails(self) -> None:
        self.data["releases"].pop()
        self.save_catalog()
        self.assertEqual(self.run_guard().returncode, 2)

    def test_catalog_package_omission_fails(self) -> None:
        engine = next(r for r in self.data["releases"] if r["component"] == "cerastream")
        del engine["packages"]["cerastream[arm64]"]
        self.save_catalog()
        self.assertEqual(self.run_guard().returncode, 2)

    def test_duplicate_json_fails(self) -> None:
        self.catalog.write_text(self.catalog.read_text().replace('"schema_version": 1', '"schema_version": 1, "schema_version": 1'))
        self.assertEqual(self.run_guard().returncode, 2)

    def test_one_architecture_downgrade_fails(self) -> None:
        pins = self.root / "manifests/first-party-deb-versions.txt"
        pins.write_text(pins.read_text() + "cerastream[arm64]=2026.9.2\n")
        result = self.run_guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("STALE cerastream cerastream[arm64]", result.stdout)

    def test_registry_only_downgrade_fails(self) -> None:
        registry = self.root / "versions.yaml"
        registry.write_text(registry.read_text().replace("pin: v2026.9.3", "pin: v2026.9.2"))
        self.assertEqual(self.run_guard().returncode, 2)

    def test_unknown_app_package_fails(self) -> None:
        fetcher = self.root / "lib/fetch-debs.sh"
        fetcher.write_text(fetcher.read_text().replace("FIRST_PARTY_APT_PKGS=(", 'FIRST_PARTY_APT_PKGS=("new-package" '))
        self.assertEqual(self.run_guard().returncode, 2)

    def test_duplicate_or_missing_pin_fails(self) -> None:
        pins = self.root / "manifests/first-party-deb-versions.txt"
        original = pins.read_text()
        for text in (original + "cerastream=2026.9.3\n", original.replace("cerastream=2026.9.3\n", "")):
            pins.write_text(text)
            self.assertEqual(self.run_guard().returncode, 2)

    def test_plugin_incident_downgrade_fails(self) -> None:
        pins = self.root / "manifests/rk3588-userspace-deb-versions.txt"
        pins.write_text(pins.read_text().replace("ceralive.5", "ceralive.2"))
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("STALE gstreamer-rockchip", result.stdout)

    def test_url_tag_mismatch_fails(self) -> None:
        pins = self.root / "manifests/rk3588-userspace-deb-versions.txt"
        pins.write_text(pins.read_text().replace("download/1.14.4%2Bceralive.5/", "download/1.14.4%2Bceralive.2/"))
        self.assertEqual(self.run_guard().returncode, 2)

    def test_librga_downgrade_fails(self) -> None:
        pins = self.root / "manifests/rk3588-userspace-deb-versions.txt"
        pins.write_text(pins.read_text().replace("1.10.1+ceralive.1", "1.10.0+ceralive.1").replace("1.10.1%2Bceralive.1", "1.10.0%2Bceralive.1"))
        self.assertEqual(self.run_guard().returncode, 1)

    def test_modem_source_counter_downgrade_fails(self) -> None:
        pins = self.root / "manifests/first-party-deb-versions.txt"
        pins.write_text(pins.read_text().replace("1.34.0-1~ceralive.3", "1.34.0-1~ceralive.2"))
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("STALE modem-stack libmbim", result.stdout)

    def test_installed_drift_is_advisory(self) -> None:
        installed = self.root / "installed.tsv"
        installed.write_text("cerastream\tarm64\t2026.9.4\ngstreamer1.0-rockchip-ceralive\tarm64\t1.14.4+ceralive.4\n")
        result = self.run_guard("--installed", str(installed))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("INSTALLED-NEWER cerastream[arm64]", result.stdout)
        self.assertIn("INSTALLED-OLDER gstreamer1.0-rockchip-ceralive[arm64]", result.stdout)
        self.assertIn("NOT-OBSERVED librga2-ceralive[arm64]", result.stdout)

    def test_predecessor_rollback_requires_override(self) -> None:
        pins = self.root / "manifests/rk3588-userspace-deb-versions.txt"
        lines = pins.read_text().splitlines()
        pins.write_text("\n".join(line.removeprefix("# ") if line.startswith("# librga2 ") else
                                  "# " + line if line.startswith("librga2-ceralive ") else line for line in lines) + "\n")
        self.assertEqual(self.run_guard().returncode, 1)
        self.overrides.write_text(json.dumps([{"subject": "librga2[arm64]", "pinned": "2.2.0-1",
            "released": "1.10.1+ceralive.1", "reason": "Restore predecessor for qualification bisect", "expires": "2099-01-01"}]))
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_real_workflow_wiring(self) -> None:
        import yaml
        for filename in ("v2-ci.yml", "release.yml", "real-build-audit.yml"):
            workflow = yaml.safe_load((ROOT / ".github/workflows" / filename).read_text())
            steps = [step for job in workflow["jobs"].values() for step in job["steps"]
                     if "check-first-party-pins.py" in step.get("run", "")]
            self.assertEqual(len(steps), 1, filename)
            step = steps[0]
            self.assertNotIn("if", step)
            self.assertNotIn("continue-on-error", step)
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c",
                step["run"].replace("python3 ci/check-first-party-pins.py", "python3 ci/check-first-party-pins.py --root " + str(self.root) + " --catalog " + str(self.catalog) + " --overrides " + str(self.overrides))],
                cwd=ROOT, text=True, capture_output=True, check=False, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.engine_pin("2026.9.2")
            rejected = subprocess.run(["bash", "-e", "-o", "pipefail", "-c",
                step["run"].replace("python3 ci/check-first-party-pins.py", "python3 ci/check-first-party-pins.py --root " + str(self.root) + " --catalog " + str(self.catalog) + " --overrides " + str(self.overrides))],
                cwd=ROOT, text=True, capture_output=True, check=False, timeout=30)
            self.assertEqual(rejected.returncode, 1, rejected.stderr)
            self.assertIn("STALE cerastream", rejected.stdout)
            self.engine_pin("2026.9.3")


class VersionTest(unittest.TestCase):
    def test_real_schemes(self) -> None:
        for left, right, expected in (
            ("1.14.4+ceralive.10", "1.14.4+ceralive.9", 1),
            ("1.14.4+ceralive.9", "1.14.4+ceralive.10", -1),
            ("v2026.9.3", "2026.9.3", 0),
            ("2026.9.2+5261ecc", "v2026.9.3", -1),
            ("srt-v1.5.6+ceralive.10", "1.5.6+ceralive.9", 1),
            ("2026.10.0", "2026.9.9", 1),
            ("2026.9.1-20260906T194138.f3c52d5", "v2026.9.1", 0),
            ("1.34.0-1~ceralive.10", "1.34.0-1~ceralive.9", 1),
        ):
            with self.subTest(left=left, right=right):
                self.assertEqual(compare(left, right), expected)

    def test_unknown_scheme_fails(self) -> None:
        for value in ("latest", "", "main", "2026.9.3-rc1", "1.14.4+ceralive.N"):
            with self.subTest(value=value), self.assertRaises(PinError):
                compare(value, "2026.9.3")

    def test_release_discovery_orders_numerically(self) -> None:
        def row(version: str, **flags: bool) -> dict:
            return {"tag_name": version, "draft": False, "prerelease": False,
                    "published_at": "2026-09-01T00:00:00Z", "assets": [{"name": f"gstreamer1.0-rockchip-ceralive_{version}_arm64.deb"}], **flags}
        data = [[row("1.14.4+ceralive.9"), row("1.14.4+ceralive.99", prerelease=True)],
                [row("1.14.4+ceralive.10"), row("1.14.4+ceralive.100", draft=True)]]
        with patch("pin_releases.github", return_value=json.dumps(data)):
            result = discover_release("gstreamer-rockchip")
        self.assertEqual(result.tag, "1.14.4+ceralive.10")

    def test_unavailable_github_fails_closed(self) -> None:
        failed = subprocess.CompletedProcess([], 1, "", "HTTP 503")
        with patch("pin_releases.subprocess.run", return_value=failed) as run, patch("pin_releases.time.sleep"):
            with self.assertRaises(PinError):
                github(["api", "repos/CERALIVE/cerastream/releases"])
        self.assertEqual(run.call_count, 3)

    def test_failed_refresh_preserves_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            path.write_text("original")
            with patch("pin_releases.discover_release", side_effect=PinError("unavailable")):
                with self.assertRaises(PinError):
                    refresh_catalog(path)
            self.assertEqual(path.read_text(), "original")


if __name__ == "__main__":
    unittest.main()
