#!/usr/bin/env python3
"""free_adopt_attribution.py -- attribute a lap's free-image cluster-write
regressions to the H-FA1 shape
(D-FREED-IMAGE-ADOPT-KEEPS-DEAD-LIFE-CORE-FIELDS-REGRESSES-FREE-DINODE).

A reload that adopts a free dinode over a live in-core core whose link count,
change count, size or block count differ from the dinode prints
P-FREE-ADOPT-CORE ino=<ino> ... applied=0|1 (applied=1: the core was taken
from the dinode; 0: the same-build control kept the freed life's).  A partial
cluster write that sends a slot whose image is behind the platter prints
P-DINO-CLOBBER#n path=partial ... with up to four
"[s<slot> ino=<ino> disk cc= mode= gen= nlink= -> mem cc= mode= gen= nlink=]"
details.  A regressed slot whose disk and mem images are both mode 0 is a
free-image regression, and each one is attributed by the latest
P-FREE-ADOPT-CORE line for the same inode on the same node before it:
  fa1             applied=0: the H-FA1 shape, the freed life's core written
  fa1_applied     applied=1: a regression after the core was taken from the
                  dinode (another writer of freed-life fields)
  free_unattributed  no adopt line for the inode before it
Regressed slots that are not both mode 0 are counted as other_regress.

Usage: free_adopt_attribution.py <lap-evidence-dir> <mark>
Reads <dir>/<node>_dmesg_stream.gz for every node, from the line holding
<mark> on.  Prints one FANODE line per node, the attributed free-image
regressions as FAREG lines, and a final FA totals line.
"""
import gzip
import os
import re
import sys

ADOPT_RE = re.compile(r'P-FREE-ADOPT-CORE ino=(\d+) gen=\d+ nlink=(\d+)->(\d+) '
                      r'cc=(\d+)->(\d+) .* applied=(\d) ')
CLOB_RE = re.compile(r'P-DINO-CLOBBER#\d+ path=(\w+) daddr=(\d+) .* regress=(\d+) ')
DET_RE = re.compile(r'\[s(\d+) ino=(\d+) disk cc=(\d+) mode=0([0-7]+) gen=(\d+) '
                    r'nlink=(\d+) -> mem cc=(\d+) mode=0([0-7]+) gen=(\d+) nlink=(\d+)\]')


def scan(path, mark):
    counts = dict(adopt_lines=0, adopt_applied=0, adopt_kept=0,
                  adopt_nlink_diff=0, adopt_cc_diff=0, clobber_partial=0,
                  free_regress=0, fa1=0, fa1_applied=0, free_unattributed=0,
                  other_regress=0)
    regs = []
    last = {}
    seen_mark = False
    with gzip.open(path, 'rt', errors='replace') as f:
        for n, line in enumerate(f, 1):
            if not seen_mark:
                if mark in line:
                    seen_mark = True
                continue
            m = ADOPT_RE.search(line)
            if m:
                ino = m.group(1)
                applied = m.group(6) == '1'
                last[ino] = (n, applied)
                counts['adopt_lines'] += 1
                counts['adopt_applied' if applied else 'adopt_kept'] += 1
                if m.group(2) != m.group(3):
                    counts['adopt_nlink_diff'] += 1
                if m.group(4) != m.group(5):
                    counts['adopt_cc_diff'] += 1
                continue
            m = CLOB_RE.search(line)
            if not m or m.group(1) != 'partial' or m.group(3) == '0':
                continue
            counts['clobber_partial'] += 1
            daddr = m.group(2)
            for d in DET_RE.findall(line):
                slot, ino, dmode, mmode = d[0], d[1], int(d[3], 8), int(d[7], 8)
                if dmode != 0 or mmode != 0:
                    counts['other_regress'] += 1
                    continue
                counts['free_regress'] += 1
                a = last.get(ino)
                if a is None:
                    cls = 'free_unattributed'
                elif a[1]:
                    cls = 'fa1_applied'
                else:
                    cls = 'fa1'
                counts[cls] += 1
                regs.append((cls, n, daddr, slot, ino, d[2], d[5], d[6], d[9]))
    return seen_mark, counts, regs


def main():
    if len(sys.argv) != 3:
        print('usage: free_adopt_attribution.py <lap-evidence-dir> <mark>', file=sys.stderr)
        return 2
    out, mark = sys.argv[1], sys.argv[2]
    streams = sorted(p for p in os.listdir(out) if p.endswith('_dmesg_stream.gz'))
    if not streams:
        print('FA ERROR no <node>_dmesg_stream.gz in %s' % out)
        return 2
    tot = {}
    for s in streams:
        node = s[:-len('_dmesg_stream.gz')]
        seen, c, regs = scan(os.path.join(out, s), mark)
        if not seen:
            print('FA ERROR %s has no line holding the mark %s' % (s, mark))
            return 2
        print('FANODE node=%s %s' % (node, ' '.join('%s=%d' % kv for kv in c.items())))
        for cls, n, daddr, slot, ino, dcc, dnl, mcc, mnl in regs:
            print('FAREG node=%s class=%s line=%d daddr=%s slot=%s ino=%s disk_cc=%s disk_nlink=%s mem_cc=%s mem_nlink=%s'
                  % (node, cls, n, daddr, slot, ino, dcc, dnl, mcc, mnl))
        for k, v in c.items():
            tot[k] = tot.get(k, 0) + v
    print('FA %s' % ' '.join('%s=%d' % kv for kv in tot.items()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
