#!/usr/bin/env python3
"""Summarise P-BUFLOCK-HOLDER reports in a node's saved kernel log.

For each report: the buffer, its flags and age, the holder pid, whether the
holder shares a thread group with the reporting task's process (when the
stack dump names it), and the MXFS/XFS frames of the holder's stack dump.

usage: tools/buflock_holder_report.py <dmesg file> [...]
"""
import re
import sys

HOLDER = re.compile(r"P-BUFLOCK-HOLDER n=(\d+) (\S+) ino=(\d+) daddr=(\d+) ops=(\S+) "
                    r"flags=(0x[0-9a-f]+) .*?lock_pid=(-?\d+) lock_age_ms=(\d+)")
EVICT = re.compile(r"P36-EVICT-LOCKED ino=(\d+) daddr=(\d+)(?: mode=(\S+))?")
TASK = re.compile(r"task:(\S+)\s+state:(\S+).*? pid:(\d+) tgid:(\d+)")
FRAME = re.compile(r"\]\s+\??\s*([A-Za-z0-9_.]+)\+0x")


def frames_for(lines, pid):
    """Frames of the stack dump for task pid: the dump lines of different
    tasks interleave, so collect every frame line between this task's header
    and the next task header or report, and keep the xfs/mxfs/blk/scsi ones."""
    out = []
    for i, ln in enumerate(lines):
        m = TASK.search(ln)
        if not m or m.group(3) != pid:
            continue
        tgid = m.group(4)
        for ln2 in lines[i + 1:i + 60]:
            if TASK.search(ln2) or "P-BUFLOCK-HOLDER" in ln2:
                break
            f = FRAME.search(ln2)
            if f and re.search(r"xfs|mxfs|caw|scsi|blk_|iowait|_read", f.group(1)):
                out.append(f.group(1))
        return tgid, out
    return None, out


def main():
    for path in sys.argv[1:]:
        with open(path, errors="replace") as f:
            lines = f.read().splitlines()
        evicts = [EVICT.search(l) for l in lines]
        evicts = [m for m in evicts if m]
        modes = {}
        for m in evicts:
            modes[m.group(3) or "?"] = modes.get(m.group(3) or "?", 0) + 1
        print(f"== {path}: P36-EVICT-LOCKED={len(evicts)} by caller mode {modes}")
        for ln in lines:
            m = HOLDER.search(ln)
            if not m:
                continue
            n, why, ino, daddr, ops, flags, pid, age = m.groups()
            tgid, fr = frames_for(lines, pid)
            st = " > ".join(dict.fromkeys(fr)) if fr else "(no stack dump)"
            print(f"n={n} ino={ino} daddr={daddr} flags={flags} age={age}ms "
                  f"holder={pid} tgid={tgid} :: {st[:400]}")


if __name__ == "__main__":
    main()
