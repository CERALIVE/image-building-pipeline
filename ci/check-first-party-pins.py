#!/usr/bin/env python3
"""Fail on stale image pins; rollback exceptions never waive missing evidence."""
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from pin_releases import Catalog, parse_catalog, refresh_catalog, require_fresh, unique_object
from pin_versions import Pin, PinError, compare, image_pins, release_version


def report_installed(pins: tuple[Pin, ...], path: Path) -> None:
    observations: dict[str, str] = {}
    for line in path.read_text().splitlines():
        fields = line.split()
        if len(fields) != 3 or fields[1] not in {"amd64", "arm64", "all"}:
            raise PinError("installed inventory requires package, architecture, version columns")
        key = f"{fields[0]}[{fields[1]}]"
        if key in observations:
            raise PinError(f"duplicate installed observation: {key}")
        observations[key] = fields[2]
    if not observations:
        raise PinError("empty installed inventory")
    for pin in pins:
        if not pin.package:
            continue
        installed = observations.get(pin.subject, observations.get(f"{pin.package}[all]"))
        if installed is None:
            print(f"NOT-OBSERVED {pin.subject}: pinned={pin.version}")
            continue
        try:
            order = compare(installed, pin.version)
            label = {-1: "INSTALLED-OLDER", 0: "INSTALLED-MATCH", 1: "INSTALLED-NEWER"}[order]
            if order == 0 and installed != pin.version:
                label = "INSTALLED-BUILD-DRIFT"
        except PinError:
            label = "INSTALLED-UNCOMPARABLE"
        print(f"{label} {pin.subject}: pinned={pin.version} installed={installed}")


def check(pins: tuple[Pin, ...], catalog: Catalog, overrides_path: Path) -> int:
    overrides = json.loads(overrides_path.read_text(), object_pairs_hook=unique_object)
    if not isinstance(overrides, list):
        raise PinError("rollback overrides must be a JSON list")
    subjects = {pin.subject for pin in pins}
    seen: set[str] = set()
    for row in overrides:
        if not isinstance(row, dict) or set(row) != {"subject", "pinned", "released", "reason", "expires"}:
            raise PinError("invalid rollback override schema")
        if not all(isinstance(value, str) and value.strip() for value in row.values()):
            raise PinError("rollback override requires non-empty strings, including reason")
        if row["subject"] not in subjects or row["subject"] in seen:
            raise PinError(f"unknown/duplicate override subject: {row['subject']}")
        seen.add(row["subject"])
        if datetime.fromisoformat(row["expires"]).date() < datetime.now(timezone.utc).date():
            raise PinError(f"expired override: {row['subject']}")
    failed = False
    used: set[str] = set()
    for pin in pins:
        release = next(r for r in catalog.releases if r.component == pin.component)
        latest = release.tag
        if pin.package and not pin.replacement:
            latest = release.packages.get(pin.subject, release.packages.get(f"{pin.package}[all]", ""))
            if not latest:
                raise PinError(f"missing published package: {pin.subject}")
        stale = pin.replacement or compare(pin.version, latest) < 0
        override = next((row for row in overrides if row["subject"] == pin.subject), None)
        label = "CURRENT"
        if stale:
            if override and override["pinned"] == pin.version and override["released"] == latest:
                label = "ROLLBACK"
                used.add(pin.subject)
            else:
                label = "STALE"
                failed = True
        print(f"{label} {pin.component} {pin.subject}: pinned={pin.version} released={latest}" +
              (f" reason={override['reason']} expires={override['expires']}" if label == "ROLLBACK" else ""))
        if pin.package and not pin.replacement and pin.component != "modem-stack":
            registry = next((p for p in pins if p.subject == f"versions.yaml:{pin.component}"), None)
            if registry and release_version(registry.version) != release_version(pin.version):
                raise PinError(f"registry/package mismatch: {pin.component} {pin.subject}")
        if pin.package == "ceralive-modem-support":
            registry = next(p for p in pins if p.subject == "versions.yaml:modem-stack")
            if compare(registry.version, pin.version) != 0:
                raise PinError("registry/package mismatch: modem-stack companion")
    if seen != used:
        raise PinError(f"unused or mismatched rollback overrides: {sorted(seen - used)}")
    return int(failed)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--overrides", type=Path)
    parser.add_argument("--refresh", action="store_true", help="refresh only release evidence through authenticated gh; never edit pins")
    parser.add_argument("--max-age-hours", type=int, default=168)
    parser.add_argument("--installed", type=Path, help="report saved dpkg-query TSV; never connects to a board")
    args = parser.parse_args()
    path = args.catalog or args.root / "manifests/first-party-releases.json"
    try:
        catalog = refresh_catalog(path) if args.refresh else parse_catalog(path.read_text())
        require_fresh(catalog, datetime.now(timezone.utc), args.max_age_hours)
        print(f"RELEASE EVIDENCE checked_at={catalog.checked_at.isoformat()} (committed snapshot; not a live lookup)")
        pins = image_pins(args.root)
        if args.installed:
            report_installed(pins, args.installed)
        return check(pins, catalog, args.overrides or args.root / "manifests/first-party-pin-overrides.json")
    except (PinError, OSError, ValueError, TypeError, KeyError) as error:
        print(f"UNVERIFIABLE: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
