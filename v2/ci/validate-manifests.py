#!/usr/bin/env python3
"""Validate every v2 board/family manifest against its draft-2020-12 JSON Schema.

CI entrypoint for the v2-ci `schema-validate` job. Routes each YAML under
manifests/{families,boards}/ to the matching schema by directory, self-validates
both schemas first, and exits non-zero (naming the offending field) on any
violation so CI can gate on it.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

V2 = Path(__file__).resolve().parent.parent
SCHEMA_DIR = V2 / "manifests" / "schema"
ROUTES = {"families": "family.schema.json", "boards": "board.schema.json"}


def load_schema(name: str) -> dict:
    return json.loads((SCHEMA_DIR / name).read_text())


def main() -> int:
    validators: dict[str, Draft202012Validator] = {}
    for subdir, schema_file in ROUTES.items():
        schema = load_schema(schema_file)
        Draft202012Validator.check_schema(schema)
        print(f"OK   schema self-valid: {schema_file}")
        validators[subdir] = Draft202012Validator(schema)

    manifests = sorted((V2 / "manifests").glob("**/*.yaml"))
    if not manifests:
        print("FAIL no manifests found under manifests/", file=sys.stderr)
        return 1

    rc = 0
    checked = 0
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

    print(f"\n{checked} manifest(s) validated, {'0 errors' if rc == 0 else 'ERRORS'}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
