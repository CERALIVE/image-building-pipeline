#!/usr/bin/env python3
"""Validate every v2 board/family manifest and add-on descriptor against schema.

CI entrypoint for the v2-ci `schema-validate` job. It:

  * self-validates board.schema.json, family.schema.json and addon.schema.json
    (they must themselves be legal draft-2020-12 documents);
  * routes each YAML under manifests/{families,boards}/ to the matching schema by
    directory and validates it;
  * validates every add-on descriptor under manifests/addons/*.json against
    addon.schema.json;
  * runs the cross-descriptor add-on checks the per-file schema cannot express:
      G1  sysext merge identity (sysextLevel == "1", versionId == "12"),
      G2  provides[] stays inside the sysext /usr+/opt boundary (no /etc, /var),
      E6  no two add-ons claim the same provides[] path unless they mutually
          declare each other in conflicts[] (the provides/conflicts model).

Exits non-zero (naming the offending field / descriptor) on any violation so CI
can gate on it. The add-ons directory is overridable via ADDONS_DIR so the test
suite can point validation at a fixture tree.
"""
from __future__ import annotations

import itertools
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

V2 = Path(__file__).resolve().parent.parent
SCHEMA_DIR = V2 / "manifests" / "schema"
ROUTES = {"families": "family.schema.json", "boards": "board.schema.json"}
ADDON_SCHEMA = "addon.schema.json"
# Overridable so the bats suite can validate a fixture tree in isolation.
ADDONS_DIR = Path(os.environ.get("ADDONS_DIR") or (V2 / "manifests" / "addons"))

# sysext merge identity (G1) — must mirror lib/app-layer/sysext.sh.
SYSEXT_LEVEL = "1"
SYSEXT_VERSION_ID = "12"
# Subtrees a systemd-sysext cannot overlay (G2): it merges /usr + /opt ONLY.
FORBIDDEN_PROVIDES_PREFIXES = ("/etc", "/var")


def load_schema(name: str) -> dict:
    return json.loads((SCHEMA_DIR / name).read_text())


def check_addon_semantics(addons: list[dict]) -> list[str]:
    """G1/G2/E6 cross-descriptor checks beyond per-file schema validation.

    Runs on every descriptor that parsed as a JSON object (even ones that failed
    schema validation) so each rule produces a crisp, descriptor-named error and
    none of these checks are vacuous. Returns a list of error strings (empty == OK).
    """
    errors: list[str] = []

    for a in addons:
        aid = a.get("id", "?")

        # G1 — the extension-release identity the kernel keys merging on. The
        # schema's const already pins this; re-checking gives a dedicated message
        # (and catches a descriptor that failed schema for an unrelated field).
        if str(a.get("sysextLevel")) != SYSEXT_LEVEL:
            errors.append(
                f"{aid}: G1 sysextLevel must be '{SYSEXT_LEVEL}' "
                f"(got {a.get('sysextLevel')!r})"
            )
        if str(a.get("versionId")) != SYSEXT_VERSION_ID:
            errors.append(
                f"{aid}: G1 versionId must be '{SYSEXT_VERSION_ID}' "
                f"(got {a.get('versionId')!r})"
            )

        # G2 — a sysext overlays /usr+/opt ONLY. An /etc or /var provides[] path
        # is dropped at merge time, so reject it at validation rather than ship a
        # descriptor that silently loses files on the device.
        for path in a.get("provides", []) or []:
            if isinstance(path, str) and path.startswith(FORBIDDEN_PROVIDES_PREFIXES):
                errors.append(
                    f"{aid}: G2 provides[] path '{path}' escapes the sysext "
                    f"/usr+/opt boundary"
                )

    # E6 — two descriptors may not claim the same provides[] path UNLESS they
    # mutually declare each other in conflicts[]. Mutually-exclusive add-ons can
    # never be merged together, so a shared path is a deliberate either/or, not a
    # runtime file collision.
    claims: dict[str, list[str]] = defaultdict(list)
    for a in addons:
        for path in a.get("provides", []) or []:
            claims[path].append(a.get("id", "?"))
    conflicts_of = {a.get("id"): set(a.get("conflicts", []) or []) for a in addons}

    for path, ids in sorted(claims.items()):
        unique_ids = sorted(set(ids))
        if len(unique_ids) < 2:
            continue
        for x, y in itertools.combinations(unique_ids, 2):
            mutually_exclusive = (
                y in conflicts_of.get(x, set()) and x in conflicts_of.get(y, set())
            )
            if not mutually_exclusive:
                errors.append(
                    f"E6 provides[] collision: path '{path}' claimed by "
                    f"'{x}' and '{y}' with no mutual conflicts[] declaration"
                )
    return errors


def main() -> int:
    rc = 0

    # 1. Self-validate every schema up-front.
    validators: dict[str, Draft202012Validator] = {}
    for subdir, schema_file in ROUTES.items():
        schema = load_schema(schema_file)
        Draft202012Validator.check_schema(schema)
        print(f"OK   schema self-valid: {schema_file}")
        validators[subdir] = Draft202012Validator(schema)

    addon_schema = load_schema(ADDON_SCHEMA)
    Draft202012Validator.check_schema(addon_schema)
    print(f"OK   schema self-valid: {ADDON_SCHEMA}")
    addon_validator = Draft202012Validator(addon_schema)

    checked = 0

    # 2. YAML board/family manifests.
    manifests = sorted((V2 / "manifests").glob("**/*.yaml"))
    if not manifests:
        print("FAIL no manifests found under manifests/", file=sys.stderr)
        return 1

    for path in manifests:
        subdir = path.relative_to(V2 / "manifests").parts[0]
        validator = validators.get(subdir)
        if validator is None:
            continue
        checked += 1
        instance = yaml.safe_load(path.read_text())
        errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))
        if errors:
            rc = 1
            for err in errors:
                field = "/".join(map(str, err.absolute_path)) or "(root)"
                print(f"FAIL {path}: field '{field}': {err.message}", file=sys.stderr)
        else:
            print(f"OK   {subdir[:-1]:6} {path.relative_to(V2)}")

    # 3. JSON add-on descriptors.
    addons: list[dict] = []
    addon_files = sorted(ADDONS_DIR.glob("*.json")) if ADDONS_DIR.is_dir() else []
    for path in addon_files:
        checked += 1
        try:
            instance = json.loads(path.read_text())
        except json.JSONDecodeError as exc:
            rc = 1
            print(f"FAIL {path}: not valid JSON: {exc}", file=sys.stderr)
            continue
        errors = sorted(addon_validator.iter_errors(instance), key=lambda e: list(e.absolute_path))
        if errors:
            rc = 1
            for err in errors:
                field = "/".join(map(str, err.absolute_path)) or "(root)"
                print(f"FAIL {path}: field '{field}': {err.message}", file=sys.stderr)
        else:
            print(f"OK   addon  {path.name}")
        # Semantic checks run on anything that parsed as an object, so a schema
        # failure on one field never masks a G1/G2/E6 violation on another.
        if isinstance(instance, dict):
            addons.append(instance)

    # 4. Cross-descriptor add-on semantics (G1 / G2 / E6).
    for msg in check_addon_semantics(addons):
        rc = 1
        print(f"FAIL {msg}", file=sys.stderr)

    print(f"\n{checked} manifest(s)/descriptor(s) validated, "
          f"{'0 errors' if rc == 0 else 'ERRORS'}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
