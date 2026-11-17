"""One resource identity for ordinary percent-encoded APT URL spellings."""

from __future__ import annotations

import re
from urllib.parse import quote_from_bytes, unquote_to_bytes, urlsplit, urlunsplit


class InputURLError(Exception):
    """A sealed URL changes origin semantics or contains unsafe path encoding."""


def canonical_url(value: str) -> str:
    if type(value) is not str or any(char.isspace() or ord(char) < 32 for char in value):
        raise InputURLError("invalid sealed origin URL")
    try:
        url = urlsplit(value)
        port = url.port
    except ValueError as exc:
        raise InputURLError("invalid sealed origin URL") from exc
    if (url.scheme != "https" or not url.hostname or url.username or url.password
            or port is not None or url.query or url.fragment or "%" in url.netloc
            or "\\" in value or re.search(r"%(?![0-9a-fA-F]{2})", url.path)
            or re.search(r"%(?:2f|5c|00)", url.path, re.IGNORECASE)):
        raise InputURLError("sealed objects require exact HTTPS origin URLs")
    path = unquote_to_bytes(url.path)
    if any(byte < 32 or byte == 127 for byte in path) or any(part in (b".", b"..") for part in path.split(b"/")):
        raise InputURLError("sealed URL path traversal")
    encoded = quote_from_bytes(path, safe="/:@!$&'()*+,;=~._-")
    return urlunsplit((url.scheme, url.netloc, encoded, "", ""))
