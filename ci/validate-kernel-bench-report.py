#!/usr/bin/env python3
"""Validate the canonical apt-worker bench schema and candidate's all-pass identity."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys

from jsonschema import Draft202012Validator
from jsonschema.exceptions import best_match


def main() -> int:
    if len(sys.argv) != 7:
        sys.exit("Usage: validate-kernel-bench-report.py REPORT CANDIDATE_RUN_ID TAG COMMIT DEB_SHA256 VERSION")
    filename, candidate, tag, commit, digest, selected = sys.argv[1:]
    report = json.loads(Path(filename).read_text())
    schema = json.loads(Path(__file__).with_name("kernel-bench-report.schema.json").read_text())
    error = best_match(Draft202012Validator(schema).iter_errors(report))
    if error:
        sys.exit(f"Kernel bench report refused: schema: {error.message}")
    values = list(report.values()) if report["type"] == "bootstrap" else [
        report["type"], report["candidate_run_id"], report["tag"],
        report["commit"], report["deb_sha256"],
        *(ref for board in report["boards"].values() for observation in board.values()
          for ref in observation["evidence"]),
    ]
    if any(re.search(r"[\x00-\x1f\x7f-\x9f]", value) for value in values):
        sys.exit("Kernel bench report refused: control character in string")
    if report["deb_sha256"] != digest:
        sys.exit("Kernel bench report refused: deb_sha256 mismatch")
    if report["type"] == "kernel-lane":
        if (report["candidate_run_id"], report["tag"], report["commit"]) != (candidate, tag, commit):
            sys.exit("Kernel bench report refused: candidate_run_id, tag or commit mismatch")
        for board, observations in report["boards"].items():
            for name, observation in observations.items():
                if observation["result"] != "pass":
                    sys.exit(f"Kernel bench report refused: {board}/{name} is not pass")
    elif report["version"] != selected:
        sys.exit("Kernel bench report refused: bootstrap version mismatch")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as exc:
        sys.exit(f"Kernel bench report refused: {exc}")
