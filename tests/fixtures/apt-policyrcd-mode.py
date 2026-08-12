#!/usr/bin/env python3
"""Report the file mode mkosi's policy-rc.d write site actually produces.

Loads a standalone reproduction of mkosi 26's `Apt.install()` policy-rc.d write
site (built by the caller), executes it against a scratch root, and prints the
resulting mode. This exists because the defect it guards is a MODE, not a path:
`invoke-rc.d` gates the helper on `test -x`, so a 0644 helper is reported as
missing rather than as denying, and every text-level assertion about the patch
would pass on a version of it that changes nothing.
"""

import os
import stat
import sys
import tempfile
import types
from contextlib import contextmanager
from pathlib import Path


@contextmanager
def _umask(mask: int):
    old = os.umask(mask & 0o777)
    try:
        yield
    finally:
        os.umask(old)


def main(apt_py: str) -> int:
    util = types.ModuleType("mkosi.util")
    util.umask = _umask  # type: ignore[attr-defined]
    pkg = types.ModuleType("mkosi")
    pkg.__path__ = []  # type: ignore[attr-defined]
    sys.modules["mkosi"] = pkg
    sys.modules["mkosi.util"] = util

    namespace: dict = {}
    exec(compile(Path(apt_py).read_text(), apt_py, "exec"), namespace)

    root = Path(tempfile.mkdtemp())
    context = types.SimpleNamespace(root=root)
    namespace["Apt"].install(context, [])

    policy = root / "usr/sbin/policy-rc.d"
    print("%04o" % stat.S_IMODE(policy.stat().st_mode))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
