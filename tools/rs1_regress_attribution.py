#!/usr/bin/env python3
"""rs1_regress_attribution.py -- attribute a lap's partial-path inode-cluster
regressions to the H-RS1 shape (D-INODE-CLUSTER-PUBLISH-WITHOUT-AUTHORITY).

A partial cluster write that sends a slot whose image is behind the platter
prints P-DINO-CLOBBER#n path=partial ... regress=N with up to four
"[s<slot> ino=<ino> disk ...]" details.  The same write path prints, for a
logged slot staged under a dead tenure, P219-LOGGED-NO-AUTHORITY (ratelimited;
since H-RS1 it carries landed=) and, for such a slot that already landed in a
release-flush or demoter context, P-RS1-LANDED-SKIP (masked=0|1).  Both come
from the same submission as the clobber check, a few lines ahead of it.

Each regressed slot is attributed by the nearest preceding line for the same
(daddr, slot, ino) within WINDOW stream lines:
  rs1            a P-RS1-LANDED-SKIP line: the H-RS1 shape, written because
                 masked=0 (a masked slot is never written, so never regresses)
  landed_unseen  no P-RS1 line, but a P219 line with stale=1 landed=1 and
                 relflush or demoter set (the shape, with its line missing)
  unlanded       a P219 line with stale=1 landed=0
  other_p219     any other P219 line
  unattributed   none of these

A slot a mask kept off the platter while its image was behind it is named by
the clobber check's P-DINO-CLOBBER-MASKED line as "[m<slot> ino=<ino> disk
...]" (at most four per line; masked= is the full count).  Each named slot is
  prevented      when the nearest preceding P-RS1-LANDED-SKIP line for the same
                 (daddr, slot, ino), within WINDOW, reads masked=1: a regression
                 the H-RS1 mask stopped
  masked_other   otherwise (another mask's catch)
and masked_unnamed counts the slots a line's masked= holds beyond the ones it
names.

Usage: rs1_regress_attribution.py <lap-evidence-dir> <mark>
Reads <dir>/<node>_dmesg_stream.gz for every node, from the line holding
<mark> on.  Prints one RS1NODE line per node, the attributed regressions as
RS1REG lines, the prevented ones as RS1PREV lines, and a final RS1 totals
line.
"""
import gzip
import os
import re
import sys

WINDOW = 400

RS1_RE = re.compile(r'P-RS1-LANDED-SKIP daddr=(\d+) slot=(\d+) ino=(\d+) masked=(\d)')
P219_RE = re.compile(r'P219-LOGGED-NO-AUTHORITY daddr=(\d+) slot=(\d+) ino=(\d+) ')
CLOB_RE = re.compile(r'P-DINO-CLOBBER#\d+ path=(\w+) daddr=(\d+) .* regress=(\d+) ')
DET_RE = re.compile(r'\[s(\d+) ino=(\d+) disk ')
MASK_RE = re.compile(r'P-DINO-CLOBBER-MASKED#\d+ daddr=(\d+) path=\w+ masked=(\d+) ')
MDET_RE = re.compile(r'\[m(\d+) ino=(\d+) disk ')


def field(line, name):
    m = re.search(r' %s=(\d+)' % name, line)
    return int(m.group(1)) if m else -1


def scan(path, mark):
    counts = dict(rs1_lines=0, rs1_masked=0, rs1_unmasked=0, p219_stale_rfdem=0,
                  clobber_partial=0, rs1=0, landed_unseen=0, unlanded=0,
                  other_p219=0, unattributed=0, prevented=0, masked_other=0,
                  masked_unnamed=0)
    regs = []
    prevs = []
    last_rs1 = {}
    last_p219 = {}
    seen_mark = False
    with gzip.open(path, 'rt', errors='replace') as f:
        for n, line in enumerate(f, 1):
            if not seen_mark:
                if mark in line:
                    seen_mark = True
                continue
            m = RS1_RE.search(line)
            if m:
                key = (m.group(1), m.group(2), m.group(3))
                last_rs1[key] = (n, int(m.group(4)))
                counts['rs1_lines'] += 1
                counts['rs1_masked' if m.group(4) == '1' else 'rs1_unmasked'] += 1
                continue
            m = P219_RE.search(line)
            if m:
                key = (m.group(1), m.group(2), m.group(3))
                stale = field(line, 'stale')
                landed = field(line, 'landed')
                rf = field(line, 'relflush')
                dem = field(line, 'demoter')
                last_p219[key] = (n, stale, landed, rf, dem)
                if stale == 1 and (rf == 1 or dem == 1):
                    counts['p219_stale_rfdem'] += 1
                continue
            m = MASK_RE.search(line)
            if m:
                daddr = m.group(1)
                named = MDET_RE.findall(line)
                counts['masked_unnamed'] += max(0, int(m.group(2)) - len(named))
                for slot, ino in named:
                    r = last_rs1.get((daddr, slot, ino))
                    if r and r[1] == 1 and n - r[0] <= WINDOW:
                        counts['prevented'] += 1
                        prevs.append((n, daddr, slot, ino))
                    else:
                        counts['masked_other'] += 1
                continue
            m = CLOB_RE.search(line)
            if not m or m.group(1) != 'partial' or m.group(3) == '0':
                continue
            counts['clobber_partial'] += 1
            daddr = m.group(2)
            for slot, ino in DET_RE.findall(line):
                key = (daddr, slot, ino)
                r = last_rs1.get(key)
                p = last_p219.get(key)
                if r and n - r[0] <= WINDOW:
                    cls = 'rs1'
                elif p and n - p[0] <= WINDOW:
                    _, stale, landed, rf, dem = p
                    if stale == 1 and landed == 1 and (rf == 1 or dem == 1):
                        cls = 'landed_unseen'
                    elif stale == 1 and landed == 0:
                        cls = 'unlanded'
                    else:
                        cls = 'other_p219'
                else:
                    cls = 'unattributed'
                counts[cls] += 1
                regs.append((cls, n, daddr, slot, ino))
    return seen_mark, counts, regs, prevs


def main():
    if len(sys.argv) != 3:
        print('usage: rs1_regress_attribution.py <lap-evidence-dir> <mark>', file=sys.stderr)
        return 2
    out, mark = sys.argv[1], sys.argv[2]
    streams = sorted(p for p in os.listdir(out) if p.endswith('_dmesg_stream.gz'))
    if not streams:
        print('RS1 ERROR no <node>_dmesg_stream.gz in %s' % out)
        return 2
    tot = {}
    for s in streams:
        node = s[:-len('_dmesg_stream.gz')]
        seen, c, regs, prevs = scan(os.path.join(out, s), mark)
        if not seen:
            print('RS1 ERROR %s has no line holding the mark %s' % (s, mark))
            return 2
        print('RS1NODE node=%s %s' % (node, ' '.join('%s=%d' % kv for kv in c.items())))
        for cls, n, daddr, slot, ino in regs:
            print('RS1REG node=%s class=%s line=%d daddr=%s slot=%s ino=%s' % (node, cls, n, daddr, slot, ino))
        for n, daddr, slot, ino in prevs:
            print('RS1PREV node=%s line=%d daddr=%s slot=%s ino=%s' % (node, n, daddr, slot, ino))
        for k, v in c.items():
            tot[k] = tot.get(k, 0) + v
    print('RS1 %s' % ' '.join('%s=%d' % kv for kv in tot.items()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
