#!/usr/bin/env python3
"""Check that the reprobe helper re-registers HDMI-IN, and only HDMI-IN, with PipeWire."""

from __future__ import annotations

import re
import shlex
import sys
from pathlib import Path
from typing import Final

SCOPE: Final = ["--subsystem-match=sound", "--sysname-match=${card_name}"]


def capture_card(conf: str) -> str:
    # The WirePlumber profile rule and the helper must name the same ALSA card id.
    body = re.sub(r"(?m)^\s*#.*$", "", conf)
    _, found, rules = body.partition("device.profile.priority.rules")
    assert found, "Missing device.profile.priority.rules"
    ids = re.findall(r'alsa\.id\s*=\s*"([^"]+)"', rules)
    assert len(ids) == 1, f"Expected one HDMI-IN alsa.id, got {ids!r}"
    return str(ids[0])


def triggers(helper: str) -> list[tuple[list[str], list[str]]]:
    found: list[tuple[list[str], list[str]]] = []
    guard: list[str] = []
    for line in helper.replace("\\\n", " ").splitlines():
        if line.lstrip().startswith("#"):
            continue
        lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        words = list(lexer)
        match words[:1]:
            case ["if" | "elif" | "else"]:
                guard = words
            case ["fi"]:
                guard = []
        if any("udevadm" in word for word in words):
            *command, _message = words
            found.append((guard, command))
    return found


def expected(action: str, guard: list[str]) -> tuple[list[str], list[str]]:
    return guard, [
        "timeout", "--signal=KILL", "1s", "udevadm", "trigger",
        f"--action={action}", *SCOPE, "||", "die",
    ]


def main() -> None:
    helper, conf = (Path(path).read_text() for path in sys.argv[1:])
    only_hdmi = ["if", "[[", "${id}", "==", capture_card(conf), "]]", ";", "then"]
    wanted = [expected("remove", []), expected("add", []), expected("change", only_hdmi)]
    actual = triggers(helper)
    assert actual == wanted, f"udev triggers differ:\n  want {wanted}\n  got  {actual}"


if __name__ == "__main__":
    main()
