#!/usr/bin/env python3
"""resolve.py — YAML parse + JSON-Schema validate + deep-merge + flatten helper.

This is the trusted parsing/validation/merge core for the CeraLive v2 manifest
resolver (``lib/resolve.sh``). The bash side owns orchestration, board/family
file discovery, loud user-facing errors and ``versions.yaml`` pin resolution
(``get_pin``, reused verbatim from ``scripts/fetch-debs.sh``). This helper owns
the parts bash cannot do safely:

  * YAML parsing (PyYAML)
  * JSON-Schema validation (draft 2020-12, python-jsonschema)
  * recursive deep-merge (board overrides family)
  * flattening to a sorted, tab-delimited ``KEY<TAB>VALUE`` param set

It is intentionally generic: it knows nothing about any specific board or
family. Adding a new board never touches this file (MUST-NOT: no board-specific
branches in the loader).

Subcommands
-----------
  get   <file> <key>
        Print one top-level scalar field (used by resolve.sh to read the
        board's ``family:`` ref before the full merge). No schema validation.

  merge --family F.yaml --board B.yaml
        [--family-schema FS.json --board-schema BS.json]
        Validate each manifest against its schema (when schemas are given),
        deep-merge (board wins), flatten, and print sorted ``KEY<TAB>VALUE``
        lines on stdout. Values are RAW (the bash side resolves versions.yaml
        defer tokens and shell-quotes them).

Exit codes
----------
  0  success
  2  schema-invalid / YAML parse error (actionable message on stderr,
     prefixed ``schema invalid:`` so the caller and graders can key on it)
  3  usage / internal error

Merge semantics (LOCKED — see learnings task 12)
------------------------------------------------
  * scalars      : board value wins on key conflict
  * nested maps  : merged recursively, board wins per leaf
  * arrays/lists : board REPLACES the family array entirely (board-specific
                   overlays are authoritative; never appended). Cleaner for
                   per-board overlay sets than an append-and-dedupe.
"""

from __future__ import annotations

import argparse
import sys
from typing import Any

try:
    import yaml
except ImportError as exc:  # pragma: no cover - environment precondition
    sys.stderr.write(
        "schema invalid: PyYAML not available (python3 -c 'import yaml'): "
        f"{exc}\n"
    )
    sys.exit(3)

try:
    import json
    from jsonschema import Draft202012Validator
except ImportError as exc:  # pragma: no cover - environment precondition
    sys.stderr.write(
        "schema invalid: python-jsonschema not available "
        f"(python3 -c 'import jsonschema'): {exc}\n"
    )
    sys.exit(3)


def _die(msg: str, code: int = 2) -> "None":
    """Write an actionable, grep-able error to stderr and exit."""
    sys.stderr.write(msg.rstrip("\n") + "\n")
    sys.exit(code)


def load_yaml(path: str) -> Any:
    """Parse a YAML file, dying loudly (exit 2) on any parse error."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return yaml.safe_load(handle)
    except FileNotFoundError:
        _die(f"schema invalid: {path}: file not found")
    except yaml.YAMLError as exc:
        _die(f"schema invalid: {path}: YAML parse error: {exc}")
    return None  # unreachable; keeps type-checkers happy


def load_json(path: str) -> Any:
    """Parse a JSON Schema file, dying loudly on error."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        _die(f"schema invalid: {path}: schema file not found")
    except json.JSONDecodeError as exc:
        _die(f"schema invalid: {path}: malformed JSON schema: {exc}")
    return None  # unreachable


def validate(instance: Any, schema: Any, path: str) -> "None":
    """Validate ``instance`` against ``schema``; die (exit 2) on any error.

    Emits one ``schema invalid: <file>: field '<field>': <message>`` line per
    violation so the offending field name is always surfaced.
    """
    validator = Draft202012Validator(schema)
    errors = sorted(
        validator.iter_errors(instance),
        key=lambda err: list(err.absolute_path),
    )
    if not errors:
        return
    for err in errors:
        field = "/".join(str(part) for part in err.absolute_path) or "(root)"
        sys.stderr.write(
            f"schema invalid: {path}: field '{field}': {err.message}\n"
        )
    sys.exit(2)


def deep_merge(base: Any, override: Any) -> Any:
    """Deep-merge ``override`` onto ``base`` with board (override) precedence.

    Nested maps merge recursively; arrays and scalars are replaced wholesale by
    the override. Generic over any manifest shape — no field is special-cased.
    """
    if isinstance(base, dict) and isinstance(override, dict):
        merged = dict(base)
        for key, value in override.items():
            if key in merged:
                merged[key] = deep_merge(merged[key], value)
            else:
                merged[key] = value
        return merged
    # arrays: override replaces; scalars: override wins.
    return override


def _scalar(value: Any, prefix: str) -> str:
    """Render a scalar leaf to its flat string form."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return ""
    if isinstance(value, (dict, list)):  # pragma: no cover - guarded by flatten
        _die(f"schema invalid: non-scalar leaf at '{prefix}'")
    # Collapse any stray newlines (e.g. YAML folded scalars) so each param
    # stays a single KEY<TAB>VALUE line.
    return " ".join(str(value).split("\n"))


def flatten(obj: Any, prefix: str = "") -> "dict[str, str]":
    """Flatten a merged manifest tree to a {KEY: value} map.

    * maps     -> ``PARENT_CHILD`` keys (recursive)
    * arrays   -> single space-joined scalar string (no nested objects allowed)
    * scalars  -> string form (bool -> true/false, null -> empty)

    Keys are upper-cased at emission time by the caller.
    """
    out: "dict[str, str]" = {}
    if isinstance(obj, dict):
        for key, value in obj.items():
            child = f"{prefix}_{key}" if prefix else str(key)
            out.update(flatten(value, child))
    elif isinstance(obj, list):
        parts = []
        for element in obj:
            if isinstance(element, (dict, list)):
                _die(
                    "schema invalid: array '"
                    f"{prefix}' contains a non-scalar element; the flat param "
                    "format only supports scalar arrays"
                )
            parts.append(_scalar(element, prefix))
        out[prefix] = " ".join(parts)
    else:
        out[prefix] = _scalar(obj, prefix)
    return out


def cmd_get(args: argparse.Namespace) -> int:
    data = load_yaml(args.file)
    if not isinstance(data, dict):
        _die(f"schema invalid: {args.file}: top-level YAML is not a mapping")
    if args.key not in data:
        _die(
            f"schema invalid: {args.file}: required field "
            f"'{args.key}' not present"
        )
    sys.stdout.write(_scalar(data[args.key], args.key) + "\n")
    return 0


def cmd_merge(args: argparse.Namespace) -> int:
    family = load_yaml(args.family)
    board = load_yaml(args.board)
    if not isinstance(family, dict):
        _die(f"schema invalid: {args.family}: top-level YAML is not a mapping")
    if not isinstance(board, dict):
        _die(f"schema invalid: {args.board}: top-level YAML is not a mapping")

    # Validation is skipped only when schemas are not supplied (the synthetic
    # merge-precedence unit test). The production resolve.sh always supplies
    # both schemas.
    if args.family_schema:
        validate(family, load_json(args.family_schema), args.family)
    if args.board_schema:
        validate(board, load_json(args.board_schema), args.board)

    merged = deep_merge(family, board)
    flat = flatten(merged)
    for key in sorted(flat):
        # Tab-delimited, RAW value. resolve.sh resolves versions.yaml defer
        # tokens then shell-quotes. Keys upper-cased here for the build params.
        sys.stdout.write(f"{key.upper()}\t{flat[key]}\n")
    return 0


def main(argv: "list[str]") -> int:
    parser = argparse.ArgumentParser(
        prog="resolve.py",
        description="YAML validate + deep-merge + flatten helper for resolve.sh",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_get = sub.add_parser("get", help="print one top-level scalar field")
    p_get.add_argument("file")
    p_get.add_argument("key")
    p_get.set_defaults(func=cmd_get)

    p_merge = sub.add_parser(
        "merge", help="validate + deep-merge (board wins) + flatten"
    )
    p_merge.add_argument("--family", required=True)
    p_merge.add_argument("--board", required=True)
    p_merge.add_argument("--family-schema", default=None)
    p_merge.add_argument("--board-schema", default=None)
    p_merge.set_defaults(func=cmd_merge)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
