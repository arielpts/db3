#!/usr/bin/env python3
"""Serialize build mutations, preserving the lock across exec and nested calls."""

import errno
import fcntl
import os
from pathlib import Path
import stat
import sys


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "build/.build.lock"
LOCK_FD_ENV = "DB3_BUILD_LOCK_FD"


def inherited_lock_fd():
    """Accept only a live descriptor for this checkout's lock file."""
    value = os.environ.get(LOCK_FD_ENV)
    if value is None:
        return None
    try:
        descriptor = int(value)
        descriptor_stat = os.fstat(descriptor)
        path_stat = LOCK_PATH.stat()
    except (ValueError, OverflowError, OSError):
        return None
    if (
        stat.S_ISREG(descriptor_stat.st_mode)
        and descriptor_stat.st_dev == path_stat.st_dev
        and descriptor_stat.st_ino == path_stat.st_ino
    ):
        return descriptor
    return None


def main():
    command = sys.argv[1:]
    if command and command[0] == "--":
        command = command[1:]
    help_requested = bool(command) and command[0] in ("-h", "--help")
    if not command or not command[0] or help_requested:
        print(
            "Usage: with-build-lock.py [--] command [arguments ...]",
            file=sys.stdout if help_requested else sys.stderr,
        )
        return 0 if help_requested else 2

    try:
        LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
        descriptor = inherited_lock_fd()
        if descriptor is None:
            descriptor = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EAGAIN):
                raise
            print(
                "db3: another build or install is running; "
                "waiting for build/.build.lock...",
                file=sys.stderr,
                flush=True,
            )
            fcntl.flock(descriptor, fcntl.LOCK_EX)

        # flock belongs to the open file description. Inheriting this descriptor
        # lets recursive make/build invocations reuse the same lock safely.
        os.set_inheritable(descriptor, True)
        environment = os.environ.copy()
        environment[LOCK_FD_ENV] = str(descriptor)
        os.chdir(ROOT)
        os.execvpe(command[0], command, environment)
    except KeyboardInterrupt:
        print("db3: interrupted while waiting for the build lock", file=sys.stderr)
        return 130
    except OSError as error:
        print(f"db3: cannot run {command[0]!r} with the build lock: {error}", file=sys.stderr)
        if isinstance(error, FileNotFoundError):
            return 127
        if isinstance(error, PermissionError):
            return 126
        return 1


if __name__ == "__main__":
    sys.exit(main())
