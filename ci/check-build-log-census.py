#!/usr/bin/env python3
"""check-build-log-census.py — schema gate for docs/build-log-census.md.

The census is a DATA FILE that ci/check-build-log.sh executes against real build
logs, so a malformed row is a silently weakened lint rather than a typo. This
checker enforces the parts a human reviewer reliably misses:

  * exactly --expect-count baseline rows, numbered 1..N with no gaps
  * every signature unique, non-empty and backtick-quoted
  * every signature an EXACT string — no wildcard/regex metacharacter that would
    turn an allowlist entry into a prefix match
  * a known stage and a non-empty owner
  * a disposition in {FIXED, ACCEPTED, BLOCKING}
  * FIXED and BLOCKING rows name the todo (8-11) that removes them
  * ACCEPTED rows carry a real rationale, not a placeholder
  * the post-fix table (if present) names an introducing todo and a numeric max

Usage:
    ci/check-build-log-census.py [--expect-count N] [CENSUS]

Prints "<N> PASS" and exits 0 when the census is well-formed.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DISPOSITIONS = ("FIXED", "ACCEPTED", "BLOCKING")

# Build stages a signature can be attributed to. Kept explicit so a typo lands as
# a failure instead of an unreviewable free-text field.
STAGES = (
    "resolve",
    "fetch",
    "kernel-build",
    "mkosi:config",
    "mkosi:base",
    "mkosi:platform",
    "mkosi:runtime",
    "mkosi:app",
    "mkosi:staging",
    "mkosi:*",
    "assemble:repart",
    "assemble:disk",
)

# The lint compares signatures with `==`, so a glob/regex here would silently
# never match. Brackets and `$` are NOT rejected: real diagnostics contain them
# ("[Output]", "$PATH").
WILDCARD_TOKENS = ("*", ".*", "\\")

TODO_RE = re.compile(r"\btodo(8|9|10|11)\b")
MIN_RATIONALE = 40


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def split_row(line: str) -> list[str]:
    inner = line.strip()
    if not inner.startswith("|") or not inner.endswith("|"):
        return []
    return [c.strip() for c in inner[1:-1].split("|")]


def is_separator(cells: list[str]) -> bool:
    return bool(cells) and all(re.fullmatch(r":?-{2,}:?", c) for c in cells)


def unquote(cell: str, where: str) -> str:
    if not (cell.startswith("`") and cell.endswith("`") and len(cell) > 2):
        fail(f"{where}: signature must be wrapped in backticks, got {cell!r}")
    return cell[1:-1]


def check_signature(sig: str, where: str, seen: dict[str, str]) -> None:
    if not sig:
        fail(f"{where}: empty signature")
    if sig != sig.strip():
        fail(f"{where}: signature has leading/trailing whitespace: {sig!r}")
    for token in WILDCARD_TOKENS:
        if token in sig:
            fail(
                f"{where}: signature contains the pattern token {token!r}; "
                "census entries must be exact strings"
            )
    if sig in seen:
        fail(f"{where}: duplicate signature (also at {seen[sig]}): {sig!r}")
    seen[sig] = where


def parse_tables(text: str) -> tuple[list[list[str]], list[list[str]]]:
    """Return (baseline rows, post-fix rows), each a list of cell lists."""
    baseline_header = ["#", "Signature", "Baseline", "Stage", "Owner", "Disposition", "Note"]
    postfix_header = ["Signature", "Max", "Stage", "Introduced by", "Rationale"]

    baseline: list[list[str]] = []
    postfix: list[list[str]] = []
    active: list[list[str]] | None = None

    for raw in text.splitlines():
        cells = split_row(raw)
        if not cells:
            active = None
            continue
        if is_separator(cells):
            continue
        if cells == baseline_header:
            active = baseline
            continue
        if cells == postfix_header:
            active = postfix
            continue
        if active is not None:
            active.append(cells)

    return baseline, postfix


def main() -> int:
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("census", nargs="?", default=str(here.parent / "docs" / "build-log-census.md"))
    ap.add_argument("--expect-count", type=int, default=None)
    args = ap.parse_args()

    path = Path(args.census)
    if not path.is_file():
        fail(f"census not found: {path}")
    text = path.read_text(encoding="utf-8")

    baseline, postfix = parse_tables(text)
    if not baseline:
        fail("no baseline census table found (header row must match the documented schema)")

    seen: dict[str, str] = {}
    blocking = 0
    counts = {d: 0 for d in DISPOSITIONS}

    for index, cells in enumerate(baseline, start=1):
        where = f"baseline row {index}"
        if len(cells) != 7:
            fail(f"{where}: expected 7 columns, got {len(cells)}")
        num, sig_cell, base_cell, stage, owner, disp, note = cells

        if num != str(index):
            fail(f"{where}: row numbers must be contiguous from 1; got {num!r}")

        check_signature(unquote(sig_cell, where), where, seen)

        if not re.fullmatch(r"\d+", base_cell):
            fail(f"{where}: baseline count must be a non-negative integer, got {base_cell!r}")
        if int(base_cell) < 1:
            fail(f"{where}: baseline count must be >= 1 (a census row records an OBSERVED signature)")

        if stage not in STAGES:
            fail(f"{where}: unknown stage {stage!r} (allowed: {', '.join(STAGES)})")
        if not owner:
            fail(f"{where}: owner must not be empty")

        if disp not in DISPOSITIONS:
            fail(f"{where}: disposition must be one of {DISPOSITIONS}, got {disp!r}")
        counts[disp] += 1

        if disp in ("FIXED", "BLOCKING"):
            if not TODO_RE.search(note):
                fail(
                    f"{where}: a {disp} row must name the todo that removes it "
                    "(todo8/todo9/todo10/todo11)"
                )
        if disp == "BLOCKING":
            blocking += 1
        if disp == "ACCEPTED" and len(note) < MIN_RATIONALE:
            fail(
                f"{where}: an ACCEPTED row needs a real rationale "
                f"(>= {MIN_RATIONALE} chars), got {len(note)}"
            )

    for index, cells in enumerate(postfix, start=1):
        where = f"post-fix row {index}"
        if len(cells) != 5:
            fail(f"{where}: expected 5 columns, got {len(cells)}")
        sig_cell, max_cell, stage, introduced, rationale = cells
        check_signature(unquote(sig_cell, where), where, seen)
        if not re.fullmatch(r"\d+", max_cell) or int(max_cell) < 1:
            fail(f"{where}: max must be a positive integer, got {max_cell!r}")
        if stage not in STAGES:
            fail(f"{where}: unknown stage {stage!r}")
        if not TODO_RE.search(introduced):
            fail(f"{where}: must name the todo that introduces it (todo8/todo9/todo10/todo11)")
        if len(rationale) < MIN_RATIONALE:
            fail(f"{where}: needs a real rationale (>= {MIN_RATIONALE} chars)")

    if args.expect_count is not None and len(baseline) != args.expect_count:
        fail(f"expected {args.expect_count} baseline signatures, found {len(baseline)}")

    print(
        f"{len(baseline)} PASS "
        f"(FIXED={counts['FIXED']} ACCEPTED={counts['ACCEPTED']} BLOCKING={blocking}, "
        f"post-fix={len(postfix)})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
