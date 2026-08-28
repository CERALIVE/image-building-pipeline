#!/usr/bin/env python3
"""resolve.py — YAML parse + JSON-Schema validate + deep-merge + flatten helper.

This is the trusted parsing/validation/merge core for the CeraLive v2 manifest
resolver (``lib/resolve.sh``). The bash side owns orchestration, board/family
file discovery, loud user-facing errors and ``versions.yaml`` pin resolution
(``get_pin``, the one shared reader in ``lib/shared/versions-lib.sh``). This
helper owns the parts bash cannot do safely:

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

  merge --family F.yaml --board B.yaml [--variant NAME]
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

Family variants (task 26)
-------------------------
A family MAY declare a ``variants:`` map of named, OPT-IN overlays. The merge
order becomes ``family -> variant -> board`` — the board still wins last, so a
variant can never override a board-specific fact.

The ``variants:`` key itself is ALWAYS stripped before flattening, selected or
not, so an unselected overlay can never leak a second kernel pin into the param
set. ``default`` is the reserved name meaning "the family's own default".

WHICH overlay that name resolves to is the family's to declare. With no
``default_variant:`` key it resolves to NO overlay, and the family top-level
fields are the production answer. With ``default_variant: <name>`` a
variant-less build resolves that named overlay instead — byte-identically to
passing ``--variant <name>`` — and the top-level fields become the base every
other variant still starts from. rk3588 uses this to make the mainline
source-built track production without copying its pins out of the ``edge``
overlay; see ``resolve_default_variant`` for why copying was refused.

When the applied overlay carries a ``kernel_source`` block the resolver also
injects ONE derived key, ``kernel_source.suppressed_packages`` — the union of
the pre-overlay family kernel/DTB package names and the post-merge ones. The
orchestrator forwards it so the fetcher excludes exactly those names from the
remote (Armbian) fetch. Deriving it here rather than authoring it in YAML is
deliberate: a hand-written suppression list would silently drift from the
replacement list the moment either changed.

Board variant overrides (task 27)
---------------------------------
Because the board always wins last, a family variant can never restate a
board-specific fact — by design. But a fact can legitimately DIFFER per variant
while still being the board's own. Two do, and the schema admits exactly those
two: a board's DTB filename comes from whichever kernel tree built it, and its
U-Boot package comes from whichever Armbian branch the variant tracks — the
``-vendor`` build carries Rockchip's closed rkbin BL31 while ``-edge`` is built
from the ``tpl-blob-atf-mainline`` scenario with TF-A compiled from upstream.
Neither pair of trees/branches need agree.

Both ride the SAME generic machinery below: ``uboot_packages`` needed no code
here because ``deep_merge`` replaces arrays wholesale, so a per-variant list
supersedes the board's top-level one by construction. What the widening does
require is a CONSUMER — ``lib/write-bootloader.sh`` keys its committed
``manifests/bootloader-blobs.tsv`` on the same board×variant tuple, so a
per-variant package that resolves here can never be written as the other
variant's blob.

So the BOARD (never the family) MAY declare a ``variant_overrides:`` map keyed
by variant name. It is applied AFTER the board merge, so board-wins-last is
strengthened rather than weakened: the override is itself a board fact, just one
scoped to a variant. Like ``variants:``, the key is ALWAYS stripped before
flattening — selected or not — so a board that declares one resolves byte-
identically on the default path to a board that never did.

An override naming a variant the family does not declare is FATAL on every
resolve, including the default path. A silently-inert override is exactly the
failure mode this mechanism exists to prevent.

Sibling variant inheritance (`extends`)
---------------------------------------
A variant MAY declare ``extends: <sibling>``, making it a DELTA on that sibling
rather than a standalone overlay. Resolution becomes ``family -> parent ->
child -> board``, ancestor-first, and the ``extends`` key never survives into
the result.

It exists so a debug sibling of a production variant cannot drift off it. The
`edge-test` variant is a KASAN/lockdep build of exactly what `edge` compiles, and
a build is only evidence about production if it compiles the same source -- a
copy-pasted sibling looks identical on the day it is written and diverges
silently on the first `edge` re-pin. Inheriting the pins makes that divergence
structurally impossible rather than merely discouraged.

Three malformed graphs are REFUSED rather than partially applied: a parent the
family does not declare, a variant naming itself, and any cycle. Because a child
is schema-validated as a PARTIAL (it does not restate its parent's required
pins), the COMPLETE contract is re-asserted here against the MERGED result -- so
`extends` is an expression of the pin discipline, not a hole in it.
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


DEFAULT_VARIANT = "default"

VARIANT_EXTENDS = "extends"

# The family key that says WHICH declared variant a variant-less build resolves.
# Absent, `default` keeps its original meaning: apply no overlay at all.
FAMILY_DEFAULT_VARIANT = "default_variant"

# The two spellings of "which Kconfig fragment(s) does this variant merge". They
# are mutually exclusive in the schema, so an `extends` child that declares one
# must CLEAR the other off its inherited parent — otherwise the merged block
# would carry both and fail its own oneOf. Keyed child-key -> sibling-to-drop.
_CONFIG_MODE_SIBLINGS = {
    "defconfig_fragment": "defconfig_fragments",
    "defconfig_fragments": "defconfig_fragment",
}


def _clear_replaced_config_keys(base: Any, overlay: Any) -> None:
    """Drop an inherited fragment key the child variant replaces.

    ``defconfig_fragment`` (one path) and ``defconfig_fragments`` (an ordered
    list) say the same thing two ways, so the schema admits exactly one. A child
    that switches spelling is REPLACING its parent's declaration, not adding a
    second one — without this the deep-merge would keep both and the resolved
    block would be rejected by the very rule that makes it unambiguous.

    Mutates ``base`` in place; ``base`` is always a fresh copy by this point.
    """
    if not isinstance(base, dict) or not isinstance(overlay, dict):
        return
    base_ks = base.get("kernel_source")
    overlay_ks = overlay.get("kernel_source")
    if not isinstance(base_ks, dict) or not isinstance(overlay_ks, dict):
        return
    for child_key, sibling in _CONFIG_MODE_SIBLINGS.items():
        if child_key in overlay_ks and sibling in base_ks:
            base_ks = dict(base_ks)
            base_ks.pop(sibling, None)
            base["kernel_source"] = base_ks


def resolve_variant_overlay(variants: Any, variant: str, path: str) -> Any:
    """Flatten a variant's ``extends`` chain into ONE effective overlay.

    Resolution is ancestor-first — the furthest ancestor is the base and each
    descendant is merged on top — so the declared order family -> parent ->
    child -> board holds, and a child only has to state what it CHANGES. The
    ``extends`` key itself never survives into the result.

    Three malformed graphs are refused rather than partially applied: a parent
    the family does not declare, a variant naming itself, and any cycle.
    """
    chain: "list[str]" = []
    seen: "set[str]" = set()
    name = variant
    while True:
        overlay = variants[name]
        chain.append(name)
        seen.add(name)
        parent = overlay.get(VARIANT_EXTENDS) if isinstance(overlay, dict) else None
        if parent is None:
            break
        if not isinstance(parent, str):
            _die(
                f"schema invalid: {path}: variant '{name}' extends a non-string "
                f"value {parent!r}"
            )
        if parent == name:
            _die(
                f"schema invalid: {path}: variant '{name}' extends itself; a "
                "variant cannot be its own parent"
            )
        if parent == DEFAULT_VARIANT:
            _die(
                f"schema invalid: {path}: variant '{name}' extends "
                f"'{DEFAULT_VARIANT}', which is the reserved no-overlay name — "
                "every variant already starts from the family defaults"
            )
        if parent not in variants:
            available = ", ".join(sorted(variants)) if variants else "<none>"
            _die(
                f"schema invalid: {path}: variant '{name}' extends unknown "
                f"variant '{parent}' (available: {available})"
            )
        if parent in seen:
            cycle = " -> ".join([*chain, parent])
            _die(f"schema invalid: {path}: variant extends cycle: {cycle}")
        name = parent

    effective: Any = {}
    for name in reversed(chain):
        overlay = {
            key: value
            for key, value in variants[name].items()
            if key != VARIANT_EXTENDS
        }
        _clear_replaced_config_keys(effective, overlay)
        effective = deep_merge(effective, overlay)
    return effective

# Family fields whose package names the remote (Armbian) fetch must skip when a
# variant builds the kernel from source. U-Boot and firmware are deliberately
# ABSENT: they stay prebuilt-fetched.
_SUPPRESSED_FIELDS = ("kernel_packages", "dtb_packages")


def _package_names(manifest: Any, fields: "tuple[str, ...]") -> "list[str]":
    """Collect the package names a manifest declares across ``fields``."""
    names: "list[str]" = []
    if not isinstance(manifest, dict):
        return names
    for field in fields:
        value = manifest.get(field)
        if isinstance(value, list):
            names.extend(str(item) for item in value)
    return names


def _dedupe(names: "list[str]") -> "list[str]":
    """Order-preserving de-duplication."""
    seen: "set[str]" = set()
    out: "list[str]" = []
    for name in names:
        if name not in seen:
            seen.add(name)
            out.append(name)
    return out


def resolve_default_variant(family: Any, path: str) -> str:
    """Return the variant name a variant-less build resolves for ``family``.

    ``default_variant`` is what makes a track the PRODUCTION one without copying
    its overlay to the family top level. Copying was the alternative and it is
    strictly worse: the ``extends`` child would have to restate its parent's
    pins (the byte-for-byte drift ``extends`` exists to make impossible) and a
    config-file-mode variant would deep-merge onto the family's defconfig mode,
    producing the half-specified config the schema's ``oneOf`` forbids.
    """
    if not isinstance(family, dict):
        return DEFAULT_VARIANT
    declared = family.get(FAMILY_DEFAULT_VARIANT)
    if declared is None:
        return DEFAULT_VARIANT
    if not isinstance(declared, str) or not declared:
        _die(
            f"schema invalid: {path}: {FAMILY_DEFAULT_VARIANT} must be a "
            f"non-empty variant name, got {declared!r}"
        )
    if declared == DEFAULT_VARIANT:
        _die(
            f"schema invalid: {path}: {FAMILY_DEFAULT_VARIANT} may not be "
            f"'{DEFAULT_VARIANT}' — that is the reserved no-overlay name, which "
            "is what an absent key already means"
        )
    variants = family.get("variants")
    if not isinstance(variants, dict) or declared not in variants:
        available = (
            ", ".join(sorted(variants))
            if isinstance(variants, dict) and variants
            else "<none>"
        )
        _die(
            f"schema invalid: {path}: {FAMILY_DEFAULT_VARIANT} names undeclared "
            f"variant '{declared}' (available: {available})"
        )
    return declared


def apply_variant(
    family: Any, variant: str, path: str, schema: Any = None
) -> "tuple[Any, Any]":
    """Strip ``variants:`` from ``family`` and apply the selected overlay.

    Returns ``(base, overlay)`` where ``base`` is the family with ``variants:``
    removed and the overlay merged in (when one was selected), and ``overlay``
    is the raw overlay mapping (or ``None`` when no overlay applies).

    Stripping happens unconditionally so an unselected ``variants:`` block never
    reaches ``flatten()`` — the guarantee that declaring a variant cannot move
    the resolved param set by a single byte. ``default_variant`` is stripped for
    the same reason; the caller has already resolved it to a real variant name.
    """
    if not isinstance(family, dict):
        return family, None
    base = {
        key: value
        for key, value in family.items()
        if key not in ("variants", FAMILY_DEFAULT_VARIANT)
    }
    variants = family.get("variants")

    if variant in ("", DEFAULT_VARIANT):
        return base, None

    if not isinstance(variants, dict) or variant not in variants:
        available = (
            ", ".join(sorted(variants)) if isinstance(variants, dict) and variants
            else "<none>"
        )
        _die(
            f"schema invalid: {path}: unknown variant '{variant}' "
            f"(available: {available})"
        )
    overlay = resolve_variant_overlay(variants, variant, path)
    if schema is not None and VARIANT_EXTENDS in variants[variant]:
        # An `extends` child is schema-validated as a PARTIAL, so the complete
        # kernel_source contract (every required pin, exactly one config mode)
        # is only checkable once inheritance has been applied. Re-run the full
        # overlay schema here so a child can neither drop a pin nor inherit an
        # ambiguous config mode.
        validate(
            overlay,
            {
                "$schema": schema.get("$schema"),
                "$ref": "#/$defs/variant_overlay",
                "$defs": schema["$defs"],
            },
            f"{path} (resolved variant '{variant}')",
        )
    return deep_merge(base, overlay), overlay


BOARD_VARIANT_OVERRIDES = "variant_overrides"


def apply_board_variant_overrides(
    board: Any, variant: str, path: str, family_variants: Any
) -> "tuple[Any, Any]":
    """Strip ``variant_overrides:`` from ``board`` and select the named override.

    Returns ``(base, override)`` where ``base`` is the board with the key
    removed and ``override`` is the raw mapping for ``variant`` (or ``None``).
    The caller merges ``override`` AFTER the board so it lands last.

    Every declared override name is cross-checked against the family's declared
    variants on EVERY resolve, default path included. A typo'd name would
    otherwise sit in the manifest looking effective while never applying.
    """
    if not isinstance(board, dict):
        return board, None
    base = {
        key: value
        for key, value in board.items()
        if key != BOARD_VARIANT_OVERRIDES
    }
    overrides = board.get(BOARD_VARIANT_OVERRIDES)
    if not isinstance(overrides, dict):
        return base, None

    declared = family_variants if isinstance(family_variants, dict) else {}
    for name in sorted(overrides):
        if name not in declared:
            available = ", ".join(sorted(declared)) if declared else "<none>"
            _die(
                f"schema invalid: {path}: {BOARD_VARIANT_OVERRIDES} names "
                f"variant '{name}', which the family does not declare "
                f"(available: {available}) — it would never apply"
            )

    if variant in ("", DEFAULT_VARIANT):
        return base, None
    return base, overrides.get(variant)


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
    family_schema: Any = None
    if args.family_schema:
        family_schema = load_json(args.family_schema)
        validate(family, family_schema, args.family)
    if args.board_schema:
        validate(board, load_json(args.board_schema), args.board)

    variant = args.variant or DEFAULT_VARIANT
    if variant == DEFAULT_VARIANT:
        variant = resolve_default_variant(family, args.family)
    pre_overlay_packages = _package_names(family, _SUPPRESSED_FIELDS)
    base, overlay = apply_variant(
        family, variant, args.family, family_schema if args.family_schema else None
    )
    board_base, board_override = apply_board_variant_overrides(
        board, variant, args.board, family.get("variants")
    )

    merged = deep_merge(base, board_base)
    if isinstance(board_override, dict):
        # Applied AFTER the board so a per-variant board fact wins over the
        # board's own default — the board still has the last word either way.
        merged = deep_merge(merged, board_override)

    if isinstance(overlay, dict) and isinstance(overlay.get("kernel_source"), dict):
        # Record which variant produced this param set, and derive the exact
        # set of package names the remote fetch must skip. Both keys appear
        # ONLY on a kernel-from-source variant, so the default path is
        # byte-unchanged.
        merged["kernel_variant"] = variant
        merged["kernel_source"]["suppressed_packages"] = _dedupe(
            pre_overlay_packages + _package_names(merged, _SUPPRESSED_FIELDS)
        )

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
    p_merge.add_argument(
        "--variant",
        default=DEFAULT_VARIANT,
        help=(
            "family variant overlay to apply (merge order family -> variant -> "
            f"board). '{DEFAULT_VARIANT}' (the default) applies no overlay."
        ),
    )
    p_merge.add_argument("--family-schema", default=None)
    p_merge.add_argument("--board-schema", default=None)
    p_merge.set_defaults(func=cmd_merge)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
