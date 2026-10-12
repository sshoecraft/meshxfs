#!/usr/bin/env python3
"""compress_evidence.py -- gzip large plain-text evidence files in place, losslessly.

The rig's LUN pool, the guest images and tests/evidence share clyde's root
filesystem, and the host preflight refuses every fleet run below 10 GB free.
Uncompressed load logs are the cheap space: two path_failover ops.log files
from 2026-10-04 were 9.1 GB as text and 124 MB gzipped.  Nothing is deleted:
each file is replaced by its .gz only after the .gz is written and verified,
and every reader of a kept log can zcat it.

Usage:
    tools/compress_evidence.py [--min-mb N] [--min-age-min N] [--jobs N] [--dry-run] [DIR]

DIR defaults to tests/evidence.  Only files over --min-mb (default 100) that
are not already compressed, were not modified in the last --min-age-min
minutes (default 120, so a running row's log is left to its writer), and
whose first 64 KiB is text are touched.  Each
file is compressed with pigz (gzip when pigz is absent) under a timeout of
--timeout seconds (default 300), then tested with `gzip -t`; a file whose
.gz fails the test keeps its original and the .gz is discarded.  Prints one
line per file and a total.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import os
import shutil
import subprocess
import sys
import time

SKIP_SUFFIXES = (".gz", ".xz", ".zst", ".bz2", ".img", ".ko", ".tar", ".zip")


def is_text(path: str) -> bool:
    with open(path, "rb") as f:
        head = f.read(65536)
    if b"\0" in head:
        return False
    try:
        head.decode("utf-8")
    except UnicodeDecodeError as e:
        # a multibyte character cut at the 64 KiB boundary is still text
        return e.start >= len(head) - 4
    return True


def candidates(root: str, min_bytes: int, min_age_s: int) -> list[tuple[int, str]]:
    # a file a running row is still writing must not be swapped for a .gz
    # under its writer: the tail written after the copy would be lost
    newest = time.time() - min_age_s
    found = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if name.endswith(SKIP_SUFFIXES):
                continue
            path = os.path.join(dirpath, name)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            if not os.path.isfile(path) or os.path.islink(path):
                continue
            if st.st_mtime > newest:
                continue
            if st.st_size >= min_bytes and is_text(path):
                found.append((st.st_size, path))
    return sorted(found, reverse=True)


def compress(path: str, tool: str, timeout: int) -> tuple[str, str]:
    gz = path + ".gz"
    if os.path.exists(gz):
        return path, f"SKIP {gz} already exists"
    try:
        with open(gz, "wb") as out:
            r = subprocess.run([tool, "-c", path], stdout=out, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.unlink(gz)
        return path, f"FAIL compression exceeded {timeout} s; original kept"
    if r.returncode != 0:
        os.unlink(gz)
        return path, f"FAIL {tool} rc={r.returncode}; original kept"
    t = subprocess.run(["gzip", "-t", gz], timeout=timeout,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if t.returncode != 0:
        os.unlink(gz)
        return path, "FAIL gzip -t on the result; original kept"
    shutil.copystat(path, gz)
    os.unlink(path)
    return path, f"OK {os.path.getsize(gz)} bytes"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("dir", nargs="?", default="tests/evidence")
    ap.add_argument("--min-mb", type=int, default=100)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--min-age-min", type=int, default=120,
                    help="skip files modified in the last N minutes (default 120)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    tool = shutil.which("pigz") or shutil.which("gzip")
    if not tool:
        print("no pigz or gzip on PATH", file=sys.stderr)
        return 2
    files = candidates(a.dir, a.min_mb * 1024 * 1024, a.min_age_min * 60)
    total = sum(s for s, _ in files)
    print(f"{len(files)} plain-text files over {a.min_mb} MB, {total / 2**30:.1f} GiB")
    if a.dry_run:
        for size, path in files:
            print(f"{size} {path}")
        return 0
    sizes = {p: s for s, p in files}
    failed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        for path, verdict in pool.map(lambda sp: compress(sp[1], tool, a.timeout), files):
            print(f"{sizes[path]} {path}: {verdict}")
            failed += verdict.startswith("FAIL")
    st = os.statvfs(a.dir)
    print(f"done: {len(files) - failed} compressed, {failed} failed; "
          f"{st.f_bavail * st.f_frsize / 2**30:.1f} GiB free on {a.dir}'s filesystem")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
