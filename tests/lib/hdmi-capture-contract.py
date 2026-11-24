#!/usr/bin/env python3
"""Check that the reprobe helper re-registers HDMI-IN, and only HDMI-IN, with PipeWire."""

from __future__ import annotations

import importlib.util
import re
import shlex
import sys
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "pipewire_clock_contract", Path(__file__).with_name("pipewire-clock-contract.py")
)
assert SPEC and SPEC.loader
spa = sys.modules[SPEC.name] = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(spa)


def capture_card(conf: str) -> str:
    # The WirePlumber profile rule and the helper must name the same ALSA card id.
    rules = spa.parse(conf).get("device.profile.priority.rules")
    assert rules, "Missing device.profile.priority.rules"
    ids = [value for key, value in spa.assignments(rules) if key == "alsa.id"]
    assert len(ids) == 1 and isinstance(ids[0], str), f"Expected one alsa.id, got {ids!r}"
    return ids[0]


def statements(helper: str) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    guard = ""
    for line in helper.replace("\\\n", " ").splitlines():
        if line.lstrip().startswith("#"):
            continue
        lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        words = " ".join(lexer)
        match words.split()[:1]:
            case ["if" | "elif" | "else"]:
                guard = words
            case ["fi"]:
                guard = ""
        found.append((guard, words))
    return found


def main() -> None:
    helper, conf = (Path(path).read_text() for path in sys.argv[1:])
    only_hdmi = f"if [[ ${{id}} == {capture_card(conf)} ]] ; then"
    wanted = [
        ("", "uptime=${CERALIVE_AUDIO_UPTIME:-/proc/uptime}"),
        ("", "timeout --foreground --signal=KILL ${left} $@"),
        ("", "id=$1"),
        ("", "card_name="),
        ("if [[ ${candidate} == ${id} ]] ; then", "card_name=${card##*/}"),
        ("", "bounded udevadm trigger --action=$1 --subsystem-match=sound"
             " --sysname-match=${card_name} 9 >& - || die"),
        ("", "trigger remove"),
        ("", "trigger add"),
        (only_hdmi, "trigger change"),
    ]
    actual = [
        (guard, re.sub(r"(\|\| die) .*", r"\1", words))
        for guard, words in statements(helper)
        if re.match(r"uptime=|id=|card_name=|trigger \w", words)
        or "udevadm" in words or "timeout" in words
    ]
    assert actual == wanted, f"HDMI-IN reprobe differs:\n  want {wanted}\n  got  {actual}"


if __name__ == "__main__":
    main()
