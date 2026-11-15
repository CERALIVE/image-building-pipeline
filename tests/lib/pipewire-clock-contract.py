#!/usr/bin/env python3
"""Read SPA objects without losing duplicate declarations or quoted strings."""

from __future__ import annotations

import json
import re
import sys
from collections import deque
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Final


@dataclass(frozen=True)
class SpaObject:
    entries: tuple[tuple[str, Value], ...]

    def get(self, key: str) -> Value | None:
        return next((value for name, value in reversed(self.entries) if name == key), None)


Value = str | tuple["Value", ...] | SpaObject
TOKEN: Final = re.compile(
    r'\s+|#[^\n]*|"(?:[^"\\]|\\.)*"|[{}\[\]=:,]|[^\s#{}\[\]=:,"]+'
)
OWNERSHIP: Final = frozenset(
    (
        "context.objects", "node.group", "priority.driver", "node.driver",
        "resample.disable", "node.force-rate", "node.lock-rate",
    )
)
RATES: Final = (
    ("default.clock.rate", "48000"),
    ("default.clock.allowed-rates", ("48000",)),
)


def scalar(token: str) -> str:
    if token.startswith('"'):
        decoded = json.loads(token)
        assert isinstance(decoded, str)
        return decoded
    assert token not in ("{", "}", "[", "]", "=", ":")
    return token


def parse(text: str) -> SpaObject:
    # SPA permits omitted root braces, commas, and =/: separators. Retain pairs:
    # a last-value dictionary alone would hide an earlier forbidden assignment.
    tokens: deque[str] = deque()
    position = 0
    for token in TOKEN.finditer(text):
        assert token.start() == position, f"Invalid SPA token at {position}"
        position = token.end()
        word = token.group()
        if not word.isspace() and not word.startswith("#") and word != ",":
            tokens.append(word)
    assert position == len(text), f"Invalid SPA token at {position}"

    def read_object(end: str | None) -> SpaObject:
        entries: list[tuple[str, Value]] = []
        while tokens and tokens[0] != end:
            key = scalar(tokens.popleft())
            if tokens and tokens[0] in ("=", ":"):
                tokens.popleft()
            entries.append((key, read_value()))
        if end is not None:
            assert tokens and tokens.popleft() == end, f"Missing {end}"
        return SpaObject(tuple(entries))

    def read_value() -> Value:
        assert tokens, "Missing SPA value"
        token = tokens.popleft()
        match token:
            case "{":
                return read_object("}")
            case "[":
                values: list[Value] = []
                while tokens and tokens[0] != "]":
                    values.append(read_value())
                assert tokens and tokens.popleft() == "]", "Missing ]"
                return tuple(values)
            case _:
                return scalar(token)

    root = read_value() if tokens and tokens[0] == "{" else read_object(None)
    assert isinstance(root, SpaObject), "Expected SPA root object"
    assert not tokens, "Trailing SPA tokens"
    return root


def assignments(value: Value) -> Iterator[tuple[str, Value]]:
    match value:
        case SpaObject(entries):
            for key, child in entries:
                yield key, child
                yield from assignments(child)
        case tuple():
            for child in value:
                yield from assignments(child)
        case str():
            return


def main() -> None:
    mode, *paths = sys.argv[1:]
    documents = [(path, parse(Path(path).read_text())) for path in paths]
    match mode:
        case "ownership":
            for path, document in documents:
                for key, _ in assignments(document):
                    assert key not in OWNERSHIP, f"{path}: image sets {key}"
        case "rate" | "allowed-rates":
            for path, document in documents:
                for key, value in assignments(document):
                    for rate_key, expected in RATES:
                        if key == rate_key:
                            assert value == expected, f"{path}: {key} = {value!r}"
            properties = documents[0][1].get("context.properties")
            assert isinstance(properties, SpaObject), "Missing context.properties"
            for key, expected in RATES:
                assert properties.get(key) == expected, f"Effective {key} != {expected!r}"
            if mode == "rate":
                print(properties.get("default.clock.rate"))
            else:
                allowed = properties.get("default.clock.allowed-rates")
                assert isinstance(allowed, tuple)
                print("[" + ",".join(str(rate) for rate in allowed) + "]")
        case "driver":
            objects = documents[0][1].get("context.objects")
            assert isinstance(objects, tuple), "Missing context.objects array"
            for node in objects:
                match node:
                    case SpaObject() if node.get("factory") == "spa-node-factory":
                        match node.get("args"):
                            case SpaObject() as args:
                                if (
                                    args.get("factory.name") == "support.node.driver"
                                    and args.get("node.name") == "Dummy-Driver"
                                    and args.get("node.group") == "pipewire.dummy"
                                ):
                                    return
            raise AssertionError("Missing Dummy-Driver args in group pipewire.dummy")
        case _:
            raise AssertionError(f"Unknown contract: {mode}")


if __name__ == "__main__":
    main()
