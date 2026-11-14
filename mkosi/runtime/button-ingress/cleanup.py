#!/usr/bin/python3
"""Remove only a stopped backend's root-private socket, never other objects."""
import os
from pathlib import Path
import stat


def cleanup(directory=Path('/run/ceralive-button-ingress')):
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise RuntimeError('unsafe ingress runtime directory')
    path = directory / 'rpc.sock'
    try:
        info = path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != 0:
        raise RuntimeError('unexpected ingress path')
    os.unlink(path)


if __name__ == '__main__':
    cleanup()
