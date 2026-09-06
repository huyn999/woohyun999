#!/usr/bin/env python3
"""Best-effort POSIX_FADV_DONTNEED for one or more files."""

import os
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: fadvise_dontneed.py <file>...", file=sys.stderr)
        return 2

    if not hasattr(os, "posix_fadvise"):
        print("ERROR: os.posix_fadvise is unavailable on this Python", file=sys.stderr)
        return 1

    failed = 0
    for path in sys.argv[1:]:
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError as exc:
            print(f"ERROR: open {path}: {exc}", file=sys.stderr)
            failed += 1
            continue

        try:
            os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        except OSError as exc:
            print(f"ERROR: posix_fadvise {path}: {exc}", file=sys.stderr)
            failed += 1
        finally:
            os.close(fd)

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
